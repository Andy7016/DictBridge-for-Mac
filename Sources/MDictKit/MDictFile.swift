import Foundation

/// Parsed MDict header (`<Dictionary ... />` attributes).
public struct MDictHeader {
    public let attributes: [String: String]
    public let engineVersion: Double
    public let encodingName: String
    /// Bit 0: key header encrypted with a registration key; bit 1: key index scrambled.
    public let encrypted: Int
    /// Numbered style definitions used by "compact" dictionaries (`` `1` `` markers).
    public let styleSheet: [String: (begin: String, end: String)]

    public var title: String { attributes["Title"] ?? "" }
    public var descriptionHTML: String { attributes["Description"] ?? "" }
    public var creationDate: String { attributes["CreationDate"] ?? "" }

    /// Title, unless it is empty or the MdxBuilder placeholder.
    public var usableTitle: String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("Title (No HTML code allowed)") { return nil }
        return t
    }
}

/// One entry of the key index: the headword and the offset of its record in the
/// concatenated (decompressed) record data.
public struct MDictKey {
    public let text: String
    public let offset: Int
}

/// Reader for MDict `.mdx` (dictionary text) and `.mdd` (resources) files.
///
/// The file is memory-mapped; records are decoded block by block by `forEachRecord`.
public final class MDictFile {
    public enum Kind { case mdx, mdd }

    public let url: URL
    public let kind: Kind
    public let header: MDictHeader
    /// Keys ordered by record offset (the order records are stored in).
    public private(set) var keys: [MDictKey] = []

    private let data: Data
    private let numberWidth: Int
    private var textEncoding: String.Encoding
    private let isUTF16: Bool
    private var recordSectionOffset = 0
    /// Keys as raw bytes until the text encoding has been confirmed.
    private var rawKeys: [(offset: Int, bytes: [UInt8])] = []
    /// Encoding actually used for keys and records. Some dictionaries declare GBK/Big5
    /// in the header but store UTF-8; this records what was detected.
    public private(set) var effectiveEncodingName: String = ""
    /// End offset of each key's record (handles keys that share a record).
    private var recordEnds: [Int] = []

    public var entryCount: Int { keys.count }

    /// Encoding used for keys and `.mdx` records (after detection; see `effectiveEncodingName`).
    public var encoding: String.Encoding { textEncoding }

    public init(url: URL) throws {
        let kind: Kind = url.pathExtension.lowercased() == "mdd" ? .mdd : .mdx
        let fileData: Data
        do {
            fileData = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw MDictError.invalidFile("cannot open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        self.url = url
        self.kind = kind
        self.data = fileData

        var reader = ByteReader(fileData)
        let header = try MDictFile.readHeader(&reader, kind: kind)
        guard header.engineVersion < 3.0 else {
            throw MDictError.unsupported("MDict 3.0 format (engine \(header.engineVersion)) is not supported yet")
        }
        let (enc, utf16) = MDictFile.stringEncoding(named: header.encodingName)
        self.textEncoding = enc
        self.isUTF16 = utf16
        self.numberWidth = header.engineVersion < 2.0 ? 4 : 8
        self.header = header

        try readKeys(&reader)
    }

    // MARK: - Header helpers

    /// Reads only the header of an MDict file (cheap; does not touch the index).
    public static func header(of url: URL) throws -> MDictHeader {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw MDictError.invalidFile("cannot open \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        let sizeBytes = handle.readData(ofLength: 4)
        guard sizeBytes.count == 4 else { throw MDictError.invalidFile("file too short") }
        let size = sizeBytes.reduce(0) { $0 << 8 | Int($1) }
        guard size > 0, size < 64 << 20 else { throw MDictError.invalidFile("bad header length") }
        var reader = ByteReader(sizeBytes + handle.readData(ofLength: size + 4))
        let kind: Kind = url.pathExtension.lowercased() == "mdd" ? .mdd : .mdx
        return try readHeader(&reader, kind: kind)
    }

    static func readHeader(_ reader: inout ByteReader, kind: Kind) throws -> MDictHeader {
        let headerSize = Int(try reader.uint32BE())
        guard headerSize > 0, headerSize < 64 << 20 else { throw MDictError.invalidFile("bad header length") }
        let headerBytes = try reader.bytes(headerSize)
        _ = try reader.uint32LE()  // adler32 of the header

        guard var headerText = String(data: headerBytes, encoding: .utf16LittleEndian) else {
            throw MDictError.invalidFile("header is not UTF-16")
        }
        while headerText.hasSuffix("\0") { headerText.removeLast() }
        guard headerText.contains("<Dictionary") || headerText.contains("<Library_Data") else {
            throw MDictError.invalidFile("missing <Dictionary> header")
        }
        let attributes = parseAttributes(headerText)

        let version = Double(attributes["GeneratedByEngineVersion"] ?? "") ?? 2.0
        let encrypted: Int
        switch (attributes["Encrypted"] ?? "").lowercased() {
        case "", "no": encrypted = 0
        case "yes": encrypted = 1
        case let other: encrypted = Int(other) ?? 0
        }

        var styles: [String: (begin: String, end: String)] = [:]
        if let sheet = attributes["StyleSheet"], !sheet.isEmpty {
            let lines = sheet.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            var i = 0
            while i + 2 < lines.count {
                styles[lines[i].trimmingCharacters(in: .whitespaces)] = (lines[i + 1], lines[i + 2])
                i += 3
            }
        }

        let encodingName: String
        if kind == .mdd {
            encodingName = "UTF-16"
        } else {
            let declared = (attributes["Encoding"] ?? "").trimmingCharacters(in: .whitespaces)
            encodingName = declared.isEmpty ? "UTF-8" : declared
        }
        return MDictHeader(attributes: attributes, engineVersion: version,
                           encodingName: encodingName, encrypted: encrypted, styleSheet: styles)
    }

    static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: "(\\w+)=\"(.*?)\"", options: [.dotMatchesLineSeparators]) else {
            return result
        }
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1))
            let value = ns.substring(with: m.range(at: 2))
            if result[key] == nil { result[key] = unescapeEntities(value) }
        }
        return result
    }

    static func unescapeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var pieces: [String] = []
            var last = 0
            for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                pieces.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
                let isHex = m.range(at: 1).length > 0
                let digits = ns.substring(with: m.range(at: 2))
                if let v = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(v) {
                    pieces.append(String(Character(scalar)))
                } else {
                    pieces.append(ns.substring(with: m.range))
                }
                last = m.range.location + m.range.length
            }
            pieces.append(ns.substring(from: last))
            out = pieces.joined()
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Maps an MDict encoding name to a Foundation encoding.
    public static func stringEncoding(named name: String) -> (String.Encoding, isUTF16: Bool) {
        let n = name.uppercased().replacingOccurrences(of: "_", with: "-")
        switch n {
        case "UTF-8", "UTF8", "":
            return (.utf8, false)
        case "UTF-16", "UTF16", "UTF-16LE", "UNICODE":
            return (.utf16LittleEndian, true)
        case "GBK", "GB2312", "GB18030", "CP936":
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return (String.Encoding(rawValue: cf), false)
        case "BIG5", "BIG-5", "CP950":
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            return (String.Encoding(rawValue: cf), false)
        default:
            let cfe = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfe != kCFStringEncodingInvalidId {
                return (String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfe)), false)
            }
            return (.utf8, false)
        }
    }

    // MARK: - Key index

    private func readKeys(_ reader: inout ByteReader) throws {
        let headerStart = reader.position
        if header.encrypted & 1 != 0 {
            // The 5 header numbers are encrypted with a registration key we do not have.
            // Recover the index by locating the blocks structurally, like readmdict does.
            try readKeysWithoutHeader(&reader, headerStart: headerStart)
            return
        }
        do {
            try readKeysNormally(&reader)
        } catch {
            reader.seek(to: headerStart)
            try readKeysWithoutHeader(&reader, headerStart: headerStart)
        }
    }

    private func readKeysNormally(_ reader: inout ByteReader) throws {
        let v2 = header.engineVersion >= 2.0
        let headerBlock = try reader.bytes(v2 ? 40 : 16)
        if v2 { _ = try reader.uint32BE() }  // adler32 of the 5 numbers
        var hr = ByteReader(headerBlock)
        let numKeyBlocks = try hr.number(width: numberWidth)
        _ = try hr.number(width: numberWidth)  // number of entries
        let infoDecompressedSize = try v2 ? hr.number(width: numberWidth) : 0
        let infoSize = try hr.number(width: numberWidth)
        let keyBlocksSize = try hr.number(width: numberWidth)

        let infoRaw = try reader.bytes(infoSize)
        let infos = try decodeKeyBlockInfo(infoRaw, decompressedSize: infoDecompressedSize)
        guard infos.count == numKeyBlocks else {
            throw MDictError.corrupt("key block count mismatch (\(infos.count) vs \(numKeyBlocks))")
        }
        let blocks = try reader.bytes(keyBlocksSize)
        try decodeKeyBlocks(blocks, infos: infos)
        recordSectionOffset = reader.position
        finishKeys()
    }

    private func readKeysWithoutHeader(_ reader: inout ByteReader, headerStart: Int) throws {
        let v2 = header.engineVersion >= 2.0
        reader.seek(to: headerStart)
        try reader.skip(v2 ? 44 : 16)
        let infoStart = reader.position
        let marker: [UInt8] = v2 ? [2, 0, 0, 0] : [1, 0, 0, 0]
        // The key-block info is followed directly by the first key block, which starts
        // with its compression type. Try each candidate boundary until one decodes.
        var searchFrom = infoStart + 8
        let bytes = data
        let limit = min(data.count - 4, infoStart + (256 << 20))
        while searchFrom < limit {
            guard let candidate = MDictFile.find(marker, in: bytes, from: searchFrom, limit: limit) else { break }
            searchFrom = candidate + 1
            let infoRaw = bytes.subdata(in: (bytes.startIndex + infoStart)..<(bytes.startIndex + candidate))
            guard let infos = try? decodeKeyBlockInfo(infoRaw, decompressedSize: 0), !infos.isEmpty else { continue }
            let total = infos.reduce(0) { $0 + $1.compressed }
            guard candidate + total <= data.count else { continue }
            let blocks = bytes.subdata(in: (bytes.startIndex + candidate)..<(bytes.startIndex + candidate + total))
            rawKeys.removeAll()
            do {
                try decodeKeyBlocks(blocks, infos: infos)
            } catch { continue }
            recordSectionOffset = candidate + total
            finishKeys()
            return
        }
        throw MDictError.unsupported("this dictionary's index is encrypted with a registration key")
    }

    /// Finds the next 4-byte `needle` at or after `from`, starting no later than `limit`.
    private static func find(_ needle: [UInt8], in data: Data, from: Int, limit: Int) -> Int? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            var i = max(0, from)
            let last = min(limit, raw.count - 4)
            while i <= last {
                if raw[i] == needle[0] && raw[i + 1] == needle[1] && raw[i + 2] == needle[2] && raw[i + 3] == needle[3] {
                    return i
                }
                i += 1
            }
            return nil
        }
    }

    private func decodeKeyBlockInfo(_ raw: Data, decompressedSize: Int) throws -> [(compressed: Int, decompressed: Int)] {
        let v2 = header.engineVersion >= 2.0
        var info: [UInt8]
        if v2 {
            var bytes = [UInt8](raw)
            guard bytes.count >= 8, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0, bytes[0] == 0 || bytes[0] == 2 else {
                throw MDictError.corrupt("unexpected key-index compression")
            }
            if header.encrypted & 2 != 0 {
                bytes = MDictCodec.decryptKeyBlockInfo(bytes)
            }
            if bytes[0] == 2 {
                info = [UInt8](try MDictCodec.inflate(Data(bytes[8...]), expectedSize: decompressedSize > 0 ? decompressedSize : nil))
            } else {
                info = Array(bytes[8...])
            }
        } else {
            info = [UInt8](raw)
        }

        let sizeWidth = v2 ? 2 : 1
        let terminator = v2 ? 1 : 0
        var result: [(compressed: Int, decompressed: Int)] = []
        var p = 0
        while p < info.count {
            _ = try Bytes.readBE(info, &p, width: numberWidth)  // entries in this block
            let headSize = try Bytes.readBE(info, &p, width: sizeWidth)
            p += isUTF16 ? (headSize + terminator) * 2 : headSize + terminator
            let tailSize = try Bytes.readBE(info, &p, width: sizeWidth)
            p += isUTF16 ? (tailSize + terminator) * 2 : tailSize + terminator
            let compressed = try Bytes.readBE(info, &p, width: numberWidth)
            let decompressed = try Bytes.readBE(info, &p, width: numberWidth)
            guard p <= info.count else { throw MDictError.corrupt("truncated key-index") }
            result.append((compressed, decompressed))
        }
        return result
    }

    private func decodeKeyBlocks(_ blocks: Data, infos: [(compressed: Int, decompressed: Int)]) throws {
        var position = 0
        for (compressed, decompressed) in infos {
            guard position + compressed <= blocks.count else { throw MDictError.corrupt("key block overrun") }
            let s = blocks.startIndex + position
            let block = blocks.subdata(in: s..<(s + compressed))
            let decoded = try MDictCodec.decodeBlock(block, decompressedSize: decompressed)
            try splitKeyBlock([UInt8](decoded))
            position += compressed
        }
    }

    private func splitKeyBlock(_ b: [UInt8]) throws {
        var i = 0
        let unit = isUTF16 ? 2 : 1
        while i < b.count {
            var p = i
            let offset = try Bytes.readBE(b, &p, width: numberWidth)
            var end = b.count
            var j = p
            if isUTF16 {
                while j + 1 < b.count {
                    if b[j] == 0 && b[j + 1] == 0 { end = j; break }
                    j += 2
                }
            } else {
                while j < b.count {
                    if b[j] == 0 { end = j; break }
                    j += 1
                }
            }
            rawKeys.append((offset, Array(b[p..<end])))
            i = end + unit
        }
    }

    private func finishKeys() {
        detectEncoding()
        keys = rawKeys.map { MDictKey(text: decode($0.bytes).trimmingCharacters(in: .whitespacesAndNewlines), offset: $0.offset) }
        rawKeys = []
        // Records are stored in offset order; keep keys in that order (stable for ties).
        let sorted = keys.enumerated().sorted { a, b in
            a.element.offset == b.element.offset ? a.offset < b.offset : a.element.offset < b.element.offset
        }.map { $0.element }
        keys = sorted
        // The record of key i ends at the next *larger* offset.
        var ends = [Int](repeating: Int.max, count: keys.count)
        var nextLarger = Int.max
        var i = keys.count - 1
        while i >= 0 {
            ends[i] = nextLarger
            if i > 0 && keys[i - 1].offset != keys[i].offset {
                nextLarger = keys[i].offset
            }
            i -= 1
        }
        recordEnds = ends
    }

    /// Many older dictionaries declare GBK or Big5 but actually contain UTF-8. If a sample of
    /// non-ASCII keys plus the first record block is valid UTF-8, trust that instead.
    private func detectEncoding() {
        effectiveEncodingName = header.encodingName
        guard !isUTF16, textEncoding != .utf8 else { return }
        var sample: [UInt8] = []
        for key in rawKeys where key.bytes.contains(where: { $0 >= 0x80 }) {
            sample += key.bytes
            sample.append(0x0A)
            if sample.count > 256 * 1024 { break }
        }
        if let block = try? firstRecordBlock() { sample += MDictFile.dropPartialUTF8(Array(block.prefix(1 << 20))) }
        guard sample.contains(where: { $0 >= 0x80 }) else { return }
        if String(bytes: sample, encoding: .utf8) != nil {
            textEncoding = .utf8
            effectiveEncodingName = "UTF-8 (header says \(header.encodingName))"
        }
    }

    /// Removes a multi-byte UTF-8 sequence cut off at the end of `b` (from taking a prefix).
    static func dropPartialUTF8(_ b: [UInt8]) -> [UInt8] {
        var k = b.count - 1
        var continuation = 0
        while k >= 0 && continuation < 3 && (b[k] & 0xC0) == 0x80 {
            k -= 1
            continuation += 1
        }
        guard k >= 0, b[k] >= 0xC0 else { return b }
        let needed = b[k] >= 0xF0 ? 4 : (b[k] >= 0xE0 ? 3 : 2)
        return b.count - k < needed ? Array(b[..<k]) : b
    }

    /// Decompressed bytes of the first record block (used for encoding detection).
    private func firstRecordBlock() throws -> [UInt8] {
        var reader = ByteReader(data, at: recordSectionOffset)
        let blockCount = try reader.number(width: numberWidth)
        guard blockCount > 0 else { return [] }
        _ = try reader.number(width: numberWidth)
        _ = try reader.number(width: numberWidth)
        _ = try reader.number(width: numberWidth)
        let firstCompressed = try reader.number(width: numberWidth)
        let firstDecompressed = try reader.number(width: numberWidth)
        try reader.skip((blockCount - 1) * numberWidth * 2)
        let raw = try reader.bytes(firstCompressed)
        return [UInt8](try MDictCodec.decodeBlock(raw, decompressedSize: firstDecompressed))
    }

    private func decode(_ bytes: [UInt8]) -> String {
        if let s = String(bytes: bytes, encoding: textEncoding) { return s }
        if textEncoding == .utf8 { return String(decoding: bytes, as: UTF8.self) }
        return (NSString(data: Data(bytes), encoding: textEncoding.rawValue) as String?) ?? String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Records

    /// Calls `body` for every record in storage order. Return `false` from `body` to stop.
    public func forEachRecord(_ body: (_ index: Int, _ key: String, _ record: Data) throws -> Bool) throws {
        var reader = ByteReader(data, at: recordSectionOffset)
        let blockCount = try reader.number(width: numberWidth)
        _ = try reader.number(width: numberWidth)  // number of entries
        _ = try reader.number(width: numberWidth)  // record block info size
        _ = try reader.number(width: numberWidth)  // record blocks size
        var infos: [(compressed: Int, decompressed: Int)] = []
        infos.reserveCapacity(blockCount)
        for _ in 0..<blockCount {
            let c = try reader.number(width: numberWidth)
            let d = try reader.number(width: numberWidth)
            infos.append((c, d))
        }

        var blockStart = 0  // offset of the current block in the concatenated record data
        var i = 0
        for (compressed, decompressed) in infos {
            let raw = try reader.bytes(compressed)
            let block = try MDictCodec.decodeBlock(raw, decompressedSize: decompressed)
            let blockEnd = blockStart + block.count
            while i < keys.count {
                let start = keys[i].offset
                if start >= blockEnd { break }
                let end = min(recordEnds[i], blockEnd)
                let s = start - blockStart
                let e = end - blockStart
                guard s >= 0, e >= s else { throw MDictError.corrupt("record offsets out of order") }
                let record = block.subdata(in: (block.startIndex + s)..<(block.startIndex + e))
                if try !body(i, keys[i].text, record) { return }
                i += 1
            }
            blockStart = blockEnd
        }
    }

    /// Decodes an `.mdx` record into text (strips the trailing NUL, applies the header style sheet).
    public func text(of record: Data) -> String {
        var bytes = [UInt8](record)
        if isUTF16 {
            while bytes.count >= 2 && bytes[bytes.count - 1] == 0 && bytes[bytes.count - 2] == 0 {
                bytes.removeLast(2)
            }
        } else {
            while let last = bytes.last, last == 0 { bytes.removeLast() }
        }
        let text = decode(bytes)
        return header.styleSheet.isEmpty ? text : applyStyleSheet(text)
    }

    private func applyStyleSheet(_ text: String) -> String {
        guard text.contains("`"), let regex = try? NSRegularExpression(pattern: "`(\\d+)`") else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ns.substring(to: matches[0].range.location)
        for (n, m) in matches.enumerated() {
            let number = ns.substring(with: m.range(at: 1))
            let segStart = m.range.location + m.range.length
            let segEnd = n + 1 < matches.count ? matches[n + 1].range.location : ns.length
            let segment = ns.substring(with: NSRange(location: segStart, length: segEnd - segStart))
            let style = header.styleSheet[number] ?? ("", "")
            if segment.hasSuffix("\n") {
                out += style.begin + segment.trimmingCharacters(in: .whitespacesAndNewlines) + style.end + "\r\n"
            } else {
                out += style.begin + segment + style.end
            }
        }
        return out
    }
}
