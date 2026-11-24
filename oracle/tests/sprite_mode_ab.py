#!/usr/bin/env python3
"""Interleaved A/B of doom_hybrid's sprite modes (p_mode 0 CedarDB-exact vs 1 vanilla), hot, one
connection, the installed package, the recorded TPC-DOOM E1M1 run.

    sprite_mode_ab.py [--step 10] [--rounds 3]          # every 10th tic
    sprite_mode_ab.py --sprite-heavy 60 [--rounds 5]     # the 60 tics with the most sprite columns

Per tic the two modes render alternately (order flipped every round, so host drift hits both);
the per-tic median (execute + fetch, ms) of each mode is summarised as mean / p50 / p95 / max and
the paired difference vanilla - exact (mean, p95, max).
"""
import argparse
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client"))
import doomora  # noqa: E402

SQL = ("SELECT y, pal, hex FROM TABLE(doom_hybrid.render_frame(:tic, :map_id, :player_id, :skill, :px, :py, :pz, "
       ":pangle, 0, 319, :smode))")


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--step", type=int, default=10)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--sprite-heavy", type=int, default=0, help="the N tics with the most sprite screen columns")
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()
    conn = doomora.connect()
    cur = conn.cursor()
    cur.arraysize, cur.prefetchrows = 256, 257
    poses = doomora.load_poses()
    import time

    def run(t, mode):
        x, y, z, an = poses[t]
        t0 = time.perf_counter()
        cur.execute(SQL, tic=t, map_id=1, player_id=157, skill=2, px=x, py=y, pz=z, pangle=an, smode=mode)
        cur.fetchall()
        return (time.perf_counter() - t0) * 1e3

    if a.sprite_heavy:
        cand = []
        for t in range(1, 1201, 2):
            if t not in poses:
                continue
            run(t, 0)
            cur.execute("SELECT hex FROM TABLE(doom_hybrid.debug_info('sprites'))")
            n = len(cur.fetchall())
            cand.append((n, t))
        tics = sorted(t for _n, t in sorted(cand, reverse=True)[:a.sprite_heavy])
        print(f"sprite-heavy sample: {len(tics)} tics, sprites per frame {min(n for n, _ in sorted(cand, reverse=True)[:a.sprite_heavy])}"
              f"..{max(n for n, _ in cand)}")
    else:
        tics = [t for t in range(1, 1201, a.step) if t in poses]
    for t in tics:                      # warm
        run(t, 0)
        run(t, 1)
    times = {0: {t: [] for t in tics}, 1: {t: [] for t in tics}}
    for rnd in range(a.rounds):
        for t in tics:
            for mode in ((0, 1) if (rnd + t) % 2 == 0 else (1, 0)):
                times[mode][t].append(run(t, mode))
    med = {m: [statistics.median(times[m][t]) for t in tics] for m in (0, 1)}
    out = {}
    for m, name in ((0, "exact"), (1, "vanilla")):
        v = med[m]
        out[name] = {"mean": statistics.mean(v), "p50": pct(v, 50), "p95": pct(v, 95), "max": max(v)}
        print(f"{name:8s} mean={out[name]['mean']:.2f} p50={out[name]['p50']:.2f} p95={out[name]['p95']:.2f} "
              f"max={out[name]['max']:.2f} ms  ({len(tics)} tics x {a.rounds} rounds)")
    d = [b - c for b, c in zip(med[1], med[0])]
    out["delta"] = {"mean": statistics.mean(d), "p95": pct(d, 95), "max": max(d),
                    "p95_of_modes": out["vanilla"]["p95"] - out["exact"]["p95"],
                    "max_of_modes": out["vanilla"]["max"] - out["exact"]["max"]}
    print(f"vanilla - exact: paired mean {out['delta']['mean']:+.3f} ms, paired p95 {out['delta']['p95']:+.3f}, "
          f"paired max {out['delta']['max']:+.3f}; p95 {out['delta']['p95_of_modes']:+.3f}, max {out['delta']['max_of_modes']:+.3f}")
    if a.json:
        a.json.write_text(json.dumps({"tics": tics, "rounds": a.rounds, **out}, indent=1))


if __name__ == "__main__":
    main()
