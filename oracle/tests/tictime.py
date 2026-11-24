"""Per-tic hot exec medians (ms) for one or more renderers, interleaved to cancel drift.
usage: tictime.py a.sql[,b.sql] [tics] [reps]"""
import statistics, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
names = sys.argv[1].split(","); tics = [int(t) for t in (sys.argv[2] if len(sys.argv) > 2 else "100,300,500,700,900,1100").split(",")]
reps = int(sys.argv[3]) if len(sys.argv) > 3 else 5
conn = doomora.connect(); poses = doomora.load_poses()
rs = [doomora.Renderer(conn, n) for n in names]
for r in rs: r.render(tics[0], poses[tics[0]])
res = {n: {} for n in names}
for t in tics:
    for _ in range(reps):
        for n, r in zip(names, rs):
            r.render(t, poses[t]); res[n].setdefault(t, []).append(r.last["exec_ms"])
for n in names:
    med = {t: statistics.median(v) for t, v in res[n].items()}
    print(f"{n:28s} " + " ".join(f"{t}:{m:.0f}" for t, m in med.items()) + f"  | mean {statistics.mean(med.values()):.1f} median {statistics.median(med.values()):.1f}")
