#!/usr/bin/env python3
"""What a spectator account can and cannot do (CedarDB scripts/spectator_check.py, Oracle SQL).

    python oracle/tests/spectator_check.py [--keep]

Creates a spectator (MP_SPECTATOR_T) and a player through the DOOM_ADMIN broker, opens a match
the way the referee does (so frame views and slots exist; no clock), then runs three groups:
  console    what a query console asks of the dictionary as this login (its tables, privileges,
             roles, sessions limit) -- every statement must run
  templates  the Doom query templates of CedarDB's spectator console, in Oracle SQL -- must run
  forbidden  read a live position, a slot pose, inputs, monster AI; write the rotation or the
             match; lock a public table (READ, not SELECT, is granted: no FOR UPDATE, no LOCK
             TABLE); create a table; call the player API; draw an identity value; read a frame
             view -- each must be refused
"""
import argparse
import sys

import oracledb

import mp_lib_api as L
sys.path.insert(0, str(L.CLIENT))
import referee as R  # noqa: E402

CONSOLE = {
    "tables and views I can read": "SELECT table_schema, table_name, privilege FROM all_tab_privs WHERE grantee IN "
                                   "(SELECT granted_role FROM user_role_privs) ORDER BY table_name",
    "the catalog (columns)": "SELECT table_name, column_name, data_type FROM all_tab_columns WHERE owner = 'DOOM' "
                             "ORDER BY table_name, column_id",
    "my roles": "SELECT granted_role, default_role FROM user_role_privs",
    "my system privileges": "SELECT privilege FROM session_privs",
    "my session limit (profile)": "SELECT resource_name, limit FROM user_resource_limits WHERE resource_name = 'SESSIONS_PER_USER'",
    "database version": "SELECT banner_full FROM v$version",
}

TEMPLATES = {
    "Who is fragging whom": "SELECT slot, role_name AS player, connected, frags, health, alive FROM doom.api_scoreboard "
                            "ORDER BY frags DESC, slot",
    "Where the match is": "SELECT state, map_name, TRUNC((timer_tics - level_tics) / 35) AS seconds_left, intermission_seconds, "
                          "next_map, maps_played, waiting AS in_lobby, altdeath, monsters FROM doom.api_match",
    "The world, live": "SELECT map_name, monsters_alive, monsters_total, monsters_awake, projectiles, effects, items_out, "
                       "items_queued, movers, input_backlog, sessions FROM doom.mp_stats",
    "Current map as text": """
WITH bounds AS (
  SELECT MIN(x) AS x0, MIN(y) AS y0, GREATEST((MAX(x) - MIN(x)) / 100, (MAX(y) - MIN(y)) / 80, 1) AS cell
    FROM doom.vertexes WHERE map_id = (SELECT map_id FROM doom.api_match)),
lines AS (
  SELECT CASE WHEN l.left_sd_id < 0 THEN 1 ELSE 0 END AS solid, v1.x AS x1, v1.y AS y1, v2.x AS x2, v2.y AS y2,
         GREATEST(1, CEIL(SQRT(POWER(v2.x - v1.x, 2) + POWER(v2.y - v1.y, 2)) / b.cell)) AS steps
    FROM doom.linedefs l
    JOIN doom.vertexes v1 ON v1.map_id = l.map_id AND v1.id = l.v1_id
    JOIN doom.vertexes v2 ON v2.map_id = l.map_id AND v2.id = l.v2_id
   CROSS JOIN bounds b
   WHERE l.map_id = (SELECT map_id FROM doom.api_match)),
wall AS (
  SELECT FLOOR((x1 + (x2 - x1) * t.n / steps - b.x0) / b.cell) AS col,
         FLOOR((y1 + (y2 - y1) * t.n / steps - b.y0) / (2 * b.cell)) AS rw, MAX(solid) AS solid
    FROM lines CROSS JOIN bounds b
   CROSS APPLY (SELECT LEVEL - 1 AS n FROM dual CONNECT BY LEVEL <= steps + 1) t
   GROUP BY FLOOR((x1 + (x2 - x1) * t.n / steps - b.x0) / b.cell), FLOOR((y1 + (y2 - y1) * t.n / steps - b.y0) / (2 * b.cell))),
box AS (SELECT MIN(col) AS c0, MAX(col) AS c1, MIN(rw) AS r0, MAX(rw) AS r1 FROM wall),
g AS (SELECT box.c0 + LEVEL - 1 AS col FROM box CONNECT BY LEVEL <= box.c1 - box.c0 + 1),
r AS (SELECT box.r0 + LEVEL - 1 AS rw FROM box CONNECT BY LEVEL <= box.r1 - box.r0 + 1)
SELECT LISTAGG(CASE WHEN w.solid = 1 THEN '#' WHEN w.col IS NOT NULL THEN '.' ELSE ' ' END) WITHIN GROUP (ORDER BY g.col) AS map
  FROM g CROSS JOIN r LEFT JOIN wall w ON w.col = g.col AND w.rw = r.rw
 GROUP BY r.rw ORDER BY r.rw DESC""",
    "Linedefs of the current map": "SELECT l.id AS linedef, v1.x AS x1, v1.y AS y1, v2.x AS x2, v2.y AS y2, l.flags, l.special, l.tag "
                                   "FROM doom.linedefs l JOIN doom.vertexes v1 ON v1.map_id = l.map_id AND v1.id = l.v1_id "
                                   "JOIN doom.vertexes v2 ON v2.map_id = l.map_id AND v2.id = l.v2_id "
                                   "WHERE l.map_id = (SELECT map_id FROM doom.api_match) ORDER BY l.id",
    "Sectors (live)": "SELECT id AS sector, floor_height, ceil_height, floor_tex, ceil_tex, light_level, special, tag "
                      "FROM doom.g_sectors WHERE map_id = (SELECT map_id FROM doom.api_match) ORDER BY id",
    "Where things spawn": "SELECT t.id AS thing, t.type, d.name, t.spawn_x, t.spawn_y, t.spawn_angle, t.flags "
                          "FROM doom.api_things_spawn t LEFT JOIN doom.thing_combat_defs d ON d.thing_type = t.type "
                          "WHERE t.map_id = (SELECT map_id FROM doom.api_match) ORDER BY t.id",
    "Every monster is a row": "SELECT thing_type, name, spawn_health, radius, height, mass, pain_chance, attack_range, "
                              "missile_type, missile_speed, hitscan_pellets, melee_mult, floats, skull_fly "
                              "FROM doom.thing_combat_defs WHERE counts_kill ORDER BY spawn_health DESC",
    "The line specials": "SELECT special, name, mechanic, cross_activated, use_activated, shoot_activated, key_required, "
                         "is_exit, door_target, mover_type, speed FROM doom.line_special_defs ORDER BY special",
    "The arsenal": "SELECT weapon_id, name, slot, ammo_type, ammo_per_shot, pellet_count, "
                   "dmg_dice_count || 'd' || dmg_dice_mult AS damage, max_range, projectile_type FROM doom.weapon_defs "
                   "ORDER BY slot, weapon_id",
    "Kills, items, secrets": "SELECT player_thing_id, level_tics, kills, total_kills, items, total_items, secrets, total_secrets "
                             "FROM doom.g_level_stats WHERE map_id = (SELECT map_id FROM doom.api_match) ORDER BY player_thing_id",
    "What the planner ran": "SELECT map_id, player_thing_id, stages AS stage_mask FROM doom.g_tic_trace ORDER BY map_id, player_thing_id",
    "The map rotation": "SELECT r.position, r.map_name, m.sky_texture FROM doom.g_mp_rotation r "
                        "LEFT JOIN doom.maps m ON m.name = r.map_name ORDER BY r.position",
    "The live overview": "SELECT kind, name, x, y FROM doom.api_things_live WHERE map_id = (SELECT map_id FROM doom.api_match)",
    "The tic's cost": "SELECT tic_ms, tic_p90_ms, tics, dropped FROM doom.api_tic",
}

FORBIDDEN = {
    "read live player positions": "SELECT position_x, position_y FROM doom.g_player_state",
    "read slot poses": "SELECT pose_x, pose_y, role_name FROM doom.g_mp_players",
    "read live thing positions": "SELECT x, y FROM doom.g_things FETCH FIRST 1 ROW ONLY",
    "read inputs": "SELECT COUNT(*) FROM doom.g_mp_inputs",
    "read monster ai": "SELECT COUNT(*) FROM doom.g_monster_ai",
    "read a player's own view": "SELECT COUNT(*) FROM doom.api_player_state",
    "write the rotation": "INSERT INTO doom.g_mp_rotation (position, map_name) VALUES (99, 'E1M1')",
    "change the match": "UPDATE doom.g_mp_match SET timer_tics = 1",
    "lock the match row (SELECT ... FOR UPDATE)": "SELECT state FROM doom.g_mp_match FOR UPDATE",
    "lock a public table (LOCK TABLE)": "LOCK TABLE doom.g_mp_rotation IN EXCLUSIVE MODE",
    "create a table": "CREATE TABLE spectator_scratch (x NUMBER)",
}


def run(cur, sql):
    try:
        cur.execute(sql)
        rows = cur.fetchall() if cur.description else []
        cur.connection.rollback()
        return True, f"{len(rows)} rows"
    except oracledb.Error as exc:
        cur.connection.rollback()
        return False, str(exc).strip().splitlines()[0][:100]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    spec, pl = "MP_SPECTATOR_T", "MP_SPEC_PLAYER_T"
    L.make_accounts([spec], "spectator")
    L.make_accounts([pl])
    ref = R.Referee(dict(R.env_config(), map_id=1, skill=2, timer_tics=0, rotation=["E1M1"]))
    if not ref.claim():
        print("another referee holds the match; stop it first")
        return 2
    bad = 0
    try:
        ref.open_match()
        p = L.player(pl)
        p.join()
        conn = oracledb.connect(user=spec, password=L.TEST_PASSWORD, dsn=L.oradb.DEFAULT_DSN)
        cur = conn.cursor()
        cur.execute("SELECT USER FROM dual")
        print(f"signed in as {cur.fetchone()[0]}\n\nconsole (the dictionary as this login)")
        for name, sql in CONSOLE.items():
            ok, detail = run(cur, sql)
            bad += not ok
            print(f"  {'OK  ' if ok else 'FAIL'} {name}: {detail}")
        print("\ntemplates (the Doom query library)")
        for name, sql in TEMPLATES.items():
            ok, detail = run(cur, sql)
            bad += not ok
            print(f"  {'OK  ' if ok else 'FAIL'} {name}: {detail}")
        print("\nforbidden (each must be refused)")
        for name, sql in FORBIDDEN.items():
            ok, detail = run(cur, sql)
            bad += ok
            print(f"  {'LEAK' if ok else 'OK  '} {name}: {detail}")
        # the player API: EXECUTE is enforced by Oracle (CedarDB's was not: there api_join answers -1)
        for name, sql in (("join the match", "BEGIN :r := doom.api_join; END;"),
                          ("push input", "BEGIN :r := doom.api_input(1, 0, FALSE, 0, FALSE, NULL, FALSE); END;")):
            try:
                cur.execute(sql, r=cur.var(int))
                print(f"  LEAK {name}: allowed")
                bad += 1
            except oracledb.Error as exc:
                print(f"  OK   {name}: {str(exc).splitlines()[0][:100]}")
        cur.execute("SELECT COUNT(*) FROM doom.api_scoreboard WHERE login = USER")
        holds = cur.fetchone()[0]
        bad += holds > 0
        print(f"  {'LEAK' if holds else 'OK  '} slots held by this login: {holds}")
        # identity sequences: the definer functions draw g_mp_inputs.seq as the owner; nobody else may
        oc, ocur = L.owner()
        ocur.execute("SELECT sequence_name FROM user_tab_identity_cols WHERE table_name = 'G_MP_INPUTS'")
        seq = ocur.fetchone()[0]
        oc.close()
        ok, detail = run(cur, f"SELECT doom.{seq}.NEXTVAL FROM dual")
        bad += ok
        print(f"  {'LEAK' if ok else 'OK  '} draw an identity value ({seq}): {detail}")
        ok, detail = run(cur, "SELECT COUNT(*) FROM doom.api_frame_slot1_m1")
        bad += ok
        print(f"  {'LEAK' if ok else 'OK  '} read a frame view (api_frame_slot1_m1): {detail}")
        # the profile: at most 16 sessions (CedarDB's CONNECTION LIMIT 16)
        cur.execute("SELECT limit FROM user_resource_limits WHERE resource_name = 'SESSIONS_PER_USER'")
        lim = cur.fetchone()[0]
        print(f"  {'OK  ' if lim == '16' else 'FAIL'} sessions per spectator login: {lim}")
        bad += lim != "16"
        conn.close()
        p.close()
    finally:
        ref.release()
        L.match_cleanup()
        if not a.keep:
            print("accounts:", L.drop_accounts([spec, pl]))
    print(f"\n{'all good' if not bad else f'{bad} problem(s)'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
