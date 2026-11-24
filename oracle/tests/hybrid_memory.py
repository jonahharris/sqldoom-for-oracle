"""Per-session memory of the hybrid renderer after rendering a run of tics.

    python tests/hybrid_memory.py [--sql render_hybrid.sql] [--step 1] [--first 1] [--last 1200] [--json out]

Fresh connection; renders the first tic (cold: package state load) and then every --step-th tic;
reports first-frame ms, hot mean ms and V$MYSTAT session pga/uga memory (current and max) before,
after the first frame and at the end, plus doom_hybrid.mem_info if the package has it.
"""
import argparse, json, statistics, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora

STATS = ("session pga memory", "session pga memory max", "session uga memory", "session uga memory max")


def mystat(cur):
    cur.execute("""SELECT n.name, s.value FROM v$mystat s JOIN v$statname n ON n.statistic# = s.statistic#
                   WHERE n.name IN ('session pga memory', 'session pga memory max',
                                    'session uga memory', 'session uga memory max')""")
    return {k: v / 1048576 for k, v in cur.fetchall()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sql", default="render_hybrid.sql")
    ap.add_argument("--step", type=int, default=1)
    ap.add_argument("--first", type=int, default=1)
    ap.add_argument("--last", type=int, default=1200)
    ap.add_argument("--json")
    a = ap.parse_args()
    conn = doomora.connect(); cur = conn.cursor(); r = doomora.Renderer(conn, a.sql); poses = doomora.load_poses()
    m0 = mystat(cur)
    t0 = time.perf_counter(); r.render(a.first, poses[a.first]); first = (time.perf_counter() - t0) * 1e3
    m1 = mystat(cur)
    times = []
    for t in range(a.first, a.last + 1, a.step):
        if t not in poses: continue
        r.render(t, poses[t]); times.append(r.last["total_ms"])
    m2 = mystat(cur)
    info = None
    try:
        cur.execute("SELECT doom_hybrid.mem_info FROM dual"); info = cur.fetchone()[0]
    except Exception:
        pass
    res = {"sql": a.sql, "first_frame_ms": round(first, 1), "frames": len(times),
           "mean_ms": round(statistics.mean(times), 2), "max_ms": round(max(times), 2),
           "p95_ms": round(sorted(times)[int(0.95 * (len(times) - 1))], 2),
           "mem_start_mb": {k: round(v, 2) for k, v in m0.items()},
           "mem_after_first_mb": {k: round(v, 2) for k, v in m1.items()},
           "mem_end_mb": {k: round(v, 2) for k, v in m2.items()}, "mem_info": info}
    print(json.dumps(res, indent=1))
    if a.json: Path(a.json).write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
