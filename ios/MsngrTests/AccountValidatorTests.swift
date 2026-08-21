import XCTest
@testable import Msngr

final class AccountValidatorTests: XCTestCase {

    // MARK: Display name

    func testNameValid() {
        XCTAssertTrue(AccountValidator.isValidName("Ann"))
        XCTAssertTrue(AccountValidator.isValidName("  Li On  ")) // surrounding whitespace is trimmed
        XCTAssertTrue(AccountValidator.isValidName("Ian")) // two letters is a name
        XCTAssertTrue(AccountValidator.isValidName("Q"))
        XCTAssertTrue(AccountValidator.isValidName(String(repeating: "a", count: 64)))
    }

    func testNameEmptyOrTooLong() {
        XCTAssertFalse(AccountValidator.isValidName(""))
        XCTAssertFalse(AccountValidator.isValidName("   \n ")) // whitespace only
        XCTAssertFalse(AccountValidator.isValidName(String(repeating: "a", count: 65)))
    }

    func testNameHintOnlyOnceSomethingIsWrong() {
        XCTAssertNil(AccountValidator.nameHint(""))
        XCTAssertNil(AccountValidator.nameHint("Ian"))
        XCTAssertNotNil(AccountValidator.nameHint(String(repeating: "a", count: 65)))
    }

    func testTrimmedName() {
        XCTAssertEqual(AccountValidator.trimmedName("  Bob \n"), "Bob")
        XCTAssertEqual(AccountValidator.trimmedName("Bob"), "Bob")
    }

    // MARK: Username

    func testUsernameValid() {
        XCTAssertTrue(AccountValidator.isValidUsername("bob"))
        XCTAssertTrue(AccountValidator.isValidUsername("bobby11"))
        XCTAssertTrue(AccountValidator.isValidUsername("user_name_42"))
        XCTAssertTrue(AccountValidator.isValidUsername(String(repeating: "a", count: 32)))
    }

    func testUsernameInvalid() {
        XCTAssertFalse(AccountValidator.isValidUsername(""))
        XCTAssertFalse(AccountValidator.isValidUsername("ab")) // shorter than 3
        XCTAssertFalse(AccountValidator.isValidUsername(String(repeating: "a", count: 33)))
        XCTAssertFalse(AccountValidator.isValidUsername("böb")) // non-ascii letter
        XCTAssertFalse(AccountValidator.isValidUsername("bob smith")) // space
        XCTAssertFalse(AccountValidator.isValidUsername("bob-1")) // hyphen
        XCTAssertFalse(AccountValidator.isValidUsername("bob!"))
    }

    func testUsernameHintOnlyOnceSomethingIsWrong() {
        XCTAssertNil(AccountValidator.usernameHint(""))
        XCTAssertNil(AccountValidator.usernameHint("bob"))
        XCTAssertNotNil(AccountValidator.usernameHint("ab"))
        XCTAssertNotNil(AccountValidator.usernameHint("böb"))
    }
}
