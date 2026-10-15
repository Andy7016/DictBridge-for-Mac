import Foundation

/// Streams the Dictionary Development Kit source XML (`<d:dictionary>` with one `<d:entry>`
/// per headword) to disk.
final class DDKSourceWriter {
    static let frontMatterID = "front_back_matter"

    static func entryID(_ index: Int) -> String { "e\(index)" }

    private let handle: FileHandle
    private var buffer = Data()
    private let flushThreshold = 8 << 20
    private(set) var bytesWritten = 0
    private(set) var entriesWritten = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        append("""
        <?xml version="1.0" encoding="UTF-8"?>
        <d:dictionary xmlns="http://www.w3.org/1999/xhtml" xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng">

        """)
    }

    private func append(_ s: String) {
        buffer.append(contentsOf: s.utf8)
        if buffer.count >= flushThreshold { flush() }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(buffer)
        bytesWritten += buffer.count
        buffer.removeAll(keepingCapacity: true)
    }

    /// Writes one entry. `searchKeys` are additional index values (inflections, redirects).
    func writeEntry(id: String, title: String, searchKeys: [String], body: String) {
        var s = "<d:entry id=\"" + Self.attr(id) + "\" d:title=\"" + Self.attr(title) + "\">"
        var seen = Set<String>()
        for key in [title] + searchKeys {
            let k = Self.indexValue(key)
            guard !k.isEmpty, seen.insert(k).inserted else { continue }
            s += "<d:index d:value=\"" + Self.attr(k) + "\" d:title=\"" + Self.attr(title) + "\"/>"
        }
        s += body
        s += "</d:entry>\n"
        append(s)
        entriesWritten += 1
    }

    /// Writes an entry that is reachable only by id (front/back matter).
    func writeFrontMatter(body: String) {
        append("<d:entry id=\"\(Self.frontMatterID)\" d:title=\"Front/Back Matter\">" + body + "</d:entry>\n")
    }

    func finish() throws {
        append("</d:dictionary>\n")
        flush()
        try handle.close()
    }

    /// Index values must be single-line and of reasonable length.
    static func indexValue(_ s: String) -> String {
        var v = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if v.utf8.count > 1000 { v = String(v.prefix(300)) }
        return v
    }

    static func attr(_ s: String) -> String {
        var out = ""
        HTMLTransformer.escapeAttribute(s, into: &out)
        return out
    }
}

/// Writes the `Info.plist` source the DDK merges into the dictionary bundle.
enum DictionaryPlist {
    static func write(to url: URL, displayName: String, bundleIdentifier: String, version: String,
                      copyright: String, sourceFile: String, frontMatter: Bool) throws {
        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "English",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleShortVersionString": version,
            "DCSDictionaryCopyright": copyright,
            "DCSDictionaryManufacturerName": "DictBridge",
            "DictBridgeVersion": DictBridge.version,
            "DictBridgeSource": sourceFile,
            "DictBridgeCreated": ISO8601DateFormatter().string(from: Date()),
        ]
        if frontMatter {
            plist["DCSDictionaryFrontMatterReferenceID"] = DDKSourceWriter.frontMatterID
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }
}
