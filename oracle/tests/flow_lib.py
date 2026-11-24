"""Level-flow scenarios (phase 4): scripted runs through everything around the game tic --
level exits, the intermission tally, the next map with the player carried over, secret exits,
boss specials, the finale, menus, save/load, typed cheats, demos and the attract loop, the
automap -- recorded on CedarDB SQLDoom and replayed on Oracle.

A flow is a Python script (flow_defs.py) written against the reference CLIENT API (doom_sql.py
calls, in the order doom_client.py makes them). It runs on CedarDB through `CedarDriver`: every
call is executed, its result logged, and the state snapshotted. The log is the recording: the
Oracle replay (`OracleDriver`) executes exactly the logged calls with the logged arguments and
compares every result and every snapshot. The script may look at CedarDB's state to decide what
to do next (aim at a monster, wait for the tally) -- those decisions are in the log as plain
calls, so the replay has no logic of its own.

Snapshots: every map-scoped game table for the maps the flow has touched (keyed by map_id +
the table's keys), plus the flow's global tables (screen_state, save slots and save_* tables,
demos, demo_tics). Stored when changed, compared at every step that took one.
Frames: the live 3-D frame (palette indices, CedarDB's index variant of renderer.sql), the
full-screen composite (render_screen.sql) and the automap (render_automap.sql), both RGB.
"""
import json, math, sys, time, zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "client"))
import record_game_reference as rgr  # noqa: E402
import scenario_lib as sl  # noqa: E402

sql = rgr.sql
OUT = HERE.parent / "reference_data" / "flows"

# map-scoped game tables (+ map_id in the key); mp_players is deathmatch only
MAP_TABLES = {t: ("map_id",) + k for t, k in rgr.TABLES.items() if t != "mp_players"}
SAVED = ("player_state", "player_weapons", "player_weapon_owned", "things", "thing_health", "monster_ai",
         "monster_projectiles", "world_effects", "sectors", "sidedefs", "sector_movers", "line_buttons",
         "line_activations", "picked_up_items", "level_secret_discoveries", "level_stats")
GLOBAL_TABLES = {"screen_state": ("id",), "save_slots": ("slot",), "demos": ("demo_id",),
                 "demo_tics": ("demo_id", "tic")}
GLOBAL_TABLES.update({f"save_{t}": ("slot",) + MAP_TABLES[t] for t in SAVED})
EXCLUDE = {"save_slots": {"saved_at"}, "demos": {"recorded_at"}, "sound_events": {"event_id"}}
# CedarDB's static tables that are its game state (Oracle: the g_ twin)
ORA_NAME = {t: "g_" + t for t in MAP_TABLES}


def oname(t):
    return ORA_NAME.get(t, t)


# ----------------------------------------------------------------- comparison
def same(a, b):
    if a == "" and b is None or a is None and b == "":
        return True                            # CedarDB '' is Oracle NULL
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, bool) or isinstance(b, bool):
        return bool(a) == bool(b)
    if isinstance(a, float) or isinstance(b, float):
        a, b = float(a), float(b)
        if a == b:
            return True
        if math.isnan(a) or math.isnan(b):
            return False
        return abs(a - b) <= 1e-9 * max(abs(a), abs(b))
    if isinstance(a, int) and isinstance(b, int):
        return a == b
    return str(a).rstrip() == str(b).rstrip()


def deep_same(a, b):
    if isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)):
        return len(a) == len(b) and all(deep_same(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(deep_same(a[k], b[k]) for k in a)
    return same(a, b)


def fkey(v):
    return (0, "") if v is None or v == "" else (1, v) if not isinstance(v, (int, float, bool)) else (1, float(v))


def compare_rows(ref, ora, cols, keys):
    kidx = [cols.index(k) for k in keys]
    rk = {tuple(fkey(x[j]) for j in kidx): x for x in ref}
    ok = {tuple(fkey(x[j]) for j in kidx): x for x in ora}
    if len(rk) != len(ref) and len(ref) == len(ora):
        # duplicate keys (e.g. two identical monster_attack_damage rows): compare as sorted multisets
        rs = sorted(ref, key=lambda x: tuple(fkey(v) for v in x))
        os_ = sorted(ora, key=lambda x: tuple(fkey(v) for v in x))
        for rr, oo in zip(rs, os_):
            for c, a, b in zip(cols, rr, oo):
                if not same(a, b):
                    return f"row {rr} column {c}: ref={a!r} ora={b!r}"
        return None
    if len(rk) != len(ok) or len(rk) != len(ref) or len(ok) != len(ora):
        missing = [k for k in rk if k not in ok][:3]
        extra = [k for k in ok if k not in rk][:3]
        return f"row count ref={len(ref)} ora={len(ora)} missing={missing} extra={extra}"
    for k, rr in rk.items():
        oo = ok.get(k)
        if oo is None:
            return f"missing key {k}"
        for c, a, b in zip(cols, rr, oo):
            if not same(a, b):
                return f"key {[r[1] for r in k]} column {c}: ref={a!r} ora={b!r}"
    return None


# ----------------------------------------------------------------- snapshots
class Snapshots:
    """Store-when-changed table snapshots keyed by step."""

    def __init__(self):
        self.cols, self.data, self.last = {}, {}, {}

    def put(self, step, table, cols, rows):
        rows = [list(r) for r in rows]
        if table not in self.cols:
            self.cols[table], self.data[table] = cols, []
        if self.last.get(table) != rows:
            self.data[table].append([step, rows])
            self.last[table] = rows

    def get(self, table, step):
        best = None
        for s, rows in self.data.get(table, []):
            if s <= step:
                best = rows
            else:
                break
        return best if best is not None else []

    def dump(self):
        return {"cols": self.cols, "data": self.data}

    @classmethod
    def load(cls, d):
        s = cls()
        s.cols, s.data = d["cols"], d["data"]
        return s


def _norm(v):
    if v is None or isinstance(v, (bool, int, str)):
        return v
    if isinstance(v, float):
        return v
    try:
        return float(v)            # Decimal
    except (TypeError, ValueError):
        return str(v)


# ----------------------------------------------------------------- drivers
class CedarDriver:
    """The reference client's calls on CedarDB (doom_sql.py), logged."""

    def __init__(self, dsn=rgr.DEFAULT_DSN):
        import psycopg2
        import record_reference as rr
        self.conn = psycopg2.connect(dsn)
        self.conn.autocommit = True
        self.cur = self.conn.cursor()
        sql.prepare_client(self.cur)
        self.cur.execute("PREPARE ref_idx(int,int,int,float8,float8,float8,float8) AS " + rr.index_variant(self.cur))
        self.stages = {s["label"].split()[0]: s for s in sql.load_stages(self.cur)}
        self.colnames, self.real = {}, {}

    # ---- state
    def table_cols(self, t):
        if t not in self.colnames:
            self.cur.execute(f'SELECT * FROM "{t}" WHERE false')
            self.colnames[t] = [d.name for d in self.cur.description if d.name not in EXCLUDE.get(t, ())]
            self.real[t] = [d.type_code == 700 for d in self.cur.description if d.name not in EXCLUDE.get(t, ())]
        return self.colnames[t]

    def fetch(self, t, maps):
        cols = self.table_cols(t)
        sel = ", ".join(f'"{c}"' for c in cols)
        if t in MAP_TABLES:
            self.cur.execute(f'SELECT {sel} FROM "{t}" WHERE map_id = ANY(%s)', (list(maps),))
        else:
            self.cur.execute(f'SELECT {sel} FROM "{t}"')
        import numpy as np
        rl = self.real[t]
        return cols, [tuple(float(np.float32(v)) if (f and v is not None) else _norm(v) for v, f in zip(r, rl))
                      for r in self.cur.fetchall()]

    def sector_at(self, map_id, x, y):
        self.cur.execute("SELECT doom_sector_at(%s, %s::float8, %s::float8)", (map_id, float(x), float(y)))
        return int(self.cur.fetchone()[0])

    def query(self, q, args=()):
        self.cur.execute(q, args)
        return self.cur.fetchall()

    # ---- calls
    def call(self, name, args):
        c, a = self.cur, args
        if name == "reset_meta":
            for t in ("save_slots", "demo_tics", "demos") + tuple(f"save_{x}" for x in SAVED):
                c.execute(f"DELETE FROM {t}")
            c.execute("""UPDATE screen_state SET screen='title', cursor_index=0, episode=1, skill=2, tics=0,
                         inter_episode=NULL, inter_level=NULL, inter_next=NULL, kills_pct=NULL, items_pct=NULL,
                         secrets_pct=NULL, time_secs=NULL, par_secs=NULL, sp_state=0, cnt_pause=0, accelerate=FALSE,
                         tgt_kills=NULL, tgt_items=NULL, tgt_secrets=NULL, tgt_time=NULL, tgt_par=NULL,
                         next_map_id=NULL, secret_exit=FALSE, finale_episode=NULL, finale_count=0, finale_stage=0,
                         demo_recording=NULL, demo_playing=NULL, demo_tic=0, attract_step=-1, attract_pagetic=0,
                         cheat_buffer='' WHERE id=0""")
            return None
        if name == "stages":
            return [[s["map_id"], s["label"].split()[0], s["player_thing_id"]] for s in sql.load_stages(c)]
        if name == "restore_render_things":
            # after a load_game: a level start, then render_things rebuilt from the spawn positions --
            # the map's rows as loaded, so later recordings start from a clean map (see game-port.md)
            m, p = a
            c.execute("SELECT doom_enter_level(%s, %s, 2, NULL, NULL)", (m, p))
            c.execute("SELECT doom_materialize_render_things(%s)", (m,))
            return None
        if name == "set_screen":
            sql.set_screen(c, a[0]); return None
        if name == "enter":
            m, p, sk, fm, fp = a
            return list(sql.enter_level(c, m, p, sk, (fm, fp) if fm is not None else None))
        if name == "cheat":
            return sql.cheat_code(c, *a)
        if name == "tic":
            m, p, command, after = a
            due = sql.execute_game_tic(c, m, p, tuple(command))
            events = []
            if due:
                events, _ = sql.fetch_sound_events(c, m, p, after)
            snap = sql.finish_game_tic(c, m, p)
            pose = [float(v) for v in sql.camera_pose(c, m, p, 1.0)]
            return {"due": bool(due), "events": [[e[0], e[1], float(e[2]), float(e[3])] for e in events],
                    "snapshot": snap, "pose": pose}
        if name == "op":
            m, p, op = a
            sl.CedarSide(c, m, p).apply_op(op); return None
        if name == "level_exit":
            return sql.level_exit(c, *a)
        if name == "inter_tic":
            st, fig = sql.intermission_tic(c); return [st, list(fig)]
        if name == "inter_accel":
            sql.intermission_accelerate(c); return None
        if name == "after_inter":
            return sql.after_intermission(c, a[0])
        if name == "finale_tic":
            return sql.finale_tic(c)
        if name == "finale_advance":
            return sql.finale_advance(c)
        if name == "finale_phase":
            return list(sql.finale_phase(c))
        if name == "menu":
            act, st = sql.menu_input(c, a[0]); return [act, st]
        if name == "screen_state":
            return sql.screen_state(c)
        if name == "cheat_key":
            return sql.cheat_key(c, *a)
        if name == "save":
            sql.save_game(c, *a); return None
        if name == "load":
            return sql.load_game(c, a[0])
        if name == "demo_begin":
            return sql.demo_begin(c, *a)
        if name == "demo_play":
            return sql.demo_play(c, a[0])
        if name == "demo_stop":
            sql.demo_stop(c); return None
        if name == "demo_header":
            return sql.demo_header(c, a[0])
        if name == "attract_start":
            sql.attract_start(c); return None
        if name == "attract_stop":
            sql.attract_stop(c); return None
        if name == "attract_tic":
            return sql.attract_tic(c)
        if name == "automap":
            what, m, p, *rest = a
            getattr(sql, "automap_" + what)(c, m, p, *rest); return None
        if name == "weapon_slot":
            return sql.select_weapon_slot(c, *a)
        if name == "weapon_cycle":
            return sql.cycle_weapon(c, *a)
        if name == "level_stats":
            sql.execute_prepared(c, sql.LEVEL_STATS_STATEMENT, tuple(a))
            r = c.fetchone()
            return None if r is None else [_norm(v) for v in r]
        if name == "frame_game":
            m, p, sk = a
            pose = sql.camera_pose(c, m, p, 1.0)
            c.execute("EXECUTE ref_idx(%s,%s,%s,%s,%s,%s,%s)", (m, p, sk, *[float(v) for v in pose]))
            return bytes(c.fetchone()[0])
        if name == "frame_screen":
            return sql.render_screen(c, a[0])
        if name == "frame_automap":
            return sql.render_automap(c, *a)
        raise ValueError(name)


class OracleDriver:
    """The same calls on Oracle: doom_game / doom_flow / doom_screen (client/game_api.py)."""

    def __init__(self):
        import oradb, game_api, numpy as np
        self.ga, self.np = game_api, np
        self.conn = oradb.connect()
        self.cur = self.conn.cursor()
        game_api.setup_session(self.cur)
        self.rcur = self.conn.cursor()
        self.rcur.arraysize = 256
        self.rcur.prefetchrows = 257
        self.colnames = {}
        self.event = 0           # this database's own sound-event cursor (event ids are per database)

    def table_cols(self, t, cedar_cols):
        return cedar_cols

    def fetch(self, t, cols, maps):
        sel = ", ".join(f'"{c.upper()}"' for c in cols)
        if t in MAP_TABLES:
            ml = ",".join(str(int(m)) for m in maps) or "-1"
            self.cur.execute(f"SELECT {sel} FROM {oname(t)} WHERE map_id IN ({ml})")
        else:
            self.cur.execute(f"SELECT {sel} FROM {oname(t)}")
        return [tuple(float(v) if isinstance(v, float) else v for v in r) for r in self.cur.fetchall()]

    def fn(self, expr, typ=str, **kw):
        r = self.cur.var(typ)
        self.cur.execute(f"BEGIN :r := {expr}; END;", r=r, **kw)
        return r.getvalue()

    def proc(self, stmt, **kw):
        self.cur.execute(f"BEGIN {stmt}; END;", **kw)

    def frame(self, sqltext, **kw):
        self.rcur.execute(sqltext, **kw)
        rows = self.rcur.fetchall()
        fr = self.np.empty((200, 320), self.np.uint8)
        for y, _p, hx in rows:
            fr[int(y)] = self.np.frombuffer(bytes.fromhex(hx), self.np.uint8)
        return fr

    def call(self, name, a):
        c, ga = self.cur, self.ga
        try:
            return self._call(name, a, c, ga)
        finally:
            self.conn.commit()

    def _call(self, name, a, c, ga):
        if name == "reset_meta":
            for t in ("save_slots", "demo_tics", "demos") + tuple(f"save_{x}" for x in SAVED):
                c.execute(f"DELETE FROM {t}")
            c.execute("""UPDATE screen_state SET screen='title', cursor_index=0, episode=1, skill=2, tics=0,
                         inter_episode=NULL, inter_level=NULL, inter_next=NULL, kills_pct=NULL, items_pct=NULL,
                         secrets_pct=NULL, time_secs=NULL, par_secs=NULL, sp_state=0, cnt_pause=0, accelerate=FALSE,
                         tgt_kills=NULL, tgt_items=NULL, tgt_secrets=NULL, tgt_time=NULL, tgt_par=NULL,
                         next_map_id=NULL, secret_exit=FALSE, finale_episode=NULL, finale_count=0, finale_stage=0,
                         demo_recording=NULL, demo_playing=NULL, demo_tic=0, attract_step=-1, attract_pagetic=0,
                         cheat_buffer=NULL WHERE id=0""")
            return None
        if name == "restore_render_things":
            m, p = a
            ga.enter_level(c, m, p, 2)
            self.proc("doom_flow.materialize_render_things(:m)", m=m)
            return None
        if name == "stages":
            c.execute(ga.STAGES_SQL)
            return [[int(r[0]), r[1], int(r[2])] for r in c.fetchall()]
        if name == "set_screen":
            self.proc("doom_flow.set_screen(:s)", s=a[0]); return None
        if name == "enter":
            self.event = 0
            return list(ga.enter_level(c, *a))
        if name == "cheat":
            return self.fn("doom_game.cheat(:m, :p, :c)", m=a[0], p=a[1], c=a[2])
        if name == "tic":
            m, p, command, _after = a
            due = ga.run_tic(c, m, p, command)
            self.conn.commit()
            events = ga.sound_events(c, m, p, self.event) if due else []
            if events:
                self.event = max(e[0] for e in events)
            snap = ga.finish_tic(c, m, p)
            pose = list(ga.camera_pose(c, m, p, 1.0))
            return {"due": due, "events": [[e[0], e[1], float(e[2]), float(e[3])] for e in events],
                    "snapshot": snap, "pose": pose}
        if name == "op":
            m, p, op = a
            sl.OracleSide(c, m, p).apply_op(op); return None
        if name == "level_exit":
            r = self.fn("doom_flow.level_exit(:m, :p, :s)", int, m=a[0], p=a[1], s=int(bool(a[2])))
            return None if r is None or r < 0 else r
        if name == "inter_tic":
            st = self.fn("doom_flow.intermission_tic", str)
            c.execute("SELECT sp_state, kills_pct, items_pct, secrets_pct, time_secs, par_secs FROM screen_state WHERE id = 0")
            fig = c.fetchone() or (0, 0, 0, 0, 0, 0)
            return [st or "done", [int(v) for v in fig]]
        if name == "inter_accel":
            self.fn("doom_flow.intermission_accelerate", int); return None
        if name == "after_inter":
            return self.fn("doom_flow.after_intermission(:m)", m=a[0])
        if name == "finale_tic":
            return self.fn("doom_flow.finale_tic") or "done"
        if name == "finale_advance":
            return self.fn("doom_flow.finale_advance") or "done"
        if name == "finale_phase":
            c.execute("SELECT finale_stage, finale_count FROM screen_state WHERE id = 0")
            r = c.fetchone()
            return [0, 0] if r is None else [int(r[0]), int(r[1])]
        if name == "menu":
            act = self.fn("doom_flow.menu_input(:k)", k=a[0]) or "none"
            return [act, self.screen_state()]
        if name == "screen_state":
            return self.screen_state()
        if name == "cheat_key":
            return self.fn("doom_flow.cheat_key(:m, :p, :k)", m=a[0], p=a[1], k=a[2]) or "none"
        if name == "save":
            self.fn("doom_flow.save_game(:sl, :m, :p, :sk, :n)", int, sl=a[0], m=a[1], p=a[2], sk=a[3], n=a[4])
            return None
        if name == "load":
            self.event = 0
            r = self.fn("doom_flow.load_game(:s)", int, s=a[0])
            if r is None or r < 0:
                return None
            c.execute("SELECT skill FROM save_slots WHERE slot = :s", s=a[0])
            got = c.fetchone()
            return {"map_id": r, "skill": 2 if got is None else int(got[0])}
        if name == "demo_begin":
            return self.fn("doom_flow.demo_begin(:n, :m, :p, :s)", int, n=a[0], m=a[1], p=a[2], s=a[3])
        if name == "demo_play":
            d = self.fn("doom_flow.demo_play(:n)", int, n=a[0])
            return None if d < 0 else self._header(d)
        if name == "demo_stop":
            self.proc("doom_flow.demo_stop"); return None
        if name == "demo_header":
            return self._header(a[0])
        if name == "attract_start":
            self.proc("doom_flow.attract_start"); return None
        if name == "attract_stop":
            self.proc("doom_flow.attract_stop"); return None
        if name == "attract_tic":
            return self.fn("doom_flow.attract_tic") or "none"
        if name == "automap":
            what, m, p, *rest = a
            if what == "pan":
                self.proc("doom_flow.automap_pan(:m, :p, :a, :b)", m=m, p=p, a=float(rest[0]), b=float(rest[1]))
            elif what == "zoom":
                self.proc("doom_flow.automap_zoom(:m, :p, :f)", m=m, p=p, f=float(rest[0]))
            elif what == "toggle":
                self.proc("doom_flow.automap_toggle(:m, :p, :w)", m=m, p=p, w=rest[0])
            elif what == "fit":
                self.proc("doom_flow.automap_fit(:m, :p)", m=m, p=p)
            return None
        if name == "weapon_slot":
            return self.fn("doom_flow.weapon_slot(:m, :p, :s)", int, m=a[0], p=a[1], s=a[2])
        if name == "weapon_cycle":
            return self.fn("doom_flow.weapon_cycle(:m, :p, :s)", int, m=a[0], p=a[1], s=a[2])
        if name == "level_stats":
            c.execute(ga.LEVEL_STATS_SQL, m=a[0], p=a[1])
            r = c.fetchone()
            return None if r is None else [v for v in r]
        if name == "frame_game":
            fr, _pose = ga.render_live(self.rcur, *a)
            return fr
        if name == "frame_screen":
            return self.frame(ga.SCREEN_SQL, t=a[0])
        if name == "frame_automap":
            return self.frame(ga.AUTOMAP_SQL, m=a[0], p=a[1])
        raise ValueError(name)

    def screen_state(self):
        self.cur.execute("SELECT screen, cursor_index, episode, skill FROM screen_state WHERE id = 0")
        r = self.cur.fetchone()
        if r is None:
            return {"screen": "game", "cursor": 0, "episode": 1, "skill": 2}
        return {"screen": r[0], "cursor": int(r[1]), "episode": int(r[2]), "skill": int(r[3])}

    def _header(self, d):
        self.cur.execute("SELECT demo_id, name, map_id, player_thing_id, skill, tic_count FROM demos WHERE demo_id = :d",
                         d=d)
        r = self.cur.fetchone()
        if r is None:
            return None
        return {"demo_id": int(r[0]), "name": r[1], "map_id": int(r[2]), "player_thing_id": int(r[3]),
                "skill": int(r[4]), "tic_count": int(r[5])}


# ----------------------------------------------------------------- recording
LIGHT = {"inter_tic", "inter_accel", "finale_tic", "finale_advance", "finale_phase", "menu", "screen_state",
         "attract_tic", "attract_start", "attract_stop", "set_screen", "demo_header", "stages", "level_stats",
         "weapon_slot", "weapon_cycle", "automap"}   # screen-level calls: snapshot the global tables only
FRAMES = {"frame_game", "frame_screen", "frame_automap"}


class Recorder:
    """Runs a flow script on CedarDB: g.<call>(...) executes, logs, snapshots."""

    def __init__(self, name, drv):
        self.name, self.drv = name, drv
        self.log, self.snaps, self.frames = [], Snapshots(), {}
        self.maps = []           # map ids touched so far
        self.map = self.player = None
        self.skill = 2
        self.event = 0
        self.mods = {}           # map_id -> CedarSide with mods applied

    # ---- low level
    def do(self, name, *args, snap=True):
        t0 = time.perf_counter()
        r = self.drv.call(name, list(args))
        ms = (time.perf_counter() - t0) * 1e3
        step = len(self.log)
        entry = {"a": name, "args": list(args), "ms": ms}
        if name in FRAMES:
            self.frames[step] = r
            entry["r"] = None
        else:
            entry["r"] = r
        if snap and name not in FRAMES:
            self.snapshot(step, full=name not in LIGHT)
            entry["snap"] = "full" if name not in LIGHT else "global"
            entry["maps"] = list(self.maps)
        self.log.append(entry)
        return r

    def snapshot(self, step, full):
        tables = list(GLOBAL_TABLES) + (list(MAP_TABLES) if full else [])
        for t in tables:
            cols, rows = self.drv.fetch(t, self.maps)
            self.snaps.put(step, t, cols, rows)

    def touch(self, m):
        if m not in self.maps:
            self.maps.append(m)

    # ---- the client's vocabulary
    def stage(self, name):
        s = self.drv.stages[name]
        return s["map_id"], s["player_thing_id"]

    def mod(self, map_name, mods):
        """Map mods (scenario_lib) applied to both databases before the run, reverted after."""
        m, p = self.stage(map_name)
        side = sl.CedarSide(self.drv.cur, m, p)
        side.apply_mods(mods)
        self.mods[m] = (side, mods)
        self.log.append({"a": "mods", "args": [m, p, mods], "r": None})

    def enter(self, map_name, skill=None, carry=False, cheats=()):
        """G_DoLoadLevel as session.restart does it (carry = the level just finished)."""
        m, p = self.stage(map_name)
        if skill is not None:
            self.skill = skill
        fm, fp = (self.map, self.player) if carry else (None, None)
        self.touch(m)
        self.map, self.player, self.event = m, p, 0
        pose = self.do("enter", m, p, self.skill, fm, fp)
        for code in cheats:
            self.do("cheat", m, p, code)
        return pose

    def enter_id(self, map_id, carry=False):
        name = next(k for k, s in self.drv.stages.items() if s["map_id"] == map_id)
        return self.enter(name, carry=carry)

    def tic(self, command=None, **kw):
        cmd = list(command) if command is not None else [self.skill, float(kw.get("fwd", 0.0)),
                                                          float(kw.get("strafe", 0.0)), bool(kw.get("run", False)),
                                                          float(kw.get("turn", 0.0)), bool(kw.get("atk", False)),
                                                          kw.get("sw"), bool(kw.get("use", False))]
        cmd[0] = self.skill
        r = self.do("tic", self.map, self.player, cmd, self.event)
        if r["events"]:
            self.event = max(e[0] for e in r["events"])
        return r

    def tics(self, commands, frame_every=0, stop_on_exit=True):
        """Run commands; returns the snapshot that showed an exit (and stops there) or None."""
        for i, c in enumerate(commands):
            r = self.tic(c)
            if frame_every and (i + 1) % frame_every == 0:
                self.frame_game()
            s = r["snapshot"]
            if stop_on_exit and (s["use_exit"] or s["cross_exit"] or s["sector_exit"] or s["boss_exit"]):
                return s
        return None

    def idle(self, n, frame_every=0):
        return self.tics([None] * n, frame_every) if n else None

    def op(self, op):
        return self.do("op", self.map, self.player, op)

    def pose(self, x, y, angle):
        return self.op({"op": "pose", "x": x, "y": y, "angle": angle})

    def frame_game(self):
        return self.do("frame_game", self.map, self.player, self.skill)

    def frame_screen(self, tics=0):
        return self.do("frame_screen", tics)

    def frame_automap(self):
        return self.do("frame_automap", self.map, self.player)

    def exit_secret(self, s):
        """doom_client: which exit the snapshot reports, as deferred_exit_secret."""
        if s["use_exit"]:
            return bool(s["use_secret_exit"])
        if s["cross_exit"]:
            return bool(s["cross_secret_exit"])
        return False

    def intermission(self, accel_at=None, frame_every=0, max_tics=4000):
        """The tally on its 35 Hz clock until 'done': a keypress (accelerate) at tally tic
        `accel_at` (and again once everything is shown)."""
        for i in range(max_tics):
            if accel_at is not None and i == accel_at:
                self.do("inter_accel")
            st, fig = self.do("inter_tic")
            if frame_every and i % frame_every == 0:
                self.frame_screen(i)
            if st == "waiting":
                self.do("inter_accel")
            if st == "done":
                return i
        raise RuntimeError("intermission did not finish")

    def finish(self):
        for m, (side, _mods) in self.mods.items():
            side.revert()
        self.mods = {}

    def write(self, root=OUT):
        out = root / self.name
        (out / "frames").mkdir(parents=True, exist_ok=True)
        for f in (out / "frames").glob("*.z"):
            f.unlink()
        for step, fr in self.frames.items():
            (out / "frames" / f"{step:05d}.z").write_bytes(zlib.compress(bytes(fr), 6))
        blob = {"name": self.name, "log": self.log, "snaps": self.snaps.dump()}
        (out / "flow.json.z").write_bytes(zlib.compress(json.dumps(blob).encode(), 6))
        return out


FLOWS = {}


def flow(name, covers=(), note=""):
    def deco(fn):
        FLOWS[name] = (fn, list(covers), note)
        return fn
    return deco
