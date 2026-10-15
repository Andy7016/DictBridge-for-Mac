import Foundation
import Compression

/// Block decoding helpers: zlib, LZO1X and MDict's index scrambling.
public enum MDictCodec {

    // MARK: zlib

    /// Inflates a zlib stream (2-byte header + deflate + adler32).
    /// - Parameter expectedSize: decompressed size if known; enables a single-shot decode.
    public static func inflate(_ input: Data, expectedSize: Int?) throws -> Data {
        guard input.count >= 2 else { throw MDictError.corrupt("zlib block too short") }
        let cmf = input[input.startIndex]
        let flg = input[input.startIndex + 1]
        guard cmf & 0x0f == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else {
            throw MDictError.corrupt("bad zlib header")
        }
        let body = input.subdata(in: (input.startIndex + 2)..<input.endIndex)

        if let size = expectedSize {
            if size == 0 { return Data() }
            var out = Data(count: size)
            let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                body.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                    guard let s = src.baseAddress, let d = dst.baseAddress else { return 0 }
                    return compression_decode_buffer(
                        d.assumingMemoryBound(to: UInt8.self), size,
                        s.assumingMemoryBound(to: UInt8.self), src.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            if written == size { return out }
            // Size header was wrong or stream is odd: fall back to streaming decode.
        }
        return try inflateStream(body)
    }

    /// Streaming raw-deflate decode for when the output size is unknown.
    private static func inflateStream(_ body: Data) throws -> Data {
        let chunk = 1 << 16
        var output = Data()
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dstBuffer.deallocate() }

        var stream = compression_stream(dst_ptr: dstBuffer, dst_size: 0, src_ptr: dstBuffer, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw MDictError.corrupt("cannot initialise zlib decoder")
        }
        defer { compression_stream_destroy(&stream) }

        try body.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let base = src.baseAddress else { return }
            stream.src_ptr = base.assumingMemoryBound(to: UInt8.self)
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dstBuffer
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                if produced > 0 { output.append(dstBuffer, count: produced) }
                switch status {
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.src_size == 0 { return }
                    continue
                case COMPRESSION_STATUS_END:
                    return
                default:
                    throw MDictError.corrupt("zlib data error")
                }
            }
        }
        return output
    }

    // MARK: LZO1X (MDict engine 1.x)

    /// LZO1X decompressor, ported from the pure-Python implementation in mdict-utils.
    public static func lzo1xDecompress(_ input: [UInt8], expectedSize: Int) throws -> [UInt8] {
        enum State { case topLoop, firstLiteralRun, match, copyMatch, matchDone, matchNext }
        var out = [UInt8]()
        out.reserveCapacity(max(expectedSize, 16))
        guard !input.isEmpty else { return out }

        var ip = 0
        func byte(_ i: Int) throws -> Int {
            guard i >= 0, i < input.count else { throw MDictError.corrupt("LZO input overrun") }
            return Int(input[i])
        }
        func literals(_ n: Int) throws {
            guard n >= 0, ip + n <= input.count else { throw MDictError.corrupt("LZO literal overrun") }
            out.append(contentsOf: input[ip..<(ip + n)])
            ip += n
        }
        func copyMatch(from pos: Int, count n: Int) throws {
            guard pos >= 0, pos < out.count else { throw MDictError.corrupt("LZO match out of range") }
            var p = pos
            for _ in 0..<n {
                out.append(out[p])
                p += 1
            }
        }

        var t = try byte(0)
        var state = State.topLoop
        var mPos = 0

        if t > 17 {
            ip += 1
            t -= 17
            if t < 4 {
                state = .matchNext
            } else {
                try literals(t)
                state = .firstLiteralRun
            }
        }

        loop: while true {
            var didCopy = false

            if state == .topLoop {
                t = try byte(ip); ip += 1
                if t >= 16 { state = .match; continue loop }
                if t == 0 {
                    while try byte(ip) == 0 { t += 255; ip += 1 }
                    t += try 15 + (byte(ip)); ip += 1
                }
                try literals(t + 3)
                state = .firstLiteralRun
            }

            if state == .firstLiteralRun {
                t = try byte(ip); ip += 1
                if t >= 16 { state = .match; continue loop }
                mPos = try out.count - 0x801 - (t >> 2) - ((byte(ip)) << 2); ip += 1
                try copyMatch(from: mPos, count: 3)
                state = .matchDone
                continue loop
            }

            if state == .match {
                if t >= 64 {
                    mPos = try out.count - 1 - ((t >> 2) & 7) - ((byte(ip)) << 3); ip += 1
                    t = (t >> 5) - 1
                    state = .copyMatch
                    continue loop
                } else if t >= 32 {
                    t &= 31
                    if t == 0 {
                        while try byte(ip) == 0 { t += 255; ip += 1 }
                        t += try 31 + (byte(ip)); ip += 1
                    }
                    mPos = try out.count - 1 - (((byte(ip)) + ((byte(ip + 1)) << 8)) >> 2); ip += 2
                } else if t >= 16 {
                    mPos = out.count - ((t & 8) << 11)
                    t &= 7
                    if t == 0 {
                        while try byte(ip) == 0 { t += 255; ip += 1 }
                        t += try 7 + (byte(ip)); ip += 1
                    }
                    mPos -= try ((byte(ip)) + ((byte(ip + 1)) << 8)) >> 2; ip += 2
                    if mPos == out.count { break loop }  // end-of-stream marker
                    mPos -= 0x4000
                } else {
                    mPos = try out.count - 1 - (t >> 2) - ((byte(ip)) << 2); ip += 1
                    try copyMatch(from: mPos, count: 2)
                    state = .matchDone
                    continue loop
                }
                if t >= 6 && (out.count - mPos) >= 4 {
                    didCopy = true
                    try copyMatch(from: mPos, count: t + 2)
                }
                state = .copyMatch
            }

            if state == .copyMatch {
                if !didCopy { try copyMatch(from: mPos, count: t + 2) }
                state = .matchDone
            }

            if state == .matchDone {
                t = try (byte(ip - 2)) & 3
                if t == 0 { state = .topLoop; continue loop }
                state = .matchNext
            }

            if state == .matchNext {
                try literals(t)
                t = try byte(ip); ip += 1
                state = .match
                continue loop
            }
        }
        return out
    }

    // MARK: MDict block container

    /// Decodes one MDict block: 4-byte compression type, 4-byte adler32, payload.
    static func decodeBlock(_ block: Data, decompressedSize: Int) throws -> Data {
        guard block.count >= 8 else { throw MDictError.corrupt("block shorter than its header") }
        let s = block.startIndex
        let type = block[s]
        guard block[s + 1] == 0, block[s + 2] == 0, block[s + 3] == 0 else {
            throw MDictError.unsupported("unknown block compression type")
        }
        let payload = block.subdata(in: (s + 8)..<block.endIndex)
        switch type {
        case 0:
            return payload
        case 1:
            return Data(try lzo1xDecompress([UInt8](payload), expectedSize: decompressedSize))
        case 2:
            return try inflate(payload, expectedSize: decompressedSize)
        default:
            throw MDictError.unsupported("block compression type \(type)")
        }
    }

    // MARK: Index scrambling (Encrypted & 2)

    /// MDict's simple byte scrambler used for the key-block index.
    public static func fastDecrypt(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        guard !key.isEmpty else { return data }
        var b = data
        var previous: UInt8 = 0x36
        for i in 0..<b.count {
            var t: UInt8 = (b[i] >> 4) | (b[i] << 4)
            t = t ^ previous ^ UInt8(truncatingIfNeeded: i) ^ key[i % key.count]
            previous = b[i]
            b[i] = t
        }
        return b
    }

    /// Decrypts a key-block-info block whose first 8 bytes are the (plain) block header.
    static func decryptKeyBlockInfo(_ block: [UInt8]) -> [UInt8] {
        guard block.count > 8 else { return block }
        let key = RIPEMD128.hash(Array(block[4..<8]) + [0x95, 0x36, 0x00, 0x00])
        return Array(block[0..<8]) + fastDecrypt(Array(block[8...]), key: key)
    }
}
