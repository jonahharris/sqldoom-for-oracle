"""Find the first CTE in a renderer that fails to parse (Oracle often reports offset 0)."""
import re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora, oracledb
sql, _ = doomora.load_sql(sys.argv[1])
body = sql[sql.index("WITH") + 4:]
# CTE starts: a line beginning with identifier AS (
starts = [m.start() for m in re.finditer(r"(?m)^([a-z_0-9]+) AS \(", body)]
names = [re.match(r"([a-z_0-9]+)", body[s:]).group(1) for s in starts]
c = doomora.connect(); cur = c.cursor()
for k in range(len(starts)):
    end = starts[k + 1] if k + 1 < len(starts) else None
    chunk = re.sub(r"(\s*--[^\n]*)*\s*$", "", body[:end]).rstrip().rstrip(",") if end else None
    if chunk is None:
        break
    q = "WITH " + chunk + f"\nSELECT * FROM {names[k]}"
    try:
        cur.parse(q)
    except oracledb.DatabaseError as e:
        print("FAIL at CTE", names[k], ":", e.args[0].message.splitlines()[0])
        seg = body[starts[k]:end]
        print(seg[:3000])
        break
else:
    print("all CTEs parse; final SELECT is the problem")
