# Oracle design: what a relational Doom renderer looks like on Oracle AI Database 26ai

## The question
Given Doom's geometry, Oracle's row-source execution engine, a 320×200 framebuffer, two database
CPUs and static WAD data: what is the minimum relational work that must exist to produce the
exact frame? The design below is driven by measurements on the target instance
(`optimization-log.md`, section 0), not by the CedarDB/Postgres formulation.

## What Oracle charges for (measured, 53,760 pixel rows)
| Work | Cost | Consequence |
|---|---|---|
| Generating rows by an indexed range join | ~3 ms | rows are cheap |
| Each SQL operator per row (BINARY_DOUBLE arithmetic) | ~0.01–0.06 µs | double math is nearly free |
| BINARY_DOUBLE→NUMBER conversion (BITAND, NUMBER keys/joins) | ~0.4 µs | keep per-pixel work in doubles |
| `SUBSTR` with character semantics on AL32UTF8 | O(n) per call | use fixed-width NVARCHAR2 |
| `LISTAGG … WITHIN GROUP (ORDER BY)` | +20 ms (sort) | assemble without sorting |
| Generic z-buffer (`MIN(key) GROUP BY pixel`, 80k fragments) | ~40 ms | must not exist |
| Front-end stages over a few thousand wide rows | 2–5 µs/row/stage | trim rows and columns early |

A 35 FPS frame is 28.6 ms. A generic z-buffer alone blows it, so the central design decision is:
**resolve visibility structurally, at interval level, so every visible pixel is generated exactly
once and sampled exactly once.**

## Pipeline (render_optimized.sql: one prepared SELECT, binds only)

```
binds (:tic :px :py :pz :pangle …)
  ↓ frame constants (materialized one-row CTEs: no per-row TAN/SIN/COS)
  ↓ BSP: 1,362 child boxes → support-function frustum test (3 half-planes, conservative)
  ↓      681 nodes → front side (exact integer predicate, Postgres-rounding emulated)
  ↓      rank(leaf) = 1 + Σ_path [side ≠ front]·leaves(front child)        ← order statistics
  ↓      → ~430 visible subsectors in exact front-to-back order (no path keys, no sort)
  ↓ segs: back-face cull, camera transform, near-plane clip in camera space, then divide
  ↓ wall parts: 7-way unpivot (solid/upper/lower/midmask + 3 clip-only boundaries)
  ↓ solid occlusion: MIN(bsp rank) of solid segs per screen column (320 rows)
  ↓ wall columns: (part × covered column) only where not behind the nearest solid
  ↓ visplane windows per column: running MAX/MIN clip bounds + carried planes
  ↓    (window functions over ~3k panel rows; LAST_VALUE … IGNORE NULLS, packed)
  ↓ EXACT INTERVAL VISIBILITY
  ↓    items = wall spans (constant depth key) + plane spans (depth = cz/(cy−y))
  ↓    elementary segments per column (cut at every item boundary)
  ↓    1 candidate → owner;  only constant-key candidates → min key, whole segment
  ↓    plane vs other → resolved per pixel inside that segment only (~5k px)
  ↓    = disjoint ownership (column, y0..y1) → item          [~7k segments]
  ↓ pixels: one row per owned pixel (53,760), by owner kind
  ↓    wall: ASCII(SUBSTR(prelit_column, floor-mod(v0 + (y−ys)·step) + 1, 1)) − 256
  ↓    flat: per-(plane class, row) table prow (depth, px+depth·cv, py+depth·sv, zlight; ~2–4k
  ↓          rows) by hash join; per pixel only (ta·depth)·sv / ·cv, texel mod, prelit quarter by hash join
  ↓    sky : rotated sky column per screen column
  ↓ sprites: projected things → candidate pixels → opaque texels → depth key vs the
  ↓    owning segment's key (no full-screen z-buffer) → nearest per pixel
  ↓ weapon psprite and pickup message (top layers)
  ↓ framebuffer: SUM(idx · 256^(x mod 15)) GROUP BY (y, x div 15) — order-free, exact
  ↓    status bar = precomputed packed background + per-frame overlay deltas
  → 4,400 NUMBERs (200 rows × 22 chunks); client decodes base-256 digits → 64,000 bytes
```

### Why each choice
* **One statement, cursor-duration temp results.** The front end is a chain of small relations
  (hundreds to a few thousand rows). Oracle has no statistics for bind-dependent rows, so
  without help it estimates 1 row everywhere and makes catastrophic choices (join predicate
  pushdown re-aggregating a view 6,440 times; band joins by `SORT JOIN`; hashing the 735k-row
  texture table). Materializing the reused stages as `CURSOR DURATION MEMORY` temp results
  (≈0.1 ms each) pins the plan shape; a handful of documented join hints pin the rest, and
  statistics feedback / adaptive plans are disabled for this cursor via `OPT_PARAM` because
  re-optimisation flipped good plans into bad ones between executions.
* **BSP order as an order statistic (H2).** Replaces the reference's bigint path key + bit shifts
  + `ROW_NUMBER` sort with one `SUM` over precomputed (leaf, ancestor, side, sibling-leaf-count)
  rows. Exact, no depth limit, no sort.
* **Exact interval visibility instead of a z-buffer (H9, H13, H20, "exact ownership").** For a
  column, wall depth is constant and plane depth `cz/(cy−y)` is monotone, so the reference's
  per-pixel `MIN(key)` is reproduced on elementary segments; per-pixel work remains only where a
  plane competes with something else. This removed ~40 ms of `GROUP BY pixel` and all texture
  sampling of losing fragments (H18).
* **Texels as NVARCHAR2 code units, pre-lit (H16, H17).** Palette index *i* is U+0100+*i*;
  AL16UTF16 is fixed width so `SUBSTR` is O(1), `SUBSTR` truncates a fractional position (free
  `FLOOR`), and `ASCII()` returns the code unit. COLORMAP is applied at load time (34 light rows),
  so lighting costs nothing per pixel for walls; flats pick a pre-lit quarter string per pixel.
* **All per-pixel addressing in BINARY_DOUBLE (H7).** `FLOOR(w) − 64·FLOOR(w/64)` is an exact mod
  in doubles (division by 2^k is exact); `BITAND` (NUMBER) cost 3× more.
* **Order-free framebuffer packing (H29, H30).** `LISTAGG … ORDER BY` sorts 54k rows; a `SUM`
  of `idx·256^k` into 38-digit NUMBERs needs only a hash aggregate. Overlays (sprites, weapon,
  message, status-bar digits) are additive deltas.
* **Static precomputation (H10, H28).** `screen_x/screen_y` IOTs with packing weight, ray tangent
  and `cy−y`; `bsp_steps`; `render_segs_ext` (seg ⨝ linedef flags, peg bits); pre-lit texture,
  flat and sprite column strings; packed status-bar background. Nothing camera- or
  frame-specific is precomputed.

## Exactness
The renderer reproduces CedarDB SQLDoom bit for bit, including its departures from vanilla Doom
(see `reference-analysis.md`). This required: identical floating-point operation order;
Postgres float→int rounding (half-even; Oracle `ROUND(BINARY_DOUBLE)` matches); CedarDB's
`real + smallint` in float4; `LEAST/GREATEST` NULL semantics; the reference's exact depth-key
tie-breaking; and CedarDB's text→float8 conversion of the camera pose (`pose_conv`, found by the
baseline port). See `correctness.md`.

## What is deliberately not used (measured, see the log)
`UTL_RAW` (PL/SQL call per pixel), `TRANSLATE` for COLORMAP (0.9 µs/char), unordered `LISTAGG`
(order not preserved), `XMLAGG`, plain PL/SQL functions in row paths (2.2× slower than inline;
the SQL Transpiler removes that cost when enabled), `KEEP (DENSE_RANK)` for the big resolve
(slower than a packed `MIN`, and the big resolve no longer exists), parallel query (unavailable
in Free).
