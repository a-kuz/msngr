import CryptoKit
import XCTest
@testable import MsngrCrypto

/// The bundle that carries an account to a device its owner has just
/// authorised. The server relays it, so what these tests hold to is that only
/// the device that opened the session can read it, and only out of the session
/// it was sealed for.
final class ProvisioningTests: XCTestCase {
    private let bundle = Provisioning.Bundle(
        userId: "u1", username: "hana", displayName: "Hana",
        identityDH: Data(repeating: 7, count: 32).base64urlEncodedString(),
        identitySigning: Data(repeating: 9, count: 32).base64urlEncodedString())

    func testTheDeviceThatOpenedTheSessionReadsTheBundle() throws {
        let eph = Provisioning.EphemeralKeyPair()
        let sealed = try Provisioning.seal(bundle, to: eph.publicKey, provisionId: "p1")
        let opened = try Provisioning.open(sealed, with: eph, provisionId: "p1")
        XCTAssertEqual(opened.userId, "u1")
        XCTAssertEqual(opened.username, "hana")
        XCTAssertEqual(opened.identityDH, bundle.identityDH)
        XCTAssertEqual(opened.identitySigning, bundle.identitySigning)
    }

    func testAnotherDeviceCannotRead() throws {
        let eph = Provisioning.EphemeralKeyPair()
        let sealed = try Provisioning.seal(bundle, to: eph.publicKey, provisionId: "p1")
        XCTAssertThrowsError(
            try Provisioning.open(sealed, with: Provisioning.EphemeralKeyPair(), provisionId: "p1")
        ) { XCTAssertEqual($0 as? Provisioning.Failure, .decryptionFailed) }
    }

    /// The session id is the salt, so a bundle lifted out of one session opens
    /// nothing in another even on the same ephemeral key.
    func testBundleDoesNotTravelBetweenSessions() throws {
        let eph = Provisioning.EphemeralKeyPair()
        let sealed = try Provisioning.seal(bundle, to: eph.publicKey, provisionId: "p1")
        XCTAssertThrowsError(try Provisioning.open(sealed, with: eph, provisionId: "p2")) {
            XCTAssertEqual($0 as? Provisioning.Failure, .decryptionFailed)
        }
    }

    func testSwappedSenderKeyIsRejected() throws {
        let eph = Provisioning.EphemeralKeyPair()
        let sealed = try Provisioning.seal(bundle, to: eph.publicKey, provisionId: "p1")
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let swapped = Provisioning.SealedBundle(
            v: 1, epk: other.base64urlEncodedString(), ct: sealed.ct)
        XCTAssertThrowsError(try Provisioning.open(swapped, with: eph, provisionId: "p1")) {
            XCTAssertEqual($0 as? Provisioning.Failure, .decryptionFailed)
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        let eph = Provisioning.EphemeralKeyPair()
        let sealed = try Provisioning.seal(bundle, to: eph.publicKey, provisionId: "p1")
        var ct = Data(base64urlEncoded: sealed.ct)!
        ct[ct.count - 1] ^= 0x01
        let tampered = Provisioning.SealedBundle(
            v: 1, epk: sealed.epk, ct: ct.base64urlEncodedString())
        XCTAssertThrowsError(try Provisioning.open(tampered, with: eph, provisionId: "p1")) {
            XCTAssertEqual($0 as? Provisioning.Failure, .decryptionFailed)
        }
    }

    func testGarbageIsRejectedWithoutCrashing() throws {
        let eph = Provisioning.EphemeralKeyPair()
        let junk = Provisioning.SealedBundle(v: 1, epk: "!!!", ct: "!!!")
        XCTAssertThrowsError(try Provisioning.open(junk, with: eph, provisionId: "p1")) {
            XCTAssertEqual($0 as? Provisioning.Failure, .badFormat)
        }
        let shortKey = Provisioning.SealedBundle(
            v: 1, epk: Data([1, 2, 3]).base64urlEncodedString(),
            ct: Data(repeating: 0, count: 40).base64urlEncodedString())
        XCTAssertThrowsError(try Provisioning.open(shortKey, with: eph, provisionId: "p1")) {
            XCTAssertEqual($0 as? Provisioning.Failure, .decryptionFailed)
        }
    }

    func testEnvelopeFromANewerBuildIsRefused() throws {
        let eph = Provisioning.EphemeralKeyPair()
        let future = Provisioning.SealedBundle(v: 2, epk: "", ct: "")
        XCTAssertThrowsError(try Provisioning.open(future, with: eph, provisionId: "p1")) {
            XCTAssertEqual($0 as? Provisioning.Failure, .unsupportedVersion)
        }
    }

    /// The account identity survives the trip as the same key pair, which is
    /// the whole point: a linked device that generated its own would show every
    /// contact a changed security code.
    func testTheIdentityArrivesAsTheSameKeyPair() throws {
        let identity = IdentityKeyPair()
        let eph = Provisioning.EphemeralKeyPair()
        let sent = Provisioning.Bundle(
            userId: "u1", username: "hana", displayName: "Hana",
            identityDH: identity.dh.rawRepresentation.base64urlEncodedString(),
            identitySigning: identity.signing.rawRepresentation.base64urlEncodedString())
        let opened = try Provisioning.open(
            try Provisioning.seal(sent, to: eph.publicKey, provisionId: "p1"),
            with: eph, provisionId: "p1")
        let restored = try IdentityKeyPair(
            dhRaw: Data(base64urlEncoded: opened.identityDH)!,
            signingRaw: Data(base64urlEncoded: opened.identitySigning)!)
        XCTAssertEqual(restored.publicKeys, identity.publicKeys)

        // and it signs prekeys the peer verifies against the account's key
        let spk = try SignedPreKey(id: 1, identity: restored)
        let bundle = PreKeyBundle(identity: identity.publicKeys, signedPreKeyId: spk.id,
                                  signedPreKey: spk.key.publicKey.rawRepresentation,
                                  signedPreKeySignature: spk.signature,
                                  oneTimePreKeyId: nil, oneTimePreKey: nil)
        XCTAssertTrue(bundle.verifySignature())
    }

    /// Two devices of one account run X3DH against each other with the same
    /// identity key on both sides. The self-DH that produces is a well-defined
    /// X25519 result, and the session that comes out of it works.
    func testTwoDevicesOfOneAccountEstablishASession() throws {
        let account = IdentityKeyPair()
        let spk = try SignedPreKey(id: 1, identity: account)
        let otp = OneTimePreKey(id: 1)
        let bundle = PreKeyBundle(identity: account.publicKeys, signedPreKeyId: spk.id,
                                  signedPreKey: spk.key.publicKey.rawRepresentation,
                                  signedPreKeySignature: spk.signature,
                                  oneTimePreKeyId: otp.id,
                                  oneTimePreKey: otp.key.publicKey.rawRepresentation)
        let initiator = try X3DH.initiate(our: account, their: bundle)
        let responder = try X3DH.respond(our: account, ourSignedPreKey: spk.key,
                                         ourOneTimePreKey: otp.key,
                                         theirIdentityDH: account.dh.publicKey.rawRepresentation,
                                         theirEphemeral: initiator.ephemeralPublic)
        XCTAssertEqual(initiator.sharedSecret, responder.sharedSecret)
        XCTAssertEqual(initiator.associatedData, responder.associatedData)
    }
}
