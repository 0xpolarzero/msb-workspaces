import XCTest

@MainActor
final class MSWMonitorUITests: XCTestCase {
    func testStatusItemPopoverRefreshAndQuit() {
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/MSWMonitor.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))

        let app = XCUIApplication(url: appURL)
        defer {
            if app.state != .notRunning {
                app.terminate()
            }
        }
        app.launchArguments = ["--ui-test-open-popover"]
        app.launch()

        let statusItem = app.statusItems["statusItem.button"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        XCTAssertEqual(statusItem.label, "MSW Monitor")
        let applicationMenu = app.menuBars.menuBarItems["MSW Monitor"]
        XCTAssertTrue(applicationMenu.waitForExistence(timeout: 3))
        applicationMenu.click()
        XCTAssertTrue(app.menuItems["About MSW Monitor"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Settings…"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Hide MSW Monitor"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Quit MSW Monitor"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])


        assertText("MSW Monitor", identifier: "monitor.title", in: app)
        assertText("dev", identifier: "workspace.dev.name", in: app)
        assertText("Stopped", identifier: "workspace.dev.state", in: app)
        assertText("playgrounds", identifier: "workspace.playgrounds.name", in: app)
        assertText("Stopped", identifier: "workspace.playgrounds.state", in: app)
        assertText("personal", identifier: "workspace.personal.name", in: app)
        assertText("Stopped", identifier: "workspace.personal.state", in: app)
        assertText("Not yet refreshed", identifier: "observation.value", in: app)

        let refresh = app.buttons["refresh.button"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 2))
        XCTAssertEqual(refresh.label, "Refresh")
        refresh.click()
        assertText("Observation #1", identifier: "observation.value", in: app)

        let quit = app.buttons["quit.button"]
        XCTAssertTrue(quit.waitForExistence(timeout: 2))
        XCTAssertEqual(quit.label, "Quit")
        quit.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 3))
    }

    private func assertText(_ text: String, identifier: String, in app: XCUIApplication) {
        let element = app.staticTexts[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 2), "Missing \(identifier)")
        XCTAssertEqual(element.value as? String, text)
    }
}
