# DESIGN SYSTEM — MAiLS

**Décision du 14/11/2026 : MAiLS suit Socle** (le design system commun des applis de Stéphan), pas le thème « AppTheme » d'origine (archivé dans `docs/archive/`).
Référence : `/Volumes/SKYRIM/TOOLS/DESIGN/Socle` (README, `tokens.json`) ; version en ligne : https://claude.ai/artifact/TkNj2Y6SQGZwT6EyME92Ah (fait foi si elle diffère). Maquettes comparées : `maquettes/comparatif.html` (colonne « Socle »).

## 1. Règles absolues (inchangées)
- Zéro transparence, zéro flou (`Material`, `NSVisualEffectView` interdits), zéro ombre portée, zéro dégradé. Surfaces mates séparées par des filets de 1 px.
- Aucune valeur de couleur, de police ou de dimension en dur dans les vues : tout vient de `Sources/MAiLS/UI/Socle.swift` (`Socle.C.*` couleurs, `Socle.M.*` mesures, `Socle.T.*` styles de texte, boutons `SocleButtonStyle`, champs `.socleField()`).
- `Socle.swift` est **généré** (ne pas le modifier à la main). Il est tenu à jour automatiquement : `Socle/sync_apps.sh` (lancé par le hook après toute modification de Socle) inclut ce projet via `EXTRA_SWIFT_APPS`. À la main : `/Volumes/SKYRIM/TOOLS/DESIGN/Socle/sync_apps.sh`.
- Thème sombre par défaut (`Socle.apply()`), clair et système disponibles.

## 2. Traduction pour un client mail
| Besoin | Socle |
|---|---|
| Fond de fenêtre / liste / lecture | `bg` · `surface` · `bg` (lecture sur `surface` en 15 px `Socle.T.reading`) |
| Barre latérale, barre d'en-tête | `surfaceRaised`, barre de 40 px (`Socle.M.sizeBar`) sur toute la largeur |
| Ligne survolée / sélectionnée | `surfaceHover` / `surfaceSelected` + filet d'accent de 2 px à gauche |
| Non lu | pastille 7 px `accent` ; sujet en `labelStrong` |
| Appel principal d'un écran (un seul) : Rédiger, Envoyer, Enregistrer | `action` (ambre), libellé `onAction` |
| Boutons secondaires | `SocleButtonStyle(.secondary)` : aplats sans contour |
| Champs (recherche, rédaction) | `.socleField()` : angles droits, fond creux |
| Palette ⌘K, rédaction, dialogues | voile sombre uni derrière (vue AppKit à calque noir, voir README Socle), rayon 12 px, pas de verre |
| Succès / avertissement / erreur | `success` / `warning` / `danger` et leurs fonds (jamais la couleur seule : toujours un mot ou un préfixe) |
| Raccourcis affichés | `SocleKeycap` |
| Nom de l'appli | « MAiLS » dont le **i** prend la couleur du logo (`Brand.swift`, `Socle.brand("MAiLS", color:)`) ; texte normal dans les menus déroulants |
| Taille du texte | tokens × 1,1 (`Socle.scale`), automatique |

## 3. Métriques de départ (à confirmer sur l'écran réel)
Barre latérale ≥ `Socle.M.sizeSidebarMin` (200), liste ≈ 340 (300–450), lecture ≥ 480, ligne de message 64 px.

## 4. À décider
- **Couleur du logo, donc du « i »** : provisoire #FF6B2B (sombre) / #EA580C (clair). Contraste du « i » mesuré : 5,9:1 sur fond sombre, 3,2:1 sur fond clair Socle (sous les 4,5:1 d'un petit texte) : à trancher avec le logo.
- **Icône de la barre de menus** (si MAiLS en a une) : silhouette en couleur ou monochrome ? Question à poser avant de la dessiner.
