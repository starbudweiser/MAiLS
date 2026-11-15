import Foundation

/// Un message prêt à afficher : mode lecture (texte épuré) et version « originale » nettoyée.
public struct ReadableMessage: Sendable {
    public var headers: ParsedHeaders
    /// Mode lecture : texte épuré.
    public var readingText: String
    /// Liens du message, avec leur adresse réelle (V0 : affichés sous le texte, jamais cliquables dans le texte).
    public var links: [HTMLText.Link]
    /// Version « originale » : HTML nettoyé et protégé (sans script, sans contenu distant).
    public var originalHTML: String
    public var hasHTML: Bool
    public var blockedRemoteCount: Int
    public var trackingPixelCount: Int
    public var attachments: [AttachmentInfo]
    public var truncated: Bool

    public static func make(from raw: [UInt8]) -> ReadableMessage {
        let parsed = MIMEParser.parse(raw)
        let hasHTML = !parsed.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let plain = HTMLText.tidyPlain(parsed.plainText)

        let reading: String
        var links: [HTMLText.Link] = []
        if hasHTML {
            let converted = HTMLText.convert(parsed.html)
            links = converted.links
            // Le texte brut de l'expéditeur prime s'il existe et n'est pas un simple avis (« activez le HTML »).
            reading = plain.count >= 20 ? plain : converted.text
        } else {
            reading = plain
        }
        if links.isEmpty { links = plainLinks(in: reading) }

        let original: SanitizedHTML
        if hasHTML { original = HTMLSanitizer.sanitize(parsed.html, inlineImages: parsed.inlineImages) }
        else { original = SanitizedHTML(html: HTMLSanitizer.wrapPlain(plain), blockedRemote: 0, trackingPixels: 0) }

        return ReadableMessage(
            headers: parsed.headers, readingText: reading, links: links, originalHTML: original.html, hasHTML: hasHTML,
            blockedRemoteCount: original.blockedRemote, trackingPixelCount: original.trackingPixels,
            attachments: parsed.attachments.filter { !$0.isInline }, truncated: parsed.truncated)
    }

    private static func plainLinks(in text: String, limit: Int = 30) -> [HTMLText.Link] {
        guard let re = try? NSRegularExpression(pattern: "https?://[^\\s<>\"')\\]]+") else { return [] }
        var seen = Set<String>()
        var result: [HTMLText.Link] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            var url = String(text[r])
            while let last = url.last, ".,;:!?".contains(last) { url.removeLast() }
            if seen.insert(url).inserted { result.append(HTMLText.Link(label: url, url: url)) }
            if result.count >= limit { break }
        }
        return result
    }
}
