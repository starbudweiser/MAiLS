import Foundation

/// HTML → texte épuré pour le **mode lecture** : titres, paragraphes, listes, citations ; scripts, styles, images et contenus cachés
/// ignorés. Les liens sont recueillis à part (adresse réelle visible, jamais derrière un texte trompeur).
public enum HTMLText {
    public struct Link: Sendable, Equatable {
        public var label: String
        public var url: String
    }

    public struct Output: Sendable, Equatable {
        public var text: String
        public var links: [Link]
    }

    private static let skipWithContent: Set<String> = ["head", "title", "svg", "iframe", "object", "embed", "noscript", "template", "video", "audio", "canvas", "select", "button"]
    private static let blockBlank: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul", "ol", "blockquote", "pre", "dl", "figure"]
    private static let blockLine: Set<String> = ["div", "tr", "li", "dd", "dt", "section", "article", "header", "footer", "form", "address", "center", "fieldset", "main", "nav", "aside", "caption"]

    public static func convert(_ html: String, maxLinks: Int = 40) -> Output {
        var out = ""
        var lineStart = true
        var pendingSpace = false
        var skipTag: String?
        var skipDepth = 0
        var preDepth = 0
        var quoteDepth = 0
        var lists: [(ordered: Bool, index: Int)] = []
        var linkStack: [(url: String, start: String.Index?, label: String)] = []
        var links: [Link] = []

        func newline() { if !out.isEmpty, !out.hasSuffix("\n") { out.append("\n") }; lineStart = true; pendingSpace = false }
        func blankLine() { newline(); if !out.isEmpty, !out.hasSuffix("\n\n") { out.append("\n") } }
        func put(_ s: String) {
            if lineStart, quoteDepth > 0 { out += String(repeating: "> ", count: quoteDepth) }
            out += s
            lineStart = false
            for i in linkStack.indices { linkStack[i].label += s }
        }
        func hidden(_ attrs: [String: String]) -> Bool {
            if attrs["hidden"] != nil || attrs["aria-hidden"] == "true" { return true }
            guard let style = attrs["style"]?.lowercased().filter({ !$0.isWhitespace }) else { return false }
            return style.contains("display:none") || style.contains("visibility:hidden") || style.contains("mso-hide:all")
                || style.contains("max-height:0") || style.contains("font-size:0")
        }

        for token in HTMLTokenizer.tokens(html) {
            switch token {
            case .raw:
                continue
            case .open(let name, let attrs, let selfClosing):
                if let tag = skipTag {
                    if name == tag, !selfClosing { skipDepth += 1 }
                    continue
                }
                if skipWithContent.contains(name) || (hidden(attrs) && !HTMLTokenizer.voidTags.contains(name)) {
                    if !selfClosing { skipTag = name; skipDepth = 1 }
                    continue
                }
                switch name {
                case "br": out.append("\n"); lineStart = true; pendingSpace = false
                case "hr": blankLine(); put("———"); blankLine()
                case "li":
                    newline()
                    if let last = lists.last {
                        lists[lists.count - 1].index += 1
                        put(last.ordered ? "\(lists[lists.count - 1].index). " : "• ")
                    } else { put("• ") }
                    pendingSpace = false
                case "ul", "ol": blankLine(); lists.append((name == "ol", 0))
                case "blockquote": blankLine(); quoteDepth += 1
                case "pre": blankLine(); preDepth += 1
                case "td", "th": if !lineStart { pendingSpace = true }
                case "a":
                    if let href = attrs["href"], let url = safeLinkTarget(href) { linkStack.append((url, nil, "")) }
                    else { linkStack.append(("", nil, "")) }
                case "img":
                    if let alt = attrs["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines), alt.count > 2, !isTiny(attrs) {
                        if pendingSpace, !lineStart { put(" ") }
                        pendingSpace = false
                        put("[\(alt)]")
                    }
                default:
                    if blockBlank.contains(name) { blankLine() } else if blockLine.contains(name) { newline() }
                }
            case .close(let name):
                if let tag = skipTag {
                    if name == tag { skipDepth -= 1; if skipDepth == 0 { skipTag = nil } }
                    continue
                }
                switch name {
                case "ul", "ol": if !lists.isEmpty { lists.removeLast() }; blankLine()
                case "blockquote": quoteDepth = max(0, quoteDepth - 1); blankLine()
                case "pre": preDepth = max(0, preDepth - 1); blankLine()
                case "a":
                    if let link = linkStack.popLast(), !link.url.isEmpty, links.count < maxLinks {
                        let label = link.label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                        if !links.contains(where: { $0.url == link.url }) { links.append(Link(label: label, url: link.url)) }
                    }
                default:
                    if blockBlank.contains(name) { blankLine() } else if blockLine.contains(name) { newline() }
                }
            case .text(let text):
                if skipTag != nil { continue }
                if preDepth > 0 {
                    put(text.replacingOccurrences(of: "\r\n", with: "\n"))
                    if text.hasSuffix("\n") { lineStart = true }
                    continue
                }
                for ch in text {
                    if ch.isWhitespace || ch == "\u{00A0}" { pendingSpace = true; continue }
                    if pendingSpace, !lineStart { put(" ") }
                    pendingSpace = false
                    put(String(ch))
                }
            }
        }
        return Output(text: tidy(out), links: links)
    }

    /// Texte brut : on garde tel quel, en retirant seulement les fins de ligne Windows et les blancs en fin de ligne.
    public static func tidyPlain(_ s: String) -> String { tidy(s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")) }

    private static func tidy(_ s: String) -> String {
        var lines: [String] = []
        var blank = 0
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            while line.last == " " || line.last == "\t" || line.last == "\u{00A0}" { line.removeLast() }
            if line.isEmpty { blank += 1; if blank <= 1 { lines.append(line) } } else { blank = 0; lines.append(line) }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isTiny(_ attrs: [String: String]) -> Bool {
        func px(_ v: String?) -> Int? { v.flatMap { Int($0.lowercased().replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)) } }
        if let w = px(attrs["width"]), w <= 2 { return true }
        if let h = px(attrs["height"]), h <= 2 { return true }
        if let style = attrs["style"]?.lowercased().filter({ !$0.isWhitespace }) {
            if let w = cssPixels(style, "width"), w <= 2 { return true }
            if let h = cssPixels(style, "height"), h <= 2 { return true }
            if style.contains("display:none") { return true }
        }
        return false
    }

    private static func cssPixels(_ style: String, _ prop: String) -> Int? {
        guard let r = style.range(of: prop + ":") else { return nil }
        let rest = style[r.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let after = rest.dropFirst(digits.count)
        guard after.isEmpty || after.hasPrefix("px") || after.hasPrefix(";") || after.hasPrefix("!") else { return nil }
        return Int(digits)
    }

    /// Seuls http, https et mailto sont des destinations de lien ; `javascript:`, `data:`, `file:`… sont refusés (même obfusqués).
    static func safeLinkTarget(_ href: String) -> String? {
        let compact = href.unicodeScalars.filter { !($0.value <= 0x20 || $0.value == 0x7F) }.map(Character.init)
        let normalized = String(compact)
        let lower = normalized.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") else { return nil }
        return href.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
