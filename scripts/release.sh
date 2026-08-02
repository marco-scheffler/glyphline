#!/usr/bin/env bash
#
# Baut Glyphline zum Weitergeben: universal, mit Developer ID signiert,
# notarisiert und getackert.
#
# Der Unterschied zu scripts/run.sh: das hier ist die Version, die auf einem
# fremden Mac per Doppelklick startet. run.sh baut ad-hoc signiert für diese
# Maschine — sobald so eine App per AirDrop, Mail oder Download reist, hängt
# macOS `com.apple.quarantine` dran und Gatekeeper verweigert den Start.
#
# Universal statt nur arm64, weil ein Intel-Mac eine reine arm64-App gar nicht
# erst startet und der Fehler beim Empfänger nach einem kaputten Download
# aussieht, nicht nach der falschen Architektur.
#
# Notarisierung braucht einmalig hinterlegte Zugangsdaten:
#
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#       --apple-id <deine Apple-ID> --team-id 7YN7YUH475 \
#       --password <app-spezifisches Passwort von appleid.apple.com>
#
# Das app-spezifische Passwort ist nicht das Apple-ID-Passwort. Es wird unter
# appleid.apple.com erzeugt und liegt danach im Schlüsselbund, nicht im Repo.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/build/release"
ARCHIVE="$BUILD/Glyphline.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Glyphline.app"
DERIVED="$BUILD/derived"
NOTARY_PROFILE="${NOTARY_PROFILE:-glyphline-notary}"
APPCAST="$REPO/appcast.xml"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"

cd "$REPO"

echo "==> Prüfe Voraussetzungen"
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "FEHLER: Kein 'Developer ID Application'-Zertifikat im Schlüsselbund." >&2
    echo "        Ohne das lässt sich nichts verteilen — in Xcode unter" >&2
    echo "        Settings > Accounts > Manage Certificates anlegen." >&2
    exit 1
fi

# Früh prüfen, nicht erst nach dem Build: ein Archive plus Export dauert
# Minuten, und ohne Zugangsdaten wäre die ganze Zeit umsonst.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "FEHLER: Kein notarytool-Profil '$NOTARY_PROFILE' im Schlüsselbund." >&2
    echo "        Einmalig anlegen (das app-spezifische Passwort kommt von" >&2
    echo "        appleid.apple.com, nicht dein Apple-ID-Passwort):" >&2
    echo >&2
    echo "        xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\" >&2
    echo "            --apple-id <deine Apple-ID> --team-id 7YN7YUH475 --password <app-spezifisch>" >&2
    exit 1
fi

# Ab hier alles, was mit dem Auto-Update zu tun hat — und zwar vor dem Build.
# Ein Update, das niemanden erreicht, merkt man sonst erst, wenn sich Wochen
# später niemand gemeldet hat.
echo "==> Prüfe die Update-Konfiguration"
xcodebuild -scheme Glyphline -derivedDataPath "$DERIVED" \
    -resolvePackageDependencies >/dev/null 2>&1

if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
    echo "FEHLER: Sparkles Werkzeuge liegen nicht unter $SPARKLE_BIN." >&2
    echo "        Das Auflösen der Pakete hat nichts geliefert." >&2
    exit 1
fi

# Der private Schlüssel liegt im Schlüsselbund. `-p` legt keinen neuen an, es
# schlägt fehl, wenn keiner da ist — genau das wollen wir wissen.
KEY_IN_KEYCHAIN="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)"
if [ -z "$KEY_IN_KEYCHAIN" ]; then
    echo "FEHLER: Kein Signaturschlüssel im Schlüsselbund." >&2
    echo "        Einmalig anlegen mit: $SPARKLE_BIN/generate_keys" >&2
    exit 1
fi

KEY_IN_APP="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$REPO/Glyphline/Info.plist" 2>/dev/null || true)"
if [ "$KEY_IN_KEYCHAIN" != "$KEY_IN_APP" ]; then
    echo "FEHLER: Der Schlüssel in Glyphline/Info.plist ist nicht der, mit dem hier" >&2
    echo "        signiert wird. Jede Prüfung beim Nutzer würde fehlschlagen, und" >&2
    echo "        zwar so, dass es nach einem Serverproblem aussieht." >&2
    echo "        Schlüsselbund: $KEY_IN_KEYCHAIN" >&2
    echo "        Info.plist:    ${KEY_IN_APP:-<fehlt>}" >&2
    exit 1
fi

# Sparkle vergleicht CFBundleVersion, nicht die Versionsnummer, die der Mensch
# liest. Bleibt die Zahl stehen, wird das Release gebaut, notarisiert,
# hochgeladen — und kein einziger Nutzer bekommt es angeboten. Nichts daran
# sieht nach einem Fehler aus, deshalb hier ein Riegel.
BUILD_NUMBER="$(/usr/bin/awk '/CURRENT_PROJECT_VERSION:/ { gsub(/[^0-9]/, "", $2); print $2 }' "$REPO/project.yml")"
NEWEST_IN_FEED="$(/usr/bin/python3 - "$APPCAST" <<'PY'
import os, sys, xml.etree.ElementTree as ET
pfad = sys.argv[1]
if not os.path.exists(pfad):
    print(0)
    raise SystemExit
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
zahlen = [
    int(e.text)
    for e in ET.parse(pfad).getroot().iterfind(".//sparkle:version", ns)
    if e.text and e.text.strip().isdigit()
]
print(max(zahlen) if zahlen else 0)
PY
)"

if [ -z "$BUILD_NUMBER" ]; then
    echo "FEHLER: CURRENT_PROJECT_VERSION nicht aus project.yml lesbar." >&2
    exit 1
fi

if [ "$BUILD_NUMBER" -le "$NEWEST_IN_FEED" ]; then
    echo "FEHLER: CURRENT_PROJECT_VERSION ist $BUILD_NUMBER, im Appcast steht schon" >&2
    echo "        $NEWEST_IN_FEED. Sparkle bietet dieses Update niemandem an." >&2
    echo "        In project.yml erhöhen, dann 'xcodegen generate'." >&2
    exit 1
fi
echo "    Build $BUILD_NUMBER, im Appcast bisher $NEWEST_IN_FEED"

# Vor dem Build, nicht danach: was hier ausgeliefert wird, geht an Nutzer in
# allen acht Sprachen, und ein nicht abgeglichener String erreicht keinen
# Übersetzer. (Es gibt kein CI in diesem Repo, das den Check sonst führen
# könnte — deshalb hängt er an run.sh und hier.)
echo "==> Prüfe den String-Katalog"
"$REPO/scripts/check-l10n.sh"

echo "==> Archiviere universal ($(git rev-parse --short HEAD))"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -scheme Glyphline -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$DERIVED" \
    ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO \
    archive \
    | grep -E "error:|warning:|ARCHIVE (SUCCEEDED|FAILED)" || true

if [ ! -d "$ARCHIVE" ]; then
    echo "FEHLER: Archivierung lieferte kein Archiv unter $ARCHIVE" >&2
    exit 1
fi

echo "==> Exportiere mit Developer ID"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$REPO/scripts/exportOptions-developerid.plist" \
    -exportPath "$EXPORT" \
    | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true

if [ ! -d "$APP" ]; then
    echo "FEHLER: Export lieferte keine App unter $APP" >&2
    exit 1
fi

# Aus dem gebauten Bundle, nicht aus Glyphline/Info.plist: dort steht der
# Platzhalter $(MARKETING_VERSION), den erst der Build ersetzt. Wer die Quelle
# liest, bekommt den Platzhalter als Dateinamen — der ist nicht nur hässlich,
# sondern in jedem Shell-Aufruf ein Zitierproblem.
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
ZIP="$BUILD/Glyphline-$VERSION.zip"

echo "==> Signatur prüfen"
codesign --verify --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|flags=" || true
echo "    Architekturen: $(lipo -archs "$APP/Contents/MacOS/Glyphline")"

echo "==> Zur Notarisierung einreichen (das dauert; --wait blockiert bis fertig)"
# ditto statt zip: ein App-Bundle ist ein Verzeichnis mit Symlinks und
# Ausführungsrechten, und `zip` verliert beides.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Ticket antackern"
# Nach dem Stapeln liegt das Ticket in der App selbst — der Empfänger braucht
# beim ersten Start keine Netzverbindung zu Apple.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Neu paketieren (das ZIP oben enthält die App noch ohne Ticket)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Gegenprobe, wie Gatekeeper sie beim Empfänger sieht"
spctl -a -vvv -t exec "$APP"

# Erst jetzt, nach dem Tackern und dem letzten Paketieren: signiert wird genau
# die Datei, die hochgeladen wird. Ein zwischendurch neu gepacktes ZIP hätte
# eine andere Länge und einen anderen Hash, und Sparkle würde den Download beim
# Nutzer als manipuliert ablehnen.
echo "==> Update signieren und in den Appcast eintragen"
TAG="v$VERSION"
SIGNATURE="$("$SPARKLE_BIN/sign_update" -p "$ZIP")"
LENGTH="$(/usr/bin/stat -f%z "$ZIP")"

"$REPO/scripts/appcast.py" \
    --appcast "$APPCAST" \
    --version "$VERSION" \
    --build "$BUILD_NUMBER" \
    --signature "$SIGNATURE" \
    --length "$LENGTH" \
    --tag "$TAG" \
    --zip-name "$(basename "$ZIP")"

echo
echo "Fertig: $ZIP"
echo "Das ZIP weitergeben, nicht die .app aus dem Finder ziehen."
echo
echo "Damit das Update auch ankommt, in dieser Reihenfolge:"
echo "  1. Release $TAG anlegen und $(basename "$ZIP") als Asset anhängen."
echo "     Der Appcast zeigt schon auf diese URL — vorher ist sie tot."
echo "  2. appcast.xml committen und nach main pushen."
echo "     Erst damit erfahren installierte Apps von $VERSION."
