import Foundation
import MDictKit

public enum ConversionError: Error, LocalizedError {
    case sourceNotFound(String)
    case noMDX(String)
    case notMDict(String)
    case emptyDictionary
    case notEnoughSpace(needed: Int64, available: Int64)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let p): return "File not found: \(p)"
        case .noMDX(let p): return "No .mdx file found for \(p)"
        case .notMDict(let n): return "\(n) is not an MDict .mdx/.mdd file"
        case .emptyDictionary: return "The dictionary contains no entries."
        case let .notEnoughSpace(needed, available):
            let f = ByteCountFormatter()
            return "Not enough free disk space: about \(f.string(fromByteCount: needed)) is needed, \(f.string(fromByteCount: available)) is available."
        case .cancelled: return "Cancelled."
        }
    }
}

public struct ConversionOptions: Sendable {
    /// Name shown in Dictionary.app.
    public var displayName: String
    /// Copy pronunciation audio from the .mdd (can be most of the size).
    public var includeAudio = true
    public var headwordMode: HeadwordMode = .auto
    /// Add Simplified/Traditional Chinese counterparts of headwords as search keys.
    public var chineseVariants = true
    /// Move the result into ~/Library/Dictionaries.
    public var install = true
    /// When not installing: where to put the built `.dictionary`.
    public var outputDirectory: URL?
    /// Keep the intermediate DDK sources (for debugging).
    public var keepWorkDirectory = false

    public init(displayName: String) { self.displayName = displayName }
}

public enum ConversionStage: String, Sendable, CaseIterable {
    case indexing, resources, converting, compiling, installing, finished
}

public struct ConversionProgress: Sendable {
    public var stage: ConversionStage
    /// Overall progress 0...1.
    public var fraction: Double
    public var detail: String
}

public struct ConversionReport: Sendable {
    public var bundleURL: URL
    public var installed: Bool
    public var entries = 0
    public var searchKeys = 0
    public var resources = 0
    public var audioLinks = 0
    public var crossLinks = 0
    public var unresolvedLinks = 0
    public var unresolvedRedirects = 0
    public var seconds: Double = 0
    public var warnings: [String] = []
}

/// Converts one MDict dictionary into an Apple Dictionary bundle.
public final class Converter: @unchecked Sendable {
    public let source: SourceDictionary
    public let options: ConversionOptions
    public let toolkit: DDKToolkit

    private let lock = NSLock()
    private var cancelled = false
    private var runner: ProcessRunner?

    static let audioExtensions: Set<String> = ["mp3", "wav", "spx", "ogg", "oga", "opus", "m4a", "aac", "amr"]
    static let reservedNames: Set<String> = [
        "body.data", "defaultstyle.css", "keytext.index", "keytext.data", "entryid.index", "entryid.data", "info.plist",
    ]
    /// Inline at most this much JavaScript into each entry that needs it.
    static let maxSharedScript = 256 * 1024

    public init(source: SourceDictionary, options: ConversionOptions, toolkit: DDKToolkit) {
        self.source = source
        self.options = options
        self.toolkit = toolkit
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let r = runner
        lock.unlock()
        r?.cancel()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func checkCancelled() throws {
        if isCancelled { throw ConversionError.cancelled }
    }

    public var bundleName: String { Slug.bundleName(for: source.baseName) }
    public var bundleIdentifier: String { DictBridge.bundleIdentifierPrefix + bundleName.lowercased() }

    // MARK: - Run

    public func run(progress: @escaping (ConversionProgress) -> Void,
                    log rawLog: @escaping (String) -> Void) throws -> ConversionReport {
        let started = Date()
        let log: (String) -> Void = { line in
            rawLog(String(format: "[%6.1fs] ", Date().timeIntervalSince(started)) + line)
        }
        let fm = FileManager.default
        var warnings: [String] = []
        func report(_ stage: ConversionStage, _ fraction: Double, _ detail: String) {
            progress(ConversionProgress(stage: stage, fraction: min(1, max(0, fraction)), detail: detail))
        }
        func warn(_ message: String) {
            warnings.append(message)
            log("warning: " + message)
        }

        let workDir = DictBridge.cacheDirectory.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer {
            if !options.keepWorkDirectory { try? fm.removeItem(at: workDir) }
        }
        log("DictBridge \(DictBridge.version) — converting \(source.mdx.lastPathComponent)")
        log("work directory: \(workDir.path)")

        // 1. Index: headwords and @@@LINK redirects -------------------------------------
        report(.indexing, 0, source.mdx.lastPathComponent)
        let mdx = try MDictFile(url: source.mdx)
        log("MDict engine \(mdx.header.engineVersion), encoding \(mdx.effectiveEncodingName), \(mdx.entryCount) keys")
        let encoding = mdx.encoding
        let linkPrefix = "@@@LINK=".data(using: encoding) ?? Data("@@@LINK=".utf8)
        func isRedirect(_ record: Data) -> Bool { record.starts(with: linkPrefix) }

        var headwords: [String] = []
        var redirects: [(alias: String, target: String)] = []
        var textBytes = 0
        let total = max(1, mdx.entryCount)
        try mdx.forEachRecord { i, key, record in
            if isRedirect(record) {
                let target = String(mdx.text(of: record).dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                redirects.append((key, target))
            } else {
                headwords.append(key)
                textBytes += record.count
            }
            if i % 5000 == 0 {
                report(.indexing, 0.05 * Double(i) / Double(total), "\(i)/\(total)")
                if self.isCancelled { return false }
            }
            return true
        }
        try checkCancelled()
        guard !headwords.isEmpty else { throw ConversionError.emptyDictionary }
        let resolver = LinkResolver(headwords: headwords, redirects: redirects)
        let (aliases, unresolvedRedirects) = resolver.aliasesByEntry()
        log("\(headwords.count) entries, \(redirects.count) redirects (\(unresolvedRedirects) point nowhere)")

        // Disk space: sources + DDK intermediates (~3x text) + resources copied twice.
        let resourceBytes = source.mdds.reduce(Int64(0)) { sum, url in
            sum + (((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let needed = Int64(textBytes) * 4 + resourceBytes * 2 + 300_000_000
        if let values = try? workDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage, available < needed {
            throw ConversionError.notEnoughSpace(needed: needed, available: available)
        }

        // 2. Resources from .mdd files and the dictionary folder ------------------------
        report(.resources, 0.05, "")
        let resDir = workDir.appendingPathComponent("OtherResources", isDirectory: true)
        try fm.createDirectory(at: resDir, withIntermediateDirectories: true)
        var written = Set<String>()
        var createdDirs = Set<String>()
        var stylesheets: [(String, String)] = []  // (name, css)
        var scripts: [(String, String)] = []
        var resourceCount = 0
        var skippedAudio = 0

        func decodeText(_ data: Data) -> String {
            if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
        }

        func store(_ relPath: String, _ data: Data) throws {
            let path = ResourcePath.normalize(relPath)
            let components = path.split(separator: "/")
            guard !path.isEmpty, !components.contains(".."), !components.contains(".") else { return }
            // Finder/Windows clutter that some .mdd files carry along.
            if components.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) || path.lowercased().hasSuffix("thumbs.db") {
                return
            }
            let lower = path.lowercased()
            guard written.insert(lower).inserted else { return }
            let ext = (path as NSString).pathExtension.lowercased()
            if ext == "css" { stylesheets.append((path, decodeText(data))) }
            if ext == "js" { scripts.append((path, decodeText(data))) }
            if !options.includeAudio && Self.audioExtensions.contains(ext) { skippedAudio += 1; return }
            if components.count == 1 && Self.reservedNames.contains(lower) {
                warn("skipped resource \(path) (name reserved by the dictionary bundle)")
                return
            }
            let dest = resDir.appendingPathComponent(path)
            let dir = dest.deletingLastPathComponent().path
            if !createdDirs.contains(dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                createdDirs.insert(dir)
            }
            try data.write(to: dest)
            resourceCount += 1
        }

        for (n, mddURL) in source.mdds.enumerated() {
            let mdd = try MDictFile(url: mddURL)
            log("\(mddURL.lastPathComponent): \(mdd.entryCount) resources")
            let count = max(1, mdd.entryCount)
            var failure: Error?
            try mdd.forEachRecord { i, key, data in
                do { try store(key, data) } catch { failure = error; return false }
                if i % 2000 == 0 {
                    let part = (Double(n) + Double(i) / Double(count)) / Double(max(1, source.mdds.count))
                    report(.resources, 0.05 + 0.15 * part, "\(mddURL.lastPathComponent) \(i)/\(count)")
                    if self.isCancelled { return false }
                }
                return true
            }
            if let failure { throw failure }
            try checkCancelled()
        }
        // Files next to the .mdx override nothing already taken from the .mdd.
        for url in source.stylesheets + source.scripts + source.looseResources {
            if let data = try? Data(contentsOf: url) { try store(url.lastPathComponent, data) }
        }
        if skippedAudio > 0 { log("left out \(skippedAudio) audio files (audio disabled)") }
        log("\(resourceCount) resource files, \(stylesheets.count) style sheets, \(scripts.count) scripts")

        var sharedScript = scripts.map { "/* \($0.0) */\n" + $0.1 }.joined(separator: "\n;\n")
        if sharedScript.utf8.count > Self.maxSharedScript {
            warn("dictionary scripts are \(sharedScript.utf8.count / 1024) KB; too large to inline, interactive features may not work")
            sharedScript = ""
        }

        // 3. Entries ---------------------------------------------------------------------
        report(.converting, 0.20, "")
        let xmlURL = workDir.appendingPathComponent("dict.xml")
        let writer = try DDKSourceWriter(url: xmlURL)
        let transformer = HTMLTransformer(
            resolver: resolver,
            context: .init(bundleIdentifier: bundleIdentifier, headwordMode: options.headwordMode, sharedScript: sharedScript))

        writer.writeFrontMatter(body: frontMatter(mdx: mdx, transformer: transformer))

        var inlineStyles: [String] = []
        var seenStyles = Set<String>()
        var stats = (audio: 0, cross: 0, unresolved: 0, keys: 0)
        var batch: [(index: Int, key: String, record: Data)] = []
        var batchBytes = 0
        var entryIndex = -1

        struct Prepared {
            var result: HTMLTransformer.Result
            var title: String
            var keys: [String]
        }
        let chinese = options.chineseVariants
        func flush() {
            guard !batch.isEmpty else { return }
            let n = batch.count
            let results = UnsafeMutableBufferPointer<Prepared?>.allocate(capacity: n)
            results.initialize(repeating: nil)
            defer {
                results.deinitialize()
                results.deallocate()
            }
            let work = batch
            DispatchQueue.concurrentPerform(iterations: n) { k in
                let item = work[k]
                let r = transformer.transform(html: mdx.text(of: item.record), headword: item.key)
                var keys = [item.key] + (aliases[item.index] ?? [])
                var extra: [String] = []
                for key in keys { extra += SearchKeys.variants(of: key, chinese: chinese) }
                keys += extra
                results[k] = Prepared(result: r, title: SearchKeys.displayTitle(for: item.key), keys: keys)
            }
            for k in 0..<n {
                guard let p = results[k] else { continue }
                let item = work[k]
                let r = p.result
                writer.writeEntry(id: DDKSourceWriter.entryID(item.index), title: p.title, searchKeys: p.keys, body: r.xhtml)
                stats.keys += Set(p.keys + [p.title]).count
                stats.audio += r.audioLinks
                stats.cross += r.crossLinks
                stats.unresolved += r.unresolvedLinks
                for style in r.inlineStyles where seenStyles.insert(style).inserted {
                    inlineStyles.append(style)
                }
            }
            batch.removeAll(keepingCapacity: true)
            batchBytes = 0
        }

        try mdx.forEachRecord { _, key, record in
            if isRedirect(record) { return true }
            entryIndex += 1
            batch.append((entryIndex, key, record))
            batchBytes += record.count
            if batch.count >= 512 || batchBytes >= 16 << 20 {
                flush()
                report(.converting, 0.20 + 0.25 * Double(entryIndex) / Double(headwords.count),
                       "\(entryIndex)/\(headwords.count)")
                if self.isCancelled { return false }
            }
            return true
        }
        try checkCancelled()
        flush()
        try writer.finish()
        log("wrote \(writer.entriesWritten) entries (\(writer.bytesWritten / 1_048_576) MB of XHTML)")

        // 4. Style sheet and Info.plist ------------------------------------------------------
        var css = ""
        var seenCSS = Set<String>()
        for (name, text) in stylesheets where seenCSS.insert(text).inserted {
            css += "/* \(name) */\n" + CSSProcessor.process(text) + "\n"
        }
        for style in inlineStyles where seenCSS.insert(style).inserted {
            css += CSSProcessor.process(style) + "\n"
        }
        css += CSSProcessor.additions + "\n"
        try css.write(to: workDir.appendingPathComponent("dict.css"), atomically: true, encoding: .utf8)

        let version = mdx.header.attributes["CreationDate"].flatMap { $0.isEmpty ? nil : $0 } ?? "1.0"
        try DictionaryPlist.write(
            to: workDir.appendingPathComponent("dict.plist"),
            displayName: options.displayName,
            bundleIdentifier: bundleIdentifier,
            version: version,
            copyright: "Converted from \(source.mdx.lastPathComponent) with DictBridge. Content © its respective owners.",
            sourceFile: source.mdx.lastPathComponent,
            frontMatter: true)

        // 5. Apple's build tool ----------------------------------------------------------
        try checkCancelled()
        report(.compiling, 0.45, "")
        let runner = ProcessRunner()
        lock.lock(); self.runner = runner; lock.unlock()
        let built = try toolkit.build(
            name: bundleName, workDirectory: workDir, xml: "dict.xml", css: "dict.css", plist: "dict.plist",
            runner: runner,
            progress: { f in report(.compiling, 0.45 + 0.52 * f, "") },
            log: log)
        try checkCancelled()

        // 6. Install / deliver -------------------------------------------------------------
        report(.installing, 0.97, "")
        let finalURL: URL
        if options.install {
            finalURL = try DictionaryLibrary.install(bundleAt: built)
            log("installed to \(finalURL.path)")
        } else {
            let dir = options.outputDirectory ?? source.folder
            let dest = dir.appendingPathComponent(built.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: built, to: dest)
            finalURL = dest
            log("saved to \(dest.path)")
        }

        var result = ConversionReport(bundleURL: finalURL, installed: options.install)
        result.entries = headwords.count
        result.searchKeys = stats.keys
        result.resources = resourceCount
        result.audioLinks = stats.audio
        result.crossLinks = stats.cross
        result.unresolvedLinks = stats.unresolved
        result.unresolvedRedirects = unresolvedRedirects
        result.seconds = Date().timeIntervalSince(started)
        result.warnings = warnings
        report(.finished, 1, "")
        log(String(format: "done in %.0f s", result.seconds))
        return result
    }

    private func frontMatter(mdx: MDictFile, transformer: HTMLTransformer) -> String {
        var html = "<h1>" + escape(options.displayName) + "</h1>"
        if let title = mdx.header.usableTitle, title != options.displayName {
            html += "<p><b>" + escape(title) + "</b></p>"
        }
        html += mdx.header.descriptionHTML
        html += "<hr/><p style=\"color:#888;font-size:85%\">Converted from " + escape(source.mdx.lastPathComponent)
            + " by DictBridge \(DictBridge.version). The dictionary content belongs to its respective owners.</p>"
        return transformer.transform(html: html, headword: "").xhtml
    }

    private func escape(_ s: String) -> String {
        var out = ""
        HTMLTransformer.escapeText(s, into: &out)
        return out
    }
}
