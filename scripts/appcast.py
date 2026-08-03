#!/usr/bin/env python3
"""Trägt eine Version in appcast.xml ein — die Datei, aus der die installierte
App erfährt, dass es etwas Neueres gibt.

Warum von Hand und nicht mit Sparkles `generate_appcast`: das Werkzeug liest
einen Ordner voller Archive und schreibt daraus den ganzen Feed, mit *einem*
gemeinsamen URL-Präfix für alle Einträge. Bei GitHub liegt aber jede Version
unter ihrem eigenen Tag-Pfad (…/releases/download/v1.2/…), und ein einzelnes
Präfix kann das nicht abbilden. Also hier: ein Eintrag pro Aufruf, mit genau der
URL, unter der das ZIP tatsächlich liegt.

Signiert wird nicht hier, sondern von `sign_update` — der private Schlüssel
liegt im Schlüsselbund und hat in einem Skript nichts verloren. Signatur und
Länge kommen als Argumente herein.

Aufruf (aus release.sh):

    scripts/appcast.py --version 1.2 --build 3 --signature <edSignature> \\
        --length 4711 --tag v1.2 --zip-name Glyphline-1.2.zip
"""

import argparse
import datetime
import os
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPO_URL = "https://github.com/marco-scheffler/glyphline"
FEED_URL = "https://raw.githubusercontent.com/marco-scheffler/glyphline/main/appcast.xml"

ET.register_namespace("sparkle", SPARKLE_NS)


def leeres_feed() -> ET.Element:
    # Die xmlns:sparkle-Deklaration wird *nicht* von Hand gesetzt.
    # register_namespace oben schreibt sie beim Serialisieren selbst dazu; beides
    # zusammen ergibt zwei gleiche Attribute am <rss>-Element, und das Ergebnis
    # ist eine Datei, die geschrieben wird, aber von keinem Parser mehr gelesen
    # werden kann — auch nicht vom nächsten Aufruf dieses Skripts.
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Glyphline"
    ET.SubElement(channel, "link").text = FEED_URL
    ET.SubElement(channel, "description").text = "Updates für Glyphline"
    ET.SubElement(channel, "language").text = "en"
    return rss


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--appcast", default="appcast.xml")
    p.add_argument("--version", required=True, help="MARKETING_VERSION, z. B. 1.2")
    p.add_argument("--build", required=True, help="CURRENT_PROJECT_VERSION, die Zahl, die Sparkle vergleicht")
    p.add_argument("--signature", required=True, help="sparkle:edSignature aus sign_update")
    p.add_argument("--length", required=True, help="Größe des ZIP in Bytes")
    p.add_argument("--tag", required=True, help="Git-Tag des Releases, z. B. v1.2")
    p.add_argument("--zip-name", required=True)
    p.add_argument("--minimum-system-version", default="26.0")
    p.add_argument(
        "--notes-file",
        help="HTML-Schnipsel mit den Release Notes. Wird in den Feed eingebettet, "
        "statt auf eine Webseite zu verweisen.",
    )
    args = p.parse_args()

    if os.path.exists(args.appcast):
        tree = ET.parse(args.appcast)
        rss = tree.getroot()
    else:
        rss = leeres_feed()

    channel = rss.find("channel")
    if channel is None:
        print(f"FEHLER: {args.appcast} hat kein <channel>", file=sys.stderr)
        return 1

    # Eine Version darf nur einmal im Feed stehen. Ein zweiter Eintrag mit
    # derselben Build-Nummer ist kein doppelter Hinweis, sondern eine Datei, bei
    # der niemand mehr sagen kann, welche Signatur gilt.
    for item in channel.findall("item"):
        vorhanden = item.find(f"{{{SPARKLE_NS}}}version")
        if vorhanden is not None and vorhanden.text == args.build:
            print(
                f"FEHLER: Build {args.build} steht schon im Appcast. "
                "CURRENT_PROJECT_VERSION in project.yml erhöhen.",
                file=sys.stderr,
            )
            return 1

    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.version
    ET.SubElement(item, "pubDate").text = datetime.datetime.now(
        datetime.timezone.utc
    ).strftime("%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.build
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    # Ohne das bietet Sparkle das Update auch einem Mac an, der es gar nicht
    # starten kann — die App braucht macOS 26.
    ET.SubElement(
        item, f"{{{SPARKLE_NS}}}minimumSystemVersion"
    ).text = args.minimum_system_version
    # Die Notizen gehören in den Feed, nicht hinter einen Link.
    #
    # `releaseNotesLink` klingt naheliegender, und es war zuerst auch so gebaut:
    # ein Verweis auf die GitHub-Release-Seite. Sparkle lädt diese URL aber in
    # eine WebView im Update-Fenster — und was dort ankommt, ist die *ganze*
    # Seite: GitHub-Kopfzeile, Navigation, "Sign in"-Knopf, Reiter für Code und
    # Issues, in einem 500 Punkte breiten Ausschnitt. Von den Release Notes ist
    # nichts zu sehen, ohne zu scrollen.
    #
    # Eingebettet steht stattdessen genau das im Fenster, was drinstehen soll,
    # und es braucht dafür keine Netzverbindung. HTML wird beim Schreiben
    # maskiert; das ist die übliche RSS-Form, und Sparkle rendert sie als HTML.
    if args.notes_file:
        with open(args.notes_file, encoding="utf-8") as f:
            ET.SubElement(item, "description").text = f.read().strip()
    else:
        # Kein Notizen-Schnipsel: lieber der Link als gar nichts, aber mit einem
        # Hinweis, weil das die schlechtere von beiden Anzeigen ist.
        print(
            f"WARNUNG: keine Release Notes für {args.version} — das Update-Fenster "
            "zeigt die GitHub-Seite statt der Notizen.",
            file=sys.stderr,
        )
        ET.SubElement(
            item, f"{{{SPARKLE_NS}}}releaseNotesLink"
        ).text = f"{REPO_URL}/releases/tag/{args.tag}"
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": f"{REPO_URL}/releases/download/{args.tag}/{args.zip_name}",
            "length": args.length,
            "type": "application/octet-stream",
            f"{{{SPARKLE_NS}}}edSignature": args.signature,
        },
    )

    # Neueste zuerst: Sparkle liest zwar den ganzen Feed, aber ein Mensch, der
    # die Datei im Diff überfliegt, liest von oben.
    erstes_item = channel.find("item")
    channel.insert(list(channel).index(erstes_item) if erstes_item is not None else len(channel), item)

    ET.indent(rss, space="  ")
    ET.ElementTree(rss).write(args.appcast, encoding="utf-8", xml_declaration=True)
    # write() hängt kein Zeilenende an, und eine Datei ohne das ist im Diff
    # jedes Mal eine Zeile "\ No newline at end of file".
    with open(args.appcast, "a", encoding="utf-8") as f:
        f.write("\n")

    print(f"==> {args.version} (Build {args.build}) in {args.appcast} eingetragen")
    return 0


if __name__ == "__main__":
    sys.exit(main())
