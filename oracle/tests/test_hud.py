"""Unit test: status-bar part (sql/parts/hud.sql) vs reference rows 168..199, every tic."""
import sys, time
from pathlib import Path
import numpy as np
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client")); sys.path.insert(0, str(HERE))
import doomora, framecmp
part = (HERE.parent / "sql" / "parts" / "hud.sql").read_text()
q = "WITH " + part.split("\n", 2)[2].strip().rstrip(",") + """
SELECT y, (SELECT pal FROM active_palette) pal, chunk, SUM(v) FROM (
  SELECT y, chunk, v FROM hud_static_packed UNION ALL SELECT y, chunk, v FROM hud_delta)
GROUP BY y, chunk"""
conn = doomora.connect(); cur = conn.cursor(); cur.arraysize = 1000
bad = 0; ts = []
step = int(sys.argv[1]) if len(sys.argv) > 1 else 1
for tic in range(1, 1201, step):
    t = time.perf_counter()
    cur.execute(q, tic=tic, map_id=1, player_id=157)
    frame, pal = doomora.decode_packed(cur.fetchall())
    ts.append((time.perf_counter() - t) * 1e3)
    ref = framecmp.load_ref(tic)
    n = int((frame[168:] != ref[168:]).sum())
    if n:
        bad += 1
        if bad <= 5: print("tic", tic, "mismatch", n)
print(f"frames with HUD mismatch: {bad}; median {np.median(ts):.2f} ms")
