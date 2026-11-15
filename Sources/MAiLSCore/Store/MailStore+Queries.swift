import Foundation
import GRDB
import Synchronization

/// Diffuse « le dossier X a changé » aux observateurs (interface), sans interrogation périodique.
final class ChangeHub: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Int64>.Continuation]>([:])

    func stream() -> AsyncStream<Int64> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            continuations.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.continuations.withLock { _ = $0.removeValue(forKey: id) } }
        }
    }

    func send(_ folderID: Int64) {
        let all = continuations.withLock { Array($0.values) }
        for c in all { c.yield(folderID) }
    }
}

public struct FolderSummary: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var path: String
    public var role: String?
    public var uidValidity: UInt32?
    public var messageCount: Int
    public var unreadCount: Int
    /// Séparateur de hiérarchie du serveur (`/` par défaut).
    public var delimiter: String = "/"
    public var pinned: Bool = false
    /// Vrai quand les compteurs sont réels : dossier synchronisé, ou compteurs lus par `STATUS`. Faux : on ne sait pas encore.
    public var countsKnown: Bool = true

    /// Nom lisible (accents décodés) ; `path` reste le nom brut à envoyer au serveur.
    public var displayPath: String { MailboxText.decode(path) }
}

extension MailStore {
    /// Flux « le dossier d'identifiant X a changé » (ajouts, drapeaux, suppressions).
    public func changes() -> AsyncStream<Int64> { hub.stream() }

    // MARK: Comptes

    public func accounts() async throws -> [AccountConfig] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, label, host, port, use_tls, username FROM accounts ORDER BY id").map { row in
                AccountConfig(
                    id: row["id"], label: row["label"], host: row["host"], port: UInt16(truncatingIfNeeded: row["port"] as Int),
                    useTLS: (row["use_tls"] as Int) != 0, username: row["username"])
            }
        }
    }

    /// Crée ou met à jour un compte (même serveur, port et identifiant = même compte).
    @discardableResult
    public func saveAccount(_ config: AccountConfig) async throws -> AccountConfig {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts(label, host, port, username, use_tls) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(host, port, username) DO UPDATE SET label = excluded.label, use_tls = excluded.use_tls
                    """,
                arguments: [config.label, config.host, Int(config.port), config.username, config.useTLS ? 1 : 0])
            var saved = config
            saved.id = try Int64.fetchOne(
                db, sql: "SELECT id FROM accounts WHERE host = ? AND port = ? AND username = ?",
                arguments: [config.host, Int(config.port), config.username])
            return saved
        }
    }

    /// Supprime le compte et, en cascade, tous ses dossiers et messages locaux (le serveur n'est pas touché).
    public func deleteAccount(id: Int64) async throws {
        try await pool.write { db in try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [id]) }
    }

    // MARK: Dossiers

    public func folderSummaries(accountID: Int64) async throws -> [FolderSummary] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, f.path, f.role, f.uid_validity, f.pinned, f.delimiter, f.last_sync_at, f.status_messages, f.status_unseen,
                       COUNT(m.id) AS total, COALESCE(SUM(CASE WHEN m.flags & 1 = 0 THEN 1 ELSE 0 END), 0) AS unread
                FROM folders f LEFT JOIN messages m ON m.folder_id = f.id
                WHERE f.account_id = ? GROUP BY f.id
                """, arguments: [accountID]).map { row in
                // Dossier synchronisé (ou en cours de synchro) : compteurs locaux. Sinon : compteurs lus par STATUS, s'ils existent.
                let synced = (row["last_sync_at"] as Int64?) != nil || (row["total"] as Int) > 0
                let statusMessages: Int? = row["status_messages"]
                let statusUnseen: Int? = row["status_unseen"]
                let delimiter: String? = row["delimiter"]
                return FolderSummary(
                    id: row["id"], path: row["path"], role: row["role"], uidValidity: row["uid_validity"],
                    messageCount: synced ? row["total"] : (statusMessages ?? 0),
                    unreadCount: synced ? row["unread"] : (statusUnseen ?? 0),
                    delimiter: delimiter ?? "/",
                    pinned: (row["pinned"] as Int) != 0,
                    countsKnown: synced || statusMessages != nil)
            }
        }
    }

    // MARK: Liste paginée

    public func count(_ query: MessageQuery) async throws -> Int {
        let (sql, args) = Self.listSQL(query, select: "COUNT(*)", tail: "")
        return try await pool.read { db in try Int.fetchOne(db, sql: sql, arguments: args) ?? 0 }
    }

    public func page(_ query: MessageQuery, offset: Int, limit: Int) async throws -> [MessageSummary] {
        let (sql, args) = Self.listSQL(
            query, select: "m.uid, m.subject, m.from_name, m.from_email, m.to_text, m.sent_at, m.flags",
            tail: " ORDER BY m.sent_at DESC, m.id DESC LIMIT ? OFFSET ?", extra: [limit, offset])
        return try await pool.read { db in try Row.fetchAll(db, sql: sql, arguments: args).map(Self.summary) }
    }

    private static func listSQL(
        _ query: MessageQuery, select: String, tail: String, extra: [any DatabaseValueConvertible] = []
    ) -> (String, StatementArguments) {
        var args: [any DatabaseValueConvertible] = []
        var sql: String
        let search = query.search.flatMap { $0.isEmpty ? nil : $0 }
        if let search, search.needsFullText {
            sql = "SELECT \(select) FROM messages_fts f JOIN messages m ON m.id = f.rowid WHERE messages_fts MATCH ?"
            args.append(search.ftsMatch)
        } else {
            sql = "SELECT \(select) FROM messages m WHERE 1 = 1"
        }
        if let folderID = query.folderID { sql += " AND m.folder_id = ?"; args.append(folderID) }
        if search?.unreadOnly == true { sql += " AND m.flags & 1 = 0" }
        sql += tail
        args += extra
        return (sql, StatementArguments(args))
    }

    static func summary(_ row: Row) -> MessageSummary {
        MessageSummary(
            uid: UInt32(truncatingIfNeeded: row["uid"] as Int64), subject: row["subject"],
            fromName: row["from_name"], fromEmail: row["from_email"], toText: row["to_text"], sentAt: row["sent_at"],
            flags: MessageFlags(rawValue: row["flags"]))
    }
}
