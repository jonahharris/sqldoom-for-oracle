"""Replay a recorded scenario up to a tic and diff the live frame against the CedarDB frame.

    scenario_frame_debug.py NAME TIC [--png out.png]
"""
import argparse, json, sys, zlib
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client"))
sys.path.insert(0, str(HERE))
import oradb, game_api, scenario_lib  # noqa: E402
import run_game_correctness as rgc  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("tic", type=int)
    a = ap.parse_args()
    root = rgc.REF.parent / "scenarios" / a.name
    ref = rgc.Reference(root)
    run = ref.run
    m, p, sk = run["map_id"], run["player_thing_id"], run["skill"]
    conn = oradb.connect(); cur = conn.cursor()
    game_api.setup_session(cur)
    side = scenario_lib.OracleSide(cur, m, p)
    if run.get("mods"):
        side.apply_mods(run["mods"])
    try:
        game_api.level_start(cur, m, p, sk, run.get("cheats"))
        for op in run["ops"].get("0", []):
            side.apply_op(op)
        for i in range(a.tic):
            if i > 0:
                for op in run["ops"].get(str(i), []):
                    side.apply_op(op)
            game_api.run_tic(cur, m, p, ref.tics[i]["command"])
            conn.commit()
        frame, pose = game_api.render_live(cur, m, p, sk)
        refi = np.frombuffer(zlib.decompress((root / "frames" / f"{a.tic:05d}.idx.z").read_bytes()),
                             np.uint8).reshape(200, 320)
        d = np.argwhere(refi != frame)
        print("pose", pose, "ref pose", ref.tics[a.tic - 1]["pose"], "differing", len(d))
        for y, x in d[:40]:
            print(f"  ({x},{y}) ref {refi[y, x]} ora {frame[y, x]}")
        cur.execute("""SELECT id, type, x, y, z FROM g_things t WHERE map_id = :m
                        AND (x - :x) * (x - :x) + (y - :y) * (y - :y) < 1000000 ORDER BY id""", m=m, x=pose[0], y=pose[1])
        for r in cur.fetchall()[:0]:
            print(r)
        cur.execute("SELECT projectile_id, projectile_type, state, age, x, y, z FROM g_monster_projectiles WHERE map_id = :m", m=m)
        print("projectiles", cur.fetchall())
        cur.execute("SELECT effect_id, effect_type, age, x, y, z FROM g_world_effects WHERE map_id = :m", m=m)
        print("effects", cur.fetchall())
        (Path(__file__).resolve().parent / "out").mkdir(exist_ok=True); np.save(Path(__file__).resolve().parent / "out" / f"dbg_{a.name}_{a.tic}.npy", np.stack([refi, frame]))
    finally:
        conn.rollback()
        side.revert()


if __name__ == "__main__":
    main()
