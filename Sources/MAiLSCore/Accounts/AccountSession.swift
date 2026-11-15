import Foundation

/// Le moteur d'un compte, de bout en bout : deux connexions IMAP (une pour le travail, une pour IDLE sur la Réception),
/// synchro continue des cinq dossiers principaux, tous les autres dossiers listés et synchronisés à l'ouverture
/// (`openFolder`), ouverture des messages à la demande, reconnexion automatique avec attente croissante.
/// Lecture seule : rien ici ne modifie le serveur (voir `IMAPSession`).
public actor AccountSession {
    public enum State: Sendable, Equatable {
        case stopped
        /// Aucun mot de passe au Trousseau : l'interface doit le demander.
        case needsPassword
        case connecting
        case syncing(folder: String, fetched: Int)
        case online(since: Date)
        /// Connexion perdue ou impossible ; une nouvelle tentative est programmée.
        case offline(String)
        /// Mot de passe refusé par le serveur : inutile de réessayer tant qu'il n'a pas changé.
        case authFailed(String)
    }

    public let config: AccountConfig
    public let accountID: Int64
    private let store: MailStore
    private let secrets: SecretStore
    private let bodyCache: BodyCache

    public private(set) var state: State = .stopped
    private var listeners: [UUID: AsyncStream<State>.Continuation] = [:]
    private var tasks: [Task<Void, Never>] = []

    private var folderPaths: [FolderRole: String] = [:]
    private var folderIDs: [String: Int64] = [:]
    /// Dossiers hors des cinq principaux que l'utilisateur a ouverts : ils suivent ensuite les resynchros complètes.
    private var openedPaths: Set<String> = []

    private struct BodyRequest {
        let id: UUID
        let folderPath: String
        let uid: UInt32
        let continuation: CheckedContinuation<[UInt8], Error>
    }
    private struct SyncRequest: Equatable {
        var role: FolderRole?  // nil (et `path` nil) : les cinq principaux et les dossiers ouverts
        var path: String? = nil  // un dossier précis, hors des cinq principaux
        var reconcile: Bool
    }
    private var bodyRequests: [BodyRequest] = []
    private var syncQueue: [SyncRequest] = []

    private var workWaiter: CheckedContinuation<Void, Never>?
    private var workPending = false
    private var credentialsWaiters: [CheckedContinuation<Void, Never>] = []
    private var credentialsChanged = false
    private var reconnectRequested = false

    /// Intervalles (secondes) : IDLE renouvelé avant la coupure serveur (~30 min) ; resynchro complète de sécurité.
    private let idleRenewal: Duration
    private let fullSyncInterval: Duration
    private let bodyTimeout: Duration

    public init(
        config: AccountConfig, accountID: Int64, store: MailStore, secrets: SecretStore, bodyCache: BodyCache,
        idleRenewal: Duration = .seconds(25 * 60), fullSyncInterval: Duration = .seconds(10 * 60), bodyTimeout: Duration = .seconds(60)
    ) {
        self.config = config
        self.accountID = accountID
        self.store = store
        self.secrets = secrets
        self.bodyCache = bodyCache
        self.idleRenewal = idleRenewal
        self.fullSyncInterval = fullSyncInterval
        self.bodyTimeout = bodyTimeout
    }

    // MARK: Interface publique

    /// Flux des états (l'état courant est émis tout de suite).
    public func states() -> AsyncStream<State> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(4))
        listeners[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        return stream
    }

    public func start() {
        guard tasks.isEmpty else { return }
        tasks = [
            Task { await self.workLoop() },
            Task { await self.idleLoop() },
            Task { await self.timerLoop() },
        ]
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        failPending(MoteurError.offline)
        signalWork()
        wakeCredentialWaiters()
        setState(.stopped)
    }

    /// Resynchronisation complète demandée par l'utilisateur.
    public func refresh() {
        queueSync(role: nil, reconcile: true)
    }

    /// À appeler après un changement de mot de passe au Trousseau.
    public func credentialsDidChange() {
        credentialsChanged = true
        wakeCredentialWaiters()
    }

    /// L'utilisateur ouvre un dossier hors des cinq principaux : synchro tout de suite, puis avec les resynchros suivantes.
    public func openFolder(path: String) {
        openedPaths.insert(path)
        queueSync(role: nil, path: path, reconcile: true)
    }

    public func folderID(for role: FolderRole) -> Int64? {
        folderPaths[role].flatMap { folderIDs[$0] }
    }

    /// Le message complet (cache d'abord, sinon téléchargé par la connexion de travail, en priorité sur la synchro).
    public func messageBytes(folderID: Int64, folderPath: String, uidValidity: UInt32, uid: UInt32) async throws -> [UInt8] {
        if let cached = try await bodyCache.get(folderID: folderID, uidValidity: uidValidity, uid: uid) { return cached }
        switch state {
        case .stopped, .needsPassword, .authFailed, .offline: throw MoteurError.offline
        default: break
        }
        let bytes = try await withThrowingTaskGroup(of: [UInt8].self) { group in
            group.addTask { try await self.requestBody(folderPath: folderPath, uid: uid) }
            group.addTask {
                try await Task.sleep(for: self.bodyTimeout)
                throw MoteurError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MoteurError.offline }
            return first
        }
        try? await bodyCache.put(bytes, folderID: folderID, uidValidity: uidValidity, uid: uid)
        return bytes
    }

    // MARK: États

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        for c in listeners.values { c.yield(new) }
    }

    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }

    // MARK: Files d'attente

    private func queueSync(role: FolderRole?, path: String? = nil, reconcile: Bool) {
        let request = SyncRequest(role: role, path: path, reconcile: reconcile)
        if syncQueue.contains(request) || syncQueue.contains(SyncRequest(role: nil, reconcile: true)) { return }
        syncQueue.append(request)
        signalWork()
    }

    private func requestBody(folderPath: String, uid: UInt32) async throws -> [UInt8] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
                bodyRequests.append(BodyRequest(id: id, folderPath: folderPath, uid: uid, continuation: continuation))
                signalWork()
            }
        } onCancel: {
            Task { await self.cancelBody(id) }
        }
    }

    private func cancelBody(_ id: UUID) {
        if let i = bodyRequests.firstIndex(where: { $0.id == id }) {
            bodyRequests.remove(at: i).continuation.resume(throwing: CancellationError())
        }
    }

    private func failPending(_ error: Error) {
        let pending = bodyRequests
        bodyRequests = []
        for r in pending { r.continuation.resume(throwing: error) }
    }

    private func signalWork() {
        if let w = workWaiter { workWaiter = nil; w.resume() } else { workPending = true }
    }

    private func waitForWork() async {
        if workPending { workPending = false; return }
        await withCheckedContinuation { workWaiter = $0 }
    }

    private func waitForCredentials() async {
        if credentialsChanged { credentialsChanged = false; return }
        await withCheckedContinuation { credentialsWaiters.append($0) }
        credentialsChanged = false
    }

    private func wakeCredentialWaiters() {
        let waiters = credentialsWaiters
        credentialsWaiters = []
        for w in waiters { w.resume() }
    }

    // MARK: Connexion de travail

    private func password() -> String? {
        guard let p = try? secrets.password(for: config.secretKey), !p.isEmpty else { return nil }
        return p
    }

    private func workLoop() async {
        var backoff: Double = 2
        while !Task.isCancelled {
            guard let password = password() else {
                setState(.needsPassword)
                await waitForCredentials()
                continue
            }
            setState(.connecting)
            do {
                try await IMAPSession.withSession(endpoint: config.endpoint) { session in
                    try await session.login(username: config.username, password: password)
                    try await self.discoverFolders(session)
                    backoff = 2
                    self.queueSync(role: nil, reconcile: true)
                    try await self.serveLoop(session)
                }
            } catch {
                if Task.isCancelled || error is CancellationError { break }
                failPending(error)
                if case MoteurError.authenticationFailed(let detail) = error {
                    setState(.authFailed(detail))
                    await waitForCredentials()
                    continue
                }
                setState(.offline(Self.describe(error)))
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 300)
            }
        }
    }

    private func discoverFolders(_ session: IMAPSession) async throws {
        let listing = try await session.listFolders()
        folderPaths = FolderRole.assign(listing)
        // Tous les dossiers sélectionnables sont enregistrés (donc visibles) ; seuls les cinq principaux ont un rôle et sont suivis en continu.
        var ids: [String: Int64] = [:]
        for folder in listing where folder.selectable {
            let mainRole = folderPaths.first(where: { $0.value == folder.path })?.key.rawValue
            let role = mainRole ?? (folder.role == "junk" ? "junk" : nil)
            ids[folder.path] = try await store.ensureFolder(accountID: accountID, path: folder.path, role: role).id
        }
        folderIDs = ids
        openedPaths.formIntersection(ids.keys)
        try await store.pruneFolders(accountID: accountID, keeping: Array(ids.keys))
    }

    private func serveLoop(_ session: IMAPSession) async throws {
        var current: String?
        while true {
            try Task.checkCancellation()
            if !bodyRequests.isEmpty {
                let request = bodyRequests.removeFirst()
                current = try await serve(request, session, current: current)
                continue
            }
            if !syncQueue.isEmpty {
                let request = syncQueue.removeFirst()
                try await runSync(request, session, current: &current)
                continue
            }
            if case .online = state {} else { setState(.online(since: Date())) }
            await waitForWork()
            if reconnectRequested { reconnectRequested = false; throw MoteurError.offline }
        }
    }

    /// Rend le dossier sélectionné après la commande (`nil` si on ne sait plus).
    private func serve(_ request: BodyRequest, _ session: IMAPSession, current: String?) async throws -> String? {
        var selected = current
        do {
            if selected != request.folderPath {
                selected = nil
                _ = try await session.examine(request.folderPath)
                selected = request.folderPath
            }
            request.continuation.resume(returning: try await session.fetchMessage(uid: request.uid))
            return selected
        } catch let error as MoteurError {
            request.continuation.resume(throwing: error)
            switch error {
            case .commandFailed, .messageTooLarge, .protocolViolation: return selected  // refus ponctuel : la connexion reste bonne
            default: throw error
            }
        } catch {
            request.continuation.resume(throwing: error)
            throw error
        }
    }

    private func runSync(_ request: SyncRequest, _ session: IMAPSession, current: inout String?) async throws {
        var targets: [(path: String, role: String?)] = []
        if let path = request.path {
            targets = [(path, nil)]
        } else if let role = request.role {
            if let path = folderPaths[role] { targets = [(path, role.rawValue)] }
        } else {
            targets = FolderRole.syncOrder.compactMap { role in folderPaths[role].map { ($0, role.rawValue) } }
            let main = Set(targets.map(\.path))
            targets += openedPaths.subtracting(main).sorted().map { ($0, nil) }
        }
        let engine = SyncEngine(store: store, batchSize: 1000)
        for target in targets {
            let path = target.path
            setState(.syncing(folder: path, fetched: 0))
            current = path
            do {
                _ = try await engine.syncFolder(
                    session: session, accountID: accountID, path: path, role: target.role, reconcile: request.reconcile,
                    progress: { [weak self] fetched in Task { await self?.reportProgress(path, fetched) } },
                    between: { [self] s, p in try await self.serveBodies(s, whileSyncing: p) })
            } catch MoteurError.commandFailed where target.role == nil {
                // Dossier ouvert puis supprimé ou refusé par le serveur : on l'oublie, la connexion reste bonne.
                openedPaths.remove(path)
                current = nil
            }
        }
        if syncQueue.isEmpty, bodyRequests.isEmpty { setState(.online(since: Date())) }
    }

    private func reportProgress(_ path: String, _ fetched: Int) {
        if case .syncing = state { setState(.syncing(folder: path, fetched: fetched)) }
    }

    /// Entre deux fenêtres de synchro : ouvre les messages demandés, puis remet la connexion sur le dossier en cours de synchro.
    private func serveBodies(_ session: IMAPSession, whileSyncing path: String) async throws {
        var selected: String? = path
        var served = false
        while !bodyRequests.isEmpty {
            let request = bodyRequests.removeFirst()
            selected = try await serve(request, session, current: selected)
            served = true
        }
        if served, selected != path { _ = try await session.examine(path) }
    }

    // MARK: Connexion IDLE (Réception)

    private func idleLoop() async {
        var backoff: Double = 2
        while !Task.isCancelled {
            guard let password = password() else { await waitForCredentials(); continue }
            guard let inbox = await waitForInboxPath() else { continue }
            do {
                try await IMAPSession.withSession(endpoint: config.endpoint) { session in
                    try await session.login(username: config.username, password: password)
                    _ = try await session.examine(inbox)
                    backoff = 2
                    while true {
                        try Task.checkCancellation()
                        switch try await session.idle(timeout: self.idleRenewal) {
                        case .newMessages: self.queueSync(role: .inbox, reconcile: false)
                        case .changed: self.queueSync(role: .inbox, reconcile: true)
                        case .timedOut: break
                        }
                    }
                }
            } catch {
                if Task.isCancelled || error is CancellationError { break }
                if case MoteurError.authenticationFailed = error { await waitForCredentials(); continue }
                // La connexion IDLE est tombée : le serveur est sans doute injoignable. On force aussi la reconnexion de la connexion de travail.
                reconnectRequested = true
                signalWork()
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 300)
            }
        }
    }

    private func waitForInboxPath() async -> String? {
        while !Task.isCancelled {
            if let path = folderPaths[.inbox] { return path }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return nil
    }

    private func timerLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: fullSyncInterval)
            if Task.isCancelled { break }
            if case .online = state { queueSync(role: nil, reconcile: true) }
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? MoteurError { return e.description }
        return String(describing: error)
    }
}
