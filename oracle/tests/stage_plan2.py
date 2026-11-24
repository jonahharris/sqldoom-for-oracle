"""Actual plan (statistics_level=ALL) of COUNT(*) FROM <stage> using the full CTE list; prints
the operations with many rows or many starts."""
import re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
name, st = sys.argv[1], sys.argv[2]; tic = int(sys.argv[3]) if len(sys.argv) > 3 else 300
sql, _ = doomora.load_sql(name); i = sql.rindex("\nSELECT ")
q = sql[:i] + f"\nSELECT COUNT(*) FROM {st}" if st != "FULL" else sql
conn = doomora.connect(); cur = conn.cursor(); cur.execute("ALTER SESSION SET statistics_level = ALL")
b = doomora.Renderer.binds(None, tic, doomora.load_poses()[tic])
for _ in range(3):
    cur.execute(q, {k: v for k, v in b.items() if f":{k}" in q}); cur.fetchall()
cur.execute("SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'))")
for (l,) in cur:
    m = re.match(r"\|\*?\s*(\d+) \|.*?\|.*?\|\s*(\d+)\s*\|\s*(\d*)\s*\|\s*(\d+)\s*\|", l)
    if m and (int(m[4]) >= 1000 or int(m[2]) >= 100) or l.startswith("| Id"):
        print(l[:160])
