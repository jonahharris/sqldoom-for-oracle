"""Sum doom_hybrid debug counters (n_* fields of timings()) over a run of tics.

    python tests/hybrid_debugsum.py [--first 1] [--last 1200] [--step 1]
Prints total and max per counter (e.g. n_slowflatpx: plane fragments outside the mod-table range).
"""
import argparse, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora

ap = argparse.ArgumentParser(); ap.add_argument("--first", type=int, default=1)
ap.add_argument("--last", type=int, default=1200); ap.add_argument("--step", type=int, default=1)
a = ap.parse_args()
conn = doomora.connect(); r = doomora.Renderer(conn, "render_hybrid.sql"); poses = doomora.load_poses()
cur = conn.cursor(); cur.execute("begin doom_hybrid.set_debug(1); end;")
tot, mx = {}, {}
for t in range(a.first, a.last + 1, a.step):
    if t not in poses: continue
    r.render(t, poses[t]); cur.execute("select doom_hybrid.timings from dual")
    for kv in cur.fetchone()[0].split():
        k, v = kv.split("=")
        if k.startswith("n_"):
            v = float(v); tot[k] = tot.get(k, 0) + v
            if v > mx.get(k, (-1, 0))[0]: mx[k] = (v, t)
for k in tot: print(f"{k:16s} total={tot[k]:.0f} max={mx[k][0]:.0f} (tic {mx[k][1]})")
