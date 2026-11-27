import Foundation

/// Logique pure de la mise à jour : lecture d'une release GitHub et comparaison des versions. Sans réseau, testable seule.
public struct ReleaseInfo: Sendable, Equatable {
    public var version: String
    public var assetURL: URL

    /// Lit la réponse de `/releases/latest` : version (étiquette sans « v ») et premier fichier .zip joint.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let s = zip["browser_download_url"] as? String, let url = URL(string: s),
              url.scheme == "https", url.host == "github.com" else { return nil }
        return ReleaseInfo(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), assetURL: url)
    }

    /// Vrai si `candidate` est strictement plus récente que `current` (« 0.1.10 » > « 0.1.9 » ; segments manquants = 0).
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
