import Foundation
import Testing

@testable import MAiLSCore

@Suite("MailStore")
struct StoreTests {
    private func makeMessage(uid: UInt32, subject: String, from: String = "Alice", flags: MessageFlags = []) -> StoredMessage {
        var h = ParsedHeaders()
        h.subject = subject
        h.from = MailAddress(name: from, email: "\(from.lowercased())@exemple.fr")
        h.sentAt = 1_700_000_000 + Int64(uid)
        return StoredMessage(uid: uid, flags: flags, internalAt: 1_700_000_000 + Int64(uid), size: 100, headers: h)
    }

    private func makeStore() async throws -> (MailStore, Int64) {
        let store = try MailStore(path: temporaryDatabasePath())
        let account = try await store.ensureAccount(label: "t", host: "h", port: 143, username: "u")
        let folder = try await store.ensureFolder(accountID: account, path: "INBOX", role: nil)
        return (store, folder.id)
    }

    @Test func rechercheIgnoreAccentsEtCasse() async throws {
        let (store, folder) = try await makeStore()
        try await store.upsert([
            makeMessage(uid: 1, subject: "Réunion de sécurité"),
            makeMessage(uid: 2, subject: "Facture d'avril", from: "Élodie"),
        ], folderID: folder)
        #expect(try await store.search(folderID: folder, query: "reunion").map(\.uid) == [1])
        #expect(try await store.search(folderID: folder, query: "SECURITE").map(\.uid) == [1])
        #expect(try await store.search(folderID: folder, query: "elodie").map(\.uid) == [2])
        #expect(try await store.search(folderID: folder, query: "facture avr").map(\.uid) == [2])  // préfixe sur le dernier mot
    }

    @Test func rechercheNeutraliseLaSyntaxeFTS() async throws {
        let (store, folder) = try await makeStore()
        try await store.upsert([makeMessage(uid: 1, subject: "budget")], folderID: folder)
        // Ces saisies feraient échouer MATCH si elles étaient passées telles quelles.
        for hostile in ["\"", "budget AND", "NEAR(", "*", "-budget", "a OR", "(((", "subject:budget", "'; DROP TABLE messages;--"] {
            _ = try await store.search(folderID: folder, query: hostile)  // ne doit pas lever d'erreur
        }
        #expect(try await store.messageCount(folderID: folder) == 1)
    }

    @Test func upsertMetAJourLesDrapeauxSansDoublon() async throws {
        let (store, folder) = try await makeStore()
        try await store.upsert([makeMessage(uid: 1, subject: "a")], folderID: folder)
        #expect(try await store.unreadCount(folderID: folder) == 1)
        try await store.upsert([makeMessage(uid: 1, subject: "a", flags: .seen)], folderID: folder)
        #expect(try await store.messageCount(folderID: folder) == 1)
        #expect(try await store.unreadCount(folderID: folder) == 0)
    }

    @Test func reconcileMetAJourEtSupprime() async throws {
        let (store, folder) = try await makeStore()
        try await store.upsert((1...5).map { makeMessage(uid: UInt32($0), subject: "m\($0)") }, folderID: folder)
        // Serveur : 1 lu, 2 inchangé, 3 supprimé, 4 marqué, 5 supprimé
        let result = try await store.reconcile(folderID: folder, serverFlags: [1: .seen, 2: [], 4: .flagged])
        #expect(result.updated == 2)
        #expect(result.removed == 2)
        #expect(try await store.localUIDs(folderID: folder) == [1, 2, 4])
        // L'index plein texte suit les suppressions (pas de fantômes).
        #expect(try await store.search(folderID: folder, query: "m3").isEmpty)
        #expect(try await store.search(folderID: folder, query: "m4").map(\.uid) == [4])
    }

    @Test func listeLesPlusRecentsDAbord() async throws {
        let (store, folder) = try await makeStore()
        try await store.upsert((1...10).map { makeMessage(uid: UInt32($0), subject: "m\($0)") }, folderID: folder)
        let page = try await store.latest(folderID: folder, limit: 3)
        #expect(page.map(\.uid) == [10, 9, 8])
        #expect(try await store.latest(folderID: folder, limit: 3, offset: 3).map(\.uid) == [7, 6, 5])
    }

    @Test func aucunMotDePasseDansLeSchema() async throws {
        let path = temporaryDatabasePath()
        let store = try MailStore(path: path)
        _ = try await store.ensureAccount(label: "t", host: "h", port: 143, username: "u")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(decoding: bytes, as: UTF8.self).lowercased()
        #expect(!text.contains("password"))
        #expect(!text.contains("passwd"))
    }

    @Test func fenetresSansTrouNiChevauchement() {
        for (lo, hi, size) in [(1, 2500, 1000), (1, 1000, 1000), (1, 1, 1000), (5, 9, 1000), (1, 10, 3), (7, 7, 1)] as [(UInt32, UInt32, UInt32)] {
            for windows in [SyncEngine.descendingWindows(lo...hi, size: size), SyncEngine.ascendingWindows(lo...hi, size: size)] {
                let covered = windows.flatMap { Array($0) }.sorted()
                #expect(covered == Array(lo...hi), "plage \(lo)...\(hi) taille \(size)")
                #expect(windows.allSatisfy { $0.count <= Int(size) })
            }
        }
    }
}
