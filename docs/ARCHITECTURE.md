# ARCHITECTURE — MAiLS (Swift 6 / macOS 15+)

**VALIDÉE par Stéphan le 14/11/2026** (propositions ci-dessous, avec les cinq décisions du § 0). L'ancienne version (stack, tables) est dans `docs/archive/ARCHITECTURE_v0.md`. Ce qui est déjà éprouvé figure dans `docs/MOTEUR_IMAP_RESULTATS.md` (moteur IMAP + base + FTS5, essayé sur Dovecot) ; son code est dans `MAiLSCore`.

## 0. Décisions de Stéphan (14/11/2026)
1. **Un seul compte : iCloud** (mot de passe d'application). Gmail est redirigé vers iCloud : tout arrive dans la boîte iCloud. Donc **pas d'OAuth2, pas de Gmail dans la V0** ; la structure reste multi-comptes mais un seul est exposé.
2. **V0 = lecture seule** : compte, liste, lecteur, recherche.
3. **Recherche sur les en-têtes seulement** (expéditeur, destinataires, sujet). Pas de corps indexés.
4. **Dossiers** : Réception, Envoyés, Archive, Corbeille, Brouillons synchronisés en continu. **Complété le 15/11/2026** : tous les autres dossiers iCloud (Indésirables, dossiers perso) sont listés dans la barre latérale ; un dossier se synchronise à son premier clic (`AccountSession.openFolder`), puis suit les resynchros complètes (⌘R, toutes les 10 min). Les dossiers que le serveur ne liste plus sont retirés de la base locale. **Barre latérale (15/11/2026)** : les compteurs (messages, non lus) de tous les dossiers jamais ouverts sont lus par `STATUS` par lots de 25, sans ouvrir le dossier (colonnes `status_messages`, `status_unseen` ; un dossier synchronisé garde ses compteurs locaux). Un dossier épinglé (`folders.pinned`) est un réglage local. L'état déplié de l'arbre et l'interrupteur « dossiers vides » sont des préférences (UserDefaults).
5. **Mode lecture par défaut** (texte épuré), bascule vers l'original.

## 1. Principes (dans l'ordre de tes critères)
1. **Sécurité par construction** : ce que l'appli ne peut pas faire n'est pas dans le code (V0 sans aucune commande qui modifie le serveur ; pas de JavaScript ; pas de contenu distant ; secrets seulement au Trousseau).
2. **Simplicité** : une seule base de données, pas de service, pas de démon, pas de réglage obligatoire.
3. **Légèreté** : démarrage depuis la base locale (la liste s'affiche avant tout réseau), mémoire bornée, pas de polling.
4. **Lisibilité** : mode lecture par défaut (voir § 6).

## 2. Découpage en modules (SwiftPM)
```
MAiLSCore  (bibliothèque, AUCUN import SwiftUI/AppKit)
  Mail/      HeaderParser ✔ · MIMEParser, Threading, Sanitizer HTML, anti-trackers
  IMAP/      IMAPSession, SyncEngine (IDLE : idleUntilNewMessage)   ← déjà écrit et testé
  Store/     MailStore (GRDB, migrations, FTS5) ✔ · BodyCache
  Accounts/  Account, AccountSession (acteur), KeychainService
  Outbox/    (V2) SMTPClient, file d'envoi, annulation 10 s
MAiLS      (application)
  App/       point d'entrée, fenêtres, menus, commandes clavier
  UI/        Socle.swift (généré), Brand.swift, Sidebar, List (NSTableView), Detail (WKWebView), Composer, Palette ⌘K
mails-bench (outil en ligne de commande, pas livré)  ← scripts/bench.sh
```
Règle de dépendance : `MAiLS → MAiLSCore`, jamais l'inverse. Tout ce qui est logique se teste sans interface (`swift test` sur `MAiLSCore`).

## 3. Données
Un fichier SQLite principal (WAL) dans `~/Library/Application Support/MAiLS/` :
- `accounts` (serveur, port, identifiant ; **jamais de mot de passe**), `folders` (rôle SPECIAL-USE, `uid_validity`, `uid_next`, `sync_floor`), `messages` (en-têtes décodés, drapeaux en bitmask, `thread_id`, désabonnement), `messages_fts` (FTS5 sans accents ni casse), `threads`, `attachments` (métadonnées seulement).
- V1 : `pending_ops` (actions en attente de confirmation du serveur). V2 : `outbox`. V3 : `snoozes`, `followups`.
Un **second fichier jetable** `bodies.db` : cache des corps déjà ouverts (plafond de taille, plus anciens retirés). On peut le supprimer sans rien perdre.
Les corps ne sont jamais téléchargés en masse : à l'ouverture d'un message, `BODY.PEEK[]` borné (64 Mo max).

## 4. Flux principaux
- **Démarrage** : ouvre la base → affiche la liste (aucun réseau) → synchronise en arrière-plan.
- **Synchro** (éprouvée) : récents d'abord, par fenêtres de 1 000, reprenable (`sync_floor`), incrémentale (`uid_next`), `UIDVALIDITY` géré, drapeaux et suppressions réconciliés. À ajouter : CONDSTORE/QRESYNC quand le serveur les annonce (supprime la passe complète sur les drapeaux), IDLE sur INBOX avec renouvellement avant 29 min, reconnexion avec attente croissante.
- **Lecture d'un message** : cache → sinon téléchargement → MIME → nettoyage → affichage (§ 6). N'altère jamais l'état sur le serveur (`BODY.PEEK`, pas de `\Seen` implicite : le « lu » est une action explicite et locale d'abord).
- **Actions (V1)** : mise à jour **locale immédiate**, enregistrée dans `pending_ops`, rejouée vers le serveur (`UID STORE`, `UID MOVE`), annulable tant que non confirmée ; en cas de refus, retour arrière visible.
- **Envoi (V2)** : message écrit dans `outbox`, délai d'annulation de 10 s, puis SMTP ; une copie en « Envoyés » ; jamais d'envoi sans trace locale.
- **Recherche** : FTS5 locale (`from:`, `to:`, `has:attachment`, `is:unread`) ; la saisie est neutralisée (aucune syntaxe FTS5 ne peut la faire échouer).
- **Erreurs** : chaque compte a un état visible (connecté, hors ligne, mot de passe refusé). Aucune erreur n'est avalée en silence.

## 5. Concurrence (Swift 6 strict)
Un acteur `AccountSession` par compte : il possède ses connexions IMAP (une pour IDLE sur INBOX, une pour le travail). `MailStore` est `Sendable` (pool GRDB). L'interface lit la base par observation (`ValueObservation`) : pas de polling, pas de copie des 100 000 lignes en mémoire ; la liste `NSTableView` charge par pages (identifiants + lignes à la demande), cible 120 Hz.

## 6. Affichage des messages et sécurité
- **Mode lecture par défaut** : texte épuré, 15 px, sans mise en page de l'expéditeur ; bascule « fidèle » (HTML d'origine) sur demande.
- `WKWebView` **sans JavaScript** (`allowsContentJavaScript = false`), contenu distant bloqué (images, feuilles de style, polices), pixels 1×1 et liens de suivi filtrés, schéma `cid:` seulement pour les images jointes.
- Liens : l'adresse réelle est montrée avant d'ouvrir ; texte et adresse qui divergent → avertissement ; ouverture dans le navigateur par défaut.
- Pièces jointes : jamais ouvertes automatiquement ; enregistrement par `NSSavePanel`, quarantaine macOS conservée.
- TLS obligatoire (sauf boucle locale pour les essais) ; aucun mot de passe en clair hors du Trousseau ; aucun contenu de message dans les journaux.
- Application **sandboxée** + runtime renforcé (droits : client réseau, Trousseau, fichiers choisis par l'utilisateur).
- Mise à jour automatique, signature et notarisation : selon tes règles habituelles (modèle `mBACKUP/Updater.swift`).

## 7. Budgets mesurés / visés
| Mesure | Acquis (Dovecot, 100 000 messages) | Cible app |
|---|---|---|
| Synchro initiale (cache serveur chaud) | 6,9 s | ≤ 10 s |
| Mémoire | 48–52 Mo | ≤ 100 Mo hors webview |
| Page de 100 messages | 0,15 ms | < 1 ms |
| Recherche | 3–11 ms | < 20 ms |
| Lancement → liste affichée | non mesuré | < 300 ms |

## 8. Versions
- **V0 — lecture seule** : comptes (Trousseau), synchro, liste, lecteur, recherche. Utilisée une semaine à côté d'Apple Mail avant d'aller plus loin.
- **V1 — actions** : lu/non lu, archiver, corbeille, drapeau (file `pending_ops`).
- **V2 — envoi** : rédaction, SMTP, annulation 10 s, signature.
- **V3 — productivité** : palette ⌘K, snooze, rappels de suivi, désabonnement en un clic (RFC 8058), nettoyage par expéditeur.

## 9. Décisions prises par défaut (à contester)
Deux modules `MAiLSCore` / `MAiLS` ; pas d'`IMAPClient` maison au-dessus de swift-nio-imap (on réutilise `IMAPCommands` 0.5.0, épinglé) ; chaînage des fils par `References`/`In-Reply-To` en local (identique pour tous les serveurs) ; corps en cache jetable séparé ; sandbox activée.

## 10. Risques ouverts
iCloud et Gmail réels (limites de débit, libellés Gmail, mot de passe d'application) ; swift-nio-imap reste en 0.x ; OAuth2 Gmail (inscription d'une application Google) si le mot de passe d'application ne suffit pas ; `NSTableView` à 100 000 lignes à mesurer en vrai ; couleur du logo à fixer.
