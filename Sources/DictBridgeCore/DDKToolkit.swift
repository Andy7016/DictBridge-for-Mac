import CryptoKit
import Foundation

public enum DDKError: Error, LocalizedError {
    case notInstalled
    case invalidFolder(String)
    case downloadFailed(String)
    case checksumMismatch(String)
    case buildFailed(String)
    case missingTool(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Apple's Dictionary Development Kit is not set up yet."
        case .invalidFolder(let p):
            return "\(p) does not look like a Dictionary Development Kit (bin/build_dict.sh is missing)."
        case .downloadFailed(let m):
            return "Could not download the Dictionary Development Kit: \(m)"
        case .checksumMismatch(let f):
            return "Downloaded file \(f) failed its SHA-256 check; nothing was installed."
        case .buildFailed(let m):
            return "Apple's dictionary build tool failed:\n\(m)"
        case .missingTool(let t):
            return "This Mac is missing \(t), which Apple's dictionary build tool needs."
        }
    }
}

/// Apple's Dictionary Development Kit (DDK): locating, downloading and running it.
///
/// Apple ships the DDK with "Additional Tools for Xcode" and its licence does not allow
/// redistribution, so DictBridge never bundles it. It either uses a copy the user already
/// has, or downloads the files from a public mirror pinned to one commit and verifies every
/// file against the SHA-256 values below (same mirror and hashes as the MIT-licensed
/// stardict2mac project).
public struct DDKToolkit {
    public let binDirectory: URL

    /// Files `build_dict.sh` actually runs.
    public static let requiredFiles = [
        "build_dict.sh", "extract_property.xsl", "generate_dict_template.sh", "make_line.pl",
        "make_body.pl", "extract_index.pl", "extract_referred_id.pl", "extract_front_matter_id.pl",
        "make_dict_package", "add_body_record", "replace_entryid_bodyid.pl", "normalize_key_text",
        "add_supplementary_key", "remove_duplicate_key.pl", "build_key_index",
        "pick_referred_entry_id.pl", "build_reference_index", "make_readonly.pl",
    ]

    /// Mirror of the DDK from Additional Tools for Xcode 14.1 (universal arm64/x86_64 binaries).
    public static let mirrorBase = URL(string: "https://raw.githubusercontent.com/nanoskript/dictionary-development-kit/d4127fd9cc133b081120dec18fb7fb195c74392d/bin/")!
    public static let mirrorPage = URL(string: "https://github.com/nanoskript/dictionary-development-kit")!
    public static let applePage = URL(string: "https://developer.apple.com/download/all/?q=Additional%20Tools%20for%20Xcode")!

    public static let pinnedSHA256: [String: String] = [
        "add_body_record": "851f42f3f017448820b1a7daa004428c367e08a2212396af3b1cb483d213799a",
        "add_key_index_record": "d8d21ab75c8483feb6177946c5fb0038f92d728823f11b933f7c17465d1ef3a1",
        "add_reference_index_record": "5c2b2e11a1a1baa56f1983fdd0e1e85c8c19e161f119d162b728b85449c74a6b",
        "add_supplementary_key": "aea17e4ea1d83a9120ba3d9db7a08baef3cafe2bce306110e2eea35566e00b52",
        "build_dict.sh": "96c60abedd89f1932bf5a54fe65ed03f739423b0434a1afe9e0cec9aae124ffc",
        "build_key_index": "e680f616c5106c80bf865323aa17982b899b78e3f13a57ffbf71005fe3699662",
        "build_reference_index": "52d0abeaffacea0c3bddb4e2c787d603788d621356b98d7ca45a4075833d0e80",
        "extract_front_matter_id.pl": "6897d1ccb71fef0b526cf7bf23fc0112d0397a0c7477e5e2dfbb59cd54d8e59b",
        "extract_index.pl": "553ffe57ce706b0420f34ed4b54f6642e793018d2405e04b13fc765305b0c721",
        "extract_property.xsl": "f3717e856b76a2fdea5d63ca325773cb0e39de0468fd666b7b133739061989c3",
        "extract_referred_id.pl": "a7a019681cde576d4be07f9f18c7b50d5abc8124195e62fe0bf835d859a0f044",
        "generate_dict_template.sh": "ca29e1549542a04b6bdbb9e3af16506e29c4770846ebafc2ae4709aca57d1d3d",
        "make_body.pl": "56610c47465fd569323cef625619d3ae64c12ecaa48f3322c2d239e4f9b80939",
        "make_dict_package": "3782e120009ea286931eaf580372c1c9f928e8413b13a73dad3f7b946dc7c2bb",
        "make_line.pl": "1737e1ab4d2254b4e661f025246932d54a1f538ab62a36572d5a5a3b69351fa6",
        "make_readonly.pl": "5a33bea0cbd1ccd7fe7ade30f1d35920c05d367f075244f0bde1ed04c89bcf0b",
        "normalize_key_text": "4f8e2e0bf2b047493b52e51c81352e90c42f658b5387f1fded102cc18fa93a92",
        "normalize_key_text.pl": "c004cec0efbf9bfb24a505fb39fc18413e51fcc116255a6330b59a6dd190948d",
        "pick_referred_entry_id.pl": "3ffa8473f480e678ebc0b0f318ba88c1b93c1b83731619d11f73367c06bc20bb",
        "remove_duplicate_key.pl": "90183557e24e44ddf5696f99b11f43aece76d54858334f56d7b08dfa5d0d9f85",
        "replace_entryid_bodyid.pl": "a60a4e3c4763866cb8a2e09e977e971ba4c4cf66c0db1f408a0ee997cf52b2b1",
    ]

    /// Where downloaded kits are stored.
    public static var managedBinDirectory: URL {
        DictBridge.supportDirectory.appendingPathComponent("DDK/bin", isDirectory: true)
    }

    private static var customPathFile: URL {
        DictBridge.supportDirectory.appendingPathComponent("ddk-path.txt")
    }

    /// Accepts the kit folder itself or its `bin` folder.
    public init?(folder: URL) {
        guard let dir = [folder, folder.appendingPathComponent("bin")].first(where: { Self.isComplete($0) }) else {
            return nil
        }
        binDirectory = dir
    }

    static func isComplete(_ dir: URL) -> Bool {
        requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// Finds a usable kit: `$DICTBRIDGE_DDK`, a folder the user chose, the managed copy,
    /// or a standard install location of Apple's kit.
    public static func locate() -> DDKToolkit? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["DICTBRIDGE_DDK"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let saved = try? String(contentsOf: customPathFile, encoding: .utf8) {
            let path = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { candidates.append(URL(fileURLWithPath: path)) }
        }
        candidates.append(managedBinDirectory)
        let home = FileManager.default.homeDirectoryForCurrentUser
        for base in ["/Applications/Utilities", "/Applications", home.appendingPathComponent("Applications").path,
                     "/Developer/Extras", home.appendingPathComponent("Developer").path] {
            candidates.append(URL(fileURLWithPath: base).appendingPathComponent("Dictionary Development Kit"))
        }
        for c in candidates {
            if let kit = DDKToolkit(folder: c) { return kit }
        }
        return nil
    }

    /// Remembers a kit folder chosen by the user.
    @discardableResult
    public static func useFolder(_ folder: URL) throws -> DDKToolkit {
        guard let kit = DDKToolkit(folder: folder) else { throw DDKError.invalidFolder(folder.path) }
        try FileManager.default.createDirectory(at: DictBridge.supportDirectory, withIntermediateDirectories: true)
        try kit.binDirectory.path.write(to: customPathFile, atomically: true, encoding: .utf8)
        return kit
    }

    /// Downloads the pinned kit, verifies every file, and installs it atomically.
    public static func download(progress: @escaping (Double) -> Void = { _ in }) async throws -> DDKToolkit {
        let fm = FileManager.default
        let staging = DictBridge.supportDirectory.appendingPathComponent("DDK-download-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let names = pinnedSHA256.keys.sorted()
        for (n, name) in names.enumerated() {
            let url = mirrorBase.appendingPathComponent(name)
            let data: Data
            do {
                let (d, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw DDKError.downloadFailed("HTTP \(http.statusCode) for \(name)")
                }
                data = d
            } catch let e as DDKError {
                throw e
            } catch {
                throw DDKError.downloadFailed(error.localizedDescription)
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == pinnedSHA256[name] else { throw DDKError.checksumMismatch(name) }
            let dest = staging.appendingPathComponent(name)
            try data.write(to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            progress(Double(n + 1) / Double(names.count))
        }

        let target = managedBinDirectory
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staging, to: target)
        try? fm.removeItem(at: customPathFile)
        guard let kit = DDKToolkit(folder: target) else { throw DDKError.notInstalled }
        return kit
    }

    /// Checks the macOS tools the kit's scripts call.
    public static func checkSystemTools() throws {
        for tool in ["/usr/bin/perl", "/usr/bin/xsltproc", "/usr/bin/xmllint", "/usr/bin/plutil", "/bin/sh"] {
            if !FileManager.default.isExecutableFile(atPath: tool) { throw DDKError.missingTool(tool) }
        }
    }

    /// Progress markers printed by `build_dict.sh`, with the fraction of the build they start.
    static let buildMilestones: [(String, Double)] = [
        ("- Checking source", 0.02),
        ("- Preprocessing dictionary sources", 0.08),
        ("- Extracting index data", 0.30),
        ("- Preparing dictionary bundle", 0.42),
        ("- Adding body data", 0.45),
        ("- Preparing index data", 0.62),
        ("- Building key_text index", 0.72),
        ("- Building reference index", 0.82),
        ("- Fixing dictionary property", 0.86),
        ("- Copying other resources", 0.88),
        ("- Finished building", 1.0),
    ]

    /// Runs `build_dict.sh` in `workDirectory` (which must contain `OtherResources/` if any).
    /// - Returns: URL of the built `<name>.dictionary` bundle.
    func build(name: String, workDirectory: URL, xml: String, css: String, plist: String,
               runner: ProcessRunner, progress: @escaping (Double) -> Void,
               log: @escaping (String) -> Void) throws -> URL {
        try Self.checkSystemTools()
        // Files we downloaded ourselves carry no quarantine flag, but a user-supplied copy might.
        for file in Self.requiredFiles {
            removexattr(binDirectory.appendingPathComponent(file).path, "com.apple.quarantine", 0)
        }
        let objects = workDirectory.appendingPathComponent("objects", isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["DICT_DEV_KIT_OBJ_DIR"] = objects.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["LC_ALL"] = "C"
        env["LANG"] = "C"

        var tail: [String] = []
        var duplicates = 0
        let status = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [binDirectory.appendingPathComponent("build_dict.sh").path, "-v", "10.11", name, xml, css, plist],
            workingDirectory: workDirectory,
            environment: env
        ) { line in
            if line.hasPrefix("* Duplicate index") { duplicates += 1; return }
            tail.append(line)
            if tail.count > 40 { tail.removeFirst() }
            log(line)
            for (marker, fraction) in Self.buildMilestones where line.hasPrefix(marker) {
                progress(fraction)
            }
        }
        if duplicates > 0 { log("(\(duplicates) duplicate index keys merged)") }
        let result = objects.appendingPathComponent("\(name).dictionary", isDirectory: true)
        guard status == 0, FileManager.default.fileExists(atPath: result.path) else {
            throw DDKError.buildFailed(tail.suffix(15).joined(separator: "\n"))
        }
        return result
    }
}
