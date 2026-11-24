#!/usr/bin/env python3
"""A deathmatch session through the player API, recorded on CedarDB and replayed on Oracle.

    python oracle/tests/api_replay.py record [--out DIR]     # CedarDB (ground truth)
    python oracle/tests/api_replay.py replay [--out DIR]     # Oracle: every call, table and frame compared

The session is the referee's work done in lock-step (so it is deterministic): the match opened
exactly as doom_server.py / referee.py open it (configure, rotation, mp_start, frame views, the
join-path warm-up, open), then per world tic: the scheduled joins and lobby calls, every seated
player's api_input (scripted bots, mp_lib.Bot), the owner's tic, a snapshot of every map-scoped state
table, then every seated player's api_camera(1.0) and reads (api_snapshot, api_player_state, its
sound events; every 5 tics its frame view; every 25 tics the scoreboard, api_match, sound loops,
weapon slot/cycle, the live overview; automap calls on a few tics). Five accounts: four seats and a
waiter; at tic 250 one seated player goes quiet and is reaped (doom_mp_reap), the waiter gets its
seat, the reaped player joins the queue. The -timer ends E1M1, the intermission runs (API calls are
no-ops), the match rotates to E1M2 with the seats carried over, and plays 250 more tics there.

Players are real database accounts on both sides and every api_* call and view runs in the
player's own session (session_user / SESSION_USER resolution exercised). CedarDB Community refuses
GRANT ("requires an enterprise license"), so the ground-truth roles there are created SUPERUSER (a
role without grants may not read the api_* views or draw from the input queue's sequence); access
control itself is verified on Oracle (mp_acl_check.py), where each player holds only DOOM_PLAYER.

Output: reference_data/api_session/ (calls.json, seg1/ and seg2/ table recordings in the
record_game_reference format, frames/*.rgb.z, automap/*.rgb.z).
"""
import argparse
import json
import sys
import time
import zlib
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "client"))
import mp_lib  # noqa: E402

OUT = HERE.parent / "reference_data" / "api_session"
CEDAR = dict(host="localhost", port=55433, dbname="postgres")
CEDAR_OWNER = "postgresql://postgres:postgres_doom_reference_pw@localhost:55433/postgres"
PLAYERS = ["apx_p1", "apx_p2", "apx_p3", "apx_p4", "apx_p5"]
PASSWORD = "Doom-Replay-Pw-2026"
CFG = dict(map_id=1, skill=2, timer=600, altdeath=True, monsters=True, respawn=True, intermission_tics=105,
           rotation=["E1M1", "E1M2"], hold=900, seed=41)
SEG2_TICS = 250
FRAME_EVERY = 5
LEAVE_TIC = 250
STATE_Q = """
SELECT mp.slot, ps.player_thing_id, ps.position_x, ps.position_y, ps.view_angle, {alive}, ps.death_tics, ps.health,
       {held}
  FROM {mpp} mp JOIN {ps} ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id
 WHERE mp.map_id = {m} ORDER BY mp.slot"""
ROLE_COLS = {"role_name", "login", "name"}


def norm(v):
    if isinstance(v, (bytes, bytearray, memoryview)):
        return bytes(v).hex()
    if isinstance(v, float) or hasattr(v, "is_finite"):
        return float(v)
    if isinstance(v, (list, tuple)):
        return [norm(x) for x in v]
    return v


# =============================================================================== CedarDB side
class Cedar:
    def __init__(self):
        import psycopg2
        self.pg = psycopg2
        self.oc = psycopg2.connect(CEDAR_OWNER)
        self.oc.autocommit = True
        self.o = self.oc.cursor()
        self.conns, self.curs = {}, {}
        self.views = {}

    def setup(self):
        self.o.execute("SELECT id, map_id, z FROM things WHERE type IN (1, 2, 3, 4) AND map_id IN (1, 2)")
        self.saved_z = self.o.fetchall()
        for p in PLAYERS:
            self.o.execute("SELECT count(*) FROM pg_roles WHERE rolname = %s", (p,))
            verb = "ALTER" if self.o.fetchone()[0] else "CREATE"
            # CedarDB Community refuses GRANT (enterprise licence): the ground-truth roles are
            # superusers, so every api_* call and view runs in the role's own session
            self.o.execute(f"{verb} ROLE {p} LOGIN SUPERUSER PASSWORD %s", (PASSWORD,))
            c = self.pg.connect(user=p, password=PASSWORD, **CEDAR)
            c.autocommit = True
            k = c.cursor()
            # the client's prepared statements (doom_sql.prepare_api_client)
            k.execute("PREPARE doom_mp_input(real,real,boolean,real,boolean,int,boolean) AS "
                      "SELECT api_input($1,$2,$3,$4,$5,$6,$7)")
            k.execute("PREPARE doom_api_camera(float8) AS SELECT api_camera($1)")
            self.conns[p], self.curs[p] = c, k

    def viewdef(self, v):
        self.o.execute("SELECT pg_get_viewdef(%s)", (v,))
        d = self.o.fetchone()[0].strip().rstrip(";")
        assert "session_user::text" in d or v in ("api_scoreboard", "api_things_live"), v
        return d

    def view(self, player, v, select="*", tail=""):
        k = self.curs[player]
        k.execute(f"SELECT {select} FROM {v} {tail}")
        return k.fetchall()

    def cleanup(self):
        for c in self.conns.values():
            c.close()
        for p in PLAYERS:
            self.o.execute(f"DROP ROLE IF EXISTS {p}")
        for t in ("mp_inputs", "mp_join_requests", "mp_players", "mp_match", "mp_waiting", "mp_holders", "mp_rotation",
                  "mp_referee"):
            self.o.execute(f"DELETE FROM {t}")
        self.o.execute("SELECT table_name FROM information_schema.tables WHERE table_name LIKE 'api_frame_%'")
        for (v,) in self.o.fetchall():
            self.o.execute(f"DROP VIEW IF EXISTS {v}")
        for tid, m, z in self.saved_z:
            self.o.execute("UPDATE things SET z = %s WHERE map_id = %s AND id = %s", (z, m, tid))

    # ------------------------------------------------------------------ owner
    def start(self):
        sys.path.insert(0, str(HERE.parents[1] / "reference" / "sqldoom"))
        from cedarscript_runtime import install_match_frame_views
        o, c = self.o, CFG
        o.execute("DELETE FROM mp_inputs")
        o.execute("SELECT doom_mp_configure(%s,%s,%s,%s,%s,%s,%s)",
                  (c["map_id"], c["skill"], c["timer"], c["altdeath"], c["monsters"], c["respawn"], c["intermission_tics"]))
        o.execute("UPDATE mp_match SET hold_seconds = %s", (c["hold"],))
        o.execute("DELETE FROM mp_rotation")
        for pos, name in enumerate(c["rotation"]):
            o.execute("INSERT INTO mp_rotation (position, map_name) VALUES (%s, %s)", (pos, name))
        o.execute("SELECT doom_mp_start(%s,%s)", (c["map_id"], c["skill"]))
        players = self.mp_players(c["map_id"])
        o.execute("SELECT map_id FROM maps WHERE name = ANY(%s) OR map_id = %s ORDER BY map_id", (c["rotation"], c["map_id"]))
        install_match_frame_views(o, [r[0] for r in o.fetchall()], c["skill"])
        self.tic(c["map_id"], c["skill"], players)
        o.execute("SELECT doom_mp_request_all(%s)", (c["map_id"],))
        self.tic(c["map_id"], c["skill"], players)
        o.execute("SELECT doom_mp_vacate_all(%s)", (c["map_id"],))
        o.execute("SELECT doom_mp_open()")
        return players

    def mp_players(self, m):
        self.o.execute("SELECT slot, player_thing_id FROM mp_players WHERE map_id = %s ORDER BY slot", (m,))
        return {int(s): int(p) for s, p in self.o.fetchall()}

    def tic(self, m, skill, players):
        try:
            self.o.execute("SELECT doom_run_mp_tic(%s,%s,%s,%s,%s,%s)",
                           (m, skill, players[1], players.get(2), players.get(3), players.get(4)))
            return bool(self.o.fetchone()[0])
        except self.pg.Error as exc:
            self.oc.rollback()
            self.o.execute("DELETE FROM mp_inputs WHERE map_id = %s", (m,))
            return "failed: " + str(exc).splitlines()[0]

    def reap(self, m, secs):
        self.o.execute("SELECT doom_mp_reap(%s, %s)", (m, secs))
        return self.o.fetchone()[0]

    def force_idle(self, role):
        self.o.execute("UPDATE mp_players SET last_seen = now() - interval '1 hour' WHERE role_name = %s", (role,))

    def intermission(self):
        self.o.execute("SELECT doom_mp_intermission_begin()")

    def rotate(self):
        self.o.execute("SELECT doom_mp_rotate()")
        return int(self.o.fetchone()[0])

    def globals(self):
        o = self.o
        o.execute("SELECT upper(role_name) FROM mp_waiting ORDER BY since")
        waiting = [r[0] for r in o.fetchall()]
        o.execute("SELECT slot, upper(role_name), display_name FROM mp_holders ORDER BY slot")
        holders = [list(r) for r in o.fetchall()]
        o.execute("SELECT position, map_name FROM mp_rotation ORDER BY position")
        rot = [list(r) for r in o.fetchall()]
        return {"waiting": waiting, "holders": holders, "rotation": rot}

    def bot_state(self, m):
        self.o.execute(STATE_Q.format(alive="ps.alive", held="mp.role_name IS NOT NULL", mpp="mp_players",
                                      ps="player_state", m=int(m)))
        st = {r[0]: dict(pid=r[1], x=float(r[2]), y=float(r[3]), angle=float(r[4]), alive=bool(r[5]),
                         death_tics=int(r[6]), health=int(r[7]), held=bool(r[8])) for r in self.o.fetchall()}
        self.o.execute("SELECT player_thing_id, weapon_id FROM player_weapon_owned WHERE map_id = %s", (m,))
        owned = {}
        for pid, w in self.o.fetchall():
            owned.setdefault(pid, set()).add(int(w))
        return st, owned

    # ------------------------------------------------------------------ players
    def fn(self, p, sql, args=()):
        k = self.curs[p]
        k.execute(sql, args)
        return k.fetchone()[0] if k.description else None

    def call(self, p, op, args, ctx):
        k = self.curs[p]
        if op == "join":
            return self.fn(p, "SELECT api_join()")
        if op == "slot":
            return self.fn(p, "SELECT api_slot()")
        if op == "set_name":
            return self.fn(p, "SELECT api_set_name(%s)", args)
        if op == "input":
            fwd, strafe, run, turn, fire, weapon, use = args
            k.execute("EXECUTE doom_mp_input(%s,%s,%s,%s,%s,%s,%s)",
                      (float(fwd), float(strafe), bool(run), float(turn), bool(fire), weapon, bool(use)))
            return k.fetchone()[0]
        if op == "camera":
            k.execute("EXECUTE doom_api_camera(%s)", (float(args[0]),))
            return k.fetchone()[0]
        if op == "weapon_slot":
            return self.fn(p, "SELECT api_weapon_slot(%s)", args)
        if op == "weapon_cycle":
            return self.fn(p, "SELECT api_weapon_cycle(%s)", args)
        if op in ("automap_pan", "automap_zoom", "automap_toggle", "automap_fit"):
            ph = ",".join(["%s"] * len(args))
            return self.fn(p, f"SELECT api_{op}({ph})", tuple(float(a) if isinstance(a, float) else a for a in args))
        if op == "automap":
            k.execute("SELECT api_automap()")
            raw = k.fetchone()[0]
            return None if raw is None else np.frombuffer(bytes(raw), np.uint8).reshape(200, 320, 3)
        if op == "frame":
            m, s = args
            k.execute(f"SELECT frame_rgb FROM api_frame_slot{int(s)}_m{int(m)}")
            row = k.fetchone()
            raw = None if row is None else row[0]
            return None if raw is None else np.frombuffer(bytes(raw), np.uint8).reshape(200, 320, 3)
        if op == "snapshot":
            return [list(r) for r in self.view(p, "api_snapshot")]
        if op == "player_state":
            k.execute("SELECT * FROM api_player_state")
            names = [x.name for x in k.description]
            return [dict(zip(names, r)) for r in k.fetchall()]
        if op == "scoreboard":
            return [list(r) for r in self.view(p, "api_scoreboard")]
        if op == "match":
            return [list(r) for r in self.view(p, "api_match", "state, map_id, map_name, timer_tics, altdeath, monsters, "
                                                "maps_played, level_tics, next_map, waiting, ahead_of_me, hold_seconds")]
        if op == "sounds":
            cursor = ctx.setdefault(("snd", p), 0)
            rows = self.view(p, "api_sound_events", "event_id, sound_name, volume, pan",
                             f"WHERE event_id > {int(cursor)} ORDER BY event_id")
            if rows:
                ctx[("snd", p)] = max(int(r[0]) for r in rows)
            return [[r[1], r[2], r[3]] for r in rows]
        if op == "loops":
            return [list(r) for r in self.view(p, "api_sound_loops")]
        if op == "things_live":
            return [list(r) for r in self.view(p, "api_things_live", "kind, thing_id, name, x, y, angle, alive",
                                               f"WHERE map_id = {int(args[0])} ORDER BY kind, thing_id")]
        raise ValueError(op)


# =============================================================================== Oracle side
class Oracle:
    def __init__(self):
        import oradb, game_api, api_client, accounts, api_install
        self.api_client, self.accounts, self.api_install = api_client, accounts, api_install
        self.oc = oradb.connect()
        self.o = self.oc.cursor()
        game_api.setup_session(self.o)
        self.players = {}
        self.lut = None

    def setup(self):
        for p in PLAYERS:
            self.accounts.add_account(self.o, p, PASSWORD, "player")
            self.players[p] = self.api_client.ApiPlayer(p, PASSWORD)
        self.lut = self.api_client.palettes(self.players[PLAYERS[0]].cur)

    def cleanup(self):
        for pl in self.players.values():
            pl.close()
        import mp_lib_api
        mp_lib_api.match_cleanup()
        print("accounts:", mp_lib_api.drop_accounts(PLAYERS))

    def start(self):
        o, c = self.o, CFG
        o.execute("DELETE FROM g_mp_inputs")
        o.execute("BEGIN doom_game.mp_configure(:m, :s, :t, :a, :mo, :r, :i); END;", m=c["map_id"], s=c["skill"],
                  t=c["timer"], a=int(c["altdeath"]), mo=int(c["monsters"]), r=int(c["respawn"]), i=c["intermission_tics"])
        # the recorded frames are CedarDB's: the players' frame views render in the exact sprite mode
        self.api_install.ensure_match_columns(o)
        o.execute("UPDATE g_mp_match SET hold_seconds = :h, sprite_mode = 0", h=c["hold"])
        o.execute("DELETE FROM g_mp_rotation")
        for pos, name in enumerate(c["rotation"]):
            o.execute("INSERT INTO g_mp_rotation (position, map_name) VALUES (:p, :n)", p=pos, n=name)
        n = o.var(int)
        o.execute("BEGIN :n := doom_game.mp_start(:m, :s); END;", n=n, m=c["map_id"], s=c["skill"])
        self.oc.commit()
        players = self.mp_players(c["map_id"])
        o.execute("SELECT map_id FROM maps WHERE name IN (SELECT map_name FROM g_mp_rotation) OR map_id = :m "
                  "ORDER BY map_id", m=c["map_id"])
        self.api_install.install_frame_views(o, [r[0] for r in o.fetchall()])
        self.oc.commit()
        self.tic(c["map_id"], c["skill"], players)
        o.execute("BEGIN doom_mp.request_all(:m); COMMIT; END;", m=c["map_id"])
        self.tic(c["map_id"], c["skill"], players)
        o.execute("BEGIN doom_game.mp_vacate_all(:m); doom_game.mp_open; COMMIT; END;", m=c["map_id"])
        return players

    def mp_players(self, m):
        self.o.execute("SELECT slot, player_thing_id FROM g_mp_players WHERE map_id = :m ORDER BY slot", m=m)
        return {int(s): int(p) for s, p in self.o.fetchall()}

    def tic(self, m, skill, players):
        r, err = self.o.var(int), self.o.var(str, 2000)
        self.o.execute("BEGIN :r := doom_mp.tic(:m, :s, :p1, :p2, :p3, :p4, :e); END;", r=r, e=err, m=m, s=skill,
                       p1=players[1], p2=players.get(2), p3=players.get(3), p4=players.get(4))
        self.last_err = err.getvalue()
        if r.getvalue() < 0:
            return "failed: " + (err.getvalue() or "").split(" | ")[0]
        return bool(r.getvalue())

    def reap(self, m, secs):
        r = self.o.var(int)
        self.o.execute("BEGIN :r := doom_mp.reap(:m, :s); COMMIT; END;", r=r, m=m, s=secs)
        return r.getvalue()

    def force_idle(self, role):
        self.o.execute("UPDATE g_mp_players SET last_seen = SYSTIMESTAMP - INTERVAL '1' HOUR WHERE role_name = UPPER(:r)",
                       r=role)
        self.oc.commit()

    def intermission(self):
        self.o.execute("BEGIN doom_mp.intermission_begin; COMMIT; END;")

    def rotate(self):
        r = self.o.var(int)
        self.o.execute("BEGIN :r := doom_mp.rotate; COMMIT; END;", r=r)
        return int(r.getvalue())

    def globals(self):
        o = self.o
        o.execute("SELECT role_name FROM g_mp_waiting ORDER BY since")
        waiting = [r[0] for r in o.fetchall()]
        o.execute("SELECT slot, role_name, display_name FROM g_mp_holders ORDER BY slot")
        holders = [list(r) for r in o.fetchall()]
        o.execute("SELECT position, map_name FROM g_mp_rotation ORDER BY position")
        rot = [list(r) for r in o.fetchall()]
        return {"waiting": waiting, "holders": holders, "rotation": rot}

    def rgb(self, idx, pal):
        return self.lut[pal][idx]

    def call(self, p, op, args, ctx):
        pl = self.players[p]
        if op != "frame":
            # the READ ONLY transaction api_camera opened is for the frame; a client's other reads
            # (and the calls, which COMMIT first anyway) see the latest committed state
            pl.end_read()
        if op == "join":
            return pl.join()
        if op == "slot":
            return pl.slot()
        if op == "set_name":
            return pl.set_name(args[0])
        if op == "input":
            return pl.input(tuple(args))
        if op == "camera":
            return pl.camera(args[0])
        if op == "weapon_slot":
            return pl.weapon_slot(args[0])
        if op == "weapon_cycle":
            return pl.weapon_cycle(args[0])
        if op == "automap_pan":
            return pl.automap_pan(*args)
        if op == "automap_zoom":
            return pl.automap_zoom(*args)
        if op == "automap_toggle":
            return pl.automap_toggle(*args)
        if op == "automap_fit":
            return pl.automap_fit()
        if op == "automap":
            pl.cur.execute("SELECT y, pal, hex FROM TABLE(api_automap())")
            rows = pl.cur.fetchall()
            if len(rows) != 200:
                return None
            out = np.empty((200, 320, 3), np.uint8)
            for y, pal, hx in rows:
                out[int(y)] = self.lut[int(pal)][np.frombuffer(bytes.fromhex(hx), np.uint8)]
            return out
        if op == "frame":
            rows = pl.frame_rows(*args)
            pl.end_read()
            if len(rows) != 200:
                return None
            out = np.empty((200, 320, 3), np.uint8)
            for y, pal, hx in rows:
                out[int(y)] = self.lut[int(pal)][np.frombuffer(bytes.fromhex(hx), np.uint8)]
            return out
        if op == "snapshot":
            return [list(r) for r in pl.query("SELECT * FROM api_snapshot")]
        if op == "player_state":
            pl.cur.execute("SELECT * FROM api_player_state")
            names = [d.name.lower() for d in pl.cur.description]
            return [dict(zip(names, r)) for r in pl.cur.fetchall()]
        if op == "scoreboard":
            return [list(r) for r in pl.query("SELECT * FROM api_scoreboard")]
        if op == "match":
            return [list(r) for r in pl.query("SELECT state, map_id, map_name, timer_tics, altdeath, monsters, maps_played, "
                                              "level_tics, next_map, waiting, ahead_of_me, hold_seconds FROM api_match")]
        if op == "sounds":
            cursor = ctx.setdefault(("snd", p), 0)
            rows = pl.query("SELECT event_id, sound_name, volume, pan FROM api_sound_events WHERE event_id > :c "
                            "ORDER BY event_id", c=cursor)
            if rows:
                ctx[("snd", p)] = max(int(r[0]) for r in rows)
            return [[r[1], r[2], r[3]] for r in rows]
        if op == "loops":
            return [list(r) for r in pl.query("SELECT * FROM api_sound_loops")]
        if op == "things_live":
            return [list(r) for r in pl.query("SELECT kind, thing_id, name, x, y, angle, alive FROM api_things_live "
                                              "WHERE map_id = :m ORDER BY kind, thing_id", m=int(args[0]))]
        raise ValueError(op)


# =============================================================================== comparison
def same(a, b, key=None):
    import math
    if isinstance(a, dict) and isinstance(b, dict):
        common = set(a) & set(b)
        for k in sorted(common):
            if not same(a[k], b[k], k):
                return False
        return True
    if isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)):
        return len(a) == len(b) and all(same(x, y, key) for x, y in zip(a, b))
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, bool) or isinstance(b, bool):
        return bool(a) == bool(b)
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        a, b = float(a), float(b)
        if a == b:
            return True
        if math.isnan(a) or math.isnan(b):
            return math.isnan(a) and math.isnan(b)
        # psycopg2 reads a CedarDB REAL from its shortest float4 text (656.6355), Oracle returns the
        # BINARY_FLOAT's exact value (656.635498046875): equal when they are the same float4
        if np.float32(a) == np.float32(b) and (float(np.float32(a)) in (a, b)):
            return True
        return abs(a - b) <= 1e-9 * max(abs(a), abs(b))
    return str(a).rstrip().upper() == str(b).rstrip().upper()


def jsonable(v):
    if isinstance(v, dict):
        return {k: jsonable(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [jsonable(x) for x in v]
    if isinstance(v, (bytes, bytearray, memoryview)):
        return bytes(v).hex()
    if hasattr(v, "is_finite"):   # Decimal
        return float(v)
    if hasattr(v, "isoformat"):
        return None
    return v


# =============================================================================== the session
class Session:
    def __init__(self, drv, mode, out):
        self.drv, self.mode, self.out = drv, mode, out
        self.ctx = {}
        self.calls = [] if mode == "record" else json.loads((out / "calls.json").read_text())
        self.i = 0
        self.bad, self.n_frames, self.bad_frames, self.n_calls = [], 0, 0, 0
        self.n_auto, self.bad_auto = 0, 0
        self.recorder = None

    # ------------------------------------------------------------------ the log
    def entry(self, kind, who, op, args, result):
        if self.mode == "record":
            self.calls.append({"k": kind, "p": who, "op": op, "args": jsonable(args), "r": jsonable(result)})
            return result
        e = self.calls[self.i]
        self.i += 1
        assert (e["k"], e["p"], e["op"]) == (kind, who, op), (e, kind, who, op)
        self.n_calls += 1
        mine = jsonable(result)
        ref_r = e["r"]
        if op in ("sounds", "scoreboard", "loops") and isinstance(ref_r, list) and isinstance(mine, list):
            # CedarDB does not keep a view's ORDER BY under SELECT * FROM view (the scoreboard came
            # back 2, 1, 3, 4): rows compared in a canonical order
            # event ids follow insert order, which differs within a tic (compared as a set, as the
            # phase-1 replay compares sound_events without event_id)
            ref_r, mine = sorted(ref_r, key=str), sorted(mine, key=str)
        if not same(ref_r, mine):
            self.bad.append((self.i, who, op, e["args"], e["r"], mine))
            if len(self.bad) <= 12:
                print(f"  call {self.i} {who} {op}{tuple(e['args'])}: ref={str(e['r'])[:160]} ora={str(mine)[:160]}",
                      flush=True)
        return e["r"]

    def own(self, op, *args):
        r = getattr(self.drv, op)(*args)
        if op == "start":
            r = {str(k): v for k, v in r.items()}
        res = self.entry("own", None, op, list(args), r)
        if op == "start":
            res = {int(k): v for k, v in res.items()}
        return res

    def ply(self, p, op, *args):
        if self.mode == "replay":
            e = self.calls[self.i]
            assert (e["k"], e["p"], e["op"]) == ("ply", p, op), (e, p, op)
            args = tuple(e["args"])
        if op in ("frame", "automap"):
            img = self.drv.call(p, op, args, self.ctx)
            kind = "frames" if op == "frame" else "automap"
            n = len(self.calls) if self.mode == "record" else self.i
            fname = f"{kind}/{n:06d}.rgb.z"
            if self.mode == "record":
                if img is not None:
                    (self.out / fname).write_bytes(zlib.compress(img.tobytes(), 6))
                return self.entry("ply", p, op, list(args), fname if img is not None else None)
            e = self.calls[self.i]
            self.i += 1
            ref = e["r"]
            if op == "frame":
                self.n_frames += 1
            else:
                self.n_auto += 1
            if ref is None or img is None:
                ok = ref is None and img is None
                diff = "missing"
            else:
                refi = np.frombuffer(zlib.decompress((self.out / ref).read_bytes()), np.uint8).reshape(200, 320, 3)
                diff = int((refi != img).any(axis=2).sum())
                ok = diff == 0
                if not ok:
                    dump = HERE / "out" / "p5" / "frames"
                    dump.mkdir(parents=True, exist_ok=True)
                    np.save(dump / f"{op}_{self.i}_{p}.npy", np.stack([refi, img]))
            if not ok:
                if op == "frame":
                    self.bad_frames += 1
                else:
                    self.bad_auto += 1
                if self.bad_frames + self.bad_auto <= 8:
                    print(f"  {op} {p}{tuple(args)} call {self.i}: {diff} pixels differ", flush=True)
            return ref
        return self.entry("ply", p, op, list(args), self.drv.call(p, op, args, self.ctx))

    def snap(self, seg, tic, map_id):
        import record_game_reference as rgr
        if self.mode == "record":
            if tic == 0:
                if self.recorder is not None:
                    self.write_seg(seg - 1)
                self.recorder = rgr.Recorder(self.drv.o, map_id, tables=MP_TABLES, exclude=mp_lib.TIME_COLS)
            self.recorder.snapshot(tic)
            self.calls.append({"k": "snap", "seg": seg, "tic": tic, "map": map_id})
            return
        e = self.calls[self.i]
        self.i += 1
        assert e["k"] == "snap" and (e["seg"], e["tic"]) == (seg, tic), (e, seg, tic)
        self.check_tables(seg, tic, map_id)

    def write_seg(self, seg):
        d = self.out / f"seg{seg}"
        self.recorder.write(d)
        (d / "tics.json").write_text("[]")     # the Reference reader of run_game_correctness wants these
        (d / "run.json").write_text("{}")

    def check_tables(self, seg, tic, map_id):
        import run_game_correctness as rgc
        if tic == 0:
            self.ref = rgc.Reference(self.out / f"seg{seg}")
            for t, by in self.ref.data.items():   # role names: lower case on CedarDB, upper case on Oracle
                cols = self.ref.cols[t]
                ri = [i for i, c in enumerate(cols) if c in ROLE_COLS]
                if ri:
                    for k, rows in by.items():
                        by[k] = [tuple(v.upper() if i in ri and isinstance(v, str) else v for i, v in enumerate(r))
                                 for r in rows]
                    if t in self.ref.base:
                        pass
        cur = self.drv.o
        for t in self.ref.changes:
            if tic == 0 and t == "tic_trace":
                continue
            msg = rgc.compare_table(self.ref.rows(t, tic), rgc.fetch_oracle(cur, t, self.ref.cols[t], map_id),
                                    self.ref.cols[t], self.ref.keys[t])
            if msg:
                self.bad.append((f"seg{seg} tic {tic}", t, msg))
                if len(self.bad) <= 12:
                    print(f"  seg{seg} tic {tic} {t}: {msg}", flush=True)
        self.n_snaps = getattr(self, "n_snaps", 0) + 1

    # ------------------------------------------------------------------ the script
    def run(self):
        rec = self.mode == "record"
        players = self.own("start")
        map_id, skill = CFG["map_id"], CFG["skill"]
        self.snap(1, 0, map_id)
        self.own("globals")
        seated = {}            # player -> slot
        waiting = set()
        bots = {}
        left = set()

        def seat(p, r):
            if r is not None and r >= 0:
                s = self.ply(p, "slot")
                seated[p] = s
                waiting.discard(p)
                bots.setdefault(p, mp_lib.Bot(s, r, CFG["seed"], 1.0))
            else:
                waiting.add(p)

        def world_tic(tic, map_id, seg):
            nonlocal players
            # scheduled joins (seg 1) and the queue
            if seg == 1:
                if tic == 1:
                    seat("apx_p1", self.ply("apx_p1", "join"))
                    self.ply("apx_p1", "set_name", "alice")
                    seat("apx_p2", self.ply("apx_p2", "join"))
                if tic == 3:
                    seat("apx_p3", self.ply("apx_p3", "join"))
                if tic == 6:
                    seat("apx_p4", self.ply("apx_p4", "join"))
                if tic == 60:
                    self.ply("apx_p2", "set_name", "Bob-2!")
                if tic == LEAVE_TIC:
                    # apx_p3 goes quiet: its slot is handed back by the reaper
                    self.own("force_idle", "apx_p3")
                    self.own("reap", map_id, 5)
                    seated.pop("apx_p3", None)
                    left.add("apx_p3")
            # the lobby: apx_p5 asks every tic from tic 8 until it has a seat; a reaped apx_p3 asks
            # right away and then every 5 tics (well inside the 5-second waiter window)
            if seg == 1 and tic >= 8 and "apx_p5" not in seated:
                seat("apx_p5", self.ply("apx_p5", "join"))
            if "apx_p3" in left and "apx_p3" not in seated and (tic % 5 == 0 or (seg == 1 and tic == LEAVE_TIC)):
                seat("apx_p3", self.ply("apx_p3", "join"))
            # inputs (the bots decide from the state before the tic; the replay sends the logged ones)
            st = owned = None
            if rec:
                st, owned = self.drv.bot_state(map_id)
            for p in sorted(seated, key=lambda q: seated[q]):
                s = seated[p]
                cmd = None
                if rec:
                    me = st[s]
                    others = [v for k, v in st.items() if k != s and v["held"]]
                    cmd = list(bots[p].command(tic, me, others, owned.get(me["pid"], set())))
                self.ply(p, "input", *(cmd or [None] * 7))
            done = self.own("tic", map_id, skill, players)
            self.snap(seg, tic, map_id)
            for p in sorted(seated, key=lambda q: seated[q]):
                self.ply(p, "camera", 1.0)
                if tic % FRAME_EVERY == 0:
                    self.ply(p, "frame", map_id, seated[p])
                self.ply(p, "snapshot")
                self.ply(p, "player_state")
                self.ply(p, "sounds")
            if tic % 25 == 0:
                for p in sorted(seated, key=lambda q: seated[q]):
                    self.ply(p, "scoreboard")
                    self.ply(p, "match")
                    self.ply(p, "loops")
                    self.ply(p, "weapon_slot", 2)
                    self.ply(p, "weapon_cycle", 1)
                    self.ply(p, "weapon_cycle", -1)
                self.ply(sorted(seated)[0], "things_live", map_id)
                for p in sorted(waiting):
                    self.ply(p, "match")
                self.own("globals")
            if tic in (100, 101, 102, 103, 104, 105) and "apx_p1" in seated:
                op = {101: ("automap_zoom", 1.5), 102: ("automap_pan", 64.0, -32.0), 103: ("automap_toggle", "grid"),
                      104: ("automap_fit",), 105: ("automap_toggle", "follow")}.get(tic)
                if op:
                    self.ply("apx_p1", *op)
                self.ply("apx_p1", "automap")
            if tic == 106 and "apx_p2" in seated:
                self.ply("apx_p2", "automap_toggle", "cheat")
                self.ply("apx_p2", "automap")
            return done

        t0 = time.perf_counter()
        tic = 0
        while True:
            tic += 1
            done = world_tic(tic, map_id, 1)
            if tic % 100 == 0:
                print(f"seg1 tic {tic} ({time.perf_counter() - t0:.0f}s)", flush=True)
            if done is True or tic >= CFG["timer"] + 50:
                break
        print(f"E1M1 ended at tic {tic} (level done: {done})", flush=True)
        self.own("intermission")
        self.own("globals")
        for p in sorted(seated, key=lambda q: seated[q]):
            self.ply(p, "match")
            self.ply(p, "join")
            self.ply(p, "input", 1.0, 0.0, False, 5.0, True, None, False)
            self.ply(p, "camera", 1.0)
        map_id = self.own("rotate")
        players = {int(k): v for k, v in self.own_players(map_id).items()}
        self.snap(2, 0, map_id)
        self.own("globals")
        for p in sorted(seated, key=lambda q: seated[q]):
            s = self.ply(p, "slot")
            seated[p] = s
            self.ply(p, "match")
        bots = {p: mp_lib.Bot(seated[p], players[seated[p]], CFG["seed"] + 1, 1.0) for p in seated}
        for t in range(1, SEG2_TICS + 1):
            world_tic(t, map_id, 2)
            if t % 100 == 0:
                print(f"seg2 tic {t} ({time.perf_counter() - t0:.0f}s)", flush=True)
        if rec:
            self.write_seg(2)
            (self.out / "calls.json").write_text(json.dumps(self.calls))
            (self.out / "run.json").write_text(json.dumps({"config": CFG, "seg1_tics": tic, "seg2_tics": SEG2_TICS,
                                                           "players": PLAYERS, "frame_every": FRAME_EVERY}))

    def own_players(self, map_id):
        r = {str(k): v for k, v in self.drv.mp_players(map_id).items()}
        return self.entry("own", None, "mp_players", [map_id], r)


MP_TABLES = None


def main():
    global MP_TABLES
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=("record", "replay"))
    ap.add_argument("--out", type=Path, default=OUT)
    a = ap.parse_args()
    import record_game_reference as rgr
    MP_TABLES = dict(rgr.TABLES)
    MP_TABLES.update({"mp_match": ("id",), "mp_join_requests": ("slot",), "mp_inputs": ("seq",)})
    if a.mode == "record":
        (a.out / "frames").mkdir(parents=True, exist_ok=True)
        (a.out / "automap").mkdir(parents=True, exist_ok=True)
        drv = Cedar()
    else:
        drv = Oracle()
    drv.setup()
    s = Session(drv, a.mode, a.out)
    t0 = time.perf_counter()
    try:
        s.run()
    finally:
        drv.cleanup()
    if a.mode == "record":
        print(f"recorded {len(s.calls)} calls in {time.perf_counter() - t0:.0f}s -> {a.out}")
        return 0
    ok = not s.bad and s.bad_frames == 0 and s.bad_auto == 0
    print(f"replay: {s.n_calls} calls, {getattr(s, 'n_snaps', 0)} table snapshots, "
          f"{len([b for b in s.bad if isinstance(b[0], int)])} calls differ, "
          f"{len([b for b in s.bad if not isinstance(b[0], int)])} table differences; frames "
          f"{s.n_frames - s.bad_frames}/{s.n_frames} pixel-exact, automap {s.n_auto - s.bad_auto}/{s.n_auto}; "
          f"{time.perf_counter() - t0:.0f}s")
    print("API REPLAY EQUAL" if ok else "API REPLAY DIFFERS")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
