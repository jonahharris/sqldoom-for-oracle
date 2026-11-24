-- =============================================================================
-- 12_mp_server.sql -- the deathmatch server's owner-side functions (package doom_mp):
-- CedarDB 39_mp.sql's referee/match pieces that phase 3 did not need, plus the referee's
-- one-round-trip helpers. Owner only: nothing here is granted to a player or spectator.
--
--   referee_claim / _beat / _release   doom_mp_referee_*   one referee per match (heartbeat)
--   reap                               doom_mp_reap        idle slots back to the lobby
--   request_all                        doom_mp_request_all the referee's join-path warm-up
--   intermission_begin / _over         doom_mp_intermission_*
--   next_map, rotate                   doom_mp_next_map, doom_mp_rotate (slots follow players)
--   tic                                doom_server.py's tic: run_mp_tic as ONE serializable
--                                      transaction, committed; a failed tic is rolled back and
--                                      its inputs dropped (the referee's own recovery)
--   hold_turnover                      doom_server.py housekeeping: a seat held past
--                                      HOLD_SECONDS while someone waits goes back
--   py_real                            CedarDB's REAL parameter from a client double (api_input)
-- Booleans cross the call boundary as 0/1 numbers (as in doom_game).
-- Units are separated by lines holding a single '/' (client/setup_game.install_plsql).
-- =============================================================================
CREATE OR REPLACE PACKAGE doom_mp AUTHID DEFINER AS
  -- seconds from p_ts to now (EXTRACT(EPOCH FROM (now() - p_ts))); NULL for NULL
  FUNCTION secs_since(p_ts TIMESTAMP WITH TIME ZONE) RETURN NUMBER;
  -- the REAL CedarDB makes of a float a client sends (psycopg2 sends repr(x); a plain decimal
  -- literal is numeric and becomes float(digits)/float(10^scale): doom_game.cmd_real; repr's
  -- exponent form is a double literal): what api_input stores for a BINARY_DOUBLE argument
  FUNCTION py_real(x BINARY_DOUBLE) RETURN BINARY_FLOAT DETERMINISTIC;
  FUNCTION referee_claim(p_map NUMBER, p_stale_seconds NUMBER) RETURN NUMBER;
  PROCEDURE referee_beat(p_map NUMBER);
  PROCEDURE referee_release(p_map NUMBER);
  FUNCTION reap(p_map NUMBER, p_seconds NUMBER) RETURN NUMBER;
  PROCEDURE request_all(p_map NUMBER);
  PROCEDURE intermission_begin;
  FUNCTION intermission_over RETURN NUMBER;
  FUNCTION next_map RETURN NUMBER;
  FUNCTION rotate RETURN NUMBER;
  -- 1 = this tic ended the level, 0 = it did not, -1 = it failed (rolled back, inputs dropped;
  -- p_err says why)
  FUNCTION tic(p_map NUMBER, p_skill NUMBER, p1 NUMBER, p2 NUMBER, p3 NUMBER, p4 NUMBER,
               p_err OUT VARCHAR2) RETURN NUMBER;
  -- 'slot:role ...' of the seats turned over (empty: none)
  FUNCTION hold_turnover(p_map NUMBER, p_seconds NUMBER) RETURN VARCHAR2;
  -- database sessions of client programs (pg_stat_activity's non-null state)
  FUNCTION session_count RETURN NUMBER;
END doom_mp;
/
CREATE OR REPLACE PACKAGE BODY doom_mp AS
  FUNCTION secs_since(p_ts TIMESTAMP WITH TIME ZONE) RETURN NUMBER IS
    d INTERVAL DAY(9) TO SECOND(6);
  BEGIN
    IF p_ts IS NULL THEN RETURN NULL; END IF;
    d := SYSTIMESTAMP - p_ts;
    RETURN EXTRACT(DAY FROM d) * 86400 + EXTRACT(HOUR FROM d) * 3600 + EXTRACT(MINUTE FROM d) * 60
           + EXTRACT(SECOND FROM d);
  END;

  FUNCTION py_real(x BINARY_DOUBLE) RETURN BINARY_FLOAT DETERMINISTIC IS
    t VARCHAR2(80);
  BEGIN
    IF x IS NULL THEN RETURN NULL; END IF;
    IF x IS NAN THEN RETURN BINARY_FLOAT_NAN; END IF;
    IF x IS INFINITE THEN
      RETURN CASE WHEN x > 0 THEN BINARY_FLOAT_INFINITY ELSE -BINARY_FLOAT_INFINITY END;
    END IF;
    IF x = 0 THEN   -- repr '0.0' / '-0.0'
      RETURN doom_game.cmd_real(CASE WHEN SUBSTR(RAWTOHEX(UTL_RAW.CAST_FROM_BINARY_DOUBLE(x)), 1, 1) >= '8'
                                     THEN '-0.0' ELSE '0.0' END);
    END IF;
    -- Python's repr switches to exponent notation below 1e-4 and from 1e16: a double literal,
    -- which CedarDB rounds to float like any double
    IF ABS(x) < 1e-4d OR ABS(x) >= 1e16d THEN RETURN TO_BINARY_FLOAT(x); END IF;
    t := TO_CHAR(doom_game.shortest(x), 'TM9');
    IF INSTR(t, '.') = 0 THEN t := t || '.0'; END IF;   -- repr(12.0) = '12.0'
    RETURN doom_game.cmd_real(t);
  END;

  FUNCTION referee_claim(p_map NUMBER, p_stale_seconds NUMBER) RETURN NUMBER IS
    busy NUMBER;
  BEGIN
    -- two referees starting at the same moment: the table lock makes the test-and-set atomic
    LOCK TABLE g_mp_referee IN EXCLUSIVE MODE;
    SELECT COUNT(*) INTO busy FROM g_mp_referee
     WHERE map_id = p_map AND heartbeat > SYSTIMESTAMP - NUMTODSINTERVAL(p_stale_seconds, 'SECOND');
    IF busy = 0 THEN
      DELETE FROM g_mp_referee WHERE map_id = p_map;
      INSERT INTO g_mp_referee (map_id, heartbeat) VALUES (p_map, SYSTIMESTAMP);
    END IF;
    COMMIT;
    RETURN CASE WHEN busy = 0 THEN 1 ELSE 0 END;
  END;

  PROCEDURE referee_beat(p_map NUMBER) IS
  BEGIN
    UPDATE g_mp_referee SET heartbeat = SYSTIMESTAMP WHERE map_id = p_map;
  END;

  PROCEDURE referee_release(p_map NUMBER) IS
  BEGIN
    DELETE FROM g_mp_referee WHERE map_id = p_map;
    COMMIT;
  END;

  FUNCTION reap(p_map NUMBER, p_seconds NUMBER) RETURN NUMBER IS
    freed NUMBER := 0; playing NUMBER;
    cutoff TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP - NUMTODSINTERVAL(p_seconds, 'SECOND');
  BEGIN
    DELETE FROM g_mp_waiting WHERE last_seen < SYSTIMESTAMP - INTERVAL '5' SECOND;
    -- nobody can heartbeat between maps (the API is quiet then), so nobody is idle either
    SELECT COUNT(*) INTO playing FROM g_mp_match WHERE state = 'playing';
    IF playing > 0 THEN
      SELECT COUNT(*) INTO freed FROM g_mp_players mp
       WHERE mp.map_id = p_map AND mp.role_name IS NOT NULL AND (mp.last_seen IS NULL OR mp.last_seen < cutoff);
    END IF;
    IF freed > 0 THEN
      UPDATE g_player_state ps
         SET alive = FALSE, health = 0, killer_id = NULL, death_tics = 36,
             momentum_x = 0, momentum_y = 0, momentum_z = 0
       WHERE ps.map_id = p_map
         AND ps.player_thing_id IN (SELECT mp.player_thing_id FROM g_mp_players mp
                                     WHERE mp.map_id = p_map AND mp.role_name IS NOT NULL
                                       AND (mp.last_seen IS NULL OR mp.last_seen < cutoff));
      UPDATE g_mp_players SET role_name = NULL, last_seen = NULL, display_name = NULL
       WHERE map_id = p_map AND role_name IS NOT NULL AND (last_seen IS NULL OR last_seen < cutoff);
    END IF;
    RETURN freed;
  END;

  PROCEDURE request_all(p_map NUMBER) IS
  BEGIN
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_mp_join_requests g_mp_join_requests_pk) */
      INTO g_mp_join_requests (map_id, slot)
    SELECT mp.map_id, mp.slot FROM g_mp_players mp WHERE mp.map_id = p_map;
  END;

  PROCEDURE intermission_begin IS
  BEGIN
    UPDATE g_mp_match
       SET state = 'intermission',
           intermission_until = SYSTIMESTAMP + NUMTODSINTERVAL(intermission_tics / 35, 'SECOND')
     WHERE state = 'playing';
  END;

  FUNCTION intermission_over RETURN NUMBER IS
    v NUMBER := 0;
  BEGIN
    FOR m IN (SELECT state, intermission_until FROM g_mp_match) LOOP
      v := CASE WHEN m.state = 'intermission' AND m.intermission_until <= SYSTIMESTAMP THEN 1 ELSE 0 END;
    END LOOP;
    RETURN v;
  END;

  FUNCTION next_map RETURN NUMBER IS
    cur_name VARCHAR2(16) := ''; next_id NUMBER := -1;
  BEGIN
    FOR r IN (SELECT ma.name FROM g_mp_match m JOIN maps ma ON ma.map_id = m.map_id) LOOP cur_name := r.name; END LOOP;
    FOR r IN (SELECT ma.map_id FROM g_mp_rotation r JOIN maps ma ON ma.name = r.map_name
               WHERE r.position > NVL((SELECT r2.position FROM g_mp_rotation r2 WHERE r2.map_name = cur_name), -1)
               ORDER BY r.position FETCH FIRST 1 ROW ONLY) LOOP
      next_id := r.map_id;
    END LOOP;
    IF next_id < 0 THEN
      FOR r IN (SELECT ma.map_id FROM g_mp_rotation r JOIN maps ma ON ma.name = r.map_name
                 ORDER BY r.position FETCH FIRST 1 ROW ONLY) LOOP
        next_id := r.map_id;
      END LOOP;
    END IF;
    IF next_id < 0 THEN
      FOR r IN (SELECT map_id FROM g_mp_match) LOOP next_id := r.map_id; END LOOP;
    END IF;
    RETURN next_id;
  END;

  FUNCTION rotate RETURN NUMBER IS
    nxt NUMBER := next_map; v_skill NUMBER := 3; n NUMBER;
  BEGIN
    FOR m IN (SELECT skill FROM g_mp_match) LOOP v_skill := m.skill; END LOOP;
    MERGE INTO g_mp_holders h
    USING (SELECT slot, role_name, display_name, claimed_at FROM g_mp_players WHERE role_name IS NOT NULL) s
       ON (h.slot = s.slot)
     WHEN MATCHED THEN UPDATE SET h.role_name = s.role_name, h.display_name = s.display_name,
                                  h.claimed_at = s.claimed_at
     WHEN NOT MATCHED THEN INSERT (slot, role_name, display_name, claimed_at)
                           VALUES (s.slot, s.role_name, s.display_name, s.claimed_at);
    DELETE FROM g_mp_holders h
     WHERE NOT EXISTS (SELECT 1 FROM g_mp_players mp WHERE mp.slot = h.slot AND mp.role_name IS NOT NULL);
    n := doom_game.mp_start(nxt, v_skill);
    -- the seat follows the player, and so does the time they have held it
    UPDATE g_mp_players mp
       SET (role_name, display_name, claimed_at) =
           (SELECT h.role_name, h.display_name, h.claimed_at FROM g_mp_holders h WHERE h.slot = mp.slot),
           last_seen = SYSTIMESTAMP + INTERVAL '15' SECOND
     WHERE mp.map_id = nxt AND EXISTS (SELECT 1 FROM g_mp_holders h WHERE h.slot = mp.slot);
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_mp_join_requests g_mp_join_requests_pk) */
      INTO g_mp_join_requests (map_id, slot)
    SELECT nxt, h.slot FROM g_mp_holders h
     WHERE EXISTS (SELECT 1 FROM g_mp_players mp WHERE mp.map_id = nxt AND mp.slot = h.slot);
    DELETE FROM g_mp_inputs;
    UPDATE g_mp_match
       SET map_id = nxt, state = 'playing', intermission_until = NULL, maps_played = maps_played + 1;
    RETURN nxt;
  END;

  FUNCTION tic(p_map NUMBER, p_skill NUMBER, p1 NUMBER, p2 NUMBER, p3 NUMBER, p4 NUMBER,
               p_err OUT VARCHAR2) RETURN NUMBER IS
    r NUMBER;
    e_serialize EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_serialize, -8177);
  BEGIN
    p_err := NULL;
    FOR attempt IN 1 .. 3 LOOP
      BEGIN
        COMMIT;
        -- CedarDB runs the tic as one transaction with snapshot isolation: every statement of
        -- the tic reads the state as of its start (inputs a client appends meanwhile belong to
        -- the next tic; a claim or a name change lands between tics) and the players see the
        -- tic whole or not at all. SERIALIZABLE is snapshot isolation for a read-write transaction.
        SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
        r := doom_game.run_mp_tic(p_map, p_skill, p1, p2, p3, p4);
        COMMIT;
        RETURN r;
      EXCEPTION WHEN e_serialize THEN
        -- ORA-08177 also comes without a conflicting row (a block whose commit SCN can only be
        -- bounded, after a large DML such as a level start): run the tic again on a fresh
        -- snapshot. Nothing of the failed attempt is left: this is the tic run a moment later.
        p_err := SUBSTR('ORA-08177 retried ' || attempt || 'x | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 2000);
        ROLLBACK;
        IF attempt = 3 THEN
          DELETE FROM g_mp_inputs WHERE map_id = p_map;
          COMMIT;
          RETURN -1;
        END IF;
      END;
    END LOOP;
    RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    p_err := SUBSTR(SQLERRM || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 2000);
    ROLLBACK;
    -- doom_server.py drops the inputs of a failed tic, or the next tic fails on them too
    DELETE FROM g_mp_inputs WHERE map_id = p_map;
    COMMIT;
    RETURN -1;
  END;

  FUNCTION hold_turnover(p_map NUMBER, p_seconds NUMBER) RETURN VARCHAR2 IS
    v VARCHAR2(4000);
  BEGIN
    IF NVL(p_seconds, 0) <= 0 THEN RETURN NULL; END IF;
    FOR r IN (SELECT mp.slot, mp.role_name FROM g_mp_players mp
               WHERE mp.map_id = p_map AND mp.role_name IS NOT NULL
                 AND mp.claimed_at < SYSTIMESTAMP - NUMTODSINTERVAL(p_seconds, 'SECOND')
                 AND EXISTS (SELECT 1 FROM g_mp_waiting w WHERE w.last_seen >= SYSTIMESTAMP - INTERVAL '5' SECOND)
               ORDER BY mp.slot) LOOP
      v := v || CASE WHEN v IS NOT NULL THEN ' ' END || r.slot || ':' || r.role_name;
      UPDATE g_mp_players SET role_name = NULL, display_name = NULL, claimed_at = NULL
       WHERE map_id = p_map AND slot = r.slot;
    END LOOP;
    RETURN v;
  END;

  FUNCTION session_count RETURN NUMBER IS
    n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO n FROM v$session WHERE type = 'USER';
    RETURN n;
  END;
END doom_mp;
/
-- what the referee prints every five seconds (CedarDB 39_mp.sql mp_stats): the match and the
-- world in one row. Owner and spectators.
CREATE OR REPLACE VIEW mp_stats AS
SELECT m.map_id, ma.name AS map_name, m.state, m.timer_tics, m.maps_played,
       (SELECT NVL(MAX(ps.level_tics), 0) FROM g_player_state ps JOIN g_mp_players mp
           ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id
         WHERE mp.map_id = m.map_id) AS level_tics,
       (SELECT COUNT(*) FROM g_thing_health h JOIN g_things t ON t.map_id = h.map_id AND t.id = h.thing_id
          JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill
         WHERE h.map_id = m.map_id AND h.alive) AS monsters_alive,
       (SELECT COUNT(*) FROM g_thing_health h JOIN g_things t ON t.map_id = h.map_id AND t.id = h.thing_id
          JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill
         WHERE h.map_id = m.map_id) AS monsters_total,
       (SELECT COUNT(*) FROM g_monster_ai ai JOIN g_thing_health h ON h.map_id = ai.map_id AND h.thing_id = ai.thing_id
         WHERE ai.map_id = m.map_id AND h.alive AND ai.state <> 'stand') AS monsters_awake,
       (SELECT COUNT(*) FROM g_monster_projectiles p WHERE p.map_id = m.map_id) AS projectiles,
       (SELECT COUNT(*) FROM g_world_effects e WHERE e.map_id = m.map_id) AS effects,
       (SELECT COUNT(*) FROM g_picked_up_items pu JOIN g_things t ON t.map_id = pu.map_id AND t.id = pu.thing_id
          JOIN pickup_defs d ON d.thing_type = t.type WHERE pu.map_id = m.map_id) AS items_out,
       (SELECT COUNT(*) FROM g_item_respawns r WHERE r.map_id = m.map_id) AS items_queued,
       (SELECT COUNT(*) FROM g_sector_movers sm WHERE sm.map_id = m.map_id) AS movers,
       (SELECT COUNT(*) FROM g_mp_inputs i) AS input_backlog,
       (SELECT COUNT(*) FROM g_sound_events e WHERE e.map_id = m.map_id) AS sound_rows,
       doom_mp.session_count AS sessions,
       (SELECT COUNT(*) FROM g_mp_waiting w WHERE w.last_seen >= SYSTIMESTAMP - INTERVAL '5' SECOND) AS waiting
  FROM g_mp_match m JOIN maps ma ON ma.map_id = m.map_id
/
