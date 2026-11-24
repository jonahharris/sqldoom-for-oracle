#!/usr/bin/env python3
"""Install the deathmatch server layer on Oracle: the account broker (once, as SYSTEM), the
server tables (07f), the owner-side package doom_mp (12), the player API functions (13), the
api_* views and the grants -- the Oracle equivalent of cedarscript_runtime.install_api_views
plus scripts/setup_roles.py's grant set.

    python oracle/client/api_install.py --admin        # once: roles + DOOM_ADMIN broker (SYSTEM)
    python oracle/client/api_install.py                # schema + packages + views + grants + audio
    python oracle/client/api_install.py --views-only   # views + grants (after a game reinstall)

The read API is the single-player client's own SQL (client/game_api.py), re-pointed at the caller:
wherever a client statement takes (map_id, player_thing_id) as binds, the view resolves them from
g_mp_players by SYS_CONTEXT('USERENV','SESSION_USER') instead -- generated from the same strings, so
the two cannot drift apart (cedarscript_runtime.api_view_definitions does the same on CedarDB).
A view runs with its owner's rights, which is what lets a user with no table grants read exactly
its own player's slice.

Grants go to two roles (DOOM_PLAYER, DOOM_SPECTATOR), never to PUBLIC, and are READ (not SELECT):
READ cannot lock (no SELECT ... FOR UPDATE, no LOCK TABLE), so no player can hold a lock the tic
needs. Accounts are recorded in api_roles / api_spectator_roles; every install re-grants the API to
the roles and the roles to every registered account (doom_admin.doom_accounts.regrant).
"""
import argparse
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import oradb  # noqa: E402
import game_api  # noqa: E402
import setup_game  # noqa: E402

SQL = oradb.SQL_DIR
SYSTEM_PASSWORD = os.getenv("DOOM_ORA_SYSTEM_PASSWORD", "DoomSys_26ai")
# the IWAD whose sounds/music are loaded: DOOM_WAD (make load-wad WAD=...), default Freedoom
WAD = Path(os.getenv("DOOM_WAD") or HERE.parent / "wad" / "freedoom1.wad").resolve()

ME = "SYS_CONTEXT('USERENV', 'SESSION_USER')"
ME_MAP = f"(SELECT mp.map_id FROM g_mp_players mp WHERE mp.role_name = {ME})"
ME_PLAYER = f"(SELECT mp.player_thing_id FROM g_mp_players mp WHERE mp.role_name = {ME})"
MATCH_MAP = "(SELECT m.map_id FROM g_mp_match m)"

PLAYER_ROLE = "DOOM_PLAYER"
SPECTATOR_ROLE = "DOOM_SPECTATOR"

API_FUNCTIONS = ("api_join", "api_slot", "api_input", "api_camera", "api_weapon_slot", "api_weapon_cycle",
                 "api_set_name", "api_automap", "api_automap_pan", "api_automap_zoom", "api_automap_toggle",
                 "api_automap_fit")
PLAYER_VIEWS = ("api_player_state", "api_snapshot", "api_sound_events", "api_sound_loops", "api_stage_music",
                "api_map_lines", "api_stages", "api_map_geometry", "api_palettes", "api_scoreboard", "api_match",
                "api_things_live")
PLAYER_TABLES = ("sound_assets",)

# What a read-only spectator may read (cedarscript_runtime.SPECTATOR_RELATIONS, Oracle names: the
# live game tables are g_*; CedarDB's live `sectors`/`sidedefs` are g_sectors/g_sidedefs here, its
# static tables keep their names; `things` (live positions there) is not granted -- api_things_spawn)
SPECTATOR_RELATIONS = (
    # the WAD
    "wads", "maps", "vertexes", "sectors", "g_sectors", "sidedefs", "g_sidedefs", "linedefs", "segs",
    "ssectors", "nodes", "node_children", "blockmaps", "walltex_meta", "flat_textures", "sprite_frames",
    "sprite_lumps", "colormap_rgb", "map_music",
    # the catalogues
    "thing_sprite_defs", "pickup_messages", "chase_dir_defs", "thing_role_defs", "thing_blocking_defs",
    "projectile_defs", "thing_combat_defs", "weapon_defs", "weapon_frames", "doom_constants", "thing_ai_frames",
    "effect_sprite_defs", "ammo_defs", "pickup_defs", "level_pars", "boss_actions", "finale_defs",
    "line_special_defs", "sector_special_defs", "thing_sound_defs",
    # the match, without anyone's position
    "g_mp_match", "g_mp_rotation", "g_level_stats", "g_tic_trace", "g_item_respawns", "g_sector_movers",
    # the public views, and the live overview
    "api_match", "api_scoreboard", "api_palettes", "api_things_spawn", "api_things_live", "mp_stats", "api_tic",
)


def _sub(text, old, new):
    assert text.count(old) == 1, f"client statement changed shape: {old[:60]!r}"
    return text.replace(old, new)


def api_view_definitions():
    """(view name, column list or None, SELECT text) for every api_* view."""
    views = []
    # the caller's own player_state row
    views.append(("api_player_state", None,
                  "SELECT ps.* FROM g_player_state ps JOIN g_mp_players mp "
                  "ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id "
                  f"WHERE mp.role_name = {ME}"))
    # the per-tic snapshot (game_tick_finish.sql); menus and demos are single-player, so the
    # screen_state columns are constants here (as cedarscript_runtime does)
    snap = game_api.FINISH_SQL
    snap = _sub(snap, "SELECT /*+ INLINE */ * FROM g_game_tic_commands WHERE map_id = :m AND player_thing_id = :p",
                "SELECT /*+ INLINE */ g.* FROM g_game_tic_commands g JOIN g_mp_players mp\n"
                "      ON mp.map_id = g.map_id AND mp.player_thing_id = g.player_thing_id\n"
                f"   WHERE mp.role_name = {ME}")
    snap = _sub(snap, "ss.screen, CASE WHEN ss.demo_playing IS NOT NULL THEN 1 ELSE 0 END",
                "'game', 0")
    snap = _sub(snap, "  CROSS JOIN screen_state ss\n", "")
    snap = _sub(snap, "\n WHERE ss.id = 0", "")
    assert ":m" not in snap and ":p" not in snap and "screen_state" not in snap
    views.append(("api_snapshot",
                  "position_x, position_y, view_angle, view_z, alive, use_locked, required_key, use_exit, "
                  "use_secret_exit, cross_exit, cross_secret_exit, sector_exit, boss_exit, power_map, tic_stages, "
                  "screen, demo_active", snap))
    # sounds positioned for this listener; the client filters by event_id
    ev = game_api.SOUND_SQL
    ev = _sub(ev, "WHERE t.map_id = :m AND t.id = :p", f"WHERE t.map_id = {ME_MAP} AND t.id = {ME_PLAYER}")
    ev = _sub(ev, "WHERE e.map_id = :m AND e.event_id > :after", f"WHERE e.map_id = {ME_MAP}")
    ev = _sub(ev, "\n  FROM positioned ORDER BY event_id", "\n  FROM positioned")
    assert ":" not in ev.replace("'USERENV'", "")
    views.append(("api_sound_events", None, ev))
    # client/sound_loops.sql: the mover and chainsaw loops for this listener
    lp = game_api.SOUND_LOOPS_SQL
    lp = _sub(lp, "SELECT :m AS map_id, :p AS player_thing_id FROM dual",
              f"SELECT {ME_MAP} AS map_id, {ME_PLAYER} AS player_thing_id FROM dual")
    assert ":m" not in lp and ":p" not in lp
    views.append(("api_sound_loops", None, lp))
    views.append(("api_stage_music", None, _sub(game_api.STAGE_MUSIC_SQL, "WHERE mm.map_id = :m",
                                                f"WHERE mm.map_id = {ME_MAP}")))
    # client/automap.sql for the match's map (live sector heights)
    views.append(("api_map_lines", None, f"""
WITH classified AS (
  SELECT ld.id AS line_id, ld.special, v1.x AS x1, v1.y AS y1, v2.x AS x2, v2.y AS y2,
         CASE WHEN ld.special <> 0 THEN 'special'
              WHEN rs.sector_id IS NULL OR ls.sector_id IS NULL OR BITAND(ld.flags, 1) <> 0 THEN 'wall'
              WHEN rsec.floor_height <> lsec.floor_height THEN 'floor'
              WHEN rsec.ceil_height <> lsec.ceil_height THEN 'ceiling'
              ELSE 'internal' END AS kind
    FROM linedefs ld
    JOIN vertexes v1 ON v1.map_id = ld.map_id AND v1.id = ld.v1_id
    JOIN vertexes v2 ON v2.map_id = ld.map_id AND v2.id = ld.v2_id
    LEFT JOIN g_sidedefs rs ON rs.map_id = ld.map_id AND rs.id = ld.right_sd_id
    LEFT JOIN g_sidedefs ls ON ls.map_id = ld.map_id AND ls.id = ld.left_sd_id
    LEFT JOIN g_sectors rsec ON rsec.map_id = ld.map_id AND rsec.id = rs.sector_id
    LEFT JOIN g_sectors lsec ON lsec.map_id = ld.map_id AND lsec.id = ls.sector_id
   WHERE ld.map_id = {MATCH_MAP})
SELECT x1, y1, x2, y2, kind, line_id, special,
       MIN(LEAST(x1, x2)) OVER () AS min_x, MIN(LEAST(y1, y2)) OVER () AS min_y,
       MAX(GREATEST(x1, x2)) OVER () AS max_x, MAX(GREATEST(y1, y2)) OVER () AS max_y
  FROM classified
 ORDER BY CASE kind WHEN 'internal' THEN 0 WHEN 'ceiling' THEN 1 WHEN 'floor' THEN 2 WHEN 'wall' THEN 3 ELSE 4 END,
          line_id"""))
    # client/stages.sql
    views.append(("api_stages", None, """
WITH ranked AS (
  SELECT m.map_id, m.name, w.wad_path, t.id AS player_thing_id,
         ROW_NUMBER() OVER (PARTITION BY w.wad_path, m.name ORDER BY m.map_id) AS copy_number
    FROM maps m
    JOIN wads w ON w.wad_id = m.wad_id
    JOIN things t ON t.map_id = m.map_id
    JOIN thing_role_defs r ON r.thing_type = t.type AND r.player_number = 1)
SELECT map_id, name, wad_path, player_thing_id FROM ranked WHERE copy_number = 1 ORDER BY wad_path, name"""))
    views.append(("api_map_geometry", None,
                  "SELECT x1, y1, x2, y2, ssector_id, CASE WHEN bsec IS NULL THEN TRUE ELSE FALSE END AS solid "
                  f"FROM g_render_segs WHERE map_id = {MATCH_MAP}"))
    # PLAYPAL: every index COLORMAP can map to, in each of the fourteen palettes (a frame's rows are
    # (y, pal, hex of mapped indices): RGB = api_palettes[pal][idx])
    views.append(("api_palettes", None, game_api.PALETTES_SQL))
    # where the match is: map, time left, between maps, what comes next, the lobby queue
    views.append(("api_match", None, f"""
SELECT m.state, m.map_id, ma.name AS map_name, m.timer_tics, m.altdeath, m.monsters, m.maps_played,
       (SELECT NVL(MAX(ps.level_tics), 0) FROM g_player_state ps JOIN g_mp_players mp
           ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id
         WHERE mp.map_id = m.map_id) AS level_tics,
       ROUND(GREATEST(0, NVL(-doom_mp.secs_since(m.intermission_until), 0))) AS intermission_seconds,
       NVL((SELECT r.map_name FROM g_mp_rotation r
             WHERE r.position > NVL((SELECT r2.position FROM g_mp_rotation r2 WHERE r2.map_name = ma.name), -1)
             ORDER BY r.position FETCH FIRST 1 ROW ONLY),
           NVL((SELECT r.map_name FROM g_mp_rotation r ORDER BY r.position FETCH FIRST 1 ROW ONLY), ma.name))
         AS next_map,
       (SELECT COUNT(*) FROM g_mp_waiting w WHERE w.last_seen >= SYSTIMESTAMP - INTERVAL '5' SECOND) AS waiting,
       (SELECT COUNT(*) FROM g_mp_waiting w JOIN g_mp_waiting mw ON mw.role_name = {ME}
         WHERE w.since < mw.since AND w.last_seen >= SYSTIMESTAMP - INTERVAL '5' SECOND) AS ahead_of_me,
       m.hold_seconds,
       (SELECT ROUND(doom_mp.secs_since(mp.claimed_at)) FROM g_mp_players mp
         WHERE mp.map_id = m.map_id AND mp.role_name = {ME}) AS my_seat_seconds
  FROM g_mp_match m JOIN maps ma ON ma.map_id = m.map_id"""))
    views.append(("api_tic", None,
                  "SELECT tic_ms, tic_p90_ms, tic_max_ms, tics, dropped, interval_seconds, "
                  "TO_BINARY_FLOAT(doom_mp.secs_since(updated_at)) AS age_seconds FROM api_tic_stats WHERE id = 1"))
    # who is in and how they are doing; public to every player
    views.append(("api_scoreboard", None,
                  "SELECT mp.slot, NVL(mp.display_name, mp.role_name) AS role_name, "
                  "CASE WHEN mp.role_name IS NOT NULL THEN TRUE ELSE FALSE END AS connected, "
                  "ps.frags, ps.health, ps.alive, mp.role_name AS login FROM g_mp_players mp "
                  "JOIN g_player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id "
                  "ORDER BY mp.slot"))
    # the overview for spectators and the bots: where things spawn, and the live positions the
    # console's map shows everyone (monsters alive, players holding a slot)
    views.append(("api_things_spawn", None,
                  "SELECT id, map_id, spawn_x, spawn_y, spawn_angle, type, flags FROM things"))
    views.append(("api_things_live", None, """
SELECT t.map_id, t.id AS thing_id, 'monster' AS kind, d.name, t.x, t.y, t.angle, h.alive
  FROM g_things t
  JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill
  JOIN g_thing_health h ON h.map_id = t.map_id AND h.thing_id = t.id
 WHERE h.alive
UNION ALL
SELECT ps.map_id, ps.player_thing_id, 'player', NVL(mp.display_name, mp.role_name),
       ps.position_x, ps.position_y, ps.view_angle, ps.alive
  FROM g_player_state ps
  JOIN g_mp_players mp ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id
 WHERE mp.role_name IS NOT NULL"""))
    return views


def frame_view_name(slot, map_id):
    return f"api_frame_slot{int(slot)}_m{int(map_id)}"


def frame_view_body(map_id, slot):
    """The live renderer for one slot on one map: the camera is the slot's pose (api_camera writes
    it, as float4 like CedarDB's REAL columns, and the view widens it exactly -- render_frame_bd, not
    render_frame, which would treat it as a client's decimal text), and the whole thing gated on the
    caller holding the slot: anyone else gets no rows. Rows (y, pal, hex): 200 rows of 320 COLORMAP-mapped palette
    indices and the active palette (api_palettes gives the RGB). The sprite mode is the match's
    (g_mp_match.sprite_mode: 1 vanilla sprite clipping, 0 CedarDB-exact), the same for every player;
    a player cannot pass any render argument."""
    return (
        "SELECT r.y, r.pal, r.hex FROM g_mp_players mp,\n"
        "  TABLE(doom_hybrid_live.render_frame_bd(-1, mp.map_id, mp.player_thing_id, mp.skill,\n"
        "        TO_BINARY_DOUBLE(mp.pose_x), TO_BINARY_DOUBLE(mp.pose_y),\n"
        "        TO_BINARY_DOUBLE(mp.pose_z), TO_BINARY_DOUBLE(mp.pose_angle), 0, 319,\n"
        "        (SELECT mm.sprite_mode FROM g_mp_match mm WHERE mm.id = 0))) r\n"
        f" WHERE mp.map_id = {int(map_id)} AND mp.slot = {int(slot)} AND mp.role_name = {ME}")


def ensure_match_columns(cur):
    """g_mp_match.sprite_mode (07c) on a database whose match table predates it."""
    cur.execute("SELECT COUNT(*) FROM user_tab_columns WHERE table_name = 'G_MP_MATCH' AND column_name = 'SPRITE_MODE'")
    if not cur.fetchone()[0]:
        cur.execute("ALTER TABLE g_mp_match ADD (sprite_mode NUMBER(1) DEFAULT 1 NOT NULL)")


def install_frame_views(cur, map_ids):
    """api_frame_slot<n>_m<map> for every player start (types 1-4) of every map the match can
    visit, granted to DOOM_PLAYER. A view whose text is already current is left alone (replacing
    it would invalidate every player's parsed frame cursor). Returns {map_id: {slot: thing}}."""
    layout = {}
    ensure_match_columns(cur)
    cur.execute("SELECT view_name, text_vc FROM user_views WHERE view_name LIKE 'API\\_FRAME\\_%' ESCAPE '\\'")
    have = {n.upper(): (t or "") for n, t in cur.fetchall()}
    for map_id in map_ids:
        cur.execute("SELECT type, MIN(id) FROM things WHERE map_id = :m AND type IN (1, 2, 3, 4) GROUP BY type "
                    "ORDER BY type", m=map_id)
        slots = {int(s): int(t) for s, t in cur.fetchall()}
        for slot in slots:
            name, body = frame_view_name(slot, map_id), frame_view_body(map_id, slot)
            if " ".join(have.get(name.upper(), "").split()) != " ".join(body.split()):
                cur.execute(f"CREATE OR REPLACE VIEW {name} AS {body}")
            cur.execute(f"GRANT READ ON {name} TO {PLAYER_ROLE}")
        layout[int(map_id)] = slots
    return layout


def grant_api(cur):
    """The whole grant set, to the two roles (re-run after every install: a dropped and
    recreated object loses its grants)."""
    cur.execute("SELECT object_name FROM user_objects WHERE object_type IN ('TABLE', 'VIEW')")
    present = {r[0].lower() for r in cur.fetchall()}
    for f in API_FUNCTIONS:
        cur.execute(f"GRANT EXECUTE ON {f} TO {PLAYER_ROLE}")
    for v in PLAYER_VIEWS + PLAYER_TABLES:
        cur.execute(f"GRANT READ ON {v} TO {PLAYER_ROLE}")
    cur.execute("SELECT view_name FROM user_views WHERE view_name LIKE 'API\\_FRAME\\_%' ESCAPE '\\'")
    for (v,) in cur.fetchall():
        cur.execute(f"GRANT READ ON {v} TO {PLAYER_ROLE}")
    granted = []
    for rel in SPECTATOR_RELATIONS:
        if rel in present:
            cur.execute(f"GRANT READ ON {rel} TO {SPECTATOR_ROLE}")
            granted.append(rel)
    return granted


def regrant_accounts(cur):
    """Every registered account gets its role again (doom_admin.doom_accounts.regrant)."""
    n = cur.var(int)
    cur.execute("BEGIN :n := doom_admin.doom_accounts.regrant; END;", n=n)
    return n.getvalue()


def install_admin():
    """12_api_admin.sql as SYSTEM: roles, the DOOM_ADMIN broker, EXECUTE on it to DOOM."""
    import oracledb
    conn = oracledb.connect(user="system", password=SYSTEM_PASSWORD, dsn=oradb.DEFAULT_DSN)
    cur = conn.cursor()
    for u in setup_game.units((SQL / "12_api_admin.sql").read_text(encoding="utf-8")):
        stmt = "\n".join(l for l in u.splitlines() if not l.lstrip().startswith("--")).strip()
        if not stmt:
            continue
        if not stmt.upper().startswith(("DECLARE", "BEGIN", "CREATE OR REPLACE PACKAGE")):
            stmt = stmt.rstrip(";")
        cur.execute(stmt)
    cur.execute("SELECT name, type, line, text FROM all_errors WHERE owner = 'DOOM_ADMIN'")
    errs = cur.fetchall()
    for e in errs:
        print("ERR", e)
    print("doom_admin broker:", "VALID" if not errs else "ERRORS")
    conn.close()
    return not errs


def load_audio(cur):
    """sound_assets from the WAD's DS* lumps (wad_loader.load_sounds: DMX format 3 -> 8-bit mono
    WAV, last lump of a name wins), sector_sound_origins from render_segs
    (doom_materialize_render_segs), wads."""
    import io, struct, wave
    import load_wad
    wad = load_wad.Wad(WAD)
    rows = {}
    for lump in wad.lumps:
        name = lump["name"]
        if not name.startswith("DS") or lump["size"] < 8:
            continue
        raw = wad.raw(lump)
        fmt, rate, count = struct.unpack("<HHI", raw[:8])
        if fmt != 3 or rate <= 0:
            continue
        count = min(count, len(raw) - 8)
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1); w.setsampwidth(1); w.setframerate(rate); w.writeframes(raw[8:8 + count])
        rows[name] = buf.getvalue()
    cur.execute("DELETE FROM sound_assets")
    import oracledb
    cur.setinputsizes(None, oracledb.DB_TYPE_BLOB)
    cur.executemany("INSERT INTO sound_assets (name, wav_data) VALUES (:1, :2)", list(rows.items()))
    cur.execute("DELETE FROM sector_sound_origins")
    # AVG over smallint is a numeric in CedarDB, truncated to 19 decimals; its ::real is
    # float4(digits) / float4(10^19), the digits going through a double (verified on all 14,556
    # rows against CedarDB; correct rounding differs in 4,243 of them)
    cur.execute("""
        INSERT INTO sector_sound_origins (map_id, sector_id, x, y)
        SELECT map_id, sector_id,
               TO_BINARY_FLOAT(TO_BINARY_DOUBLE(TRUNC(AVG(x), 19) * 1e19)) / TO_BINARY_FLOAT(1e19),
               TO_BINARY_FLOAT(TO_BINARY_DOUBLE(TRUNC(AVG(y), 19) * 1e19)) / TO_BINARY_FLOAT(1e19)
          FROM (SELECT map_id, fsec AS sector_id, x1 AS x, y1 AS y FROM render_segs
                UNION ALL
                SELECT map_id, bsec, x1, y1 FROM render_segs WHERE bsec IS NOT NULL)
         GROUP BY map_id, sector_id""")
    cur.execute("""MERGE INTO wads w USING (SELECT 1 AS wad_id, 'IWAD' AS wad_type, :p AS wad_path FROM dual) s
                   ON (w.wad_id = s.wad_id)
                   WHEN MATCHED THEN UPDATE SET w.wad_type = s.wad_type, w.wad_path = s.wad_path
                   WHEN NOT MATCHED THEN INSERT (wad_id, wad_type, wad_path) VALUES (s.wad_id, s.wad_type, s.wad_path)""",
                p=str(WAD))
    cur.connection.commit()
    return len(rows)


def load_music(cur, render_audio=True):
    """music_assets + map_music (wad_loader.load_music: MUS -> MIDI for every D_* lump, the map's
    track by name; rendered Ogg only where FluidSynth + a soundfont + ffmpeg exist)."""
    import load_wad, music
    return music.load_music(cur, load_wad.Wad(WAD), render_audio)


def install_client(cur):
    """sql/14_client.sql: doom_float8 (the camera statement's alpha, as CedarDB parses it)."""
    ok = setup_game.install_plsql(cur, SQL / "14_client.sql")
    cur.execute("SELECT status FROM user_objects WHERE object_name = 'DOOM_FLOAT8'")
    row = cur.fetchone()
    return ok and row is not None and row[0] == "VALID"


def install_views(cur):
    for name, cols, body in api_view_definitions():
        cur.execute(f"CREATE OR REPLACE VIEW {name}{f' ({cols})' if cols else ''} AS {body}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--admin", action="store_true", help="install the account broker as SYSTEM (once)")
    ap.add_argument("--views-only", action="store_true", help="views + grants only")
    ap.add_argument("--no-audio", action="store_true")
    ap.add_argument("--client-only", action="store_true", help="sql/14_client.sql only")
    ap.add_argument("--audio-only", action="store_true", help="(re)load sound_assets, music_assets, map_music only")
    a = ap.parse_args()
    if a.admin and not install_admin():
        sys.exit(1)
    conn = oradb.connect()
    cur = conn.cursor()
    if a.client_only:
        print("doom_float8:", "VALID" if install_client(cur) else "ERRORS")
        return
    if a.audio_only:
        print("sound_assets:", load_audio(cur), "sounds")
        n, midi, ogg = load_music(cur)
        print(f"music_assets: {n} tracks, {midi} MIDI bytes, {ogg} rendered audio bytes")
        return
    if not a.views_only:
        oradb.run_script(cur, SQL / "07f_api_schema.sql")
        ensure_match_columns(cur)
        ok = setup_game.install_plsql(cur, SQL / "12_mp_server.sql")
        ok = setup_game.install_plsql(cur, SQL / "13_api.sql") and ok
        ok = install_client(cur) and ok
        cur.execute("SELECT name, type, line, text FROM user_errors WHERE name = 'DOOM_MP' OR name LIKE 'API\\_%' "
                    "ESCAPE '\\' ORDER BY name, sequence")
        errs = cur.fetchall()
        for e in errs[:30]:
            print("ERR", e)
        print("doom_mp / api_*:", "VALID" if not errs else "ERRORS")
        if errs:
            sys.exit(1)
        if not a.no_audio:
            print("sound_assets:", load_audio(cur), "sounds")
            n, midi, ogg = load_music(cur)
            print(f"music_assets: {n} tracks, {midi} MIDI bytes, {ogg} rendered audio bytes")
    install_views(cur)
    # objects invalidated by the reload recompile on first use anyway; do it now so the count is real
    cur.execute("BEGIN DBMS_UTILITY.COMPILE_SCHEMA(USER, compile_all => FALSE); END;")
    cur.execute("SELECT COUNT(*) FROM user_objects WHERE status <> 'VALID' AND (object_name LIKE 'API\\_%' ESCAPE '\\' "
                "OR object_name IN ('DOOM_MP', 'MP_STATS'))")
    bad = cur.fetchone()[0]
    granted = grant_api(cur)
    try:
        n = regrant_accounts(cur)
    except Exception as exc:  # noqa: BLE001 - the broker is not installed yet
        n = f"skipped ({str(exc).splitlines()[0]})"
    conn.commit()
    print(f"api views: {len(api_view_definitions())}, invalid objects: {bad}; spectator relations: {len(granted)}; "
          f"accounts re-granted: {n}")
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()
