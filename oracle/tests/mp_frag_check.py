#!/usr/bin/env python3
"""Each player kills the other once with the pistol, through the API (CedarDB
scripts/mp_frag_check.py): the killer gains a frag, the victim keeps its count, both get the frag
messages (with the names set through api_set_name), and the scoreboard shows it.

    python oracle/tests/mp_frag_check.py

Two test players join through api_join; the owner runs the tics in lock-step (doom_mp.tic, the
referee's own call) and, as the CedarDB script does, holds the victim in front of the shooter
(a test privilege, not a client's). The shooter only sends api_input with the fire button held.
"""
import math
import sys

import mp_lib_api as L
sys.path.insert(0, str(L.CLIENT))
import referee as R  # noqa: E402

P = {1: "FRAG_P1", 2: "FRAG_P2"}
NAMES = {1: "ALICE", 2: "BOB"}


def duel(shooter_slot):
    conn, cur = L.owner()
    ref = R.Referee(dict(R.env_config(), map_id=1, skill=3, timer_tics=0, rotation=["E1M1"], monsters=False))
    if not ref.claim():
        raise SystemExit("another referee holds the match")
    players = {}
    try:
        ref.open_match()
        for slot in (1, 2):
            p = L.player(P[slot])
            p.join()
            p.set_name(NAMES[slot])
            players[slot] = p
        ref.tic()   # the claims respawn both players
        slots = ref.players
        s, v = slots[shooter_slot], slots[3 - shooter_slot]
        cur.execute("SELECT position_x, position_y, view_angle, sector_id, base_z, view_z FROM g_player_state "
                    "WHERE map_id = 1 AND player_thing_id = :p", p=s)
        x, y, ang, sec, bz, vz = cur.fetchone()
        a = math.radians(float(ang))
        vx, vy = float(x) + 96 * math.cos(a), float(y) + 96 * math.sin(a)

        def hold_victim():
            cur.execute("UPDATE g_player_state SET position_x = :x, position_y = :y, previous_x = :x, previous_y = :y, "
                        "sector_id = :s, base_z = :bz, view_z = :vz, momentum_x = 0, momentum_y = 0, momentum_z = 0 "
                        "WHERE map_id = 1 AND player_thing_id = :p", x=vx, y=vy, s=sec, bz=bz, vz=vz, p=v)
            cur.execute("UPDATE g_things SET x = :x, y = :y, z = :z, mom_x = 0, mom_y = 0 WHERE map_id = 1 AND id = :p",
                        x=vx, y=vy, z=bz, p=v)
            conn.commit()
        hold_victim()
        alive, tic = True, 0
        for tic in range(400):
            players[shooter_slot].input((0.0, 0.0, False, 0.0, True, None, False))
            players[3 - shooter_slot].input((0.0, 0.0, False, 0.0, False, None, False))
            ref.tic()
            cur.execute("SELECT CASE WHEN alive THEN 1 ELSE 0 END FROM g_player_state WHERE map_id = 1 AND player_thing_id = :p",
                        p=v)
            alive = bool(cur.fetchone()[0])
            if not alive:
                break
            hold_victim()
        ref.tic()
        cur.execute("SELECT player_thing_id, frags, CASE WHEN alive THEN 1 ELSE 0 END, message FROM g_player_state "
                    "WHERE map_id = 1 AND player_thing_id IN (:a, :b) ORDER BY player_thing_id", a=s, b=v)
        rows = cur.fetchall()
        board = players[shooter_slot].query("SELECT slot, role_name, frags, alive FROM api_scoreboard WHERE connected")
        print(f"  slot {shooter_slot} (thing {s}) shoots slot {3 - shooter_slot} (thing {v}): victim "
              f"{'dead' if not alive else 'ALIVE'} after {tic + 1} tics; "
              + "; ".join(f"thing {t}: {f} frags, {'alive' if al else 'dead'}, msg={m!r}" for t, f, al, m in rows))
        print(f"    scoreboard (as {P[shooter_slot]} sees it): {board}")
        frags = {t: f for t, f, _, _ in rows}
        msgs = {t: m for t, _, _, m in rows}
        return ((not alive) and frags[s] == 1 and frags[v] == 0
                and msgs[s] == f"YOU FRAGGED {NAMES[3 - shooter_slot]}"
                and msgs[v] == f"{NAMES[shooter_slot]} FRAGGED YOU"
                and sorted((r[0], r[2]) for r in board) == sorted([(shooter_slot, 1), (3 - shooter_slot, 0)]))
    finally:
        for p in players.values():
            p.close()
        ref.release()
        L.match_cleanup()
        conn.close()


def main():
    L.make_accounts(list(P.values()))
    try:
        ok = duel(1) and duel(2)
    finally:
        print("accounts:", L.drop_accounts(list(P.values())))
    print("FRAGS OK" if ok else "FRAGS WRONG")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
