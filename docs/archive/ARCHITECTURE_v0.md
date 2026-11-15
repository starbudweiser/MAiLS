# ARCHITECTURE TECHNIQUE — MAiLS (SWIFT 6 / MACOS)

## 1. Stack
- **UI :** SwiftUI + AppKit (`NSTableView` pour la liste, `WKWebView` sans JS pour le rendu HTML).
- **Base de données :** SQLite via `GRDB.swift` + table virtuelle `FTS5` (`messages_fts`).
- **Réseau :** `SwiftNIO` (`swift-nio-imap`) pour IMAP/IDLE et `Network.framework` / `SwiftNIO` pour SMTP TLS.
- **Sécurité :** Trousseau macOS (`Security.framework`).

## 2. Tables SQLite principales
- `accounts`, `folders`, `threads`, `messages`, `attachments`, `messages_fts` (FTS5 synchronisé par triggers).
