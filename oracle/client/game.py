#!/usr/bin/env python3
"""The 35 Hz game loop on Oracle: the real SQLDoom game tic (doom_game) and the hybrid
renderer drawing the LIVE game state (doom_hybrid_live over the lv_* views), one frame
per tic, replaying the TPC-DOOM E1M1 command stream (as TPC-DOOM test R does).

    python oracle/client/game.py [--tics 1200] [--realtime] [--pipelined] [--check] [--png-every N]

  default      test R: one connection, tic -> camera_pose -> frame, back to back
  --realtime   pace the loop at 35 Hz (sleep when ahead) and count late periods
  --pipelined  render frame N on a second connection (read-only snapshot) while tic N+1
               runs on the first: the two Oracle Free CPUs work in parallel
  --split      render each frame on two sessions in parallel, one screen column range each
               (doomora.SplitRenderer; Oracle Free has 2 CPUs and no parallel query). Serial:
               the game session renders the left part itself, a second session the right part;
               pipelined: two render sessions pinned to the same read-only snapshot
  --check      compare every live frame with the recorded CedarDB frame
               (reference_data/e1m1/frames_idx) and every camera pose with poses.json

The client sends commands and fetches results only; all game logic and rendering run in
the database.
"""
import argparse, json, statistics, sys, threading, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "tests"))
import oradb, game_api, doomora  # noqa: E402

LIVE_TIC = -1
RENDER_SQL = ("SELECT y, pal, hex FROM TABLE(doom_hybrid_live.render_frame(:tic, :map_id, :player_id, :skill, "
              ":px, :py, :pz, :pangle))")
SPLIT_SQL = ("SELECT y, pal, hex FROM TABLE(doom_hybrid_live.render_frame(:tic, :map_id, :player_id, :skill, "
             ":px, :py, :pz, :pangle, :x0, :x1))")
REF_FRAMES = HERE.parent / "reference_data" / "e1m1"


class Frame:
    def __init__(self, conn, readonly=False, conn2=None):
        self.conn, self.readonly, self.conn2 = conn, readonly, conn2
        self.cur = conn.cursor()
        self.cur.arraysize = 256
        self.cur.prefetchrows = 257
        self.pcur = conn.cursor()
        self.split = doomora.SplitRenderer(conn, conn2, sql=SPLIT_SQL) if conn2 else None
        self.pcur2 = conn2.cursor() if conn2 else None

    def snapshot(self):
        """Pipelined mode: pin a read-only snapshot of the state the last committed tic left
        (called by the game thread right after the commit, before the next tic starts)."""
        self.conn.rollback()
        self.pcur.execute("SET TRANSACTION READ ONLY")
        if self.conn2:
            self.conn2.rollback()
            self.pcur2.execute("SET TRANSACTION READ ONLY")

    def draw(self, map_id, player, skill):
        """camera_pose at alpha 1.0 + render_frame; returns (frame, pal, pose, ms)."""
        t0 = time.perf_counter()
        pose = game_api.camera_pose(self.pcur, map_id, player, 1.0)
        x, y, z, a = pose
        if self.split:
            frame, pal = self.split.render_binds(dict(tic=LIVE_TIC, map_id=map_id, player_id=player, skill=skill,
                                                      px=x, py=y, pz=z, pangle=a))
            if self.readonly:
                self.conn.rollback(); self.conn2.rollback()
            return frame, pal, pose, (time.perf_counter() - t0) * 1e3
        self.cur.execute(RENDER_SQL, tic=LIVE_TIC, map_id=map_id, player_id=player, skill=skill,
                         px=x, py=y, pz=z, pangle=a)
        rows = self.cur.fetchall()
        if self.readonly:
            self.conn.rollback()
        ms = (time.perf_counter() - t0) * 1e3
        frame, pal = doomora.decode_hexrows(rows)
        return frame, pal, pose, ms


def stats(v):
    v = sorted(v)
    n = len(v)
    return {"mean": statistics.mean(v), "p50": v[n // 2], "p95": v[int(n * 0.95)], "p99": v[int(n * 0.99)],
            "max": v[-1]}


def fmt(name, s):
    return f"{name:12s} mean {s['mean']:6.2f}  p50 {s['p50']:6.2f}  p95 {s['p95']:6.2f}  p99 {s['p99']:6.2f}  max {s['max']:6.2f} ms"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tics", type=int, default=1200)
    ap.add_argument("--warmup", type=int, default=120)
    ap.add_argument("--realtime", action="store_true")
    ap.add_argument("--pipelined", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--split", action="store_true")
    ap.add_argument("--json", type=Path, help="write per-tic timings here")
    a = ap.parse_args()
    cmds = [c["command"] for c in json.loads((HERE.parent / "tests" / "run-e1m1-b-commands.json").read_text())]
    map_id, player, skill = 1, 157, 2
    conn = oradb.connect()
    cur = conn.cursor()
    game_api.setup_session(cur)
    t0 = time.perf_counter()
    game_api.level_start(cur, map_id, player, skill)
    level_ms = (time.perf_counter() - t0) * 1e3
    rconn = oradb.connect() if a.pipelined else conn
    if a.pipelined:
        game_api.setup_session(rconn.cursor())
    rconn2 = None
    if a.split:
        rconn2 = oradb.connect()
        game_api.setup_session(rconn2.cursor())
    fr = Frame(rconn, readonly=a.pipelined, conn2=rconn2)
    t0 = time.perf_counter()
    if a.pipelined:
        fr.snapshot()
    fr.draw(map_id, player, skill)                    # first frame: loads the renderer's static caches
    first_frame_ms = (time.perf_counter() - t0) * 1e3

    refposes = doomora.load_poses(REF_FRAMES) if a.check else {}
    if a.check:
        import numpy as np, framecmp  # noqa: F401
    tic_ms, frame_ms, period_ms, late = [], [], [], 0
    frame_bad, pose_bad = [], []
    period = 1.0 / 35.0

    def check(tic, frame, pose):
        if not a.check:
            return
        ref = framecmp.load_ref(tic, REF_FRAMES)
        c = framecmp.compare(frame, ref)
        if c["mismatch"]:
            frame_bad.append((tic, c["mismatch"]))
        if tuple(pose) != tuple(refposes[tic]):
            pose_bad.append((tic, pose, refposes[tic]))

    pending = None  # pipelined: (tic, thread, result)
    event_cursor = 0
    starts = []
    start = time.perf_counter()
    for i in range(a.tics):
        tic = i + 1
        if a.realtime:
            due = start + i * period
            now = time.perf_counter()
            if now < due:
                time.sleep(due - now)
            elif now - due > period:
                late += 1
        p0 = time.perf_counter()
        starts.append(p0)
        # the tic as TPC-DOOM test T runs it: execute_game_tic, fetch_sound_events, finish_game_tic
        if game_api.run_tic(cur, map_id, player, (skill, *cmds[i % len(cmds)][1:])):
            ev = game_api.sound_events(cur, map_id, player, event_cursor)
            if ev:
                event_cursor = max(e[0] for e in ev)
        conn.commit()
        game_api.finish_tic(cur, map_id, player)
        t1 = time.perf_counter()
        tic_ms.append((t1 - p0) * 1e3)
        if a.pipelined:
            if pending:
                pending[1].join()
                ptic, _, res = pending
                frame_ms.append(res[3]); check(ptic, res[0], res[2])
            res = [None] * 4
            fr.snapshot()          # the frame sees exactly this tic's committed state

            def job(res=res):
                res[:] = fr.draw(map_id, player, skill)
            th = threading.Thread(target=job)
            th.start()
            pending = (tic, th, res)
        else:
            frame, pal, pose, ms = fr.draw(map_id, player, skill)
            frame_ms.append(ms)
            check(tic, frame, pose)
        period_ms.append((time.perf_counter() - p0) * 1e3)
        if tic % 200 == 0:
            print(f"tic {tic}: {time.perf_counter() - start:.1f}s", flush=True)
    if pending:
        pending[1].join()
        frame_ms.append(pending[2][3]); check(pending[0], pending[2][0], pending[2][2])
    total = time.perf_counter() - start
    w = a.warmup
    meas = period_ms[w:]
    if a.realtime:   # achieved rate between tic starts after the warm-up
        tpsd = (len(starts) - 1 - w) / (starts[-1] - starts[w])
    else:
        tpsd = len(meas) / (sum(meas) / 1e3)
    print(f"level start {level_ms:.0f} ms; first frame {first_frame_ms:.0f} ms; mode "
          f"{'pipelined' if a.pipelined else 'serial (test R)'}{' split' if a.split else ''}{' realtime' if a.realtime else ''}")
    print(fmt("tic", stats(tic_ms[w:])))
    print(fmt("frame", stats(frame_ms[w:])))
    print(fmt("tic+frame" if not a.pipelined else "period", stats(meas)))
    within = sum(1 for p in meas if p <= 1000 / 35) / len(meas) * 100
    print(f"tpsD {tpsd:.1f} tic-and-frame pairs/s, RTF {tpsd / 35:.2f}; {within:.1f}% of periods <= 28.6 ms"
          + (f"; late periods {late}" if a.realtime else ""))
    if a.check:
        print(f"live frames vs CedarDB: {a.tics - len(frame_bad)}/{a.tics} pixel-exact; "
              f"camera poses equal: {a.tics - len(pose_bad)}/{a.tics}")
        for b in frame_bad[:10]:
            print("  frame differs", b)
        for b in pose_bad[:5]:
            print("  pose differs", b)
    if a.json:
        a.json.write_text(json.dumps({"tic_ms": tic_ms, "frame_ms": frame_ms, "period_ms": period_ms}))


if __name__ == "__main__":
    main()
