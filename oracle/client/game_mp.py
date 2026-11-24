#!/usr/bin/env python3
"""The deathmatch loop on Oracle: one shared world tic (doom_game.run_mp_tic, every slot of
the map) per 35 Hz period and one frame per player, each player's frame rendered by its own
Oracle session (doom_hybrid_live over the live g_* tables), the render sessions concurrently.

    python oracle/client/game_mp.py --players 2 [--tics 1200] [--pipelined] [--realtime]
                                    [--check dm_e1m1_2p] [--json out.json]

Sessions: one tic session (the referee) + one render session per claimed player.
Per period:
  tic session    one round trip: the players' input rows (array bind, FORALL INSERT into
                 g_mp_inputs), run_mp_tic, COMMIT, all in one anonymous PL/SQL block
  render session i  (in parallel, one thread each) one SELECT: player i's camera pose
                 (camera_pose.sql's interpolation at alpha 1) joined laterally into
                 render_frame, so pose and frame read one snapshot; 200 hex rows fetched
  serial         tic, then all frames in parallel, then the next tic
  --pipelined    frames of tic N render while tic N+1 runs: before the next tic starts, every
                 render session pins a read-only snapshot of tic N (one round trip each, in
                 parallel), so no frame can see a later tic

Inputs: --check MATCH replays the recorded inputs of reference_data/MATCH (CedarDB) and compares
every recorded frame per player (pixel-exact) and every camera pose; otherwise the scripted bots
of tests/mp_lib.py play live from Oracle's own state. No game logic or rendering runs in the
client: it only chooses inputs (bots), sends them and decodes the hex rows.
"""
import argparse, json, statistics, sys, threading, time, zlib
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "tests"))
import oradb, game_api, doomora  # noqa: E402
import mp_lib  # noqa: E402

REF = HERE.parent / "reference_data"
BUDGET = 1000.0 / 35.0

TIC_BLOCK = """
DECLARE
  TYPE tn IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  TYPE tv IS TABLE OF VARCHAR2(40) INDEX BY PLS_INTEGER;
  p tn := :p; f tv := :f; st tv := :st; rn tn := :rn; t tv := :t; atk tn := :atk; sw tn := :sw; u tn := :u;
BEGIN
  FORALL i IN 1 .. :n
    INSERT INTO g_mp_inputs (map_id, player_thing_id, move_fwd, move_strafe, running, turn_degrees,
                             attack_held, weapon_switch_to, use_requested)
    VALUES (:m, p(i), doom_game.cmd_real(f(i)), doom_game.cmd_real(st(i)), rn(i) = 1, doom_game.cmd_real(t(i)),
            atk(i) = 1, CASE WHEN sw(i) > 0 THEN sw(i) END, u(i) = 1);
  :r := doom_game.run_mp_tic(:m, :s, :p1, :p2, :p3, :p4);
  COMMIT;
END;"""

FRAME_SQL = game_api.FRAME_SQL

STATE_Q = """
SELECT mp.slot, ps.player_thing_id, ps.position_x, ps.position_y, ps.view_angle,
       CASE WHEN ps.alive THEN 1 ELSE 0 END, ps.death_tics, ps.health, CASE WHEN mp.role_name IS NOT NULL THEN 1 ELSE 0 END
  FROM g_mp_players mp JOIN g_player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id
 WHERE mp.map_id = :m ORDER BY mp.slot"""


class RenderSession(threading.Thread):
    """One player's render session: waits for a 'go', optionally pins a snapshot, renders."""

    def __init__(self, map_id, pid, skill, pin):
        super().__init__(daemon=True)
        self.map_id, self.pid, self.skill, self.pin = map_id, pid, skill, pin
        self.conn = oradb.connect()
        self.cur = self.conn.cursor()
        game_api.setup_session(self.cur)
        self.cur.arraysize = 256
        self.cur.prefetchrows = 257
        self.go, self.done, self.pinned = threading.Event(), threading.Event(), threading.Event()
        self.result, self.stop = None, False

    def pin_snapshot(self):
        self.cur.execute("BEGIN ROLLBACK; SET TRANSACTION READ ONLY; END;")

    def render(self):
        t0 = time.perf_counter()
        self.cur.execute(FRAME_SQL, map_id=self.map_id, player_id=self.pid, skill=self.skill, sprites=game_api.SPRITES_EXACT)
        rows = self.cur.fetchall()
        t1 = time.perf_counter()
        frame = np.empty((200, 320), np.uint8)
        for y, _p, hx, *_ in rows:
            frame[int(y)] = np.frombuffer(bytes.fromhex(hx), np.uint8)
        pose = tuple(float(v) for v in rows[0][3:7])
        if not self.pin:
            self.conn.rollback()
        return frame, pose, (t1 - t0) * 1e3, (time.perf_counter() - t0) * 1e3

    def run(self):
        while True:
            self.go.wait(); self.go.clear()
            if self.stop:
                return
            if self.pin:
                t0 = time.perf_counter()
                self.pin_snapshot()
                self.pin_ms = (time.perf_counter() - t0) * 1e3
                self.pinned.set()
            self.result = self.render()
            self.done.set()


def stats(v):
    v = sorted(v)
    n = len(v)
    return {"n": n, "mean": statistics.mean(v), "p50": v[n // 2], "p95": v[int(n * 0.95)],
            "p99": v[min(n - 1, int(n * 0.99))], "max": v[-1]}


def fmt(name, s):
    return (f"{name:14s} mean {s['mean']:6.2f}  p50 {s['p50']:6.2f}  p95 {s['p95']:6.2f}  "
            f"p99 {s['p99']:6.2f}  max {s['max']:6.2f} ms")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--players", type=int, default=2)
    ap.add_argument("--map", default="E1M1")
    ap.add_argument("--skill", type=int, default=2)
    ap.add_argument("--tics", type=int, default=0)
    ap.add_argument("--warmup", type=int, default=60)
    ap.add_argument("--pipelined", action="store_true")
    ap.add_argument("--realtime", action="store_true")
    ap.add_argument("--check", default=None, help="replay reference_data/<match> and compare frames/poses")
    ap.add_argument("--no-monsters", action="store_true")
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()

    ref_run, ref_tics = None, None
    if a.check:
        ref_run = json.loads((REF / a.check / "run.json").read_text())
        ref_tics = json.loads((REF / a.check / "tics.json").read_text())
        cfg = ref_run["config"]
        map_id, skill = ref_run["map_id"], ref_run["skill"]
        n_tics = a.tics or ref_run["tics"]
        claimed = ref_run["claimed"]
    else:
        cfg = dict(timer=0, altdeath=True, monsters=not a.no_monsters, respawn=True, seed=7)
        map_id = {"E1M1": 1, "E1M2": 2, "E1M3": 3}[a.map]
        skill = a.skill
        n_tics = a.tics or 1200
        claimed = list(range(1, a.players + 1))

    conn = oradb.connect()
    cur = conn.cursor()
    game_api.setup_session(cur)
    sys.path.insert(0, str(HERE.parent / "tests"))
    import run_game_correctness as rgc  # noqa: E402  (match start helpers)
    run = {"config": cfg, "map_id": map_id, "skill": skill, "claimed": claimed}
    rgc.mp_cleanup(cur)
    t0 = time.perf_counter()
    rgc.mp_open(cur, run)
    start_ms = (time.perf_counter() - t0) * 1e3
    cur.execute("SELECT slot, player_thing_id FROM g_mp_players WHERE map_id = :m ORDER BY slot", m=map_id)
    players = {int(s): int(p) for s, p in cur.fetchall()}
    claimed = [s for s in claimed if s in players]
    bots = {s: mp_lib.Bot(s, players[s], cfg.get("seed", 7)) for s in claimed}
    rs = {s: RenderSession(map_id, players[s], skill, a.pipelined) for s in claimed}
    for r in rs.values():
        r.start()
    # warm the renderers' static caches (first frame per session) before the clock starts
    for r in rs.values():
        r.go.set()
    for r in rs.values():
        r.done.wait(); r.done.clear(); r.pinned.clear()
    tcur = conn.cursor()
    rvar = tcur.var(int)

    tic_ms, period_ms, frame_ms, exec_ms, pin_ms, wall_frames = [], [], {s: [] for s in claimed}, [], [], []
    frame_bad, pose_bad, checked = [], [], 0
    late = 0

    def collect(tic):
        nonlocal checked
        worst = 0.0
        for s, r in rs.items():
            r.done.wait(); r.done.clear()
            frame, pose, ex, ms = r.result
            frame_ms[s].append(ms)
            worst = max(worst, ms)
            if ref_tics is not None:
                rp = ref_tics[tic - 1]["poses"][str(s)]
                if tuple(rp) != pose:
                    pose_bad.append((tic, s, pose, rp))
                fp = REF / a.check / "frames" / f"{tic:05d}_{s}.idx.z"
                if fp.exists():
                    checked += 1
                    refi = np.frombuffer(zlib.decompress(fp.read_bytes()), np.uint8).reshape(200, 320)
                    n = int((refi != frame).sum())
                    if n:
                        frame_bad.append((tic, s, n))
        return worst

    pending = None
    start = time.perf_counter()
    starts = []
    for i in range(n_tics):
        tic = i + 1
        if a.realtime:
            due = start + i / 35.0
            now = time.perf_counter()
            if now < due:
                time.sleep(due - now)
            elif now - due > 1 / 35.0:
                late += 1
        # inputs for this tic: recorded (check) or the bots' choice from the state before the tic
        if ref_tics is not None:
            inp = {int(s): c for s, c in ref_tics[i]["inputs"].items()}
            rgc.mp_ops(tcur, map_id, players, ref_tics[i].get("ops"))
        else:
            if pending is not None and a.pipelined:
                pass   # bots read committed state; the render snapshot pins do not block reads
            tcur.execute(STATE_Q, m=map_id)
            st = {r_[0]: dict(pid=r_[1], x=float(r_[2]), y=float(r_[3]), angle=float(r_[4]), alive=bool(r_[5]),
                              death_tics=int(r_[6]), health=int(r_[7]), held=bool(r_[8])) for r_ in tcur.fetchall()}
            inp = {}
            for s in claimed:
                others = [v for k, v in st.items() if k != s and v["held"]]
                inp[s] = [skill, *bots[s].command(tic, st[s], others, {1, 2, 3, 4, 5})]
        p0 = time.perf_counter()
        starts.append(p0)
        ss = sorted(inp)
        cols = list(zip(*[inp[s] for s in ss]))
        av = tcur.arrayvar
        tcur.execute(TIC_BLOCK, n=len(ss), m=map_id, s=skill, r=rvar,
                     p=av(int, [players[s] for s in ss]), f=av(str, [repr(float(v)) for v in cols[1]], 40),
                     st=av(str, [repr(float(v)) for v in cols[2]], 40), rn=av(int, [1 if v else 0 for v in cols[3]]),
                     t=av(str, [repr(float(v)) for v in cols[4]], 40), atk=av(int, [1 if v else 0 for v in cols[5]]),
                     sw=av(int, [int(v) if v else 0 for v in cols[6]]), u=av(int, [1 if v else 0 for v in cols[7]]),
                     p1=players.get(1), p2=players.get(2), p3=players.get(3), p4=players.get(4))
        t1 = time.perf_counter()
        tic_ms.append((t1 - p0) * 1e3)
        if a.pipelined:
            if pending is not None:
                worst = collect(pending)
            for r in rs.values():
                r.pinned.clear()
                r.go.set()
            for r in rs.values():
                r.pinned.wait()
            pin_ms.append(max(r.pin_ms for r in rs.values()))
            pending = tic
        else:
            for r in rs.values():
                r.go.set()
            collect(tic)
        period_ms.append((time.perf_counter() - p0) * 1e3)
        if rvar.getvalue():
            print(f"level done at tic {tic}")
            n_tics = tic
            break
        if tic % 200 == 0:
            print(f"tic {tic}: {time.perf_counter() - start:.1f}s", flush=True)
    if pending is not None:
        collect(pending)
    total = time.perf_counter() - start
    for r in rs.values():
        r.stop = True; r.go.set()
    w = a.warmup
    meas = period_ms[w:]
    if a.pipelined:   # tic-to-tic interval is the period
        meas = [(starts[k + 1] - starts[k]) * 1e3 for k in range(w, len(starts) - 1)]
    mode = ("pipelined" if a.pipelined else "serial") + (" realtime" if a.realtime else "")
    print(f"{len(claimed)} players ({len(players)} slots ticked), map {map_id}, {mode}; match start {start_ms:.0f} ms")
    st_tic = stats(tic_ms[w:])
    print(fmt("tic", st_tic))
    allf = [x for s in claimed for x in frame_ms[s][w:]]
    for s in claimed:
        print(fmt(f"frame slot {s}", stats(frame_ms[s][w:])))
    st_per = stats(meas)
    print(fmt("period", st_per))
    within = sum(1 for p in meas if p <= BUDGET) / len(meas) * 100
    fwithin = sum(1 for p in allf if p <= BUDGET) / len(allf) * 100
    rate = len(meas) / (sum(meas) / 1e3)
    print(f"periods <= 28.6 ms: {within:.1f}%; frames <= 28.6 ms: {fwithin:.1f}%; {rate:.1f} periods/s "
          f"({rate * len(claimed):.0f} frames/s total)" + (f"; late {late}" if a.realtime else ""))
    if ref_tics is not None:
        print(f"frames vs CedarDB: {checked - len(frame_bad)}/{checked} pixel-exact over {len(claimed)} players; "
              f"camera poses differing: {len(pose_bad)}")
        for b in frame_bad[:8]:
            print("  frame differs (tic, slot, pixels)", b)
        for b in pose_bad[:4]:
            print("  pose differs", b)
    if a.json:
        a.json.write_text(json.dumps({
            "players": len(claimed), "mode": mode, "tic": st_tic, "period": st_per,
            "frame": {str(s): stats(frame_ms[s][w:]) for s in claimed}, "frame_all": stats(allf),
            "within_pct": within, "frames_within_pct": fwithin, "periods_per_s": rate,
            "checked": checked, "frame_bad": len(frame_bad), "pose_bad": len(pose_bad),
            "tic_ms": tic_ms, "period_ms": period_ms, "frame_ms": {str(s): v for s, v in frame_ms.items()}}))
    rgc.mp_cleanup(cur)
    return 0 if not frame_bad and not pose_bad else 1


if __name__ == "__main__":
    sys.exit(main())
