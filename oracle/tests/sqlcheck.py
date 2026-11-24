"""Execute a renderer once and, on error, show the offending SQL position in context."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora, oracledb
name = sys.argv[1]; tic = int(sys.argv[2]) if len(sys.argv) > 2 else 300
conn = doomora.connect(); r = doomora.Renderer(conn, name)
poses = doomora.load_poses()
try:
    r.render(tic, poses[tic])
    print("ok", r.last)
except oracledb.DatabaseError as e:
    err = e.args[0]; off = getattr(err, "offset", 0)
    print(err.message)
    s = r.sql; line = s[:off].count("\n") + 1
    lines = s.split("\n")
    for i in range(max(0, line - 4), min(len(lines), line + 2)):
        print(f"{i+1:5d}{'>' if i+1 == line else ' '} {lines[i]}")
