import AppKit
import SwiftUI

@main
struct MSWMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusBarController(model: AppModel())
        statusBarController = controller

        if ProcessInfo.processInfo.arguments.contains("--ui-test-open-popover") {
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                controller.togglePopover()
            }
        }
    }
}
