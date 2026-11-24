#!/usr/bin/env python3
"""Benchmark an Oracle renderer over the deterministic TPC-DOOM E1M1 run (1,200 tics).

    python benchmark/bench.py render_optimized.sql [--tics 1-1200] [--warmup 120] [--label x]

Modes (all on ONE connection and ONE prepared cursor, warm database):
  A  database-only  : server elapsed per execution from V$SQL deltas (no client work), and
                      client-observed execute+fetch (the round trip, no decode)
  B  end-to-end     : bind -> execute -> fetch -> decode to palette indices -> display-ready
                      RGB framebuffer (palette lookup). No sleeps. Sustained FPS = frames / wall.
Per-frame percentiles are reported for B and for execute+fetch; per-scene groups are reported
using scene tags derived from the reference cardinalities (benchmark/scenes.py).
Results: benchmark/results/<label>.json
"""
import argparse
import json
import statistics
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client"))
sys.path.insert(0, str(HERE.parent / "tests"))
import doomora  # noqa: E402
import framecmp  # noqa: E402


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p / 100.0 * (len(v) - 1))))]


def summarize(ms, wall_s=None):
    out = {"n": len(ms), "mean": statistics.fmean(ms), "p50": pct(ms, 50), "p95": pct(ms, 95),
           "p99": pct(ms, 99), "min": min(ms), "max": max(ms)}
    if wall_s:
        out["sustained_fps"] = len(ms) / wall_s
    return {k: round(v, 3) for k, v in out.items()}


def sql_stats(cur, sql_text):
    """Cumulative V$SQL counters for the renderer cursor (all child cursors)."""
    cur.execute("""SELECT NVL(SUM(executions),0), NVL(SUM(parse_calls),0), NVL(SUM(loads),0),
                          NVL(SUM(elapsed_time),0), NVL(SUM(cpu_time),0), NVL(SUM(buffer_gets),0),
                          NVL(SUM(rows_processed),0), COUNT(*), MAX(sql_id)
                   FROM v$sql WHERE sql_fulltext LIKE :p AND sql_text NOT LIKE '%v$sql%'""",
                p=sql_text[:200].replace("%", "\\%") + "%")
    r = cur.fetchone()
    keys = ("executions", "parse_calls", "loads", "elapsed_us", "cpu_us", "buffer_gets", "rows", "children", "sql_id")
    return dict(zip(keys, r))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("renderer")
    ap.add_argument("--tics", default="1-1200")
    ap.add_argument("--warmup", type=int, default=120)
    ap.add_argument("--label")
    ap.add_argument("--step", type=int, default=1, help="sample every Nth tic (slow renderers)")
    ap.add_argument("--run", default=str(HERE.parent / "reference_data" / "e1m1"))
    args = ap.parse_args()
    run = Path(args.run)
    meta = json.loads((run / "run.json").read_text())
    poses = doomora.load_poses(run)
    a, _, b = args.tics.partition("-")
    tics = list(range(int(a), int(b or a) + 1, args.step))
    pal = framecmp.playpal()

    conn = doomora.connect()
    mon = conn.cursor()
    split = "split" in Path(args.renderer).stem
    if split:   # one frame, two sessions (column ranges) in parallel: doomora.SplitRenderer
        r = doomora.SplitRenderer(conn, doomora.connect(), args.renderer)
        r.cur = r.curs[0]
    else:
        r = doomora.Renderer(conn, args.renderer)
    kw = dict(map_id=meta["map_id"], player_id=meta["player_thing_id"], skill=meta["skill"])

    # warm-up (parses the cursor once, warms buffer cache / IM / PGA)
    t0 = time.perf_counter()
    first = None
    for tic in tics[:args.warmup]:
        r.render(tic, poses[tic], **kw)
        first = first or r.last["total_ms"]
    warm_s = time.perf_counter() - t0
    try:
        before = sql_stats(mon, r.sql)
    except Exception:  # V$SQL access may need a grant
        before = None

    # timed run: end-to-end, display-ready RGB
    rec = []
    t0 = time.perf_counter()
    for tic in tics[args.warmup:]:
        s = time.perf_counter()
        frame, p = r.render(tic, poses[tic], **kw)
        rgb = pal[frame]  # display-ready framebuffer (palette -> RGB is allowed client work)
        e = (time.perf_counter() - s) * 1e3
        rec.append({"tic": tic, "e2e_ms": e, **r.last})
    wall = time.perf_counter() - t0
    after = sql_stats(mon, r.sql) if before else None

    e2e = [x["e2e_ms"] for x in rec]
    xf = [x["exec_ms"] + x["fetch_ms"] for x in rec]
    res = {"renderer": args.renderer, "encoding": r.encoding, "frames": len(rec), "warmup_frames": args.warmup,
           "warmup_s": round(warm_s, 3), "first_frame_ms": round(first or 0, 3),
           "end_to_end": summarize(e2e, wall),
           "execute_fetch": summarize(xf),
           "execute": summarize([x["exec_ms"] for x in rec]),
           "fetch": summarize([x["fetch_ms"] for x in rec]),
           "decode": summarize([x["decode_ms"] for x in rec])}
    if split:
        res["split_column"] = summarize([x["split"] for x in rec])
        res["half_a"] = summarize([x["half_a_ms"] for x in rec])
        res["half_b"] = summarize([x["half_b_ms"] for x in rec])
    if after:
        d = {k: after[k] - before[k] for k in ("executions", "parse_calls", "loads", "elapsed_us", "cpu_us",
                                              "buffer_gets", "rows")}
        n = max(1, d["executions"])
        res["v$sql"] = {"sql_id": after["sql_id"], "child_cursors": after["children"],
                        "executions": d["executions"], "parse_calls": d["parse_calls"],
                        "hard_parses(loads)": d["loads"],
                        "db_elapsed_ms_per_exec": round(d["elapsed_us"] / n / 1e3, 3),
                        "db_cpu_ms_per_exec": round(d["cpu_us"] / n / 1e3, 3),
                        "buffer_gets_per_exec": round(d["buffer_gets"] / n, 1),
                        "rows_per_exec": round(d["rows"] / n, 1)}
        res["database_only_fps"] = round(1000.0 / max(1e-9, d["elapsed_us"] / n / 1e3), 2)
    res["end_to_end_fps"] = round(res["end_to_end"]["sustained_fps"], 2)
    res["per_frame"] = [{k: (round(v, 3) if isinstance(v, float) else v) for k, v in x.items()} for x in rec]
    label = args.label or Path(args.renderer).stem
    out = HERE / "results" / f"{label}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(res, indent=1))
    show = {k: v for k, v in res.items() if k != "per_frame"}
    print(json.dumps(show, indent=1))


if __name__ == "__main__":
    main()
