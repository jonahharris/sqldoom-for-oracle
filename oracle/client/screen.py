#!/usr/bin/env python3
"""Render the full-screen composites (doom_screen, sql/11_screens.sql) to PNG.

    python oracle/client/screen.py --screen title|main|episode|skill|load|save|help1|help2 [--cursor N] --out x.png
    python oracle/client/screen.py --automap MAP [--player ID] --out map.png       # current live state
    python oracle/client/screen.py --current --out x.png                           # whatever screen_state shows

--screen sets screen_state (and the cursor) first, as the menu would; the frame is one SELECT
(doom_screen.render_screen / render_automap), decoded with PLAYPAL. No pixel is computed here.
"""
import argparse, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "tests"))
import oradb, game_api, framecmp  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--screen")
    g.add_argument("--automap", type=int)
    g.add_argument("--current", action="store_true")
    ap.add_argument("--cursor", type=int, default=0)
    ap.add_argument("--player", type=int, default=None)
    ap.add_argument("--tics", type=int, default=0, help="the client's frame counter (skull blink)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    conn = oradb.connect()
    cur = conn.cursor()
    game_api.setup_session(cur)
    if a.screen:
        cur.execute("UPDATE screen_state SET screen = :s, cursor_index = :c WHERE id = 0", s=a.screen, c=a.cursor)
        conn.commit()
    t = time.perf_counter()
    if a.automap is not None:
        player = a.player
        if player is None:
            cur.execute(game_api.STAGES_SQL)
            player = next(p for m, _n, p in cur.fetchall() if m == a.automap)
        frame = game_api.render_automap(cur, a.automap, player)
    else:
        frame = game_api.render_screen(cur, a.tics)
    print(f"frame in {(time.perf_counter() - t) * 1e3:.1f} ms -> {a.out}")
    framecmp.save_png(frame, a.out)


if __name__ == "__main__":
    main()
