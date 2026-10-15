import Foundation

/// RIPEMD-128, used by MDict to derive the key that scrambles the key-block index
/// (`Encrypted="2"`). Follows http://homes.esat.kuleuven.be/~bosselae/ripemd/rmd128.txt
public enum RIPEMD128 {
    private static let r: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
    ]
    private static let rp: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
    ]
    private static let s: [UInt32] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
    ]
    private static let sp: [UInt32] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
    ]

    @inline(__always)
    private static func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j {
        case 0..<16: return x ^ y ^ z
        case 16..<32: return (x & y) | (z & ~x)
        case 32..<48: return (x | ~y) ^ z
        default: return (x & z) | (y & ~z)
        }
    }

    @inline(__always)
    private static func k(_ j: Int) -> UInt32 {
        switch j {
        case 0..<16: return 0x0000_0000
        case 16..<32: return 0x5a82_7999
        case 32..<48: return 0x6ed9_eba1
        default: return 0x8f1b_bcdc
        }
    }

    @inline(__always)
    private static func kp(_ j: Int) -> UInt32 {
        switch j {
        case 0..<16: return 0x50a2_8be6
        case 16..<32: return 0x5c4d_d124
        case 32..<48: return 0x6d70_3ef3
        default: return 0x0000_0000
        }
    }

    @inline(__always)
    private static func rol(_ s: UInt32, _ x: UInt32) -> UInt32 {
        (x << s) | (x >> (32 - s))
    }

    /// Returns the 16-byte RIPEMD-128 digest of `message`.
    public static func hash(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x6745_2301
        var h1: UInt32 = 0xefcd_ab89
        var h2: UInt32 = 0x98ba_dcfe
        var h3: UInt32 = 0x1032_5476

        var msg = message
        let originalLength = message.count
        let padLength = 64 - ((((originalLength - 56) % 64) + 64) % 64)  // at least 1
        msg.append(0x80)
        msg.append(contentsOf: [UInt8](repeating: 0, count: padLength - 1))
        var bitLength = UInt64(originalLength) &* 8
        for _ in 0..<8 {
            msg.append(UInt8(truncatingIfNeeded: bitLength))
            bitLength >>= 8
        }

        var x = [UInt32](repeating: 0, count: 16)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for j in 0..<16 {
                let o = chunk + j * 4
                x[j] = UInt32(msg[o]) | UInt32(msg[o + 1]) << 8 | UInt32(msg[o + 2]) << 16 | UInt32(msg[o + 3]) << 24
            }
            var (a, b, c, d) = (h0, h1, h2, h3)
            var (ap, bp, cp, dp) = (h0, h1, h2, h3)
            for j in 0..<64 {
                var t = rol(s[j], a &+ f(j, b, c, d) &+ x[r[j]] &+ k(j))
                (a, d, c, b) = (d, c, b, t)
                t = rol(sp[j], ap &+ f(63 - j, bp, cp, dp) &+ x[rp[j]] &+ kp(j))
                (ap, dp, cp, bp) = (dp, cp, bp, t)
            }
            let t = h1 &+ c &+ dp
            h1 = h2 &+ d &+ ap
            h2 = h3 &+ a &+ bp
            h3 = h0 &+ b &+ cp
            h0 = t
        }

        var out = [UInt8]()
        out.reserveCapacity(16)
        for h in [h0, h1, h2, h3] {
            out.append(UInt8(truncatingIfNeeded: h))
            out.append(UInt8(truncatingIfNeeded: h >> 8))
            out.append(UInt8(truncatingIfNeeded: h >> 16))
            out.append(UInt8(truncatingIfNeeded: h >> 24))
        }
        return out
    }
}
