import Foundation

/// Lance `Fixtures/fake_imap_server.py` sur un port libre pour la durée d'un test.
final class TestServer: @unchecked Sendable {
    let port: UInt16
    let logPath: String
    private let process = Process()

    init(messages: Int, port: UInt16? = nil, extraFolders: Bool = false) throws {
        self.port = port ?? UInt16.random(in: 20000...39000)
        let dir = NSTemporaryDirectory() + "moteur-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        logPath = dir + "/commands.log"

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-I", root.appendingPathComponent("Fixtures/fake_imap_server.py").path,
            "--port", "\(self.port)", "--messages", "\(messages)", "--log", logPath,
        ] + (extraFolders ? ["--extra-folders"] : [])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Attend la ligne « prêt » (le serveur écrit après avoir ouvert le port).
        let handle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(10)
        var seen = Data()
        while Date() < deadline {
            let chunk = handle.availableData
            seen.append(chunk)
            if String(decoding: seen, as: UTF8.self).contains("prêt") { return }
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        }
        process.terminate()
        throw NSError(domain: "TestServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "serveur de test non démarré"])
    }

    deinit { process.terminate() }

    /// Coupure brutale (comme un câble débranché ou un serveur qui plante).
    func kill() { process.terminate() }

    /// Commande d'administration (XADD, XFLAG, XEXPUNGE, XRESET) sur le dossier `folder`.
    func admin(_ command: String, folder: String = "INBOX") throws {
        let script = "a LOGIN test test\r\nb SELECT \(folder)\r\nc \(command)\r\nd LOGOUT\r\n"
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-w", "3", "127.0.0.1", "\(port)"]
        let input = Pipe()
        let output = Pipe()
        nc.standardInput = input
        nc.standardOutput = output
        try nc.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        let reply = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        nc.waitUntilExit()
        guard reply.contains("c OK") else {
            throw NSError(domain: "TestServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "admin \(command) : \(reply)"])
        }
    }

    func commandLog() -> [String] {
        ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

func temporaryDatabasePath() -> String {
    NSTemporaryDirectory() + "moteur-\(UUID().uuidString).db"
}
