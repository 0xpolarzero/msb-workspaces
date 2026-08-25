import AppKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class MSWMonitorUITests: XCTestCase {
    func testStatusItemMinimalPopoverAndQuit() {
        let app = launchFixture(["--ui-test-open-popover"])
        defer { terminateIfNeeded(app) }

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
        assertText("Not observed", identifier: "monitor.health", in: app)
        assertText("dev", identifier: "workspace.dev.name", in: app)
        assertText("Stopped", identifier: "workspace.dev.state", in: app)
        assertText("playgrounds", identifier: "workspace.playgrounds.name", in: app)
        assertText("Stopped", identifier: "workspace.playgrounds.state", in: app)
        assertText("personal", identifier: "workspace.personal.name", in: app)
        assertText("Stopped", identifier: "workspace.personal.state", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["observation.value"].exists)
        XCTAssertFalse(app.buttons["refresh.button"].exists)
        let openMonitor = app.buttons["open-monitor.button"]
        XCTAssertTrue(openMonitor.waitForExistence(timeout: 2))
        XCTAssertEqual(openMonitor.label, "Open MSW Monitor…")
        XCTAssertFalse(app.buttons["details.button"].exists)
        XCTAssertFalse(app.buttons["settings.button"].exists)
        XCTAssertFalse(app.buttons["setup.button"].exists)

        let quit = app.buttons["quit.button"]
        XCTAssertTrue(quit.waitForExistence(timeout: 2))
        XCTAssertEqual(quit.label, "Quit")
        quit.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 3))
    }

    func testDirectFolderPickerFromStatusPopover() {
        let app = launchFixture([
            "--ui-test-open-popover",
            "--ui-test-folder-browser",
            "--ui-test-folder-loading-skeleton"
        ])
        defer { terminateIfNeeded(app) }

        assertDirectFolderPicker(in: app)
        app.buttons["folders.popover.close"].click()
        XCTAssertTrue(app.descendants(matching: .any)["monitor.title"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["details.sidebar"].exists)
        app.buttons["quit.button"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 3))
    }

    func testApplicationPreferencesUpdateWorkspaceActions() {
        let app = launchFixture([
            "--ui-test-open-popover",
            "--ui-test-folder-browser",
            "--ui-test-app-preferences"
        ])
        defer { terminateIfNeeded(app) }

        XCTAssertEqual(app.buttons["workspace.dev.open-terminal"].label, "Open in Fixture Terminal")
        app.typeKey(",", modifierFlags: .command)
        let terminalPicker = app.popUpButtons["settings.applications.terminal.picker"]
        let editorPicker = app.popUpButtons["settings.applications.editor.picker"]
        XCTAssertTrue(terminalPicker.waitForExistence(timeout: 3))
        XCTAssertTrue(editorPicker.waitForExistence(timeout: 2))
        XCTAssertEqual(terminalPicker.value as? String, "System Default — Fixture Terminal")
        XCTAssertEqual(editorPicker.value as? String, "System Default — Xcode")
        terminalPicker.click()
        terminalPicker.menuItems["Ghostty"].click()
        editorPicker.click()
        editorPicker.menuItems["Zed"].click()
        XCTAssertEqual(terminalPicker.value as? String, "Ghostty")
        XCTAssertEqual(editorPicker.value as? String, "Zed")

        app.typeKey("w", modifierFlags: .command)
        let preferenceStatusItem = app.statusItems["statusItem.button"]
        XCTAssertTrue(preferenceStatusItem.waitForExistence(timeout: 2))
        preferenceStatusItem.click()
        XCTAssertEqual(app.buttons["workspace.dev.open-terminal"].label, "Open in Ghostty")
        let actions = app.menuButtons["workspace.dev.actions"]
        actions.click()
        XCTAssertTrue(app.menuItems["Open in Zed…"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["quit.button"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 3))
    }

    private func launchFixture(_ arguments: [String]) -> XCUIApplication {
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/MSWMonitor.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        let app = XCUIApplication(url: appURL)
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func terminateIfNeeded(_ app: XCUIApplication) {
        if app.state != .notRunning {
            app.terminate()
        }
    }
    func testOperationFailureOpensDetailedLogs() {
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
        app.launchArguments = ["--ui-test-open-popover", "--ui-test-operation-failure"]
        app.launch()

        assertText("Start failed", identifier: "monitor.health", in: app)
        let details = app.buttons["error.details.button"]
        XCTAssertTrue(details.waitForExistence(timeout: 2))
        details.click()

        XCTAssertTrue(app.descendants(matching: .any)["settings.tabs"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["details.sidebar"].exists)
        assertText("Logs", identifier: "details.section-title", in: app)
        let failurePanel = app.descendants(matching: .any)["details.latest-operation-error"]
        XCTAssertTrue(failurePanel.waitForExistence(timeout: 2))
        let systemHealth = app.buttons["View system health"]
        XCTAssertTrue(systemHealth.waitForExistence(timeout: 2))
        systemHealth.click()
        XCTAssertTrue(app.windows["Overview"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["overview.system-health"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.dev.summary-error"]
                .waitForExistence(timeout: 2)
        )
    }
    func testUnifiedWindowUsesTopTabsAndWorkspaceSections() {
        let app = launchFixture(["--ui-test-open-popover", "--ui-test-folder-browser"])
        defer { terminateIfNeeded(app) }

        let openMonitor = app.buttons["open-monitor.button"]
        XCTAssertTrue(openMonitor.waitForExistence(timeout: 2))
        openMonitor.click()

        XCTAssertTrue(app.descendants(matching: .any)["settings.tabs"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.windows["Overview"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["overview.system-health"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["Run checks"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.descendants(matching: .any)["workspace.section-picker"].exists)
        XCTAssertFalse(app.popUpButtons["details.workspace-picker"].exists)

        let expectedStates = ["dev": "Running", "playgrounds": "Stopped", "personal": "Stopped"]
        for workspace in ["dev", "playgrounds", "personal"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["workspace.\(workspace).summary-row"]
                    .waitForExistence(timeout: 2)
            )
            assertText(
                expectedStates[workspace]!,
                identifier: "workspace.\(workspace).summary-state",
                in: app
            )
        }
        XCTAssertFalse(app.staticTexts["Primary software development workspace"].exists)

        let workspacesTab = app.toolbars.buttons["Workspaces"]
        XCTAssertTrue(workspacesTab.waitForExistence(timeout: 2))
        workspacesTab.click()
        XCTAssertTrue(app.windows["Workspaces"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["workspace.section-picker"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.descendants(matching: .any)["workspace.section.Summary"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["workspace.section.Repositories"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["workspace.section.Maintenance"].exists)
        assertText("Files", identifier: "details.section-title", in: app)
        XCTAssertTrue(app.popUpButtons["details.workspace-picker"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Repositories"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["folders.path-bar"].waitForExistence(timeout: 2))

        let logs = app.buttons["Logs"]
        XCTAssertTrue(logs.waitForExistence(timeout: 2))
        logs.click()
        assertText("Logs", identifier: "details.section-title", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["details.logs"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.popUpButtons["details.workspace-picker"].exists)
        for workspace in ["dev", "playgrounds", "personal"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["logs.filter.\(workspace)"]
                    .waitForExistence(timeout: 2)
            )
            XCTAssertTrue(
                app.descendants(matching: .any)["logs.workspace.\(workspace)"]
                    .waitForExistence(timeout: 2)
            )
        }
        XCTAssertFalse(app.descendants(matching: .any)["details.error"].exists)
        XCTAssertFalse(app.buttons["Retry"].exists)
        let devLogFilter = app.descendants(matching: .any)["logs.filter.dev"]
        devLogFilter.click()
        XCTAssertFalse(app.descendants(matching: .any)["logs.workspace.dev"].exists)
        app.descendants(matching: .any)["logs.filter.dev"].click()
        XCTAssertTrue(app.descendants(matching: .any)["logs.workspace.dev"].waitForExistence(timeout: 2))

        let network = app.buttons["Network"]
        XCTAssertTrue(network.waitForExistence(timeout: 2))
        network.click()
        assertText("Network", identifier: "details.section-title", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["details.ports"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.popUpButtons["details.workspace-picker"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["network.workspace.dev"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.descendants(matching: .any)["network.workspace.playgrounds"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["network.workspace.personal"].exists)
        XCTAssertTrue(app.staticTexts["Active"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["network.dev.port.3000.open"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["network.dev.port.3000.copy"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["network.dev.port.5173.open"].exists
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["network.dev.port.5173.copy"].exists
        )

        let activity = app.buttons["Activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 2))
        activity.click()
        assertText("Activity", identifier: "details.section-title", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["details.activity"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.popUpButtons["details.workspace-picker"].exists)
        for workspace in ["dev", "playgrounds", "personal"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["activity.filter.\(workspace)"]
                    .waitForExistence(timeout: 2)
            )
        }
        let githubTab = app.toolbars.buttons["GitHub"]
        XCTAssertTrue(githubTab.waitForExistence(timeout: 2))
        githubTab.click()
        XCTAssertTrue(app.windows["GitHub"].waitForExistence(timeout: 2))

        let generalTab = app.toolbars.buttons["General"]
        XCTAssertTrue(generalTab.waitForExistence(timeout: 2))
        generalTab.click()

        XCTAssertTrue(app.windows["General"].waitForExistence(timeout: 2))

        app.typeKey("w", modifierFlags: .command)
        let statusItem = app.statusItems["statusItem.button"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 2))
        statusItem.click()
        app.buttons["quit.button"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 3))
    }
    func testNetworkShowsActivePortsFirst() {
        let app = launchFixture(["--ui-test-open-popover", "--ui-test-folder-browser"])
        defer { terminateIfNeeded(app) }

        XCTAssertTrue(app.buttons["open-monitor.button"].waitForExistence(timeout: 2))
        app.buttons["open-monitor.button"].click()
        XCTAssertTrue(app.windows["Overview"].waitForExistence(timeout: 2))

        XCTAssertTrue(app.toolbars.buttons["Workspaces"].waitForExistence(timeout: 2))
        app.toolbars.buttons["Workspaces"].click()
        XCTAssertTrue(app.windows["Workspaces"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Network"].waitForExistence(timeout: 2))
        app.buttons["Network"].click()

        assertText("Network", identifier: "details.section-title", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["network.workspace.dev"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.descendants(matching: .any)["network.workspace.playgrounds"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["network.workspace.personal"].exists)
        XCTAssertTrue(app.staticTexts["Active"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["network.dev.port.3000.open"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["network.dev.port.3000.copy"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.descendants(matching: .any)["network.dev.port.5173.open"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["network.dev.port.5173.copy"].exists)
    }

    func testFilesStayCachedAcrossWorkspaceTabs() {
        let app = launchFixture(["--ui-test-open-popover", "--ui-test-folder-browser"])
        defer { terminateIfNeeded(app) }

        XCTAssertTrue(app.buttons["open-monitor.button"].waitForExistence(timeout: 2))
        app.buttons["open-monitor.button"].click()
        XCTAssertTrue(app.windows["Overview"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.toolbars.buttons["Workspaces"].waitForExistence(timeout: 2))
        app.toolbars.buttons["Workspaces"].click()

        let folderTree = app.descendants(matching: .any)["folders.tree"]
        XCTAssertTrue(folderTree.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["folders.entry.Projects"].waitForExistence(timeout: 2))
        let repository = app.descendants(matching: .any)["repository.ui-playground-repo"]
        XCTAssertTrue(repository.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["main • 0 ahead, 0 behind"].waitForExistence(timeout: 2))
        for confusingCopy in ["blocked", "localChanges", "checked", "Uncommitted changes"] {
            XCTAssertEqual(
                app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS[c] %@", confusingCopy)
                ).count,
                0
            )
        }

        XCTAssertTrue(app.buttons["Logs"].waitForExistence(timeout: 2))
        app.buttons["Logs"].click()
        assertText("Logs", identifier: "details.section-title", in: app)
        XCTAssertFalse(folderTree.exists)

        XCTAssertTrue(app.buttons["Files"].waitForExistence(timeout: 2))
        app.buttons["Files"].click()
        assertText("Files", identifier: "details.section-title", in: app)
        XCTAssertTrue(folderTree.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["folders.entry.Projects"].exists)
        XCTAssertTrue(repository.exists)
        XCTAssertFalse(app.descendants(matching: .any)["folders.loading-skeleton"].exists)
        XCTAssertFalse(app.progressIndicators["Loading folders…"].exists)
    }

    private func assertDirectFolderPicker(in app: XCUIApplication) {
        let terminalName = defaultApplicationName(for: .unixExecutable)
        XCTAssertTrue(app.buttons["workspace.dev.open-terminal"].waitForExistence(timeout: 2))
        XCTAssertEqual(
            app.buttons["workspace.dev.open-terminal"].label,
            terminalName.map { "Open in \($0)" } ?? "Open in Default Terminal"
        )
        XCTAssertFalse(app.textFields["folders.search.field"].exists)

        let editorShortcut = app.buttons["workspace.dev.open-editor-shortcut"]
        XCTAssertTrue(editorShortcut.waitForExistence(timeout: 2))
        XCTAssertEqual(editorShortcut.label, "Open in Unsupported Editor…")
        editorShortcut.click()

        let loadingSkeleton = app.descendants(matching: .any)["folders.loading-skeleton"]
        XCTAssertTrue(loadingSkeleton.waitForExistence(timeout: 2))
        XCTAssertFalse(app.progressIndicators["Loading folders…"].exists)

        assertText("dev folders", identifier: "folders.popover.title", in: app)
        let pathBar = app.descendants(matching: .any)["folders.path-bar"]
        XCTAssertTrue(pathBar.waitForExistence(timeout: 2))
        let rootBreadcrumb = app.buttons["folders.breadcrumb.root"]
        XCTAssertTrue(rootBreadcrumb.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["folders.truncated"].waitForExistence(timeout: 2))
        let pickerContent = app.descendants(matching: .any)["folders.popover.content"]
        let pickerTitle = app.staticTexts["folders.popover.title"]
        let folderTree = app.descendants(matching: .any)["folders.tree"]
        XCTAssertTrue(pickerContent.waitForExistence(timeout: 2))
        XCTAssertTrue(folderTree.waitForExistence(timeout: 2))
        XCTAssertFalse(loadingSkeleton.exists)
        let closePicker = app.buttons["folders.popover.close"]
        let headerOpen = app.buttons["folders.open.button"]
        XCTAssertTrue(closePicker.waitForExistence(timeout: 2))
        XCTAssertTrue(headerOpen.waitForExistence(timeout: 2))
        XCTAssertLessThan(closePicker.frame.maxX, headerOpen.frame.minX)
        XCTAssertEqual(closePicker.frame.midY, headerOpen.frame.midY, accuracy: 1)
        XCTAssertLessThan(pickerTitle.frame.minY - pickerContent.frame.minY, 36)
        XCTAssertGreaterThan(folderTree.frame.height, 150)
        XCTAssertLessThan(pickerContent.frame.maxY - pathBar.frame.maxY, 36)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Direct status-popover folder picker — compact top-aligned layout"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(app.descendants(matching: .any)["monitor.title"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["details.sidebar"].exists)

        let projectsExpand = app.descendants(matching: .any)["folders.entry.Projects.expand"]
        XCTAssertTrue(projectsExpand.waitForExistence(timeout: 2))
        projectsExpand.click()
        XCTAssertTrue(app.buttons["folders.entry.Projects/Demo"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.descendants(matching: .any)["folders.entry.Scratch.expand"].exists)

        let projects = app.buttons["folders.entry.Projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 2))
        projects.doubleClick()
        XCTAssertTrue(app.buttons["folders.breadcrumb.Projects"].waitForExistence(timeout: 2))
        rootBreadcrumb.click()
        XCTAssertFalse(app.buttons["folders.breadcrumb.Projects"].exists)
        XCTAssertFalse(app.buttons["folders.up.button"].exists)

        let scratch = app.buttons["folders.entry.Scratch"]
        XCTAssertTrue(scratch.waitForExistence(timeout: 2))
        scratch.doubleClick()
        XCTAssertTrue(app.buttons["folders.breadcrumb.Scratch"].waitForExistence(timeout: 2))
        let emptyState = app.descendants(matching: .any)["folders.empty"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 2))
        let emptySearchField = app.textFields["folders.search.field"]
        XCTAssertLessThan(emptyState.frame.minY - emptySearchField.frame.maxY, 30)
        XCTAssertLessThan(emptyState.frame.height, 30)
        XCTAssertLessThan(pickerContent.frame.maxY - pathBar.frame.maxY, 36)
        let emptyScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        emptyScreenshot.name = "Direct status-popover empty folder — compact top-aligned layout"
        emptyScreenshot.lifetime = .keepAlways
        add(emptyScreenshot)

        rootBreadcrumb.click()
        XCTAssertFalse(app.buttons["folders.breadcrumb.Scratch"].exists)
        app.buttons["folders.entry.Projects"].doubleClick()
        XCTAssertTrue(app.buttons["folders.breadcrumb.Projects"].waitForExistence(timeout: 2))

        let search = app.textFields["folders.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.click()
        search.typeText("Demo")
        let demo = app.buttons["folders.entry.Projects/Demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        demo.click()
        let openFolder = app.buttons["folders.open.button"]
        XCTAssertEqual(openFolder.label, "Open in Unsupported Editor")
        XCTAssertEqual(openFolder.value as? String, "/workspace/Projects/Demo")
        openFolder.click()
        let folderError = app.staticTexts["folders.error"]
        XCTAssertTrue(folderError.waitForExistence(timeout: 2))
        XCTAssertTrue((folderError.value as? String)?.contains("Unsupported Editor") == true)
        XCTAssertTrue((folderError.value as? String)?.contains("no fallback was opened") == true)
    }

    private func defaultApplicationName(for type: UTType) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: type).flatMap(applicationName(at:))
    }

    private func applicationName(at url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        return (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
    func testSetupCanReviewAndFinishInFixtureMode() {
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
        app.launchArguments = [
            "--ui-test-setup",
            "--ui-test-github-disconnected",
            "--ui-test-app-preferences"
        ]
        app.launch()

        let setup = app.windows["setup.window"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))

        let stepper = app.descendants(matching: .any)["setup.stepper"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 2))
        for identifier in [
            "setup.step.dependencies",
            "setup.step.workspaces",
            "setup.step.github",
            "setup.step.identity",
            "setup.step.review"
        ] {
            assertIdentifier(identifier, in: app)
        }
        XCTAssertTrue(app.buttons["setup.step.dependencies"].label.contains("Dependencies"))
        let gitStep = app.buttons["setup.step.identity"]
        XCTAssertTrue(gitStep.label.contains("Git"))


        let preflight = app.descendants(matching: .any)["setup.preflight"]
        XCTAssertTrue(preflight.waitForExistence(timeout: 2))
        let setupTerminalPicker = app.popUpButtons["setup.applications.terminal.picker"]
        let setupEditorPicker = app.popUpButtons["setup.applications.editor.picker"]
        XCTAssertTrue(setupTerminalPicker.waitForExistence(timeout: 2))
        XCTAssertTrue(setupEditorPicker.waitForExistence(timeout: 2))
        XCTAssertEqual(setupTerminalPicker.value as? String, "System Default — Fixture Terminal")
        XCTAssertEqual(setupEditorPicker.value as? String, "System Default — Xcode")
        setupTerminalPicker.click()
        setupTerminalPicker.menuItems["Ghostty"].click()
        setupEditorPicker.click()
        setupEditorPicker.menuItems["Zed"].click()
        XCTAssertEqual(setupTerminalPicker.value as? String, "Ghostty")
        XCTAssertEqual(setupEditorPicker.value as? String, "Zed")
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github-boundary"]
                .waitForNonExistence(timeout: 2)
        )

        let primaryAction = app.buttons["setup.primary-action"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 2))
        XCTAssertEqual(primaryAction.label, "Continue")
        XCTAssertTrue(waitUntilEnabled(primaryAction, timeout: 5))
        let retry = app.buttons["setup.retry.button"]
        XCTAssertTrue(retry.waitForExistence(timeout: 2))
        XCTAssertEqual(retry.frame.midY, primaryAction.frame.midY, accuracy: 0.5)
        assertActionsReachTrailingEdge(of: setup, in: app)
        primaryAction.click()

        XCTAssertTrue(app.descendants(matching: .any)["setup.workspaces"].waitForExistence(timeout: 2))
        assertText("Configure workspaces", identifier: "setup.workspaces.title", in: app)
        XCTAssertEqual(app.textFields["setup.workspaces.row.0.name"].value as? String, "dev")
        XCTAssertEqual(app.textFields["setup.workspaces.row.1.name"].value as? String, "playgrounds")
        XCTAssertEqual(app.textFields["setup.workspaces.row.2.name"].value as? String, "personal")
        XCTAssertEqual(
            app.descendants(matching: .any)["setup.workspaces.row.0.memory"].value as? String,
            "32 GB"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["setup.workspaces.row.2.max-memory"].value as? String,
            "32 GB"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["setup.workspaces.row.0.cpus"].value as? String,
            "8 CPU"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["setup.workspaces.row.0.max-cpus"].value as? String,
            "12 CPU"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["setup.workspaces.row.0.workspace-storage"].value as? String,
            "120 GB"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["setup.workspaces.row.0.runtime-storage"].value as? String,
            "100 GB"
        )

        let devName = app.textFields["setup.workspaces.row.0.name"]
        devName.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("development")
        XCTAssertEqual(devName.value as? String, "development")

        let playgroundsName = app.textFields["setup.workspaces.row.1.name"]
        playgroundsName.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("development")
        let workspaceValidation = app.staticTexts["setup.workspaces.validation"]
        XCTAssertTrue(workspaceValidation.waitForExistence(timeout: 2))
        XCTAssertEqual(workspaceValidation.value as? String, "Workspace names must be unique.")
        XCTAssertFalse(app.buttons["setup.workspaces.continue.button"].isEnabled)
        playgroundsName.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("playgrounds")
        XCTAssertTrue(workspaceValidation.waitForNonExistence(timeout: 2))

        let devMemory = app.descendants(matching: .any)["setup.workspaces.row.0.memory"]
        devMemory.click()
        XCTAssertTrue(app.menuItems["16 GB"].waitForExistence(timeout: 2))
        app.menuItems["16 GB"].click()
        XCTAssertEqual(devMemory.value as? String, "16 GB")

        let addWorkspace = app.buttons["setup.workspaces.add.button"]
        XCTAssertTrue(addWorkspace.waitForExistence(timeout: 2))
        addWorkspace.click()
        let addedName = app.textFields["setup.workspaces.row.0.name"]
        XCTAssertTrue(addedName.waitForExistence(timeout: 2))
        addedName.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("lab")
        XCTAssertEqual(addedName.value as? String, "lab")
        let removeAdded = app.buttons["setup.workspaces.row.0.remove.button"]
        XCTAssertTrue(removeAdded.waitForExistence(timeout: 2))
        removeAdded.click()
        let restoredFirstName = app.textFields["setup.workspaces.row.0.name"]
        XCTAssertTrue(restoredFirstName.waitForExistence(timeout: 2))
        XCTAssertEqual(restoredFirstName.value as? String, "development")
        XCTAssertFalse(app.textFields["setup.workspaces.row.3.name"].exists)

        let workspaceContinue = app.buttons["setup.workspaces.continue.button"]
        XCTAssertTrue(workspaceContinue.waitForExistence(timeout: 2))
        XCTAssertTrue(workspaceContinue.isEnabled)
        workspaceContinue.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github-boundary"]
                .waitForExistence(timeout: 2)
        )
        // Local mode (default) presents the policy picker, never the Connect
        // unavailable outcome.
        XCTAssertFalse(app.descendants(matching: .any)["setup.github.unavailable"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["setup.github.disconnected"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["setup.github.attention"].exists)
        XCTAssertFalse(app.buttons["setup.github.reconnect.button"].exists)
        XCTAssertFalse(app.buttons["setup.github.retry.button"].exists)
        XCTAssertFalse(app.buttons["setup.github.refresh.button"].exists)
        let workspaceBack = app.buttons["setup.back.button"]
        XCTAssertTrue(workspaceBack.waitForExistence(timeout: 2))
        workspaceBack.click()
        XCTAssertTrue(app.descendants(matching: .any)["setup.workspaces"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["setup.workspaces.row.0.name"].value as? String, "development")
        XCTAssertEqual(
            app.descendants(matching: .any)["setup.workspaces.row.0.memory"].value as? String,
            "16 GB"
        )
        app.buttons["setup.workspaces.continue.button"].click()
        let connect = app.buttons["setup.github.connect-account.button"]
        XCTAssertTrue(connect.waitForExistence(timeout: 3))
        XCTAssertEqual(connect.label, "Connect GitHub")
        let githubSkip = app.buttons["setup.github.skip.button"]
        let githubBack = app.buttons["setup.back.button"]
        XCTAssertTrue(githubSkip.waitForExistence(timeout: 2))
        XCTAssertTrue(githubBack.waitForExistence(timeout: 2))
        XCTAssertEqual(githubSkip.label, "Skip")
        XCTAssertEqual(app.buttons.matching(identifier: "setup.github.skip.button").count, 1)
        assertAction(githubSkip, precedes: githubBack, in: app)
        githubSkip.click()

        let identityName = app.textFields["setup.identity.name"]
        let identityEmail = app.textFields["setup.identity.email"]
        XCTAssertTrue(identityName.waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.identity"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github-boundary"]
                .waitForNonExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Targets: development, playgrounds, personal."].exists)
        let gitSkip = app.buttons["setup.identity.skip.button"]
        let gitBack = app.buttons["setup.back.button"]
        let gitContinue = app.buttons["setup.identity.continue.button"]
        XCTAssertTrue(gitSkip.waitForExistence(timeout: 2))
        XCTAssertTrue(gitBack.waitForExistence(timeout: 2))
        XCTAssertTrue(gitContinue.waitForExistence(timeout: 2))
        XCTAssertEqual(gitSkip.label, "Skip")
        XCTAssertEqual(gitBack.label, "Back")
        XCTAssertEqual(gitContinue.label, "Continue")
        XCTAssertFalse(gitContinue.isEnabled, "Git identity remains required before continuing")
        assertAction(gitSkip, precedes: gitBack, in: app)
        assertAction(gitBack, precedes: gitContinue, in: app)
        assertActionsReachTrailingEdge(of: setup, in: app)
        gitBack.click()
        let githubContinue = app.buttons["setup.github.continue.button"]
        XCTAssertTrue(githubContinue.waitForExistence(timeout: 2))
        XCTAssertEqual(gitBack.frame.midY, githubContinue.frame.midY, accuracy: 0.5)
        assertActionsReachTrailingEdge(of: setup, in: app)
        githubContinue.click()
        XCTAssertTrue(identityName.waitForExistence(timeout: 2))
        gitSkip.click()
        let finalReview = app.staticTexts["setup.final-review.title"]
        XCTAssertTrue(finalReview.waitForExistence(timeout: 2))
        gitBack.click()
        XCTAssertTrue(identityName.waitForExistence(timeout: 2))
        identityName.click()
        identityName.typeText("Taylor Example")
        identityEmail.click()
        identityEmail.typeText("taylor@example.com")
        XCTAssertTrue(gitContinue.isEnabled)
        let continueWidth = gitContinue.frame.width
        gitContinue.click()
        XCTAssertEqual(gitContinue.value as? String, "Saving")
        XCTAssertEqual(gitContinue.frame.width, continueWidth, accuracy: 0.5)
        XCTAssertFalse(app.buttons["setup.review.button"].exists)

        XCTAssertTrue(finalReview.waitForExistence(timeout: 2))
        assertText("Review setup", identifier: "setup.final-review.title", in: app)
        let workspaceReview = app.descendants(matching: .any)["setup.final-review.workspaces"]
        XCTAssertTrue(workspaceReview.waitForExistence(timeout: 2))
        XCTAssertEqual(workspaceReview.label, "Configured workspaces")
        XCTAssertEqual(
            workspaceReview.value as? String,
            "development: 8/12 CPU, 16/48 GB memory, 120 GB workspace storage, " +
            "100 GB runtime storage; playgrounds: 4/12 CPU, 32/48 GB memory, " +
            "60 GB workspace storage, 60 GB runtime storage; personal: 6/12 CPU, " +
            "16/32 GB memory, 100 GB workspace storage, 80 GB runtime storage"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["setup.final-review.terminal"].value as? String,
            "Ghostty"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["setup.final-review.editor"].value as? String,
            "Zed"
        )
        let done = app.buttons["setup.done.button"]
        XCTAssertTrue(done.waitForExistence(timeout: 2))
        XCTAssertEqual(done.label, "Done")
        XCTAssertTrue(done.isEnabled)
        done.click()
        XCTAssertTrue(setup.waitForNonExistence(timeout: 3))
        XCTAssertNotEqual(app.state, .notRunning)
    }

    func testGitHubLocalSuccessAppliesPolicyAndFinishesSetup() {
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
        app.launchArguments = ["--ui-test-setup", "--ui-test-github-success"]
        app.launch()

        let setup = app.windows["setup.window"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        let primaryAction = app.buttons["setup.primary-action"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 2))
        advanceFromDependenciesToGitHub(in: app)

        let githubTitle = app.staticTexts["setup.github.title"]
        let githubAccount = app.descendants(matching: .any)["setup.github.account"]
        let refreshCatalog = app.buttons["setup.github.refresh.button"]
        let githubSkip = app.buttons["setup.github.skip.button"]
        let githubBack = app.buttons["setup.back.button"]
        XCTAssertTrue(githubTitle.waitForExistence(timeout: 2))
        XCTAssertTrue(githubAccount.waitForExistence(timeout: 3))
        assertText("Connected as @octocat", identifier: "setup.github.account", in: app)
        XCTAssertFalse(app.buttons["setup.github.connect-account.button"].exists)
        XCTAssertTrue(refreshCatalog.waitForExistence(timeout: 2))
        XCTAssertEqual(refreshCatalog.label, "Refresh")
        XCTAssertLessThan(githubTitle.frame.maxX, githubAccount.frame.minX)
        XCTAssertLessThan(githubAccount.frame.maxX, refreshCatalog.frame.minX)
        XCTAssertEqual(githubTitle.frame.midY, githubAccount.frame.midY, accuracy: 1)
        XCTAssertEqual(githubAccount.frame.midY, refreshCatalog.frame.midY, accuracy: 1)
        XCTAssertTrue(githubSkip.waitForExistence(timeout: 2))
        XCTAssertTrue(githubBack.waitForExistence(timeout: 2))
        XCTAssertEqual(githubSkip.label, "Skip")
        XCTAssertEqual(app.buttons.matching(identifier: "setup.github.skip.button").count, 1)
        assertAction(githubSkip, precedes: githubBack, in: app)
        refreshCatalog.click()
        XCTAssertTrue(waitUntilEnabled(refreshCatalog, timeout: 2))

        let initialSetupFrame = setup.frame
        let workspaceAccessHelp = "Choose which repositories each workspace can use with your GitHub credentials, and whether it can push changes. Public repositories remain cloneable without granting access."
        let pushHelp = "Push to GitHub from inside this workspace's VM. You can always push from outside the VM using MSW Monitor."
        let accessInfo = app.descendants(matching: .any)["setup.github.workspace-access.info"]
        XCTAssertTrue(accessInfo.waitForExistence(timeout: 2))
        XCTAssertEqual(accessInfo.label, "Workspace Access information")
        XCTAssertFalse(app.buttons["setup.github.workspace-access.info.button"].exists)
        accessInfo.hover()
        assertText(
            workspaceAccessHelp,
            identifier: "setup.github.workspace-access.info.tooltip",
            in: app
        )
        XCTAssertFalse(app.buttons["setup.github.workspace-access.help.done"].exists)

        let picker = app.buttons["github.workspace.dev.repository-picker.button"]
        XCTAssertTrue(picker.waitForExistence(timeout: 2))
        let initialPickerWidth = picker.frame.width
        picker.click()
        let search = app.textFields["github.workspace.dev.repository-picker.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.click()
        search.typeText("one")
        XCTAssertFalse(app.descendants(matching: .any)["github.workspace.dev.repository.1002"].exists)
        let repository = app.checkBoxes["github.workspace.dev.repository.1001"]
        XCTAssertTrue(repository.waitForExistence(timeout: 2))
        repository.click()
        app.typeKey(.escape, modifierFlags: [])
        let push = app.descendants(matching: .any)["github.workspace.dev.repository.1001.allow-pushes"]
        XCTAssertTrue(push.waitForExistence(timeout: 2))
        XCTAssertEqual(
            picker.frame.width,
            initialPickerWidth,
            accuracy: 0.5,
            "Repository picker width must remain stable after selection"
        )
        XCTAssertEqual(push.label, "Allow pushes")
        push.hover()
        assertText(
            pushHelp,
            identifier: "github.workspace.dev.repository.1001.allow-pushes.tooltip",
            in: app
        )
        push.click()
        XCTAssertFalse(app.checkBoxes["Assign"].exists)
        XCTAssertFalse(app.staticTexts["Owner installation"].exists)
        XCTAssertFalse(app.staticTexts["Verification repository"].exists)
        XCTAssertFalse(app.staticTexts["Access mode"].exists)
        XCTAssertEqual(setup.frame, initialSetupFrame, "Repository selection must not resize setup")

        XCTAssertFalse(app.buttons["setup.github.review.button"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["setup.github.review"].exists)
        let apply = app.buttons["setup.github.apply.button"]
        XCTAssertTrue(apply.waitForExistence(timeout: 2))
        XCTAssertTrue(apply.isEnabled)
        XCTAssertEqual(apply.label, "Continue")
        apply.click()

        let identitySkip = app.buttons["setup.identity.skip.button"]
        XCTAssertTrue(identitySkip.waitForExistence(timeout: 2))
        identitySkip.click()
        let done = app.buttons["setup.done.button"]
        XCTAssertTrue(done.waitForExistence(timeout: 2))
        XCTAssertTrue(done.isEnabled)
        done.click()
        XCTAssertTrue(setup.waitForNonExistence(timeout: 3))
    }

    func testGitHubDisconnectedConnectsLoadsAndOpensSettings() {
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/MSWMonitor.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))

        let app = XCUIApplication(url: appURL)
        defer {
            if app.state != .notRunning { app.terminate() }
        }
        app.launchArguments = ["--ui-test-setup", "--ui-test-github-disconnected"]
        app.launch()

        let setup = app.windows["setup.window"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        advanceFromDependenciesToGitHub(in: app)

        let connect = app.buttons["setup.github.connect-account.button"]
        XCTAssertTrue(connect.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["setup.github.refresh.button"].exists)
        let connectWidth = connect.frame.width
        connect.click()
        XCTAssertEqual(connect.value as? String, "Connecting")
        XCTAssertEqual(connect.frame.width, connectWidth, accuracy: 0.5)
        assertText(
            "Waiting for GitHub sign-in in your browser…",
            identifier: "setup.github.status",
            in: app
        )

        XCTAssertTrue(app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 5))
        assertText("Connected as @octocat", identifier: "setup.github.account", in: app)
        XCTAssertFalse(app.buttons["setup.github.connect-account.button"].exists)
        XCTAssertTrue(app.buttons["setup.github.skip.button"].exists)
        XCTAssertTrue(app.buttons["setup.github.refresh.button"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["github.workspace.dev.repository-picker.button"].waitForExistence(timeout: 2))

        let manage = app.buttons["setup.github.manage-account.button"]
        XCTAssertTrue(manage.waitForExistence(timeout: 2))
        manage.click()
        XCTAssertTrue(setup.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["settings.tabs"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["settings.github.status"].waitForExistence(timeout: 3))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(setup.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilHittable(app.buttons["github.workspace.dev.repository-picker.button"], timeout: 2))
    }

    func testGitHubLocalEmptyCatalogShowsNoRepositories() {
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
        app.launchArguments = ["--ui-test-setup", "--ui-test-github-no-installation"]
        app.launch()

        let setup = app.windows["setup.window"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        advanceFromDependenciesToGitHub(in: app)

        // The account is connected but the catalog is empty; the no-repos
        // status is shown and the refresh control re-enables instead of hanging.
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 3)
        )
        assertText(
            "No repositories were found. Refresh, manage your connected account, or skip GitHub. Public repositories remain cloneable without granting access.",
            identifier: "setup.github.status",
            in: app
        )
        XCTAssertTrue(waitUntilEnabled(app.buttons["setup.github.refresh.button"], timeout: 2))
        let skip = app.buttons["setup.github.skip.button"]
        XCTAssertTrue(skip.waitForExistence(timeout: 2))
        XCTAssertTrue(skip.isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["setup.github.manual-add"].exists)
    }

    func testGitHubRefreshKeepsRepositoryActionsInteractiveAndProgressLocal() {
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/MSWMonitor.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))

        let app = XCUIApplication(url: appURL)
        defer {
            if app.state != .notRunning { app.terminate() }
        }
        app.launchArguments = ["--ui-test-setup", "--ui-test-github-interaction-states"]
        app.launch()

        let setup = app.windows["setup.window"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        advanceFromDependenciesToGitHub(in: app)

        let picker = app.buttons["github.workspace.dev.repository-picker.button"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.click()
        let repository = app.checkBoxes["github.workspace.dev.repository.1001"]
        XCTAssertTrue(repository.waitForExistence(timeout: 2))
        repository.click()
        app.typeKey(.escape, modifierFlags: [])

        let refresh = app.buttons["setup.github.refresh.button"]
        let apply = app.buttons["setup.github.apply.button"]
        let manage = app.buttons["setup.github.manage-account.button"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 2))
        XCTAssertTrue(apply.waitForExistence(timeout: 2))
        XCTAssertTrue(manage.waitForExistence(timeout: 2))
        let refreshWidth = refresh.frame.width
        let applyWidth = apply.frame.width
        let pickerFrame = picker.frame
        XCTAssertFalse(app.staticTexts["Repositories are up to date."].exists)

        refresh.click()
        XCTAssertEqual(refresh.label, "Refresh")
        XCTAssertEqual(refresh.value as? String, "Refreshing repositories")
        XCTAssertEqual(apply.label, "Continue")
        XCTAssertEqual(apply.value as? String, "Ready")
        XCTAssertTrue(apply.isEnabled, "Refresh must not disable the save action")
        XCTAssertTrue(picker.isEnabled, "Refresh must not disable repository selection")
        XCTAssertTrue(manage.isEnabled, "Refresh must not disable account management")

        XCTAssertTrue(waitUntilEnabled(refresh, timeout: 3))
        XCTAssertEqual(refresh.frame.width, refreshWidth, accuracy: 0.5)
        XCTAssertEqual(apply.frame.width, applyWidth, accuracy: 0.5)
        XCTAssertEqual(picker.frame.width, pickerFrame.width, accuracy: 0.5)
        XCTAssertEqual(picker.frame.minY, pickerFrame.minY, accuracy: 0.5)

        apply.click()
        // Saving no longer blocks the step: navigation is immediate while the
        // save continues in the background, reported from the footer.
        XCTAssertTrue(app.buttons["setup.identity.skip.button"].waitForExistence(timeout: 2))
    }

    func testSetupLocalGitHubStepUnlocksWhenSystemReadyThenVerifiesThroughDone() {
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
        app.launchArguments = ["--ui-test-setup", "--ui-test-setup-reconnect", "--ui-test-github-success"]
        app.launch()

        let setup = app.windows["setup.window"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))

        // Workspace configuration is the required step between dependencies
        // and GitHub, even while bootstrap is still creating workspaces.
        let githubStep = app.descendants(matching: .any)["setup.step.github"]
        XCTAssertTrue(githubStep.waitForExistence(timeout: 2))
        XCTAssertFalse(githubStep.isEnabled)

        let primaryAction = app.buttons["setup.primary-action"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 2))
        XCTAssertEqual(primaryAction.label, "Continue")
        advanceFromDependenciesToGitHub(in: app)

        // Local mode unlocks the GitHub step as soon as preflight passes.
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github-boundary"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.descendants(matching: .any)["setup.github.attention"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 2))
        assertText("Connected as @octocat", identifier: "setup.github.account", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["setup.github.attention"].exists)

        let picker = app.buttons["github.workspace.dev.repository-picker.button"]
        XCTAssertTrue(picker.waitForExistence(timeout: 2))
        picker.click()
        let repository = app.checkBoxes["github.workspace.dev.repository.1001"]
        XCTAssertTrue(repository.waitForExistence(timeout: 2))
        repository.click()
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertFalse(app.buttons["setup.github.review.button"].exists)
        let apply = app.buttons["setup.github.apply.button"]
        XCTAssertTrue(apply.waitForExistence(timeout: 2))
        XCTAssertTrue(apply.isEnabled)
        XCTAssertEqual(apply.label, "Continue")
        apply.click()

        let identitySkip = app.buttons["setup.identity.skip.button"]
        XCTAssertTrue(identitySkip.waitForExistence(timeout: 2))
        identitySkip.click()

        // Bootstrap is still incomplete: Done is blocked and the review step
        // offers the workspace completion action.
        let done = app.buttons["setup.done.button"]
        XCTAssertTrue(done.waitForExistence(timeout: 2))
        XCTAssertFalse(done.isEnabled)
        let verify = app.buttons["setup.review.verify.button"]
        XCTAssertTrue(verify.waitForExistence(timeout: 2))
        XCTAssertTrue(verify.isEnabled)
        verify.click()
        // The failing first bootstrap attempt already ran when the Workspaces
        // step advanced; this retry completes and unlocks Done.
        XCTAssertTrue(waitUntilEnabled(done, timeout: 3))
        done.click()
        XCTAssertTrue(setup.waitForNonExistence(timeout: 3))
        XCTAssertNotEqual(app.state, .notRunning)
    }

    func testGitHubLocalCatalogFailureThenRetrySucceeds() {
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
        app.launchArguments = ["--ui-test-setup", "--ui-test-github-cancel-retry"]
        app.launch()

        let setup = app.windows["setup.window"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        advanceFromDependenciesToGitHub(in: app)

        // The first catalog load reports a retryable unavailability; the retry
        // uses the current attempt and succeeds.
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.issue.unavailable"]
                .waitForExistence(timeout: 2)
        )
        assertText(
            "GitHub could not be reached. Try again later.",
            identifier: "setup.github.issue.unavailable",
            in: app
        )
        let retry = app.buttons["setup.github.retry.button"]
        XCTAssertTrue(retry.waitForExistence(timeout: 2))
        XCTAssertTrue(retry.isEnabled)
        retry.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.account"]
                .waitForExistence(timeout: 2)
        )
        assertText("Connected as @octocat", identifier: "setup.github.account", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.issue.unavailable"]
                .waitForNonExistence(timeout: 2)
        )
    }


    func testGitHubLocalCatalogUnavailableShowsIssueAndSkip() {
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
        app.launchArguments = ["--ui-test-setup", "--ui-test-github-unavailable"]
        app.launch()

        let setup = app.windows["setup.window"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        advanceFromDependenciesToGitHub(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github-boundary"].waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.descendants(matching: .any)["setup.github.unavailable"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["setup.github.disconnected"].exists)
        assertText(
            "GitHub could not be reached. Try again later.",
            identifier: "setup.github.issue.unavailable",
            in: app
        )
        let skip = app.buttons["setup.github.skip.button"]
        XCTAssertTrue(skip.waitForExistence(timeout: 2))
        XCTAssertEqual(skip.label, "Skip")
        XCTAssertTrue(skip.isEnabled)
        let back = app.buttons["setup.back.button"]
        XCTAssertTrue(back.waitForExistence(timeout: 2))
        XCTAssertEqual(app.buttons.matching(identifier: "setup.github.skip.button").count, 1)
        assertAction(skip, precedes: back, in: app)
        skip.click()
        XCTAssertTrue(app.buttons["setup.identity.skip.button"].waitForExistence(timeout: 2))
    }

    func testSetupReviewRendersTitleInTestLaunchMode() {
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
        app.launchArguments = ["--ui-test-setup-review"]
        app.launch()

        let setup = app.windows["setup.window"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["setup.final-review.title"].waitForExistence(timeout: 2))
        assertText("Review setup", identifier: "setup.final-review.title", in: app)
        assertIdentifier("setup.final-review.terminal", in: app)
        assertIdentifier("setup.final-review.editor", in: app)
    }


    private func advanceFromDependenciesToGitHub(in app: XCUIApplication) {
        let dependenciesContinue = app.buttons["setup.primary-action"]
        XCTAssertTrue(dependenciesContinue.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilEnabled(dependenciesContinue, timeout: 5))
        dependenciesContinue.click()
        let workspaceContinue = app.buttons["setup.workspaces.continue.button"]
        XCTAssertTrue(workspaceContinue.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilEnabled(workspaceContinue, timeout: 5))
        workspaceContinue.click()
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func assertIdentifier(_ identifier: String, in app: XCUIApplication) {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 2), "Missing \(identifier)")
    }

    private func assertText(_ text: String, identifier: String, in app: XCUIApplication) {
        let element = app.staticTexts[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 2), "Missing \(identifier)")
        XCTAssertEqual(element.value as? String, text)
    }

    private func assertAction(
        _ first: XCUIElement,
        precedes second: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThan(first.frame.minX, second.frame.minX, file: file, line: line)
        XCTAssertEqual(first.frame.midY, second.frame.midY, accuracy: 0.5, file: file, line: line)
        let identifiers = app.buttons.allElementsBoundByIndex.map(\.identifier)
        guard let firstIndex = identifiers.firstIndex(of: first.identifier),
              let secondIndex = identifiers.firstIndex(of: second.identifier) else {
            XCTFail("Missing actions in accessibility order", file: file, line: line)
            return
        }
        XCTAssertLessThan(firstIndex, secondIndex, file: file, line: line)
    }

    private func assertActionsReachTrailingEdge(
        of window: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actions = app.descendants(matching: .any)["setup.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 2), file: file, line: line)
        XCTAssertLessThan(window.frame.maxX - actions.frame.maxX, 30, file: file, line: line)
    }
}
