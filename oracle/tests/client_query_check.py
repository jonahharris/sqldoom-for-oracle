#!/usr/bin/env python3
"""Phase 6: the client's own queries, CedarDB vs Oracle.

The reference client (doom_client.py / doom_sql.py) issues, besides the tic and the frame, the
statements of sql/client/: sound_assets.sql, sound_events.sql, sound_loops.sql, stage_music.sql,
camera_pose.sql (the camera between two tics, by alpha), demo_header.sql, stages.sql, spawn_pose.sql,
level_stats.sql. This check runs recorded command streams on CedarDB through doom_sql.py (record) and
replays them on Oracle through client/game_api.py (replay), comparing after every tic:

  * sound events newer than the client's cursor (when the tic made sounds, as the client fetches
    them): name, volume, pan -- a tic's events as a multiset (ids are per database)
  * the sound-loop set (every tic): loop key, sound, volume, pan
  * camera_pose at alphas 0, 0.25, 0.5, 1 and two pseudo-random full-precision alphas per tic
  * every K-th tic, a frame rendered at camera_pose(random alpha): palette indices, pixel-exact
  * once per run: stage_music for every map, sound_assets (byte-equal), stages, spawn pose

    client_query_check.py cedar-music            # load music_assets/map_music into CedarDB (see below)
    client_query_check.py assets                 # sound_assets, music_assets, map_music, stage music: byte-equal
    client_query_check.py mus-fuzz [N]           # music.mus_to_midi == reference wad_loader.mus_to_midi
    client_query_check.py record [runs]          # CedarDB ground truth -> reference_data/client_queries/
    client_query_check.py replay [runs]          # Oracle vs the recording

Runs: tpc_e1m1 (the TPC-DOOM E1M1 stream, 1,200 tics) and recorded scenarios by name
(reference_data/scenarios/<name>: mods, ops, cheats, commands).

Music: freedoom1.wad ships its D_* lumps as standard MIDI files, not MUS; the reference loader
converts MUS only, so CedarDB SQLDoom loaded from this WAD has no music at all. Oracle's loader
(client/music.py) also stores MIDI lumps as they are. `cedar-music` runs the reference loader's
load_music (which finds no MUS score) and then adds the MIDI lumps to CedarDB the same way, so the
stage-music query can be compared on the same data.
"""
import argparse, hashlib, json, math, random, sys, time, zlib
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "client"))
import record_game_reference as rgr  # noqa: E402
import scenario_lib as sl  # noqa: E402
sql = rgr.sql
OUT = HERE.parent / "reference_data" / "client_queries"
WAD = HERE.parent / "wad" / "freedoom1.wad"
FIXED_ALPHAS = (0.0, 0.25, 0.5, 1.0)
DEFAULT_RUNS = ("tpc_e1m1", "tpc_chainsaw", "e1m1_lift62", "e1m2_raise58", "e1m3_stairs7", "tpc_bfg",
                "e1m2_teleport39", "smoke_e2m4")


def load_run(name):
    """(map_id, player, skill, cheats, mods, ops, commands, frame_every)"""
    if name == "tpc_e1m1":
        cmds = [c["command"] for c in json.loads((HERE / "run-e1m1-b-commands.json").read_text())]
        return 1, 157, 2, ["IDDQD", "IDKFA"], [], {}, cmds, 20
    root = HERE.parent / "reference_data" / "scenarios" / name
    run = json.loads((root / "run.json").read_text())
    tics = json.loads((root / "tics.json").read_text())
    cmds = [t["command"] for t in tics]
    return (run["map_id"], run["player_thing_id"], run["skill"], run.get("cheats", ["IDDQD", "IDKFA"]),
            run.get("mods", []), run.get("ops", {}), cmds, 50)


def alphas(name, tic):
    rnd = random.Random(f"{name}:{tic}")
    return list(FIXED_ALPHAS) + [rnd.random(), rnd.random()]


def frame_alpha(name, tic):
    return random.Random(f"{name}:frame:{tic}").random()


def digest(b):
    return None if b is None else hashlib.sha256(bytes(b)).hexdigest()


# ------------------------------------------------------------------------------- CedarDB side
class Cedar:
    def __init__(self, dsn=rgr.DEFAULT_DSN):
        import psycopg2
        import record_reference as rr
        self.psycopg2 = psycopg2
        self.conn = psycopg2.connect(dsn)
        self.conn.autocommit = True
        self.cur = self.conn.cursor()
        sql.prepare_client(self.cur)
        self.cur.execute("PREPARE ref_idx(int,int,int,float8,float8,float8,float8) AS " + rr.index_variant(self.cur))

    def start(self, m, p, sk, cheats, mods, ops0):
        self.side = sl.CedarSide(self.cur, m, p)
        self.side.apply_mods(mods)
        sql.set_screen(self.cur, "game")
        sql.enter_level(self.cur, m, p, sk)
        for c in cheats:
            sql.cheat_code(self.cur, m, p, c)
        for op in ops0:
            self.side.apply_op(op)

    def finish(self):
        self.side.revert()

    def op(self, op):
        self.side.apply_op(op)

    def tic(self, m, p, cmd):
        try:
            return sql.execute_game_tic(self.cur, m, p, tuple(cmd))
        except self.psycopg2.Error as ex:
            return "error: " + str(ex).splitlines()[0]

    def events(self, m, p, after):
        ev, _ = sql.fetch_sound_events(self.cur, m, p, after)
        return [(int(e[0]), e[1], float(e[2]), float(e[3])) for e in ev]

    def loops(self, m, p):
        sql.execute_prepared(self.cur, sql.SOUND_LOOPS_STATEMENT, (m, p))
        return [(r[0], r[1], float(r[2]), float(r[3])) for r in self.cur.fetchall()]

    def snapshot(self, m, p):
        return sql.finish_game_tic(self.cur, m, p)

    def camera(self, m, p, a):
        r = sql.camera_pose(self.cur, m, p, a)
        return None if r is None else [float(v) for v in r]

    def frame(self, m, p, sk, a):
        pose = sql.camera_pose(self.cur, m, p, a)
        self.cur.execute("EXECUTE ref_idx(%s,%s,%s,%s,%s,%s,%s)", (m, p, sk, *[float(v) for v in pose]))
        return np.frombuffer(bytes(self.cur.fetchone()[0]), np.uint8).reshape(200, 320)

    def stages(self):
        return [[s["map_id"], s["label"], s["player_thing_id"]] for s in sql.load_stages(self.cur)]

    def music(self, m):
        r = sql.fetch_stage_music(self.cur, m)
        return None if r is None else [r[0], digest(r[1]), digest(r[2]), r[3]]

    def assets(self):
        return {n: digest(w) for n, w in sql.fetch_sound_assets(self.cur)}


# ------------------------------------------------------------------------------- Oracle side
class Oracle:
    def __init__(self):
        import oradb, game_api
        self.ga = game_api
        self.conn = oradb.connect()
        self.cur = self.conn.cursor()
        game_api.setup_session(self.cur)
        self.rcur = self.conn.cursor()
        self.rcur.arraysize = 256
        self.rcur.prefetchrows = 257

    def start(self, m, p, sk, cheats, mods, ops0):
        self.side = sl.OracleSide(self.cur, m, p)
        if mods:
            self.side.apply_mods(mods)
        self.ga.level_start(self.cur, m, p, sk, cheats)
        for op in ops0:
            self.side.apply_op(op)

    def finish(self):
        self.conn.rollback()
        if self.side.undo:
            self.side.revert()

    def op(self, op):
        self.side.apply_op(op)

    def tic(self, m, p, cmd):
        try:
            due = self.ga.run_tic(self.cur, m, p, cmd)
            self.conn.commit()
            return due
        except Exception as ex:  # noqa: BLE001
            self.conn.rollback()
            return "error: " + str(ex).splitlines()[0]

    def events(self, m, p, after):
        return [(int(e[0]), e[1], float(e[2]), float(e[3])) for e in self.ga.sound_events(self.cur, m, p, after)]

    def loops(self, m, p):
        return [(r[0], r[1], float(r[2]), float(r[3])) for r in self.ga.sound_loops(self.cur, m, p)]

    def snapshot(self, m, p):
        return self.ga.finish_tic(self.cur, m, p)

    def camera(self, m, p, a):
        r = self.ga.camera_pose(self.cur, m, p, a)
        return None if r is None else list(r)

    def frame(self, m, p, sk, a):
        fr, _pose = self.ga.render_live(self.rcur, m, p, sk, alpha=a)
        self.conn.rollback()
        return fr

    def stages(self):
        self.cur.execute(self.ga.STAGES_SQL)
        return [[int(r[0]), r[1], int(r[2])] for r in self.cur.fetchall()]

    def music(self, m):
        r = self.ga.stage_music(self.cur, m)
        return None if r is None else [r[0], digest(r[1]), digest(r[2]), r[3]]

    def assets(self):
        return {n: digest(w) for n, w in self.ga.sound_assets(self.cur)}


# ------------------------------------------------------------------------------- one run
def run(db, name, limit=None, frames=True):
    m, p, sk, cheats, mods, ops, cmds, fevery = load_run(name)
    if limit:
        cmds = cmds[:limit]
    out = {"run": name, "map_id": m, "player": p, "skill": sk, "tics": []}
    db.start(m, p, sk, cheats, mods, ops.get("0", []))
    frames_out = {}
    cursor = 0
    try:
        out["start_pose"] = {str(a): db.camera(m, p, a) for a in FIXED_ALPHAS}
        for i, cmd in enumerate(cmds):
            tic = i + 1
            if i > 0:
                for op in ops.get(str(i), []):
                    db.op(op)
            due = db.tic(m, p, cmd)
            rec = {"tic": tic}
            if isinstance(due, str):
                rec["error"] = due
                out["tics"].append(rec)
                continue
            ev = []
            if due:
                ev = db.events(m, p, cursor)
                if ev:
                    cursor = max(e[0] for e in ev)
            rec["due"] = bool(due)
            rec["events"] = [list(e[1:]) for e in ev]
            rec["loops"] = [list(r) for r in db.loops(m, p)]
            snap = db.snapshot(m, p)
            rec["alive"] = snap["alive"]
            rec["camera"] = [[a, db.camera(m, p, a)] for a in alphas(name, tic)]
            if frames and fevery and tic % fevery == 0:
                a = frame_alpha(name, tic)
                frames_out[tic] = (a, db.frame(m, p, sk, a))
            out["tics"].append(rec)
    finally:
        db.finish()
    return out, frames_out


def close(a, b, tol=1e-9):
    if a is None or b is None:
        return a is None and b is None
    if a == b:
        return True
    return abs(a - b) <= tol * max(1.0, abs(a), abs(b))


def compare(ref, ora, rframes, oframes):
    res = {"tics": 0, "tic_errors": 0, "events": 0, "events_exact": 0, "event_tics_bad": 0, "loop_sets": 0,
           "loop_rows": 0, "loop_exact": 0, "loop_bad": 0, "poses": 0, "poses_exact": 0, "pose_bad": 0,
           "frames": 0, "frames_exact": 0, "max_ev_diff": 0.0, "max_loop_diff": 0.0}
    bad = []
    for r, o in zip(ref["tics"], ora["tics"]):
        res["tics"] += 1
        if "error" in r or "error" in o:
            res["tic_errors"] += 1
            if ("error" in r) != ("error" in o):
                bad.append((r["tic"], "error", r.get("error"), o.get("error")))
            continue
        re_, oe = sorted(map(tuple, r["events"])), sorted(map(tuple, o["events"]))
        res["events"] += len(re_)
        if len(re_) != len(oe) or any(a[0] != b[0] or not close(a[1], b[1]) or not close(a[2], b[2])
                                      for a, b in zip(re_, oe)):
            res["event_tics_bad"] += 1
            bad.append((r["tic"], "events", re_, oe))
        else:
            for a, b in zip(re_, oe):
                res["events_exact"] += a == b
                res["max_ev_diff"] = max(res["max_ev_diff"], abs(a[1] - b[1]), abs(a[2] - b[2]))
        rl, ol = r["loops"], o["loops"]
        res["loop_sets"] += 1
        res["loop_rows"] += len(rl)
        if len(rl) != len(ol) or any(a[0] != b[0] or a[1] != b[1] or not close(a[2], b[2]) or not close(a[3], b[3])
                                     for a, b in zip(rl, ol)):
            res["loop_bad"] += 1
            bad.append((r["tic"], "loops", rl, ol))
        else:
            for a, b in zip(rl, ol):
                res["loop_exact"] += tuple(a) == tuple(b)
                res["max_loop_diff"] = max(res["max_loop_diff"], abs(a[2] - b[2]), abs(a[3] - b[3]))
        for (a1, p1), (a2, p2) in zip(r["camera"], o["camera"]):
            res["poses"] += 1
            if a1 != a2 or p1 != p2:
                res["pose_bad"] += 1
                bad.append((r["tic"], "camera", a1, p1, p2))
            else:
                res["poses_exact"] += 1
    if len(ref["tics"]) != len(ora["tics"]):
        bad.append(("length", len(ref["tics"]), len(ora["tics"])))
    for tic, (a, fr) in rframes.items():
        res["frames"] += 1
        oa, ofr = oframes.get(tic, (None, None))
        if ofr is not None and oa == a:
            n = int((ofr != fr).sum())
            if n == 0:
                res["frames_exact"] += 1
            else:
                bad.append((tic, "frame", a, n))
        else:
            bad.append((tic, "frame missing"))
    return res, bad


def save(name, out, frames):
    d = OUT / name
    (d / "frames").mkdir(parents=True, exist_ok=True)
    (d / "data.json.z").write_bytes(zlib.compress(json.dumps(out).encode(), 6))
    meta = {}
    for tic, (a, fr) in frames.items():
        (d / "frames" / f"{tic:05d}.idx.z").write_bytes(zlib.compress(fr.tobytes(), 6))
        meta[tic] = a
    (d / "frames.json").write_text(json.dumps(meta))


def load(name):
    d = OUT / name
    out = json.loads(zlib.decompress((d / "data.json.z").read_bytes()))
    meta = json.loads((d / "frames.json").read_text())
    frames = {int(t): (a, np.frombuffer(zlib.decompress((d / "frames" / f"{int(t):05d}.idx.z").read_bytes()),
                                        np.uint8).reshape(200, 320)) for t, a in meta.items()}
    return out, frames


# ------------------------------------------------------------------------------- music on CedarDB
def cedar_music(dsn=rgr.DEFAULT_DSN):
    """The reference loader's load_music on CedarDB, then the MIDI lumps it skips, as Oracle's loader
    stores them (client/music.py, accept_midi)."""
    import psycopg2
    sys.path.insert(0, str(rgr.SQLDOOM))
    import wad_loader
    import load_wad, music
    conn = psycopg2.connect(dsn)
    cur = conn.cursor()
    wad = load_wad.Wad(WAD)
    with open(WAD, "rb") as fp:
        n_mus, _, _ = wad_loader.load_music(fp, cur, [dict(l) for l in wad.lumps], render_audio=False)
    added = 0
    for name, (orig, midi) in music.scores(wad).items():
        cur.execute("SELECT 1 FROM music_assets WHERE name = %s", (name,))
        if cur.fetchone():
            continue
        cur.execute("INSERT INTO music_assets (name, mus_data, midi_data, audio_data, audio_format) "
                    "VALUES (%s, %s, %s, NULL, NULL)", (name, psycopg2.Binary(orig), psycopg2.Binary(midi)))
        added += 1
    cur.execute("SELECT map_id, name FROM maps")
    for m, n in cur.fetchall():
        t = music.music_lump_for_map(n)
        cur.execute("SELECT 1 FROM music_assets WHERE name = %s", (t,))
        if t and cur.fetchone():
            cur.execute("INSERT INTO map_music (map_id, music_name) VALUES (%s, %s) "
                        "ON CONFLICT (map_id) DO UPDATE SET music_name = EXCLUDED.music_name", (m, t))
    conn.commit()
    print(f"CedarDB: reference load_music found {n_mus} MUS scores; {added} MIDI lumps added")


def assets():
    """sound_assets, music_assets, map_music byte-equal; stage music, stages, spawn pose per map."""
    c, o = Cedar(), Oracle()
    ok = True
    ca, oa = c.assets(), o.assets()
    same = sum(1 for k in ca if oa.get(k) == ca[k])
    print(f"sound_assets: {same}/{len(ca)} byte-equal (Oracle {len(oa)} rows)")
    ok &= same == len(ca) == len(oa)
    c.cur.execute("SELECT name, mus_data, midi_data, audio_data, audio_format FROM music_assets")
    cm = {r[0]: (digest(r[1]), digest(r[2]), digest(r[3]), r[4]) for r in c.cur.fetchall()}
    o.cur.execute("SELECT name, mus_data, midi_data, audio_data, audio_format FROM music_assets")
    om = {r[0]: (digest(r[1].read()), digest(r[2].read()), digest(r[3].read() if r[3] else None), r[4])
          for r in o.cur.fetchall()}
    same = sum(1 for k in cm if om.get(k) == cm[k])
    print(f"music_assets: {same}/{len(cm)} byte-equal (Oracle {len(om)} rows)")
    ok &= same == len(cm) == len(om)
    c.cur.execute("SELECT map_id, music_name FROM map_music ORDER BY 1")
    o.cur.execute("SELECT map_id, music_name FROM map_music ORDER BY 1")
    cmm, omm = [tuple(r) for r in c.cur.fetchall()], [(int(a), b) for a, b in o.cur.fetchall()]
    print(f"map_music: {'equal' if cmm == omm else 'DIFFERENT'} ({len(cmm)} maps)")
    ok &= cmm == omm
    cs, os_ = c.stages(), o.stages()
    cs2 = [[m, lbl.split()[0], p] for m, lbl, p in cs]
    print(f"stages: {'equal' if cs2 == os_ else 'DIFFERENT'} ({len(cs)} maps)")
    ok &= cs2 == os_
    good = 0
    for m, _n, _p in cs2:
        good += c.music(m) == o.music(m)
    print(f"stage_music: {good}/{len(cs2)} maps equal")
    ok &= good == len(cs2)
    return ok


def mus_fuzz(n):
    """The MUS converter has no input in freedoom1.wad (its music is MIDI already): compare the port
    with the reference function on random MUS scores (every event type, delays, velocities, the
    truncated and invalid cases)."""
    sys.path.insert(0, str(rgr.SQLDOOM))
    import wad_loader
    import music
    rnd = random.Random(6)
    eq = errs = 0
    for k in range(n):
        body = bytearray()
        for _ in range(rnd.randint(0, 400)):
            et = rnd.choice((0, 1, 1, 2, 3, 4, 4, 5 if rnd.random() < 0.01 else 0, 6 if rnd.random() < 0.02 else 1))
            last = rnd.random() < 0.4
            ch = rnd.randint(0, 15)
            body.append((0x80 if last else 0) | (et << 4) | ch)
            if et == 0:
                body.append(rnd.randint(0, 127))
            elif et == 1:
                note = rnd.randint(0, 255)
                body.append(note)
                if note & 0x80:
                    body.append(rnd.randint(0, 255))
            elif et == 2:
                body.append(rnd.randint(0, 255))
            elif et == 3:
                body.append(rnd.randint(10, 16 if rnd.random() < 0.02 else 14))
            elif et == 4:
                body += bytes((rnd.randint(0, 16 if rnd.random() < 0.02 else 9), rnd.randint(0, 255)))
            if last:
                for _ in range(rnd.randint(0, 2)):
                    body.append(0x80 | rnd.randint(0, 127))
                body.append(rnd.randint(0, 127))
        if rnd.random() < 0.1 and body:
            body = body[:rnd.randint(0, len(body))]
        hdr = b"MUS\x1a" + len(body).to_bytes(2, "little") + (16).to_bytes(2, "little") + bytes(8)
        data = hdr + bytes(body)
        try:
            a = wad_loader.mus_to_midi(data)
        except ValueError as ex:
            a = ("err", str(ex))
        try:
            b = music.mus_to_midi(data)
        except ValueError as ex:
            b = ("err", str(ex))
        eq += a == b
        errs += isinstance(a, tuple)
    print(f"mus_to_midi: {eq}/{n} equal to the reference ({errs} invalid scores rejected identically)")
    return eq == n


def cedar_float8(x):
    """CedarDB's float8 parse of Python's shortest text of x (what doom_float8 emulates in SQL)."""
    t = repr(float(x))
    if x == 0:
        return 0.0
    if abs(x) < 1e-4 or abs(x) >= 1e16 or "e" in t:
        return float(t)
    neg = t.startswith("-")
    t = t.lstrip("-")
    ip, _, fp = t.partition(".")
    m, scale = int(ip + fp), len(fp)
    bits = m.bit_length()
    if bits > 53:                                   # round the mantissa to 53 bits, ties to even
        sh = bits - 53
        q, r = divmod(m, 1 << sh)
        half = 1 << (sh - 1)
        if r > half or (r == half and q & 1):
            q += 1
        m = q << sh
    v = float(m) / float(10 ** scale)
    return -v if neg else v


def camera_emulated(row, alpha):
    """client/camera_pose.sql in IEEE arithmetic with PostgreSQL's types, from the REAL columns:
    position - previous is real - real (float4), the rest float8 (the angle is cast to float8 first)."""
    import math
    px, x, py, y, pz, z, pa, va = row
    a = min(1.0, max(0.0, cedar_float8(alpha)))
    d = va - pa + 180.0
    turn = (d - 360.0 * math.floor(d / 360.0)) - 180.0
    ang = pa + turn * a
    import numpy as np
    f4 = lambda u, v: float(np.float32(u) - np.float32(v))   # real - real is float4 arithmetic  # noqa: E731
    return [px + f4(x, px) * a, py + f4(y, py) * a, pz + f4(z, pz) * a, ang - 360.0 * math.floor(ang / 360.0)]


def emulate(names, limit):
    """Without CedarDB: the camera statement on Oracle vs camera_pose.sql evaluated in Python double
    arithmetic (the same IEEE operations CedarDB's float8 executes), for the recorded command streams."""
    o = Oracle()
    total = bad = 0
    for n in names:
        m, p, sk, cheats, mods, ops, cmds, _fe = load_run(n)
        cmds = cmds[:limit] if limit else cmds
        o.start(m, p, sk, cheats, mods, ops.get("0", []))
        nb = nt = 0
        try:
            for i, cmd in enumerate(cmds):
                if i > 0:
                    for op in ops.get(str(i), []):
                        o.op(op)
                if isinstance(o.tic(m, p, cmd), str):
                    continue
                o.cur.execute("SELECT previous_x, position_x, previous_y, position_y, previous_view_z, view_z, "
                              "previous_view_angle, view_angle FROM g_player_state WHERE map_id = :m "
                              "AND player_thing_id = :p", m=m, p=p)
                row = [float(v) for v in o.cur.fetchone()]
                for al in alphas(n, i + 1):
                    nt += 1
                    if o.camera(m, p, al) != camera_emulated(row, al):
                        nb += 1
        finally:
            o.finish()
        print(f"{n}: camera statement vs camera_pose.sql in double arithmetic: {nt - nb}/{nt} equal", flush=True)
        total += nt
        bad += nb
    return bad == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=("cedar-music", "assets", "mus-fuzz", "record", "replay", "emulate"))
    ap.add_argument("names", nargs="*")
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--no-frames", action="store_true")
    a = ap.parse_args()
    if a.cmd == "cedar-music":
        cedar_music()
        return
    if a.cmd == "assets":
        sys.exit(0 if assets() else 1)
    if a.cmd == "mus-fuzz":
        sys.exit(0 if mus_fuzz(int(a.names[0]) if a.names else 3000) else 1)
    names = a.names or list(DEFAULT_RUNS)
    if a.cmd == "emulate":
        sys.exit(0 if emulate(names, a.limit) else 1)
    if a.cmd == "record":
        c = Cedar()
        for n in names:
            t0 = time.perf_counter()
            out, frames = run(c, n, a.limit, not a.no_frames)
            save(n, out, frames)
            print(f"{n}: {len(out['tics'])} tics, {len(frames)} frames recorded in {time.perf_counter() - t0:.0f}s",
                  flush=True)
        return
    o = Oracle()
    total, allok = {}, True
    for n in names:
        ref, rframes = load(n)
        t0 = time.perf_counter()
        ora, oframes = run(o, n, len(ref["tics"]), not a.no_frames)
        res, bad = compare(ref, ora, rframes if not a.no_frames else {}, oframes)
        ok = not bad
        allok &= ok
        for k, v in res.items():
            total[k] = max(total.get(k, 0), v) if k.startswith("max_") else total.get(k, 0) + v
        print(f"{n}: {'EQUAL' if ok else 'DIFFERENT'} -- {res['tics']} tics ({res['tic_errors']} failed on both), "
              f"{res['events']} sound events ({res['events_exact']} bit-exact), {res['loop_sets']} loop sets "
              f"({res['loop_rows']} rows, {res['loop_exact']} bit-exact), camera poses {res['poses_exact']}/{res['poses']}, "
              f"frames {res['frames_exact']}/{res['frames']} pixel-exact  [{time.perf_counter() - t0:.0f}s]", flush=True)
        for b in bad[:6]:
            print("   ", str(b)[:300])
    print("TOTAL", json.dumps(total))
    sys.exit(0 if allok else 1)


if __name__ == "__main__":
    main()
