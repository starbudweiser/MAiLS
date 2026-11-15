import Foundation

/// Un compte de messagerie IMAP. Le mot de passe n'en fait JAMAIS partie : il vit dans le Trousseau (`SecretStore`).
public struct AccountConfig: Sendable, Equatable, Codable {
    public var id: Int64?
    public var label: String
    public var host: String
    public var port: UInt16
    public var useTLS: Bool
    public var username: String

    public init(id: Int64? = nil, label: String, host: String, port: UInt16, useTLS: Bool, username: String) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.username = username
    }

    public var endpoint: ServerEndpoint { ServerEndpoint(host: host, port: port, useTLS: useTLS) }

    /// Clé du mot de passe dans le Trousseau.
    public var secretKey: String { "\(username)@\(host):\(port)" }

    /// iCloud Mail : mot de passe d'application obligatoire (Réglages Apple ID).
    public static func icloud(username: String) -> AccountConfig {
        AccountConfig(label: "iCloud", host: "imap.mail.me.com", port: 993, useTLS: true, username: username.trimmingCharacters(in: .whitespaces))
    }
}
