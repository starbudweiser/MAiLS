import Foundation
import Testing

@testable import MAiLSCore

/// Le moteur d'un compte de bout en bout contre le serveur local de test.
@Suite("AccountSession", .serialized)
struct AccountSessionTests {
    struct Rig {
        let server: TestServer
        let store: MailStore
        let session: AccountSession
        let secrets: MemorySecretStore
        let config: AccountConfig
        let accountID: Int64
    }

    private func makeRig(messages: Int, password: String? = "test", port: UInt16? = nil, idleRenewal: Duration = .seconds(25 * 60), extraFolders: Bool = false, tree: Bool = false) async throws -> Rig {
        let server = try TestServer(messages: messages, port: port, extraFolders: extraFolders, tree: tree)
        let store = try MailStore(path: temporaryDatabasePath())
        var config = AccountConfig(label: "essai", host: "127.0.0.1", port: server.port, useTLS: false, username: "test")
        config = try await store.saveAccount(config)
        let secrets = MemorySecretStore()
        if let password { try secrets.setPassword(password, for: config.secretKey) }
        let cache = try BodyCache(path: temporaryDatabasePath())
        let session = AccountSession(config: config, accountID: config.id!, store: store, secrets: secrets, bodyCache: cache, idleRenewal: idleRenewal)
        return Rig(server: server, store: store, session: session, secrets: secrets, config: config, accountID: config.id!)
    }

    private func wait(_ seconds: Double = 20, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func synchroDesCinqDossiers() async throws {
        let rig = try await makeRig(messages: 1500)
        await rig.session.start()
        defer { Task { await rig.session.stop() } }
        let done = try await wait {
            let s = try await rig.store.folderSummaries(accountID: rig.accountID)
            return s.count == 5 && s.allSatisfy { $0.messageCount > 0 } && s.first(where: { $0.role == "inbox" })?.messageCount == 1500
                && s.first(where: { $0.role == "archive" })?.messageCount == 2500
        }
        #expect(done)
        let summaries = try await rig.store.folderSummaries(accountID: rig.accountID)
        let counts = Dictionary(uniqueKeysWithValues: summaries.map { ($0.role ?? "?", $0.messageCount) })
        #expect(counts == ["inbox": 1500, "sent": 120, "drafts": 3, "archive": 2500, "trash": 40])
        let online = try await wait { if case .online = await rig.session.state { return true } else { return false } }
        #expect(online)
        // Lecture seule : aucune commande qui modifie le serveur.
        let forbidden = ["STORE", "EXPUNGE", "DELETE", "APPEND", "COPY", "MOVE", "CREATE", "RENAME", "SELECT"]
        #expect(!rig.server.commandLog().contains { entry in forbidden.contains { entry.contains($0) } })
    }

    @Test func tousLesDossiersListesSynchroALOuverture() async throws {
        let rig = try await makeRig(messages: 200, extraFolders: true)
        await rig.session.start()
        defer { Task { await rig.session.stop() } }
        // Les 5 principaux + Factures + « Été » + Junk sont tous visibles dès la découverte.
        #expect(try await wait { try await rig.store.folderSummaries(accountID: rig.accountID).count == 8 })
        #expect(try await wait { if case .online = await rig.session.state { return true } else { return false } })
        let summaries = try await rig.store.folderSummaries(accountID: rig.accountID)
        let byPath = Dictionary(uniqueKeysWithValues: summaries.map { ($0.path, $0) })
        #expect(byPath["Junk"]?.role == "junk")
        #expect(byPath["Factures"]?.role == nil && byPath["&AMk-t&AOk-"]?.displayPath == "Été")
        // Hors des cinq principaux : aucun message n'est téléchargé tant que le dossier n'est pas ouvert...
        #expect(try await rig.store.messageCount(folderID: byPath["Factures"]!.id) == 0)
        #expect(try await rig.store.messageCount(folderID: byPath["Junk"]!.id) == 0)
        // ... mais leurs compteurs sont lus par STATUS, sans ouvrir le dossier.
        #expect(try await wait {
            let s = try await rig.store.folderSummaries(accountID: rig.accountID)
            let f = s.first { $0.path == "Factures" }, j = s.first { $0.path == "Junk" }, e = s.first { $0.path == "&AMk-t&AOk-" }
            return f?.countsKnown == true && f?.messageCount == 30 && j?.messageCount == 5 && e?.messageCount == 12 && j?.unreadCount == 5
        })
        #expect(rig.server.commandLog().contains { $0.contains("STATUS") })
        #expect(byPath["INBOX"]?.messageCount == 200)
        // Ouverture : synchro de ce dossier-là seulement.
        await rig.session.openFolder(path: "Factures")
        #expect(try await wait { try await rig.store.messageCount(folderID: byPath["Factures"]!.id) == 30 })
        #expect(try await rig.store.messageCount(folderID: byPath["&AMk-t&AOk-"]!.id) == 0)
        // Toujours lecture seule (vérifié avant la commande d'administration, qui utilise SELECT).
        let forbidden = ["STORE", "EXPUNGE", "DELETE", "APPEND", "COPY", "MOVE", "CREATE", "RENAME", "SELECT"]
        #expect(!rig.server.commandLog().contains { entry in forbidden.contains { entry.contains($0) } })
        // Un dossier ouvert est ensuite repris par la resynchro complète.
        try rig.server.admin("XADD 3", folder: "Factures")
        await rig.session.refresh()
        #expect(try await wait { try await rig.store.messageCount(folderID: byPath["Factures"]!.id) == 33 })
    }

    @Test func grosArbreCompteursDeTousLesDossiers() async throws {
        let rig = try await makeRig(messages: 50, tree: true)
        await rig.session.start()
        defer { Task { await rig.session.stop() } }
        // Dossiers à noms avec espaces, « & » (UTF-7 : « &- ») et six niveaux : tous reçoivent leurs compteurs, sans rien télécharger.
        #expect(try await wait(30) {
            let s = try await rig.store.folderSummaries(accountID: rig.accountID).filter { $0.role == nil }
            return s.count == 45 && s.allSatisfy(\.countsKnown)
        }, "compteurs de tous les dossiers attendus")
        let state = await rig.session.state
        if case .offline(let detail) = state { Issue.record("session hors ligne : \(detail)") }
        let summaries = try await rig.store.folderSummaries(accountID: rig.accountID)
        #expect(summaries.contains { $0.path == "ADMINISTRATIONS/BANQUE/PAYPAL/1&-1" && $0.displayPath.hasSuffix("1&1") })
        #expect(summaries.contains { $0.path.hasSuffix("LITIGE STELLANTIS/CUSTOMER SERVICES") })
        #expect(summaries.filter { $0.role == nil }.contains { $0.messageCount == 0 })  // des dossiers vides, connus comme tels
        let tree = FolderTree.build(summaries)
        #expect(tree.map(\.name) == ["ADMINISTRATIONS", "EMPLOI", "PERSONNEL", "PROFESSIONNEL"])
    }

    @Test func ouvertureDUnMessagePuisCache() async throws {
        let rig = try await makeRig(messages: 800)
        await rig.session.start()
        defer { Task { await rig.session.stop() } }
        #expect(try await wait { await rig.session.folderID(for: .inbox) != nil })
        let folder = try await rig.store.ensureFolder(accountID: rig.accountID, path: "INBOX", role: "inbox")
        #expect(try await wait { try await rig.store.messageCount(folderID: folder.id) == 800 })
        let validity = try await rig.store.ensureFolder(accountID: rig.accountID, path: "INBOX", role: nil).uidValidity ?? 0
        let first = try await rig.session.messageBytes(folderID: folder.id, folderPath: "INBOX", uidValidity: validity, uid: 700)
        #expect(String(decoding: first, as: UTF8.self).contains("Message-ID"))
        let fetchesBefore = rig.server.commandLog().filter { $0 == "UID FETCH" }.count
        let second = try await rig.session.messageBytes(folderID: folder.id, folderPath: "INBOX", uidValidity: validity, uid: 700)
        #expect(second == first)
        #expect(rig.server.commandLog().filter { $0 == "UID FETCH" }.count == fetchesBefore)  // servi par le cache : aucune commande de plus
        let readable = ReadableMessage.make(from: first)
        #expect(!readable.readingText.isEmpty)
        #expect(readable.headers.messageID != nil)
    }

    @Test func ouvertureDurantLaSynchroEstServieEnPriorite() async throws {
        let rig = try await makeRig(messages: 60_000)
        await rig.session.start()
        defer { Task { await rig.session.stop() } }
        #expect(try await wait { await rig.session.folderID(for: .inbox) != nil })
        let folder = try await rig.store.ensureFolder(accountID: rig.accountID, path: "INBOX", role: "inbox")
        // Attend que la synchro de la Réception ait commencé (état « synchronisation » ou premières lignes en base).
        #expect(try await wait { try await rig.store.messageCount(folderID: folder.id) > 0 })
        let t0 = ContinuousClock.now
        let bytes = try await rig.session.messageBytes(folderID: folder.id, folderPath: "INBOX", uidValidity: 1_700_000_000, uid: 59_990)
        let elapsed = ContinuousClock.now - t0
        #expect(String(decoding: bytes, as: UTF8.self).contains("Message-ID"))
        #expect(elapsed < .seconds(5), "ouverture trop lente pendant la synchro : \(elapsed)")
    }

    @Test func nouveauMessageParIdle() async throws {
        let rig = try await makeRig(messages: 500)
        await rig.session.start()
        defer { Task { await rig.session.stop() } }
        let folder = try await rig.store.ensureFolder(accountID: rig.accountID, path: "INBOX", role: "inbox")
        #expect(try await wait { try await rig.store.messageCount(folderID: folder.id) == 500 })
        #expect(try await wait { if case .online = await rig.session.state { return true } else { return false } })
        try await Task.sleep(for: .seconds(1))  // laisse la connexion IDLE s'établir
        try rig.server.admin("XADD 3")
        #expect(try await wait(15) { try await rig.store.messageCount(folderID: folder.id) == 503 })
    }

    @Test func motDePasseAbsentPuisRefuse() async throws {
        let rig = try await makeRig(messages: 50, password: nil)
        await rig.session.start()
        defer { Task { await rig.session.stop() } }
        #expect(try await wait { await rig.session.state == .needsPassword })
        try rig.secrets.setPassword("faux", for: rig.config.secretKey)
        await rig.session.credentialsDidChange()
        #expect(try await wait { if case .authFailed = await rig.session.state { return true } else { return false } })
        try rig.secrets.setPassword("test", for: rig.config.secretKey)
        await rig.session.credentialsDidChange()
        #expect(try await wait { if case .online = await rig.session.state { return true } else { return false } })
    }

    @Test func coupureDuServeurPuisReprise() async throws {
        let rig = try await makeRig(messages: 300)
        await rig.session.start()
        defer { Task { await rig.session.stop() } }
        let folder = try await rig.store.ensureFolder(accountID: rig.accountID, path: "INBOX", role: "inbox")
        #expect(try await wait { try await rig.store.messageCount(folderID: folder.id) == 300 })
        #expect(try await wait { if case .online = await rig.session.state { return true } else { return false } })
        let port = rig.server.port
        rig.server.kill()
        #expect(try await wait(20) { if case .offline = await rig.session.state { return true } else { return false } }, "état hors ligne attendu")
        // Le serveur revient sur le même port : le moteur se reconnecte seul.
        let reborn = try TestServer(messages: 310, port: port)
        withExtendedLifetime(reborn) {}
        #expect(try await wait(60) { try await rig.store.messageCount(folderID: folder.id) == 310 }, "reprise après coupure attendue")
        #expect(try await wait { if case .online = await rig.session.state { return true } else { return false } })
    }

    @Test func arretCoupeProprementLesDemandesEnAttente() async throws {
        let rig = try await makeRig(messages: 100, password: nil)  // jamais connecté
        await rig.session.start()
        #expect(try await wait { await rig.session.state == .needsPassword })
        await #expect(throws: MoteurError.self) {
            _ = try await rig.session.messageBytes(folderID: 1, folderPath: "INBOX", uidValidity: 1, uid: 1)
        }
        await rig.session.stop()
        #expect(await rig.session.state == .stopped)
    }
}
