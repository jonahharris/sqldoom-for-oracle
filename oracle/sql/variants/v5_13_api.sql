-- =============================================================================
-- 13_api.sql -- the player API of the deathmatch server (CedarDB 42_api.sql and the
-- api_camera / api_automap* functions cedarscript_runtime.py generates)
--
-- A player logs in as its own database user holding only the DOOM_PLAYER role: EXECUTE on
-- these functions and READ on the api_* views (client/api_install.py). Every function is
-- definer's rights (it runs as the game owner, so it can write what its body writes and
-- nothing a caller chooses) and resolves the caller's slot from SYS_CONTEXT('USERENV',
-- 'SESSION_USER') -- the login, which no ALTER SESSION can change -- never from a parameter.
--
-- Transactions: every function that writes starts and ends with COMMIT, so a player can
-- never hold a row lock across calls (a held lock on g_mp_players or g_player_state would
-- freeze the referee); the starting COMMIT also ends a READ ONLY transaction the client
-- opened for its last frame. Call them from PL/SQL (BEGIN :r := api_join; END;).
-- =============================================================================
CREATE OR REPLACE FUNCTION api_join RETURN NUMBER AUTHID DEFINER IS
  me VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
  pid NUMBER := -1; n NUMBER; playing BOOLEAN := FALSE; first_in_line BOOLEAN;
  claim NUMBER := -1; claim_map NUMBER; claim_slot NUMBER;
BEGIN
  COMMIT;
  -- a spectator never joins
  SELECT COUNT(*) INTO n FROM api_spectator_roles WHERE role_name = me;
  IF n > 0 THEN RETURN -1; END IF;
  FOR r IN (SELECT player_thing_id FROM g_mp_players WHERE role_name = me) LOOP pid := r.player_thing_id; END LOOP;
  IF pid < 0 THEN
    -- the queue: a caller without a slot is a waiter from its first call, and stays one while it
    -- keeps calling; waiters quiet for five seconds have left (doom_mp.reap)
    MERGE INTO g_mp_waiting w USING (SELECT me AS role_name FROM dual) s ON (w.role_name = s.role_name)
     WHEN MATCHED THEN UPDATE SET w.last_seen = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (role_name, since, last_seen) VALUES (s.role_name, SYSTIMESTAMP, SYSTIMESTAMP);
  END IF;
  -- between maps nothing is claimed: the referee is moving the slots to the next map
  FOR m IN (SELECT state FROM g_mp_match) LOOP playing := m.state = 'playing'; END LOOP;
  IF NOT playing THEN COMMIT; RETURN -1; END IF;
  SELECT CASE WHEN EXISTS (SELECT 1 FROM g_mp_waiting w, g_mp_waiting mw
                            WHERE mw.role_name = me AND w.since < mw.since) THEN 0 ELSE 1 END
    INTO n FROM dual;
  first_in_line := n = 1;
  IF pid < 0 AND first_in_line THEN
    FOR r IN (SELECT map_id, slot, player_thing_id FROM g_mp_players WHERE role_name IS NULL
               ORDER BY map_id, slot FETCH FIRST 1 ROW ONLY) LOOP
      claim_map := r.map_id; claim_slot := r.slot; claim := r.player_thing_id;
    END LOOP;
  END IF;
  IF claim >= 0 THEN
    BEGIN
      UPDATE g_mp_players SET role_name = me, claimed_at = SYSTIMESTAMP
       WHERE map_id = claim_map AND slot = claim_slot AND role_name IS NULL;
      n := SQL%ROWCOUNT;
    EXCEPTION WHEN DUP_VAL_ON_INDEX THEN n := 0;   -- the same login claimed in another session
    END;
    IF n = 0 THEN
      -- another caller took the slot first (CedarDB: a serialization failure); ask again
      COMMIT; RETURN -1;
    END IF;
    DELETE FROM g_mp_waiting WHERE role_name = me;
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_mp_join_requests g_mp_join_requests_pk) */
      INTO g_mp_join_requests (map_id, slot) VALUES (claim_map, claim_slot);
    pid := claim;
  END IF;
  IF pid >= 0 THEN
    UPDATE g_mp_players SET last_seen = SYSTIMESTAMP WHERE role_name = me;
  END IF;
  IF claim >= 0 THEN
    -- a fresh claim's grace: the client prepares its frame statement next (several seconds for
    -- a renderer session's first frame); the heartbeats never shorten it
    UPDATE g_mp_players SET last_seen = SYSTIMESTAMP + INTERVAL '15' SECOND WHERE role_name = me;
  END IF;
  COMMIT;
  RETURN pid;
END;
/
-- which slot the caller holds (1 to 4), -1 for none; frame views are api_frame_slot<n>_m<map>
CREATE OR REPLACE FUNCTION api_slot RETURN NUMBER AUTHID DEFINER IS
  s NUMBER := -1;
BEGIN
  FOR r IN (SELECT slot FROM g_mp_players WHERE role_name = SYS_CONTEXT('USERENV', 'SESSION_USER')) LOOP
    s := r.slot;
  END LOOP;
  RETURN s;
END;
/
-- one frame of input, appended for the caller's slot; values clamped to what the keyboard can
-- produce. The floats arrive as the client's doubles and are stored as the REAL CedarDB makes of
-- the same client value (doom_mp.py_real).
CREATE OR REPLACE FUNCTION api_input(p_fwd BINARY_DOUBLE, p_strafe BINARY_DOUBLE, p_run BOOLEAN,
                                     p_turn BINARY_DOUBLE, p_fire BOOLEAN, p_weapon NUMBER,
                                     p_use BOOLEAN) RETURN NUMBER AUTHID DEFINER IS
  me VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
  playing BOOLEAN := FALSE; f BINARY_FLOAT; s BINARY_FLOAT; t BINARY_FLOAT;
  FUNCTION clamp(x BINARY_FLOAT, lim BINARY_FLOAT) RETURN BINARY_FLOAT IS
  BEGIN
    -- LEAST(lim, GREATEST(-lim, COALESCE(x, 0))): NaN is the largest value, so it ends at lim
    IF x IS NULL THEN RETURN 0f; END IF;
    IF x IS NAN OR x > lim THEN RETURN lim; END IF;
    IF x < -lim THEN RETURN -lim; END IF;
    RETURN x;
  END;
BEGIN
  COMMIT;
  FOR m IN (SELECT state FROM g_mp_match) LOOP playing := m.state = 'playing'; END LOOP;
  IF playing THEN
    f := clamp(doom_mp.py_real(p_fwd), 1f);
    s := clamp(doom_mp.py_real(p_strafe), 1f);
    t := clamp(doom_mp.py_real(p_turn), 180f);
    INSERT INTO g_mp_inputs (map_id, player_thing_id, move_fwd, move_strafe, running, turn_degrees,
                             attack_held, weapon_switch_to, use_requested)
    SELECT mp.map_id, mp.player_thing_id, f, s, NVL(p_run, FALSE), t, NVL(p_fire, FALSE),
           CASE WHEN p_weapon BETWEEN 1 AND 8 AND p_weapon = TRUNC(p_weapon) THEN p_weapon END,
           NVL(p_use, FALSE)
      FROM g_mp_players mp WHERE mp.role_name = me;
    COMMIT;
  END IF;
  RETURN 1;
END;
/
-- client/camera_pose.sql over the caller's own player at alpha (clamped to [0, 1]), written into
-- the slot's pose: the per-slot frame view renders from it. Also the slot's heartbeat.
CREATE OR REPLACE FUNCTION api_camera(p_alpha BINARY_DOUBLE) RETURN NUMBER AUTHID DEFINER IS
  me VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');
  playing BOOLEAN := FALSE;
BEGIN
  COMMIT;
  FOR m IN (SELECT state FROM g_mp_match) LOOP playing := m.state = 'playing'; END LOOP;
  IF playing THEN
    FOR c IN (
      SELECT mp.map_id, mp.slot,
             ps.previous_x + (ps.position_x - ps.previous_x) * k.a AS x,
             ps.previous_y + (ps.position_y - ps.previous_y) * k.a AS y,
             ps.previous_view_z + (ps.view_z - ps.previous_view_z) * k.a AS z,
             w.a0 + t.turn * k.a - 360d * FLOOR((w.a0 + t.turn * k.a) / 360d) AS angle
        FROM g_mp_players mp
        JOIN g_player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id
       CROSS APPLY (SELECT LEAST(1d, GREATEST(0d, p_alpha)) AS a FROM dual) k
       CROSS APPLY (SELECT TO_BINARY_DOUBLE(ps.previous_view_angle) AS a0,
                           TO_BINARY_DOUBLE(ps.view_angle) - TO_BINARY_DOUBLE(ps.previous_view_angle) + 180d AS d
                      FROM dual) w
       CROSS APPLY (SELECT (w.d - 360d * FLOOR(w.d / 360d)) - 180d AS turn FROM dual) t
       WHERE mp.role_name = me) LOOP
      UPDATE g_mp_players mp
         SET pose_x = TO_BINARY_FLOAT(c.x), pose_y = TO_BINARY_FLOAT(c.y), pose_z = TO_BINARY_FLOAT(c.z),
             pose_angle = TO_BINARY_FLOAT(c.angle),
             last_seen = GREATEST(NVL(mp.last_seen, SYSTIMESTAMP), SYSTIMESTAMP)
       WHERE mp.map_id = c.map_id AND mp.slot = c.slot AND mp.role_name = me;
    END LOOP;
    COMMIT;
  END IF;
  RETURN 1;
END;
/
-- number-key weapon selection and wheel cycling over the caller's own weapons (client
-- weapon_slot.sql / weapon_cycle.sql = doom_flow.weapon_slot / _cycle); -1: nothing owned there
CREATE OR REPLACE FUNCTION api_weapon_slot(p_slot NUMBER) RETURN NUMBER AUTHID DEFINER IS
  w NUMBER := -1;
BEGIN
  FOR r IN (SELECT map_id, player_thing_id FROM g_mp_players
             WHERE role_name = SYS_CONTEXT('USERENV', 'SESSION_USER')) LOOP
    w := NVL(doom_flow.weapon_slot(r.map_id, r.player_thing_id, p_slot), -1);
  END LOOP;
  RETURN w;
END;
/
CREATE OR REPLACE FUNCTION api_weapon_cycle(p_step NUMBER) RETURN NUMBER AUTHID DEFINER IS
  w NUMBER := -1;
BEGIN
  FOR r IN (SELECT map_id, player_thing_id FROM g_mp_players
             WHERE role_name = SYS_CONTEXT('USERENV', 'SESSION_USER')) LOOP
    w := NVL(doom_flow.weapon_cycle(r.map_id, r.player_thing_id, p_step), -1);
  END LOOP;
  RETURN w;
END;
/
-- the name the scoreboard and the frag messages use: letters, digits, space, - and _, at most 12,
-- upper case; empty clears it back to the login
CREATE OR REPLACE FUNCTION api_set_name(p_name VARCHAR2) RETURN NUMBER AUTHID DEFINER IS
BEGIN
  COMMIT;
  UPDATE g_mp_players
     SET display_name = TRIM(UPPER(SUBSTR(REGEXP_REPLACE(SUBSTR(p_name, 1, 4000), '[^A-Za-z0-9 _-]', ''), 1, 12)))
   WHERE role_name = SYS_CONTEXT('USERENV', 'SESSION_USER');
  COMMIT;
  RETURN 1;
END;
/
-- the automap of the caller's own player: only what it has walked, unless it holds the computer
-- map (power_map); IDDT is not reachable (doom_screen.render_automap over g_automap_view, whose
-- cheat counter only doom_flow.cheat_key can raise). Rows (y, pal, hex) like every frame.
CREATE OR REPLACE FUNCTION api_automap RETURN doom_hex_tab PIPELINED AUTHID DEFINER IS
BEGIN
  FOR me IN (SELECT map_id, player_thing_id FROM g_mp_players
              WHERE role_name = SYS_CONTEXT('USERENV', 'SESSION_USER')) LOOP
    FOR r IN (SELECT y, pal, hex FROM TABLE(doom_screen.render_automap(me.map_id, me.player_thing_id))) LOOP
      PIPE ROW (doom_hex_row(r.y, r.pal, r.hex));
    END LOOP;
  END LOOP;
  RETURN;
END;
/
CREATE OR REPLACE FUNCTION api_automap_pan(p_dx BINARY_DOUBLE, p_dy BINARY_DOUBLE) RETURN NUMBER AUTHID DEFINER IS
BEGIN
  COMMIT;
  FOR me IN (SELECT map_id, player_thing_id FROM g_mp_players
              WHERE role_name = SYS_CONTEXT('USERENV', 'SESSION_USER')) LOOP
    doom_flow.automap_pan(me.map_id, me.player_thing_id, p_dx, p_dy);
  END LOOP;
  COMMIT;
  RETURN 1;
END;
/
CREATE OR REPLACE FUNCTION api_automap_zoom(p_factor BINARY_DOUBLE) RETURN NUMBER AUTHID DEFINER IS
BEGIN
  COMMIT;
  FOR me IN (SELECT map_id, player_thing_id FROM g_mp_players
              WHERE role_name = SYS_CONTEXT('USERENV', 'SESSION_USER')) LOOP
    doom_flow.automap_zoom(me.map_id, me.player_thing_id, p_factor);
  END LOOP;
  COMMIT;
  RETURN 1;
END;
/
-- 'follow' or 'grid'; anything else ('cheat' included) touches the view and changes nothing
CREATE OR REPLACE FUNCTION api_automap_toggle(p_what VARCHAR2) RETURN NUMBER AUTHID DEFINER IS
BEGIN
  COMMIT;
  FOR me IN (SELECT map_id, player_thing_id FROM g_mp_players
              WHERE role_name = SYS_CONTEXT('USERENV', 'SESSION_USER')) LOOP
    doom_flow.automap_toggle(me.map_id, me.player_thing_id,
                             CASE WHEN p_what IN ('follow', 'grid') THEN p_what ELSE 'none' END);
  END LOOP;
  COMMIT;
  RETURN 1;
END;
/
CREATE OR REPLACE FUNCTION api_automap_fit RETURN NUMBER AUTHID DEFINER IS
BEGIN
  COMMIT;
  FOR me IN (SELECT map_id, player_thing_id FROM g_mp_players
              WHERE role_name = SYS_CONTEXT('USERENV', 'SESSION_USER')) LOOP
    doom_flow.automap_fit(me.map_id, me.player_thing_id);
  END LOOP;
  COMMIT;
  RETURN 1;
END;
/
