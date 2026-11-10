import AppKit
import SwiftUI

@main
struct YANCMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("YANC for Mac") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateChecker.check() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // needed when started with `swift run` (no app bundle)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
