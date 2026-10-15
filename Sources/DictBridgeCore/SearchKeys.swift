import Foundation

/// Extra search keys so Dictionary.app finds entries the way MDict users expect.
///
/// MDict looks words up loosely (it ignores punctuation such as syllable dots); Dictionary.app
/// needs the exact key. So for every headword DictBridge adds:
/// - a form without syllable separators: `ap.ple` → `apple`, `beau·ti·ful` → `beautiful`;
/// - Simplified/Traditional Chinese counterparts: `蘋果` ↔ `苹果`.
public enum SearchKeys {
    /// Characters dictionaries use to mark syllables or stress inside a headword.
    static let syllableMarks: Set<Character> = [".", "·", "•", "‧", "∙", "ˈ", "ˌ"]
    static let stressMarks: Set<Character> = ["ˈ", "ˌ"]

    /// `ap.ple` → `apple`; nil when nothing changes. Marks are only removed between two
    /// letters (stress marks anywhere), so `e.g.` → `eg.` and `St. Louis` stays as it is.
    public static func withoutSyllableMarks(_ s: String) -> String? {
        guard s.contains(where: { syllableMarks.contains($0) }) else { return nil }
        let chars = Array(s)
        var out = ""
        for (i, c) in chars.enumerated() {
            if stressMarks.contains(c) { continue }
            if syllableMarks.contains(c) {
                let prevIsLetter = i > 0 && chars[i - 1].isLetter
                let nextIsLetter = i + 1 < chars.count && chars[i + 1].isLetter
                if prevIsLetter && nextIsLetter { continue }
            }
            out.append(c)
        }
        return out == s || out.isEmpty ? nil : out
    }

    /// True for headwords like `ap.ple` or `dic·tion·ar·y`: letters split by syllable marks only.
    public static func isSyllabified(_ s: String) -> Bool {
        var sawMark = false
        var sawLetter = false
        for c in s {
            if c.isLetter { sawLetter = true; continue }
            if syllableMarks.contains(c) { sawMark = true; continue }
            return false
        }
        return sawMark && sawLetter && s.first?.isLetter == true && s.last?.isLetter == true
    }

    /// Title to show in Dictionary.app's result list for `headword`.
    public static func displayTitle(for headword: String) -> String {
        if isSyllabified(headword), let clean = withoutSyllableMarks(headword) { return clean }
        return headword
    }

    /// Additional keys for `word` (not including `word` itself).
    public static func variants(of word: String, chinese: Bool = true) -> [String] {
        var result: [String] = []
        func add(_ s: String?) {
            guard let s, !s.isEmpty, s != word, !result.contains(s) else { return }
            result.append(s)
        }
        let plain = withoutSyllableMarks(word)
        add(plain)
        if chinese {
            for v in ChineseScript.variants(of: word) { add(v) }
            if let plain { for v in ChineseScript.variants(of: plain) { add(v) } }
        }
        return result
    }
}

/// Simplified ↔ Traditional Chinese, character by character (ICU transforms, built once).
public enum ChineseScript {
    static func isHan(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) || (0xF900...0xFAFF).contains(s.value)
    }

    private static let tables: (toSimplified: [UInt32: String], toTraditional: [UInt32: String]) = {
        var scalars: [Unicode.Scalar] = []
        for range in [0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF] {
            for v in range { if let s = Unicode.Scalar(v) { scalars.append(s) } }
        }
        let joined = scalars.map { String($0) }.joined(separator: "\n")
        func table(_ ids: [String]) -> [UInt32: String] {
            for id in ids {
                guard let out = joined.applyingTransform(StringTransform(rawValue: id), reverse: false) else { continue }
                let parts = out.components(separatedBy: "\n")
                guard parts.count == scalars.count else { continue }
                var map: [UInt32: String] = [:]
                for (s, p) in zip(scalars, parts) where p != String(s) && !p.isEmpty { map[s.value] = p }
                if !map.isEmpty { return map }
            }
            return [:]
        }
        return (table(["Traditional-Simplified", "Hant-Hans"]), table(["Simplified-Traditional", "Hans-Hant"]))
    }()

    /// Whether the system's ICU provides the conversion tables.
    public static var isAvailable: Bool { !tables.toSimplified.isEmpty }

    /// The simplified and traditional forms of `s` that differ from it.
    public static func variants(of s: String) -> [String] {
        guard s.unicodeScalars.contains(where: isHan) else { return [] }
        let t = tables
        var simplified = ""
        var traditional = ""
        for scalar in s.unicodeScalars {
            simplified += t.toSimplified[scalar.value] ?? String(scalar)
            traditional += t.toTraditional[scalar.value] ?? String(scalar)
        }
        var out: [String] = []
        if simplified != s { out.append(simplified) }
        if traditional != s && traditional != simplified { out.append(traditional) }
        return out
    }
}
