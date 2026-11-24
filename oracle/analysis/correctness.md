# Correctness

## Ground truth
* **Reference renderer:** CedarDB SQLDoom (`reference/sqldoom/sql/renderer.sql`) running in the
  `cedardb/cedardb` image, with Freedoom 0.13.0 `freedoom1.wad` loaded by the reference's own loader.
* **Frames:** the deterministic TPC-DOOM E1M1 run (`tests/run-e1m1-b-commands.json`, 1,200 tics,
  skill 2, IDDQD+IDKFA), replayed in CedarDB by `tests/record_reference.py`. The run includes
  live monsters, imp fireballs, chained barrel explosions, doors, a lift, pickups, a secret and
  weapon switches.
* **Validation of the replay:** 1,180 of 1,200 RGB frames are byte-identical to the published
  TPC-DOOM CedarDB run (`reference/saildoom/tpc-doom/results/0001-*`). The other 20 differ through
  newer-CedarDB/libm effects in the published run.
* **Comparison space:** 8-bit palette indices after COLORMAP (64,000 bytes per frame, status bar
  included). These come from an index-emitting variant of the reference renderer, obtained purely by
  table renames: `colormap_rgb.rgb` becomes the 1-byte mapped index. For all 1,200 frames,
  `PLAYPAL[idx]` equals the reference RGB, except during the 30 frames of whole-screen palette flash.
* **Palette number:** compared separately per frame. It is the damage/bonus/radsuit flash (`ST_doPaletteStuff`).
* **State:** the recorder also snapshots every table the renderer reads, per tic (`reference_data/e1m1/state/*.parquet`).
  The Oracle renderers read exactly that state, so frames are compared on identical worlds.

## Results (`tests/run_correctness.py`, exact = all 64,000 indices equal and palette equal)

| Renderer | Frames checked | Exact | Mismatched pixels |
|---|---|---|---|
| `render_baseline.sql` (faithful port) | 48 (every 25th tic) | 48 | 0 |
| `render_optimized.sql` (pure SQL) | 1,200 (every tic) | 1,200 | 0 |
| `render_hybrid.sql` (SQL + PL/SQL) | 1,200 (every tic) | 1,200 | 0 |

`render_optimized.sql` was checked:
* at every 10th tic (120 frames) after tuning round 1, all exact;
* at every 7th tic offset by 3 (172 frames) when verifying the hybrid, all exact;
* over the full run, as recorded in `benchmark-results.md`.

`render_hybrid.sql` was additionally checked at every 7th tic offset by 3 (172 frames), and all were exact.

No tic is special-cased anywhere. There are no intentional deviations from the reference, so the
"documented differences" list is empty. Each renderer reproduces the reference's own departures
from vanilla Doom, which are listed in `reference-analysis.md`.

## Exactness issues found and how they were resolved

| Issue | Symptom | Resolution |
|---|---|---|
| CedarDB parses the camera pose from SQL text as float8(mantissa)/10^scale, sometimes 1 ulp from the nearest double | 5 of 48 baseline frames off by 127 px in total | `pose_conv`: exact NUMBER reconstruction of CedarDB's conversion (baseline); a 0.3 ms variant in the optimized renderer, bit-identical on all 4,800 pose values |
| Postgres float→int casts round half-to-even | — | `ROUND(BINARY_DOUBLE)` in Oracle is half-even; used for every reference `::int/::bigint` of a float |
| CedarDB evaluates `real + smallint` in float4 | sprite top/bottom rows | `TO_BINARY_FLOAT` at each step; checked over all 814,592 combinations in the run |
| `256.0/90.0` is a NUMERIC constant in CedarDB | sky column choice | the constant is written as `2.844444d`, which is not the same double as `256d/90d` |
| CedarDB's `LEAST`/`GREATEST` ignore NULL; Oracle's return NULL | carried plane caps | explicit NULL handling |
| Oracle ATAN differs from CedarDB's by 1 ulp for 4 of the 320 screen columns | none observed | Could change the sky texture column only if a value lands exactly on a texel boundary. Never observed in 1,200 frames. Known residual risk. |
| Texture/BLOB bounds semantics (`GET_BYTE` out of range gives 0) | — | reproduced via offset-keyed NVARCHAR2 chunks (baseline) or exact column strings |

## How to reproduce
```sh
make test                         # optimized, 120 frames
R=render_hybrid.sql make test-full
make reference                    # regenerate ground truth (CedarDB container)
```
Diff images for any mismatching frame are written to `oracle/tests/out/` as triptychs: got | reference | mismatches in red.
