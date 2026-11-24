#!/usr/bin/env python3
"""What a player account can and cannot do, statement by statement (CedarDB scripts/mp_acl_check.py).

    python oracle/tests/mp_acl_check.py [--keep]

Creates two test players (ACL_P1, ACL_P2) and a spectator through the DOOM_ADMIN broker, opens a
match the way the referee does (client/referee.py: claim, configure, mp_start, frame views, warm-up,
open; no clock running so the owner can look at the input queue), then runs every statement a player
must and must not be able to run. Each forbidden statement must fail with a privilege error (or have
no effect where the API itself refuses, which is checked as owner). Drops the accounts at the end.
"""
import argparse
import sys
import time

import oracledb

import mp_lib_api as L
sys.path.insert(0, str(L.CLIENT))
import referee as R  # noqa: E402

P1, P2 = "ACL_P1", "ACL_P2"
results = []


def tryq(p, label, sql, expect_ok, binds=None, plsql=False, check=None):
    try:
        if plsql:
            p.cur.execute(sql, **(binds or {}))
            note = "ok"
        else:
            p.cur.execute(sql, **(binds or {}))
            rows = p.cur.fetchall() if p.cur.description else "ok"
            note = str(rows)[:60]
        ok = True
        p.conn.commit()
    except oracledb.Error as e:
        p.conn.rollback()
        ok = False
        note = str(e).strip().splitlines()[0][:70]
    good = ok == expect_ok
    if good and check is not None:
        good, extra = check()
        note += f" | {extra}"
    results.append((label, ok, expect_ok, good))
    print(f"  {'allowed' if ok else 'denied '}  {label:<62} {'as expected' if good else '*** UNEXPECTED ***'}   {note}")
    return good


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true", help="keep the test accounts")
    a = ap.parse_args()
    L.make_accounts([P1, P2])
    L.make_accounts(["ACL_SPEC"], "spectator")
    conn, cur = L.owner()

    def one(sql, **b):
        cur.execute(sql, **b)
        return cur.fetchone()
    ref = R.Referee(dict(R.env_config(), map_id=1, skill=2, timer_tics=0, rotation=["E1M1", "E1M2"]))
    if not ref.claim():
        print("another referee holds the match; stop it first")
        return 2
    try:
        ref.open_match()
        p1, p2 = L.player(P1), L.player(P2)
        print("player 1:")
        tryq(p1, "api_join", "BEGIN :r := api_join; END;", True, {"r": p1.cur.var(int)}, plsql=True)
        p1.where()
        own = f"api_frame_slot{p1.slot_no}_m1"
        for v in ("api_snapshot", "api_player_state", "api_palettes", "api_scoreboard", "api_match", "api_sound_events",
                  "api_sound_loops", "api_stage_music", "api_map_lines", "api_map_geometry", "api_stages",
                  "api_things_live", "sound_assets"):
            tryq(p1, f"read {v}", f"SELECT COUNT(*) FROM {v}", True)
        for t in ("g_player_state", "g_things", "things", "linedef_geom", "g_mp_players", "g_mp_inputs", "mp_stats",
                  "api_tic", "api_things_spawn", "g_sound_events", "screen_state"):
            tryq(p1, f"read {t}", f"SELECT COUNT(*) FROM {t}", False)
        tryq(p1, "the other slot's frame view: no frame for a non-holder", "SELECT COUNT(*) FROM api_frame_slot2_m1", True,
             check=lambda: ((n := p1.query("SELECT COUNT(*) FROM api_frame_slot2_m1")[0][0]) == 0, f"{n} rows"))
        tryq(p1, "own frame view", f"SELECT COUNT(*) FROM {own}", True,
             check=lambda: ((n := p1.query(f"SELECT COUNT(*) FROM {own}")[0][0]) == 200, f"{n} rows"))
        tryq(p1, "api_slot", "BEGIN :r := api_slot; END;", True, {"r": p1.cur.var(int)}, plsql=True)
        tryq(p1, "api_camera(0.5)", "BEGIN :r := api_camera(0.5); END;", True, {"r": p1.cur.var(int)}, plsql=True)
        # the camera is the server's: no api_pose, and alpha is clamped
        tryq(p1, "name my own camera with api_pose", "BEGIN :r := api_pose(0, 0, 0, 0); END;", False,
             {"r": p1.cur.var(int)}, plsql=True)
        before = lambda: one("SELECT pose_x, pose_y FROM g_mp_players WHERE role_name = :r", r=P1)
        tryq(p1, "api_camera with alpha out of range (clamped to 1)", "BEGIN :r := api_camera(9999); END;", True,
             {"r": p1.cur.var(int)}, plsql=True,
             check=lambda: (lambda pose, ps: (pose == ps, f"pose {pose} = position {ps}"))(
                 before(), one("SELECT position_x, position_y FROM g_player_state WHERE map_id = 1 AND "
                               "player_thing_id = :p", p=p1.join())))
        tryq(p1, "ask the automap for reveal_all + IDDT", "SELECT COUNT(*) FROM TABLE(api_automap(0, 0, 0.1, 1, 2, 0))",
             False)
        tryq(p1, "draw the automap I am entitled to", "SELECT COUNT(*) FROM TABLE(api_automap())", True)
        tryq(p1, "api_automap_toggle('cheat') (accepted, changes nothing)", "BEGIN :r := api_automap_toggle('cheat'); END;",
             True, {"r": p1.cur.var(int)}, plsql=True,
             check=lambda: (lambda c: (c == 0, f"automap cheat counter {c}"))(
                 one("SELECT NVL(MAX(cheat), 0) FROM g_automap_view WHERE map_id = 1")[0]))
        tryq(p1, "give myself the computer map", "UPDATE g_player_state SET power_map = TRUE", False)
        tryq(p1, "give myself health through the view", "UPDATE api_player_state SET health = 999", False)
        tryq(p1, "lock my player row (SELECT ... FOR UPDATE on a view)", "SELECT health FROM api_player_state FOR UPDATE",
             False)
        tryq(p1, "lock the scoreboard (LOCK TABLE)", "LOCK TABLE api_scoreboard IN EXCLUSIVE MODE", False)
        tryq(p1, "push input via api_input", "BEGIN :r := api_input(1, 0, FALSE, 0, TRUE, NULL, FALSE); END;", True,
             {"r": p1.cur.var(int)}, plsql=True)
        tryq(p1, "api_input out of range (clamped: fwd 50 -> 1, turn 9999 -> 180, weapon 9 -> none)",
             "BEGIN :r := api_input(50, -50, TRUE, 9999, FALSE, 9, FALSE); END;", True, {"r": p1.cur.var(int)}, plsql=True,
             check=lambda: (lambda r: (tuple(r) == (1.0, -1.0, 180.0, None), f"stored {r}"))(
                 one("SELECT move_fwd, move_strafe, turn_degrees, weapon_switch_to FROM g_mp_inputs "
                     "WHERE seq = (SELECT MAX(seq) FROM g_mp_inputs)")))
        tryq(p1, "insert g_mp_inputs for another slot directly",
             "INSERT INTO g_mp_inputs (map_id, player_thing_id) VALUES (1, 158)", False)
        tryq(p1, "run the tic", "BEGIN :r := doom_game.run_mp_tic(1, 2, 157, 158, NULL, NULL); END;", False,
             {"r": p1.cur.var(int)}, plsql=True)
        tryq(p1, "run the referee's tic", "DECLARE e VARCHAR2(2000); BEGIN :r := doom_mp.tic(1, 2, 157, 158, NULL, NULL, e); END;",
             False, {"r": p1.cur.var(int)}, plsql=True)
        tryq(p1, "cheat (doom_game.cheat IDDQD)", "BEGIN :r := doom_game.cheat(1, 157, 'IDDQD'); END;", False,
             {"r": p1.cur.var(str)}, plsql=True)
        tryq(p1, "typed cheat (doom_flow.cheat_key)", "BEGIN doom_flow.cheat_key('i'); END;", False, plsql=True)
        tryq(p1, "reset / open a level (doom_game.enter_level)", "BEGIN doom_game.enter_level(1, 157, 2); END;", False,
             plsql=True)
        tryq(p1, "open a match (doom_game.mp_start)", "BEGIN :r := doom_game.mp_start(1, 2); END;", False,
             {"r": p1.cur.var(int)}, plsql=True)
        tryq(p1, "rotate the match (doom_mp.rotate)", "BEGIN :r := doom_mp.rotate; END;", False, {"r": p1.cur.var(int)},
             plsql=True)
        tryq(p1, "reap the other players (doom_mp.reap)", "BEGIN :r := doom_mp.reap(1, 0); END;", False,
             {"r": p1.cur.var(int)}, plsql=True)
        tryq(p1, "claim a slot for someone else (doom_game.mp_claim)", "BEGIN :r := doom_game.mp_claim(1, 3, 'ACL_P2'); END;",
             False, {"r": p1.cur.var(int)}, plsql=True)
        tryq(p1, "render any pose (doom_hybrid_live.render_frame)",
             "SELECT COUNT(*) FROM TABLE(doom_hybrid_live.render_frame(-1, 1, 158, 2, 0, 0, 41, 0))", False)
        tryq(p1, "set a name with SQL in it (sanitised)", "BEGIN :r := api_set_name('x''); DROP TABLE t; --'); END;", True,
             {"r": p1.cur.var(int)}, plsql=True,
             check=lambda: (lambda n: (n == "X DROP TABLE", f"display_name {n!r}"))(
                 one("SELECT display_name FROM g_mp_players WHERE role_name = :r", r=P1)[0]))
        tryq(p1, "read the broker's account table", "SELECT COUNT(*) FROM doom_admin.accounts", False)
        tryq(p1, "create an account through the broker",
             "BEGIN :r := doom_admin.doom_accounts.add_account('EVIL', 'Evil-Pw-2026x', 'player'); END;", False,
             {"r": p1.cur.var(str)}, plsql=True)
        tryq(p1, "create a user", "CREATE USER evil IDENTIFIED BY \"Evil-Pw-2026x\"", False)
        tryq(p1, "create a table", "CREATE TABLE scratch (x NUMBER)", False)
        tryq(p1, "grant myself a role", "GRANT doom_spectator TO acl_p1", False)
        tryq(p1, "join twice (keeps the one slot)", "BEGIN :r := api_join; END;", True, {"r": p1.cur.var(int)},
             plsql=True, check=lambda: (lambda n: (n == 1, f"slots held {n}"))(
                 one("SELECT COUNT(*) FROM g_mp_players WHERE role_name = :r", r=P1)[0]))
        print("player 2 joins; its input lands on slot 2 only; player 1 cannot read slot 2's frame:")
        pid2 = p2.join()
        p2.where()
        cur.execute("DELETE FROM g_mp_inputs")
        conn.commit()
        p2.input((0.0, 0.0, False, 0.0, False, None, True))
        cur.execute("SELECT player_thing_id, COUNT(*) FROM g_mp_inputs GROUP BY player_thing_id")
        rows = cur.fetchall()
        ok = rows == [(pid2, 1)]
        results.append(("player 2's input on its own slot", ok, ok, ok))
        print(f"  player 2 joined as thing {pid2} (slot {p2.slot_no}); g_mp_inputs by player: {rows} "
              f"{'as expected' if ok else '*** UNEXPECTED ***'}")
        p2.camera(1.0)
        p2.end_read()
        n_other = p1.query(f"SELECT COUNT(*) FROM api_frame_slot{p2.slot_no}_m1")[0][0]
        n_own = p2.query(f"SELECT COUNT(*) FROM api_frame_slot{p2.slot_no}_m1")[0][0]
        ok = n_other == 0 and n_own == 200
        results.append(("slot 2's frame only to its holder", ok, ok, ok))
        print(f"  slot {p2.slot_no}'s frame view: player 1 gets {n_other} rows, player 2 gets {n_own} "
              f"{'as expected' if ok else '*** UNEXPECTED ***'}")
        print("spectator:")
        sp = L.api_client.ApiPlayer("ACL_SPEC", L.TEST_PASSWORD)
        tryq(sp, "read api_scoreboard", "SELECT COUNT(*) FROM api_scoreboard", True)
        tryq(sp, "join the match", "BEGIN :r := api_join; END;", False, {"r": sp.cur.var(int)}, plsql=True)
        tryq(sp, "read a frame view", f"SELECT COUNT(*) FROM {own}", False)
        for c in (p1, p2, sp):
            c.close()
    finally:
        ref.release()
        L.match_cleanup()
        if not a.keep:
            print("accounts:", L.drop_accounts([P1, P2, "ACL_SPEC"]))
    good = all(r[3] for r in results)
    print(f"{sum(r[3] for r in results)}/{len(results)} as expected")
    print("ALL AS EXPECTED" if good else "SOME CHECKS FAILED")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
