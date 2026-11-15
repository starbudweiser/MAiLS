import Foundation

public struct SanitizedHTML: Sendable, Equatable {
    public var html: String
    /// Images distantes retirées (hors pixels de suivi).
    public var blockedRemote: Int
    /// Pixels et balises de suivi retirés (images de 1 à 2 px, masquées).
    public var trackingPixels: Int
}

/// Nettoyage du HTML pour l'affichage « original » : liste blanche de balises et d'attributs, aucun script, aucun contenu distant,
/// aucune image externe (les `cid:` deviennent des images intégrées), liens `http(s)`/`mailto` seulement.
/// Défense en profondeur : la vue web désactive aussi JavaScript et bloque tout chargement distant (voir `docs/ARCHITECTURE.md` § 6).
public enum HTMLSanitizer {
    private static let allowedTags: Set<String> = [
        "a", "abbr", "address", "article", "aside", "b", "big", "blockquote", "br", "caption", "center", "cite", "code", "col", "colgroup", "dd",
        "del", "div", "dl", "dt", "em", "font", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "i", "img", "ins", "li", "main",
        "mark", "nav", "ol", "p", "pre", "q", "s", "section", "small", "span", "strike", "strong", "sub", "sup", "table", "tbody", "td", "tfoot",
        "th", "thead", "tr", "tt", "u", "ul",
    ]
    private static let dropWithContent: Set<String> = ["script", "iframe", "object", "embed", "svg", "video", "audio", "canvas", "title", "noscript", "template", "head", "select", "textarea", "button"]
    private static let allowedAttributes: Set<String> = [
        "align", "valign", "width", "height", "bgcolor", "color", "colspan", "rowspan", "border", "cellpadding", "cellspacing", "dir", "lang",
        "title", "face", "size", "nowrap", "alt",
    ]
    static let contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'"

    public static func sanitize(_ html: String, inlineImages: [String: InlineImage] = [:]) -> SanitizedHTML {
        var out = ""
        var blocked = 0
        var trackers = 0
        var skipTag: String?
        var skipDepth = 0

        for token in HTMLTokenizer.tokens(html) {
            switch token {
            case .text(let t):
                if skipTag == nil { out += escape(t) }
            case .raw(let name, let content):
                if skipTag == nil, name == "style" { out += "<style>" + sanitizeCSS(content) + "</style>" }
            case .open(let name, let attrs, let selfClosing):
                if let tag = skipTag {
                    if name == tag, !selfClosing { skipDepth += 1 }
                    continue
                }
                if name == "style" || name == "script" { continue }  // contenu géré par `.raw`
                if dropWithContent.contains(name) {
                    if !selfClosing { skipTag = name; skipDepth = 1 }
                    continue
                }
                guard allowedTags.contains(name) else { continue }  // balise inconnue : retirée, contenu gardé
                if HTMLText.isTinyAttrs(attrs), name == "img" { trackers += 1; continue }
                var rendered = "<" + name
                for (key, value) in attrs.sorted(by: { $0.key < $1.key }) {
                    if allowedAttributes.contains(key) { rendered += " \(key)=\"\(escapeAttribute(value))\"" }
                }
                if let style = attrs["style"] {
                    let cleaned = sanitizeStyleAttribute(style)
                    if !cleaned.isEmpty { rendered += " style=\"\(escapeAttribute(cleaned))\"" }
                }
                if name == "a" {
                    if let href = attrs["href"], let safe = HTMLText.safeLinkTarget(href) {
                        rendered += " href=\"\(escapeAttribute(safe))\" rel=\"noopener noreferrer\""
                    }
                }
                if name == "img" {
                    guard let src = attrs["src"]?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                    let lower = src.lowercased()
                    if lower.hasPrefix("cid:") {
                        let cid = String(src.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                        if let image = inlineImages[cid], isSafeRaster(image.mime) {
                            rendered += " src=\"data:\(image.mime);base64,\(Data(image.data).base64EncodedString())\""
                        } else { continue }
                    } else if lower.hasPrefix("data:image/"), isSafeRaster(String(lower.dropFirst(5).prefix { $0 != ";" && $0 != "," })) {
                        rendered += " src=\"\(escapeAttribute(src))\""
                    } else {
                        blocked += 1
                        continue
                    }
                }
                rendered += ">"
                out += rendered
            case .close(let name):
                if let tag = skipTag {
                    if name == tag { skipDepth -= 1; if skipDepth == 0 { skipTag = nil } }
                    continue
                }
                if allowedTags.contains(name), !HTMLTokenizer.voidTags.contains(name) { out += "</\(name)>" }
            }
        }
        let page = """
            <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">\
            <style>:root{color-scheme:light}body{margin:16px;font:14px/1.5 -apple-system,sans-serif;color:#111;background:#fff;word-wrap:break-word}\
            img{max-width:100%;height:auto}table{max-width:100%}pre{white-space:pre-wrap}</style></head><body>\(out)</body></html>
            """
        return SanitizedHTML(html: page, blockedRemote: blocked, trackingPixels: trackers)
    }

    /// Message sans HTML : le texte est présenté tel quel dans la même enveloppe protégée.
    public static func wrapPlain(_ text: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">\
        <style>:root{color-scheme:light}body{margin:16px;font:14px/1.5 -apple-system,sans-serif;color:#111;background:#fff}pre{white-space:pre-wrap;font:inherit;margin:0}</style>\
        </head><body><pre>\(escape(text))</pre></body></html>
        """
    }

    private static func isSafeRaster(_ mime: String) -> Bool {
        ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp", "image/bmp"].contains(mime.lowercased())
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Déclarations CSS : celles qui chargent quelque chose (`url(`), exécutent (`expression`) ou superposent (`position`) sont retirées.
    static func sanitizeStyleAttribute(_ style: String) -> String {
        style.split(separator: ";").map(String.init).filter { decl in
            let d = decl.lowercased().filter { !$0.isWhitespace }
            return !(d.contains("url(") || d.contains("expression") || d.contains("javascript") || d.contains("behavior") || d.contains("-moz-binding")
                || d.hasPrefix("position:") || d.hasPrefix("z-index") || d.contains("@import"))
        }.joined(separator: ";")
    }

    static func sanitizeCSS(_ css: String) -> String {
        var s = css
        for pattern in ["@import[^;]*;", "url\\([^)]*\\)", "expression\\([^)]*\\)", "position\\s*:\\s*(fixed|absolute|sticky)\\s*;?", "behavior\\s*:[^;}]*;?", "-moz-binding\\s*:[^;}]*;?"] {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: pattern.hasPrefix("url") ? "none" : "")
            }
        }
        return s.replacingOccurrences(of: "</", with: "<\\/")  // jamais de fermeture de balise dans une feuille de style
    }
}

extension HTMLText {
    static func isTinyAttrs(_ attrs: [String: String]) -> Bool { isTiny(attrs) }
}
