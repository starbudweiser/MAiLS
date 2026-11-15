import Foundation

/// Une adresse e-mail avec son nom d'affichage éventuel (déjà décodé).
public struct MailAddress: Sendable, Equatable {
    public var name: String?
    public var email: String

    public init(name: String?, email: String) {
        self.name = name
        self.email = email
    }
}

/// Les en-têtes utiles à MAiLS, décodés (RFC 5322 / RFC 2047).
public struct ParsedHeaders: Sendable, Equatable {
    public var subject: String = ""
    public var from: MailAddress?
    public var to: [MailAddress] = []
    public var cc: [MailAddress] = []
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String] = []
    /// En-tête `Date`, en secondes depuis 1970 (UTC). `nil` s'il est absent ou illisible.
    public var sentAt: Int64?
    /// Première URL `https:` de `List-Unsubscribe` (sinon la première `mailto:`).
    public var unsubscribeURL: String?
    /// `List-Unsubscribe-Post: List-Unsubscribe=One-Click` (RFC 8058).
    public var unsubscribeOneClick = false

    public init() {}
}

/// Analyse des en-têtes de message. Pur, sans état, sans réseau : testable seul.
public enum HeaderParser {
    /// Champs à demander au serveur (`BODY.PEEK[HEADER.FIELDS (…)]`).
    public static let requestedFields = [
        "FROM", "TO", "CC", "SUBJECT", "DATE", "MESSAGE-ID", "IN-REPLY-TO", "REFERENCES",
        "LIST-UNSUBSCRIBE", "LIST-UNSUBSCRIBE-POST",
    ]

    public static func parse(_ bytes: [UInt8]) -> ParsedHeaders {
        var result = ParsedHeaders()
        for (name, value) in unfold(bytes) {
            switch name {
            case "subject":
                result.subject = decodeEncodedWords(value).trimmingCharacters(in: .whitespaces)
            case "from":
                result.from = parseAddresses(value).first
            case "to":
                result.to += parseAddresses(value)
            case "cc":
                result.cc += parseAddresses(value)
            case "message-id":
                result.messageID = messageIDs(in: value).first
            case "in-reply-to":
                result.inReplyTo = messageIDs(in: value).first
            case "references":
                result.references = messageIDs(in: value)
            case "date":
                result.sentAt = parseDate(value)
            case "list-unsubscribe":
                result.unsubscribeURL = unsubscribeTarget(value)
            case "list-unsubscribe-post":
                result.unsubscribeOneClick = value.lowercased().contains("list-unsubscribe=one-click")
            default:
                break
            }
        }
        return result
    }

    // MARK: - Dépliage

    /// Découpe un bloc d'en-têtes en (nom en minuscules, valeur dépliée). S'arrête à la première ligne vide.
    /// Les octets sont lus en UTF-8 ; à défaut, en ISO-8859-1 (certains vieux expéditeurs envoient du 8 bits brut).
    static func unfold(_ bytes: [UInt8]) -> [(name: String, value: String)] {
        var fields: [(String, String)] = []
        var currentName: String?
        var currentValue = ""

        func flush() {
            if let name = currentName { fields.append((name, currentValue)) }
            currentName = nil
            currentValue = ""
        }

        var lineStart = 0
        let count = bytes.count
        while lineStart < count {
            var lineEnd = lineStart
            while lineEnd < count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            var contentEnd = lineEnd
            if contentEnd > lineStart, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let line = decodeLine(bytes[lineStart..<contentEnd])
            lineStart = lineEnd + 1

            if line.isEmpty { break }  // fin des en-têtes
            if let first = line.unicodeScalars.first, first == " " || first == "\t" {
                if currentName != nil { currentValue += " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            currentName = line[..<colon].lowercased()
            currentValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        flush()
        return fields
    }

    private static func decodeLine(_ slice: ArraySlice<UInt8>) -> String {
        if let s = String(validating: slice, as: UTF8.self) { return s }
        return String(slice.map { Character(UnicodeScalar($0)) })  // ISO-8859-1 brut
    }

    // MARK: - RFC 2047

    /// Décode les « mots codés » `=?charset?B|Q?texte?=`. Les mots adjacents (séparés seulement par des
    /// espaces) sont recollés sans l'espace, comme le veut la RFC.
    public static func decodeEncodedWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var out = ""
        var rest = Substring(input)
        var previousWasEncoded = false
        var pendingSpace = ""

        while !rest.isEmpty {
            if let (decoded, remaining) = scanEncodedWord(rest) {
                if !previousWasEncoded { out += pendingSpace }
                pendingSpace = ""
                out += decoded
                rest = remaining
                previousWasEncoded = true
                continue
            }
            // Pas de mot codé ici : avaler un éventuel bloc d'espaces, puis un « mot » ordinaire.
            if let ch = rest.first, ch == " " || ch == "\t" {
                var spaces = ""
                while let c = rest.first, c == " " || c == "\t" { spaces.append(c); rest = rest.dropFirst() }
                if previousWasEncoded { pendingSpace = spaces } else { out += spaces }
                continue
            }
            out += pendingSpace
            pendingSpace = ""
            previousWasEncoded = false
            var word = ""
            while let c = rest.first, c != " ", c != "\t" {
                if c == "=", rest.dropFirst().first == "?", !word.isEmpty { break }
                word.append(c)
                rest = rest.dropFirst()
            }
            if word.isEmpty, let c = rest.first { word.append(c); rest = rest.dropFirst() }
            out += word
        }
        out += pendingSpace
        return out
    }

    private static func scanEncodedWord(_ s: Substring) -> (String, Substring)? {
        guard s.hasPrefix("=?") else { return nil }
        var idx = s.index(s.startIndex, offsetBy: 2)
        func field(until stop: Character) -> String? {
            let start = idx
            while idx < s.endIndex, s[idx] != stop {
                if s[idx] == " " || s[idx] == "\t" { return nil }
                idx = s.index(after: idx)
            }
            guard idx < s.endIndex else { return nil }
            let value = String(s[start..<idx])
            idx = s.index(after: idx)
            return value
        }
        guard var charset = field(until: "?"), let enc = field(until: "?"), enc.count == 1 else { return nil }
        // Texte chiffré jusqu'à « ?= »
        let textStart = idx
        guard let end = s[textStart...].range(of: "?=") else { return nil }
        let payload = String(s[textStart..<end.lowerBound])
        if payload.contains(" ") { return nil }
        if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }  // RFC 2231 : langue
        let bytes: [UInt8]?
        switch enc.uppercased() {
        case "B": bytes = decodeBase64Lenient(payload)
        case "Q": bytes = decodeQ(payload)
        default: return nil
        }
        guard let bytes, let text = decodeBytes(bytes, charset: charset) else { return nil }
        return (text, s[end.upperBound...])
    }

    static func decodeQ(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == UInt8(ascii: "_") { out.append(0x20); i += 1 }
            else if c == UInt8(ascii: "="), i + 2 < u.count, let h = hex(u[i + 1]), let l = hex(u[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else { out.append(c); i += 1 }
        }
        return out
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    static func decodeBase64Lenient(_ s: String) -> [UInt8]? {
        var padded = s
        while padded.utf8.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded).map { [UInt8]($0) }
    }

    static func decodeBytes(_ bytes: [UInt8], charset: String) -> String? {
        let name = charset.lowercased()
        if name == "utf-8" || name == "utf8" { return String(validating: bytes, as: UTF8.self) ?? String(decoding: bytes, as: UTF8.self) }
        if name == "us-ascii" || name == "ascii" { return String(decoding: bytes, as: UTF8.self) }
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        return String(data: Data(bytes), encoding: enc)
    }

    // MARK: - Adresses

    /// Analyse une liste d'adresses (`From`, `To`, `Cc`) : `Nom <a@b>`, `"Nom, Prénom" <a@b>`, `a@b (Nom)`,
    /// groupes `Équipe: a@b, c@d;`, mots codés, commentaires.
    public static func parseAddresses(_ input: String) -> [MailAddress] {
        var results: [MailAddress] = []
        for part in splitTopLevel(input) {
            if let address = parseSingleAddress(part) { results.append(address) }
        }
        return results
    }

    /// Coupe sur les virgules qui ne sont ni dans des guillemets, ni dans <>, ni dans un commentaire ;
    /// traite les groupes (`nom: … ;`) en gardant leurs membres.
    static func splitTopLevel(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false
        var inAngle = false
        var commentDepth = 0
        var escaped = false
        for c in s {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\", inQuote || commentDepth > 0 { current.append(c); escaped = true; continue }
            if inQuote { if c == "\"" { inQuote = false }; current.append(c); continue }
            if commentDepth > 0 {
                if c == "(" { commentDepth += 1 } else if c == ")" { commentDepth -= 1 }
                current.append(c)
                continue
            }
            switch c {
            case "\"": inQuote = true; current.append(c)
            case "(": commentDepth = 1; current.append(c)
            case "<": inAngle = true; current.append(c)
            case ">": inAngle = false; current.append(c)
            case ",", ";":
                if inAngle { current.append(c) } else { parts.append(current); current = "" }
            case ":":
                // « Groupe: » en tête d'un segment sans adresse → on jette le nom de groupe.
                if !inAngle, !current.contains("@"), !current.contains("<") { current = "" } else { current.append(c) }
            default: current.append(c)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func parseSingleAddress(_ raw: String) -> MailAddress? {
        let (text, comments) = stripComments(raw)
        var name: String?
        var email: String

        if let lt = lastTopLevelIndex(of: "<", in: text), let gt = text[lt...].firstIndex(of: ">") {
            email = String(text[text.index(after: lt)..<gt])
            name = String(text[..<lt])
        } else {
            email = text
            name = comments.first  // ancien style : a@b (Nom)
        }
        email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if email.hasPrefix("<"), email.hasSuffix(">") { email = String(email.dropFirst().dropLast()) }
        // Route source obsolète : <@a,@b:user@host>
        if let colon = email.lastIndex(of: ":"), email.hasPrefix("@") { email = String(email[email.index(after: colon)...]) }
        email = email.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        guard !email.isEmpty, !email.contains(" ") else { return nil }

        if let n = name {
            let cleaned = unquote(n.trimmingCharacters(in: .whitespacesAndNewlines))
            let decoded = decodeEncodedWords(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
            name = decoded.isEmpty ? nil : decoded
        }
        if name == email { name = nil }
        return MailAddress(name: name, email: email.lowercased())
    }

    private static func lastTopLevelIndex(of target: Character, in s: String) -> String.Index? {
        var inQuote = false
        var found: String.Index?
        var i = s.startIndex
        var escaped = false
        while i < s.endIndex {
            let c = s[i]
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { inQuote.toggle() }
            else if c == target, !inQuote { found = i }
            i = s.index(after: i)
        }
        return found
    }

    private static func stripComments(_ s: String) -> (String, [String]) {
        var out = ""
        var comments: [String] = []
        var depth = 0
        var current = ""
        var inQuote = false
        var escaped = false
        for c in s {
            if escaped { if depth > 0 { current.append(c) } else { out.append(c) }; escaped = false; continue }
            if c == "\\" { escaped = true; if depth > 0 { current.append(c) } else { out.append(c) }; continue }
            if depth == 0, c == "\"" { inQuote.toggle(); out.append(c); continue }
            if inQuote { out.append(c); continue }
            if c == "(" { if depth > 0 { current.append(c) }; depth += 1; continue }
            if c == ")", depth > 0 {
                depth -= 1
                if depth == 0 { comments.append(decodeEncodedWords(current).trimmingCharacters(in: .whitespaces)); current = "" } else { current.append(c) }
                continue
            }
            if depth > 0 { current.append(c) } else { out.append(c) }
        }
        return (out, comments)
    }

    private static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
        var out = ""
        var escaped = false
        for c in s.dropFirst().dropLast() {
            if escaped { out.append(c); escaped = false } else if c == "\\" { escaped = true } else { out.append(c) }
        }
        return out
    }

    // MARK: - Identifiants et désabonnement

    static func messageIDs(in s: String) -> [String] {
        var ids: [String] = []
        var current: String?
        for c in s {
            if c == "<" { current = "" }
            else if c == ">" { if let id = current, !id.isEmpty { ids.append(id) }; current = nil }
            else if current != nil { current?.append(c) }
        }
        return ids
    }

    static func unsubscribeTarget(_ s: String) -> String? {
        let targets = s.split(separator: ",").compactMap { part -> String? in
            guard let lt = part.firstIndex(of: "<"), let gt = part.firstIndex(of: ">"), lt < gt else { return nil }
            return String(part[part.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
        }
        return targets.first { $0.lowercased().hasPrefix("https://") } ?? targets.first
    }

    // MARK: - Dates (RFC 5322)

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let zones: [String: Int] = [
        "ut": 0, "utc": 0, "gmt": 0, "z": 0, "est": -300, "edt": -240, "cst": -360, "cdt": -300,
        "mst": -420, "mdt": -360, "pst": -480, "pdt": -420, "cet": 60, "cest": 120, "bst": 60,
    ]

    /// `Mon, 01 Jan 2024 02:01:00 +0200 (CEST)` → secondes UTC depuis 1970. `nil` si illisible.
    public static func parseDate(_ input: String) -> Int64? {
        var s = stripComments(input).0
        if let comma = s.firstIndex(of: ",") { s = String(s[s.index(after: comma)...]) }
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 4 else { return nil }
        guard let day = Int(tokens[0]),
              let month = months[tokens[1].lowercased().prefix(3).description],
              var year = Int(tokens[2])
        else { return nil }
        if year < 50 { year += 2000 } else if year < 100 { year += 1900 }
        let timeParts = tokens[3].split(separator: ":").compactMap { Int($0) }
        guard timeParts.count >= 2 else { return nil }
        let hour = timeParts[0], minute = timeParts[1], second = timeParts.count > 2 ? timeParts[2] : 0
        var zoneMinutes = 0
        if tokens.count > 4 {
            let z = tokens[4]
            if (z.hasPrefix("+") || z.hasPrefix("-")), z.count >= 5, let n = Int(z.dropFirst().prefix(4)) {
                let sign = z.hasPrefix("-") ? -1 : 1
                zoneMinutes = sign * ((n / 100) * 60 + n % 100)
            } else if let known = zones[z.lowercased()] {
                zoneMinutes = known
            }
        }
        guard (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        return epoch(year: year, month: month, day: day, hour: hour, minute: minute, second: second, zoneMinutes: zoneMinutes)
    }

    /// Jours depuis 1970 (algorithme de H. Hinnant), sans `Calendar` ni `DateFormatter`.
    public static func epoch(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, zoneMinutes: Int) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Int64(days) * 86400 + Int64(hour * 3600 + minute * 60 + second - zoneMinutes * 60)
    }
}
