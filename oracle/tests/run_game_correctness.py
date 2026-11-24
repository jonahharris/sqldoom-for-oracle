#!/usr/bin/env python3
"""Replay the TPC-DOOM E1M1 run in Oracle (doom_game) and compare the game state with
the CedarDB recording (record_game_reference.py) after the level start and after
every tic.

    run_game_correctness.py [--tics 1-1200] [--continue] [--tables a,b] [--quiet]

Comparison: every recorded table (g_<table> in Oracle), integers/strings/booleans
exactly, floats to 1e-9 relative; sound_events without event_id (its value follows
the insert order). Also the finish_game_tic snapshot, the sound_due flag and the
sounds fetched (name, volume, pan). Stops at the first divergence and prints
table/key/column unless --continue, which reports the first divergence per table and
counts the diverging tics.
"""
import argparse, json, math, sys, time, zlib
from pathlib import Path
import numpy as np
import pyarrow.parquet as pq

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client"))
sys.path.insert(0, str(HERE))
import oradb, game_api  # noqa: E402
import scenario_lib  # noqa: E402

REF = HERE.parent / "reference_data" / "e1m1_game"
SKIP_COLS = {"sound_events": {"event_id"}}
REAL_SNAPSHOT = {"x", "y", "angle", "z"}


class Reference:
    def __init__(self, root=REF):
        self.root = root
        meta = json.loads((root / "changes.json").read_text())
        self.changes, self.keys, self.sparse = meta["changes"], meta["keys"], set(meta["sparse"])
        self.cols, self.data, self.base = {}, {}, {}
        for t in self.changes:
            tb = pq.read_table(root / "tables" / f"{t}.parquet")
            names = [n for n in tb.column_names if n != "tic"]
            keep = [n for n in names if n not in SKIP_COLS.get(t, ())]
            self.cols[t] = keep
            tics = tb.column("tic").to_pylist()
            cols = [tb.column(n).to_pylist() for n in keep]
            by = {}
            for i, tic in enumerate(tics):
                by.setdefault(tic, []).append(tuple(c[i] for c in cols))
            self.data[t] = by
            if t in self.sparse:
                kidx = [keep.index(k) for k in self.keys[t]]
                self.base[t] = {tuple(r[j] for j in kidx): r for r in by.get(0, [])}
        self.tics = json.loads((root / "tics.json").read_text())
        self.run = json.loads((root / "run.json").read_text())

    def rows(self, table, tic):
        stored = self.changes[table]
        lo, hi = 0, len(stored) - 1
        best = None
        while lo <= hi:
            mid = (lo + hi) // 2
            if stored[mid] <= tic:
                best, lo = stored[mid], mid + 1
            else:
                hi = mid - 1
        rows = self.data[table].get(best, []) if best is not None else []
        if table in self.sparse:
            if best == 0 or best is None:
                return list(self.base[table].values())
            kidx = [self.cols[table].index(k) for k in self.keys[table]]
            merged = dict(self.base[table])
            for r in rows:
                merged[tuple(r[j] for j in kidx)] = r
            return list(merged.values())
        return rows


def fkey(v):
    return (0, "") if v is None else (1, v) if not isinstance(v, (int, float, bool)) else (1, float(v))


def sort_rows(rows, kidx):
    return sorted(rows, key=lambda r: tuple(fkey(r[j]) for j in kidx) + tuple(fkey(x) for x in r))


def same(a, b):
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, bool) or isinstance(b, bool):
        return bool(a) == bool(b)
    if isinstance(a, float) or isinstance(b, float):
        a, b = float(a), float(b)
        if a == b:
            return True
        if math.isnan(a) or math.isnan(b):
            return False
        return abs(a - b) <= 1e-9 * max(abs(a), abs(b))
    if isinstance(a, (int,)) and isinstance(b, (int,)):
        return a == b
    return str(a).rstrip() == str(b).rstrip()


def compare_table(ref_rows, ora_rows, cols, keys):
    kidx = [cols.index(k) for k in keys]
    r = sort_rows(ref_rows, kidx)
    o = sort_rows(ora_rows, kidx)
    rk = {tuple(x[j] for j in kidx): x for x in r}
    ok = {tuple(x[j] for j in kidx): x for x in o}
    if len(r) != len(o) or len(rk) != len(r) or len(ok) != len(o):
        missing = [k for k in rk if k not in ok][:3]
        extra = [k for k in ok if k not in rk][:3]
        if missing or extra or len(r) != len(o):
            return f"row count ref={len(r)} ora={len(o)} missing={missing} extra={extra}"
    for k, rr in rk.items():
        oo = ok.get(k)
        if oo is None:
            return f"missing key {k}"
        for c, a, b in zip(cols, rr, oo):
            if not same(a, b):
                return f"key {dict(zip(keys, k))} column {c}: ref={a!r} ora={b!r}"
    return None


def fetch_oracle(cur, table, cols, map_id):
    sel = ", ".join(f'"{c.upper()}"' for c in cols)
    cur.execute(f"SELECT {sel} FROM g_{table} WHERE map_id = :m", m=map_id)
    out = []
    for row in cur.fetchall():
        out.append(tuple(float(v) if isinstance(v, float) else v for v in row))
    return out


def parse_range(s, n):
    if not s:
        return 1, n
    a, _, b = s.partition("-")
    return int(a), int(b or a)


def replay(ref, args, label=""):
    """Replay one recording (the TPC-DOOM run or a scenario) and compare every tic."""
    run = ref.run
    map_id, player, skill = run["map_id"], run["player_thing_id"], run["skill"]
    first, last = parse_range(args.tics, run["tics"])
    tables = [t for t in ref.changes if not args.tables or t in args.tables.split(",")]
    tables = [t for t in tables if t not in ("automap_view", "mp_players")]
    conn = oradb.connect()
    cur = conn.cursor()
    game_api.setup_session(cur)
    side = None
    if run.get("mods"):
        side = scenario_lib.OracleSide(cur, map_id, player)
        side.apply_mods(run["mods"])
    try:
        return _replay(ref, args, label, conn, cur, map_id, player, skill, first, last, tables)
    finally:
        if side:
            conn.rollback()
            side.revert()
        conn.close()


def _replay(ref, args, label, conn, cur, map_id, player, skill, first, last, tables):
    run = ref.run
    ops = run.get("ops", {})
    oside = scenario_lib.OracleSide(cur, map_id, player)
    game_api.level_start(cur, map_id, player, skill, run.get("cheats", ("IDDQD", "IDKFA")))
    for op in ops.get("0", []):
        oside.apply_op(op)
    divergent_tics, first_div = 0, {}
    t_tic = []
    event_cursor = 0
    frames_n = [0, 0]
    n_err = [0]
    rcur = conn.cursor(); rcur.arraysize = 256; rcur.prefetchrows = 257

    def check(tic):
        bad = []
        for t in tables:
            msg = compare_table(ref.rows(t, tic), fetch_oracle(cur, t, ref.cols[t], map_id), ref.cols[t], ref.keys[t])
            if msg:
                bad.append((t, msg))
        return bad

    if first == 1 and not args.no_compare:
        # tic_trace is not part of the level start (doom_reset_stage keeps the last run's row)
        bad = [b for b in check(0) if b[0] != "tic_trace"]
        for t, msg in bad:
            print(f"{label}tic 0 (level start) {t}: {msg}")
        if bad and not args.cont:
            return 1
    t0 = time.perf_counter()
    for i in range(last):
        tic = i + 1
        rec = ref.tics[i]
        if i > 0:
            for op in ops.get(str(i), []):
                oside.apply_op(op)
        a = time.perf_counter()
        if "error" in rec:
            # CedarDB failed this tic (the client drops it): Oracle must fail it too, leaving no trace
            try:
                game_api.run_tic(cur, map_id, player, rec["command"])
                err = None
            except Exception as ex:      # noqa: BLE001
                err = str(ex).splitlines()[0]
            conn.rollback()
            n_err[0] += 1
            if tic < first or args.no_compare:
                continue
            bad = check(tic)
            if err is None:
                bad.append(("tic_error", f"ref failed ({rec['error']}), Oracle did not"))
            if bad:
                divergent_tics += 1
                for t, msg in bad:
                    if t not in first_div:
                        first_div[t] = (tic, msg)
                        print(f"{label}tic {tic} DIVERGES {t}: {msg}", flush=True)
                if not args.cont:
                    print(f"{label}first divergence at tic {tic}; {tic - first} tics equal before it")
                    return 1
            continue
        due = game_api.run_tic(cur, map_id, player, rec["command"])
        conn.commit()
        t_tic.append(time.perf_counter() - a)
        events = []
        if due:
            events = game_api.sound_events(cur, map_id, player, event_cursor)
            if events:
                event_cursor = max(e[0] for e in events)
        snap = game_api.finish_tic(cur, map_id, player)
        if tic < first or args.no_compare:
            continue
        bad = check(tic)
        fe = run.get("frame_every") or 0
        if fe and tic % fe == 0 and not args.no_frames:
            fp = ref.root / "frames" / f"{tic:05d}.idx.z"
            frame, fpose = game_api.render_live(rcur, map_id, player, skill)
            conn.rollback()
            refi = np.frombuffer(zlib.decompress(fp.read_bytes()), np.uint8).reshape(200, 320)
            nbad = int((refi != frame).sum())
            frames_n[0] += 1
            if nbad:
                frames_n[1] += 1
                bad.append(("frame", f"{nbad} pixels differ"))
        if due != rec["sound_due"]:
            bad.append(("sound_due", f"ref={rec['sound_due']} ora={due}"))
        rs = sorted((e[1], round(e[2], 9), round(e[3], 9)) for e in rec["events"])
        os_ = sorted((e[1], round(e[2], 9), round(e[3], 9)) for e in events)
        if [x[0] for x in rs] != [x[0] for x in os_] or any(
                not (same(x[1], y[1]) and same(x[2], y[2])) for x, y in zip(rs, os_)):
            bad.append(("sound_events_fetched", f"ref={rs[:6]} ora={os_[:6]}"))
        for kk, v in rec["snapshot"].items():
            o = snap.get(kk)
            if kk in REAL_SNAPSHOT:      # REAL columns came back from CedarDB as shortest float4 text
                v, o = float(np.float32(v)), float(np.float32(o))
            if not same(v, o):
                bad.append(("snapshot", f"{kk}: ref={v!r} ora={snap.get(kk)!r}"))
                break
        if bad:
            divergent_tics += 1
            for t, msg in bad:
                if t not in first_div:
                    first_div[t] = (tic, msg)
                    print(f"{label}tic {tic} DIVERGES {t}: {msg}", flush=True)
            if not args.cont:
                print(f"{label}first divergence at tic {tic}; {tic - first} tics equal before it")
                return 1
        elif not args.quiet and tic % 100 == 0:
            print(f"{label}tic {tic} equal  ({time.perf_counter() - t0:.0f}s)", flush=True)
    n = last - first + 1
    ms = sorted(x * 1e3 for x in t_tic)
    fr = f"; frames {frames_n[0] - frames_n[1]}/{frames_n[0]} pixel-exact" if frames_n[0] else ""
    if n_err[0]:
        fr += f"; {n_err[0]} tics failed on both (CedarDB error, dropped)"
    ms = ms or [0.0]
    print(f"{label}tics {first}-{last}: {n - divergent_tics}/{n} equal{fr}; tic call mean {sum(ms)/len(ms):.2f} ms "
          f"p50 {ms[len(ms)//2]:.2f} p95 {ms[int(len(ms)*0.95)]:.2f} max {ms[-1]:.2f}", flush=True)
    return 0 if divergent_tics == 0 else 1


MP_INPUT_SQL = """INSERT INTO g_mp_inputs (map_id, player_thing_id, move_fwd, move_strafe, running, turn_degrees,
                                    attack_held, weapon_switch_to, use_requested)
VALUES (:m, :p, doom_game.cmd_real(:f), doom_game.cmd_real(:st), :run, doom_game.cmd_real(:t), :atk, :sw, :use)"""
MP_TIC_SQL = "BEGIN :r := doom_game.run_mp_tic(:m, :s, :p1, :p2, :p3, :p4); END;"


def mp_open(cur, run):
    """The match start as recorded: configure, mp_start, claim the slots, open."""
    cfg, m = run["config"], run["map_id"]
    cur.execute("BEGIN doom_game.mp_configure(:m, :s, :t, :a, :mo, :r, 350); END;", m=m, s=run["skill"],
                t=cfg["timer"], a=int(cfg["altdeath"]), mo=int(cfg["monsters"]), r=int(cfg["respawn"]))
    n = cur.var(int)
    cur.execute("BEGIN :n := doom_game.mp_start(:m, :s); END;", n=n, m=m, s=run["skill"])
    for slot in run["claimed"]:
        cur.execute("DECLARE x NUMBER; BEGIN x := doom_game.mp_claim(:m, :sl, :r); END;", m=m, sl=slot, r=f"bot{slot}")
    cur.execute("BEGIN doom_game.mp_open; END;")
    cur.connection.commit()


def mp_cleanup(cur):
    for t in ("g_mp_inputs", "g_mp_join_requests", "g_mp_players", "g_mp_match"):
        cur.execute(f"DELETE FROM {t}")
    cur.connection.commit()


def mp_push(cur, map_id, pid, c):
    _sk, f, st, run_, t, atk, sw, use = c
    cur.execute(MP_INPUT_SQL, m=map_id, p=pid, f=repr(float(f)), st=repr(float(st)), run=bool(run_),
                t=repr(float(t)), atk=bool(atk), sw=sw, use=bool(use))


def mp_ops(cur, map_id, players, ops):
    """The recorder's arena poses (slot, x, y, angle): the same UPDATE + spawn_player as on CedarDB."""
    for op in ops or ():
        s, x, y, ang = op[:4]
        cur.execute("UPDATE g_things SET x = :x, y = :y, angle = :a WHERE map_id = :m AND id = :p",
                    x=float(x), y=float(y), a=float(ang), m=map_id, p=players[int(s)])
        cur.execute("BEGIN doom_game.spawn_player(:m, :p); END;", m=map_id, p=players[int(s)])
        if len(op) > 4 and op[4]:
            cur.execute("""INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_player_weapon_owned g_player_weapon_owned_pk) */
                           INTO g_player_weapon_owned (map_id, player_thing_id, weapon_id)
                           SELECT :m, :p, w FROM (SELECT 4 AS w FROM dual UNION ALL SELECT 5 FROM dual)""",
                        m=map_id, p=players[int(s)])
            cur.execute("UPDATE g_player_state SET ammo_bullets = 200, ammo_rockets = 30 "
                        "WHERE map_id = :m AND player_thing_id = :p", m=map_id, p=players[int(s)])
    if ops:
        cur.connection.commit()


def mp_tic(cur, map_id, skill, players):
    r = cur.var(int)
    cur.execute(MP_TIC_SQL, r=r, m=map_id, s=skill, p1=players.get(1), p2=players.get(2), p3=players.get(3),
                p4=players.get(4))
    return bool(r.getvalue())


def replay_mp(ref, args, label=""):
    run = ref.run
    map_id, skill = run["map_id"], run["skill"]
    players = {int(k): v for k, v in run["players"].items()}
    first, last = parse_range(args.tics, run["tics"])
    tables = [t for t in ref.changes if t != "automap_view" and (not args.tables or t in args.tables.split(","))]
    conn = oradb.connect()
    cur = conn.cursor()
    game_api.setup_session(cur)
    mp_open(cur, run)
    divergent, first_div, t_tic = 0, {}, []
    frames_n = [0, 0]
    rcur = conn.cursor(); rcur.arraysize = 256; rcur.prefetchrows = 257

    def check(tic):
        bad = []
        for t in tables:
            msg = compare_table(ref.rows(t, tic), fetch_oracle(cur, t, ref.cols[t], map_id), ref.cols[t], ref.keys[t])
            if msg:
                bad.append((t, msg))
        return bad

    try:
        if first == 1:
            bad = [b for b in check(0) if b[0] != "tic_trace"]
            for t, msg in bad:
                print(f"{label}tic 0 (match start) {t}: {msg}")
            if bad and not args.cont:
                return 1
        t0 = time.perf_counter()
        for i in range(last):
            tic = i + 1
            rec = ref.tics[i]
            mp_ops(cur, map_id, players, rec.get("ops"))
            a = time.perf_counter()
            for s, c in sorted(rec["inputs"].items()):
                mp_push(cur, map_id, players[int(s)], c)
            done = mp_tic(cur, map_id, skill, players)
            conn.commit()
            t_tic.append(time.perf_counter() - a)
            if tic < first:
                continue
            bad = check(tic)
            if done != bool(rec["level_done"]):
                bad.append(("level_done", f"ref={rec['level_done']} ora={done}"))
            for s, pose in rec["poses"].items():
                o = game_api.camera_pose(cur, map_id, players[int(s)], 1.0)
                if o is None or any(not same(a_, b_) for a_, b_ in zip(pose, o)):
                    bad.append(("camera_pose", f"slot {s}: ref={pose} ora={o}"))
                    break
            if not args.no_frames:
                for s in run["claimed"]:
                    fp = ref.root / "frames" / f"{tic:05d}_{s}.idx.z"
                    if fp.exists():
                        frame, _ = game_api.render_live(rcur, map_id, players[int(s)], skill)
                        refi = np.frombuffer(zlib.decompress(fp.read_bytes()), np.uint8).reshape(200, 320)
                        nbad = int((refi != frame).sum())
                        frames_n[0] += 1
                        if nbad:
                            frames_n[1] += 1
                            bad.append(("frame", f"slot {s}: {nbad} pixels differ"))
                            if args.dump:
                                np.save(args.dump / f"mp_{tic}_{s}.npy", np.stack([refi, frame]))
                conn.rollback()
            if bad:
                divergent += 1
                for t, msg in bad:
                    if t not in first_div:
                        first_div[t] = (tic, msg)
                        print(f"{label}tic {tic} DIVERGES {t}: {msg}", flush=True)
                if not args.cont:
                    print(f"{label}first divergence at tic {tic}; {tic - first} tics equal before it")
                    return 1
            elif not args.quiet and tic % 100 == 0:
                print(f"{label}tic {tic} equal  ({time.perf_counter() - t0:.0f}s)", flush=True)
        n = last - first + 1
        ms = sorted(x * 1e3 for x in t_tic)
        fr = f"; frames {frames_n[0] - frames_n[1]}/{frames_n[0]} pixel-exact" if frames_n[0] else ""
        print(f"{label}tics {first}-{last}: {n - divergent}/{n} equal{fr}; mp tic (inputs + tic + commit) mean "
              f"{sum(ms)/len(ms):.2f} ms p50 {ms[len(ms)//2]:.2f} p95 {ms[int(len(ms)*0.95)]:.2f} max {ms[-1]:.2f}",
              flush=True)
        return 0 if divergent == 0 else 1
    finally:
        mp_cleanup(cur)
        conn.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tics", default="")
    ap.add_argument("--continue", dest="cont", action="store_true")
    ap.add_argument("--tables", default="")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--no-frames", action="store_true", help="scenarios: skip the recorded frames")
    ap.add_argument("--dump", type=Path, default=None, help="save (ref, oracle) arrays of differing frames here")
    ap.add_argument("--no-compare", action="store_true", help="only replay (timing)")
    ap.add_argument("--scenario", nargs="*", default=None,
                    help="replay recorded scenarios (names, prefix*, or none = all recorded)")
    ap.add_argument("--summary", type=Path, default=None, help="write a JSON summary of scenario results")
    ap.add_argument("--mp", default=None, help="replay a recorded deathmatch run (reference_data/<name>)")
    args = ap.parse_args()
    if args.mp:
        return replay_mp(Reference(REF.parent / args.mp), args, label=f"[{args.mp}] ")
    if args.scenario is None:
        return replay(Reference(), args)
    root = REF.parent / "scenarios"
    have = sorted(p.name for p in root.iterdir() if (p / "run.json").exists())
    names = have if not args.scenario else [h for h in have if any(
        h == n or (n.endswith("*") and h.startswith(n[:-1])) for n in args.scenario)]
    results = {}
    for n in names:
        t = time.perf_counter()
        rc = replay(Reference(root / n), args, label=f"[{n}] ")
        results[n] = {"ok": rc == 0, "s": round(time.perf_counter() - t, 1)}
    bad = [n for n, r in results.items() if not r["ok"]]
    print(f"scenarios: {len(names) - len(bad)}/{len(names)} equal" + (f"; diverging: {' '.join(bad)}" if bad else ""))
    if args.summary:
        args.summary.write_text(json.dumps(results, indent=1))
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
