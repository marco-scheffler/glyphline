/* ===================== Kulisse aus echten Daten ===================== */
/* Kein Baustein wird erfunden. Jedes Gebäude ist ein OSM-Grundriss mit seiner
   getaggten Höhe, jede Wasser- und Waldfläche ein OSM-Polygon, das Gelände ein
   SRTM-Höhenmodell.

   Die Extrusion ist eine Schrägprojektion: was hoch liegt, rutscht im Bild nach
   oben. Das gilt für die Bauhöhe und für die Geländehöhe gleichermassen —
   deshalb klettert Monacos Stadt den Hang hinauf und Eau Rouge steigt sichtbar
   an, statt flach dazuliegen. */

const LEAN = 0.62;

function ringArea(r) {
  let a = 0;
  for (let i = 0, n = r.length; i < n; i++) {
    const j = (i + 1) % n;
    a += r[i][0] * r[j][1] - r[j][0] * r[i][1];
  }
  return a * 0.5;
}

/* Bilineare Abfrage im Höhengitter, in Metern des gedrehten Rahmens. */
function elevAt(T, x, y) {
  if (!T) return 0;
  const u = (x - T.minX) / (T.maxX - T.minX) * (T.gw - 1);
  const v = (y - T.minY) / (T.maxY - T.minY) * (T.gh - 1);
  const iu = Math.max(0, Math.min(T.gw - 2, Math.floor(u)));
  const iv = Math.max(0, Math.min(T.gh - 2, Math.floor(v)));
  const fu = Math.max(0, Math.min(1, u - iu)), fv = Math.max(0, Math.min(1, v - iv));
  const g = T.grid, w = T.gw;
  const a = g[iv * w + iu] * (1 - fu) + g[iv * w + iu + 1] * fu;
  const b = g[(iv + 1) * w + iu] * (1 - fu) + g[(iv + 1) * w + iu + 1] * fu;
  return a * (1 - fv) + b * fv;
}

/* Geländeschattierung: die Normale kommt aus dem Gefälle des Höhengitters,
   beleuchtet wird mit derselben Sonne wie jede Hauswand. */
function drawTerrain(c, T, L, ground, x0, y0, x1, y1) {
  if (!T) return;
  const gw = T.gw, gh = T.gh, g = T.grid;
  const off = document.createElement('canvas');
  off.width = gw; off.height = gh;
  const octx = off.getContext('2d');
  const img = octx.createImageData(gw, gh);
  const d = img.data;
  const mx = (T.maxX - T.minX) / gw, my = (T.maxY - T.minY) / gh;
  const range = Math.max(1, T.hi - T.lo);
  const gl = toLin(ground);
  const sinEl = Math.max(0.05, Math.sin(Math.max(0, L.keyElev) * Math.PI / 180));
  const cosEl = Math.cos(Math.max(0, L.keyElev) * Math.PI / 180);

  const sea = T.sea || null;
  // Tiefes Wasser schluckt fast alles; was man sieht, ist der gespiegelte
  // Himmel plus die Sonnenbahn darauf.
  const WATER = toLin([9, 26, 42]);

  for (let y = 0; y < gh; y++) {
    for (let x = 0; x < gw; x++) {
      const idx = y * gw + x;
      let col;
      if (sea && sea[idx]) {
        // Wellenkräuselung als Normalenstörung, damit die Sonnenbahn eine Bahn
        // wird und kein Fleck
        const rip = Math.sin(x * 0.55 + y * 0.31) * 0.10 + Math.sin(x * 0.17 - y * 0.44) * 0.07;
        const nx = rip, ny = rip * 0.6, nz = 1;
        const nl = Math.sqrt(nx * nx + ny * ny + 1);
        const hdotn = Math.max(0, (nx / nl) * L.sunX * cosEl + (ny / nl) * L.sunY * cosEl + (nz / nl) * sinEl);
        const glint = Math.pow(hdotn, 90) * L.direct * 5.0;
        const refl = 0.34 + 0.22 * (1 - sinEl);      // flacher Blick spiegelt mehr
        col = encode(L, [WATER[0] * L.ambL[0] * L.diffuse + L.skyL[0] * refl * L.diffuse + L.sunL[0] * glint,
                         WATER[1] * L.ambL[1] * L.diffuse + L.skyL[1] * refl * L.diffuse + L.sunL[1] * glint,
                         WATER[2] * L.ambL[2] * L.diffuse + L.skyL[2] * refl * L.diffuse + L.sunL[2] * glint]);
      } else {
        const xm = Math.max(0, x - 1), xp = Math.min(gw - 1, x + 1);
        const ym = Math.max(0, y - 1), yp = Math.min(gh - 1, y + 1);
        const dzdx = (g[y * gw + xp] - g[y * gw + xm]) / ((xp - xm) * mx);
        const dzdy = (g[yp * gw + x] - g[ym * gw + x]) / ((yp - ym) * my);
        // Normale (-dz/dx, -dz/dy, 1), normiert
        const len = Math.sqrt(dzdx * dzdx + dzdy * dzdy + 1);
        const nx = -dzdx / len, ny = -dzdy / len, nz = 1 / len;
        const lambert = Math.max(0, nx * L.sunX * cosEl + ny * L.sunY * cosEl + nz * sinEl);
        const h = (g[idx] - T.lo) / range;
        // Höhe hellt leicht auf — Kuppen fangen mehr Himmel
        const tint = 0.90 + h * 0.22;
        const kd = L.diffuse * tint, ks = L.direct * lambert;
        // dieselbe lineare Pipeline wie für Wände und Dächer
        col = encode(L, [gl[0] * (L.ambL[0] * kd + L.sunL[0] * ks),
                         gl[1] * (L.ambL[1] * kd + L.sunL[1] * ks),
                         gl[2] * (L.ambL[2] * kd + L.sunL[2] * ks)]);
      }
      const i = idx * 4;
      d[i] = col[0]; d[i + 1] = col[1]; d[i + 2] = col[2]; d[i + 3] = 255;
    }
  }
  octx.putImageData(img, 0, 0);
  c.save();
  c.imageSmoothingEnabled = true;
  c.imageSmoothingQuality = 'high';
  c.drawImage(off, x0, y0, x1 - x0, y1 - y0);
  c.restore();
}

/* Einmal pro Strecke und Fenstergrösse. Pro Bild wäre das für Monacos 951
   Gebäude nicht zu bezahlen. */
/* `map` trägt den Geländeversatz bereits in sich — jeder Punkt wird um seine
   eigene Höhe nach oben geschoben. Grundrisse scheren dadurch minimal mit dem
   Hang, was an einem Hang genau richtig ist. */
function prepareScene(scn, map, MPP) {
  const out = { buildings: [], areas: [] };
  if (!scn) return out;

  for (const a of scn.areas) {
    out.areas.push({ ring: a.p.map(map), k: a.k, a: a.a });
  }
  out.areas.sort((x, y) => y.a - x.a);

  for (let i = 0; i < scn.buildings.length; i++) {
    const b = scn.buildings[i];
    const ring = b.p.map(map);
    if (ringArea(ring) < 0) ring.reverse();
    let maxY = -Infinity;
    for (const p of ring) if (p[1] > maxY) maxY = p[1];
    // Eine Stadt hat nicht ein Grau. Dach- und Wandton werden aus dem Index
    // gehasht — deterministisch, also über Neustarts hinweg dasselbe Haus.
    const seed = (Math.imul(i + 1, 2654435761)) >>> 0;
    const v = (seed % 1000) / 1000;
    const warm = ((seed >>> 10) % 1000) / 1000;
    out.buildings.push({
      ring, h: b.h, lift: b.h * MPP * LEAN, maxY, seed,
      wall: [138 + v * 34, 131 + v * 32 - warm * 6, 121 + v * 30 - warm * 14],
      roof: [104 + v * 40, 99 + v * 36 - warm * 8, 93 + v * 32 - warm * 16],
    });
  }
  out.buildings.sort((a, b) => a.maxY - b.maxY);
  return out;
}

function fillRing(c, ring, dx, dy) {
  c.beginPath();
  c.moveTo(ring[0][0] + dx, ring[0][1] + dy);
  for (let i = 1; i < ring.length; i++) c.lineTo(ring[i][0] + dx, ring[i][1] + dy);
  c.closePath();
}

function buildingShadows(c, scene, L) {
  if (L.shadowAlpha < 0.02) return;
  c.save();
  c.globalAlpha = L.shadowAlpha;
  c.fillStyle = '#000';
  if (L.shadowBlur > 0.2 && c.filter !== undefined) c.filter = `blur(${(1.2 + L.shadowBlur * 4).toFixed(1)}px)`;
  for (const b of scene.buildings) {
    const len = b.lift / LEAN * L.shadowLen;
    const dx = L.shadowDirX * len, dy = L.shadowDirY * len * 0.55;
    const r = b.ring, n = r.length;
    c.beginPath();
    c.moveTo(r[0][0] + dx, r[0][1] + dy);
    for (let i = 1; i < n; i++) c.lineTo(r[i][0] + dx, r[i][1] + dy);
    c.closePath();
    for (let i = 0; i < n; i++) {
      const a = r[i], b2 = r[(i + 1) % n];
      c.moveTo(a[0], a[1]); c.lineTo(b2[0], b2[1]);
      c.lineTo(b2[0] + dx, b2[1] + dy); c.lineTo(a[0] + dx, a[1] + dy);
      c.closePath();
    }
    c.fill();
  }
  c.restore();
}

function drawBuildings(c, scene, L, MPP) {
  for (const b of scene.buildings) {
    const r = b.ring, n = r.length, lift = b.lift;

    for (let i = 0; i < n; i++) {
      const a = r[i], q = r[(i + 1) % n];
      const dx = q[0] - a[0], dy = q[1] - a[1];
      if (dx >= 0) continue;
      const len = Math.hypot(dx, dy) || 1;
      const nx = dy / len, ny = -dx / len;
      c.fillStyle = css(shadeWall(L, nx, ny, b.wall));
      c.beginPath();
      c.moveTo(a[0], a[1]); c.lineTo(q[0], q[1]);
      c.lineTo(q[0], q[1] - lift); c.lineTo(a[0], a[1] - lift);
      c.closePath(); c.fill();

      if (L.night > 0.05 && lift > 4) {
        const cols = Math.max(1, (len / (5.4 * MPP)) | 0);
        const rows = Math.max(1, (lift / (3.4 * MPP)) | 0);
        const ux = dx / cols, uy = dy / cols, vy = lift / rows;
        for (let ci = 0; ci < cols; ci++) for (let ri = 0; ri < rows; ri++) {
          const hsh = (b.seed ^ (ci * 73856093) ^ (ri * 19349663)) >>> 0;
          if ((hsh % 100) > 46) continue;
          const wx0 = a[0] + ux * (ci + .28), wy0 = a[1] + uy * (ci + .28);
          c.fillStyle = css(emissive(L, [255, 200 + (hsh % 40), 140 + (hsh % 50)], .55),
                            .34 + .52 * L.night);
          c.fillRect(wx0, wy0 - lift + ri * vy + vy * .30,
                     Math.max(1, Math.abs(ux) * .44), Math.max(1, vy * .38));
        }
      }
    }

    c.fillStyle = css(shadeRoof(L, b.roof));
    fillRing(c, r, 0, -lift); c.fill();
    if (lift > 2.5) {
      c.strokeStyle = `rgba(0,0,0,${.10 + .12 * L.diffuse})`;
      c.lineWidth = Math.max(.5, MPP * .35); c.stroke();
    }
  }
}

function drawAreas(c, scene, L, MPP, t) {
  for (const a of scene.areas) {
    if (a.k === 'water') {
      const lit = shadeRoof(L, L.night > .5 ? [26, 44, 78] : [40, 92, 130]);
      c.fillStyle = css([lit[0] * 1.2, lit[1] * 1.2, lit[2] * 1.35]);
      fillRing(c, a.ring, 0, 0); c.fill();
      c.save(); c.clip();
      c.strokeStyle = `rgba(255,246,224,${.03 + .13 * L.direct})`;
      c.lineWidth = Math.max(1, MPP * .8);
      let minY = Infinity, maxY = -Infinity;
      for (const p of a.ring) { if (p[1] < minY) minY = p[1]; if (p[1] > maxY) maxY = p[1]; }
      for (let y = minY; y < maxY; y += 7 * Math.max(1, MPP)) {
        const w = Math.sin(t * .55 + y * .09) * 3 * Math.max(1, MPP);
        c.beginPath(); c.moveTo(-9999, y + w); c.lineTo(9999, y + w); c.stroke();
      }
      c.restore();
    } else if (a.k === 'wood') {
      c.fillStyle = css(shadeRoof(L, [58, 84, 46]));
      fillRing(c, a.ring, 0, 0); c.fill();
      c.save(); c.clip();
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
      for (const p of a.ring) {
        if (p[0] < minX) minX = p[0]; if (p[0] > maxX) maxX = p[0];
        if (p[1] < minY) minY = p[1]; if (p[1] > maxY) maxY = p[1];
      }
      const step = Math.max(5, 9 * MPP);
      const crown = shadeRoof(L, [88, 124, 62]);
      const dark = shadeRoof(L, [34, 52, 28]);
      let k = 0;
      for (let y = minY; y < maxY; y += step) for (let x = minX; x < maxX; x += step) {
        const h = ((k++ * 2654435761) >>> 0);
        const jx = x + (h % 100) / 100 * step, jy = y + ((h >> 7) % 100) / 100 * step;
        const rr2 = step * (.36 + (h % 37) / 120);
        c.fillStyle = css(dark, .55);
        c.beginPath(); c.arc(jx + L.shadowDirX * rr2 * .5, jy + L.shadowDirY * rr2 * .3, rr2, 0, 7); c.fill();
        c.fillStyle = css(crown, .9);
        c.beginPath(); c.arc(jx, jy - rr2 * .25, rr2 * .82, 0, 7); c.fill();
      }
      c.restore();
    } else {
      c.fillStyle = css(shadeRoof(L, [98, 120, 70]), .88);
      fillRing(c, a.ring, 0, 0); c.fill();
    }
  }
}
