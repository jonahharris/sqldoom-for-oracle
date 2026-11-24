"""Hot cumulative cost of renderer stages: final SELECT replaced by COUNT(*) FROM <stage>,
each variant executed N times (first runs parse/warm), median of the rest."""
import statistics, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
name = sys.argv[1]; stages = sys.argv[2].split(","); tic = int(sys.argv[3]) if len(sys.argv) > 3 else 300
sql, _ = doomora.load_sql(name)
i = sql.rindex("\nSELECT ")
conn = doomora.connect(); cur = conn.cursor()
b = doomora.Renderer.binds(None, tic, doomora.load_poses()[tic])
for st in stages:
    q = sql[:i] + f"\nSELECT COUNT(*) FROM {st}" if st != "FULL" else sql
    ts = []
    for k in range(7):
        t = time.perf_counter(); cur.execute(q, {k2: v for k2, v in b.items() if f":{k2}" in q}); r = cur.fetchall()
        ts.append((time.perf_counter() - t) * 1e3)
    print(f"{st:14s} {statistics.median(ts[3:]):8.1f} ms  (first {ts[0]:.0f})  rows={r[0][0] if st != 'FULL' else len(r)}", flush=True)
