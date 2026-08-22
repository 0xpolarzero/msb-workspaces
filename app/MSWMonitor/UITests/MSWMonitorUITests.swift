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
        app.launchArguments = ["--ui-test-setup"]
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
        XCTAssertFalse(
            app.descendants(matching: .any)["github.workspace.dev.repository.1001.mode"].exists,
            "Repository write controls appear only after a catalog load and selection."
        )
        let load = app.buttons["setup.github.load.button"]
        XCTAssertTrue(load.waitForExistence(timeout: 2))
        XCTAssertEqual(load.label, "Load GitHub repositories")
        XCTAssertTrue(load.isEnabled)
        load.click()
        XCTAssertTrue(app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 3))
        assertText("Connected as @octocat", identifier: "setup.github.account", in: app)
        let repository = app.descendants(matching: .any)["github.workspace.dev.repository.1001"]
        XCTAssertTrue(repository.waitForExistence(timeout: 2))
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

        let load = app.buttons["setup.github.load.button"]
        XCTAssertTrue(load.waitForExistence(timeout: 2))
        XCTAssertTrue(load.isEnabled)
        load.click()

        XCTAssertTrue(app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 2))
        assertText("Connected as @octocat", identifier: "setup.github.account", in: app)

        let repository = app.descendants(matching: .any)["github.workspace.dev.repository.1001"]
        XCTAssertTrue(repository.waitForExistence(timeout: 2))
        repository.click()
        let mode = app.descendants(matching: .any)["github.workspace.dev.repository.1001.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 2), "The mode selector appears only after selection.")
        let readOnlyMode = mode.radioButtons["Clone/pull (push from Mac)"]
        let writeMode = mode.radioButtons["Clone/pull + Push from VM"]
        XCTAssertTrue(readOnlyMode.exists)
        XCTAssertTrue(writeMode.waitForExistence(timeout: 2))
        writeMode.click()
        XCTAssertFalse(app.checkBoxes["Assign"].exists)
        XCTAssertFalse(app.staticTexts["Owner installation"].exists)
        XCTAssertFalse(app.staticTexts["Verification repository"].exists)
        XCTAssertFalse(app.staticTexts["Access mode"].exists)

        let review = app.buttons["setup.github.review.button"]
        XCTAssertTrue(review.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilEnabled(review, timeout: 2))
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 2))
        scrollView.swipeUp()
        XCTAssertTrue(waitUntilHittable(review, timeout: 2))
        review.click()

        let apply = app.buttons["setup.github.apply.button"]
        XCTAssertTrue(apply.waitForExistence(timeout: 2))
        XCTAssertTrue(apply.isEnabled)
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

        let load = app.buttons["setup.github.load.button"]
        XCTAssertTrue(load.waitForExistence(timeout: 2))
        XCTAssertTrue(load.isEnabled)
        load.click()

        // The account is connected but the catalog is empty; the no-repos
        // status is shown and the load control re-enables instead of hanging.
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 3)
        )
        assertText(
            "No repositories were found for your GitHub account. Grant access in GitHub, then load again.",
            identifier: "setup.github.status",
            in: app
        )
        XCTAssertTrue(waitUntilEnabled(load, timeout: 2))
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

        // System-ready but bootstrap-incomplete: the GitHub step starts locked.
        let githubStep = app.descendants(matching: .any)["setup.step.github"]
        XCTAssertTrue(githubStep.waitForExistence(timeout: 2))
        XCTAssertFalse(githubStep.isEnabled)

        let primaryAction = app.buttons["setup.primary-action"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 2))
        XCTAssertEqual(primaryAction.label, "Continue")
        primaryAction.click()

        // Local mode unlocks the GitHub step as soon as preflight passes.
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github-boundary"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.descendants(matching: .any)["setup.github.attention"].exists)
        let load = app.buttons["setup.github.load.button"]
        XCTAssertTrue(load.waitForExistence(timeout: 2))
        XCTAssertTrue(load.isEnabled)
        load.click()

        XCTAssertTrue(app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 2))
        assertText("Connected as @octocat", identifier: "setup.github.account", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["setup.github.attention"].exists)

        let repository = app.descendants(matching: .any)["github.workspace.dev.repository.1001"]
        XCTAssertTrue(repository.waitForExistence(timeout: 2))
        repository.click()

        let review = app.buttons["setup.github.review.button"]
        XCTAssertTrue(review.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilEnabled(review, timeout: 2))
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 2))
        scrollView.swipeUp()
        XCTAssertTrue(waitUntilHittable(review, timeout: 2))
        review.click()

        let apply = app.buttons["setup.github.apply.button"]
        XCTAssertTrue(apply.waitForExistence(timeout: 2))
        XCTAssertTrue(apply.isEnabled)
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

        let load = app.buttons["setup.github.load.button"]
        XCTAssertTrue(load.waitForExistence(timeout: 2))
        load.click()

        // The first catalog load fails with a retryable issue; the retry
        // uses the current attempt and succeeds.
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.issue.failed"]
                .waitForExistence(timeout: 2)
        )
        assertText(
            "GitHub could not be reached. Try again later.",
            identifier: "setup.github.issue.failed",
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
            app.descendants(matching: .any)["setup.github.issue.failed"]
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
        let load = app.buttons["setup.github.load.button"]
        XCTAssertTrue(load.waitForExistence(timeout: 2))
        XCTAssertEqual(load.label, "Load GitHub repositories")
        XCTAssertTrue(load.isEnabled)
        load.click()
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
