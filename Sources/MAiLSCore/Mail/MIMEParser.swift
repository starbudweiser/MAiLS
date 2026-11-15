import Foundation

public struct AttachmentInfo: Sendable, Equatable {
    public var filename: String
    public var contentType: String
    public var size: Int
    public var contentID: String?
    public var isInline: Bool
}

public struct InlineImage: Sendable, Equatable {
    public var mime: String
    public var data: [UInt8]
}

public struct ParsedMessage: Sendable {
    public var headers: ParsedHeaders
    /// Parties `text/plain` affichables, dans l'ordre du message.
    public var plainText: String
    /// Parties `text/html` affichables.
    public var html: String
    public var attachments: [AttachmentInfo] = []
    /// Images référencées par `cid:` (clé : Content-ID sans chevrons), 5 Mo maximum chacune.
    public var inlineImages: [String: InlineImage] = [:]
    /// Vrai si les limites de profondeur ou de nombre de parties ont été atteintes (message piégé ou démesuré).
    public var truncated = false
}

/// Analyse MIME (RFC 2045/2046/2231), bornée : profondeur 10, 300 parties. Ne plante sur aucune entrée.
public enum MIMEParser {
    static let maxDepth = 10
    static let maxParts = 300
    static let maxInlineImageBytes = 5 * 1024 * 1024

    public static func parse(_ raw: [UInt8]) -> ParsedMessage {
        let (headerBytes, body) = splitHeaderBody(raw[...])
        var result = ParsedMessage(headers: HeaderParser.parse(Array(headerBytes)), plainText: "", html: "")
        var state = WalkState()
        walk(PartHeaders(HeaderParser.unfold(Array(headerBytes))), body, depth: 0, state: &state, result: &result)
        result.plainText = state.plain.joined(separator: "\n\n")
        result.html = state.html.joined(separator: "\n")
        result.truncated = state.truncated
        return result
    }

    // MARK: Structure

    private struct WalkState {
        var plain: [String] = []
        var html: [String] = []
        var parts = 0
        var truncated = false
    }

    struct PartHeaders {
        var type = "text/plain"
        var params: [String: String] = [:]
        var transferEncoding = "7bit"
        var disposition: String?
        var dispositionParams: [String: String] = [:]
        var contentID: String?

        init(_ fields: [(name: String, value: String)]) {
            for (name, value) in fields {
                switch name {
                case "content-type":
                    let (main, params) = MIMEParser.parseParameterized(value)
                    if !main.isEmpty { type = main.lowercased() }
                    self.params = params
                case "content-transfer-encoding": transferEncoding = value.trimmingCharacters(in: .whitespaces).lowercased()
                case "content-disposition":
                    let (main, params) = MIMEParser.parseParameterized(value)
                    disposition = main.lowercased()
                    dispositionParams = params
                case "content-id":
                    contentID = HeaderParser.messageIDs(in: value).first ?? value.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
                default: break
                }
            }
        }

        var filename: String? { dispositionParams["filename"] ?? params["name"] }
    }

    private static func walk(_ headers: PartHeaders, _ body: ArraySlice<UInt8>, depth: Int, state: inout WalkState, result: inout ParsedMessage) {
        state.parts += 1
        if state.parts > maxParts || depth > maxDepth { state.truncated = true; return }

        if headers.type.hasPrefix("multipart/"), let boundary = headers.params["boundary"], !boundary.isEmpty {
            for part in splitMultipart(body, boundary: boundary) {
                let (h, b) = splitHeaderBody(part)
                walk(PartHeaders(HeaderParser.unfold(Array(h))), b, depth: depth + 1, state: &state, result: &result)
                if state.truncated && state.parts > maxParts { return }
            }
            return
        }

        let isAttachmentDisposition = headers.disposition == "attachment"
        let hasFilename = headers.filename != nil
        let isText = headers.type == "text/plain" || headers.type == "text/html"

        if isText, !isAttachmentDisposition, !(hasFilename && headers.disposition != "inline") {
            let bytes = decodeTransfer(body, encoding: headers.transferEncoding)
            let text = decodeText(bytes, charset: headers.params["charset"])
            if headers.type == "text/html" { state.html.append(text) } else { state.plain.append(text) }
            return
        }

        // Pièce jointe, image intégrée, message transmis, invitation…
        let cid = headers.contentID
        let size = decodedSize(body, encoding: headers.transferEncoding)
        let name = headers.filename.map { HeaderParser.decodeEncodedWords($0) } ?? defaultName(for: headers.type)
        let inline = headers.disposition == "inline" || (cid != nil && headers.type.hasPrefix("image/"))
        result.attachments.append(AttachmentInfo(filename: name, contentType: headers.type, size: size, contentID: cid, isInline: inline && cid != nil))
        if let cid, headers.type.hasPrefix("image/"), size <= maxInlineImageBytes {
            result.inlineImages[cid] = InlineImage(mime: headers.type, data: decodeTransfer(body, encoding: headers.transferEncoding))
        }
    }

    private static func defaultName(for type: String) -> String {
        switch type {
        case "message/rfc822": return "message.eml"
        case "text/calendar": return "invitation.ics"
        default: return "pièce-jointe"
        }
    }

    // MARK: Découpage

    /// Sépare en-têtes et corps à la première ligne vide (CRLF ou LF seul).
    static func splitHeaderBody(_ data: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        var i = data.startIndex
        while i < data.endIndex {
            var lineEnd = i
            while lineEnd < data.endIndex, data[lineEnd] != 0x0A { lineEnd += 1 }
            var content = lineEnd
            if content > i, data[content - 1] == 0x0D { content -= 1 }
            if content == i {  // ligne vide
                let bodyStart = min(lineEnd + 1, data.endIndex)
                return (data[data.startIndex..<i], data[bodyStart...])
            }
            i = lineEnd + 1
        }
        return (data, data[data.endIndex...])
    }

    /// Les parties d'un `multipart` : entre les lignes `--boundary` ; le préambule et l'épilogue sont ignorés.
    static func splitMultipart(_ data: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let marker = Array(("--" + boundary).utf8)
        var parts: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var i = data.startIndex
        while i < data.endIndex {
            var lineEnd = i
            while lineEnd < data.endIndex, data[lineEnd] != 0x0A { lineEnd += 1 }
            var content = lineEnd
            if content > i, data[content - 1] == 0x0D { content -= 1 }
            let line = data[i..<content]
            if line.count >= marker.count, line.prefix(marker.count).elementsEqual(marker) {
                let rest = line.dropFirst(marker.count)
                let isClose = rest.starts(with: [0x2D, 0x2D])
                let isDelimiter = isClose || rest.allSatisfy { $0 == 0x20 || $0 == 0x09 }
                if isDelimiter {
                    if let start = partStart {
                        var end = i
                        if end > start, data[end - 1] == 0x0A { end -= 1 }
                        if end > start, data[end - 1] == 0x0D { end -= 1 }
                        parts.append(data[start..<max(start, end)])
                    }
                    if isClose { return parts }
                    partStart = min(lineEnd + 1, data.endIndex)
                }
            }
            i = lineEnd + 1
        }
        if let start = partStart, start < data.endIndex { parts.append(data[start...]) }  // fermeture manquante
        return parts
    }

    // MARK: Paramètres (RFC 2045 / 2231)

    /// `multipart/mixed; boundary="x"; name*=utf-8''%C3%A9.txt` → ("multipart/mixed", ["boundary": "x", "name": "é.txt"]).
    static func parseParameterized(_ value: String) -> (String, [String: String]) {
        var pieces: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        for c in value {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\", inQuote { current.append(c); escaped = true; continue }
            if c == "\"" { inQuote.toggle(); current.append(c); continue }
            if c == ";", !inQuote { pieces.append(current); current = ""; continue }
            current.append(c)
        }
        pieces.append(current)
        let main = pieces.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var raw: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            raw[key] = val
        }
        return (main, mergeRFC2231(raw))
    }

    private static func mergeRFC2231(_ raw: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        var grouped: [String: [(Int, String, Bool)]] = [:]
        for (key, value) in raw {
            if key.contains("*") {
                var base = key
                var index = 0
                var encoded = false
                if base.hasSuffix("*") { encoded = true; base.removeLast() }
                if let star = base.lastIndex(of: "*"), let n = Int(base[base.index(after: star)...]) {
                    index = n
                    base = String(base[..<star])
                }
                grouped[base, default: []].append((index, value, encoded))
            } else {
                result[key] = value
            }
        }
        for (base, pieces) in grouped where result[base] == nil {
            let sorted = pieces.sorted { $0.0 < $1.0 }
            var charset = "utf-8"
            var bytes: [UInt8] = []
            for (i, piece) in sorted.enumerated() {
                var v = piece.1
                if piece.2 {
                    if i == 0 {
                        let parts = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if parts.count == 3 { charset = String(parts[0]).isEmpty ? "utf-8" : String(parts[0]); v = String(parts[2]) }
                    }
                    bytes += percentDecode(v)
                } else {
                    bytes += Array(v.utf8)
                }
            }
            result[base] = HeaderParser.decodeBytes(bytes, charset: charset) ?? String(decoding: bytes, as: UTF8.self)
        }
        return result
    }

    private static func percentDecode(_ s: String) -> [UInt8] {
        let u = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x37
            case 0x61...0x66: return c - 0x57
            default: return nil
            }
        }
        while i < u.count {
            if u[i] == 0x25, i + 2 < u.count, let h = hex(u[i + 1]), let l = hex(u[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else { out.append(u[i]); i += 1 }
        }
        return out
    }

    // MARK: Décodage du contenu

    static func decodeTransfer(_ body: ArraySlice<UInt8>, encoding: String) -> [UInt8] {
        switch encoding {
        case "base64":
            let cleaned = body.filter { !($0 == 0x0A || $0 == 0x0D || $0 == 0x20 || $0 == 0x09) }
            var padded = cleaned
            while padded.count % 4 != 0 { padded.append(0x3D) }
            return Data(base64Encoded: Data(padded)).map { [UInt8]($0) } ?? []
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return Array(body)
        }
    }

    static func decodedSize(_ body: ArraySlice<UInt8>, encoding: String) -> Int {
        switch encoding {
        case "base64":
            var count = 0
            var padding = 0
            for b in body {
                if b == 0x0A || b == 0x0D || b == 0x20 || b == 0x09 { continue }
                if b == 0x3D { padding += 1 } else { count += 1 }
            }
            return max(0, (count + padding) / 4 * 3 - padding)
        case "quoted-printable":
            return decodeQuotedPrintable(body).count
        default:
            return body.count
        }
    }

    static func decodeQuotedPrintable(_ body: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(body.count)
        let u = Array(body)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x37
            case 0x61...0x66: return c - 0x57
            default: return nil
            }
        }
        while i < u.count {
            let c = u[i]
            if c == 0x3D {  // '='
                if i + 1 < u.count, u[i + 1] == 0x0A { i += 2; continue }                                  // saut de ligne doux (LF)
                if i + 2 < u.count, u[i + 1] == 0x0D, u[i + 2] == 0x0A { i += 3; continue }                // saut de ligne doux (CRLF)
                if i + 2 < u.count, let h = hex(u[i + 1]), let l = hex(u[i + 2]) { out.append(h << 4 | l); i += 3; continue }
                out.append(c); i += 1
            } else { out.append(c); i += 1 }
        }
        return out
    }

    static func decodeText(_ bytes: [UInt8], charset: String?) -> String {
        var data = bytes
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        if let charset, !charset.isEmpty, let s = HeaderParser.decodeBytes(data, charset: charset) { return s }
        if let s = String(validating: data, as: UTF8.self) { return s }
        // Charset absent ou inconnu et octets non UTF-8 : le Latin-1 ne perd aucun octet.
        return String(data.map { Character(UnicodeScalar($0)) })
    }
}
