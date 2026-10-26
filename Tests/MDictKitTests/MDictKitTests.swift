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

    // MARK: MDict 3.0 ciphers

    func testXXHash64Vectors() {
        let vectors: [([UInt8], String)] = [
            (Array("".utf8), "ef46db3751d8e999"),
            (Array("a".utf8), "d24ec4f1a98c6e5b"),
            (Array("abc".utf8), "44bc2cf5ad770999"),
            (Array("0123456789abcdef0123456789abcdef".utf8), "642a94958e71e6c5"),
            (Array("The quick brown fox jumps over the lazy dog".utf8), "0b242d361fda71bc"),
            ((0..<768).map { UInt8($0 & 0xFF) }, "8e03c838c596036f"),
        ]
        for (input, digest) in vectors {
            XCTAssertEqual(hex(XXHash64.digest(input)), digest, "\(input.count) bytes")
        }
    }

    func testSalsa20Vectors() {
        let key16 = (0..<16).map { UInt8($0) }
        let stream = Salsa20.xor([UInt8](repeating: 0, count: 150), key: key16, rounds: 8)
        XCTAssertEqual(hex(Array(stream[0..<64])), "b944f975fa4f57828cd395ec502244c7ec8cc5c03b0855362712093a0f3e4d7fad253a30ae26c6a4d5533581684e4c9299f95b4a04d0e0fb045eecad98b9bed9")
        XCTAssertEqual(hex(Array(stream[128..<150])), "20deaaaccf69ebb3e2f4817c2856667e8a9ecec45e5f")
        let key32 = (0..<32).map { UInt8($0) }
        let stream32 = Salsa20.xor([UInt8](repeating: 0, count: 64), key: key32, rounds: 8)
        XCTAssertEqual(hex(stream32), "ba3fb682eb86d3672981d4d7c39ba93a66b78d1d867a8ef6bd9523c8ca39cae47a0cdf6118afbaf8cd60d5f1626967216aa433df22a7be576c80df29197ccd0f")
        // Decryption is the same operation.
        let plain = Array("MDict 3.0 record block".utf8)
        XCTAssertEqual(Salsa20.xor(Salsa20.xor(plain, key: key16), key: key16), plain)
    }

    func testV3BlockKeyFromUUID() {
        let key = MDictFile.blockKey(uuid: "5c3f1a2e-8d4b-4c7a-9e61-0b2d3f4a5c6d")
        XCTAssertEqual(key.map(hex), "ab31853ff32df811f01e455e18c4f7d8")
        XCTAssertNil(MDictFile.blockKey(uuid: nil))
        XCTAssertNil(MDictFile.blockKey(uuid: ""))
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

    func testMDictV3MDX() throws {
        try checkMDX("v3.mdx")
        let mdx = try MDictFile(url: try fixture("v3.mdx"))
        XCTAssertEqual(mdx.header.engineVersion, 3.0)
        XCTAssertEqual(mdx.header.descriptionHTML, "<b>Synthetic</b> 3.0 fixture")
        XCTAssertTrue(mdx.keys.contains { $0.text == "蘋果" })
    }

    /// UUID-keyed file: Salsa20 key blocks, mixed fast/Salsa20/stored record blocks, sections in reverse order.
    func testMDictV3EncryptedMDX() throws {
        try checkMDX("v3-encrypted.mdx")
        XCTAssertEqual(try MDictFile(url: try fixture("v3-encrypted.mdx")).header.engineVersion, 3.0)
    }

    func testMislabeledEncodingIsDetected() throws {
        try checkMDX("mislabeled.mdx")
        let mdx = try MDictFile(url: try fixture("mislabeled.mdx"))
        XCTAssertEqual(mdx.header.encodingName, "BIG5")
        XCTAssertTrue(mdx.effectiveEncodingName.hasPrefix("UTF-8"), mdx.effectiveEncodingName)
        XCTAssertTrue(mdx.keys.contains { $0.text == "蘋果" })
    }

    func testPartialUTF8IsTrimmed() {
        let apple = Array("蘋果".utf8)  // two 3-byte sequences
        XCTAssertEqual(MDictFile.dropPartialUTF8(apple), apple)
        XCTAssertEqual(MDictFile.dropPartialUTF8(Array(apple.prefix(5))), Array(apple.prefix(3)))
        XCTAssertEqual(MDictFile.dropPartialUTF8(Array(apple.prefix(4))), Array(apple.prefix(3)))
        XCTAssertEqual(MDictFile.dropPartialUTF8(Array("ab".utf8)), Array("ab".utf8))
        XCTAssertEqual(MDictFile.dropPartialUTF8([]), [])
    }

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

    func testMDDResources() throws { try checkMDD("basic.mdd") }
    func testMDictV3MDD() throws { try checkMDD("v3.mdd") }

    private func checkMDD(_ name: String) throws {
        let exp = try XCTUnwrap(try expected()[name])
        let mdd = try MDictFile(url: try fixture(name))
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
        if exp.files == nil {
            XCTFail("\(name): no file expectations")
        }
    }

    func testRejectsNonMDictFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-dict-\(UUID().uuidString).mdx")
        try Data("hello world, definitely not mdict".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try MDictFile(url: tmp))
    }
}
