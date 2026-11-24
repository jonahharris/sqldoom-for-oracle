"""Run the full renderer once with GATHER_PLAN_STATISTICS and list plan lines by SELF time."""
import re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
name = sys.argv[1]; tic = int(sys.argv[2]) if len(sys.argv) > 2 else 300; top = int(sys.argv[3]) if len(sys.argv) > 3 else 25
sql, _ = doomora.load_sql(name)
q = sql  # identical text to the renderer; row-source stats via session statistics_level=ALL
conn = doomora.connect(); cur = conn.cursor()
cur.execute("ALTER SESSION SET statistics_level = ALL")
b = doomora.Renderer.binds(None, tic, doomora.load_poses()[tic])
for _ in range(4):
    cur.execute(q, b); cur.fetchall()
cur.execute("SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'))")
lines = [l for (l,) in cur]
out = Path(__file__).resolve().parents[1] / "analysis" / "plans"; out.mkdir(parents=True, exist_ok=True)
(out / f"{Path(name).stem}_tic{tic}.txt").write_text("\n".join(lines))
rows = []
for l in lines:
    m = re.match(r"\|\*?\s*(\d+) \|( *)(.*?)\s*\|\s*(.*?)\s*\|\s*(\d+)\s*\|\s*(\d*)\s*\|\s*(\d+)\s*\|(\d\d):(\d\d):(\d\d)\.(\d\d)", l)
    if m:
        i, ind, op, nm, st, er, ar = int(m[1]), len(m[2]), m[3], m[4], int(m[5]), m[6], int(m[7])
        t = int(m[8]) * 3600 + int(m[9]) * 60 + int(m[10]) + int(m[11]) / 100
        rows.append([i, ind, op, nm, st, er, ar, t])
# self time = time - sum(children time)
for k, r in enumerate(rows):
    ch = 0
    for r2 in rows[k + 1:]:
        if r2[1] <= r[1]: break
        if r2[1] == r[1] + 1: ch += r2[7]
    r.append(max(0.0, r[7] - ch))
total = rows[0][7] if rows else 0
print(f"total {total:.2f}s; plan saved to analysis/plans/")
for r in sorted(rows, key=lambda r: -r[8])[:top]:
    print(f"{r[0]:4d} self={r[8]:5.2f}s tot={r[7]:5.2f}s starts={r[4]:6d} E={r[5]:>6s} A={r[6]:8d}  {'  '*0}{r[2]} {r[3]}")
