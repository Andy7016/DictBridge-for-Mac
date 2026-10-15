import Foundation
import libxml2

/// What the transformer should do when an entry's HTML does not show its headword.
public enum HeadwordMode: String, Codable, CaseIterable, Sendable {
    case auto, always, never
}

/// Rewrites one MDict HTML entry into the XHTML fragment Apple's Dictionary expects.
///
/// Dictionary.app quirks this handles (all found while testing real dictionaries):
/// - whitespace-only text nodes are dropped, which glues words together → keep them as NBSP;
/// - a click on plain text looks the word up instead of running `onclick` → clickable
///   elements get an inner `<a href="javascript:void(0)">`;
/// - `sound://`, `entry://`, `bword://` links → JavaScript audio / `x-dictionary:` URLs;
/// - resource paths (`/img/a.png`, `\img\a.png`, `file://…`) → paths relative to the bundle.
public struct HTMLTransformer {

    public struct Context: Sendable {
        public var bundleIdentifier: String
        public var headwordMode: HeadwordMode
        /// Mark small click-only elements (buttons, tabs, speaker icons) with `dictbridge-control`
        /// so the look-up popover, where clicks do nothing, can hide them.
        public var markControls: Bool
        public init(bundleIdentifier: String, headwordMode: HeadwordMode = .auto, markControls: Bool = true) {
            self.bundleIdentifier = bundleIdentifier
            self.headwordMode = headwordMode
            self.markControls = markControls
        }
    }

    public struct Result: Sendable {
        public var xhtml: String
        /// `<link rel="stylesheet" href>` targets seen in the entry.
        public var stylesheetRefs: Set<String> = []
        /// `<script src>` targets seen in the entry.
        public var scriptRefs: Set<String> = []
        /// Contents of `<style>` blocks seen in the entry.
        public var inlineStyles: [String] = []
        public var audioLinks = 0
        public var crossLinks = 0
        public var unresolvedLinks = 0
    }

    let resolver: LinkResolver?
    let context: Context

    public init(resolver: LinkResolver?, context: Context) {
        self.resolver = resolver
        self.context = context
        _ = HTMLTransformer.parserReady
    }

    private static let parserReady: Bool = {
        xmlInitParser()
        return true
    }()

    // MARK: - Public entry point

    public func transform(html: String, headword: String) -> Result {
        let wrapped = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"></head><body>"
            + html + "</body></html>"
        var bytes = Array(wrapped.utf8)
        let options = Int32(HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NOERROR.rawValue
            | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_NONET.rawValue)
        let doc: htmlDocPtr? = bytes.withUnsafeMutableBufferPointer { buf -> htmlDocPtr? in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { p in
                htmlReadMemory(p, Int32(buf.count), nil, "UTF-8", options)
            }
        }
        var state = State()
        state.headwordKey = LinkResolver.normalize(headword)
        var out = ""

        guard let doc else {
            out += "<div class=\"dictbridge-entry\">"
            Self.escapeText(html, into: &out)
            out += "</div>"
            return Result(xhtml: out)
        }
        defer { xmlFreeDoc(doc) }

        var body: xmlNodePtr?
        if let root = xmlDocGetRootElement(doc) {
            var child = root.pointee.children
            while let c = child {
                if c.pointee.type == XML_ELEMENT_NODE {
                    let name = Self.name(of: c)
                    if name == "body" { body = c } else if name == "head" { collectHeadResources(c, into: &state) }
                }
                child = c.pointee.next
            }
        }

        var inner = ""
        inner.reserveCapacity(html.utf8.count + html.utf8.count / 8 + 256)
        if let body {
            if needsHeadword(body: body, headword: headword) {
                inner += "<div class=\"dictbridge-headword\">"
                Self.escapeText(headword, into: &inner)
                inner += "</div>"
            }
            emitChildren(of: body, parentName: "div", insideLink: false, state: &state, out: &inner)
        }

        out += "<div class=\"dictbridge-entry\">"
        // Scripts from the entry's <head>, in order. Dictionary.app (window and popover) loads
        // <script src> from the bundle, so every entry shares one copy of each file.
        for script in state.headScripts {
            switch script {
            case .file(let path): Self.emitScript(src: path, into: &out)
            case .code(let code): Self.emitScript(code: code, into: &out)
            }
        }
        out += inner
        out += "</div>"

        var result = Result(xhtml: out)
        result.stylesheetRefs = state.stylesheetRefs
        result.scriptRefs = state.scriptRefs
        result.inlineStyles = state.inlineStyles
        result.audioLinks = state.audioLinks
        result.crossLinks = state.crossLinks
        result.unresolvedLinks = state.unresolvedLinks
        return result
    }

    // MARK: - Tree walk

    private enum HeadScript {
        case file(String)
        case code(String)
    }

    private struct State {
        var stylesheetRefs = Set<String>()
        var scriptRefs = Set<String>()
        var headScripts: [HeadScript] = []
        var inlineStyles: [String] = []
        var headwordKey = ""
        var audioLinks = 0
        var crossLinks = 0
        var unresolvedLinks = 0
    }

    static func emitScript(src: String, into out: inout String) {
        out += "<script type=\"text/javascript\" src=\""
        escapeAttribute(src, into: &out)
        out += "\"></script>"
    }

    static func emitScript(code: String, into out: inout String) {
        out += "<script type=\"text/javascript\">/*<![CDATA[*/\n"
        out += code.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
        out += "\n/*]]>*/</script>"
    }

    /// Characters that mark text as phonetics, which stays visible even inside a sound link.
    static let phoneticScalars: Set<Unicode.Scalar> = Set("ˈˌːəɪʊæʌɔɒɜθðʃʒŋɑɛɐɚɝʔ".unicodeScalars)

    /// Small click-only elements: tabs, menu buttons, speaker icons. Longer content (examples that
    /// expand on click), phonetics and the headword itself are never treated as controls.
    private func looksLikeControl(_ node: xmlNodePtr, headwordKey: String) -> Bool {
        let text = Self.textContent(of: node).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 24 { return false }
        if text.contains("/") || text.unicodeScalars.contains(where: { Self.phoneticScalars.contains($0) }) { return false }
        if !headwordKey.isEmpty && !text.isEmpty && LinkResolver.normalize(text).contains(headwordKey) { return false }
        return true
    }

    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]
    static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "br", "caption", "center", "col", "colgroup", "dd",
        "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1",
        "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "html", "li", "main", "menu", "nav", "ol", "p", "pre",
        "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ]
    /// Parents whose whitespace children are never significant.
    static let structuralElements: Set<String> = [
        "table", "tbody", "thead", "tfoot", "tr", "ul", "ol", "dl", "select", "colgroup", "html", "head",
    ]
    static let droppedElements: Set<String> = ["head", "meta", "title", "base", "noscript", "iframe", "object", "frameset", "frame"]
    static let eventAttributes: Set<String> = ["onclick", "onmousedown", "onmouseup", "ondblclick"]
    static let resourceAttributes: Set<String> = ["src", "background", "poster", "data-src"]

    @inline(__always)
    static func name(of node: xmlNodePtr) -> String {
        guard let n = node.pointee.name else { return "" }
        return String(cString: n).lowercased()
    }

    @inline(__always)
    static func content(of node: xmlNodePtr) -> String {
        guard let c = node.pointee.content else { return "" }
        return String(cString: c)
    }

    static func attributes(of node: xmlNodePtr) -> [(String, String)] {
        var result: [(String, String)] = []
        var attr = node.pointee.properties
        while let a = attr {
            let name = a.pointee.name.map { String(cString: $0) } ?? ""
            var value = ""
            if let v = xmlNodeListGetString(node.pointee.doc, a.pointee.children, 1) {
                value = String(cString: v)
                xmlFree(v)
            }
            if !name.isEmpty { result.append((name.lowercased(), value)) }
            attr = a.pointee.next
        }
        return result
    }

    static func textContent(of node: xmlNodePtr) -> String {
        guard let c = xmlNodeGetContent(node) else { return "" }
        defer { xmlFree(c) }
        return String(cString: c)
    }

    static func subtreeContains(_ node: xmlNodePtr, element: String) -> Bool {
        var child = node.pointee.children
        while let c = child {
            if c.pointee.type == XML_ELEMENT_NODE {
                if name(of: c) == element || subtreeContains(c, element: element) { return true }
            }
            child = c.pointee.next
        }
        return false
    }

    private func collectHeadResources(_ head: xmlNodePtr, into state: inout State) {
        var child = head.pointee.children
        while let c = child {
            if c.pointee.type == XML_ELEMENT_NODE {
                switch Self.name(of: c) {
                case "link": collectLink(c, into: &state)
                case "style": state.inlineStyles.append(Self.textContent(of: c))
                case "script":
                    if let src = Self.attributes(of: c).first(where: { $0.0 == "src" })?.1, !src.isEmpty {
                        let path = ResourcePath.normalize(src)
                        if state.scriptRefs.insert(path).inserted { state.headScripts.append(.file(path)) }
                    } else {
                        let code = Self.textContent(of: c)
                        if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state.headScripts.append(.code(code)) }
                    }
                default: break
                }
            }
            child = c.pointee.next
        }
    }

    private func collectLink(_ node: xmlNodePtr, into state: inout State) {
        let attrs = Self.attributes(of: node)
        let rel = attrs.first(where: { $0.0 == "rel" })?.1.lowercased() ?? ""
        if rel.contains("stylesheet") || rel.isEmpty, let href = attrs.first(where: { $0.0 == "href" })?.1, !href.isEmpty {
            state.stylesheetRefs.insert(ResourcePath.normalize(href))
        }
    }

    private func needsHeadword(body: xmlNodePtr, headword: String) -> Bool {
        switch context.headwordMode {
        case .never: return false
        case .always: return true
        case .auto:
            let word = LinkResolver.normalize(headword)
            guard !word.isEmpty else { return false }
            let text = LinkResolver.normalize(String(Self.textContent(of: body).prefix(800)))
            return !text.contains(word)
        }
    }

    private func emitChildren(of parent: xmlNodePtr, parentName: String, insideLink: Bool,
                              state: inout State, out: inout String) {
        var child = parent.pointee.children
        while let c = child {
            emit(c, parentName: parentName, insideLink: insideLink, state: &state, out: &out)
            child = c.pointee.next
        }
    }

    private static func significantSibling(_ node: xmlNodePtr?, forward: Bool) -> xmlNodePtr? {
        var n = node
        while let x = n {
            if x.pointee.type == XML_ELEMENT_NODE || x.pointee.type == XML_TEXT_NODE || x.pointee.type == XML_CDATA_SECTION_NODE {
                return x
            }
            n = forward ? x.pointee.next : x.pointee.prev
        }
        return nil
    }

    private static func isBlock(_ node: xmlNodePtr?) -> Bool {
        guard let node, node.pointee.type == XML_ELEMENT_NODE else { return false }
        return blockElements.contains(name(of: node))
    }

    private func emit(_ node: xmlNodePtr, parentName: String, insideLink: Bool,
                      state: inout State, out: inout String) {
        switch node.pointee.type {
        case XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
            let text = Self.content(of: node)
            if text.isEmpty { return }
            if Self.isWhitespaceOnly(text) {
                // Dictionary.app drops whitespace-only nodes; keep the ones a browser would render.
                if Self.structuralElements.contains(parentName) { return }
                let prev = Self.significantSibling(node.pointee.prev, forward: false)
                let next = Self.significantSibling(node.pointee.next, forward: true)
                if Self.isBlock(prev) || Self.isBlock(next) { return }
                if (prev == nil || next == nil) && Self.blockElements.contains(parentName) { return }
                out += "\u{00A0}"
                return
            }
            Self.escapeText(text, into: &out)

        case XML_ELEMENT_NODE:
            emitElement(node, insideLink: insideLink, state: &state, out: &out)

        case XML_ENTITY_REF_NODE:
            // Unknown entity kept by the parser: write its text if any.
            Self.escapeText(Self.textContent(of: node), into: &out)

        default:
            return  // comments, processing instructions, DTD nodes
        }
    }

    private func emitElement(_ node: xmlNodePtr, insideLink: Bool, state: inout State, out: inout String) {
        var name = Self.name(of: node)
        if !Self.isValidName(name) { name = "span" }

        switch name {
        case "script":
            let attrs = Self.attributes(of: node)
            if let src = attrs.first(where: { $0.0 == "src" })?.1, !src.isEmpty {
                // Kept in place: the file is in the bundle and shared by all entries.
                let path = ResourcePath.normalize(src)
                state.scriptRefs.insert(path)
                Self.emitScript(src: path, into: &out)
                return
            }
            let code = Self.textContent(of: node)
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Self.emitScript(code: code, into: &out)
            return
        case "style":
            state.inlineStyles.append(Self.textContent(of: node))
            return
        case "link":
            collectLink(node, into: &state)
            return
        default:
            if Self.droppedElements.contains(name) { return }
        }

        var attrs = Self.attributes(of: node).filter { Self.isValidName($0.0) && !$0.0.hasPrefix("xmlns") }
        var wrapInClickLink = false
        var childInsideLink = insideLink

        if name == "a" {
            let href = attrs.first(where: { $0.0 == "href" })?.1
            if let href {
                attrs = rewriteLink(href: href, attributes: attrs, state: &state)
                childInsideLink = true
            } else {
                // Named anchor: becomes a plain target the scroll links can find.
                name = "span"
                if let anchor = attrs.first(where: { $0.0 == "name" })?.1, !attrs.contains(where: { $0.0 == "id" }) {
                    attrs.append(("id", anchor))
                }
                attrs.removeAll { $0.0 == "name" }
            }
        }

        // Rewrite resource paths.
        for i in attrs.indices {
            let key = attrs[i].0
            if Self.resourceAttributes.contains(key) {
                attrs[i].1 = ResourcePath.normalize(attrs[i].1)
            } else if key == "style", attrs[i].1.contains("url(") {
                attrs[i].1 = CSSProcessor.rewriteURLs(in: attrs[i].1)
            }
        }

        // Clickable non-link elements: give them a link child so Dictionary.app runs the
        // handler instead of looking up the clicked word.
        let hasHandler = attrs.contains { Self.eventAttributes.contains($0.0) }
        if hasHandler {
            if name != "a" && !Self.voidElements.contains(name) && !insideLink
                && !Self.subtreeContains(node, element: "a") {
                wrapInClickLink = true
                childInsideLink = true
            }
        }

        // Click-only controls get a class the popover style hides (clicks do nothing there).
        if context.markControls {
            let clickOnly: Bool
            if name == "a" {
                let href = attrs.first(where: { $0.0 == "href" })?.1.lowercased() ?? ""
                clickOnly = href.hasPrefix("javascript:") || (href.isEmpty && hasHandler)
            } else {
                clickOnly = hasHandler
            }
            // Pictures stay: an image that enlarges on click is still content.
            if clickOnly && !Self.voidElements.contains(name) && looksLikeControl(node, headwordKey: state.headwordKey) {
                if let i = attrs.firstIndex(where: { $0.0 == "class" }) {
                    attrs[i].1 = attrs[i].1.isEmpty ? "dictbridge-control" : attrs[i].1 + " dictbridge-control"
                } else {
                    attrs.append(("class", "dictbridge-control"))
                }
            }
        }

        out += "<" + name
        for (k, v) in attrs {
            out += " " + k + "=\""
            Self.escapeAttribute(v, into: &out)
            out += "\""
        }
        if Self.voidElements.contains(name) {
            out += "/>"
            return
        }
        out += ">"
        if wrapInClickLink { out += "<a class=\"dictbridge-click\" href=\"javascript:void(0)\">" }
        emitChildren(of: node, parentName: name, insideLink: childInsideLink, state: &state, out: &out)
        if wrapInClickLink { out += "</a>" }
        out += "</" + name + ">"
    }

    // MARK: - Links

    static let jsVoid = "javascript:void(0)"

    private func rewriteLink(href rawHref: String, attributes: [(String, String)], state: inout State) -> [(String, String)] {
        var attrs = attributes.filter { $0.0 != "href" && $0.0 != "name" }
        if let anchor = attributes.first(where: { $0.0 == "name" })?.1, !attributes.contains(where: { $0.0 == "id" }) {
            attrs.append(("id", anchor))
        }
        let href = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = href.lowercased()

        func setHref(_ value: String) { attrs.insert(("href", value), at: 0) }
        func addClass(_ cls: String) {
            if let i = attrs.firstIndex(where: { $0.0 == "class" }) {
                attrs[i].1 = attrs[i].1.isEmpty ? cls : attrs[i].1 + " " + cls
            } else {
                attrs.append(("class", cls))
            }
        }
        func prependClick(_ js: String) {
            if let i = attrs.firstIndex(where: { $0.0 == "onclick" }) {
                attrs[i].1 = js + attrs[i].1
            } else {
                attrs.append(("onclick", js + "return false;"))
            }
        }

        if lower.hasPrefix("sound://") || lower.hasPrefix("snd://") {
            let path = ResourcePath.normalize(String(href[href.index(href.startIndex, offsetBy: lower.hasPrefix("snd://") ? 6 : 8)...]))
            setHref(Self.jsVoid)
            addClass("dictbridge-sound")
            prependClick("new Audio('\(Self.jsString(path))').play();")
            state.audioLinks += 1
        } else if lower.hasPrefix("entry://") || lower.hasPrefix("bword://") {
            let target = String(href.dropFirst(8))
            let decoded = target.removingPercentEncoding ?? target
            let parts = decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let word = parts.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            let fragment = parts.count > 1 ? String(parts[1]) : ""
            if word.isEmpty {
                setHref(Self.jsVoid)
                prependClick(Self.scrollScript(fragment))
            } else if let ids = resolver?.resolve(word), let first = ids.first {
                setHref("x-dictionary:r:\(DDKSourceWriter.entryID(first)):\(context.bundleIdentifier)")
                state.crossLinks += 1
            } else {
                setHref("x-dictionary:d:" + word)
                state.unresolvedLinks += 1
            }
        } else if href.hasPrefix("#") {
            setHref(Self.jsVoid)
            prependClick(Self.scrollScript(String(href.dropFirst())))
        } else if lower.hasPrefix("file://") {
            setHref(ResourcePath.normalize(href))
        } else {
            setHref(href)  // http(s), mailto, x-dictionary, javascript, relative
        }
        return attrs
    }

    static func scrollScript(_ fragment: String) -> String {
        let f = jsString(fragment)
        return "var e=document.getElementById('\(f)')||document.getElementsByName('\(f)')[0];if(e){e.scrollIntoView();}"
    }

    static func jsString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    // MARK: - Escaping

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              (first >= "a" && first <= "z") || (first >= "A" && first <= "Z") || first == "_" else { return false }
        for s in name.unicodeScalars {
            let ok = (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9") || s == "-" || s == "_" || s == "."
            if !ok { return false }
        }
        return true
    }

    static func isWhitespaceOnly(_ s: String) -> Bool {
        for u in s.utf8 where !(u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0x0C) {
            return false
        }
        return true
    }

    @inline(__always)
    static func isXMLChar(_ v: UInt32) -> Bool {
        v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000
    }

    static func escapeText(_ s: String, into out: inout String) {
        var needs = false
        for u in s.utf8 where u == 0x26 || u == 0x3C || u == 0x3E || u < 0x20 || u == 0xEF {
            needs = true
            break
        }
        if !needs { out += s; return }
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\r": continue
            default:
                if isXMLChar(scalar.value) { out.unicodeScalars.append(scalar) }
            }
        }
    }

    static func escapeAttribute(_ s: String, into out: inout String) {
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n": out += "&#10;"
            case "\t": out += "&#9;"
            case "\r": continue
            default:
                if isXMLChar(scalar.value) { out.unicodeScalars.append(scalar) }
            }
        }
    }
}

/// Normalises resource references found in MDict HTML/CSS to bundle-relative paths.
public enum ResourcePath {
    public static func normalize(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = p.lowercased()
        if lower.hasPrefix("data:") || lower.hasPrefix("http:") || lower.hasPrefix("https:")
            || lower.hasPrefix("javascript:") || lower.hasPrefix("x-dictionary:") || lower.hasPrefix("#") {
            return p
        }
        if lower.hasPrefix("file://") { p = String(p.dropFirst(7)) }
        p = p.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasPrefix("./") { p.removeFirst(2) }
        return p
    }

    /// False for web, data and script URLs, which are not files in the dictionary.
    public static func isLocal(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        return !["data:", "http:", "https:", "javascript:", "x-dictionary:", "#", "//", "mailto:"].contains { lower.hasPrefix($0) }
    }

    /// Normalised key used to match references against extracted files (case-insensitive).
    public static func key(_ raw: String) -> String {
        let p = normalize(raw)
        return (p.removingPercentEncoding ?? p).lowercased()
    }
}
