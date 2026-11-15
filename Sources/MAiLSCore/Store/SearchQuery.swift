import Foundation

/// Saisie de recherche analysée : mots libres, `from:`, `to:`, `is:unread`. En-têtes seulement (décision du 14/11/2026) :
/// `has:attachment` n'est pas disponible car les pièces jointes ne sont connues qu'après téléchargement du corps.
public struct SearchQuery: Sendable, Equatable {
    public var terms: [String] = []
    public var from: [String] = []
    public var to: [String] = []
    public var unreadOnly = false

    public init() {}

    public var isEmpty: Bool { terms.isEmpty && from.isEmpty && to.isEmpty && !unreadOnly }
    /// Vrai s'il y a quelque chose à chercher dans l'index (sinon un simple filtre SQL suffit).
    var needsFullText: Bool { !(terms.isEmpty && from.isEmpty && to.isEmpty) }

    public static func parse(_ input: String) -> SearchQuery {
        var query = SearchQuery()
        for token in tokenize(input) {
            let lower = token.lowercased()
            if lower == "is:unread" || lower == "is:non-lu" { query.unreadOnly = true; continue }
            if lower.hasPrefix("from:") { let v = clean(String(token.dropFirst(5))); if !v.isEmpty { query.from.append(v) }; continue }
            if lower.hasPrefix("to:") { let v = clean(String(token.dropFirst(3))); if !v.isEmpty { query.to.append(v) }; continue }
            let v = clean(token)
            if !v.isEmpty { query.terms.append(v) }
        }
        return query
    }

    /// Expression FTS5 sûre : chaque mot entre guillemets (aucune syntaxe FTS5 saisie par l'utilisateur ne passe), préfixe sur tous.
    var ftsMatch: String {
        func quoted(_ w: String) -> String { "\"\(w)\"*" }
        var parts: [String] = terms.map(quoted)
        parts += from.map { "{from_name from_email} : " + quoted($0) }
        parts += to.map { "{to_text} : " + quoted($0) }
        return parts.joined(separator: " ")
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Coupe sur les espaces, sauf entre guillemets (`from:"jean dupont"`, `"réunion budget"`).
    private static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        for c in s {
            if c == "\"" { inQuote.toggle(); current.append(c) }
            else if c.isWhitespace, !inQuote { if !current.isEmpty { tokens.append(current); current = "" } }
            else { current.append(c) }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

/// Ce que la liste affiche : un dossier, éventuellement filtré par une recherche.
public struct MessageQuery: Sendable, Equatable {
    public var folderID: Int64?
    public var search: SearchQuery?

    public init(folderID: Int64?, search: SearchQuery? = nil) {
        self.folderID = folderID
        self.search = search
    }
}
