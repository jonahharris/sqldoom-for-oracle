"""Build a renderer SQL from a saved parts directory: build_variant.py <dir> -> sql/variants/<dir>.sql"""
import re, sys
from pathlib import Path
D = Path(__file__).resolve().parent; src = D / sys.argv[1]
parts = ["opt_frontend.sql", "opt_background.sql", "hud.sql", "opt_pixels.sql"]
body = [(src / p).read_text().strip() + ("," if p == "hud.sql" else "") for p in parts]
text = "\n".join(body)
for name in [l.strip() for l in (src / "materialize.txt").read_text().splitlines() if l.strip() and not l.startswith("#")]:
    m = re.search(r"(?m)^" + name + r" AS \(\s*(--[^\n]*\s*)*SELECT", text); assert m, name
    text = text[:m.end()] + " /*+ MATERIALIZE */" + text[m.end():]
(D / (sys.argv[1] + ".sql")).write_text("-- @output packed\nWITH\n" + text + "\n")
