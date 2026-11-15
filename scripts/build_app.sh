#!/bin/zsh
# Construit l'appli MAiLS (SwiftPM → .app), la signe (certificat stable, voir _tools/sign_app.sh) et NE LA LANCE PAS.
#   scripts/build_app.sh dev     → build/MAiLS Dev.app          (identifiant fr.stephan.mails.dev : données et Trousseau à part)
#   scripts/build_app.sh local   → ~/Applications/Applications Personnelles/MAiLS.app   (ma version locale, signature locale)
# Pas de notarisation, pas de GitHub : voir « compile, notarise et pousse ».
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-dev}"
SIGN="/Volumes/SKYRIM/TOOLS/MAC/_tools/sign_app.sh"
VERSION="${MAILS_VERSION:-0.1.2}"

case "$MODE" in
  dev)   APP="build/MAiLS Dev.app"; BUNDLE_ID="fr.stephan.mails.dev"; DISPLAY="MAiLS Dev" ;;
  local) APP="$HOME/Applications/Applications Personnelles/MAiLS.app"; BUNDLE_ID="fr.stephan.mails"; DISPLAY="MAiLS" ;;
  *) echo "usage : $0 dev|local" >&2; exit 2 ;;
esac

swift build -c release --product MAiLS --arch arm64 >/dev/null
BIN=".build/arm64-apple-macosx/release"
[ -x "$BIN/MAiLS" ] || BIN=".build/release"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MAiLS" "$APP/Contents/MacOS/MAiLS"
for l in Resources/*.lproj; do cp -R "$l" "$APP/Contents/Resources/"; done
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done   # ressources des dépendances
ICON_KEY=""
if [ -f assets/MAiLS.icns ]; then cp assets/MAiLS.icns "$APP/Contents/Resources/AppIcon.icns"; ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleDisplayName</key><string>$DISPLAY</string>
<key>CFBundleName</key><string>$DISPLAY</string>
<key>CFBundleExecutable</key><string>MAiLS</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleLocalizations</key><array><string>fr</string><string>en</string><string>es</string><string>it</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
$ICON_KEY
</dict></plist>
PLIST

SIGN_ENTITLEMENTS="Resources/MAiLS.entitlements" "$SIGN" "$APP" "$VERSION" >/dev/null
echo "OK : $APP ($BUNDLE_ID)"
