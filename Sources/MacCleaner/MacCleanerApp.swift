import AppKit
import MacCleanerCore
import MacCleanerUI
import SwiftUI

@main
struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MacCleanerScene()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // running from `swift run` has no bundle; make it a normal windowed app anyway.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// mole, fd and fclones run in their own process groups; stop them with the app.
    func applicationWillTerminate(_ notification: Notification) {
        ProcessRunner.terminateAll()
    }
}
