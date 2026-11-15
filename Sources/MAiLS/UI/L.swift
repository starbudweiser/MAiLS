import Foundation

/// Texte localisé (fr, en, es, it ; anglais si la langue du système n'en fait pas partie). Aucun texte visible n'est écrit en dur dans les vues.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}
