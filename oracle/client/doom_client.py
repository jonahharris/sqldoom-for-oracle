#!/usr/bin/env python3
"""SQL Doom on Oracle: the playable desktop client (pygame), a port of CedarDB SQLDoom's
doom_client.py. All game logic and all rendering run in the database; this program reads the
keyboard and mouse, sends one command per 35 Hz tic, asks for frames, maps palette indices through
PLAYPAL, and plays the sounds and music the database selects.

    python oracle/client/doom_client.py                      # single player: title screen, menus
    python oracle/client/doom_client.py --warp E1M3 --skill 3   # straight into a level
    python oracle/client/doom_client.py --join alice --password ...   # deathmatch (referee running)

Single player (the game owner's account, DOOM by default): the title and attract loop, the menus
(new game, episode, skill, load/save, quit), level exits, the intermission tally, the next map with
the player carried over, secret exits, the finale, the automap, typed cheats (IDDQD, IDKFA, IDCLEVxy,
IDMUSxy, IDDT, ...), demo recording and playback (F9/F10) -- every one a doom_flow/doom_game call.

Deathmatch (--join): the player's own database account (accounts.py player NAME), the api_* surface
only: api_join (waits in the lobby), api_input per tic, api_camera(alpha) + the slot's frame view
per frame, api_sound_events/_loops, api_stage_music, api_automap*, api_weapon_*.

Frames are requested independently of the tic: a render thread with its own session(s) renders
the newest request as fast as the database answers, each frame at the camera interpolated between
the last two tics by alpha (client/camera_pose.sql, in SQL), in a READ ONLY transaction started
between two tics (so a frame never mixes two tics). Split rendering draws each frame on two
sessions, one screen-column range each (both pinned to the same tic). Nothing of a frame is cached.

Sprites: by default the renderer clips sprites the way Doom does (planes drawn first, sprites clipped
only by the silhouettes of the segs in front of them, so barrels and items stand on the floor instead
of sinking into it); --cedar-exact renders them as the CedarDB reference does (depth-tested against
floors and ceilings: pixel-exact to it). Deathmatch frames follow the match's setting (the referee's
SPRITE_MODE), the same for every player.

Render sessions per player = max(1, database CPUs // players) (render_sessions()): single player on
Oracle Free (2 CPUs) splits by default; deathmatch renders one session per player. --split /
--no-split override the rule.

Controls (as the reference): W/S or Up/Down move, A/D strafe, Q/E or Left/Right turn, mouse turns,
left button or Ctrl fires, Shift runs, Space uses (and respawns), 1-7 pick a weapon, the wheel
cycles weapons, Tab automap (F follow, G grid, Home fit, +/- or wheel zoom, WASD/arrows pan),
Esc menu, ` releases the mouse, F5 prints the pose, F6 hides the HUD, F9 records a demo of the
level, F10 plays it back, -/= window size.
"""
import argparse
import io
import json
import math
import os
import sys
import threading
import time
from collections import deque
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

SCREEN_W, SCREEN_H = 320, 200
MAX_TICS_PER_FRAME = 4
AUTOMAP_PAN_SPEED = 900.0


# ================================================================================= database: single player
class SPGame:
    """The reference client's doom_sql.py calls, on Oracle (doom_game / doom_flow / doom_screen via
    client/game_api.py). Every call commits (CedarDB's client runs in autocommit)."""

    api = False

    def __init__(self, dsn=None, user=None, password=None):
        import oradb, game_api
        self.ga = game_api
        kw = {}
        if dsn:
            kw["dsn"] = dsn
        if user:
            kw["user"], kw["password"] = user, password
        self.conn = oradb.connect(**kw)
        self.cur = self.conn.cursor()
        game_api.setup_session(self.cur)
        self.scur = self.conn.cursor()
        self.scur.arraysize = 256
        self.scur.prefetchrows = 257
        self.connect_args = kw

    # -- plumbing
    def fn(self, expr, typ=str, **kw):
        r = self.cur.var(typ)
        self.cur.execute(f"BEGIN :r := {expr}; END;", r=r, **kw)
        self.conn.commit()
        return r.getvalue()

    def proc(self, stmt, **kw):
        self.cur.execute(f"BEGIN {stmt}; END;", **kw)
        self.conn.commit()

    def constants(self):
        self.cur.execute("SELECT name, value FROM doom_constants WHERE name IN ('TICRATE', 'TURN_DEGREES_PER_TIC')")
        return {n: float(v) for n, v in self.cur.fetchall()}

    def palettes(self):
        return self.ga.palettes(self.cur)

    def stages(self):
        self.cur.execute(self.ga.STAGES_SQL)
        return [{"map_id": int(m), "label": n, "player_thing_id": int(p)} for m, n, p in self.cur.fetchall()]

    def sound_assets(self):
        return self.ga.sound_assets(self.cur)

    def stage_music(self, map_id):
        return self.ga.stage_music(self.cur, map_id)

    # -- the level
    def enter_level(self, map_id, player, skill, carry_from=None):
        fm, fp = carry_from if carry_from else (None, None)
        return self.ga.enter_level(self.cur, map_id, player, skill, fm, fp)

    def level_start_like_recorder(self, map_id, player, skill, cheats):
        """set_screen('game') + enter_level + doom_game.cheat(...) -- what the CedarDB recorders do."""
        self.ga.level_start(self.cur, map_id, player, skill, cheats)
        self.cur.execute(self.ga.SPAWN_POSE_SQL, m=map_id, p=player)
        return tuple(float(v) for v in self.cur.fetchone())

    def player_pose(self, map_id, player):
        self.cur.execute("SELECT position_x, position_y, view_angle, view_z, CASE WHEN alive THEN 1 ELSE 0 END "
                         "FROM g_player_state WHERE map_id = :m AND player_thing_id = :p", m=map_id, p=player)
        r = self.cur.fetchone()
        return None if r is None else (float(r[0]), float(r[1]), float(r[2]), float(r[3]), bool(r[4]))

    def tic(self, map_id, player, command, after):
        """run_game_tic: (snapshot, events or None, loops or None)."""
        due = self.ga.run_tic(self.cur, map_id, player, command)
        self.conn.commit()
        events = loops = None
        if due:
            events = self.ga.sound_events(self.cur, map_id, player, after)
            loops = self.ga.sound_loops(self.cur, map_id, player)
        snap = self.ga.finish_tic(self.cur, map_id, player)
        self.conn.commit()
        return snap, events, loops

    def player_health(self, map_id, player):
        self.cur.execute("SELECT health, sector_id FROM g_player_state WHERE map_id = :m AND player_thing_id = :p",
                         m=map_id, p=player)
        r = self.cur.fetchone()
        return "?" if r is None else f"{r[0]} in sector {r[1]}"

    # -- flow (doom_flow)
    def set_screen(self, s):
        self.proc("doom_flow.set_screen(:s)", s=s)

    def screen_state(self):
        self.cur.execute("SELECT screen, cursor_index, episode, skill FROM screen_state WHERE id = 0")
        r = self.cur.fetchone()
        if r is None:
            return {"screen": "game", "cursor": 0, "episode": 1, "skill": 2}
        return {"screen": r[0], "cursor": int(r[1]), "episode": int(r[2]), "skill": int(r[3])}

    def menu_input(self, key):
        act = self.fn("doom_flow.menu_input(:k)", k=key) or "none"
        return act, self.screen_state()

    def save_game(self, slot, map_id, player, skill, name):
        self.fn("doom_flow.save_game(:sl, :m, :p, :sk, :n)", int, sl=slot, m=map_id, p=player, sk=skill, n=name)

    def load_game(self, slot):
        r = self.fn("doom_flow.load_game(:s)", int, s=slot)
        if r is None or r < 0:
            return None
        self.cur.execute("SELECT skill FROM save_slots WHERE slot = :s", s=slot)
        got = self.cur.fetchone()
        return {"map_id": int(r), "skill": 2 if got is None else int(got[0])}

    def level_exit(self, map_id, player, secret):
        r = self.fn("doom_flow.level_exit(:m, :p, :s)", int, m=map_id, p=player, s=int(bool(secret)))
        return None if r is None or r < 0 else int(r)

    def intermission_tic(self):
        st = self.fn("doom_flow.intermission_tic") or "done"
        self.cur.execute("SELECT sp_state, kills_pct, items_pct, secrets_pct, time_secs, par_secs "
                         "FROM screen_state WHERE id = 0")
        fig = self.cur.fetchone() or (0, 0, 0, 0, 0, 0)
        return st, tuple(int(v or 0) for v in fig)

    def intermission_accelerate(self):
        self.fn("doom_flow.intermission_accelerate", int)

    def after_intermission(self, map_id):
        return self.fn("doom_flow.after_intermission(:m)", m=map_id) or f"level:{map_id}"

    def finale_tic(self):
        return self.fn("doom_flow.finale_tic") or "done"

    def finale_advance(self):
        return self.fn("doom_flow.finale_advance") or "done"

    def finale_phase(self):
        self.cur.execute("SELECT finale_stage, finale_count FROM screen_state WHERE id = 0")
        r = self.cur.fetchone()
        return (0, 0) if r is None else (int(r[0]), int(r[1]))

    def cheat_key(self, map_id, player, key):
        return self.fn("doom_flow.cheat_key(:m, :p, :k)", m=map_id, p=player, k=key) or "none"

    def weapon_slot(self, map_id, player, slot):
        r = self.fn("doom_flow.weapon_slot(:m, :p, :s)", int, m=map_id, p=player, s=slot)
        return None if r is None or r < 0 else int(r)

    def weapon_cycle(self, map_id, player, step):
        r = self.fn("doom_flow.weapon_cycle(:m, :p, :s)", int, m=map_id, p=player, s=step)
        return None if r is None or r < 0 else int(r)

    def automap(self, what, map_id, player, *args):
        if what == "pan":
            self.proc("doom_flow.automap_pan(:m, :p, :a, :b)", m=map_id, p=player, a=float(args[0]), b=float(args[1]))
        elif what == "zoom":
            self.proc("doom_flow.automap_zoom(:m, :p, :f)", m=map_id, p=player, f=float(args[0]))
        elif what == "toggle":
            self.proc("doom_flow.automap_toggle(:m, :p, :w)", m=map_id, p=player, w=args[0])
        elif what == "fit":
            self.proc("doom_flow.automap_fit(:m, :p)", m=map_id, p=player)

    def demo_begin(self, name, map_id, player, skill):
        return self.fn("doom_flow.demo_begin(:n, :m, :p, :s)", int, n=name, m=map_id, p=player, s=skill)

    def demo_play(self, name):
        d = self.fn("doom_flow.demo_play(:n)", int, n=name)
        return None if d is None or d < 0 else self.demo_header(d)

    def demo_stop(self):
        self.proc("doom_flow.demo_stop")

    def demo_header(self, demo_id):
        self.cur.execute(self.ga.DEMO_HEADER_SQL, d=demo_id)
        r = self.cur.fetchone()
        if r is None:
            return None
        return {"demo_id": int(r[0]), "name": r[1], "map_id": int(r[2]), "player_thing_id": int(r[3]),
                "skill": int(r[4]), "tic_count": int(r[5])}

    def attract_start(self):
        self.proc("doom_flow.attract_start")

    def attract_stop(self):
        self.proc("doom_flow.attract_stop")

    def attract_tic(self):
        return self.fn("doom_flow.attract_tic") or "none"

    # -- full-screen frames (doom_screen): uint8[200,320] palette indices, palette 0
    def _rows(self, sqltext, **kw):
        self.scur.execute(sqltext, **kw)
        rows = self.scur.fetchall()
        if len(rows) != 200:
            return None
        return decode_rows(rows)

    def render_screen(self, tics):
        return self._rows(self.ga.SCREEN_SQL, t=int(tics))

    def render_automap(self, map_id, player):
        return self._rows(self.ga.AUTOMAP_SQL, m=map_id, p=player)

    def close(self):
        try:
            self.conn.close()
        except Exception:  # noqa: BLE001
            pass


# ================================================================================= database: deathmatch player
class MPGame:
    """A deathmatch player's side through the api_* surface (the player's own account)."""

    api = True

    def __init__(self, user, password, dsn=None):
        import api_client, oradb
        self.user, self.password, self.dsn = user, password, dsn or oradb.DEFAULT_DSN
        self.p = api_client.ApiPlayer(user, password, self.dsn)
        self.cur = self.p.cur
        self.cur.execute("ALTER SESSION SET COMMIT_WAIT = 'NOWAIT'")
        self.connect_args = {"user": user, "password": password, "dsn": self.dsn}

    def constants(self):
        return {"TICRATE": 35.0, "TURN_DEGREES_PER_TIC": 3.2}   # players cannot read doom_constants

    def palettes(self):
        import api_client
        return api_client.palettes(self.cur)

    def stages(self):
        self.cur.execute("SELECT map_id, name, player_thing_id FROM api_stages")
        return [{"map_id": int(m), "label": n, "player_thing_id": int(p)} for m, n, p in self.cur.fetchall()]

    def sound_assets(self):
        self.cur.execute("SELECT name, wav_data FROM sound_assets")
        return [(n, b.read()) for n, b in self.cur.fetchall()]

    def stage_music(self, _map_id=None):
        self.cur.execute("SELECT name, midi_data, audio_data, audio_format FROM api_stage_music")
        r = self.cur.fetchone()
        if r is None:
            return None
        return r[0], r[1].read() if r[1] else None, r[2].read() if r[2] else None, r[3]

    def join(self):
        return self.p.join()

    def where(self):
        return self.p.where()

    def player_pose(self, _m=None, _p=None):
        self.cur.execute("SELECT position_x, position_y, view_angle, view_z, CASE WHEN alive THEN 1 ELSE 0 END "
                         "FROM api_player_state")
        r = self.cur.fetchone()
        return None if r is None else (float(r[0]), float(r[1]), float(r[2]), float(r[3]), bool(r[4]))

    SNAP_COLS = ("x", "y", "angle", "z", "alive", "use_locked", "required_key", "use_exit", "use_secret_exit",
                 "cross_exit", "cross_secret_exit", "sector_exit", "boss_exit", "power_map", "tic_stages",
                 "screen", "demo_active")

    def tic(self, _m, _p, command, after):
        """mp_client_tic: the command goes to the server's next tic; sounds and the snapshot back."""
        _skill, fwd, strafe, run, turn, fire, weapon, use = command
        self.p.input((fwd, strafe, run, turn, fire, weapon, use))
        self.cur.execute("SELECT event_id, sound_name, volume, pan FROM api_sound_events WHERE event_id > :a "
                         "ORDER BY event_id", a=after)
        events = self.cur.fetchall()
        self.cur.execute("SELECT loop_key, sound_name, volume, pan FROM api_sound_loops")
        loops = self.cur.fetchall()
        self.cur.execute("SELECT * FROM api_snapshot")
        r = self.cur.fetchone()
        snap = None
        if r is not None:
            snap = dict(zip(self.SNAP_COLS, r))
            for k in ("x", "y", "angle", "z"):
                snap[k] = float(snap[k])
            for k in ("alive", "use_locked", "use_exit", "use_secret_exit", "cross_exit", "cross_secret_exit",
                      "sector_exit", "boss_exit", "power_map", "demo_active"):
                snap[k] = bool(snap[k])
        return snap, events, loops

    def events_max(self):
        self.cur.execute("SELECT NVL(MAX(event_id), 0) FROM api_sound_events")
        return int(self.cur.fetchone()[0])

    def weapon_slot(self, _m, _p, slot):
        r = self.p.weapon_slot(slot)
        return None if r < 0 else r

    def weapon_cycle(self, _m, _p, step):
        r = self.p.weapon_cycle(step)
        return None if r < 0 else r

    def automap(self, what, _m, _p, *args):
        if what == "pan":
            self.p.automap_pan(*args)
        elif what == "zoom":
            self.p.automap_zoom(args[0])
        elif what == "toggle":
            self.p.automap_toggle(args[0])
        elif what == "fit":
            self.p.automap_fit()

    def render_automap(self, _m=None, _p=None):
        return self.p.automap()

    def match(self):
        self.cur.execute("SELECT state, map_id, map_name, intermission_seconds, next_map FROM api_match")
        return self.cur.fetchone()

    def scoreboard(self):
        self.cur.execute("SELECT slot, role_name, connected, frags, health, alive, login FROM api_scoreboard")
        return self.cur.fetchall()

    def close(self):
        self.p.close()


def render_sessions(db_cpus, players):
    """Render sessions per player: the database CPUs shared out, at least one each."""
    return max(1, int(db_cpus) // max(1, int(players)))


def db_cpu_count(game, default=2):
    """The database's cpu_count when this session may read it (the game owner can; a player
    account cannot), else the Oracle Free default."""
    if getattr(game, "api", False):
        return default
    try:
        cur = game.conn.cursor()
        cur.execute("SELECT TO_NUMBER(value) FROM v$parameter WHERE name = 'cpu_count'")
        row = cur.fetchone()
        return int(row[0]) if row and row[0] else default
    except Exception:  # noqa: BLE001
        return default


def decode_rows(rows):
    """(y, pal, hex) rows -> (uint8[200, 320] palette indices, palette number)."""
    frame = np.frombuffer(bytes.fromhex("".join(r[2] for r in sorted(rows, key=lambda r: int(r[0])))),
                          np.uint8).reshape(SCREEN_H, -1)
    return frame, int(rows[0][1] or 0)


# ================================================================================= the render thread
class RenderWorker:
    """Frames on their own session(s), never waiting on the game loop and never waited on by it.

    The game loop calls request() every display frame; the thread renders the newest request.
    Each frame starts with a READ ONLY transaction taken while the game loop is between tics
    (the shared tic lock), so all of the renderer's queries see one committed tic; the alpha
    (time into the next tic) is computed at that same moment from the loop's tic clock. With
    split=True two sessions render the left and right column ranges of the same frame in
    parallel, both pinned to the same tic."""

    def __init__(self, game, clock, split=False, log_frames=False, sprites=1):
        import oradb, game_api
        self.ga = game_api
        self.clock = clock
        self.mp = game.api
        self.cond = threading.Condition()
        self.req = 0
        self.ctx = None              # (map_id, player, skill, generation) or MP (map_id, slot, generation)
        self.result = None           # (frame idx, pal, frame_id, tic, alpha, ms)
        self.frame_id = 0
        self.error = None
        self.stop_flag = False
        self.split = split
        self.sprites = sprites       # single player: the renderer's sprite mode (deathmatch: the match's)
        self.log_frames = log_frames
        self.frame_log = []          # (tic, alpha, frame) when logging
        self.completions = deque(maxlen=512)
        self.ms = deque(maxlen=200000)
        if self.mp:
            import api_client
            self.sessions = [api_client.ApiPlayer(game.user, game.password, game.dsn)]
        else:
            self.sessions = []
            for _ in range(2 if split else 1):
                c = oradb.connect(**game.connect_args)
                cur = c.cursor()
                game_api.setup_session(cur)
                self.sessions.append(c)
        self.split_col = 160
        if split:
            import concurrent.futures
            self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        self.thread = threading.Thread(target=self._run, name="sql-renderer", daemon=True)
        self.thread.start()

    def set_context(self, ctx):
        with self.cond:
            self.ctx = ctx
            self.result = None
            self.cond.notify()

    def request(self):
        with self.cond:
            self.req += 1
            self.cond.notify()

    def poll(self, have_id):
        with self.cond:
            if self.result is None or self.result[2] == have_id:
                return None
            return self.result

    def close(self):
        with self.cond:
            self.stop_flag = True
            self.cond.notify_all()
        self.thread.join(timeout=2)
        for s in self.sessions:
            try:
                (s.close() if self.mp else s.close())
            except Exception:  # noqa: BLE001
                pass

    # -- one frame
    def _begin(self):
        """READ ONLY transaction(s) between two tics; returns (tic, alpha)."""
        with self.clock.lock:
            tic, alpha = self.clock.tic_count, self.clock.alpha()
            for c in self.sessions:
                c.rollback()
                c.cursor().execute("SET TRANSACTION READ ONLY")
        return tic, alpha

    def _sp_half(self, k, ctx, alpha, x0, x1):
        cur = self.sessions[k].cursor()
        cur.arraysize = 256
        cur.prefetchrows = 257
        m, p, sk, _g = ctx
        if x0 is None:
            cur.execute(self.ga.FRAME_AT_SQL, map_id=m, player_id=p, skill=sk, a=float(alpha), sprites=self.sprites)
        else:
            cur.execute(self.ga.FRAME_AT_SPLIT_SQL, map_id=m, player_id=p, skill=sk, a=float(alpha), x0=x0, x1=x1,
                        sprites=self.sprites)
        return cur.fetchall()

    def _render(self, ctx):
        t0 = time.perf_counter()
        if self.mp:
            m, slot, _g = ctx
            p = self.sessions[0]
            with self.clock.lock:
                tic, alpha = self.clock.tic_count, self.clock.alpha()
            p.camera(alpha)                       # api_camera + SET TRANSACTION READ ONLY, one round trip
            rows = p.frame_rows(m, slot)
            p.end_read()
            if len(rows) != 200:
                return None, tic, alpha, (time.perf_counter() - t0) * 1e3
            fr, pal = decode_rows(rows)
            return (fr, pal), tic, alpha, (time.perf_counter() - t0) * 1e3
        tic, alpha = self._begin()
        try:
            if self.split:
                s = self.split_col
                ta0 = time.perf_counter()
                fut = self.pool.submit(lambda: (self._sp_half(1, ctx, alpha, s, 319), time.perf_counter()))
                ra = self._sp_half(0, ctx, alpha, 0, s - 1)
                ta = time.perf_counter() - ta0
                rb, tb_end = fut.result()
                tb = tb_end - ta0
                ra.sort(key=lambda r: int(r[0]))
                rb.sort(key=lambda r: int(r[0]))
                frame = np.frombuffer(bytes.fromhex("".join(a[2] + b[2] for a, b in zip(ra, rb))),
                                      np.uint8).reshape(SCREEN_H, SCREEN_W)
                pal = int(ra[0][1] or 0)
                d = (ta - tb) / max(1e-6, ta + tb)            # balance the halves (load only)
                self.split_col = max(64, min(256, s - 16 * max(-3, min(3, int(round(d * 10))))))
                out = (frame, pal)
            else:
                rows = self._sp_half(0, ctx, alpha, None, None)
                out = decode_rows(rows) if len(rows) == 200 else None
        finally:
            for c in self.sessions:
                c.rollback()
        return out, tic, alpha, (time.perf_counter() - t0) * 1e3

    def _run(self):
        last = 0
        failures = 0
        while True:
            with self.cond:
                self.cond.wait_for(lambda: self.stop_flag or (self.req > last and self.ctx is not None))
                if self.stop_flag:
                    return
                last, ctx = self.req, self.ctx
            try:
                out, tic, alpha, ms = self._render(ctx)
            except Exception as exc:  # noqa: BLE001
                with self.cond:
                    self.error = str(exc).splitlines()[0]
                print(f"[render error] {self.error}", file=sys.stderr, flush=True)
                failures += 1
                time.sleep(min(0.5, 0.05 * failures))
                continue
            failures = 0
            with self.cond:
                if self.ctx != ctx:
                    continue                      # never publish a frame that crossed a stage change
                if out is None:
                    self.error = "no frame (slot or map changed)"
                    continue
                self.frame_id += 1
                self.error = None
                self.result = (out[0], out[1], self.frame_id, tic, alpha, ms)
                now = time.perf_counter()
                self.completions.append(now)
                self.ms.append(ms)
                if self.log_frames:
                    self.frame_log.append((tic, alpha, out[0].copy(), now))


class TicClock:
    """The 35 Hz clock the game loop runs and the render thread reads (under lock)."""

    def __init__(self, tic_seconds):
        self.lock = threading.Lock()
        self.tic_seconds = tic_seconds
        self.tic_count = 0
        self.accumulator = 0.0
        self.stamp = time.perf_counter()
        self.running = False      # is the world ticking (alpha meaningful)

    def alpha(self):
        if not self.running:
            return 1.0
        acc = self.accumulator + (time.perf_counter() - self.stamp)
        return min(1.0, max(0.0, acc / self.tic_seconds))


# ================================================================================= audio
class Audio:
    """pygame's mixer: SQL decides what plays, how loud and where (audio.py)."""

    def __init__(self, game, enabled=True):
        import pygame
        self.pg = pygame
        self.on = enabled and pygame.mixer.get_init() is not None
        self.bank = {}
        self.loops = {}
        self.next_channel = 8
        self.music_name = None
        self.played = 0
        if self.on:
            pygame.mixer.set_num_channels(24)
            pygame.mixer.set_reserved(8)
            for name, wav in game.sound_assets():
                try:
                    self.bank[name] = pygame.mixer.Sound(file=io.BytesIO(wav))
                except Exception:  # noqa: BLE001
                    pass

    def events(self, events):
        for _id, name, volume, pan in events:
            self.played += 1
            snd = self.bank.get(name)
            volume = max(0.0, min(1.0, float(volume)))
            if not self.on or snd is None or volume <= 0.0:
                continue
            pan = max(-1.0, min(1.0, float(pan)))
            ch = self.pg.mixer.Channel(self.next_channel)
            self.next_channel = 8 + ((self.next_channel - 7) % 16)
            ch.set_volume(volume * min(1.0, 1.0 - pan), volume * min(1.0, 1.0 + pan))
            ch.play(snd)

    def sync_loops(self, loops):
        if not self.on:
            return
        wanted = {k: (n, float(v), float(p)) for k, n, v, p in loops}
        for k in list(self.loops):
            if k not in wanted:
                self.loops.pop(k)[0].stop()
        used = {e[0] for e in self.loops.values()}
        free = [self.pg.mixer.Channel(i) for i in range(8) if self.pg.mixer.Channel(i) not in used]
        for k, (name, volume, pan) in wanted.items():
            snd = self.bank.get(name)
            if snd is None:
                continue
            entry = self.loops.get(k)
            if entry is None:
                if not free:
                    continue
                ch = free.pop(0)
                self.loops[k] = (ch, name)
                ch.play(snd, loops=-1)
            else:
                ch, prev = entry
                if prev != name:
                    ch.play(snd, loops=-1)
                    self.loops[k] = (ch, name)
            volume, pan = max(0.0, min(1.0, volume)), max(-1.0, min(1.0, pan))
            ch.set_volume(volume * min(1.0, 1.0 - pan), volume * min(1.0, 1.0 + pan))

    def stop_loops(self):
        for ch, _n in self.loops.values():
            ch.stop()
        self.loops.clear()

    def music(self, row):
        """Start a stage track: (name, midi, audio, format) from stage_music.sql."""
        self.music_name = None if row is None else row[0]
        if not self.on:
            return
        self.pg.mixer.music.stop()
        if row is None:
            return
        name, midi, audio, fmt = row
        try:
            if audio:
                self.pg.mixer.music.load(io.BytesIO(audio), fmt or "ogg")
            else:
                self.pg.mixer.music.load(io.BytesIO(midi), "mid")
            self.pg.mixer.music.set_volume(0.55)
            self.pg.mixer.music.play(-1)
        except Exception as exc:  # noqa: BLE001
            print(f"Music decoder unavailable: {exc}")


# ================================================================================= scripted input (tests)
class Script:
    """--script FILE: timed key events injected into pygame's queue, for unattended runs.
    JSON list of steps {"t": seconds since start, "key": "w", "down": true/false} or
    {"t": .., "press": "return"} or {"t": .., "type": "iddqd"} or {"t": .., "quit": true}, and for tests
    {"t": .., "op": {...}}: a scenario op (tests/scenario_lib.py, e.g. place the player) applied to the
    single-player world -- test setup, like the scenario recorders' ops."""

    def __init__(self, path, pygame):
        self.pg = pygame
        self.steps = sorted(json.loads(Path(path).read_text()), key=lambda s: s["t"])
        self.i = 0
        self.t0 = time.perf_counter()
        self.held = set()

    def key(self, name):
        name = {"return": "RETURN", "escape": "ESCAPE", "space": "SPACE", "tab": "TAB", "up": "UP",
                "down": "DOWN", "left": "LEFT", "right": "RIGHT", "lctrl": "LCTRL", "lshift": "LSHIFT",
                "f9": "F9", "f10": "F10", "home": "HOME", "equals": "EQUALS", "minus": "MINUS"}.get(name, name)
        return getattr(self.pg, "K_" + name)

    def pump(self, op=None):
        pg, now = self.pg, time.perf_counter() - self.t0
        while self.i < len(self.steps) and self.steps[self.i]["t"] <= now:
            s = self.steps[self.i]
            self.i += 1
            if "op" in s and op is not None:
                op(s["op"])
            elif s.get("quit"):
                pg.event.post(pg.event.Event(pg.QUIT))
            elif "press" in s:
                k = self.key(s["press"])
                pg.event.post(pg.event.Event(pg.KEYDOWN, key=k, mod=0, unicode="", scancode=0))
                pg.event.post(pg.event.Event(pg.KEYUP, key=k, mod=0, unicode="", scancode=0))
            elif "type" in s:
                for ch in s["type"]:
                    k = self.key(ch)
                    pg.event.post(pg.event.Event(pg.KEYDOWN, key=k, mod=0, unicode=ch, scancode=0))
                    pg.event.post(pg.event.Event(pg.KEYUP, key=k, mod=0, unicode=ch, scancode=0))
            elif "key" in s:
                k = self.key(s["key"])
                (self.held.add if s.get("down", True) else self.held.discard)(k)
            elif "wheel" in s:
                pg.event.post(pg.event.Event(pg.MOUSEWHEEL, x=0, y=int(s["wheel"]), flipped=False))
        return self.i >= len(self.steps)

    def pressed(self, keys):
        """pygame.key.get_pressed() with the script's held keys."""
        held = self.held

        class K:
            def __getitem__(_, k):
                return k in held or bool(keys[k])
        return K()


# ================================================================================= the client
MENU_KEYS_NAMES = {"UP": "up", "DOWN": "down", "w": "up", "s": "down", "RETURN": "enter", "KP_ENTER": "enter",
                   "SPACE": "enter", "ESCAPE": "escape"}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--warp", help="start in this level (e.g. E1M1) instead of the title screen")
    ap.add_argument("--skill", type=int, default=2, help="0-4 (default 2, Hurt Me Plenty)")
    ap.add_argument("--join", metavar="USER", help="deathmatch: join the referee's match as this player account")
    ap.add_argument("--password", default=os.getenv("DOOM_PLAYER_PASSWORD"), help="the player account's password")
    ap.add_argument("--dsn", default=None, help="Oracle DSN (default DOOM_ORA_DSN or localhost:1521/FREEPDB1)")
    ap.add_argument("--split", dest="split", action="store_true", default=None,
                    help="force split rendering: each frame on two sessions (column ranges)")
    ap.add_argument("--no-split", dest="split", action="store_false",
                    help="force one render session (default: max(1, database CPUs // players))")
    ap.add_argument("--db-cpus", type=int, default=int(os.getenv("DOOM_DB_CPUS", "0")),
                    help="database CPUs for the render-session rule (default: cpu_count when readable, "
                         "else 2, Oracle Free)")
    ap.add_argument("--scale", type=int, default=int(os.getenv("WINDOW_SCALE", "0")), help="window scale (0: fit)")
    ap.add_argument("--fps-cap", type=int, default=120, help="display loop cap")
    ap.add_argument("--max-fps", type=float, default=0, help="cap on frame requests per second (0: as fast as answered)")
    ap.add_argument("--no-sound", action="store_true")
    ap.add_argument("--no-music", action="store_true")
    ap.add_argument("--cedar-exact", action="store_true",
                    help="single player: render sprites exactly as the CedarDB reference (depth-tested against "
                         "floors and ceilings, so items sink into the floor) instead of Doom's sprite clipping "
                         "(default); deathmatch frames use the match's setting (referee SPRITE_MODE)")
    ap.add_argument("--mouse-sensitivity", type=float, default=float(os.getenv("MOUSE_SENSITIVITY", "0.15")))
    # unattended / test runs
    ap.add_argument("--headless", action="store_true", help="SDL dummy video and audio drivers")
    ap.add_argument("--script", help="JSON file of timed key events (see Script)")
    ap.add_argument("--commands", help="JSON command stream (TPC-DOOM format): tic N uses command N")
    ap.add_argument("--cheats", default="", help="with --warp: doom_game.cheat codes at the level start "
                                                   "(as the CedarDB recorders), e.g. IDDQD,IDKFA")
    ap.add_argument("--tics", type=int, default=0, help="quit after this many game tics")
    ap.add_argument("--seconds", type=float, default=0, help="quit after this many seconds")
    ap.add_argument("--log", help="write a JSON log (tics: snapshot, pose, events; frames; timings)")
    ap.add_argument("--log-frames", help="with --log: save every displayed 3-D frame (tic, alpha, indices) "
                                         "to this .npz")
    a = ap.parse_args(argv)

    if a.headless:
        os.environ["SDL_VIDEODRIVER"] = "dummy"
        os.environ["SDL_AUDIODRIVER"] = "dummy"
    os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
    import pygame

    joining = bool(a.join)
    if joining and not a.password:
        import getpass
        a.password = getpass.getpass(f"password for {a.join}: ")
    game = MPGame(a.join, a.password, a.dsn) if joining else SPGame(a.dsn)
    consts = game.constants()
    tic_seconds = 1.0 / consts.get("TICRATE", 35.0)
    turn_per_tic = consts.get("TURN_DEGREES_PER_TIC", 3.2)
    lut = game.palettes()
    stages = game.stages()
    commands = None
    if a.commands:
        commands = [c["command"] for c in json.loads(Path(a.commands).read_text())]

    pygame.mixer.pre_init(frequency=44100, size=-16, channels=2, buffer=512)
    pygame.init()
    audio = Audio(game, enabled=not a.no_sound)
    if a.scale:
        scale = a.scale
    else:
        try:
            dw, dh = pygame.display.get_desktop_sizes()[0]
        except Exception:  # noqa: BLE001
            dw, dh = 0, 0
        scale = max(1, min(int(dw * 0.96) // SCREEN_W, int(dh * 0.92) // SCREEN_H)) if dw >= 640 else 3

    def open_window(s):
        return pygame.display.set_mode((SCREEN_W * s, SCREEN_H * s))

    window = open_window(scale)
    font = pygame.font.Font(None, 24)
    hud_font = pygame.font.Font(None, max(18, min(36, window.get_height() // 55)))
    script = Script(a.script, pygame) if a.script else None

    def capture(on):
        if a.headless:
            return on
        pygame.event.set_grab(on)
        pygame.mouse.set_visible(not on)
        pygame.mouse.get_rel()
        return on

    # ---------------------------------------------------------------- the stage
    stage_index = 0
    if a.warp:
        stage_index = next((i for i, s in enumerate(stages) if s["label"].upper() == a.warp.upper()), None)
        if stage_index is None:
            raise SystemExit(f"no map {a.warp}; loaded: {', '.join(s['label'] for s in stages)}")
    elif os.getenv("MAP_ID"):
        stage_index = next((i for i, s in enumerate(stages) if s["map_id"] == int(os.getenv("MAP_ID"))), 0)
    stage = stages[stage_index]
    map_id, player = stage["map_id"], stage["player_thing_id"]
    skill = a.skill
    clock = TicClock(tic_seconds)
    started = time.perf_counter()
    if a.split is None:
        cpus = a.db_cpus or db_cpu_count(game)
        a.split = render_sessions(cpus, 1) >= 2 and not joining
    elif a.split and joining:
        # deathmatch frames come from the per-slot frame views, one session per player: two
        # sessions could not be pinned to one referee tic (the referee commits on its own clock)
        print("[render] --split applies to single player; deathmatch renders one session per player")
        a.split = False
    log = {"tics": [], "flow": [], "screens": {}, "mode": "mp" if joining else "sp", "split": a.split}

    def note(what, **kw):
        log["flow"].append(dict(t=round(time.perf_counter() - started, 3), what=what, **kw))

    # session state (GameSession)
    sess = {"x": 0.0, "y": 0.0, "z": 0.0, "angle": 0.0, "alive": True, "mouse_turn": 0.0, "use": False,
            "weapon": None, "event": 0}
    slot = None
    if joining:
        print(f"[join] signing in as {a.join}; waiting for a slot ...", flush=True)
        announced = False
        while True:
            pid = game.join()
            if pid >= 0:
                break
            if not announced:
                print("[join] all slots taken or the match is between maps; queued", flush=True)
                announced = True
            time.sleep(0.5)
        map_id, slot = game.where()
        player = pid
        stage = next((s for s in stages if s["map_id"] == map_id), {"label": f"map {map_id}"})
        pose = game.player_pose()
        if pose:
            sess["x"], sess["y"], sess["angle"], sess["z"], sess["alive"] = pose
        sess["event"] = game.events_max()
        if not a.no_music:
            audio.music(game.stage_music())
        menu_screen = None
        print(f"[join] {a.join}: slot {slot} on {stage['label']} (thing {player})", flush=True)
    else:
        if a.warp:
            cheats = [c.strip().upper() for c in a.cheats.split(",") if c.strip()]
            x, y, ang, z = game.level_start_like_recorder(map_id, player, skill, cheats)
            menu_screen = None
        else:
            x, y, ang, z = game.enter_level(map_id, player, skill)
            game.set_screen("title")
            menu_screen = "title"
        sess.update(x=x, y=y, angle=ang, z=z, alive=True)
        if not a.no_music and not menu_screen:
            audio.music(game.stage_music(map_id))
    menu_state = {"screen": "game", "cursor": 0, "episode": 1, "skill": 2} if (joining or a.warp) \
        else game.screen_state()

    renderer = RenderWorker(game, clock, split=a.split, log_frames=bool(a.log_frames),
                            sprites=0 if a.cedar_exact else 1)   # game_api.SPRITES_EXACT / _VANILLA
    generation = [0]

    def render_context():
        generation[0] += 1
        renderer.set_context((map_id, slot, generation[0]) if joining else (map_id, player, skill, generation[0]))

    render_context()
    mouse_captured = capture(not menu_screen)
    automap_on = False
    attract_on = not joining and not a.warp and not commands
    if attract_on:
        game.attract_start()
    attract_acc = 0.0
    demo_active = False
    demo_recording = None
    inter_active = False
    inter_acc = 0.0
    inter_next = None
    inter_figures = (0,) * 6
    finale_active = False
    finale_acc = 0.0
    deferred_exit = None
    tic_failures = 0
    hud = True
    surface = None
    frame_id = 0
    tic_ms = deque(maxlen=256)
    tic_starts = []
    level_tics = 0           # tics since the level start (index into --commands)
    total_tics = 0
    last_match_check = 0.0
    pygame_clock = pygame.time.Clock()
    caption = (f"SQL Doom on Oracle - {stage['label']}" + (f" - {a.join} slot {slot}" if joining else "")
               + " - LMB/Ctrl fire, Space use, Tab map, Esc menu")
    pygame.display.set_caption(caption)

    def show_indices(idx, pal):
        rgb = lut[pal][idx]
        surf = pygame.image.frombuffer(rgb.tobytes(), (idx.shape[1], idx.shape[0]), "RGB")
        return pygame.transform.scale(surf, window.get_size())

    def restart(new_index=None, carry=None):
        nonlocal stage_index, stage, map_id, player, level_tics, inter_active, inter_next, surface
        if new_index is not None:
            stage_index = new_index
            stage = stages[stage_index]
            map_id, player = stage["map_id"], stage["player_thing_id"]
            inter_active, inter_next = False, None
        audio.stop_loops()
        with clock.lock:
            x, y, ang, z = game.enter_level(map_id, player, skill, carry)
            clock.accumulator = 0.0
            clock.stamp = time.perf_counter()
        sess.update(x=x, y=y, angle=ang, z=z, alive=True, mouse_turn=0.0, use=False, weapon=None, event=0)
        level_tics = 0
        surface = None
        if not a.no_music:
            audio.music(game.stage_music(map_id))
        note("enter", map=stage["label"], skill=skill, carry=bool(carry), music=audio.music_name)
        render_context()
        pygame.display.set_caption(f"SQL Doom on Oracle - {stage['label']} - LMB/Ctrl fire, Space use, Tab map, "
                                   "Esc menu, F9 record, F10 play")

    def test_op(op):
        sys.path.insert(0, str(HERE.parent / "tests"))
        import scenario_lib
        with clock.lock:
            scenario_lib.OracleSide(game.cur, map_id, player).apply_op(op)
        print(f"[script] op {op}", flush=True)

    def stage_by_label(prefix):
        return next((i for i, s in enumerate(stages) if s["label"].startswith(prefix)), None)

    running = True
    while running:
        dt = min(pygame_clock.tick(a.fps_cap if (menu_screen is None and not inter_active and not finale_active
                                                  and not automap_on) else 35) / 1000.0, 0.1)
        now = time.perf_counter()
        if a.seconds and now - started >= a.seconds:
            break
        if script is not None:
            script.pump(None if joining else test_op)
        stage_to = None
        carry = None
        respawn = False
        mouse_dx = 0

        # ---------------------------------------------------- the level flow (single player)
        if deferred_exit is not None and not inter_active:
            inter_next = game.level_exit(map_id, player, deferred_exit)
            note("level_exit", map=stage["label"], secret=bool(deferred_exit), next=inter_next)
            inter_active, inter_acc, inter_figures = True, 0.0, (0,) * 6
            deferred_exit = None
            clock.running = False
        if inter_active:
            inter_acc += dt
            while inter_acc >= tic_seconds:
                inter_acc -= tic_seconds
                st, inter_figures = game.intermission_tic()
                if st == "done":
                    inter_active = False
                    outcome = game.after_intermission(map_id)
                    note("intermission_done", figures=list(inter_figures), outcome=outcome)
                    if outcome == "finale":
                        finale_active, finale_acc = True, 0.0
                        break
                    nxt = int(outcome.split(":", 1)[1])
                    stage_to = next((i for i, s in enumerate(stages) if s["map_id"] == nxt),
                                    (stage_index + 1) % len(stages))
                    carry = (map_id, player)
                    break
            mouse_captured = capture(False)
            audio.stop_loops()
        if finale_active:
            finale_acc += dt
            while finale_acc >= tic_seconds:
                finale_acc -= tic_seconds
                if game.finale_tic() == "done":
                    finale_active = False
                    break
            mouse_captured = capture(False)
            audio.stop_loops()

        # ---------------------------------------------------- events
        for ev in pygame.event.get():
            if ev.type == pygame.QUIT:
                running = False
            elif ev.type == pygame.KEYDOWN:
                key = ev.key
                if joining and key in (pygame.K_ESCAPE, pygame.K_F9, pygame.K_F10):
                    continue                        # menus, saves and demos are single-player
                if attract_on:
                    attract_on = False
                    game.attract_stop()
                    if demo_active:
                        demo_active = False
                        menu_screen = "title"
                        menu_state = game.screen_state()
                        clock.running = False
                        continue
                if (menu_screen is None and not inter_active and not finale_active and not joining
                        and (pygame.K_a <= key <= pygame.K_z or pygame.K_0 <= key <= pygame.K_9)):
                    action = game.cheat_key(map_id, player, chr(key))
                    if action != "none":
                        note("cheat", action=action)
                    if action.startswith("warp:"):
                        tgt = action[5:]
                        ch = stage_by_label(tgt)
                        print(f"[cheat] {tgt} is not loaded" if ch is None else f"[cheat] warping to {tgt}")
                        if ch is not None:
                            stage_to = ch
                    elif action.startswith("music:"):
                        tgt = stage_by_label(action[6:])
                        if tgt is not None and not a.no_music:
                            audio.music(game.stage_music(stages[tgt]["map_id"]))
                            print("[cheat] Music Change")
                    elif action == "iddt":
                        if automap_on:
                            game.automap("toggle", map_id, player, "cheat")
                    elif action.startswith("msg:"):
                        print(f"[cheat] {action[4:]}")
                if finale_active:
                    if game.finale_advance() == "done":
                        finale_active = False
                        menu_screen = "title"
                        menu_state = game.screen_state()
                    continue
                if menu_screen is not None:
                    kname = MENU_KEYS_NAMES.get(pygame.key.name(key).upper() if pygame.key.name(key) in
                                                ("up", "down", "return", "space", "escape", "enter")
                                                else pygame.key.name(key))
                    kname = {pygame.K_UP: "up", pygame.K_DOWN: "down", pygame.K_w: "up", pygame.K_s: "down",
                             pygame.K_RETURN: "enter", pygame.K_KP_ENTER: "enter", pygame.K_SPACE: "enter",
                             pygame.K_ESCAPE: "escape"}.get(key)
                    if kname is None:
                        continue
                    action, menu = game.menu_input(kname)
                    menu_state = menu
                    note("menu", key=kname, action=action, screen=menu["screen"], cursor=menu["cursor"])
                    was_open = menu_screen is not None
                    menu_screen = None if menu["screen"] == "game" else menu["screen"]
                    if was_open and menu_screen is None:
                        mouse_captured = capture(True)
                        sess["mouse_turn"] = 0.0
                        clock.stamp = time.perf_counter()
                    if action == "quit":
                        running = False
                    elif action.startswith("load:"):
                        restored = game.load_game(int(action.split(":", 1)[1]))
                        if restored is None:
                            game.set_screen("load")
                            menu_screen = "load"
                            menu_state = game.screen_state()
                        else:
                            skill = restored["skill"]
                            ch = next((i for i, s in enumerate(stages) if s["map_id"] == restored["map_id"]), None)
                            if ch is not None:
                                stage_index, stage = ch, stages[ch]
                                map_id, player = stage["map_id"], stage["player_thing_id"]
                            pose = game.player_pose(map_id, player)
                            if pose:
                                sess["x"], sess["y"], sess["angle"], sess["z"], sess["alive"] = pose
                            sess.update(mouse_turn=0.0, use=False, weapon=None, event=0)
                            level_tics = 0
                            surface = None
                            mouse_captured = capture(True)
                            render_context()
                            if not a.no_music:
                                audio.music(game.stage_music(map_id))
                    elif action.startswith("save:"):
                        game.save_game(int(action.split(":", 1)[1]), map_id, player, skill, stage["label"])
                        mouse_captured = capture(True)
                    elif action == "start":
                        tgt = stage_by_label(f"E{menu['episode']}M1")
                        skill = menu["skill"]
                        stage_to = tgt if tgt is not None else stage_index
                    continue
                if inter_active:
                    if key in (pygame.K_RETURN, pygame.K_KP_ENTER, pygame.K_SPACE, pygame.K_ESCAPE):
                        game.intermission_accelerate()
                    continue
                if key == pygame.K_F6:
                    hud = not hud
                    continue
                if not sess["alive"]:
                    if key == pygame.K_SPACE:
                        respawn = not joining
                        continue
                    if key not in (pygame.K_TAB, pygame.K_ESCAPE):
                        continue
                if automap_on:
                    if key in (pygame.K_ESCAPE, pygame.K_TAB):
                        automap_on = False
                        mouse_captured = capture(True)
                    elif key == pygame.K_f:
                        game.automap("toggle", map_id, player, "follow")
                    elif key == pygame.K_g:
                        game.automap("toggle", map_id, player, "grid")
                    elif key == pygame.K_HOME:
                        game.automap("fit", map_id, player)
                    elif key in (pygame.K_MINUS, pygame.K_KP_MINUS, pygame.K_LEFTBRACKET):
                        game.automap("zoom", map_id, player, 1 / 1.25)
                    elif key in (pygame.K_EQUALS, pygame.K_KP_PLUS, pygame.K_RIGHTBRACKET):
                        game.automap("zoom", map_id, player, 1.25)
                    continue
                if key == pygame.K_ESCAPE:
                    game.set_screen("main")
                    menu_screen = "main"
                    menu_state = game.screen_state()
                    mouse_captured = capture(False)
                elif key == pygame.K_TAB:
                    automap_on = True
                    note("automap")
                    mouse_captured = capture(False)
                elif key == pygame.K_BACKQUOTE:
                    mouse_captured = capture(not mouse_captured)
                elif key == pygame.K_F5:
                    print(f"[pose] map={map_id} player={player} skill={skill}\n    x={sess['x']:.4f} "
                          f"y={sess['y']:.4f} z={sess['z']:.4f} angle={sess['angle']:.4f}", file=sys.stderr, flush=True)
                elif key == pygame.K_r:
                    renderer.request()
                elif key == pygame.K_F9:
                    if demo_recording is not None:
                        print(f"[demo] recorded '{demo_recording}' on {stage['label']}")
                        note("demo_stop")
                        game.demo_stop()
                        demo_recording = None
                    else:
                        demo_recording = f"{stage['label'].lower()}-demo"
                        game.demo_begin(demo_recording, map_id, player, skill)
                        stage_to = stage_index
                        print(f"[demo] recording '{demo_recording}' from the start of {stage['label']} -- F9 "
                              "again to stop")
                        note("demo_record", name=demo_recording)
                elif key == pygame.K_F10:
                    if attract_on:
                        attract_on = False
                        game.attract_stop()
                    if demo_active:
                        print("[demo] playback stopped")
                        game.demo_stop()
                        demo_active = False
                    else:
                        demo_recording = None
                        header = game.demo_play(f"{stage['label'].lower()}-demo")
                        if header is None:
                            print(f"[demo] nothing recorded for {stage['label']} yet -- F9 records")
                        else:
                            demo_active = True
                            skill = header["skill"]
                            stage_to = stage_index
                            print(f"[demo] playing back {header['tic_count']} tics of {stage['label']}")
                            note("demo_play", tics=header["tic_count"])
                elif key == pygame.K_SPACE:
                    sess["use"] = True
                elif pygame.K_1 <= key <= pygame.K_7:
                    sess["weapon"] = game.weapon_slot(map_id, player, key - pygame.K_0)
                elif key in (pygame.K_MINUS, pygame.K_KP_MINUS, pygame.K_LEFTBRACKET):
                    scale = max(1, scale - 1)
                    window = open_window(scale)
                elif key in (pygame.K_EQUALS, pygame.K_KP_PLUS, pygame.K_RIGHTBRACKET):
                    scale += 1
                    window = open_window(scale)
            elif ev.type == pygame.MOUSEWHEEL and automap_on:
                if ev.y:
                    game.automap("zoom", map_id, player, 1.15 ** ev.y)
            elif (ev.type == pygame.MOUSEWHEEL and ev.y and not automap_on and menu_screen is None
                  and not inter_active and not finale_active):
                picked = game.weapon_cycle(map_id, player, 1 if ev.y > 0 else -1)
                if picked is not None:
                    sess["weapon"] = picked
            elif ev.type == pygame.MOUSEMOTION and mouse_captured and not automap_on:
                mouse_dx += ev.rel[0]
            elif ev.type == pygame.MOUSEBUTTONDOWN:
                if inter_active and ev.button == 1:
                    game.intermission_accelerate()
                elif not mouse_captured and not automap_on and menu_screen is None:
                    mouse_captured = capture(True)
            elif ev.type == pygame.WINDOWFOCUSLOST and mouse_captured:
                mouse_captured = capture(False)

        # ---------------------------------------------------- the attract loop
        if attract_on and not demo_active and menu_screen is not None:
            attract_acc += dt
            while attract_acc >= tic_seconds:
                attract_acc -= tic_seconds
                outcome = game.attract_tic()
                if outcome == "none":
                    continue
                if outcome == "page":
                    menu_state = game.screen_state()
                    menu_screen = menu_state["screen"]
                    continue
                header = game.demo_header(int(outcome.split(":", 1)[1]))
                ch = next((i for i, s in enumerate(stages) if header and s["map_id"] == header["map_id"]), None)
                if ch is None:
                    game.demo_stop()
                    continue
                print(f"[attract] playing '{header['name']}' on {stages[ch]['label']}")
                note("attract_demo", name=header["name"])
                skill = header["skill"]
                stage_to = ch
                demo_active = True
                menu_screen = None
                break

        if stage_to is not None or respawn:
            restart(stage_to, carry)
            mouse_captured = capture(True)

        # ---------------------------------------------------- deathmatch: where is the match
        if joining and now - last_match_check > 1.0:
            last_match_check = now
            try:
                m = game.match()
                if m and m[0] == "playing" and int(m[1]) != map_id:
                    map_id, slot = game.where()
                    audio.stop_loops()
                    if not a.no_music:
                        audio.music(game.stage_music())
                    sess["event"] = game.events_max()
                    render_context()
                    print(f"[match] now on {m[2]}, slot {slot}", flush=True)
                inter_active_mp = bool(m and m[0] == "intermission")
                if inter_active_mp:
                    pygame.display.set_caption(f"SQL Doom on Oracle - {m[2]} complete - {m[4]} in {m[3]} s")
            except Exception as exc:  # noqa: BLE001
                print(f"[match] {exc}")

        keys = pygame.key.get_pressed()
        if script is not None:
            keys = script.pressed(keys)
        if automap_on:
            px = (1 if keys[pygame.K_d] or keys[pygame.K_RIGHT] else 0) - (1 if keys[pygame.K_a] or keys[pygame.K_LEFT] else 0)
            py = (1 if keys[pygame.K_w] or keys[pygame.K_UP] else 0) - (1 if keys[pygame.K_s] or keys[pygame.K_DOWN] else 0)
            if px or py:
                ln = math.hypot(px, py)
                game.automap("pan", map_id, player, px / ln * AUTOMAP_PAN_SPEED * dt, py / ln * AUTOMAP_PAN_SPEED * dt)

        # ---------------------------------------------------- the 35 Hz tic
        world_running = not automap_on and not inter_active and menu_screen is None and not finale_active
        if joining:
            world_running = not inter_active       # the server's world keeps running under the automap
        clock.running = world_running
        controls = world_running and sess["alive"] and not automap_on
        run = controls and (keys[pygame.K_LSHIFT] or keys[pygame.K_RSHIFT])
        attack = controls and (keys[pygame.K_LCTRL] or keys[pygame.K_RCTRL]
                               or (mouse_captured and pygame.mouse.get_pressed(num_buttons=3)[0]))
        if joining and world_running and not sess["alive"]:
            attack = bool(keys[pygame.K_LCTRL] or keys[pygame.K_RCTRL] or keys[pygame.K_SPACE]
                          or (mouse_captured and pygame.mouse.get_pressed(num_buttons=3)[0]))
        turn_in = controls * ((1.0 if (keys[pygame.K_e] or keys[pygame.K_RIGHT]) else 0.0)
                              - (1.0 if (keys[pygame.K_q] or keys[pygame.K_LEFT]) else 0.0))
        if controls:
            sess["mouse_turn"] += mouse_dx * a.mouse_sensitivity
        else:
            sess["mouse_turn"] = 0.0
        fwd = controls * ((1.0 if (keys[pygame.K_w] or keys[pygame.K_UP]) else 0.0)
                          - (1.0 if (keys[pygame.K_s] or keys[pygame.K_DOWN]) else 0.0))
        strafe = controls * ((1.0 if keys[pygame.K_d] else 0.0) - (1.0 if keys[pygame.K_a] else 0.0))

        with clock.lock:
            clock.accumulator += (now - clock.stamp) if world_running else 0.0
            clock.stamp = now
        ntics = 0
        while clock.accumulator >= tic_seconds and ntics < MAX_TICS_PER_FRAME:
            ntics += 1
            turn = turn_in * turn_per_tic + sess["mouse_turn"]
            sess["mouse_turn"] = 0.0
            command = (skill, float(fwd), float(strafe), bool(run), float(turn), bool(attack), sess["weapon"],
                       bool(sess["use"]))
            if commands is not None:
                if level_tics >= len(commands):
                    running = False
                    break
                command = tuple(commands[level_tics])
            sess["weapon"], sess["use"] = None, False
            t0 = time.perf_counter()
            try:
                with clock.lock:
                    snap, events, loops = game.tic(map_id, player, command, sess["event"])
                    clock.accumulator -= tic_seconds
                    clock.tic_count += 1
                tic_failures = 0
            except Exception as exc:  # noqa: BLE001
                try:
                    game.conn.rollback() if hasattr(game, "conn") else game.p.conn.rollback()
                except Exception:  # noqa: BLE001
                    pass
                with clock.lock:
                    clock.accumulator -= tic_seconds
                tic_failures += 1
                print(f"dropped a game tic: {exc.__class__.__name__}: {str(exc).splitlines()[0]}")
                log["tics"].append({"tic": level_tics + 1, "error": str(exc).splitlines()[0]})
                level_tics += 1
                total_tics += 1
                if tic_failures >= 30:
                    raise
                break
            t1 = time.perf_counter()
            tic_ms.append((t1 - t0) * 1e3)
            tic_starts.append(t0 - started)
            level_tics += 1
            total_tics += 1
            if events:
                sess["event"] = max(int(e[0]) for e in events)
                audio.events(events)
            if loops is not None:
                audio.sync_loops(loops)
            if snap is None:
                continue
            sess["x"], sess["y"], sess["z"], sess["angle"] = snap["x"], snap["y"], snap["z"], snap["angle"]
            sess["alive"] = snap["alive"]
            if a.log:
                log["tics"].append({"tic": level_tics, "map_id": map_id, "t": round(t0 - started, 5),
                                    "ms": round((t1 - t0) * 1e3, 3), "command": list(command), "snapshot": snap,
                                    "events": [[e[1], float(e[2]), float(e[3])] for e in (events or [])],
                                    "loops": [list(map(str, lp[:2])) for lp in (loops or [])]})
            if demo_active and not snap["demo_active"]:
                print("[demo] finished")
                note("demo_finished")
                demo_active = False
                if attract_on:
                    menu_screen = "title"
                    menu_state = game.screen_state()
            if snap["use_locked"]:
                print(f"Door requires the {snap['required_key']} key")
            if not joining:
                if snap["use_exit"]:
                    deferred_exit = snap["use_secret_exit"]
                elif snap["cross_exit"]:
                    deferred_exit = snap["cross_secret_exit"]
                elif snap["sector_exit"] or snap["boss_exit"]:
                    deferred_exit = False
                if deferred_exit is not None:
                    reason = ("use" if snap["use_exit"] else "crossed line" if snap["cross_exit"] else
                              "boss floor" if snap["sector_exit"] else "last boss died")
                    print(f"[exit] {stage['label']} finished via {reason} -- health "
                          f"{game.player_health(map_id, player)} secret={deferred_exit}")
                    with clock.lock:
                        clock.accumulator = 0.0
                    break
            if a.tics and total_tics >= a.tics:
                running = False
                break
        if ntics == MAX_TICS_PER_FRAME:
            with clock.lock:
                clock.accumulator = min(clock.accumulator, tic_seconds)

        # ---------------------------------------------------- frames
        in_3d = menu_screen is None and not inter_active and not finale_active and not automap_on
        if in_3d:
            if not a.max_fps or not renderer.completions or now - renderer.completions[-1] >= 1.0 / a.max_fps:
                renderer.request()
            got = renderer.poll(frame_id)
            if got is not None:
                idx, pal, frame_id = got[0], got[1], got[2]
                surface = show_indices(idx, pal)
            if surface is not None:
                window.blit(surface, (0, 0))
            else:
                window.fill((0, 0, 0))
        else:
            # a full-screen SQL composite: one SELECT per displayed frame (35 Hz while one is up)
            fr = None
            try:
                if automap_on:
                    fr = game.render_automap(map_id, player)
                    fr = None if fr is None else (fr[0] if isinstance(fr, tuple) else fr)
                else:
                    if menu_screen is not None and menu_state.get("screen") != menu_screen:
                        menu_state = game.screen_state()
                    fr = game.render_screen(int(now * 35) // 8 * 8)
                    fr = None if fr is None else fr[0]
            except Exception as exc:  # noqa: BLE001
                print(f"[screen] {str(exc).splitlines()[0]}")
            if fr is not None:
                window.blit(show_indices(fr, 0), (0, 0))
                kind = ("automap" if automap_on else "intermission" if inter_active else "finale" if finale_active
                        else (menu_screen or "screen"))
                log["screens"][kind] = log["screens"].get(kind, 0) + 1
        if hud and in_3d:
            t = time.perf_counter()
            while renderer.completions and renderer.completions[0] < t - 1.0:
                renderer.completions.popleft()
            label = f"{len(renderer.completions):.0f} SQL fps"
            if tic_ms:
                label += f"   {tic_ms[-1]:.1f} ms tic"
            if a.split:
                label += "   split"
            img = hud_font.render(label, True, (235, 178, 58))
            shadow = hud_font.render(label, True, (0, 0, 0))
            x = window.get_width() - img.get_width() - 8
            window.blit(shadow, (x + 1, 9))
            window.blit(img, (x, 8))
        if renderer.error and in_3d:
            window.blit(font.render(f"Render error: {renderer.error}", True, (255, 96, 96)), (8, 8))
        pygame.display.flip()

    # ------------------------------------------------------------------- shutdown + log
    elapsed = time.perf_counter() - started
    renderer.close()
    if pygame.mixer.get_init() is not None:
        pygame.mixer.music.stop()
    pygame.quit()
    if a.log:
        fl = renderer.frame_log
        log["summary"] = summarize(tic_starts, list(tic_ms), [f[3] - started for f in fl] if fl else
                                   None, renderer, elapsed, total_tics, audio)
        log["summary"]["sprites"] = "match" if joining else ("cedar-exact" if a.cedar_exact else "vanilla")
        Path(a.log).write_text(json.dumps(log))
        if a.log_frames:
            np.savez_compressed(a.log_frames, tic=np.array([f[0] for f in fl], np.int32),
                                alpha=np.array([f[1] for f in fl], np.float64),
                                t=np.array([f[3] - started for f in fl], np.float64),
                                frames=np.stack([f[2] for f in fl]) if fl else np.zeros((0, 200, 320), np.uint8))
        print(json.dumps(log["summary"]))
    game.close()


def summarize(tic_starts, tic_ms, frame_times, renderer, elapsed, total_tics, audio):
    s = {"seconds": round(elapsed, 2), "tics": total_tics, "sound_events_played": audio.played}
    if len(tic_starts) > 40:
        iv = np.diff(np.array(tic_starts[20:])) * 1e3
        s["tic_rate_hz"] = round((len(tic_starts) - 21) / (tic_starts[-1] - tic_starts[20]), 2)
        s["tic_interval_ms"] = {"mean": round(float(iv.mean()), 2), "p50": round(float(np.percentile(iv, 50)), 2),
                                "p95": round(float(np.percentile(iv, 95)), 2), "max": round(float(iv.max()), 2),
                                "std": round(float(iv.std()), 2)}
        tm = np.array(tic_ms[20:]) if len(tic_ms) > 20 else np.array(tic_ms)
        s["tic_call_ms"] = {"mean": round(float(tm.mean()), 2), "p95": round(float(np.percentile(tm, 95)), 2)}
    ms = np.array(renderer.ms) if renderer.ms else None
    if ms is not None and len(ms) > 10:
        s["frame_ms"] = {"mean": round(float(ms.mean()), 2), "p50": round(float(np.percentile(ms, 50)), 2),
                         "p95": round(float(np.percentile(ms, 95)), 2)}
    s["frames"] = renderer.frame_id
    if frame_times and len(frame_times) > 20:
        ft = np.array(frame_times)
        ft = ft[ft >= ft[0] + 1.0]
        if len(ft) > 2:
            s["fps"] = round((len(ft) - 1) / (ft[-1] - ft[0]), 2)
    elif renderer.frame_id and elapsed > 0:
        s["fps_overall"] = round(renderer.frame_id / elapsed, 2)
    return s


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
