//
//  Investment_AppUITests.swift
//  Investment AppUITests
//
//  Created by Mohammed Elrashidy on 17/10/2026.
//
//  Every test launches the app with `-uiTesting`: an empty, isolated portfolio and offline canned
//  Yahoo/Claude responses (see UITestEnvironment in the app), so nothing touches real data or the internet.
//

import XCTest

final class Investment_AppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
    }

    @MainActor
    private func launch(importingSample: Bool = false) {
        if importingSample {
            app.launchArguments.append("-uiTestImportSample")
        }
        app.launch()
    }

    /// First element whose label contains the text (works for Labels, Text and buttons alike).
    @MainActor
    private func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    private func clearAndType(_ field: XCUIElement, _ text: String) {
        field.tap()
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 2))
        field.typeText(text)
    }

    // MARK: - Investments

    @MainActor
    func testAddInvestmentBlocksInvalidNumbersThenSaves() throws {
        launch()
        app.buttons["Add Investment"].tap()

        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("UI Test Fund")

        let target = app.textFields["Target %"]
        clearAndType(target, "1.2.3")
        XCTAssertTrue(app.staticTexts["Invalid number"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Save"].isEnabled, "Save is blocked while a number is invalid")

        clearAndType(target, "10")
        XCTAssertFalse(app.staticTexts["Invalid number"].exists)
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Save"].tap()

        // New investments start in "Unclassified"; expand it to see the row
        let sector = app.staticTexts["Unclassified"].firstMatch
        XCTAssertTrue(sector.waitForExistence(timeout: 5))
        sector.tap()
        XCTAssertTrue(app.staticTexts["UI Test Fund"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDeleteInvestmentFromLongPressMenu() throws {
        launch()
        app.buttons["Add Investment"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("To Delete")
        app.buttons["Save"].tap()

        app.staticTexts["Unclassified"].firstMatch.tap()
        let row = app.staticTexts["To Delete"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.2)

        app.buttons["Delete"].firstMatch.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    // MARK: - Import preview

    @MainActor
    func testImportRequiresBrokerAndCorrectsSymbolThenApplies() throws {
        launch(importingSample: true)

        let apply = app.buttons["import.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10), "The sample import opens the preview")
        XCTAssertFalse(apply.isEnabled, "No broker on the statement yet")

        // Sui's SUI-GBP fails on (stub) Yahoo and Claude corrects it automatically
        XCTAssertTrue(element(containing: "Symbol corrected").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "SUI20947-USD").exists)
        XCTAssertFalse(apply.isEnabled, "Still waiting for a broker")

        let broker = app.textFields["import.broker"]
        broker.tap()
        broker.typeText("Revolut")
        XCTAssertTrue(apply.isEnabled)
        apply.tap()

        // Back on the portfolio: the stubbed classification puts both holdings in "Tech"
        let tech = app.staticTexts["Tech"].firstMatch
        XCTAssertTrue(tech.waitForExistence(timeout: 10))
        tech.tap()
        XCTAssertTrue(app.staticTexts["Apple"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sui"].exists)
    }

    @MainActor
    func testAccountTypeCanBeForcedForTheWholeStatement() throws {
        launch(importingSample: true)
        let picker = app.buttons["import.accountType"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        app.buttons["ISA"].firstMatch.tap()
        XCTAssertTrue(element(containing: "recorded under ISA").waitForExistence(timeout: 5))
    }

    @MainActor
    func testCancellingTheImportChangesNothing() throws {
        launch(importingSample: true)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()

        XCTAssertTrue(app.buttons["Add Investment"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Tech"].exists)
        XCTAssertFalse(app.staticTexts["Apple"].exists)
    }

    // MARK: - Settings

    @MainActor
    func testSaveAndRemoveAPIKey() throws {
        launch()
        app.buttons["menu.more"].tap()
        app.buttons["Settings"].tap()

        // Start clean if a key was left from an earlier run
        let remove = app.buttons["Remove Key"]
        if remove.waitForExistence(timeout: 2) {
            remove.tap()
        }
        XCTAssertTrue(element(containing: "No API key saved").waitForExistence(timeout: 5))

        let field = app.secureTextFields.firstMatch
        field.tap()
        field.typeText("sk-ui-test-9876")
        app.buttons["Save Key"].tap()
        XCTAssertTrue(element(containing: "9876").waitForExistence(timeout: 5), "Masked key shows the last 4 characters")
        XCTAssertFalse(element(containing: "sk-ui-test").exists, "The full key is never shown")

        app.buttons["Remove Key"].tap()
        XCTAssertTrue(element(containing: "No API key saved").waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }
}
