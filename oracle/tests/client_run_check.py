#!/usr/bin/env python3
"""Phase 6: the desktop client end to end, against CedarDB.

Runs client/doom_client.py unattended (SDL dummy video/audio) through its real game loop -- 35 Hz
tic clock, the render thread requesting frames independently at interpolated cameras, palette
lookup, sound -- with the TPC-DOOM E1M1 command stream as its input (--commands; the level start
is the recorders' one: --warp E1M1 --cheats IDDQD,IDKFA), and checks what it did:

  1. every tic's snapshot (game_tick_finish.sql: pose, alive, exits, keys, tic stages, screen, demo)
     and sound events against the CedarDB recording (reference_data/e1m1_game/tics.json)
  2. the frames it displayed: for a sample of them (tic, alpha as the client used them), CedarDB
     replays the run and renders the same tic at camera_pose(alpha) (renderer.sql, index variant);
     the client's frame must be pixel-exact
  3. timing: tic rate and interval regularity, tic call, frame latency, frames per second

The client runs with --cedar-exact (the CedarDB-exact sprite mode; its default is vanilla sprite
clipping, which is not what the reference renders). Without CedarDB (--skip-cedar) the displayed
frames drawn at alpha = 1 (the tic's own pose) are compared with the recorded CedarDB frames of
that tic (reference_data/e1m1/frames_idx).

    client_run_check.py [--tics 1200] [--split] [--sample 10] [--skip-cedar]
"""
import argparse, json, subprocess, sys, time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
ROOT = HERE.parents[1]
REF = HERE.parent / "reference_data" / "e1m1_game"
OUT = HERE / "out" / "p6"


def same(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return bool(a) == bool(b)
    if isinstance(a, float) or isinstance(b, float):
        a, b = float(a), float(b)
        return a == b or abs(a - b) <= 1e-6 * max(1.0, abs(a), abs(b))   # the recording holds float4 text
    if a in ("", None) and b in ("", None):
        return True
    return a == b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tics", type=int, default=1200)
    ap.add_argument("--split", action="store_true")
    ap.add_argument("--sample", type=int, default=10, help="check every Nth displayed frame on CedarDB")
    ap.add_argument("--skip-cedar", action="store_true")
    ap.add_argument("--label", default=None)
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    label = a.label or ("client_tpc_split" if a.split else "client_tpc")
    log, npz = OUT / f"{label}.json", OUT / f"{label}.npz"
    cmd = [sys.executable, str(ROOT / "oracle" / "client" / "doom_client.py"), "--headless", "--warp", "E1M1",
           "--cheats", "IDDQD,IDKFA", "--commands", str(HERE / "run-e1m1-b-commands.json"), "--tics", str(a.tics),
           "--log", str(log), "--log-frames", str(npz), "--cedar-exact"] + (["--split"] if a.split else ["--no-split"])
    t0 = time.perf_counter()
    r = subprocess.run(cmd, capture_output=True, text=True)
    print(f"client run: {time.perf_counter() - t0:.1f}s, exit {r.returncode}")
    if r.returncode:
        print(r.stdout[-2000:], r.stderr[-3000:])
        sys.exit(1)
    run = json.loads(log.read_text())
    summ = run["summary"]
    print("summary:", json.dumps(summ))

    # 1. snapshots and sounds
    ref = json.loads((REF / "tics.json").read_text())
    tics = [t for t in run["tics"] if "snapshot" in t]
    bad_snap, bad_ev, n_ev = [], [], 0
    for t in tics:
        rt = ref[t["tic"] - 1]
        s, rs = t["snapshot"], rt["snapshot"]
        diff = [k for k in rs if not same(s.get(k), rs[k])]
        if diff:
            bad_snap.append((t["tic"], diff[:4]))
        ev = sorted((e[0], e[1], e[2]) for e in t["events"])
        rev = sorted((e[1], e[2], e[3]) for e in rt["events"])
        n_ev += len(rev)
        if len(ev) != len(rev) or any(x[0] != y[0] or abs(x[1] - y[1]) > 1e-9 or abs(x[2] - y[2]) > 1e-9
                                      for x, y in zip(ev, rev)):
            bad_ev.append(t["tic"])
    print(f"tic snapshots vs CedarDB: {len(tics) - len(bad_snap)}/{len(tics)} equal; sound events: "
          f"{len(tics) - len(bad_ev)}/{len(tics)} tics equal ({n_ev} events)")
    for b in bad_snap[:5]:
        print("   snapshot differs", b)
    for b in bad_ev[:5]:
        print("   events differ at tic", b)

    # 2. frames at the client's (tic, alpha), re-rendered by CedarDB
    z = np.load(npz)
    ftic, falpha, frames = z["tic"], z["alpha"], z["frames"]
    print(f"frames displayed: {len(ftic)}; distinct tics {len(set(ftic.tolist()))}; alpha range "
          f"{falpha.min():.3f}..{falpha.max():.3f}; interpolated (0<alpha<1): {int(((falpha > 0) & (falpha < 1)).sum())}")
    result = {"label": label, "summary": summ, "tics": len(tics), "snap_equal": len(tics) - len(bad_snap),
              "event_tics_equal": len(tics) - len(bad_ev), "events": n_ev, "frames": int(len(ftic))}
    # 2a. frames at alpha 1 against the recorded CedarDB frames (no CedarDB needed)
    import framecmp
    rec_root = HERE.parent / "reference_data" / "e1m1"
    rec_ok = rec_n = 0
    rec_bad = []
    for i in np.nonzero(falpha == 1.0)[0]:
        tic = int(ftic[i])
        if not (rec_root / "frames_idx" / f"{tic:05d}.idx").exists():
            continue
        n = int((framecmp.load_ref(tic, rec_root) != frames[i]).sum())
        rec_n += 1
        rec_ok += n == 0
        if n:
            rec_bad.append((tic, n))
    print(f"client frames at alpha 1 vs the recorded CedarDB frames of that tic: {rec_ok}/{rec_n} pixel-exact")
    for b in rec_bad[:5]:
        print("   frame differs", b)
    result.update(recorded_checked=rec_n, recorded_exact=rec_ok)
    if not a.skip_cedar:
        import client_query_check as q
        c = q.Cedar()
        sample = sorted(range(0, len(ftic), a.sample))
        want = {}
        for i in sample:
            want.setdefault(int(ftic[i]), []).append(i)
        cmds = [cm["command"] for cm in json.loads((HERE / "run-e1m1-b-commands.json").read_text())]
        c.start(1, 157, 2, ["IDDQD", "IDKFA"], [], [])
        exact = checked = 0
        bad = []
        last = max(want) if want else 0
        try:
            for tic in range(0, last + 1):
                if tic > 0:
                    c.tic(1, 157, cmds[tic - 1])
                for i in want.get(tic, []):
                    fr = c.frame(1, 157, 2, float(falpha[i]))
                    n = int((fr != frames[i]).sum())
                    checked += 1
                    exact += n == 0
                    if n:
                        bad.append((tic, float(falpha[i]), n))
        finally:
            c.finish()
        print(f"client frames re-rendered on CedarDB at the client's (tic, alpha): {exact}/{checked} pixel-exact")
        for b in bad[:5]:
            print("   frame differs", b)
        result.update(frames_checked=checked, frames_exact=exact)
    (OUT / f"{label}_result.json").write_text(json.dumps(result, indent=1))
    ok = (not bad_snap and not bad_ev and result.get("frames_exact", 0) == result.get("frames_checked", 0)
          and rec_ok == rec_n)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
