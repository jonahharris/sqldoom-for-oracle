#!/usr/bin/env python3
"""Compare renderers on the same tics: correctness vs CedarDB, frame-for-frame agreement
between renderers, and hot latency (execute+fetch+decode).

    python oracle/benchmark/compare.py render_baseline.sql render_optimized.sql --tics 1-1200 --step 50
"""
import argparse
import json
import statistics
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client"))
sys.path.insert(0, str(HERE.parent / "tests"))
import doomora  # noqa: E402
import framecmp  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("renderers", nargs="+")
    ap.add_argument("--tics", default="1-1200")
    ap.add_argument("--step", type=int, default=50)
    ap.add_argument("--reps", type=int, default=1)
    a = ap.parse_args()
    lo, hi = map(int, a.tics.split("-"))
    tics = list(range(lo, hi + 1, a.step))
    poses = doomora.load_poses()
    conn = doomora.connect()
    rs = [doomora.Renderer(conn, n) for n in a.renderers]
    for r in rs:  # parse + warm once
        r.render(tics[0], poses[tics[0]])
    res = {n: {"ms": [], "exact": 0, "mismatch": 0} for n in a.renderers}
    agree = 0
    for t in tics:
        ref = framecmp.load_ref(t)
        frames = []
        for r in rs:
            best = None
            for _ in range(a.reps):
                f, _p = r.render(t, poses[t])
                best = r.last["total_ms"] if best is None else min(best, r.last["total_ms"])
            res[r.name]["ms"].append(best)
            c = framecmp.compare(f, ref)
            res[r.name]["exact"] += c["mismatch"] == 0
            res[r.name]["mismatch"] += c["mismatch"]
            frames.append(f)
        agree += all(np.array_equal(frames[0], f) for f in frames[1:])
    out = {"tics": len(tics), "renderers_agree_on_frames": agree}
    for n, v in res.items():
        ms = sorted(v["ms"])
        out[n] = {"exact_vs_cedardb": f"{v['exact']}/{len(tics)}", "mismatched_px": v["mismatch"],
                  "median_ms": round(statistics.median(ms), 1), "p95_ms": round(ms[int(0.95 * (len(ms) - 1))], 1),
                  "max_ms": round(ms[-1], 1)}
    if len(rs) >= 2:
        b, o = out[a.renderers[0]]["median_ms"], out[a.renderers[-1]]["median_ms"]
        out["speedup_median"] = round(b / o, 1)
    print(json.dumps(out, indent=1))
    (HERE / "results").mkdir(exist_ok=True)
    (HERE / "results" / "compare.json").write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
