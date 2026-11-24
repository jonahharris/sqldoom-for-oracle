# SQL Doom on Oracle AI Database 26ai

Doom, running inside an Oracle database. The game itself is in the database: every tic of the world
(player, monsters, doors, lifts, projectiles) is SQL and PL/SQL, and every frame is one SQL query.
The client only sends your keys and draws the 320×200 frames that come back, at about 60 FPS on the
free 2-CPU Oracle 26ai Free.

It is a port of [CedarDB SQLDoom](https://github.com/cedardb/sqldoom), and every frame and every tic
is verified pixel- and state-exact against it. Play the whole single-player game, a deathmatch
on the desktop, or a deathmatch in the browser, with [Freedoom](https://freedoom.github.io/) or the
original Doom 1.9 shareware episode.

- [Play it](#play-it)
- [Deathmatch](#deathmatch)
- [Troubleshooting](#troubleshooting)
- [How it works and how fast it is](#how-it-works-and-how-fast-it-is)
- [Tests and benchmarks](#tests-and-benchmarks)

## Play it

### What you need
- **Docker**, with at least 2 CPUs and 4 GB of memory for the Oracle container. The image
  (`gvenzl/oracle-free:full`) is a few GB to download.
- **Python 3.10+**.
- A desktop session for the game window (pygame). Sound and music play out of the box.
- Optional: **Node.js**, only for the browser test bots.

### Install (once, about 10 minutes)
```sh
git clone https://github.com/jonahharris/sqldoom-for-oracle.git
cd sqldoom-for-oracle
make venv        # Python environment
make db-up       # start Oracle Free in Docker, wait until it is healthy
make setup       # download Freedoom, load every map, install the game (about 6–8 minutes)
```

### Play
```sh
make play
```
You get Doom's title screen and menus. Choose **New Game**, an episode and a skill. Everything after
that works as in Doom: level exits, the intermission tally, secret levels, the finale, save and load.

To jump straight into a level instead:
```sh
.venv/bin/python oracle/client/doom_client.py --warp E1M3 --skill 3
```

### Freedoom or the Doom shareware episode
The install uses Freedoom: free, BSD-licensed game data with all four episodes (36 levels).
To play the original **Doom 1.9 shareware** episode, *Knee-Deep in the Dead* (9 levels), instead:
```sh
make shareware   # downloads doom1.wad (checksum-pinned) and loads it, about 5 minutes
make play
```
Switch back with `make freedoom`. The database holds one game at a time. Stop a running deathmatch
server before you switch.

### Controls
| | |
|---|---|
| move | W / S or ↑ / ↓ |
| strafe | A / D |
| turn | Q / E, ← / →, or the mouse |
| fire | left mouse button or Ctrl |
| run | Shift |
| use (doors, switches), respawn after death | Space |
| weapons | 1–7, mouse wheel cycles |
| automap | Tab (F follow, G grid, Home fit, + / − zoom) |
| menu (New Game, Save, Load, Quit) | Esc |
| release the mouse | \` |
| window size | − / = |
| hide the FPS badge | F6 |
| record a demo of the level / play it back | F9 / F10 |

The classic cheats work: type IDDQD, IDKFA, IDFA, IDCLIP, IDCLEV*xy*, IDMUS*xy*, IDBEHOLD*x*,
IDMYPOS, or IDDT on the automap.

### Client options
| option | |
|---|---|
| `--warp E1M3 --skill 0-4` | start in a level (skill 2 is *Hurt Me Plenty*) |
| `--scale N` | window scale (default: fit the screen) |
| `--mouse-sensitivity 0.15` | mouse turn speed |
| `--no-sound`, `--no-music` | mute |
| `--no-split` | render each frame on one database session instead of two (lower FPS) |
| `--cedar-exact` | draw sprites exactly as CedarDB does: items sink a few pixels into the floor |
| `--dsn host:1521/FREEPDB1` | a database on another machine |

## Deathmatch
In deathmatch, a **referee** process runs the 35 Hz game clock for the match. Each player is a separate
database account that can only reach the game through a narrow API: it can send its own input and
read its own view, nothing else.

**Desktop clients.** Open one terminal per process:
```sh
make player NAME=alice       # create an account; prints alice's password once
make player NAME=bob
make server                  # terminal 1: the referee (E1M1, skill 2); Ctrl-C stops it
make join NAME=alice PASSWORD='...'   # terminal 2
make join NAME=bob PASSWORD='...'     # terminal 3
```
- **Pick the map:** `make server MAP_ID=3 SKILL=4`. Maps are numbered in episode order: E1M1 = 1 …
  E1M9 = 9, E2M1 = 10 …, up to E4M9 = 36 on Freedoom.
- **Match settings**, as environment variables of the referee:
  - `TIMER_MINUTES` (10)
  - `MONSTERS` (1, set 0 for none)
  - `ALTDEATH` (1)
  - `ROTATION` (E1M1,…,E1M7): the maps played in turn when a level ends
  - `SPRITE_MODE` (`vanilla` or `cedar`)
- **Players on other machines** run the client with `--dsn <your-host>:1521/FREEPDB1`, after
  `make venv` on their side. Port 1521 must be reachable.
- **How many players:** two players run at full speed on the 2-CPU Oracle Free. Three or four work,
  but slower, because Oracle Free is limited to 2 CPUs.
- **Remove accounts afterwards:** `.venv/bin/python oracle/client/accounts.py drop alice bob`.

**In the browser.** A small bridge serves the game page and signs in to the database as the browser's
own player account:
```sh
make server                  # the match
make web                     # http://127.0.0.1:8080/   (DOOM_WEB_ADDRESS=0.0.0.0 to open it to the LAN)
```
Open the page and sign in with a player account, for example alice and her password. For drop-in
guests, list `USER PASSWORD` lines in a file and start the bridge with `DOOM_GUESTS_FILE=guests.txt make web`.
Browser music needs FluidSynth, a General MIDI soundfont and ffmpeg on the server when the game is
installed. Without them the browser plays sound effects only; the desktop client always has music.

## Troubleshooting
| problem | fix |
|---|---|
| `make setup` or `make play` cannot connect | `make db-up` and wait for it to finish; the first start of the container takes a few minutes |
| low FPS | other load on the Docker host; check that Docker has at least 2 CPUs. `make play` renders each frame on two sessions automatically when the database has 2 CPUs. |
| "invalid objects" or ORA- errors after an interrupted install | run `make setup` again (or `make freedoom` / `make shareware`): it reinstalls everything |
| deathmatch client cannot join | the referee (`make server`) must be running; check the account's password (`make player NAME=...` resets it) |
| start over completely | `make db-down`, `docker volume rm oracle_oradata`, then `make db-up setup` |

Passwords: the database accounts `doom` and `SYSTEM` use local-only default passwords (`doom`,
`DoomSys_26ai`). If the database is reachable from other machines, change them in
`oracle/docker-compose.yml` before the first `make db-up`, and set `DOOM_ORA_PASSWORD` and
`DOOM_ORA_SYSTEM_PASSWORD` to match.

## How it works and how fast it is
- **The world.** Each tic is one call into the `doom_game` package (`oracle/sql/08_game.sql`): set-based
  SQL plus PL/SQL over about 40 world-state tables. The level flow, menus and intermission are in
  `doom_flow`, and the full-screen pictures are queries in `doom_screen`.
- **The frame** is one prepared `SELECT` (`render_hybrid.sql`). SQL reads the camera and the world
  state, and the PL/SQL package `doom_hybrid` does the BSP walk, walls, floors, sprites and status
  bar. The client fetches palette indices, interpolates the camera between tics, and plays the sounds
  and music the database chooses.
- **Two sessions per frame.** Oracle Free has 2 CPUs and no parallel query, so single player renders
  each frame on two sessions, one per half of the screen.

Speed on Oracle 26ai Free (2 CPUs, arm64; 1,080 measured frames):

| | frame time (mean) | FPS |
|---|---|---|
| CedarDB SQLDoom on the same host | 16.7 ms (p50) | ≈ 60 |
| one session | 20.0 ms | 50 |
| two sessions (single-player default) | 13.1 ms | 76 |
| game tic | 3.0 ms (CedarDB: 3.9) | — |

The full story, phase by phase: [oracle/analysis/overview.md](oracle/analysis/overview.md). Design:
[oracle-design.md](oracle/analysis/oracle-design.md) and [hybrid-design.md](oracle/analysis/hybrid-design.md).
Every experiment, kept or reverted: [optimization-log.md](oracle/analysis/optimization-log.md).

**Sprites.** By default the clients clip sprites the way Doom does, so barrels and items stand on the
floor. The CedarDB reference depth-tests sprites against the floor, so its items sink a few pixels.
`--cedar-exact` (desktop) or `SPRITE_MODE=cedar` (deathmatch) gives you that look. Tests and
benchmarks always use the exact mode.

## Tests and benchmarks
These all run on Freedoom: run `make freedoom` first if you switched to the shareware episode.
```sh
make test            # 120 frames pixel-exact vs the recorded CedarDB frames (make test-full: all 1,200)
make bench           # 1,080 measured frames, DB-only and end to end
R=render_hybrid_split.sql make bench     # any renderer: render_baseline / render_optimized / render_hybrid[_split].sql
make render TIC=300  # one frame to PNG    (make anim: a GIF of tics 1–350)
make client-check    # the desktop client headless, plus a scripted UI walk-through
.venv/bin/python oracle/tests/run_game_correctness.py         # every tic's world state vs CedarDB
.venv/bin/python oracle/client/game.py --check --pipelined    # live game loop, frames checked
```
The longer suites compare against more CedarDB recordings: 14 level flows, 178 gameplay scenarios,
deathmatches and an API session. Download those recordings first (about 700 MB):
```sh
make fetch-reference
.venv/bin/python oracle/tests/run_flow.py replay
.venv/bin/python oracle/tests/run_game_correctness.py --scenario
.venv/bin/python oracle/tests/run_game_correctness.py --mp dm_e1m1_4p
.venv/bin/python oracle/tests/api_replay.py replay
```
To regenerate ground truth with CedarDB itself (`make reference`, `oracle/tests/record_*.py`),
`make fetch-sources` clones the reference implementations into `reference/`. Results and methods:
[correctness.md](oracle/analysis/correctness.md), [benchmark-results.md](oracle/analysis/benchmark-results.md),
[feature-coverage.md](oracle/analysis/feature-coverage.md), [clients.md](oracle/analysis/clients.md),
[multiplayer-server.md](oracle/analysis/multiplayer-server.md).

### Data not in the repository
| what | how |
|---|---|
| `oracle/wad/freedoom1.wad` (Freedoom 0.13.0, BSD) | `make fetch-wad`, run by `make setup` |
| `oracle/wad/doom1.wad` (Doom 1.9 shareware, id Software; not redistributed here) | `make fetch-shareware-wad`, run by `make shareware` (from Debian's `doom-wad-shareware` package) |
| extended CedarDB ground truth (`reference_data/flows`, `scenarios`, `dm_*`, `api_session`) | `make fetch-reference` (a release asset) |
| the three reference implementations (`reference/`) | `make fetch-sources` (pinned commits) |

## Layout
```
Makefile                   every command above; each target has a ## comment
oracle/
  docker-compose.yml       Oracle Free (and, optional profile, CedarDB for ground truth)
  sql/                     the database side: schema (00–05, 07*), renderer (06_hybrid.sql, render_*.sql),
                           game tic (08), live views (09), flow (10), screens (11), deathmatch server
                           and API (12, 13), client helpers (14); variants/ = optimization snapshots
  client/                  doom_client.py (desktop), doom_web.py + web/ (browser), referee.py, accounts.py,
                           setup_db.py / setup_game.py / api_install.py (install), fetch_data.py, loaders
  tests/                   correctness suites and CedarDB recorders
  benchmark/               bench.py, compare.py, calibration/, results/
  reference_data/          CedarDB ground truth (e1m1 frames + state, e1m1_game, client_queries; more via fetch)
  analysis/                design notes, results and the optimization log
```

## Licence and credits
GPL-2.0 (see `LICENSE`). The renderer, the game tic, the flow, the screens and the multiplayer layer
are ports of [CedarDB SQLDoom](https://github.com/cedardb/sqldoom) (GPL-2.0), which is also the
ground truth; the WAD loader and the MUS→MIDI conversion are adapted from its loader. The 1,200-tic
TPC-DOOM E1M1 input stream comes from [saildoom](https://github.com/querygraph/saildoom) (GPL-2.0);
[DoomSQL](https://github.com/sqlartist/DoomSQL) (MIT) was studied as a further reference.
Game data: [Freedoom](https://freedoom.github.io/) (BSD, `oracle/wad/COPYING.txt`). Doom is a
trademark of id Software; this project is not affiliated with id Software, CedarDB or Oracle.
