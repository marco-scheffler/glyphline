#!/usr/bin/env node
/* Deterministischer Screenshot-Lauf.
 *
 * node shot.mjs <datei.html> <ausgabeordner> [--check]
 *
 * Rendert das Regressionsset. Mit --check wird jedes Bild zweimal gerendert und
 * der Hash verglichen — das Akzeptanzkriterium aus Abschnitt 2. Ohne diesen
 * Nachweis ist jeder Vorher/Nachher-Vergleich wertlos, weil die Abweichung auch
 * vom Zufall kommen könnte.
 */
import { chromium } from 'playwright';
import { createHash } from 'crypto';
import { mkdirSync, writeFileSync, readFileSync } from 'fs';
import { resolve, basename } from 'path';

const file = resolve(process.argv[2] ?? 'out.html');
const outDir = resolve(process.argv[3] ?? 'shots');
const CHECK = process.argv.includes('--check');
mkdirSync(outDir, { recursive: true });

/* Presets, die die Aussagen der Szene abdecken: Stadt mit vielen Fassaden,
   Wald mit Gelände, Nacht, Regen, hohe Sonne. */
const PRESETS = [
  { name: 'monaco-tag',    track: 'monaco', min: 13 * 60 + 30, wx: 'clear' },
  { name: 'monaco-abend',  track: 'monaco', min: 20 * 60 + 10, wx: 'clear' },
  { name: 'monaco-nacht',  track: 'monaco', min: 1 * 60,       wx: 'clear' },
  { name: 'spa-regen',     track: 'spa',    min: 17 * 60,      wx: 'rain'  },
  { name: 'spa-tag',       track: 'spa',    min: 12 * 60,      wx: 'clear' },
  { name: 'suzuka-nacht',  track: 'suzuka', min: 3 * 60 + 56,  wx: 'cloud' },
  { name: 'monza-mittag',  track: 'monza',  min: 12 * 60 + 30, wx: 'clear' },
  { name: 'vegas-nacht',   track: 'vegas',  min: 22 * 60,      wx: 'clear' },
];

const url = (p) =>
  `file://${file}?track=${p.track}&min=${p.min}&wx=${p.wx}&frame=600&seed=1&hud=off`;

/* Software-Rasterisierung erzwingen. Mit GPU wichen zwei Läufe um 6 von 3 Mio.
 * Pixeln ab — Kantenglättung der dünnen Regenlinien, nicht die Szene. Für einen
 * Vorher/Nachher-Vergleich muss die Abweichung aber allein aus der Änderung
 * kommen, sonst misst man das Rauschen mit. */
const browser = await chromium.launch({
  headless: true, channel: 'chrome',
  args: ['--disable-gpu', '--disable-gpu-rasterization', '--disable-partial-raster',
         '--disable-skia-runtime-opts', '--force-color-profile=srgb',
         '--disable-lcd-text', '--deterministic-mode', '--run-all-compositor-stages-before-draw'],
});
const page = await browser.newPage({
  viewport: { width: 1500, height: 900 },
  deviceScaleFactor: 2,
});

async function shoot(p) {
  await page.goto(url(p), { waitUntil: 'load' });
  await page.waitForFunction('window.__READY__ === true', null, { timeout: 60000 });
  const el = await page.$('.zx-stage');
  return await el.screenshot();
}

const rows = [];
for (const p of PRESETS) {
  const buf = await shoot(p);
  const hash = createHash('sha256').update(buf).digest('hex').slice(0, 12);
  writeFileSync(`${outDir}/${p.name}.png`, buf);
  let det = '';
  if (CHECK) {
    const again = await shoot(p);
    const h2 = createHash('sha256').update(again).digest('hex').slice(0, 12);
    det = h2 === hash ? '  deterministisch' : `  ABWEICHUNG (${h2})`;
  }
  rows.push({ name: p.name, hash, bytes: buf.length, det });
  console.log(`${p.name.padEnd(15)} ${hash}  ${(buf.length / 1024).toFixed(0).padStart(4)} KB${det}`);
}

writeFileSync(`${outDir}/hashes.json`,
  JSON.stringify(Object.fromEntries(rows.map(r => [r.name, r.hash])), null, 1));
await browser.close();

const bad = rows.filter(r => r.det.includes('ABWEICHUNG')).length;
console.log(bad ? `\n${bad} Presets sind nicht reproduzierbar.` :
  CHECK ? '\nAlle Presets reproduzierbar (gleicher Hash bei zwei Läufen).' : '');
