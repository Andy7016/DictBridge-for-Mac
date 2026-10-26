import Foundation

/// xxHash64 (seed 0 by default). MDict 3.0 derives a file's block key from its UUID with it.
enum XXHash64 {
    private static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }

    @inline(__always) private static func step(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }

    @inline(__always) private static func merge(_ acc: UInt64, _ value: UInt64) -> UInt64 {
        (acc ^ step(0, value)) &* p1 &+ p4
    }

    static func hash(_ b: [UInt8], seed: UInt64 = 0) -> UInt64 {
        let n = b.count
        func read64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(b[o + k]) << (8 * UInt64(k)) }
            return v
        }
        func read32(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<4 { v |= UInt64(b[o + k]) << (8 * UInt64(k)) }
            return v
        }
        var i = 0
        var h: UInt64
        if n >= 32 {
            var v1 = seed &+ p1 &+ p2
            var v2 = seed &+ p2
            var v3 = seed
            var v4 = seed &- p1
            while i + 32 <= n {
                v1 = step(v1, read64(i))
                v2 = step(v2, read64(i + 8))
                v3 = step(v3, read64(i + 16))
                v4 = step(v4, read64(i + 24))
                i += 32
            }
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = merge(h, v1)
            h = merge(h, v2)
            h = merge(h, v3)
            h = merge(h, v4)
        } else {
            h = seed &+ p5
        }
        h = h &+ UInt64(n)
        while i + 8 <= n {
            h ^= step(0, read64(i))
            h = rotl(h, 27) &* p1 &+ p4
            i += 8
        }
        if i + 4 <= n {
            h ^= read32(i) &* p1
            h = rotl(h, 23) &* p2 &+ p3
            i += 4
        }
        while i < n {
            h ^= UInt64(b[i]) &* p5
            h = rotl(h, 11) &* p1
            i += 1
        }
        h ^= h >> 33
        h = h &* p2
        h ^= h >> 29
        h = h &* p3
        h ^= h >> 32
        return h
    }

    /// The canonical (big-endian) 8-byte digest.
    static func digest(_ b: [UInt8]) -> [UInt8] {
        let h = hash(b)
        return (0..<8).map { UInt8(truncatingIfNeeded: h >> (56 - 8 * UInt64($0))) }
    }
}

/// Salsa20 stream cipher with a zero nonce, as MDict uses it (8 rounds, 128- or 256-bit key).
/// Encryption and decryption are the same operation.
enum Salsa20 {
    static func xor(_ data: [UInt8], key: [UInt8], rounds: Int = 8) -> [UInt8] {
        guard !data.isEmpty, key.count == 16 || key.count == 32 else { return data }
        let c: [UInt32] = key.count == 32
            ? [0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574]   // "expand 32-byte k"
            : [0x6170_7865, 0x3120_646E, 0x7962_2D36, 0x6B20_6574]   // "expand 16-byte k"
        func le32(_ o: Int) -> UInt32 {
            UInt32(key[o]) | UInt32(key[o + 1]) << 8 | UInt32(key[o + 2]) << 16 | UInt32(key[o + 3]) << 24
        }
        let k0 = (0..<4).map { le32($0 * 4) }
        let k1 = key.count == 32 ? (4..<8).map { le32($0 * 4) } : k0

        var out = data
        var counter: UInt64 = 0
        var pos = 0
        var x = [UInt32](repeating: 0, count: 16)
        @inline(__always) func rotl(_ v: UInt32, _ r: UInt32) -> UInt32 { (v << r) | (v >> (32 - r)) }
        while pos < data.count {
            let input: [UInt32] = [c[0], k0[0], k0[1], k0[2], k0[3], c[1], 0, 0,
                                   UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter >> 32),
                                   c[2], k1[0], k1[1], k1[2], k1[3], c[3]]
            x = input
            func qr(_ a: Int, _ b: Int, _ cc: Int, _ d: Int) {
                x[b] ^= rotl(x[a] &+ x[d], 7)
                x[cc] ^= rotl(x[b] &+ x[a], 9)
                x[d] ^= rotl(x[cc] &+ x[b], 13)
                x[a] ^= rotl(x[d] &+ x[cc], 18)
            }
            for _ in 0..<(rounds / 2) {
                qr(0, 4, 8, 12); qr(5, 9, 13, 1); qr(10, 14, 2, 6); qr(15, 3, 7, 11)  // columns
                qr(0, 1, 2, 3); qr(5, 6, 7, 4); qr(10, 11, 8, 9); qr(15, 12, 13, 14)  // rows
            }
            let n = min(64, data.count - pos)
            for j in 0..<n {
                let word = x[j / 4] &+ input[j / 4]
                out[pos + j] ^= UInt8(truncatingIfNeeded: word >> (8 * UInt32(j % 4)))
            }
            counter += 1
            pos += 64
        }
        return out
    }
}
