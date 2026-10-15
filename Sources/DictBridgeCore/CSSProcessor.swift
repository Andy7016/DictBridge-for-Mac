import Foundation

/// Adapts dictionary style sheets to the converted XHTML.
///
/// The HTML parser lower-cases element names (`<EN>` → `<en>`), but CSS type selectors are
/// case-sensitive in XHTML, so selectors such as `EXAMPLE{…}` are lower-cased to match.
/// `url(...)` references are rewritten to bundle-relative paths.
public enum CSSProcessor {

    /// Extra rules appended to every converted dictionary.
    public static let additions = """

    /* ---- added by DictBridge ---- */
    a.dictbridge-click { color: inherit; text-decoration: inherit; cursor: pointer; }
    a.dictbridge-sound { cursor: pointer; }
    .dictbridge-headword { font-size: 150%; font-weight: bold; margin: 0 0 0.4em 0; }
    """

    public static func process(_ css: String) -> String {
        let s = Array(stripComments(css).unicodeScalars)
        var out = String.UnicodeScalarView()
        var prelude = String.UnicodeScalarView()
        // true: block contains rules (top level, @media...); false: declarations
        var stack: [Bool] = []
        var quote: Unicode.Scalar?
        var i = 0

        func inRules() -> Bool { stack.last ?? true }

        while i < s.count {
            let c = s[i]
            i += 1
            if let q = quote {
                if inRules() { prelude.append(c) } else { out.append(c) }
                if c == "\\" && i < s.count {
                    if inRules() { prelude.append(s[i]) } else { out.append(s[i]) }
                    i += 1
                } else if c == q {
                    quote = nil
                }
                continue
            }
            if c == "\"" || c == "'" {
                quote = c
                if inRules() { prelude.append(c) } else { out.append(c) }
                continue
            }
            if inRules() {
                switch c {
                case "{":
                    let p = String(prelude)
                    let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("@") {
                        let keyword = trimmed.dropFirst().prefix { $0.isLetter || $0 == "-" }.lowercased()
                        out.append(contentsOf: p.unicodeScalars)
                        out.append("{")
                        stack.append(["media", "supports", "document", "layer", "container", "-moz-document"].contains(keyword))
                    } else {
                        out.append(contentsOf: lowercaseTypeSelectors(p).unicodeScalars)
                        out.append("{")
                        stack.append(false)
                    }
                    prelude = String.UnicodeScalarView()
                case "}":
                    out.append(contentsOf: prelude)
                    out.append("}")
                    prelude = String.UnicodeScalarView()
                    if !stack.isEmpty { stack.removeLast() }
                case ";":
                    let statement = String(prelude).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !(statement.hasPrefix("@charset") || statement.hasPrefix("@import")) {
                        out.append(contentsOf: prelude)
                        out.append(";")
                    }
                    prelude = String.UnicodeScalarView()
                default:
                    prelude.append(c)
                }
            } else {
                out.append(c)
                if c == "{" {
                    stack.append(false)
                } else if c == "}" {
                    stack.removeLast()
                }
            }
        }
        out.append(contentsOf: prelude)
        return rewriteURLs(in: String(out))
    }

    static func stripComments(_ css: String) -> String {
        guard css.contains("/*") else { return css }
        var out = ""
        var rest = Substring(css)
        while let start = rest.range(of: "/*") {
            out += rest[rest.startIndex..<start.lowerBound]
            let after = rest[start.upperBound...]
            if let end = after.range(of: "*/") {
                rest = after[end.upperBound...]
            } else {
                rest = ""
            }
        }
        out += rest
        return out
    }

    private static func isIdentStart(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
    }

    private static func isIdentChar(_ c: Unicode.Scalar) -> Bool {
        isIdentStart(c) || (c >= "0" && c <= "9") || c == "-"
    }

    /// Lower-cases element names in a selector list, leaving classes, ids, attribute
    /// selectors and pseudo-classes alone.
    public static func lowercaseTypeSelectors(_ selector: String) -> String {
        let s = Array(selector.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var bracket = 0
        var quote: Unicode.Scalar?
        let separators = Set(" \t\n\r\u{0C},>+~(".unicodeScalars)
        while i < s.count {
            let c = s[i]
            if let q = quote {
                out.append(c)
                if c == q { quote = nil }
                i += 1
                continue
            }
            if c == "\"" || c == "'" { quote = c; out.append(c); i += 1; continue }
            if c == "[" { bracket += 1 } else if c == "]" { bracket = max(0, bracket - 1) }
            if bracket == 0 && isIdentStart(c) {
                let prev: Unicode.Scalar? = i > 0 ? s[i - 1] : nil
                let isType = prev == nil || separators.contains(prev!)
                var j = i
                while j < s.count && isIdentChar(s[j]) { j += 1 }
                let word = String(String.UnicodeScalarView(s[i..<j]))
                out.append(contentsOf: (isType ? word.lowercased() : word).unicodeScalars)
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    private static let urlRegex = try! NSRegularExpression(pattern: "url\\(\\s*(['\"]?)(.*?)\\1\\s*\\)", options: [.caseInsensitive])

    /// Rewrites every `url(...)` to a bundle-relative path.
    public static func rewriteURLs(in css: String) -> String {
        guard css.range(of: "url(", options: .caseInsensitive) != nil else { return css }
        let ns = css as NSString
        var out = ""
        var last = 0
        for m in urlRegex.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let quote = ns.substring(with: m.range(at: 1))
            let path = ResourcePath.normalize(ns.substring(with: m.range(at: 2)))
            out += "url(" + quote + path + quote + ")"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
