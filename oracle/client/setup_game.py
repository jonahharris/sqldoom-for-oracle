#!/usr/bin/env python3
"""Install the Oracle game layer: schema (07), extra catalogs (07b), derived static
tables (linedef_geom, sector_adjacency), the doom_game package (08) and the live
views the renderer can read (09).

    python oracle/client/setup_game.py [--package-only] [--no-schema]

Requires the static data layer (client/load_wad.py) to be loaded first.
"""
import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import oradb  # noqa: E402

DERIVE = [
    "DELETE FROM linedef_geom",
    """INSERT INTO linedef_geom (map_id, linedef_id, x1, y1, x2, y2, flags, special, right_sd_id, left_sd_id, fsec, bsec)
       SELECT ld.map_id, ld.id, v1.x, v1.y, v2.x, v2.y, ld.flags, ld.special, ld.right_sd_id, ld.left_sd_id,
              rs.sector_id, ls.sector_id
         FROM linedefs ld
         JOIN vertexes v1 ON v1.map_id = ld.map_id AND v1.id = ld.v1_id
         JOIN vertexes v2 ON v2.map_id = ld.map_id AND v2.id = ld.v2_id
         LEFT JOIN sidedefs rs ON rs.map_id = ld.map_id AND rs.id = ld.right_sd_id
         LEFT JOIN sidedefs ls ON ls.map_id = ld.map_id AND ls.id = ld.left_sd_id""",
    "DELETE FROM sector_adjacency",
    """INSERT INTO sector_adjacency (map_id, linedef_id, sector_id, other_id)
       SELECT ld.map_id, ld.id, r.sector_id, l.sector_id
         FROM linedefs ld
         JOIN sidedefs r ON r.map_id = ld.map_id AND r.id = ld.right_sd_id
         JOIN sidedefs l ON l.map_id = ld.map_id AND l.id = ld.left_sd_id
       UNION ALL
       SELECT ld.map_id, ld.id, l.sector_id, r.sector_id
         FROM linedefs ld
         JOIN sidedefs r ON r.map_id = ld.map_id AND r.id = ld.right_sd_id
         JOIN sidedefs l ON l.map_id = ld.map_id AND l.id = ld.left_sd_id""",
]

GAME_TABLES = ["doom_constants", "pickup_defs", "pickup_messages", "chase_dir_defs", "thing_role_defs",
               "thing_blocking_defs", "sector_special_defs", "thing_sound_defs", "level_pars", "boss_actions",
               "linedef_geom", "sector_adjacency"]


def units(text):
    cur = []
    for line in text.splitlines():
        if line.strip() == "/":
            u = "\n".join(cur).strip()
            if u:
                yield u
            cur = []
        else:
            cur.append(line)
    u = "\n".join(cur).strip()
    if u:
        yield u


def install_plsql(cur, path):
    """Run a file of '/'-separated units (CREATE PACKAGE / BODY / VIEW ...); report errors."""
    cur.execute("ALTER SESSION SET plsql_optimize_level = 3")
    for u in units(Path(path).read_text(encoding="utf-8")):
        body = "\n".join(l for l in u.splitlines() if not l.lstrip().startswith("-- ") and l.strip() != "--").strip()
        if not body:
            continue
        if not body.upper().startswith(("CREATE OR REPLACE PACKAGE", "CREATE OR REPLACE FUNCTION",
                                        "CREATE OR REPLACE PROCEDURE", "CREATE OR REPLACE TYPE")):
            body = body.rstrip(";")
        cur.execute(u if body.upper().startswith("CREATE OR REPLACE PACKAGE") else body)
    cur.execute("""SELECT name, type, line, position, text FROM user_errors
                    WHERE name IN ('DOOM_GAME', 'DOOM_FLOW', 'DOOM_SCREEN') ORDER BY name, type, sequence""")
    errs = cur.fetchall()
    for e in errs[:40]:
        print("ERR", e)
    return not errs


LIVE_TABLES = ("sectors", "things", "render_things", "player_state", "player_weapons", "player_weapon_owned",
               "monster_ai", "thing_health", "world_effects", "monster_projectiles", "picked_up_items",
               "sector_light_fx", "mp_players", "render_seg_tex")


def live_renderer_source():
    """doom_hybrid_live: 06_hybrid.sql with st_<table> -> lv_<table> (09_live_views.sql)."""
    import re
    src = (oradb.SQL_DIR / "06_hybrid.sql").read_text(encoding="utf-8")
    src = re.sub(r"\bdoom_hybrid\b", "doom_hybrid_live", src)
    src = re.sub(r"\bst_(" + "|".join(LIVE_TABLES) + r")\b", r"lv_\1", src)
    return src


def install_live_renderer(cur):
    import install_hybrid
    for u in install_hybrid.units(live_renderer_source()):
        stmt = install_hybrid.strip_comments(u)
        if not stmt:
            continue
        if not stmt.upper().startswith(("CREATE OR REPLACE PACKAGE", "CREATE TYPE", "CREATE OR REPLACE TYPE")):
            stmt = stmt.rstrip(";")
        cur.execute(stmt)
    cur.execute("SELECT COUNT(*) FROM user_errors WHERE name = 'DOOM_HYBRID_LIVE' AND text NOT LIKE 'PLS-00924%'")
    n = cur.fetchone()[0]
    print("doom_hybrid_live:", "VALID" if n == 0 else f"{n} errors")
    return n == 0


def gather_game_stats(cur, map_id=1, player=157, skill=2):
    """Optimizer statistics for the g_* tables, taken at a level start (enter_level + cheats):
    without them the live views' joins (renderer thing_view) plan badly (+6 ms a frame).
    Phase 4: every map is started first, so the statistics describe the tables as they are once
    the maps have been played (rows of all 36 maps): statistics taken with one map's rows made the
    E1M1 tic 1.7x slower (movement 0.2 -> 1.2 ms) once the other maps had been entered."""
    import game_api
    cur.execute(game_api.STAGES_SQL)
    for m, _name, p in cur.fetchall():
        game_api.level_start(cur, m, p, skill)
    game_api.level_start(cur, map_id, player, skill)
    cur.execute("SELECT table_name FROM user_tables WHERE table_name LIKE 'G\\_%' ESCAPE '\\'")
    for (t,) in cur.fetchall():
        cur.execute("BEGIN DBMS_STATS.GATHER_TABLE_STATS(ownname => USER, tabname => :t, cascade => TRUE,"
                    " no_invalidate => FALSE); END;", t=t)


def install_flow_schema(cur):
    """07d (screen_state, automap view, demos, save slots, menu/finale catalogs) + 07e (their rows)."""
    oradb.run_script(cur, oradb.SQL_DIR / "07d_flow_schema.sql")
    oradb.run_script(cur, oradb.SQL_DIR / "07e_flow_catalogs.sql")
    cur.connection.commit()
    oradb.gather_stats(cur, ["screen_state", "menu_items", "menu_decor", "finale_defs", "demos", "demo_tics",
                             "save_slots", "g_automap_view"])


def install_flow(cur):
    """doom_flow (10_flow.sql) and doom_screen (11_screens.sql)."""
    ok = install_plsql(cur, oradb.SQL_DIR / "10_flow.sql")
    scr = oradb.SQL_DIR / "11_screens.sql"
    if scr.exists():
        ok = install_plsql(cur, scr) and ok
    print("doom_flow/doom_screen:", "VALID" if ok else "ERRORS")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--package-only", action="store_true")
    ap.add_argument("--no-schema", action="store_true", help="keep tables, reinstall catalogs + package")
    ap.add_argument("--live-only", action="store_true", help="only the live views and doom_hybrid_live")
    ap.add_argument("--stats-only", action="store_true", help="only gather the g_* statistics")
    ap.add_argument("--mp-schema", action="store_true", help="(re)create the deathmatch tables (07c) first")
    ap.add_argument("--flow-schema", action="store_true",
                    help="(re)create the flow/screen tables (07d) and their catalogs (07e) first")
    ap.add_argument("--flow-only", action="store_true", help="only doom_flow (10) and doom_screen (11)")
    a = ap.parse_args()
    conn = oradb.connect()
    cur = conn.cursor()
    if a.mp_schema:
        oradb.run_script(cur, oradb.SQL_DIR / "07c_mp_schema.sql")
    if a.flow_schema:
        install_flow_schema(cur)
    if a.flow_only:
        sys.exit(0 if install_flow(cur) else 1)
    if a.stats_only:
        gather_game_stats(cur)
        sys.exit(0)
    if a.live_only:
        install_plsql(cur, oradb.SQL_DIR / "09_live_views.sql")
        sys.exit(0 if install_live_renderer(cur) else 1)
    if not a.package_only:
        if not a.no_schema:
            oradb.run_script(cur, oradb.SQL_DIR / "07_game_schema.sql")
            oradb.run_script(cur, oradb.SQL_DIR / "07c_mp_schema.sql")
            install_flow_schema(cur)
        oradb.run_script(cur, oradb.SQL_DIR / "07b_game_catalogs.sql")
        for s in DERIVE:
            cur.execute(s)
        conn.commit()
        oradb.gather_stats(cur, GAME_TABLES)
    ok = install_plsql(cur, oradb.SQL_DIR / "08_game.sql")
    ok = install_flow(cur) and ok
    live = oradb.SQL_DIR / "09_live_views.sql"
    if live.exists() and not a.package_only:
        install_plsql(cur, live)
        install_live_renderer(cur)
        if ok:
            gather_game_stats(cur)
    print("doom_game:", "VALID" if ok else "ERRORS")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
