"""A/B hot timing of COUNT(*) FROM <stage> (or FULL) for the built renderer vs. textual variants.
usage: abtest.py <stage> <tic> <variants.py>   variants.py defines VARIANTS = {name: [(old, new), ...]}"""
import statistics, sys, time, runpy
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
st, tic, vf = sys.argv[1], int(sys.argv[2]), sys.argv[3]
V = {"base": []}; V.update(runpy.run_path(vf)["VARIANTS"])
sql, _ = doomora.load_sql("render_optimized.sql")
conn = doomora.connect(); cur = conn.cursor()
b = doomora.Renderer.binds(None, tic, doomora.load_poses()[tic])
qs = {}
for n, reps in V.items():
    s = sql
    for o, nw in reps:
        assert o in s, (n, o[:60]); s = s.replace(o, nw)
    i = s.rindex("\nSELECT ")
    qs[n] = (s[:i] + (f"\nSELECT {st}" if " " in st else f"\nSELECT COUNT(*) FROM {st}")) if st != "FULL" else s
import os
nonce = f"/* ab {time.time_ns()} */"
qs = {n: q.replace("WITH", "WITH " + nonce, 1) for n, q in qs.items()}
pt = int(os.environ.get("PARSE_TIC", "1"))   # parse every variant with the same peeked binds (bench parses at tic 1)
pb = doomora.Renderer.binds(None, pt, doomora.load_poses()[pt])
for n, q in qs.items():
    cur.execute(q, {k: v for k, v in pb.items() if f":{k}" in q}); cur.fetchall()
res = {n: [] for n in qs}
for rnd in range(8):
    for n, q in qs.items():
        t = time.perf_counter(); cur.execute(q, {k: v for k, v in b.items() if f":{k}" in q}); r = cur.fetchall()
        if rnd >= 2: res[n].append((time.perf_counter() - t) * 1e3)
        if rnd == 0 and st != "FULL": print(n, "rows", r[0][0])
for n, v in res.items(): print(f"{n:20s} {statistics.median(v):8.1f} ms")
