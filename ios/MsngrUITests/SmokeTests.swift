import XCTest

/// Смоук-гейт: базовые пользовательские сценарии.
/// Требует запущенный wrangler dev на :8787 и юзера akuz на сервере.
/// Тесты идут по алфавиту — префиксы фиксируют порядок.
final class SmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // forwards a custom stand to the app under test; the test runner process
        // itself doesn't share its environment with the launched app by default
        if let server = ProcessInfo.processInfo.environment["MSNGR_SERVER"] {
            app.launchEnvironment["MSNGR_SERVER"] = server
        }
        app.launch()
        ensureRegistered()
    }

    /// Первый запуск на чистом симуляторе — регистрируем свежего юзера.
    private func ensureRegistered() {
        let username = app.textFields["reg.username"]
        if username.waitForExistence(timeout: 3) {
            username.tap()
            username.typeText("ui\(Int(Date().timeIntervalSince1970) % 100_000_000)")
            // submit stays disabled until a display name (>= 3 chars) is filled too
            let displayName = app.textFields["reg.displayName"]
            displayName.tap()
            displayName.typeText("UI Tester")
            app.buttons["reg.submit"].tap()
        }
        // ждём сам список, а не заголовок навигации: заголовка в дереве
        // доступности нет, пока список пуст и его закрывает пустое состояние.
        // Регистрация генерирует ключи, на симуляторе это занимает секунды
        XCTAssertTrue(app.otherElements["chatlist.root"].waitForExistence(timeout: 30)
                        || app.staticTexts["Чаты"].exists,
                      "чат-лист не открылся")
    }

    /// Открывает чат с akuz: из списка, либо через поиск нового чата.
    private func openChatWithAkuz() {
        let existing = app.cells.containing(NSPredicate(format: "label CONTAINS 'Akuz'")).firstMatch
        if existing.waitForExistence(timeout: 2) {
            existing.tap()
        } else {
            app.buttons["chatlist.new"].tap()
            // в шите нового чата своё поле — не путать с «Поиск» чат-листа под шитом
            let search = app.searchFields["Юзернейм или имя"]
            XCTAssertTrue(search.waitForExistence(timeout: 5), "нет поля поиска юзеров")
            search.tap()
            _ = search.waitForExistence(timeout: 1)
            search.typeText("akuz")
            let row = app.staticTexts["@akuz"]
            XCTAssertTrue(row.waitForExistence(timeout: 8), "юзер akuz не найден поиском")
            row.tap()
        }
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 8), "чат не открылся")
    }

    private func send(_ text: String) {
        let input = app.textViews["chat.input"]
        input.tap()
        input.typeText(text)
        app.buttons["chat.send"].tap()
    }

    func testA_LaunchShowsChatList() {
        XCTAssertTrue(app.buttons["chatlist.new"].exists)
    }

    func testB_SendTextAppearsInFeed() {
        openChatWithAkuz()
        let marker = "smoke-\(Int(Date().timeIntervalSince1970))"
        send(marker)
        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 8),
                      "отправленное сообщение не появилось в ленте")
    }

    func testC_DraftPersistsAcrossReopen() {
        openChatWithAkuz()
        let input = app.textViews["chat.input"]
        input.tap()
        let draft = "draft-\(Int(Date().timeIntervalSince1970))"
        input.typeText(draft)
        app.navigationBars.buttons.firstMatch.tap() // назад
        XCTAssertTrue(app.staticTexts["Чаты"].waitForExistence(timeout: 5))
        openChatWithAkuz()
        let value = app.textViews["chat.input"].value as? String ?? ""
        XCTAssertTrue(value.contains(draft), "черновик потерян: '\(value)'")
        // очистка: отправляем черновик, чтобы следующий прогон стартовал чисто
        app.buttons["chat.send"].tap()
    }

    func testD_LongMessageContextMenu() {
        openChatWithAkuz()
        let input = app.textViews["chat.input"]
        input.tap()
        let marker = "long-\(Int(Date().timeIntervalSince1970))"
        input.typeText(marker)
        for i in 1...14 { input.typeText("\nстрока \(i)") }
        app.buttons["chat.send"].tap()
        let bubble = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", marker)).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 8))
        bubble.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["Ответить"].waitForExistence(timeout: 4),
                      "контекстное меню не показалось для длинного сообщения")
        // закрыть тапом по фону (верхний левый угол)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).tap()
        XCTAssertFalse(app.staticTexts["Ответить"].waitForExistence(timeout: 2),
                       "меню не закрылось по тапу мимо")
    }

    func testE_AttachMenuOpensFromPaperclip() {
        openChatWithAkuz()
        app.buttons["chat.attach"].tap()
        XCTAssertTrue(app.buttons["Фото или видео"].waitForExistence(timeout: 4)
                      || app.staticTexts["Фото или видео"].waitForExistence(timeout: 1),
                      "меню вложений не открылось")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    }
}
