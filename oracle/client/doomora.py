"""Thin Oracle client for the SQL Doom renderers.

The client only: binds the frame state, executes one prepared renderer cursor, fetches the
framebuffer, and decodes the transport encoding into a (200, 320) uint8 palette-index array.
All rendering (visibility, projection, rasterisation, texturing, lighting, compositing) happens
in the database.

Renderer SQL files are single SELECT statements using these binds:
    :tic                game-state snapshot id (st_* tables)      -- dynamic world state
    :map_id :player_id :skill
    :px :py :pz :pangle camera pose (map units, eye z, degrees)

Transport encodings (first line of the .sql file: `-- @output <name>`):
    hexrows   rows (y, pal, hex)    -- hex = 640 hex chars = 320 palette indices, one row per y
    packed    rows (y, pal, n0..)   -- see decode_packed: 15 pixels per NUMBER, base 256
    nchar     rows (y, pal, s)      -- NVARCHAR2: char U+0100+i is palette index i
"""
import os
import re
import time
from pathlib import Path

import numpy as np
import oracledb

ROOT = Path(__file__).resolve().parents[1]
SQL = ROOT / "sql"
W, H = 320, 200

DSN = os.environ.get("DOOM_DSN", "localhost:1521/FREEPDB1")
USER = os.environ.get("DOOM_USER", "doom")
PASSWORD = os.environ.get("DOOM_PASSWORD", "doom")


def connect():
    conn = oracledb.connect(user=USER, password=PASSWORD, dsn=DSN)
    conn.autocommit = False
    return conn


def load_sql(name):
    text = (SQL / name).read_text()
    m = re.search(r"--\s*@output\s+(\w+)", text)
    enc = m.group(1) if m else "hexrows"
    body = text.strip().rstrip(";").rstrip("/").strip()
    return body, enc


class Renderer:
    """One prepared renderer cursor, re-executed with new binds every frame."""

    def __init__(self, conn, sql_file, arraysize=256):
        self.conn = conn
        self.name = sql_file
        self.sql, self.encoding = load_sql(sql_file)
        self.cur = conn.cursor()
        self.cur.arraysize = arraysize
        self.cur.prefetchrows = arraysize + 1
        self.last = {}

    def binds(self, tic, pose, map_id=1, player_id=157, skill=2):
        x, y, z, a = pose
        return {"tic": int(tic), "map_id": int(map_id), "player_id": int(player_id),
                "skill": int(skill), "px": float(x), "py": float(y), "pz": float(z), "pangle": float(a)}

    def render(self, tic, pose, **kw):
        """Return (frame uint8[200,320], pal) and record timings in self.last (ms)."""
        b = self.binds(tic, pose, **kw)
        t0 = time.perf_counter()
        self.cur.execute(self.sql, b)
        t1 = time.perf_counter()
        rows = self.cur.fetchall()
        t2 = time.perf_counter()
        frame, pal = DECODERS[self.encoding](rows)
        t3 = time.perf_counter()
        self.last = {"exec_ms": (t1 - t0) * 1e3, "fetch_ms": (t2 - t1) * 1e3,
                     "decode_ms": (t3 - t2) * 1e3, "total_ms": (t3 - t0) * 1e3, "rows": len(rows)}
        return frame, pal



class SplitRenderer:
    """One frame rendered by two sessions in parallel: session A renders screen columns
    0..split-1, session B columns split..319 (render_hybrid_split.sql, the same exact renderer
    restricted to a column range); the client joins the two halves of each hex row. Oracle Free
    has 2 CPUs and no parallel query, so this is how one frame uses both. The split column (a
    multiple of 16) follows the measured per-half time of the previous frame (load balance only:
    nothing of a frame is reused)."""

    def __init__(self, conn_a, conn_b, sql_file="render_hybrid_split.sql", split=160, adaptive=True, sql=None):
        import concurrent.futures
        self.sql, self.encoding = (sql, "hexrows") if sql else load_sql(sql_file)
        self.name = sql_file
        self.curs = []
        for c in (conn_a, conn_b):
            cur = c.cursor(); cur.arraysize = 256; cur.prefetchrows = 257
            self.curs.append(cur)
        self.split, self.adaptive = split, adaptive
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        self.last = {}

    binds = Renderer.binds

    def _half(self, k, b, x0, x1):
        t0 = time.perf_counter()
        cur = self.curs[k]
        cur.execute(self.sql, dict(b, x0=x0, x1=x1))
        rows = cur.fetchall()
        return rows, (time.perf_counter() - t0) * 1e3

    def render_binds(self, b):
        s = self.split
        t0 = time.perf_counter()
        fut = self.pool.submit(self._half, 1, b, s, 319)
        rows_a, ta = self._half(0, b, 0, s - 1)
        rows_b, tb = fut.result()
        t1 = time.perf_counter()
        frame = np.empty((H, W), np.uint8)
        pal = 0
        for (y, p, ha), (_, _, hb) in zip(rows_a, rows_b):
            frame[int(y)] = np.frombuffer(bytes.fromhex(ha + hb), np.uint8)
            pal = int(p or 0)
        t2 = time.perf_counter()
        self.last = {"exec_ms": (t1 - t0) * 1e3, "fetch_ms": 0.0, "decode_ms": (t2 - t1) * 1e3,
                     "total_ms": (t2 - t0) * 1e3, "rows": len(rows_a), "split": s,
                     "half_a_ms": ta, "half_b_ms": tb}
        if self.adaptive:   # move the split towards equal halves (at most 48 columns a frame)
            d = (ta - tb) / max(1e-6, ta + tb)
            step = max(-3, min(3, int(round(d * 10))))
            self.split = max(64, min(256, s - 16 * step))
        return frame, pal

    def render(self, tic, pose, **kw):
        return self.render_binds(self.binds(tic, pose, **kw))

def decode_hexrows(rows):
    frame = np.zeros((H, W), np.uint8)
    pal = 0
    for y, p, hx in rows:
        frame[int(y)] = np.frombuffer(bytes.fromhex(hx), np.uint8)
        pal = int(p or 0)
    return frame, pal


_NCHAR_OFF = 0x100


def decode_nchar(rows):
    frame = np.zeros((H, W), np.uint8)
    pal = 0
    for y, p, s in rows:
        frame[int(y)] = np.frombuffer(s.encode("utf-16-le"), np.uint16) - _NCHAR_OFF
        pal = int(p or 0)
    return frame, pal


PACK = 15  # pixels per NUMBER: 256**15 < 10**38


def decode_packed(rows):
    """rows: (y, pal, chunk, value) with value = sum(idx[x] * 256**(x - 15*chunk))."""
    frame = np.zeros((H, W), np.uint8)
    pal = 0
    for y, p, chunk, v in rows:
        v = int(v)
        x0 = int(chunk) * PACK
        b = v.to_bytes(PACK, "little")
        n = min(PACK, W - x0)
        frame[int(y), x0:x0 + n] = np.frombuffer(b[:n], np.uint8)
        pal = int(p or 0)
    return frame, pal


DECODERS = {"hexrows": decode_hexrows, "nchar": decode_nchar, "packed": decode_packed}


def load_poses(run=ROOT / "reference_data" / "e1m1"):
    import json
    return {p["tic"]: tuple(p["pose"]) for p in json.loads((Path(run) / "poses.json").read_text())}
