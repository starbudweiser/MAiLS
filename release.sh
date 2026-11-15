#!/bin/zsh
# Publie une version de MAiLS : compilation, signature Developer ID, notarisation, agrafage, release GitHub.
# Usage : ./release.sh [--notes "texte"] [--replace]   — la version vient de MAILS_VERSION (défaut : celle de build_app.sh).
#   --replace   remplace les fichiers d'une release qui existe déjà pour cette version
# DRY=1 : montre les étapes sans notariser ni publier.
# Prérequis : dépôt propre et poussé sur main (le tag vise main), gh connecté, _tools/notarize_app.sh opérationnel.
# Ma version locale (signature locale) est reconstruite ; la notarisation travaille sur une copie.
set -euo pipefail
cd "$(dirname "$0")"

OWNER="starbudweiser"; REPO="MAiLS"; NAME="MAiLS"
TOOLS="/Volumes/SKYRIM/TOOLS/MAC/_tools"
APP="$HOME/Applications/Applications Personnelles/$NAME.app"
REPLACE=0; NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --replace) REPLACE=1 ;;
    --notes) NOTES="${2:-}"; shift ;;
    *) echo "option inconnue : $1" >&2; exit 1 ;;
  esac
  shift
done
run() { if [ "${DRY:-0}" = 1 ]; then echo "[DRY] $*"; else "$@"; fi; }

# Dépôt propre et poussé.
[ -d .git ] || { echo "release : pas un dépôt git" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "release : modifications non commitées" >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "release : pas synchronisé avec origin/main (commit ou push manquant)" >&2; exit 1; }

echo "→ Compilation"
run scripts/build_app.sh local
[ -d "$APP" ] || { echo "release : $APP introuvable" >&2; exit 1; }
version="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
tag="v$version"
echo "→ $NAME $version (tag $tag)"
if gh release view "$tag" -R "$OWNER/$REPO" >/dev/null 2>&1 && [ "$REPLACE" != 1 ]; then
  echo "release : la release $tag existe déjà (--replace pour remplacer ses fichiers)" >&2; exit 1
fi

echo "→ Notarisation"
# Le bac à sable (client réseau) est conservé : droits propres de l'appli.
run env APP_ENTITLEMENTS="$PWD/Resources/MAiLS.entitlements" "$TOOLS/notarize_app.sh" "$APP"
zip="$TOOLS/notarized/$NAME.zip"
asset="$NAME-$version-macOS-arm64.zip"
if [ "${DRY:-0}" != 1 ]; then
  [ -f "$zip" ] || { echo "release : $zip absent après la notarisation" >&2; exit 1; }
  stage="$(mktemp -d)"; cp "$zip" "$stage/$asset"
  (cd "$stage" && shasum -a 256 "$asset" > "$asset.sha256")
fi

echo "→ Publication"
[ -n "$NOTES" ] && notes=(--notes "$NOTES") || notes=(--generate-notes)
if gh release view "$tag" -R "$OWNER/$REPO" >/dev/null 2>&1; then
  run gh release upload "$tag" -R "$OWNER/$REPO" --clobber "${stage:-/tmp}/$asset" "${stage:-/tmp}/$asset.sha256"
else
  run gh release create "$tag" -R "$OWNER/$REPO" --target main --title "$NAME $version" "${notes[@]}" "${stage:-/tmp}/$asset" "${stage:-/tmp}/$asset.sha256"
fi
echo "✓ https://github.com/$OWNER/$REPO/releases/tag/$tag"
