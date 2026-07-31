/* ===================== Licht und Farbe ===================== */
/*
 * Arbeitsraum linear, Ausgabe sRGB, dazwischen ein filmisches Tonemapping.
 *
 * Vorher wurden sRGB-Werte direkt miteinander multipliziert. Das ist der Fehler,
 * der eine Szene "nach Spielzeug" aussehen lässt: Licht addiert sich in einem
 * Raum, in dem 128 nicht die Hälfte von 255 ist, und ohne Tonemapping clippt
 * alles Helle hart auf Weiss. Monacos helle Kulisse hat das zuerst gezeigt.
 *
 * Jetzt: Albedo und Lichtfarben nach linear, dort rechnen, mit einer einzigen
 * Belichtung skalieren, durch die ACES-Kurve, zurück nach sRGB. Highlights
 * laufen weich aus, Tiefen behalten Zeichnung.
 *
 * Die Nacht wird nicht mehr per Gammakurve aufgehellt, sondern über die
 * Belichtung — also so, wie eine Kamera es täte. Das Tonemapping verhindert
 * dabei, dass die Fensterlichter ausbrennen.
 */

function smooth(a, b, x) { const t = Math.max(0, Math.min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t); }
function mixRGB(a, b, t) { return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]; }

/* sRGB 0..255 -> linear 0..1, als Tabelle, weil das pro Wand und pro
   Geländezelle aufgerufen wird. */
const S2L = new Float32Array(256);
for (let i = 0; i < 256; i++) {
  const v = i / 255;
  S2L[i] = v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
}
function toLin(c) { return [S2L[c[0] | 0] || 0, S2L[c[1] | 0] || 0, S2L[c[2] | 0] || 0]; }
function linToSrgb(v) {
  v = v <= 0 ? 0 : v;
  return 255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055);
}
/* ACES, Näherung nach Narkowicz. Eine Zeile, und sie erledigt genau das, was
   ohne sie fehlt: der Übergang ins Weiss wird eine Kurve statt einer Kante. */
function aces(x) {
  const a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
  const y = (x * (a * x + b)) / (x * (c * x + d) + e);
  return y < 0 ? 0 : y > 1 ? 1 : y;
}
/* Der eine Ausgang aus dem linearen Raum. Alles Sichtbare geht hier durch. */
function encode(L, lin) {
  const E = L.exposure;
  return [linToSrgb(aces(lin[0] * E)), linToSrgb(aces(lin[1] * E)), linToSrgb(aces(lin[2] * E))];
}
function css(c, alpha) {
  const q = v => Math.round(v < 0 ? 0 : v > 255 ? 255 : v);
  return `rgba(${q(c[0])},${q(c[1])},${q(c[2])},${alpha === undefined ? 1 : alpha})`;
}
/* Für Dinge, die schon als fertige Bildschirmfarbe gedacht sind (HUD, Linien):
   durch dieselbe Kurve, damit sie nicht neben der Szene stehen. */
function emissive(L, srgb, strength) {
  const lin = toLin(srgb).map(v => v * (strength === undefined ? 1 : strength));
  return encode(L, lin);
}

function sunTint(elDeg) {
  const e = Math.max(-6, elDeg);
  const warm = smooth(25, 0, e);
  const base = mixRGB([255, 250, 244], [255, 152, 66], warm);
  return mixRGB(base, [255, 100, 52], smooth(6, -2, e) * 0.6);
}
const MOON_TINT = [150, 178, 222];

function skyTint(elDeg, wx, night) {
  const e = elDeg;
  let c;
  if (e <= -12) c = [13, 20, 38];
  else if (e <= -4) c = mixRGB([13, 20, 38], [44, 50, 88], smooth(-12, -4, e));
  else if (e <= 2) c = mixRGB([44, 50, 88], [214, 128, 84], smooth(-4, 2, e));
  else if (e <= 12) c = mixRGB([214, 128, 84], [136, 184, 226], smooth(2, 12, e));
  else c = mixRGB([136, 184, 226], [86, 152, 214], smooth(12, 55, e));
  if (wx === 'cloud') c = mixRGB(c, night > .5 ? [34, 40, 54] : [104, 112, 126], .58);
  if (wx === 'rain') c = mixRGB(c, night > .5 ? [26, 32, 44] : [62, 70, 82], .78);
  if (wx === 'fog') c = mixRGB(c, night > .5 ? [46, 54, 68] : [168, 176, 186], .70);
  return c;
}

const WEATHER = {
  clear: { direct: 1.00, diffuse: 1.00, shadow: 1.00, blur: 0.10 },
  cloud: { direct: 0.34, diffuse: 1.18, shadow: 0.34, blur: 0.55 },
  rain:  { direct: 0.10, diffuse: 1.02, shadow: 0.10, blur: 0.85 },
  fog:   { direct: 0.16, diffuse: 1.12, shadow: 0.14, blur: 0.90 },
};

const NIGHT_FLOOR = 0.22;
const MOON_ELEV = 34;
/* Die eine Belichtung. Nicht über Materialien verteilt — genau ein Regler. */
const EXPOSURE = 1.05;
const NIGHT_EXPOSURE = 2.6;

function lighting(elDeg, azRad, mapRot, wx) {
  const W = WEATHER[wx] || WEATHER.clear;
  const el = elDeg;
  const night = smooth(6, -6, el);

  const above = Math.max(0, Math.sin(el * Math.PI / 180));
  const extinct = smooth(-2.5, 7, el);
  const directSun = above * extinct * W.direct;
  const directMoon = 0.14 * night * W.direct;
  const direct = Math.max(directSun, directMoon);

  const dayDiffuse = 0.10 + 0.42 * smooth(-9, 14, el);
  const diffuse = Math.max(dayDiffuse, NIGHT_FLOOR) * W.diffuse;

  const wx0 = Math.sin(azRad), wy0 = -Math.cos(azRad);
  const sx = wx0 * Math.cos(mapRot) - wy0 * Math.sin(mapRot);
  const sy = wx0 * Math.sin(mapRot) + wy0 * Math.cos(mapRot);

  const keyElev = el > 2 ? el : MOON_ELEV * night + Math.max(2.2, el) * (1 - night);
  const shadowLen = Math.min(7.5, 1 / Math.tan(Math.max(2.2, keyElev) * Math.PI / 180));

  const sun = mixRGB(sunTint(el), MOON_TINT, night);
  const sky = skyTint(el, wx, night);
  const amb = mixRGB(mixRGB(sky, [150, 170, 200], .35), [104, 130, 176], night * .75);

  const L = {
    el, keyElev, direct, diffuse, sun, sky, amb,
    sunL: toLin(sun), ambL: toLin(amb), skyL: toLin(sky),
    exposure: EXPOSURE * (1 + NIGHT_EXPOSURE * night),
    sunX: sx, sunY: sy,
    shadowDirX: -sx, shadowDirY: -sy,
    shadowLen,
    shadowAlpha: Math.max(0.13 * night, (0.16 + 0.40 * smooth(0, 22, el))) * W.shadow,
    shadowBlur: Math.max(W.blur, night * .5),
    wet: wx === 'rain',
    dark: el < 0.5, wx, night,
  };
  // Der Himmel ist selbst eine Lichtquelle und geht durch dieselbe Kurve wie
  // alles andere — sonst steht er neben der Szene statt in ihr.
  L.skyC = encode(L, L.skyL);
  return L;
}

/* Lambert für eine senkrechte Wand — jetzt im linearen Raum. */
function shadeWall(L, nx, ny, albedo) {
  const A = toLin(albedo);
  const cosEl = Math.cos(Math.max(0, L.keyElev) * Math.PI / 180);
  const lambert = Math.max(0, nx * L.sunX + ny * L.sunY) * cosEl;
  const kd = L.diffuse * 0.74, ks = L.direct * lambert;
  return encode(L, [A[0] * (L.ambL[0] * kd + L.sunL[0] * ks),
                    A[1] * (L.ambL[1] * kd + L.sunL[1] * ks),
                    A[2] * (L.ambL[2] * kd + L.sunL[2] * ks)]);
}

/* Ein Dach schaut nach oben: voller Himmel, Sonne nach ihrem Sinus. */
function shadeRoof(L, albedo) {
  const A = toLin(albedo);
  const sinEl = Math.max(0, Math.sin(Math.max(0, L.keyElev) * Math.PI / 180));
  const ks = L.direct * sinEl;
  return encode(L, [A[0] * (L.ambL[0] * L.diffuse + L.sunL[0] * ks),
                    A[1] * (L.ambL[1] * L.diffuse + L.sunL[1] * ks),
                    A[2] * (L.ambL[2] * L.diffuse + L.sunL[2] * ks)]);
}
