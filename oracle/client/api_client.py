#!/usr/bin/env python3
"""The player side of the deathmatch server on Oracle: what a player client sends, as the player's
own database account (CedarDB doom_sql.py in API_MODE / prepare_api_client). No game logic and no
rendering here: every call is an api_* function or view of the game owner's schema.

    p = ApiPlayer("ALICE", "password")
    p.join()                         # -> player thing id, or -1 (lobby / between maps)
    p.step((fwd, strafe, run, turn, fire, weapon, use), alpha=1.0)   # input + camera, one round trip
    frame, pal = p.frame()           # this slot's frame view: uint8[200, 320] mapped indices + palette

A frame is read inside a READ ONLY transaction opened right after api_camera commits (step()), so
every query of the renderer sees the same committed tic; the next api_* call ends it.
"""
import os
import sys
from pathlib import Path

import numpy as np
import oracledb

sys.path.insert(0, str(Path(__file__).resolve().parent))
import oradb  # noqa: E402

OWNER = os.getenv("DOOM_ORA_OWNER", "DOOM")

STEP_SQL = """BEGIN
  :i := api_input(:f, :st, :rn, :t, :atk, :w, :u);
  :c := api_camera(:a);
  SET TRANSACTION READ ONLY;
END;"""
CAMERA_SQL = "BEGIN :c := api_camera(:a); SET TRANSACTION READ ONLY; END;"
INPUT_SQL = "BEGIN :i := api_input(:f, :st, :rn, :t, :atk, :w, :u); END;"


class ApiPlayer:
    def __init__(self, user, password, dsn=oradb.DEFAULT_DSN):
        self.user = user.upper()
        self.conn = oracledb.connect(user=user, password=password, dsn=dsn)
        self.cur = self.conn.cursor()
        for s in ("ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,'",
                  "ALTER SESSION SET SESSION_CACHED_CURSORS = 200",
                  f"ALTER SESSION SET CURRENT_SCHEMA = {OWNER}"):
            self.cur.execute(s)
        self.fcur = self.conn.cursor()
        self.fcur.arraysize = 256
        self.fcur.prefetchrows = 257
        self._ivar = self.cur.var(int)
        self._cvar = self.cur.var(int)
        self.map_id = self.slot_no = None

    def close(self):
        try:
            self.conn.close()
        except Exception:  # noqa: BLE001
            pass

    # ------------------------------------------------------------------ functions
    def _call(self, fn, *args, kind=int):
        r = self.cur.var(kind)
        binds = ", ".join(f":a{i}" for i in range(len(args)))
        self.cur.execute(f"BEGIN :r := {fn}{'(' + binds + ')' if args else ''}; END;", r=r,
                         **{f"a{i}": v for i, v in enumerate(args)})
        return r.getvalue()

    def join(self):
        return int(self._call("api_join"))

    def slot(self):
        return int(self._call("api_slot"))

    def set_name(self, name):
        return self._call("api_set_name", name)

    def weapon_slot(self, n):
        return int(self._call("api_weapon_slot", n))

    def weapon_cycle(self, step):
        return int(self._call("api_weapon_cycle", step))

    def automap_pan(self, dx, dy):
        self.cur.setinputsizes(a0=oracledb.DB_TYPE_BINARY_DOUBLE, a1=oracledb.DB_TYPE_BINARY_DOUBLE)
        return self._call("api_automap_pan", float(dx), float(dy))

    def automap_zoom(self, f):
        self.cur.setinputsizes(a0=oracledb.DB_TYPE_BINARY_DOUBLE)
        return self._call("api_automap_zoom", float(f))

    def automap_toggle(self, what):
        return self._call("api_automap_toggle", what)

    def automap_fit(self):
        return self._call("api_automap_fit")

    def _input_binds(self, cmd):
        fwd, strafe, run, turn, fire, weapon, use = cmd
        self.cur.setinputsizes(f=oracledb.DB_TYPE_BINARY_DOUBLE, st=oracledb.DB_TYPE_BINARY_DOUBLE,
                               t=oracledb.DB_TYPE_BINARY_DOUBLE, rn=oracledb.DB_TYPE_BOOLEAN,
                               atk=oracledb.DB_TYPE_BOOLEAN, u=oracledb.DB_TYPE_BOOLEAN)
        return dict(f=float(fwd), st=float(strafe), rn=bool(run), t=float(turn), atk=bool(fire),
                    w=(int(weapon) if weapon else None), u=bool(use))

    def input(self, cmd):
        self.cur.execute(INPUT_SQL, i=self._ivar, **self._input_binds(cmd))
        return self._ivar.getvalue()

    def camera(self, alpha=1.0):
        """api_camera, then a READ ONLY transaction for the frame that follows."""
        self.cur.setinputsizes(a=oracledb.DB_TYPE_BINARY_DOUBLE)
        self.cur.execute(CAMERA_SQL, c=self._cvar, a=float(alpha))
        return self._cvar.getvalue()

    def step(self, cmd, alpha=1.0):
        """api_input + api_camera + READ ONLY transaction: one round trip."""
        b = self._input_binds(cmd)
        self.cur.setinputsizes(f=oracledb.DB_TYPE_BINARY_DOUBLE, st=oracledb.DB_TYPE_BINARY_DOUBLE,
                               t=oracledb.DB_TYPE_BINARY_DOUBLE, rn=oracledb.DB_TYPE_BOOLEAN,
                               atk=oracledb.DB_TYPE_BOOLEAN, u=oracledb.DB_TYPE_BOOLEAN,
                               a=oracledb.DB_TYPE_BINARY_DOUBLE)
        self.cur.execute(STEP_SQL, i=self._ivar, c=self._cvar, a=float(alpha), **b)

    def end_read(self):
        self.conn.rollback()

    # ------------------------------------------------------------------ views
    def where(self):
        """(map_id, slot) as the server has them (api_match, api_slot)."""
        self.cur.execute("SELECT map_id FROM api_match")
        row = self.cur.fetchone()
        self.map_id = int(row[0]) if row else None
        self.slot_no = self.slot()
        return self.map_id, self.slot_no

    def frame(self, map_id=None, slot=None):
        """This slot's frame (api_frame_slot<n>_m<map>): (uint8[200, 320] or None, palette)."""
        m = map_id if map_id is not None else self.map_id
        s = slot if slot is not None else self.slot_no
        self.fcur.execute(f"SELECT y, pal, hex FROM api_frame_slot{int(s)}_m{int(m)}")
        rows = self.fcur.fetchall()
        if len(rows) != 200:
            return None, None
        frame = np.empty((200, 320), np.uint8)
        for y, _p, hx in rows:
            frame[int(y)] = np.frombuffer(bytes.fromhex(hx), np.uint8)
        return frame, int(rows[0][1])

    def frame_rows(self, map_id, slot):
        self.fcur.execute(f"SELECT y, pal, hex FROM api_frame_slot{int(slot)}_m{int(map_id)}")
        return self.fcur.fetchall()

    def automap(self):
        self.fcur.execute("SELECT y, pal, hex FROM TABLE(api_automap())")
        rows = self.fcur.fetchall()
        if len(rows) != 200:
            return None
        frame = np.empty((200, 320), np.uint8)
        for y, _p, hx in rows:
            frame[int(y)] = np.frombuffer(bytes.fromhex(hx), np.uint8)
        return frame

    def query(self, sql, **binds):
        self.cur.execute(sql, **binds)
        return self.cur.fetchall()


def palettes(cur):
    """api_palettes as a lookup table [pal][idx] -> (r, g, b)."""
    cur.execute("SELECT pal, idx, r, g, b FROM api_palettes")
    lut = np.zeros((14, 256, 3), np.uint8)
    for pal, idx, r, g, b in cur.fetchall():
        lut[int(pal), int(idx)] = (r, g, b)
    return lut
