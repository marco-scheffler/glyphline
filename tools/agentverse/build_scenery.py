#!/usr/bin/env python3
"""Fetch the real surroundings of each circuit: building footprints with their
heights, water, woodland, parkland.

Drawing invented blocks was the honest limit of the last version. This replaces
them with what is actually there — Monaco's buildings stand where they stand,
with their own outlines and storey counts, and the harbour is the harbour rather
than a rectangle guessed from the track's interior.

The projection is re-derived with the same formulas as build_circuits.py, so
scenery and centreline land in one coordinate frame.
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

CIRCUITS = {
    "monaco": "mc-1929.geojson", "spa": "be-1925.geojson",
    "suzuka": "jp-1962.geojson", "monza": "it-1922.geojson",
    "vegas": "us-2023.geojson",
}
BASE = "https://raw.githubusercontent.com/bacinger/f1-circuits/master/circuits/"
MIRRORS = ["https://overpass-api.de/api/interpreter",
           "https://overpass.kumi.systems/api/interpreter"]
UA = {"User-Agent": "glyphline-agentverse/0.1 (circuit surroundings research)"}
R = 6371000.0
MARGIN_M = 420          # how far beyond the circuit to keep scenery
KEEP_NEAR_M = 400       # discard anything further than this from the track
CACHE = CACHE_DIR / "scenery-cache.json"
cache = json.load(open(CACHE)) if CACHE.exists() else {}


def overpass(query, key, tries=6):
    if key in cache:
        return cache[key]
    last = None
    for i in range(tries):
        req = urllib.request.Request(
            MIRRORS[i % len(MIRRORS)],
            data=urllib.parse.urlencode({"data": query}).encode(), headers=UA)
        try:
            with urllib.request.urlopen(req, timeout=600) as fh:
                res = json.load(fh)
            cache[key] = res
            json.dump(cache, open(CACHE, "w"))
            return res
        except Exception as exc:
            last = exc
            print(f"    retry {i+1}: {exc}", flush=True)
            time.sleep(15 + i * 20)
    raise RuntimeError(f"overpass failed for {key}: {last}")


def rdp(pts, eps):
    """Douglas-Peucker. A Monaco footprint carries far more vertices than a
    building three pixels wide can show."""
    if len(pts) < 3:
        return pts
    ax, ay = pts[0]
    bx, by = pts[-1]
    dx, dy = bx - ax, by - ay
    n2 = dx * dx + dy * dy
    worst, wi = -1.0, 0
    for i in range(1, len(pts) - 1):
        px, py = pts[i]
        if n2 == 0:
            d = math.hypot(px - ax, py - ay)
        else:
            t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / n2))
            d = math.hypot(px - (ax + dx * t), py - (ay + dy * t))
        if d > worst:
            worst, wi = d, i
    if worst <= eps:
        return [pts[0], pts[-1]]
    return rdp(pts[:wi + 1], eps)[:-1] + rdp(pts[wi:], eps)


def height_of(tags):
    h = tags.get("height") or tags.get("building:height")
    if h:
        try:
            return max(2.0, float(str(h).replace("m", "").strip()))
        except ValueError:
            pass
    lv = tags.get("building:levels") or tags.get("levels")
    if lv:
        try:
            return max(2.0, float(str(lv).split(";")[0]) * 3.2)
        except ValueError:
            pass
    if tags.get("building") in ("garage", "shed", "hut", "roof", "carport"):
        return 3.0
    return 9.0


def seg_dist(p, a, b):
    vx, vy = b[0] - a[0], b[1] - a[1]
    L2 = vx * vx + vy * vy
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / L2))
    return math.hypot(p[0] - (a[0] + vx * t), p[1] - (a[1] + vy * t))


out = {}
for key, fname in CIRCUITS.items():
    print(f"{key} …", flush=True)
    with urllib.request.urlopen(BASE + fname, timeout=60) as fh:
        gj = json.load(fh)
    feat = gj["features"][0]
    coords = feat["geometry"]["coordinates"]
    if feat["geometry"]["type"] == "MultiLineString":
        coords = max(coords, key=len)
    lat0 = sum(c[1] for c in coords) / len(coords)
    lon0 = sum(c[0] for c in coords) / len(coords)
    kx = R * math.cos(math.radians(lat0))

    def to_m(lon, lat):
        return (math.radians(lon - lon0) * kx, -math.radians(lat - lat0) * R)

    track = [to_m(c[0], c[1]) for c in coords]
    if math.hypot(track[0][0] - track[-1][0], track[0][1] - track[-1][1]) < 1.0:
        track = track[:-1]
    n = len(track)
    mx = sum(p[0] for p in track) / n
    my = sum(p[1] for p in track) / n
    cxx = sum((p[0] - mx) ** 2 for p in track) / n
    cyy = sum((p[1] - my) ** 2 for p in track) / n
    cxy = sum((p[0] - mx) * (p[1] - my) for p in track) / n
    theta = 0.5 * math.atan2(2 * cxy, cxx - cyy)
    ct, st = math.cos(-theta), math.sin(-theta)

    def frame(p):
        return ((p[0] - mx) * ct - (p[1] - my) * st,
                (p[0] - mx) * st + (p[1] - my) * ct)

    tr = [frame(p) for p in track]

    lats = [c[1] for c in coords]
    lons = [c[0] for c in coords]
    dlat = MARGIN_M / 111320.0
    dlon = MARGIN_M / (111320.0 * math.cos(math.radians(lat0)))
    bbox = f"{min(lats)-dlat},{min(lons)-dlon},{max(lats)+dlat},{max(lons)+dlon}"

    q = (f'[out:json][timeout:540];('
         f'way["building"]({bbox});'
         f'way["natural"="water"]({bbox});'
         f'way["waterway"="riverbank"]({bbox});'
         f'way["natural"="wood"]({bbox});'
         f'way["landuse"~"^(forest|grass|meadow|village_green|recreation_ground)$"]({bbox});'
         f'way["leisure"~"^(park|pitch|golf_course|garden)$"]({bbox});'
         f');out geom;')
    res = overpass(q, key)

    buildings, areas = [], []
    for e in res.get("elements", []):
        g = e.get("geometry") or []
        if len(g) < 3:
            continue
        tags = e.get("tags", {})
        ring = [frame(to_m(p["lon"], p["lat"])) for p in g]
        if ring[0] == ring[-1]:
            ring = ring[:-1]
        if len(ring) < 3:
            continue
        cx = sum(p[0] for p in ring) / len(ring)
        cy = sum(p[1] for p in ring) / len(ring)
        d = min(seg_dist((cx, cy), a, b) for a, b in zip(tr, tr[1:] + tr[:1]))
        if d > KEEP_NEAR_M:
            continue
        area = abs(0.5 * sum(ring[i][0] * ring[(i + 1) % len(ring)][1]
                             - ring[(i + 1) % len(ring)][0] * ring[i][1]
                             for i in range(len(ring))))
        simple = rdp(ring + [ring[0]], 1.6)[:-1]
        if len(simple) < 3:
            continue
        pts = [[round(p[0], 1), round(p[1], 1)] for p in simple]
        if "building" in tags:
            if area < 18:
                continue
            buildings.append({"p": pts, "h": round(height_of(tags), 1), "a": round(area)})
        else:
            if area < 220:
                continue
            kind = ("water" if tags.get("natural") == "water" or tags.get("waterway") == "riverbank"
                    else "wood" if tags.get("natural") == "wood" or tags.get("landuse") == "forest"
                    else "green")
            areas.append({"p": pts, "k": kind, "a": round(area)})

    buildings.sort(key=lambda b: -b["a"])
    areas.sort(key=lambda a: -a["a"])
    buildings = buildings[:1400]
    areas = areas[:220]
    out[key] = {"buildings": buildings, "areas": areas}
    hs = [b["h"] for b in buildings]
    print(f"  -> {len(buildings)} Gebäude (Höhe {min(hs) if hs else 0:.0f}–{max(hs) if hs else 0:.0f} m, "
          f"Median {sorted(hs)[len(hs)//2] if hs else 0:.0f} m), "
          f"{len(areas)} Flächen "
          f"({sum(1 for a in areas if a['k']=='water')} Wasser, "
          f"{sum(1 for a in areas if a['k']=='wood')} Wald, "
          f"{sum(1 for a in areas if a['k']=='green')} Grün)", flush=True)
    time.sleep(5)

dest = DATA / "scenery.json"
json.dump(out, open(dest, "w"), separators=(",", ":"))
print(f"\nwrote {dest} ({os.path.getsize(dest)/1024:.0f} KB)")
