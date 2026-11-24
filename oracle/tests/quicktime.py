"""Quick hot timing of a renderer over a few tics: exec / fetch / decode medians (ms)."""
import statistics, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
name = sys.argv[1]; tics = [int(t) for t in (sys.argv[2] if len(sys.argv) > 2 else "100,300,500,700,900,1100").split(",")]
reps = int(sys.argv[3]) if len(sys.argv) > 3 else 3
conn = doomora.connect(); r = doomora.Renderer(conn, name); poses = doomora.load_poses()
r.render(tics[0], poses[tics[0]])
acc = {"exec_ms": [], "fetch_ms": [], "decode_ms": [], "total_ms": []}
for t in tics:
    for _ in range(reps):
        r.render(t, poses[t])
        for k in acc: acc[k].append(r.last[k])
print(name, " ".join(f"{k}={statistics.median(v):.1f}" for k, v in acc.items()), f"rows={r.last['rows']}")
