import XCTest
@testable import DictBridgeCore

final class DarkColorsTests: XCTestCase {

    private func lightness(_ css: String) -> Double {
        let color = DarkColors.parseHex(String(css.dropFirst())) ?? DarkColors.parseFunction("rgba", String(css.dropFirst(5).dropLast()))!
        return DarkColors.Oklab(color).l
    }

    /// The dark half of the first `light-dark(original, dark)` in `css`.
    private func darkHalf(_ css: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let start = css.range(of: "light-dark(") else {
            XCTFail("no light-dark() in \(css)", file: file, line: line)
            return ""
        }
        var depth = 1
        var comma: String.Index?
        var i = start.upperBound
        while i < css.endIndex {
            let c = css[i]
            if c == "(" { depth += 1 } else if c == ")" {
                depth -= 1
                if depth == 0 { break }
            } else if c == "," && depth == 1 && comma == nil {
                comma = i
            }
            i = css.index(after: i)
        }
        return css[css.index(after: comma!)..<i].trimmingCharacters(in: .whitespaces)
    }

    func testDarkTextBecomesLight() {
        let out = DarkColors.adaptDeclarations("color:#333")
        XCTAssertTrue(out.hasPrefix("color:#333; color: light-dark(#333, #"), out)
        XCTAssertGreaterThanOrEqual(lightness(darkHalf(out)), 0.74)
        // Named and functional colors too.
        XCTAssertTrue(DarkColors.adaptDeclarations("color: Brown").contains("light-dark(Brown, #"))
        XCTAssertTrue(DarkColors.adaptDeclarations("color: rgb(0 0 0 / 50%)").contains("light-dark(rgb(0 0 0 / 50%), rgba(222, 222, 222, 0.5))"))
        XCTAssertTrue(DarkColors.adaptDeclarations("color: hsl(0, 100%, 25%)").contains("light-dark(hsl(0, 100%, 25%), #"))
    }

    func testLightTextAndDarkBackgroundsStay() {
        XCTAssertEqual(DarkColors.adaptDeclarations("color:#fff"), "color:#fff")
        XCTAssertEqual(DarkColors.adaptDeclarations("background-color:#08d;color:white"), "background-color:#08d;color:white")
    }

    func testLightBackgroundBecomesDark() {
        let out = DarkColors.adaptDeclarations("background: #fafafa url(/img/a.png) no-repeat")
        XCTAssertTrue(out.contains("; background: light-dark(#fafafa, #"), out)
        XCTAssertTrue(out.hasSuffix(" url(/img/a.png) no-repeat"), out)
        XCTAssertLessThan(lightness(darkHalf(out)), 0.3)
    }

    func testLinesAreAlwaysMirrored() {
        let light = DarkColors.adaptDeclarations("border-bottom: 1px solid #ddd")
        XCTAssertTrue(light.contains("border-bottom: 1px solid light-dark(#ddd, #"), light)
        XCTAssertLessThan(lightness(darkHalf(light)), 0.4)
        let dark = DarkColors.adaptDeclarations("outline: 1px solid black")
        XCTAssertGreaterThan(lightness(darkHalf(dark)), 0.85)
    }

    func testKeepsImportantAndWhitespace() {
        XCTAssertEqual(DarkColors.adaptDeclarations("color: #000 !important "),
                       "color: #000 !important; color: light-dark(#000, #dedede) !important ")
    }

    func testLeavesNonColorsAlone() {
        for css in ["color: var(--text)", "color: light-dark(#000, #fff)", "color: currentColor",
                    "color: transparent", "font-family: Gray, Red", "content: '#000 black'",
                    "background: url(black.png)", "width: 10px", "color: rgba(0,0,0,0)"] {
            XCTAssertEqual(DarkColors.adaptDeclarations(css), css)
        }
    }

    func testGradientsAndShadows() {
        let out = DarkColors.adaptDeclarations("background: linear-gradient(to right, #fff, #eee)")
        XCTAssertTrue(out.contains("linear-gradient(to right, light-dark(#fff, #"), out)
        XCTAssertTrue(out.contains("light-dark(#eee, #"), out)
        XCTAssertEqual(DarkColors.adaptDeclarations("box-shadow: 0 1px 2px rgba(0,0,0,.2)"),
                       "box-shadow: 0 1px 2px rgba(0,0,0,.2)")
    }

    func testParsing() {
        XCTAssertEqual(DarkColors.parseHex("f00"), DarkColors.RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(DarkColors.parseHex("ff000080")?.a ?? 0, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(DarkColors.parseHex("f008")?.a ?? 0, 136.0 / 255, accuracy: 1e-9)
        XCTAssertNil(DarkColors.parseHex("12345"))
        XCTAssertEqual(DarkColors.parseFunction("rgb", "255, 0, 0"), DarkColors.RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(DarkColors.parseFunction("rgba", "100% 0% 0% / 50%"), DarkColors.RGBA(r: 1, g: 0, b: 0, a: 0.5))
        let green = DarkColors.parseFunction("hsl", "120deg 100% 50%")!
        XCTAssertEqual(green.g, 1, accuracy: 1e-9)
        XCTAssertEqual(green.r, 0, accuracy: 1e-9)
        XCTAssertNil(DarkColors.parseFunction("rgb", "1, 2"))
    }

    func testDarkVariantsStayInGamut() {
        for hex: UInt32 in [0x0000ff, 0xff0000, 0x00ff00, 0x000000, 0xffffff, 0x004fce, 0xffff00] {
            for role in [DarkColors.Role.text, .background, .line] {
                let c = DarkColors.darkVariant(of: DarkColors.RGBA(hex: hex), role: role)
                for v in [c.r, c.g, c.b] { XCTAssertTrue(v >= 0 && v <= 1, "\(hex) \(role) → \(c)") }
            }
        }
        // Hue is kept: dark blue text stays blue.
        let blue = DarkColors.darkVariant(of: DarkColors.RGBA(hex: 0x00008b), role: .text)
        XCTAssertGreaterThan(blue.b, blue.r)
        XCTAssertGreaterThan(blue.b, blue.g)
    }
}

final class DarkModeStyleTests: XCTestCase {

    func testProcessAdaptsRulesMediaAndKeyframes() {
        let css = ".a{color:#222}@media screen{SPAN.b{background:white;border:1px solid}}@keyframes k{from{color:black}}"
        let out = CSSProcessor.process(css, adaptColors: true)
        XCTAssertTrue(out.contains(".a{color:#222; color: light-dark(#222, #"), out)
        XCTAssertTrue(out.contains("span.b{background:white; background: light-dark(white, #"), out)
        XCTAssertTrue(out.contains("border:1px solid}"), out)
        XCTAssertTrue(out.contains("from{color:black; color: light-dark(black, #"), out)
        // Without the option nothing changes.
        XCTAssertFalse(CSSProcessor.process(css).contains("light-dark"))
    }

    func testProcessKeepsUrlRewritingAndStrings() {
        let out = CSSProcessor.process(".x{background:#fff URL(/img/b.png);content:\"#000;}\"}", adaptColors: true)
        XCTAssertTrue(out.contains("url(img/b.png)"), out)
        XCTAssertTrue(out.contains("content:\"#000;}\""), out)
    }

    func testAdditions() {
        let auto = CSSProcessor.additions(darkMode: .auto)
        XCTAssertTrue(auto.contains("color-scheme: light dark"))
        XCTAssertTrue(auto.contains("@supports not (color: light-dark(#000, #fff))"))
        XCTAssertTrue(auto.contains("dictbridge-control"))
        let light = CSSProcessor.additions(darkMode: .light)
        XCTAssertTrue(light.contains("color-scheme: light only"))
        XCTAssertFalse(light.contains("light dark"))
    }

    func testInfoPlistDeclaresSystemAppearance() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictbridge-test-\(UUID()).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try DictionaryPlist.write(to: url, displayName: "T", bundleIdentifier: "org.dictbridge.dict.t", version: "1",
                                  copyright: "", sourceFile: "t.mdx", frontMatter: false)
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        XCTAssertEqual(plist?["DCSDictionaryUseSystemAppearance"] as? Bool, true)
    }

    private func transform(_ html: String, adapt: Bool = true) -> String {
        HTMLTransformer(resolver: nil, context: .init(bundleIdentifier: "org.dictbridge.dict.t", headwordMode: .never,
                                                       adaptColors: adapt))
            .transform(html: html, headword: "x").xhtml
    }

    func testInlineStylesFontColorAndBgcolor() {
        let styled = transform("<span style=\"color:#123\">a</span>")
        XCTAssertTrue(styled.contains("style=\"color:#123; color: light-dark(#123, #"), styled)

        let font = transform("<font color=\"#800000\">b</font>")
        XCTAssertTrue(font.contains("color=\"#800000\""), font)
        XCTAssertTrue(font.contains("style=\"color: #800000; color: light-dark(#800000, #"), font)

        let legacy = transform("<font color=\"336699\">c</font>")
        XCTAssertTrue(legacy.contains("light-dark(#336699, #"), legacy)

        let cell = transform("<table><tr><td bgcolor=\"#eeeeee\" style=\"padding:1px\">d</td></tr></table>")
        XCTAssertTrue(cell.contains("style=\"background-color: #eeeeee; background-color: light-dark(#eeeeee, #"), cell)
        XCTAssertTrue(cell.contains("; padding:1px\""), cell)

        // Light text needs nothing; without the option nothing changes.
        XCTAssertFalse(transform("<font color=\"white\">e</font>").contains("style="))
        XCTAssertFalse(transform("<span style=\"color:#123\">a</span>", adapt: false).contains("light-dark"))
    }
}
