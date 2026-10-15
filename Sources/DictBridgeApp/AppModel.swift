import AppKit
import DictBridgeCore
import Foundation
import SwiftUI

/// A dictionary the user picked, waiting for confirmation in the import sheet.
struct PendingImport: Identifiable {
    let id = UUID()
    let source: SourceDictionary
    var displayName: String
    var includeAudio = true
    var headwordMode: HeadwordMode = .auto
    var replacesExisting: Bool
}

/// State of the running (or last) conversion.
struct ConversionJob {
    enum Status { case running, succeeded(ConversionReport), failed(String), cancelled }
    let name: String
    var status: Status = .running
    var stage: ConversionStage = .indexing
    var fraction: Double = 0
    var detail = ""
    var log: [String] = []

    var isRunning: Bool { if case .running = status { return true } else { return false } }
}

@MainActor
final class AppModel: ObservableObject {
    static weak var shared: AppModel?

    @Published var installed: [InstalledDictionary] = []
    @Published var sizes: [String: Int64] = [:]
    @Published var job: ConversionJob?
    @Published var pendingImport: PendingImport?
    @Published var showImporter = false
    @Published var showDDKSetup = false
    @Published var ddkReady = DDKToolkit.locate() != nil
    @Published var ddkDownloading = false
    @Published var ddkProgress: Double = 0
    @Published var errorMessage: String?
    @Published var removeCandidate: InstalledDictionary?
    @Published var dropTargeted = false

    private var converter: Converter?
    /// Import to start right after the DDK setup sheet succeeds.
    private var importAfterSetup: PendingImport?

    init() {
        AppModel.shared = self
        refresh()
    }

    // MARK: Library

    func refresh() {
        installed = DictionaryLibrary.installed()
        let urls = installed.map(\.url)
        Task.detached(priority: .utility) {
            var result: [String: Int64] = [:]
            for url in urls { result[url.path] = DictionaryLibrary.size(of: url) }
            await MainActor.run { [result] in self.sizes = result }
        }
    }

    func reveal(_ d: InstalledDictionary) {
        NSWorkspace.shared.activateFileViewerSelecting([d.url])
    }

    func revealLibraryFolder() {
        try? FileManager.default.createDirectory(at: DictionaryLibrary.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(DictionaryLibrary.directory)
    }

    func openDictionaryApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DictionaryLibrary.dictionaryAppBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func confirmRemove(_ d: InstalledDictionary) { removeCandidate = d }

    func remove(_ d: InstalledDictionary) {
        do {
            try DictionaryLibrary.remove(d)
            Task {
                await DictionaryLibrary.restartDictionaryApp(reopen: DictionaryLibrary.isDictionaryAppRunning)
                refresh()
            }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Import

    func handle(urls: [URL]) {
        guard let url = urls.first else { return }
        if job?.isRunning == true { errorMessage = L.busy; return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let source = try SourceDictionary(url: url)
            let bundleFile = Slug.bundleName(for: source.baseName) + ".dictionary"
            let exists = FileManager.default.fileExists(atPath: DictionaryLibrary.directory.appendingPathComponent(bundleFile).path)
            pendingImport = PendingImport(source: source, displayName: source.suggestedName(), replacesExisting: exists)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startConversion(_ request: PendingImport) {
        pendingImport = nil
        guard let toolkit = DDKToolkit.locate() else {
            importAfterSetup = request
            showDDKSetup = true
            return
        }
        var options = ConversionOptions(displayName: request.displayName.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? request.source.baseName : request.displayName)
        options.includeAudio = request.includeAudio
        options.headwordMode = request.headwordMode
        let converter = Converter(source: request.source, options: options, toolkit: toolkit)
        self.converter = converter
        job = ConversionJob(name: options.displayName)

        let progressSink = ThrottledSink<ConversionProgress> { [weak self] p in
            guard let self, self.job?.isRunning == true else { return }
            self.job?.stage = p.stage
            self.job?.fraction = p.fraction
            self.job?.detail = p.detail
        }
        let logSink = LineSink { [weak self] lines in
            guard let self else { return }
            self.job?.log.append(contentsOf: lines)
            if let count = self.job?.log.count, count > 3000 { self.job?.log.removeFirst(count - 3000) }
        }

        Task.detached(priority: .userInitiated) {
            let outcome: Result<ConversionReport, Error>
            do {
                outcome = .success(try converter.run(progress: { progressSink.send($0) }, log: { logSink.send($0) }))
            } catch {
                outcome = .failure(error)
            }
            await logSink.flushNow()
            await MainActor.run {
                switch outcome {
                case .success(let report):
                    self.job?.fraction = 1
                    self.job?.status = .succeeded(report)
                case .failure(let error):
                    if let ce = error as? ConversionError, case .cancelled = ce {
                        self.job?.status = .cancelled
                    } else {
                        self.job?.status = .failed(error.localizedDescription)
                    }
                }
                self.converter = nil
                self.refresh()
            }
            if case .success = outcome {
                await DictionaryLibrary.restartDictionaryApp(reopen: DictionaryLibrary.isDictionaryAppRunning)
            }
        }
    }

    func cancelConversion() { converter?.cancel() }

    func dismissJob() { if job?.isRunning != true { job = nil } }

    func copyLog() {
        guard let log = job?.log.joined(separator: "\n") else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log, forType: .string)
    }

    // MARK: DDK

    func downloadDDK() {
        ddkDownloading = true
        ddkProgress = 0
        Task {
            do {
                _ = try await DDKToolkit.download { p in
                    Task { @MainActor in self.ddkProgress = p }
                }
                ddkReady = true
                ddkDownloading = false
                finishDDKSetup()
            } catch {
                ddkDownloading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func useDDKFolder(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try DDKToolkit.useFolder(url)
            ddkReady = true
            finishDDKSetup()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finishDDKSetup() {
        showDDKSetup = false
        if let pending = importAfterSetup {
            importAfterSetup = nil
            startConversion(pending)
        }
    }

    func cancelDDKSetup() {
        showDDKSetup = false
        importAfterSetup = nil
    }
}

/// Coalesces high-frequency progress updates into at most ~10 main-thread updates per second.
final class ThrottledSink<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: T?
    private var scheduled = false
    private let deliver: @MainActor (T) -> Void

    init(_ deliver: @escaping @MainActor (T) -> Void) { self.deliver = deliver }

    func send(_ value: T) {
        lock.lock()
        latest = value
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard needsSchedule else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.drain()
        }
    }

    @MainActor private func drain() {
        lock.lock()
        let v = latest
        scheduled = false
        lock.unlock()
        if let v { deliver(v) }
    }
}

/// Batches log lines for the main thread.
final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []
    private var scheduled = false
    private let deliver: @MainActor ([String]) -> Void

    init(_ deliver: @escaping @MainActor ([String]) -> Void) { self.deliver = deliver }

    func send(_ line: String) {
        lock.lock()
        buffer.append(line)
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard needsSchedule else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.drain()
        }
    }

    func flushNow() async {
        await MainActor.run { self.drain() }
    }

    @MainActor private func drain() {
        lock.lock()
        let lines = buffer
        buffer.removeAll()
        scheduled = false
        lock.unlock()
        if !lines.isEmpty { deliver(lines) }
    }
}
