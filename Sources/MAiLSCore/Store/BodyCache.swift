import Foundation
import GRDB

/// Cache jetable des messages déjà ouverts (fichier `bodies.db`, séparé de la base principale).
/// Le supprimer ne fait perdre aucune donnée : les corps se retéléchargent à la demande.
/// Clé : dossier + UIDVALIDITY + UID (un UIDVALIDITY modifié rend les anciennes entrées inutilisables).
public final class BodyCache: Sendable {
    private let pool: DatabasePool
    public let maxBytes: Int

    public init(path: String, maxBytes: Int = 500 * 1024 * 1024) throws {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous = NORMAL") }
        pool = try DatabasePool(path: path, configuration: config)
        self.maxBytes = maxBytes
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE bodies (
                    folder_id INTEGER NOT NULL, uid_validity INTEGER NOT NULL, uid INTEGER NOT NULL,
                    fetched_at INTEGER NOT NULL, size INTEGER NOT NULL, data BLOB NOT NULL,
                    PRIMARY KEY (folder_id, uid_validity, uid)
                ) WITHOUT ROWID;
                CREATE INDEX bodies_age ON bodies(fetched_at);
                """)
        }
        try migrator.migrate(pool)
    }

    public func get(folderID: Int64, uidValidity: UInt32, uid: UInt32) async throws -> [UInt8]? {
        try await pool.read { db in
            try Data.fetchOne(
                db, sql: "SELECT data FROM bodies WHERE folder_id = ? AND uid_validity = ? AND uid = ?",
                arguments: [folderID, Int64(uidValidity), Int64(uid)]).map { [UInt8]($0) }
        }
    }

    public func put(_ bytes: [UInt8], folderID: Int64, uidValidity: UInt32, uid: UInt32) async throws {
        let cap = maxBytes
        try await pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO bodies(folder_id, uid_validity, uid, fetched_at, size, data) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [folderID, Int64(uidValidity), Int64(uid), Int64(Date().timeIntervalSince1970), bytes.count, Data(bytes)])
            // Élagage : on retire les plus anciens tant que le total dépasse le plafond.
            var total = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM bodies") ?? 0
            while total > cap {
                let rows = try Row.fetchAll(
                    db, sql: "SELECT folder_id, uid_validity, uid, size FROM bodies ORDER BY fetched_at ASC LIMIT 50")
                if rows.isEmpty { break }
                for row in rows where total > cap {
                    try db.execute(
                        sql: "DELETE FROM bodies WHERE folder_id = ? AND uid_validity = ? AND uid = ?",
                        arguments: [row["folder_id"] as Int64, row["uid_validity"] as Int64, row["uid"] as Int64])
                    total -= row["size"] as Int
                }
            }
        }
    }

    public func totalBytes() async throws -> Int {
        try await pool.read { db in try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM bodies") ?? 0 }
    }

    public func clear() async throws {
        try await pool.write { db in try db.execute(sql: "DELETE FROM bodies") }
    }
}
