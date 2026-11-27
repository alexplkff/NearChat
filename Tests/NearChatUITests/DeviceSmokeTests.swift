import XCTest

/// Exercises the already-installed app without deleting its container or sending messages.
final class DeviceSmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private var wasRunningNetwork = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "local.nearchat.lab")
        app.activate()
        XCTAssertTrue(app.buttons["tab-0"].waitForExistence(timeout: 15))
        guard !app.descendants(matching: .any)["storage-warning"].exists else {
            throw XCTSkip("Storage warning is present; do not terminate an app with unsaved data")
        }
        wasRunningNetwork = app.buttons["Стоп"].exists
        if wasRunningNetwork { app.buttons["Стоп"].tap() }
    }
    override func tearDownWithError() throws {
        if app != nil, app.state == .runningForeground, wasRunningNetwork, app.buttons["Начать"].exists {
            app.buttons["Начать"].tap()
        }
        app = nil
    }
    private func messageInput() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "message-input").firstMatch
    }
    private func assertNoExistingDraft() throws {
        app.buttons["tab-1"].tap()
        let input = messageInput()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        if let text = input.value as? String, !text.isEmpty, text != "Сообщение" {
            throw XCTSkip("Existing draft detected; restart was not performed")
        }
    }
    private func historyLabel() -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Локальная история ·")).firstMatch
    }
    private func restart() {
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["tab-0"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Начать"].exists, "Cold launch must leave networking off")
        XCTAssertFalse(app.descendants(matching: .any)["storage-warning"].exists)
    }
    func testIdentitySurvivesRelaunchAndNetworkStaysOff() throws {
        try assertNoExistingDraft()
        app.buttons["tab-0"].tap()
        let fingerprint = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9a-f]{16}")).firstMatch
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 5))
        let before = fingerprint.label
        restart()
        let after = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9a-f]{16}")).firstMatch
        XCTAssertTrue(after.waitForExistence(timeout: 5))
        XCTAssertEqual(after.label, before, "Public identity fingerprint changed")
    }
    func testExistingHistoryCountSurvivesRelaunch() throws {
        try assertNoExistingDraft()
        let counter = historyLabel()
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        let before = counter.label
        if before.contains("· 0 сообщений") { throw XCTSkip("No existing history to verify") }
        restart()
        app.buttons["tab-1"].tap()
        XCTAssertTrue(historyLabel().waitForExistence(timeout: 5))
        XCTAssertEqual(historyLabel().label, before)
    }
    func testKeyboardDoesNotBlockNavigation() throws {
        app.buttons["tab-1"].tap()
        let input = messageInput()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab-0"].isHittable)
        app.buttons["tab-0"].tap()
        let hidden = NSPredicate(format: "exists == false")
        expectation(for: hidden, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        app.buttons["tab-2"].tap()
        XCTAssertTrue(app.staticTexts["Счётчики текущего процесса"].exists)
        app.buttons["tab-3"].tap()
        XCTAssertTrue(app.textFields["history-budget-mb"].exists)
        app.textFields["history-budget-mb"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab-1"].isHittable)
        app.buttons["tab-1"].tap()
        expectation(for: hidden, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
    }
    func testInvalidRelayQuotaIsRejectedAndSavedLimitsSurviveRelaunch() throws {
        try assertNoExistingDraft()
        app.buttons["tab-3"].tap()
        let history = app.textFields["history-budget-mb"]
        let relay = app.textFields["relay-budget-mb"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        let originalHistory = try XCTUnwrap(history.value as? String)
        let originalRelay = try XCTUnwrap(relay.value as? String)
        relay.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        relay.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalRelay.count + 2) + "4")
        XCTAssertEqual(relay.value as? String, "4")
        app.buttons["Применить лимит ретрансляции"].tap()
        XCTAssertTrue(app.staticTexts["Недопустимый лимит хранилища"].waitForExistence(timeout: 5))
        restart()
        app.buttons["tab-3"].tap()
        XCTAssertEqual(app.textFields["history-budget-mb"].value as? String, originalHistory)
        XCTAssertEqual(app.textFields["relay-budget-mb"].value as? String, originalRelay)
    }
}
