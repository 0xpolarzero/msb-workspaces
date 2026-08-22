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
        assertText("Not observed", identifier: "monitor.health", in: app)
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
        app.launchArguments = ["--ui-test-setup", "--ui-test-github-disconnected"]
        app.launch()

        let setup = app.windows["setup.window"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))

        let stepper = app.descendants(matching: .any)["setup.stepper"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 2))
        for identifier in [
            "setup.step.readiness",
            "setup.step.github",
            "setup.step.identity",
            "setup.step.review"
        ] {
            assertIdentifier(identifier, in: app)
        }

        let preflight = app.descendants(matching: .any)["setup.preflight"]
        XCTAssertTrue(preflight.waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github-boundary"]
                .waitForNonExistence(timeout: 2)
        )

        let primaryAction = app.buttons["setup.primary-action"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 2))
        XCTAssertEqual(primaryAction.label, "Continue")
        XCTAssertTrue(primaryAction.isEnabled)
        primaryAction.click()

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
        let connect = app.buttons["setup.github.connect-account.button"]
        XCTAssertTrue(connect.waitForExistence(timeout: 3))
        XCTAssertEqual(connect.label, "Connect GitHub Account on This Mac")
        let githubSkip = app.buttons["setup.github.skip.button"]
        XCTAssertTrue(githubSkip.waitForExistence(timeout: 2))
        XCTAssertEqual(githubSkip.label, "Skip GitHub")
        githubSkip.click()

        let identitySkip = app.buttons["setup.identity.skip.button"]
        XCTAssertTrue(identitySkip.waitForExistence(timeout: 2))
        XCTAssertEqual(identitySkip.label, "Skip identity for now")
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.identity"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github-boundary"]
                .waitForNonExistence(timeout: 2)
        )
        identitySkip.click()
        let review = app.buttons["setup.review.button"]
        XCTAssertTrue(review.waitForExistence(timeout: 2))
        XCTAssertTrue(review.isEnabled)
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.final-review.title"]
                .waitForNonExistence(timeout: 2)
        )
        review.click()

        let finalReview = app.staticTexts["setup.final-review.title"]
        XCTAssertTrue(finalReview.waitForExistence(timeout: 2))
        assertText("Ready to finish", identifier: "setup.final-review.title", in: app)
        assertText("Your choices are ready to apply.", identifier: "setup.final-review.summary", in: app)
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
        primaryAction.click()

        XCTAssertTrue(app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 3))
        assertText("Connected as @octocat", identifier: "setup.github.account", in: app)
        XCTAssertFalse(app.buttons["setup.github.connect-account.button"].exists)
        XCTAssertFalse(app.buttons["setup.github.skip.button"].exists)
        let refreshCatalog = app.buttons["setup.github.refresh.button"]
        XCTAssertTrue(refreshCatalog.waitForExistence(timeout: 2))
        XCTAssertEqual(refreshCatalog.label, "Refresh")
        refreshCatalog.click()
        XCTAssertTrue(waitUntilEnabled(refreshCatalog, timeout: 2))

        let initialSetupFrame = setup.frame
        let accessInfo = app.buttons["setup.github.workspace-access.info.button"]
        XCTAssertTrue(accessInfo.waitForExistence(timeout: 2))
        XCTAssertEqual(accessInfo.label, "Workspace Access information")
        XCTAssertTrue(accessInfo.isEnabled)
        accessInfo.click()
        assertText(
            "When enabled, this VM may use the Mac-held GitHub credential to push. The credential stays on the Mac.",
            identifier: "setup.github.workspace-access.help",
            in: app
        )
        app.buttons["setup.github.workspace-access.help.done"].click()
        XCTAssertTrue(
            app.staticTexts["setup.github.workspace-access.help"].waitForNonExistence(timeout: 2)
        )
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["setup.github.workspace-access.help"].waitForExistence(timeout: 2)
        )
        app.buttons["setup.github.workspace-access.help.done"].click()

        let picker = app.buttons["github.workspace.dev.repository-picker.button"]
        XCTAssertTrue(picker.waitForExistence(timeout: 2))
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
        XCTAssertEqual(push.label, "Allow pushes from this VM")
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
        XCTAssertFalse(app.buttons["Continue"].exists)
        apply.click()

        // Local mode writes the policy file; there are no verification
        // results to render.
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.verifications"]
                .waitForNonExistence(timeout: 2)
        )
        assertText(
            "Applied repository access for 1 workspace(s).",
            identifier: "setup.github.status",
            in: app
        )
        let githubContinue = app.buttons["Continue"]
        XCTAssertTrue(githubContinue.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilEnabled(githubContinue, timeout: 2))
        githubContinue.click()

        let identitySkip = app.buttons["setup.identity.skip.button"]
        XCTAssertTrue(identitySkip.waitForExistence(timeout: 2))
        identitySkip.click()
        let reviewSetup = app.buttons["setup.review.button"]
        XCTAssertTrue(reviewSetup.waitForExistence(timeout: 2))
        reviewSetup.click()
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
        app.buttons["setup.primary-action"].click()

        let connect = app.buttons["setup.github.connect-account.button"]
        XCTAssertTrue(connect.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["setup.github.refresh.button"].exists)
        connect.click()

        XCTAssertTrue(app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 3))
        assertText("Connected as @octocat", identifier: "setup.github.account", in: app)
        XCTAssertFalse(app.buttons["setup.github.connect-account.button"].exists)
        XCTAssertFalse(app.buttons["setup.github.skip.button"].exists)
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
        app.buttons["setup.primary-action"].click()

        // The account is connected but the catalog is empty; the no-repos
        // status is shown and the refresh control re-enables instead of hanging.
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 3)
        )
        assertText(
            "No repositories found.",
            identifier: "setup.github.status",
            in: app
        )
        XCTAssertTrue(waitUntilEnabled(app.buttons["setup.github.refresh.button"], timeout: 2))
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

        // Local mode can be configured as soon as preflight passes, even while
        // bootstrap is still creating workspaces.
        let githubStep = app.descendants(matching: .any)["setup.step.github"]
        XCTAssertTrue(githubStep.waitForExistence(timeout: 2))
        XCTAssertTrue(githubStep.isEnabled)

        let primaryAction = app.buttons["setup.primary-action"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 2))
        XCTAssertEqual(primaryAction.label, "Continue")
        primaryAction.click()

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
        XCTAssertFalse(app.buttons["Continue"].exists)
        apply.click()

        assertText(
            "Applied repository access for 1 workspace(s).",
            identifier: "setup.github.status",
            in: app
        )
        let githubContinue = app.buttons["Continue"]
        XCTAssertTrue(githubContinue.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilEnabled(githubContinue, timeout: 2))
        githubContinue.click()

        let identitySkip = app.buttons["setup.identity.skip.button"]
        XCTAssertTrue(identitySkip.waitForExistence(timeout: 2))
        identitySkip.click()
        let reviewSetup = app.buttons["setup.review.button"]
        XCTAssertTrue(reviewSetup.waitForExistence(timeout: 2))
        reviewSetup.click()

        // Bootstrap is still incomplete: Done is blocked and the review step
        // offers the workspace verification action.
        let done = app.buttons["setup.done.button"]
        XCTAssertTrue(done.waitForExistence(timeout: 2))
        XCTAssertFalse(done.isEnabled)
        let verify = app.buttons["setup.review.verify.button"]
        XCTAssertTrue(verify.waitForExistence(timeout: 2))
        XCTAssertTrue(verify.isEnabled)
        verify.click()
        // The reconnect fixture fails its first bootstrap run; a second run
        // completes and unlocks Done.
        XCTAssertTrue(verify.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilEnabled(verify, timeout: 3))
        verify.click()

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
        app.buttons["setup.primary-action"].click()

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
        app.buttons["setup.primary-action"].click()
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
        XCTAssertEqual(skip.label, "Skip GitHub")
        XCTAssertTrue(skip.isEnabled)
        skip.click()
        XCTAssertTrue(app.buttons["setup.identity.skip.button"].waitForExistence(timeout: 2))
    }

    func testSetupReviewExplainsCompletionState() {
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
        assertText("Ready to finish", identifier: "setup.final-review.title", in: app)
        assertText("Your choices are ready to apply.", identifier: "setup.final-review.summary", in: app)
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
}
