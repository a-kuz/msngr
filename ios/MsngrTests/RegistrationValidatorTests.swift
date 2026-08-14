import XCTest
@testable import Msngr

final class RegistrationValidatorTests: XCTestCase {

    // MARK: Имя

    func testNameValid() {
        XCTAssertTrue(RegistrationValidator.isValidName("Аня"))
        XCTAssertTrue(RegistrationValidator.isValidName("Bob"))
        XCTAssertTrue(RegistrationValidator.isValidName("  Ли Он  ")) // пробелы по краям обрезаются
    }

    func testNameTooShort() {
        XCTAssertFalse(RegistrationValidator.isValidName(""))
        XCTAssertFalse(RegistrationValidator.isValidName("Ян"))
        XCTAssertFalse(RegistrationValidator.isValidName("  a  ")) // после trim остаётся 1 символ
        XCTAssertFalse(RegistrationValidator.isValidName("   \n ")) // одни пробелы
    }

    func testTrimmedName() {
        XCTAssertEqual(RegistrationValidator.trimmedName("  Bob \n"), "Bob")
        XCTAssertEqual(RegistrationValidator.trimmedName("Bob"), "Bob")
    }

    // MARK: Юзернейм

    func testUsernameValid() {
        XCTAssertTrue(RegistrationValidator.isValidUsername("bob"))
        XCTAssertTrue(RegistrationValidator.isValidUsername("bobby11"))
        XCTAssertTrue(RegistrationValidator.isValidUsername("user_name_42"))
        XCTAssertTrue(RegistrationValidator.isValidUsername(String(repeating: "a", count: 32)))
    }

    func testUsernameInvalid() {
        XCTAssertFalse(RegistrationValidator.isValidUsername(""))
        XCTAssertFalse(RegistrationValidator.isValidUsername("ab")) // короче 3
        XCTAssertFalse(RegistrationValidator.isValidUsername(String(repeating: "a", count: 33)))
        XCTAssertFalse(RegistrationValidator.isValidUsername("боб")) // кириллица
        XCTAssertFalse(RegistrationValidator.isValidUsername("bob smith")) // пробел
        XCTAssertFalse(RegistrationValidator.isValidUsername("bob-1")) // дефис
        XCTAssertFalse(RegistrationValidator.isValidUsername("bob!"))
    }
}
