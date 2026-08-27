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

    func testDedicatedRuntimeRepairClearsEverySurfaceAfterVerifiedReactivation() {
        let app = launchFixture([
            "--ui-test-open-popover",
            "--ui-test-runtime-repair"
        ])
        defer { terminateIfNeeded(app) }

        let statusItem = app.statusItems["statusItem.button"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        XCTAssertEqual(statusItem.label, "MSW Monitor")
        XCTAssertEqual(
            statusItem.value as? String,
            "MSW Monitor. Repair needed. MSW installation needs repair."
        )

        let applicationMenu = app.menuBars.menuBarItems["MSW Monitor"]
        XCTAssertTrue(applicationMenu.waitForExistence(timeout: 2))
        applicationMenu.click()
        XCTAssertTrue(app.menuItems["About MSW Monitor"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Settings…"].exists)
        XCTAssertTrue(app.menuItems["Hide MSW Monitor"].exists)
        XCTAssertTrue(app.menuItems["Quit MSW Monitor"].exists)
        app.typeKey(.escape, modifierFlags: [])

        assertText("MSW Monitor", identifier: "monitor.title", in: app)
        assertText("dev", identifier: "workspace.dev.name", in: app)
        assertText("Stopped", identifier: "workspace.dev.state", in: app)
        assertText("playgrounds", identifier: "workspace.playgrounds.name", in: app)
        assertText("Stopped", identifier: "workspace.playgrounds.state", in: app)
        assertText("personal", identifier: "workspace.personal.name", in: app)
        assertText("Stopped", identifier: "workspace.personal.state", in: app)
        assertText(
            "MSW installation needs repair",
            identifier: "runtime-repair.popover.message",
            in: app
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "runtime-repair.popover.row").count,
            1
        )
        XCTAssertEqual(
            app.staticTexts.matching(identifier: "runtime-repair.popover.message").count,
            1
        )
        XCTAssertEqual(app.buttons.matching(identifier: "runtime-repair.popover.action").count, 1)
        XCTAssertEqual(app.buttons["runtime-repair.popover.action"].label, "Repair…")
        XCTAssertEqual(app.buttons["open-monitor.button"].label, "Open MSW Monitor…")
        XCTAssertEqual(app.buttons["quit.button"].label, "Quit")
        XCTAssertFalse(app.buttons["details.button"].exists)
        XCTAssertFalse(app.buttons["settings.button"].exists)
        XCTAssertFalse(app.buttons["setup.button"].exists)

        app.buttons["runtime-repair.popover.action"].click()
        let repairWindow = app.windows["runtime-repair.window"]
        XCTAssertTrue(repairWindow.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["runtime-repair.page"].exists)
        let repairTitle = app.descendants(matching: .any)["runtime-repair.title"]
        XCTAssertTrue(repairTitle.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["MSW installation needs repair"].exists)
        XCTAssertTrue(app.buttons["runtime-repair.installation.action"].exists)
        XCTAssertTrue(app.buttons["runtime-repair.close"].exists)
        XCTAssertFalse(app.windows["setup.window"].exists)
        app.buttons["runtime-repair.close"].click()
        XCTAssertTrue(repairWindow.waitForNonExistence(timeout: 3))

        statusItem.click()
        XCTAssertTrue(app.buttons["open-monitor.button"].waitForExistence(timeout: 2))

        app.buttons["open-monitor.button"].click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.tabs"].waitForExistence(timeout: 3))
        for tab in ["Overview", "Workspaces", "GitHub", "Notifications", "Backup", "General"] {
            let tabButton = app.toolbars.buttons[tab]
            XCTAssertTrue(tabButton.waitForExistence(timeout: 2), "Missing \(tab) tab")
            tabButton.click()
            assertText(
                "MSW installation needs repair",
                identifier: "runtime-repair.window.message",
                in: app
            )
            XCTAssertEqual(
                app.descendants(matching: .any)
                    .matching(identifier: "runtime-repair.window.banner").count,
                1
            )
            XCTAssertEqual(
                app.staticTexts.matching(identifier: "runtime-repair.window.message").count,
                1
            )
            XCTAssertEqual(app.buttons.matching(identifier: "runtime-repair.window.action").count, 1)
            XCTAssertEqual(app.buttons["runtime-repair.window.action"].label, "Repair…")
            let chrome = app.descendants(matching: .any)["runtime-repair.window.chrome"]
            XCTAssertTrue(chrome.exists, "Missing repair chrome on \(tab)")
            if ["Workspaces", "Backup", "GitHub"].contains(tab) {
                XCTAssertFalse(app.staticTexts["Request failed"].exists, "Duplicate repair error on \(tab)")
            }
            if tab == "Workspaces" || tab == "Backup" {
                XCTAssertFalse(app.descendants(matching: .any)["details.error"].exists)
            }
            if tab == "Backup" {
                XCTAssertFalse(app.descendants(matching: .any)["backup.operation.card"].exists)
            }
            if tab == "GitHub" {
                XCTAssertFalse(app.descendants(matching: .any)["settings.github.error"].exists)
            }
        }

        app.buttons["runtime-repair.window.action"].click()
        XCTAssertTrue(repairWindow.waitForExistence(timeout: 3))
        XCTAssertFalse(app.windows["setup.window"].exists)
        let repair = app.buttons["runtime-repair.installation.action"]
        XCTAssertTrue(repair.waitForExistence(timeout: 3))
        repair.click()
        let repairResult = app.descendants(matching: .any)["runtime-repair.result"]
        XCTAssertTrue(repairResult.waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts["MSW runtime repair could not complete. Show details, then retry."]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.descendants(matching: .any)["runtime-repair.details.text"].exists)
        let finalDetail = NSPredicate(
            format: "label CONTAINS %@",
            "Final fixture error: package metadata was unavailable."
        )
        XCTAssertEqual(app.staticTexts.matching(finalDetail).count, 0)
        let detailsDisclosure = app.buttons["runtime-repair.details.disclosure"]
        XCTAssertTrue(detailsDisclosure.waitForExistence(timeout: 2))
        XCTAssertEqual(detailsDisclosure.label, "Show Details")
        detailsDisclosure.click()
        let details = app.descendants(matching: .any)["runtime-repair.details.text"]
        XCTAssertTrue(details.waitForExistence(timeout: 2))
        NSPasteboard.general.clearContents()
        app.buttons["runtime-repair.details.copy"].click()
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "Installing dependency fixture\nFinal fixture error: package metadata was unavailable."
        )

        repair.click()
        XCTAssertFalse(app.descendants(matching: .any)["runtime-repair.details.text"].exists)
        XCTAssertFalse(app.buttons["runtime-repair.details.copy"].exists)
        XCTAssertTrue(app.staticTexts["Installation repaired"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["runtime-repair.window.banner"]
                .waitForNonExistence(timeout: 3)
        )
        app.buttons["runtime-repair.close"].click()
        XCTAssertTrue(repairWindow.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(identifier: "runtime-repair.window.action").count, 0)
        XCTAssertEqual(app.staticTexts.matching(identifier: "runtime-repair.window.message").count, 0)
        for tab in ["Overview", "Workspaces", "GitHub", "Notifications", "Backup", "General"] {
            app.toolbars.buttons[tab].click()
            XCTAssertFalse(app.descendants(matching: .any)["runtime-repair.window.banner"].exists)
            XCTAssertFalse(app.staticTexts["runtime-repair.window.message"].exists)
            XCTAssertFalse(app.buttons["runtime-repair.window.action"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["runtime-repair.window.chrome"].exists)
        }
        let compatibleStatus = NSPredicate(
            format: "value == %@",
            "Not observed. No authoritative workspace state is available yet."
        )
        expectation(for: compatibleStatus, evaluatedWith: statusItem)
        waitForExpectations(timeout: 3)

        statusItem.click()
        XCTAssertTrue(app.descendants(matching: .any)["monitor.title"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.descendants(matching: .any)["runtime-repair.popover.row"].exists)
        XCTAssertFalse(app.staticTexts["runtime-repair.popover.message"].exists)
        XCTAssertFalse(app.buttons["runtime-repair.popover.action"].exists)
        app.buttons["quit.button"].click()
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

    func testGitHubSettingsPreloadsAndEditsInline() {
        let app = launchFixture([
            "--ui-test-open-popover",
            "--ui-test-github-success"
        ])
        defer { terminateIfNeeded(app) }

        let openMonitor = app.buttons["open-monitor.button"]
        XCTAssertTrue(openMonitor.waitForExistence(timeout: 2))
        openMonitor.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.tabs"].waitForExistence(timeout: 3))

        let githubTab = app.toolbars.buttons["GitHub"]
        XCTAssertTrue(githubTab.waitForExistence(timeout: 2))
        githubTab.click()

        XCTAssertTrue(
            app.staticTexts["Connected as @octocat"].waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.staticTexts["Loading GitHub status…"].exists)

        XCTAssertFalse(app.buttons["settings.github.setup.button"].exists)
        XCTAssertTrue(app.buttons["settings.github.disable-all"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["settings.github.reset"].waitForExistence(timeout: 2))
        let workspaceAccess = app.descendants(matching: .any)["settings.github.workspace-access"]
        XCTAssertTrue(workspaceAccess.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["settings.github.editor.save"].exists)
        XCTAssertFalse(app.windows["setup.window"].exists)

        let repositoryPicker = app.buttons["github.workspace.dev.repository-picker.button"]
        XCTAssertTrue(repositoryPicker.waitForExistence(timeout: 2))
        repositoryPicker.click()
        let repository = app.checkBoxes["github.workspace.dev.repository.1001"]
        XCTAssertTrue(repository.waitForExistence(timeout: 2))
        repository.click()

        XCTAssertTrue(app.staticTexts["Unsaved"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.github.unsaved"]
                .waitForExistence(timeout: 2)
        )
        repository.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.github.unsaved"]
                .waitForNonExistence(timeout: 2)
        )
        repository.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.github.unsaved"]
                .waitForExistence(timeout: 2)
        )
        app.typeKey(.escape, modifierFlags: [])
        let save = app.buttons["settings.github.editor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        XCTAssertTrue(save.isEnabled)
        let editorScreenshot = XCTAttachment(screenshot: app.screenshot())
        editorScreenshot.name = "GitHub settings unsaved workspace access"
        editorScreenshot.lifetime = .keepAlways
        add(editorScreenshot)

        save.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.github.unsaved"]
                .waitForNonExistence(timeout: 3)
        )
        XCTAssertTrue(workspaceAccess.exists)
        let disable = app.buttons["settings.github.disable-all"]
        disable.click()
        XCTAssertTrue(app.buttons["Enable Access"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Access disabled"].exists)
        app.buttons["Enable Access"].click()
        XCTAssertTrue(app.buttons["Disable Access"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.windows["setup.window"].exists)
    }

    private func launchFixture(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/MSWMonitor.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        let app = XCUIApplication(url: appURL)
        app.launchArguments = arguments
        app.launchEnvironment.merge(environment) { _, requested in requested }
        app.launch()
        return app
    }

    private func terminateIfNeeded(_ app: XCUIApplication) {
        if app.state != .notRunning {
            app.terminate()
        }
    }

    func testBackupDestinationSelectionShowsRequiredSpaceConfirmation() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWMonitor Backups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let app = launchFixture([
            "--ui-test-open-popover",
            "--ui-test-backup-destination=\(destination.path)"
        ])
        defer { terminateIfNeeded(app) }

        XCTAssertTrue(app.buttons["open-monitor.button"].waitForExistence(timeout: 2))
        app.buttons["open-monitor.button"].click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.tabs"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.toolbars.buttons["Backup"].waitForExistence(timeout: 2))
        app.toolbars.buttons["Backup"].click()

        let createNewBackup = app.buttons["backup.create-new.button"]
        XCTAssertTrue(createNewBackup.waitForExistence(timeout: 2))
        createNewBackup.click()

        let destinationPanel = app.dialogs["Choose Backup Destination"]
        XCTAssertTrue(destinationPanel.waitForExistence(timeout: 3))
        let chooseDestination = destinationPanel.buttons["Choose Destination…"]
        XCTAssertTrue(chooseDestination.waitForExistence(timeout: 2))
        chooseDestination.click()

        let confirmationTitle = app.descendants(matching: .any)["backup.confirmation.title"]
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 3))
        XCTAssertEqual(confirmationTitle.value as? String, "Create new backup")
        XCTAssertEqual(
            app.descendants(matching: .any)["backup.required-space.label"].value as? String,
            "Allocated source data"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["backup.required-space.value"].value as? String,
            "16 GB"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["backup.estimate.explanation"].value as? String,
            "Estimated archive size: unavailable until a same-scope backup completes. Exact compressed size is unknowable without compressing; no synthetic estimate is shown."
        )
        XCTAssertEqual(app.buttons["backup.confirmation.create"].label, "Create Backup")
        app.buttons["backup.confirmation.cancel"].click()
        XCTAssertTrue(confirmationTitle.waitForNonExistence(timeout: 2))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.statusItems["statusItem.button"].waitForExistence(timeout: 2))
        app.statusItems["statusItem.button"].click()
        app.buttons["quit.button"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 3))
    }

    func testBackupResultCardSuccessPartialAndFailure() throws {
        let scenarios = ["running", "success", "partial", "failure"]
        var launchedApps: [XCUIApplication] = []
        var destinations: [URL] = []
        defer {
            launchedApps.forEach { terminateIfNeeded($0) }
            destinations.forEach { try? FileManager.default.removeItem(at: $0) }
        }

        for scenario in scenarios {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("MSWMonitor Backup Result \(scenario)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            destinations.append(destination)
            let app = launchFixture([
                "--ui-test-open-popover",
                "--ui-test-backup-destination=\(destination.path)",
                "--ui-test-backup-result=\(scenario)",
                "-AppleLanguages", "(en)",
                "-AppleLocale", "en_FR"
            ], environment: ["TZ": "Europe/Paris"])
            launchedApps.append(app)

            XCTAssertTrue(app.buttons["open-monitor.button"].waitForExistence(timeout: 2))
            app.buttons["open-monitor.button"].click()
            XCTAssertTrue(app.toolbars.buttons["Backup"].waitForExistence(timeout: 3))
            app.toolbars.buttons["Backup"].click()
            app.buttons["backup.create-new.button"].click()
            let destinationPanel = app.dialogs["Choose Backup Destination"]
            XCTAssertTrue(destinationPanel.waitForExistence(timeout: 3))
            destinationPanel.buttons["Choose Destination…"].click()
            XCTAssertTrue(app.buttons["backup.confirmation.create"].waitForExistence(timeout: 3))
            app.buttons["backup.confirmation.create"].click()

            XCTAssertTrue(
                app.descendants(matching: .any)["backup.operation.card"]
                    .waitForExistence(timeout: 3)
            )
            XCTAssertFalse(app.staticTexts["Latest backup result"].exists)
            XCTAssertFalse(app.staticTexts["Outcome unknown"].exists)
            XCTAssertFalse(app.buttons["Retry Backup"].exists)

            switch scenario {
            case "running":
                assertText("Archiving and writing", identifier: "backup.running.status", in: app)
                assertText("Fixture archive pipeline is advancing.", identifier: "backup.running.message", in: app)
                assertIdentifier("backup.running.spinner", in: app)
                assertIdentifier("backup.running.started", in: app)
                assertIdentifier("backup.running.updated", in: app)
                assertIdentifier("backup.running.counters", in: app)
                XCTAssertFalse(app.descendants(matching: .any)["backup.running.percentage"].exists)
                XCTAssertFalse(app.descendants(matching: .any)["backup.result.archive"].exists)
                XCTAssertFalse(app.staticTexts["Request failed"].exists)
            case "success":
                assertText("Archive created", identifier: "backup.result.status", in: app)
                assertText(
                    "microsandbox-all-20260826-120000.tar.zst",
                    identifier: "backup.result.archive",
                    in: app
                )
                assertBackupArchiveSize(in: app)
                assertBackupCompletionTime(in: app)
                XCTAssertFalse(app.descendants(matching: .any)["backup.result.restart-warning"].exists)
                XCTAssertFalse(app.staticTexts["Request failed"].exists)
            case "partial":
                assertText("Archive created", identifier: "backup.result.status", in: app)
                assertText(
                    "microsandbox-all-20260826-120000.tar.zst",
                    identifier: "backup.result.archive",
                    in: app
                )
                assertText(
                    "Restart required for: personal.",
                    identifier: "backup.result.restart-warning",
                    in: app
                )
                assertBackupArchiveSize(in: app)
                assertBackupCompletionTime(in: app)
                XCTAssertFalse(app.staticTexts["Request failed"].exists)
                XCTAssertFalse(app.descendants(matching: .any)["details.error"].exists)
                let refresh = app.buttons["backup.result.refresh-workspaces"]
                XCTAssertTrue(refresh.waitForExistence(timeout: 2))
                XCTAssertTrue(refresh.isEnabled)
                refresh.click()
            case "failure":
                assertText("Request failed", identifier: "backup.result.failure", in: app)
                XCTAssertEqual(
                    app.descendants(matching: .any)
                        .matching(NSPredicate(format: "value == %@", "Request failed")).count,
                    1
                )
                XCTAssertFalse(app.descendants(matching: .any)["details.error"].exists)
                XCTAssertFalse(app.descendants(matching: .any)["backup.result.archive"].exists)
            default:
                XCTFail("Unexpected backup result scenario")
            }

            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 3))
        }
    }

    func testBackupConcurrentFixtureReattachesAfterRelaunchAndAdvancesCounters() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWMonitor Backup Reattach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let arguments = [
            "--ui-test-open-popover",
            "--ui-test-backup-destination=\(destination.path)",
            "--ui-test-backup-reattach",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_FR"
        ]

        var initialCounters: String?
        var initialUpdated: String?
        for launchIndex in 0..<2 {
            let launchArguments = launchIndex == 0
                ? arguments
                : arguments + ["--ui-test-backup-reattach-advanced"]
            let app = launchFixture(launchArguments, environment: ["TZ": "Europe/Paris"])
            defer { terminateIfNeeded(app) }
            XCTAssertTrue(app.buttons["open-monitor.button"].waitForExistence(timeout: 3))
            app.buttons["open-monitor.button"].click()
            XCTAssertTrue(app.toolbars.buttons["Backup"].waitForExistence(timeout: 3))
            app.toolbars.buttons["Backup"].click()

            let cards = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", "backup.operation.card")
            )
            XCTAssertEqual(cards.count, 2)
            assertText("Archive created", identifier: "backup.result.status", in: app)
            assertText("fixture-completed.tar.zst", identifier: "backup.result.archive", in: app)
            assertText("Archiving and writing", identifier: "backup.running.status", in: app)
            assertText(
                launchIndex == 0
                    ? "Fixture reattached to CLI-owned operation."
                    : "Fixture counters advanced after reattachment.",
                identifier: "backup.running.message", in: app
            )
            let counters = app.descendants(matching: .any)["backup.running.counters"]
            XCTAssertTrue(counters.waitForExistence(timeout: 2))
            let countersValue = counters.value as? String
            let updated = app.descendants(matching: .any)["backup.running.updated"]
            XCTAssertTrue(updated.waitForExistence(timeout: 2))
            let updatedValue = updated.value as? String
            if launchIndex == 0 {
                initialCounters = countersValue
                initialUpdated = updatedValue
            } else {
                XCTAssertNotEqual(countersValue, initialCounters)
                XCTAssertNotEqual(updatedValue, initialUpdated)
            }

            if launchIndex == 0 {
                app.typeKey("q", modifierFlags: .command)
            } else {
                app.typeKey("w", modifierFlags: .command)
                XCTAssertTrue(app.statusItems["statusItem.button"].waitForExistence(timeout: 2))
                app.statusItems["statusItem.button"].click()
                app.buttons["quit.button"].click()
            }
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 3))
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
        app.launchArguments = [
            "--ui-test-open-popover", "--ui-test-operation-failure",
            "--ui-test-malformed-backup"
        ]
        app.launch()

        assertText("Start failed", identifier: "monitor.health", in: app)
        let details = app.buttons["error.details.button"]
        XCTAssertTrue(details.waitForExistence(timeout: 2))
        details.click()

        XCTAssertTrue(app.descendants(matching: .any)["settings.tabs"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["details.sidebar"].exists)
        assertWorkspaceSection("Logs", in: app)
        let failurePanel = app.descendants(matching: .any)["details.latest-operation-error"]
        XCTAssertTrue(failurePanel.waitForExistence(timeout: 2))
        assertText(
            "The runtime rejected the start request.",
            identifier: "lifecycle.failure.summary",
            in: app
        )
        XCTAssertEqual(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "malformed backup data")
            ).count,
            0
        )
        XCTAssertFalse(app.descendants(matching: .any)["lifecycle.failure.details.text"].exists)
        let disclosure = app.buttons["lifecycle.failure.details.disclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 2))
        XCTAssertEqual(disclosure.label, "Show Details")
        disclosure.click()
        let diagnosticText = app.staticTexts["lifecycle.failure.details.text"]
        XCTAssertTrue(diagnosticText.waitForExistence(timeout: 2))
        XCTAssertTrue(diagnosticText.isEnabled)
        NSPasteboard.general.clearContents()
        diagnosticText.click()
        diagnosticText.typeKey("a", modifierFlags: .command)
        diagnosticText.typeKey("c", modifierFlags: .command)
        let copiedSelection = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copiedSelection.contains("/dev/vdc"))
        NSPasteboard.general.clearContents()
        let copyDetails = app.buttons["lifecycle.failure.details.copy"]
        XCTAssertTrue(copyDetails.waitForExistence(timeout: 2))
        copyDetails.click()
        let copiedDetails = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copiedDetails.contains("/dev/vdc"))
        XCTAssertTrue(copiedDetails.contains("MSW_WORKSPACE_DISK_INVALID"))
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
        let app = launchFixture([
            "--ui-test-open-popover",
            "--ui-test-folder-browser"
        ])
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
        XCTAssertEqual(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@",
                    "Runs the same dependency checks"
                )
            ).count,
            0
        )
        XCTAssertTrue(app.buttons["Run checks"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.descendants(matching: .any)["workspace.section.Files"].exists)
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
        assertWorkspaceSection("Files", in: app)
        let navigationScreenshot = XCTAttachment(screenshot: app.screenshot())
        navigationScreenshot.name = "Workspace primary and secondary navigation"
        navigationScreenshot.lifetime = .keepAlways
        add(navigationScreenshot)
        XCTAssertFalse(app.descendants(matching: .any)["workspace.section.Summary"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["workspace.section.Repositories"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["workspace.section.Maintenance"].exists)
        XCTAssertFalse(app.popUpButtons["details.workspace-picker"].exists)
        assertText("Repositories", identifier: "files.repositories.title", in: app)
        assertText("File tree", identifier: "files.tree.title", in: app)
        let combinedFileTree = app.descendants(matching: .any)["files.workspace-tree"]
        XCTAssertTrue(combinedFileTree.waitForExistence(timeout: 2))
        XCTAssertFalse(app.descendants(matching: .any)["folders.path-bar"].exists)
        XCTAssertFalse(app.textFields["folders.search.field"].exists)
        for workspace in ["dev", "playgrounds", "personal"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["workspace.filter.\(workspace)"]
                    .waitForExistence(timeout: 2)
            )
            XCTAssertTrue(
                app.descendants(matching: .any)["repositories.workspace.\(workspace)"]
                    .waitForExistence(timeout: 2)
            )
            XCTAssertTrue(
                app.descendants(matching: .any)["files.tree.workspace.\(workspace)"]
                    .waitForExistence(timeout: 2)
            )
        }
        XCTAssertFalse(app.staticTexts["Loading repositories…"].exists)

        let bulkWorkspaceFilter = app.descendants(matching: .any)["workspace.filter.toggle-all"]
        XCTAssertTrue(bulkWorkspaceFilter.waitForExistence(timeout: 2))
        XCTAssertEqual(bulkWorkspaceFilter.label, "Clear all workspaces")
        bulkWorkspaceFilter.click()
        XCTAssertTrue(app.staticTexts["No workspaces selected"].waitForExistence(timeout: 2))
        XCTAssertEqual(bulkWorkspaceFilter.label, "Select all workspaces")
        bulkWorkspaceFilter.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["repositories.workspace.dev"]
                .waitForExistence(timeout: 2)
        )

        let devWorkspaceFilter = app.descendants(matching: .any)["workspace.filter.dev"]
        devWorkspaceFilter.click()
        let logs = app.buttons["Logs"]
        XCTAssertTrue(logs.waitForExistence(timeout: 2))
        logs.click()
        assertWorkspaceSection("Logs", in: app)
        XCTAssertFalse(app.popUpButtons["details.workspace-picker"].exists)
        let logTable = app.descendants(matching: .any)["logs.table"]
        XCTAssertTrue(logTable.waitForExistence(timeout: 2))
        let logSearch = app.textFields["logs.search"]
        XCTAssertTrue(logSearch.waitForExistence(timeout: 2))
        let followLogs = app.descendants(matching: .any)["logs.follow"]
        XCTAssertTrue(followLogs.waitForExistence(timeout: 2))
        XCTAssertEqual(followLogs.label, "Pause")
        let wrapLogs = app.descendants(matching: .any)["logs.wrap"]
        XCTAssertTrue(wrapLogs.waitForExistence(timeout: 2))
        let copySelectedLogs = app.descendants(matching: .any)["logs.copy.selected"]
        XCTAssertTrue(copySelectedLogs.waitForExistence(timeout: 2))
        XCTAssertFalse(copySelectedLogs.isEnabled)
        let copyVisibleLogs = app.descendants(matching: .any)["logs.copy.visible"]
        XCTAssertTrue(copyVisibleLogs.waitForExistence(timeout: 2))
        XCTAssertTrue(copyVisibleLogs.isEnabled)

        let playgroundLog = app.descendants(matching: .any)["logs.row.playgrounds.0.message"]
        let personalLog = app.descendants(matching: .any)["logs.row.personal.0.message"]
        XCTAssertTrue(playgroundLog.waitForExistence(timeout: 2))
        XCTAssertTrue(personalLog.waitForExistence(timeout: 2))
        XCTAssertFalse(app.descendants(matching: .any)["logs.row.dev.0.message"].exists)
        XCTAssertEqual(playgroundLog.value as? String, "Playground task completed")
        XCTAssertEqual(personalLog.value as? String, "Personal task completed")
        XCTAssertFalse((playgroundLog.value as? String ?? "").contains("bounded logs"))

        logSearch.click()
        logSearch.typeText("Playground")
        XCTAssertTrue(playgroundLog.waitForExistence(timeout: 2))
        XCTAssertFalse(personalLog.exists)
        logSearch.typeKey("a", modifierFlags: .command)
        logSearch.typeKey(.delete, modifierFlags: [])

        app.descendants(matching: .any)["workspace.filter.dev"].click()
        let devLog = app.descendants(matching: .any)["logs.row.dev.0.message"]
        XCTAssertTrue(devLog.waitForExistence(timeout: 2))
        XCTAssertEqual(devLog.value as? String, "Development service ready")
        XCTAssertFalse((devLog.value as? String ?? "").contains("HHHHHHHH"))
        XCTAssertFalse(app.descendants(matching: .any)["logs.select.dev.0"].exists)

        let structuredLog = app.descendants(matching: .any)["logs.row.dev.1.message"]
        XCTAssertTrue(structuredLog.waitForExistence(timeout: 2))
        XCTAssertEqual(
            structuredLog.value as? String,
            #"{"event":"build","level":"info","ok":true}"#
        )
        app.descendants(matching: .any)["logs.row.dev.1.timestamp"].click()
        XCTAssertTrue(copySelectedLogs.isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["logs.inspector"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["JSON details"].waitForExistence(timeout: 2))

        followLogs.click()
        XCTAssertEqual(followLogs.label, "Follow")
        followLogs.click()
        XCTAssertEqual(followLogs.label, "Pause")
        wrapLogs.click()
        copyVisibleLogs.click()

        let workspacesWindow = app.windows["Workspaces"]
        XCTAssertLessThan(logTable.frame.minX - workspacesWindow.frame.minX, 120)
        XCTAssertLessThan(logTable.frame.minY - logSearch.frame.maxY, 36)
        let logViewerScreenshot = XCTAttachment(screenshot: app.screenshot())
        logViewerScreenshot.name = "Native workspace log viewer"
        logViewerScreenshot.lifetime = .keepAlways
        add(logViewerScreenshot)

        let network = app.buttons["Network"]
        XCTAssertTrue(network.waitForExistence(timeout: 2))
        network.click()
        assertWorkspaceSection("Network", in: app)
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
        assertWorkspaceSection("Activity", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["details.activity"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.popUpButtons["details.workspace-picker"].exists)
        for workspace in ["dev", "playgrounds", "personal"] {
            XCTAssertTrue(app.descendants(matching: .any)["workspace.filter.\(workspace)"].exists)
        }

        let backupTab = app.toolbars.buttons["Backup"]
        XCTAssertTrue(backupTab.waitForExistence(timeout: 2))
        backupTab.click()
        XCTAssertTrue(app.windows["Backup"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Archive scope"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Backup"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Restore"].waitForExistence(timeout: 2))
        let createNewBackup = app.buttons["backup.create-new.button"]
        XCTAssertTrue(createNewBackup.waitForExistence(timeout: 2))
        XCTAssertEqual(createNewBackup.label, "Create New Backup…")
        XCTAssertFalse(app.buttons["Review New Backup…"].exists)
        XCTAssertTrue(app.buttons["Choose Restore Archive…"].waitForExistence(timeout: 2))

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

    func testUnifiedWindowOwnsLifecycleConfirmationAndVerifiesRestartGap() {
        let app = launchFixture([
            "--ui-test-open-popover",
            "--ui-test-lifecycle"
        ])
        defer { terminateIfNeeded(app) }

        XCTAssertTrue(app.buttons["open-monitor.button"].waitForExistence(timeout: 2))
        app.buttons["open-monitor.button"].click()
        XCTAssertTrue(app.windows["Overview"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)["monitor.popover"]
                .waitForNonExistence(timeout: 2)
        )

        let stop = app.buttons["workspace.dev.window-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 2))
        stop.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["lifecycle.window-confirmation.sheet"]
                .waitForExistence(timeout: 2)
        )
        let confirmation = app.descendants(matching: .any)["lifecycle.window-confirmation.confirm"]
        let cancel = app.descendants(matching: .any)["lifecycle.window-confirmation.cancel"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        XCTAssertEqual(confirmation.label, "Stop")
        XCTAssertFalse(app.descendants(matching: .any)["monitor.popover"].exists)
        cancel.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["lifecycle.window-confirmation.sheet"]
                .waitForNonExistence(timeout: 2)
        )
        assertText("Running", identifier: "workspace.dev.summary-state", in: app)

        let restart = app.buttons["workspace.dev.window-restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 2))
        restart.click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        XCTAssertEqual(confirmation.label, "Restart")
        XCTAssertFalse(app.descendants(matching: .any)["monitor.popover"].exists)
        confirmation.click()
        let state = app.staticTexts["workspace.dev.summary-state"]
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", "Stopped"),
                    object: state
                )],
                timeout: 2
            ),
            .completed
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", "Running"),
                    object: state
                )],
                timeout: 4
            ),
            .completed
        )
        app.typeKey("q", modifierFlags: .command)
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

        assertWorkspaceSection("Network", in: app)
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

        let combinedFileTree = app.descendants(matching: .any)["files.workspace-tree"]
        XCTAssertTrue(combinedFileTree.waitForExistence(timeout: 2))
        for workspace in ["dev", "playgrounds", "personal"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["files.tree.workspace.\(workspace)"]
                    .waitForExistence(timeout: 2)
            )
        }
        XCTAssertFalse(app.textFields["folders.search.field"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["folders.path-bar"].exists)
        let folderTree = app.descendants(matching: .any)["folders.tree"]
        XCTAssertTrue(folderTree.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["folders.entry.Projects"].waitForExistence(timeout: 2))
        assertText("Repositories", identifier: "files.repositories.title", in: app)
        assertText("File tree", identifier: "files.tree.title", in: app)
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
        assertWorkspaceSection("Logs", in: app)
        XCTAssertFalse(folderTree.exists)
        XCTAssertFalse(combinedFileTree.exists)

        XCTAssertTrue(app.buttons["Files"].waitForExistence(timeout: 2))
        app.buttons["Files"].click()
        assertWorkspaceSection("Files", in: app)
        XCTAssertTrue(folderTree.waitForExistence(timeout: 2))
        XCTAssertTrue(combinedFileTree.waitForExistence(timeout: 2))
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
        XCTAssertFalse(app.descendants(matching: .any)["folders.truncated"].exists)
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
        let initialPushValue = String(describing: push.value)
        push.hover()
        push.click()
        XCTAssertNotEqual(
            String(describing: push.value),
            initialPushValue,
            "Hovering the help tooltip must not consume the switch click"
        )
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

    private func assertWorkspaceSection(
        _ section: String,
        in app: XCUIApplication
    ) {
        let item = app.descendants(matching: .any)["workspace.section.\(section)"]
        XCTAssertTrue(item.waitForExistence(timeout: 2), "Missing \(section) workspace submenu item")
        XCTAssertEqual(item.value as? String, "Selected")
    }

    private func assertText(_ text: String, identifier: String, in app: XCUIApplication) {
        let element = app.staticTexts[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 2), "Missing \(identifier)")
        XCTAssertEqual(element.value as? String, text)
    }

    private func assertBackupArchiveSize(in app: XCUIApplication) {
        let element = app.staticTexts["backup.result.size"]
        XCTAssertTrue(element.waitForExistence(timeout: 2), "Missing backup.result.size")
        let value = element.value as? String ?? ""
        XCTAssertNotNil(
            value.range(of: #"^7[.,]3 M(B|o)$"#, options: .regularExpression),
            "Unexpected compressed archive size: \(value)"
        )
    }

    private func assertBackupCompletionTime(in app: XCUIApplication) {
        assertText(
            "26 Aug 2026 at 14:00:00",
            identifier: "backup.result.completed",
            in: app
        )
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
