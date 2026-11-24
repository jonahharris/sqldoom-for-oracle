"""Render one tic with a renderer and print exec ms (hot, 3 runs)."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
name = sys.argv[1]; t = int(sys.argv[2]) if len(sys.argv) > 2 else 300
conn = doomora.connect(); r = doomora.Renderer(conn, name); p = doomora.load_poses()
for _ in range(3):
    r.render(t, p[t]); print(r.last["exec_ms"], r.last["rows"])
