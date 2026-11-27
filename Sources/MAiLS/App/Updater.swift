// MAiLS — mise à jour depuis les releases GitHub (modèle : mBACKUP/Updater.swift).
// L'appli est dans le bac à sable : elle ne peut pas se remplacer elle-même. Elle télécharge la nouvelle version,
// vérifie sa signature Developer ID, la dépose dans Téléchargements et l'indique dans le Finder.
import AppKit
import Foundation
import MAiLSCore
import Observation

@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case ready(version: String)
        case failed(String)
    }

    static let repo = "starbudweiser/MAiLS"
    static let teamID = "35KLMK53PN"  // seule signature acceptée
    private static let interval: TimeInterval = 24 * 3600

    private(set) var state: State = .idle
    private var release: ReleaseInfo?

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }

    /// Au lancement : une recherche par jour au plus, si elle est permise.
    func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: "updateLastCheck") as? Date ?? .distantPast
        guard autoCheck, state == .idle, Date().timeIntervalSince(last) > Self.interval else { return }
        Task { await check() }
    }

    func check() async {
        switch state { case .checking, .downloading: return; default: break }
        state = .checking
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let info = ReleaseInfo.parse(data) else { throw UpdateError.noRelease }
            UserDefaults.standard.set(Date(), forKey: "updateLastCheck")
            if ReleaseInfo.isNewer(info.version, than: currentVersion) {
                release = info
                state = .available(version: info.version)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Télécharge, vérifie, dépose dans Téléchargements et montre la nouvelle appli dans le Finder.
    func download() async {
        guard case .available(let version) = state, let url = release?.assetURL else { return }
        state = .downloading
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MAiLS-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmp, to: zip)
            let out = work.appendingPathComponent("out")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
            let app = out.appendingPathComponent("MAiLS.app")
            try await verify(app, expecting: version)
            guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { throw UpdateError.download }
            let dest = downloads.appendingPathComponent("MAiLS \(version).app")
            try? FileManager.default.removeItem(at: dest)
            try await Self.run("/usr/bin/ditto", [app.path, dest.path])
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            state = .ready(version: version)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    enum UpdateError: LocalizedError {
        case noRelease, download, badSignature, badVersion
        var errorDescription: String? {
            switch self {
            case .noRelease: return L("upd.err.none")
            case .download: return L("upd.err.download")
            case .badSignature: return L("upd.err.signature")
            case .badVersion: return L("upd.err.version")
            }
        }
    }

    /// La nouvelle appli doit être valide, signée par la même équipe, du même identifiant, et de la version annoncée.
    private func verify(_ app: URL, expecting version: String) async throws {
        try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let info = try await Self.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        guard info.contains("TeamIdentifier=\(Self.teamID)") else { throw UpdateError.badSignature }
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let v = plist["CFBundleShortVersionString"] as? String, v == version,
              ReleaseInfo.isNewer(v, than: currentVersion) else { throw UpdateError.badVersion }
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 { cont.resume(returning: String(decoding: data, as: UTF8.self)) }
                else { cont.resume(throwing: exe.hasSuffix("codesign") ? UpdateError.badSignature : UpdateError.download) }
            }
        }
    }
}
