#!/usr/bin/env python3
"""Splice data and modules into the template and write the screen."""
import json
import os
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
# Since the bundling the data no longer sits beside the scripts.
DATA = REPO / "Glyphline" / "Resources" / "agentverse"
# The mockup is a throwaway artifact and lands beside the script unless told
# otherwise — this used to be a fixed path into one particular home directory,
# which made the script fail on every other machine.
DEST = pathlib.Path(os.environ.get("AGENTVERSE_OUT", HERE))

name = sys.argv[1] if len(sys.argv) > 1 else "agentverse-v4.html"
tpl = (HERE / "template2.html").read_text()

circuits = (DATA / "circuits.json").read_text()
scenery_path = DATA / "scenery.json"
if scenery_path.exists():
    scenery = scenery_path.read_text()
else:
    print("scenery.json missing — writing the screen without surroundings")
    scenery = "null"

def optional(fname):
    p = DATA / fname
    if p.exists():
        return p.read_text()
    print(f"{fname} missing — that layer stays off")
    return "null"


for token, payload in (("/*__CIRCUITS__*/ null", circuits),
                       ("/*__SCENERY__*/ null", scenery),
                       ("/*__TERRAIN__*/ null", optional("terrain.json")),
                       ("/*__CORNERS__*/ null", optional("corners.json")),
                       ("/*__LIGHTING__*/", (HERE / "lighting.js").read_text()),
                       ("/*__SCENE__*/", (HERE / "scene.js").read_text())):
    assert token in tpl, f"missing placeholder {token}"
    tpl = tpl.replace(token, payload)

(DEST / name).write_text(tpl)
(HERE / "check.js").write_text(re.search(r"<script>(.*)</script>", tpl, re.S).group(1))
print(f"wrote {name}  {len(tpl)/1024:.0f} KB")

if scenery != "null":
    s = json.loads(scenery)
    for k, v in s.items():
        hs = sorted(b["h"] for b in v["buildings"])
        print(f"  {k:8s} {len(v['buildings']):5d} Gebäude  "
              f"Median {hs[len(hs)//2] if hs else 0:5.1f} m  höchstes {hs[-1] if hs else 0:5.1f} m  "
              f"{len(v['areas']):4d} Flächen")
