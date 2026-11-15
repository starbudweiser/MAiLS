import Foundation

enum HTMLToken {
    case text(String)
    case open(name: String, attrs: [String: String], selfClosing: Bool)
    case close(name: String)
    /// Contenu brut de `<script>` ou `<style>` (non analysé).
    case raw(name: String, content: String)
}

/// Découpage HTML tolérant (pas un analyseur complet) : sans exception, borné à 5 Mo, entités décodées dans le texte et les attributs.
enum HTMLTokenizer {
    static let maxBytes = 5 * 1024 * 1024
    static let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "base", "col", "area", "wbr", "source", "track", "param", "embed"]

    static func tokens(_ html: String) -> [HTMLToken] {
        var bytes = Array(html.utf8)
        if bytes.count > maxBytes { bytes.removeSubrange(maxBytes...) }
        var tokens: [HTMLToken] = []
        var i = 0
        var textStart = 0
        let n = bytes.count

        func flushText(_ end: Int) {
            if end > textStart { tokens.append(.text(decodeEntities(String(decoding: bytes[textStart..<end], as: UTF8.self)))) }
        }
        func isLetter(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }
        func find(_ needle: [UInt8], from: Int, caseInsensitive: Bool = false) -> Int? {
            guard !needle.isEmpty, from + needle.count <= n else { return nil }
            var k = from
            outer: while k + needle.count <= n {
                for j in 0..<needle.count {
                    var a = bytes[k + j]
                    if caseInsensitive, a >= 0x41, a <= 0x5A { a += 32 }
                    if a != needle[j] { k += 1; continue outer }
                }
                return k
            }
            return nil
        }

        while i < n {
            guard bytes[i] == 0x3C else { i += 1; continue }  // '<'
            guard i + 1 < n else { i += 1; continue }
            let next = bytes[i + 1]
            if next == 0x21 {  // <! : commentaire ou doctype
                flushText(i)
                if i + 3 < n, bytes[i + 2] == 0x2D, bytes[i + 3] == 0x2D { i = (find([0x2D, 0x2D, 0x3E], from: i + 4).map { $0 + 3 }) ?? n }
                else { i = (find([0x3E], from: i).map { $0 + 1 }) ?? n }
                textStart = i
            } else if next == 0x3F {  // <? : instruction
                flushText(i)
                i = (find([0x3E], from: i).map { $0 + 1 }) ?? n
                textStart = i
            } else if next == 0x2F, i + 2 < n, isLetter(bytes[i + 2]) {  // </nom>
                flushText(i)
                var j = i + 2
                while j < n, bytes[j] != 0x3E, !isSpace(bytes[j]) { j += 1 }
                let name = String(decoding: bytes[(i + 2)..<j], as: UTF8.self).lowercased()
                while j < n, bytes[j] != 0x3E { j += 1 }
                tokens.append(.close(name: name))
                i = min(j + 1, n)
                textStart = i
            } else if isLetter(next) {  // <nom …>
                flushText(i)
                var j = i + 1
                while j < n, !isSpace(bytes[j]), bytes[j] != 0x3E, bytes[j] != 0x2F { j += 1 }
                let name = String(decoding: bytes[(i + 1)..<j], as: UTF8.self).lowercased()
                var attrs: [String: String] = [:]
                var selfClosing = false
                while j < n {
                    while j < n, isSpace(bytes[j]) { j += 1 }
                    if j >= n { break }
                    if bytes[j] == 0x3E { j += 1; break }
                    if bytes[j] == 0x2F { selfClosing = true; j += 1; continue }
                    let nameStart = j
                    while j < n, !isSpace(bytes[j]), bytes[j] != 0x3D, bytes[j] != 0x3E, bytes[j] != 0x2F { j += 1 }
                    let attrName = String(decoding: bytes[nameStart..<j], as: UTF8.self).lowercased()
                    while j < n, isSpace(bytes[j]) { j += 1 }
                    var value = ""
                    if j < n, bytes[j] == 0x3D {
                        j += 1
                        while j < n, isSpace(bytes[j]) { j += 1 }
                        if j < n, bytes[j] == 0x22 || bytes[j] == 0x27 {
                            let quote = bytes[j]
                            j += 1
                            let vs = j
                            while j < n, bytes[j] != quote { j += 1 }
                            value = String(decoding: bytes[vs..<min(j, n)], as: UTF8.self)
                            j = min(j + 1, n)
                        } else {
                            let vs = j
                            while j < n, !isSpace(bytes[j]), bytes[j] != 0x3E { j += 1 }
                            value = String(decoding: bytes[vs..<j], as: UTF8.self)
                        }
                    }
                    if !attrName.isEmpty, attrs[attrName] == nil { attrs[attrName] = decodeEntities(value) }
                }
                i = min(j, n)
                if name == "script" || name == "style" {
                    let close = Array("</\(name)".utf8)
                    let end = find(close, from: i, caseInsensitive: true) ?? n
                    tokens.append(.open(name: name, attrs: attrs, selfClosing: false))
                    tokens.append(.raw(name: name, content: String(decoding: bytes[i..<end], as: UTF8.self)))
                    tokens.append(.close(name: name))
                    i = (find([0x3E], from: end).map { $0 + 1 }) ?? n
                } else {
                    tokens.append(.open(name: name, attrs: attrs, selfClosing: selfClosing || voidTags.contains(name)))
                }
                textStart = i
            } else {
                i += 1
            }
        }
        flushText(n)
        return tokens
    }

    // MARK: Entités

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "ndash": "–", "mdash": "—",
        "hellip": "…", "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "euro": "€",
        "copy": "©", "reg": "®", "trade": "™", "bull": "•", "middot": "·", "deg": "°", "times": "×", "eacute": "é",
        "egrave": "è", "ecirc": "ê", "euml": "ë", "agrave": "à", "acirc": "â", "auml": "ä", "aring": "å", "ccedil": "ç",
        "icirc": "î", "iuml": "ï", "ocirc": "ô", "ouml": "ö", "ugrave": "ù", "ucirc": "û", "uuml": "ü", "Eacute": "É",
        "Egrave": "È", "Agrave": "À", "Ccedil": "Ç", "ntilde": "ñ", "iacute": "í", "oacute": "ó", "aacute": "á",
        "uacute": "ú", "szlig": "ß", "oelig": "œ", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶",
        "iexcl": "¡", "iquest": "¿", "frac12": "½", "frac14": "¼", "frac34": "¾", "rarr": "→", "larr": "←", "zwnj": "",
        "zwj": "", "shy": "",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = s[s.index(after: i)..<semi]
                var replacement: String?
                if body.hasPrefix("#") {
                    let digits = body.dropFirst()
                    let value: UInt32? = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                    if let v = value, let scalar = Unicode.Scalar(v) { replacement = String(Character(scalar)) }
                } else {
                    replacement = named[String(body)]
                }
                if let r = replacement { out += r; i = s.index(after: semi); continue }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }
}
