"""Record gameplay scenarios (scenario_defs.py) on CedarDB SQLDoom as ground truth.

Each scenario is replayed exactly like record_game_reference.py replays the TPC-DOOM run
(set_screen 'game', enter_level, the scenario's cheats, then per tic execute_game_tic,
fetch_sound_events when the tic made sounds, finish_game_tic, camera_pose), with the
scenario's map mods applied before the level start (and reverted afterwards) and its ops
applied between tics. Every state table is snapshotted after the level start (+ tic-0 ops)
and after every tic, in the same format as reference_data/e1m1_game.

Output: oracle/reference_data/scenarios/<name>/{tables/*.parquet, changes.json, tics.json, run.json}
run.json holds the resolved plan (mods, ops with explicit poses, cheats, skill) that the
Oracle replay (run_game_correctness.py --scenario) applies.

Usage: record_scenarios.py [names or prefixes ...] [--list] [--force]
"""
import argparse, json, sys, time
from pathlib import Path
import psycopg2

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import record_game_reference as rgr  # noqa: E402
import record_reference as rr  # noqa: E402
import zlib  # noqa: E402
import scenario_lib as sl  # noqa: E402
sql = rgr.sql

OUT = HERE.parent / "reference_data" / "scenarios"


def select(names):
    if not names:
        return list(sl.SCENARIOS)
    out = []
    for n in names:
        out += [k for k in sl.SCENARIOS if k == n or (n.endswith("*") and k.startswith(n[:-1]))]
    return out


def record(cur, scn, out_root):
    stages = {s["label"]: s for s in sql.load_stages(cur)}
    stage = stages[scn.map_name]
    map_id, player = stage["map_id"], stage["player_thing_id"]
    side = sl.CedarSide(cur, map_id, player)
    geo = sl.cedar_geometry(cur, map_id)
    ops = sl.resolve(scn, geo, side.sector_at)
    t_start = time.perf_counter()
    side.apply_mods(scn.mods)
    try:
        sql.set_screen(cur, "game")
        sql.enter_level(cur, map_id, player, scn.skill)
        for code in scn.cheats:
            sql.cheat_code(cur, map_id, player, code)
        for op in ops.get("0", []):
            side.apply_op(op)
        rec = rgr.Recorder(cur, map_id)
        rec.snapshot(0)
        tics, event = [], 0
        for i, command in enumerate(scn.cmds):
            if i > 0:
                for op in ops.get(str(i), []):
                    side.apply_op(op)
            t0 = time.perf_counter()
            try:
                due = sql.execute_game_tic(cur, map_id, player, tuple(command))
            except psycopg2.Error as ex:
                # the reference client drops a tic whose call fails (doom_client.run_game_tic's except:
                # rollback, next frame); the call is one transaction, so nothing of it remains
                msg = str(ex).splitlines()[0]
                tics.append({"tic": i + 1, "command": list(command), "error": msg})
                rec.snapshot(i + 1)
                continue
            t1 = time.perf_counter()
            events = []
            if due:
                events, _ = sql.fetch_sound_events(cur, map_id, player, event)
                if events:
                    event = max(e[0] for e in events)
            snap = sql.finish_game_tic(cur, map_id, player)
            t3 = time.perf_counter()
            pose = tuple(float(v) for v in sql.camera_pose(cur, map_id, player, 1.0))
            tics.append({"tic": i + 1, "command": list(command), "sound_due": due,
                         "events": [[e[0], e[1], float(e[2]), float(e[3])] for e in events],
                         "snapshot": snap, "pose": list(pose),
                         "ms": {"tic": (t1 - t0) * 1e3, "total": (t3 - t0) * 1e3}})
            rec.snapshot(i + 1)
            if scn.frame_every and (i + 1) % scn.frame_every == 0:
                cur.execute("EXECUTE ref_idx(%s,%s,%s,%s,%s,%s,%s)", (map_id, player, scn.skill, *pose))
                idx = bytes(cur.fetchone()[0])
                fd = out_root / scn.name / "frames"
                fd.mkdir(parents=True, exist_ok=True)
                (fd / f"{i + 1:05d}.idx.z").write_bytes(zlib.compress(idx, 6))
    finally:
        side.revert()
    out = out_root / scn.name
    out.mkdir(parents=True, exist_ok=True)
    rec.write(out)
    (out / "tics.json").write_text(json.dumps(tics))
    (out / "run.json").write_text(json.dumps({
        "scenario": scn.name, "map": scn.map_name, "map_id": map_id, "player_thing_id": player,
        "skill": scn.skill, "tics": len(scn.cmds), "cheats": scn.cheats, "mods": scn.mods, "ops": ops,
        "covers": scn.covers, "note": scn.note, "frame_every": scn.frame_every, "recorded_s": time.perf_counter() - t_start}))
    return len(scn.cmds), time.perf_counter() - t_start


def _term(*_):
    raise KeyboardInterrupt


def main():
    import signal
    signal.signal(signal.SIGTERM, _term)
    signal.signal(signal.SIGINT, _term)
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--dsn", default=rgr.DEFAULT_DSN)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--force", action="store_true", help="re-record existing scenarios")
    args = ap.parse_args()
    names = select(args.names)
    if args.list:
        for n in names:
            s = sl.SCENARIOS[n]
            print(f"{n:22s} {s.map_name} skill {s.skill} tics {len(s.cmds):5d}  {', '.join(s.covers)}")
        return
    conn = psycopg2.connect(args.dsn); conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    if any(sl.SCENARIOS[n].frame_every for n in names):
        cur.execute("PREPARE ref_idx(int,int,int,float8,float8,float8,float8) AS " + rr.index_variant(cur))
    for n in names:
        if (OUT / n / "run.json").exists() and not args.force:
            print(f"{n}: exists, skipped")
            continue
        n_tics, secs = record(cur, sl.SCENARIOS[n], OUT)
        print(f"{n}: {n_tics} tics recorded in {secs:.0f}s", flush=True)


if __name__ == "__main__":
    main()
