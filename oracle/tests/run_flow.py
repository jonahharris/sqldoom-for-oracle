#!/usr/bin/env python3
"""Level-flow scenarios (flow_lib.py, flow_defs.py): record on CedarDB, replay on Oracle.

    run_flow.py record [names ...] [--force]      CedarDB ground truth -> reference_data/flows/<name>/
    run_flow.py replay [names ...] [--continue]   Oracle: every call's result, every snapshot, every frame
    run_flow.py list

A replay executes the recorded calls in order with the recorded arguments and compares
  * each call's result (spawn poses, tic snapshots/sounds/camera poses, next map ids, tally
    figures, menu actions and screen state, cheat-key results, loaded map/skill, demo headers ...),
  * after each call that took a snapshot: every map-scoped game table of the touched maps and the
    flow's global tables (screen_state, save_*, demos, demo_tics), floats to 1e-9,
  * every recorded frame: 3-D frames in palette indices, screen/automap frames in RGB.
"""
import argparse, json, sys, time, zlib
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import flow_lib as fl  # noqa: E402
import flow_defs  # noqa: E402,F401  (registers the flows)
import framecmp  # noqa: E402

REAL_SNAPSHOT = {"x", "y", "angle", "z"}


def select(names):
    if not names:
        return list(fl.FLOWS)
    return [k for k in fl.FLOWS for n in names if k == n or (n.endswith("*") and k.startswith(n[:-1]))]


def record(names, force):
    drv = fl.CedarDriver()
    for n in names:
        out = fl.OUT / n
        if (out / "flow.json.z").exists() and not force:
            print(f"{n}: exists, skipped")
            continue
        fn, covers, note = fl.FLOWS[n]
        rec = fl.Recorder(n, drv)
        t0 = time.perf_counter()
        try:
            rec.do("reset_meta")
            fn(rec)
        finally:
            rec.finish()
        rec.log.append({"a": "meta", "args": [], "r": {"covers": covers, "note": note,
                                                        "recorded_s": time.perf_counter() - t0}})
        rec.write()
        nt = sum(1 for e in rec.log if e["a"] == "tic")
        print(f"{n}: {len(rec.log)} calls ({nt} tics, {len(rec.frames)} frames) in {time.perf_counter() - t0:.0f}s",
              flush=True)


def cmp_result(name, ref, got):
    if name == "tic":
        bad = []
        if bool(ref["due"]) != bool(got["due"]):
            bad.append(f"sound_due ref={ref['due']} ora={got['due']}")
        rs = sorted((e[1], round(e[2], 9), round(e[3], 9)) for e in ref["events"])
        os_ = sorted((e[1], round(e[2], 9), round(e[3], 9)) for e in got["events"])
        if [x[0] for x in rs] != [x[0] for x in os_] or any(
                not (fl.same(x[1], y[1]) and fl.same(x[2], y[2])) for x, y in zip(rs, os_)):
            bad.append(f"sounds ref={rs[:4]} ora={os_[:4]}")
        for k, v in ref["snapshot"].items():
            o = got["snapshot"].get(k)
            if k in REAL_SNAPSHOT:
                v, o = float(np.float32(v)), float(np.float32(o))
            if not fl.same(v, o):
                bad.append(f"snapshot {k}: ref={v!r} ora={o!r}")
                break
        if not fl.deep_same(ref["pose"], got["pose"]):
            bad.append(f"pose ref={ref['pose']} ora={got['pose']}")
        return "; ".join(bad) or None
    if not fl.deep_same(ref, got):
        return f"ref={ref!r} ora={got!r}"
    return None


def cmp_frame(name, ref_bytes, got, pal):
    if name == "frame_game":
        ref = np.frombuffer(ref_bytes, np.uint8).reshape(200, 320)
        return int((ref != got).sum())
    ref = np.frombuffer(ref_bytes, np.uint8).reshape(200, 320, 3)
    return int((pal[got] != ref).any(axis=2).sum())


def replay(name, cont=False, dump=None, quiet=False):
    root = fl.OUT / name
    blob = json.loads(zlib.decompress((root / "flow.json.z").read_bytes()))
    log, snaps = blob["log"], fl.Snapshots.load(blob["snaps"])
    drv = fl.OracleDriver()
    pal = framecmp.playpal()
    sides = []
    stats = {"calls": 0, "tics": 0, "snapshots": 0, "frames": 0, "frame_bad": 0, "bad_steps": 0}
    timing = {}
    first = {}
    t_all = time.perf_counter()
    try:
        for step, e in enumerate(log):
            a = e["a"]
            if a == "meta":
                continue
            if a == "mods":
                m, p, mods = e["args"]
                side = fl.sl.OracleSide(drv.cur, m, p)
                side.apply_mods(mods)
                sides.append(side)
                continue
            t0 = time.perf_counter()
            got = drv.call(a, e["args"])
            ms = (time.perf_counter() - t0) * 1e3
            timing.setdefault(a, []).append((ms, e.get("ms", 0.0)))
            stats["calls"] += 1
            stats["tics"] += a == "tic"
            bad = []
            if a in fl.FRAMES:
                fp = root / "frames" / f"{step:05d}.z"
                n = cmp_frame(a, zlib.decompress(fp.read_bytes()), got, pal)
                stats["frames"] += 1
                if n:
                    stats["frame_bad"] += 1
                    bad.append((a, f"{n} pixels differ"))
                    if dump:
                        dump.mkdir(parents=True, exist_ok=True)
                        np.save(dump / f"{name}_{step}_{a}.npy", got)
            else:
                msg = cmp_result(a, e["r"], got)
                if msg:
                    bad.append((a, msg))
            if e.get("snap"):
                stats["snapshots"] += 1
                tables = list(fl.GLOBAL_TABLES) + (list(fl.MAP_TABLES) if e["snap"] == "full" else [])
                for t in tables:
                    if t == "tic_trace" and a != "tic":
                        continue       # not part of a level start (doom_reset_stage keeps the last run's row)
                    cols = snaps.cols.get(t)
                    if cols is None:
                        continue
                    ora = drv.fetch(t, cols, e["maps"])
                    msg = fl.compare_rows(snaps.get(t, step), ora, cols, list(fl.MAP_TABLES.get(t) or fl.GLOBAL_TABLES[t]))
                    if msg:
                        bad.append((t, msg))
            if bad:
                stats["bad_steps"] += 1
                for t, msg in bad:
                    if t not in first:
                        first[t] = (step, msg)
                        print(f"[{name}] step {step} ({a} {json.dumps(e['args'])[:80]}) DIVERGES {t}: {msg}", flush=True)
                if not cont:
                    break
            elif not quiet and step % 500 == 0:
                print(f"[{name}] step {step} equal ({time.perf_counter() - t_all:.0f}s)", flush=True)
    finally:
        drv.conn.rollback()
        for side in reversed(sides):
            side.revert()
        drv.conn.close()
    ok = stats["bad_steps"] == 0
    summ = {k: v for k, v in stats.items()}
    tm = {k: {"ora_ms": round(sum(x for x, _ in v) / len(v), 2), "cedar_ms": round(sum(y for _, y in v) / len(v), 2),
              "n": len(v)} for k, v in timing.items()}
    print(f"[{name}] {'EQUAL' if ok else 'DIVERGES'}: {summ['calls']} calls, {summ['tics']} tics, "
          f"{summ['snapshots']} snapshots, frames {summ['frames'] - summ['frame_bad']}/{summ['frames']} exact "
          f"({time.perf_counter() - t_all:.0f}s)", flush=True)
    return ok, summ, tm


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["record", "replay", "list"])
    ap.add_argument("names", nargs="*")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--continue", dest="cont", action="store_true")
    ap.add_argument("--dump", type=Path, default=None)
    ap.add_argument("--summary", type=Path, default=None)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    names = select(args.names)
    if args.cmd == "list":
        for n in names:
            print(f"{n:24s} {', '.join(fl.FLOWS[n][1])}")
        return 0
    if args.cmd == "record":
        record(names, args.force)
        return 0
    have = [n for n in names if (fl.OUT / n / "flow.json.z").exists()]
    results = {}
    for n in have:
        ok, summ, tm = replay(n, args.cont, args.dump, args.quiet)
        results[n] = {"ok": ok, **summ, "timing": tm}
    bad = [n for n, r in results.items() if not r["ok"]]
    print(f"flows: {len(have) - len(bad)}/{len(have)} equal" + (f"; diverging: {' '.join(bad)}" if bad else ""))
    if args.summary:
        args.summary.write_text(json.dumps(results, indent=1))
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
