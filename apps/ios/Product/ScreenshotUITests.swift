import XCTest

final class ScreenshotUITests: XCTestCase {
    @MainActor
    private func open(_ state: String) throws -> XCUIApplication {
        let hash = try XCTUnwrap(ProcessInfo.processInfo.environment["TRAILMESH_CAPTURE_MAP_HASH"])
        let app = XCUIApplication()
        app.launchEnvironment["TRAILMESH_CAPTURE_SCREEN"] = state
        app.launchEnvironment["TRAILMESH_CAPTURE_MAP_HASH"] = hash
        app.launch()
        return app
    }

    @MainActor
    private func button(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", label)).firstMatch
    }

    @MainActor
    private func capture(_ name: String, after element: XCUIElement) throws {
        guard element.waitForExistence(timeout: 25) else {
            XCTFail("Expected UI for \(name) was not visible")
            return
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func tap(_ element: XCUIElement) throws {
        guard element.waitForExistence(timeout: 25), element.isHittable else {
            throw NSError(domain: "ScreenshotUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing hittable control: \(element)"])
        }
        element.tap()
    }

    @MainActor
    func testMapControls() throws {
        let app = try open("explore")
        try tap(button("Map controls", in: app))
        try capture("map-controls-menu", after: button("Offline maps", in: app))
    }

    @MainActor
    func testDeveloperTools() throws {
        let app = try open("explore")
        try tap(button("Developer tools", in: app))
        try capture("developer-tools-menu", after: button("Research diagnostics", in: app))
    }

    @MainActor
    func testReportCategory() throws {
        let app = try open("report-compose")
        try tap(button("Category", in: app))
        try capture("report-category-picker", after: app.staticTexts["Water"].firstMatch)
    }

    @MainActor
    func testReportStatus() throws {
        let app = try open("report-compose")
        try tap(button("Status", in: app))
        try capture("report-status-picker", after: app.staticTexts["Muddy"].firstMatch)
    }

    @MainActor
    func testMaximumTrailGrade() throws {
        let app = try open("route-planner")
        try tap(button("Maximum trail grade", in: app))
        try capture("route-grade-picker", after: app.staticTexts["Grade 3"].firstMatch)
    }

    @MainActor
    func testSearchKeyboard() throws {
        let app = try open("search-empty")
        try tap(app.searchFields.firstMatch)
        app.searchFields.firstMatch.typeText("Malyovitsa")
        try capture("search-keyboard", after: app.keyboards.firstMatch)
    }
}
