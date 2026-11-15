# PRD — Client Mail Natif macOS « MAiLS »

## 1. Vision produit
Remplacer Apple Mail par un client natif macOS ultra-léger, instantané à la recherche, pilotable intégralement au clavier et doté d'un design **100 % Flat** (inspiré de Linear et Superhuman), sans abonnement ni transit des données par un serveur tiers.

## 2. Compatibilité & Comptes
- **Plateforme :** macOS 15.0+ (Apple Silicon natif).
- **Protocoles :** IMAP (SSL/TLS port 993, IDLE push) et SMTP (STARTTLS port 587 / SSL port 465).
- **Fournisseurs cibles :**
  - **iCloud Mail :** authentification via mot de passe d'application Apple (`imap.mail.me.com` / `smtp.mail.me.com`).
  - **Gmail / Google Workspace :** OAuth2 ou mot de passe d'application (`imap.gmail.com` / `smtp.gmail.com`).
  - **IMAP/SMTP standard :** configuration manuelle complète (OVH, Infomaniak, Proton Bridge, etc.).
- **Multi-comptes :** Boîte de réception unifiée + vue par compte individuel + gestion des alias d'expédition.

## 3. Fonctionnalités clés (Supérieures à Apple Mail)
- `Cmd + K` : Palette de commandes universelle.
- `J`/`K` : Navigation ; `E` : Archiver ; `#` : Corbeille ; `R` : Répondre ; `C` : Rédiger ; `H` : Snooze ; `U` : Désabonnement RFC 8058 en 1 clic ; `/` : Recherche FTS5 (`from:`, `to:`, `has:attachment`, `is:unread`).
- **Confidentialité :** Bouclier anti-trackers (`1x1`), blocage des images distantes par défaut, `WKWebView` sandboxée sans JavaScript.
- **Productivité :** Rappels de suivi (*Follow-up* sans réponse sous 48/72 h), annulation d'envoi réelle (*Undo Send* 10 s), vue nettoyage par expéditeur, signature Markdown/HTML.
