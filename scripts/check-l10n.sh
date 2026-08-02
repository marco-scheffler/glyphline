#!/usr/bin/env bash
#
# Prüft, ob Localizable.xcstrings noch zum Quelltext passt.
#
# Warum das nötig ist: Xcode gleicht den String-Katalog beim Bauen in der IDE
# automatisch ab, `xcodebuild` tut das nicht. Ein neu hinzugefügter
# String(localized:) landet dadurch nie im Katalog — und nichts sieht kaputt
# aus, weil der englische Fallback aus dem Quelltext korrekt gerendert wird.
# Auffallen würde es erst dem Nutzer einer anderen Sprache, also niemandem hier.
#
# Der Ablauf ist der von Apple dokumentierte manuelle Weg: bauen mit
# SWIFT_EMIT_LOC_STRINGS=YES, danach `xcstringstool sync`. Gebaut wird gegen
# eine Kopie des Katalogs; verändert der sync sie, fehlte etwas — dann schlägt
# das hier fehl und nennt den Diff.
#
#   scripts/check-l10n.sh              # prüfen, Katalog bleibt unangetastet
#   scripts/check-l10n.sh --fix        # gleich synchronisieren statt meckern
#
# Kein CI: dieses Repo hat keine Workflows, deshalb hängt der Check an den zwei
# Skripten, die tatsächlich laufen — run.sh bei jedem Durchlauf und release.sh
# vor dem Ausliefern. Beide reichen ihr eigenes Build-Verzeichnis durch, damit
# hier nicht ein zweites Mal von vorn gebaut wird.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$REPO/Glyphline/Resources/Localizable.xcstrings"
DERIVED="${L10N_DERIVED_DATA:-$REPO/build/l10n}"
FIX=0

for arg in "$@"; do
    case "$arg" in
        --fix) FIX=1 ;;
        *) echo "FEHLER: unbekanntes Argument '$arg'" >&2; exit 2 ;;
    esac
done

cd "$REPO"

# Fremdes Build-Verzeichnis mitbenutzen — aber nur, wenn der Aufrufer es
# ausdrücklich durchreicht. Genau dann hat er gerade selbst mit
# SWIFT_EMIT_LOC_STRINGS=YES gebaut, und ein zweiter Build wäre verschenkte Zeit.
#
# Ohne diese Bedingung entschied die bloße *Existenz* alter .stringsdata, ob neu
# gebaut wird. Das ging still schief: ein Aufruf von Hand fand die Reste eines
# früheren Laufs, glich den Katalog gegen einen alten Stand ab und meldete
# "synchronisiert", ohne einen einzigen neuen String gesehen zu haben. release.sh
# reicht nichts durch — dort hätte derselbe Fehler eine Auslieferung durchgewunken.
if [ -n "${L10N_DERIVED_DATA:-}" ] \
    && [ -n "$(find "$DERIVED" -name '*.stringsdata' -print -quit 2>/dev/null)" ]; then
    echo "==> Nutze die .stringsdata aus $DERIVED"
else
    echo "==> Baue mit SWIFT_EMIT_LOC_STRINGS=YES"
    # Erst wegräumen: sonst mischen sich die .stringsdata dieses Builds mit denen
    # des vorigen, und ein gelöschter String bliebe über seine alte Datei am Leben.
    rm -rf "$DERIVED"
    xcodebuild -scheme Glyphline -configuration Debug -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED" SWIFT_EMIT_LOC_STRINGS=YES build \
        | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
fi

STRINGSDATA=()
while IFS= read -r file; do
    STRINGSDATA+=(--stringsdata "$file")
done < <(find "$DERIVED" -name '*.stringsdata' | sort)

if [ ${#STRINGSDATA[@]} -eq 0 ]; then
    echo "FEHLER: Keine .stringsdata unter $DERIVED — der Build hat nichts geliefert." >&2
    exit 1
fi

if [ "$FIX" = "1" ]; then
    xcrun xcstringstool sync "$CATALOG" "${STRINGSDATA[@]}"
    echo "==> Katalog synchronisiert: $CATALOG"
    exit 0
fi

# Auf einer Kopie synchronisieren, damit ein Prüflauf nie den Arbeitsbaum
# anfasst — sonst würde ausgerechnet der Check den Fehler stillschweigend
# beheben, den er melden soll.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$CATALOG" "$WORK/Localizable.xcstrings"
xcrun xcstringstool sync "$WORK/Localizable.xcstrings" "${STRINGSDATA[@]}"

if diff -q "$CATALOG" "$WORK/Localizable.xcstrings" >/dev/null; then
    echo "==> String-Katalog ist aktuell"
    exit 0
fi

echo "FEHLER: Localizable.xcstrings passt nicht mehr zum Quelltext." >&2
echo "        Ein String wurde hinzugefügt, geändert oder entfernt, ohne den" >&2
echo "        Katalog abzugleichen. Übersetzer bekommen ihn so nie zu sehen." >&2
echo >&2
diff -u "$CATALOG" "$WORK/Localizable.xcstrings" | head -60 >&2
echo >&2
echo "        Beheben mit: scripts/check-l10n.sh --fix" >&2
exit 1
