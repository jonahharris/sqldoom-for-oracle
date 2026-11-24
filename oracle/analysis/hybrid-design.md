# Hybrid renderer design (H27): SQL for state, PL/SQL for geometry and pixels

## Goal and result
Same frames as the pixel-exact SQL renderer (`render_optimized.sql`, itself equal to the CedarDB
SQLDoom reference) at ~30 FPS on Oracle AI Database 26ai Free (2 CPUs), every frame ≤ 33 ms.
Result (round 2): **1200/1200 tics pixel-exact**, **22.3 ms** hot median per frame (pure SQL:
143 ms), **45.9 FPS** sustained end to end over the TPC-DOOM run (`benchmark/bench.py`, mean 21.8,
p95 29.0, p99 30.5, max 32.2 ms, **100% of frames ≤ 33 ms**). Details and every experiment:
`optimization-log.md`, sections "Hybrid renderer (H27)" and "Hybrid round 2". Round 3 (memory,
section "Hybrid memory / shared cache"): per-session package state 91.5 → 68.5–70 MB, first frame
352 → 139–151 ms, `final_hybrid_r3` mean 21.0, p95 27.9, max 31.6 ms, 47.6 FPS, 1200/1200 exact.

## Interface (unchanged for all tools)
`sql/render_hybrid.sql` is one prepared SELECT with the usual binds:
`SELECT y, pal, hex FROM TABLE(doom_hybrid.render_frame(:tic, :map_id, :player_id, :skill, :px, :py, :pz, :pangle))`
— 200 rows, `hexrows` encoding (640 hex characters = 320 palette indices per row). Round 4 added
two optional parameters `p_x0, p_x1` (default 0, 319): only those screen columns are rasterised
and output (rows of 2·(x1−x0+1) hex chars); `sql/render_hybrid_split.sql` binds them and
`client/doomora.SplitRenderer` renders one frame as two column ranges on two sessions in parallel
(Oracle Free: 2 CPUs, no parallel query), joining the halves of each row. BSP order, the player
sector, every depth key and the sprite tie test are computed exactly as for the full frame, so
any split is pixel-identical (verified 1200/1200 with the adaptive split and at fixed columns
77 and 141). The package is
`sql/06_hybrid.sql`, installed by `client/install_hybrid.py` (also the last step of
`client/setup_db.py`).

## Boundary: what runs where, and why
| SQL (per frame, 4 statements) | PL/SQL (per frame) | Static package cache (per map, first call) |
|---|---|---|
| player/weapon/HUD state, palette number, owned-weapon bitmask; sectors + animated-light formulas; seg texture overrides; `thing_view` (12-table join, depth/side, `ATAN2` rotation) | pose conversion; BSP traversal (keep/front/order); seg cull, transform, near clip, projection; wall parts; solid occlusion; wall columns (z-tested and shaded as generated); visplane clip windows and spans; exact z-buffer with interval-level culling; texturing, lighting, COLORMAP; sprite frame choice and bounds; weapon, message, status bar; hex rows | BSP nodes and child pointers/boxes; segs with texture codes; texel arrays (wall textures lazily per column, flats/sprite lumps per lump); COLORMAP; sprite_frames; HUD patches and background; lookup tables (incl. column ray angles) |

SQL keeps what it is good at: retrieving and joining the tic's game state (a few hundred rows).
Everything whose cost grows with geometry or pixels moved to PL/SQL, because Oracle charges
1–3 µs per row per SQL stage while interpreted PL/SQL costs 5–50 ns per operation. Nothing
camera-, tic- or frame-specific is cached; buffers are reset every frame.

## Pipeline (PL/SQL)
1. **Camera**: CedarDB's text→float8 pose conversion in NUMBER math, then `COS/SIN` once.
2. **BSP**: front-first depth-first traversal from the root with an explicit stack. At a reached
   node: front side with half-even `ROUND`, support-function frustum test of its two child boxes,
   push back child then front child. The reference's order statistic rank(leaf) = 1 +
   Σ[side ≠ front]·leaves(front child) is the leaf's position in this traversal, so visible
   subsectors come out in exact front-to-back order, numbered 1..n (the number is only compared).
3. **Segs → wall parts**: back-face cull, camera transform, near-plane clip, projection; the
   reference's 7-way unpivot (solid/upper/lower/midmask + 3 clip-only boundaries); per-column
   nearest solid seg. Per seg and part everything column-independent is computed once (zt − pz,
   texture size/base, V origin term, stable key, light base, sort key).
4. **Wall columns, shaded as generated**: per (seg, column) the perspective-correct 1/z and u/z;
   per part the vertical extent (top z ≥ bottom z ⇒ ytf ≤ ybf) → a visplane panel (seg index,
   kind, depth, ytf, ybf, sort key; stored per column) and, for textured parts, a wall span that is
   immediately z-tested and shaded (texture column, V origin/step, light, constant key). The
   covered-band test (see 6) clips the span first. If the span's first and last texel rows lie in
   one texture period, the per-pixel `mod th` becomes a constant offset; magnified spans (step < 1)
   reuse the colour while the texel row repeats.
5. **Visplanes**: per column the panels are sorted by (depth_x, bsp_seq, part, seg_id) (insertion
   sort, near linear because BSP order is near depth order); camera-sector seed spans are emitted
   first; one sweep keeps the running ceiling/floor clip and the carried ceiling/floor (as a seg
   index) and emits the reference's plane spans. Panel spans of the camera sector's own floor or
   ceiling are clipped against the column's seed span of that plane (equal depth key there, and
   the seed's source 0 always beats source 1).
6. **Visibility**: a per-pixel z-buffer on the reference key. `ROUND(clamp(depth)·4096)·2^20 +
   ((2−surface)·4 + source)·2^16 + stable id` is < 2^49, so it is exact in one BINARY_DOUBLE. Ties:
   a wall key is unique within a column (seg, part), the class bits separate walls, sprites and
   planes, and equal plane keys mean the same sector, plane and source (same light and palette),
   so only sprite-vs-sprite ties need the reference's light/palette comparison; the owner array is
   written by the sprite pass only, and only for sprites whose key is not unique in the frame.
   **Interval-level culling (exact):** per column, rows 0..bt and bb..167 are covered contiguously
   by earlier wall spans and every pixel there has zq ≤ a band bound (zq only decreases); a wall
   span with a larger key skips its overlap with a band, a plane span skips it when its key —
   monotone on the plane's valid rows — exceeds the bound at both ends of the valid overlap.
   For planes the per-row depth, key, zlight and the depth-only plane terms depend only on the
   plane height and are tabulated once per height (valid side of the horizon, valid row range).
7. **Eager shading**: a fragment is textured, lit and COLORMAPped when it wins; winners ≈ pixels.
   Flats: `wx = (px + depth·cv) + (ta·depth)·sv` with the first term tabulated per row (same IEEE
   operations as the reference), mod-64 via tables, zlight via a clamp table.
8. **Sprites**: `thing_view` from SQL, frame choice and bounds in PL/SQL including the float4
   (`real + smallint`) tops; their fragments enter the same z-buffer. Magnified sprites (scale ≥ 2)
   fetch the texel once per run of equal texel rows and skip transparent runs.
9. **Overlays and output**: weapon psprite (flash over weapon), pickup message, status bar (template
   copy + digits/keys/arms/face), then 16 pixels per string statement into 640-char hex rows,
   `PIPE ROW` × 200.

## Round 4 (speed) in short
Wall texel rows: `f(y) = v0 + (y − ys)·step` is non-decreasing in y, so `FLOOR(f)` is recomputed
only when `f` reaches the next integer (magnified spans) and the texture-period base only when the
row enters the next period (cross-period spans). `LEAST/GREATEST` (26 ns in the interpreter) became
`IF` clamps in per-column and per-panel code; the visplane sort derives its tie key from (seg,
part kind) instead of storing it. Single session −4.6 % mean; split frame 13.1 ms mean, 17.4 p95.
Details: `optimization-log.md`, "Hybrid round 4 / game loop phase 2".

## Sprite modes (exact by default, vanilla opt-in)
`render_frame` / `render_frame_bd` take a last optional parameter `p_mode` (default 0). **0 =
CedarDB-exact**, the path described above: sprites enter the same z-buffer as walls and planes, so the
rows a sprite patch hangs below its foot (barrel BAR1 4 px, BON1 4, COLU 5 …) lose against the floor in
front of it and items look sunk into the floor (a reference departure from Doom,
[reference-analysis.md](reference-analysis.md)). Every SQL file (`render_hybrid.sql`,
`render_hybrid_split.sql`), test, recording and benchmark uses it; it is byte-identical to before.
**1 = vanilla sprites**, Doom's `R_DrawSprite` clipping: planes never occlude a sprite; a sprite column
is clipped by the silhouettes of the segs in front of it. The players' clients use it by default
([clients.md](clients.md)).

How mode 1 works, reusing the visplane sweep's structures:
* The sprite list (SQL `thing_view` + bounds) is built before the visplane sweep (in both modes; it
  depends on nothing the walls or planes compute). Per sprite: depth, foot z `gz` (its base z) and top
  z `gzt` (the float4 top), as vanilla's `vissprite_t`.
* Per seg, its silhouettes as `R_StoreWallRange` sets them: bottom applies to a sprite with `gz <
  h_vb` (`h_vb` = front floor if front floor > back floor; +∞ if the back floor is above the eye;
  −∞ otherwise; +∞ and "whole column" if the back ceiling ≤ front floor; a masked midtexture makes a
  missing silhouette +∞), top symmetrically with `gzt > h_vt`; one-sided segs clip the whole column.
* Per screen column, the sprites that cover it, in ascending depth. The walls are already in the
  z-buffer at this point, so a (sprite, column) whose box rows are all covered by nearer walls is closed
  right away (no sweep work, no raster).
* The visplane sweep visits each column's panels in depth order; in a column with sprites it also
  keeps Doom's running ceiling/floor clip with Doom's rules and rounding (`R_RenderSegLoop`): below an
  upper wall the first open row is `floor(bottom) + 1`, where only the ceiling ends at the seg
  (UPPER_OPEN, UPPER_FLUSH: `markceiling`) it is `ceil(top)`; above a lower wall the last open row is
  `ceil(top) − 1`, where only the floor ends (LOWER_DOWN: `markfloor`) `floor(bottom)`; an edge off
  the screen covers nothing. (The sweep's own `cc_max`/`fc_min` are the reference's visplane clips:
  they ignore UPPER_OPEN, clamp to row 1 and round the floor edge differently.) After every panel
  nearer than a sprite (per-column depth, the z-buffer's notion of "in front") whose seg's silhouette
  applies to it, the running clip becomes the sprite's clip in this column; the last one wins. That
  is exactly vanilla's snapshot of the farthest applicable drawseg in front of the sprite, which
  already contains every nearer seg's clip. A SOLID panel closes the column for every sprite behind it
  and ends the work. The extra work is per column with sprites and per panel up to the farthest of
  them, inside the sweep (exact mode pays one boolean test per panel).
* The sprites are drawn before the plane pass, z-tested against the walls (masked midtextures stay
  opaque walls, as in the reference) and against each other with the reference key and tie rule,
  within their clip window. A sprite pixel stores `key − 2^50` (< 0): the plane pass that follows never
  overwrites it, while every non-sprite pixel resolves exactly as in mode 0.

So mode 1 differs from mode 0 only on pixels where a sprite now covers a floor or ceiling — with
one deliberate exception: the reference gives a sky ceiling the farthest depth, so a sprite poking above
a *nearer* sky ceiling edge wins the z-test in mode 0, while Doom clips it by that edge's silhouette
(seen once, 1 pixel, in 80 shareware E1M1 test views; never in the TPC run);
`tests/vanilla_sprites_check.py` verifies that on every frame of the TPC run (and checks each added
pixel against an independent walk over the map, see below). Mode 2 (debug only) is mode 1 without the
silhouette clip, used by the check to show what the clip removes. `doom_hybrid.debug_info('zbuf' |
'sprites' | 'sectors')` exposes the last frame's z-buffer owners for the check.

## Exactness rules kept
IEEE BINARY_DOUBLE operation order identical to the reference everywhere (verified: PL/SQL
`COS/SIN/TAN/ATAN/ATAN2` = SQL, `ROUND(BINARY_DOUBLE)` half-even in both, BINARY_FLOAT arithmetic
= SQL on 814,592 sprite-top combinations); CedarDB pose conversion; `LEAST/GREATEST` NULL semantics
as explicit branches; 2.844444 sky constant; masked midtextures opaque; plane-depth cap for
carried planes; seed spans; reference tie-breaking of the depth key. A `NO_DATA_FOUND` inside the
pipelined function would silently end the row stream, so it is re-raised as ORA-20001.

## Platform note: native compilation
The brief asks for natively compiled PL/SQL. The units are compiled with `PLSQL_CODE_TYPE=NATIVE`
(recorded in `USER_PLSQL_OBJECT_SETTINGS`), but this Oracle Free build (linux/arm64) reports
`PLS-00924: native compilation is not supported on this platform` and runs them as interpreted
M-code: NATIVE 26.3 ms vs INTERPRETED 26.8 ms (noise). All optimizations therefore target the
interpreter: fewer statements and function calls, fewer double→integer conversions, table lookups
instead of integer `MOD`/division, work hoisted per run/span/height. On a platform with native
PL/SQL the same source compiles to machine code unchanged.

## Cost profile and limits
Mean per frame (6 sample tics, hot) / heaviest class (tic 577): walls geometry + wall shading
7.5 / 10.2 ms, plane shading 4.3 / 6.6, visplane sort + sweep 2.3 / 4.7, hex output 2.5, SQL state
+ sprites 1.3, everything else ≤ 0.6 each. The remaining cost is interpreter work per shaded pixel
(walls ≈ 100–130 ns, flats ≈ 200 ns, mostly array lookups) and per visplane panel (≈ 0.45 µs).
The heaviest scenes (≈ 6–8k panels, 2.5–3k plane spans, tics 500–590) run at 27–29 ms hot; over
the whole run every frame is ≤ 33 ms end to end (max 32.2 ms). Measured and rejected: full
per-column interval ownership (a streamlined z-test is only ≈ 18 ns per winner), horizontal flat
runs (−12% per pixel before span conversion; column-major buffers make row walks 1.7× slower),
texel reuse for flats, per-(height, light) tables, pre-hexed status-bar chunks, nested tables /
VARRAYs, `SIMPLE_*` types (`optimization-log.md`, "Hybrid round 2").

## Memory (per session) and sharing
All static data lives in package state, i.e. in each session's UGA/PGA: ≈ 30 B per INDEX BY
element whatever the value, ≈ 68 B per short string element. After the whole run a session holds
≈ 68–70 MB PGA (42 MB after the first frame): the texel store `g_tx` 1.30M elements ≈ 39 MB (wall
columns 0.65M + sky 32k, sprites 0.45M, flats 0.18M), wall hex rows (column-load source) ≈ 3 MB,
`g_hex2` 4.3 MB, z/frame buffers and their reset templates ≈ 6–7 MB, mod-64 tables 3.75 MB,
COLORMAP/status bar ≈ 1.6 MB, geometry and per-frame items ≈ 2 MB. Kept savings (round 3): wall
textures load per column on first touch (a run touches 55% of the columns of the textures it shows),
mod-64 tables over ±32768 with an exact per-row range check per plane height (spans outside use the
general exact path; none in the run), no unused z template. Not adopted because they cost speed:
denser texel encodings (+≈ 190 ns per texel read), 1-pixel hex table (+1–3%), texture eviction (reload
spikes), and sharing texels through the SGA (result cache, buffer-cached tables, MEMOPTIMIZE): the
cheapest per-frame fetch adds ≥ 1.2 ms mean and ≈ 2.2 ms to the heaviest frames (over 33 ms) for
≈ 22 MB per session (≈ 14 MB of SGA once). Concurrency: 2 sessions 91.8 FPS total at unchanged
latency; 4 sessions stay at the 2-CPU throughput and are throttled by Oracle Free's CPU cap
(`resmgr:cpu quantum`, ≈ 4% of frames stall 0.1–0.66 s). `doom_hybrid.mem_info` lists the big
collections and the texel split.

## Tools
`tests/hybrid_phases.py` (per-phase timings via `doom_hybrid.set_debug(1)` / `timings()`),
`tests/hybrid_lineprof.py` (line-level DBMS_PROFILER, creates its tables on first use),
`tests/hybrid_float4_check.py` (float4 equivalence), `client/install_hybrid.py [--interpreted]`,
`tests/hybrid_memory.py` (session memory + first frame over a run), `tests/hybrid_ab.py` (interleaved
A/B of package variants), `tests/hybrid_debugsum.py` (debug counters over a run),
`benchmark/concurrency.py` (N sessions), `benchmark/shared_cache_experiment.py` (SGA sharing costs).
