import Foundation
import GRDB

/// Drapeaux IMAP, stockés en bitmask (une seule colonne entière, filtrable par index partiel).
public struct MessageFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let seen = MessageFlags(rawValue: 1)
    public static let answered = MessageFlags(rawValue: 2)
    public static let flagged = MessageFlags(rawValue: 4)
    public static let deleted = MessageFlags(rawValue: 8)
    public static let draft = MessageFlags(rawValue: 16)
}

/// Un message prêt à être stocké (en-têtes seulement ; le corps se charge à la demande).
public struct StoredMessage: Sendable, Equatable {
    public var uid: UInt32
    public var flags: MessageFlags
    public var internalAt: Int64
    public var size: Int
    public var headers: ParsedHeaders

    public init(uid: UInt32, flags: MessageFlags, internalAt: Int64, size: Int, headers: ParsedHeaders) {
        self.uid = uid
        self.flags = flags
        self.internalAt = internalAt
        self.size = size
        self.headers = headers
    }
}

/// Ancien nom de `MessageSummary`.
public typealias SearchHit = MessageSummary

public struct FolderState: Sendable, Equatable {
    public var id: Int64
    public var path: String
    public var uidValidity: UInt32?
    /// UIDNEXT du serveur à la fin de la dernière synchro : tout UID ≥ cette valeur est nouveau.
    public var uidNext: UInt32?
    /// Plus petit UID dont on a déjà tout reçu jusqu'au sommet (reprise d'une synchro initiale interrompue).
    public var syncFloor: UInt32?
}

public struct MessageSummary: Sendable, Equatable {
    public var uid: UInt32
    public var subject: String
    public var fromName: String?
    public var fromEmail: String?
    public var toText: String?
    public var sentAt: Int64
    public var flags: MessageFlags
}

/// Base locale (SQLite, WAL) : dossiers, messages, index plein texte FTS5.
public final class MailStore: Sendable {
    let pool: DatabasePool
    let hub = ChangeHub()

    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        pool = try DatabasePool(path: path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    // MARK: Schéma

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            // Jamais de mot de passe ici : ils vivent dans le Trousseau.
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id INTEGER PRIMARY KEY,
                    label TEXT NOT NULL,
                    host TEXT NOT NULL,
                    port INTEGER NOT NULL,
                    username TEXT NOT NULL,
                    UNIQUE(host, port, username)
                );
                CREATE TABLE folders (
                    id INTEGER PRIMARY KEY,
                    account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    role TEXT,
                    uid_validity INTEGER,
                    uid_next INTEGER,
                    sync_floor INTEGER,
                    last_sync_at INTEGER,
                    UNIQUE(account_id, path)
                );
                CREATE TABLE messages (
                    id INTEGER PRIMARY KEY,
                    folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                    uid INTEGER NOT NULL,
                    message_id TEXT,
                    in_reply_to TEXT,
                    refs TEXT,
                    subject TEXT NOT NULL,
                    from_name TEXT,
                    from_email TEXT,
                    to_text TEXT,
                    cc_text TEXT,
                    sent_at INTEGER NOT NULL,
                    internal_at INTEGER NOT NULL,
                    size INTEGER NOT NULL,
                    flags INTEGER NOT NULL DEFAULT 0,
                    unsubscribe_url TEXT,
                    unsubscribe_one_click INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(folder_id, uid)
                );
                CREATE INDEX messages_folder_date ON messages(folder_id, sent_at DESC);
                CREATE INDEX messages_unread ON messages(folder_id) WHERE flags & 1 = 0;
                CREATE INDEX messages_msgid ON messages(message_id);

                CREATE VIRTUAL TABLE messages_fts USING fts5(
                    subject, from_name, from_email, to_text,
                    content='messages', content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2'
                );
                CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
                    INSERT INTO messages_fts(rowid, subject, from_name, from_email, to_text)
                    VALUES (new.id, new.subject, new.from_name, new.from_email, new.to_text);
                END;
                CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, subject, from_name, from_email, to_text)
                    VALUES ('delete', old.id, old.subject, old.from_name, old.from_email, old.to_text);
                END;
                CREATE TRIGGER messages_au AFTER UPDATE OF subject, from_name, from_email, to_text ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, subject, from_name, from_email, to_text)
                    VALUES ('delete', old.id, old.subject, old.from_name, old.from_email, old.to_text);
                    INSERT INTO messages_fts(rowid, subject, from_name, from_email, to_text)
                    VALUES (new.id, new.subject, new.from_name, new.from_email, new.to_text);
                END;
                """)
        }
        m.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE accounts ADD COLUMN use_tls INTEGER NOT NULL DEFAULT 1")
        }
        m.registerMigration("v3") { db in
            // Arbre des dossiers : compteurs lus par STATUS (dossiers jamais ouverts), épinglés, séparateur de hiérarchie.
            try db.execute(sql: "ALTER TABLE folders ADD COLUMN status_messages INTEGER")
            try db.execute(sql: "ALTER TABLE folders ADD COLUMN status_unseen INTEGER")
            try db.execute(sql: "ALTER TABLE folders ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE folders ADD COLUMN delimiter TEXT")
        }
        return m
    }

    // MARK: Comptes et dossiers

    public func ensureAccount(label: String, host: String, port: Int, username: String) async throws -> Int64 {
        try await pool.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO accounts(label, host, port, username) VALUES (?, ?, ?, ?)",
                arguments: [label, host, port, username])
            return try Int64.fetchOne(
                db, sql: "SELECT id FROM accounts WHERE host = ? AND port = ? AND username = ?",
                arguments: [host, port, username]) ?? 0
        }
    }

    public func ensureFolder(accountID: Int64, path: String, role: String?, delimiter: String? = nil) async throws -> FolderState {
        try await pool.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO folders(account_id, path, role) VALUES (?, ?, ?)",
                arguments: [accountID, path, role])
            if let delimiter {
                try db.execute(
                    sql: "UPDATE folders SET delimiter = ? WHERE account_id = ? AND path = ? AND IFNULL(delimiter, '') != ?",
                    arguments: [delimiter, accountID, path, delimiter])
            }
            guard let row = try Row.fetchOne(
                db, sql: "SELECT id, path, uid_validity, uid_next, sync_floor FROM folders WHERE account_id = ? AND path = ?",
                arguments: [accountID, path])
            else { throw MailStoreError.folderMissing(path) }
            return FolderState(
                id: row["id"], path: row["path"], uidValidity: row["uid_validity"],
                uidNext: row["uid_next"], syncFloor: row["sync_floor"])
        }
    }

    /// Retire les dossiers locaux que le serveur ne liste plus (supprimés ou renommés), avec leurs messages. Sans liste, ne fait rien.
    public func pruneFolders(accountID: Int64, keeping paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await pool.write { db in
            let marks = Array(repeating: "?", count: paths.count).joined(separator: ",")
            var values: [any DatabaseValueConvertible] = [accountID]
            values.append(contentsOf: paths)
            try db.execute(
                sql: "DELETE FROM folders WHERE account_id = ? AND path NOT IN (\(marks))",
                arguments: StatementArguments(values))
        }
    }

    /// Enregistre les compteurs lus par `STATUS` (dossiers jamais ouverts : leurs messages ne sont pas en base).
    public func setFolderStatuses(accountID: Int64, _ statuses: [(path: String, counts: FolderCounts)]) async throws {
        guard !statuses.isEmpty else { return }
        try await pool.write { db in
            for s in statuses {
                try db.execute(
                    sql: "UPDATE folders SET status_messages = ?, status_unseen = ? WHERE account_id = ? AND path = ?",
                    arguments: [s.counts.messages, s.counts.unseen, accountID, s.path])
            }
        }
        hub.send(0)  // 0 : aucun dossier en particulier, seulement la liste des dossiers à relire
    }

    /// Épingle ou désépingle un dossier (réglage local, rien n'est écrit sur le serveur).
    public func setPinned(folderID: Int64, pinned: Bool) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE folders SET pinned = ? WHERE id = ?", arguments: [pinned ? 1 : 0, folderID])
        }
        hub.send(0)
    }

    public func setFolderState(
        folderID: Int64, uidValidity: UInt32?, uidNext: UInt32?, syncFloor: UInt32?, now: Int64
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE folders SET uid_validity = ?, uid_next = ?, sync_floor = ?, last_sync_at = ?, status_messages = NULL, status_unseen = NULL WHERE id = ?",
                arguments: [uidValidity, uidNext, syncFloor, now, folderID])
        }
    }

    /// UIDVALIDITY modifié : les UID locaux ne signifient plus rien, on repart de zéro pour ce dossier.
    public func wipeFolderMessages(folderID: Int64) async throws {
        try await wipeNow(folderID: folderID)
        hub.send(folderID)
    }

    private func wipeNow(folderID: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM messages WHERE folder_id = ?", arguments: [folderID])
            try db.execute(
                sql: "UPDATE folders SET uid_next = NULL, sync_floor = NULL WHERE id = ?", arguments: [folderID])
        }
    }

    // MARK: Messages

    /// Insère ou met à jour (drapeaux) un lot de messages dans une seule transaction.
    public func upsert(_ messages: [StoredMessage], folderID: Int64) async throws {
        try await upsertNow(messages, folderID: folderID)
        hub.send(folderID)
    }

    private func upsertNow(_ messages: [StoredMessage], folderID: Int64) async throws {
        try await pool.write { db in
            let insert = try db.cachedStatement(sql: """
                INSERT INTO messages(folder_id, uid, message_id, in_reply_to, refs, subject, from_name, from_email,
                                     to_text, cc_text, sent_at, internal_at, size, flags, unsubscribe_url, unsubscribe_one_click)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(folder_id, uid) DO UPDATE SET flags = excluded.flags
                """)
            for m in messages {
                let h = m.headers
                try insert.execute(arguments: [
                    folderID, Int64(m.uid), h.messageID, h.inReplyTo,
                    h.references.isEmpty ? nil : h.references.joined(separator: " "),
                    h.subject, h.from?.name, h.from?.email,
                    h.to.map { address in address.name.map { "\($0) <\(address.email)>" } ?? address.email }
                        .joined(separator: ", "),
                    h.cc.map(\.email).joined(separator: ", "),
                    h.sentAt ?? m.internalAt, m.internalAt, m.size, m.flags.rawValue,
                    h.unsubscribeURL, h.unsubscribeOneClick ? 1 : 0,
                ])
            }
        }
    }

    /// Met à jour seulement les drapeaux (resynchro) et supprime les messages disparus du serveur.
    /// `serverFlags` doit contenir **tous** les UID présents côté serveur pour la plage considérée.
    public func reconcile(folderID: Int64, serverFlags: [UInt32: MessageFlags]) async throws -> (updated: Int, removed: Int) {
        let result = try await reconcileNow(folderID: folderID, serverFlags: serverFlags)
        if result.updated > 0 || result.removed > 0 { hub.send(folderID) }
        return result
    }

    private func reconcileNow(folderID: Int64, serverFlags: [UInt32: MessageFlags]) async throws -> (updated: Int, removed: Int) {
        try await pool.write { db in
            var updated = 0
            var removed = 0
            let rows = try Row.fetchCursor(db, sql: "SELECT uid, flags FROM messages WHERE folder_id = ?", arguments: [folderID])
            var toUpdate: [(UInt32, Int)] = []
            var toDelete: [UInt32] = []
            while let row = try rows.next() {
                let uid = UInt32(truncatingIfNeeded: row["uid"] as Int64)
                let local: Int = row["flags"]
                if let server = serverFlags[uid] {
                    if server.rawValue != local { toUpdate.append((uid, server.rawValue)) }
                } else {
                    toDelete.append(uid)
                }
            }
            let up = try db.cachedStatement(sql: "UPDATE messages SET flags = ? WHERE folder_id = ? AND uid = ?")
            for (uid, flags) in toUpdate {
                try up.execute(arguments: [flags, folderID, Int64(uid)])
                updated += 1
            }
            let del = try db.cachedStatement(sql: "DELETE FROM messages WHERE folder_id = ? AND uid = ?")
            for uid in toDelete {
                try del.execute(arguments: [folderID, Int64(uid)])
                removed += 1
            }
            return (updated, removed)
        }
    }

    public func messageCount(folderID: Int64) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE folder_id = ?", arguments: [folderID]) ?? 0
        }
    }

    public func unreadCount(folderID: Int64) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messages WHERE folder_id = ? AND flags & 1 = 0", arguments: [folderID]) ?? 0
        }
    }

    /// Les plus récents d'abord (c'est la requête de la liste centrale).
    public func latest(folderID: Int64, limit: Int, offset: Int = 0) async throws -> [MessageSummary] {
        try await page(MessageQuery(folderID: folderID), offset: offset, limit: limit)
    }

    /// Recherche plein texte (voir `SearchQuery` : opérateurs `from:`, `to:`, `is:unread`).
    public func search(folderID: Int64?, query: String, limit: Int = 50) async throws -> [MessageSummary] {
        let parsed = SearchQuery.parse(query)
        guard !parsed.isEmpty else { return [] }
        return try await page(MessageQuery(folderID: folderID, search: parsed), offset: 0, limit: limit)
    }

    public func localUIDs(folderID: Int64) async throws -> Set<UInt32> {
        try await pool.read { db in
            var set = Set<UInt32>()
            let cursor = try Int64.fetchCursor(db, sql: "SELECT uid FROM messages WHERE folder_id = ?", arguments: [folderID])
            while let uid = try cursor.next() { set.insert(UInt32(truncatingIfNeeded: uid)) }
            return set
        }
    }

    /// Taille du fichier de base (octets), WAL compris, pour le banc d'essai.
    public func integrityCheck() async throws -> String {
        try await pool.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "?" }
    }
}

public enum MailStoreError: Error, Equatable {
    case folderMissing(String)
}
