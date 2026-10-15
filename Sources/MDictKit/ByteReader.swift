import Foundation

/// Sequential big/little-endian reader over a `Data` value.
/// Offsets are always relative to the start of the data, whatever its `startIndex`.
struct ByteReader {
    let data: Data
    private(set) var position: Int

    init(_ data: Data, at position: Int = 0) {
        self.data = data
        self.position = position
    }

    var remaining: Int { data.count - position }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, position + count <= data.count else {
            throw MDictError.invalidFile("unexpected end of data (wanted \(count) bytes at \(position), have \(remaining))")
        }
        let start = data.startIndex + position
        let result = data.subdata(in: start..<(start + count))
        position += count
        return result
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, position + count <= data.count else {
            throw MDictError.invalidFile("unexpected end of data while skipping \(count) bytes")
        }
        position += count
    }

    mutating func seek(to offset: Int) {
        position = offset
    }

    mutating func uint32BE() throws -> UInt32 {
        UInt32(try unsignedBE(width: 4))
    }

    mutating func uint32LE() throws -> UInt32 {
        let b = try bytes(4)
        return b.withUnsafeBytes { raw -> UInt32 in
            var v: UInt32 = 0
            for i in (0..<4).reversed() { v = v << 8 | UInt32(raw[i]) }
            return v
        }
    }

    /// Reads a big-endian unsigned integer of `width` bytes (1...8).
    mutating func unsignedBE(width: Int) throws -> UInt64 {
        guard position + width <= data.count else {
            throw MDictError.invalidFile("unexpected end of data reading a \(width)-byte number")
        }
        var v: UInt64 = 0
        let base = data.startIndex + position
        for i in 0..<width { v = v << 8 | UInt64(data[base + i]) }
        position += width
        return v
    }

    /// Reads an MDict "number" (4 bytes before engine 2.0, 8 bytes afterwards) as Int.
    mutating func number(width: Int) throws -> Int {
        let v = try unsignedBE(width: width)
        guard v <= UInt64(Int.max) else { throw MDictError.corrupt("number out of range") }
        return Int(v)
    }
}

/// Helpers for reading big-endian numbers out of byte arrays.
enum Bytes {
    static func readBE(_ b: [UInt8], _ pos: inout Int, width: Int) throws -> Int {
        guard pos >= 0, pos + width <= b.count else {
            throw MDictError.corrupt("truncated block (number at \(pos))")
        }
        var v: UInt64 = 0
        for i in 0..<width { v = v << 8 | UInt64(b[pos + i]) }
        pos += width
        guard v <= UInt64(Int.max) else { throw MDictError.corrupt("number out of range") }
        return Int(v)
    }
}
