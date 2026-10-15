import DictBridgeCore
import Foundation
import MDictKit

// dictbridge — command-line front end for DictBridge.

let usage = """
DictBridge \(DictBridge.version) — put MDict (.mdx/.mdd) dictionaries into macOS Dictionary.app

USAGE
  dictbridge convert <file.mdx|folder> [options]   convert and install a dictionary
  dictbridge list                                   list dictionaries in ~/Library/Dictionaries
  dictbridge remove <name|file.dictionary>          move an installed dictionary to the Trash
  dictbridge info <file.mdx|file.mdd>               show what is inside an MDict file
  dictbridge ddk [--download | --use <folder>]      show / set up Apple's Dictionary Development Kit

CONVERT OPTIONS
  --name <text>        name shown in Dictionary.app (default: the dictionary's title)
  --no-audio           leave pronunciation audio out of the bundle
  --headword auto|always|never
                       add the headword on top of entries that do not show it (default: auto)
  --no-chinese-variants
                       do not add Simplified/Traditional counterparts of Chinese headwords
  --no-install         do not install; save the .dictionary next to the .mdx (or --output)
  --output <folder>    where to save the .dictionary with --no-install
  --keep-work          keep the intermediate build folder (for debugging)
  --no-restart         do not restart Dictionary.app after installing

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func out(_ s: String) { print(s) }

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { out(usage); exit(0) }
args.removeFirst()

func takeValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { fail("\(flag) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func takeFlag(_ flag: String) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}

func formatBytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

/// Runs async work from synchronous top-level code (detached, so the main thread can block).
final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

func blocking<T>(_ operation: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.value = .success(try await operation()) } catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return box.value!
}

/// Restarts Dictionary.app around a change to its list of enabled dictionaries.
func updateDictionaryApp(enable: URL? = nil, disable: URL? = nil) {
    let result = blocking {
        await DictionaryLibrary.updateDictionaryApp {
            let enabled = enable.flatMap { DictionaryLibrary.describe($0) }.map { [$0] } ?? []
            return DictionaryLibrary.setEnabled(enabled, disable: disable.map { [$0] } ?? [])
        }
    }
    if case .success(let message) = result, !message.isEmpty { out("  " + message) }
}

func requireToolkit(downloadIfMissing: Bool) -> DDKToolkit {
    if let kit = DDKToolkit.locate() { return kit }
    guard downloadIfMissing else { fail("Apple's Dictionary Development Kit is not set up. Run: dictbridge ddk --download") }
    out("Downloading Apple's Dictionary Development Kit (verified by SHA-256)…")
    switch blocking({ try await DDKToolkit.download() }) {
    case .success(let kit):
        out("Installed to \(kit.binDirectory.path)")
        return kit
    case .failure(let e):
        fail(e.localizedDescription)
    }
}

switch command {
case "convert":
    let name = takeValue("--name")
    let output = takeValue("--output")
    let headword = takeValue("--headword")
    let noAudio = takeFlag("--no-audio")
    let noInstall = takeFlag("--no-install")
    let keepWork = takeFlag("--keep-work")
    let noRestart = takeFlag("--no-restart")
    let noChinese = takeFlag("--no-chinese-variants")
    guard let path = args.first else { fail("convert needs an .mdx file or folder") }
    let source: SourceDictionary
    do { source = try SourceDictionary(url: URL(fileURLWithPath: path)) } catch { fail(error.localizedDescription) }

    var options = ConversionOptions(displayName: name ?? source.suggestedName())
    options.includeAudio = !noAudio
    options.install = !noInstall
    options.keepWorkDirectory = keepWork
    options.chineseVariants = !noChinese
    if let output { options.outputDirectory = URL(fileURLWithPath: output) }
    if let headword {
        guard let mode = HeadwordMode(rawValue: headword) else { fail("--headword must be auto, always or never") }
        options.headwordMode = mode
    }

    out("Source:  \(source.mdx.path)")
    for mdd in source.mdds { out("         \(mdd.lastPathComponent)") }
    for css in source.stylesheets { out("         \(css.lastPathComponent)") }
    out("Name:    \(options.displayName)")

    let toolkit = requireToolkit(downloadIfMissing: true)
    let converter = Converter(source: source, options: options, toolkit: toolkit)
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigint.setEventHandler { converter.cancel() }
    sigint.resume()

    var lastStage: ConversionStage?
    var lastPercent = -1
    do {
        let report = try converter.run(progress: { p in
            let pct = Int(p.fraction * 100)
            if p.stage != lastStage || pct != lastPercent {
                lastStage = p.stage
                lastPercent = pct
                FileHandle.standardError.write(Data("\r[\(pct)%] \(p.stage.rawValue) \(p.detail)        ".utf8))
            }
        }, log: { line in
            FileHandle.standardError.write(Data(("\r" + line + "\n").utf8))
        })
        out("")
        out("✓ \(report.entries) entries, \(report.searchKeys) search keys, \(report.resources) resources")
        out("  \(report.crossLinks) cross-references, \(report.audioLinks) audio links, \(report.unresolvedLinks) unresolved links")
        out("  \(report.installed ? "Installed" : "Saved"): \(report.bundleURL.path)")
        for w in report.warnings { out("  warning: \(w)") }
        if report.installed && !noRestart {
            updateDictionaryApp(enable: report.bundleURL)
            out("  Open Dictionary.app → Settings to enable or reorder it.")
        }
    } catch {
        fail(error.localizedDescription)
    }

case "list":
    let items = DictionaryLibrary.installed()
    if items.isEmpty { out("No dictionaries in \(DictionaryLibrary.directory.path)") }
    for d in items {
        let tag = d.isDictBridge ? "[DictBridge]" : "            "
        out("\(tag) \(d.name)  —  \(d.url.lastPathComponent)  \(formatBytes(DictionaryLibrary.size(of: d.url)))")
    }

case "remove":
    guard let target = args.first else { fail("remove needs a dictionary name or file name") }
    let items = DictionaryLibrary.installed()
    let matches = items.filter {
        $0.name == target || $0.url.lastPathComponent == target || $0.url.deletingPathExtension().lastPathComponent == target
            || $0.url.path == target
    }
    guard matches.count == 1, let d = matches.first else {
        fail(matches.isEmpty ? "no installed dictionary called \(target) (see: dictbridge list)" : "\(target) is ambiguous")
    }
    do {
        try DictionaryLibrary.remove(d)
        out("Moved \(d.name) to the Trash.")
        updateDictionaryApp(disable: d.url)
    } catch {
        fail(error.localizedDescription)
    }

case "info":
    guard let path = args.first else { fail("info needs a file") }
    do {
        let file = try MDictFile(url: URL(fileURLWithPath: path))
        out("Title:      \(file.header.title)")
        out("Engine:     \(file.header.engineVersion)")
        out("Encoding:   \(file.header.encodingName)")
        out("Encrypted:  \(file.header.encrypted)")
        out("Keys:       \(file.entryCount)")
        var shown = 0
        try file.forEachRecord { _, key, record in
            if file.kind == .mdx {
                let text = file.text(of: record)
                out("  \(key): \(text.prefix(100).replacingOccurrences(of: "\n", with: " "))")
            } else {
                out("  \(key) (\(record.count) bytes)")
            }
            shown += 1
            return shown < 5
        }
    } catch {
        fail(error.localizedDescription)
    }

case "ddk":
    if takeFlag("--download") {
        _ = requireToolkit(downloadIfMissing: true)
    } else if let folder = takeValue("--use") {
        do {
            let kit = try DDKToolkit.useFolder(URL(fileURLWithPath: folder))
            out("Using \(kit.binDirectory.path)")
        } catch { fail(error.localizedDescription) }
    } else if let kit = DDKToolkit.locate() {
        out("Dictionary Development Kit: \(kit.binDirectory.path)")
    } else {
        out("Dictionary Development Kit: not set up (run: dictbridge ddk --download)")
    }

case "-h", "--help", "help":
    out(usage)

case "--version", "version":
    out(DictBridge.version)

default:
    fail("unknown command \(command)\n\n" + usage)
}
