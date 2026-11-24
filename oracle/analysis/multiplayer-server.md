# The deathmatch server on Oracle (phase 5)

CedarDB SQLDoom's server layer (`reference/sqldoom/MULTIPLAYER.md`, `42_api.sql`,
`cedarscript_runtime.install_api_views`, `doom_server.py`, `scripts/add_player.py` …) ported to Oracle
AI Database 26ai: the database is the game server; players log in as their own database accounts and
reach the game only through an `api_*` surface; one trusted process outside it, the referee, keeps the
35 Hz clock.

## Security model

| who | holds | may | may not |
|---|---|---|---|
| `DOOM` (game owner) | its schema; `EXECUTE ON DOOM_ADMIN.DOOM_ACCOUNTS` (the only privilege phase 5 adds) | everything in its schema: install, referee, single player | create, alter or drop database users itself |
| `DOOM_ADMIN` (schema-only account, `NO AUTHENTICATION`: nobody can log in as it) | `CREATE/ALTER/DROP USER`, `CREATE SESSION WITH ADMIN OPTION`, `DOOM_PLAYER` and `DOOM_SPECTATOR` `WITH ADMIN OPTION` | through its definer-rights package `DOOM_ACCOUNTS`: create, re-password or drop **only accounts it created itself** (its `ACCOUNTS` table), granting exactly `CREATE SESSION` + one role | anything else (no `ALTER SYSTEM`, no dictionary access beyond `ALL_USERS`) |
| a player (`accounts.py player NAME`) | `CREATE SESSION`, role `DOOM_PLAYER` | `EXECUTE` on the `api_*` functions; `READ` on the `api_*` views, `sound_assets` and the per-slot frame views | read any table, write anything, lock anything, advance the tic, cheat, reset/open a level, take another player's slot or frame, name its own camera, reveal the automap, create objects or users |
| a spectator (`accounts.py spectator`) | `CREATE SESSION`, role `DOOM_SPECTATOR`, profile `DOOM_SPECTATOR_PROFILE` (16 sessions, CedarDB's connection limit) | `READ` on the WAD and catalogue tables, the match without positions (`g_mp_match`, `g_mp_rotation`, `g_level_stats`, `g_tic_trace`, `g_item_respawns`, `g_sector_movers`, live `g_sectors`/`g_sidedefs`) and the public views (`api_match`, `api_scoreboard`, `api_palettes`, `api_things_spawn`, `api_things_live`, `mp_stats`, `api_tic`) | the player API (Oracle enforces `EXECUTE`; CedarDB did not, its `api_join` answers -1 to a spectator — kept here too), any position, input, frame view, identity sequence, write or lock |

Why Oracle needs the broker: `add_player.py` runs `CREATE ROLE … LOGIN` as the CedarDB owner, a
superuser. On Oracle the equivalent system privileges (`CREATE/ALTER/DROP USER`) reach every account of
the PDB (`ALTER USER SYSTEM IDENTIFIED BY …`). The game owner therefore gets none of them, only
`EXECUTE` on a package that refuses any name it did not create, validates names (`^[A-Z][A-Z0-9_]{0,29}$`,
no `SYS`/`ORA`/`APEX`… prefixes) and passwords (8–100 of `A-Za-z0-9_!#%+.:=?@-`, no quote can reach
the DDL), and grants a fixed set. Installed once as SYSTEM: `api_install.py --admin` (`sql/12_api_admin.sql`).

Oracle-specific hardening found while porting (each is a check in `mp_acl_check.py` / `spectator_check.py`):

* **`READ`, not `SELECT`.** A `SELECT` object privilege also allows `SELECT … FOR UPDATE` and `LOCK
  TABLE`. `api_player_state` is a join over `g_player_state`; a player locking its own row with `FOR
  UPDATE` would make the next tic wait forever — the whole world frozen by one client. Every grant
  (players and spectators) is `READ`, which cannot lock (ORA-41900 missing SELECT/LOCK privilege).
* **No transaction left open by an API call.** Every writing `api_*` function starts and ends with
  `COMMIT`. In Oracle an uncommitted row change holds a row lock until the session commits; a client
  that called `api_camera` and never committed would block the reaper's `UPDATE g_mp_players`. The
  leading `COMMIT` also ends the READ ONLY transaction the client opened for its previous frame.
* **The caller is `SYS_CONTEXT('USERENV','SESSION_USER')`** — the login, unchanged inside
  definer-rights code and not settable by `ALTER SESSION` (`CURRENT_SCHEMA` only changes name
  resolution, which the client uses: `ALTER SESSION SET CURRENT_SCHEMA = DOOM`).
* **One slot per login**: a unique index on `g_mp_players(role_name)` (NULLs are not indexed, so free
  slots are fine). A second concurrent `api_join` of the same login gets ORA-00001 inside the function
  and answers -1 (CedarDB: its serializable `api_join` fails the second claim).
* No sequence grants: the definer functions draw `g_mp_inputs.seq` (an identity) as the owner; CedarDB
  needs `GRANT USAGE ON SEQUENCE` because its `nextval` is checked against the caller.
* No `PUBLIC` grant anywhere; nothing is granted to an account directly, only to the two roles.

Re-grant on reinstall (CedarDB's `api_roles` registry): `CREATE OR REPLACE` keeps Oracle grants, but a
reinstalled table loses them, so every `api_install.py` run re-grants the API to the roles and calls
`DOOM_ACCOUNTS.REGRANT` (role + `CREATE SESSION` to every account still present). Accounts are recorded
in `api_roles` / `api_spectator_roles` (and the broker's own `ACCOUNTS`).

## The API

| CedarDB | Oracle | notes |
|---|---|---|
| `api_join()` | `api_join RETURN NUMBER` | the lobby queue (`g_mp_waiting`), first come first served; between maps -1; 15 s join grace |
| `api_slot()` | `api_slot` | |
| `api_input(real,real,bool,real,bool,int,bool)` | `api_input(BINARY_DOUBLE, BINARY_DOUBLE, BOOLEAN, BINARY_DOUBLE, BOOLEAN, NUMBER, BOOLEAN)` | clamped as CedarDB; the client's double is stored as the REAL CedarDB makes of the same client value (`doom_mp.py_real` = `cmd_real(repr(x))`, equal on 5,018 test values incl. −0.0, exponents, NaN/Inf) |
| `api_camera(float8)` | `api_camera(BINARY_DOUBLE)` | `camera_pose.sql` over the caller at clamped alpha, written to the slot's float4 pose; the heartbeat |
| `api_weapon_slot/cycle(int)` | same | `doom_flow.weapon_slot/_cycle`, -1 when nothing |
| `api_set_name(text)` | `api_set_name(VARCHAR2)` | `[^A-Za-z0-9 _-]` removed, 12 chars, upper case |
| `api_automap()` → RGB bytea | `TABLE(api_automap())` → 200 rows `(y, pal, hex)` | the caller's own walked map; `power_map` decides reveal; no IDDT |
| `api_automap_pan/zoom/toggle/fit` | same | `toggle` accepts only `follow`/`grid` |
| views `api_player_state`, `api_snapshot`, `api_sound_events`, `api_sound_loops`, `api_stage_music`, `api_map_lines`, `api_stages`, `api_map_geometry`, `api_palettes`, `api_match`, `api_tic`, `api_scoreboard`, `api_things_live`, `api_things_spawn` | same names | generated from the single-player client's SQL (`client/game_api.py`) by `api_install.py`, exactly as `install_api_views` generates them from `sql/client/*.sql` |
| `api_frame_slot<n>_m<map>` (RGB) / `api_frame_idx_slot<n>_m<map>` (indices) | `api_frame_slot<n>_m<map>` → 200 rows `(y, pal, hex)` | one view per slot and map of the rotation, created by the referee; rows are COLORMAP-mapped palette indices + the active palette (`api_palettes` gives RGB: one 3×256 lookup). Only the slot's holder gets rows. The sprite mode is the match's `g_mp_match.sprite_mode` (an Oracle-only column: 1 vanilla sprite clipping, the default; 0 CedarDB-exact; set by the referee's `SPRITE_MODE`, the API replay sets 0) — the same for every player, not a player argument. |
| `sound_assets` | `sound_assets` (BLOB) | loaded from the WAD (`api_install.load_audio`), 69/69 byte-equal to CedarDB |

A frame from a client: one round trip `BEGIN :i := api_input(…); :c := api_camera(:a); SET TRANSACTION
READ ONLY; END;`, then `SELECT y, pal, hex FROM api_frame_slot<n>_m<map>` (200 rows, one fetch). The
frame view is the phase 3/4 fast path, one renderer session per player, through
`doom_hybrid_live.render_frame_bd`: the same frame as `render_frame`, but the slot's REAL pose is widened
to a double exactly, as CedarDB's view does (`render_frame` treats its pose as a client's decimal text and
reproduces CedarDB's parse of it — not the identity, which cost 7 of 675 frames before the change). **The READ ONLY
transaction is what makes the frame consistent**: `render_frame` runs many queries, and under Oracle's
statement-level consistency a tic committing mid-frame would otherwise split the frame between two
tics; in a read-only transaction every query sees the committed state as of its start (CedarDB gets
the same from its single statement).

## Per-player screens (task item 4)

CedarDB's `screen_state` is one global row and stays single-player in the server too: `api_snapshot`
replaces its columns by constants (`'game'`, `demo_active` false); menus, save/load, demos, the
single-player intermission and the finale are not reachable through the API. What is per player is
the automap (`automap_view` keyed by map and player thing; `api_automap*` act on the caller's row) and
the deathmatch intermission (`mp_match.state` + `api_match` / `api_scoreboard`, shared by all). Oracle
does exactly the same (`g_automap_view`, `api_snapshot` constants); the replay below compares the
automap calls and frames of two players.

## The referee (`client/referee.py`)

| doom_server.py | referee.py | verified by |
|---|---|---|
| one referee per match: heartbeat row, refuse while fresh (3 s), release on SIGINT/SIGTERM, wait out a crash | `doom_mp.referee_claim/_beat/_release` (`g_mp_referee`; the claim locks the table so two simultaneous starts cannot both win) | `referee_check.py` |
| 35 Hz clock, catch-up limited to 0.5 s | same | `referee_check.py` (35.0 tics/s), `mp_api_match.py` |
| the tic in one transaction | `doom_mp.tic`: `SET TRANSACTION ISOLATION LEVEL SERIALIZABLE` + `run_mp_tic` + `COMMIT`, one round trip | the replay; live runs (0 dropped) |
| a failed tic: rollback, inputs dropped, counted | same (and ORA-08177 retried on a fresh snapshot, up to 3 times) | |
| once a second: heartbeat, idle reaping (`IDLE_SECONDS`), seat turnover (`HOLD_MINUTES` while someone waits), stale waiters | `doom_mp.referee_beat` + `doom_mp.reap` + `doom_mp.hold_turnover`, one block | `lobby_check.py` |
| every 5 s: tic median/p90/max, dropped, `mp_stats`, the board, `api_tic_stats` | same | logs |
| level end (-timer, exits) → intermission (`INTERMISSION_SECONDS`) → `doom_mp_rotate` (slots follow players, frags reset) | `doom_mp.intermission_begin/_over`, `doom_mp.rotate` | `mp_rotation_check.py`, the replay |
| join-path warm-up (tic, `request_all`, tic, `vacate_all`) | same | the replay starts with it |
| frame views for every map of the rotation, created once | `api_install.install_frame_views` (a view whose text is current is left alone) | |

**Why SERIALIZABLE.** CedarDB runs the tic as one snapshot-isolated transaction. Oracle's default READ
COMMITTED gives each statement its own snapshot: the tic folds `MAX(seq)` of the input rows, folds them
into commands, then deletes `seq <= MAX` — an input committed between the fold and the delete would be
deleted unread; a claim landing mid-tic would be seen by some stages and not others. SERIALIZABLE is
Oracle's snapshot isolation for a read-write transaction. It raised ORA-08177 on the tic's DELETE of
input rows whenever a player had inserted into the same block after the tic began (block-level commit
SCNs; a probe: 116 of 190 tics). `ROWDEPENDENCIES` on `g_mp_inputs` and `g_mp_join_requests` (a commit
SCN per row) makes the check row-level: 0 of 190, and 0 in every live run since.

## Verification

All on 2026-11-23, Oracle 26ai Free (2 CPUs) and the CedarDB reference container on the same host; logs
in `tests/out/p5/`. Every check creates its accounts through the broker and drops them at the end.

**ACL** (`mp_acl_check.py`, port of CedarDB's `scripts/mp_acl_check.py`; a match opened by the
referee code, no clock): **63/63 as expected.**

| a player … | result |
|---|---|
| joins, reads `api_snapshot`, `api_player_state`, `api_palettes`, `api_scoreboard`, `api_match`, `api_sound_events`, `api_sound_loops`, `api_stage_music`, `api_map_lines`, `api_map_geometry`, `api_stages`, `api_things_live`, `sound_assets`; `api_slot`; `api_camera(0.5)`; `api_automap()`; `api_input` | allowed |
| reads its own frame view | 200 rows |
| reads another slot's frame view | allowed, **0 rows** (no frame for a non-holder); the holder gets 200 |
| `api_camera(9999)` | clamped: the pose is the player's position |
| `api_input(50, −50, run, 9999, …, weapon 9, …)` | stored clamped (1, −1, 180, no weapon) |
| `api_automap_toggle('cheat')` | accepted, cheat counter stays 0 |
| `api_set_name` with SQL in it | sanitised (`X DROP TABLE`) |
| `api_join` twice | still one slot |
| player 2's `api_input` | lands on slot 2 only |
| read `g_player_state`, `g_things`, `things`, `linedef_geom`, `g_mp_players`, `g_mp_inputs`, `g_sound_events`, `screen_state`, `mp_stats`, `api_tic`, `api_things_spawn` | denied (ORA-00942) |
| `UPDATE api_player_state`, `SELECT … FOR UPDATE`, `LOCK TABLE api_scoreboard` | denied (ORA-41900: READ grants cannot write or lock) |
| `UPDATE g_player_state SET power_map`, `INSERT INTO g_mp_inputs` | denied |
| `api_pose(…)` (name its own camera), `api_automap(…reveal, IDDT…)` | denied (no such API) |
| run the tic (`doom_game.run_mp_tic`, `doom_mp.tic`), cheat (`doom_game.cheat`, `doom_flow.cheat_key`), reset/open a level (`enter_level`, `mp_start`), rotate, reap, claim for someone else, render any pose (`render_frame`) | denied |
| read `doom_admin.accounts`, call the broker, `CREATE USER`, `CREATE TABLE`, `GRANT doom_spectator` | denied |
| a spectator: read `api_scoreboard` / join / read a frame view | allowed / denied / denied |

**Spectators** (`spectator_check.py`): all good — 6 console statements (dictionary as the login), 15
Doom templates in Oracle SQL (scoreboard, match, `mp_stats`, the map as text, linedefs, live sectors,
spawns, catalogues, level stats, tic trace, rotation, live overview, `api_tic`) run; refused: live player
positions, slot poses, live things, inputs, monster AI, `api_player_state`, writing the rotation or the
match, `FOR UPDATE` / `LOCK TABLE`, `CREATE TABLE`, `api_join` / `api_input`, the identity sequence, a
frame view; 0 slots held; the profile limits the login to 16 sessions.

**Referee** (`referee_check.py`): ONE REFEREE OK — A ready, heartbeat fresh; A runs 35.0 tics/s; B
refuses while A runs (exit 2) and the world stays at 34.8 tics/s (not doubled); SIGINT stops A and
deletes its heartbeat; C starts at once, is SIGKILLed, its heartbeat stays; D within 3 s refuses; E
after 3.2 s takes the match; SIGTERM releases; logs clean.

**Lobby and idle reaping** (`lobby_check.py`, IDLE_SECONDS 3, HOLD_MINUTES 0.75): LOBBY OK — four
seats; two waiters get −1, `api_match` waiting 2, ahead_of_me 0 and 1; a seated player that stops
heartbeating loses its seat after the 15 s join grace + 3 s, logged as idle; the first waiter (not the
second) gets it and is respawned by the next tic; seats held past 45 s while someone waits are turned over
and the remaining waiter gets one; quiet waiters leave the queue after 5 s.

**Frags** (`mp_frag_check.py`): FRAGS OK — each player kills the other with the pistol through
`api_input` (146 tics each way): killer 1 frag, victim 0; messages `YOU FRAGGED BOB` / `ALICE FRAGGED
YOU` from the names set with `api_set_name`; the scoreboard as a player sees it agrees.

**Rotation** (`mp_rotation_check.py`, port, TIMER 1,400 tics, rotation E1M1 > E1M2): ROTATION OK —
monsters in; a taken item queued and back after 29.5 s with IFOG and DSITMBK; intermission 3 s; rotated
to E1M2; same players in the same slots; respawned, frags 0; both bots rendered on both maps (1,851 / 300
and 1,759 / 271 frames), 0 errors; SIGINT stop; log clean.

**The API session, CedarDB vs Oracle** (`api_replay.py`; recording `reference_data/api_session/`, 20,622
calls, 15 min on CedarDB; replay 2 min): five accounts; joins at tics 1/1/3/6, a waiter from tic 8, names
set, a seated player reaped at tic 250 and its seat taken by the waiter, the reaped player queuing; 598
tics on E1M1 until the -timer, the intermission (API calls no-ops), the rotation to E1M2 with the seats
carried over, 250 tics there; automap zoom/pan/grid/fit/follow and a refused cheat toggle.

| compared | result |
|---|---|
| state tables after the match start and every tic (39 map-scoped tables incl. `mp_players` poses written by `api_camera`, `mp_match`, `mp_join_requests`, `mp_inputs`, `automap_view`) | **850/850 snapshots equal** |
| per-slot frames (`api_frame_slot<n>_m<map>`, RGB through `api_palettes`) | **675/675 pixel-exact** (both maps, four slots) |
| automap frames (`api_automap`) | **14/14 pixel-exact** |
| API call results (`api_join`, `api_slot`, `api_input`, `api_camera`, `api_set_name`, `api_weapon_slot/cycle`, `api_automap_*`, `api_snapshot`, `api_player_state`, `api_sound_events`, `api_sound_loops`, `api_scoreboard`, `api_match`, `api_things_live`, the owner's start/tic/reap/rotate results, `mp_waiting`/`mp_holders`/`mp_rotation`) | **19,079 / 19,083 equal**; the 4 others are `api_match.waiting` right after the rotation, 0 on CedarDB and 1 on Oracle: the queued player's last `api_join` was more than 5 s of wall clock earlier on CedarDB (its intermission + rotation, which recompiles, took longer) and less on Oracle — the 5-second lobby window, not game state |

On CedarDB the session's roles are created `SUPERUSER`: CedarDB Community refuses `GRANT` ("requires an
enterprise license"), and a role without grants may not read the api views nor draw the input queue's
sequence. Every call still runs in the role's own session with `session_user` = the role; access control
itself is verified on Oracle. Three comparison rules: CedarDB REALs arrive as shortest float4 text (equal
when the same float4), sound events of one tic as a set (their ids follow insert order), and CedarDB does
not keep a view's `ORDER BY` under `SELECT * FROM view` (scoreboard rows compared by slot).

**Live matches**: see optimization-log.md, "Phase 5": two players through the API at 35.0 tics/s with no
late or dropped tic, 35 frames/s each, frame latency (input + camera + frame) 22.6 ms mean, **93.0 %
within 28.6 ms** (phase 3 `game_mp.py` 2 players pipelined: 23.6 ms mean period, 92.4 %); four players
CPU-bound as in phase 3 (102 frames/s total, 90 % of frames within 28.6 ms, the referee at 29.2 tics/s).

**Regression** (after the renderer's `render_frame_bd` and the 07c change): TPC replay 1,200/1,200;
deathmatch replays `dm_e1m1_2p` 1,500/1,500 tics, 1,000/1,000 frames and `dm_e1m1_4p` 1,150/1,150, 764/764;
scenarios `e1m1_lift62`, `tpc_bfg`, `smoke_e2m4`, `stop006_057` 4/4 equal, all frames exact; flows
`exit_e1m1_e1m2` and `automap_views` 2/2 equal (all calls, snapshots and frames); `game.py --check --pipelined` 1,200/1,200 frames exact (period 21.8 ms mean, 94.2 % ≤ 28.6);
test T 3.09 ms mean; `render_hybrid` / `render_hybrid_split` 120/120; `bench.py render_hybrid.sql` p50
21.7 ms, 49.4 FPS.

## Files

| file | what |
|---|---|
| `sql/12_api_admin.sql` | roles, the `DOOM_ADMIN` broker (run once as SYSTEM) |
| `sql/07f_api_schema.sql` | `g_mp_referee`, `g_mp_rotation`, `g_mp_holders`, `g_mp_waiting`, `api_roles`, `api_spectator_roles`, `api_tic_stats`, `sound_assets`, `music_assets`, `map_music`, `sector_sound_origins`, `wads` |
| `sql/07c_mp_schema.sql` | + `ROWDEPENDENCIES` on the input/join tables, unique `role_name` |
| `sql/12_mp_server.sql` | package `doom_mp` (owner side), view `mp_stats` |
| `sql/13_api.sql` | the `api_*` functions |
| `sql/06_hybrid.sql` | + `render_frame_bd` (exact double pose; `doom_hybrid_live` is generated from it) |
| `client/api_install.py` | install: schema, packages, generated views, grants, re-grants, audio; frame views |
| `client/accounts.py` | add_player / add_spectator / setup_roles / drop |
| `client/referee.py` | the referee |
| `client/api_client.py` | the player side (statements only) |
| `tests/mp_acl_check.py`, `spectator_check.py`, `referee_check.py`, `lobby_check.py`, `mp_frag_check.py`, `mp_rotation_check.py`, `mp_api_match.py`, `api_replay.py`, `mp_lib_api.py` | the checks |
| `reference_data/api_session/` | the CedarDB recording of the API session |

## Commands

```sh
.venv/bin/python oracle/client/api_install.py --admin        # once, as SYSTEM: roles + broker
.venv/bin/python oracle/client/api_install.py                # schema, doom_mp, api_*, views, grants, audio
.venv/bin/python oracle/client/accounts.py player alice      # prints a generated password once
.venv/bin/python oracle/client/accounts.py spectator         # DOOM_SPECTATOR1
.venv/bin/python oracle/client/accounts.py drop alice        # cleanup
MAP_ID=1 SKILL=2 .venv/bin/python oracle/client/referee.py   # the server
.venv/bin/python oracle/tests/mp_acl_check.py                # each check creates and drops its own accounts
.venv/bin/python oracle/tests/api_replay.py replay           # vs CedarDB (record: api_replay.py record)
.venv/bin/python oracle/tests/mp_api_match.py --players 2
```

State left behind: no test account (each check drops its own; `accounts.py list` shows the
registry), empty match tables. The roles `DOOM_PLAYER` / `DOOM_SPECTATOR`, the profile and the
`DOOM_ADMIN` broker are installed fixtures; the frame views `api_frame_slot<n>_m<map>` for E1M1–E1M7
stay installed (the referee recreates only views whose text changed). On CedarDB the recorder drops its
roles and frame views and empties the match tables.

## For phase 6 (clients, sound, interpolation)

* Frames come as `(y, pal, hex)`; a client applies `api_palettes` (14 × 256 RGB). No RGB view exists:
  building 192,000 RGB bytes in interpreted PL/SQL would cost more than the frame; CedarDB's browser
  client reads the index variant for the same reason.
* `api_camera(alpha)` already interpolates (alpha = time into the next tic); a client sends it per
  frame. Unpaced clients render as fast as the database answers.
* Sound: `api_sound_events` (filter `event_id > :last`), `api_sound_loops`, `sound_assets` are in
  place. `music_assets` / `map_music` exist but are empty — as on the CedarDB reference here (its
  loader was run without music); phase 6 needs the MUS→MIDI conversion (`wad_loader.mus_to_midi`).
* `blockmaps` is not in the Oracle data layer (spectator list skips it).
* A guest relay (`doom_web.py`) would hand out pre-provisioned accounts; the broker already supports
  any number of them.
