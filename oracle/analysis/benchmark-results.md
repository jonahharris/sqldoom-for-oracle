# Benchmark results

## Environment (see `environment.json`)
* **Database:** Oracle AI Database 26ai Free Release 23.26.4.0.0, image `gvenzl/oracle-free:full`
  @ `sha256:7e95311077d8d4a2d839883f7eb8717c0a7f04fe3d4b1cd330dde8b39aa588ab`.
* **Platform:** Linux AARCH64 in Docker 29.4.0 on an Apple-silicon Mac (arm64, 12 host CPUs).
* **Oracle Free limits (verified):** `cpu_count = 2`; SGA max 1,536 MB; PGA target 512 MB, limit 2 GB.
  Parallel execution is not available (`Parallel execution = FALSE`, `parallel_max_servers = 1`).
  In-Memory is available.
* **In-Memory during the final runs:** `INMEMORY_SIZE` was 256 MB, left over from the H22 experiment,
  with no objects marked INMEMORY.
* **Reference measured on the same host:** CedarDB `v2026-11-18`, container limited to 2 CPUs.

## Method
* **Workload:** the deterministic TPC-DOOM E1M1 run, 1,200 tics. The first 120 are warm-up and the
  next 1,080 are measured. The baseline is sampled every 10th tic, giving 117 measured frames.
  Each frame renders from that tic's recorded world state and camera pose.
* **Setup:** one session and one prepared cursor; database, map data and package state warm.
  No sleeps.
* **Mode A (database-only):** server elapsed time per execution, from `V$SQL` deltas over the
  measured interval.
* **Mode B (end to end):** client wall clock for bind → execute → fetch → decode to palette
  indices → display-ready RGB (PLAYPAL lookup). Sustained FPS = frames / wall time.
* **Cursor reuse (all runs):** 1 child cursor, **0 parse calls and 0 hard parses** during the
  measured interval.

## Results

| Renderer | DB ms/frame (mode A) | End-to-end mean | p50 | p95 | p99 | min | max | DB-only FPS | **Sustained end-to-end FPS** | Exact frames |
|---|---|---|---|---|---|---|---|---|---|---|
| CedarDB SQLDoom (reference, 2 CPUs) | — | — | 16.7 | 21.2 | — | — | 24.0 | — | ≈ 60 | ground truth |
| `render_baseline.sql` (faithful port) | 4,934 | 4,936 | 5,044 | 7,922 | 11,138 | 1,748 | 11,326 | 0.20 | **0.20** | 48/48 sampled |
| `render_optimized.sql` (pure SQL) | 123.2 | 131.3 | 140.7 | 190.9 | 202.7 | 52.4 | 523.9 | 8.1 | **7.6** | 1,200/1,200 |
| `render_hybrid.sql` (SQL + PL/SQL) | 25.3 | 26.2 | 27.2 | 34.6 | 36.7 | 16.7 | 44.1 | 39.6 | **38.2** | 1,200/1,200 |
| `render_hybrid.sql`, round 4 | 19.0 | 19.96 | 21.48 | 26.47 | 27.57 | 10.44 | 43.42 ¹ | 52.5 | **50.1** | 1,200/1,200 |
| `render_hybrid_split.sql`, round 4: one frame on 2 sessions | 12.0 per half | 13.13 | 14.02 | 17.41 | 19.55 | 6.77 | 31.31 ¹ | — | **76.2** | 1,200/1,200 |

¹ isolated host hiccups (different tics in every run); the steady heaviest frames (tics 577–581)
take 28.8–29.0 ms single-session and ≈ 16–17 ms split. Round-3 renderer measured the same day:
mean 20.93, p95 27.39, p99 28.45 (`benchmark/results/r4_baseline_p0.json`).

Notes:
* **CedarDB figures** come from the reference's own prepared renderer, measured as execute + fetch
  of the 192 KB RGB frame, every 5th tic (`benchmark/cedar_stats.py`).
* **Frame budgets:** the hybrid meets the 33 ms (30 FPS) budget on 91% of frames; the p95 is 34.6 ms.
* **Hybrid round 2** (`optimization-log.md`, "Hybrid round 2"; `benchmark/results/final_hybrid_r2.json`):
  DB 20.9 ms/frame, end-to-end mean 21.8, p50 23.4, p95 29.0, p99 30.5, min 11.9, max 32.2 ms,
  47.9 FPS database-only, **45.9 FPS** sustained end-to-end, **100% of frames ≤ 33 ms**, 1,200/1,200 exact.
  The table row above is the round-1 (H27) result.
* **Round 4** (`optimization-log.md`, "Hybrid round 4 / game loop phase 2";
  `benchmark/results/final_hybrid_r4.json`, `final_hybrid_split_r4.json`): single session −4.6 % mean,
  −0.9 ms p95/p99 (wall texel-row thresholds, `IF` clamps, cheaper visplane sort). The split mode
  renders the two column ranges of one frame on two sessions in parallel (Oracle Free: 2 CPUs, no
  parallel query) and joins the hex halves of each row; per frame it is interactive latency, not
  batch throughput (each frame is requested, rendered and returned before the next).
* **First frame (cold, excluded from FPS):**
  * hybrid: 222 ms, which includes loading static map data and textures into package memory
    (≈ 84 MB per session);
  * pure SQL: ≈ 1 s, which is mostly the hard parse of the 800-line statement.

| Speed-up (end-to-end p50) | |
|---|---|
| pure SQL vs baseline | 36× |
| hybrid vs baseline | 185× |
| hybrid vs pure SQL | 5.2× |
| hybrid vs CedarDB reference (2 CPUs) | 0.61× (1.6× slower) |

### Per scene (end-to-end, ms) — `benchmark/scenes.py`
Each scene class is a top or bottom quartile of the reference renderer's own stage cardinalities
for that tic.

| scene class | pure SQL p50 / p95 | hybrid p50 / p95 | CedarDB p50 |
|---|---|---|---|
| simple (few visible subsectors) | 61 / 143 | 17 / 25 | 13.5 |
| many visible subsectors | 143 / 176 | 28 / 33 | 17.2 |
| high overdraw | 151 / 203 | 29 / 36 | 17.7 |
| many sprites | 146 / 199 | 27 / 36 | 17.0 |
| large open areas (many plane pixels) | 171 / 199 | 32 / 36 | 17.9 |
| all | 141 / 190 | 27 / 35 | 16.7 |

### Transport
* **Pure SQL:** 4,400 rows × one NUMBER, holding 15 pixels per exact 38-digit base-256 NUMBER.
  Fetch 5.0 ms, decode 2.5 ms.
* **Hybrid:** 200 rows of 640-char hex scanlines. Fetch < 0.1 ms, decode 0.14 ms.
* **Comparison:** the reference returns 192,000 RGB bytes; both Oracle encodings carry 64,000
  palette indices, and the client applies PLAYPAL.

## Stage cardinalities (tic 300; reference medians over the run in parentheses)

| Stage | Rows |
|---|---|
| BSP child boxes tested / kept | 1,362 / 429 subsectors (164 median) |
| segs after back-face + frustum | 630 → 580 on screen (278) |
| wall parts | 980 |
| wall columns (after solid occlusion) | 3,291 (1,413 wall spans) |
| panel rows in visplane windows | 3,177 |
| plane spans | 1,165 |
| visibility items | 2,159 |
| elementary segments | 2,243 |
| pixels resolved per pixel (plane vs other) | 5,342 |
| final owned segments | 6,923 |
| background pixel rows | **53,760 = exactly one per view pixel** (reference: 63,980 fragments ranked) |
| sprite candidate pixels → visible | 5,336 → 704 |
| weapon pixels | 2,412 |
| packed output | 4,400 NUMBERs |

## Dominant remaining costs
* **Pure SQL** (ablation at tic 500, ≈ 210 ms):
  * front end up to final ownership ≈ 88 ms, at 1–3 µs per row per stage over 2–10 k-row
    windowed and aggregated stages;
  * background pixels ≈ 70 ms: flats ≈ 1.7 µs/px, walls ≈ 1.5 µs/px; row generation itself
    is only ≈ 6 ms;
  * sprites ≈ 12 ms; overlay and packing ≈ 10 ms; status bar ≈ 4 ms.
* **Hybrid** (round 4, live renderer, mean ms per frame):
  * walls 7.0 (pixel loops ≈ 55 %, per seg-column/part setup ≈ 30 %, visplane panel records ≈ 10 %);
  * flats 4.8 (one exact statement per pixel: two `FLOOR`s and eleven lookups, ≈ 150–200 ns);
  * hex output 2.4–3.1; visplane sort + sweep 1.95 (4.7 at the heaviest tics);
  * sprite SQL 0.8, status bar 0.6, state SQL 0.5, buffer reset 0.5, sprites 0.5, segs 0.4.
  * Interpreter cost model behind these (ns): collection read 9–11, write 17, `FLOOR` into an
    index 31, `TRUNC` 104, `MOD` 90, `LEAST/GREATEST` 26 (an `IF` clamp 9).

  The hybrid runs **interpreted** PL/SQL: native compilation fails with `PLS-00924` on this arm64
  Free build, and measured timings for native and interpreted settings are identical. On a
  platform with native compilation, the per-pixel loops are where it would pay.

## Live game loop (round 4: tic + frame per 35 Hz period, budget 28.6 ms)
`client/game.py --check [--pipelined] [--split]`, 1,200 tics, warm-up 120 excluded; every run
1,200/1,200 live frames pixel-exact, camera poses equal (`benchmark/results/game_loop_r4.json`).

| mode | period mean | p50 | p95 | p99 | max | ≤ 28.6 ms | before (same day) |
|---|---|---|---|---|---|---|---|
| serial (test R, one session) | 23.15 | 24.47 | 30.48 | 32.09 | 33.80 | 83.3 % | 24.74 / p95 32.18 / 69.2 % |
| pipelined (tic N+1 ∥ frame N) | 20.99 | 22.34 | 27.70 | 29.87 | 36.59 | 97.5 % | 23.22 / p95 30.57 / 80.5 % |
| serial, split frame | 16.69 | 17.17 | 22.47 | 25.58 | 32.53 | 99.9 % | — |
| pipelined, split frame | 15.20 | 15.91 | 20.35 | 21.93 | 28.32 | **100 %** | — |

Test T (tic + sound events + finish): 3.04 ms mean, p95 4.17 (phase 1, same day: 3.57 / 4.82;
CedarDB on this host 3.92).

## Multiplayer (phase 3: one shared tic + one frame per player, budget 28.6 ms)
`client/game_mp.py --players N [--pipelined] [--realtime]`, E1M1, live scripted bots, all four start
slots ticked (as CedarDB's referee does), 1,200 tics, warm-up 60; one tic session + one render
session per player (`benchmark/results/p3_mp_{N}p_{serial,pipelined}.json`). Correctness:
`game_mp.py --check` 2 players pipelined 1,000/1,000, 4 players 764/764, duel 600/600 frames
pixel-exact; replays of 5 CedarDB deathmatch recordings equal on all 6,250 tics, 3,364 frames exact.

| players | mode | tic mean | frame mean (per player) | period mean | p95 | p99 | ≤ 28.6 ms | frames/s |
|---|---|---|---|---|---|---|---|---|
| 1 | serial | 4.00 | 16.9 | 20.9 | 27.3 | 29.9 | 97.8 % | 48 |
| 1 | pipelined | 4.28 | 17.3 | 17.6 | 24.6 | 27.1 | 99.6 % | 57 |
| 2 | serial | 5.54 | 19.1 / 21.7 | 28.1 | 33.7 | 37.0 | 52.4 % | 71 |
| 2 | **pipelined** | 5.91 | 19.9 / 22.4 | **23.6** | 29.4 | 34.0 | **92.4 %** | 85 |
| 2 | pipelined, paced 35 Hz | 5.80 | 19.5 / 22.1 | 28.57 (35.0 Hz) | — | — | 0 late periods | 70 |
| 3 | serial | 6.42 | 25.2 / 23.2 / 20.1 | 33.3 | 37.7 | 96.5 | 11.5 % | 90 |
| 3 | pipelined | 8.52 | 31.3 / 28.5 / 25.0 | 33.3 | 37.6 | 307.6 | 74.4 % | 90 |
| 4 | serial | 7.93 | 26.5 / 21.4 / 24.4 / 27.8 | 40.5 | 42.8 | 316.4 | 18.0 % | 99 |
| 4 | pipelined | 9.31 | 33.8 / 28.4 / 30.5 / 35.6 | 41.4 | 43.4 | 478.5 | 62.2 % | 97 |

Two CPUs: N frames of ≈ 20 ms + a 4–8 ms tic is the CPU per period; two players fit on average
(pipelined), three and four do not, and 4–5 busy sessions hit Oracle Free's CPU cap (p99 stalls).

Deathmatch tic only (`tests/mp_profile.py --no-debug`; CedarDB: `record_mp_reference.py
--timing-only`), 700 tics, same host:

| claimed slots (of 4 ticked) | Oracle mean / p95 | CedarDB mean / p95 |
|---|---|---|
| 1 | 3.87 / 4.25 | 3.89 / 4.58 |
| 2 | 5.52 / 6.97 | 5.24 / 9.77 |
| 3 | 5.91 / 7.29 | 6.70 / 11.34 |
| 4 | 7.25 / 9.07 | 7.42 / 13.34 |

Single player, same day as phase 3 (`benchmark/results/p3_game_*.json`, 1,200/1,200 frames exact
each): serial period 23.94 mean / p95 31.09 (75.3 %), pipelined 21.62 / 28.55 (95.2 %), serial split
17.28 / 22.79 (99.6 %); test T 3.28–3.31 ms (phase-2 package, same session: 3.24 ms).

## Next experiments most likely to raise FPS
1. **Native PL/SQL compilation** on an x86-64 Oracle Free image. It needs no code change and
   targets the 13 ms of per-pixel loops.
2. **Hybrid: per-pixel z-test.** Round 4 measured it: the z-test is ≈ 16 ns of a 100–200 ns
   pixel and 91 % of tested wall pixels are first writes, so dropping it saves ≤ 0.6 ms.
3. **Hybrid: flats as horizontal spans** (Doom's visplane approach): ≈ −13 % of flat shading
   before the span conversion (column-major buffers make row walks slower); not built.
3b. **Split mode:** balance by a per-column cost profile instead of the last frame's half times;
   share the ≈ 3 ms of column-independent work.
4. **Pure SQL: flats as horizontal spans** and a merged front end. The visplane windows, items and
   segment classification could be one or two stages. Estimated floor ≈ 60–100 ms.
5. **Concurrency.** Two sessions rendering *different* frames use both Free CPUs for throughput
   (not interactive FPS); round 4's split mode instead uses both for *one* frame (latency).
