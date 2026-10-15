import XCTest
@testable import DictBridgeCore

final class HTMLTransformerTests: XCTestCase {

    private let bundleID = "org.dictbridge.dict.test"

    private func transformer(headwords: [String] = ["apple", "banana", "cherry"],
                             redirects: [(String, String)] = [("Bananas", "banana")],
                             script: String = "",
                             headwordMode: HeadwordMode = .never) -> HTMLTransformer {
        let resolver = LinkResolver(headwords: headwords, redirects: redirects.map { (alias: $0.0, target: $0.1) })
        return HTMLTransformer(resolver: resolver,
                               context: .init(bundleIdentifier: bundleID, headwordMode: headwordMode, sharedScript: script))
    }

    private func xhtml(_ html: String, headword: String = "apple", _ t: HTMLTransformer? = nil) -> String {
        (t ?? transformer()).transform(html: html, headword: headword).xhtml
    }

    /// The output must be well-formed XML inside the DDK's namespaces.
    private func assertWellFormed(_ fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        let doc = "<d:entry xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:d=\"http://www.apple.com/DTDs/DictionaryService-1.0.rng\" id=\"x\">"
            + fragment + "</d:entry>"
        let parser = XMLParser(data: Data(doc.utf8))
        XCTAssertTrue(parser.parse(), "not well-formed: \(parser.parserError?.localizedDescription ?? "?")\n\(fragment)",
                      file: file, line: line)
    }

    func testWrapsInEntryDiv() {
        let out = xhtml("<b>hi</b>")
        XCTAssertTrue(out.hasPrefix("<div class=\"dictbridge-entry\">"), out)
        XCTAssertTrue(out.hasSuffix("</div>"), out)
        assertWellFormed(out)
    }

    func testWhitespaceBetweenInlineElementsBecomesNBSP() {
        let out = xhtml("<span>one</span> <span>two</span>")
        XCTAssertTrue(out.contains("<span>one</span>\u{00A0}<span>two</span>"), out)
    }

    func testWhitespaceBetweenBlocksIsDropped() {
        let out = xhtml("<div>one</div>\n  <div>two</div>")
        XCTAssertTrue(out.contains("<div>one</div><div>two</div>"), out)
    }

    func testCustomTagsAreKeptAndLowercased() {
        let out = xhtml("<EN>a round fruit</EN><TRAN>苹果</TRAN><exat></exat>")
        XCTAssertTrue(out.contains("<en>a round fruit</en>"), out)
        XCTAssertTrue(out.contains("<tran>苹果</tran>"), out)
        XCTAssertTrue(out.contains("<exat></exat>"), "empty elements must not self-close: \(out)")
        assertWellFormed(out)
    }

    func testVoidElementsSelfClose() {
        let out = xhtml("line<br>next <img src=\"a.png\"> end")
        XCTAssertTrue(out.contains("<br/>"), out)
        XCTAssertTrue(out.contains("<img src=\"a.png\"/>"), out)
        assertWellFormed(out)
    }

    func testEntities() {
        let out = xhtml("<p>a&nbsp;b &amp; c &lt;d&gt; &copy;</p>")
        XCTAssertTrue(out.contains("a\u{00A0}b &amp; c &lt;d&gt; ©"), out)
        assertWellFormed(out)
    }

    func testSoundLink() {
        let r = transformer().transform(html: "<a href=\"sound://snd/apple.mp3\"><img src=\"img/spk.png\"></a>", headword: "apple")
        XCTAssertEqual(r.audioLinks, 1)
        XCTAssertTrue(r.xhtml.contains("href=\"javascript:void(0)\""), r.xhtml)
        XCTAssertTrue(r.xhtml.contains("new Audio('snd/apple.mp3').play();return false;"), r.xhtml)
        XCTAssertTrue(r.xhtml.contains("dictbridge-sound"), r.xhtml)
        assertWellFormed(r.xhtml)
    }

    func testSoundLinkWithBackslashes() {
        let out = xhtml("<a href=\"sound://\\snd\\b.mp3\">x</a>")
        XCTAssertTrue(out.contains("new Audio('snd/b.mp3')"), out)
    }

    func testEntryLinkResolvesThroughRedirect() {
        let r = transformer().transform(html: "<a href=\"entry://Bananas#sense1\">bananas</a>", headword: "apple")
        XCTAssertTrue(r.xhtml.contains("href=\"x-dictionary:r:e1:\(bundleID)\""), r.xhtml)
        XCTAssertEqual(r.crossLinks, 1)
    }

    func testEntryLinkPercentEncoded() {
        let t = transformer(headwords: ["cooking apple"], redirects: [])
        let out = t.transform(html: "<a href=\"entry://cooking%20apple\">x</a>", headword: "x").xhtml
        XCTAssertTrue(out.contains("x-dictionary:r:e0:"), out)
    }

    func testBwordAndUnresolvedLinks() {
        let r = transformer().transform(html: "<a href=\"bword://cherry\">c</a><a href=\"entry://zzz\">z</a>", headword: "apple")
        XCTAssertTrue(r.xhtml.contains("x-dictionary:r:e2:"), r.xhtml)
        XCTAssertTrue(r.xhtml.contains("href=\"x-dictionary:d:zzz\""), r.xhtml)
        XCTAssertEqual(r.unresolvedLinks, 1)
    }

    func testFragmentLinksScroll() {
        let out = xhtml("<a href=\"entry://#s2\">go</a> <a href=\"#s3\">go</a><a name=\"s2\"></a>")
        XCTAssertTrue(out.contains("getElementById('s2')"), out)
        XCTAssertTrue(out.contains("getElementById('s3')"), out)
        XCTAssertTrue(out.contains("<span id=\"s2\"></span>"), out)
        assertWellFormed(out)
    }

    func testClickableSpanGetsInnerLink() {
        let out = xhtml("<span class=\"btn\" onclick=\"x.toggle(this)\">Examples</span><div class=\"pop\">hidden</div>")
        XCTAssertTrue(out.contains("<span class=\"btn\" onclick=\"x.toggle(this)\"><a class=\"dictbridge-click\" href=\"javascript:void(0)\">Examples</a></span>"), out)
        assertWellFormed(out)
    }

    func testClickableElementWithLinkInsideIsNotWrapped() {
        let out = xhtml("<div onclick=\"f()\"><a href=\"http://example.com\">x</a></div>")
        XCTAssertFalse(out.contains("dictbridge-click"), out)
    }

    func testImageHandlersAreKept() {
        let out = xhtml("<img src=\"/img/a.jpg\" onclick=\"this.style.maxHeight='none'\">")
        XCTAssertTrue(out.contains("<img src=\"img/a.jpg\" onclick=\"this.style.maxHeight='none'\"/>"), out)
    }

    func testResourcePaths() {
        let out = xhtml("<img src=\"\\img\\a.png\"><img src=\"/img/b.png\"><img src=\"file://c.png\"><img src=\"data:image/png;base64,AA==\">")
        XCTAssertTrue(out.contains("src=\"img/a.png\""), out)
        XCTAssertTrue(out.contains("src=\"img/b.png\""), out)
        XCTAssertTrue(out.contains("src=\"c.png\""), out)
        XCTAssertTrue(out.contains("src=\"data:image/png;base64,AA==\""), out)
    }

    func testStylesheetsScriptsAndStylesAreCollected() {
        let html = "<link rel=\"stylesheet\" href=\"/sample.css\"><script src=\"sample.js\"></script><style>.a{color:red}</style><p>x</p>"
        let r = transformer().transform(html: html, headword: "apple")
        XCTAssertEqual(r.stylesheetRefs, ["sample.css"])
        XCTAssertEqual(r.scriptRefs, ["sample.js"])
        XCTAssertEqual(r.inlineStyles, [".a{color:red}"])
        XCTAssertFalse(r.xhtml.contains("<link"), r.xhtml)
        XCTAssertFalse(r.xhtml.contains("<style"), r.xhtml)
    }

    func testSharedScriptInlinedOnlyWhenNeeded() {
        let t = transformer(script: "var sample={a:1}; if (1 < 2 && true) {}")
        let withHandler = t.transform(html: "<span onclick=\"sample.a\">x</span>", headword: "apple").xhtml
        XCTAssertTrue(withHandler.contains("<script type=\"text/javascript\">/*<![CDATA[*/"), withHandler)
        XCTAssertTrue(withHandler.contains("if (1 < 2 && true)"), withHandler)
        assertWellFormed(withHandler)
        let plain = t.transform(html: "<b>plain</b>", headword: "apple").xhtml
        XCTAssertFalse(plain.contains("<script"), plain)
    }

    func testInlineScriptKeptAsCDATA() {
        let out = xhtml("<script>if (a < b) { c = '&'; }</script><b>x</b>")
        XCTAssertTrue(out.contains("/*<![CDATA[*/\nif (a < b) { c = '&'; }\n/*]]>*/"), out)
        assertWellFormed(out)
    }

    func testHeadwordAuto() {
        let t = transformer(headwordMode: .auto)
        XCTAssertTrue(t.transform(html: "<p>only a definition</p>", headword: "zebra").xhtml.contains("dictbridge-headword"))
        XCTAssertFalse(t.transform(html: "<p><b>zebra</b> an animal</p>", headword: "zebra").xhtml.contains("dictbridge-headword"))
    }

    func testControlCharactersAndBadAttributesAreDropped() {
        let out = xhtml("<p data-x=\"1\" foo:bar=\"2\" class=\"a\">ok\u{0001}</p>")
        XCTAssertFalse(out.contains("foo:bar"), out)
        XCTAssertFalse(out.contains("\u{0001}"), out)
        assertWellFormed(out)
    }

    func testBrokenHTMLStillWellFormed() {
        let samples = [
            "<p>unclosed <b>bold <i>italic</p> tail",
            "</span>stray close<div>",
            "<table><tr><td>a<td>b</table>",
            "<a href=\"entry://x\"><a href=\"entry://y\">nested</a></a>",
            "<span onclick=\"f('<x>')\">quote \" test</span>",
            "<o:p>office</o:p><svg:rect/>",
            "plain text & more < less",
        ]
        for s in samples { assertWellFormed(xhtml(s)) }
    }
}

final class CSSProcessorTests: XCTestCase {
    func testTypeSelectorsAreLowercased() {
        XCTAssertEqual(CSSProcessor.process("EXAMPLE{margin-left:5px;font-style:normal;}"), "example{margin-left:5px;font-style:normal;}")
        XCTAssertEqual(CSSProcessor.lowercaseTypeSelectors(".Foo EN > TRAN, div.X:hover, #Id"), ".Foo en > tran, div.X:hover, #Id")
        XCTAssertEqual(CSSProcessor.lowercaseTypeSelectors("img[src*=\"Spkr_\"]"), "img[src*=\"Spkr_\"]")
        XCTAssertEqual(CSSProcessor.lowercaseTypeSelectors("SPAN:not(EN)"), "span:not(en)")
    }

    func testDeclarationsAndMediaBlocks() {
        let css = "@media screen { EN { color: RED } }\n.A{background:URL(/img/x.png)}"
        let out = CSSProcessor.process(css)
        XCTAssertTrue(out.contains("@media screen { en { color: RED } }"), out)
        XCTAssertTrue(out.contains(".A{background:url(img/x.png)}"), out)
    }

    func testFontFaceUrlsAndImportsAndComments() {
        let css = "/* c */@charset \"utf-8\";@import url(other.css);@font-face{font-family:X;src:url('/fonts/a.ttf')}"
        let out = CSSProcessor.process(css)
        XCTAssertFalse(out.contains("@import"), out)
        XCTAssertFalse(out.contains("@charset"), out)
        XCTAssertFalse(out.contains("/* c */"), out)
        XCTAssertTrue(out.contains("src:url('fonts/a.ttf')"), out)
    }
}

final class LinkResolverTests: XCTestCase {
    func testResolution() {
        let r = LinkResolver(headwords: ["apple", "eleven-plus", "Twelve Step", "apple"],
                             redirects: [("11-plus", "eleven-plus"), ("12 step", "Twelve Step"), ("loop", "loop2"), ("loop2", "loop")])
        XCTAssertEqual(r.resolve("APPLE"), [0, 3])
        XCTAssertEqual(r.resolve("11-plus"), [1])
        XCTAssertEqual(r.resolve("11 plus"), [1], "loose match ignores punctuation")
        XCTAssertEqual(r.resolve("twelve  step"), [2])
        XCTAssertNil(r.resolve("loop"), "cycles terminate")
        XCTAssertNil(r.resolve("nothing"))
        let (aliases, unresolved) = r.aliasesByEntry()
        XCTAssertEqual(aliases[1], ["11-plus"])
        XCTAssertEqual(aliases[2], ["12 step"])
        XCTAssertEqual(unresolved, 2)
    }
}

final class SlugTests: XCTestCase {
    func testSlugs() {
        XCTAssertEqual(Slug.make("LDOCE6++ En-Cn V2-19"), "LDOCE6-En-Cn-V2-19")
        XCTAssertEqual(Slug.make("朗文"), "")
        XCTAssertTrue(Slug.bundleName(for: "朗文").hasPrefix("Dictionary-"))
        XCTAssertEqual(Slug.bundleName(for: "朗文"), Slug.bundleName(for: "朗文"))
    }
}
