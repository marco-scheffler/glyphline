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
NOTARY_PROFILE="${NOTARY_PROFILE:-glyphline-notary}"

cd "$REPO"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Glyphline/Info.plist 2>/dev/null || echo "0.0")"
ZIP="$BUILD/Glyphline-$VERSION.zip"

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

echo "==> Archiviere universal ($(git rev-parse --short HEAD))"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -scheme Glyphline -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
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

echo
echo "Fertig: $ZIP"
echo "Das ZIP weitergeben, nicht die .app aus dem Finder ziehen."
