"""Frame comparison in 8-bit palette-index space (after COLORMAP).

A frame is 64,000 bytes: 320x200 row-major palette indices, rows 0..167 the 3-D view,
168..199 the status bar. Ground truth comes from CedarDB (tests/record_reference.py).
"""
import hashlib
import struct
from pathlib import Path

import numpy as np

W, H, VIEW_H = 320, 200, 168
ROOT = Path(__file__).resolve().parents[1]
REF = ROOT / "reference_data" / "e1m1"


def playpal(wad=ROOT / "wad" / "freedoom1.wad"):
    """PLAYPAL palette 0 as a (256,3) uint8 array, read straight from the WAD."""
    data = Path(wad).read_bytes()
    n, off = struct.unpack_from("<ii", data, 4)
    for i in range(n):
        pos, size, name = struct.unpack_from("<ii8s", data, off + 16 * i)
        if name.rstrip(b"\0") == b"PLAYPAL":
            return np.frombuffer(data[pos:pos + 768], np.uint8).reshape(256, 3)
    raise KeyError("PLAYPAL")


def load_ref(tic, root=REF):
    return np.frombuffer((root / "frames_idx" / f"{tic:05d}.idx").read_bytes(), np.uint8).reshape(H, W)


def digest(frame):
    return hashlib.sha256(np.ascontiguousarray(frame, np.uint8).tobytes()).hexdigest()[:16]


def compare(got, ref):
    """Return a dict of mismatch statistics between two (200,320) index frames."""
    got = np.asarray(got, np.uint8).reshape(H, W)
    ref = np.asarray(ref, np.uint8).reshape(H, W)
    diff = got != ref
    n = int(diff.sum())
    out = {"mismatch": n, "pct": 100.0 * n / (W * H), "view_mismatch": int(diff[:VIEW_H].sum()),
           "hud_mismatch": int(diff[VIEW_H:].sum()), "hash": digest(got), "ref_hash": digest(ref)}
    if n:
        ys, xs = np.nonzero(diff)
        out["bbox"] = (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()))
        # worst 16x16 tile, to localise clustered errors
        tiles = diff.reshape(H // 8, 8, W // 16, 16).sum(axis=(1, 3))
        ty, tx = np.unravel_index(int(tiles.argmax()), tiles.shape)
        out["worst_tile"] = (int(tx) * 16, int(ty) * 8, int(tiles.max()))
        out["cols_affected"] = int(np.unique(xs).size)
    return out


def save_png(frame, path, pal=None):
    from PIL import Image
    pal = playpal() if pal is None else pal
    Image.fromarray(pal[np.asarray(frame, np.uint8).reshape(H, W)]).save(path)


def save_diff_png(got, ref, path, pal=None):
    """Side by side: got | ref | mismatches in red over a dimmed reference."""
    from PIL import Image
    pal = playpal() if pal is None else pal
    g = pal[np.asarray(got, np.uint8).reshape(H, W)]
    r = pal[np.asarray(ref, np.uint8).reshape(H, W)]
    d = (r // 3).copy()
    d[np.asarray(got).reshape(H, W) != np.asarray(ref).reshape(H, W)] = (255, 0, 0)
    Image.fromarray(np.concatenate([g, r, d], axis=1)).save(path)
