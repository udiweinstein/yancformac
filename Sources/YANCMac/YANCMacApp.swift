import AppKit
import SwiftUI

@main
struct YANCMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var cmd = Commander()

    var body: some Scene {
        WindowGroup("YANC for Mac") {
            ContentView(cmd: cmd)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateChecker.check() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Disk Image…") { cmd.newImage() }
                    .keyboardShortcut("n")
                Button("Make Bootable…") { cmd.makeBootable() }
                    .keyboardShortcut("b")
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
