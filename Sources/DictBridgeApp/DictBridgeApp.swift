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
    /// Set while quitting waits for the cancelled conversion to wind down.
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When run straight from `swift run`, make sure we get a Dock icon and focus.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingFiles.append(contentsOf: urls)
        flushPendingFiles()
    }

    // Closing the window does not stop a conversion (the Dock icon brings the window back);
    // the app quits when the conversion ends instead.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppModel.shared?.job?.isRunning != true
    }

    /// Quitting during a conversion asks first, then cancels the conversion and quits once Apple's
    /// build tool has stopped and the work folder is gone. Quitting at once would leave both behind.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.shared, let job = model.job, job.isRunning else { return .terminateNow }
        if quitting { return .terminateCancel }
        let alert = NSAlert()
        alert.messageText = L.quitWhileConverting(job.name)
        alert.informativeText = L.quitWhileConvertingDetail
        alert.addButton(withTitle: L.quitAndCancel)
        alert.addButton(withTitle: L.keepConverting).keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        quitting = true
        Task {
            await model.cancelConversionAndWait()
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    func flushPendingFiles() {
        guard !pendingFiles.isEmpty, let model = AppModel.shared else { return }
        let urls = pendingFiles
        pendingFiles.removeAll()
        model.handle(urls: urls)
    }
}
