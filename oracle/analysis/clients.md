# The clients (phase 6): desktop, browser, sound, music, interpolation

CedarDB SQLDoom ships a pygame client (`doom_client.py` + `doom_sql.py`, `render_worker.py`,
`audio.py`, `dock.py`, `doom_config.py`), a browser client (`web/` + `doom_web.py`, a WebSocket
tunnel to the Postgres wire protocol) and the client SQL of `sql/client/`. Phase 6 ports them to
Oracle. As in the reference, the clients hold no game logic and no renderer: they read input, send
one command per 35 Hz tic, ask the database for frames, map palette indices through PLAYPAL and play
the sounds and music the database selects.

## What runs where

| piece | reference (CedarDB) | Oracle |
|---|---|---|
| single-player client | `doom_client.py` (psycopg2, prepared statements) | `client/doom_client.py`, class `SPGame` (the `doom_sql.py` calls over `doom_game` / `doom_flow` / `doom_screen`, `client/game_api.py`) |
| deathmatch player | `DOOM_JOIN=n doom_client.py` (API_MODE) | `doom_client.py --join USER`, class `MPGame` (`api_*` only, the player's own account) |
| render thread | `render_worker.RenderWorker`: newest request, own connection, frames never waited on | `doom_client.RenderWorker`: the same, plus a READ ONLY transaction taken between two tics (Oracle's statement-level consistency, see below) and optional split rendering |
| camera between tics | `client/camera_pose.sql` by alpha, then `renderer.sql` at that pose | `game_api.CAMERA_SQL` (alpha through `doom_float8`, CedarDB's float8 parse), joined laterally into `render_frame` in one statement (`FRAME_AT_SQL`) |
| sound | `audio.py`: `sound_assets` WAVs, `sound_events.sql` one-shots on 16 channels, `sound_loops.sql` on 8 reserved channels | `doom_client.Audio`: the same channels and volume/pan law; `SOUND_SQL`, `SOUND_LOOPS_SQL`, `SOUND_ASSETS_SQL` |
| music | `stage_music.sql` → MIDI to `pygame.mixer.music` | `STAGE_MUSIC_SQL` → MIDI (or rendered Ogg when present) to `pygame.mixer.music` (pygame-ce's SDL_mixer plays MIDI on macOS) |
| full-screen frames | `render_screen.sql`, `render_automap.sql` → RGB, composited per state change | `doom_screen.render_screen/_automap` → palette indices; one SELECT per displayed frame (35/s while a screen is up; no composite is cached) |
| dock / BSP band (EXPLAIN ANALYZE replay, pipeline graph, `render_stats_tail.sql`) | CedarDB diagnostics of `renderer.sql`'s CTE pipeline | not ported: the hybrid renderer has no CTE pipeline to count; the FPS badge (SQL frames/s + tic ms) is kept, F6 hides it |
| browser | `web/index.html`, `app.js`, `pgwire.js` (Postgres protocol + SCRAM in JS) through `doom_web.py` (byte tunnel) | `client/web/index.html`, `app.js`, `oraws.js` through `client/doom_web.py` (a bridge with a closed statement vocabulary, below) |
| bots, web smoke, browser check | `scripts/bots.mjs`, `web_smoke.mjs`, `web_browser_check.mjs` | `tests/bots.mjs`, `tests/web_smoke.mjs`, `tests/web_browser_check.mjs` |

## Sprite mode: vanilla by default for players

The renderer has two sprite modes (`doom_hybrid` `p_mode`, [hybrid-design.md](hybrid-design.md)):
CedarDB-exact (0: sprites depth-tested against floors and ceilings, so barrels and items sink a few
pixels into the floor — the reference's behaviour) and vanilla (1: Doom's sprite clipping by the
silhouettes of the segs in front, planes never occlude a sprite). Walls, planes, the weapon and the
status bar are identical in both. What uses which:

| path | mode |
|---|---|
| `doom_client.py` single player, split and non-split | **vanilla**; `--cedar-exact` switches to the exact mode. The render thread binds it (`:sprites` of `game_api.FRAME_AT_SQL` / `FRAME_AT_SPLIT_SQL`) |
| deathmatch: `doom_client.py --join`, the browser (`doom_web.py`), bots | the per-slot frame views pass `g_mp_match.sprite_mode` (one value for the match, so every player sees the same rendering; a player still cannot pass any render argument). The referee sets it: `SPRITE_MODE=vanilla` (default) or `cedar`, or `referee.py --cedar-exact` |
| the game owner's SQL API (`game_api.FRAME_AT_SQL`, `FRAME_SQL`, `render_live(..., sprites=0)`) | a bind; every test passes 0 (exact) |
| `render_hybrid.sql`, `render_hybrid_split.sql`, `run_correctness.py`, `bench.py`, `game.py --check`, `client_run_check.py` (passes `--cedar-exact`), `api_replay.py` (sets `sprite_mode = 0` for its match), recordings | exact |

`sql/render_hybrid_vanilla.sql` is the benchmark SELECT for the vanilla mode. Cost: see
optimization-log.md, "Vanilla sprite mode".

## Data: sound and music

* `sound_assets`: 69 DS* lumps as 8-bit mono WAV (`api_install.load_audio`, phase 5): **69/69
  byte-equal** to CedarDB.
* `music_assets` / `map_music` (`client/music.py`, called by `api_install.py` and `--audio-only`):
  `mus_to_midi` and `music_lump_for_map` are ported unchanged; **3,000/3,000 random MUS scores convert
  byte-identically** to the reference function (`client_query_check.py mus-fuzz`, every event
  type, invalid and truncated scores included: 792 rejected identically). freedoom1.wad stores its
  41 D_* lumps as standard MIDI files, not MUS, and the reference loader skips them — CedarDB
  SQLDoom loaded from this WAD has **no music at all**. The Oracle loader stores a MIDI lump as it is
  (original and MIDI alike): the one documented extension. `client_query_check.py cedar-music` runs
  the reference loader's `load_music` on CedarDB (0 MUS scores) and adds the MIDI lumps the same way,
  so the stage-music query is compared on the same data: **41/41 tracks byte-equal, map_music equal
  (36 maps), stage_music.sql equal on all 36 maps**.
* Rendered Ogg for browsers (`midi_render.py`): ported in `music.py` (FluidSynth + a GM soundfont +
  ffmpeg; macOS library names added, `DOOM_SOUNDFONT`). Not present on this host, so `audio_data` is
  NULL — as on the reference without FluidSynth, the browser then plays no music; the desktop client
  plays the MIDI.

## Camera interpolation

`client/camera_pose.sql` blends the previous and the current tic's pose by alpha (0 = last tic, 1 =
this tic; the angle along the shorter turn). Oracle runs the same arithmetic in BINARY_DOUBLE
(`game_api.CAMERA_SQL`). The one subtlety is the alpha itself: the reference client sends a Python
float as its shortest decimal text and CedarDB parses a float8 literal as float8(mantissa rounded to
53 bits) / float8(10^scale), which is not always the correctly rounded double. python-oracledb binds a
Python float as a NUMBER with the same digits; `doom_float8` (`sql/14_client.sql`, the arithmetic of
`doom_hybrid.pose_conv`) turns it into the double CedarDB uses. The frame at an interpolated pose is
one statement: the camera row joined laterally into `doom_hybrid_live.render_frame`, the pose handed
over through `doom_game.shortest` (what the reference client's round trip through Python does).

## The desktop client (`client/doom_client.py`)

The reference's main loop, statement for statement: the 35 Hz accumulator (catch-up limited to 4
tics), commands from the keyboard and mouse, the tic (`run_tic` + sound events/loops when due +
`game_tick_finish`), exits deferred to the intermission (`level_exit`, the tally's own 35 Hz clock,
`after_intermission` → next map with carry, or the finale), the menus (`menu_input` actions start /
save:n / load:n / quit), the attract loop and demos, typed cheats (`cheat_key` actions warp:, music:,
iddt, msg:), the automap (follow, grid, fit, zoom, pan), weapon slots and the wheel, respawn on Space.

Frames: the render thread (`RenderWorker`) renders the newest request on its own session. Oracle's
read consistency is per statement, and `render_frame` runs many queries; a tic committing in the
middle would split a frame between two tics. The thread therefore opens a READ ONLY transaction
while holding the loop's tic lock (taken by the game thread around each tic and its commit), and
computes alpha at the same moment from the loop's clock — the frame shows exactly that committed
tic, interpolated to that instant. `--split` renders each frame on two sessions (left/right column
ranges, `render_frame(..., x0, x1)`), both READ ONLY transactions opened under the same lock, so both
halves see the same tic; the split column follows the measured half times (load balancing only).
Split is the single-player default whenever the database has 2+ CPUs (rule: render sessions per
player = max(1, CPUs ÷ players); `render_sessions()` in `doom_client.py`, `--no-split` to force one
session). Deathmatch always renders one session per player: on 2 CPUs the rule gives 1 as soon as
two players are in, and two player sessions could not be pinned to one tic anyway, because the
referee commits tics on its own clock rather than under the client's tic lock.

Deathmatch (`--join USER`): the player's own account, `MPGame` over `api_client.ApiPlayer`:
`api_join` (waits in the lobby), `api_input` per tic, `api_sound_events` / `_loops` / `api_snapshot`,
`api_stage_music`; the render thread's session calls `api_camera(alpha)` + `SET TRANSACTION READ
ONLY` in one round trip, then reads the slot's frame view. Map changes (rotation) are followed through
`api_match` once a second. Menus, saves and demos are single-player, as in the reference.

Unattended options (tests): `--headless` (SDL dummy drivers), `--script FILE` (timed key events,
held keys, wheel, scenario ops), `--commands FILE` (a recorded command stream replaces the keyboard),
`--warp MAP --cheats CODES` (the recorders' level start), `--tics`, `--seconds`, `--log`, `--log-frames`.

## The browser client (`client/doom_web.py`, `client/web/`)

A browser cannot speak Oracle's protocol, so the bridge terminates the WebSocket and talks to Oracle
with python-oracledb (thin, asyncio), **logged in as the browser's own player account** — the
credentials the page sends (or a leased guest *player* account from `DOOM_GUESTS_FILE`, as the
reference's guest pool). The bridge has no account of its own. It accepts a closed vocabulary: a
fixed table of named statements (`STATEMENTS`), each an `api_*` function or view or `sound_assets`,
with typed, length-limited parameters; no SQL text crosses the WebSocket, frame views are addressed
only by the integer slot and map the bridge itself reads from `api_slot` / `api_match`. Behind it,
Oracle's grants are the boundary (a player holds only `DOOM_PLAYER`), so a bridge bug still could
not reach a table. Each browser gets two sessions: tic traffic and frames, so a frame never delays
the 35 Hz input. Frames go as binary messages (64,000 indices + palette), XORed against the previous
frame of the same kind and permessage-deflate compressed (the reference's `pg-delta` idea).

`web/app.js` is the reference page with `pgwire.js` replaced by `oraws.js`: the same lobby view
(the live plan of the match while queued), scoreboard, input, two frames in flight, WebAudio sounds
and loops, automap, stats line, embed mode.

## Verification (2026-11-24, logs and JSON in `tests/out/p6/`)

| check | result |
|---|---|
| `client_query_check.py assets` | sound_assets 69/69, music_assets 41/41 byte-equal, map_music equal (36 maps), stages equal, stage_music.sql 36/36 maps equal — **vs CedarDB** |
| `client_query_check.py mus-fuzz 3000` | `mus_to_midi` 3,000/3,000 equal to the reference function |
| `client_run_check.py` — the desktop client headless, TPC-DOOM E1M1 stream as input, real 35 Hz loop | every tic's snapshot **1,200/1,200 equal to the CedarDB recording** (pose, alive, exits, keys, tic stages, screen, demo), sound events 1,200/1,200 tics equal (177 events, name/volume/pan); 1,629 frames displayed (1,367 at an interpolated alpha), split mode 2,179 (1,807) |
| `client_query_check.py emulate` — the camera statement vs `camera_pose.sql` evaluated with PostgreSQL's types in IEEE arithmetic (real − real in float4, the rest float8; alpha through CedarDB's float8 parse) | **22,662/22,662** poses equal (8 recorded runs × 6 alphas a tic: 0, 0.25, 0.5, 1 and two full-precision random) |
| alpha = 1 (the tic's own pose) vs CedarDB | 1,200/1,200 (`game.py --check`, the client run) |
| `client_ui_smoke.py` — scripted single-player flow through the client | **all 17 checks ok**: attract → title → New Game → episode → skill → E1M1; IDDQD/IDKFA typed; weapon key and wheel; automap (grid, zoom); Esc → Save → slot 0; Esc → Load → slot 0; exit switch (Space) → tally (accelerated, dismissed) → E1M2 with the player carried; F9 demo recorded, F10 played back to its end; IDCLEV13 → E1M3; every screen kind drawn by `doom_screen` (title 56, main 94, episode 29, skill 30, save 18, load 19, automap 47, intermission 102 frames); music selected on every level; 37 sounds played; no render error |
| `doom_client.py --join` (deathmatch, headless, scripted input) | joins through the lobby, 418 tics through `api_input`, 415 frames from the slot's frame view, sounds 78, automap via `api_automap`, weapon slot/wheel |
| `web_smoke.mjs` (Node, the page's own `oraws.js`, through the bridge) | sign-in as a player account, join, palettes, 69 sounds, music row, 35 Hz input, frames, automap: ok |
| `web_browser_check.mjs` (headless Chrome, the real page) | signed in, "in the game", 34.5 fps (page cap 35), stats line, automap drawn, canvas 64,000/64,000 lit, scoreboard, **no console errors or warnings** |
| `bots.mjs` (2 bots through the bridge) | both seated, 34.6 / 32.8 fps, hunting 96–99 % of the time, 0 empty frames, 0 frame or tic errors |
| `determinism_check.py` (Oracle, E1M1/E1M6/E2M4), `all_maps_smoke.py` (36 maps), `prepared_pipeline_smoke.py` | reproducible 3/3; 36/36 maps ok; pipeline ok |

**Not completed: the CedarDB-side recordings.** `client_query_check.py record/replay` (sound events
with cursors and sound loops every tic, camera poses at interpolated alphas and frames rendered at them,
compared with CedarDB directly), the CedarDB re-render of the client's displayed frames
(`client_run_check.py` without `--skip-cedar`) and the `--cedar` modes of `determinism_check.py` /
`all_maps_smoke.py` need live CedarDB game tics. During this phase the CedarDB reference container
crashed (SIGSEGV) on the second tic of the first recording, was started again, and since then every
session's second game tic hangs while two server threads spin at the container's 2-CPU cap (3.3 GB);
simple queries still answer. It needs a restart (`docker restart sqldoom-cedar`), which was not
available to this session. Then:
```sh
.venv/bin/python oracle/tests/client_query_check.py record && .venv/bin/python oracle/tests/client_query_check.py replay
.venv/bin/python oracle/tests/client_run_check.py && .venv/bin/python oracle/tests/client_run_check.py --split
.venv/bin/python oracle/tests/determinism_check.py --cedar && .venv/bin/python oracle/tests/all_maps_smoke.py --cedar
```
Until then the sound-loop query is verified through the phase-5 API replay (`api_sound_loops`, now
generated from the same `SOUND_LOOPS_SQL` text, equal on every call of the recorded session) and the
interpolated camera through the emulation above; frames at any pose are the phase 1–5 renderer
(verified at 1,200 + 1,055 + 3,364 + 675 recorded poses).

**Regression** (after all phase-6 changes): TPC replay 1,200/1,200 equal (tic call 3.78 ms mean);
scenarios `e1m1_lift62`, `tpc_bfg`, `smoke_e2m4`, `stop006_057`, `tpc_chainsaw`, `e1m3_stairs7` 6/6
equal, frames exact; flows `exit_e1m1_e1m2`, `save_load_e1m2`, `menus_newgame`, `automap_views`,
`demo_record_play` 5/5 equal (all frames exact); `api_replay.py` 19,079/19,083 calls (the same 4
wall-clock lobby-window calls as phase 5), 850/850 snapshots, 675/675 frames, 14/14 automaps;
`mp_acl_check.py` 63/63; `game.py --check --pipelined` 1,200/1,200 frames exact, poses 1,200/1,200.

A finding on the harness: deathmatch play on E1M2 (a referee + players there) leaves the other slots'
`g_player_state` rows of that map in a different state, and the single-player flows recorded on E1M2
(`exit_e1m1_e1m2`, `save_load_e1m2`) then diverge (monsters target a leftover player row — the same
would happen on CedarDB, whose level start does not remove them either). `api_replay.py replay`
leaves those rows in the state the flows were recorded with; after it both flows are equal again.
Run deathmatch experiments on a map the flows do not use, or `api_replay.py replay` before the flows.

## Performance (same host; Oracle Free 2 CPUs; the CedarDB container was spinning on its own 2 CPUs)

**Desktop client, single player** (`client_run_check.py`, 1,200 tics of TPC-DOOM, headless, frames
as fast as answered; the loop's display cap 120 Hz):

| mode | client FPS (3-D frames/s) | frame latency mean / p50 / p95 | tic rate | tic interval mean / p50 / p95 / max (std) | tic call mean / p95 |
|---|---|---|---|---|---|
| one render session | **48.4** | 20.8 / 22.0 / 29.9 ms | 35.00 Hz | 28.57 / 29.5 / 33.8 / 40.1 ms (4.3) | 5.1 / 7.8 ms |
| `--split` (two render sessions) | **64.6** | 15.5 / 15.7 / 22.4 ms | 35.00 Hz | 28.57 / 29.4 / 33.9 / 40.2 ms (4.1) | 4.8 / 7.0 ms |

The tic clock holds 35.00 Hz over the run; a tic's start lands on the display loop's iteration (≈ 8 ms
granularity at 120 Hz plus the frame upload), so single intervals vary by a few ms around 28.57 ms —
the same accumulator design as the reference client. About 84 % of displayed frames are drawn at an
interpolated camera. Frames and tics share Oracle Free's 2 CPUs; with `--split` the frame uses both
and the tic runs between them.

**Deathmatch through the API** (`doom_client.py --join`, referee at 35 Hz, monsters on): 35.0 tics/s,
tic call (input + sounds + snapshot) 3.8 ms mean, frame (camera + frame view) 22.3 ms mean.

**Browser path** (`web_latency.py`: one player, the same account kind and map, 10 s each, one after
the other):

| path | frames/s | camera + frame round trip mean / p50 / p95 | tic round trip (input + own state + sounds + loops) mean / p95 |
|---|---|---|---|
| direct (python-oracledb, two sessions) | 49.1 | 20.4 / 19.4 / 30.1 ms | 5.3 / 8.7 ms |
| through `doom_web.py` (Node client, WebSocket, deflate + XOR delta) | 51.1 | 19.5 / 18.5 / 27.7 ms | 5.0 / 8.1 ms |

The bridge adds no measurable latency on localhost (its decode of 200 hex rows and the XOR delta are
under a millisecond; the difference is within run-to-run noise). The page itself caps at 35 fps
(`DOOM_MAX_FPS`, as the reference). A frame message is 64,007 bytes before deflate; after the XOR with
the previous frame most of it is zeros (status bar, sky, still walls).

## Files

| file | what |
|---|---|
| `client/doom_client.py` | the desktop client (single player, deathmatch, render thread, audio, scripted runs) |
| `client/music.py` | MUS → MIDI, map → track, optional Ogg rendering, the music loader |
| `client/game_api.py` | + `SOUND_LOOPS_SQL`, `SOUND_ASSETS_SQL`, `STAGE_MUSIC_SQL`, `DEMO_HEADER_SQL`, `PALETTES_SQL`, `FRAME_AT_SQL`, `FRAME_AT_SPLIT_SQL`; `CAMERA_SQL` alpha via `doom_float8` |
| `client/api_install.py` | + music load, `--audio-only`, `--client-only`; `api_sound_loops` / `api_stage_music` / `api_palettes` generated from `game_api` |
| `sql/14_client.sql` | `doom_float8` |
| `client/doom_web.py`, `client/web/{index.html,app.js,oraws.js}` | the browser client and its bridge |
| `tests/client_query_check.py` | the client SQL vs CedarDB (assets, music, sound events/loops, camera poses, interpolated frames) |
| `tests/client_run_check.py` | the desktop client end to end vs CedarDB |
| `tests/client_ui_smoke.py` | the desktop client's single-player flow, scripted |
| `tests/web_smoke.mjs`, `tests/bots.mjs`, `tests/web_browser_check.mjs`, `tests/web_latency.py` | browser path: smoke, bots, headless Chrome, bridge vs direct latency |
| `tests/determinism_check.py`, `tests/all_maps_smoke.py`, `tests/prepared_pipeline_smoke.py` | ports of the reference scripts (with `--cedar` comparisons) |

## CedarDB comparisons completed (after rebuilding the reference container)
The pending CedarDB-side checks were run on a freshly created CedarDB container (same image
v2026-11-18, 2 CPUs, reference `wad_loader.py` for all 36 maps + `client_query_check.py cedar-music`):
* `client_query_check.py` record/replay (8 runs, 3,777 tics): sound events 398/398 bit-exact; loop sets
  3,777/3,777 equal (1,319/1,320 rows bit-exact, the other within 3.3e-16); camera poses at
  interpolated alphas 22,662/22,662; frames at interpolated alphas 111/111 pixel-exact.
* `client_run_check.py`: 1,200/1,200 tic snapshots and sound events equal; client frames re-rendered on
  CedarDB at the client's (tic, alpha) 166/166 pixel-exact; `--split` 224/224.
* `determinism_check.py --cedar`: 36/36 playthroughs reproducible and equal to CedarDB.
* `all_maps_smoke.py --cedar`: 34/34 maps state equal and frame exact (E1M6 and E4M5 excluded; see below).

**CedarDB instability.** CedarDB Community v2026-11-18 (arm64) crashed with SIGSEGV twice: once right
after a tic on E4M5 failed with its own "more than one row returned by a subquery" error, and once at
the start of a run that followed a 36-map determinism playthrough that includes E4M5/E1M6. After each
crash its WAL recovery leaves a database on which every new game session hangs in its second tic
(two threads spinning, memory growing to ~5 GB); `docker restart` and reinstalling the runtime do not
help. Recovery: recreate the container and reload (`wad_loader.py` all maps, ~30 s, then
`client_query_check.py cedar-music`). All recorded ground truth lives in `oracle/reference_data/`, so
nothing is lost. Avoid E1M6/E4M5 in long CedarDB sessions; they are verified by their own scenarios.
