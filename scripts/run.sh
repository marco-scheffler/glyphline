#!/usr/bin/env bash
#
# Baut Glyphline neu und startet die frische Version.
#
# Warum es die App nach ~/Applications kopiert und nicht einfach aus dem
# Build-Verzeichnis startet: `open -a Glyphline` aktiviert eine bereits
# laufende Instanz, statt eine neue zu starten — man sieht dann den alten
# Stand und sucht den Fehler im Code. Deshalb wird hier immer erst beendet,
# dann gebaut, dann die Kopie ersetzt.
#
# ~/Applications statt /Applications, weil dorthin ohne Passwortabfrage
# geschrieben werden kann. Spotlight findet beides gleichermaßen.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$REPO/build/xcode"
DEST="$HOME/Applications"
APP="$DERIVED/Build/Products/Release/Glyphline.app"

cd "$REPO"

echo "==> Beende eine laufende Instanz"
osascript -e 'tell application "Glyphline" to quit' 2>/dev/null || true
sleep 1
pkill -x Glyphline 2>/dev/null || true

echo "==> Baue Release ($(git rev-parse --short HEAD))"
xcodebuild -scheme Glyphline -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" build \
    | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true

if [ ! -d "$APP" ]; then
    echo "FEHLER: Build lieferte keine App unter $APP" >&2
    exit 1
fi

echo "==> Installiere nach $DEST"
mkdir -p "$DEST"
rm -rf "$DEST/Glyphline.app"
cp -R "$APP" "$DEST/Glyphline.app"

echo "==> Starte"
open "$DEST/Glyphline.app"
sleep 2
if pgrep -x Glyphline >/dev/null; then
    echo "läuft — das Symbol sitzt in der Menüleiste, es öffnet sich kein Fenster"
else
    echo "WARNUNG: Prozess nicht gefunden" >&2
    exit 1
fi
