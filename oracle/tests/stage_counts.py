"""Row count and (cumulative) time of every CTE stage of a renderer, for one tic.

    python tests/stage_counts.py render_optimized.sql [tic] [--only name,name] [--timeout-ms 20000]
Each stage is measured as WITH <all CTEs up to it> SELECT COUNT(*) FROM <stage> (so times
include upstream stages; Oracle may merge/prune differently than in the full query).
"""
import argparse, re, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora, oracledb

ap = argparse.ArgumentParser()
ap.add_argument("renderer"); ap.add_argument("tic", nargs="?", type=int, default=300)
ap.add_argument("--only"); ap.add_argument("--timeout-ms", type=int, default=20000)
a = ap.parse_args()
sql, _ = doomora.load_sql(a.renderer)
body = sql[sql.index("WITH") + 4:]
starts = [m.start() for m in re.finditer(r"(?m)^([a-z_0-9]+) AS \(", body)]
names = [re.match(r"([a-z_0-9]+)", body[s:]).group(1) for s in starts]
only = set(a.only.split(",")) if a.only else None
conn = doomora.connect(); conn.call_timeout = a.timeout_ms; cur = conn.cursor()
pose = doomora.load_poses()[a.tic]
binds = doomora.Renderer.binds(None, a.tic, pose)
for k, name in enumerate(names):
    if only and name not in only:
        continue
    end = starts[k + 1] if k + 1 < len(starts) else body.rindex("\nSELECT")
    chunk = re.sub(r"(\s*--[^\n]*)*\s*$", "", body[:end]).rstrip().rstrip(",")
    q = "WITH " + chunk + f"\nSELECT COUNT(*) FROM {name}"
    used = {b: v for b, v in binds.items() if f":{b}" in q}
    t = time.perf_counter()
    try:
        cur.execute(q, used); n = cur.fetchone()[0]
        print(f"{name:18s} {n:9d} rows {1e3*(time.perf_counter()-t):9.1f} ms", flush=True)
    except oracledb.DatabaseError as e:
        print(f"{name:18s} ERROR/timeout after {1e3*(time.perf_counter()-t):.0f} ms: {e.args[0].message.splitlines()[0]}", flush=True)
        conn = doomora.connect(); conn.call_timeout = a.timeout_ms; cur = conn.cursor()
