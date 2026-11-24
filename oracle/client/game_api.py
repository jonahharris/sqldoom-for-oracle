"""Client API of the Oracle game: the statements SQLDoom's client (doom_sql.py) issues,
translated to Oracle. All game logic runs in the database (package doom_game); this
module only sends commands and fetches results.

  level_start(cur, map_id, player, skill)  -> set_screen + enter_level + IDDQD + IDKFA
  run_tic(cur, map_id, player, command)    -> execute_game_tic (returns sound_due)
  sound_events(cur, map_id, player, after) -> fetch_sound_events (events only)
  finish_tic(cur, map_id, player)          -> finish_game_tic snapshot dict
  camera_pose(cur, map_id, player, alpha)  -> camera_pose (x, y, z, angle)

Float command fields are sent as the decimal text psycopg2 would send (repr) and converted
by doom_game.cmd_real exactly the way CedarDB turns that literal into a REAL parameter.
"""

SESSION_SETUP = (
    "ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,'",
    # TPC-DOOM rule 7: durability is not required; commit without waiting for the redo write.
    "ALTER SESSION SET COMMIT_WAIT = 'NOWAIT'",
    "ALTER SESSION SET COMMIT_LOGGING = 'BATCH'",
    # doom_game holds a few hundred static statements; with the default cache of 50 most of them
    # were soft-parsed again on every execution (~69 parse calls a tic) and a cursor that had left
    # the shared pool meanwhile was hard-parsed mid-run (spikes of 50-100 ms on a rare branch).
    # A larger session cursor cache keeps them: test T 3.34 -> 3.00 ms, 10 parse calls a tic.
    "ALTER SESSION SET SESSION_CACHED_CURSORS = 1000",
)

TIC_SQL = """BEGIN :r := doom_game.run_tic(:m, :p, :s, doom_game.cmd_real(:f), doom_game.cmd_real(:st), :run,
                                             doom_game.cmd_real(:t), :atk, :sw, :use); END;"""

FINISH_SQL = """
WITH command AS (
  SELECT /*+ INLINE */ * FROM g_game_tic_commands WHERE map_id = :m AND player_thing_id = :p
),
cross_exit AS (
  SELECT NVL(MAX(CASE WHEN d.is_exit THEN 1 ELSE 0 END), 0) AS requested,
         NVL(MAX(CASE WHEN d.secret_exit THEN 1 ELSE 0 END), 0) AS secret
    FROM g_line_special_events e
    JOIN command c ON c.map_id = e.map_id AND c.player_thing_id = e.player_thing_id
    JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
    JOIN line_special_defs d ON d.special = ld.special
   WHERE e.trigger_type = 'cross'
),
sector_exit AS (
  SELECT NVL(MAX(CASE WHEN ps.health <= sd.exit_at_health THEN 1 ELSE 0 END), 0) AS requested
    FROM command c
    JOIN g_player_state ps ON ps.map_id = c.map_id AND ps.player_thing_id = c.player_thing_id
    JOIN g_sectors s ON s.map_id = ps.map_id AND s.id = ps.sector_id
    LEFT JOIN sector_special_defs sd ON sd.special = s.special
),
boss_exit AS (
  SELECT NVL(MAX(CASE WHEN q.alive_bosses = 0 THEN 1 ELSE 0 END), 0) AS requested
    FROM (SELECT SUM(CASE WHEN h.alive THEN 1 ELSE 0 END) AS alive_bosses
            FROM command c
            JOIN boss_actions ba ON ba.action = 'exit_level'
            JOIN maps m ON m.name = ba.map_name AND m.map_id = c.map_id
            JOIN g_things t ON t.map_id = m.map_id AND t.type = ba.boss_type
            JOIN g_thing_health h ON h.map_id = t.map_id AND h.thing_id = t.id
           GROUP BY ba.map_name) q
)
SELECT ps.position_x, ps.position_y, ps.view_angle, ps.view_z,
       CASE WHEN ps.alive THEN 1 ELSE 0 END,
       CASE WHEN NVL(ur.locked, FALSE) THEN 1 ELSE 0 END,
       CASE WHEN NVL(ur.locked, FALSE) THEN usd.key_required END,
       CASE WHEN c.use_requested AND ur.eligible AND usd.is_exit THEN 1 ELSE 0 END,
       CASE WHEN c.use_requested AND ur.eligible AND usd.secret_exit THEN 1 ELSE 0 END,
       ce.requested, ce.secret, se.requested, be.requested,
       CASE WHEN ps.power_map THEN 1 ELSE 0 END,
       NVL(tt.stages, 0),
       ss.screen, CASE WHEN ss.demo_playing IS NOT NULL THEN 1 ELSE 0 END
  FROM command c
  CROSS JOIN screen_state ss
  JOIN g_player_state ps ON ps.map_id = c.map_id AND ps.player_thing_id = c.player_thing_id
  LEFT JOIN g_line_use_results ur ON ur.map_id = c.map_id AND ur.player_thing_id = c.player_thing_id
  LEFT JOIN line_special_defs usd ON usd.special = ur.special
  LEFT JOIN g_tic_trace tt ON tt.map_id = c.map_id AND tt.player_thing_id = c.player_thing_id
  CROSS JOIN cross_exit ce CROSS JOIN sector_exit se CROSS JOIN boss_exit be
 WHERE ss.id = 0"""

CAMERA_SQL = """
SELECT ps.previous_x + (ps.position_x - ps.previous_x) * k.a AS x,
       ps.previous_y + (ps.position_y - ps.previous_y) * k.a AS y,
       ps.previous_view_z + (ps.view_z - ps.previous_view_z) * k.a AS z,
       w.a0 + t.turn * k.a - 360d * FLOOR((w.a0 + t.turn * k.a) / 360d) AS angle
  FROM g_player_state ps
 CROSS APPLY (SELECT LEAST(1d, GREATEST(0d, doom_float8(:a))) AS a FROM dual) k
 CROSS APPLY (SELECT TO_BINARY_DOUBLE(ps.previous_view_angle) AS a0,
                     TO_BINARY_DOUBLE(ps.view_angle) - TO_BINARY_DOUBLE(ps.previous_view_angle) + 180d AS d FROM dual) w
 CROSS APPLY (SELECT (w.d - 360d * FLOOR(w.d / 360d)) - 180d AS turn FROM dual) t
 WHERE ps.map_id = :m AND ps.player_thing_id = :p"""

# One statement per frame: the player's camera pose (CAMERA_SQL at alpha 1) joined laterally
# into the live renderer, so pose and frame read the same snapshot; rows (y, pal, hex, x, y, z, angle).
# render_frame takes the pose as NUMBER and converts it the way CedarDB converts the client's
# decimal text; a client that fetched the pose and bound it again would send the shortest decimal
# of each double (Python repr), so the in-SQL hand-off goes through doom_game.shortest (passing
# the BINARY_DOUBLE straight in converts its exact binary expansion instead: wrong in the last ulp
# for some poses). :sprites is the renderer's sprite mode (doom_hybrid p_mode): 0 CedarDB-exact (every
# test and recording), 1 vanilla sprite clipping (the player-facing clients' default).
SPRITES_EXACT, SPRITES_VANILLA = 0, 1
FRAME_AT_SQL = """
SELECT r.y, r.pal, r.hex, c.x, c.y, c.z, c.angle
  FROM (""" + CAMERA_SQL.replace(":m", ":map_id").replace(":p", ":player_id") + """) c,
       TABLE(doom_hybrid_live.render_frame(-1, :map_id, :player_id, :skill, doom_game.shortest(c.x),
                                           doom_game.shortest(c.y), doom_game.shortest(c.z),
                                           doom_game.shortest(c.angle), 0, 319, :sprites)) r"""
FRAME_SQL = FRAME_AT_SQL.replace(":a", "1")
# The same frame for a screen-column range x0..x1 (split mode: two sessions, one frame)
FRAME_AT_SPLIT_SQL = FRAME_AT_SQL.replace("doom_game.shortest(c.angle), 0, 319, :sprites)) r",
                                          "doom_game.shortest(c.angle), :x0, :x1, :sprites)) r")
assert FRAME_AT_SPLIT_SQL != FRAME_AT_SQL


def render_live(cur, map_id, player, skill, alpha=None, sprites=SPRITES_EXACT):
    """(frame uint8[200,320], pose) of the live state, one statement; alpha (the camera between
    the last two tics, client/camera_pose.sql) defaults to the current tic; sprites: the sprite
    mode (default CedarDB-exact)."""
    import numpy as np
    if alpha is None:
        cur.execute(FRAME_SQL, map_id=map_id, player_id=player, skill=skill, sprites=sprites)
    else:
        cur.execute(FRAME_AT_SQL, map_id=map_id, player_id=player, skill=skill, a=float(alpha), sprites=sprites)
    rows = cur.fetchall()
    frame = np.empty((200, 320), np.uint8)
    for y, _p, hx, *_ in rows:
        frame[int(y)] = np.frombuffer(bytes.fromhex(hx), np.uint8)
    return frame, tuple(float(v) for v in rows[0][3:7])


SOUND_SQL = """
WITH listener AS (
  SELECT TO_BINARY_DOUBLE(t.x) AS px, TO_BINARY_DOUBLE(t.y) AS py,
         TO_BINARY_DOUBLE(t.angle) * (3.14159265358979323846d / 180d) AS angle
    FROM g_things t WHERE t.map_id = :m AND t.id = :p),
positioned AS (
  SELECT e.event_id, e.sound_name,
         CASE WHEN e.source_x IS NULL THEN 0d
              ELSE SQRT((e.source_x - l.px) * (e.source_x - l.px) + (e.source_y - l.py) * (e.source_y - l.py)) END AS distance,
         CASE WHEN e.source_x IS NULL THEN 0d
              ELSE SIN(ATAN2(e.source_y - l.py, e.source_x - l.px) - l.angle) END AS pan
    FROM g_sound_events e CROSS JOIN listener l
   WHERE e.map_id = :m AND e.event_id > :after)
SELECT event_id, sound_name,
       CASE WHEN distance <= 160 THEN 1d WHEN distance >= 1200 THEN 0d ELSE 1d - (distance - 160d) / 1040d END AS volume,
       GREATEST(-1d, LEAST(1d, pan)) AS pan
  FROM positioned ORDER BY event_id"""


# client/sound_loops.sql: the complete current loop set (moving sectors, the chainsaw) for a listener
SOUND_LOOPS_SQL = """
WITH input AS (
  SELECT :m AS map_id, :p AS player_thing_id FROM dual),
listener AS (
  SELECT TO_BINARY_DOUBLE(t.x) AS px, TO_BINARY_DOUBLE(t.y) AS py,
         TO_BINARY_DOUBLE(t.angle) * (3.14159265358979323846d / 180d) AS angle
    FROM g_things t JOIN input i ON t.map_id = i.map_id AND t.id = i.player_thing_id),
loops AS (
  SELECT 'mover:' || sm.sector_id AS loop_key, 'DSSTNMOV' AS sound_name,
         TO_BINARY_DOUBLE(so.x) AS source_x, TO_BINARY_DOUBLE(so.y) AS source_y
    FROM g_sector_movers sm
    JOIN input i ON i.map_id = sm.map_id
    JOIN sector_sound_origins so ON so.map_id = sm.map_id AND so.sector_id = sm.sector_id
   WHERE sm.direction IN (-1, 1)
  UNION ALL
  SELECT 'chainsaw:' || i.player_thing_id, CASE WHEN pw.state = 'fire' THEN 'DSSAWFUL' ELSE 'DSSAWIDL' END,
         CAST(NULL AS BINARY_DOUBLE), CAST(NULL AS BINARY_DOUBLE)
    FROM input i JOIN g_player_weapons pw ON pw.map_id = i.map_id AND pw.player_thing_id = i.player_thing_id
   WHERE pw.current_weapon = 8 AND pw.state <> 'down'),
positioned AS (
  SELECT l.loop_key, l.sound_name,
         CASE WHEN l.source_x IS NULL THEN 0d
              ELSE SQRT((l.source_x - p.px) * (l.source_x - p.px) + (l.source_y - p.py) * (l.source_y - p.py)) END AS distance,
         CASE WHEN l.source_x IS NULL THEN 0d
              ELSE SIN(ATAN2(l.source_y - p.py, l.source_x - p.px) - p.angle) END AS pan
    FROM loops l CROSS JOIN listener p)
SELECT loop_key, sound_name,
       CASE WHEN distance <= 160 THEN 1d WHEN distance >= 1200 THEN 0d ELSE 1d - (distance - 160d) / 1040d END AS volume,
       GREATEST(-1d, LEAST(1d, pan)) AS pan
  FROM positioned ORDER BY loop_key"""

# client/sound_assets.sql, client/stage_music.sql, client/demo_header.sql
SOUND_ASSETS_SQL = "SELECT name, wav_data FROM sound_assets"
STAGE_MUSIC_SQL = """
SELECT ma.name, ma.midi_data, ma.audio_data, ma.audio_format
  FROM map_music mm
  JOIN music_assets ma ON ma.name = mm.music_name
 WHERE mm.map_id = :m"""
DEMO_HEADER_SQL = "SELECT demo_id, name, map_id, player_thing_id, skill, tic_count FROM demos WHERE demo_id = :d"
# PLAYPAL as the frames need it: RGB of every mapped index in each of the fourteen palettes
PALETTES_SQL = ("SELECT pal, mapped_index AS idx, MIN(r) AS r, MIN(g) AS g, MIN(b) AS b "
                "FROM colormap_rgb GROUP BY pal, mapped_index")


def sound_loops(cur, map_id, player):
    cur.execute(SOUND_LOOPS_SQL, m=map_id, p=player)
    return cur.fetchall()


def sound_assets(cur):
    cur.execute(SOUND_ASSETS_SQL)
    return [(n, b.read() if hasattr(b, "read") else bytes(b)) for n, b in cur.fetchall()]


def stage_music(cur, map_id):
    """(name, midi bytes, audio bytes or None, audio format) of the map's track, or None."""
    cur.execute(STAGE_MUSIC_SQL, m=map_id)
    row = cur.fetchone()
    if row is None:
        return None
    rd = lambda b: None if b is None else (b.read() if hasattr(b, "read") else bytes(b))  # noqa: E731
    return row[0], rd(row[1]), rd(row[2]), row[3]


def palettes(cur):
    """[14, 256, 3] uint8 RGB lookup for (pal, mapped index)."""
    import numpy as np
    cur.execute(PALETTES_SQL)
    lut = np.zeros((14, 256, 3), np.uint8)
    for pal, idx, r, g, b in cur.fetchall():
        lut[int(pal), int(idx)] = (r, g, b)
    return lut


def setup_session(cur):
    for s in SESSION_SETUP:
        cur.execute(s)


def level_start(cur, map_id, player, skill, cheats=("IDDQD", "IDKFA")):
    # as the recorders do on CedarDB: set_screen('game'), enter_level, the cheats
    cur.execute("UPDATE screen_state SET screen = 'game' WHERE id = 0")
    cur.execute("BEGIN doom_game.enter_level(:m, :p, :s); END;", m=map_id, p=player, s=skill)
    msgs = []
    for code in cheats:
        r = cur.var(str)
        cur.execute("BEGIN :r := doom_game.cheat(:m, :p, :c); END;", r=r, m=map_id, p=player, c=code)
        msgs.append(r.getvalue())
    cur.connection.commit()
    return msgs


def _ftxt(v):
    return repr(float(v))


def run_tic(cur, map_id, player, command):
    """command = (skill, move_fwd, move_strafe, running, turn_degrees, attack_held,
    weapon_switch_to, use_requested) as in the TPC-DOOM command file."""
    skill, fwd, strafe, running, turn, attack, switch, use = command
    r = cur.var(int)
    cur.execute(TIC_SQL, r=r, m=map_id, p=player, s=skill, f=_ftxt(fwd), st=_ftxt(strafe),
                run=1 if running else 0, t=_ftxt(turn), atk=1 if attack else 0, sw=switch,
                use=1 if use else 0)
    return bool(r.getvalue())


def sound_events(cur, map_id, player, after):
    cur.execute(SOUND_SQL, m=map_id, p=player, after=after)
    return cur.fetchall()


def finish_tic(cur, map_id, player):
    cur.execute(FINISH_SQL, m=map_id, p=player)
    row = cur.fetchone()
    if row is None:
        raise RuntimeError("game tic did not produce a player snapshot")
    return {
        "x": float(row[0]), "y": float(row[1]), "angle": float(row[2]), "z": float(row[3]),
        "alive": bool(row[4]), "use_locked": bool(row[5]), "required_key": row[6],
        "use_exit": bool(row[7]), "use_secret_exit": bool(row[8]), "cross_exit": bool(row[9]),
        "cross_secret_exit": bool(row[10]), "sector_exit": bool(row[11]), "boss_exit": bool(row[12]),
        "power_map": bool(row[13]), "tic_stages": int(row[14] or 0),
        "screen": row[15], "demo_active": bool(row[16]),
    }


def camera_pose(cur, map_id, player, alpha):
    cur.execute(CAMERA_SQL, a=float(alpha), m=map_id, p=player)
    row = cur.fetchone()
    return None if row is None else tuple(float(v) for v in row)


# ------------------------------------------------------------------ phase 4: level flow + screens
# client/stages.sql: every loaded map with a player-1 start, by name
STAGES_SQL = """
SELECT m.map_id, m.name, t.id
  FROM maps m
  JOIN things t ON t.map_id = m.map_id
  JOIN thing_role_defs r ON r.thing_type = t.type AND r.player_number = 1
 ORDER BY m.name"""

# client/spawn_pose.sql: the pose the client seeds its camera with after a level start
SPAWN_POSE_SQL = """
SELECT t.x, t.y, t.angle, ps.view_z
  FROM g_things t
  JOIN g_player_state ps ON ps.map_id = t.map_id AND ps.player_thing_id = t.id
  JOIN thing_role_defs r ON r.thing_type = t.type AND r.player_number = 1
 WHERE t.map_id = :m AND t.id = :p"""

# client/level_stats.sql
LEVEL_STATS_SQL = """
SELECT ls.map_id, m.name, ls.skill_bit, ls.level_tics, ls.par_tics, ls.kills, ls.total_kills, ls.items,
       ls.total_items, ls.secrets, ls.total_secrets, ls.secret_exit
  FROM g_level_stats ls JOIN maps m ON m.map_id = ls.map_id
 WHERE ls.map_id = :m AND ls.player_thing_id = :p AND ls.completed"""

# the full-screen composites (sql/11_screens.sql): rows (y, pal, hex)
SCREEN_SQL = "SELECT y, pal, hex FROM TABLE(doom_screen.render_screen(:t))"
AUTOMAP_SQL = "SELECT y, pal, hex FROM TABLE(doom_screen.render_automap(:m, :p))"


def enter_level(cur, map_id, player, skill, from_map=None, from_player=None):
    """G_DoLoadLevel in one call (doom_sql.enter_level); returns the spawn pose (x, y, angle, z)."""
    cur.execute("BEGIN doom_game.enter_level(:m, :p, :s, :fm, :fp); END;", m=map_id, p=player, s=skill,
                fm=from_map, fp=from_player)
    cur.execute(SPAWN_POSE_SQL, m=map_id, p=player)
    row = cur.fetchone()
    cur.connection.commit()
    if row is None:
        raise RuntimeError("could not resolve the selected player start")
    return tuple(float(v) for v in row)


def render_screen(cur, tics):
    """The title/menu/intermission/finale frame: uint8[200,320] palette indices (pal 0)."""
    import numpy as np
    cur.execute(SCREEN_SQL, t=tics)
    frame = np.empty((200, 320), np.uint8)
    for y, _p, hx in cur.fetchall():
        frame[int(y)] = np.frombuffer(bytes.fromhex(hx), np.uint8)
    return frame


def render_automap(cur, map_id, player):
    import numpy as np
    cur.execute(AUTOMAP_SQL, m=map_id, p=player)
    frame = np.empty((200, 320), np.uint8)
    for y, _p, hx in cur.fetchall():
        frame[int(y)] = np.frombuffer(bytes.fromhex(hx), np.uint8)
    return frame
