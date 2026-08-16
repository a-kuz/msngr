import XCTest
@testable import Msngr

final class RegistrationValidatorTests: XCTestCase {

    // MARK: Display name

    func testNameValid() {
        XCTAssertTrue(RegistrationValidator.isValidName("Аня"))
        XCTAssertTrue(RegistrationValidator.isValidName("Bob"))
        XCTAssertTrue(RegistrationValidator.isValidName("  Ли Он  ")) // surrounding whitespace is trimmed
    }

    func testNameTooShort() {
        XCTAssertFalse(RegistrationValidator.isValidName(""))
        XCTAssertFalse(RegistrationValidator.isValidName("Ян"))
        XCTAssertFalse(RegistrationValidator.isValidName("  a  ")) // 1 character left after the trim
        XCTAssertFalse(RegistrationValidator.isValidName("   \n ")) // whitespace only
    }

    func testTrimmedName() {
        XCTAssertEqual(RegistrationValidator.trimmedName("  Bob \n"), "Bob")
        XCTAssertEqual(RegistrationValidator.trimmedName("Bob"), "Bob")
    }

    // MARK: Username

    func testUsernameValid() {
        XCTAssertTrue(RegistrationValidator.isValidUsername("bob"))
        XCTAssertTrue(RegistrationValidator.isValidUsername("bobby11"))
        XCTAssertTrue(RegistrationValidator.isValidUsername("user_name_42"))
        XCTAssertTrue(RegistrationValidator.isValidUsername(String(repeating: "a", count: 32)))
    }

    func testUsernameInvalid() {
        XCTAssertFalse(RegistrationValidator.isValidUsername(""))
        XCTAssertFalse(RegistrationValidator.isValidUsername("ab")) // shorter than 3
        XCTAssertFalse(RegistrationValidator.isValidUsername(String(repeating: "a", count: 33)))
        XCTAssertFalse(RegistrationValidator.isValidUsername("боб")) // cyrillic
        XCTAssertFalse(RegistrationValidator.isValidUsername("bob smith")) // space
        XCTAssertFalse(RegistrationValidator.isValidUsername("bob-1")) // hyphen
        XCTAssertFalse(RegistrationValidator.isValidUsername("bob!"))
    }
}
