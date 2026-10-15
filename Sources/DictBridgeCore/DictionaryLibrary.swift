import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A dictionary bundle installed in `~/Library/Dictionaries`.
public struct InstalledDictionary: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleIdentifier: String
    /// Made by DictBridge (as opposed to dictionaries installed some other way).
    public let isDictBridge: Bool
    /// Original `.mdx` file name, for DictBridge dictionaries.
    public let source: String?
    public let created: Date?
}

/// Manages the user's dictionary folder.
public enum DictionaryLibrary {
    public static let dictionaryAppBundleID = "com.apple.Dictionary"

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Dictionaries", isDirectory: true)
    }

    /// All `.dictionary` bundles in `~/Library/Dictionaries`, DictBridge ones first, then by name.
    public static func installed() -> [InstalledDictionary] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { $0.pathExtension.lowercased() == "dictionary" }
            .compactMap { describe($0) }
            .sorted {
                if $0.isDictBridge != $1.isDictBridge { return $0.isDictBridge }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    public static func describe(_ url: URL) -> InstalledDictionary? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        var info: [String: Any] = [:]
        if let data = try? Data(contentsOf: plistURL),
           let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            info = obj
        }
        let bundleID = info["CFBundleIdentifier"] as? String ?? ""
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let isOurs = info["DictBridgeVersion"] != nil || bundleID.hasPrefix(DictBridge.bundleIdentifierPrefix)
        var created: Date?
        if let s = info["DictBridgeCreated"] as? String { created = ISO8601DateFormatter().date(from: s) }
        if created == nil { created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate }
        return InstalledDictionary(url: url, name: name, bundleIdentifier: bundleID, isDictBridge: isOurs,
                                   source: info["DictBridgeSource"] as? String, created: created)
    }

    /// Total size of a bundle in bytes (walks the folder; call off the main thread).
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Moves a freshly built bundle into `~/Library/Dictionaries`, sending any previous
    /// version with the same file name to the Trash.
    @discardableResult
    public static func install(bundleAt built: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(built.lastPathComponent, isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.trashItem(at: dest, resultingItemURL: nil)
        }
        try fm.moveItem(at: built, to: dest)
        return dest
    }

    /// Moves a dictionary to the Trash (recoverable).
    @discardableResult
    public static func remove(_ dictionary: InstalledDictionary) throws -> URL? {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: dictionary.url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    // MARK: Dictionary.app's list of enabled dictionaries

    private static let servicesDomain = "com.apple.DictionaryServices" as CFString
    private static let activeKey = "DCSActiveDictionaries" as CFString

    /// Adds dictionaries to / removes them from Dictionary.app's enabled list
    /// (`DCSActiveDictionaries` in the `com.apple.DictionaryServices` preferences).
    /// Quit Dictionary.app first, or it may write its own copy back when it quits.
    /// - Returns: a short description for the log.
    @discardableResult
    public static func setEnabled(_ enable: [InstalledDictionary], disable: [URL] = []) -> String {
        CFPreferencesAppSynchronize(servicesDomain)
        guard let current = CFPreferencesCopyAppValue(activeKey, servicesDomain) as? [String] else {
            return "Dictionary.app keeps no explicit list yet; leaving its defaults alone"
        }
        var list = current
        let disabledPaths = Set(disable.map { $0.standardizedFileURL.path })
        list.removeAll { disabledPaths.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) }
        // Entries are file paths on the macOS versions we know; fall back to identifiers if not.
        let usesIdentifiers = !list.isEmpty && !list.contains { $0.hasPrefix("/") }
        var added = 0
        for d in enable {
            let path = d.url.standardizedFileURL.path
            let token = usesIdentifiers ? d.bundleIdentifier : path
            let present = list.contains { $0 == path || $0 == d.bundleIdentifier
                || URL(fileURLWithPath: $0).standardizedFileURL.path == path }
            if !present && !token.isEmpty {
                list.append(token)
                added += 1
            }
        }
        guard list != current else { return "Dictionary.app list unchanged (\(list.count) enabled)" }
        CFPreferencesSetAppValue(activeKey, list as CFArray, servicesDomain)
        CFPreferencesAppSynchronize(servicesDomain)
        return "Dictionary.app: enabled \(added), \(list.count) now in its list (\(usesIdentifiers ? "identifiers" : "paths"))"
    }

    /// Whether Dictionary.app lists `dictionary` as enabled (nil if unknown).
    public static func isEnabled(_ dictionary: InstalledDictionary) -> Bool? {
        CFPreferencesAppSynchronize(servicesDomain)
        guard let list = CFPreferencesCopyAppValue(activeKey, servicesDomain) as? [String] else { return nil }
        let path = dictionary.url.standardizedFileURL.path
        return list.contains { $0 == path || $0 == dictionary.bundleIdentifier
            || URL(fileURLWithPath: $0).standardizedFileURL.path == path }
    }

    #if canImport(AppKit)
    /// Quits Dictionary.app, applies `change`, then reopens Dictionary.app if it was running
    /// (it only notices added or removed dictionaries when it starts).
    @discardableResult
    public static func updateDictionaryApp(reopen: Bool? = nil, _ change: () -> String = { "" }) async -> String {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: dictionaryAppBundleID)
        let wasRunning = !running.isEmpty
        for app in running { app.terminate() }
        for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let message = change()
        if reopen ?? wasRunning, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: dictionaryAppBundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        }
        return message
    }

    /// Restarts Dictionary.app so it picks up added or removed dictionaries.
    public static func restartDictionaryApp(reopen: Bool) async {
        await updateDictionaryApp(reopen: reopen)
    }

    public static var isDictionaryAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: dictionaryAppBundleID).isEmpty
    }
    #endif
}
