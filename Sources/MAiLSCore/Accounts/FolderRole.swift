import Foundation

/// Les cinq dossiers synchronisés par défaut (décision du 14/11/2026).
public enum FolderRole: String, Sendable, CaseIterable, Codable {
    case inbox, sent, drafts, archive, trash

    /// Ordre de synchronisation : la réception d'abord.
    public static let syncOrder: [FolderRole] = [.inbox, .sent, .drafts, .archive, .trash]

    /// Détermine le rôle d'un dossier : SPECIAL-USE d'abord (RFC 6154), sinon le nom (iCloud, Gmail, Dovecot, français).
    public static func resolve(_ folder: FolderListing) -> FolderRole? {
        guard folder.selectable else { return nil }
        if folder.path.caseInsensitiveCompare("INBOX") == .orderedSame { return .inbox }
        if let role = folder.role.flatMap(FolderRole.init(rawValue:)) { return role }
        let name = folder.path.split(separator: "/").last.map(String.init)?.lowercased() ?? folder.path.lowercased()
        switch name {
        case "sent", "sent messages", "sent items", "envoyés", "envoyes", "éléments envoyés", "elements envoyes": return .sent
        case "drafts", "draft", "brouillons": return .drafts
        case "archive", "archives", "all mail": return .archive
        case "trash", "deleted messages", "deleted items", "corbeille", "éléments supprimés": return .trash
        default: return nil
        }
    }

    /// Un dossier par rôle (le premier trouvé gagne ; un rôle absent est simplement ignoré).
    public static func assign(_ folders: [FolderListing]) -> [FolderRole: String] {
        var result: [FolderRole: String] = [:]
        // Passe 1 : rôles annoncés par le serveur ; passe 2 : par le nom.
        for f in folders where f.selectable {
            if f.path.caseInsensitiveCompare("INBOX") == .orderedSame { result[.inbox] = f.path }
            else if let r = f.role.flatMap(FolderRole.init(rawValue:)), result[r] == nil { result[r] = f.path }
        }
        for f in folders {
            if let r = resolve(f), result[r] == nil { result[r] = f.path }
        }
        return result
    }
}
