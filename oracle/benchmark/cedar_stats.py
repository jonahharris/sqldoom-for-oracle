"""Replay the TPC-DOOM run on CedarDB and record, per tic, the reference renderer's
own stage cardinalities (its @stats-cut splice) and its frame latency (hot, prepared)."""
import json, statistics, sys, time
from pathlib import Path
import psycopg2
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "reference" / "sqldoom"))
import doom_sql as sql  # noqa

dsn = sys.argv[1]; out = Path(sys.argv[2]); every = int(sys.argv[3]) if len(sys.argv) > 3 else 5
cmds = [c["command"] for c in json.loads((HERE.parent / "tests" / "run-e1m1-b-commands.json").read_text())]
conn = psycopg2.connect(dsn); conn.autocommit = True; cur = conn.cursor()
sql.prepare_client(cur)
st = {s["label"]: s for s in sql.load_stages(cur)}["E1M1"]; m, p = st["map_id"], st["player_thing_id"]
sql.set_screen(cur, "game"); sql.enter_level(cur, m, p, 2)
for code in ("IDDQD", "IDKFA"): sql.cheat_code(cur, m, p, code)
sql.prepare_renderer(cur, m, p, 2); sql.prepare_render_stats(cur)
rows, ev = [], 0
for i in range(1200):
    if sql.execute_game_tic(cur, m, p, (2, *cmds[i][1:])):
        e, _ = sql.fetch_sound_events(cur, m, p, ev); ev = max([x[0] for x in e] + [ev])
    sql.finish_game_tic(cur, m, p)
    tic = i + 1
    if tic % every: continue
    pose = tuple(float(v) for v in sql.camera_pose(cur, m, p, 1.0))
    ts = []
    for _ in range(3):
        t = time.perf_counter(); sql.render_frame(cur, m, p, 2, pose, 320, 200, 1.0); ts.append((time.perf_counter() - t) * 1000)
    s = sql.fetch_render_stats(cur, m, p, 2, pose)
    s.pop("bsp_subsectors", None)
    rows.append({"tic": tic, "ms": min(ts), **{k: v for k, v in s.items() if isinstance(v, (int, float))}})
out.write_text(json.dumps(rows))
keys = [k for k in rows[0] if k != "tic"]
print("metric            median      p95       max")
for k in keys:
    v = sorted(r[k] for r in rows)
    print(f"{k:16s} {statistics.median(v):9.1f} {v[int(0.95*len(v))-1]:9.1f} {v[-1]:9.1f}")
