import Foundation
import MAiLSCore

// Banc d'essai du moteur de MAiLS, sans interface.
//   mails-bench sync    --db f.db [--host 127.0.0.1] [--port 14300] [--folder INBOX] [--batch 1000] [--user test]
//   mails-bench search  --db f.db [--folder INBOX] mot…
//   mails-bench latest  --db f.db [--folder INBOX]
//   mails-bench body    --uid N [--folder INBOX]
//   mails-bench idle    [--folder INBOX]
//   mails-bench folders
// Le mot de passe se lit dans MOTEUR_PASSWORD (jamais en argument : visible dans `ps`).

func argument(_ name: String, default fallback: String? = nil) -> String? {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count { return args[i + 1] }
    return fallback
}

func millis(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

func peakRSSMegabytes() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576  // macOS : octets
}

func fileSize(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let command = CommandLine.arguments.dropFirst().first ?? "help"
let host = argument("host", default: "127.0.0.1")!
let port = UInt16(argument("port", default: "14300")!) ?? 14300
let useTLS = argument("tls", default: "no") == "yes"
let user = argument("user", default: "test")!
let folderPath = argument("folder", default: "INBOX")!
let dbPath = argument("db", default: "/tmp/mails-bench.db")!
let password = ProcessInfo.processInfo.environment["MOTEUR_PASSWORD"] ?? "test"
let endpoint = ServerEndpoint(host: host, port: port, useTLS: useTLS)

func printMetric(_ key: String, _ value: String) { print("\(key.padding(toLength: 28, withPad: " ", startingAt: 0)) \(value)") }

do {
    switch command {
    case "sync":
        let store = try MailStore(path: dbPath)
        let batch = UInt32(argument("batch", default: "1000")!) ?? 1000
        let engine = SyncEngine(store: store, batchSize: batch)
        let accountID = try await store.ensureAccount(label: "essai", host: host, port: Int(port), username: user)
        let report = try await IMAPSession.withSession(endpoint: endpoint) { session in
            try await session.login(username: user, password: password)
            return try await engine.syncFolder(session: session, accountID: accountID, path: folderPath) { fetched in
                if fetched > 0, fetched % 20000 == 0 { FileHandle.standardError.write(Data("  … \(fetched) messages\n".utf8)) }
            }
        }
        let folder = try await store.ensureFolder(accountID: accountID, path: folderPath, role: nil)
        let count = try await store.messageCount(folderID: folder.id)
        let ms = millis(report.duration)
        printMetric("dossier", report.folder)
        printMetric("messages côté serveur", "\(report.serverMessages)")
        printMetric("nouveaux en base", "\(report.newMessages)")
        printMetric("total en base", "\(count)")
        printMetric("drapeaux mis à jour", "\(report.flagsUpdated)")
        printMetric("supprimés", "\(report.removed)")
        printMetric("fenêtres", "\(report.batches)")
        printMetric("UIDVALIDITY changé", "\(report.wipedForUIDValidity)")
        printMetric("durée", String(format: "%.0f ms", ms))
        if report.newMessages > 0 { printMetric("débit", String(format: "%.0f messages/s", Double(report.newMessages) / (ms / 1000))) }
        printMetric("taille de la base", String(format: "%.1f Mo", Double(fileSize(dbPath) + fileSize(dbPath + "-wal")) / 1_048_576))
        printMetric("mémoire max (RSS)", String(format: "%.0f Mo", peakRSSMegabytes()))
        printMetric("intégrité SQLite", try await store.integrityCheck())

    case "search":
        let store = try MailStore(path: dbPath)
        let accountID = try await store.ensureAccount(label: "essai", host: host, port: Int(port), username: user)
        let folder = try await store.ensureFolder(accountID: accountID, path: folderPath, role: nil)
        // Mots de la requête : arguments positionnels (on saute les couples « --option valeur »).
        var terms: [String] = []
        var skip = false
        for arg in CommandLine.arguments.drop(while: { $0 != "search" }).dropFirst() {
            if skip { skip = false; continue }
            if arg.hasPrefix("--") { skip = true; continue }
            terms.append(arg)
        }
        let queries = terms.isEmpty ? ["facture", "élodie", "securite", "chloe dupont", "rapport budget", "remboursement", "zoe mueller"] : terms
        let clock = ContinuousClock()
        for q in queries {
            var times: [Double] = []
            var hits: [SearchHit] = []
            for _ in 0..<20 {
                let t0 = clock.now
                hits = try await store.search(folderID: folder.id, query: q)
                times.append(millis(clock.now - t0))
            }
            times.sort()
            printMetric("« \(q) »", String(format: "%3d résultats · médiane %.2f ms · pire %.2f ms", hits.count, times[times.count / 2], times.last!))
        }

    case "latest":
        let store = try MailStore(path: dbPath)
        let accountID = try await store.ensureAccount(label: "essai", host: host, port: Int(port), username: user)
        let folder = try await store.ensureFolder(accountID: accountID, path: folderPath, role: nil)
        let clock = ContinuousClock()
        var times: [Double] = []
        for page in 0..<20 {
            let t0 = clock.now
            let rows = try await store.latest(folderID: folder.id, limit: 100, offset: page * 100)
            times.append(millis(clock.now - t0))
            if page == 0, let first = rows.first { printMetric("plus récent", "\(first.subject) — \(first.fromName ?? first.fromEmail ?? "?")") }
        }
        times.sort()
        printMetric("100 plus récents (×20 pages)", String(format: "médiane %.2f ms · pire %.2f ms", times[10], times.last!))
        let t1 = clock.now
        let unread = try await store.unreadCount(folderID: folder.id)
        printMetric("non lus", "\(unread) en \(String(format: "%.2f", millis(clock.now - t1))) ms")

    case "body":
        guard let uidText = argument("uid"), let uid = UInt32(uidText) else { fail("--uid requis") }
        let clock = ContinuousClock()
        try await IMAPSession.withSession(endpoint: endpoint) { session in
            try await session.login(username: user, password: password)
            _ = try await session.examine(folderPath)
            let t0 = clock.now
            let bytes = try await session.fetchMessage(uid: uid)
            printMetric("message \(uid)", "\(bytes.count) octets en \(String(format: "%.1f", millis(clock.now - t0))) ms")
            print(String(decoding: bytes.prefix(400), as: UTF8.self))
        }

    case "idle":
        let clock = ContinuousClock()
        try await IMAPSession.withSession(endpoint: endpoint) { session in
            try await session.login(username: user, password: password)
            let status = try await session.examine(folderPath)
            printMetric("IDLE démarré", "\(status.exists) messages")
            let t0 = clock.now
            let n = try await session.idleUntilNewMessage()
            printMetric("notification reçue", "\(n) messages, après \(String(format: "%.0f", millis(clock.now - t0))) ms")
        }

    case "folders":
        try await IMAPSession.withSession(endpoint: endpoint) { session in
            try await session.login(username: user, password: password)
            for f in try await session.listFolders() { printMetric(f.path, "\(f.role ?? "-")\(f.selectable ? "" : " (non sélectionnable)")") }
        }

    default:
        print("Commandes : sync, search, latest, body, idle, folders")
    }
} catch {
    fail("Erreur : \(error)")
}
