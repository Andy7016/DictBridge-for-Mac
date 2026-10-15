import CryptoKit
import XCTest
@testable import MDictKit

final class MDictKitTests: XCTestCase {

    private struct Expected: Decodable {
        struct FileInfo: Decodable { let size: Int; let sha256: String }
        let count: Int
        let entries: [String: String]?
        let title: String?
        let files: [String: FileInfo]?
    }

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("missing fixture \(name)")
        }
        return url
    }

    private func expected() throws -> [String: Expected] {
        let data = try Data(contentsOf: try fixture("expected.json"))
        return try JSONDecoder().decode([String: Expected].self, from: data)
    }

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    // MARK: RIPEMD-128

    func testRIPEMD128KnownVectors() {
        let vectors: [(String, String)] = [
            ("", "cdf26213a150dc3ecb610f18f6b38b46"),
            ("a", "86be7afa339d0fc7cfc785e72f578d33"),
            ("abc", "c14a12199c66e4ba84636b0f69144c77"),
            ("message digest", "9e327b3d6e523062afc1132d7df9d1b8"),
            ("The quick brown fox jumps over the lazy dog", "3fa9b57f053c053fbe2735b2380db596"),
            (String(repeating: "1234567890", count: 8), "3f45ef194732c2dbb2c4a2c769795fa3"),
            (String(repeating: "x", count: 56), "01b3ed3753c897abadee8a09b85760a6"),
            (String(repeating: "y", count: 64), "1df3c47a393761d61ecd6ea43bf15add"),
        ]
        for (message, digest) in vectors {
            XCTAssertEqual(hex(RIPEMD128.hash(Array(message.utf8))), digest, "RIPEMD-128(\(message.prefix(10)))")
        }
    }

    // MARK: LZO

    /// Builds a literal-only LZO1X stream (same scheme as scripts/make_fixtures.py).
    private func lzoLiteralStream(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        let n = data.count
        if n == 0 { return [0x11, 0, 0] }
        if n <= 238 {
            out.append(UInt8(17 + n))
        } else {
            let t = n - 3
            out.append(0)
            var rem = t - 15
            while rem > 255 { out.append(0); rem -= 255 }
            out.append(UInt8(rem))
        }
        out += data
        out += [0x11, 0, 0]
        return out
    }

    func testLZOLiteralStreams() throws {
        for n in [1, 3, 4, 5, 17, 238, 239, 270, 271, 1000, 5000] {
            let payload = (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            let decoded = try MDictCodec.lzo1xDecompress(lzoLiteralStream(payload), expectedSize: n)
            XCTAssertEqual(decoded, payload, "length \(n)")
        }
    }

    func testLZOWithBackReference() throws {
        // "abcd" as literals, then an M2 match (distance 4, length 4) copying "abcd" again, then EOF.
        // M2: t >= 64, length = (t >> 5) - 1 + 2, distance = ((t >> 2) & 7) + (next << 3) + 1.
        // t = (3 << 5) | (3 << 2) = 0x6C -> length 4, distance low bits 3 -> distance 4.
        let stream: [UInt8] = [17 + 4, 0x61, 0x62, 0x63, 0x64, 0x6C, 0x00, 0x11, 0x00, 0x00]
        let decoded = try MDictCodec.lzo1xDecompress(stream, expectedSize: 8)
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "abcdabcd")
    }

    // MARK: zlib

    func testInflateKnownAndUnknownSize() throws {
        // zlib.compress(b"hello hello hello hello")
        let z = Data([0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0x40, 0x27, 0x01, 0x68, 0x03, 0x08, 0xb1])
        let plain = "hello hello hello hello"
        XCTAssertEqual(String(decoding: try MDictCodec.inflate(z, expectedSize: plain.utf8.count), as: UTF8.self), plain)
        XCTAssertEqual(String(decoding: try MDictCodec.inflate(z, expectedSize: nil), as: UTF8.self), plain)
    }

    // MARK: MDX fixtures

    private func checkMDX(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let exp = try XCTUnwrap(try expected()[name], "no expectation for \(name)")
        let mdx = try MDictFile(url: try fixture(name))
        XCTAssertEqual(mdx.kind, .mdx)
        XCTAssertEqual(mdx.entryCount, exp.count, "\(name): entry count", file: file, line: line)
        if let title = exp.title {
            XCTAssertEqual(mdx.header.title, title, "\(name): title", file: file, line: line)
        }
        var seen: [String: String] = [:]
        var visited = 0
        try mdx.forEachRecord { _, key, record in
            visited += 1
            seen[key] = mdx.text(of: record)
            return true
        }
        XCTAssertEqual(visited, exp.count, "\(name): records visited", file: file, line: line)
        for (key, value) in exp.entries ?? [:] {
            XCTAssertEqual(seen[key], value, "\(name): record for \(key)", file: file, line: line)
        }
    }

    func testBasicMDX() throws { try checkMDX("basic.mdx") }
    func testEncryptedIndexMDX() throws {
        try checkMDX("encrypted.mdx")
        XCTAssertEqual(try MDictFile(url: try fixture("encrypted.mdx")).header.encrypted, 2)
    }
    func testUTF16MDX() throws { try checkMDX("utf16.mdx") }
    func testGBKMDX() throws { try checkMDX("gbk.mdx") }
    func testVersion12MDX() throws { try checkMDX("v12.mdx") }
    func testLZOMDX() throws { try checkMDX("lzo.mdx") }
    func testStoredMDX() throws { try checkMDX("stored.mdx") }
    func testMultiBlockMDX() throws { try checkMDX("multiblock.mdx") }

    func testHeaderDescriptionIsUnescaped() throws {
        let mdx = try MDictFile(url: try fixture("basic.mdx"))
        XCTAssertEqual(mdx.header.descriptionHTML, "<b>Synthetic</b> test dictionary &amp; fixture")
    }

    func testStopEarly() throws {
        let mdx = try MDictFile(url: try fixture("multiblock.mdx"))
        var n = 0
        try mdx.forEachRecord { _, _, _ in
            n += 1
            return n < 10
        }
        XCTAssertEqual(n, 10)
    }

    // MARK: MDD fixture

    func testMDDResources() throws {
        let exp = try XCTUnwrap(try expected()["basic.mdd"])
        let mdd = try MDictFile(url: try fixture("basic.mdd"))
        XCTAssertEqual(mdd.kind, .mdd)
        XCTAssertEqual(mdd.entryCount, exp.count)
        var found: [String: (Int, String)] = [:]
        try mdd.forEachRecord { _, key, data in
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            found[key] = (data.count, digest)
            return true
        }
        for (name, info) in exp.files ?? [:] {
            let got = try XCTUnwrap(found[name], "missing resource \(name)")
            XCTAssertEqual(got.0, info.size, name)
            XCTAssertEqual(got.1, info.sha256, name)
        }
    }

    func testRejectsNonMDictFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-dict-\(UUID().uuidString).mdx")
        try Data("hello world, definitely not mdict".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try MDictFile(url: tmp))
    }
}
