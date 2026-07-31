#!/usr/bin/env python3
"""Pull the real corner names off the circuit and pin them to the centreline.

Two hand-placed labels were a stopgap. OSM has the corners named where the
mappers bothered — Suzuka's S字 and スプーンカーブ, Monza's Variante del Rettifilo
— so the labels can come from the map instead of from me.

A named way only counts if it actually lies on the circuit: pit lanes, support
layouts and neighbouring roads carry names too.
"""
import json
import math
import pathlib
import re
import time
import urllib.parse
import urllib.request

# Paths resolved from the script rather than from the working directory — see
# the note in build_circuits.py for why nothing but the JSON may land in DATA.
HERE = pathlib.Path(__file__).resolve().parent
DATA = HERE.parent.parent / "Glyphline" / "Resources" / "agentverse"
CACHE_DIR = HERE / ".cache"
CACHE_DIR.mkdir(exist_ok=True)

MIRRORS = ["https://overpass-api.de/api/interpreter",
           "https://overpass.kumi.systems/api/interpreter"]
UA = {"User-Agent": "glyphline-agentverse/0.1 (circuit corner research)"}
R = 6371000.0
CACHE = CACHE_DIR / "corners-cache.json"
cache = json.load(open(CACHE)) if CACHE.exists() else {}
SKIP = re.compile(r"pit ?lane|voie des stands|boxengasse|ピットレーン|support|west circuit|"
                  r"east circuit|club|national|kart|ex circuito|anello", re.I)

CIRC = json.load(open(DATA / "circuits.json"))


def overpass(q, key, tries=5):
    if key in cache:
        return cache[key]
    last = None
    for i in range(tries):
        req = urllib.request.Request(MIRRORS[i % 2],
                                     data=urllib.parse.urlencode({"data": q}).encode(), headers=UA)
        try:
            with urllib.request.urlopen(req, timeout=240) as fh:
                res = json.load(fh)
            cache[key] = res
            json.dump(cache, open(CACHE, "w"))
            return res
        except Exception as exc:
            last = exc
            print(f"    retry {i+1}: {exc}", flush=True)
            time.sleep(10 + i * 14)
    raise RuntimeError(last)


def seg_dist(p, a, b):
    vx, vy = b[0] - a[0], b[1] - a[1]
    L2 = vx * vx + vy * vy
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / L2))
    return math.hypot(p[0] - (a[0] + vx * t), p[1] - (a[1] + vy * t))


out = {}
for key, c in CIRC.items():
    print(f"{key} …", flush=True)
    lat0, lon0, rot = c["lat"], c["lon"], c["rot"]
    kx = R * math.cos(math.radians(lat0))
    ct, st = math.cos(rot), math.sin(rot)
    pts = c["points"]

    q = (f'[out:json][timeout:180];'
         f'way["highway"="raceway"]["name"](around:2600,{lat0},{lon0});'
         f'out geom;')
    named = []
    for e in overpass(q, key).get("elements", []):
        nm = (e.get("tags") or {}).get("name")
        g = e.get("geometry") or []
        if not nm or SKIP.search(nm) or len(g) < 2:
            continue
        # in denselben Rahmen wie die Mittellinie
        fr = []
        for p in g:
            wx = math.radians(p["lon"] - lon0) * kx
            wy = -math.radians(p["lat"] - lat0) * R
            fr.append((wx * ct - wy * st, wx * st + wy * ct))
        # Sitzt der Weg wirklich auf der Strecke?
        d = sum(min(seg_dist(p, pts[i], pts[(i + 1) % len(pts)]) for i in range(len(pts)))
                for p in fr) / len(fr)
        if d > 28:
            continue
        mid = fr[len(fr) // 2]
        idx = min(range(len(pts)), key=lambda i: (pts[i][0] - mid[0]) ** 2 + (pts[i][1] - mid[1]) ** 2)
        named.append({"name": nm, "idx": idx, "d": round(d, 1)})

    # Ein Name pro Stelle: dichte Duplikate zusammenfassen
    named.sort(key=lambda x: x["idx"])
    merged = []
    for c2 in named:
        if merged and c2["name"] == merged[-1]["name"] and abs(c2["idx"] - merged[-1]["idx"]) < len(pts) * .1:
            continue
        if any(abs(c2["idx"] - m["idx"]) < len(pts) * .035 for m in merged):
            continue
        merged.append(c2)
    out[key] = merged
    print(f"  -> {len(merged)} Kurvennamen: "
          + ", ".join(m["name"] for m in merged[:9]) + ("…" if len(merged) > 9 else ""), flush=True)
    time.sleep(4)

json.dump(out, open(DATA / "corners.json", "w"), ensure_ascii=False, separators=(",", ":"))
print(f"\nwrote {DATA / 'corners.json'}")
