"""Actual execution plan (ALLSTATS LAST) of one CTE stage of a renderer, or the full query."""
import argparse, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
ap = argparse.ArgumentParser(); ap.add_argument("renderer"); ap.add_argument("stage")
ap.add_argument("tic", nargs="?", type=int, default=300); ap.add_argument("--fmt", default="ALLSTATS LAST")
a = ap.parse_args()
sql, _ = doomora.load_sql(a.renderer)
if a.stage == "FULL":
    q = sql.replace("WITH", "WITH", 1)
    q = "SELECT /*+ GATHER_PLAN_STATISTICS */ COUNT(*) FROM (" + q + ")"
else:
    body = sql[sql.index("WITH") + 4:]
    starts = [m.start() for m in re.finditer(r"(?m)^([a-z_0-9]+) AS \(", body)]
    names = [re.match(r"([a-z_0-9]+)", body[s:]).group(1) for s in starts]
    k = names.index(a.stage)
    end = starts[k + 1] if k + 1 < len(starts) else body.rindex("\nSELECT")
    chunk = re.sub(r"(\s*--[^\n]*)*\s*$", "", body[:end]).rstrip().rstrip(",")
    q = "WITH " + chunk + f"\nSELECT /*+ GATHER_PLAN_STATISTICS */ COUNT(*) FROM {a.stage}"
conn = doomora.connect(); cur = conn.cursor()
b = doomora.Renderer.binds(None, a.tic, doomora.load_poses()[a.tic])
cur.execute(q, {k: v for k, v in b.items() if f":{k}" in q}); cur.fetchall()
cur.execute("SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, :f))", f=a.fmt)
for (l,) in cur:
    print(l)
