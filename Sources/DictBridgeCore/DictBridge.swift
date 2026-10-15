import Foundation

/// Project-wide constants.
public enum DictBridge {
    public static let version = "0.3.0"
    public static let bundleIdentifierPrefix = "org.dictbridge.dict."

    /// `~/Library/Application Support/DictBridge`
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DictBridge", isDirectory: true)
    }

    /// `~/Library/Caches/DictBridge` – build working directories live here.
    public static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("DictBridge", isDirectory: true)
    }
}

/// Turns arbitrary names into safe file names / bundle-identifier components.
public enum Slug {
    /// ASCII letters, digits and `-`; empty if nothing usable remains.
    public static func make(_ s: String) -> String {
        var out = ""
        var lastDash = false
        for scalar in s.unicodeScalars {
            let isAlnum = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9")
            if isAlnum {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out += "-"
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(60))
    }

    /// Stable short hash for names without usable ASCII.
    public static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// File name (without extension) for a dictionary bundle. Non-Latin names are
    /// transliterated (`新牛津英汉双解大词典` → `xin-niu-jin-ying-han-shuang-jie-da-ci-dian`).
    public static func bundleName(for source: String) -> String {
        var latin = source
        if source.unicodeScalars.contains(where: { $0.value > 0x7F }) {
            latin = source.applyingTransform(.toLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false) ?? source
        }
        let s = make(latin)
        if s.count >= 3 { return s }
        return (s.isEmpty ? "Dictionary" : s) + "-" + String(hash(source).prefix(8))
    }
}
