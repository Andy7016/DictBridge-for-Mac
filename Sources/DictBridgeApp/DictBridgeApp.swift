import AppKit
import DictBridgeCore
import SwiftUI

@main
struct DictBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DictBridge") {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.flushPendingFiles() }
        }
        .defaultSize(width: 780, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L.addDictionary) { model.showImporter = true }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .help) {
                Link("DictBridge on GitHub", destination: URL(string: "https://github.com/Andy7016/DictBridge-for-Mac")!)
            }
        }
    }
}

/// Handles files opened from Finder ("Open With…", dropping on the Dock icon).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When run straight from `swift run`, make sure we get a Dock icon and focus.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingFiles.append(contentsOf: urls)
        flushPendingFiles()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func flushPendingFiles() {
        guard !pendingFiles.isEmpty, let model = AppModel.shared else { return }
        let urls = pendingFiles
        pendingFiles.removeAll()
        model.handle(urls: urls)
    }
}
