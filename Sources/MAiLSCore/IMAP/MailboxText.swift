import Foundation

/// Noms de dossiers IMAP : le serveur les écrit en UTF-7 modifié (RFC 3501 § 5.1.3), « Été » devient « &AMk-t&AOk- ».
/// On garde le nom brut pour parler au serveur ; ce décodage ne sert qu'à l'affichage.
public enum MailboxText {
    public static func decode(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        var out = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            guard raw[i] == "&" else {
                out.append(raw[i])
                i = raw.index(after: i)
                continue
            }
            // Séquence « &…- » : « &- » est une esperluette, le reste est du UTF-16 en base 64 (« , » à la place de « / »).
            guard let end = raw[i...].firstIndex(of: "-") else {
                out.append(contentsOf: raw[i...])
                break
            }
            let body = String(raw[raw.index(after: i)..<end])
            if body.isEmpty {
                out.append("&")
            } else if let text = utf16(fromBase64: body) {
                out.append(text)
            } else {
                out.append(contentsOf: raw[i...end])  // séquence invalide : laissée telle quelle
            }
            i = raw.index(after: end)
        }
        return out
    }

    private static func utf16(fromBase64 body: String) -> String? {
        var base64 = body.replacingOccurrences(of: ",", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), !data.isEmpty, data.count % 2 == 0 else { return nil }
        let bytes = [UInt8](data)
        let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        return String(decoding: units, as: UTF16.self)
    }
}
