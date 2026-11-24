#!/usr/bin/env python3
"""A live deathmatch through the API with the referee (CedarDB scripts/mp_api_match.py), timed.

    python oracle/tests/mp_api_match.py --players 2 [--seconds 60] [--warmup 10] [--unpaced] [--json out.json]

The referee (client/referee.py, a subprocess) runs the world at 35 Hz. Each player is its own process
and its own database account (holding only DOOM_PLAYER), one Oracle session each, and plays like a
client: api_join, then per period: read its state through the API (api_player_state, the other
players from api_things_live -- what a bot may read), one round trip api_input + api_camera (+ READ
ONLY transaction), one round trip for its frame view (200 rows). The bots' decisions are
tests/mp_lib.Bot's. Paced at 35 Hz by default (one input and one frame per tic, as game_mp.py's
loop); --unpaced renders as fast as the database answers.

Reported per player: frame latency (input+camera round trip + frame), the whole period's work
(state read + frame latency), the share of periods / frames within 28.6 ms, frames per second;
for the referee: tics per second, tic latency, late and dropped tics.
"""
import argparse
import json
import multiprocessing as mp
import statistics
import sys
import time
from pathlib import Path

import mp_lib_api as L
import mp_lib

BUDGET = 1000.0 / 35.0
RESULTS = L.HERE.parent / "benchmark" / "results"


def stats(v):
    v = sorted(v)
    n = len(v)
    if not n:
        return {"n": 0}
    return {"n": n, "mean": statistics.mean(v), "p50": v[n // 2], "p95": v[int(n * 0.95)],
            "p99": v[min(n - 1, int(n * 0.99))], "max": v[-1], "within_pct": sum(1 for x in v if x <= BUDGET) / n * 100}


def bot(name, idx, start_at, measure_s, paced, q):
    p = L.player(name)
    me = -1
    while me < 0:
        me = p.join()
        if me < 0:
            time.sleep(0.2)
    map_id, slot = p.where()
    b = mp_lib.Bot(slot, me, 7 + idx, 1.0)
    frame_ms, work_ms, starts, errors, empty = [], [], [], 0, 0
    tic = 0
    nxt = time.perf_counter()
    end_at = start_at + measure_s
    while time.time() < end_at:
        measuring = time.time() >= start_at
        t0 = time.perf_counter()
        try:
            tic += 1
            ps = p.query("SELECT position_x, position_y, view_angle, CASE WHEN alive THEN 1 ELSE 0 END, death_tics, health "
                         "FROM api_player_state")[0]
            mine = dict(x=float(ps[0]), y=float(ps[1]), angle=float(ps[2]), alive=bool(ps[3]), death_tics=int(ps[4]),
                        health=int(ps[5]))
            others = [dict(x=float(r[0]), y=float(r[1]), angle=float(r[2]), alive=bool(r[3]))
                      for r in p.query("SELECT x, y, angle, CASE WHEN alive THEN 1 ELSE 0 END FROM api_things_live "
                                       "WHERE kind = 'player' AND map_id = :m AND thing_id <> :p", m=map_id, p=me)]
            cmd = b.command(tic, mine, others, {1, 2, 3, 4, 5})
            t1 = time.perf_counter()
            p.step(cmd, 1.0)
            frame, _pal = p.frame(map_id, slot)
            t2 = time.perf_counter()
            p.end_read()
            if frame is None:
                empty += 1
            if measuring:
                frame_ms.append((t2 - t1) * 1e3)
                work_ms.append((t2 - t0) * 1e3)
                starts.append(t0)
        except Exception as exc:  # noqa: BLE001
            errors += 1
            p.end_read()
            if errors <= 2:
                print(f"  {name} error: {str(exc).splitlines()[0][:120]}", flush=True)
        if paced:
            nxt += 1.0 / 35.0
            d = nxt - time.perf_counter()
            if d > 0:
                time.sleep(d)
            elif d < -0.5:
                nxt = time.perf_counter()
    periods = [(starts[i + 1] - starts[i]) * 1e3 for i in range(len(starts) - 1)]
    q.put({"name": name, "slot": slot, "frames": len(frame_ms), "errors": errors, "empty": empty,
           "frame_ms": frame_ms, "work_ms": work_ms, "period_ms": periods,
           "fps": len(frame_ms) / measure_s if measure_s else 0})
    p.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--players", type=int, default=2)
    ap.add_argument("--seconds", type=float, default=60)
    ap.add_argument("--warmup", type=float, default=10)
    ap.add_argument("--unpaced", action="store_true")
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()
    names = [f"LIVE_P{i}" for i in range(1, a.players + 1)]
    L.make_accounts(names)
    ref_json = Path(L.HERE / "out" / "referee_live.json")
    ref_json.parent.mkdir(exist_ok=True)
    total = a.warmup + a.seconds + 8
    ref = L.RefereeProcess(dict(MAP_ID=1, SKILL=2, TIMER_TICS=0, ROTATION="E1M1", MONSTERS=1),
                           args=("--seconds", str(total), "--json", str(ref_json)))
    res = []
    try:
        if not ref.wait_for("ready in"):
            print("\n".join(ref.lines))
            return 1
        start_at = time.time() + 3 + a.warmup
        q = mp.Queue()
        procs = [mp.Process(target=bot, args=(n, i, start_at, a.seconds, not a.unpaced, q)) for i, n in enumerate(names)]
        for p in procs:
            p.start()
        res = [q.get(timeout=total + 120) for _ in procs]
        for p in procs:
            p.join(10)
        ref.p.wait(total + 30)
    finally:
        ref.stop()
        L.match_cleanup()
        print("accounts:", L.drop_accounts(names))
    rj = json.loads(ref_json.read_text()) if ref_json.exists() else {}
    mode = "unpaced" if a.unpaced else "paced 35 Hz"
    print(f"{a.players} players through the API, {mode}, {a.seconds:.0f} s measured")
    print(f"referee: {rj.get('tics_per_s', 0):.2f} tics/s, tic mean {rj.get('tic_mean', 0):.2f} p50 {rj.get('tic_p50', 0):.2f} "
          f"p95 {rj.get('tic_p95', 0):.2f} max {rj.get('tic_max', 0):.2f} ms; late {rj.get('late')}, dropped "
          f"{rj.get('dropped')}, retried {rj.get('retried')}")
    out = {"players": a.players, "mode": mode, "seconds": a.seconds, "referee": {k: v for k, v in rj.items() if k != "tic_ms"},
           "per_player": {}}
    allf, allw, allp = [], [], []
    for r in sorted(res, key=lambda r: r["slot"]):
        fs, ws, ps = stats(r["frame_ms"]), stats(r["work_ms"]), stats(r["period_ms"])
        allf += r["frame_ms"]; allw += r["work_ms"]; allp += r["period_ms"]
        print(f"  slot {r['slot']} {r['name']}: {r['fps']:.1f} frames/s; frame (input+camera+frame) mean {fs['mean']:.1f} "
              f"p50 {fs['p50']:.1f} p95 {fs['p95']:.1f} p99 {fs['p99']:.1f} ms, {fs['within_pct']:.1f}% <= 28.6 ms; "
              f"period work (state+frame) mean {ws['mean']:.1f} p95 {ws['p95']:.1f}, {ws['within_pct']:.1f}% <= 28.6; "
              f"period mean {ps['mean']:.1f}; errors {r['errors']}, empty {r['empty']}")
        out["per_player"][r["name"]] = {"slot": r["slot"], "fps": r["fps"], "frame": fs, "work": ws, "period": ps,
                                        "errors": r["errors"], "empty": r["empty"]}
    out["frame_all"], out["work_all"], out["period_all"] = stats(allf), stats(allw), stats(allp)
    print(f"all players: frame mean {out['frame_all']['mean']:.1f} p95 {out['frame_all']['p95']:.1f}, "
          f"{out['frame_all']['within_pct']:.1f}% <= 28.6 ms; work mean {out['work_all']['mean']:.1f} "
          f"p95 {out['work_all']['p95']:.1f}, {out['work_all']['within_pct']:.1f}% <= 28.6 ms; "
          f"{sum(r['fps'] for r in res):.0f} frames/s total")
    retried = [l for l in ref.lines if "retried" in l or "dropped a tic" in l]
    for l in retried[:5]:
        print("  " + l[:240])
    if a.json:
        a.json.write_text(json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
