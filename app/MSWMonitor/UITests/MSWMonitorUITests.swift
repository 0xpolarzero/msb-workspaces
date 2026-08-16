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
        // The canonical build embeds the public GitHub App, so the step
        // offers the real direct login instead of the unavailable note.
        let connect = app.buttons["setup.github.connect.button"]
        XCTAssertTrue(connect.waitForExistence(timeout: 2))
        XCTAssertTrue(connect.isEnabled)
        let githubSkip = app.buttons["setup.github.skip.button"]
        XCTAssertTrue(githubSkip.waitForExistence(timeout: 2))
        XCTAssertEqual(githubSkip.label, "Continue without GitHub")
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

    func testGitHubAuthorizationSuccessAssignsAndVerifiesRepository() {
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

        let connect = app.buttons["setup.github.connect.button"]
        XCTAssertTrue(connect.waitForExistence(timeout: 2))
        XCTAssertTrue(connect.isEnabled)
        connect.click()

        XCTAssertTrue(app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 2))
        assertText("Connected as @octocat", identifier: "setup.github.account", in: app)

        let repository = app.descendants(matching: .any)["github.repository.1001.workspace.dev"]
        XCTAssertTrue(repository.waitForExistence(timeout: 2))
        repository.click()
        let mode = app.descendants(matching: .any)["github.repository.1001.workspace.dev.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 2), "The mode selector appears only after selection.")
        XCTAssertTrue(mode.label.contains("Read-only") || (mode.value as? String) == "Read-only")
        choosePicker("github.repository.1001.workspace.dev.mode", option: "Read & write", in: app)

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

        XCTAssertTrue(app.descendants(matching: .any)["setup.github.verifications"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.verification.dev.guest"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.verification.dev.host"]
                .waitForExistence(timeout: 2)
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

    func testGitHubAuthorizationNoInstallationShowsStatusAndDoesNotHang() {
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

        let connect = app.buttons["setup.github.connect.button"]
        XCTAssertTrue(connect.waitForExistence(timeout: 2))
        XCTAssertTrue(connect.isEnabled)
        connect.click()

        // The fixture returns no installation; the success cleanup must still
        // run so the wait ends and the status is shown instead of hanging.
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 3)
        )
        assertText(
            "Connected as @octocat, but no MSW App installation was found. Install the app, then connect GitHub again.",
            identifier: "setup.github.status",
            in: app
        )
        XCTAssertTrue(waitUntilEnabled(connect, timeout: 2))
    }

    func testSetupGitHubReconnectUnlocksGitHubStepThenVerifiesThroughDone() {
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

        // System-ready but bootstrap-incomplete: GitHub step starts locked.
        let githubStep = app.descendants(matching: .any)["setup.step.github"]
        XCTAssertTrue(githubStep.waitForExistence(timeout: 2))
        XCTAssertFalse(githubStep.isEnabled)

        let primaryAction = app.buttons["setup.primary-action"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 2))
        XCTAssertEqual(primaryAction.label, "Continue")
        primaryAction.click()

        // Continue runs the fixture bootstrap, which fails with a typed
        // reconnect error; setup jumps straight to the GitHub step and shows
        // the attention state there — no readiness warning, no second click.
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github-boundary"].waitForExistence(timeout: 3)
        )
        assertText(
            "GitHub access for dev needs attention.",
            identifier: "setup.github.attention",
            in: app
        )

        // Reconnect GitHub for dev using the fixture authorization flow.
        let connect = app.buttons["setup.github.connect.button"]
        XCTAssertTrue(connect.waitForExistence(timeout: 2))
        XCTAssertTrue(connect.isEnabled)
        connect.click()

        XCTAssertTrue(app.descendants(matching: .any)["setup.github.account"].waitForExistence(timeout: 2))
        assertText("Connected as @octocat", identifier: "setup.github.account", in: app)

        // Discovery alone creates no host credential; the attention banner
        // must survive the re-authorization until dev's grant commits.
        XCTAssertTrue(app.staticTexts["setup.github.attention"].exists)

        let repository = app.descendants(matching: .any)["github.repository.1001.workspace.dev"]
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

        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.verification.dev.guest"]
                .waitForExistence(timeout: 2)
        )
        // Only the successful commit for the attention workspace clears it.
        XCTAssertFalse(app.staticTexts["setup.github.attention"].exists)
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

        // Verification has not passed yet: Done is blocked and the review step
        // offers the re-verification action.
        let done = app.buttons["setup.done.button"]
        XCTAssertTrue(done.waitForExistence(timeout: 2))
        XCTAssertFalse(done.isEnabled)
        let verify = app.buttons["setup.review.verify.button"]
        XCTAssertTrue(verify.waitForExistence(timeout: 2))
        XCTAssertTrue(verify.isEnabled)
        verify.click()

        XCTAssertTrue(waitUntilEnabled(done, timeout: 3))
        done.click()
        XCTAssertTrue(setup.waitForNonExistence(timeout: 3))
        XCTAssertNotEqual(app.state, .notRunning)
    }
    func testSettingsMakesDirectDeviceScopeTruthful() {
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
        // Deterministic fixture: no real Keychain session and no network.
        app.launchArguments = ["--ui-test-setup", "--ui-test-device-access"]
        app.launch()
        XCTAssertTrue(app.windows["setup.window"].waitForExistence(timeout: 3))
        app.menuBars.menuItems["Settings…"].click()
        let settings = app.windows.matching(
            NSPredicate(format: "identifier != %@", "setup.window")
        ).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        let githubTab = settings.buttons["GitHub"]
        XCTAssertTrue(githubTab.waitForExistence(timeout: 5))
        githubTab.click()

        XCTAssertTrue(settings.descendants(matching: .any)["settings.github.device-scope"].waitForExistence(timeout: 5))
        let account = settings.descendants(matching: .any)["settings.github.status"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.staticTexts["Connected as @octocat"].waitForExistence(timeout: 5))
        XCTAssertFalse(settings.checkBoxes["github.workspace.dev.access"].exists)
    }

    func testGitHubAuthorizationCancelThenRetryUsesCurrentAttempt() {
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

        let connect = app.buttons["setup.github.connect.button"]
        XCTAssertTrue(connect.waitForExistence(timeout: 2))
        connect.click()

        let cancel = app.buttons["setup.github.cancel.button"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilHittable(cancel, timeout: 2))
        cancel.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.issue.cancelled"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(connect.waitForExistence(timeout: 2))
        XCTAssertTrue(connect.isEnabled)
        connect.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.account"]
                .waitForExistence(timeout: 2)
        )
        assertText("Connected as @octocat", identifier: "setup.github.account", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["setup.github.issue.cancelled"]
                .waitForNonExistence(timeout: 2)
        )
    }


    func testGitHubAuthorizationUnavailablePreservesOptionalPath() {
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
        assertText(
            "GitHub connection is unavailable. The existing access and saved choices remain unchanged; retry after MSW Connect is available.",
            identifier: "setup.github.unavailable",
            in: app
        )
        XCTAssertTrue(
            app.buttons["setup.github.connect.button"].waitForNonExistence(timeout: 1)
        )
        let skip = app.buttons["setup.github.skip.button"]
        XCTAssertTrue(skip.waitForExistence(timeout: 2))
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

    private func choosePicker(
        _ identifier: String,
        option: String,
        in app: XCUIApplication
    ) {
        let picker = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 2), "Missing \(identifier)")
        picker.click()
        let menuItem = app.menuItems[option]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2), "Missing picker option \(option)")
        menuItem.click()
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

