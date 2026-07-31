#!/usr/bin/env python3
"""Build the circuit dataset: centreline, pit lane, and a measured start/finish.

Emitted in metres, centred, long axis laid flat. Normalising against a fixed
16:9 was the bug that pushed half of Las Vegas out of frame — the fit belongs to
the renderer, the only thing that knows how tall the stage really is.

Picking the pit lane needed three passes to get right. Length alone chose Spa's
support paddock (1201 m against the real 719 m). Proximity alone kept it, because
that paddock hugs the circuit too. What separates them is the name: a venue that
runs several layouts labels the secondary ones, and only the primary lane is
left plain.
"""
import json
import math
import pathlib
import re
import time
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
# Every path is resolved from the script, never from the working directory.
# XcodeGen expands `resources: Glyphline/Resources` from the filesystem, so
# anything left lying in the data directory is copied into the app whether or
# not git tracks it — the caches would ship silently, and `tiles/` is hundreds
# of megabytes. Only the finished JSON is allowed in there.
DATA = REPO / "Glyphline" / "Resources" / "agentverse"
CACHE_DIR = HERE / ".cache"
CACHE_DIR.mkdir(exist_ok=True)

CIRCUITS = {
    "monaco": ("mc-1929.geojson", "Europe/Monaco"),
    "spa":    ("be-1925.geojson", "Europe/Brussels"),
    "suzuka": ("jp-1962.geojson", "Asia/Tokyo"),
    "monza":  ("it-1922.geojson", "Europe/Rome"),
    "vegas":  ("us-2023.geojson", "America/Los_Angeles"),
}
BASE = "https://raw.githubusercontent.com/bacinger/f1-circuits/master/circuits/"
MIRRORS = ["https://overpass-api.de/api/interpreter",
           "https://overpass.kumi.systems/api/interpreter"]
UA = {"User-Agent": "glyphline-agentverse/0.1 (circuit geometry research)"}
NAME_RE = "[Pp]it ?[Ll]ane|[Vv]oie des stands|[Bb]oxengasse|ピット|[Pp]itlane"
# Secondary layouts announce themselves. The Grand Prix lane never does.
SECONDARY = re.compile(r"support|west|east|club|national|kart|junior|south|north|"
                       r"school|test|paddock", re.I)
R = 6371000.0
# How each circuit is actually driven. Las Vegas is the odd one out.
DIRECTION = {"monaco": "cw", "spa": "cw", "suzuka": "cw", "monza": "cw", "vegas": "ccw"}
# Where OSM marks the start line outright. Only Monaco has one, and it sits 250 m
# from where projecting the pit lane's midpoint put it — worth the special case.
START_NODES = {"monaco": (43.7350269, 7.4212652)}
CACHE = CACHE_DIR / "overpass-cache.json"
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
            with urllib.request.urlopen(req, timeout=240) as fh:
                res = json.load(fh)
            cache[key] = res
            json.dump(cache, open(CACHE, "w"))
            return res
        except Exception as exc:
            last = exc
            print(f"    retry {i+1}: {exc}", flush=True)
            time.sleep(10 + i * 15)
    raise RuntimeError(f"overpass failed for {key}: {last}")


def to_metres(lonlat, lat0, lon0):
    k = R * math.cos(math.radians(lat0))
    return [(math.radians(lo - lon0) * k, -math.radians(la - lat0) * R)
            for lo, la in lonlat]


def seg_dist(p, a, b):
    vx, vy = b[0] - a[0], b[1] - a[1]
    L2 = vx * vx + vy * vy
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / L2))
    return math.hypot(p[0] - (a[0] + vx * t), p[1] - (a[1] + vy * t))


def dist_to_poly(p, poly):
    return min(seg_dist(p, a, b) for a, b in zip(poly, poly[1:] + poly[:1]))


out = {}
for key, (fname, tz) in CIRCUITS.items():
    print(f"{key} …", flush=True)
    with urllib.request.urlopen(BASE + fname, timeout=60) as fh:
        gj = json.load(fh)
    feat = gj["features"][0]
    props = feat["properties"]
    coords = feat["geometry"]["coordinates"]
    if feat["geometry"]["type"] == "MultiLineString":
        coords = max(coords, key=len)

    lat0 = sum(c[1] for c in coords) / len(coords)
    lon0 = sum(c[0] for c in coords) / len(coords)
    track = to_metres([(c[0], c[1]) for c in coords], lat0, lon0)
    if math.hypot(track[0][0] - track[-1][0], track[0][1] - track[-1][1]) < 1.0:
        track = track[:-1]
    n = len(track)
    length = sum(math.hypot(track[(i + 1) % n][0] - track[i][0],
                            track[(i + 1) % n][1] - track[i][1]) for i in range(n))

    q = (f'[out:json][timeout:180];'
         f'(way["raceway"="pitlane"](around:2800,{lat0},{lon0});'
         f' way["pit_lane"](around:2800,{lat0},{lon0});'
         f' way["highway"="raceway"]["name"~"{NAME_RE}"](around:2800,{lat0},{lon0}););'
         f'out geom;')
    cands = []
    for e in overpass(q, key).get("elements", []):
        g = e.get("geometry") or []
        if len(g) < 4:
            continue
        pl = to_metres([(p["lon"], p["lat"]) for p in g], lat0, lon0)
        plen = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pl, pl[1:]))
        if plen < 150:
            continue
        mean_d = sum(dist_to_poly(p, track) for p in pl) / len(pl)
        if mean_d > 70:
            continue
        cands.append({"name": e.get("tags", {}).get("name"), "len": plen,
                      "d": mean_d, "pts": pl,
                      "secondary": bool(SECONDARY.search(e.get("tags", {}).get("name") or ""))})
    if not cands:
        raise RuntimeError(f"{key}: no pit lane candidate")
    for c in sorted(cands, key=lambda c: -c["len"]):
        print(f"    {'SKIP' if c['secondary'] else 'keep'} "
              f"{str(c['name'] or '(unnamed)'):26s} {c['len']:6.0f} m  ⌀{c['d']:5.1f} m", flush=True)
    primary = [c for c in cands if not c["secondary"]] or cands
    best = max(primary, key=lambda c: c["len"])
    pit = best["pts"]

    mx = sum(p[0] for p in track) / n
    my = sum(p[1] for p in track) / n
    cxx = sum((p[0] - mx) ** 2 for p in track) / n
    cyy = sum((p[1] - my) ** 2 for p in track) / n
    cxy = sum((p[0] - mx) * (p[1] - my) for p in track) / n
    theta = 0.5 * math.atan2(2 * cxy, cxx - cyy)
    ct, st = math.cos(-theta), math.sin(-theta)
    rot = lambda p: [round((p[0] - mx) * ct - (p[1] - my) * st, 2),
                     round((p[0] - mx) * st + (p[1] - my) * ct, 2)]
    tr = [rot(p) for p in track]
    pr = [rot(p) for p in pit]

    # Neither source promises anything about direction. The centreline's vertex
    # order is whatever the mapper drew, and OSM way direction is not racing
    # direction — Monaco's pit lane is stored against the flow. Both get checked
    # against how the circuit is actually driven, and corrected here rather than
    # assumed in the renderer.
    #
    # Screen space is y-down, so a positive shoelace area reads as clockwise.
    area = 0.5 * sum(tr[i][0] * tr[(i + 1) % n][1] - tr[(i + 1) % n][0] * tr[i][1]
                     for i in range(n))
    if (area > 0) != (DIRECTION[key] == "cw"):
        tr.reverse()
        print(f"    reversed centreline to run {DIRECTION[key]}", flush=True)

    m = len(pr) // 2
    ptx, pty = pr[m][0] - pr[m - 1][0], pr[m][1] - pr[m - 1][1]
    ni = min(range(n), key=lambda i: (tr[i][0] - pr[m][0]) ** 2 + (tr[i][1] - pr[m][1]) ** 2)
    ttx, tty = tr[(ni + 1) % n][0] - tr[ni][0], tr[(ni + 1) % n][1] - tr[ni][1]
    if ptx * ttx + pty * tty < 0:
        pr.reverse()
        print("    reversed pit lane to follow the racing direction", flush=True)

    # ---- start/finish, on the already direction-corrected centreline ----
    #
    # Where OSM names the start line, that wins outright. Everywhere else the
    # line is bracketed by the pit lane: entry leaves the track before it, exit
    # rejoins after it, so the line lies between the two. Projecting the pit
    # lane's own midpoint instead — the previous approach — drifts wherever the
    # entry road curves in, which at Monaco was 250 m of a 3.3 km lap.
    def nearest(p):
        return min(range(n), key=lambda i: (tr[i][0] - p[0]) ** 2 + (tr[i][1] - p[1]) ** 2)

    if key in START_NODES:
        slat, slon = START_NODES[key]
        node_m = to_metres([(slon, slat)], lat0, lon0)[0]
        start_i = nearest(rot(node_m))
        how = "OSM-Knoten"
    else:
        entry, exit_ = nearest(pr[0]), nearest(pr[-1])
        span = (exit_ - entry) % n
        start_i = (entry + span // 2) % n
        how = f"zwischen Einfahrt {entry} und Ausfahrt {exit_}"

    # Back to lat/lon purely so the result can be eyeballed against a map.
    ct2, st2 = math.cos(theta), math.sin(theta)
    bx = tr[start_i][0] * ct2 - tr[start_i][1] * st2 + mx
    by = tr[start_i][0] * st2 + tr[start_i][1] * ct2 + my
    sf_lat = lat0 - math.degrees(by / R)
    sf_lon = lon0 + math.degrees(bx / (R * math.cos(math.radians(lat0))))

    xs = [p[0] for p in tr] + [p[0] for p in pr]
    ys = [p[1] for p in tr] + [p[1] for p in pr]

    out[key] = {
        "name": props.get("Name"), "location": props.get("Location"), "tz": tz,
        "lengthKm": round(length / 1000, 3),
        "lat": round(lat0, 5), "lon": round(lon0, 5), "rot": round(-theta, 6),
        "minX": round(min(xs), 1), "minY": round(min(ys), 1),
        "spanX": round(max(xs) - min(xs), 1), "spanY": round(max(ys) - min(ys), 1),
        "startIdx": start_i, "pitName": best["name"], "pitLenM": round(best["len"]),
        "points": tr, "pit": pr,
    }
    print(f"  -> {props.get('Name')}: {length/1000:.3f} km, "
          f"{max(xs)-min(xs):.0f}x{max(ys)-min(ys):.0f} m, "
          f"pit '{best['name'] or '(unnamed)'}' {best['len']:.0f} m\n"
          f"     S/F {sf_lat:.5f},{sf_lon:.5f}  ({how})\n", flush=True)

json.dump(out, open(DATA / "circuits.json", "w"), separators=(",", ":"))
print(f"wrote {DATA / 'circuits.json'}")
