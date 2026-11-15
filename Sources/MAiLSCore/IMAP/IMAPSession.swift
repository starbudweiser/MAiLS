import Foundation
import IMAPCommands
import NIOCore
import NIOIMAP

public struct ServerEndpoint: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var useTLS: Bool

    public init(host: String, port: UInt16, useTLS: Bool) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
    }

    /// Seules les boucles locales peuvent se passer de TLS (essais). Un mot de passe ne part jamais en clair
    /// vers une autre machine : c'est refusé par construction dans `IMAPSession.login`.
    var isLoopback: Bool { ["localhost", "127.0.0.1", "::1"].contains(host) }
}

public enum MoteurError: Error, Equatable, CustomStringConvertible {
    case plaintextLoginRefused(host: String)
    case authenticationFailed(String)
    case commandFailed(String)
    case protocolViolation(String)
    case messageTooLarge(limit: Int)
    case offline
    case timedOut

    public var description: String {
        switch self {
        case .plaintextLoginRefused(let host): "Connexion sans TLS refusée vers \(host) : le mot de passe ne part pas en clair."
        case .authenticationFailed(let t): "Authentification refusée : \(t)"
        case .commandFailed(let t): "Commande refusée par le serveur : \(t)"
        case .protocolViolation(let t): "Réponse inattendue du serveur : \(t)"
        case .messageTooLarge(let limit): "Message plus grand que la limite de \(limit) octets."
        case .offline: "Pas de connexion au serveur."
        case .timedOut: "Le serveur n'a pas répondu à temps."
        }
    }
}

public struct MailboxStatus: Sendable, Equatable {
    public var exists: Int
    public var uidNext: UInt32
    public var uidValidity: UInt32
}

public struct FolderListing: Sendable, Equatable {
    /// Nom tel qu'envoyé par le serveur (UTF-7 modifié pour les accents).
    public var path: String
    /// `sent`, `trash`, `archive`, `drafts`, `junk` d'après les attributs SPECIAL-USE, sinon `nil`.
    public var role: String?
    public var selectable: Bool
}

/// Un message tel que reçu : en-têtes bruts, pas encore analysés.
public struct RawHeaderMessage: Sendable {
    public var uid: UInt32
    public var flags: MessageFlags
    public var internalAt: Int64
    public var size: Int
    public var headerBytes: [UInt8]
}

/// Une session IMAP ouverte (un compte, une connexion). Lecture seule par conception : les dossiers
/// s'ouvrent en `EXAMINE`, et cette version n'expose aucune commande qui modifie le serveur.
public struct IMAPSession: Sendable {
    let connection: IMAPConnection
    let endpoint: ServerEndpoint

    // MARK: Ouverture

    /// Ouvre une connexion, exécute `body`, referme.
    nonisolated(nonsending) public static func withSession<Result>(
        endpoint: ServerEndpoint,
        _ body: nonisolated(nonsending) (IMAPSession) async throws -> Result
    ) async throws -> Result {
        let configuration = IMAPConnection.Configuration(
            hostname: endpoint.host, port: endpoint.port, useTLS: endpoint.useTLS, logging: .noLogging)
        return try await IMAPConnection.withConnection(configuration: configuration) { _, connection in
            try await body(IMAPSession(connection: connection, endpoint: endpoint))
        }
    }

    public func login(username: String, password: String) async throws {
        guard endpoint.useTLS || endpoint.isLoopback else {
            throw MoteurError.plaintextLoginRefused(host: endpoint.host)
        }
        let tagged = try await connection.send(.login(username: username, password: password)) { _, responses in
            try await responses.waitForCompletion()
        }
        do { _ = try tagged.getOK() } catch { throw MoteurError.authenticationFailed("\(tagged.state)") }
    }

    // MARK: Dossiers

    public func listFolders() async throws -> [FolderListing] {
        try await connection.send(.list(nil, reference: MailboxName([]), .mailbox(ByteBuffer(string: "*")), [])) { _, responses in
            var folders: [FolderListing] = []
            for try await response in responses {
                switch response {
                case .untagged(.mailboxData(.list(let info))):
                    let path = String(decoding: info.path.name.bytes, as: UTF8.self)
                    let attrs = info.attributes
                    let selectable = !attrs.contains(.noSelect) && !attrs.contains(.nonExistent)
                    let role: String? =
                        attrs.contains(Self.sentAttribute) ? "sent"
                        : attrs.contains(Self.trashAttribute) ? "trash"
                        : attrs.contains(Self.archiveAttribute) ? "archive"
                        : attrs.contains(Self.draftsAttribute) ? "drafts"
                        : attrs.contains(Self.junkAttribute) ? "junk"
                        : nil
                    folders.append(FolderListing(path: path, role: role, selectable: selectable))
                case .tagged(let tagged):
                    try tagged.checkOK()
                default:
                    break
                }
            }
            return folders
        }
    }

    /// Ouvre un dossier **en lecture seule** (`EXAMINE`).
    public func examine(_ path: String) async throws -> MailboxStatus {
        let name = MailboxName(Array(path.utf8))
        return try await connection.send(.examine(name)) { _, responses in
            var exists: Int?
            var uidNext: UID?
            var uidValidity: UIDValidity?
            for try await response in responses {
                switch response {
                case .untagged(.mailboxData(.exists(let n))):
                    exists = n
                case .untagged(.conditionalState(.ok(let text))):
                    switch text.code {
                    case .uidNext(let u): uidNext = u
                    case .uidValidity(let v): uidValidity = v
                    default: break
                    }
                case .tagged(let tagged):
                    do { _ = try tagged.getOK() } catch { throw MoteurError.commandFailed("EXAMINE \(path) : \(tagged.state)") }
                default:
                    break
                }
            }
            guard let exists else { throw MoteurError.protocolViolation("EXAMINE sans EXISTS") }
            guard let uidNext else { throw MoteurError.protocolViolation("EXAMINE sans UIDNEXT") }
            guard let uidValidity else { throw MoteurError.protocolViolation("EXAMINE sans UIDVALIDITY") }
            return MailboxStatus(exists: exists, uidNext: uidNext.rawValue, uidValidity: UInt32(uidValidity))
        }
    }

    // MARK: Lecture des en-têtes

    /// `UID FETCH lo:hi (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (…)])`.
    public func fetchHeaders(uids: ClosedRange<UInt32>) async throws -> [RawHeaderMessage] {
        let set = LastCommandSet<UID>.range(
            MessageIdentifierRange(UID(rawValue: uids.lowerBound)...UID(rawValue: uids.upperBound)))
        let attributes: [FetchAttribute] = [
            .uid, .flags, .internalDate, .rfc822Size,
            .bodySection(peek: true, .headerFields(HeaderParser.requestedFields), nil),
        ]
        return try await connection.send(.uidFetch(set, attributes, [])) { _, responses in
            var messages: [RawHeaderMessage] = []
            messages.reserveCapacity(uids.count / 2)
            var current = PartialMessage()
            for try await response in responses {
                switch response {
                case .fetch(let fetch):
                    switch fetch {
                    case .start:
                        current = PartialMessage()
                    case .startUID(let uid):
                        current = PartialMessage()
                        current.uid = uid.rawValue
                    case .simpleAttribute(let attribute):
                        current.apply(attribute)
                    case .streamingBegin(_, let byteCount):
                        current.header.reserveCapacity(byteCount)
                    case .streamingBytes(let buffer):
                        current.header.append(contentsOf: buffer.readableBytesView)
                    case .streamingEnd:
                        break
                    case .finish:
                        if let message = current.complete() { messages.append(message) }
                        current = PartialMessage()
                    }
                case .tagged(let tagged):
                    do { _ = try tagged.getOK() } catch { throw MoteurError.commandFailed("UID FETCH : \(tagged.state)") }
                default:
                    break
                }
            }
            return messages
        }
    }

    /// Les drapeaux de **tous** les messages (une ligne par message : léger), pour resynchroniser
    /// les lus/non lus et détecter les suppressions.
    public func fetchAllFlags() async throws -> [UInt32: MessageFlags] {
        try await connection.send(.uidFetch(.range(.all), [.uid, .flags], [])) { _, responses in
            var result: [UInt32: MessageFlags] = [:]
            var uid: UInt32?
            var flags: MessageFlags = []
            for try await response in responses {
                switch response {
                case .fetch(let fetch):
                    switch fetch {
                    case .start, .startUID:
                        uid = nil
                        flags = []
                    case .simpleAttribute(.uid(let u)):
                        uid = u.rawValue
                    case .simpleAttribute(.flags(let f)):
                        flags = Self.messageFlags(from: f)
                    case .finish:
                        if let uid { result[uid] = flags }
                    default:
                        break
                    }
                case .tagged(let tagged):
                    do { _ = try tagged.getOK() } catch { throw MoteurError.commandFailed("UID FETCH FLAGS : \(tagged.state)") }
                default:
                    break
                }
            }
            return result
        }
    }

    // MARK: Corps d'un message

    /// Le message complet (`BODY.PEEK[]` : ne marque pas comme lu). Borné pour protéger la mémoire.
    public func fetchMessage(uid: UInt32, maxBytes: Int = 64 * 1024 * 1024) async throws -> [UInt8] {
        let set = LastCommandSet<UID>.range(MessageIdentifierRange(UID(rawValue: uid)...UID(rawValue: uid)))
        let attributes: [FetchAttribute] = [.uid, .bodySection(peek: true, .complete, nil)]
        return try await connection.send(.uidFetch(set, attributes, [])) { _, responses in
            var bytes: [UInt8] = []
            for try await response in responses {
                switch response {
                case .fetch(.streamingBegin(_, let byteCount)):
                    if byteCount > maxBytes { throw MoteurError.messageTooLarge(limit: maxBytes) }
                    bytes.reserveCapacity(byteCount)
                case .fetch(.streamingBytes(let buffer)):
                    if bytes.count + buffer.readableBytes > maxBytes { throw MoteurError.messageTooLarge(limit: maxBytes) }
                    bytes.append(contentsOf: buffer.readableBytesView)
                case .tagged(let tagged):
                    do { _ = try tagged.getOK() } catch { throw MoteurError.commandFailed("UID FETCH BODY : \(tagged.state)") }
                default:
                    break
                }
            }
            return bytes
        }
    }

    // MARK: IDLE

    /// Attend qu'un message arrive (`IDLE`). Rend le nouveau nombre de messages dès que le serveur le signale.
    /// À réémettre au moins toutes les 29 minutes (limite habituelle des serveurs) : l'appelant boucle.
    public func idleUntilNewMessage() async throws -> Int {
        try await connection.sendIdle { _, responses in
            for try await response in responses {
                if case .untagged(.mailboxData(.exists(let n))) = response { return n }
                if case .tagged(let tagged) = response {
                    do { _ = try tagged.getOK() } catch { throw MoteurError.commandFailed("IDLE : \(tagged.state)") }
                }
            }
            throw MoteurError.protocolViolation("IDLE terminé sans notification")
        }
    }

    public enum IdleOutcome: Sendable, Equatable {
        /// Un message est arrivé (`* n EXISTS`).
        case newMessages
        /// Suppression ou changement de drapeaux signalé.
        case changed
        /// Délai écoulé sans événement : le serveur coupe IDLE vers 30 min, on le renouvelle avant.
        case timedOut
    }

    /// `IDLE` borné dans le temps. Rend dès que le serveur signale un changement, ou à l'échéance ; la connexion reste utilisable ensuite.
    public func idle(timeout: Duration) async throws -> IdleOutcome {
        let outcome = try await withThrowingTaskGroup(of: IdleOutcome?.self) { group in
            group.addTask { try await self.idleWaitForEvent() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            // Attendre la fin de l'autre branche : l'annulation fait terminer IDLE proprement (DONE envoyé).
            while true {
                do { if try await group.next() == nil { break } } catch { continue }
            }
            return first ?? .timedOut
        }
        // `sendIdle` rend la main dès que `DONE` est écrit, avant la réponse du serveur. Un `NOOP` termine proprement l'échange : quand il
        // revient, l'IDLE précédent est complètement fini et la connexion peut servir (swift-nio-imap exige une seule commande active
        // pour démarrer un nouvel IDLE).
        let tagged = try await connection.send(.noop) { _, responses in try await responses.waitForCompletion() }
        do { _ = try tagged.getOK() } catch { throw MoteurError.commandFailed("NOOP après IDLE : \(tagged.state)") }
        return outcome
    }

    private func idleWaitForEvent() async throws -> IdleOutcome? {
        try await connection.sendIdle { _, responses in
            for try await response in responses {
                switch response {
                case .untagged(.mailboxData(.exists)): return IdleOutcome.newMessages
                case .untagged(.messageData), .fetch: return IdleOutcome.changed
                case .tagged(let tagged):
                    do { _ = try tagged.getOK() } catch { throw MoteurError.commandFailed("IDLE : \(tagged.state)") }
                default: break
                }
            }
            return nil  // flux terminé : annulation demandée
        }
    }

    // MARK: Aides

    private static let sentAttribute: MailboxInfo.Attribute = #"\Sent"#
    private static let trashAttribute: MailboxInfo.Attribute = #"\Trash"#
    private static let archiveAttribute: MailboxInfo.Attribute = #"\Archive"#
    private static let draftsAttribute: MailboxInfo.Attribute = #"\Drafts"#
    private static let junkAttribute: MailboxInfo.Attribute = #"\Junk"#

    static func messageFlags(from flags: [Flag]) -> MessageFlags {
        var result: MessageFlags = []
        for flag in flags {
            if flag == .seen { result.insert(.seen) }
            else if flag == .answered { result.insert(.answered) }
            else if flag == .flagged { result.insert(.flagged) }
            else if flag == .deleted { result.insert(.deleted) }
            else if flag == .draft { result.insert(.draft) }
        }
        return result
    }
}

private struct PartialMessage {
    var uid: UInt32?
    var flags: MessageFlags = []
    var internalAt: Int64?
    var size: Int?
    var header: [UInt8] = []

    mutating func apply(_ attribute: MessageAttribute) {
        switch attribute {
        case .uid(let u): uid = u.rawValue
        case .flags(let f): flags = IMAPSession.messageFlags(from: f)
        case .rfc822Size(let s): size = s
        case .internalDate(let date):
            let c = date.components
            internalAt = HeaderParser.epoch(
                year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute, second: c.second,
                zoneMinutes: c.zoneMinutes)
        default: break
        }
    }

    func complete() -> RawHeaderMessage? {
        guard let uid else { return nil }
        return RawHeaderMessage(uid: uid, flags: flags, internalAt: internalAt ?? 0, size: size ?? 0, headerBytes: header)
    }
}
