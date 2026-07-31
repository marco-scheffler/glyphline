# Circuit data

Regenerates `Glyphline/Resources/agentverse/*.json`. Everything here is offline
after one run; the app never fetches anything.

| Script | Produces | Source |
|---|---|---|
| `build_circuits.py` | `circuits.json` | centrelines from bacinger/f1-circuits (MIT); pit lanes, start/finish from OpenStreetMap (ODbL) |
| `build_scenery.py` | `scenery.json` | building footprints, water, woodland from OpenStreetMap (ODbL) |
| `build_terrain.py` | `terrain.json` | Mapzen/AWS terrarium elevation tiles |
| `build_sea.py` | patches `terrain.json` | coastlines from OpenStreetMap (ODbL) |
| `build_corners.py` | `corners.json` | named corners from OpenStreetMap (ODbL) |

Run in that order; each caches its network responses beside itself, so a rerun
after a failure is cheap. Overpass is slow and rate-limits — a full run took over
an hour and hit repeated 504s.

## Two rules that are not obvious

**Picking the pit lane.** Selecting by length picks Spa's support paddock
(1 201 m) over its real pit lane (720 m); selecting by proximity keeps it, because
the paddock hugs the circuit too. What separates them is the name: a venue running
several layouts labels the secondary ones, so the primary lane is the one left
plain or unnamed.

**Direction.** Neither source promises anything about direction. The centreline's
vertex order is whatever the mapper drew, and OSM way direction is not racing
direction — Monaco's pit lane is stored against the flow. Both are checked against
how each circuit is actually driven (clockwise everywhere except Las Vegas) and
corrected in the data, never assumed by the renderer.

## Design mockup and screenshot harness

Not part of the data pipeline. `assemble.py` splices `scene.js`, `lighting.js`
and the data into `template2.html` to produce a standalone browser mockup of the
map, and `shot.mjs` / `diffshot.mjs` render it deterministically under Playwright
— `shot.mjs --check` renders each frame twice and compares hashes. That check is
what caught a non-determinism the unit suite was green through, which is why it
is kept here rather than thrown away after the design settled.
