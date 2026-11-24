#!/usr/bin/env python3
"""Every loaded map: level start, a scripted minute of play, a frame (port of CedarDB SQLDoom's
scripts/all_maps_smoke.py), and with --cedar the same on CedarDB: the end state and the frame at the
end pose must be equal (pixel-exact; the frame is rendered at camera_pose(alpha) for an
interpolated alpha, so it also covers the camera statement on every map). The end frame is also
rendered in the vanilla sprite mode (the clients' default; render_live(..., sprites=1)): it must render
and may differ from the exact frame only by a few sprite pixels (reported).

    all_maps_smoke.py [--tics 120] [--maps E1M1,...] [--cedar] [--alpha 0.4]
"""
import argparse, json, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "client"))
import determinism_check as dc  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tics", type=int, default=120)
    ap.add_argument("--maps", default="")
    ap.add_argument("--cedar", action="store_true")
    ap.add_argument("--alpha", type=float, default=0.4)
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()
    import numpy as np
    o = dc.OracleSide()
    rcur = o.conn.cursor()
    rcur.arraysize = 256
    rcur.prefetchrows = 257
    c = None
    if a.cedar:
        import record_reference as rr
        c = dc.CedarSide()
        c.cur.execute("PREPARE ref_idx(int,int,int,float8,float8,float8,float8) AS " + rr.index_variant(c.cur))
    want = {x.strip().upper() for x in a.maps.split(",") if x.strip()}
    maps = [mm for mm in o.maps() if not want or mm[1] in want]
    fails, results = 0, []
    for m, name, p in maps:
        cmds = dc.script(3, a.tics, 1)
        try:
            t0 = time.perf_counter()
            w, f = o.play(m, p, 3, cmds)
            tic_ms = (time.perf_counter() - t0) * 1e3 / a.tics
            t0 = time.perf_counter()
            frame, pose = o.ga.render_live(rcur, m, p, 3, alpha=a.alpha)
            frame_ms = (time.perf_counter() - t0) * 1e3
            t0 = time.perf_counter()
            vframe, _vpose = o.ga.render_live(rcur, m, p, 3, alpha=a.alpha, sprites=o.ga.SPRITES_VANILLA)
            vframe_ms = (time.perf_counter() - t0) * 1e3
            o.conn.rollback()
            vdiff = int((vframe != frame).sum())
            distinct = len(np.unique(frame))
            ok = frame.shape == (200, 320) and distinct > 8 and vframe.shape == (200, 320) and \
                len(np.unique(vframe)) > 8 and not (vframe[168:] != frame[168:]).any()
            hp = w[0][0][4] if w[0] else "?"
            line = (f"  {name}: {'ok ' if ok else 'BAD'} {a.tics} tics at {tic_ms:.1f} ms, frame {frame_ms:.0f} ms "
                    f"({distinct} distinct indices), hp {hp}; vanilla sprites {vframe_ms:.0f} ms, {vdiff} px differ")
            res = {"map": name, "ok": ok, "tic_ms": tic_ms, "frame_ms": frame_ms, "failed_tics": len(f),
                   "vanilla_frame_ms": vframe_ms, "vanilla_diff_px": vdiff}
            if c is not None:
                wc, fc = c.play(m, p, 3, cmds)
                eq = all(dc.same_rows(x, y) for x, y in zip(w, wc)) and fc == f
                cp = c.sql.camera_pose(c.cur, m, p, a.alpha)
                c.cur.execute("EXECUTE ref_idx(%s,%s,%s,%s,%s,%s,%s)", (m, p, 3, *[float(v) for v in cp]))
                ref = np.frombuffer(bytes(c.cur.fetchone()[0]), np.uint8).reshape(200, 320)
                nbad = int((ref != frame).sum())
                line += f"; CedarDB: state {'EQUAL' if eq else 'DIFFERENT'}, frame {'exact' if nbad == 0 else f'{nbad} px off'}"
                res.update(cedar_state_equal=eq, cedar_frame_exact=nbad == 0)
                ok = ok and eq and nbad == 0
            print(line, flush=True)
        except Exception as exc:  # noqa: BLE001
            o.conn.rollback()
            ok = False
            res = {"map": name, "ok": False, "error": str(exc).splitlines()[0]}
            print(f"  {name}: ERROR {str(exc).splitlines()[0][:140]}", flush=True)
        fails += not ok
        results.append(res)
    print(f"{len(maps) - fails}/{len(maps)} maps ok" + (" (state and frame equal to CedarDB)" if c else ""))
    if a.json:
        a.json.write_text(json.dumps(results, indent=1))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
