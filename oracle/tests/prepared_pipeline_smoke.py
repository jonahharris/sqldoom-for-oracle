#!/usr/bin/env python3
"""A quick check that an installed Oracle SQL Doom works end to end (port of CedarDB SQLDoom's
scripts/prepared_pipeline_smoke.py): catalogue counts, a level start, the first executions, 40
tics of firing (the weapon fires and uses ammunition, the player survives), the automap lines, the
stage music, the sound assets, the camera statement, a frame and a screen.

    prepared_pipeline_smoke.py [--map E1M1] [--skill 2] [--attack-tics 40]
"""
import argparse, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client"))
import oradb, game_api  # noqa: E402

# The reference script still expects 102 AI frames and 35 pickups; its own catalogues have since
# grown (CedarDB SQLDoom as installed here: 171 and 39 -- the Oracle catalogues are exported from it).
EXPECTED_CATALOG_COUNTS = {"thing_sprite_defs": 116, "thing_combat_defs": 21, "thing_ai_frames": 171,
                           "pickup_defs": 39, "weapon_defs": 8, "weapon_frames": 51}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", default="E1M1")
    ap.add_argument("--skill", type=int, default=2)
    ap.add_argument("--attack-tics", type=int, default=40)
    a = ap.parse_args()
    conn = oradb.connect()
    cur = conn.cursor()
    game_api.setup_session(cur)
    counts = {}
    for t, n in EXPECTED_CATALOG_COUNTS.items():
        cur.execute(f"SELECT COUNT(*) FROM {t}")
        counts[t] = int(cur.fetchone()[0])
        assert counts[t] == n, f"{t}: expected {n}, got {counts[t]}"
    cur.execute(game_api.STAGES_SQL)
    stage = next((r for r in cur.fetchall() if r[1] == a.map.upper()), None)
    assert stage, f"map {a.map} is not loaded"
    m, p = int(stage[0]), int(stage[2])
    idle = (a.skill, 0.0, 0.0, False, 0.0, False, None, False)
    attack = (a.skill, 0.0, 0.0, False, 0.0, True, None, False)
    pose = game_api.enter_level(cur, m, p, a.skill)
    for _ in range(2):
        game_api.run_tic(cur, m, p, idle)
        conn.commit()
        game_api.finish_tic(cur, m, p)
    pose = game_api.enter_level(cur, m, p, a.skill)
    cur.execute("SELECT ammo_bullets FROM g_player_state WHERE map_id = :m AND player_thing_id = :p", m=m, p=p)
    start_ammo = int(cur.fetchone()[0])
    t0 = time.perf_counter()
    for _ in range(a.attack_tics):
        game_api.run_tic(cur, m, p, attack)
        conn.commit()
        snap = game_api.finish_tic(cur, m, p)
    tic_ms = (time.perf_counter() - t0) * 1e3 / a.attack_tics
    cur.execute("SELECT w.shot_serial, s.ammo_bullets FROM g_player_weapons w JOIN g_player_state s "
                "ON s.map_id = w.map_id AND s.player_thing_id = w.player_thing_id "
                "WHERE w.map_id = :m AND w.player_thing_id = :p", m=m, p=p)
    shots, end_ammo = map(int, cur.fetchone())
    assert shots > 0 and end_ammo < start_ammo, "the weapon tic did not fire and use ammunition"
    assert snap["alive"], "player died during the stationary smoke test"
    cur.execute("SELECT COUNT(*) FROM linedefs WHERE map_id = :m", m=m)
    assert int(cur.fetchone()[0]) > 0, "no automap lines"
    music = game_api.stage_music(cur, m)
    assert music is not None and music[1], "stage music projection returned no row"
    sounds = game_api.sound_assets(cur)
    assert len(sounds) >= 60, "sound assets missing"
    cam = game_api.camera_pose(cur, m, p, 0.5)
    assert cam is not None
    rcur = conn.cursor()
    rcur.arraysize = 256
    frame, fpose = game_api.render_live(rcur, m, p, a.skill, alpha=0.5)
    conn.rollback()
    assert tuple(fpose) == tuple(cam), (fpose, cam)
    screen = game_api.render_screen(cur, 0)
    print(f"map: {a.map} at {tuple(round(v, 2) for v in pose)}")
    print("catalogs:", ", ".join(f"{k}={v}" for k, v in counts.items()))
    print(f"weapon: shots={shots}, bullets={start_ammo}->{end_ammo}; tic {tic_ms:.1f} ms")
    print(f"audio: {len(sounds)} sounds, music {music[0]} ({len(music[1])} MIDI bytes)")
    print(f"camera at alpha 0.5: {tuple(round(v, 3) for v in cam)}; frame {frame.shape}, "
          f"{len(set(frame.ravel().tolist()))} distinct indices; screen {screen.shape}")
    print("prepared pipeline: ok")


if __name__ == "__main__":
    main()
