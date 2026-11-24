#!/usr/bin/env node
// Drive the browser client's database path from Node (port of CedarDB SQLDoom's scripts/web_smoke.mjs):
// through doom_web.py, sign in as a player account with the same oraws.js the page uses, claim a
// slot, send 35 Hz input and pull camera+frame pairs for a few seconds; report frames per second,
// the camera+frame round trip, the tic round trip, bytes per frame. Exit 0 on success.
//
//   node oracle/tests/web_smoke.mjs ws://127.0.0.1:8080/ws USER PASSWORD [seconds] [--json out.json]
import { OraConnection, bytes } from '../client/web/oraws.js';
import { writeFileSync } from 'node:fs';

const args = process.argv.slice(2);
const jsonAt = args.indexOf('--json');
const jsonOut = jsonAt >= 0 ? args.splice(jsonAt, 2)[1] : null;
const [url, user, password, secondsArg] = args;
if (!url || !user || password === undefined) {
  console.error('usage: web_smoke.mjs <ws url> <user> <password> [seconds] [--json out.json]');
  process.exit(2);
}
const seconds = parseFloat(secondsArg || '5');
const db = new OraConnection(url);
let done = false;
db.onclose = (err) => { if (!done) { console.error('closed early:', err.message); process.exit(1); } };
try {
  await db.connect({ user, password });
} catch (err) {
  console.error(`sign-in failed: ${err.message}`);
  process.exit(1);
}
console.log(`signed in as ${db.user}`);
let thing = -1;
for (let i = 0; i < 30 && thing < 0; i++) {
  thing = parseInt((await db.run([{ name: 'join' }]))[0].value, 10);
  if (thing < 0) await new Promise((r) => setTimeout(r, 1000));
}
if (thing < 0) { console.error('no free slot'); process.exit(1); }
const slot = parseInt((await db.run([{ name: 'slot' }]))[0].value, 10);
console.log(`joined: thing ${thing}, slot ${slot}`);
const [pal, snd, mus] = await db.run([{ name: 'palettes' }, { name: 'sounds_all' }, { name: 'music' }]);
const sndBytes = snd.rows.reduce((n, r) => n + bytes(r[1]).length, 0);
console.log(`palette rows ${pal.rows.length}, sounds ${snd.rows.length} (${sndBytes} bytes), music ${mus.rows.length ? mus.rows[0][0] + (mus.rows[0][1] ? ' (rendered)' : ' (MIDI only)') : 'none'}`);

let frames = 0, bytesIn0 = db.bytesIn, first = null, rtt = [], tics = 0, ticRtt = [], events = 0;
let lastEvent = parseInt((await db.run([{ name: 'events_max' }]))[0].rows[0][0], 10);
const t0 = performance.now();
const ticker = setInterval(async () => {
  const s = performance.now();
  try {
    const cmd = process.env.DOOM_STILL ? [0, 0, false, 0, false, null, false] : [1, 0, false, 2.0, tics % 20 === 0, null, false];
    const [, , ev] = await db.run([{ name: 'input', params: cmd }, { name: 'me' }, { name: 'events', params: [lastEvent] }, { name: 'loops' }]);
    for (const r of ev.rows) { lastEvent = Math.max(lastEvent, r[0]); events++; }
    ticRtt.push(performance.now() - s); tics++;
  } catch (e) { /* closing */ }
}, 1000 / 35);
while (performance.now() - t0 < seconds * 1000) {
  const f0 = performance.now();
  const fr = await db.frame({ alpha: 0.5 });
  rtt.push(performance.now() - f0);
  if (!fr.indices) { console.error('empty frame: slot lost'); process.exit(1); }
  if (first === null) first = fr;
  frames++;
}
clearInterval(ticker);
const automap = await db.frame({ alpha: 1, automap: true, am: [{ name: 'am_zoom', params: [1.25] }] });
const elapsed = (performance.now() - t0) / 1000;
const stat = (v) => { const s = [...v].sort((a, b) => a - b); return { mean: +(s.reduce((a, b) => a + b, 0) / s.length).toFixed(2), p50: +s[Math.floor(s.length / 2)].toFixed(2), p95: +s[Math.floor(s.length * 0.95)].toFixed(2) }; };
const distinct = new Set(first.indices).size;
const out = {
  frames, seconds: +elapsed.toFixed(2), fps: +(frames / elapsed).toFixed(1), frame_rtt_ms: stat(rtt),
  tics, tic_rtt_ms: stat(ticRtt), sound_events: events,
  wire_bytes_per_frame_after_delta: Math.round((db.bytesIn - bytesIn0) / Math.max(1, frames)),
  first_frame_distinct_indices: distinct, palette: first.pal, automap: automap.kind,
};
console.log(JSON.stringify(out));
if (jsonOut) writeFileSync(jsonOut, JSON.stringify(out, null, 1));
done = true;
db.close();
process.exit(frames > 0 && distinct > 8 && automap.kind === 'automap' ? 0 : 1);
