#!/usr/bin/env python3
"""Per-stage timing of the Oracle game tic (doom_game.set_debug(1) / timings()) over the
TPC-DOOM E1M1 command stream. Prints mean / p95 / max microseconds per stage and the
client-side tic latency.

    game_profile.py [--tics 1200] [--warmup 120]
"""
import argparse, json, sys, time
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client"))
import oradb, game_api  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tics", type=int, default=1200)
    ap.add_argument("--warmup", type=int, default=120)
    ap.add_argument("--no-debug", action="store_true")
    ap.add_argument("--test-t", action="store_true",
                    help="TPC-DOOM test T: time execute_game_tic + fetch_sound_events + finish_game_tic")
    a = ap.parse_args()
    cmds = [c["command"] for c in json.loads((HERE / "run-e1m1-b-commands.json").read_text())]
    conn = oradb.connect(); cur = conn.cursor()
    game_api.setup_session(cur)
    game_api.level_start(cur, 1, 157, 2)
    if not a.no_debug:
        cur.execute("BEGIN doom_game.set_debug(1); END;")
    stages, lat = defaultdict(list), []
    tv = cur.var(str)
    cursor = 0
    for i in range(a.tics):
        t0 = time.perf_counter()
        due = game_api.run_tic(cur, 1, 157, (2, *cmds[i][1:]))
        conn.commit()
        if a.test_t:
            if due:
                ev = game_api.sound_events(cur, 1, 157, cursor)
                if ev:
                    cursor = max(e[0] for e in ev)
            game_api.finish_tic(cur, 1, 157)
        lat.append((time.perf_counter() - t0) * 1e3)
        if not a.no_debug:
            cur.execute("BEGIN :t := doom_game.timings; END;", t=tv)
            if i >= a.warmup:
                for part in (tv.getvalue() or "").split():
                    k, _, v = part.partition("=")
                    stages[k].append(int(v))
    for k, v in stages.items():
        v = sorted(v)
        print(f"{k:10s} mean {sum(v)/len(v):8.0f} us  p95 {v[int(len(v)*.95)]:7d}  max {v[-1]:7d}")
    m = sorted(lat[a.warmup:])
    print(f"{'test T (tic+sounds+finish)' if a.test_t else 'tic latency (client)'} mean {sum(m)/len(m):.2f} ms p50 {m[len(m)//2]:.2f} p95 {m[int(len(m)*.95)]:.2f} "
          f"max {m[-1]:.2f}; first tic {lat[0]:.1f} ms")


if __name__ == "__main__":
    main()
