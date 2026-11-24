# Project overview: results by phase

The long-form summary that used to open the README: what each phase built, what it measured, and
how it was verified. Commands are run from the repository root.

A pixel-exact, relational Doom renderer running inside **Oracle AI Database 26ai Free**
(`gvenzl/oracle-free:full`). Each frame (320×200: 320×168 3-D view + Doom's status bar) is
produced by **one prepared SELECT** executed with bind variables. The client only binds the
camera/game state, fetches 4,400 NUMBERs and decodes them into 64,000 palette indices.

Ground truth is the CedarDB SQLDoom renderer (`reference/sqldoom`), run for real over the
deterministic 1,200-tic TPC-DOOM E1M1 gameplay run (monsters, fireballs, barrels, doors, a lift,
weapon switches). Every renderer here is compared pixel-for-pixel against it.


## Results (1,080 measured frames, end to end, one session, prepared cursor, 0 hard parses)

| Renderer | p50 ms | p95 ms | Sustained FPS | Exact vs CedarDB |
|---|---|---|---|---|
| CedarDB SQLDoom reference (2 CPUs, same host) | 16.7 | 21.2 | ≈ 60 | — |
| `render_baseline.sql` — faithful Oracle port | 5,044 | 7,922 | 0.2 | 48/48 sampled |
| `render_optimized.sql` — pure SQL, one SELECT (round 2) | 137 | 188 | 7.8 | 1,200/1,200 |
| `render_hybrid.sql` — SQL state + PL/SQL geometry/raster (round 3) | 22.5 | 27.9 | 47.6 (max frame 31.6 ms) | 1,200/1,200 |
| `render_hybrid.sql` — round 4 | 21.5 | 26.5 | **50.1** (mean 19.96, p99 27.6) | 1,200/1,200 |
| `render_hybrid_split.sql` — round 4, one frame on both CPUs (2 sessions) | 14.0 | 17.4 | **76.2** (mean 13.1, p99 19.5) | 1,200/1,200 |

The pure-SQL renderer is 36× faster than the port, and resolves visibility exactly at interval
level, so it generates exactly one row per visible pixel. Its floor on this 2-CPU Free instance is
the per-row cost of Oracle's row-source engine, which no Oracle option tested moved
(In-Memory, VECTOR, MODEL, transpiler).

The hybrid keeps the single prepared SELECT, state retrieval in SQL, and static data cached per
session. It moves the geometry and pixel loops into PL/SQL. It reaches 47.6 FPS sustained with every one of 1,080 measured frames ≤ 33 ms (≈ 70 MB PGA per session; 2 concurrent players ≈ 92 FPS total), running
interpreted, because native compilation is unsupported on arm64 Free.

Round 4 (speed for the game loop) made the single-session renderer ≈ 5 % faster (interpreted
PL/SQL is now close to its per-pixel floor) and added a split mode: Oracle Free has 2 CPUs and no
parallel query, so two sessions each render one screen-column range of the *same* frame with the
same exact renderer and the client joins the two hex halves of each row — frame latency ≈ 13 ms
mean, 17 ms p95.

### Live game loop (phase 2)
The CedarDB game tic itself is ported (`sql/08_game.sql`, package `doom_game`, set-based SQL +
PL/SQL). Over the 1,200-tic E1M1 run every tic's world state equals CedarDB's (38 tables, floats to
1e-9), and live frames rendered from the live tables are 1,200/1,200 pixel-exact.
Tic (test T) 3.0 ms mean, p95 4.2 (CedarDB on the same host: 3.9 ms). Each 35 Hz period is one
tic + one frame; budget 1000/35 = 28.6 ms (`oracle/benchmark/results/game_loop_r4.json`, every run
1,200/1,200 live frames pixel-exact):

| mode | period mean | p95 | p99 | max | periods ≤ 28.6 ms |
|---|---|---|---|---|---|
| serial, one session (TPC-DOOM test R) | 23.2 | 30.5 | 32.1 | 33.8 | 83.3 % (phase 1, same day: 69.2 %) |
| pipelined (tic N+1 ∥ frame N) | 21.0 | 27.7 | 29.9 | 36.6 | 97.5 % (phase 1, same day: 80.5 %) |
| serial, split frame | 16.7 | 22.5 | 25.6 | 32.5 | 99.9 % (1 of 1,080 over) |
| pipelined, split frame | 15.2 | 20.4 | 21.9 | 28.3 | **100 %** |

Paced at 35 Hz (`--realtime`) the pipelined and split modes hold 35.0 Hz with no late period.
See [game-port.md](game-port.md).

### Full game tic + deathmatch (phase 3)
Every gameplay feature CedarDB's game SQL implements is ported and verified against CedarDB
([feature-coverage.md](feature-coverage.md)): besides the TPC-DOOM run, **178
scripted scenarios** (all 135 line specials — doors, floors, lifts, perpetual platforms, ceilings,
crushers with crush damage, stairs, donut, light changes and strobes, teleports, switches,
one-shot/repeatable, exits; sector lights and damaging floors; skills 0/3/4 incl. nightmare
respawn; BFG spray, plasma, chainsaw; cacodemons/lost souls/baron) are equal to CedarDB on all
49,806 tics, and their 1,055 recorded frames are pixel-exact. **Deathmatch** (`doom_game.run_mp_tic`,
CedarDB's `doom_run_mp_tic`: one shared world tic for every slot, frags, respawns, -altdeath,
-timer): five CedarDB recordings (2–4 players, 6,250 tics) are equal on every tic and all 3,364
per-player frames pixel-exact.

`client/game_mp.py`: one tic session (inputs + tic + commit in one round trip) and one render
session per player, frames concurrent, pipelined behind the next tic (live bots, 1,200 tics):

| players | period mean | p95 | periods ≤ 28.6 ms | frames/s total |
|---|---|---|---|---|
| 1 (pipelined) | 17.6 | 24.6 | 99.6 % | 57 |
| **2 (pipelined)** | **23.6** | 29.4 | **92.4 %**; paced at 35 Hz: **35.0 Hz, 0 late periods** | 85 |
| 3 (pipelined) | 33.3 | 37.6 | 74.4 % | 90 |
| 4 (pipelined) | 41.4 | 43.4 | 62.2 % | 97 |

Two players fit the 2-CPU Oracle Free; three and four are CPU-bound (and hit its CPU cap). The
deathmatch tic itself: 3.9 / 5.5 / 5.9 / 7.3 ms for 1–4 players (CedarDB, same host: 3.9 / 5.2 /
6.7 / 7.4).
```sh
.venv/bin/python oracle/tests/run_game_correctness.py --scenario      # 178 scenarios vs CedarDB
.venv/bin/python oracle/tests/run_game_correctness.py --mp dm_e1m1_4p # a deathmatch: state + frames
.venv/bin/python oracle/client/game_mp.py --players 2 --pipelined [--realtime] [--check dm_e1m1_2p]
```
```sh
.venv/bin/python oracle/client/setup_game.py                 # install
.venv/bin/python oracle/tests/run_game_correctness.py        # tic-by-tic state vs CedarDB (~100 s)
.venv/bin/python oracle/client/game.py --check --pipelined [--split] [--realtime]
```

Details: [benchmark-results.md](benchmark-results.md),
[correctness.md](correctness.md),
[optimization-log.md](optimization-log.md).

### Every map, the level flow, the screens (phase 4)
All 36 maps of `freedoom1.wad` are loaded (E1M1–E4M9, ids 1–36; CedarDB reloaded with the reference
loader). The level flow and the meta game are ported to the database (`doom_flow`, `sql/10_flow.sql`;
`doom_game.enter_level` with carry-over, demo record/playback in the tic): level exits,
finish_level/level stats, the intermission tally, next-map and secret-exit routing, boss specials,
the finale (incl. the E3 bunny scroll), menus, save/load, typed cheats, demos and the attract loop,
the automap camera. The full-screen frames (menus, load/save, help, intermission, finale, automap)
are one SELECT each (`doom_screen`, `sql/11_screens.sql`), pixel-exact against CedarDB's
`render_screen.sql` / `render_automap.sql`: menu 3.4 ms, intermission 2.4 ms, automap 2.0 ms
(CedarDB 7.7–8.1 / 5.3 ms). Verification (details: [feature-coverage.md](feature-coverage.md)):
14 scripted flows recorded on CedarDB through the reference client API and replayed call by call,
and a smoke run on every map (level start + 400 tics, 8 frames each).
```sh
.venv/bin/python oracle/tests/run_flow.py replay                       # 14 flows vs CedarDB
.venv/bin/python oracle/tests/run_game_correctness.py --scenario 'smoke_*'   # every map
.venv/bin/python oracle/client/screen.py --screen main --out main.png   # a menu frame
.venv/bin/python oracle/client/screen.py --automap 1 --out map.png      # the automap
.venv/bin/python oracle/tests/run_flow.py record NAME --force           # CedarDB ground truth
```

### The deathmatch server (phase 5)
The server layer of CedarDB SQLDoom's multiplayer (`MULTIPLAYER.md`) on Oracle: players log in as
their own database accounts holding only the `DOOM_PLAYER` role and reach the game through `api_*`
definer-rights functions and `READ`-only views that resolve the caller from
`SYS_CONTEXT('USERENV','SESSION_USER')` (no slot parameter anywhere); per-slot frame views return a frame
only to the slot's holder; spectators read the match without positions; a referee (`client/referee.py`)
keeps the 35 Hz clock with a one-per-match heartbeat, idle reaping, the lobby queue, seat turnover, map
rotation and the join-path warm-up, each tic one SERIALIZABLE transaction. Accounts are created by a
broker package (`DOOM_ADMIN.DOOM_ACCOUNTS`): the game owner gets no CREATE/ALTER/DROP USER.
Details, ACL results, the CedarDB-recorded API session replay and live latency:
[multiplayer-server.md](multiplayer-server.md).
```sh
.venv/bin/python oracle/client/api_install.py --admin              # once (SYSTEM): roles + account broker
.venv/bin/python oracle/client/api_install.py                      # server tables, doom_mp, api_*, grants
.venv/bin/python oracle/client/accounts.py player alice            # a player (password printed once)
MAP_ID=1 SKILL=2 .venv/bin/python oracle/client/referee.py         # the referee
.venv/bin/python oracle/tests/mp_acl_check.py                      # what a player may / may not do
.venv/bin/python oracle/tests/api_replay.py replay                 # API session vs CedarDB
.venv/bin/python oracle/tests/mp_api_match.py --players 2          # live match through the API, timed
.venv/bin/python oracle/client/accounts.py drop alice              # remove an account
```

### Play it (phase 6: clients, sound, music, interpolation)
The playable clients — the CedarDB reference's pygame client and browser client, ported. All game
logic and rendering stay in Oracle; the clients send input, fetch palette-index frames, apply PLAYPAL
and play the sounds/music the database selects. Frames are requested independently of the 35 Hz
tic and drawn at the camera interpolated between tics (in SQL). Details and measurements:
[clients.md](clients.md).

```sh
make venv                                                      # adds pygame-ce and websockets
.venv/bin/python oracle/client/api_install.py --client-only    # doom_float8 (once, after phase 5)
.venv/bin/python oracle/client/api_install.py --audio-only     # sounds + music (once)
```

**Single player** (the DOOM account; title screen, attract loop, menus, the whole episode flow):
```sh
.venv/bin/python oracle/client/doom_client.py                  # or: make play
.venv/bin/python oracle/client/doom_client.py --warp E1M3 --skill 3   # straight into a level
.venv/bin/python oracle/client/doom_client.py --no-split       # one render session (~48 FPS)
.venv/bin/python oracle/client/doom_client.py --cedar-exact    # sprites exactly as CedarDB (sunk into floors)
```
Sprites are drawn the way Doom draws them by default (clipped by the silhouettes of the walls and
ledges in front of them, so barrels and items stand on the floor); `--cedar-exact` renders them exactly
as the CedarDB reference does (depth-tested against floors and ceilings: items sink a few pixels into
the floor, every frame pixel-exact to CedarDB). Deathmatch uses the referee's setting for everyone
(`SPRITE_MODE=vanilla` default, `SPRITE_MODE=cedar` or `referee.py --cedar-exact`). All tests and
benchmarks use the exact mode; see [clients.md](clients.md).
Render sessions per player = max(1, database CPUs ÷ players). On Oracle Free (2 CPUs) single player
therefore renders each frame on two sessions by default (split, ~65 FPS, steadier tics), and each
deathmatch player renders on one session. `--split` / `--no-split` override; `--db-cpus N` (or
`DOOM_DB_CPUS`) sets the CPU count when the client cannot read `cpu_count`.
Keys: W/S or ↑/↓ move, A/D strafe, Q/E or ←/→ turn, mouse turns, left button or Ctrl fires, Shift
runs, Space uses (and restarts after death), 1–7 weapons, wheel cycles weapons, Tab automap (F follow,
G grid, Home fit, +/− zoom, WASD/arrows pan), Esc menu (New Game, Load, Save, Quit), \` frees the
mouse, F6 hides the FPS badge, F9 records a demo of the level / F10 plays it, −/= window size. Cheats
are typed in game: IDDQD, IDKFA, IDFA, IDCLIP, IDCLEVxy, IDMUSxy, IDDT (on the automap), IDBEHOLDx, IDMYPOS.

**Deathmatch** (the referee owns the world; each player is a database account with only the
`DOOM_PLAYER` role):
```sh
.venv/bin/python oracle/client/accounts.py player alice        # prints alice's password once
.venv/bin/python oracle/client/accounts.py player bob
MAP_ID=1 SKILL=2 .venv/bin/python oracle/client/referee.py     # terminal 1: the server (Ctrl-C stops it)
.venv/bin/python oracle/client/doom_client.py --join alice --password '<alice password>'   # terminal 2
.venv/bin/python oracle/client/doom_client.py --join bob --password '<bob password>'       # terminal 3
.venv/bin/python oracle/client/accounts.py drop alice bob      # afterwards
```

**Browser** (deathmatch in a page: the bridge logs in as the browser's own player account and only
forwards a fixed set of `api_*` statements):
```sh
MAP_ID=1 .venv/bin/python oracle/client/referee.py             # the match
.venv/bin/python oracle/client/doom_web.py                     # http://127.0.0.1:8080/ (DOOM_WEB_ADDRESS=0.0.0.0 for the LAN)
# open the page, "sign in with a player account": alice / <password>
DOOM_GUESTS_FILE=guests.txt .venv/bin/python oracle/client/doom_web.py   # optional guest seats: lines "USER PASSWORD"
node oracle/tests/bots.mjs ws://127.0.0.1:8080/ws 2            # bots (guest seats or DOOM_BOT_ACCOUNTS=user:pw,...)
```

Checks: `tests/client_query_check.py` (client SQL vs CedarDB), `tests/client_run_check.py` (the client
end to end vs CedarDB), `tests/client_ui_smoke.py`, `tests/web_smoke.mjs`, `tests/web_browser_check.mjs`,
`tests/determinism_check.py`, `tests/all_maps_smoke.py` — see clients.md. The vanilla sprite mode:
`tests/vanilla_sprites_check.py` (exact vs vanilla per frame, PNGs in `tests/out/vanilla/`), `tests/sprite_mode_ab.py` (cost).
