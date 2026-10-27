import XCTest

final class AmpWorkbenchPhoneUITests: XCTestCase {
    func testWideSoundsSearchAcceptsKeyboardInput() {
        let app = XCUIApplication()
        app.launchArguments += ["-soundAIMode", "Local rules"]
        app.launch()

        let search = app.textFields["soundSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Search should remain visible in the Duo sidebar")
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Tapping search should open the keyboard")
        search.typeText("American Idiot")
        XCTAssertEqual(search.value as? String, "American Idiot")
        let create = app.buttons["createSoundButton"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        XCTAssertTrue(app.textFields["soundRefinementField"].waitForExistence(timeout: 20),
                      "The created sound should open with an AI refinement field")
        let save = app.buttons["Save sound"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        let archive = app.buttons["Archive sound"]
        XCTAssertTrue(archive.waitForExistence(timeout: 10), "Saved sounds should be archivable")
        archive.tap()
        let confirm = app.buttons.matching(identifier: "Archive sound").element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }
}
