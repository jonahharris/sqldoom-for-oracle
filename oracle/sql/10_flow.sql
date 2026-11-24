-- =============================================================================
-- 10_flow.sql -- level flow, menus, save/load, demos, cheat keys, automap camera
-- (package doom_flow, phase 4)
--
-- A port of the reference's meta-game functions (reference/sqldoom/sql/runtime/functions):
--   06 doom_finish_level            finish_level
--   33 doom_intermission_*          intermission_begin / _accelerate / _tic
--   41 doom_level_exit, doom_after_intermission, doom_demo_*, doom_attract_*
--   36 doom_finale_*                finale_begin / _tic / _advance
--   31 doom_menu_input              menu_input
--   32 doom_save_game, doom_load_game (incl. loader 00/01 materialize_render_segs/things)
--   38 doom_cheat_key               cheat_key
--   44 doom_automap_*               automap_touch / _pan / _zoom / _toggle / _fit
--   client weapon_slot.sql, weapon_cycle.sql
-- doom_game holds the level start (enter_level incl. 30 doom_carry_player) and the
-- tic (40 doom_run_game_tic incl. demo record/playback).
-- State: screen_state (one row, id 0), demos, demo_tics, save_*, g_automap_view and the
-- g_* game tables (07_game_schema.sql, 07d_flow_schema.sql). Booleans cross the call
-- boundary as 0/1 numbers. CedarDB's '' (cheat_buffer) is NULL here.
-- Units are separated by lines holding a single '/' (client/setup_game.py).
-- =============================================================================
CREATE OR REPLACE PACKAGE doom_flow AS
  PROCEDURE set_screen(p_screen VARCHAR2);
  PROCEDURE finish_level(p_map NUMBER, p_player NUMBER, p_secret NUMBER);
  FUNCTION intermission_begin(p_map NUMBER, p_player NUMBER, p_secret NUMBER) RETURN NUMBER;
  FUNCTION level_exit(p_map NUMBER, p_player NUMBER, p_secret NUMBER) RETURN NUMBER;
  FUNCTION intermission_accelerate RETURN NUMBER;
  FUNCTION intermission_tic RETURN VARCHAR2;
  FUNCTION after_intermission(p_map NUMBER) RETURN VARCHAR2;
  FUNCTION finale_begin(p_episode NUMBER) RETURN NUMBER;
  FUNCTION finale_tic RETURN VARCHAR2;
  FUNCTION finale_advance RETURN VARCHAR2;
  FUNCTION menu_input(p_key VARCHAR2) RETURN VARCHAR2;
  FUNCTION save_game(p_slot NUMBER, p_map NUMBER, p_player NUMBER, p_skill NUMBER, p_name VARCHAR2) RETURN NUMBER;
  FUNCTION load_game(p_slot NUMBER) RETURN NUMBER;
  FUNCTION demo_begin(p_name VARCHAR2, p_map NUMBER, p_player NUMBER, p_skill NUMBER) RETURN NUMBER;
  FUNCTION demo_play(p_name VARCHAR2) RETURN NUMBER;
  PROCEDURE demo_stop;
  PROCEDURE attract_start;
  PROCEDURE attract_stop;
  FUNCTION attract_tic RETURN VARCHAR2;
  FUNCTION cheat_key(p_map NUMBER, p_player NUMBER, p_key VARCHAR2) RETURN VARCHAR2;
  PROCEDURE automap_touch(p_map NUMBER, p_player NUMBER);
  PROCEDURE automap_pan(p_map NUMBER, p_player NUMBER, p_dx BINARY_DOUBLE, p_dy BINARY_DOUBLE);
  PROCEDURE automap_zoom(p_map NUMBER, p_player NUMBER, p_factor BINARY_DOUBLE);
  PROCEDURE automap_toggle(p_map NUMBER, p_player NUMBER, p_what VARCHAR2);
  PROCEDURE automap_fit(p_map NUMBER, p_player NUMBER);
  FUNCTION weapon_slot(p_map NUMBER, p_player NUMBER, p_slot NUMBER) RETURN NUMBER;
  FUNCTION weapon_cycle(p_map NUMBER, p_player NUMBER, p_step NUMBER) RETURN NUMBER;
  -- doom_materialize_render_segs / _render_things over the live g_* tables
  PROCEDURE materialize_render_segs(p_map NUMBER);
  PROCEDURE materialize_render_things(p_map NUMBER);
END doom_flow;
/
CREATE OR REPLACE PACKAGE BODY doom_flow AS
  -- the tables doom_save_game / doom_load_game copy, in the reference's order
  TYPE t_names IS TABLE OF VARCHAR2(64);
  c_saved CONSTANT t_names := t_names('player_state', 'player_weapons', 'player_weapon_owned', 'things',
    'thing_health', 'monster_ai', 'monster_projectiles', 'world_effects', 'sectors', 'sidedefs', 'sector_movers',
    'line_buttons', 'line_activations', 'picked_up_items', 'level_secret_discoveries', 'level_stats');
  TYPE t_cols IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(64);
  g_cols t_cols;     -- g_<table> column list (static dictionary data)

  FUNCTION cols(p_table VARCHAR2) RETURN VARCHAR2 IS
    v VARCHAR2(4000);
  BEGIN
    IF NOT g_cols.EXISTS(p_table) THEN
      SELECT LISTAGG(column_name, ', ') WITHIN GROUP (ORDER BY column_id) INTO v
        FROM user_tab_columns WHERE table_name = 'G_' || UPPER(p_table);
      g_cols(p_table) := v;
    END IF;
    RETURN g_cols(p_table);
  END;

  -- PostgreSQL/CedarDB SUBSTRING(s FROM a FOR n): the characters at positions [a, a+n)
  -- that exist (a may be <= 0); Oracle's SUBSTR treats position 0 as 1.
  FUNCTION pg_substr(s VARCHAR2, a PLS_INTEGER, n PLS_INTEGER) RETURN VARCHAR2 IS
    lo PLS_INTEGER := GREATEST(a, 1); hi PLS_INTEGER := LEAST(a + n - 1, NVL(LENGTH(s), 0));
  BEGIN
    IF hi < lo THEN RETURN NULL; END IF;
    RETURN SUBSTR(s, lo, hi - lo + 1);
  END;

  FUNCTION pg_right(s VARCHAR2, n PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    IF NVL(LENGTH(s), 0) <= n THEN RETURN s; END IF;
    RETURN SUBSTR(s, -n);
  END;

  PROCEDURE set_screen(p_screen VARCHAR2) IS
  BEGIN
    UPDATE screen_state SET screen = p_screen WHERE id = 0;
  END;

  -- doom_finish_level (06): freeze the run's totals for the intermission
  PROCEDURE finish_level(p_map NUMBER, p_player NUMBER, p_secret NUMBER) IS
  BEGIN
    UPDATE g_level_stats ls
       SET (level_tics, kills, items, secrets, completed, secret_exit) = (
           SELECT ps.level_tics,
                  (SELECT COUNT(*) FROM g_thing_health h
                     JOIN g_things t ON t.map_id = h.map_id AND t.id = h.thing_id
                     JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill
                    WHERE h.map_id = p_map AND NOT h.alive),
                  (SELECT COUNT(*) FROM g_picked_up_items pi
                     JOIN g_things t ON t.map_id = pi.map_id AND t.id = pi.thing_id
                    WHERE pi.map_id = p_map
                      AND EXISTS (SELECT 1 FROM pickup_defs d WHERE d.thing_type = t.type AND d.counts_item)),
                  (SELECT COUNT(*) FROM g_level_secret_discoveries sd
                    WHERE sd.map_id = p_map AND sd.player_thing_id = p_player),
                  TRUE, p_secret = 1
             FROM g_player_state ps WHERE ps.map_id = p_map AND ps.player_thing_id = p_player)
     WHERE ls.map_id = p_map AND ls.player_thing_id = p_player
       AND EXISTS (SELECT 1 FROM g_player_state ps WHERE ps.map_id = p_map AND ps.player_thing_id = p_player);
  END;

  -- doom_intermission_begin (33): the tally targets and Doom's next-level routing
  FUNCTION intermission_begin(p_map NUMBER, p_player NUMBER, p_secret NUMBER) RETURN NUMBER IS
    v_ep NUMBER; v_lv NUMBER; v_next_lv NUMBER; v_next_id NUMBER; v_n NUMBER;
    v_tics NUMBER; v_par NUMBER; v_k NUMBER; v_tk NUMBER; v_i NUMBER; v_ti NUMBER; v_s NUMBER; v_ts NUMBER;
    v_found BOOLEAN := FALSE;
  BEGIN
    FOR r IN (SELECT m.name FROM maps m WHERE m.map_id = p_map) LOOP
      v_ep := TO_NUMBER(SUBSTR(r.name, 2, 1)); v_lv := TO_NUMBER(SUBSTR(r.name, 4, 1));
      v_next_lv := CASE WHEN p_secret = 1 THEN 9
                        WHEN v_lv = 9 THEN CASE v_ep WHEN 1 THEN 4 WHEN 2 THEN 6 WHEN 3 THEN 7 ELSE 3 END
                        WHEN v_lv = 8 THEN NULL ELSE v_lv + 1 END;
      SELECT MIN(n.map_id), COUNT(*) INTO v_next_id, v_n FROM maps n
       WHERE n.name = 'E' || TO_CHAR(v_ep) || 'M' || TO_CHAR(v_next_lv);
      FOR s IN (SELECT ls.level_tics, ls.par_tics, ls.kills, ls.total_kills, ls.items, ls.total_items,
                       ls.secrets, ls.total_secrets
                  FROM g_level_stats ls WHERE ls.map_id = p_map AND ls.player_thing_id = p_player) LOOP
        v_found := TRUE;
        v_tics := s.level_tics; v_par := s.par_tics;
        v_k := CASE WHEN s.total_kills > 0 THEN LEAST(100, TRUNC(s.kills * 100 / s.total_kills)) ELSE 0 END;
        v_i := CASE WHEN s.total_items > 0 THEN LEAST(100, TRUNC(s.items * 100 / s.total_items)) ELSE 0 END;
        v_s := CASE WHEN s.total_secrets > 0 THEN LEAST(100, TRUNC(s.secrets * 100 / s.total_secrets)) ELSE 0 END;
      END LOOP;
      IF v_found THEN
        UPDATE screen_state
           SET screen = 'intermission', cursor_index = 0, inter_episode = v_ep, inter_level = v_lv,
               inter_next = NVL(v_next_lv, v_lv), next_map_id = v_next_id, secret_exit = p_secret = 1,
               tgt_kills = v_k, tgt_items = v_i, tgt_secrets = v_s,
               tgt_time = TRUNC(v_tics / 35), tgt_par = NVL(TRUNC(v_par / 35), 0),
               kills_pct = 0, items_pct = 0, secrets_pct = 0, time_secs = 0, par_secs = 0,
               sp_state = 1, cnt_pause = 35, accelerate = FALSE
         WHERE id = 0;
      END IF;
    END LOOP;
    SELECT NVL(MIN(next_map_id), -1) INTO v_next_id FROM screen_state WHERE id = 0;
    RETURN v_next_id;
  END;

  -- doom_level_exit (41): G_DoCompleted
  FUNCTION level_exit(p_map NUMBER, p_player NUMBER, p_secret NUMBER) RETURN NUMBER IS
  BEGIN
    finish_level(p_map, p_player, p_secret);
    RETURN intermission_begin(p_map, p_player, p_secret);
  END;

  FUNCTION intermission_accelerate RETURN NUMBER IS
  BEGIN
    UPDATE screen_state SET accelerate = TRUE WHERE id = 0;
    RETURN 0;
  END;

  -- doom_intermission_tic (33): one 35 Hz step of WI_updateStats
  FUNCTION intermission_tic RETURN VARCHAR2 IS
    v_result VARCHAR2(16) := 'counting'; v_accel BOOLEAN := FALSE; v_state NUMBER := 0;
  BEGIN
    FOR r IN (SELECT accelerate, sp_state FROM screen_state WHERE id = 0) LOOP
      v_accel := r.accelerate; v_state := r.sp_state;
    END LOOP;
    UPDATE screen_state s
       SET kills_pct = CASE WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_kills
                            WHEN s.sp_state = 2 THEN LEAST(s.tgt_kills, s.kills_pct + 2) ELSE s.kills_pct END,
           items_pct = CASE WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_items
                            WHEN s.sp_state = 4 THEN LEAST(s.tgt_items, s.items_pct + 2) ELSE s.items_pct END,
           secrets_pct = CASE WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_secrets
                              WHEN s.sp_state = 6 THEN LEAST(s.tgt_secrets, s.secrets_pct + 2) ELSE s.secrets_pct END,
           time_secs = CASE WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_time
                            WHEN s.sp_state = 8 THEN LEAST(s.tgt_time, s.time_secs + 3) ELSE s.time_secs END,
           par_secs = CASE WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_par
                           WHEN s.sp_state = 8 THEN LEAST(s.tgt_par, s.par_secs + 3) ELSE s.par_secs END,
           sp_state = CASE WHEN s.accelerate AND s.sp_state <> 10 THEN 10
                           WHEN s.sp_state = 2 AND s.kills_pct + 2 >= s.tgt_kills THEN 3
                           WHEN s.sp_state = 4 AND s.items_pct + 2 >= s.tgt_items THEN 5
                           WHEN s.sp_state = 6 AND s.secrets_pct + 2 >= s.tgt_secrets THEN 7
                           WHEN s.sp_state = 8 AND s.time_secs + 3 >= s.tgt_time AND s.par_secs + 3 >= s.tgt_par THEN 10
                           WHEN s.sp_state IN (1, 3, 5, 7, 9) AND s.cnt_pause <= 1 THEN s.sp_state + 1
                           ELSE s.sp_state END,
           cnt_pause = CASE WHEN s.sp_state IN (1, 3, 5, 7, 9) AND s.cnt_pause > 1 THEN s.cnt_pause - 1
                            WHEN s.sp_state IN (1, 3, 5, 7, 9) THEN 35 ELSE s.cnt_pause END,
           accelerate = FALSE
     WHERE s.id = 0;
    FOR r IN (SELECT CASE WHEN screen <> 'intermission' THEN 'done' WHEN sp_state >= 10 THEN 'waiting'
                          ELSE 'counting' END AS st
                FROM screen_state WHERE id = 0) LOOP
      v_result := r.st;
    END LOOP;
    IF v_accel AND v_state >= 10 THEN
      UPDATE screen_state SET screen = 'game', sp_state = 0, cnt_pause = 0 WHERE id = 0;
      v_result := 'done';
    END IF;
    RETURN v_result;
  END;

  -- doom_after_intermission (41): G_WorldDone
  FUNCTION after_intermission(p_map NUMBER) RETURN VARCHAR2 IS
    v_nxt NUMBER := -1; v_ep NUMBER := 1; v_first NUMBER;
  BEGIN
    FOR r IN (SELECT NVL(s.next_map_id, -1) AS n, TO_NUMBER(SUBSTR(m.name, 2, 1)) AS e
                FROM screen_state s, maps m WHERE s.id = 0 AND m.map_id = p_map) LOOP
      v_nxt := r.n; v_ep := r.e;
    END LOOP;
    IF v_nxt >= 0 THEN RETURN 'level:' || TO_CHAR(v_nxt); END IF;
    IF finale_begin(v_ep) <> 0 THEN RETURN 'finale'; END IF;
    SELECT MIN(map_id) INTO v_first FROM maps;
    RETURN 'level:' || TO_CHAR(v_first);
  END;

  -- doom_finale_begin / _tic / _advance (36)
  FUNCTION finale_begin(p_episode NUMBER) RETURN NUMBER IS
    v_found NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_found FROM finale_defs WHERE episode = p_episode;
    IF v_found <> 0 THEN
      UPDATE screen_state SET screen = 'finale', finale_episode = p_episode, finale_count = 0, finale_stage = 0,
                              cursor_index = 0
       WHERE id = 0;
    END IF;
    RETURN v_found;
  END;

  FUNCTION finale_tic RETURN VARCHAR2 IS
    v_result VARCHAR2(16) := 'text';
  BEGIN
    MERGE INTO screen_state s
    USING (SELECT s2.id, CASE WHEN s2.finale_stage = 0 AND s2.finale_count + 1 > LENGTH(f.story_text) * 3 + 250
                              THEN 1 ELSE 0 END AS adv
             FROM screen_state s2 JOIN finale_defs f ON f.episode = s2.finale_episode
            WHERE s2.id = 0 AND s2.screen = 'finale') d
       ON (s.id = d.id)
     WHEN MATCHED THEN UPDATE SET s.finale_count = CASE WHEN d.adv = 1 THEN 0 ELSE s.finale_count + 1 END,
                                  s.finale_stage = CASE WHEN d.adv = 1 THEN 1 ELSE s.finale_stage END;
    FOR r IN (SELECT CASE WHEN screen <> 'finale' THEN 'done' WHEN finale_stage = 0 THEN 'text' ELSE 'picture' END AS st
                FROM screen_state WHERE id = 0) LOOP
      v_result := r.st;
    END LOOP;
    RETURN v_result;
  END;

  FUNCTION finale_advance RETURN VARCHAR2 IS
    v_result VARCHAR2(16) := 'text'; v_stage NUMBER := 0; v_count NUMBER := 0; v_typed NUMBER := 0;
  BEGIN
    FOR r IN (SELECT s.finale_stage, s.finale_count, NVL(LENGTH(f.story_text), 0) * 3 + 10 AS t
                FROM screen_state s LEFT JOIN finale_defs f ON f.episode = s.finale_episode WHERE s.id = 0) LOOP
      v_stage := r.finale_stage; v_count := r.finale_count; v_typed := r.t;
    END LOOP;
    IF v_stage <> 0 THEN
      UPDATE screen_state SET screen = 'title', finale_stage = 0, finale_count = 0, finale_episode = NULL,
                              cursor_index = 0
       WHERE id = 0;
      v_result := 'done';
    END IF;
    IF v_stage = 0 AND v_count < v_typed THEN
      UPDATE screen_state SET finale_count = v_typed WHERE id = 0;
      v_result := 'text';
    END IF;
    IF v_stage = 0 AND v_count >= v_typed THEN
      UPDATE screen_state SET finale_stage = 1, finale_count = 0 WHERE id = 0;
      v_result := 'picture';
    END IF;
    RETURN v_result;
  END;

  -- doom_menu_input (31): one keypress against the title/menu state machine
  FUNCTION menu_input(p_key VARCHAR2) RETURN VARCHAR2 IS
    v_action VARCHAR2(32) := 'none';
  BEGIN
    FOR r IN (SELECT CASE
                       WHEN s.screen = 'skill' AND p_key = 'enter' THEN 'start'
                       WHEN s.screen = 'main' AND p_key = 'enter' AND s.cursor_index = 5 THEN 'quit'
                       WHEN s.screen = 'intermission' AND p_key IN ('enter', 'escape') THEN 'advance'
                       WHEN s.screen = 'load' AND p_key = 'enter'
                            AND EXISTS (SELECT 1 FROM save_slots v WHERE v.slot = s.cursor_index)
                         THEN 'load:' || TO_CHAR(s.cursor_index)
                       WHEN s.screen = 'save' AND p_key = 'enter' THEN 'save:' || TO_CHAR(s.cursor_index)
                       ELSE 'none' END AS act
                FROM screen_state s WHERE s.id = 0) LOOP
      v_action := r.act;
    END LOOP;
    UPDATE screen_state s
       SET screen = CASE
             WHEN s.screen = 'title' THEN 'main'
             WHEN s.screen = 'main' AND p_key = 'enter' AND s.cursor_index = 0 THEN 'episode'
             WHEN s.screen = 'main' AND p_key = 'enter' AND s.cursor_index = 4 THEN 'help1'
             WHEN s.screen = 'help1' AND p_key = 'enter' THEN 'help2'
             WHEN s.screen = 'help2' AND p_key = 'enter' THEN 'main'
             WHEN s.screen IN ('help1', 'help2') AND p_key = 'escape' THEN 'main'
             WHEN s.screen = 'main' AND p_key = 'enter' AND s.cursor_index = 2 THEN 'load'
             WHEN s.screen = 'main' AND p_key = 'enter' AND s.cursor_index = 3 THEN 'save'
             WHEN s.screen IN ('load', 'save') AND p_key = 'escape' THEN 'main'
             WHEN s.screen = 'main' AND p_key = 'escape' THEN 'game'
             WHEN s.screen = 'save' AND p_key = 'enter' THEN 'game'
             WHEN s.screen = 'load' AND p_key = 'enter'
                  AND EXISTS (SELECT 1 FROM save_slots v WHERE v.slot = s.cursor_index) THEN 'game'
             WHEN s.screen = 'episode' AND p_key = 'enter' THEN 'skill'
             WHEN s.screen = 'episode' AND p_key = 'escape' THEN 'main'
             WHEN s.screen = 'skill' AND p_key = 'escape' THEN 'episode'
             WHEN s.screen = 'skill' AND p_key = 'enter' THEN 'game'
             WHEN s.screen = 'intermission' AND p_key IN ('enter', 'escape') THEN 'game'
             ELSE s.screen END,
           cursor_index = CASE
             WHEN s.screen = 'title' THEN 0
             WHEN p_key = 'enter' AND s.screen = 'episode' THEN 2
             WHEN p_key = 'enter' AND ((s.screen = 'main' AND s.cursor_index IN (0, 2, 3))
                                       OR s.screen IN ('skill', 'intermission', 'load', 'save')) THEN 0
             WHEN s.screen IN ('help1', 'help2') THEN 4
             WHEN p_key = 'escape' AND s.screen = 'skill' THEN 0
             WHEN p_key = 'escape' AND s.screen IN ('episode', 'intermission', 'load', 'save', 'main') THEN 0
             WHEN p_key = 'down' THEN MOD(s.cursor_index + 1,
                    GREATEST(1, (SELECT COUNT(*) FROM menu_items m WHERE m.screen = s.screen)))
             WHEN p_key = 'up' THEN MOD(s.cursor_index - 1
                    + GREATEST(1, (SELECT COUNT(*) FROM menu_items m WHERE m.screen = s.screen)),
                    GREATEST(1, (SELECT COUNT(*) FROM menu_items m WHERE m.screen = s.screen)))
             ELSE s.cursor_index END,
           episode = CASE WHEN s.screen = 'episode' AND p_key = 'enter' THEN s.cursor_index + 1 ELSE s.episode END,
           skill = CASE WHEN s.screen = 'skill' AND p_key = 'enter' THEN s.cursor_index ELSE s.skill END
     WHERE s.id = 0;
    RETURN v_action;
  END;

  -- doom_materialize_render_segs (loader 00) over the live sectors/sidedefs
  PROCEDURE materialize_render_segs(p_map NUMBER) IS
  BEGIN
    DELETE FROM g_render_segs WHERE map_id = p_map;
    INSERT INTO g_render_segs (map_id, seg_id, ssector_id, direction, linedef_id, x1, y1, x2, y2, seg_u1, seg_u2,
                               fsec, bsec, x_offset, y_offset, upper_tex, mid_tex, lower_tex, flags,
                               f_floor, f_ceil, f_ceil_tex, f_light, b_floor, b_ceil, b_ceil_tex, b_light, light_bias)
    SELECT rs.map_id, rs.seg_id, rs.ssector_id, rs.direction, rs.linedef_id, rs.x1, rs.y1, rs.x2, rs.y2,
           rs.seg_u1, rs.seg_u2, fs.id, bs.id, front.x_offset, front.y_offset,
           front.upper_tex, front.mid_tex, front.lower_tex, ld.flags,
           fs.floor_height, fs.ceil_height, fs.ceil_tex, fs.light_level,
           bs.floor_height, bs.ceil_height, bs.ceil_tex, bs.light_level, rs.light_bias
      FROM render_segs rs
      JOIN linedefs ld ON ld.map_id = rs.map_id AND ld.id = rs.linedef_id
      JOIN g_sidedefs front ON front.map_id = rs.map_id
       AND front.id = CASE WHEN rs.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END
      LEFT JOIN g_sidedefs back ON back.map_id = rs.map_id
       AND back.id = CASE WHEN rs.direction = 0 THEN ld.left_sd_id ELSE ld.right_sd_id END
      JOIN g_sectors fs ON fs.map_id = rs.map_id AND fs.id = front.sector_id
      LEFT JOIN g_sectors bs ON bs.map_id = rs.map_id AND bs.id = back.sector_id
     WHERE rs.map_id = p_map;
  END;

  -- doom_materialize_render_things (loader 01) over the live things: each Thing with a sprite,
  -- located by the BSP (the side test in float4 as the reference's (tx - n.x)::float8)
  PROCEDURE materialize_render_things(p_map NUMBER) IS
    TYPE t_n IS TABLE OF NUMBER;
    TYPE t_f IS TABLE OF BINARY_FLOAT;
    ids t_n; xs t_f; ys t_f; secs t_n := t_n();
  BEGIN
    DELETE FROM g_render_things WHERE map_id = p_map;
    SELECT t.id, t.x, t.y BULK COLLECT INTO ids, xs, ys
      FROM g_things t JOIN thing_sprite_defs d ON d.thing_type = t.type WHERE t.map_id = p_map;
    secs.EXTEND(ids.COUNT);
    FOR i IN 1 .. ids.COUNT LOOP secs(i) := doom_game.locate_thing(p_map, xs(i), ys(i)); END LOOP;
    FORALL i IN 1 .. ids.COUNT
      INSERT INTO g_render_things (map_id, thing_id, sector_id, spawn_sector_id, sprite, frame, fullbright,
                                   spawn_ceiling, thing_height)
      SELECT p_map, t.id, secs(i), secs(i), d.sprite, d.frame, d.fullbright, d.spawn_ceiling, d.thing_height
        FROM g_things t JOIN thing_sprite_defs d ON d.thing_type = t.type
       WHERE t.map_id = p_map AND t.id = ids(i) AND secs(i) IS NOT NULL;
  END;

  -- doom_save_game (32)
  FUNCTION save_game(p_slot NUMBER, p_map NUMBER, p_player NUMBER, p_skill NUMBER, p_name VARCHAR2) RETURN NUMBER IS
  BEGIN
    DELETE FROM save_slots WHERE slot = p_slot;
    INSERT INTO save_slots (slot, saved_at, name, map_id, player_thing_id, map_name, skill)
    SELECT p_slot, SYSTIMESTAMP, p_name, p_map, p_player, (SELECT m.name FROM maps m WHERE m.map_id = p_map),
           NVL((SELECT ls.skill_bit FROM g_level_stats ls WHERE ls.map_id = p_map AND ls.player_thing_id = p_player),
               p_skill)
      FROM dual;
    FOR i IN 1 .. c_saved.COUNT LOOP
      EXECUTE IMMEDIATE 'DELETE FROM save_' || c_saved(i) || ' WHERE slot = :s' USING p_slot;
      EXECUTE IMMEDIATE 'INSERT INTO save_' || c_saved(i) || ' (slot, ' || cols(c_saved(i)) || ') SELECT :s, '
                        || cols(c_saved(i)) || ' FROM g_' || c_saved(i) || ' WHERE map_id = :m' USING p_slot, p_map;
    END LOOP;
    RETURN p_slot;
  END;

  -- doom_load_game (32): the restored map_id, or -1 when the slot is empty
  FUNCTION load_game(p_slot NUMBER) RETURN NUMBER IS
    v_target NUMBER;
  BEGIN
    SELECT NVL(MIN(map_id), -1) INTO v_target FROM save_slots WHERE slot = p_slot;
    IF v_target >= 0 THEN
      FOR i IN 1 .. c_saved.COUNT LOOP
        EXECUTE IMMEDIATE 'DELETE FROM g_' || c_saved(i) || ' WHERE map_id = :m' USING v_target;
        EXECUTE IMMEDIATE 'INSERT INTO g_' || c_saved(i) || ' (' || cols(c_saved(i)) || ') SELECT '
                          || cols(c_saved(i)) || ' FROM save_' || c_saved(i) || ' WHERE slot = :s' USING p_slot;
      END LOOP;
      DELETE FROM g_game_tic_commands WHERE map_id = v_target;
      DELETE FROM g_line_special_events WHERE map_id = v_target;
      DELETE FROM g_line_use_results WHERE map_id = v_target;
      DELETE FROM g_pickup_touches WHERE map_id = v_target;
      DELETE FROM g_pickup_grants WHERE map_id = v_target;
      DELETE FROM g_sound_events WHERE map_id = v_target;
      DELETE FROM g_hitscan_hits WHERE map_id = v_target;
      DELETE FROM g_projectile_damage WHERE map_id = v_target;
      DELETE FROM g_projectile_impacts WHERE map_id = v_target;
      DELETE FROM g_monster_attack_damage WHERE map_id = v_target;
      materialize_render_segs(v_target);
      materialize_render_things(v_target);
      DELETE FROM g_sector_light_fx WHERE map_id = v_target;
      INSERT INTO g_sector_light_fx (map_id, sector_id, special, base_light, dark_light)
      SELECT s.map_id, s.id, s.special, NVL(s.spawn_light_level, s.light_level),
             LEAST(NVL(s.spawn_light_level, s.light_level), NVL(MIN(other.light_level), 0))
        FROM g_sectors s
        LEFT JOIN (SELECT edge.map_id, r.sector_id AS rsec, l.sector_id AS lsec
                     FROM linedefs edge
                     LEFT JOIN g_sidedefs r ON r.map_id = edge.map_id AND r.id = edge.right_sd_id
                     LEFT JOIN g_sidedefs l ON l.map_id = edge.map_id AND l.id = edge.left_sd_id
                    WHERE edge.map_id = v_target) e
          ON e.rsec = s.id OR e.lsec = s.id
        LEFT JOIN g_sectors other ON other.map_id = s.map_id
         AND other.id = CASE WHEN e.rsec = s.id THEN e.lsec WHEN e.lsec = s.id THEN e.rsec END
       WHERE s.map_id = v_target AND s.special IN (1, 2, 3, 8, 12, 13, 17)
       GROUP BY s.map_id, s.id, s.special, s.spawn_light_level, s.light_level;
      doom_game.reset_cache;
    END IF;
    RETURN v_target;
  END;

  -- doom_demo_begin / _play / _stop (41)
  FUNCTION demo_begin(p_name VARCHAR2, p_map NUMBER, p_player NUMBER, p_skill NUMBER) RETURN NUMBER IS
    v_did NUMBER;
  BEGIN
    SELECT NVL((SELECT MIN(d.demo_id) FROM demos d WHERE d.name = p_name),
               (SELECT NVL(MAX(x.demo_id), 0) + 1 FROM demos x)) INTO v_did FROM dual;
    DELETE FROM demo_tics WHERE demo_id = v_did;
    MERGE INTO demos d USING (SELECT v_did AS demo_id FROM dual) q ON (d.demo_id = q.demo_id)
     WHEN MATCHED THEN UPDATE SET d.name = p_name, d.map_id = p_map, d.player_thing_id = p_player, d.skill = p_skill,
                                  d.tic_count = 0, d.recorded_at = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (demo_id, name, map_id, player_thing_id, skill, tic_count)
                           VALUES (v_did, p_name, p_map, p_player, p_skill, 0);
    UPDATE screen_state SET demo_recording = v_did, demo_playing = NULL, demo_tic = 0 WHERE id = 0;
    RETURN v_did;
  END;

  FUNCTION demo_play(p_name VARCHAR2) RETURN NUMBER IS
    v_did NUMBER := -1;
  BEGIN
    FOR r IN (SELECT d.demo_id FROM demos d WHERE d.name = p_name) LOOP v_did := r.demo_id; END LOOP;
    IF v_did >= 0 THEN
      UPDATE screen_state SET demo_playing = v_did, demo_recording = NULL, demo_tic = 0 WHERE id = 0;
    END IF;
    RETURN v_did;
  END;

  PROCEDURE demo_stop IS
  BEGIN
    UPDATE screen_state SET demo_playing = NULL, demo_recording = NULL, demo_tic = 0 WHERE id = 0;
  END;

  -- D_DoAdvanceDemo (41): title, demo, credit, demo ...
  PROCEDURE attract_start IS
  BEGIN
    UPDATE screen_state SET attract_step = 0, attract_pagetic = 170, screen = 'title', cursor_index = 0,
                            demo_playing = NULL, demo_recording = NULL, demo_tic = 0
     WHERE id = 0;
  END;

  PROCEDURE attract_stop IS
  BEGIN
    UPDATE screen_state SET attract_step = -1,
                            screen = CASE WHEN demo_playing IS NOT NULL THEN 'title' ELSE screen END,
                            demo_playing = NULL, demo_tic = 0
     WHERE id = 0;
  END;

  FUNCTION attract_tic RETURN VARCHAR2 IS
    v_step NUMBER := -1; v_pagetic BINARY_FLOAT := 0; v_playing NUMBER; v_n NUMBER; v_slot NUMBER;
    v_did NUMBER := -1;
  BEGIN
    FOR r IN (SELECT attract_step, attract_pagetic, demo_playing FROM screen_state WHERE id = 0) LOOP
      v_step := r.attract_step; v_pagetic := r.attract_pagetic; v_playing := r.demo_playing;
    END LOOP;
    IF v_step < 0 OR v_playing IS NOT NULL THEN RETURN 'none'; END IF;
    IF v_pagetic > 1 THEN
      UPDATE screen_state SET attract_pagetic = attract_pagetic - 1 WHERE id = 0;
      RETURN 'none';
    END IF;
    v_step := v_step + 1;
    SELECT COUNT(*) INTO v_n FROM demos;
    IF v_n = 0 THEN
      UPDATE screen_state SET attract_step = v_step, attract_pagetic = 170, screen = 'title', cursor_index = 0
       WHERE id = 0;
      RETURN 'page';
    END IF;
    v_slot := MOD(v_step, 2 * v_n);
    IF MOD(v_slot, 2) = 0 THEN
      UPDATE screen_state
         SET attract_step = v_step, attract_pagetic = CASE WHEN v_slot = 0 THEN 170 ELSE 200 END,
             screen = CASE WHEN v_slot = 0 THEN 'title' ELSE 'help2' END, cursor_index = 0
       WHERE id = 0;
      RETURN 'page';
    END IF;
    FOR r IN (SELECT q.demo_id FROM (SELECT d.demo_id, ROW_NUMBER() OVER (ORDER BY d.demo_id) AS rn FROM demos d) q
               WHERE q.rn = TRUNC(v_slot / 2) + 1) LOOP
      v_did := r.demo_id;
    END LOOP;
    UPDATE screen_state SET attract_step = v_step, attract_pagetic = 0, demo_playing = v_did, demo_recording = NULL,
                            demo_tic = 0, screen = 'game'
     WHERE id = 0;
    RETURN 'demo:' || TO_CHAR(v_did);
  END;

  -- doom_cheat_key (38): ST_Responder's sequence buffer
  FUNCTION cheat_key(p_map NUMBER, p_player NUMBER, p_key VARCHAR2) RETURN VARCHAR2 IS
    v_buf VARCHAR2(64); v_len PLS_INTEGER; v_result VARCHAR2(400) := 'none';
    TYPE t_codes IS TABLE OF VARCHAR2(16);
    -- ORDER BY LENGTH(code) DESC, code
    c_codes CONSTANT t_codes := t_codes('IDCHOPPERS', 'IDSPISPOPD', 'IDBEHOLDA', 'IDBEHOLDI', 'IDBEHOLDL',
                                         'IDBEHOLDR', 'IDBEHOLDS', 'IDBEHOLDV', 'IDMYPOS', 'IDCLIP', 'IDDQD',
                                         'IDKFA', 'IDFA');
    c1 VARCHAR2(4); c2 VARCHAR2(4);
  BEGIN
    UPDATE screen_state SET cheat_buffer = CASE WHEN LENGTH(cheat_buffer || UPPER(p_key)) > 12
                                                THEN SUBSTR(cheat_buffer || UPPER(p_key), -12)
                                                ELSE cheat_buffer || UPPER(p_key) END
     WHERE id = 0;
    FOR r IN (SELECT cheat_buffer FROM screen_state WHERE id = 0) LOOP v_buf := r.cheat_buffer; END LOOP;
    v_len := NVL(LENGTH(v_buf), 0);
    c1 := pg_substr(v_buf, v_len - 1, 1); c2 := pg_right(v_buf, 1);
    IF pg_substr(v_buf, v_len - 7, 6) = 'IDCLEV' AND c1 BETWEEN '1' AND '9' AND c2 BETWEEN '1' AND '9' THEN
      v_result := 'warp:E' || c1 || 'M' || c2;
    ELSIF pg_substr(v_buf, v_len - 6, 5) = 'IDMUS' AND c1 BETWEEN '1' AND '9' AND c2 BETWEEN '1' AND '9' THEN
      v_result := 'music:E' || c1 || 'M' || c2;
    ELSIF pg_right(v_buf, 4) = 'IDDT' THEN
      v_result := 'iddt';
    ELSE
      FOR i IN 1 .. c_codes.COUNT LOOP
        IF v_len >= LENGTH(c_codes(i)) AND SUBSTR(v_buf, -LENGTH(c_codes(i))) = c_codes(i) THEN
          v_result := 'msg:' || doom_game.cheat(p_map, p_player, c_codes(i));
          EXIT;
        END IF;
      END LOOP;
    END IF;
    IF v_result <> 'none' THEN
      UPDATE screen_state SET cheat_buffer = NULL WHERE id = 0;
    END IF;
    RETURN v_result;
  END;

  -- doom_automap_* (44)
  PROCEDURE automap_touch(p_map NUMBER, p_player NUMBER) IS
  BEGIN
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_automap_view g_automap_view_pk) */
      INTO g_automap_view (map_id, player_thing_id, center_x, center_y)
    SELECT p_map, p_player, ps.position_x, ps.position_y
      FROM g_player_state ps WHERE ps.map_id = p_map AND ps.player_thing_id = p_player;
  END;

  PROCEDURE automap_pan(p_map NUMBER, p_player NUMBER, p_dx BINARY_DOUBLE, p_dy BINARY_DOUBLE) IS
  BEGIN
    automap_touch(p_map, p_player);
    UPDATE g_automap_view av
       SET (center_x, center_y, follow) = (
           SELECT TO_BINARY_FLOAT(TO_BINARY_DOUBLE(CASE WHEN av.follow THEN ps.position_x ELSE av.center_x END) + p_dx),
                  TO_BINARY_FLOAT(TO_BINARY_DOUBLE(CASE WHEN av.follow THEN ps.position_y ELSE av.center_y END) + p_dy),
                  FALSE
             FROM g_player_state ps WHERE ps.map_id = av.map_id AND ps.player_thing_id = av.player_thing_id)
     WHERE av.map_id = p_map AND av.player_thing_id = p_player
       AND EXISTS (SELECT 1 FROM g_player_state ps WHERE ps.map_id = av.map_id AND ps.player_thing_id = av.player_thing_id);
  END;

  FUNCTION kconst(p_name VARCHAR2) RETURN BINARY_DOUBLE IS
    v BINARY_DOUBLE;
  BEGIN
    SELECT value INTO v FROM doom_constants WHERE name = p_name;
    RETURN v;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL;
  END;

  PROCEDURE automap_zoom(p_map NUMBER, p_player NUMBER, p_factor BINARY_DOUBLE) IS
    v_lo BINARY_DOUBLE := kconst('AUTOMAP_MIN_ZOOM'); v_hi BINARY_DOUBLE := kconst('AUTOMAP_MAX_ZOOM');
    z BINARY_DOUBLE;
  BEGIN
    automap_touch(p_map, p_player);
    FOR r IN (SELECT zoom FROM g_automap_view WHERE map_id = p_map AND player_thing_id = p_player) LOOP
      z := TO_BINARY_DOUBLE(r.zoom) * p_factor;
      IF v_hi < z THEN z := v_hi; END IF;
      IF v_lo > z THEN z := v_lo; END IF;
      UPDATE g_automap_view SET zoom = TO_BINARY_FLOAT(z) WHERE map_id = p_map AND player_thing_id = p_player;
    END LOOP;
  END;

  PROCEDURE automap_toggle(p_map NUMBER, p_player NUMBER, p_what VARCHAR2) IS
  BEGIN
    automap_touch(p_map, p_player);
    UPDATE g_automap_view
       SET follow = CASE WHEN p_what = 'follow' THEN NOT follow ELSE follow END,
           grid = CASE WHEN p_what = 'grid' THEN NOT grid ELSE grid END,
           cheat = CASE WHEN p_what = 'cheat' THEN MOD(cheat + 1, 3) ELSE cheat END
     WHERE map_id = p_map AND player_thing_id = p_player;
  END;

  -- automap_fit: CedarDB's numeric division keeps scale s1 + p2 + 1 digits, truncated
  -- (224.0 / GREATEST(1.0, smallint): numeric(5,1) / numeric(6,1) -> 8 decimals), and a
  -- numeric converts to double as digits / 10^scale
  PROCEDURE automap_fit(p_map NUMBER, p_player NUMBER) IS
    v_wh BINARY_DOUBLE := kconst('AUTOMAP_WORLD_HEIGHT');
    v_lo BINARY_DOUBLE := kconst('AUTOMAP_MIN_ZOOM'); v_hi BINARY_DOUBLE := kconst('AUTOMAP_MAX_ZOOM');
    v_x0 NUMBER; v_x1 NUMBER; v_y0 NUMBER; v_y1 NUMBER; fx NUMBER; fy NUMBER; f BINARY_DOUBLE;
  BEGIN
    automap_touch(p_map, p_player);
    SELECT MIN(LEAST(v1.x, v2.x)), MAX(GREATEST(v1.x, v2.x)), MIN(LEAST(v1.y, v2.y)), MAX(GREATEST(v1.y, v2.y))
      INTO v_x0, v_x1, v_y0, v_y1
      FROM linedefs ld
      JOIN vertexes v1 ON v1.map_id = ld.map_id AND v1.id = ld.v1_id
      JOIN vertexes v2 ON v2.map_id = ld.map_id AND v2.id = ld.v2_id
     WHERE ld.map_id = p_map;
    IF v_x0 IS NULL THEN RETURN; END IF;
    fx := TRUNC(224 / GREATEST(1, v_x1 - v_x0), 8);
    fy := TRUNC(56 / GREATEST(1, v_y1 - v_y0), 8);
    f := (TO_BINARY_DOUBLE(LEAST(fx, fy) * 100000000) / 100000000d) / (200d / v_wh);
    IF v_hi < f THEN f := v_hi; END IF;
    IF v_lo > f THEN f := v_lo; END IF;
    UPDATE g_automap_view
       -- (min + max) / 2.0 is a numeric of scale 6; CedarDB makes a REAL of it as
       -- float4(digits) / float4(10^6) (doom_game.cmd_real): -5684.000000 -> -5683.9995
       SET center_x = doom_game.cmd_real(TO_CHAR((v_x0 + v_x1) / 2, 'FM9999999990.000000')),
           center_y = doom_game.cmd_real(TO_CHAR((v_y0 + v_y1) / 2, 'FM9999999990.000000')),
           zoom = TO_BINARY_FLOAT(f), follow = FALSE
     WHERE map_id = p_map AND player_thing_id = p_player;
  END;

  -- client weapon_slot.sql: the owned weapon a number key selects
  FUNCTION weapon_slot(p_map NUMBER, p_player NUMBER, p_slot NUMBER) RETURN NUMBER IS
    v NUMBER;
  BEGIN
    SELECT MIN(wd.weapon_id) KEEP (DENSE_RANK FIRST ORDER BY
             CASE WHEN p_slot = 1 AND pw.current_weapon = 8 AND wd.weapon_id = 1 THEN 0
                  WHEN p_slot = 1 AND pw.current_weapon <> 8 AND wd.weapon_id = 8 THEN 0
                  WHEN wd.weapon_id = pw.current_weapon THEN 2 ELSE 1 END, wd.weapon_id DESC)
      INTO v
      FROM g_player_weapon_owned o
      JOIN weapon_defs wd ON wd.weapon_id = o.weapon_id
      JOIN g_player_weapons pw ON pw.map_id = o.map_id AND pw.player_thing_id = o.player_thing_id
     WHERE o.map_id = p_map AND o.player_thing_id = p_player AND wd.slot = p_slot;
    RETURN v;
  END;

  -- client weapon_cycle.sql: the next (+1) / previous (-1) owned weapon in slot order
  FUNCTION weapon_cycle(p_map NUMBER, p_player NUMBER, p_step NUMBER) RETURN NUMBER IS
    v NUMBER;
  BEGIN
    WITH owned AS (
      SELECT wd.weapon_id, ROW_NUMBER() OVER (ORDER BY wd.slot, wd.weapon_id) AS pos, COUNT(*) OVER () AS n
        FROM g_player_weapon_owned o JOIN weapon_defs wd ON wd.weapon_id = o.weapon_id
       WHERE o.map_id = p_map AND o.player_thing_id = p_player),
    here AS (
      SELECT o.pos, o.n FROM owned o
        JOIN g_player_weapons pw ON pw.map_id = p_map AND pw.player_thing_id = p_player
         AND pw.current_weapon = o.weapon_id)
    SELECT MIN(o.weapon_id) INTO v FROM owned o CROSS JOIN here h
     WHERE o.pos = MOD(h.pos - 1 + p_step + h.n, h.n) + 1;
    RETURN v;
  END;
END doom_flow;
/
