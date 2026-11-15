import Foundation
import Testing

@testable import MAiLSCore

@Suite("Requêtes, comptes, cache")
struct StoreQueryTests {
    private func message(_ uid: UInt32, subject: String, from: String = "Alice", to: String = "stephan", flags: MessageFlags = []) -> StoredMessage {
        var h = ParsedHeaders()
        h.subject = subject
        h.from = MailAddress(name: from, email: "\(from.lowercased())@exemple.fr")
        h.to = [MailAddress(name: nil, email: "\(to)@exemple.fr")]
        h.sentAt = 1_700_000_000 + Int64(uid)
        return StoredMessage(uid: uid, flags: flags, internalAt: 1_700_000_000 + Int64(uid), size: 10, headers: h)
    }

    @Test func analyseDeLaRecherche() {
        let q = SearchQuery.parse("from:jean to:\"marie curie\" is:unread réunion \"budget annuel\" from:")
        #expect(q.from == ["jean"])
        #expect(q.to == ["marie curie"])
        #expect(q.unreadOnly)
        #expect(q.terms == ["réunion", "budget annuel"])
        #expect(SearchQuery.parse("   ").isEmpty)
        #expect(SearchQuery.parse("is:unread").needsFullText == false)
    }

    @Test func operateursFromToUnread() async throws {
        let store = try MailStore(path: temporaryDatabasePath())
        let account = try await store.ensureAccount(label: "t", host: "h", port: 1, username: "u")
        let folder = try await store.ensureFolder(accountID: account, path: "INBOX", role: "inbox")
        try await store.upsert([
            message(1, subject: "Budget", from: "Jean", to: "marie", flags: .seen),
            message(2, subject: "Budget", from: "Paul", to: "jean"),
            message(3, subject: "Autre", from: "Jean", to: "paul"),
        ], folderID: folder.id)
        func uids(_ q: String) async throws -> [UInt32] {
            try await store.page(MessageQuery(folderID: folder.id, search: .parse(q)), offset: 0, limit: 50).map(\.uid).sorted()
        }
        #expect(try await uids("from:jean") == [1, 3])
        #expect(try await uids("to:jean") == [2])           // « jean » destinataire, pas expéditeur
        #expect(try await uids("budget") == [1, 2])
        #expect(try await uids("budget is:unread") == [2])
        #expect(try await uids("is:unread") == [2, 3])      // filtre seul, sans index plein texte
        #expect(try await uids("from:jean budget") == [1])
        #expect(try await store.count(MessageQuery(folderID: folder.id, search: .parse("budget"))) == 2)
    }

    @Test func paginationStable() async throws {
        let store = try MailStore(path: temporaryDatabasePath())
        let account = try await store.ensureAccount(label: "t", host: "h", port: 1, username: "u")
        let folder = try await store.ensureFolder(accountID: account, path: "INBOX", role: nil)
        try await store.upsert((1...250).map { message(UInt32($0), subject: "m\($0)") }, folderID: folder.id)
        let q = MessageQuery(folderID: folder.id)
        #expect(try await store.count(q) == 250)
        let p1 = try await store.page(q, offset: 0, limit: 100)
        let p3 = try await store.page(q, offset: 200, limit: 100)
        #expect(p1.first?.uid == 250 && p1.last?.uid == 151)
        #expect(p3.count == 50 && p3.last?.uid == 1)
    }

    @Test func comptesEtSuppressionEnCascade() async throws {
        let store = try MailStore(path: temporaryDatabasePath())
        let saved = try await store.saveAccount(.icloud(username: "  moi@icloud.com "))
        #expect(saved.id != nil && saved.username == "moi@icloud.com" && saved.host == "imap.mail.me.com" && saved.port == 993 && saved.useTLS)
        let again = try await store.saveAccount(saved)               // même compte : pas de doublon
        #expect(again.id == saved.id)
        #expect(try await store.accounts().count == 1)
        let folder = try await store.ensureFolder(accountID: saved.id!, path: "INBOX", role: "inbox")
        try await store.upsert([message(1, subject: "a")], folderID: folder.id)
        let summaries = try await store.folderSummaries(accountID: saved.id!)
        #expect(summaries.first?.messageCount == 1 && summaries.first?.unreadCount == 1)
        try await store.deleteAccount(id: saved.id!)
        #expect(try await store.accounts().isEmpty)
        #expect(try await store.search(folderID: nil, query: "a").isEmpty)  // messages et index supprimés avec le compte
    }

    @Test func dossiersDisparusDuServeurRetires() async throws {
        let store = try MailStore(path: temporaryDatabasePath())
        let account = try await store.ensureAccount(label: "t", host: "h", port: 1, username: "u")
        let keep = try await store.ensureFolder(accountID: account, path: "Factures", role: nil)
        let gone = try await store.ensureFolder(accountID: account, path: "Ancien", role: nil)
        try await store.upsert([message(1, subject: "a")], folderID: gone.id)
        try await store.pruneFolders(accountID: account, keeping: [])           // liste vide : on ne touche à rien
        #expect(try await store.folderSummaries(accountID: account).count == 2)
        try await store.pruneFolders(accountID: account, keeping: ["Factures"])
        let left = try await store.folderSummaries(accountID: account)
        #expect(left.map(\.path) == ["Factures"] && left.first?.id == keep.id)
        #expect(try await store.search(folderID: nil, query: "a").isEmpty)      // ses messages sont partis avec lui
    }

    @Test func notificationsDeChangement() async throws {
        let store = try MailStore(path: temporaryDatabasePath())
        let account = try await store.ensureAccount(label: "t", host: "h", port: 1, username: "u")
        let folder = try await store.ensureFolder(accountID: account, path: "INBOX", role: nil)
        var iterator = store.changes().makeAsyncIterator()
        try await store.upsert([message(1, subject: "a")], folderID: folder.id)
        #expect(await iterator.next() == folder.id)
    }

    @Test func cacheDeCorpsBorneEtLieAUidValidity() async throws {
        let cache = try BodyCache(path: temporaryDatabasePath(), maxBytes: 1000)
        try await cache.put([UInt8](repeating: 1, count: 400), folderID: 1, uidValidity: 7, uid: 1)
        #expect(try await cache.get(folderID: 1, uidValidity: 7, uid: 1)?.count == 400)
        #expect(try await cache.get(folderID: 1, uidValidity: 8, uid: 1) == nil)   // UIDVALIDITY changé : entrée inutilisable
        try await cache.put([UInt8](repeating: 2, count: 400), folderID: 1, uidValidity: 7, uid: 2)
        try await cache.put([UInt8](repeating: 3, count: 400), folderID: 1, uidValidity: 7, uid: 3)  // dépasse 1000 : le plus ancien part
        #expect(try await cache.totalBytes() <= 1000)
        #expect(try await cache.get(folderID: 1, uidValidity: 7, uid: 3) != nil)
        try await cache.clear()
        #expect(try await cache.totalBytes() == 0)
    }

    @Test func rolesDesDossiers() {
        func f(_ p: String, _ r: String? = nil) -> FolderListing { FolderListing(path: p, role: r, selectable: true) }
        let icloud = FolderRole.assign([f("INBOX"), f("Sent Messages"), f("Drafts"), f("Deleted Messages"), f("Archive"), f("Junk"), f("Notes")])
        #expect(icloud == [.inbox: "INBOX", .sent: "Sent Messages", .drafts: "Drafts", .trash: "Deleted Messages", .archive: "Archive"])
        let special = FolderRole.assign([f("INBOX"), f("Courrier envoyé", "sent"), f("Poubelle", "trash")])
        #expect(special[.sent] == "Courrier envoyé" && special[.trash] == "Poubelle")
        #expect(FolderRole.resolve(FolderListing(path: "Sent", role: nil, selectable: false)) == nil)
        #expect(FolderRole.assign([f("Perso")]).isEmpty)
    }

    @Test func coffreEnMemoire() throws {
        let store = MemorySecretStore()
        #expect(try store.password(for: "k") == nil)
        try store.setPassword("secret", for: "k")
        #expect(try store.password(for: "k") == "secret")
        try store.deletePassword(for: "k")
        #expect(try store.password(for: "k") == nil)
    }

    @Test func trousseauReel() throws {
        let store = KeychainSecretStore(service: "fr.stephan.mails.tests.\(UUID().uuidString)")
        let key = "essai@exemple.fr"
        defer { try? store.deletePassword(for: key) }
        do {
            #expect(try store.password(for: key) == nil)
            try store.setPassword("un-mot-de-passe-d'application", for: key)
            #expect(try store.password(for: key) == "un-mot-de-passe-d'application")
            try store.setPassword("modifié", for: key)
            #expect(try store.password(for: key) == "modifié")
            try store.deletePassword(for: key)
            #expect(try store.password(for: key) == nil)
        } catch SecretStoreError.keychain(let status) where status == errSecInteractionNotAllowed || status == errSecNoSuchKeychain || status == -25308 {
            // Session sans Trousseau déverrouillé (exécution sans interface) : on ne prétend pas avoir testé.
            Issue.record("Trousseau indisponible dans cette session (\(status)) : test non concluant")
        }
    }
}
