"""Per-scene latency groups. Scene tags come from the REFERENCE renderer's own stage cardinalities
per tic (benchmark/results/cedar_stats_2cpu.json, every 5th tic): a tic is in a scene class when
its metric is in the top (or bottom) quartile of the run."""
import json, statistics, sys
from pathlib import Path
R = Path(__file__).resolve().parent / "results"
cs = {r["tic"]: r for r in json.loads((R / "cedar_stats_2cpu.json").read_text())}
def q(key, lo):
    v = sorted(r[key] for r in cs.values()); return v[len(v) // 4] if lo else v[3 * len(v) // 4]
classes = {
  "simple (few subsectors, bottom quartile)": lambda r: r["subsectors"] <= q("subsectors", True),
  "many visible subsectors (top quartile)": lambda r: r["subsectors"] >= q("subsectors", False),
  "high overdraw (fragments ranked, top quartile)": lambda r: r["fragments_ranked"] >= q("fragments_ranked", False),
  "many sprites (sprite px, top quartile)": lambda r: r["sprite_px"] >= q("sprite_px", False),
  "large open areas (plane px, top quartile)": lambda r: r["plane_px"] >= q("plane_px", False),
}
runs = sys.argv[1:] or ["final_baseline", "final_sql", "final_hybrid"]
print("| scene class | tics | " + " | ".join(f"{r} p50 / p95 ms" for r in runs) + " | CedarDB p50 ms |")
print("|---|---|" + "---|" * len(runs) + "---|")
data = {r: {f["tic"]: f["e2e_ms"] for f in json.loads((R / f"{r}.json").read_text())["per_frame"]} for r in runs}
for name, f in list(classes.items()) + [("all tics", lambda r: True)]:
    tics = [t for t, r in cs.items() if f(r)]
    cells = []
    for r in runs:
        v = sorted(data[r][t] for t in tics if t in data[r])
        cells.append(f"{statistics.median(v):.0f} / {v[int(0.95 * (len(v) - 1))]:.0f} (n={len(v)})" if v else "—")
    ced = statistics.median(cs[t]["ms"] for t in tics)
    print(f"| {name} | {len(tics)} | " + " | ".join(cells) + f" | {ced:.1f} |")
