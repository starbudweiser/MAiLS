import Foundation
import Testing

@testable import MAiLSCore

/// Essais contre le serveur local `Fixtures/fake_imap_server.py` (voir ses limites : ce n'est pas Dovecot).
@Suite("Synchro IMAP", .serialized)
struct SyncIntegrationTests {
    private func run<T: Sendable>(
        server: TestServer, store: MailStore,
        _ body: @Sendable (IMAPSession, SyncEngine, Int64) async throws -> T
    ) async throws -> T {
        let accountID = try await store.ensureAccount(label: "t", host: "127.0.0.1", port: Int(server.port), username: "test")
        let endpoint = ServerEndpoint(host: "127.0.0.1", port: server.port, useTLS: false)
        return try await IMAPSession.withSession(endpoint: endpoint) { session in
            try await session.login(username: "test", password: "test")
            return try await body(session, SyncEngine(store: store, batchSize: 700), accountID)
        }
    }

    @Test func synchroInitialeCompleteEtRecherche() async throws {
        let server = try TestServer(messages: 2500)
        let store = try MailStore(path: temporaryDatabasePath())
        let report = try await run(server: server, store: store) { session, engine, account in
            try await engine.syncFolder(session: session, accountID: account, path: "INBOX")
        }
        #expect(report.newMessages == 2500)
        #expect(report.batches == 4)  // 2500 / 700
        let account = try await store.ensureAccount(label: "t", host: "127.0.0.1", port: Int(server.port), username: "test")
        let folder = try await store.ensureFolder(accountID: account, path: "INBOX", role: nil)
        #expect(try await store.messageCount(folderID: folder.id) == 2500)
        #expect(folder.syncFloor == 1)
        #expect(folder.uidNext == 2501)
        // Accents du serveur (mots codés B/Q, UTF-8 et Latin-1) retrouvés par recherche sans accent.
        #expect(try await store.search(folderID: folder.id, query: "elodie").count > 0)
        #expect(try await store.search(folderID: folder.id, query: "securite").count > 0)
        // Aucun sujet resté codé : le décodeur RFC 2047 a tout traité.
        let page = try await store.latest(folderID: folder.id, limit: 2500)
        #expect(page.count == 2500)
        #expect(page.allSatisfy { !$0.subject.isEmpty })  // garde-fou : « pas de =? » ne doit pas passer à vide
        #expect(page.allSatisfy { !$0.subject.contains("=?") })
        #expect(page.allSatisfy { !($0.fromName ?? "").contains("=?") })
        #expect(page.allSatisfy { $0.fromEmail?.contains("@") == true })
        #expect(page.contains { $0.fromName == "Élodie Martin" })
        #expect(page.contains { $0.subject.contains("é") })
    }

    @Test func synchroIncrementaleNePrendQueLesNouveaux() async throws {
        let server = try TestServer(messages: 1500)
        let store = try MailStore(path: temporaryDatabasePath())
        _ = try await run(server: server, store: store) { s, e, a in try await e.syncFolder(session: s, accountID: a, path: "INBOX") }
        try server.admin("XADD 25")
        try server.admin("XFLAG 10 \\Seen \\Flagged")
        try server.admin("XEXPUNGE 11")
        let report = try await run(server: server, store: store) { s, e, a in try await e.syncFolder(session: s, accountID: a, path: "INBOX") }
        #expect(report.newMessages == 25)
        #expect(report.removed == 1)
        #expect(report.flagsUpdated >= 1)
        #expect(report.batches == 1)  // une seule fenêtre : on n'a pas retéléchargé l'historique
        let account = try await store.ensureAccount(label: "t", host: "127.0.0.1", port: Int(server.port), username: "test")
        let folder = try await store.ensureFolder(accountID: account, path: "INBOX", role: nil)
        #expect(try await store.messageCount(folderID: folder.id) == 1500 + 25 - 1)
        #expect(!(try await store.localUIDs(folderID: folder.id)).contains(11))
    }

    @Test func uidValidityChangeRepartDeZero() async throws {
        let server = try TestServer(messages: 800)
        let store = try MailStore(path: temporaryDatabasePath())
        _ = try await run(server: server, store: store) { s, e, a in try await e.syncFolder(session: s, accountID: a, path: "INBOX") }
        try server.admin("XRESET")
        let report = try await run(server: server, store: store) { s, e, a in try await e.syncFolder(session: s, accountID: a, path: "INBOX") }
        #expect(report.wipedForUIDValidity)
        #expect(report.newMessages == 800)  // tout est retéléchargé, rien n'est resté de l'ancienne numérotation
        let account = try await store.ensureAccount(label: "t", host: "127.0.0.1", port: Int(server.port), username: "test")
        let folder = try await store.ensureFolder(accountID: account, path: "INBOX", role: nil)
        #expect(try await store.messageCount(folderID: folder.id) == 800)
    }

    @Test func reprendUneSynchroInterrompue() async throws {
        let server = try TestServer(messages: 2200)
        let store = try MailStore(path: temporaryDatabasePath())
        let account = try await store.ensureAccount(label: "t", host: "127.0.0.1", port: Int(server.port), username: "test")
        let endpoint = ServerEndpoint(host: "127.0.0.1", port: server.port, useTLS: false)

        // Coupure simulée : on arrête après la première fenêtre en levant une erreur depuis le suivi de progression…
        struct Stop: Error {}
        do {
            try await IMAPSession.withSession(endpoint: endpoint) { session in
                try await session.login(username: "test", password: "test")
                // … en synchronisant « à la main » une seule fenêtre du haut (UID 1501…2200), comme le ferait le moteur.
                let status = try await session.examine("INBOX")
                let raws = try await session.fetchHeaders(uids: 1501...2200)
                let folder = try await store.ensureFolder(accountID: account, path: "INBOX", role: nil)
                try await store.upsert(raws.map {
                    StoredMessage(uid: $0.uid, flags: $0.flags, internalAt: $0.internalAt, size: $0.size, headers: HeaderParser.parse($0.headerBytes))
                }, folderID: folder.id)
                try await store.setFolderState(folderID: folder.id, uidValidity: status.uidValidity, uidNext: status.uidNext, syncFloor: 1501, now: 0)
                throw Stop()
            }
        } catch is Stop {}

        let report = try await run(server: server, store: store) { s, e, a in try await e.syncFolder(session: s, accountID: a, path: "INBOX") }
        #expect(report.newMessages == 1500)  // seulement l'historique manquant (1…1500), pas les 700 déjà reçus
        let folder = try await store.ensureFolder(accountID: account, path: "INBOX", role: nil)
        #expect(try await store.messageCount(folderID: folder.id) == 2200)
        #expect(folder.syncFloor == 1)
    }

    @Test func lectureSeuleAucuneCommandeQuiModifieLeServeur() async throws {
        let server = try TestServer(messages: 600)
        let store = try MailStore(path: temporaryDatabasePath())
        _ = try await run(server: server, store: store) { s, e, a in
            _ = try await e.syncFolder(session: s, accountID: a, path: "INBOX")
            _ = try await s.fetchMessage(uid: 10)
            return try await e.syncFolder(session: s, accountID: a, path: "INBOX")
        }
        let log = server.commandLog()
        #expect(!log.isEmpty)
        let forbidden = ["STORE", "EXPUNGE", "DELETE", "APPEND", "COPY", "MOVE", "CREATE", "RENAME", "SELECT"]
        for entry in log {
            #expect(!forbidden.contains(where: { entry.contains($0) }), "commande interdite en lecture seule : \(entry)")
        }
        #expect(log.contains("EXAMINE"))
    }

    @Test func lireUnMessageNeLeMarquePasCommeLu() async throws {
        let server = try TestServer(messages: 400)
        let store = try MailStore(path: temporaryDatabasePath())
        // UID 400 est non lu (les 50 derniers le sont). Après lecture du corps puis resynchro, il doit le rester.
        _ = try await run(server: server, store: store) { s, e, a in
            _ = try await e.syncFolder(session: s, accountID: a, path: "INBOX")
            let bytes = try await s.fetchMessage(uid: 400)
            #expect(String(decoding: bytes, as: UTF8.self).contains("Message-ID"))
            return try await e.syncFolder(session: s, accountID: a, path: "INBOX")
        }
        let account = try await store.ensureAccount(label: "t", host: "127.0.0.1", port: Int(server.port), username: "test")
        let folder = try await store.ensureFolder(accountID: account, path: "INBOX", role: nil)
        let newest = try await store.latest(folderID: folder.id, limit: 400).first { $0.uid == 400 }
        #expect(newest != nil)
        #expect(newest?.flags.contains(.seen) == false)
    }

    @Test func refuseLeMotDePasseEnClairVersUneAutreMachine() async throws {
        let endpoint = ServerEndpoint(host: "imap.exemple.invalid", port: 143, useTLS: false)
        // Le refus doit survenir avant toute connexion réseau : on le vérifie sur la règle elle-même.
        #expect(!endpoint.isLoopback)
        #expect(ServerEndpoint(host: "127.0.0.1", port: 143, useTLS: false).isLoopback)
        #expect(ServerEndpoint(host: "localhost", port: 143, useTLS: false).isLoopback)
    }

    @Test func mauvaisMotDePasseEstRefuse() async throws {
        let server = try TestServer(messages: 10)
        let endpoint = ServerEndpoint(host: "127.0.0.1", port: server.port, useTLS: false)
        await #expect(throws: MoteurError.self) {
            try await IMAPSession.withSession(endpoint: endpoint) { session in
                try await session.login(username: "test", password: "faux")
            }
        }
    }

    @Test func idleReveilleEnQuelquesMillisecondes() async throws {
        let server = try TestServer(messages: 300)
        let endpoint = ServerEndpoint(host: "127.0.0.1", port: server.port, useTLS: false)
        let clock = ContinuousClock()
        let elapsed: Duration = try await IMAPSession.withSession(endpoint: endpoint) { session in
            try await session.login(username: "test", password: "test")
            _ = try await session.examine("INBOX")
            let trigger = Task.detached {
                try await Task.sleep(for: .milliseconds(400))
                try server.admin("XADD 1")
            }
            let t0 = clock.now
            let count = try await session.idleUntilNewMessage()
            let dt = clock.now - t0
            try await trigger.value
            #expect(count == 301)
            return dt
        }
        #expect(elapsed < .seconds(3))
    }

    @Test func messageTropGrosEstRefuse() async throws {
        let server = try TestServer(messages: 50)
        let endpoint = ServerEndpoint(host: "127.0.0.1", port: server.port, useTLS: false)
        await #expect(throws: MoteurError.messageTooLarge(limit: 100)) {
            try await IMAPSession.withSession(endpoint: endpoint) { session in
                try await session.login(username: "test", password: "test")
                _ = try await session.examine("INBOX")
                _ = try await session.fetchMessage(uid: 5, maxBytes: 100)
            }
        }
    }

    @Test func coupureReseauPendantLaSynchroLeveUneErreurSansBloquer() async throws {
        let server = try TestServer(messages: 120_000)
        let store = try MailStore(path: temporaryDatabasePath())
        let account = try await store.ensureAccount(label: "t", host: "127.0.0.1", port: Int(server.port), username: "test")
        let endpoint = ServerEndpoint(host: "127.0.0.1", port: server.port, useTLS: false)
        let clock = ContinuousClock()
        let t0 = clock.now

        let outcome: String = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    _ = try await IMAPSession.withSession(endpoint: endpoint) { session in
                        try await session.login(username: "test", password: "test")
                        return try await SyncEngine(store: store, batchSize: 500)
                            .syncFolder(session: session, accountID: account, path: "INBOX")
                    }
                    return "terminée"
                } catch { return "erreur" }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(600))
                server.kill()
                try? await Task.sleep(for: .seconds(20))
                return "bloquée"
            }
            let first = await group.next() ?? "?"
            group.cancelAll()
            return first
        }
        #expect(outcome == "erreur", "attendu : une erreur franche, obtenu : \(outcome) après \(clock.now - t0)")

        // Ce qui a été reçu avant la coupure est conservé et cohérent : la base reste valide.
        #expect(try await store.integrityCheck() == "ok")
        let folder = try await store.ensureFolder(accountID: account, path: "INBOX", role: nil)
        let stored = try await store.messageCount(folderID: folder.id)
        #expect(stored < 120_000)
        // sync_floor décrit exactement ce qui est présent : tout UID ≥ floor est en base.
        if let floor = folder.syncFloor, floor > 1 {
            let uids = try await store.localUIDs(folderID: folder.id)
            #expect((floor...120_000).allSatisfy { uids.contains($0) }, "trou au-dessus de sync_floor=\(floor)")
        }
    }

    @Test func idleBorneEnTempsPuisConnexionReutilisable() async throws {
        let server = try TestServer(messages: 200)
        let endpoint = ServerEndpoint(host: "127.0.0.1", port: server.port, useTLS: false)
        try await IMAPSession.withSession(endpoint: endpoint) { session in
            try await session.login(username: "test", password: "test")
            _ = try await session.examine("INBOX")
            // Deux IDLE de suite (régression : swift-nio-imap plantait si le précédent n'était pas terminé), puis une commande ordinaire.
            #expect(try await session.idle(timeout: .milliseconds(400)) == .timedOut)
            #expect(try await session.idle(timeout: .milliseconds(400)) == .timedOut)
            let raws = try await session.fetchHeaders(uids: 1...10)
            #expect(raws.count == 10)
            // Un événement pendant IDLE : rendu aussitôt, connexion toujours bonne.
            let trigger = Task.detached { try await Task.sleep(for: .milliseconds(300)); try server.admin("XADD 1") }
            #expect(try await session.idle(timeout: .seconds(10)) == .newMessages)
            try await trigger.value
            #expect(try await session.idle(timeout: .milliseconds(300)) == .timedOut)
        }
    }
}
