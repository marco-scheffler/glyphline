#!/usr/bin/env python3
"""Fetch a real elevation model for each circuit.

Spa climbs 100 m through Eau Rouge and the flat rendering shows none of it. A
digital elevation model lets the terrain be hillshaded with the very sun that
already lights the buildings, and gives the centreline a gradient.

Terrarium tiles encode height in RGB: (R*256 + G + B/256) - 32768 metres.
"""
import io
import json
import math
import os
import time
import urllib.request

import numpy as np
from PIL import Image

CIRCUITS = {"monaco": "mc-1929.geojson", "spa": "be-1925.geojson",
            "suzuka": "jp-1962.geojson", "monza": "it-1922.geojson",
            "vegas": "us-2023.geojson"}
BASE = "https://raw.githubusercontent.com/bacinger/f1-circuits/master/circuits/"
TILES = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
UA = {"User-Agent": "glyphline-agentverse/0.1 (terrain research)"}
R = 6371000.0
ZOOM = 14
MARGIN_M = 500
GW, GH = 150, 105          # Auflösung des ausgegebenen Höhengitters
TILE_CACHE = "tiles"
os.makedirs(TILE_CACHE, exist_ok=True)
DIRECTION = {"monaco": "cw", "spa": "cw", "suzuka": "cw", "monza": "cw", "vegas": "ccw"}


def tile(z, x, y):
    path = f"{TILE_CACHE}/{z}_{x}_{y}.png"
    if not os.path.exists(path):
        for attempt in range(4):
            try:
                req = urllib.request.Request(TILES.format(z=z, x=x, y=y), headers=UA)
                with urllib.request.urlopen(req, timeout=90) as fh:
                    open(path, "wb").write(fh.read())
                break
            except Exception as exc:
                if attempt == 3:
                    raise
                time.sleep(3 + attempt * 4)
    im = Image.open(path).convert("RGB")
    a = np.asarray(im).astype(np.float32)
    return a[:, :, 0] * 256 + a[:, :, 1] + a[:, :, 2] / 256 - 32768


def lonlat_to_px(lon, lat, z):
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    lr = math.radians(lat)
    y = (1 - math.log(math.tan(lr) + 1 / math.cos(lr)) / math.pi) / 2 * n
    return x * 256, y * 256


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

    track = [(math.radians(c[0] - lon0) * kx, -math.radians(c[1] - lat0) * R) for c in coords]
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
    fwd = lambda p: ((p[0] - mx) * ct - (p[1] - my) * st,
                     (p[0] - mx) * st + (p[1] - my) * ct)
    # zurück aus dem gedrehten Rahmen in Meter, dann in Grad
    bct, bst = math.cos(theta), math.sin(theta)
    def inv(fx, fy):
        wx = fx * bct - fy * bst + mx
        wy = fx * bst + fy * bct + my
        return (lon0 + math.degrees(wx / kx), lat0 - math.degrees(wy / R))

    tr = [fwd(p) for p in track]
    area = 0.5 * sum(tr[i][0] * tr[(i + 1) % n][1] - tr[(i + 1) % n][0] * tr[i][1] for i in range(n))
    if (area > 0) != (DIRECTION[key] == "cw"):
        tr.reverse()

    xs = [p[0] for p in tr]
    ys = [p[1] for p in tr]
    minX, maxX = min(xs) - MARGIN_M, max(xs) + MARGIN_M
    minY, maxY = min(ys) - MARGIN_M, max(ys) + MARGIN_M

    # Kachelbereich aus den vier Ecken des gedrehten Rechtecks
    corners = [inv(minX, minY), inv(maxX, minY), inv(minX, maxY), inv(maxX, maxY)]
    pxs = [lonlat_to_px(lo, la, ZOOM) for lo, la in corners]
    x0 = int(min(p[0] for p in pxs) // 256) - 1
    x1 = int(max(p[0] for p in pxs) // 256) + 1
    y0 = int(min(p[1] for p in pxs) // 256) - 1
    y1 = int(max(p[1] for p in pxs) // 256) + 1
    tw, th = (x1 - x0 + 1), (y1 - y0 + 1)
    mosaic = np.zeros((th * 256, tw * 256), dtype=np.float32)
    for ty in range(y0, y1 + 1):
        for tx in range(x0, x1 + 1):
            mosaic[(ty - y0) * 256:(ty - y0 + 1) * 256,
                   (tx - x0) * 256:(tx - x0 + 1) * 256] = tile(ZOOM, tx, ty)
    print(f"    {tw}x{th} Kacheln", flush=True)

    def sample(lon, lat):
        px, py = lonlat_to_px(lon, lat, ZOOM)
        u = px - x0 * 256
        v = py - y0 * 256
        iu, iv = int(u), int(v)
        if iu < 0 or iv < 0 or iu >= mosaic.shape[1] - 1 or iv >= mosaic.shape[0] - 1:
            return float("nan")
        fu, fv = u - iu, v - iv
        a = mosaic[iv, iu] * (1 - fu) + mosaic[iv, iu + 1] * fu
        b = mosaic[iv + 1, iu] * (1 - fu) + mosaic[iv + 1, iu + 1] * fu
        return float(a * (1 - fv) + b * fv)

    grid = np.zeros((GH, GW), dtype=np.float32)
    for gy in range(GH):
        fy = minY + (maxY - minY) * (gy + .5) / GH
        for gx in range(GW):
            fx = minX + (maxX - minX) * (gx + .5) / GW
            grid[gy, gx] = sample(*inv(fx, fy))
    grid = np.nan_to_num(grid, nan=float(np.nanmedian(grid)))

    prof = [round(sample(*inv(p[0], p[1])), 1) for p in tr]
    lo, hi = float(grid.min()), float(grid.max())
    plo, phi = min(prof), max(prof)
    out[key] = {
        "minX": round(minX, 1), "minY": round(minY, 1),
        "maxX": round(maxX, 1), "maxY": round(maxY, 1),
        "gw": GW, "gh": GH,
        "lo": round(lo, 1), "hi": round(hi, 1),
        "grid": [int(round(v)) for v in grid.flatten().tolist()],
        "profile": prof,
    }
    print(f"  -> Gelände {lo:.0f}–{hi:.0f} m  ({hi-lo:.0f} m Spanne)   "
          f"Strecke {plo:.0f}–{phi:.0f} m  ({phi-plo:.0f} m Höhenunterschied)", flush=True)

json.dump(out, open("terrain.json", "w"), separators=(",", ":"))
print(f"\nwrote terrain.json ({os.path.getsize('terrain.json')/1024:.0f} KB)")
