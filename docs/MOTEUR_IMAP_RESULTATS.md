# Essai du moteur IMAP de MAiLS — résultats (14/11/2026)

Expérience **sans interface**, séparée du paquet principal (aucun fichier de MAiLS modifié).
Lancer : `swift test` (42 tests) puis `./bench.sh` (100 000 messages, une minute).

## Ce qui existe
- `HeaderParser` : en-têtes RFC 5322, mots codés RFC 2047 (B/Q, UTF-8, Latin-1, 2022-JP…), adresses, dates, List-Unsubscribe.
- `MailStore` : SQLite (GRDB, WAL) + FTS5 sans accents ni casse ; aucun mot de passe en base.
- `IMAPSession` : client sur swift-nio-imap 0.5.0 (`IMAPCommands`), **lecture seule** (`EXAMINE` uniquement), IDLE, corps borné.
- `SyncEngine` : récents d'abord, reprenable, incrémental, UIDVALIDITY, drapeaux et suppressions.

## Mesures (serveur local de test, build release, 100 000 messages en-têtes seuls)
| Mesure | Résultat |
|---|---|
| Synchro initiale | 5,8 s (≈ 17 000 messages/s) |
| Base sur disque | 39 Mo |
| Mémoire max du processus | 52 Mo |
| 100 plus récents (liste) | 0,15 ms |
| Recherche plein texte (50 résultats) | 2,7 à 8 ms |
| Resynchro sans changement | 1,5 s (passe « drapeaux » sur 100 000) |
| +50 messages, 1 lu, 1 supprimé | 1,5 s dont 1 seule fenêtre téléchargée |
| Corps d'un message | 5 ms |
| Réveil IDLE | ≈ 5 ms après l'arrivée |

## Essai sur un vrai Dovecot 2.4.5 (14/11/2026, Homebrew, instance locale sans root)
`Fixtures/dovecot/start_dovecot.sh start`, Maildir de 100 000 messages (`Fixtures/make_maildir.py`), mêmes données que le faux serveur.
| Mesure | Résultat |
|---|---|
| **Fidélité** | base synchronisée depuis Dovecot **identique champ par champ** à celle du faux serveur (100 000 lignes, 0 écart sur sujet, expéditeur, destinataires, dates, Message-ID, références, désabonnement, taille, drapeaux) |
| Synchro initiale, **première fois** (Dovecot lit ses 100 000 fichiers à froid, disque externe) | 86 s (≈ 1 150 messages/s) |
| Même synchro, cache de Dovecot chaud | 6,9 s (≈ 14 500 messages/s) |
| Resynchro sans changement | 1,7 s |
| 50 messages livrés + 1 lu + 1 supprimé dans la Maildir | détectés exactement, 1 fenêtre, 1,7 s |
| Lire le corps d'un message non lu | aucun fichier de la boîte modifié (pas de marquage « lu ») |
| Corps d'un message | 859 ms à froid, 0,6 ms ensuite |
| IDLE | réveil par livraison dans la Maildir en moins d'une seconde environ (mesure grossière) |
| Rôles des dossiers (`\Sent`, `\Trash`, `\Drafts`, `\Archive`) | reconnus via SPECIAL-USE |
Dovecot annonce CONDSTORE, QRESYNC, MOVE, SORT, THREAD, COMPRESS=DEFLATE : de quoi accélérer la resynchro (aujourd'hui une passe complète sur les drapeaux) et le threading plus tard.
Tests : `MOTEUR_DOVECOT_PORT=14500 swift test` (45 tests, dont 3 sur Dovecot, ignorés sans cette variable).
Écart avec la prod : l'instance tourne en local, sans TLS, avec une Maildir synthétique ; Dovecot n'est ni iCloud ni Gmail.

## Limites — à ne pas oublier
1. **Le faux serveur Python n'est pas un vrai serveur**, mais Dovecot l'a confirmé sur ce sous-ensemble. **iCloud et Gmail restent à essayer** (leurs particularités : limites de débit, libellés Gmail, IDLE coupé, mot de passe d'application). Réseau local : aucune latence, le débit réel sera plus bas.
2. TLS non essayé (la connexion sans TLS n'est permise que vers localhost, et le moteur refuse d'envoyer un mot de passe en clair ailleurs).
3. Pas de Trousseau, OAuth2, SMTP, CONDSTORE/QRESYNC, rafraîchissement d'IDLE toutes les 29 min, noms de dossiers en UTF-7 modifié, threading, corps indexés.
4. Le paquet principal `Package.swift` demande `swift-nio-imap 1.0.0-alpha.1` : **cette version n'existe pas** (dernière étiquette : 0.5.0), le projet principal ne se résoudrait pas.

## Garanties vérifiées par test
Lecture seule (journal du serveur : aucun STORE/EXPUNGE/APPEND…), lire un corps ne marque pas « lu », reprise après coupure, coupure réseau brutale → erreur franche sans blocage et base intacte, UIDVALIDITY, FTS5 insensible aux saisies hostiles, message trop gros refusé.
