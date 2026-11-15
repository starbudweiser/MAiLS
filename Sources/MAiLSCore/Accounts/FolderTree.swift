import Foundation

/// Un dossier de l'arbre, ou un parent implicite que le serveur ne liste pas comme dossier (`folder == nil`).
public struct FolderNode: Identifiable, Sendable, Equatable {
    /// Chemin brut jusqu'à ce niveau.
    public var id: String
    /// Dernier niveau du chemin, accents décodés.
    public var name: String
    public var folder: FolderSummary?
    public var children: [FolderNode]
    /// Non lus de ce dossier et de tous ses sous-dossiers.
    public var unreadTotal: Int

    /// Vrai si ce niveau ou l'un de ses sous-dossiers a des messages, ou si on ne sait pas encore (compteurs pas lus).
    /// Sert à masquer les dossiers vides sans jamais en cacher un dont on ignore le contenu.
    var hasContent: Bool {
        if let folder, !folder.countsKnown || folder.messageCount > 0 { return true }
        return children.contains { $0.hasContent }
    }
}

/// Une ligne visible de l'arbre (déjà aplati selon les niveaux dépliés).
public struct FolderRow: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var depth: Int
    public var folder: FolderSummary?
    public var hasChildren: Bool
    public var isExpanded: Bool
    /// Non lus affichés : ceux du dossier seul s'il est déplié ou sans enfant, ceux de tout son contenu s'il est replié.
    public var unread: Int
}

/// Logique pure de l'arbre des dossiers : construction, aplatissement, recherche, chemin. Sans interface, testable seule.
public enum FolderTree {
    // MARK: Construction

    /// Arbre des dossiers sans rôle (les principaux ont leur place fixe). Les niveaux manquants deviennent des parents implicites.
    ///
    /// Un sous-dossier d'un dossier principal (« Archive/2022 ») se range sous un niveau qui porte le nom affiché de ce dossier
    /// (`displayName`) mais n'est pas sélectionnable : le dossier principal lui-même reste dans la liste fixe du haut.
    /// Un dossier principal sans sous-dossier n'apparaît pas dans l'arbre.
    public static func build(
        _ folders: [FolderSummary], displayName: (FolderSummary) -> String = { $0.displayPath }
    ) -> [FolderNode] {
        final class Builder {
            let path: String
            var name: String
            var folder: FolderSummary?
            var children: [String: Builder] = [:]
            init(path: String, name: String) { self.path = path; self.name = name }
        }
        var roots: [String: Builder] = [:]
        let roleFolders = Dictionary(folders.filter { $0.role != nil }.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for folder in folders where folder.role == nil {
            let delimiter = folder.delimiter.isEmpty ? "/" : folder.delimiter
            let parts = folder.path.components(separatedBy: delimiter)
            var current: Builder?
            var prefix = ""
            for (i, part) in parts.enumerated() {
                prefix = i == 0 ? part : prefix + delimiter + part
                let existing: Builder?
                if let current { existing = current.children[prefix] } else { existing = roots[prefix] }
                let node = existing ?? Builder(path: prefix, name: MailboxText.decode(part))
                if existing == nil, let parent = roleFolders[prefix] { node.name = displayName(parent) }
                if existing == nil {
                    if let current { current.children[prefix] = node } else { roots[prefix] = node }
                }
                current = node
            }
            current?.folder = folder
        }
        func convert(_ b: Builder) -> FolderNode {
            let kids = b.children.values.map(convert).sorted { sortName($0) < sortName($1) }
            return FolderNode(
                id: b.path, name: b.name, folder: b.folder, children: kids,
                unreadTotal: (b.folder?.unreadCount ?? 0) + kids.reduce(0) { $0 + $1.unreadTotal })
        }
        return roots.values.map(convert).sorted { sortName($0) < sortName($1) }
    }

    /// Ordre « naturel » : insensible à la casse et aux accents, les nombres dans l'ordre (« 2 » avant « 10 »).
    private struct SortKey: Comparable {
        let text: String
        static func < (a: SortKey, b: SortKey) -> Bool { a.text.localizedStandardCompare(b.text) == .orderedAscending }
    }
    private static func sortName(_ node: FolderNode) -> SortKey { SortKey(text: node.name) }

    // MARK: Aplatissement

    /// Lignes visibles : un nœud est déplié si son chemin est dans `expanded`. `hideEmpty` masque les dossiers connus vides.
    /// `keeping` : chemins qui restent visibles même vides (le dossier ouvert), avec leurs parents.
    public static func rows(
        _ roots: [FolderNode], expanded: Set<String>, hideEmpty: Bool, keeping: Set<String> = []
    ) -> [FolderRow] {
        var out: [FolderRow] = []
        func shown(_ node: FolderNode) -> Bool {
            !hideEmpty || node.hasContent || keeping.contains(node.id) || node.children.contains(where: shown)
        }
        func visit(_ node: FolderNode, depth: Int) {
            guard shown(node) else { return }
            let kids = hideEmpty ? node.children.filter(shown) : node.children
            let open = !kids.isEmpty && expanded.contains(node.id)
            out.append(FolderRow(
                id: node.id, name: node.name, depth: depth, folder: node.folder, hasChildren: !kids.isEmpty, isExpanded: open,
                unread: open || kids.isEmpty ? (node.folder?.unreadCount ?? 0) : node.unreadTotal))
            if open { for k in kids { visit(k, depth: depth + 1) } }
        }
        for r in roots { visit(r, depth: 0) }
        return out
    }

    // MARK: Chemin

    /// Niveaux du chemin, du premier au dernier : nom lisible et chemin brut cumulé (pour retrouver le dossier de chaque niveau).
    public static func breadcrumb(for folder: FolderSummary) -> [(name: String, path: String)] {
        let delimiter = folder.delimiter.isEmpty ? "/" : folder.delimiter
        var prefix = ""
        return folder.path.components(separatedBy: delimiter).enumerated().map { i, part in
            prefix = i == 0 ? part : prefix + delimiter + part
            return (MailboxText.decode(part), prefix)
        }
    }

    /// Chemins bruts de tous les niveaux au-dessus du dossier (à déplier pour le montrer).
    public static func ancestorPaths(of folder: FolderSummary) -> [String] {
        Array(breadcrumb(for: folder).dropLast().map(\.path))
    }

    // MARK: Recherche (« Aller à un dossier »)

    /// Dossiers dont le chemin contient tous les mots tapés (sans casse ni accents). Un mot trouvé dans le nom passe avant un mot
    /// trouvé seulement dans un parent ; à égalité, le dossier le moins profond puis l'ordre alphabétique.
    public static func search(
        _ folders: [FolderSummary], query: String, limit: Int = 30, displayName: (FolderSummary) -> String
    ) -> [FolderSummary] {
        let tokens = fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        struct Hit { let folder: FolderSummary; let rank: Int; let depth: Int; let key: String }
        var hits: [Hit] = []
        for folder in folders {
            let name = fold(displayName(folder))
            let full = folder.role == nil ? fold(folder.displayPath.replacingOccurrences(of: folder.delimiter, with: " ")) : name
            guard tokens.allSatisfy({ full.contains($0) }) else { continue }
            let rank = name.hasPrefix(tokens[0]) ? 0 : (tokens.allSatisfy { name.contains($0) } ? 1 : 2)
            hits.append(Hit(folder: folder, rank: rank, depth: folder.path.components(separatedBy: folder.delimiter).count, key: full))
        }
        hits.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.key.localizedStandardCompare(b.key) == .orderedAscending
        }
        return hits.prefix(limit).map(\.folder)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
