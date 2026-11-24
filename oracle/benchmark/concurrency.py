#!/usr/bin/env python3
"""Concurrent hybrid rendering: N sessions (own process + connection each) render different tics.

    python benchmark/concurrency.py [--sessions 1,2,4] [--sql render_hybrid.sql] [--label x]

Session k of N renders the tics t of 1..1200 with t % N == k (interleaved, so every session gets
the same mix of light and heavy scenes). Each session first renders its whole list once (warm:
static caches, cursor), then all sessions start the timed pass together (barrier). Reported per
N: per-session frame latency (client execute+fetch+decode, ms: mean/p50/p95/p99/max), total
throughput (frames / wall time of the timed pass), and per-session memory (V$MYSTAT session
pga/uga memory and their max after the run). Oracle Free caps the instance at 2 CPUs.
Results: benchmark/results/<label>.json (default concurrency_<sql stem>).
"""
import argparse, json, multiprocessing as mp, statistics, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client"))


def pct(v, p):
    v = sorted(v); return v[min(len(v) - 1, int(round(p / 100.0 * (len(v) - 1))))]


def worker(k, n, sql, barrier, q):
    import doomora
    conn = doomora.connect(); cur = conn.cursor(); r = doomora.Renderer(conn, sql); poses = doomora.load_poses()
    tics = [t for t in range(1, 1201) if t % n == k and t in poses]
    t0 = time.perf_counter(); r.render(tics[0], poses[tics[0]]); first = (time.perf_counter() - t0) * 1e3
    for t in tics: r.render(t, poses[t])
    barrier.wait()
    ms = []; w0 = time.perf_counter()
    for t in tics:
        r.render(t, poses[t]); ms.append(r.last["total_ms"])
    wall = time.perf_counter() - w0
    cur.execute("""SELECT n.name, s.value FROM v$mystat s JOIN v$statname n ON n.statistic# = s.statistic#
                   WHERE n.name IN ('session pga memory', 'session pga memory max', 'session uga memory',
                                    'session uga memory max', 'CPU used by this session')""")
    st = dict(cur.fetchall())
    q.put({"session": k, "frames": len(ms), "first_frame_ms": round(first, 1), "wall_s": wall, "ms": ms,
           "mem_mb": {kk: round(v / 1048576, 2) for kk, v in st.items() if "memory" in kk},
           "cpu_s": st.get("CPU used by this session", 0) / 100.0})


def sysevents():
    import oracledb, doomora
    c = oracledb.connect(user="system", password="DoomSys_26ai", dsn=doomora.DSN); cur = c.cursor()
    cur.execute("""SELECT event, total_waits, time_waited_micro FROM v$system_event
                   WHERE event IN ('resmgr:cpu quantum', 'latch free', 'library cache: mutex X', 'cursor: pin S')""")
    r = {e: (w, t) for e, w, t in cur.fetchall()}; c.close(); return r


def run(n, sql):
    ev0 = sysevents()
    ctx = mp.get_context("spawn"); barrier = ctx.Barrier(n); q = ctx.Queue()
    ps = [ctx.Process(target=worker, args=(k, n, sql, barrier, q)) for k in range(n)]
    for p in ps: p.start()
    res = [q.get() for _ in ps]
    for p in ps: p.join()
    res.sort(key=lambda d: d["session"])
    allms = [x for d in res for x in d["ms"]]
    wall = max(d["wall_s"] for d in res)
    ev1 = sysevents()
    waits = {e: {"waits": ev1[e][0] - ev0.get(e, (0, 0))[0], "ms": round((ev1[e][1] - ev0.get(e, (0, 0))[1]) / 1e3)}
             for e in ev1}
    out = {"sessions": n, "frames": len(allms), "frames_over_33ms": sum(x > 33 for x in allms),
           "frames_over_100ms": sum(x > 100 for x in allms), "wait_events_delta": waits, "wall_s": round(wall, 2),
           "throughput_fps": round(len(allms) / wall, 1),
           "latency_ms": {"mean": round(statistics.fmean(allms), 2), "p50": round(pct(allms, 50), 2),
                          "p95": round(pct(allms, 95), 2), "p99": round(pct(allms, 99), 2), "max": round(max(allms), 2)},
           "per_session": [{"session": d["session"], "frames": d["frames"], "first_frame_ms": d["first_frame_ms"],
                            "mean_ms": round(statistics.fmean(d["ms"]), 2), "p95_ms": round(pct(d["ms"], 95), 2),
                            "max_ms": round(max(d["ms"]), 2), "fps": round(d["frames"] / d["wall_s"], 1),
                            "mem_mb": d["mem_mb"]} for d in res],
           "mem_per_session_mb": {"pga_mean": round(statistics.fmean(d["mem_mb"]["session pga memory"] for d in res), 1),
                                  "pga_max_max": round(max(d["mem_mb"]["session pga memory max"] for d in res), 1)}}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sessions", default="1,2,4"); ap.add_argument("--sql", default="render_hybrid.sql")
    ap.add_argument("--label")
    a = ap.parse_args()
    label = a.label or f"concurrency_{Path(a.sql).stem}"
    results = []
    for n in [int(x) for x in a.sessions.split(",")]:
        o = run(n, a.sql); results.append(o)
        print(f"N={n}: {o['throughput_fps']} FPS total, latency mean {o['latency_ms']['mean']} p95 {o['latency_ms']['p95']} "
              f"max {o['latency_ms']['max']} ms, PGA/session {o['mem_per_session_mb']['pga_mean']} MB "
              f"(max {o['mem_per_session_mb']['pga_max_max']}); >33ms {o['frames_over_33ms']}, >100ms {o['frames_over_100ms']}, "
              f"waits {o['wait_events_delta']}", flush=True)
    out = HERE / "results" / f"{label}.json"
    out.write_text(json.dumps({"sql": a.sql, "runs": results}, indent=1))
    print("wrote", out)


if __name__ == "__main__":
    main()
