# Game feature coverage: CedarDB SQLDoom vs the Oracle port (phases 3–6)

Every gameplay feature CedarDB's game SQL (`reference/sqldoom/sql/runtime/functions`) implements,
whether `doom_game` (`sql/08_game.sql`) ports it, and how it was verified. **Verified** means: a
recording made on CedarDB exercises the branch (the recording itself shows the effect, see
`tests/scenario_evidence.py`), and the Oracle replay equals CedarDB after the level start and after
every tic in every state table (38–42 tables, floats to 1e-9), plus `sound_due`, the sounds fetched
and the `finish_game_tic` snapshot (single player) or `level_done` and every slot's camera pose
(deathmatch); scenarios marked *frames* also compare the live frame pixel by pixel.

Recordings: the TPC-DOOM E1M1 run (`reference_data/e1m1_game`, 1,200 tics), 178 scenarios
(`reference_data/scenarios/*`, `tests/scenario_defs.py`; 49,806 tics, 1,055 frames compared) and 5 deathmatch runs
(`reference_data/dm_*`, `tests/mp_lib.py`). Status: all equal (`tests/out/scenario_replay_final.log`,
`tests/out/mp_replay_final.log`).

How scenarios reach branches E1M1–E1M3 do not contain: a linedef's special (and its derived flags,
plus CedarDB's `linedef_geom` materialized view) is changed on **both** databases before the level
start and restored afterwards, so the special drives real tagged sectors (E1M1 sector 98, a lift
with a 116-unit opening and three neighbours); the player is placed with the reference's own
`doom_spawn_player` (pose ops), god mode is left off where damage matters; sector specials and
thing types are changed the same way. See `scenario_lib.py`.

## Phase 4: every map, the level flow, the screens

Recordings added: 38 smoke scenarios (`reference_data/scenarios/smoke_*`: each of the 36 maps, level
start + 400 tics of the TPC-DOOM command stream at the episode's skill, 8 frames each; plus E1M6 and
E4M5 without firing) and 14 flows (`reference_data/flows/*`, `tests/flow_defs.py`): scripted runs
through the reference client API, every call's result, every snapshot and every frame compared
(`tests/run_flow.py replay`). Status: see "Phase 4 verification" below.

| area | CedarDB implements | Oracle | verified by |
|---|---|---|---|
| every map of the WAD (36: E1M1–E4M9) | yes (reference loader) | yes (`setup_db.py` loads all, ids 1–36 in WAD order) | ✔ smoke runs: state equal every tic, 8 frames per map pixel-exact |
| BSP deeper than 40 (renderer path key wraps modulo 64) | yes (as a side effect) | yes (`doom_hybrid` deep-BSP key) | ✔ `smoke_e1m4`, `e3m7`, `e4m1`, `e4m2`, `e4m4`, `e4m8`, `e4m9` frames |
| a tic CedarDB fails (noise flood UPDATE … FROM matching a monster twice) — the client drops it | yes | yes (same error, nothing written) | ✔ `smoke_e1m6`, `smoke_e4m5` (379 of 400 tics fail on both); `*_nofire` runs cover the maps |
| level exits → finish_level (kills, items, secrets, time, par) → level_stats | yes | yes | ✔ `exit_e1m1_e1m2`, `secret_exit_*`, `boss_*`, `exit_e4m8_finale4` |
| intermission tally (counting, one-second pauses, waiting, accelerate mid-count, dismiss), screens | yes | yes | ✔ same flows; tally frames pixel-exact (WIMAP0/1/2, INTERPIC) |
| next-map routing: ExMy → ExM(y+1), secret → ExM9, ExM9 → E1M4/E2M6/E3M7/E4M3, ExM8 → finale | yes | yes | ✔ `exit_e1m1_e1m2` (→ E1M2), `secret_exit_e1m3_e1m9_e1m4` (E1M3 → E1M9 → E1M4), boss/E4M8 flows (→ finale) |
| carry_player (health, armor, backpack, ammo, weapons, current weapon; keys/powerups dropped; dead player carries nothing) | yes | yes | ✔ `exit_e1m1_e1m2`, `secret_exit_*` (twice), `death_restart` |
| boss specials: E1M8 barons dead → tag 666 floor lowers | yes | yes | ✔ `boss_e1m8_finale1` (105 snapshots of the 666 mover) |
| boss exit: last cyberdemon (E2M8) / spider mastermind (E3M8) dies → level ends | yes | yes | ✔ `boss_e2m8_finale2`, `boss_e3m8_bunny` |
| finale: text typed at 3 tics/char over the tiled flat, keypress fills the page, TEXTWAIT auto-advance, ending picture, back to the title; E3 bunny scroll + THE END | yes | yes | ✔ episodes 1–4 (`boss_e1m8_finale1`, `boss_e2m8_finale2`, `boss_e3m8_bunny` 55 frames, `exit_e4m8_finale4`) |
| menus: title → main, cursor wrap, help pages, episode/skill, new game, quit action, Esc | yes | yes | ✔ `menus_newgame` (17 frames incl. both skull frames) |
| save/load (menu path, slot names drawn, empty slot ignored, world restored incl. render caches, saved skill_bit adopted) | yes | yes | ✔ `save_load_e1m2` |
| typed cheats (`doom_cheat_key`): all codes, IDDT, IDMUS, IDCLEV warp, 12-char buffer | yes | yes | ✔ `cheat_keys` |
| weapon slot / cycle queries | yes (client SQL) | yes (`doom_flow.weapon_slot/_cycle`) | ✔ `cheat_keys` |
| demo record, playback, end of demo; attract loop (title, demo, credit, demo …) | yes | yes | ✔ `demo_record_play` |
| automap: follow, zoom (clamped), pan, grid, fit, computer map, IDDT 1/2, on four maps | yes | yes (`doom_screen.render_automap`) | ✔ `automap_views` (56 automap frames) |
| a monster crossing a monsters-only teleport line | yes | yes | ✔ `monster_teleport` (E2M2 closet imps, 8 monster_teleports rows) |
| the lost soul's charge hitting the player | yes | yes | ✔ `lost_soul_charge` |
| sound loops (`sound_loops.sql`), stage music (`stage_music.sql`), the api role layer, referee | yes | yes (phase 5: `api_sound_loops`, `api_stage_music`, `api_*`, `referee.py`; phase 6: the single-player statements) | see "Phase 5" and "Phase 6" below |

### Phase 4 verification (final run, `tests/out/p4/`)

* **Smoke runs**: 38/38 equal on every tic (36 maps + E1M6/E4M5 without firing; 15,200 tics; on
  E1M6 and E4M5 379 tics each fail on CedarDB and identically on Oracle), 296/296 frames pixel-exact.
* **Flows**: 14/14 equal — 11,525 calls, 8,107 tics, 11,254 snapshots, 271/271 frames exact (60
  3-D, 154 full-screen, 57 automap).

| flow | calls | tics | frames | covers |
|---|---|---|---|---|
| `exit_e1m1_e1m2` | 1,210 | 1,003 | 31 | use exit, tally counted out, carry, E1M2 |
| `secret_exit_e1m3_e1m9_e1m4` | 737 | 656 | 18 | secret exit → E1M9 → E1M4, accelerated tallies |
| `boss_e1m8_finale1` | 874 | 374 | 19 | barons dead → 666 floor, W1 exit, finale 1 (typing, auto-advance, picture) |
| `boss_e2m8_finale2` | 215 | 89 | 11 | cyberdemons dead → boss exit, finale 2 |
| `boss_e3m8_bunny` | 1,440 | 45 | 55 | spider dead → boss exit, bunny scroll, THE END |
| `exit_e4m8_finale4` | 362 | 123 | 20 | E4M8 exit, INTERPIC tally, finale 4 |
| `save_load_e1m2` | 1,172 | 1,125 | 11 | menu save ×2, menu load (empty slot, slot 1), play on, restart after load |
| `menus_newgame` | 252 | 200 | 17 | title/main/help/episode/skill/quit, new game |
| `cheat_keys` | 787 | 618 | 6 | every typed cheat, IDDT, IDMUS, IDCLEV, weapon slot/cycle |
| `automap_views` | 1,369 | 1,240 | 56 | automap on E1M1, E2M2, E3M3, E4M4 |
| `demo_record_play` | 1,443 | 1,008 | 15 | record, playback, attract loop with demos and pages |
| `death_restart` | 541 | 530 | 3 | death, restart, carry from a dead player |
| `monster_teleport` | 1,029 | 1,013 | 4 | closet imps through 125 lines on E2M2 |
| `lost_soul_charge` | 94 | 83 | 5 | a charge landing on the player |

* Everything of phase 3 still equal: TPC run 1,200/1,200, 178 scenarios, 5 deathmatch replays.

## Phase 5: the deathmatch server

| area | CedarDB implements | Oracle | verified by |
|---|---|---|---|
| player accounts with no table grants; `api_*` functions (join, slot, input, camera, weapon slot/cycle, set name, automap + pan/zoom/toggle/fit) and views (snapshot, player state, sound events/loops, stage music, map lines/geometry, stages, palettes, scoreboard, match, tic, things live/spawn) | yes (`42_api.sql`, `install_api_views`) | yes (`sql/13_api.sql`, `api_install.py`; roles `DOOM_PLAYER`/`DOOM_SPECTATOR`, READ grants) | ✔ `mp_acl_check.py` 63/63; `api_replay.py` vs CedarDB |
| per-slot frame views, a frame only for the slot's holder | yes | yes (`api_frame_slot<n>_m<map>`, `render_frame_bd`) | ✔ ACL check; 675/675 replayed frames pixel-exact |
| the lobby queue, join grace, idle reaping, seat turnover while others wait | yes | yes (`api_join`, `doom_mp.reap`, `hold_turnover`) | ✔ `lobby_check.py`; replay (reap + queued claim) |
| spectators | yes | yes (READ on the WAD, catalogues, public match views; profile 16 sessions) | ✔ `spectator_check.py` |
| referee: one per match (heartbeat), 35 Hz, signals, crash wait-out, warm-up, -timer end, intermission, rotation with slots carried over | yes (`doom_server.py`) | yes (`client/referee.py`, `doom_mp`) | ✔ `referee_check.py`, `mp_rotation_check.py`, replay |
| frags through the API (names, messages, scoreboard) | yes | yes | ✔ `mp_frag_check.py` |
| per-player screens: automap per player; `screen_state` single-player (constants in `api_snapshot`) | yes | yes | ✔ replay (automap calls of two players, 14 frames) |
| account provisioning (`add_player.py`, `add_spectator.py`, `setup_roles.py`), re-grant on reinstall | yes | yes (`accounts.py` via the `DOOM_ADMIN` broker; `api_install.py` re-grants) | ✔ every check provisions and drops its accounts |
| music assets (`music_assets`, `map_music`) | MUS lumps only (freedoom1.wad has none: empty) | MUS + MIDI lumps (41 tracks) | phase 6 below |

## Phase 6: the clients

Details: [clients.md](clients.md).

| reference client file | what it does | Oracle | verified by |
|---|---|---|---|
| `doom_client.py` — single player | input, 35 Hz tic, deferred exits, intermission/finale/attract clocks, menus, save/load, cheats, demos, automap, weapon slot/cycle, respawn | `client/doom_client.py` (`SPGame`) | ✔ `client_run_check.py` (1,200/1,200 tic snapshots + sounds equal to CedarDB through the real loop); `client_ui_smoke.py` 17/17 |
| `doom_client.py` — `DOOM_JOIN` deathmatch | the player's own role, `api_*` only | `doom_client.py --join USER` (`MPGame`) | ✔ headless join run (lobby, input, frames, automap, sounds) |
| `render_worker.py` | frames on their own connection, newest request, never waited on | `RenderWorker` + READ ONLY transaction between tics; `--split` (two sessions per frame) | ✔ frames at interpolated alphas (pending: CedarDB re-render, see clients.md) |
| `audio.py` | sound bank, one-shots on 16 channels, loops on 8 reserved channels, stage music | `doom_client.Audio` (same channel plan and pan law; MIDI via pygame-ce) | ✔ events equal (client run); loops via the API replay; music 36/36 maps |
| `midi_render.py`, `wad_loader.load_music` (MUS→MIDI, map→track) | music data | `client/music.py` (+ native MIDI lumps: Freedoom's music is MIDI) | ✔ 3,000/3,000 MUS conversions equal; 41/41 tracks byte-equal on the same data |
| `dock.py` | diagnostics dock: EXPLAIN replay, CTE pipeline graph, BSP band, tic rack, FPS badge | FPS badge only (F6) | — the hybrid renderer has no CTE pipeline to count (not ported) |
| `doom_config.py` | env knobs, constants from `doom_constants` | CLI options + env (`MAP_ID`, `WINDOW_SCALE`, `MOUSE_SENSITIVITY`); constants read from `doom_constants` | — |
| `sql/client/camera_pose.sql` | camera between tics | `game_api.CAMERA_SQL` (+ `doom_float8`), `FRAME_AT_SQL` | ✔ 22,662/22,662 vs a type-faithful evaluation; α = 1 vs CedarDB 1,200/1,200 (direct CedarDB comparison pending) |
| `sound_assets.sql`, `sound_events.sql`, `sound_loops.sql`, `stage_music.sql` | audio queries | `SOUND_ASSETS_SQL`, `SOUND_SQL`, `SOUND_LOOPS_SQL`, `STAGE_MUSIC_SQL` (the API views generated from them) | ✔ assets 69/69, music 36/36 maps, events 1,200 tics; loops: API replay |
| `demo_header.sql`, `spawn_pose.sql`, `stages.sql`, `level_stats.sql` | flow queries | `DEMO_HEADER_SQL`, `SPAWN_POSE_SQL`, `STAGES_SQL`, `LEVEL_STATS_SQL` | ✔ flows (phase 4), stages 36/36 |
| `render_stats_tail.sql` | counts of the CTE pipeline for the dock | — | not applicable (see dock) |
| `doom_web.py` + `web/index.html`, `app.js`, `pgwire.js` | browser deathmatch through a Postgres-protocol WebSocket tunnel | `client/doom_web.py` (bridge with a closed `api_*` vocabulary, the browser's own account) + `client/web/index.html`, `app.js`, `oraws.js` | ✔ headless Chrome: in game, 34.5 fps, no console errors; bridge ≈ direct latency |
| `scripts/web_smoke.mjs`, `web_browser_check.mjs`, `bots.mjs` | browser path tests, bots | `tests/web_smoke.mjs`, `web_browser_check.mjs`, `bots.mjs` | ✔ run (clients.md) |
| `scripts/determinism_check.py`, `all_maps_smoke.py`, `prepared_pipeline_smoke.py` | reproducibility, every map, install sanity | `tests/` ports, with `--cedar` comparisons | ✔ Oracle side (3/3, 36/36, ok); `--cedar` pending |
| `scripts/render_capacity.py` | renderer processes next to a 35 Hz ticker | covered by `benchmark/concurrency.py` (renders) and `tests/mp_api_match.py` (renders + referee through the API) | phase 2–5 results |
| `scripts/local_demo.sh` | start everything for a demo | README "Play it" (referee, accounts, client, bridge commands); `make play`, `make web` | — |

## Summary

| area | CedarDB implements | Oracle | verified by |
|---|---|---|---|
| line specials (135 in `line_special_defs`) | all 135 | all ported | every special has a scenario, all 135 equal on every tic; 128 of them change state on CedarDB in their scenario (the rest: see the notes below the table) |
| doors: DR/D1/S1/SR/W1/WR open, close, open-wait-close, close-wait-open, blazing, keyed (blue/yellow/red, locked message) | yes | yes | ✔ (`s0xx`, `w0xx`, `s1xx`, `e1m1_door117`, `e1m2_door63/103/109`, `e1m2_keys`, `e1m1_locked`, `e1m3_d1blue`) |
| floors: lower to lowest/highest/highest+8 (turbo), raise to lowest ceiling (−8 crush), next higher, +24/+32/+512, shortest texture, *change* variants (flat + special copy) | yes | yes | ✔ (`s/w0xx`, `e1m1_floor23`, `e1m2_raise58`, `e1m3_raise20` *frames*, `s014` *frames*) |
| lifts / platforms (S1/SR/W1/WR, blazing), perpetual platforms + stop, resume | yes | yes | ✔ (`e1m1_lift62` *frames*, `e1m2_lift120/123`, `stop053_054`, `stop087_089`) |
| ceilings: raise to highest, lower to floor, floor+8 crush | yes | yes | ✔ (`s041` *frames*, `s043`, `w040`, `w044`, `w072`) |
| crushers (normal, fast, silent, WR) + stop + resume, crush damage (god off) | yes | yes | ✔ (`stop006_057` *frames*, `stop025_074`, `stop073_057`, `stop077_074`, `stop141_057`: player crushed to death) |
| stairs (8, 16 turbo; S1/W1) | yes | yes | ✔ (`e1m3_stairs7` *frames*, `s007`, `s127`, `w008`, `w100`) |
| donut (S1) | yes | yes | ✔ (`s009` *frames*) |
| light lines: to 255 / 35 / max / min neighbour, strobing | yes | yes | ✔ (`e1m3_lights138`, `s138` *frames*, `s139`, `w012/013/035/079/081/104`, `w017` *frames*; `w080`: no brighter neighbour, nothing to change) |
| teleports: W1/WR, player, fog, from the back (no teleport), monsters-only lines crossed by the player | yes | yes | ✔ (`e1m2_teleport_back` (97), `e1m2_teleport39`; `e1m2_teleport125/126`, `e1m2_teleport97` *frames*: no teleport) |
| switches: SW1 texture change, repeatable button timer and restore, one-shot activations | yes | yes | ✔ (`e1m1_floor23` *frames*, `e1m2_turbo71`, `e1m1_lift62`, every S1 scenario) |
| shoot-activated lines (G1/GR) | yes | yes | ✔ (`g024`, `g046`, `g047`) |
| exits: use (S1), cross (W1), secret exits, finish snapshot flags | yes | yes | ✔ (`e1m1_exit`, `s011`, `s051`, `w052`, `w124`, `e1m3_secret_exit`) |
| scrolling wall (48) | renderer only (a function of `level_tics`) | renderer | frames (`e1m2_scroll48` *frames*) |
| sector light specials 1 2 3 8 12 13 17 (`sector_light_fx` at level start, animated by the renderer) | yes | yes | ✔ state (`e1m1_sector_fx`) and frames (`e1m1_sector_fx` *frames*, 140 frames) |
| damaging floors 5 7 16, 4 (+blink), 11 (+ ends the level at ≤ 10 % health, god mode removed) | yes | yes | ✔ (`e1m1_nukage`, `e1m3_damage`, `e1m1_sector_damage`: death, sector_exit) |
| secret sectors (9) | yes | yes | ✔ (TPC run, scenarios) |
| sector 10 / 14 (door closes after 30 s / opens after 300 s) | **not implemented by CedarDB** (no code reads them) | — | `e1m1_door_timer10` (1,120 tics) shows no effect on either side |
| player: movement, collision, step-up, bobbing, turning, use trace, line crossing, pickups (health, armor, ammo, weapons, backpack, keys, powerups) | yes | yes | ✔ (TPC run + every scenario) |
| player damage without god mode, armor absorption, pain, death, death view sinking | yes | yes | ✔ (`tpc_nogod`, `e1m1_nukage`, crushers) |
| weapons: fist, chainsaw, pistol, shotgun, chaingun, rocket launcher (splash, thrust), plasma, BFG ball + BFG spray | yes | yes | ✔ (TPC run, `tpc_fist`, `tpc_chainsaw`, `tpc_plasma`, `tpc_bfg` *frames*: `bfg` projectile and `bfg_spray` effects in the recording) |
| skills 0 (ITYTD: double ammo, half damage), 2, 3 (UV), 4 (nightmare: fast monsters, respawn) | yes | yes | ✔ (`tpc_skill0`, TPC run, `tpc_skill3`, `tpc_nightmare` 2,000 tics: a monster respawned with teleport fog) |
| monsters: sight, noise alert, chase, melee, hitscan, missiles (imp, caco, baron), pain, death, gibs, drops, infighting, barrels | yes | yes | ✔ (TPC run, `tpc_floaters` with cacodemons, lost souls and a baron put in place of zombies/imps, *frames*) |
| monster float (caco, lost soul), lost soul charge (skull_fly) | yes | yes | ✔ float (`tpc_floaters`), charge hitting the player (`lost_soul_charge` flow, phase 4) |
| monster teleports (monster crossing 97/125/126) | yes | yes | ✔ `monster_teleport` flow (phase 4) |
| boss actions (E1M8 666 floor, exit on boss death) | yes | yes | ✔ `boss_e1m8_finale1`, `boss_e2m8_finale2`, `boss_e3m8_bunny` (phase 4) |
| level start, cheats (IDDQD, IDKFA, IDFA, IDCLIP, IDBEHOLD*, …) | yes | yes | ✔ (every recording starts with them) |
| sounds (`sound_events`, fetched with volume/pan), trim | yes | yes | ✔ (single player every tic; deathmatch trim every 35 tics) |
| **deathmatch** (39_mp.sql, 40 mp tic, 27 item respawn): match row, slots, claims/join requests, input folding, respawn on a random free DM start (fog + DSTELEPT), reborn loadout, other players block / are shot / are hit by missiles and splash, killer bookkeeping, frags (+1, suicide/world −1), messages, PLAY sprite frames (run/attack/flash/pain/death/gib), -altdeath item respawn (IFOG + DSITMBK), -nomonsters, -respawn, -timer level end, exits, rotating world player for monsters, retarget on dead/unclaimed players | yes | yes | ✔ 5 recordings, 6,250 tics, 3,364 frames per player view (below) |
| menus, save/load, intermission, finale, demos, attract loop, `doom_cheat_key`, automap | yes | yes (phase 4) | ✔ flows (above) |
| deathmatch server: player/spectator accounts, `api_*` functions and views, per-slot frame views, referee (heartbeat, 35 Hz, reaping, lobby, seat turnover, rotation, warm-up) | yes | yes (phase 5) | ✔ see "Phase 5" |

### Deathmatch recordings (all equal; `run_game_correctness.py --mp NAME`)

| run | map, skill | slots claimed / ticked | tics | features shown in the recording | frames compared |
|---|---|---|---|---|---|
| `dm_e1m1_2p_roam` | E1M1, 2 | 2 / 4 | 1,500 | monsters on, -altdeath (36 item respawn rows), roaming bots | 1,000 / 1,000 |
| `dm_e1m1_2p` | E1M1, 2 | 2 / 4 | 1,500 | arena: players meet; monsters kill them (frags −4/−1), 11 deaths and respawns | 1,000 / 1,000 |
| `dm_e1m1_4p` | E1M1, 2 | 4 / 4 | 1,150 | -nomonsters, 4 bots frag each other (5/2/4/3), 14 deaths, -timer ends the level at tic 1,150 | 764 / 764 |
| `dm_e1m1_2p_duel` | E1M1, 2 | 2 / 4 | 1,200 | chaingun + rocket loadout, frags, suicides | 600 / 600 |
| `dm_e1m2_3p_nomon` | E1M2, 3 | 3 / 4 | 900 | -nomonsters, skill 3, roaming | — |

## Line specials

Generated by `tests/coverage_matrix.py --summary tests/out/scenarios_summary.json` from the
recordings (`scenario_evidence.py`: what CedarDB's own run shows) and the replay results. "no
effect" means CedarDB ran the special and nothing changed, and Oracle agreed:
* 80 (lights to brightest neighbour): sector 98's neighbours are not brighter; 128/130/132 (raise to
  next higher floor): sector 98 has no higher neighbouring floor; e1m2_floor19/38: the natural lines
  surround raised platforms the player cannot walk into (the crafted `w019`/`w038` move floors).
* 125/126 (monsters-only teleports) crossed by the player: no teleport. `e1m2_teleport97` walks into
  line 1219/126 from the side that blocks the player (no crossing); `e1m2_teleport_back` crosses the
  natural 97 line from the passable side and is teleported (CedarDB's teleport does not test the
  crossing side), `e1m2_teleport39` the same with special 39.
* 48 (scrolling wall) changes no state: the renderer scrolls it from `level_tics`;
  `e1m2_scroll48` compares 35 frames of the scrolling wall, all pixel-exact.

| special | name | scenarios | CedarDB effect | Oracle equal |
|---|---|---|---|---|
| 1 | DR Door Open Wait Close | s001 | s001: door_manual_raise/ceiling | yes |
| 2 | W1 Door Open Stay | e1m1_w1door, w002 | e1m1_w1door: door_open/ceiling; one-shot; w002: door_open/ceiling; one-shot | yes |
| 3 | W1 Door Close Stay | w003 | w003: door_close/ceiling; one-shot | yes |
| 4 | W1 Door Open Wait Close | w004 | w004: door_raise/ceiling; one-shot | yes |
| 5 | W1 Floor Raise To Lowest Ceiling | w005 | w005: floor_raise/floor; one-shot | yes |
| 6 | W1 Ceiling Crusher Fast | stop006_057, w006 | stop006_057: crusher/ceiling crush; one-shot; min hp 34; w006: crusher/ceiling crush; one-shot; min hp 0 | yes |
| 7 | S1 Stairs Raise 8 | e1m3_stairs7, s007 | e1m3_stairs7: floor_raise/floor; one-shot; s007: floor_raise/floor; one-shot | yes |
| 8 | W1 Stairs Raise 8 | w008 | w008: floor_raise/floor; one-shot | yes |
| 9 | S1 Donut | s009 | s009: floor_lower/floor; one-shot | yes |
| 10 | W1 Lift | w010 | w010: platform/floor; one-shot | yes |
| 11 | S1 Exit Level | e1m1_exit, s011 | e1m1_exit: use_exit; one-shot; switch tex; s011: use_exit; one-shot | yes |
| 12 | W1 Lights To Max Neighbor | w012 | w012: one-shot | yes |
| 13 | W1 Lights To 255 | w013 | w013: light x1; one-shot | yes |
| 14 | S1 Floor Raise 32 Change | s014 | s014: floor_raise/floor; flat change; one-shot | yes |
| 15 | S1 Floor Raise 24 Change | s015 | s015: floor_raise/floor; flat change; one-shot | yes |
| 16 | W1 Door Close Wait Open | w016 | w016: door_close_open/ceiling; one-shot | yes |
| 17 | W1 Lights Start Strobing | w017 | w017: one-shot | yes |
| 18 | S1 Floor Raise To Next Higher | s018 | s018: one-shot | yes |
| 19 | W1 Floor Lower To Highest | e1m2_floor19, w019 | e1m2_floor19: no effect; w019: floor_lower/floor; one-shot | yes |
| 20 | S1 Floor Raise To Next Higher Change | e1m3_raise20, s020 | e1m3_raise20: floor_raise/floor; flat change; one-shot; switch tex; s020: one-shot | yes |
| 21 | S1 Lift | s021 | s021: platform/floor; one-shot | yes |
| 22 | W1 Floor Raise To Next Higher Change | w022 | w022: one-shot | yes |
| 23 | S1 Floor Lower To Lowest | e1m1_floor23, e1m3_floor23, s023 | e1m1_floor23: floor_lower/floor; one-shot; switch tex; e1m3_floor23: floor_lower/floor; one-shot; switch tex; s023: floor_lower/floor; one-shot | yes |
| 24 | G1 Floor Raise To Lowest Ceiling | g024 | g024: floor_raise/floor; one-shot | yes |
| 25 | W1 Ceiling Crusher | stop025_074, w025 | stop025_074: crusher/ceiling crush; one-shot; min hp 0; w025: crusher/ceiling crush; one-shot; min hp 0 | yes |
| 26 | DR Door Blue Key | s026 | s026: door_manual_raise/ceiling | yes |
| 27 | DR Door Yellow Key | e1m2_keys, s027 | e1m2_keys: door_manual_raise/ceiling; s027: door_manual_raise/ceiling | yes |
| 28 | DR Door Red Key | e1m2_keys, s028 | e1m2_keys: door_manual_raise/ceiling; s028: door_manual_raise/ceiling | yes |
| 29 | S1 Door Open Wait Close | s029 | s029: door_raise/ceiling; one-shot | yes |
| 30 | W1 Floor Raise By Shortest Texture | w030 | w030: floor_raise/floor; one-shot | yes |
| 31 | D1 Door Open Stay | e1m2_d1door31, s031 | e1m2_d1door31: door_open/ceiling; one-shot; s031: door_open/ceiling; one-shot | yes |
| 32 | D1 Door Blue Key | e1m3_d1blue, s032 | e1m3_d1blue: door_open/ceiling; one-shot; s032: door_open/ceiling; one-shot | yes |
| 33 | D1 Door Red Key | s033 | s033: door_open/ceiling; one-shot | yes |
| 34 | D1 Door Yellow Key | s034 | s034: door_open/ceiling; one-shot | yes |
| 35 | W1 Lights To 35 | w035 | w035: light x1; one-shot | yes |
| 36 | W1 Floor Lower Turbo | w036 | w036: floor_lower/floor; one-shot | yes |
| 37 | W1 Floor Lower To Lowest Change | w037 | w037: floor_lower/floor; flat change; one-shot | yes |
| 38 | W1 Floor Lower To Lowest | e1m2_floor38, w038 | e1m2_floor38: no effect; w038: floor_lower/floor; one-shot | yes |
| 39 | W1 Teleport | e1m2_teleport39 | e1m2_teleport39: teleport; one-shot | yes |
| 40 | W1 Ceiling Raise To Highest | w040 | w040: ceiling_raise/ceiling; one-shot | yes |
| 41 | S1 Ceiling Lower To Floor | s041 | s041: ceiling_lower/ceiling; one-shot | yes |
| 42 | SR Door Close Stay | s042 | s042: door_close/ceiling | yes |
| 43 | SR Ceiling Lower To Floor | s043 | s043: ceiling_lower/ceiling | yes |
| 44 | W1 Ceiling Lower To Floor+8 Crush | w044 | w044: ceiling_lower/ceiling crush; one-shot; min hp 0 | yes |
| 45 | SR Floor Lower To Highest | s045 | s045: floor_lower/floor | yes |
| 46 | GR Door Open Stay | g046 | g046: door_open/ceiling | yes |
| 47 | G1 Floor Raise To Next Change | g047 | g047: one-shot | yes |
| 48 | Scrolling Wall Left | e1m2_scroll48 | e1m2_scroll48: no effect | yes |
| 50 | S1 Door Close Stay | s050 | s050: door_close/ceiling; one-shot | yes |
| 51 | S1 Secret Exit | e1m3_secret_exit, s051 | e1m3_secret_exit: use_exit/use_secret_exit; one-shot; switch tex; s051: use_exit/use_secret_exit; one-shot | yes |
| 52 | W1 Exit Level | w052 | w052: cross_exit; one-shot | yes |
| 53 | W1 Platform Perpetual Raise | stop053_054, w053 | stop053_054: platform_perpetual/floor; one-shot; min hp 94; w053: platform_perpetual/floor; one-shot | yes |
| 54 | W1 Platform Stop | stop053_054 | stop053_054: platform_perpetual/floor; one-shot; min hp 94 | yes |
| 55 | S1 Floor Raise To Lowest Ceiling -8 Crush | s055 | s055: floor_raise/floor crush; one-shot; min hp 85 | yes |
| 56 | W1 Floor Raise To Lowest Ceiling -8 Crush | w056 | w056: floor_raise/floor crush; one-shot; min hp 0 | yes |
| 57 | W1 Ceiling Crusher Stop | stop006_057, stop073_057, stop141_057 | stop006_057: crusher/ceiling crush; one-shot; min hp 34; stop073_057: crusher/ceiling crush; min hp 0; stop141_057: crusher/ceiling crush; one-shot; min hp 0 | yes |
| 58 | W1 Floor Raise 24 | e1m2_raise58, w058 | e1m2_raise58: floor_raise/floor; one-shot; w058: floor_raise/floor; one-shot | yes |
| 59 | W1 Floor Raise 24 Change | w059 | w059: floor_raise/floor; flat change; one-shot | yes |
| 60 | SR Floor Lower To Lowest | s060 | s060: floor_lower/floor | yes |
| 61 | SR Door Open Stay | s061 | s061: door_open/ceiling | yes |
| 62 | SR Lift | e1m1_lift62, s062 | e1m1_lift62: platform/floor; s062: platform/floor | yes |
| 63 | SR Door Open Wait Close | e1m2_door63, s063 | e1m2_door63: door_raise/ceiling; s063: door_raise/ceiling | yes |
| 64 | SR Floor Raise To Lowest Ceiling | s064 | s064: floor_raise/floor | yes |
| 65 | SR Floor Raise To Lowest Ceiling -8 Crush | s065 | s065: floor_raise/floor crush; min hp 85 | yes |
| 66 | SR Floor Raise 24 Change | s066 | s066: floor_raise/floor; flat change | yes |
| 67 | SR Floor Raise 32 Change | s067 | s067: floor_raise/floor; flat change | yes |
| 70 | SR Floor Lower Turbo | s070 | s070: floor_lower/floor | yes |
| 71 | S1 Floor Lower Turbo | e1m2_turbo71, s071 | e1m2_turbo71: floor_lower/floor; one-shot; switch tex; s071: floor_lower/floor; one-shot | yes |
| 72 | WR Ceiling Lower To Floor+8 Crush | w072 | w072: ceiling_lower/ceiling crush; min hp 0 | yes |
| 73 | WR Ceiling Crusher | stop073_057, w073 | stop073_057: crusher/ceiling crush; min hp 0; w073: crusher/ceiling crush; min hp 0 | yes |
| 74 | WR Ceiling Crusher Stop | stop025_074, stop077_074 | stop025_074: crusher/ceiling crush; one-shot; min hp 0; stop077_074: crusher/ceiling crush; min hp 0 | yes |
| 75 | WR Door Close Stay | w075 | w075: door_close/ceiling | yes |
| 76 | WR Door Close Wait Open | w076 | w076: door_close_open/ceiling | yes |
| 77 | WR Ceiling Crusher Fast | stop077_074, w077 | stop077_074: crusher/ceiling crush; min hp 0; w077: crusher/ceiling crush; min hp 0 | yes |
| 79 | WR Lights To 35 | w079 | w079: light x1 | yes |
| 80 | WR Lights To Max Neighbor | w080 | w080: no effect | yes |
| 81 | WR Lights To 255 | w081 | w081: light x1 | yes |
| 82 | WR Floor Lower To Lowest | w082 | w082: floor_lower/floor | yes |
| 83 | WR Floor Lower To Highest | w083 | w083: floor_lower/floor | yes |
| 84 | WR Floor Lower To Lowest Change | w084 | w084: floor_lower/floor; flat change | yes |
| 86 | WR Door Open Stay | w086 | w086: door_open/ceiling | yes |
| 87 | WR Platform Perpetual Raise | stop087_089, w087 | stop087_089: platform_perpetual/floor; min hp 94; w087: platform_perpetual/floor | yes |
| 88 | WR Lift | w088 | w088: platform/floor | yes |
| 89 | WR Platform Stop | stop087_089 | stop087_089: platform_perpetual/floor; min hp 94 | yes |
| 90 | WR Door Open Wait Close | w090 | w090: door_raise/ceiling | yes |
| 91 | WR Floor Raise To Lowest Ceiling | w091 | w091: floor_raise/floor | yes |
| 92 | WR Floor Raise 24 | w092 | w092: floor_raise/floor | yes |
| 93 | WR Floor Raise 24 Change | w093 | w093: floor_raise/floor; flat change | yes |
| 94 | WR Floor Raise To Lowest Ceiling -8 Crush | w094 | w094: floor_raise/floor crush; min hp 0 | yes |
| 96 | WR Floor Raise By Shortest Texture | w096 | w096: floor_raise/floor | yes |
| 97 | WR Teleport | e1m2_teleport97, e1m2_teleport_back | e1m2_teleport97: no effect; e1m2_teleport_back: teleport | yes |
| 98 | WR Floor Lower Turbo | w098 | w098: floor_lower/floor | yes |
| 99 | SR Door Blue Open Stay Blazing | s099 | s099: door_open/ceiling | yes |
| 100 | W1 Stairs Raise 16 Turbo | w100 | w100: floor_raise/floor; one-shot | yes |
| 101 | S1 Floor Raise To Lowest Ceiling | s101 | s101: floor_raise/floor; one-shot | yes |
| 102 | S1 Floor Lower To Highest | e1m2_floor102, s102 | e1m2_floor102: floor_lower/floor; one-shot; s102: floor_lower/floor; one-shot | yes |
| 103 | S1 Door Open Stay | e1m2_door103, e1m3_door103, s103 | e1m2_door103: door_open/ceiling; one-shot; switch tex; e1m3_door103: door_open/ceiling; one-shot; s103: door_open/ceiling; one-shot | yes |
| 104 | W1 Lights To Min Neighbor | w104 | w104: light x1; one-shot | yes |
| 105 | WR Door Open Wait Close Blazing | w105 | w105: door_raise/ceiling | yes |
| 106 | WR Door Open Stay Blazing | w106 | w106: door_open/ceiling | yes |
| 107 | WR Door Close Blazing | w107 | w107: door_close/ceiling | yes |
| 108 | W1 Door Open Wait Close Blazing | w108 | w108: door_raise/ceiling; one-shot | yes |
| 109 | W1 Door Open Blazing | e1m2_door109, w109 | e1m2_door109: door_open/ceiling; one-shot; w109: door_open/ceiling; one-shot | yes |
| 110 | W1 Door Close Blazing | w110 | w110: door_close/ceiling; one-shot | yes |
| 111 | S1 Door Open Wait Close Blazing | s111 | s111: door_raise/ceiling; one-shot | yes |
| 112 | S1 Door Open Stay Blazing | s112 | s112: door_open/ceiling; one-shot | yes |
| 113 | S1 Door Close Blazing | s113 | s113: door_close/ceiling; one-shot | yes |
| 114 | SR Door Open Wait Close Blazing | s114 | s114: door_raise/ceiling | yes |
| 115 | SR Door Open Stay Blazing | s115 | s115: door_open/ceiling | yes |
| 116 | SR Door Close Blazing | s116 | s116: door_close/ceiling | yes |
| 117 | DR Door Blazing | e1m1_door117, s117 | e1m1_door117: door_manual_raise/ceiling,platform/floor; s117: door_manual_raise/ceiling | yes |
| 118 | S1 Door Open Blazing | s118 | s118: door_open/ceiling; one-shot | yes |
| 119 | W1 Floor Raise To Next | w119 | w119: one-shot | yes |
| 120 | WR Lift Blazing | e1m2_lift120, w120 | e1m2_lift120: platform/floor; w120: platform/floor | yes |
| 121 | W1 Lift Blazing | w121 | w121: platform/floor; one-shot | yes |
| 122 | S1 Lift Blazing | s122 | s122: platform/floor; one-shot | yes |
| 123 | SR Lift Blazing | e1m2_lift123, s123 | e1m2_lift123: platform/floor; s123: platform/floor | yes |
| 124 | W1 Secret Exit | w124 | w124: cross_exit/cross_secret_exit; one-shot | yes |
| 125 | W1 Teleport Monsters Only | e1m2_teleport125 | e1m2_teleport125: no effect | yes |
| 126 | WR Teleport Monsters Only | e1m2_teleport126 | e1m2_teleport126: no effect | yes |
| 127 | S1 Stairs Raise 16 Turbo | s127 | s127: floor_raise/floor; one-shot | yes |
| 128 | WR Floor Raise To Next | w128 | w128: no effect | yes |
| 129 | W1 Floor Raise Turbo To Next | w129 | w129: one-shot | yes |
| 130 | WR Floor Raise Turbo To Next | w130 | w130: no effect | yes |
| 131 | S1 Floor Raise Turbo To Next | s131 | s131: one-shot | yes |
| 132 | SR Floor Raise Turbo To Next | s132 | s132: no effect | yes |
| 133 | S1 Door Blue Open Stay Blazing | s133 | s133: door_open/ceiling; one-shot | yes |
| 134 | SR Door Red Open Stay Blazing | s134 | s134: door_open/ceiling | yes |
| 135 | S1 Door Red Open Stay Blazing | s135 | s135: door_open/ceiling; one-shot | yes |
| 136 | SR Door Yellow Open Stay Blazing | s136 | s136: door_open/ceiling | yes |
| 137 | S1 Door Yellow Open Stay Blazing | s137 | s137: door_open/ceiling; one-shot | yes |
| 138 | SR Lights To 255 | e1m3_lights138, s138 | e1m3_lights138: light x1; s138: light x1 | yes |
| 139 | SR Lights To 35 | s139 | s139: light x1 | yes |
| 140 | S1 Floor Raise 512 | s140 | s140: floor_raise/floor; one-shot | yes |
| 141 | W1 Ceiling Crusher Silent | stop141_057, w141 | stop141_057: crusher/ceiling crush; one-shot; min hp 0; w141: crusher/ceiling crush; one-shot; min hp 0 | yes |

