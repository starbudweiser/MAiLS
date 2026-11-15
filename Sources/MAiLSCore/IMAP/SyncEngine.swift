import Foundation

public struct SyncReport: Sendable, Equatable {
    public var folder: String
    public var serverMessages: Int
    public var newMessages: Int
    public var flagsUpdated: Int
    public var removed: Int
    public var batches: Int
    public var wipedForUIDValidity: Bool
    public var duration: Duration
}

/// Synchronise un dossier IMAP vers la base locale, en lecture seule.
///
/// Principes :
/// - **Les plus récents d'abord** : la synchro initiale descend du dernier UID vers le premier, par fenêtres,
///   pour que la liste soit utilisable après la première fenêtre.
/// - **Reprenable** : `sync_floor` (plus petit UID dont tout ce qui est au-dessus est reçu) est écrit après
///   chaque fenêtre ; une coupure ne fait rien perdre ni recommencer.
/// - **Incrémentale** : ensuite, seuls les UID ≥ `uid_next` mémorisé sont téléchargés ; les drapeaux et les
///   suppressions se resynchronisent en une passe légère (`UID FETCH 1:* (UID FLAGS)`).
/// - **UIDVALIDITY** modifié : les UID locaux sont périmés, le dossier est vidé puis resynchronisé.
public struct SyncEngine: Sendable {
    public let store: MailStore
    public var batchSize: UInt32

    public init(store: MailStore, batchSize: UInt32 = 1000) {
        self.store = store
        self.batchSize = max(1, batchSize)
    }

    public func syncFolder(
        session: IMAPSession,
        accountID: Int64,
        path: String,
        role: String? = nil,
        reconcile: Bool = true,
        progress: (@Sendable (_ fetched: Int) -> Void)? = nil,
        between: (@Sendable (IMAPSession, String) async throws -> Void)? = nil
    ) async throws -> SyncReport {
        let clock = ContinuousClock()
        let start = clock.now

        let status = try await session.examine(path)
        var folder = try await store.ensureFolder(accountID: accountID, path: path, role: role)
        var wiped = false

        if let known = folder.uidValidity, known != status.uidValidity {
            try await store.wipeFolderMessages(folderID: folder.id)
            folder.uidNext = nil
            folder.syncFloor = nil
            wiped = true
        }

        let now = Int64(Date().timeIntervalSince1970)
        var newMessages = 0
        var batches = 0

        // Fenêtres à récupérer, dans l'ordre : d'abord le « haut » (messages arrivés depuis), puis le « bas » (historique).
        var windows: [(range: ClosedRange<UInt32>, isTail: Bool)] = []
        let serverTop = status.uidNext &- 1  // plus grand UID possible aujourd'hui

        if let localNext = folder.uidNext {
            // Synchro déjà commencée : nouveaux messages au-dessus de ce qu'on connaît.
            if localNext <= serverTop { windows += Self.ascendingWindows(localNext...serverTop, size: batchSize).map { ($0, true) } }
            // Historique restant à descendre (si la synchro initiale a été interrompue).
            if let floor = folder.syncFloor, floor > 1 {
                windows += Self.descendingWindows(1...(floor - 1), size: batchSize).map { ($0, false) }
            }
        } else if serverTop >= 1 {
            // Première synchro : tout, du plus récent au plus ancien.
            windows += Self.descendingWindows(1...serverTop, size: batchSize).map { ($0, false) }
            // Marqueur de départ : « tout ce qui est ≥ uidNext est synchronisé » (vrai : il n'y a rien).
            try await store.setFolderState(
                folderID: folder.id, uidValidity: status.uidValidity, uidNext: status.uidNext,
                syncFloor: status.uidNext, now: now)
            folder.uidNext = status.uidNext
            folder.syncFloor = status.uidNext
        }

        // Écriture en base de la fenêtre k pendant le téléchargement de la fenêtre k+1.
        var pendingWrite: Task<Int, Error>?
        var floor = folder.syncFloor ?? status.uidNext
        var uidNextToStore = folder.uidNext ?? status.uidNext
        let folderID = folder.id
        let store = self.store

        for window in windows {
            let raws = try await session.fetchHeaders(uids: window.range)
            batches += 1
            if let pendingWrite { newMessages += try await pendingWrite.value }

            if window.isTail { uidNextToStore = max(uidNextToStore, window.range.upperBound &+ 1) }
            else { floor = min(floor, window.range.lowerBound) }
            let floorNow = floor
            let nextNow = uidNextToStore
            let validity = status.uidValidity
            pendingWrite = Task {
                let stored = raws.map { raw in
                    StoredMessage(
                        uid: raw.uid, flags: raw.flags, internalAt: raw.internalAt, size: raw.size,
                        headers: HeaderParser.parse(raw.headerBytes))
                }
                try await store.upsert(stored, folderID: folderID)
                try await store.setFolderState(
                    folderID: folderID, uidValidity: validity, uidNext: nextNow, syncFloor: floorNow, now: now)
                return stored.count
            }
            progress?(newMessages)
            // Entre deux fenêtres, la connexion peut servir à autre chose (ouvrir un message demandé par l'utilisateur).
            try await between?(session, path)
        }
        if let pendingWrite { newMessages += try await pendingWrite.value }

        // Tout est arrivé : on aligne uid_next sur le serveur (messages absents = UID jamais attribués).
        let finalFloor: UInt32 = serverTop == 0 ? 1 : floor
        try await store.setFolderState(
            folderID: folderID, uidValidity: status.uidValidity, uidNext: status.uidNext, syncFloor: finalFloor, now: now)

        // Drapeaux et suppressions (dossier complet seulement).
        var updated = 0
        var removed = 0
        if floor <= 1, reconcile {
            let serverFlags = try await session.fetchAllFlags()
            (updated, removed) = try await store.reconcile(folderID: folderID, serverFlags: serverFlags)
        }

        return SyncReport(
            folder: path, serverMessages: status.exists, newMessages: newMessages, flagsUpdated: updated,
            removed: removed, batches: batches, wipedForUIDValidity: wiped, duration: clock.now - start)
    }

    static func descendingWindows(_ range: ClosedRange<UInt32>, size: UInt32) -> [ClosedRange<UInt32>] {
        var result: [ClosedRange<UInt32>] = []
        var high = range.upperBound
        while high >= range.lowerBound {
            let low = high >= range.lowerBound &+ (size - 1) ? high - (size - 1) : range.lowerBound
            result.append(max(low, range.lowerBound)...high)
            if low <= range.lowerBound { break }
            high = low - 1
        }
        return result
    }

    static func ascendingWindows(_ range: ClosedRange<UInt32>, size: UInt32) -> [ClosedRange<UInt32>] {
        var result: [ClosedRange<UInt32>] = []
        var low = range.lowerBound
        while low <= range.upperBound {
            let high = range.upperBound - low >= size - 1 ? low + (size - 1) : range.upperBound
            result.append(low...high)
            if high == range.upperBound { break }
            low = high + 1
        }
        return result
    }
}
