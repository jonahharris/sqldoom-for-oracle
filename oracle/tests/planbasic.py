"""Uninstrumented plan of 'SELECT <tail>' (or FULL) over the built renderer's CTEs.
usage: planbasic.py "<tail or stage>" [tic] [fmt]"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
st = sys.argv[1]; tic = int(sys.argv[2]) if len(sys.argv) > 2 else 300
fmt = sys.argv[3] if len(sys.argv) > 3 else "BASIC +ROWS +PREDICATE"
import os; sql, _ = doomora.load_sql(os.environ.get("SQLF", "render_optimized.sql")); i = sql.rindex("\nSELECT ")
q = (sql[:i] + (f"\nSELECT {st}" if " " in st else f"\nSELECT COUNT(*) FROM {st}")) if st != "FULL" else sql
conn = doomora.connect(); cur = conn.cursor()
b = doomora.Renderer.binds(None, tic, doomora.load_poses()[tic])
cur.execute(q, {k: v for k, v in b.items() if f":{k}" in q}); cur.fetchall()
cur.execute("SELECT prev_sql_id, prev_child_number FROM v$session WHERE sid = SYS_CONTEXT('USERENV','SID')")
sid, ch = cur.fetchone()
cur.execute("SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(:a, :b, :c))", a=sid, b=ch, c=fmt)
for (l,) in cur: print(l)
