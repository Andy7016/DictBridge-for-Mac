import Foundation

/// How a converted dictionary looks when macOS is in Dark Mode.
///
/// Every converted dictionary declares `DCSDictionaryUseSystemAppearance`, so Dictionary.app
/// shows it as it is instead of putting its own lightness-inverting filter over the page
/// (which does not work well on many dictionaries: white page, washed-out text).
public enum DarkMode: String, Codable, CaseIterable, Sendable {
    /// Follow the system: every color in the dictionary's style sheets and inline styles gets a
    /// dark counterpart (`light-dark()`). macOS versions whose Dictionary.app cannot do that
    /// (before macOS 14.5) show the dictionary in light colors.
    case auto
    /// Always show the dictionary in light colors (white page, as in GoldenDict or Eudic).
    case light

    /// Rules appended to every dictionary's style sheet for this mode.
    var styleAdditions: String {
        switch self {
        case .auto:
            return """
            /* Dark Mode: colors written by the dictionary get a dark counterpart with light-dark().
               Systems without light-dark() (before macOS 14.5) keep the dictionary light. */
            :root { color-scheme: light dark; }
            html { color: CanvasText; }
            @supports not (color: light-dark(#000, #fff)) {
                :root { color-scheme: light only; }
                html { background-color: #fff; color: #000; }
            }
            """
        case .light:
            return """
            /* Always light, also in Dark Mode. */
            :root { color-scheme: light only; }
            html { background-color: #fff; color: #000; }
            """
        }
    }
}

/// Gives the colors in CSS declarations a Dark Mode counterpart:
/// `color: #333` → `color: #333; color: light-dark(#333, #d6d6d6)`.
///
/// The original declaration stays in front, so systems that do not understand `light-dark()`
/// drop the second one and keep the dictionary's colors. Dark counterparts keep the hue and
/// mirror the lightness (in Oklab, so that equally light colors stay equally light):
/// - text colors that are dark become light; light text (white on a colored button) stays;
/// - backgrounds that are light become dark; dark and strongly colored ones stay;
/// - borders and outlines are always mirrored, so they keep their contrast;
/// - shadows are left alone (a dark shadow still works on a dark page).
public enum DarkColors {

    enum Role { case text, background, line }

    // MARK: Declarations

    /// Rewrites the color declarations in a declaration list (the inside of a CSS rule or a
    /// `style` attribute). Anything that is not a color declaration is left as it is.
    public static func adaptDeclarations(_ css: String) -> String {
        guard !css.isEmpty else { return css }
        var out = ""
        var segment = ""
        var quote: Character?
        var depth = 0
        func flushSegment() {
            out += adaptDeclaration(segment)
            segment = ""
        }
        for c in css {
            if let q = quote {
                segment.append(c)
                if c == q { quote = nil }
                continue
            }
            switch c {
            case "\"", "'":
                quote = c
                segment.append(c)
            case "(":
                depth += 1
                segment.append(c)
            case ")":
                depth = max(0, depth - 1)
                segment.append(c)
            case ";", "{", "}":
                if depth == 0 {
                    flushSegment()
                    out.append(c)
                } else {
                    segment.append(c)
                }
            default:
                segment.append(c)
            }
        }
        flushSegment()
        return out
    }

    /// One `property: value` declaration (without the `;`).
    static func adaptDeclaration(_ declaration: String) -> String {
        guard let colon = declaration.firstIndex(of: ":") else { return declaration }
        let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let role = role(of: property) else { return declaration }
        var value = String(declaration[declaration.index(after: colon)...])
        let lower = value.lowercased()
        // Already theme-aware or not resolvable here.
        if lower.contains("light-dark(") || lower.contains("var(") || lower.contains("env(") { return declaration }
        var important = ""
        if let bang = value.range(of: "!\\s*important\\s*$", options: [.regularExpression, .caseInsensitive]) {
            important = " !important"
            value = String(value[..<bang.lowerBound])
        }
        guard let adapted = adaptValue(value.trimmingCharacters(in: .whitespacesAndNewlines), role: role) else {
            return declaration
        }
        // Keep the original whitespace after the declaration out of the middle.
        let trimmed = declaration.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let trailing = String(declaration.dropFirst(trimmed.count))
        return trimmed + "; " + property + ": " + adapted + important + trailing
    }

    static func role(of property: String) -> Role? {
        switch property {
        case "color", "caret-color", "fill", "stroke",
             "text-decoration", "text-decoration-color", "-webkit-text-decoration-color",
             "text-emphasis", "text-emphasis-color", "-webkit-text-emphasis", "-webkit-text-emphasis-color",
             "-webkit-text-fill-color", "-webkit-text-stroke", "-webkit-text-stroke-color":
            return .text
        case "background", "background-color", "background-image":
            return .background
        case "outline", "outline-color":
            return .line
        default:
            if property.hasPrefix("border") && !property.hasPrefix("border-image") { return .line }
            if property.hasPrefix("column-rule") || property.hasPrefix("-webkit-column-rule") { return .line }
            return nil
        }
    }

    // MARK: Values

    /// Replaces every color in a property value with `light-dark(color, darkColor)`.
    /// Returns nil when the value has no color to replace.
    static func adaptValue(_ value: String, role: Role) -> String? {
        let s = Array(value)
        var out = ""
        var changed = false
        var i = 0

        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "-" || c == "_" }

        /// Index after the `)` that closes the parenthesis opened just before `start`.
        func closing(from start: Int) -> Int {
            var depth = 1
            var j = start
            var quote: Character?
            while j < s.count {
                let c = s[j]
                j += 1
                if let q = quote { if c == q { quote = nil }; continue }
                if c == "\"" || c == "'" { quote = c } else if c == "(" { depth += 1 } else if c == ")" {
                    depth -= 1
                    if depth == 0 { return j }
                }
            }
            return j
        }

        func emit(_ original: String, _ color: RGBA?) {
            // Fully transparent colors look the same either way.
            if let color, color.a > 0, case let dark = darkVariant(of: color, role: role), dark.css != color.css {
                out += "light-dark(" + original + ", " + dark.css + ")"
                changed = true
            } else {
                out += original
            }
        }

        while i < s.count {
            let c = s[i]
            if c == "\"" || c == "'" {
                var j = i + 1
                while j < s.count && s[j] != c { j += 1 }
                j = min(j + 1, s.count)
                out += String(s[i..<j])
                i = j
            } else if c == "#" {
                var j = i + 1
                while j < s.count && s[j].isHexDigit { j += 1 }
                let token = String(s[i..<j])
                let endsWord = j == s.count || !isIdent(s[j])
                emit(token, endsWord ? parseHex(String(token.dropFirst())) : nil)
                i = j
            } else if c.isLetter || (c == "-" && i + 1 < s.count && (s[i + 1].isLetter || s[i + 1] == "-")) {
                let startsWord = i == 0 || !isIdent(s[i - 1])
                var j = i
                while j < s.count && isIdent(s[j]) { j += 1 }
                let word = String(s[i..<j])
                let name = word.lowercased()
                if j < s.count && s[j] == "(" {
                    if ["rgb", "rgba", "hsl", "hsla"].contains(name) {
                        let end = closing(from: j + 1)
                        let token = String(s[i..<end])
                        emit(token, parseFunction(name, String(s[(j + 1)..<max(j + 1, end - 1)])))
                        i = end
                    } else if name == "url" {
                        let end = closing(from: j + 1)
                        out += String(s[i..<end])
                        i = end
                    } else {
                        // Gradients and other functions: look for colors inside.
                        out += word + "("
                        i = j + 1
                    }
                } else {
                    emit(word, startsWord ? namedColors[name].map { RGBA(hex: $0) } : nil)
                    i = j
                }
            } else {
                out.append(c)
                i += 1
            }
        }
        return changed ? out : nil
    }

    // MARK: Parsing

    struct RGBA: Equatable {
        var r, g, b: Double  // 0...1
        var a: Double = 1

        init(r: Double, g: Double, b: Double, a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        init(hex: UInt32) {
            r = Double((hex >> 16) & 0xff) / 255
            g = Double((hex >> 8) & 0xff) / 255
            b = Double(hex & 0xff) / 255
        }

        var css: String {
            func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
            if a >= 1 {
                return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
            }
            return "rgba(\(byte(r)), \(byte(g)), \(byte(b)), " + String(format: "%g", (a * 1000).rounded() / 1000) + ")"
        }
    }

    static func parseHex(_ digits: String) -> RGBA? {
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        var d = digits
        if d.count == 3 || d.count == 4 { d = d.map { "\($0)\($0)" }.joined() }
        guard d.count == 6 || d.count == 8, let v = UInt64(d, radix: 16) else { return nil }
        if d.count == 6 { return RGBA(hex: UInt32(v)) }
        var c = RGBA(hex: UInt32(v >> 8))
        c.a = Double(v & 0xff) / 255
        return c
    }

    /// Parses the arguments of `rgb()`/`rgba()`/`hsl()`/`hsla()`, comma or space separated.
    static func parseFunction(_ name: String, _ arguments: String) -> RGBA? {
        let parts = arguments.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
        guard parts.count == 3 || parts.count == 4 else { return nil }

        func number(_ s: String, percentScale: Double) -> Double? {
            if s.hasSuffix("%") { return Double(s.dropLast()).map { $0 / 100 * percentScale } }
            return Double(s)
        }
        var alpha = 1.0
        if parts.count == 4 {
            guard let a = number(parts[3], percentScale: 1) else { return nil }
            alpha = min(max(a, 0), 1)
        }
        if name.hasPrefix("rgb") {
            guard let r = number(parts[0], percentScale: 255), let g = number(parts[1], percentScale: 255),
                  let b = number(parts[2], percentScale: 255) else { return nil }
            return RGBA(r: min(max(r / 255, 0), 1), g: min(max(g / 255, 0), 1), b: min(max(b / 255, 0), 1), a: alpha)
        }
        var hueText = parts[0]
        var hueScale = 1.0
        for (unit, scale) in [("deg", 1.0), ("turn", 360.0), ("rad", 180 / Double.pi), ("grad", 0.9)]
        where hueText.hasSuffix(unit) {
            hueText = String(hueText.dropLast(unit.count))
            hueScale = scale
            break
        }
        guard let h = Double(hueText).map({ $0 * hueScale }), let sat = number(parts[1], percentScale: 1),
              let light = number(parts[2], percentScale: 1) else { return nil }
        // hsl() without % (modern syntax allows plain numbers 0...100).
        let sv = parts[1].hasSuffix("%") ? sat : sat / 100
        let lv = parts[2].hasSuffix("%") ? light : light / 100
        return hslToRGB(h: h, s: min(max(sv, 0), 1), l: min(max(lv, 0), 1), a: alpha)
    }

    static func hslToRGB(h: Double, s: Double, l: Double, a: Double) -> RGBA {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func f(_ n: Double) -> Double {
            let k = (n + hue * 12).truncatingRemainder(dividingBy: 12)
            let amount = s * min(l, 1 - l)
            return l - amount * max(-1, min(k - 3, 9 - k, 1))
        }
        return RGBA(r: f(0), g: f(8), b: f(4), a: a)
    }

    // MARK: Dark counterpart

    /// Lightness (Oklab) of the page and the text in Dictionary.app's Dark Mode.
    static let darkPage = 0.235  // about #1e1e1e
    static let darkText = 0.90   // about #dfdfdf

    /// Mirrors a lightness so that white lands on the dark page and black on the dark text.
    static func mirror(_ l: Double) -> Double { darkPage + (1 - l) * (darkText - darkPage) }

    static func darkVariant(of color: RGBA, role: Role) -> RGBA {
        var lab = Oklab(color)
        switch role {
        case .text:
            // Light text (often on a colored background) already works on a dark page.
            guard lab.l < 0.62 else { return color }
            lab.l = max(mirror(lab.l), 0.75)
        case .background:
            // Dark or strongly colored backgrounds keep their (usually light) text readable.
            guard lab.l > 0.7 else { return color }
            lab.l = mirror(lab.l)
        case .line:
            lab.l = mirror(lab.l)
        }
        var result = lab.rgbInGamut()
        result.a = color.a
        return result
    }

    /// Oklab (Björn Ottosson, 2020), with sRGB transfer functions.
    struct Oklab {
        var l, a, b: Double

        init(_ c: RGBA) {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = linear(c.r), g = linear(c.g), bl = linear(c.b)
            let l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
            let m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
            let s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
            l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
            a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
            b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        }

        /// Linear sRGB, possibly out of 0...1.
        func linearRGB(scale k: Double) -> (Double, Double, Double) {
            let l_ = l + 0.3963377774 * a * k + 0.2158037573 * b * k
            let m_ = l - 0.1055613458 * a * k - 0.0638541728 * b * k
            let s_ = l - 0.0894841775 * a * k - 1.2914855480 * b * k
            let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
            return (4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
                    -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
                    -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S)
        }

        /// Converts back to sRGB, reducing the chroma (keeping hue and lightness) until the
        /// color fits.
        func rgbInGamut() -> RGBA {
            func fits(_ c: (Double, Double, Double)) -> Bool {
                let e = 1e-4
                return [c.0, c.1, c.2].allSatisfy { $0 >= -e && $0 <= 1 + e }
            }
            var k = 1.0
            if !fits(linearRGB(scale: 1)) {
                var lo = 0.0, hi = 1.0
                for _ in 0..<24 {
                    let mid = (lo + hi) / 2
                    if fits(linearRGB(scale: mid)) { lo = mid } else { hi = mid }
                }
                k = lo
            }
            let c = linearRGB(scale: k)
            func encode(_ v: Double) -> Double {
                let x = min(max(v, 0), 1)
                return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            }
            return RGBA(r: encode(c.0), g: encode(c.1), b: encode(c.2))
        }
    }

    // MARK: Named colors

    /// CSS named colors (`transparent` and `currentcolor` are left alone on purpose).
    static let namedColors: [String: UInt32] = [
        "aliceblue": 0xf0f8ff, "antiquewhite": 0xfaebd7, "aqua": 0x00ffff, "aquamarine": 0x7fffd4,
        "azure": 0xf0ffff, "beige": 0xf5f5dc, "bisque": 0xffe4c4, "black": 0x000000,
        "blanchedalmond": 0xffebcd, "blue": 0x0000ff, "blueviolet": 0x8a2be2, "brown": 0xa52a2a,
        "burlywood": 0xdeb887, "cadetblue": 0x5f9ea0, "chartreuse": 0x7fff00, "chocolate": 0xd2691e,
        "coral": 0xff7f50, "cornflowerblue": 0x6495ed, "cornsilk": 0xfff8dc, "crimson": 0xdc143c,
        "cyan": 0x00ffff, "darkblue": 0x00008b, "darkcyan": 0x008b8b, "darkgoldenrod": 0xb8860b,
        "darkgray": 0xa9a9a9, "darkgreen": 0x006400, "darkgrey": 0xa9a9a9, "darkkhaki": 0xbdb76b,
        "darkmagenta": 0x8b008b, "darkolivegreen": 0x556b2f, "darkorange": 0xff8c00, "darkorchid": 0x9932cc,
        "darkred": 0x8b0000, "darksalmon": 0xe9967a, "darkseagreen": 0x8fbc8f, "darkslateblue": 0x483d8b,
        "darkslategray": 0x2f4f4f, "darkslategrey": 0x2f4f4f, "darkturquoise": 0x00ced1, "darkviolet": 0x9400d3,
        "deeppink": 0xff1493, "deepskyblue": 0x00bfff, "dimgray": 0x696969, "dimgrey": 0x696969,
        "dodgerblue": 0x1e90ff, "firebrick": 0xb22222, "floralwhite": 0xfffaf0, "forestgreen": 0x228b22,
        "fuchsia": 0xff00ff, "gainsboro": 0xdcdcdc, "ghostwhite": 0xf8f8ff, "gold": 0xffd700,
        "goldenrod": 0xdaa520, "gray": 0x808080, "green": 0x008000, "greenyellow": 0xadff2f,
        "grey": 0x808080, "honeydew": 0xf0fff0, "hotpink": 0xff69b4, "indianred": 0xcd5c5c,
        "indigo": 0x4b0082, "ivory": 0xfffff0, "khaki": 0xf0e68c, "lavender": 0xe6e6fa,
        "lavenderblush": 0xfff0f5, "lawngreen": 0x7cfc00, "lemonchiffon": 0xfffacd, "lightblue": 0xadd8e6,
        "lightcoral": 0xf08080, "lightcyan": 0xe0ffff, "lightgoldenrodyellow": 0xfafad2, "lightgray": 0xd3d3d3,
        "lightgreen": 0x90ee90, "lightgrey": 0xd3d3d3, "lightpink": 0xffb6c1, "lightsalmon": 0xffa07a,
        "lightseagreen": 0x20b2aa, "lightskyblue": 0x87cefa, "lightslategray": 0x778899, "lightslategrey": 0x778899,
        "lightsteelblue": 0xb0c4de, "lightyellow": 0xffffe0, "lime": 0x00ff00, "limegreen": 0x32cd32,
        "linen": 0xfaf0e6, "magenta": 0xff00ff, "maroon": 0x800000, "mediumaquamarine": 0x66cdaa,
        "mediumblue": 0x0000cd, "mediumorchid": 0xba55d3, "mediumpurple": 0x9370db, "mediumseagreen": 0x3cb371,
        "mediumslateblue": 0x7b68ee, "mediumspringgreen": 0x00fa9a, "mediumturquoise": 0x48d1cc,
        "mediumvioletred": 0xc71585, "midnightblue": 0x191970, "mintcream": 0xf5fffa, "mistyrose": 0xffe4e1,
        "moccasin": 0xffe4b5, "navajowhite": 0xffdead, "navy": 0x000080, "oldlace": 0xfdf5e6,
        "olive": 0x808000, "olivedrab": 0x6b8e23, "orange": 0xffa500, "orangered": 0xff4500,
        "orchid": 0xda70d6, "palegoldenrod": 0xeee8aa, "palegreen": 0x98fb98, "paleturquoise": 0xafeeee,
        "palevioletred": 0xdb7093, "papayawhip": 0xffefd5, "peachpuff": 0xffdab9, "peru": 0xcd853f,
        "pink": 0xffc0cb, "plum": 0xdda0dd, "powderblue": 0xb0e0e6, "purple": 0x800080,
        "rebeccapurple": 0x663399, "red": 0xff0000, "rosybrown": 0xbc8f8f, "royalblue": 0x4169e1,
        "saddlebrown": 0x8b4513, "salmon": 0xfa8072, "sandybrown": 0xf4a460, "seagreen": 0x2e8b57,
        "seashell": 0xfff5ee, "sienna": 0xa0522d, "silver": 0xc0c0c0, "skyblue": 0x87ceeb,
        "slateblue": 0x6a5acd, "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xfffafa,
        "springgreen": 0x00ff7f, "steelblue": 0x4682b4, "tan": 0xd2b48c, "teal": 0x008080,
        "thistle": 0xd8bfd8, "tomato": 0xff6347, "turquoise": 0x40e0d0, "violet": 0xee82ee,
        "wheat": 0xf5deb3, "white": 0xffffff, "whitesmoke": 0xf5f5f5, "yellow": 0xffff00,
        "yellowgreen": 0x9acd32,
    ]
}
