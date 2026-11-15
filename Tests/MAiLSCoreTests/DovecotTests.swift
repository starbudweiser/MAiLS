import Foundation
import Testing

@testable import MAiLSCore

/// Essais contre un vrai Dovecot (Fixtures/dovecot/start_dovecot.sh start). Ignorés si MOTEUR_DOVECOT_PORT n'est pas défini :
///   MOTEUR_DOVECOT_PORT=14500 swift test --filter Dovecot
private let dovecotPort: UInt16? = ProcessInfo.processInfo.environment["MOTEUR_DOVECOT_PORT"].flatMap { UInt16($0) }

@Suite("Dovecot réel", .serialized, .enabled(if: dovecotPort != nil))
struct DovecotTests {
    let endpoint = ServerEndpoint(host: "127.0.0.1", port: dovecotPort ?? 0, useTLS: false)

    @Test func rolesDesDossiersViaSpecialUse() async throws {
        let folders = try await IMAPSession.withSession(endpoint: endpoint) { session in
            try await session.login(username: "test", password: "test")
            return try await session.listFolders()
        }
        let roles = Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0.role) })
        #expect(roles["Sent"] == "sent")
        #expect(roles["Trash"] == "trash")
        #expect(roles["Drafts"] == "drafts")
        #expect(roles["Archive"] == "archive")
        #expect(roles["INBOX"] == .some(nil))
    }

    @Test func synchroDuDossierArchiveEtLectureSansEffetDeBord() async throws {
        let maildir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".dovecot/Maildir/.Archive/cur")
        let before = try FileManager.default.contentsOfDirectory(atPath: maildir.path).sorted()

        let store = try MailStore(path: temporaryDatabasePath())
        let account = try await store.ensureAccount(label: "d", host: "127.0.0.1", port: Int(endpoint.port), username: "test")
        let report = try await IMAPSession.withSession(endpoint: endpoint) { session in
            try await session.login(username: "test", password: "test")
            let r = try await SyncEngine(store: store, batchSize: 500).syncFolder(session: session, accountID: account, path: "Archive")
            // Lire le corps de messages non lus ne doit rien changer côté serveur.
            for uid: UInt32 in [2450, 2460, 2499] {
                let bytes = try await session.fetchMessage(uid: uid)
                #expect(String(decoding: bytes, as: UTF8.self).contains("Message-ID"))
            }
            return r
        }
        #expect(report.newMessages == 2500)
        let folder = try await store.ensureFolder(accountID: account, path: "Archive", role: nil)
        let page = try await store.latest(folderID: folder.id, limit: 2500)
        #expect(page.count == 2500)
        #expect(page.allSatisfy { !$0.subject.isEmpty && !$0.subject.contains("=?") })
        #expect(page.allSatisfy { $0.fromEmail?.contains("@") == true })
        #expect(try await store.search(folderID: folder.id, query: "securite").count > 0)

        let after = try FileManager.default.contentsOfDirectory(atPath: maildir.path).sorted()
        #expect(before == after, "la lecture a modifié la boîte (drapeaux ou fichiers)")
    }

    @Test func idleSeReveille() async throws {
        // Livre un message dans Trash (non utilisé ailleurs) et attend la notification IDLE.
        let maildir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".dovecot/Maildir/.Trash/new")
        let name = "17999\(Int.random(in: 10000...99999)).M\(UInt32.random(in: 1...999999))P1.test"
        let deliver = Task.detached {
            try await Task.sleep(for: .seconds(1))
            try Data("From: a@b.fr\r\nSubject: idle\r\nMessage-ID: <idle@x>\r\n\r\ncorps\r\n".utf8)
                .write(to: maildir.appendingPathComponent(name))
        }
        let clock = ContinuousClock()
        let elapsed: Duration = try await IMAPSession.withSession(endpoint: endpoint) { session in
            try await session.login(username: "test", password: "test")
            _ = try await session.examine("Trash")
            let t0 = clock.now
            _ = try await session.idleUntilNewMessage()
            return clock.now - t0
        }
        try await deliver.value
        try? FileManager.default.removeItem(at: maildir.appendingPathComponent(name))  // ne laisse pas de trace (déjà indexé : nettoyage best effort)
        #expect(elapsed < .seconds(10), "IDLE n'a réagi qu'après \(elapsed)")
    }

    @Test func idleBorneEnTempsSurDovecot() async throws {
        try await IMAPSession.withSession(endpoint: endpoint) { session in
            try await session.login(username: "test", password: "test")
            _ = try await session.examine("Drafts")
            #expect(try await session.idle(timeout: .milliseconds(500)) == .timedOut)
            #expect(try await session.idle(timeout: .milliseconds(500)) == .timedOut)
            #expect(try await session.fetchHeaders(uids: 1...3).count == 3)
        }
    }
}
