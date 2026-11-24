#!/usr/bin/env python3
"""Render frames with an Oracle renderer and write PNG / animated GIF.

    python oracle/client/render.py --tic 300 --out frame.png
    python oracle/client/render.py --tics 100-400 --out run.gif            # every tic, 35 fps GIF
    python oracle/client/render.py --tic 300 --pose -416,256,41,90 --out custom.png
    python oracle/client/render.py --renderer render_baseline.sql --tic 300 --out base.png

The world state (sectors, things, monsters, weapon, status bar values) comes from the recorded
per-tic snapshot (--tic); the camera pose defaults to that tic's pose but can be any pose.
The client only binds state, executes the prepared renderer, decodes palette indices and maps
them to RGB through PLAYPAL (honouring the frame's damage/bonus palette).
"""
import argparse
import struct
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import doomora  # noqa: E402

ROOT = HERE.parent


def playpals(wad=ROOT / "wad" / "freedoom1.wad"):
    data = Path(wad).read_bytes()
    n, off = struct.unpack_from("<ii", data, 4)
    for i in range(n):
        pos, size, name = struct.unpack_from("<ii8s", data, off + 16 * i)
        if name.rstrip(b"\0") == b"PLAYPAL":
            return np.frombuffer(data[pos:pos + size], np.uint8).reshape(-1, 256, 3)
    raise KeyError("PLAYPAL")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--renderer", default="render_optimized.sql")
    ap.add_argument("--tic", type=int)
    ap.add_argument("--tics", help="a-b range for an animation")
    ap.add_argument("--pose", help="x,y,z,angle (overrides the recorded pose)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--scale", type=int, default=2)
    a = ap.parse_args()
    pals = playpals()
    poses = doomora.load_poses()
    conn = doomora.connect()
    r = doomora.Renderer(conn, a.renderer)
    if a.tics:
        lo, hi = map(int, a.tics.split("-"))
        tics = list(range(lo, hi + 1))
    else:
        tics = [a.tic or 1]
    imgs, ms = [], []
    for t in tics:
        pose = tuple(float(v) for v in a.pose.split(",")) if a.pose else poses[t]
        frame, pal = r.render(t, pose)
        ms.append(r.last["total_ms"])
        img = Image.fromarray(pals[pal][frame])
        imgs.append(img.resize((320 * a.scale, 200 * a.scale), Image.NEAREST) if a.scale > 1 else img)
    if len(imgs) == 1:
        imgs[0].save(a.out)
    else:
        imgs[0].save(a.out, save_all=True, append_images=imgs[1:], duration=int(1000 / 35), loop=0)
    print(f"{len(imgs)} frame(s) -> {a.out}; median {sorted(ms)[len(ms) // 2]:.1f} ms/frame")


if __name__ == "__main__":
    main()
