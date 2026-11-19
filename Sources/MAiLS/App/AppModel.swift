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
    /// Incrémenté pour demander le focus du champ « Aller à un dossier » (⌘J).
    private(set) var focusJumpTick = 0
    /// Arbre des dossiers sans rôle (les principaux ont leur place fixe en haut de la barre latérale).
    private(set) var tree: [FolderNode] = []
    /// Chemins bruts des niveaux dépliés (retenus d'un lancement à l'autre).
    private(set) var expandedPaths: Set<String> = []
    var hideEmptyFolders = false {
        didSet { if oldValue != hideEmptyFolders { UserDefaults.standard.set(hideEmptyFolders, forKey: Self.hideEmptyKey) } }
    }
    /// Texte de « Aller à un dossier » et ligne choisie parmi les résultats.
    var jumpText = "" {
        didSet { if oldValue != jumpText { jumpIndex = 0 } }
    }
    var jumpIndex = 0

    var selectedFolderID: Int64? {
        didSet {
            guard oldValue != selectedFolderID else { return }
            selectedUID = nil
            reader = .none
            rebuildQuery()
            openSelectedFolderIfNeeded()
            expandAncestorsOfSelection()
        }
    }
    var searchText = "" {
        didSet { if oldValue != searchText { rebuildQuery() } }
    }

    private var observers: [Task<Void, Never>] = []
    private var openTask: Task<Void, Never>?
    private var openFolderTask: Task<Void, Never>?
    private var deferFolderOpen = false
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
        expandedPaths = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey(id)) ?? [])
        hideEmptyFolders = UserDefaults.standard.bool(forKey: Self.hideEmptyKey)
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

    /// Un clic ouvre (synchronise) le dossier tout de suite ; aux flèches, seulement si on s'y arrête (sinon chaque dossier survolé
    /// serait synchronisé en entier et retenu).
    private func openSelectedFolderIfNeeded() {
        openFolderTask?.cancel()
        openFolderTask = nil
        guard let folder = folders.first(where: { $0.id == selectedFolderID }), !Self.isMainFolder(folder) else { return }
        let path = folder.path
        if deferFolderOpen {
            openFolderTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, self.selectedFolder?.path == path else { return }
                await self.session?.openFolder(path: path)
            }
        } else {
            Task { await session?.openFolder(path: path) }
        }
    }

    func refreshFolders() async {
        guard let id = account?.id, let all = try? await store.folderSummaries(accountID: id) else { return }
        folders = all.sorted {
            let (a, b) = (Self.rank($0), Self.rank($1))
            return a != b ? a < b : $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending
        }
        tree = FolderTree.build(folders) { [self] in displayName(for: $0) }
        if selectedFolderID == nil || !folders.contains(where: { $0.id == selectedFolderID }) {
            selectedFolderID = folders.first(where: { $0.role == "inbox" })?.id ?? folders.first?.id
        }
    }

    // MARK: Arbre, épinglés, « Aller à un dossier »

    private static let hideEmptyKey = "hideEmptyFolders"
    private static func expandedKey(_ accountID: Int64) -> String { "expandedFolders.\(accountID)" }

    /// Dossiers fixes du haut : les cinq principaux puis les indésirables, dans l'ordre habituel.
    var mainFolders: [FolderSummary] { folders.filter { Self.isMainFolder($0) || $0.role == "junk" } }
    var pinnedFolders: [FolderSummary] {
        folders.filter(\.pinned).sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
    }
    var treeRows: [FolderRow] {
        let keep = selectedFolder.flatMap { $0.role == nil ? Set([$0.path]) : nil } ?? []
        return FolderTree.rows(tree, expanded: expandedPaths, hideEmpty: hideEmptyFolders, keeping: keep)
    }
    var treeFolderCount: Int { folders.filter { $0.role == nil }.count }
    var jumpResults: [FolderSummary] {
        FolderTree.search(folders, query: jumpText) { [self] in displayName(for: $0) }
    }
    var isJumping: Bool { !jumpText.trimmingCharacters(in: .whitespaces).isEmpty }
    var selectedFolder: FolderSummary? { folders.first { $0.id == selectedFolderID } }

    func displayName(for folder: FolderSummary) -> String {
        if let role = folder.role { return L("folder.\(role)") }
        return FolderTree.breadcrumb(for: folder).last?.name ?? folder.displayPath
    }

    func folder(atPath path: String) -> FolderSummary? { folders.first { $0.path == path } }

    func toggleExpanded(_ path: String) {
        if expandedPaths.contains(path) { expandedPaths.remove(path) } else { expandedPaths.insert(path) }
        persistExpanded()
    }

    func collapseAll() {
        expandedPaths = []
        persistExpanded()
    }

    private func persistExpanded() {
        guard let id = account?.id else { return }
        UserDefaults.standard.set(Array(expandedPaths), forKey: Self.expandedKey(id))
    }

    /// Montre le dossier choisi : ses niveaux parents se déplient.
    private func expandAncestorsOfSelection() {
        guard let folder = selectedFolder, folder.role == nil else { return }
        let missing = FolderTree.ancestorPaths(of: folder).filter { !expandedPaths.contains($0) }
        guard !missing.isEmpty else { return }
        expandedPaths.formUnion(missing)
        persistExpanded()
    }

    func selectFolder(_ id: Int64) {
        selectedFolderID = id
        jumpText = ""
    }

    func togglePin(_ folder: FolderSummary) {
        let pinned = !folder.pinned
        Task { try? await store.setPinned(folderID: folder.id, pinned: pinned) }
    }

    func focusJump() { focusJumpTick += 1 }

    func moveJumpSelection(_ delta: Int) {
        let n = jumpResults.count
        guard n > 0 else { return }
        jumpIndex = min(max(jumpIndex + delta, 0), n - 1)
    }

    /// Entrée dans « Aller à un dossier » : ouvre le résultat choisi.
    func openJumpSelection() {
        let results = jumpResults
        guard results.indices.contains(jumpIndex) else { return }
        selectFolder(results[jumpIndex].id)
    }

    // MARK: Clavier dans la barre latérale

    /// Une ligne de la barre latérale atteignable aux flèches : `key` identifie la ligne (« m: » principal, « t: » arbre),
    /// `folderID` est nil pour un niveau qui n'est pas un dossier (on le saute).
    private struct NavigationItem {
        let key: String
        let folderID: Int64?
    }

    /// Lignes dans l'ordre affiché : principaux puis arbre. Par ligne, pas par dossier : aucune ligne n'est confondue avec une autre.
    private var navigationItems: [NavigationItem] {
        mainFolders.map { NavigationItem(key: "m:\($0.id)", folderID: $0.id) }
            + treeRows.map { NavigationItem(key: "t:\($0.id)", folderID: $0.folder?.id) }
    }

    /// Sélection au clavier : le dossier n'est ouvert (synchronisé) que si on s'y arrête.
    private func selectFromKeyboard(_ id: Int64) {
        deferFolderOpen = true
        selectFolder(id)
        deferFolderOpen = false
    }

    func moveSelection(_ delta: Int) {
        let items = navigationItems
        guard !items.isEmpty else { return }
        var start: Int?
        if let current = selectedFolder {
            let key = current.role == nil ? "t:\(current.path)" : "m:\(current.id)"
            start = items.firstIndex { $0.key == key }
            if start == nil {
                // Le dossier ouvert est caché (parent replié) : on part de la ligne visible de son plus proche parent.
                for path in FolderTree.ancestorPaths(of: current).reversed() {
                    if let i = items.firstIndex(where: { $0.key == "t:\(path)" }) { start = i; break }
                }
            }
        }
        var i = start ?? (delta > 0 ? -1 : items.count)
        repeat { i += delta } while items.indices.contains(i) && items[i].folderID == nil
        guard items.indices.contains(i), let id = items[i].folderID else { return }  // au bout de la liste : on reste
        selectFromKeyboard(id)
    }

    /// Flèche droite : déplie, ou descend sur le premier sous-dossier (un niveau qui n'est pas un dossier se déplie d'abord).
    /// Sans effet sur un dossier principal de la liste fixe.
    func expandOrDescend() {
        guard let current = selectedFolder, current.role == nil else { return }
        let rows = treeRows
        guard let index = rows.firstIndex(where: { $0.id == current.path }), rows[index].hasChildren else { return }
        let row = rows[index]
        if !row.isExpanded { toggleExpanded(row.id); return }
        for next in rows[(index + 1)...] {
            guard next.depth > row.depth else { return }
            if let id = next.folder?.id { selectFromKeyboard(id); return }
            if next.hasChildren && !next.isExpanded { toggleExpanded(next.id); return }
        }
    }

    /// Flèche gauche : replie, ou remonte sur le dossier parent.
    func collapseOrAscend() {
        guard let current = selectedFolder, current.role == nil, let row = treeRows.first(where: { $0.id == current.path }) else { return }
        if row.isExpanded { toggleExpanded(row.id); return }
        // Le plus proche parent qui est un dossier (les niveaux que le serveur ne liste pas sont sautés).
        for path in FolderTree.ancestorPaths(of: current).reversed() {
            if let parent = folder(atPath: path) { selectFromKeyboard(parent.id); return }
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
        tree = []
        expandedPaths = []
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
        guard let e = error as? MoteurError else { return error.localizedDescription }
        // Le moteur (MAiLSCore) reste sans interface : le texte visible est composé ici, dans la langue de l'utilisateur.
        switch e {
        case .plaintextLoginRefused(let host): return L("err.plaintext", host)
        case .authenticationFailed(let t): return L("err.auth", t)
        case .commandFailed(let t): return L("err.command", t)
        case .protocolViolation(let t): return L("err.protocol", t)
        case .messageTooLarge(let limit): return L("err.toolarge", limit)
        case .offline: return L("err.offline")
        case .timedOut: return L("err.timeout")
        }
    }
}
