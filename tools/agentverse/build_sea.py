#!/usr/bin/env python3
"""Work out which part of the frame is sea, and put it in the terrain grid.

Monaco's harbour was rendering as ground because OSM does not carry the sea as a
polygon — the water is implied by `natural=coastline`, whose documented rule is
that land lies to the left of the way direction. That rule is enough: for every
terrain cell, find the nearest coastline segment and test which side it falls on.

Screen coordinates run y-downwards, which flips handedness against the usual
maths convention, so here land is where the cross product is negative. Checked
against a north-running and an east-running coast before being trusted.
"""
import json
import math
import os
import pathlib
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
UA = {"User-Agent": "glyphline-agentverse/0.1 (coastline research)"}
R = 6371000.0
CACHE = CACHE_DIR / "sea-cache.json"
cache = json.load(open(CACHE)) if CACHE.exists() else {}

CIRC = json.load(open(DATA / "circuits.json"))
TERR = json.load(open(DATA / "terrain.json"))


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


for key, c in CIRC.items():
    T = TERR[key]
    lat0, lon0, rot = c["lat"], c["lon"], c["rot"]
    kx = R * math.cos(math.radians(lat0))
    ct, st = math.cos(rot), math.sin(rot)

    # A generous search window: the coast can run on beyond the frame
    half = max(T["maxX"] - T["minX"], T["maxY"] - T["minY"]) * 0.85
    radius = int(half + 1200)
    q = (f'[out:json][timeout:180];'
         f'way["natural"="coastline"](around:{radius},{lat0},{lon0});'
         f'out geom;')
    ways = []
    try:
        for e in overpass(q, key).get("elements", []):
            g = e.get("geometry") or []
            if len(g) < 2:
                continue
            pts = []
            for p in g:
                wx = math.radians(p["lon"] - lon0) * kx
                wy = -math.radians(p["lat"] - lat0) * R
                pts.append((wx * ct - wy * st, wx * st + wy * ct))
            ways.append(pts)
    except Exception as exc:
        print(f"{key:8s} coastline query failed: {exc}")
        ways = []

    if not ways:
        T["sea"] = None
        print(f"{key:8s} no coastline in range — entirely inland")
        time.sleep(3)
        continue

    segs = []
    for pts in ways:
        for a, b in zip(pts, pts[1:]):
            if a != b:
                segs.append((a[0], a[1], b[0] - a[0], b[1] - a[1]))

    gw, gh = T["gw"], T["gh"]
    minX, minY = T["minX"], T["minY"]
    dx = (T["maxX"] - minX) / gw
    dy = (T["maxY"] - minY) / gh
    mask = bytearray(gw * gh)
    for gy in range(gh):
        py = minY + (gy + .5) * dy
        for gx in range(gw):
            px = minX + (gx + .5) * dx
            best, bestcross = 1e18, 0.0
            for (ax, ay, vx, vy) in segs:
                L2 = vx * vx + vy * vy
                t = 0.0 if L2 == 0 else ((px - ax) * vx + (py - ay) * vy) / L2
                t = 0.0 if t < 0 else 1.0 if t > 1 else t
                ex, ey = px - (ax + vx * t), py - (ay + vy * t)
                d2 = ex * ex + ey * ey
                if d2 < best:
                    best = d2
                    bestcross = vx * (py - ay) - vy * (px - ax)
            mask[gy * gw + gx] = 1 if bestcross > 0 else 0

    sea = sum(mask)
    T["sea"] = list(mask)
    print(f"{key:8s} {len(segs):4d} coastline segments  ->  "
          f"{sea*100//(gw*gh)}% of the frame is water")
    time.sleep(3)

dest = DATA / "terrain.json"
json.dump(TERR, open(dest, "w"), separators=(",", ":"))
print(f"\nupdated {dest} ({os.path.getsize(dest)/1024:.0f} KB)")
