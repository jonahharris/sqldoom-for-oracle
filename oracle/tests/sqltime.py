"""Hot timing of an ad-hoc SQL file (WITH ... SELECT) with renderer binds for a tic.
usage: sqltime.py file.sql [tic] [reps]  -- prints median ms and first rows"""
import statistics, sys, time, re
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
q = Path(sys.argv[1]).read_text().strip().rstrip(";"); tic = int(sys.argv[2]) if len(sys.argv) > 2 else 300
reps = int(sys.argv[3]) if len(sys.argv) > 3 else 7
conn = doomora.connect(); cur = conn.cursor()
b = doomora.Renderer.binds(None, tic, doomora.load_poses()[tic]); b = {k: v for k, v in b.items() if re.search(":" + k + r"\b", q)}
ts = []
for _ in range(reps):
    t = time.perf_counter(); cur.execute(q, b); r = cur.fetchall(); ts.append((time.perf_counter() - t) * 1e3)
print(f"median {statistics.median(ts[2:]):.2f} ms first {ts[0]:.0f}", r[:5])
