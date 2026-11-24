"""Per-phase timings of the hybrid renderer (doom_hybrid debug timing), hot, per tic.

    python tests/hybrid_phases.py [tics] [reps]
Prints client exec/total and the median of each PL/SQL phase (ms) per tic.
"""
import statistics, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
tics = [int(t) for t in (sys.argv[1] if len(sys.argv) > 1 else "100,300,500,700,900,1100").split(",")]
reps = int(sys.argv[2]) if len(sys.argv) > 2 else 5
conn = doomora.connect(); r = doomora.Renderer(conn, "render_hybrid.sql"); poses = doomora.load_poses()
cur = conn.cursor(); cur.execute("begin doom_hybrid.set_debug(1); end;")
r.render(tics[0], poses[tics[0]])
allph = {}
for t in tics:
    ph = {}; tot = []
    for _ in range(reps):
        r.render(t, poses[t]); tot.append(r.last["total_ms"])
        cur.execute("select doom_hybrid.timings from dual")
        for kv in cur.fetchone()[0].split():
            k, v = kv.split("="); ph.setdefault(k, []).append(float(v))
    line = " ".join(f"{k}={statistics.median(v):.1f}" for k, v in ph.items())
    print(f"tic {t:5d} total={statistics.median(tot):.1f}  {line}")
    for k, v in ph.items(): allph.setdefault(k, []).append(statistics.median(v))
print("mean   ", " ".join(f"{k}={statistics.mean(v):.1f}" for k, v in allph.items()))
cur.execute("begin doom_hybrid.set_debug(0); end;")
