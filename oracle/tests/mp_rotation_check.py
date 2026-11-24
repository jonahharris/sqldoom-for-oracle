#!/usr/bin/env python3
"""The steady-state match (CedarDB scripts/mp_rotation_check.py): a referee with a short -timer
and a two-map rotation, two bot players through the API, and the owner watching. Checks that the
level ends on the timer, the intermission runs, the match moves to the next map with the same
players in the same slots and zero frags, the bots keep getting frames there, monsters are in, and
a taken item comes back after 30 seconds with its fog and sound.

    python oracle/tests/mp_rotation_check.py
"""
import signal
import sys
import threading
import time

import mp_lib_api as L

P1, P2 = "ROT_P1", "ROT_P2"
TIMER_TICS = 1400          # 40 s: long enough to see an item respawn first
INTERMISSION = 3


def bot(name, stop, out):
    p = L.player(name)
    me = -1
    while me < 0 and not stop.is_set():
        me = p.join()
        time.sleep(0.2)
    frames, empties, errors, last_map = {}, 0, 0, None
    while not stop.is_set():
        try:
            row = p.query("SELECT map_id, map_name, state FROM api_match")[0]
            map_id, mname, state = row
            if mname != last_map:
                out.append(f"    {name} sees {mname} ({state})")
                last_map = mname
            p.input((0.0, 0.0, False, 3.0, False, None, False))
            p.camera(1.0)            # also the heartbeat that keeps the slot
            frame, _pal = p.frame(map_id, p.slot() if p.slot() > 0 else 1)
            p.end_read()
            if frame is None:
                empties += 1         # between maps (or the slot moved): no frame for this view
                time.sleep(0.05)
                continue
            frames[mname] = frames.get(mname, 0) + 1
        except Exception as exc:  # noqa: BLE001
            errors += 1
            p.end_read()
            time.sleep(0.1)
            if errors <= 2:
                out.append(f"    bot error: {str(exc).splitlines()[0][:100]}")
    out.append(f"    {name}: frames per map {frames}, {empties} empty, {errors} errors")
    out.append(("ok", all(v > 20 for v in frames.values()) and len(frames) >= 2 and errors == 0))
    p.close()


def main():
    L.make_accounts([P1, P2])
    env = dict(MAP_ID=1, SKILL=3, IDLE_SECONDS=5, TIMER_TICS=TIMER_TICS, INTERMISSION_SECONDS=INTERMISSION,
               ROTATION="E1M1,E1M2", MONSTERS=1, ALTDEATH=1)
    ref = L.RefereeProcess(env)
    bad = 0

    def check(cond, what):
        nonlocal bad
        bad += 0 if cond else 1
        print(f"  {'ok ' if cond else 'BAD'} {what}", flush=True)

    stop, out, bots = threading.Event(), [], []
    try:
        if not ref.wait_for("ready in"):
            print("\n".join(ref.lines))
            return 1
        print("  referee: " + next((l for l in ref.lines if "match:" in l), "?"))
        conn, ka = L.owner()
        bots = [threading.Thread(target=bot, args=(n, stop, out), daemon=True) for n in (P1, P2)]
        for b in bots:
            b.start()
        time.sleep(6)
        ka.execute("SELECT slot, role_name FROM g_mp_players WHERE role_name IS NOT NULL ORDER BY slot")
        held0 = ka.fetchall()
        check(len(held0) == 2, f"two slots held: {held0}")
        ka.execute("SELECT COUNT(*) FROM g_thing_health h JOIN g_things t ON t.map_id = h.map_id AND t.id = h.thing_id "
                   "JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill WHERE h.map_id = 1 AND h.alive")
        check(ka.fetchone()[0] > 0, "monsters are in (MONSTERS=1)")
        # -altdeath: take an item by hand and watch it come back
        ka.execute("SELECT t.id FROM g_things t JOIN pickup_defs d ON d.thing_type = t.type WHERE t.map_id = 1 "
                   "AND NOT EXISTS (SELECT 1 FROM g_picked_up_items pu WHERE pu.map_id = t.map_id AND pu.thing_id = t.id) "
                   "ORDER BY t.id FETCH FIRST 1 ROW ONLY")
        item = ka.fetchone()[0]
        ka.execute("INSERT INTO g_picked_up_items (map_id, thing_id) VALUES (1, :i)", i=item)
        conn.commit()
        time.sleep(0.5)
        ka.execute("SELECT respawn_tic FROM g_item_respawns WHERE map_id = 1 AND thing_id = :i", i=item)
        q = ka.fetchone()
        check(q is not None, f"item {item} queued for respawn at tic {q and q[0]}")
        t_take, back, fog = time.time(), None, 0
        while time.time() - t_take < 40:
            ka.execute("SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM g_picked_up_items WHERE map_id = 1 AND thing_id = :i) "
                       "THEN 1 ELSE 0 END, (SELECT COUNT(*) FROM g_world_effects WHERE map_id = 1 AND effect_type = 'ifog') "
                       "FROM dual", i=item)
            gone, fog_now = ka.fetchone()
            fog = max(fog, fog_now)
            if gone:
                back = time.time() - t_take
                break
            time.sleep(0.1)
        check(back is not None and 28 <= back <= 36, f"item back after {back and round(back, 1)} s (vanilla: 30)")
        ka.execute("SELECT COUNT(*) FROM g_sound_events WHERE map_id = 1 AND event_key LIKE 'itemrespawn:%'")
        check(ka.fetchone()[0] >= 1, "DSITMBK cued for the respawn")
        for _ in range(12):
            ka.execute("SELECT COUNT(*) FROM g_world_effects WHERE map_id = 1 AND effect_type = 'ifog'")
            fog = max(fog, ka.fetchone()[0])
            time.sleep(0.05)
        check(fog >= 1, f"item fog effect seen ({fog})")
        # the timer
        t0, seen = time.time(), []
        while time.time() - t0 < 60:
            ka.execute("SELECT state, map_id FROM g_mp_match")
            st = ka.fetchone()
            if not seen or seen[-1][1:] != st:
                seen.append((round(time.time() - t0, 1),) + tuple(st))
            if st[0] == "playing" and st[1] != 1:
                break
            time.sleep(0.2)
        print(f"    match states seen: {seen}")
        check(any(s[1] == "intermission" for s in seen), "intermission ran")
        check(seen[-1][1] == "playing" and seen[-1][2] != 1, f"rotated to map {seen[-1][2]}")
        ka.execute("SELECT slot, role_name FROM g_mp_players WHERE role_name IS NOT NULL ORDER BY slot")
        held1 = ka.fetchall()
        check(held1 == held0, f"same players hold the same slots: {held1}")
        time.sleep(8)
        ka.execute("SELECT mp.slot, ps.frags, CASE WHEN ps.alive THEN 1 ELSE 0 END, ps.level_tics FROM g_mp_players mp "
                   "JOIN g_player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id "
                   "WHERE mp.role_name IS NOT NULL ORDER BY mp.slot")
        rows = ka.fetchall()
        check(all(r[2] for r in rows), f"players respawned on the new map: {rows}")
        check(all(r[1] == 0 for r in rows), "frags start at zero")
        conn.close()
    finally:
        stop.set()
        for b in bots:
            b.join(10)
        for line in out:
            if isinstance(line, str):
                print(line)
        stopped = ref.stop(signal.SIGINT)
        L.match_cleanup()
        print("accounts:", L.drop_accounts([P1, P2]))
    check(all(v for k, v in (o for o in out if isinstance(o, tuple))) and len(out) > 0,
          "bots rendered on both maps without errors")
    check(stopped, "referee stopped on SIGINT within 15 s")
    errs = [l for l in ref.lines if "dropped a tic" in l or "Traceback" in l]
    check(not errs, f"referee log clean ({len(errs)} problems)" + ("" if not errs else ": " + errs[0][:120]))
    for l in ref.lines:
        if "level ended" in l or "now on map" in l:
            print("    " + l)
    print("ROTATION OK" if not bad else f"ROTATION: {bad} problems")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
