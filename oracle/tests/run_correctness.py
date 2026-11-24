"""Render reference tics with an Oracle renderer and compare against CedarDB ground truth.

    python tests/run_correctness.py render_optimized.sql [--tics 1-1200] [--step 10] [--pngs N]

Exit status 0 only if every compared frame is pixel-exact (palette indices after COLORMAP)
and the frame palette (damage/bonus/radsuit flash) matches.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "client"))
import doomora  # noqa: E402
import framecmp  # noqa: E402

OUT = HERE / "out"


def expected_pal(run):
    """ST_doPaletteStuff, from the recorded player_state (same rule the renderer uses)."""
    t = pq.read_table(run / "state" / "player_state.parquet").to_pandas() if False else \
        pq.read_table(run / "state" / "player_state.parquet").to_pylist()
    pal = {}
    for r in t:
        d, b, rs = r["damage_count"] or 0, r["bonus_count"] or 0, r["radsuit_tics"] or 0
        if d > 0:
            p = min(7, (d + 7) // 8) + 1
        elif b > 0:
            p = min(3, (b + 7) // 8) + 9
        elif rs > 128 or (rs & 8):
            p = 13
        else:
            p = 0
        pal[r["tic"]] = p
    return pal


def parse_tics(spec, step):
    a, _, b = spec.partition("-")
    return list(range(int(a), int(b or a) + 1, step))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("renderer")
    ap.add_argument("--tics", default="1-1200")
    ap.add_argument("--step", type=int, default=1)
    ap.add_argument("--pngs", type=int, default=6, help="diff images for the N worst frames")
    ap.add_argument("--run", default=str(HERE.parent / "reference_data" / "e1m1"))
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--split-col", type=int, default=0,
                    help="render_hybrid_split.sql: fixed split column (default: adaptive, as SplitRenderer)")
    args = ap.parse_args()
    run = Path(args.run)
    poses = doomora.load_poses(run)
    meta = json.loads((run / "run.json").read_text())
    pals = expected_pal(run)
    conn = doomora.connect()
    if "split" in Path(args.renderer).stem:   # two sessions, one column range each
        r = doomora.SplitRenderer(conn, doomora.connect(), args.renderer, split=args.split_col or 160,
                                  adaptive=not args.split_col)
    else:
        r = doomora.Renderer(conn, args.renderer)
    results, worst = [], []
    for tic in parse_tics(args.tics, args.step):
        frame, pal = r.render(tic, poses[tic], map_id=meta["map_id"], player_id=meta["player_thing_id"],
                              skill=meta["skill"])
        ref = framecmp.load_ref(tic, run)
        c = framecmp.compare(frame, ref)
        c.update(tic=tic, pal=pal, pal_ok=(pal == pals.get(tic, 0)), ms=r.last["total_ms"])
        results.append(c)
        if c["mismatch"]:
            worst.append((c["mismatch"], tic, frame, ref))
        if not args.quiet and (c["mismatch"] or not c["pal_ok"]):
            print(f"tic {tic:5d}: {c['mismatch']:6d} px ({c['pct']:.3f}%) view={c['view_mismatch']} "
                  f"hud={c['hud_mismatch']} bbox={c.get('bbox')} pal={pal}/{pals.get(tic, 0)}", flush=True)
    worst.sort(key=lambda w: -w[0])
    OUT.mkdir(exist_ok=True)
    stem = Path(args.renderer).stem
    for n, tic, frame, ref in worst[:args.pngs]:
        framecmp.save_diff_png(frame, ref, OUT / f"{stem}_diff_{tic:05d}.png")
    n = len(results)
    exact = sum(1 for c in results if c["mismatch"] == 0)
    tot = sum(c["mismatch"] for c in results)
    pal_bad = sum(1 for c in results if not c["pal_ok"])
    summary = {"renderer": args.renderer, "frames": n, "exact_frames": exact,
               "mismatched_pixels": tot, "mismatch_pct_of_all_pixels": 100.0 * tot / (n * 64000),
               "max_frame_mismatch": max((c["mismatch"] for c in results), default=0),
               "pal_mismatch_frames": pal_bad,
               "median_ms": float(np.median([c["ms"] for c in results]))}
    (OUT / f"{stem}_correctness.json").write_text(json.dumps({"summary": summary, "frames": results}, default=str))
    print(json.dumps(summary, indent=1))
    sys.exit(0 if exact == n and pal_bad == 0 else 1)


if __name__ == "__main__":
    main()
