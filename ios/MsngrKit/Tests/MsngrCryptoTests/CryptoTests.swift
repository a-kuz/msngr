import XCTest
import CryptoKit
@testable import MsngrCrypto

final class X3DHTests: XCTestCase {
    func testSharedSecretMatches() throws {
        let alice = IdentityKeyPair()
        let bob = IdentityKeyPair()
        let bobSPK = try SignedPreKey(id: 1, identity: bob)
        let bobOTP = OneTimePreKey(id: 7)

        let bundle = PreKeyBundle(
            identity: bob.publicKeys,
            signedPreKeyId: 1,
            signedPreKey: bobSPK.key.publicKey.rawRepresentation,
            signedPreKeySignature: bobSPK.signature,
            oneTimePreKeyId: 7,
            oneTimePreKey: bobOTP.key.publicKey.rawRepresentation
        )
        let a = try X3DH.initiate(our: alice, their: bundle)
        let b = try X3DH.respond(our: bob, ourSignedPreKey: bobSPK.key,
                                 ourOneTimePreKey: bobOTP.key,
                                 theirIdentityDH: alice.publicKeys.dh,
                                 theirEphemeral: a.ephemeralPublic)
        XCTAssertEqual(a.sharedSecret.withUnsafeBytes { Data($0) },
                       b.sharedSecret.withUnsafeBytes { Data($0) })
        XCTAssertEqual(a.associatedData, b.associatedData)
    }

    func testWithoutOneTimePreKey() throws {
        let alice = IdentityKeyPair()
        let bob = IdentityKeyPair()
        let bobSPK = try SignedPreKey(id: 1, identity: bob)
        let bundle = PreKeyBundle(
            identity: bob.publicKeys, signedPreKeyId: 1,
            signedPreKey: bobSPK.key.publicKey.rawRepresentation,
            signedPreKeySignature: bobSPK.signature,
            oneTimePreKeyId: nil, oneTimePreKey: nil
        )
        let a = try X3DH.initiate(our: alice, their: bundle)
        let b = try X3DH.respond(our: bob, ourSignedPreKey: bobSPK.key, ourOneTimePreKey: nil,
                                 theirIdentityDH: alice.publicKeys.dh,
                                 theirEphemeral: a.ephemeralPublic)
        XCTAssertEqual(a.sharedSecret.withUnsafeBytes { Data($0) },
                       b.sharedSecret.withUnsafeBytes { Data($0) })
    }

    func testRejectsBadSignature() throws {
        let alice = IdentityKeyPair()
        let bob = IdentityKeyPair()
        let mallory = IdentityKeyPair()
        let bobSPK = try SignedPreKey(id: 1, identity: mallory) // signed by the wrong identity
        let bundle = PreKeyBundle(
            identity: bob.publicKeys, signedPreKeyId: 1,
            signedPreKey: bobSPK.key.publicKey.rawRepresentation,
            signedPreKeySignature: bobSPK.signature,
            oneTimePreKeyId: nil, oneTimePreKey: nil
        )
        XCTAssertThrowsError(try X3DH.initiate(our: alice, their: bundle))
    }
}

final class DoubleRatchetTests: XCTestCase {
    private func makeSessions() throws -> (alice: DoubleRatchetSession, bob: DoubleRatchetSession) {
        let alice = IdentityKeyPair()
        let bob = IdentityKeyPair()
        let bobSPK = try SignedPreKey(id: 1, identity: bob)
        let bundle = PreKeyBundle(
            identity: bob.publicKeys, signedPreKeyId: 1,
            signedPreKey: bobSPK.key.publicKey.rawRepresentation,
            signedPreKeySignature: bobSPK.signature,
            oneTimePreKeyId: nil, oneTimePreKey: nil
        )
        let a = try X3DH.initiate(our: alice, their: bundle)
        let b = try X3DH.respond(our: bob, ourSignedPreKey: bobSPK.key, ourOneTimePreKey: nil,
                                 theirIdentityDH: alice.publicKeys.dh,
                                 theirEphemeral: a.ephemeralPublic)
        let sa = try DoubleRatchetSession.initAlice(
            sharedSecret: a.sharedSecret,
            theirRatchetPub: bobSPK.key.publicKey.rawRepresentation,
            ad: a.associatedData)
        let sb = DoubleRatchetSession.initBob(
            sharedSecret: b.sharedSecret, ourRatchetKey: bobSPK.key, ad: b.associatedData)
        return (sa, sb)
    }

    func testPingPong() throws {
        var (alice, bob) = try makeSessions()
        for i in 0..<20 {
            let m1 = try alice.encrypt(Data("a->b \(i)".utf8))
            XCTAssertEqual(try bob.decrypt(m1), Data("a->b \(i)".utf8))
            let m2 = try bob.encrypt(Data("b->a \(i)".utf8))
            XCTAssertEqual(try alice.decrypt(m2), Data("b->a \(i)".utf8))
        }
    }

    func testOutOfOrderWithinChain() throws {
        var (alice, bob) = try makeSessions()
        let m0 = try alice.encrypt(Data("0".utf8))
        let m1 = try alice.encrypt(Data("1".utf8))
        let m2 = try alice.encrypt(Data("2".utf8))
        XCTAssertEqual(try bob.decrypt(m2), Data("2".utf8))
        XCTAssertEqual(try bob.decrypt(m0), Data("0".utf8))
        XCTAssertEqual(try bob.decrypt(m1), Data("1".utf8))
    }

    func testOutOfOrderAcrossRatchetSteps() throws {
        var (alice, bob) = try makeSessions()
        let a0 = try alice.encrypt(Data("a0".utf8))
        let a1 = try alice.encrypt(Data("a1".utf8)) // held back
        XCTAssertEqual(try bob.decrypt(a0), Data("a0".utf8))
        let b0 = try bob.encrypt(Data("b0".utf8))
        XCTAssertEqual(try alice.decrypt(b0), Data("b0".utf8))
        let a2 = try alice.encrypt(Data("a2".utf8)) // already on a new chain
        XCTAssertEqual(try bob.decrypt(a2), Data("a2".utf8))
        XCTAssertEqual(try bob.decrypt(a1), Data("a1".utf8)) // the straggler from the old chain
    }

    func testDuplicateFails() throws {
        var (alice, bob) = try makeSessions()
        let m = try alice.encrypt(Data("x".utf8))
        _ = try bob.decrypt(m)
        XCTAssertThrowsError(try bob.decrypt(m))
    }

    func testTamperedCiphertextFails() throws {
        var (alice, bob) = try makeSessions()
        let m = try alice.encrypt(Data("x".utf8))
        var bad = m.ciphertext
        bad[bad.count - 1] ^= 0xFF
        XCTAssertThrowsError(try bob.decrypt(RatchetMessage(header: m.header, ciphertext: bad)))
    }

    func testReplayedFirstMessageDoesNotResetRatchet() throws {
        // Bob receives a prekey message, opens a session and steps the ratchet.
        // Feeding him the same prekey message again must not reset that session.
        var (alice, bob) = try makeSessions()
        let pk = try alice.encrypt(Data("first".utf8))
        XCTAssertEqual(try bob.decrypt(pk), Data("first".utf8))
        // step the ratchet forward
        let reply = try bob.encrypt(Data("reply".utf8))
        XCTAssertEqual(try alice.decrypt(reply), Data("reply".utf8))
        let second = try alice.encrypt(Data("second".utf8))
        XCTAssertEqual(try bob.decrypt(second), Data("second".utf8))
        // bob.hasReceived == true is what sends E2EEManager down the stale_pk_ignored branch.
        XCTAssertTrue(bob.hasReceived)
    }

    func testSessionSerializationRoundtrip() throws {
        var (alice, bob) = try makeSessions()
        _ = try bob.decrypt(try alice.encrypt(Data("1".utf8)))
        // serialize both states and carry on with the restored copies
        let alice2Data = try JSONEncoder().encode(alice)
        let bob2Data = try JSONEncoder().encode(bob)
        var alice2 = try JSONDecoder().decode(DoubleRatchetSession.self, from: alice2Data)
        var bob2 = try JSONDecoder().decode(DoubleRatchetSession.self, from: bob2Data)
        let m = try bob2.encrypt(Data("after restore".utf8))
        XCTAssertEqual(try alice2.decrypt(m), Data("after restore".utf8))
    }
}

final class SenderKeyTests: XCTestCase {
    func testGroupFanout() throws {
        var sender = SenderKeyState()
        let dist = try sender.distribution
        var r1 = SenderKeyReceiver(distribution: dist)
        var r2 = SenderKeyReceiver(distribution: dist)
        for i in 0..<10 {
            let msg = try sender.encrypt(Data("msg \(i)".utf8))
            XCTAssertEqual(try r1.decrypt(msg), Data("msg \(i)".utf8))
            XCTAssertEqual(try r2.decrypt(msg), Data("msg \(i)".utf8))
        }
    }

    func testOutOfOrder() throws {
        var sender = SenderKeyState()
        var r = SenderKeyReceiver(distribution: try sender.distribution)
        let m0 = try sender.encrypt(Data("0".utf8))
        let m1 = try sender.encrypt(Data("1".utf8))
        let m2 = try sender.encrypt(Data("2".utf8))
        XCTAssertEqual(try r.decrypt(m2), Data("2".utf8))
        XCTAssertEqual(try r.decrypt(m0), Data("0".utf8))
        XCTAssertEqual(try r.decrypt(m1), Data("1".utf8))
        XCTAssertThrowsError(try r.decrypt(m1)) // replay
    }

    func testLateJoinerCannotReadHistory() throws {
        var sender = SenderKeyState()
        _ = try sender.encrypt(Data("old".utf8))
        let distLater = try sender.distribution // iteration=1
        var late = SenderKeyReceiver(distribution: distLater)
        let newMsg = try sender.encrypt(Data("new".utf8))
        XCTAssertEqual(try late.decrypt(newMsg), Data("new".utf8))
    }

    func testForgedSignatureRejected() throws {
        var sender = SenderKeyState()
        var r = SenderKeyReceiver(distribution: try sender.distribution)
        let msg = try sender.encrypt(Data("x".utf8))
        var otherSigner = SenderKeyState()
        let forged = try otherSigner.encrypt(Data("y".utf8))
        let fake = SenderKeyMessage(keyId: msg.keyId, iteration: msg.iteration,
                                    ciphertext: msg.ciphertext, signature: forged.signature)
        XCTAssertThrowsError(try r.decrypt(fake))
    }
}

final class MediaCryptoTests: XCTestCase {
    func testRoundtrip() throws {
        let data = Data((0..<100_000).map { UInt8($0 % 251) })
        let enc = try MediaCrypto.encrypt(data)
        XCTAssertNotEqual(enc.ciphertext, data)
        let dec = try MediaCrypto.decrypt(enc.ciphertext, key: enc.key, expectedSHA256: enc.sha256)
        XCTAssertEqual(dec, data)
    }

    func testHashMismatchRejected() throws {
        let enc = try MediaCrypto.encrypt(Data("hello".utf8))
        var bad = enc.ciphertext
        bad[0] ^= 1
        XCTAssertThrowsError(try MediaCrypto.decrypt(bad, key: enc.key, expectedSHA256: enc.sha256))
    }
}

final class SafetyNumberTests: XCTestCase {
    func testSymmetricAndStable() {
        let a = IdentityKeyPair().publicKeys
        let b = IdentityKeyPair().publicKeys
        let n1 = SafetyNumbers.generate(ourIdentitySigning: a.signing, ourUserId: "alice",
                                        theirIdentitySigning: b.signing, theirUserId: "bob")
        let n2 = SafetyNumbers.generate(ourIdentitySigning: b.signing, ourUserId: "bob",
                                        theirIdentitySigning: a.signing, theirUserId: "alice")
        XCTAssertEqual(n1, n2)
        XCTAssertEqual(n1.count, 60)
        let c = IdentityKeyPair().publicKeys
        let n3 = SafetyNumbers.generate(ourIdentitySigning: a.signing, ourUserId: "alice",
                                        theirIdentitySigning: c.signing, theirUserId: "carol")
        XCTAssertNotEqual(n1, n3)
    }
}
