#!/usr/bin/env python3
"""The browser front door for SQL Doom on Oracle: serves oracle/client/web/ and bridges each
browser's WebSocket to Oracle sessions of that browser's OWN player account.

CedarDB's doom_web.py is a byte pipe: the page speaks the Postgres wire protocol (pgwire.js) and
authenticates itself. Oracle's protocol (TTC over Net8) has no browser implementation, so this
bridge terminates the WebSocket instead and speaks to Oracle with python-oracledb (thin, asyncio),
logged in with the credentials the browser sends -- the bridge has no account of its own and no
credentials but those (and, optionally, a file of provisioned guest PLAYER accounts it leases out,
CedarDB's DOOM_GUESTS_FILE). What it forwards is a closed vocabulary: a fixed table of named
statements, every one an api_* function or view (or sound_assets), with typed parameters. No SQL
text crosses the WebSocket. Behind that, Oracle's grants are the real boundary: a player account
holds only DOOM_PLAYER (EXECUTE on api_*, READ on the api_* views), so even a bridge bug could not
reach a table.

    python oracle/client/doom_web.py                 # http://127.0.0.1:8080/
    DOOM_WEB_PORT=8080 DOOM_WEB_ADDRESS=0.0.0.0 DOOM_ORA_DSN=host:1521/FREEPDB1 python oracle/client/doom_web.py
    DOOM_GUESTS_FILE=guests.txt ...                  # lines "USER PASSWORD" (accounts.py player ...)

Protocol (JSON text frames; frames as binary):
  -> {"op": "login", "user": U, "password": P} | {"op": "login", "guest": true}
  <- {"op": "login", "ok": true, "user": U} | {"op": "login", "ok": false, "error": ...}
  -> {"id": n, "run": [{"name": "join"}, {"name": "events", "params": [42]}, ...]}
  <- {"id": n, "results": [{"rows": [[...], ...]} | {"value": v} | {"error": msg}, ...]}
  -> {"id": n, "frame": {"alpha": a, "automap": bool, "am": [{"name": "am_zoom", "params": [1.25]}]}}
  <- binary: u32 id | u8 kind (0 view, 1 automap, 255 none) | u8 palette | u8 delta | 64,000 indices
     (delta=1: XOR with the previous binary frame of the same kind on this connection; every message is
     permessage-deflate compressed, so unchanged pixels cost almost nothing)

Each browser gets two sessions: one for its tic traffic (input, own state, sounds), one for frames
(api_camera(alpha) + SET TRANSACTION READ ONLY in one round trip, then the slot's frame view), so a
20 ms frame never delays the 35 Hz input.
"""
import asyncio
import base64
import json
import os
import struct
import sys
import time
from pathlib import Path

import oracledb
from websockets.asyncio.server import serve
from websockets.datastructures import Headers
from websockets.http11 import Response

HERE = Path(__file__).resolve().parent
WEB_ROOT = HERE / "web"
PORT = int(os.getenv("DOOM_WEB_PORT", "8080"))
ADDRESS = os.getenv("DOOM_WEB_ADDRESS", "127.0.0.1")
DSN = os.getenv("DOOM_ORA_DSN", "localhost:1521/FREEPDB1")
OWNER = os.getenv("DOOM_ORA_OWNER", "DOOM")
MAX_FPS = int(os.getenv("DOOM_MAX_FPS", "35"))
GUESTS_FILE = os.getenv("DOOM_GUESTS_FILE", "")
GUEST_COOLDOWN = float(os.getenv("DOOM_GUEST_COOLDOWN", "8"))
CONTENT_TYPES = {".html": "text/html; charset=utf-8", ".js": "application/javascript; charset=utf-8",
                 ".css": "text/css; charset=utf-8", ".json": "application/json", ".png": "image/png",
                 ".ico": "image/x-icon", ".svg": "image/svg+xml"}

F, I, B, S = "float", "int", "bool", "text"
# name -> (kind, statement, parameter types). kind: "rows" (a query), "fn" (a function's value).
# Every statement reads an api_* view or sound_assets, or calls an api_* function: the whole
# vocabulary a browser can use (web/app.js, the smoke test, the bots).
STATEMENTS = {
    "palettes": ("rows", "SELECT pal, idx, r, g, b FROM api_palettes", ()),
    "sounds_all": ("rows", "SELECT name, wav_data FROM sound_assets", ()),
    "join": ("fn", "api_join", ()),
    "slot": ("fn", "api_slot", ()),
    "setname": ("fn", "api_set_name", (S,)),
    "score": ("rows", "SELECT slot, role_name, connected, frags, health, alive, login FROM api_scoreboard "
                      "ORDER BY slot", ()),
    "seats": ("rows", "SELECT SUM(CASE WHEN connected THEN 1 ELSE 0 END), COUNT(*) FROM api_scoreboard", ()),
    "match": ("rows", "SELECT state, map_name, level_tics, timer_tics, intermission_seconds, next_map, map_id, "
                      "waiting, ahead_of_me, hold_seconds FROM api_match", ()),
    "me": ("rows", "SELECT alive, health, frags, position_x, position_y, view_angle, ammo_bullets, ammo_shells, "
                   "ammo_rockets FROM api_player_state", ()),
    "input": ("fn", "api_input", (F, F, B, F, B, I, B)),
    "events": ("rows", "SELECT event_id, sound_name, volume, pan FROM api_sound_events WHERE event_id > :1 "
                       "ORDER BY event_id", (I,)),
    "events_max": ("rows", "SELECT NVL(MAX(event_id), 0) FROM api_sound_events", ()),
    "loops": ("rows", "SELECT loop_key, sound_name, volume, pan FROM api_sound_loops", ()),
    "music": ("rows", "SELECT name, audio_data, audio_format FROM api_stage_music", ()),
    "weapon_slot": ("fn", "api_weapon_slot", (I,)),
    "weapon_cycle": ("fn", "api_weapon_cycle", (I,)),
    "map_geo": ("rows", "SELECT x1, y1, x2, y2, solid FROM api_map_geometry", ()),
    "walls": ("rows", "SELECT x1, y1, x2, y2 FROM api_map_lines WHERE kind IN ('wall', 'special')", ()),
    "live": ("rows", "SELECT kind, name, x, y, angle, alive, thing_id FROM api_things_live WHERE map_id = :1", (I,)),
    # the bots (tests/bots.mjs)
    "bot_me": ("rows", "SELECT alive, position_x, position_y, view_angle, frags, ammo_bullets, ammo_shells, "
                       "ammo_rockets FROM api_player_state", ()),
    "bot_live": ("rows", "SELECT thing_id, kind, x, y FROM api_things_live WHERE map_id = :1 AND alive", (I,)),
    "bot_match": ("rows", "SELECT state, map_id, map_name, waiting FROM api_match", ()),
    "am_pan": ("fn", "api_automap_pan", (F, F)),
    "am_zoom": ("fn", "api_automap_zoom", (F,)),
    "am_toggle": ("fn", "api_automap_toggle", (S,)),
    "am_fit": ("fn", "api_automap_fit", ()),
}
DB_TYPES = {F: oracledb.DB_TYPE_BINARY_DOUBLE, I: oracledb.DB_TYPE_NUMBER, B: oracledb.DB_TYPE_BOOLEAN,
            S: oracledb.DB_TYPE_VARCHAR}


def log(msg):
    print(f"[web {time.strftime('%H:%M:%S')}] {msg}", flush=True)


class GuestPool:
    """Provisioned guest PLAYER accounts (accounts.py player ...), leased one per connection."""

    def __init__(self, path):
        self.seats, self.leased, self.cooldown = {}, set(), {}
        for line in Path(path).read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                user, password = line.split(None, 1)
                self.seats[user] = password

    def lease(self):
        now = time.time()
        for user in sorted(self.seats):
            if user not in self.leased and self.cooldown.get(user, 0) <= now:
                self.leased.add(user)
                return user, self.seats[user]
        return None

    def release(self, user):
        self.leased.discard(user)
        self.cooldown[user] = time.time() + GUEST_COOLDOWN

    def free(self):
        now = time.time()
        return sum(1 for u in self.seats if u not in self.leased and self.cooldown.get(u, 0) <= now)


GUESTS = GuestPool(GUESTS_FILE) if GUESTS_FILE and Path(GUESTS_FILE).is_file() else None


def http(status, body, ctype="text/plain; charset=utf-8", extra=()):
    reason = {200: "OK", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"}[status]
    h = Headers([("Content-Type", ctype), ("Content-Length", str(len(body))), ("Cache-Control", "no-store"),
                 *extra])
    return Response(status, reason, h, body)


def process_request(connection, request):
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return None if request.path.split("?")[0] == "/ws" else http(404, b"no such endpoint")
    path = request.path.split("?")[0]
    if path in ("", "/"):
        path = "/index.html"
    if path == "/config.json":
        body = json.dumps({"max_fps": MAX_FPS, "guests": len(GUESTS.seats) if GUESTS else 0,
                           "guests_free": GUESTS.free() if GUESTS else 0, "database": "oracle"}).encode()
        return http(200, body, "application/json", (("Access-Control-Allow-Origin", "*"),))
    target = (WEB_ROOT / path.lstrip("/")).resolve()
    if WEB_ROOT not in target.parents or not target.is_file():
        return http(404, b"not found")
    return http(200, target.read_bytes(), CONTENT_TYPES.get(target.suffix, "application/octet-stream"))


def jsonable(v):
    if isinstance(v, (bytes, bytearray)):
        return {"b64": base64.b64encode(v).decode()}
    if isinstance(v, float) and v != v:
        return None
    return v


class Player:
    """One browser: two Oracle sessions of its own account."""

    def __init__(self, ws, user):
        self.ws, self.user = ws, user
        self.main = self.frame = None
        self.prev = {}
        self.slot = self.map_id = None
        self.frames = self.requests = 0
        self.raw_out = 0

    async def connect(self, user, password):
        async def one():
            c = await oracledb.connect_async(user=user, password=password, dsn=DSN)
            c.autocommit = False
            async with c.cursor() as cur:
                for s in ("ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,'",
                          "ALTER SESSION SET SESSION_CACHED_CURSORS = 200",
                          "ALTER SESSION SET COMMIT_WAIT = 'NOWAIT'",
                          f"ALTER SESSION SET CURRENT_SCHEMA = {OWNER}"):
                    await cur.execute(s)
            return c
        self.main, self.frame = await asyncio.gather(one(), one())

    async def close(self):
        for c in (self.main, self.frame):
            if c is not None:
                try:
                    await c.close()
                except Exception:  # noqa: BLE001
                    pass

    @staticmethod
    def _bind(types, params):
        params = list(params or [])
        if len(params) != len(types):
            raise ValueError(f"expected {len(types)} parameters")
        out = []
        for t, v in zip(types, params):
            if v is None:
                out.append(None)
            elif t == F:
                out.append(float(v))
            elif t == I:
                out.append(int(v))
            elif t == B:
                out.append(bool(v))
            else:
                out.append(str(v)[:64])
        return out

    async def statement(self, conn, name, params):
        if name not in STATEMENTS:
            raise ValueError(f"unknown statement {name!r}")
        kind, text, types = STATEMENTS[name]
        args = self._bind(types, params)
        async with conn.cursor() as cur:
            if kind == "fn":
                binds = ", ".join(f":a{i}" for i in range(len(args)))
                call = f"BEGIN :r := {text}{'(' + binds + ')' if args else ''}; END;"
                r = cur.var(oracledb.DB_TYPE_NUMBER if text != "api_set_name" else oracledb.DB_TYPE_VARCHAR)
                cur.setinputsizes(**{f"a{i}": DB_TYPES[t] for i, t in enumerate(types)})
                await cur.execute(call, r=r, **{f"a{i}": v for i, v in enumerate(args)})
                v = r.getvalue()
                if isinstance(v, float) and v.is_integer():
                    v = int(v)
                return {"value": v}
            await cur.execute(text, args)
            rows = await cur.fetchall()
            out = []
            for row in rows:
                vals = []
                for v in row:
                    if isinstance(v, oracledb.AsyncLOB):
                        v = await v.read()
                    vals.append(jsonable(v))
                out.append(vals)
            await conn.rollback()         # end the read: no transaction left open between calls
            return {"rows": out}

    async def run(self, batch):
        res = []
        for item in batch:
            try:
                res.append(await self.statement(self.main, item.get("name"), item.get("params")))
            except Exception as exc:  # noqa: BLE001
                try:
                    await self.main.rollback()
                except Exception:  # noqa: BLE001
                    pass
                res.append({"error": str(exc).splitlines()[0]})
        return res

    async def where(self):
        async with self.frame.cursor() as cur:
            r = cur.var(oracledb.DB_TYPE_NUMBER)
            await cur.execute("BEGIN :r := api_slot; END;", r=r)
            self.slot = int(r.getvalue())
            await cur.execute("SELECT map_id FROM api_match")
            row = await cur.fetchone()
            self.map_id = int(row[0]) if row else None
        await self.frame.rollback()

    async def render(self, req):
        """api_camera(alpha) + the slot's frame view (or the automap): (kind, pal, indices)."""
        alpha = min(1.0, max(0.0, float(req.get("alpha", 1.0))))
        for op in req.get("am") or []:
            if op.get("name") in ("am_pan", "am_zoom", "am_toggle", "am_fit"):
                await self.statement(self.frame, op["name"], op.get("params"))
        async with self.frame.cursor() as cur:
            cur.arraysize = 256
            cur.prefetchrows = 257
            c = cur.var(oracledb.DB_TYPE_NUMBER)
            cur.setinputsizes(a=oracledb.DB_TYPE_BINARY_DOUBLE)
            await cur.execute("BEGIN :c := api_camera(:a); SET TRANSACTION READ ONLY; END;", c=c, a=alpha)
            if req.get("automap"):
                kind = 1
                await cur.execute("SELECT y, pal, hex FROM TABLE(api_automap())")
            else:
                kind = 0
                if self.slot is None or self.slot < 0 or self.map_id is None:
                    await self.frame.rollback()
                    await self.where()
                    if self.slot is None or self.slot < 0 or self.map_id is None:
                        return 255, 0, None
                await cur.execute(f"SELECT y, pal, hex FROM api_frame_slot{int(self.slot)}_m{int(self.map_id)}")
            rows = await cur.fetchall()
        await self.frame.rollback()
        if len(rows) != 200:
            self.slot = None            # slot lost or the map changed: look again next time
            return 255, 0, None
        rows.sort(key=lambda r: int(r[0]))
        return kind, int(rows[0][1] or 0), bytes.fromhex("".join(r[2] for r in rows))

    async def send_frame(self, rid, req):
        try:
            kind, pal, data = await self.render(req)
        except Exception as exc:  # noqa: BLE001
            try:
                await self.frame.rollback()
            except Exception:  # noqa: BLE001
                pass
            self.slot = None
            await self.ws.send(json.dumps({"id": rid, "error": str(exc).splitlines()[0]}))
            return
        if data is None:
            await self.ws.send(struct.pack("<IBBB", rid, 255, 0, 0))
            return
        prev = self.prev.get(kind)
        self.prev[kind] = data
        delta = 0
        if prev is not None and len(prev) == len(data):
            data = (int.from_bytes(data, "little") ^ int.from_bytes(prev, "little")).to_bytes(len(data), "little")
            delta = 1
        self.frames += 1
        self.raw_out += len(data)
        await self.ws.send(struct.pack("<IBBB", rid, kind, pal, delta) + data)


async def handler(ws):
    peer = ws.remote_address[0] if ws.remote_address else "?"
    guest = None
    player = None
    try:
        hello = json.loads(await asyncio.wait_for(ws.recv(), 30))
        if hello.get("op") != "login":
            await ws.send(json.dumps({"op": "login", "ok": False, "error": "login first"}))
            return
        if hello.get("guest"):
            guest = GUESTS.lease() if GUESTS else None
            if guest is None:
                await ws.send(json.dumps({"op": "login", "ok": False, "error": "no guest seats are configured"
                                          if not GUESTS else "all guest seats are taken; try again in a minute"}))
                return
            user, password = guest
        else:
            user, password = str(hello.get("user", "")), str(hello.get("password", ""))
        player = Player(ws, user.upper())
        try:
            await player.connect(user, password)
        except Exception as exc:  # noqa: BLE001
            await ws.send(json.dumps({"op": "login", "ok": False, "error": str(exc).splitlines()[0]}))
            return
        await ws.send(json.dumps({"op": "login", "ok": True, "user": player.user}))
        log(f"{peer} signed in as {player.user}" + (" (guest)" if guest else ""))
        started = time.perf_counter()
        frame_lock = asyncio.Lock()
        main_lock = asyncio.Lock()
        tasks = set()

        async def do_run(rid, batch):
            async with main_lock:
                res = await player.run(batch)
            await ws.send(json.dumps({"id": rid, "results": res}))

        async def do_frame(rid, req):
            async with frame_lock:
                await player.send_frame(rid, req)

        async for msg in ws:
            if isinstance(msg, bytes):
                continue
            m = json.loads(msg)
            rid = int(m.get("id", 0))
            if "run" in m:
                t = asyncio.create_task(do_run(rid, m["run"]))
            elif "frame" in m:
                t = asyncio.create_task(do_frame(rid, m["frame"]))
            else:
                continue
            player.requests += 1
            tasks.add(t)
            t.add_done_callback(tasks.discard)
        for t in list(tasks):
            t.cancel()
        log(f"{peer} {player.user} left after {time.perf_counter() - started:.0f} s: {player.frames} frames, "
            f"{player.raw_out / 1e6:.1f} MB before deflate, {player.requests} requests")
    except (asyncio.TimeoutError, json.JSONDecodeError):
        pass
    except Exception as exc:  # noqa: BLE001
        if "ConnectionClosed" not in type(exc).__name__:
            log(f"{peer} error: {exc}")
    finally:
        if player is not None:
            await player.close()
        if guest:
            GUESTS.release(guest[0])


async def main():
    if not (WEB_ROOT / "index.html").is_file():
        raise SystemExit(f"no page to serve at {WEB_ROOT}")
    async with serve(handler, ADDRESS, PORT, process_request=process_request, compression="deflate",
                     max_size=1 << 20, ping_interval=20, ping_timeout=45) as server:
        log(f"serving {WEB_ROOT} on http://{ADDRESS}:{PORT}/ ; Oracle {DSN}")
        if GUESTS:
            log(f"{len(GUESTS.seats)} guest seats from {GUESTS_FILE}")
        log("players open the page and sign in with the account accounts.py gave them")
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
