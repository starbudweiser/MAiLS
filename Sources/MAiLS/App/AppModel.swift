import AppKit
import MAiLSCore
import Observation
import SwiftUI

/// État de l'application : compte, dossiers, liste, message ouvert. Tout ce qui touche au réseau ou à la base passe par `MAiLSCore`.
@MainActor
@Observable
final class AppModel {
    enum ReaderState {
        case none
        case loading
        case ready(ReadableMessage, MessageSummary)
        case failed(String)
    }

    enum ReaderMode: Hashable { case reading, original }

    let store: MailStore
    let bodyCache: BodyCache
    let secrets: KeychainSecretStore

    private(set) var account: AccountConfig?
    private(set) var session: AccountSession?
    private(set) var syncState: AccountSession.State = .stopped
    private(set) var folders: [FolderSummary] = []
    private(set) var query: MessageQuery?
    /// Incrémenté à chaque changement de données : la liste se recharge.
    private(set) var listRevision = 0
    /// Nombre de lignes de la liste (renseigné par la liste), pour afficher « aucun message ».
    private(set) var listCount = 0
    private(set) var reader: ReaderState = .none
    private(set) var selectedUID: UInt32?
    var readerMode: ReaderMode = .reading
    var showSetup = false
    var setupError: String?
    var showRemoveConfirmation = false
    /// Incrémenté pour demander le focus du champ de recherche (⌘F).
    private(set) var focusSearchTick = 0

    var selectedFolderID: Int64? {
        didSet {
            guard oldValue != selectedFolderID else { return }
            selectedUID = nil
            reader = .none
            rebuildQuery()
            openSelectedFolderIfNeeded()
        }
    }
    var searchText = "" {
        didSet { if oldValue != searchText { rebuildQuery() } }
    }

    private var observers: [Task<Void, Never>] = []
    private var openTask: Task<Void, Never>?
    private var started = false

    init(store: MailStore, bodyCache: BodyCache, secrets: KeychainSecretStore) {
        self.store = store
        self.bodyCache = bodyCache
        self.secrets = secrets
    }

    /// Dossier de données : `~/Library/Application Support/MAiLS` (dans le conteneur de l'appli quand elle est sandboxée).
    static func makeDefault() throws -> AppModel {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MAiLS", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "fr.stephan.mails"
        return AppModel(
            store: try MailStore(path: base.appendingPathComponent("mails.db").path),
            bodyCache: try BodyCache(path: base.appendingPathComponent("bodies.db").path),
            secrets: KeychainSecretStore(service: bundleID))
    }

    // MARK: Démarrage

    func start() async {
        guard !started else { return }
        started = true
        if let dev = Self.developmentAccount() {
            if let saved = try? await store.saveAccount(dev.config) {
                try? secrets.setPassword(dev.password, for: saved.secretKey)
                attach(saved)
                return
            }
        }
        if let existing = try? await store.accounts().first {
            attach(existing)
        } else {
            showSetup = true
        }
    }

    /// Essais seulement : `MAILS_DEV_ACCOUNT=hôte:port:utilisateur:mot-de-passe`, honoré uniquement par la version de développement
    /// (identifiant `….dev`) et vers la boucle locale. Évite de saisir un mot de passe d'essai à la main.
    private static func developmentAccount() -> (config: AccountConfig, password: String)? {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
              let raw = ProcessInfo.processInfo.environment["MAILS_DEV_ACCOUNT"] else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 3).map(String.init)
        guard parts.count == 4, let port = UInt16(parts[1]), ["127.0.0.1", "localhost"].contains(parts[0]) else { return nil }
        return (AccountConfig(label: "Dev", host: parts[0], port: port, useTLS: false, username: parts[2]), parts[3])
    }

    private func attach(_ config: AccountConfig) {
        observers.forEach { $0.cancel() }
        observers = []
        if let old = session { Task { await old.stop() } }
        guard let id = config.id else { return }
        account = config
        let newSession = AccountSession(config: config, accountID: id, store: store, secrets: secrets, bodyCache: bodyCache)
        session = newSession

        observers.append(Task { [weak self] in
            for await state in await newSession.states() {
                guard let self else { return }
                self.apply(state)
            }
        })
        observers.append(Task { [weak self] in
            guard let self else { return }
            await self.refreshFolders()
            for await folderID in self.store.changes() {
                await self.refreshFolders()
                if folderID == self.query?.folderID { self.listRevision += 1 }
            }
        })
        Task { await newSession.start() }
    }

    private func apply(_ state: AccountSession.State) {
        syncState = state
        switch state {
        case .needsPassword:
            setupError = nil
            showSetup = true
        case .authFailed:
            setupError = L("status.authFailed")
            showSetup = true
        default:
            break
        }
        if case .online = state { Task { await refreshFolders() } }
    }

    private static let roleOrder: [String] = FolderRole.syncOrder.map(\.rawValue)

    /// Cinq principaux dans l'ordre habituel, puis les indésirables, puis les autres dossiers par nom.
    private static func rank(_ folder: FolderSummary) -> Int {
        if let role = folder.role, let i = roleOrder.firstIndex(of: role) { return i }
        return folder.role == "junk" ? roleOrder.count : roleOrder.count + 1
    }

    /// Vrai pour les cinq principaux (suivis en continu) ; les autres dossiers, indésirables compris, ne se synchronisent qu'à l'ouverture.
    static func isMainFolder(_ folder: FolderSummary) -> Bool { folder.role.map(roleOrder.contains) ?? false }

    private func openSelectedFolderIfNeeded() {
        guard let folder = folders.first(where: { $0.id == selectedFolderID }), !Self.isMainFolder(folder) else { return }
        Task { await session?.openFolder(path: folder.path) }
    }

    func refreshFolders() async {
        guard let id = account?.id, let all = try? await store.folderSummaries(accountID: id) else { return }
        folders = all.sorted {
            let (a, b) = (Self.rank($0), Self.rank($1))
            return a != b ? a < b : $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending
        }
        if selectedFolderID == nil || !folders.contains(where: { $0.id == selectedFolderID }) {
            selectedFolderID = folders.first(where: { $0.role == "inbox" })?.id ?? folders.first?.id
        }
    }

    private func rebuildQuery() {
        guard let folderID = selectedFolderID else { query = nil; return }
        let parsed = SearchQuery.parse(searchText)
        query = MessageQuery(folderID: folderID, search: parsed.isEmpty ? nil : parsed)
        listRevision += 1
    }

    // MARK: Actions

    func setListCount(_ n: Int) { if n != listCount { listCount = n } }
    func refresh() { Task { await session?.refresh() } }
    func focusSearch() { focusSearchTick += 1 }

    func saveAccount(username: String, password: String) async {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty else { setupError = L("setup.error.empty"); return }
        do {
            let saved = try await store.saveAccount(.icloud(username: user))
            try secrets.setPassword(password, for: saved.secretKey)
            setupError = nil
            showSetup = false
            if let session, account?.secretKey == saved.secretKey { await session.credentialsDidChange() } else { attach(saved) }
        } catch {
            setupError = L("setup.error.keychain")
        }
    }

    func removeAccount() async {
        guard let account, let id = account.id else { return }
        observers.forEach { $0.cancel() }
        observers = []
        await session?.stop()
        session = nil
        try? secrets.deletePassword(for: account.secretKey)
        try? await store.deleteAccount(id: id)
        try? await bodyCache.clear()
        self.account = nil
        folders = []
        query = nil
        reader = .none
        selectedUID = nil
        selectedFolderID = nil
        syncState = .stopped
        showSetup = true
    }

    // MARK: Lecture d'un message

    func open(_ summary: MessageSummary) {
        guard selectedUID != summary.uid || reader.isNone else { return }
        selectedUID = summary.uid
        reader = .loading
        openTask?.cancel()
        guard let session, let folderID = selectedFolderID, let folder = folders.first(where: { $0.id == folderID }) else { return }
        let uid = summary.uid
        openTask = Task { [weak self] in
            do {
                let bytes = try await session.messageBytes(folderID: folderID, folderPath: folder.path, uidValidity: folder.uidValidity ?? 0, uid: uid)
                // Analyse (MIME, HTML) hors du fil principal.
                let readable = await Task.detached(priority: .userInitiated) { ReadableMessage.make(from: bytes) }.value
                guard let self, !Task.isCancelled, self.selectedUID == uid else { return }
                self.reader = .ready(readable, summary)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.selectedUID == uid else { return }
                self.reader = .failed(AccountSession.describeForUser(error))
            }
        }
    }

    func clearSelection() {
        selectedUID = nil
        reader = .none
        openTask?.cancel()
    }
}

extension AppModel.ReaderState {
    var isNone: Bool { if case .none = self { true } else { false } }
}

extension AccountSession {
    nonisolated static func describeForUser(_ error: Error) -> String {
        if let e = error as? MoteurError { return e.description }
        return error.localizedDescription
    }
}
