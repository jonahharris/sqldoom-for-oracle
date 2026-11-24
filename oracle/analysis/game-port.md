# Game loop: SQLDoom's game tic on Oracle (phases 1–6)

## Phase 6 (2026-11-24): the clients, sound, music, interpolation

The playable desktop client (`client/doom_client.py`: single player with the whole flow, deathmatch via
`--join`), the browser client (`client/doom_web.py` + `client/web/`), sound and music data and queries,
and the camera interpolated between tics: [clients.md](clients.md).

## Phase 5 (2026-11-23): the deathmatch server

The server layer of CedarDB's multiplayer — player accounts with no table grants, the `api_*` functions
and views (caller from `SYS_CONTEXT('USERENV','SESSION_USER')`, no slot parameter), per-slot frame views,
spectators, the referee (heartbeat, 35 Hz, idle reaping, lobby, seat turnover, rotation, warm-up) — is
ported: [multiplayer-server.md](multiplayer-server.md) (security model, API, referee, verification).
`game_mp.py` stays as the phase-3 benchmark loop; `client/referee.py` + `client/api_client.py` are the
server and the player side.

* Reference → Oracle: 42 `api_*` → `sql/13_api.sql` (definer-rights functions) + `client/api_install.py`
  (views generated from `game_api.py`'s statements, as `install_api_views` does from `sql/client`); 39
  `doom_mp_reap/_referee_*/_request_all/_intermission_*/_next_map/_rotate`, `mp_stats` → package
  `doom_mp` (`sql/12_mp_server.sql`); `doom_server.py` → `client/referee.py`; `scripts/add_player.py`,
  `add_spectator.py`, `setup_roles.py` → `client/accounts.py` over the `DOOM_ADMIN.DOOM_ACCOUNTS` broker
  (`sql/12_api_admin.sql`); `install_match_frame_views` → `api_install.install_frame_views`.
* The tic is one SERIALIZABLE transaction (`doom_mp.tic`); `ROWDEPENDENCIES` on the input and join
  tables keeps Oracle's serializability check row-level (optimization-log.md, "Phase 5").
* A recorded API session (5 accounts, 848 tics over a rotation E1M1 → E1M2, joins, the lobby, a reap)
  replays equal: 850/850 table snapshots, 675/675 per-slot frames and 14/14 automaps pixel-exact,
  19,079/19,083 call results (the rest: a wall-clock lobby window).
* Two players through the API keep 35.0 Hz, 93 % of frames within 28.6 ms.


## Phase 4 (2026-11-23): every map, the level flow, the screens

**All 36 maps.** `setup_db.py` now loads every map of `freedoom1.wad` (E1M1–E4M9, map_id 1–36 in
WAD order, so E1M1–E1M3 keep ids 1–3); CedarDB was reloaded with the reference's own
`wad_loader.py` (all maps, same ids). The renderer precompute (`04_precompute.sql`: `bsp_steps`,
`render_segs_ext`, texture strings) and the game's derived tables (`linedef_geom`,
`sector_adjacency`) cover every map; `doom_hybrid` and `doom_game` load a map's static data on its
first use. Every map has a smoke run (`smoke_<map>`: level start, 400 tics of the TPC-DOOM command
stream at the episode's skill — E1 2, E2 3, E3 1, E4 4 — frames every 50 tics) recorded on CedarDB
and replayed on Oracle: see feature-coverage.md for the counts.

**Two reference behaviours found on the new maps, reproduced exactly:**
* *BSP deeper than 40 levels* (E1M4 43, E3M7 52, E4M1 56, E4M2/E4M4/E4M8/E4M9 42–49): renderer.sql
  orders the visible subsectors by `SUM(1::bigint << (40 - depth))` over each leaf's back-side
  steps; CedarDB's shift count wraps modulo 64 (`1 << -1 = -2^63`, `1 << -2 = 2^62`), so on such
  maps the order — and with it the player sector (psprite light) and the occlusion/tie order — is
  not front-to-back. `doom_hybrid` carries the same 64-bit key down its traversal (exact NUMBER
  sums) and sorts by it on those maps (E1M4: a weapon sprite lit by the wrong sector, 3,505 pixels,
  before the fix). The ordinary maps keep the plain front-first traversal (identical order).
* *The noise flood's UPDATE … FROM*: `doom_cs_monster_noise` joins `monster_ai` to the flood's
  `(sector, block)` rows; a sector reached both unblocked and through one sound-blocking line is
  two rows, and CedarDB rejects an UPDATE … FROM that matches a target row twice ("more than one
  row returned by a subquery used as an expression") — the whole tic fails and the client drops it
  (`doom_client.run_game_tic`: rollback, next frame). On E1M6 and E4M5 a weapon fired near such
  lines fails every tic (379 of 400 in the smoke runs; the fire is never consumed). `cs_monster_noise`
  raises the same error before writing anything; the recorders store the failed tic, the replays
  require Oracle to fail it too and compare the (unchanged) state. `smoke_e1m6_nofire` /
  `smoke_e4m5_nofire` cover those maps without firing.

**The level flow and the meta game** (`sql/07d_flow_schema.sql`, `07e_flow_catalogs.sql`,
`10_flow.sql` package `doom_flow`, additions to `doom_game`):

| Reference | Oracle |
|---|---|
| 06 `doom_finish_level` | `doom_flow.finish_level` |
| 30 `doom_carry_player` | `doom_game.carry_player` (each statement tests a live source, as the reference) |
| 41 `doom_enter_level(.., from_map, from_player)` | `doom_game.enter_level(map, player, skill, from_map, from_player)` (+ cheat buffer reset; `doom_reset_stage` also clears `automap_view`) |
| 41 `doom_level_exit`, `doom_after_intermission` | `doom_flow.level_exit`, `after_intermission` |
| 33 `doom_intermission_begin/_accelerate/_tic` | `doom_flow.intermission_*` (ExM9 routing, secret exits, tally state machine) |
| 36 `doom_finale_begin/_tic/_advance` | `doom_flow.finale_*` |
| 31 `doom_menu_input` | `doom_flow.menu_input`, `set_screen` |
| 32 `doom_save_game`, `doom_load_game` (+ loader 00/01 materialize) | `doom_flow.save_game`, `load_game`, `materialize_render_segs/things` (BSP location with the reference's float4 `(tx - n.x)` side test: `doom_game.locate_thing`) |
| 38 `doom_cheat_key` | `doom_flow.cheat_key` (PostgreSQL `SUBSTRING`/`RIGHT` semantics for short buffers; `''` is NULL) |
| 41 `doom_demo_begin/_play/_stop`, `doom_attract_start/_stop/_tic` | `doom_flow.demo_*`, `attract_*` |
| 40 `doom_run_game_tic`: demo playback/recording | `doom_game.run_tic` (one PK read of `screen_state` a tic when no demo is active) |
| 44 `doom_automap_touch/_pan/_zoom/_toggle/_fit` | `doom_flow.automap_*` (fit: CedarDB numeric division keeps `s1 + p2 + 1` digits, truncated) |
| client `stages.sql`, `spawn_pose.sql`, `level_stats.sql`, `weapon_slot.sql`, `weapon_cycle.sql`, `game_tick_finish.sql` (screen, demo_active) | `game_api.STAGES_SQL`, `SPAWN_POSE_SQL`, `LEVEL_STATS_SQL`, `doom_flow.weapon_slot/_cycle`, `FINISH_SQL` |
| client `render_screen.sql`, `render_automap.sql` | `doom_screen.render_screen(tics)`, `render_automap(map, player)` (`sql/11_screens.sql`) |

The orchestration stays where the reference has it — the client decides *when* to call
`level_exit`, the 35 Hz intermission/finale/attract steps and `enter_level` from the tic snapshot,
exactly as `doom_client.py` does; every decision's inputs and every effect are in the database.

**Verification: flows** (`tests/flow_lib.py`, `flow_defs.py`, `run_flow.py`). A flow is a script
against the reference client API, run on CedarDB with every call logged and every state table
snapshotted after it (all map-scoped game tables of the touched maps + `screen_state`, save slots,
`save_*`, demos), plus 3-D, screen and automap frames. The Oracle replay executes the logged calls
and compares each result, snapshot and frame. See feature-coverage.md for the 14 flows.

**Screens** (`doom_screen`): one pipelined call per frame, the renderer's `(y, pal, hex)` rows
(palette indices after COLORMAP level 0; holes black). Static WAD data cached in package state:
patch pixels with per-row opaque spans, full-screen backgrounds and tiled finale flats as hex rows
(after COLORMAP). Per frame only the patches over the background are painted (pixels carry a frame
stamp instead of a 64,000-entry reset) and a row nobody wrote is emitted as its background string.
Timings: optimization-log.md, "Phase 4".

### Phase 4: what remains

* Smoke runs sample 8 frames per map (296 frames on the 34 new maps + E1M1–E1M3); long, frame-dense
  recordings exist only for E1M1–E1M3 and the flows. `render_optimized.sql` / `render_baseline.sql`
  (the pure-SQL renderers, not on the live path) do not carry the deep-BSP and clamped-stable-id
  fixes and are only verified on E1M1.
* Serial single-session play on the heaviest maps (tic 6–7 ms there) fits fewer periods than on
  E1M1; pipelined / split modes are needed for 35 Hz.
* Not ported (later phases): music/sound assets and loops, the api role layer, the referee (phase 5: ported; music assets still empty, as on the CedarDB reference).

### Notes for the later phases (DB-side pieces they will need)

* **Clients / sound** — not loaded or ported yet: `sound_assets`, `music_assets`, `map_music`
  (the reference loader's audio tables), `client/sound_loops.sql` (mover and chainsaw loops) and
  `client/stage_music.sql`; the screen frames are ready (`doom_screen`), as are the flow calls the
  client loop makes (`game_api` / `doom_flow`). A playable client must run the 35 Hz intermission,
  finale and attract steps and pass the skull blink counter to `render_screen`, as doom_client.py does.
* **Multiplayer server layer** — `doom_mp_level_done` already ends a deathmatch level; the referee's
  intermission (`mp_match.intermission_until`) and rotation (`mp_rotation`) can use `doom_flow`'s
  routing tables; `screen_state` is a single global row (as in CedarDB), so per-player screens in a
  server would need a per-role variant — the reference has none.
* The reference's failing tics (f2 in optimization-log.md, phase 4) also fail in deathmatch on those maps.

### Phase 4 files

| File | What |
|---|---|
| `sql/07d_flow_schema.sql`, `07e_flow_catalogs.sql` | screen_state, g_automap_view, demos, demo_tics, save_slots, save_*; menu_items, menu_decor, finale_defs (exported from CedarDB) |
| `sql/10_flow.sql` | package `doom_flow` |
| `sql/11_screens.sql` | package `doom_screen` |
| `sql/08_game.sql` | enter_level/carry_player/locate_thing, demo record/playback in run_tic, the noise-flood error, IDMYPOS text |
| `sql/06_hybrid.sql` | deep-BSP sort key |
| `client/game_api.py` | flow/screen statements, FINISH_SQL screen + demo_active, level_start sets the screen |
| `client/screen.py` | a screen or automap frame to PNG |
| `client/setup_db.py`, `setup_game.py` | all maps; `--flow-schema`, `--flow-only` |
| `tests/flow_lib.py`, `flow_defs.py`, `run_flow.py` | the flows (record on CedarDB, replay on Oracle) |
| `tests/scenario_defs.py` | 36 + 2 smoke scenarios; `scenario_lib.py` `thing_health` op |
| `tests/record_scenarios.py`, `run_game_correctness.py` | failed (dropped) tics recorded and required |
| `tests/map_tic_timing.py` | test T per map, CedarDB and Oracle |
| `reference_data/flows/*`, `reference_data/scenarios/smoke_*` | the recordings |

```sh
.venv/bin/python oracle/client/setup_db.py && .venv/bin/python oracle/client/setup_game.py   # all maps
.venv/bin/python oracle/tests/run_flow.py replay [names]          # flows vs CedarDB
.venv/bin/python oracle/tests/run_flow.py record [names] --force  # CedarDB ground truth
.venv/bin/python oracle/tests/run_game_correctness.py --scenario 'smoke_*'
.venv/bin/python oracle/client/screen.py --screen main --out main.png
```

---


## Phase 3 (2026-11-21): every game feature CedarDB implements, and deathmatch

**Single player, full coverage.** `doom_game` ports every branch of CedarDB's game SQL (the
inventory with the evidence for each feature: [feature-coverage.md](feature-coverage.md)). Besides
the TPC-DOOM E1M1 run (1,200/1,200 tics equal), **178 scripted scenarios** recorded on CedarDB
(`reference_data/scenarios/`, 49,806 tics) replay equal on every tic in every state table, and the
1,055 frames recorded in 15 of them (moving floors/ceilings, crushers, stairs, donut, lights,
strobes, switch textures, flat changes, teleport, scroller, BFG, floaters) are pixel-exact. Every
one of the 135 line specials has a scenario (128 change state on CedarDB in it); crushers kill the
player with god mode off; damaging floors, nightmare respawn, BFG spray, plasma, chainsaw, skills
0/3/4 are covered. Not exercised (no scripted path reaches them): a monster crossing a teleport line,
the lost soul's charge hitting the player, boss specials (no E1M1–E1M3 boss). CedarDB does not
implement sector specials 10/14 (door timers).

**Deathmatch.** `doom_game.run_mp_tic(map, skill, slot1..slot4)` is CedarDB's `doom_run_mp_tic`:
inputs folded per slot, claimed slots respawned, one shared world tic (`run_tic_core`, the port of
`doom_run_tic_core` with its per-player stage groups; single player is the same core with three NULL
slots), `doom_mp_level_done`. Five CedarDB deathmatch recordings (E1M1 2 and 4 players with and
without monsters, a rocket duel, E1M2 3 players at skill 3; 6,250 tics, frags, suicides, deaths to
monsters, respawns, -altdeath item respawns, -timer level end) are **equal on every tic**, and all
**3,364 recorded per-player frames are pixel-exact** (replay), as are the live frames of
`game_mp.py --check` (2 players pipelined 1,000/1,000, 4 players 764/764, duel 600/600).

**Fastest multiplayer loop** (`client/game_mp.py`): one tic session (inputs + `run_mp_tic` + commit
in one round trip) and one render session per player, frames concurrent, optionally pipelined
behind the next tic. Live bots, E1M1, all four start slots ticked as CedarDB's referee does,
1,200 tics, warm-up 60 (`benchmark/results/p3_mp_*.json`; budget 28.6 ms):

| players | mode | tic mean / p95 | frame mean (per player) | period mean / p50 / p95 / p99 | periods ≤ 28.6 ms | frames/s total |
|---|---|---|---|---|---|---|
| 1 | serial | 4.00 / 4.47 | 16.9 | 20.9 / 19.7 / 27.3 / 29.9 | 97.8 % | 48 |
| 1 | pipelined | 4.28 / 4.87 | 17.3 | 17.6 / 16.5 / 24.6 / 27.1 | **99.6 %** | 57 |
| 2 | serial | 5.54 / 7.15 | 19.1, 21.7 | 28.1 / 28.4 / 33.7 / 37.0 | 52.4 % | 71 |
| 2 | pipelined | 5.91 / 8.25 | 19.9, 22.4 | **23.6** / 23.7 / 29.4 / 34.0 | **92.4 %** | 85 |
| 3 | serial | 6.42 / 8.19 | 25.2, 23.2, 20.1 | 33.3 / 31.7 / 37.7 / 96.5 | 11.5 % | 90 |
| 3 | pipelined | 8.52 / 11.88 | 31.3, 28.5, 25.0 | 33.3 / 25.9 / 37.6 / 307.6 | 74.4 % | 90 |
| 4 | serial | 7.93 / 9.19 | 26.5, 21.4, 24.4, 27.8 | 40.5 / 33.4 / 42.8 / 316.4 | 18.0 % | 99 |
| 4 | pipelined | 9.31 / 13.43 | 33.8, 28.4, 30.5, 35.6 | 41.4 / 27.4 / 43.4 / 478.5 | 62.2 % | 97 |

Paced at 35 Hz (`--realtime`), **two players pipelined hold 35.0 periods/s over 1,200 tics with
no late period** (`p3_mp_2p_pipelined_rt.json`; per-player frames p95 25.4 / 27.8 ms, 97.7 % of
frames ≤ 28.6 ms; the 1-player loop holds 35 Hz with ≈ 40 % of the CPU idle).
Oracle Free runs on 2 CPUs: two frames (≈ 20 ms each) plus a 5–6 ms tic are ≈ 46 ms of CPU per
period, so two players are at the CPU limit (pipelined mean 23.6 ms ≈ 46/2); three or four
players need 66–95 ms of CPU per period and cannot fit 28.6 ms on two CPUs, and with four or five
busy sessions Oracle Free's CPU cap (resource manager, `resmgr:cpu quantum`) stalls a few percent of
periods for 0.3–0.5 s (the p99 column). Total throughput saturates at ≈ 85–100 frames/s.

**Tic latency vs CedarDB** (same host, 4 slots ticked, bots, tic only; Oracle: input rows +
`run_mp_tic` + commit, `tests/mp_profile.py`; CedarDB: `doom_run_mp_tic` call after the inputs,
`record_mp_reference.py --timing-only`; 700 tics, warm-up 60–100):

| slots claimed | Oracle mean / p95 (ms) | CedarDB mean / p95 (ms) |
|---|---|---|
| 1 | 3.87 / 4.25 | 3.89 / 4.58 |
| 2 | 5.52 / 6.97 | 5.24 / 9.77 |
| 3 | 5.91 / 7.29 | 6.70 / 11.34 |
| 4 | 7.25 / 9.07 | 7.42 / 13.34 |

Single player on the same day: test T 3.28–3.31 ms with the phase-3 package vs 3.24 ms with the
phase-2 package (the per-player refactor costs ≈ 1–2 %); TPC run, `game.py --check` serial,
pipelined and split: 1,200/1,200 frames exact.

### Multiplayer architecture

* **State**: `g_mp_match` (the match as a row: -timer, -altdeath, monsters, -respawn),
  `g_mp_players` (one slot per player start; `role_name` = holder), `g_mp_join_requests`,
  `g_mp_inputs` (`sql/07c_mp_schema.sql`). Every other table is the single-player `g_*` table; all
  players share one world. `lv_mp_players` exposes the slots to the renderer (the PLAY sprite's
  green range is translated per slot).
* **Match start** (`mp_configure`, `mp_start`, `mp_claim` = the owner-side core of `api_join`,
  `mp_open`): the reference's order — level reset, slots for types 1–4, every slot respawned on a
  random free deathmatch start (`prandom(p, level_tics, 41)`) then vacated, -nomonsters applied.
* **Tic** (`run_mp_tic`): `MAX(seq)` of the input rows; slots with a join request respawned (frags
  reset); every slot's input rows folded (latest movement, summed turn, any press) into
  `g_game_tic_commands` in **one MERGE**; then `run_tic_core(p1..p4)`: clock/plan per slot, use per
  slot, specials and doors once, movement and death per slot, secrets/discover/cross/pickups per
  slot, weapon + hitscan per slot, then the world stages once with the **world player** rotating over
  the live held slots (`level_tics mod n`): projectiles (all players are targets), sound (world cues
  built once a tic, player cues per slot), monsters (retarget drops dead or unheld targets),
  -altdeath item respawn, sector effects per slot, thing physics, boss; then `mp_frags` (+1 for the
  killer; suicide or the world −1; messages) and per slot the PLAY frame and P_DeathThink respawn
  (attack or use after 35 tics); `mp_level_done` (timer, exit lines used/crossed, exit floor, boss).
* **Client** (`game_mp.py`): the referee session sends all players' inputs (array binds), the tic
  and the commit as one PL/SQL block — one round trip per tic. Each player has its own render
  session (renderer package state per session, ≈ 70 MB); a frame is one statement
  (`game_api.FRAME_SQL`: the camera pose computed in SQL and handed to `render_frame` through
  `doom_game.shortest`, which reproduces the decimal a client would have sent). `--pipelined`: the
  render sessions pin a read-only snapshot of tic N (one round trip each, in parallel) before tic
  N+1 starts and render while it runs. `--check MATCH` replays a recorded match's inputs and compares
  every recorded frame and pose; `--realtime` paces at 35 Hz.

### Phase 3 files

| File | What |
|---|---|
| `sql/07c_mp_schema.sql` | deathmatch tables |
| `sql/08_game.sql` | + `run_tic_core`, `run_mp_tic`, `mp_*`, `cs_item_respawn`, `cs_player_pose`, `shortest` |
| `sql/09_live_views.sql` | `lv_mp_players` over `g_mp_players` |
| `tests/scenario_lib.py`, `scenario_defs.py` | scenario model (mods, pose ops, commands) and the 178 scenarios |
| `tests/record_scenarios.py` | record scenarios on CedarDB (`reference_data/scenarios/<name>/`) |
| `tests/scenario_evidence.py`, `coverage_matrix.py` | what each CedarDB recording shows; the line-special matrix |
| `tests/mp_lib.py`, `record_mp_reference.py` | match configurations, scripted bots; record a deathmatch (+ per-player frames, `--timing-only`) |
| `tests/run_game_correctness.py` | `--scenario [names]`, `--mp NAME`, `--continue`, `--dump DIR` |
| `tests/mp_profile.py` | deathmatch tic stages / latency |
| `client/game_mp.py` | the multiplayer loop (serial / pipelined / realtime / check) |
| `client/game_api.py` | + `FRAME_SQL`, `render_live`, cheats parameter |

```sh
.venv/bin/python oracle/client/setup_game.py --mp-schema --package-only    # (setup_game.py installs 07c too)
.venv/bin/python oracle/client/setup_game.py --live-only                    # lv_mp_players + doom_hybrid_live
.venv/bin/python oracle/tests/run_game_correctness.py --scenario            # all 178 scenarios (~45 min)
.venv/bin/python oracle/tests/run_game_correctness.py --mp dm_e1m1_4p       # a deathmatch, state + frames
.venv/bin/python oracle/client/game_mp.py --players 2 --pipelined [--realtime]
.venv/bin/python oracle/client/game_mp.py --check dm_e1m1_2p --pipelined
.venv/bin/python oracle/tests/record_scenarios.py [names]                   # CedarDB ground truth
.venv/bin/python oracle/tests/record_mp_reference.py dm_e1m1_2p [--timing-only --players N]
```
Never run two of these against the same map at once: they share the `g_*` tables (and
`mp_cleanup` empties every match table).

---

# Phase 1: SQLDoom's single-player game tic on Oracle

Status (2026-11-21): the real SQLDoom game tic runs inside Oracle AI Database 26ai Free
(package `doom_game`, `sql/08_game.sql`) and is **equal to CedarDB at the level start and after
every one of the 1,200 tics** of the TPC-DOOM E1M1 run: every state table the tic reads or writes,
the `finish_game_tic` snapshot, the `sound_due` flag and the sounds fetched. The hybrid renderer
draws the **live** game state (`doom_hybrid_live` over the `lv_*` views): **1,200/1,200 frames
pixel-exact** against the recorded CedarDB frames, camera poses bit-equal.

| | Oracle (this port) | CedarDB, same host (2 CPUs) |
|---|---|---|
| test T tic (execute + sounds + finish), mean / p50 / p95 / max | **3.04 / 2.98 / 4.17 / ≤ 10 ms** (phase 2; phase 1: 3.38 / 3.31 / 4.53 / 28.4) | 3.92 / 3.68 / 4.65 / 12.8 ms |
| `run_tic` call + commit, mean / p50 / p95 | 2.56 / 2.55 / 3.58 ms (phase 1: 2.91 / 2.89 / 3.97) | — |
| first tic / slowest warm-up tic | 5 ms / 28 ms | 632 ms / 16.0 s (query compilation) |
| level start (`enter_level` + IDDQD + IDKFA) | 55 ms | 422 ms |

Test R on Oracle (tic as in test T, then `camera_pose` and the frame, warm-up 120 tics excluded).
**Phase 2** (round 4 renderer + tic fixes, `benchmark/results/game_loop_r4.json`; the budget is
1000/35 = 28.6 ms per period):

| mode | tic mean / p95 | frame mean / p95 | period mean / p50 / p95 / p99 / max | periods ≤ 28.6 ms |
|---|---|---|---|---|
| serial, one connection (test R) | 3.20 / 4.28 | 19.62 / 26.22 | 23.15 / 24.47 / 30.48 / 32.09 / 33.80 | 83.3 % |
| pipelined | 3.77 / 6.07 | 20.24 / 26.93 | 20.99 / 22.34 / 27.70 / 29.87 / 36.59 | 97.5 % |
| serial, split frame (`--split`) | 3.29 / 4.49 | 13.20 / 18.38 | 16.69 / 17.17 / 22.47 / 25.58 / 32.53 | 99.9 % |
| pipelined, split frame | 3.98 / 6.32 | 14.34 / 19.44 | 15.20 / 15.91 / 20.35 / 21.93 / 28.32 | **100 %** |

Same day, phase-1 code: serial 24.74 / p95 32.18 / 69.2 %, pipelined 23.22 / p95 30.57 / 80.5 %.
Paced at 35 Hz (`--realtime`, 1,200 tics): pipelined, serial + split and pipelined + split all hold
35.0 Hz with 0 late periods.
`--split` renders each frame on two sessions in parallel (one screen-column range each, the exact
same renderer; see `optimization-log.md`, "Hybrid round 4"). All runs 1200/1200 frames exact.

Phase 1 (for reference):

| mode | tic mean / p95 | frame mean / p95 | tic+frame (period) mean / p50 / p95 | tpsD | RTF | periods ≤ 28.6 ms |
|---|---|---|---|---|---|---|
| serial, one connection (TPC-DOOM test R) | 3.63 / 5.13 | 20.37 / 27.16 | 24.33 / 25.31 / 31.78 | 41.1 | **1.17** | 72.8 % |
| pipelined (frame N on a 2nd connection while tic N+1 runs) | 4.16 / 6.69 | 21.37 / 28.25 | 22.13 / 23.59 / 29.01 | 45.2 | **1.29** | 93.2 % |
| pipelined, paced at 35 Hz (`--realtime`, 600 tics) | | | | 35.0 Hz held | 1.00 | 99.0 %, 0 late |

The frame (≈ 20 ms, 2 CPUs shared with the tic) is now the whole budget; the tic is ≈ 14 % of a
period. Serial mode averages under 28.6 ms but its p95 does not fit (the renderer's own p95 is
27 ms); pipelined mode keeps 35 Hz.

## Files

| File | What |
|---|---|
| `tests/record_game_reference.py` | CedarDB ground truth: replays the command stream like `record_reference.py`, snapshots 40 tables after the level start and every tic (stored when changed; `sidedefs`/`render_segs` as diffs from tic 0), plus every tic's command, `sound_due`, fetched sounds, `finish_game_tic` dict, camera pose and CedarDB timings. `--timing-only` = test T on CedarDB. |
| `reference_data/e1m1_game/` | the recording (1.8 MB): `tables/*.parquet`, `changes.json`, `tics.json`, `run.json` |
| `sql/07_game_schema.sql` | `g_*` game-state tables (REAL→`BINARY_FLOAT`), extra catalogs' DDL, `linedef_geom`, `sector_adjacency` |
| `sql/07b_game_catalogs.sql` | generated by `client/export_game_catalogs.py` from CedarDB: `doom_constants`, `pickup_defs`, `pickup_messages`, `chase_dir_defs`, `thing_role_defs`, `thing_blocking_defs`, `sector_special_defs`, `thing_sound_defs`, `level_pars`, `boss_actions` |
| `sql/08_game.sql` | package `doom_game`: level start, cheats, the tic (≈ 4,100 lines) |
| `sql/09_live_views.sql` | `lv_*` views: the `g_*` tables in the shape of the renderer's `st_*` tables, as tic −1 |
| `client/setup_game.py` | installs 07, 07b, the derived tables, 08, 09, generates `doom_hybrid_live` from `06_hybrid.sql` (`st_<t>` → `lv_<t>`), gathers `g_*` statistics at a level start |
| `client/game_api.py` | the client statements (level start, tic, sounds, finish snapshot, camera pose) |
| `client/game.py` | the 35 Hz loop: tic + frame per tic, serial / `--pipelined` / `--realtime`, `--check` against the CedarDB frames |
| `tests/run_game_correctness.py` | replay + compare every table after every tic; `--continue` reports the first divergence per table |
| `tests/game_profile.py` | per-stage timing (`doom_game.set_debug(1)`), `--test-t` for the TPC-DOOM test T measure |

Commands:
```sh
.venv/bin/python oracle/client/setup_game.py                 # schema + catalogs + package + live renderer + stats
.venv/bin/python oracle/tests/run_game_correctness.py        # 1200/1200 equal (≈ 100 s)
.venv/bin/python oracle/client/game.py --check               # test R, live frames vs CedarDB
.venv/bin/python oracle/client/game.py --pipelined --check   # 2-connection pipeline
.venv/bin/python oracle/tests/game_profile.py --no-debug --test-t
.venv/bin/python oracle/tests/record_game_reference.py [--timing-only]   # needs the CedarDB container
```

## Architecture

* **State lives in tables, only static data in package state.** Every table the reference tic
  writes has a `g_` twin (the renderer's own tables are untouched). The package caches, per map,
  the constants, line geometry, the BSP and ssector→sector map, a 128-unit line grid, and the
  catalogs (combat, frame, sound, chase-direction defs). The only other package variables are
  per-call scratch buffers (`s_fl/s_ce`, the current sector heights) that are reloaded every tic
  after the movers have run (`s_valid` is reset at the start of every tic and after the doors).
* **One PL/SQL call per tic** (`doom_game.run_tic`), mirroring `doom_run_tic_core`: the same stage
  order, the same plan bits gating each stage (`cs_plan`, `cs_monster_plan`), the same stage trace
  (`g_tic_trace` equals CedarDB's `tic_trace` every tic).
* **SQL where the reference statement is a cheap set operation** (state updates, damage
  aggregation, specials, pickups, inserts/merges), **PL/SQL where per-row geometry dominates**:
  movement collision, the use trace, line crossings, hitscan aiming and pellets, missile sweeps,
  monster sight, chase steps, the noise flood, BSP descents. Spatial work uses a static grid of
  line bounding boxes; every grid query returns a superset of the lines the reference's exact
  tests can accept, and the reference's own tests (bounding box, strict side products) are then
  applied, so the result is identical (argument per use in the code comments).
* **Live rendering without copies.** The renderer reads `st_<table> WHERE tic = :tic`; the live
  variant reads `lv_<table>` views over `g_*` (REAL widened to `BINARY_DOUBLE`, exactly what the
  recording stores), tic −1. Nothing is copied per tic. In pipelined mode the frame's connection
  pins a read-only snapshot right after the tic commits.

### CedarScript → Oracle mapping

| Reference (sql/runtime/functions) | Oracle (`doom_game` unless noted) |
|---|---|
| 00 `doom_prandom` | `prandom` (same table and hash, NUMBER arithmetic, `PRAGMA UDF`) |
| 01 `doom_const` | `load_map` → `k(name)` + hot constants |
| 02 `doom_sector_at` | `sector_at` (static BSP; ssector → `fsec` of its lowest render seg) |
| 03 `doom_weapon_decision` (view), 20 `doom_cs_weapon_state`, 21 `doom_cs_weapon` | `cs_weapon` (one SELECT + PL/SQL state machine) |
| 04 `doom_reset_stage`, 05 `doom_spawn_player`, 41 `doom_enter_level` | `reset_stage`, `spawn_player`, `enter_level` (reset from the static tables, which hold the map as loaded) |
| 07 `doom_cheat_arsenal`, 38 `doom_cheat` | `cheat_arsenal`, `cheat` |
| 08 `doom_cs_begin`, 09 `doom_cs_clock`, 10 `doom_cs_plan` | `cs_begin`, `cs_clock`, `cs_plan` |
| 11 `doom_cs_use` | `cs_use` (PL/SQL trace over the lines) |
| 12 `doom_cs_activate_specials` | `cs_activate_specials` (SQL, every branch: doors, floors, lifts, donut, switches, one-shots, raises, stairs (PL/SQL walk), lights, teleport, ceilings, crushers, stop) |
| 13 `doom_cs_doors` | `cs_doors` (buttons SQL; mover step PL/SQL; plane/crush/render_segs SQL) |
| 14 `doom_cs_movement_mode`, 15 `doom_cs_move`, 16 `doom_cs_turn`, 34 `doom_cs_death` | `cs_movement_mode`, `cs_move` (PL/SQL, grid), `cs_turn`, `cs_death` |
| 17 `doom_cs_secret`, 37 `doom_cs_discover`, 18 `doom_cs_cross`, 19 `doom_cs_pickups` | `cs_secret`, `cs_discover`, `cs_cross` (PL/SQL), `cs_pickups` (SQL) |
| 22 `doom_cs_hitscan_fire`, 23 `doom_cs_hitscan_apply` | `cs_hitscan_fire` (PL/SQL), `cs_hitscan_apply` (SQL) |
| 24 `doom_cs_projectiles` | `cs_projectiles` (spawn + swept collision PL/SQL; radius/BFG/damage/thrust/advance SQL) |
| 25 `doom_cs_sound`, 25a views | `cs_sound` (PL/SQL builds the eleven branches' rows, one FORALL insert) |
| 26 `doom_cs_monsters` and its 13 functions | `cs_monsters`, `cs_monster_plan/retarget/noise/think/step/move/float/chase/attack/barrel/blast/deaths/respawn` |
| 28 `doom_cs_sector_fx`, 29 `doom_cs_thing_physics`, 35 `doom_cs_boss` | `cs_sector_fx`, `cs_thing_physics`, `cs_boss` |
| 40 `doom_run_game_tic` / `doom_run_tic_core` | `run_tic` (single player; returns sound_due) |
| client `game_tick_finish.sql`, `camera_pose.sql`, `sound_events.sql` | `game_api.FINISH_SQL`, `CAMERA_SQL`, `SOUND_SQL` |
| 27 `doom_cs_item_respawn`, 39 `doom_mp_*`, 40 `doom_run_tic_core` (p1..p4) / `doom_run_mp_tic` (phase 3) | `cs_item_respawn`, `mp_*`, `run_tic_core`, `run_mp_tic` |
| 06, 30, 31, 32, 33, 36, 38 `doom_cheat_key`, 41 flow/demo/attract, 44 automap, demo record/playback in `doom_run_game_tic` (phase 4) | `doom_flow` (10_flow.sql), `doom_game.enter_level/carry_player/run_tic`, `doom_screen` (11_screens.sql) |
| 42 api (roles, security definer wrappers), 39 referee heartbeat/reaping/rotation (phase 5) | `sql/13_api.sql`, `doom_mp` (`sql/12_mp_server.sql`), `client/referee.py`, `client/api_install.py` |

Exercised and verified by the run: level start, cheats, clock/plan, movement/turn, use (manual door
1, blue-key door 26, a non-eligible lift switch, a plain wall), cross specials (a lift), doors and
lift movers, monsters opening doors, secrets, automap discovery, pickups (health bonuses, armor, a
dropped shotgun with shells), weapon switching, pistol/shotgun/chaingun hitscan with drops, rockets
with splash and thrust, imp fireballs (monster missiles hitting the player), monster melee and
hitscan attacks, noise alerts, chase steps, infighting retargets, pain, deaths, sounds. Not
exercised by this run (translated, untested): floor/raise/stairs/donut/light/teleport/ceiling/
crusher/stop specials, switch textures, one-shot activations, BFG spray, lost-soul/cacodemon
float and charge, monster teleports, nightmare respawn, crushing, damaging floors (god mode).

## Exactness: what had to match CedarDB

1. **Float types.** CedarDB keeps `real op real` and `real op literal` in single precision and
   rounds every write to a REAL column; `real op double` is double. REAL columns are
   `BINARY_FLOAT`, and every reference expression was typed: e.g. the missile wall sweep is
   entirely float4 (`f.vx*(ld.y2-ld.y1)`), `(v.x - pt.x)::float8` subtracts in float4 then widens,
   the monster cross test subtracts `ms.old_y - v1.y` in float4, the chase door test and the
   sound melee distance compute `sqrt(power(real,2)+...)` in float4.
2. **Oracle `POWER(binary_float, 2)` returns BINARY_DOUBLE**, unlike CedarDB's real `power`:
   squares are written `x*x`.
3. **`ROUND(double)` is half away from zero in CedarDB, half-even in Oracle** → `doom_game.rnd`
   (exact: `floor(|x|) + (|x| - floor(|x|) >= 0.5)`) for the 16.16 thrust sums. Casts
   double→int are half-even in both (`ROUND(BINARY_DOUBLE)` for dropped-item spawn coordinates).
4. **`RADIANS(x) = x * (pi/180)`, `DEGREES(x) = x * (180/pi)`** with the constant folded first
   (probed on 100,000 values; `x*pi/180` differs in 30 %).
5. **`LEAST`/`GREATEST` ignore NULLs in CedarDB** (Oracle returns NULL): one-sided lines'
   openings are handled explicitly.
6. **The client's REAL parameters.** psycopg2 sends a float as its decimal text; CedarDB types a
   plain decimal literal as numeric and converts it to REAL as `float(digits) / float(10^scale)`
   (not correctly rounded), and an exponent literal as double then float. Correct rounding was
   1 ulp off at tic 21 (turn −0.349242934758081). `doom_game.cmd_real` reproduces it; verified on
   all 661 distinct command values. The client sends `repr(float)`, as psycopg2 does.
7. Integer `/` truncates, `%` is `MOD`, `>>` on non-negative values is `FLOOR(x/2^n)`; numeric
   literals (`12.5`, `0.125`) stay exact in NUMBER and widen to double as in CedarDB.
8. Statement order and visibility are kept (e.g. a missile entering `explode` at age 0 is aged by
   the next statement to 1; pickups' ammo caps read the backpack the previous statement set).
9. Translation rules: `ON CONFLICT DO NOTHING` → `IGNORE_ROW_ON_DUPKEY_INDEX`; `UPDATE … FROM` /
   `DO UPDATE` → `MERGE`; `ARG_MAX` → `KEEP (DENSE_RANK LAST …)`; `BOOL_OR` → `MAX(CASE …)`;
   `IS DISTINCT FROM` → explicit NULL tests; `ORDER BY … LIMIT 1` → ordered PL/SQL selection with
   the same tie-breakers; `generate_series` → `CONNECT BY`; reserved words renamed (`raw`, `mode`,
   `level_pars.level` → `lvl`).
10. Recorder/compare details: `tic_trace` is not reset by `doom_reset_stage` (tic 0 holds the
    previous run's row; not compared at tic 0); `sound_events.event_id` follows insert order
    (compared without it, as saildoom does); the `finish_game_tic` REAL fields arrive from CedarDB
    as shortest float4 text, so they are compared as float32.

## Performance work (details in optimization-log.md, "Game loop phase 1" and "Hybrid round 4 / game loop phase 2")

Phase 2: the deterministic 22–31 ms tics (a door activating) came from the door MERGE's
`door_sectors` CTE joining every tag-0 sector for a back-sector door (61,250 intermediate rows that
the GROUP BY collapsed); the tag join now applies to tag doors only (no group changes), and the
CTEs referenced several times are `INLINE`. Join-order hints on `cs_monster_plan` (74 → 34 µs,
twice a tic) and the corpse INSERT (67 → 25 µs). `SESSION_CACHED_CURSORS = 1000` in the client's
session setup: the default 50 made most of the few hundred static statements re-parse on every
execution (69 parse calls a tic → 10) and let a rarely run statement be hard-parsed mid-run (a 98 ms
tic). Test T 3.57 → 3.04 ms mean (same day), max ≤ 10 ms.

Phase 1:

First correct version: `run_tic` 6.3 ms mean; final 2.9 ms (test T 3.38 ms). What mattered:
statistics on the `g_*` tables (and the live renderer's thing query: 6.9 → 1.0 ms a frame); a
line grid with exact superset queries (bounding boxes, and segment walks with a 1-unit margin for
sight lines and missile sweeps); fetching only rows that can matter (conservative SQL boxes,
static catalog caches instead of joins); the sound stage rebuilt in PL/SQL (364 → 184 µs);
sector heights read once per tic after the movers; forced nested loops on two small joins; and a
CTE that Oracle materialised in the finish snapshot (`/*+ INLINE */`: 2.1 → 0.22 ms).

Per stage, mean µs over 1,080 tics: begin 111, doors 187, move 232, secrets/pickups 246,
weapon 139, projectiles 307 (on missile tics), sound 184, monster plan/retarget 121,
think 325, step 265, chase 217, rest 73, tail (sector fx, physics, boss, trace) 177.

## Remaining work

**Phase 2 (speed) — done (round 4, above).** Pipelined + split frame fits every period of the
run (max 28.3 ms); serial + split all but one in 1,080; single-session serial 83 % (the frame,
≈ 20 ms mean / 26 ms p95, is the period). Phase-1 notes, kept for reference: the tic is ≈ 3 ms;
the frame (≈ 20 ms, p95 27 ms) is what keeps serial
test R from fitting every period. Tic: monster sight (176 µs) and steps could share one
segment-walk per monster; the five `cs_plan` calls (≈ 140 µs) could be derived incrementally;
pickups' SQL (130 µs) and movement's thing query; hitscan still scans all 1,175 lines per pellet
(a grid ray walk would cut shotgun tics); per-tic redo/undo of ≈ 100 row changes. Frame: the
hybrid renderer's own phases (walls 7.7, plane z 5.8 ms). The pipelined loop already holds 35 Hz.
The untested special branches need scenario recordings (saildoom's `scenarios.py` style) before
they can be claimed exact.

**Phase 3 (full tic + multiplayer) — done (see the top of this file).** Remaining:
* not exercised by any recording: a monster crossing a teleport line (`monster_teleports`), the lost
  soul's charge hitting the player, E1M8 boss specials; scripting a monster through a teleporter
  (e.g. luring one across E1M2's line 1219) would close the first;
* the client/meta flow is not ported (menus, save/load, intermission, finale, demos, the api role
  layer, referee heartbeat/reaping/map rotation): `game_mp.py` plays the owner/referee part itself;
* three or four players cannot fit 28.6 ms on Oracle Free's two CPUs (CPU-bound, plus the CPU-cap
  stalls); on more cores the render sessions scale (each player's frame is independent);
* the deathmatch tic still runs every per-player stage for unclaimed (dead) slots, as CedarDB's
  referee does; skipping them would change `level_tics` of those slots and so the state.
