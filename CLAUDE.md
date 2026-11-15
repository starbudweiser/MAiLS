# CLAUDE.md — Instructions d'architecture et de développement pour MAiLS

Tu es un ingénieur logiciel senior macOS (Swift 6, SwiftUI, AppKit, GRDB, SwiftNIO).
Ce dépôt contient les spécifications et la base du projet **MAiLS**, un client de messagerie natif macOS ultra-rapide, 100 % Flat et orienté productivité clavier.

## 1. Documentation de référence obligatoire
Avant d'écrire la moindre ligne de code, lis et applique strictement :
- `docs/PRD.md` : Périmètre fonctionnel, raccourcis clavier, fonctionnalités avancées (Snooze, Follow-up, Anti-tracker, Désabonnement 1 clic, Palette `Cmd+K`).
- `docs/DESIGN_SYSTEM.md` : MAiLS suit **Socle** (décision du 14/11/2026) : règles, traduction pour un client mail, points à décider. Ancien thème AppTheme archivé dans `docs/archive/`.
- `docs/MOTEUR_IMAP_RESULTATS.md` : moteur IMAP/FTS5 déjà essayé (lecture seule, sur Dovecot) ; son code est dans `Sources/MAiLSCore/` (modules `Mail`, `IMAP`, `Store`).
- `docs/ARCHITECTURE.md` : Schéma SQLite/GRDB + FTS5, moteurs IMAP/SMTP, sécurité Keychain et structure des dossiers.

## 2. Règles strictes d'implémentation
1. **Esthétique 100 % Flat :**
   - **INTERDICTION ABSOLUE** d'utiliser `.ultraThinMaterial`, `.regularMaterial`, `NSVisualEffectView`, `VisualEffectBlur`, des ombres portées (`.shadow(...)`) ou des dégradés (`LinearGradient`).
   - Toutes les couleurs, polices et dimensions doivent provenir exclusivement de `Sources/MAiLS/UI/Socle.swift` (`Socle.C`, `Socle.M`, `Socle.T`, `SocleButtonStyle`, `.socleField()`), fichier **généré** : ne jamais le modifier à la main (voir `docs/DESIGN_SYSTEM.md`). Aucune valeur hexadécimale ou taille en dur dans les vues.
   - Le nom de l'appli s'écrit « MAiLS » avec le « i » dans la couleur du logo (`Text(branded:)`), sauf dans les menus déroulants, titres de fenêtre et notifications système (texte normal).
2. **Performance & Concurrence (Swift 6) :**
   - Respecter la concurrence stricte Swift 6 (`Sendable`, acteurs isolés pour le réseau et la base de données).
   - La liste centrale des e-mails doit utiliser un wrapper AppKit `NSTableView` (`NSViewRepresentable`) pour garantir un défilement à 120 Hz sur plus de 100 000 messages.
   - Le rendu des e-mails HTML utilise `WKWebView` avec JavaScript désactivé (`allowsContentJavaScript = false`) et filtrage des pixels de suivi `1x1`.
3. **Qualité & Fiabilité :**
   - Stockage exclusif des mots de passe et jetons dans le trousseau macOS (`Security.framework`), jamais dans `UserDefaults` ni SQLite.
   - Écriture atomique et gestion explicite des erreurs réseau/IMAP/SMTP (jamais de `try!` ni de force unwrap `!` en production).
   - Écrire des tests unitaires (`swift test`) pour les parsers MIME/IMAP, les requêtes FTS5 GRDB et le moteur de règles anti-tracker.

## 3. État et suite (architecture validée le 14/11/2026, voir `docs/ARCHITECTURE.md`)
Paquet : `MAiLSCore` (logique, sans interface) ← `MAiLS` (application) ; `mails-bench` (outil d'essai) ; tests dans `Tests/MAiLSCoreTests` (88 tests ; ceux de Dovecot : `Fixtures/dovecot/start_dovecot.sh start` puis `MOTEUR_DOVECOT_PORT=14500 swift test`).
**V0 (lecture seule, un compte iCloud) construite le 14/11/2026, essayée sur Dovecot** : Trousseau, synchro continue des 5 dossiers principaux avec IDLE et reconnexion (les autres dossiers iCloud sont listés et synchronisés au premier clic, 15/11/2026), MIME, mode lecture, original nettoyé (WebKit sans JavaScript ni contenu distant), liste `NSTableView` paginée, recherche (`from:`, `to:`, `is:unread`), 4 langues. **Validée sur le vrai compte iCloud de Stéphan le 15/11/2026** (88 tests au départ, 94 avec les dossiers supplémentaires).
Construire et installer : `scripts/build_app.sh dev` (build/MAiLS Dev.app, identifiant `fr.stephan.mails.dev`, données à part) puis `scripts/build_app.sh local` (~/Applications/Applications Personnelles/MAiLS.app). Ne lance rien. Essais automatiques : `open -g -n "build/MAiLS Dev.app" --env MAILS_DEV_ACCOUNT=127.0.0.1:14500:test:test` (version dev seulement, boucle locale seulement) avec Dovecot démarré, puis pilotage en arrière-plan (computer-use, `app_*`).
**v0.1.0 notarisée et publiée le 15/11/2026** : dépôt privé `starbudweiser/MAiLS` (branche `main`), `./release.sh` (compile la version locale, notarise une copie avec le bac à sable conservé, release GitHub), README avec section « About ». **Icône et couleur du logo faites le 15/11/2026** (concept A, orange #FF6B2B ; `assets/MAiLS.icns`, prise par `build_app.sh`) : elle n'est pas dans la v0.1.0, seulement dans la prochaine. Reste avant une vraie diffusion : mise à jour automatique (modèle `mBACKUP/Updater.swift`), alertes centrées sur la fenêtre (`runCenteredOnAppWindow`).
Hors V0 : actions (V1), envoi SMTP (V2), palette ⌘K, snooze, suivi, désabonnement (V3).
