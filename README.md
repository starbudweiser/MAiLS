# MAiLS

A macOS mail client: simple, readable, safe and light. Native Swift 6, read-only in this first version (one iCloud account).

## About

- **Authors:** Stéphan Le Gac Savoye, made with Claude Code (Anthropic).
- **License:** all rights reserved.
- **Disclaimer:** provided as is, without warranty. MAiLS reads your mail without ever changing it (IMAP `EXAMINE` and `BODY.PEEK` only).
- Open *About MAiLS* in the app menu for the version and credits.

## Build

```bash
scripts/build_app.sh dev     # build/MAiLS Dev.app (separate data and Keychain)
scripts/build_app.sh local   # ~/Applications/Applications Personnelles/MAiLS.app
swift test                   # unit tests (Dovecot ones: see CLAUDE.md)
./release.sh                 # notarize and publish a GitHub release
```

Design and architecture: `docs/ARCHITECTURE.md`, `docs/DESIGN_SYSTEM.md`, `docs/MOTEUR_IMAP_RESULTATS.md`.
