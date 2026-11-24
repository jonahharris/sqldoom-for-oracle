-- =============================================================================
-- 08_game.sql -- the SQLDoom single-player game tic on Oracle (package doom_game)
--
-- A port of reference/sqldoom/sql/runtime/functions (CedarScript) to PL/SQL + SQL
-- over the g_* tables of 07_game_schema.sql. Entry points:
--   doom_game.enter_level(map, player, skill)        doom_enter_level (G_DoLoadLevel)
--   doom_game.cheat(map, player, code) -> message      doom_cheat
--   doom_game.run_tic(map, player, skill, fwd, strafe, running, turn, attack,
--                     weapon_switch_to, use) -> 0/1   doom_run_game_tic (sound_due)
-- Booleans cross the call boundary as 0/1 numbers.
--
-- Design (see analysis/game-port.md):
--   * package state holds STATIC data only: constants, line geometry, the BSP, a line
--     grid, catalogs. Every piece of game state is read from / written to g_* tables
--     each tic.
--   * set-based SQL where the reference statement is a cheap set operation; PL/SQL
--     loops where per-row geometry dominates (movement, use/cross traces, hitscan,
--     monster sight/steps, missile sweeps, BSP descents).
--   * float semantics follow CedarDB: REAL columns are BINARY_FLOAT and real-only
--     arithmetic stays single precision; ::float8 math is BINARY_DOUBLE with the
--     reference's operation order; RADIANS(x) = x*(pi/180), DEGREES(x) = x*(180/pi);
--     ROUND(double) is half away from zero (rnd); double->int casts are half-even;
--     LEAST/GREATEST ignore NULLs (handled explicitly); integer '/' truncates.
-- Units are separated by lines holding a single '/' (client/setup_game.py).
-- =============================================================================
CREATE OR REPLACE PACKAGE doom_game AS
  PROCEDURE enter_level(p_map NUMBER, p_player NUMBER, p_skill NUMBER);
  PROCEDURE spawn_player(p_map NUMBER, p_player NUMBER);
  FUNCTION cheat(p_map NUMBER, p_player NUMBER, p_code VARCHAR2) RETURN VARCHAR2;
  FUNCTION run_tic(p_map NUMBER, p_player NUMBER, p_skill NUMBER,
                   p_fwd BINARY_FLOAT, p_strafe BINARY_FLOAT, p_running NUMBER,
                   p_turn BINARY_FLOAT, p_attack NUMBER, p_switch NUMBER, p_use NUMBER)
    RETURN NUMBER;
  -- helpers also used from SQL
  -- CedarDB's conversion of the client's float parameter text to REAL (see game-port.md):
  -- a plain decimal literal is numeric, converted as float(digits) / float(10^scale);
  -- one in exponent notation is a double, rounded to float.
  FUNCTION cmd_real(p_text VARCHAR2) RETURN BINARY_FLOAT DETERMINISTIC;
  FUNCTION prandom(p_actor NUMBER, p_tic NUMBER, p_use NUMBER) RETURN NUMBER DETERMINISTIC;
  FUNCTION rnd(x BINARY_DOUBLE) RETURN BINARY_DOUBLE DETERMINISTIC;
  -- the shortest decimal that rounds back to x (Python's repr): what a client sends when it
  -- binds a fetched BINARY_DOUBLE as a parameter, so an in-SQL pose hand-off (camera ->
  -- render_frame) passes the renderer exactly the NUMBER a client round trip would
  FUNCTION shortest(x BINARY_DOUBLE) RETURN NUMBER DETERMINISTIC;
  FUNCTION sector_at(p_map NUMBER, p_x BINARY_DOUBLE, p_y BINARY_DOUBLE) RETURN NUMBER;
  -- profiling: per-stage elapsed microseconds of the last tic (debug level 1)
  PROCEDURE set_debug(p_level NUMBER);
  FUNCTION timings RETURN VARCHAR2;
  PROCEDURE reset_cache;
  -- deathmatch (39_mp.sql, 40_run_game_tic.sql): match row, slots, the shared tic
  PROCEDURE mp_configure(p_map NUMBER, p_skill NUMBER, p_timer_tics NUMBER, p_altdeath NUMBER, p_monsters NUMBER,
                         p_respawn_monsters NUMBER, p_intermission_tics NUMBER);
  PROCEDURE mp_open;
  FUNCTION mp_start(p_map NUMBER, p_skill NUMBER) RETURN NUMBER;
  FUNCTION mp_claim(p_map NUMBER, p_slot NUMBER, p_role VARCHAR2) RETURN NUMBER;
  PROCEDURE mp_vacate_all(p_map NUMBER);
  FUNCTION mp_level_done(p_map NUMBER) RETURN NUMBER;
  FUNCTION run_mp_tic(p_map NUMBER, p_skill NUMBER, p1 NUMBER, p2 NUMBER, p3 NUMBER, p4 NUMBER) RETURN NUMBER;
END doom_game;
/
-- @@BODY@@
CREATE OR REPLACE PACKAGE BODY doom_game AS
  -- ---------------------------------------------------------------- types
  TYPE t_num  IS TABLE OF NUMBER        INDEX BY PLS_INTEGER;
  TYPE t_int  IS TABLE OF PLS_INTEGER   INDEX BY PLS_INTEGER;
  TYPE t_dbl  IS TABLE OF BINARY_DOUBLE INDEX BY PLS_INTEGER;
  TYPE t_flt  IS TABLE OF BINARY_FLOAT  INDEX BY PLS_INTEGER;
  TYPE t_bool IS TABLE OF BOOLEAN       INDEX BY PLS_INTEGER;
  TYPE t_str  IS TABLE OF VARCHAR2(64)  INDEX BY PLS_INTEGER;
  TYPE t_kdbl IS TABLE OF BINARY_DOUBLE INDEX BY VARCHAR2(64);
  TYPE t_kint IS TABLE OF PLS_INTEGER   INDEX BY VARCHAR2(64);

  c_pi     CONSTANT BINARY_DOUBLE := 3.14159265358979323846d;
  c_rad    CONSTANT BINARY_DOUBLE := 3.14159265358979323846d / 180d;   -- RADIANS(x) = x * c_rad
  c_deg    CONSTANT BINARY_DOUBLE := 180d / 3.14159265358979323846d;   -- DEGREES(x) = x * c_deg
  c_eps    CONSTANT BINARY_DOUBLE := 1e-9d;

  -- ------------------------------------------------- static data (per map)
  g_map    NUMBER := -1;
  g_rtab   t_int;                       -- prandom byte table
  k        t_kdbl;                      -- doom_constants
  -- hot constants
  k_player_radius BINARY_DOUBLE; k_player_height BINARY_DOUBLE; k_maxstep BINARY_DOUBLE;
  k_viewheight BINARY_DOUBLE; k_friction BINARY_DOUBLE; k_stopspeed BINARY_DOUBLE;
  k_maxmove BINARY_DOUBLE; k_fwd BINARY_DOUBLE; k_fwd_run BINARY_DOUBLE; k_side BINARY_DOUBLE;
  k_side_run BINARY_DOUBLE; k_thrust BINARY_DOUBLE; k_maxbob BINARY_DOUBLE; k_gravity BINARY_DOUBLE;
  k_bob_factor BINARY_DOUBLE; k_bob_period BINARY_DOUBLE; k_block_margin BINARY_DOUBLE;
  k_pos_eps BINARY_DOUBLE; k_ps_eps BINARY_DOUBLE; k_ps_rx BINARY_DOUBLE; k_ps_ry BINARY_DOUBLE;
  k_userange BINARY_DOUBLE; k_sight_range BINARY_DOUBLE; k_attack_range_def BINARY_DOUBLE;
  k_blockmap_cell BINARY_DOUBLE; k_min_walk BINARY_DOUBLE; k_monster_step BINARY_DOUBLE;
  k_chase_deadband BINARY_DOUBLE; k_chase_swap BINARY_DOUBLE; k_chase_mask BINARY_DOUBLE;

  -- lines, indexed by linedef id (0 .. l_n-1)
  l_n      PLS_INTEGER := 0;
  l_x1 t_dbl; l_y1 t_dbl; l_x2 t_dbl; l_y2 t_dbl;
  l_flags t_int; l_special t_int; l_tag t_int; l_rsd t_int; l_lsd t_int;
  l_fsec t_int; l_bsec t_int;            -- -1 when the side is missing
  l_cross t_bool; l_cross_once t_bool; l_mcross t_bool;
  l_cross_list t_int; l_cross_n PLS_INTEGER := 0;   -- cross_activated lines
  l_open t_bool;                                     -- static: two-sided with both sectors (heights decide)
  l_use_list t_int; l_use_n PLS_INTEGER := 0;        -- monster-usable, non-secret lines (P_UseSpecialLine)
  -- BSP
  n_root PLS_INTEGER;
  n_x t_dbl; n_y t_dbl; n_dx t_dbl; n_dy t_dbl;
  n_rnode t_bool; n_rchild t_int; n_lnode t_bool; n_lchild t_int;
  ss_sec t_int;                          -- ssector -> fsec of its lowest render seg
  -- line grid (static): cell (cx, cy) -> lines whose bounding box overlaps the cell
  gr_x0 PLS_INTEGER; gr_y0 PLS_INTEGER; gr_nx PLS_INTEGER; gr_ny PLS_INTEGER;
  gr_start t_int; gr_cnt t_int; gr_line t_int;
  gr_stamp t_int; gr_epoch PLS_INTEGER := 0;
  -- catalogs
  ad_cap t_kint; ad_bcap t_kint;                     -- ammo_defs by ammo_type
  TYPE t_kbool IS TABLE OF BOOLEAN INDEX BY VARCHAR2(64);
  fa_tics t_kint; fa_atk t_kbool; fa_max t_kint;     -- thing_ai_frames: 'type:state:seq', 'type:state'
  cd_dx t_dbl; cd_dy t_dbl; cd_ang t_flt; cd_opp t_int; -- chase_dir_defs by dir
  -- thing_combat_defs by thing_type
  tc_xd t_str; tc_expl t_bool; tc_range t_dbl; tc_fast t_bool; tc_radius t_dbl;
  bd_radius t_dbl;                                   -- thing_blocking_defs by thing_type
  tc_attack_sound t_str; tc_missile t_str; tc_melee t_num;
  TYPE t_kstr IS TABLE OF VARCHAR2(8) INDEX BY VARCHAR2(64);
  sd_name t_kstr; sd_n t_kint;                       -- thing_sound_defs: 'type:cue:variant' -> name, 'type:cue' -> count
  g_max_radius BINARY_DOUBLE;                        -- largest actor/decoration radius (query bounds)
  g_has_boss666 BOOLEAN := FALSE;                    -- boss_actions has a lower_666 row for this map

  -- ------------------------------------------------- per-tic scratch (reloaded every use)
  s_fl t_int; s_ce t_int;                            -- sector floor / ceiling heights
  s_valid BOOLEAN := FALSE;                          -- s_fl/s_ce hold this tic's heights (reset every tic)
  g_snd_lt NUMBER := -1;                             -- level tic whose world sound cues are already in (reset every tic)

  -- ------------------------------------------------- debug timing
  g_debug PLS_INTEGER := 0;
  g_t0 PLS_INTEGER;
  g_tim VARCHAR2(4000);
  g_ts TIMESTAMP(6);

  PROCEDURE set_debug(p_level NUMBER) IS BEGIN g_debug := p_level; END;
  FUNCTION timings RETURN VARCHAR2 IS BEGIN RETURN g_tim; END;
  PROCEDURE tmark(p_name VARCHAR2) IS
    t TIMESTAMP(6);
  BEGIN
    IF g_debug = 0 THEN RETURN; END IF;
    t := SYSTIMESTAMP;
    IF p_name IS NULL THEN g_tim := NULL;
    ELSE g_tim := g_tim || p_name || '=' || ROUND((EXTRACT(SECOND FROM (t - g_ts)) + 60 * EXTRACT(MINUTE FROM (t - g_ts))) * 1e6) || ' ';
    END IF;
    g_ts := t;
  END;

  -- ------------------------------------------------- helpers
  FUNCTION shortest(x BINARY_DOUBLE) RETURN NUMBER DETERMINISTIC IS
    PRAGMA UDF;
    bits NUMBER; ex PLS_INTEGER; man NUMBER; n NUMBER; a NUMBER; e PLS_INTEGER; r NUMBER;
  BEGIN
    IF x IS NULL THEN RETURN NULL; END IF;
    IF x = 0 THEN RETURN 0; END IF;
    -- the value of x to ~38 digits from its bits (TO_NUMBER(x) keeps only ~17 digits, which
    -- can turn a nearest-16-digit choice the wrong way)
    bits := TO_NUMBER(RAWTOHEX(UTL_RAW.CAST_FROM_BINARY_DOUBLE(x)), 'XXXXXXXXXXXXXXXX');
    ex := MOD(TRUNC(bits / 4503599627370496), 2048);
    man := MOD(bits, 4503599627370496);
    IF ex = 0 THEN n := man * POWER(2, -1074); ELSE n := (man + 4503599627370496) * POWER(2, ex - 1075); END IF;
    IF bits >= 9223372036854775808 THEN n := -n; END IF;
    a := ABS(n);
    e := FLOOR(LOG(10, a));
    IF a >= POWER(10, e + 1) THEN e := e + 1; ELSIF a < POWER(10, e) THEN e := e - 1; END IF;
    FOR d IN 1 .. 17 LOOP
      r := ROUND(n, d - 1 - e);
      -- an exact tie (common: float4 values widened to double end in ...5) goes to the even
      -- digit, as Python's repr does; ROUND alone rounds it away from zero
      IF ABS(n - r) = 0.5 * POWER(10, e - d + 1) AND MOD(ABS(r) * POWER(10, d - 1 - e), 2) = 1 THEN
        r := r - SIGN(n) * POWER(10, e - d + 1);
      END IF;
      IF TO_BINARY_DOUBLE(r) = x THEN RETURN r; END IF;
    END LOOP;
    RETURN n;
  END;

  -- CedarDB ROUND(double precision): half away from zero (exact).
  FUNCTION rnd(x BINARY_DOUBLE) RETURN BINARY_DOUBLE DETERMINISTIC IS
    PRAGMA UDF;
    a BINARY_DOUBLE := ABS(x); f BINARY_DOUBLE;
  BEGIN
    IF x IS NULL THEN RETURN NULL; END IF;
    f := FLOOR(a);
    IF a - f >= 0.5d THEN f := f + 1d; END IF;
    IF x < 0 THEN RETURN -f; END IF;
    RETURN f;
  END;

  -- doom_prandom (00_prandom.sql): Doom's rndtable indexed by a hash of (actor, tic, use).
  FUNCTION prandom(p_actor NUMBER, p_tic NUMBER, p_use NUMBER) RETURN NUMBER DETERMINISTIC IS
    PRAGMA UDF;
    h NUMBER; q NUMBER; x NUMBER;
    c_hex CONSTANT VARCHAR2(512) := '00086ddcdef1956b4bf8fe8c10424a15d32f50f29a1bcd80a1594d245f6e5530d48cd3f9164fc8321cbc348cca7844913e46b8be5bc598e0956819b2fcb6cab68dc50451b5f2912a27e39cc6e1c1db5d7aaff900af8f46ef2ef6a335a36da88702eb195c14918a4d45a64eb0add4a6715ea12932ef316fa4463c0225ab4b889c0b382a928ae549924d3d62c4876a3fc5c35660cb7165aaf7b57150fa6c07ffed81e24f6b70a667f118dfef78c63a3c528003b8428fe091e051cea32d3f5aa8723b219f5f1c8b7b627dc40f46c2fd360e6de24711a15dba57f48a14347bfb1a24112e34e7e84c1fdd5425d8a5d46ac5f2622b27affe91be5476debb8878a3ecf9';
  BEGIN
    IF g_rtab.COUNT = 0 THEN
      FOR i IN 0 .. 255 LOOP
        g_rtab(i) := TO_NUMBER(SUBSTR(c_hex, i * 2 + 1, 2), 'XX');
      END LOOP;
    END IF;
    h := MOD(ABS(p_actor) * 2654435761 + ABS(p_tic) * 2246822519 + ABS(p_use) * 3266489917, 4294967296);
    q := TRUNC(h / 32768);
    x := h + q - 2 * BITAND(h, q);                      -- h # q
    RETURN g_rtab(MOD(TRUNC(MOD(x * 40503, 4294967296) / 256), 256));
  END;

  FUNCTION cmd_real(p_text VARCHAR2) RETURN BINARY_FLOAT DETERMINISTIC IS
    t VARCHAR2(80) := TRIM(p_text); neg BOOLEAN := FALSE; ip VARCHAR2(80); fp VARCHAR2(80); p PLS_INTEGER;
    r BINARY_FLOAT;
  BEGIN
    IF INSTR(UPPER(t), 'E') > 0 OR INSTR(UPPER(t), 'N') > 0 THEN
      RETURN TO_BINARY_FLOAT(TO_BINARY_DOUBLE(t));
    END IF;
    IF SUBSTR(t, 1, 1) = '-' THEN neg := TRUE; t := SUBSTR(t, 2);
    ELSIF SUBSTR(t, 1, 1) = '+' THEN t := SUBSTR(t, 2); END IF;
    p := INSTR(t, '.');
    IF p = 0 THEN ip := t; fp := NULL; ELSE ip := SUBSTR(t, 1, p - 1); fp := SUBSTR(t, p + 1); END IF;
    r := TO_BINARY_FLOAT(TO_NUMBER(NVL(ip, '0') || fp)) / TO_BINARY_FLOAT(POWER(10, NVL(LENGTH(fp), 0)));
    IF neg THEN r := -r; END IF;
    RETURN r;
  END;

  PROCEDURE reset_cache IS BEGIN g_map := -1; END;

  PROCEDURE load_map(p_map NUMBER) IS
    a t_num; b t_num; c t_num; d t_num; e t_num; f t_num; g t_num; h t_num; i2 t_num; j t_num; kk t_num;
    m t_num; bo1 t_bool; bo2 t_bool; bo3 t_bool; bo4 t_bool;
    nm t_str; vv t_dbl;
    xmin NUMBER; xmax NUMBER; ymin NUMBER; ymax NUMBER;
    cx PLS_INTEGER; cy PLS_INTEGER; key PLS_INTEGER; pos PLS_INTEGER;
    tmp t_int;
  BEGIN
    IF g_map = p_map THEN RETURN; END IF;
    -- constants
    SELECT name, value BULK COLLECT INTO nm, vv FROM doom_constants;
    k.DELETE;
    FOR i IN 1 .. nm.COUNT LOOP k(nm(i)) := vv(i); END LOOP;
    k_player_radius := k('PLAYER_RADIUS'); k_player_height := k('PLAYER_HEIGHT'); k_maxstep := k('MAXSTEP');
    k_viewheight := k('VIEWHEIGHT'); k_friction := k('FRICTION'); k_stopspeed := k('STOPSPEED');
    k_maxmove := k('MAXMOVE'); k_fwd := k('FORWARDMOVE'); k_fwd_run := k('FORWARDMOVE_RUN');
    k_side := k('SIDEMOVE'); k_side_run := k('SIDEMOVE_RUN'); k_thrust := k('THRUST_UNIT');
    k_maxbob := k('MAXBOB'); k_gravity := k('GRAVITY'); k_bob_factor := k('BOB_FACTOR');
    k_bob_period := k('BOB_PERIOD_TICS'); k_block_margin := k('BLOCK_MARGIN'); k_pos_eps := k('POS_EPSILON');
    k_ps_eps := k('PSPRITE_EPSILON'); k_ps_rx := k('PSPRITE_REST_X'); k_ps_ry := k('PSPRITE_REST_Y');
    k_userange := k('USERANGE'); k_sight_range := k('SIGHT_RANGE'); k_attack_range_def := k('DEFAULT_ATTACK_RANGE');
    k_blockmap_cell := k('BLOCKMAP_CELL'); k_min_walk := k('MIN_WALK_OPENING'); k_monster_step := k('MONSTER_STEP');
    k_chase_deadband := k('CHASE_AXIS_DEADBAND'); k_chase_swap := k('CHASE_SWAP_CHANCE'); k_chase_mask := k('CHASE_MOVECOUNT_MASK');
    -- lines
    SELECT lg.linedef_id, lg.x1, lg.y1, lg.x2, lg.y2, lg.flags, lg.special, ld.tag, lg.right_sd_id, lg.left_sd_id,
           NVL(lg.fsec, -1), NVL(lg.bsec, -1), ld.cross_activated, ld.cross_once, ld.monster_crossable
      BULK COLLECT INTO a, b, c, d, e, f, g, m, h, i2, j, kk, bo1, bo2, bo3
      FROM linedef_geom lg JOIN linedefs ld ON ld.map_id = lg.map_id AND ld.id = lg.linedef_id
     WHERE lg.map_id = p_map ORDER BY lg.linedef_id;
    l_n := a.COUNT; l_cross_n := 0;
    l_x1.DELETE; l_y1.DELETE; l_x2.DELETE; l_y2.DELETE; l_cross_list.DELETE;
    FOR i IN 1 .. a.COUNT LOOP
      IF a(i) <> i - 1 THEN RAISE_APPLICATION_ERROR(-20010, 'linedef ids are not dense'); END IF;
      l_x1(a(i)) := b(i); l_y1(a(i)) := c(i); l_x2(a(i)) := d(i); l_y2(a(i)) := e(i);
      l_flags(a(i)) := f(i); l_special(a(i)) := g(i); l_tag(a(i)) := m(i);
      l_rsd(a(i)) := h(i); l_lsd(a(i)) := i2(i); l_fsec(a(i)) := j(i); l_bsec(a(i)) := kk(i);
      l_cross(a(i)) := bo1(i); l_cross_once(a(i)) := bo2(i); l_mcross(a(i)) := bo3(i);
      IF bo1(i) THEN l_cross_list(l_cross_n) := a(i); l_cross_n := l_cross_n + 1; END IF;
      l_open(a(i)) := NOT (h(i) = -1 OR i2(i) = -1 OR j(i) = -1 OR kk(i) = -1);
    END LOOP;
    l_use_n := 0; l_use_list.DELETE;
    FOR r IN (SELECT lg.linedef_id FROM linedef_geom lg JOIN line_special_defs d ON d.special = lg.special AND d.monster_usable
               WHERE lg.map_id = p_map AND BITAND(lg.flags, 32) = 0 ORDER BY lg.linedef_id) LOOP
      l_use_list(l_use_n) := r.linedef_id; l_use_n := l_use_n + 1;
    END LOOP;
    -- BSP: nodes, children, root = highest node id
    SELECT id, x, y, dx, dy BULK COLLECT INTO a, b, c, d, e FROM nodes WHERE map_id = p_map;
    n_root := -1;
    FOR i IN 1 .. a.COUNT LOOP
      n_x(a(i)) := b(i); n_y(a(i)) := c(i); n_dx(a(i)) := d(i); n_dy(a(i)) := e(i);
      IF a(i) > n_root THEN n_root := a(i); END IF;
    END LOOP;
    SELECT node_id, CASE WHEN side = 'R' THEN 1 ELSE 0 END, CASE WHEN child_kind = 'NODE' THEN 1 ELSE 0 END,
           CASE WHEN child_kind = 'NODE' THEN child_node_id ELSE child_ssector_id END
      BULK COLLECT INTO a, b, c, d FROM node_children WHERE map_id = p_map;
    FOR i IN 1 .. a.COUNT LOOP
      IF b(i) = 1 THEN n_rnode(a(i)) := c(i) = 1; n_rchild(a(i)) := d(i);
      ELSE n_lnode(a(i)) := c(i) = 1; n_lchild(a(i)) := d(i); END IF;
    END LOOP;
    -- ssector -> sector of its lowest-numbered render seg (doom_sector_at)
    ss_sec.DELETE;
    SELECT ssector_id, MIN(fsec) KEEP (DENSE_RANK FIRST ORDER BY seg_id)
      BULK COLLECT INTO a, b FROM render_segs WHERE map_id = p_map AND ssector_id IS NOT NULL GROUP BY ssector_id;
    FOR i IN 1 .. a.COUNT LOOP ss_sec(a(i)) := b(i); END LOOP;
    -- line grid, 128-unit cells
    SELECT FLOOR(MIN(LEAST(x1, x2)) / 128), FLOOR(MAX(GREATEST(x1, x2)) / 128),
           FLOOR(MIN(LEAST(y1, y2)) / 128), FLOOR(MAX(GREATEST(y1, y2)) / 128)
      INTO xmin, xmax, ymin, ymax FROM linedef_geom WHERE map_id = p_map;
    gr_x0 := xmin; gr_y0 := ymin; gr_nx := xmax - xmin + 1; gr_ny := ymax - ymin + 1;
    gr_start.DELETE; gr_cnt.DELETE; gr_line.DELETE; gr_stamp.DELETE; tmp.DELETE;
    FOR i IN 0 .. gr_nx * gr_ny - 1 LOOP gr_cnt(i) := 0; END LOOP;
    FOR pass IN 1 .. 2 LOOP
      IF pass = 2 THEN
        pos := 0;
        FOR i IN 0 .. gr_nx * gr_ny - 1 LOOP gr_start(i) := pos; pos := pos + gr_cnt(i); tmp(i) := gr_start(i); END LOOP;
      END IF;
      FOR li IN 0 .. l_n - 1 LOOP
        FOR cxx IN FLOOR(LEAST(l_x1(li), l_x2(li)) / 128) .. FLOOR(GREATEST(l_x1(li), l_x2(li)) / 128) LOOP
          FOR cyy IN FLOOR(LEAST(l_y1(li), l_y2(li)) / 128) .. FLOOR(GREATEST(l_y1(li), l_y2(li)) / 128) LOOP
            key := (cxx - gr_x0) * gr_ny + (cyy - gr_y0);
            IF pass = 1 THEN gr_cnt(key) := gr_cnt(key) + 1;
            ELSE gr_line(tmp(key)) := li; tmp(key) := tmp(key) + 1; END IF;
          END LOOP;
        END LOOP;
      END LOOP;
    END LOOP;
    FOR li IN 0 .. l_n - 1 LOOP gr_stamp(li) := 0; END LOOP;
    -- ammo caps
    SELECT ammo_type, cap, backpack_cap BULK COLLECT INTO nm, a, b FROM ammo_defs;
    FOR i IN 1 .. nm.COUNT LOOP ad_cap(nm(i)) := a(i); ad_bcap(nm(i)) := b(i); END LOOP;
    -- thing_ai_frames
    fa_tics.DELETE; fa_atk.DELETE; fa_max.DELETE;
    FOR r IN (SELECT thing_type, state, seq_index, tics, is_attack_frame FROM thing_ai_frames) LOOP
      fa_tics(r.thing_type || ':' || r.state || ':' || r.seq_index) := r.tics;
      fa_atk(r.thing_type || ':' || r.state || ':' || r.seq_index) := r.is_attack_frame;
      IF NOT fa_max.EXISTS(r.thing_type || ':' || r.state) OR fa_max(r.thing_type || ':' || r.state) < r.seq_index THEN
        fa_max(r.thing_type || ':' || r.state) := r.seq_index;
      END IF;
    END LOOP;
    sd_name.DELETE; sd_n.DELETE;
    FOR r IN (SELECT thing_type, cue, variant, sound_name FROM thing_sound_defs) LOOP
      sd_name(r.thing_type || ':' || r.cue || ':' || r.variant) := r.sound_name;
      IF sd_n.EXISTS(r.thing_type || ':' || r.cue) THEN sd_n(r.thing_type || ':' || r.cue) := sd_n(r.thing_type || ':' || r.cue) + 1;
      ELSE sd_n(r.thing_type || ':' || r.cue) := 1; END IF;
    END LOOP;
    FOR r IN (SELECT thing_type, attack_sound, missile_type, melee_mult FROM thing_combat_defs) LOOP
      tc_attack_sound(r.thing_type) := r.attack_sound; tc_missile(r.thing_type) := r.missile_type;
      tc_melee(r.thing_type) := r.melee_mult;
    END LOOP;
    FOR r IN (SELECT thing_type, xdeath_frame, explodes, attack_range, fast_on_nightmare, radius FROM thing_combat_defs) LOOP
      tc_xd(r.thing_type) := r.xdeath_frame; tc_expl(r.thing_type) := r.explodes;
      tc_range(r.thing_type) := NVL(r.attack_range, k_attack_range_def); tc_fast(r.thing_type) := r.fast_on_nightmare;
      tc_radius(r.thing_type) := r.radius;
    END LOOP;
    SELECT COUNT(*) INTO xmin FROM boss_actions ba JOIN maps m ON m.name = ba.map_name
     WHERE m.map_id = p_map AND ba.action = 'lower_666';
    g_has_boss666 := xmin > 0;
    g_max_radius := 0;
    FOR r IN (SELECT thing_type, radius FROM thing_blocking_defs) LOOP
      bd_radius(r.thing_type) := r.radius; g_max_radius := GREATEST(g_max_radius, r.radius);
    END LOOP;
    FOR r IN (SELECT MAX(radius) AS m FROM thing_combat_defs) LOOP g_max_radius := GREATEST(g_max_radius, r.m); END LOOP;
    FOR r IN (SELECT dir, dx, dy, angle, opposite FROM chase_dir_defs) LOOP
      cd_dx(r.dir) := r.dx; cd_dy(r.dir) := r.dy; cd_ang(r.dir) := r.angle; cd_opp(r.dir) := r.opposite;
    END LOOP;
    g_map := p_map;
  END;

  -- grid query along a segment: every line whose bounding box may contain a point within 1 unit
  -- of (ax,ay)-(bx,by). A line the strict side tests report as crossing the segment shares a
  -- point with it, so it is always among these (superset of the exact tests' positives).
  PROCEDURE grid_seg(ax BINARY_DOUBLE, ay BINARY_DOUBLE, bx BINARY_DOUBLE, by_ BINARY_DOUBLE,
                     p_out IN OUT NOCOPY t_int, p_n OUT PLS_INTEGER) IS
    m CONSTANT BINARY_DOUBLE := 1d;
    x0 BINARY_DOUBLE := LEAST(ax, bx); x1 BINARY_DOUBLE := GREATEST(ax, bx);
    c0 PLS_INTEGER; c1 PLS_INTEGER; cxa BINARY_DOUBLE; cxb BINARY_DOUBLE; ya BINARY_DOUBLE; yb BINARY_DOUBLE;
    r0 PLS_INTEGER; r1 PLS_INTEGER; key PLS_INTEGER; li PLS_INTEGER; dx BINARY_DOUBLE := bx - ax; tmpy BINARY_DOUBLE;
  BEGIN
    p_n := 0;
    gr_epoch := gr_epoch + 1;
    c0 := GREATEST(FLOOR((x0 - m) / 128d) - gr_x0, 0);
    c1 := LEAST(FLOOR((x1 + m) / 128d) - gr_x0, gr_nx - 1);
    FOR cx IN c0 .. c1 LOOP
      -- x-range of this column intersected with the segment's (widened by the margin)
      cxa := GREATEST((cx + gr_x0) * 128d - m, x0 - m); cxb := LEAST((cx + gr_x0 + 1) * 128d + m, x1 + m);
      IF ABS(dx) < 1e-9d THEN ya := LEAST(ay, by_); yb := GREATEST(ay, by_);
      ELSE
        ya := ay + (GREATEST(LEAST(cxa, x1), x0) - ax) * (by_ - ay) / dx;
        yb := ay + (GREATEST(LEAST(cxb, x1), x0) - ax) * (by_ - ay) / dx;
        IF ya > yb THEN tmpy := ya; ya := yb; yb := tmpy; END IF;
      END IF;
      r0 := GREATEST(FLOOR((ya - m) / 128d) - gr_y0, 0);
      r1 := LEAST(FLOOR((yb + m) / 128d) - gr_y0, gr_ny - 1);
      FOR cy IN r0 .. r1 LOOP
        key := cx * gr_ny + cy;
        FOR q IN gr_start(key) .. gr_start(key) + gr_cnt(key) - 1 LOOP
          li := gr_line(q);
          IF gr_stamp(li) <> gr_epoch THEN gr_stamp(li) := gr_epoch; p_out(p_n) := li; p_n := p_n + 1; END IF;
        END LOOP;
      END LOOP;
    END LOOP;
  END;

  -- doom_sector_at: BSP descent; (x - n.x)*dy - (y - n.y)*dx > 0 takes the right child.
  FUNCTION sector_at(p_map NUMBER, p_x BINARY_DOUBLE, p_y BINARY_DOUBLE) RETURN NUMBER IS
    n PLS_INTEGER;
  BEGIN
    load_map(p_map);
    n := n_root;
    LOOP
      IF (p_x - n_x(n)) * n_dy(n) - (p_y - n_y(n)) * n_dx(n) > 0 THEN
        IF n_rnode(n) THEN n := n_rchild(n);
        ELSE RETURN CASE WHEN ss_sec.EXISTS(n_rchild(n)) THEN ss_sec(n_rchild(n)) END; END IF;
      ELSE
        IF n_lnode(n) THEN n := n_lchild(n);
        ELSE RETURN CASE WHEN ss_sec.EXISTS(n_lchild(n)) THEN ss_sec(n_lchild(n)) END; END IF;
      END IF;
    END LOOP;
  END;

  -- current sector heights into s_fl / s_ce
  PROCEDURE load_sectors(p_map NUMBER) IS
    a t_num; b t_num; c t_num;
  BEGIN
    IF s_valid THEN RETURN; END IF;
    SELECT id, floor_height, ceil_height BULK COLLECT INTO a, b, c FROM g_sectors WHERE map_id = p_map;
    FOR i IN 1 .. a.COUNT LOOP s_fl(a(i)) := b(i); s_ce(a(i)) := c(i); END LOOP;
    s_valid := TRUE;
  END;

  -- grid query: every line whose bounding box may overlap [x0,x1]x[y0,y1] is pushed into p_out
  -- once (superset; callers apply the reference's exact tests).
  PROCEDURE grid_lines(x0 BINARY_DOUBLE, y0 BINARY_DOUBLE, x1 BINARY_DOUBLE, y1 BINARY_DOUBLE,
                       p_out IN OUT NOCOPY t_int, p_n OUT PLS_INTEGER) IS
    cx0 PLS_INTEGER := GREATEST(FLOOR(x0 / 128d) - gr_x0, 0);
    cx1 PLS_INTEGER := LEAST(FLOOR(x1 / 128d) - gr_x0, gr_nx - 1);
    cy0 PLS_INTEGER := GREATEST(FLOOR(y0 / 128d) - gr_y0, 0);
    cy1 PLS_INTEGER := LEAST(FLOOR(y1 / 128d) - gr_y0, gr_ny - 1);
    key PLS_INTEGER; li PLS_INTEGER;
  BEGIN
    p_n := 0;
    gr_epoch := gr_epoch + 1;
    FOR cx IN cx0 .. cx1 LOOP
      FOR cy IN cy0 .. cy1 LOOP
        key := cx * gr_ny + cy;
        FOR q IN gr_start(key) .. gr_start(key) + gr_cnt(key) - 1 LOOP
          li := gr_line(q);
          IF gr_stamp(li) <> gr_epoch THEN
            gr_stamp(li) := gr_epoch; p_out(p_n) := li; p_n := p_n + 1;
          END IF;
        END LOOP;
      END LOOP;
    END LOOP;
  END;

  -- =====================================================================
  -- Level start: doom_enter_level = doom_reset_stage + doom_spawn_player + doom_cs_secret
  -- (04_reset_stage.sql, 05_spawn_player.sql, 41_flow.sql). The static tables of
  -- 01_schema.sql hold the map as loaded, which is what doom_reset_stage restores.
  -- =====================================================================
  PROCEDURE cs_secret(p_map NUMBER, p_player NUMBER) IS
  BEGIN
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_level_secret_discoveries g_level_secret_discoveries_pk) */
      INTO g_level_secret_discoveries (map_id, player_thing_id, sector_id)
    SELECT ps.map_id, ps.player_thing_id, ps.sector_id
      FROM g_player_state ps
      JOIN g_sectors s ON s.map_id = ps.map_id AND s.id = ps.sector_id
      JOIN sector_special_defs sd ON sd.special = s.special AND sd.is_secret
     WHERE ps.map_id = p_map AND ps.player_thing_id = p_player
       AND NOT EXISTS (SELECT 1 FROM g_level_secret_discoveries d
                        WHERE d.map_id = ps.map_id AND d.player_thing_id = ps.player_thing_id
                          AND d.sector_id = ps.sector_id);
  END;

  PROCEDURE reset_stage(p_map NUMBER, p_skill NUMBER) IS
    v_bit NUMBER := CASE WHEN p_skill <= 1 THEN 1 WHEN p_skill = 2 THEN 2 ELSE 4 END;
  BEGIN
    DELETE FROM g_sectors WHERE map_id = p_map;
    INSERT INTO g_sectors (id, map_id, floor_height, ceil_height, spawn_floor_height, spawn_ceil_height,
                           spawn_floor_tex, spawn_light_level, floor_tex, ceil_tex, light_level, special, tag)
    SELECT id, map_id, spawn_floor_height, spawn_ceil_height, spawn_floor_height, spawn_ceil_height,
           spawn_floor_tex, spawn_light_level, spawn_floor_tex, ceil_tex,
           NVL(spawn_light_level, light_level), special, tag
      FROM sectors WHERE map_id = p_map;

    DELETE FROM g_sector_light_fx WHERE map_id = p_map;
    -- (the reference query: every linedef touching the sector on either side)
    INSERT INTO g_sector_light_fx (map_id, sector_id, special, base_light, dark_light)
    SELECT s.map_id, s.id, s.special, NVL(s.spawn_light_level, s.light_level),
           LEAST(NVL(s.spawn_light_level, s.light_level), NVL(MIN(other.light_level), 0))
      FROM g_sectors s
      LEFT JOIN (SELECT edge.map_id, r.sector_id AS rsec, l.sector_id AS lsec
                   FROM linedefs edge
                   LEFT JOIN sidedefs r ON r.map_id = edge.map_id AND r.id = edge.right_sd_id
                   LEFT JOIN sidedefs l ON l.map_id = edge.map_id AND l.id = edge.left_sd_id
                  WHERE edge.map_id = p_map) e
        ON e.rsec = s.id OR e.lsec = s.id
      LEFT JOIN g_sectors other ON other.map_id = s.map_id
       AND other.id = CASE WHEN e.rsec = s.id THEN e.lsec WHEN e.lsec = s.id THEN e.rsec END
     WHERE s.map_id = p_map AND s.special IN (1, 2, 3, 8, 12, 13, 17)
     GROUP BY s.map_id, s.id, s.special, s.spawn_light_level, s.light_level;

    DELETE FROM g_sidedefs WHERE map_id = p_map;
    INSERT INTO g_sidedefs (id, map_id, x_offset, y_offset, upper_tex, lower_tex, mid_tex, sector_id)
    SELECT id, map_id, x_offset, y_offset, upper_tex, lower_tex, mid_tex, sector_id
      FROM sidedefs WHERE map_id = p_map;

    DELETE FROM g_render_segs WHERE map_id = p_map;
    INSERT INTO g_render_segs (map_id, seg_id, ssector_id, direction, linedef_id, x1, y1, x2, y2, seg_u1, seg_u2,
                               fsec, bsec, x_offset, y_offset, upper_tex, mid_tex, lower_tex, flags,
                               f_floor, f_ceil, f_ceil_tex, f_light, b_floor, b_ceil, b_ceil_tex, b_light, light_bias)
    SELECT rs.map_id, rs.seg_id, rs.ssector_id, rs.direction, rs.linedef_id, rs.x1, rs.y1, rs.x2, rs.y2,
           rs.seg_u1, rs.seg_u2, rs.fsec, rs.bsec,
           CASE WHEN sd.id IS NULL THEN rs.x_offset ELSE sd.x_offset END,
           CASE WHEN sd.id IS NULL THEN rs.y_offset ELSE sd.y_offset END,
           CASE WHEN sd.id IS NULL THEN rs.upper_tex ELSE sd.upper_tex END,
           CASE WHEN sd.id IS NULL THEN rs.mid_tex ELSE sd.mid_tex END,
           CASE WHEN sd.id IS NULL THEN rs.lower_tex ELSE sd.lower_tex END,
           rs.flags,
           CASE WHEN fs.id IS NULL THEN rs.f_floor ELSE fs.floor_height END,
           CASE WHEN fs.id IS NULL THEN rs.f_ceil ELSE fs.ceil_height END,
           CASE WHEN fs.id IS NULL THEN rs.f_ceil_tex ELSE fs.ceil_tex END,
           CASE WHEN fs.id IS NULL THEN rs.f_light ELSE fs.light_level END,
           CASE WHEN bs.id IS NULL THEN rs.b_floor ELSE bs.floor_height END,
           CASE WHEN bs.id IS NULL THEN rs.b_ceil ELSE bs.ceil_height END,
           CASE WHEN bs.id IS NULL THEN rs.b_ceil_tex ELSE bs.ceil_tex END,
           CASE WHEN bs.id IS NULL THEN rs.b_light ELSE bs.light_level END,
           rs.light_bias
      FROM render_segs rs
      LEFT JOIN linedefs ld ON ld.map_id = rs.map_id AND ld.id = rs.linedef_id
      LEFT JOIN g_sidedefs sd ON sd.map_id = rs.map_id
       AND sd.id = CASE WHEN rs.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END
      LEFT JOIN g_sectors fs ON fs.map_id = rs.map_id AND fs.id = rs.fsec
      LEFT JOIN g_sectors bs ON bs.map_id = rs.map_id AND bs.id = rs.bsec
     WHERE rs.map_id = p_map;

    DELETE FROM g_sector_movers WHERE map_id = p_map;
    DELETE FROM g_line_buttons WHERE map_id = p_map;
    DELETE FROM g_line_activations WHERE map_id = p_map;
    DELETE FROM g_line_special_events WHERE map_id = p_map;
    DELETE FROM g_line_use_results WHERE map_id = p_map;
    DELETE FROM g_pickup_grants WHERE map_id = p_map;
    DELETE FROM g_sound_events WHERE map_id = p_map;
    DELETE FROM g_mapped_lines WHERE map_id = p_map;

    -- Things back at their spawn; dropped items (id >= 100000) are gone.
    DELETE FROM g_render_things WHERE map_id = p_map;
    INSERT INTO g_render_things (map_id, thing_id, sector_id, spawn_sector_id, sprite, frame, fullbright,
                                 spawn_ceiling, thing_height)
    SELECT map_id, thing_id, NVL(spawn_sector_id, sector_id), spawn_sector_id, sprite, frame, fullbright,
           spawn_ceiling, thing_height
      FROM render_things WHERE map_id = p_map AND thing_id < 100000;
    DELETE FROM g_things WHERE map_id = p_map;
    INSERT INTO g_things (id, map_id, x, y, z, angle, spawn_x, spawn_y, spawn_angle, mom_x, mom_y, type, flags)
    SELECT id, map_id, spawn_x, spawn_y, z, spawn_angle, spawn_x, spawn_y, spawn_angle, 0, 0, type, flags
      FROM things WHERE map_id = p_map AND id < 100000;
    -- floaters keep their height in z
    MERGE INTO g_things t
    USING (SELECT rt.thing_id, s.floor_height
             FROM g_render_things rt
             JOIN g_sectors s ON s.map_id = rt.map_id AND s.id = rt.sector_id
             JOIN g_things tt ON tt.map_id = rt.map_id AND tt.id = rt.thing_id
             JOIN thing_combat_defs d ON d.thing_type = tt.type AND d.floats
            WHERE rt.map_id = p_map) q
       ON (t.map_id = p_map AND t.id = q.thing_id)
     WHEN MATCHED THEN UPDATE SET t.z = q.floor_height;

    DELETE FROM g_thing_health WHERE map_id = p_map;
    DELETE FROM g_monster_deaths WHERE map_id = p_map;
    DELETE FROM g_monster_steps WHERE map_id = p_map;
    DELETE FROM g_monster_attack_damage WHERE map_id = p_map;
    DELETE FROM g_monster_teleports WHERE map_id = p_map;
    DELETE FROM g_monster_respawns WHERE map_id = p_map;
    INSERT INTO g_thing_health (map_id, thing_id, health, max_health, alive)
    SELECT t.map_id, t.id, d.spawn_health, d.spawn_health, TRUE
      FROM g_things t JOIN thing_combat_defs d ON d.thing_type = t.type
     WHERE t.map_id = p_map AND BITAND(t.flags, v_bit) <> 0 AND BITAND(t.flags, 16) = 0;

    DELETE FROM g_monster_ai WHERE map_id = p_map;
    INSERT INTO g_monster_ai (map_id, thing_id, state, state_tics, seq_index, sector_id, attack_cooldown, fired_this_tick)
    SELECT map_id, thing_id, 'stand', -1, 0, NULL, 0, FALSE FROM g_thing_health WHERE map_id = p_map;

    DELETE FROM g_player_weapons WHERE map_id = p_map;
    INSERT INTO g_player_weapons (map_id, player_thing_id)
    SELECT t.map_id, t.id FROM g_things t JOIN thing_role_defs r ON r.thing_type = t.type AND r.player_number = 1
     WHERE t.map_id = p_map;

    DELETE FROM g_player_weapon_owned WHERE map_id = p_map;
    INSERT INTO g_player_weapon_owned (map_id, player_thing_id, weapon_id)
    SELECT t.map_id, t.id, w.weapon_id
      FROM g_things t CROSS JOIN (SELECT 1 AS weapon_id FROM dual UNION ALL SELECT 2 FROM dual) w
      JOIN thing_role_defs r ON r.thing_type = t.type AND r.player_number = 1
     WHERE t.map_id = p_map;

    DELETE FROM g_player_state WHERE map_id = p_map;
    INSERT INTO g_player_state (map_id, player_thing_id, health, alive, ammo_bullets, previous_x, previous_y,
                                position_x, position_y, base_z, view_z, view_angle)
    SELECT t.map_id, t.id, 100, TRUE, 50, t.x, t.y, t.x, t.y, t.z, t.z, t.angle
      FROM g_things t JOIN thing_role_defs r ON r.thing_type = t.type AND r.player_number = 1
     WHERE t.map_id = p_map;

    DELETE FROM g_world_effects WHERE map_id = p_map;
    DELETE FROM g_monster_projectiles WHERE map_id = p_map;
    DELETE FROM g_projectile_impacts WHERE map_id = p_map;
    DELETE FROM g_projectile_damage WHERE map_id = p_map;
    DELETE FROM g_hitscan_hits WHERE map_id = p_map;
    DELETE FROM g_picked_up_items WHERE map_id = p_map;
    DELETE FROM g_item_respawns WHERE map_id = p_map;
    DELETE FROM g_pickup_touches WHERE map_id = p_map;
    DELETE FROM g_game_tic_commands WHERE map_id = p_map;
    -- tic_trace is not reset by doom_reset_stage: it keeps the previous run's last value until tic 1.
    DELETE FROM g_level_secret_discoveries WHERE map_id = p_map;
    DELETE FROM g_level_stats WHERE map_id = p_map;
    INSERT INTO g_level_stats (map_id, player_thing_id, skill_bit, par_tics, total_kills, total_items, total_secrets)
    SELECT t.map_id, t.id, v_bit,
           (SELECT lp.par_secs * 35 FROM level_pars lp
             WHERE lp.episode = TO_NUMBER(SUBSTR(m.name, 2, 1)) AND lp.lvl = TO_NUMBER(SUBSTR(m.name, 4, 1))),
           (SELECT COUNT(*) FROM g_things mt JOIN thing_combat_defs cd ON cd.thing_type = mt.type AND cd.counts_kill
             WHERE mt.map_id = p_map AND BITAND(mt.flags, v_bit) <> 0 AND BITAND(mt.flags, 16) = 0),
           (SELECT COUNT(*) FROM g_things it
             WHERE it.map_id = p_map AND BITAND(it.flags, v_bit) <> 0 AND BITAND(it.flags, 16) = 0
               AND EXISTS (SELECT 1 FROM pickup_defs pd WHERE pd.thing_type = it.type AND pd.counts_item)),
           (SELECT COUNT(*) FROM g_sectors s JOIN sector_special_defs sd ON sd.special = s.special AND sd.is_secret
             WHERE s.map_id = p_map)
      FROM g_things t
      JOIN thing_role_defs r ON r.thing_type = t.type AND r.player_number = 1
      JOIN maps m ON m.map_id = t.map_id
     WHERE t.map_id = p_map;
  END;

  PROCEDURE spawn_player(p_map NUMBER, p_player NUMBER) IS
    v_x BINARY_DOUBLE; v_y BINARY_DOUBLE; v_a BINARY_DOUBLE; v_sec NUMBER; v_z BINARY_DOUBLE;
  BEGIN
    SELECT t.x, t.y, t.angle INTO v_x, v_y, v_a
      FROM g_things t JOIN thing_role_defs r ON r.thing_type = t.type AND r.is_player_start
     WHERE t.map_id = p_map AND t.id = p_player;
    v_sec := sector_at(p_map, v_x, v_y);
    SELECT floor_height INTO v_z FROM g_sectors WHERE map_id = p_map AND id = v_sec;
    v_z := v_z + k_viewheight;
    UPDATE g_player_state
       SET previous_x = v_x, previous_y = v_y, position_x = v_x, position_y = v_y,
           base_z = v_z, view_z = v_z, view_angle = v_a, previous_view_z = v_z, previous_view_angle = v_a,
           momentum_x = 0, momentum_y = 0, bob_strength = 0, sector_id = v_sec
     WHERE map_id = p_map AND player_thing_id = p_player;
    UPDATE g_things t
       SET (x, y, z, angle) = (SELECT ps.position_x, ps.position_y, ps.view_z, ps.view_angle FROM g_player_state ps
                                WHERE ps.map_id = t.map_id AND ps.player_thing_id = t.id)
     WHERE t.map_id = p_map AND t.id = p_player;
  EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
  END;

  PROCEDURE enter_level(p_map NUMBER, p_player NUMBER, p_skill NUMBER) IS
  BEGIN
    load_map(p_map);
    s_valid := FALSE;
    reset_stage(p_map, p_skill);
    spawn_player(p_map, p_player);
    cs_secret(p_map, p_player);
  END;

  -- doom_cheat_arsenal (07_cheat_arsenal.sql)
  PROCEDURE cheat_arsenal(p_map NUMBER, p_player NUMBER) IS
  BEGIN
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_player_weapon_owned g_player_weapon_owned_pk) */
      INTO g_player_weapon_owned (map_id, player_thing_id, weapon_id)
    SELECT p_map, p_player, LEVEL FROM dual CONNECT BY LEVEL <= 8;
    UPDATE g_player_state
       SET ammo_bullets = (SELECT CASE WHEN backpack THEN ad.backpack_cap ELSE ad.cap END FROM ammo_defs ad WHERE ad.ammo_type = 'bullets'),
           ammo_shells  = (SELECT CASE WHEN backpack THEN ad.backpack_cap ELSE ad.cap END FROM ammo_defs ad WHERE ad.ammo_type = 'shells'),
           ammo_rockets = (SELECT CASE WHEN backpack THEN ad.backpack_cap ELSE ad.cap END FROM ammo_defs ad WHERE ad.ammo_type = 'rockets'),
           ammo_cells   = (SELECT CASE WHEN backpack THEN ad.backpack_cap ELSE ad.cap END FROM ammo_defs ad WHERE ad.ammo_type = 'cells')
     WHERE map_id = p_map AND player_thing_id = p_player;
  END;

  -- doom_cheat (38_cheats.sql)
  FUNCTION cheat(p_map NUMBER, p_player NUMBER, p_code VARCHAR2) RETURN VARCHAR2 IS
    v_code VARCHAR2(32) := UPPER(p_code);
    v_msg  VARCHAR2(200);
    v_b    BOOLEAN;
    v_x BINARY_FLOAT; v_y BINARY_FLOAT; v_a BINARY_FLOAT;
  BEGIN
    load_map(p_map);
    IF v_code = 'IDDQD' THEN
      UPDATE g_player_state SET god_mode = NOT god_mode WHERE map_id = p_map AND player_thing_id = p_player
        RETURNING god_mode INTO v_b;
      v_msg := CASE WHEN v_b THEN 'Degreelessness Mode ON' ELSE 'Degreelessness Mode OFF' END;
    END IF;
    IF v_code IN ('IDCLIP', 'IDSPISPOPD') THEN
      UPDATE g_player_state SET noclip = NOT noclip WHERE map_id = p_map AND player_thing_id = p_player
        RETURNING noclip INTO v_b;
      v_msg := CASE WHEN v_b THEN 'No Clipping Mode ON' ELSE 'No Clipping Mode OFF' END;
    END IF;
    IF v_code IN ('IDFA', 'IDKFA') THEN
      cheat_arsenal(p_map, p_player);
      v_msg := 'Ammo (no keys) Added';
    END IF;
    IF v_code = 'IDKFA' THEN
      UPDATE g_player_state SET key_red = TRUE, key_blue = TRUE, key_yellow = TRUE
       WHERE map_id = p_map AND player_thing_id = p_player;
      v_msg := 'Very Happy Ammo Added';
    END IF;
    IF v_code = 'IDBEHOLDV' THEN
      UPDATE g_player_state SET invuln_tics = 1050 WHERE map_id = p_map AND player_thing_id = p_player;
      v_msg := 'Invulnerability';
    END IF;
    IF v_code = 'IDBEHOLDS' THEN
      UPDATE g_player_state SET berserk = TRUE, health = GREATEST(health, 100) WHERE map_id = p_map AND player_thing_id = p_player;
      v_msg := 'Berserk';
    END IF;
    IF v_code = 'IDBEHOLDI' THEN
      UPDATE g_player_state SET invis_tics = 2100 WHERE map_id = p_map AND player_thing_id = p_player;
      v_msg := 'Partial Invisibility';
    END IF;
    IF v_code = 'IDBEHOLDR' THEN
      UPDATE g_player_state SET radsuit_tics = 2100 WHERE map_id = p_map AND player_thing_id = p_player;
      v_msg := 'Radiation Suit';
    END IF;
    IF v_code = 'IDBEHOLDA' THEN
      UPDATE g_player_state SET power_map = TRUE WHERE map_id = p_map AND player_thing_id = p_player;
      v_msg := 'Computer Area Map';
    END IF;
    IF v_code = 'IDBEHOLDL' THEN
      UPDATE g_player_state SET light_amp_tics = 4200 WHERE map_id = p_map AND player_thing_id = p_player;
      v_msg := 'Light Amplification Visor';
    END IF;
    IF v_code = 'IDCHOPPERS' THEN
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_player_weapon_owned g_player_weapon_owned_pk) */
        INTO g_player_weapon_owned (map_id, player_thing_id, weapon_id) VALUES (p_map, p_player, 8);
      v_msg := '... doesn''t suck - GM';
    END IF;
    IF v_code = 'IDMYPOS' THEN
      SELECT x, y, angle INTO v_x, v_y, v_a FROM g_things WHERE map_id = p_map AND id = p_player;
      v_msg := 'ang=' || TO_CHAR(rnd(v_a)) || '; x,y=(' || TO_CHAR(rnd(v_x)) || ',' || TO_CHAR(rnd(v_y)) || ')';
    END IF;
    RETURN v_msg;
  END;

  -- =====================================================================
  -- Tic stages: command, clock, plan, use, movement (08..16, 34)
  -- =====================================================================
  -- doom_cs_begin
  PROCEDURE cs_begin(p_map NUMBER, p_player NUMBER, p_skill NUMBER, p_fwd BINARY_FLOAT, p_strafe BINARY_FLOAT,
                     p_running BOOLEAN, p_turn BINARY_FLOAT, p_attack BOOLEAN, p_switch NUMBER, p_use BOOLEAN) IS
    v_bit NUMBER := CASE WHEN p_skill <= 1 THEN 1 WHEN p_skill = 2 THEN 2 ELSE 4 END;
  BEGIN
    DELETE FROM g_pickup_touches WHERE map_id = p_map AND player_thing_id = p_player;
    DELETE FROM g_pickup_grants WHERE map_id = p_map AND player_thing_id = p_player;
    UPDATE g_game_tic_commands
       SET command_serial = command_serial + 1, skill = p_skill, skill_bit = v_bit,
           move_fwd = p_fwd, move_strafe = p_strafe, running = p_running, turn_degrees = p_turn,
           attack_held = p_attack, weapon_switch_to = p_switch, use_requested = p_use, movement_mode = 'idle'
     WHERE map_id = p_map AND player_thing_id = p_player;
    IF SQL%ROWCOUNT = 0 THEN
      INSERT INTO g_game_tic_commands (map_id, player_thing_id, command_serial, skill, skill_bit, move_fwd, move_strafe,
                                       running, turn_degrees, attack_held, weapon_switch_to, use_requested, movement_mode)
      VALUES (p_map, p_player, 1, p_skill, v_bit, p_fwd, p_strafe, p_running, p_turn, p_attack, p_switch, p_use, 'idle');
    END IF;
  END;

  -- doom_cs_clock
  PROCEDURE cs_clock(p_map NUMBER, p_player NUMBER) IS
  BEGIN
    UPDATE g_player_state
       SET level_tics = level_tics + 1,
           pain_face_tics = GREATEST(0, pain_face_tics - 1), radsuit_tics = GREATEST(0, radsuit_tics - 1),
           invis_tics = GREATEST(0, invis_tics - 1), light_amp_tics = GREATEST(0, light_amp_tics - 1),
           invuln_tics = GREATEST(0, invuln_tics - 1), message_tics = GREATEST(0, message_tics - 1),
           message = CASE WHEN message_tics <= 1 THEN NULL ELSE message END,
           damage_count = GREATEST(0, damage_count - 1), bonus_count = GREATEST(0, bonus_count - 1)
     WHERE map_id = p_map AND player_thing_id = p_player;
  END;

  -- doom_cs_plan: 1 use, 2 specials, 4 movers, 8 moved, 16 weapon, 32 hitscan, 64 projectiles, 128 sound
  FUNCTION cs_plan(p_map NUMBER, p_player NUMBER) RETURN PLS_INTEGER IS
    v NUMBER;
  BEGIN
    SELECT CASE WHEN g.use_requested THEN 1 ELSE 0 END
         + CASE WHEN EXISTS (SELECT 1 FROM g_line_special_events e WHERE e.map_id = g.map_id) THEN 2 ELSE 0 END
         + CASE WHEN EXISTS (SELECT 1 FROM g_sector_movers sm WHERE sm.map_id = g.map_id AND sm.direction <> 2)
                  OR EXISTS (SELECT 1 FROM g_line_buttons b WHERE b.map_id = g.map_id AND b.countdown > 0)
                THEN 4 ELSE 0 END
         + CASE WHEN ABS(ps.position_x - ps.previous_x) > k_pos_eps
                  OR ABS(ps.position_y - ps.previous_y) > k_pos_eps THEN 8 ELSE 0 END
         + CASE WHEN g.attack_held OR g.weapon_switch_to IS NOT NULL
                  OR EXISTS (SELECT 1 FROM g_pickup_grants pg WHERE pg.map_id = g.map_id
                               AND pg.player_thing_id = g.player_thing_id)
                  OR pw.state <> 'ready' OR pw.flash_seq_index IS NOT NULL
                  OR ps.bob_strength > k_ps_eps
                  OR ABS(pw.sx - k_ps_rx) > k_ps_eps OR ABS(pw.sy - k_ps_ry) > k_ps_eps
                  OR EXISTS (SELECT 1 FROM g_world_effects we WHERE we.map_id = g.map_id)
                THEN 16 ELSE 0 END
         + CASE WHEN pw.fired_this_tick AND wd.pellet_count > 0 THEN 32 ELSE 0 END
         + CASE WHEN EXISTS (SELECT 1 FROM g_monster_projectiles mp WHERE mp.map_id = g.map_id)
                  OR (pw.fired_this_tick AND wd.projectile_type IS NOT NULL)
                  OR EXISTS (SELECT 1 FROM g_monster_ai ai
                               JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
                               JOIN thing_combat_defs d ON d.thing_type = t.type
                              WHERE ai.map_id = g.map_id AND ai.fired_this_tick AND d.missile_type IS NOT NULL)
                THEN 64 ELSE 0 END
         + CASE WHEN g.use_requested OR pw.fired_this_tick
                  OR EXISTS (SELECT 1 FROM g_pickup_touches pt WHERE pt.map_id = g.map_id
                               AND pt.player_thing_id = g.player_thing_id)
                  OR EXISTS (SELECT 1 FROM g_monster_ai ai WHERE ai.map_id = g.map_id AND ai.fired_this_tick)
                  OR EXISTS (SELECT 1 FROM g_projectile_impacts pi WHERE pi.map_id = g.map_id)
                  OR EXISTS (SELECT 1 FROM g_sector_movers sm WHERE sm.map_id = g.map_id AND sm.direction IN (-1, 1))
                  OR (wd.idle_loop_sound IS NOT NULL AND pw.state <> 'down')
                  OR EXISTS (SELECT 1 FROM g_monster_ai ai WHERE ai.map_id = g.map_id AND ai.state <> 'stand')
                  OR NOT ps.alive OR ps.pain_face_tics > 0
                THEN 128 ELSE 0 END
      INTO v
      FROM g_game_tic_commands g
      JOIN g_player_state ps ON ps.map_id = g.map_id AND ps.player_thing_id = g.player_thing_id
      JOIN g_player_weapons pw ON pw.map_id = g.map_id AND pw.player_thing_id = g.player_thing_id
      JOIN weapon_defs wd ON wd.weapon_id = pw.current_weapon
     WHERE g.map_id = p_map AND g.player_thing_id = p_player;
    RETURN v;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN 0;
  END;

  -- doom_cs_use: trace the first usable/blocking line within USERANGE (P_UseLines)
  FUNCTION cs_use(p_map NUMBER, p_player NUMBER) RETURN BOOLEAN IS
    px BINARY_DOUBLE; py BINARY_DOUBLE; dx BINARY_DOUBLE; dy BINARY_DOUBLE; ang BINARY_DOUBLE;
    den BINARY_DOUBLE; dist BINARY_DOUBLE; frac BINARY_DOUBLE;
    best PLS_INTEGER := -1; best_d BINARY_DOUBLE; best_front BOOLEAN;
    f PLS_INTEGER; b PLS_INTEGER; opening NUMBER; cand BOOLEAN;
    v_kr BOOLEAN; v_kb BOOLEAN; v_ky BOOLEAN;
    v_key VARCHAR2(8); v_use_act BOOLEAN; v_use_once BOOLEAN; v_found BOOLEAN;
    v_locked BOOLEAN; v_supported BOOLEAN; v_elig BOOLEAN; v_act NUMBER;
  BEGIN
    DELETE FROM g_line_use_results WHERE map_id = p_map AND player_thing_id = p_player;
    BEGIN
      SELECT t.x, t.y, t.angle INTO px, py, ang
        FROM g_game_tic_commands g JOIN g_things t ON t.map_id = g.map_id AND t.id = g.player_thing_id
       WHERE g.map_id = p_map AND g.player_thing_id = p_player AND g.use_requested;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN FALSE;
    END;
    dx := COS(ang * c_rad); dy := SIN(ang * c_rad);
    load_sectors(p_map);
    FOR li IN 0 .. l_n - 1 LOOP
      den := dx * (l_y2(li) - l_y1(li)) - dy * (l_x2(li) - l_x1(li));
      IF ABS(den) > 1e-9d THEN
        dist := ((l_x1(li) - px) * (l_y2(li) - l_y1(li)) - (l_y1(li) - py) * (l_x2(li) - l_x1(li))) / den;
        frac := ((l_x1(li) - px) * dy - (l_y1(li) - py) * dx) / den;
        IF dist >= 0 AND dist <= k_userange AND frac >= 0 AND frac <= 1 THEN
          f := l_fsec(li); b := l_bsec(li);
          cand := l_special(li) <> 0 OR l_lsd(li) = -1 OR l_rsd(li) = -1 OR BITAND(l_flags(li), 1) <> 0;
          IF NOT cand AND (f <> -1 OR b <> -1) THEN
            -- LEAST/GREATEST ignore NULLs
            IF f <> -1 AND b <> -1 THEN opening := LEAST(s_ce(f), s_ce(b)) - GREATEST(s_fl(f), s_fl(b));
            ELSIF f <> -1 THEN opening := s_ce(f) - s_fl(f);
            ELSE opening := s_ce(b) - s_fl(b); END IF;
            cand := opening <= 0;
          END IF;
          IF cand AND (best < 0 OR dist < best_d OR (dist = best_d AND li < best)) THEN
            best := li; best_d := dist;
            best_front := ((l_x2(li) - l_x1(li)) * (py - l_y1(li)) - (l_y2(li) - l_y1(li)) * (px - l_x1(li))) < 0;
          END IF;
        END IF;
      END IF;
    END LOOP;
    IF best < 0 THEN RETURN FALSE; END IF;
    SELECT key_red, key_blue, key_yellow INTO v_kr, v_kb, v_ky
      FROM g_player_state WHERE map_id = p_map AND player_thing_id = p_player;
    BEGIN
      SELECT key_required, use_activated, use_once INTO v_key, v_use_act, v_use_once
        FROM line_special_defs WHERE special = l_special(best);
      v_found := TRUE;
    EXCEPTION WHEN NO_DATA_FOUND THEN v_found := FALSE; v_use_act := FALSE; v_use_once := FALSE;
    END;
    v_locked := (v_key = 'red' AND NOT v_kr) OR (v_key = 'blue' AND NOT v_kb) OR (v_key = 'yellow' AND NOT v_ky);
    v_locked := NVL(v_locked, FALSE);
    v_supported := best_front AND NVL(v_use_act, FALSE);
    SELECT COUNT(*) INTO v_act FROM g_line_activations WHERE map_id = p_map AND line_id = best;
    v_elig := v_supported AND NOT v_locked AND NOT (NVL(v_use_once, FALSE) AND v_act > 0);
    INSERT INTO g_line_use_results (map_id, player_thing_id, line_id, special, locked, eligible, from_front)
    VALUES (p_map, p_player, best, l_special(best), v_locked, v_elig, best_front);
    IF v_elig THEN
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_line_special_events g_line_special_events_pk) */
        INTO g_line_special_events (map_id, player_thing_id, line_id, trigger_type, from_front)
      VALUES (p_map, p_player, best, 'use', best_front);
    END IF;
    RETURN v_elig;
  END;

  -- doom_cs_movement_mode
  FUNCTION cs_movement_mode(p_map NUMBER, p_player NUMBER) RETURN VARCHAR2 IS
    v_fwd BINARY_FLOAT; v_str BINARY_FLOAT; v_turn BINARY_FLOAT; v_alive BOOLEAN;
    v_mx BINARY_FLOAT; v_my BINARY_FLOAT; v_mz BINARY_FLOAT; v_bob BINARY_FLOAT;
    v_vz BINARY_FLOAT; v_bz BINARY_FLOAT; v_movers NUMBER; v_mode VARCHAR2(8);
  BEGIN
    SELECT g.move_fwd, g.move_strafe, g.turn_degrees, ps.alive, ps.momentum_x, ps.momentum_y, ps.momentum_z,
           ps.bob_strength, ps.view_z, ps.base_z,
           CASE WHEN EXISTS (SELECT 1 FROM g_sector_movers sm WHERE sm.map_id = g.map_id AND sm.direction <> 2)
                THEN 1 ELSE 0 END
      INTO v_fwd, v_str, v_turn, v_alive, v_mx, v_my, v_mz, v_bob, v_vz, v_bz, v_movers
      FROM g_game_tic_commands g
      JOIN g_player_state ps ON ps.map_id = g.map_id AND ps.player_thing_id = g.player_thing_id
     WHERE g.map_id = p_map AND g.player_thing_id = p_player;
    IF NOT v_alive THEN v_mode := 'idle';
    ELSIF ABS(v_fwd) > 0 OR ABS(v_str) > 0 OR ABS(v_mx) > 0.0000001f OR ABS(v_my) > 0.0000001f
       OR ABS(v_mz) > 0.0000001f OR v_bob > 0.0000001f OR ABS(v_vz - v_bz) > 0.0000001f OR v_movers = 1 THEN
      v_mode := 'full';
    ELSIF ABS(v_turn) > 0.0000001f THEN v_mode := 'turn';
    ELSE v_mode := 'idle';
    END IF;
    UPDATE g_game_tic_commands SET movement_mode = v_mode WHERE map_id = p_map AND player_thing_id = p_player;
    IF v_mode = 'idle' THEN
      UPDATE g_player_state
         SET previous_x = position_x, previous_y = position_y, momentum_x = 0, momentum_y = 0, bob_strength = 0,
             view_z = CASE WHEN alive THEN base_z ELSE view_z END,
             previous_view_z = CASE WHEN alive THEN base_z ELSE view_z END,
             previous_view_angle = view_angle
       WHERE map_id = p_map AND player_thing_id = p_player;
    END IF;
    RETURN v_mode;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN 'idle';
  END;

  -- doom_cs_turn
  PROCEDURE cs_turn(p_map NUMBER, p_player NUMBER) IS
    v_x BINARY_FLOAT; v_y BINARY_FLOAT; v_a BINARY_DOUBLE; v_t BINARY_DOUBLE; d BINARY_DOUBLE;
  BEGIN
    SELECT t.x, t.y, t.angle, g.turn_degrees INTO v_x, v_y, v_a, v_t
      FROM g_things t JOIN g_game_tic_commands g ON g.map_id = t.map_id AND g.player_thing_id = t.id
     WHERE t.map_id = p_map AND t.id = p_player AND g.movement_mode = 'turn';
    d := v_a - v_t;
    d := d - 360d * FLOOR(d / 360d);
    UPDATE g_player_state
       SET previous_x = v_x, previous_y = v_y, position_x = v_x, position_y = v_y, view_angle = d,
           previous_view_angle = view_angle, previous_view_z = view_z,
           momentum_x = 0, momentum_y = 0, bob_strength = 0, view_z = base_z
     WHERE map_id = p_map AND player_thing_id = p_player;
    UPDATE g_things t SET angle = (SELECT ps.view_angle FROM g_player_state ps
                                    WHERE ps.map_id = t.map_id AND ps.player_thing_id = t.id)
     WHERE t.map_id = p_map AND t.id = p_player;
  EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
  END;

  -- doom_cs_death: P_DeathThink's view drop
  PROCEDURE cs_death(p_map NUMBER, p_player NUMBER) IS
  BEGIN
    UPDATE g_player_state ps
       SET (view_z, previous_view_z, previous_view_angle, damage_count, death_tics,
            momentum_x, momentum_y, momentum_z, bob_strength) =
           (SELECT GREATEST(TO_BINARY_DOUBLE(s.floor_height) + 6d, ps.view_z - 1),
                   ps.view_z, ps.view_angle, GREATEST(0, ps.damage_count - 1), ps.death_tics + 1, 0, 0, 0, 0
              FROM g_sectors s WHERE s.map_id = ps.map_id AND s.id = ps.sector_id)
     WHERE ps.map_id = p_map AND ps.player_thing_id = p_player AND NOT ps.alive
       AND EXISTS (SELECT 1 FROM g_sectors s WHERE s.map_id = ps.map_id AND s.id = ps.sector_id);
  END;

  -- doom_cs_move: one 35 Hz player movement step (P_XYMovement / P_TryMove / P_ZMovement)
  PROCEDURE cs_move(p_map NUMBER, p_player NUMBER) IS
    fwd BINARY_DOUBLE; side BINARY_DOUBLE; running BOOLEAN; turn BINARY_DOUBLE; noclip BOOLEAN; skill_bit NUMBER;
    px BINARY_DOUBLE; py BINARY_DOUBLE; oa BINARY_DOUBLE; omx BINARY_DOUBLE; omy BINARY_DOUBLE; omz BINARY_DOUBLE;
    feet_z BINARY_DOUBLE; on_ground BOOLEAN; lt NUMBER; base_f BINARY_FLOAT; mz_f BINARY_FLOAT;
    r BINARY_DOUBLE := k_player_radius; ft BINARY_DOUBLE; st BINARY_DOUBLE; na BINARY_DOUBLE;
    ca BINARY_DOUBLE; sa BINARY_DOUBLE; rmx BINARY_DOUBLE; rmy BINARY_DOUBLE;
    lx0 BINARY_DOUBLE; lx1 BINARY_DOUBLE; ly0 BINARY_DOUBLE; ly1 BINARY_DOUBLE;
    cand t_int; ncand PLS_INTEGER; blk t_int; nblk PLS_INTEGER := 0;
    li PLS_INTEGER; f PLS_INTEGER; b PLS_INTEGER; isblk BOOLEAN;
    tx t_dbl; ty t_dbl; tbd t_dbl; ntb PLS_INTEGER := 0;
    a1 t_flt; a2 t_flt; a3 t_dbl;
    cx BINARY_DOUBLE; cy BINARY_DOUBLE; found BOOLEAN := FALSE; blocked BOOLEAN;
    dxl BINARY_DOUBLE; dyl BINARY_DOUBLE; den BINARY_DOUBLE; tt BINARY_DOUBLE; ex BINARY_DOUBLE; ey BINARY_DOUBLE;
    dist BINARY_DOUBLE; dist0 BINARY_DOUBLE; d1 BINARY_DOUBLE; d2 BINARY_DOUBLE; d3 BINARY_DOUBLE; d4 BINARY_DOUBLE;
    sec NUMBER; fl NUMBER; zsum BINARY_DOUBLE; feet BINARY_DOUBLE; nmz BINARY_DOUBLE; base BINARY_DOUBLE;
    bob BINARY_DOUBLE; slx BINARY_DOUBLE; sly BINARY_DOUBLE; boff BINARY_DOUBLE; nmx BINARY_DOUBLE; nmy BINARY_DOUBLE;
    gx BINARY_DOUBLE; gy BINARY_DOUBLE; mxl BINARY_DOUBLE; myl BINARY_DOUBLE; rad BINARY_DOUBLE;
  BEGIN
    BEGIN
      SELECT g.move_fwd, g.move_strafe, g.running, g.turn_degrees, ps.noclip, g.skill_bit,
             t.x, t.y, t.angle, ps.momentum_x, ps.momentum_y, ps.momentum_z, ps.base_z, ps.level_tics
        INTO fwd, side, running, turn, noclip, skill_bit, px, py, oa, omx, omy, mz_f, base_f, lt
        FROM g_game_tic_commands g
        JOIN g_player_state ps ON ps.map_id = g.map_id AND ps.player_thing_id = g.player_thing_id
        JOIN g_things t ON t.map_id = g.map_id AND t.id = g.player_thing_id
       WHERE g.map_id = p_map AND g.player_thing_id = p_player AND g.movement_mode = 'full';
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN;
    END;
    omz := mz_f;
    feet_z := TO_BINARY_DOUBLE(base_f) - k_viewheight;
    on_ground := mz_f = 0;
    ft := CASE WHEN running THEN k_fwd_run ELSE k_fwd END * k_thrust;
    st := CASE WHEN running THEN k_side_run ELSE k_side END * k_thrust;
    na := (oa - turn) - 360d * FLOOR((oa - turn) / 360d);
    ca := COS(na * c_rad); sa := SIN(na * c_rad);
    IF on_ground THEN
      rmx := LEAST(k_maxmove, GREATEST(-k_maxmove, omx + (fwd * ft * ca + side * st * sa)));
      rmy := LEAST(k_maxmove, GREATEST(-k_maxmove, omy + (fwd * ft * sa - side * st * ca)));
    ELSE
      rmx := LEAST(k_maxmove, GREATEST(-k_maxmove, omx + 0d));
      rmy := LEAST(k_maxmove, GREATEST(-k_maxmove, omy + 0d));
    END IF;
    -- blocking lines (bounded by the move's box, as the reference does)
    load_sectors(p_map);
    lx1 := GREATEST(px, px + rmx) + r + 2d; lx0 := LEAST(px, px + rmx) - r - 2d;
    ly1 := GREATEST(py, py + rmy) + r + 2d; ly0 := LEAST(py, py + rmy) - r - 2d;
    grid_lines(lx0, ly0, lx1, ly1, cand, ncand);
    FOR q IN 0 .. ncand - 1 LOOP
      li := cand(q);
      IF LEAST(l_x1(li), l_x2(li)) <= lx1 AND GREATEST(l_x1(li), l_x2(li)) >= lx0
         AND LEAST(l_y1(li), l_y2(li)) <= ly1 AND GREATEST(l_y1(li), l_y2(li)) >= ly0 THEN
        f := l_fsec(li); b := l_bsec(li);
        isblk := l_lsd(li) = -1 OR l_rsd(li) = -1 OR BITAND(l_flags(li), 1) <> 0;
        IF NOT isblk AND f <> -1 AND b <> -1 THEN
          isblk := LEAST(s_ce(f), s_ce(b)) - GREATEST(s_fl(f), s_fl(b)) < k_player_height
                   OR GREATEST(s_fl(b), s_fl(f)) > feet_z + k_maxstep;
        END IF;
        IF isblk THEN blk(nblk) := li; nblk := nblk + 1; END IF;
      END IF;
    END LOOP;
    -- blocking things (PIT_CheckThing): live actors and solid decorations near the move. The SQL
    -- box is a superset (largest radius); the reference's per-thing box is applied below.
    gx := GREATEST(px, px + rmx); mxl := LEAST(px, px + rmx);
    gy := GREATEST(py, py + rmy); myl := LEAST(py, py + rmy);
    FOR rr IN (SELECT tt2.x, tt2.y, tt2.type, tt2.flags, hh.alive
                 FROM g_things tt2
                 LEFT JOIN g_thing_health hh ON hh.map_id = tt2.map_id AND hh.thing_id = tt2.id
                WHERE tt2.map_id = p_map AND tt2.id <> p_player
                  AND tt2.x BETWEEN mxl - (g_max_radius + k_player_radius + k_block_margin + 1d)
                                AND gx + (g_max_radius + k_player_radius + k_block_margin + 1d)
                  AND tt2.y BETWEEN myl - (g_max_radius + k_player_radius + k_block_margin + 1d)
                                AND gy + (g_max_radius + k_player_radius + k_block_margin + 1d)) LOOP
      IF (tc_radius.EXISTS(rr.type) AND NVL(rr.alive, FALSE))
         OR (bd_radius.EXISTS(rr.type) AND BITAND(rr.flags, 16) = 0 AND BITAND(rr.flags, skill_bit) <> 0) THEN
        rad := CASE WHEN tc_radius.EXISTS(rr.type) THEN tc_radius(rr.type) ELSE bd_radius(rr.type) END;
        IF rr.x <= gx + rad + k_player_radius + k_block_margin
           AND rr.x >= mxl - rad - k_player_radius - k_block_margin
           AND rr.y <= gy + rad + k_player_radius + k_block_margin
           AND rr.y >= myl - rad - k_player_radius - k_block_margin THEN
          tx(ntb) := rr.x; ty(ntb) := rr.y; tbd(ntb) := rad + k_player_radius; ntb := ntb + 1;
        END IF;
      END IF;
    END LOOP;
    -- other live players (deathmatch) also block
    FOR rr IN (SELECT ot.x, ot.y FROM g_player_state op JOIN g_things ot ON ot.map_id = op.map_id AND ot.id = op.player_thing_id
                WHERE op.map_id = p_map AND op.player_thing_id <> p_player AND op.alive) LOOP
      tx(ntb) := rr.x; ty(ntb) := rr.y; tbd(ntb) := k_player_radius * 2; ntb := ntb + 1;
    END LOOP;
    -- candidates in priority order: full move, x only, y only, stay
    FOR pri IN 1 .. 4 LOOP
      cx := CASE WHEN pri IN (1, 2) THEN px + rmx ELSE px END;
      cy := CASE WHEN pri IN (1, 3) THEN py + rmy ELSE py END;
      blocked := FALSE;
      IF NOT noclip THEN
        FOR q IN 0 .. nblk - 1 LOOP
          li := blk(q);
          dxl := l_x2(li) - l_x1(li); dyl := l_y2(li) - l_y1(li);
          den := dxl * dxl + dyl * dyl;
          IF den = 0 THEN tt := 0;
          ELSE tt := LEAST(1d, GREATEST(0d, ((cx - l_x1(li)) * dxl + (cy - l_y1(li)) * dyl) / den)); END IF;
          ex := cx - (l_x1(li) + tt * dxl); ey := cy - (l_y1(li) + tt * dyl);
          dist := SQRT(ex * ex + ey * ey);
          IF den = 0 THEN tt := 0;
          ELSE tt := LEAST(1d, GREATEST(0d, ((px - l_x1(li)) * dxl + (py - l_y1(li)) * dyl) / den)); END IF;
          ex := px - (l_x1(li) + tt * dxl); ey := py - (l_y1(li) + tt * dyl);
          dist0 := SQRT(ex * ex + ey * ey);
          IF dist < r AND dist < dist0 THEN blocked := TRUE; EXIT; END IF;
          d1 := (px - l_x1(li)) * dyl - (py - l_y1(li)) * dxl;
          d2 := (cx - l_x1(li)) * dyl - (cy - l_y1(li)) * dxl;
          d3 := (l_x1(li) - px) * (cy - py) - (l_y1(li) - py) * (cx - px);
          d4 := (l_x2(li) - px) * (cy - py) - (l_y2(li) - py) * (cx - px);
          IF d1 * d2 < 0 AND d3 * d4 < 0 THEN blocked := TRUE; EXIT; END IF;
        END LOOP;
        IF NOT blocked THEN
          FOR q IN 0 .. ntb - 1 LOOP
            IF ABS(cx - tx(q)) < tbd(q) AND ABS(cy - ty(q)) < tbd(q) THEN blocked := TRUE; EXIT; END IF;
          END LOOP;
        END IF;
      END IF;
      IF NOT blocked THEN found := TRUE; EXIT; END IF;
    END LOOP;
    IF found THEN
      sec := sector_at(p_map, cx, cy);
      IF sec IS NOT NULL AND s_fl.EXISTS(sec) THEN
        fl := s_fl(sec);
        zsum := feet_z + omz;
        IF zsum <= fl THEN feet := fl; nmz := 0d;
        ELSIF omz = 0d THEN feet := zsum; nmz := -2d * k_gravity;
        ELSE feet := zsum; nmz := omz - k_gravity; END IF;
        base := feet + k_viewheight;
        bob := LEAST((rmx * rmx + rmy * rmy) / k_bob_factor, k_maxbob);
        slx := CASE WHEN ABS(cx - (px + rmx)) < k_pos_eps THEN rmx ELSE 0d END;
        sly := CASE WHEN ABS(cy - (py + rmy)) < k_pos_eps THEN rmy ELSE 0d END;
        boff := (bob / 2d) * SIN(2d * c_pi * lt / k_bob_period);
        IF NOT on_ground THEN nmx := slx; nmy := sly;
        ELSIF fwd = 0 AND side = 0 AND ABS(slx) < k_stopspeed AND ABS(sly) < k_stopspeed THEN nmx := 0d; nmy := 0d;
        ELSE nmx := slx * k_friction; nmy := sly * k_friction; END IF;
        UPDATE g_player_state
           SET previous_x = px, previous_y = py, position_x = cx, position_y = cy,
               base_z = base, view_z = base + boff, view_angle = na,
               previous_view_z = view_z, previous_view_angle = view_angle,
               momentum_x = nmx, momentum_y = nmy, momentum_z = nmz, bob_strength = bob, sector_id = sec
         WHERE map_id = p_map AND player_thing_id = p_player;
      END IF;
    END IF;
    UPDATE g_things t
       SET (x, y, z, angle) = (SELECT ps.position_x, ps.position_y, ps.view_z, ps.view_angle FROM g_player_state ps
                                WHERE ps.map_id = t.map_id AND ps.player_thing_id = t.id)
     WHERE t.map_id = p_map AND t.id = p_player;
  END;

  -- =====================================================================
  -- doom_cs_activate_specials (12_cs_activate_specials.sql): queued linedef
  -- events -> sector movers, switches, lights, teleports. Rare; SQL translation.
  -- =====================================================================
  FUNCTION cs_activate_specials(p_map NUMBER) RETURN PLS_INTEGER IS
    v_flags PLS_INTEGER := 0;
    v_active PLS_INTEGER := 0;
    v_n1 NUMBER; v_n2 NUMBER;
  BEGIN
    DELETE FROM g_line_special_events e
     WHERE e.map_id = p_map
       AND EXISTS (
         SELECT 1 FROM linedefs ld JOIN line_special_defs d ON d.special = ld.special
          WHERE ld.map_id = e.map_id AND ld.id = e.line_id
            AND EXISTS (
              SELECT 1 FROM g_line_special_events e2
                JOIN linedefs ld2 ON ld2.map_id = e2.map_id AND ld2.id = e2.line_id
                JOIN line_special_defs d2 ON d2.special = ld2.special
               WHERE e2.map_id = e.map_id AND d2.mechanic = d.mechanic
                 AND ((ld.tag <> 0 AND ld2.tag = ld.tag) OR (ld.tag = 0 AND ld2.id = ld.id))
                 AND (ld2.id < ld.id OR (ld2.id = ld.id AND e2.player_thing_id < e.player_thing_id))));

    SELECT NVL(MAX(CASE WHEN stale = 1 THEN 1 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND mechanic = 'door' THEN 2 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND mechanic = 'floor' THEN 4 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND mechanic = 'platform' THEN 8 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND mechanic = 'donut' THEN 16 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND has_sw = 1 AND flips_switch THEN 32 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND one_shot = 1 THEN 64 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND mechanic = 'raise' THEN 128 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND mechanic = 'stairs' THEN 256 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND mechanic = 'lights' THEN 512 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND mechanic = 'teleport' THEN 1024 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND mechanic = 'ceiling' THEN 2048 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND mechanic = 'crusher' THEN 4096 ELSE 0 END), 0)
         + NVL(MAX(CASE WHEN stale = 0 AND mechanic = 'stop' THEN 8192 ELSE 0 END), 0)
      INTO v_flags
      FROM (SELECT d.mechanic, d.flips_switch,
                   CASE WHEN NVL(d.cross_once, FALSE) OR NVL(d.use_once, FALSE) THEN 1 ELSE 0 END AS one_shot,
                   CASE WHEN (NVL(d.cross_once, FALSE) OR NVL(d.use_once, FALSE))
                             AND EXISTS (SELECT 1 FROM g_line_activations a WHERE a.map_id = e.map_id AND a.line_id = e.line_id)
                        THEN 1 ELSE 0 END AS stale,
                   CASE WHEN sd.upper_tex LIKE 'SW1%' OR sd.mid_tex LIKE 'SW1%' OR sd.lower_tex LIKE 'SW1%'
                        THEN 1 ELSE 0 END AS has_sw
              FROM g_line_special_events e
              JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
              LEFT JOIN line_special_defs d ON d.special = ld.special
              LEFT JOIN g_sidedefs sd ON sd.map_id = ld.map_id AND sd.id = ld.right_sd_id
             WHERE e.map_id = p_map);

    IF BITAND(v_flags, 1) <> 0 THEN
      DELETE FROM g_line_special_events e
       WHERE e.map_id = p_map AND EXISTS (
         SELECT 1 FROM linedefs ld JOIN g_line_activations a ON a.map_id = ld.map_id AND a.line_id = ld.id
           JOIN line_special_defs d ON d.special = ld.special AND (d.cross_once OR d.use_once)
          WHERE ld.map_id = e.map_id AND ld.id = e.line_id);
    END IF;

    IF BITAND(v_flags, 2) <> 0 THEN
      -- doors: manual back-sector doors plus tagged remote doors
      MERGE INTO g_sector_movers m
      USING (
        WITH events AS (
          SELECT e.map_id, e.line_id, e.trigger_type, ld.special, ld.tag, ld.left_sd_id
            FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
           WHERE e.map_id = p_map),
        door_sectors AS (
          -- INLINE: referenced twice; materialising it (TEMP TABLE TRANSFORMATION) cost ~22 ms a call
          SELECT /*+ INLINE */ e.map_id, e.line_id, e.special,
                 CASE WHEN d.door_target = 'back' THEN back.sector_id ELSE s.id END AS sector_id
            FROM events e
            JOIN line_special_defs d ON d.special = e.special AND d.mechanic = 'door'
            LEFT JOIN g_sidedefs back ON back.map_id = e.map_id AND back.id = e.left_sd_id
            -- the tag join only matters for tag doors: for a back door (tag 0) it repeated the row
            -- once per tag-0 sector (175x, 61k rows after neighbors); the GROUP BY in targets
            -- collapses those identical rows, so restricting the join changes no result
            LEFT JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = e.tag AND d.door_target = 'tag'
           WHERE (d.door_target = 'back' AND back.sector_id IS NOT NULL)
              OR (d.door_target = 'tag' AND s.id IS NOT NULL)),
        neighbors AS (
          SELECT ds.map_id, ds.line_id, ds.special, ds.sector_id, other.ceil_height
            FROM door_sectors ds
            JOIN sector_adjacency a ON a.map_id = p_map AND a.sector_id = ds.sector_id AND a.sector_id <> a.other_id
            JOIN g_sectors other ON other.map_id = ds.map_id AND other.id = a.other_id),
        targets AS (
          SELECT ds.map_id, ds.line_id, ds.special, ds.sector_id, s.floor_height, s.ceil_height,
                 GREATEST(s.ceil_height, NVL(MIN(n.ceil_height) - 4, s.ceil_height)) AS open_height
            FROM door_sectors ds
            JOIN g_sectors s ON s.map_id = ds.map_id AND s.id = ds.sector_id
            LEFT JOIN neighbors n ON n.map_id = ds.map_id AND n.line_id = ds.line_id AND n.sector_id = ds.sector_id
           GROUP BY ds.map_id, ds.line_id, ds.special, ds.sector_id, s.floor_height, s.ceil_height),
        targets_unique AS (
          SELECT * FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.map_id, t.sector_id ORDER BY t.line_id) AS rn
                           FROM targets t) WHERE rn = 1)
        SELECT t.map_id, t.sector_id, t.line_id, d.mover_type, d.direction, t.floor_height,
               CASE WHEN d.direction = -1 THEN t.ceil_height ELSE t.open_height END AS top_height,
               d.speed, d.wait_tics
          FROM targets_unique t JOIN line_special_defs d ON d.special = t.special) src
      ON (m.map_id = src.map_id AND m.sector_id = src.sector_id)
      WHEN MATCHED THEN UPDATE SET
        m.source_line_id = CASE WHEN src.mover_type = 'door_manual_raise' AND m.plane = 'ceiling'
                                THEN src.line_id ELSE m.source_line_id END,
        m.direction = CASE WHEN src.mover_type = 'door_manual_raise' AND m.plane = 'ceiling'
                           THEN CASE WHEN m.direction IN (-1, 2) THEN 1 ELSE -1 END ELSE m.direction END,
        m.countdown = CASE WHEN src.mover_type = 'door_manual_raise' AND m.plane = 'ceiling' THEN 0 ELSE m.countdown END,
        m.next_ceiling = CASE WHEN src.mover_type = 'door_manual_raise' AND m.plane = 'ceiling'
                              THEN NULL ELSE m.next_ceiling END,
        m.moved_this_tick = CASE WHEN src.mover_type = 'door_manual_raise' AND m.plane = 'ceiling'
                                 THEN FALSE ELSE m.moved_this_tick END
      WHEN NOT MATCHED THEN INSERT
        (map_id, sector_id, source_line_id, mover_type, plane, direction, bottom_height, top_height, speed,
         wait_tics, countdown, next_ceiling, next_floor, target_floor_tex, moved_this_tick)
        VALUES (src.map_id, src.sector_id, src.line_id, src.mover_type, 'ceiling', src.direction, src.floor_height,
                src.top_height, src.speed, src.wait_tics, 0, NULL, NULL, NULL, FALSE);
    END IF;

    IF BITAND(v_flags, 4) <> 0 THEN
      -- floor lowering
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_sector_movers g_sector_movers_pk) */ INTO g_sector_movers
        (map_id, sector_id, source_line_id, mover_type, plane, direction, bottom_height, top_height, speed,
         wait_tics, countdown, next_ceiling, next_floor, target_floor_tex, moved_this_tick)
      WITH events AS (
        SELECT e.map_id, e.line_id, ld.special, ld.tag, d.height_target, d.mover_type, d.direction, d.speed, d.change_tex
          FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
          JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'floor'
         WHERE e.map_id = p_map),
      targets AS (
        SELECT e.map_id, e.line_id, e.special, e.height_target, e.mover_type, e.direction, e.speed, e.change_tex,
               s.id AS sector_id, s.floor_height,
               MIN(other.floor_height) AS lowest_floor, MAX(other.floor_height) AS highest_floor
          FROM events e JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = e.tag
          JOIN sector_adjacency a ON a.map_id = p_map AND a.sector_id = s.id AND a.sector_id <> a.other_id
          JOIN g_sectors other ON other.map_id = s.map_id AND other.id = a.other_id
         GROUP BY e.map_id, e.line_id, e.special, e.height_target, e.mover_type, e.direction, e.speed, e.change_tex,
                  s.id, s.floor_height),
      dest AS (
        SELECT t.*, CASE WHEN height_target = 'lowest' THEN lowest_floor
                         WHEN height_target = 'highest' THEN highest_floor
                         WHEN highest_floor <> floor_height THEN highest_floor + 8
                         ELSE floor_height END AS destination
          FROM targets t),
      model AS (
        SELECT d.*,
               CASE WHEN d.change_tex THEN
                 (SELECT MIN(o.floor_tex) KEEP (DENSE_RANK FIRST ORDER BY o.id)
                    FROM sector_adjacency a JOIN g_sectors o ON o.map_id = d.map_id AND o.id = a.other_id
                   WHERE a.map_id = p_map AND a.sector_id <> a.other_id AND a.sector_id = d.sector_id
                     AND o.floor_height = d.destination) END AS model_tex
          FROM dest d)
      SELECT map_id, sector_id, line_id, mover_type, 'floor', direction, LEAST(floor_height, destination),
             floor_height, speed, 0, 0, NULL, NULL, model_tex, FALSE
        FROM model WHERE destination < floor_height;
    END IF;

    IF BITAND(v_flags, 8) <> 0 THEN
      -- down-wait-up lifts
      MERGE INTO g_sector_movers m
      USING (
        WITH events AS (
          SELECT e.map_id, e.line_id, ld.special, ld.tag, d.mover_type, d.direction, d.speed, d.wait_tics
            FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
            JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'platform'
           WHERE e.map_id = p_map),
        targets AS (
          SELECT e.map_id, e.line_id, e.mover_type, e.direction, e.speed, e.wait_tics, s.id AS sector_id, s.floor_height,
                 MIN(other.floor_height) AS lowest_floor, MAX(other.floor_height) AS highest_floor
            FROM events e JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = e.tag
            JOIN sector_adjacency a ON a.map_id = p_map AND a.sector_id = s.id AND a.sector_id <> a.other_id
            JOIN g_sectors other ON other.map_id = s.map_id AND other.id = a.other_id
           GROUP BY e.map_id, e.line_id, e.mover_type, e.direction, e.speed, e.wait_tics, s.id, s.floor_height),
        targets_unique AS (
          SELECT * FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.map_id, t.sector_id ORDER BY t.line_id) AS rn
                           FROM targets t) WHERE rn = 1)
        SELECT map_id, sector_id, line_id, mover_type, direction, LEAST(floor_height, lowest_floor) AS bottom_height,
               CASE WHEN mover_type = 'platform_perpetual' THEN GREATEST(floor_height, highest_floor)
                    ELSE floor_height END AS top_height, speed, wait_tics
          FROM targets_unique) src
      ON (m.map_id = src.map_id AND m.sector_id = src.sector_id)
      WHEN MATCHED THEN UPDATE SET m.source_line_id = src.line_id, m.direction = -1, m.countdown = 0,
                                   m.next_floor = NULL, m.moved_this_tick = FALSE
        WHERE m.direction = 2 AND m.plane = 'floor'
      WHEN NOT MATCHED THEN INSERT
        (map_id, sector_id, source_line_id, mover_type, plane, direction, bottom_height, top_height, speed,
         wait_tics, countdown, next_ceiling, next_floor, target_floor_tex, moved_this_tick)
        VALUES (src.map_id, src.sector_id, src.line_id, src.mover_type, 'floor', src.direction, src.bottom_height,
                src.top_height, src.speed, src.wait_tics, 0, NULL, NULL, NULL, FALSE);
    END IF;

    IF BITAND(v_flags, 16) <> 0 THEN
      -- S1 donut
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_sector_movers g_sector_movers_pk) */ INTO g_sector_movers
        (map_id, sector_id, source_line_id, mover_type, plane, direction, bottom_height, top_height, speed,
         wait_tics, countdown, next_ceiling, next_floor, target_floor_tex, moved_this_tick)
      WITH events AS (
        SELECT e.map_id, e.line_id, ld.tag
          FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
          JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'donut'
         WHERE e.map_id = p_map),
      pillar AS (
        SELECT e.map_id, e.line_id, s.id AS pillar_id, s.floor_height AS pillar_floor
          FROM events e JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = e.tag),
      ring AS (
        SELECT * FROM (
          SELECT p.*, a.other_id AS ring_id,
                 ROW_NUMBER() OVER (PARTITION BY p.map_id, p.line_id, p.pillar_id ORDER BY a.linedef_id) AS rn
            FROM pillar p JOIN sector_adjacency a ON a.map_id = p_map AND a.sector_id = p.pillar_id)
         WHERE rn = 1),
      outside AS (
        SELECT * FROM (
          SELECT r.map_id, r.line_id, r.pillar_id, r.pillar_floor, r.ring_id, a.other_id AS outside_id,
                 ROW_NUMBER() OVER (PARTITION BY r.map_id, r.line_id, r.pillar_id ORDER BY a.linedef_id) AS orn
            FROM ring r JOIN sector_adjacency a ON a.map_id = p_map AND a.sector_id = r.ring_id
           WHERE a.other_id <> r.pillar_id)
         WHERE orn = 1),
      motions AS (
        SELECT o.map_id, o.line_id, o.pillar_id AS sector_id, 'floor_lower' AS mover_type, -1 AS direction,
               LEAST(o.pillar_floor, s.floor_height) AS bottom_height, o.pillar_floor AS top_height,
               CAST(NULL AS VARCHAR2(8)) AS target_tex
          FROM outside o JOIN g_sectors s ON s.map_id = o.map_id AND s.id = o.outside_id
        UNION ALL
        SELECT o.map_id, o.line_id, o.ring_id, 'donut_raise', 1, ring.floor_height,
               GREATEST(ring.floor_height, s.floor_height), s.floor_tex
          FROM outside o JOIN g_sectors ring ON ring.map_id = o.map_id AND ring.id = o.ring_id
          JOIN g_sectors s ON s.map_id = o.map_id AND s.id = o.outside_id)
      SELECT map_id, sector_id, line_id, mover_type, 'floor', direction, bottom_height, top_height, 1, 0, 0,
             NULL, NULL, target_tex, FALSE
        FROM motions WHERE bottom_height <> top_height;
    END IF;

    IF BITAND(v_flags, 32) <> 0 THEN
      -- switch textures
      DELETE FROM g_line_buttons b WHERE b.map_id = p_map AND b.countdown = 0
         AND EXISTS (SELECT 1 FROM g_line_special_events e WHERE e.map_id = b.map_id AND e.line_id = b.line_id);
      INSERT INTO g_line_buttons (map_id, line_id, sidedef_id, texture_part, original_tex, active_tex, countdown, just_restored)
      WITH events AS (
        SELECT DISTINCT e.map_id, e.line_id, ld.special, ld.right_sd_id,
               CASE WHEN d.cross_once OR d.use_once THEN 1 ELSE 0 END AS one_shot
          FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
          JOIN line_special_defs d ON d.special = ld.special AND d.flips_switch
         WHERE e.map_id = p_map),
      parts AS (
        SELECT e.map_id, e.line_id, e.right_sd_id AS sidedef_id, 'upper' AS texture_part, sd.upper_tex AS tex,
               CASE WHEN e.one_shot = 1 THEN -1 ELSE 35 END AS countdown
          FROM events e JOIN g_sidedefs sd ON sd.map_id = e.map_id AND sd.id = e.right_sd_id
         WHERE sd.upper_tex LIKE 'SW1%'
        UNION ALL
        SELECT e.map_id, e.line_id, e.right_sd_id, 'middle', sd.mid_tex, CASE WHEN e.one_shot = 1 THEN -1 ELSE 35 END
          FROM events e JOIN g_sidedefs sd ON sd.map_id = e.map_id AND sd.id = e.right_sd_id
         WHERE sd.mid_tex LIKE 'SW1%'
        UNION ALL
        SELECT e.map_id, e.line_id, e.right_sd_id, 'lower', sd.lower_tex, CASE WHEN e.one_shot = 1 THEN -1 ELSE 35 END
          FROM events e JOIN g_sidedefs sd ON sd.map_id = e.map_id AND sd.id = e.right_sd_id
         WHERE sd.lower_tex LIKE 'SW1%')
      SELECT map_id, line_id, sidedef_id, texture_part, tex, 'SW2' || SUBSTR(tex, 4), countdown, FALSE FROM parts;
      UPDATE g_sidedefs sd
         SET upper_tex = NVL((SELECT MIN(u.active_tex) FROM g_line_buttons u WHERE u.map_id = sd.map_id
                                AND u.sidedef_id = sd.id AND u.texture_part = 'upper'), sd.upper_tex),
             mid_tex = NVL((SELECT MIN(u.active_tex) FROM g_line_buttons u WHERE u.map_id = sd.map_id
                                AND u.sidedef_id = sd.id AND u.texture_part = 'middle'), sd.mid_tex),
             lower_tex = NVL((SELECT MIN(u.active_tex) FROM g_line_buttons u WHERE u.map_id = sd.map_id
                                AND u.sidedef_id = sd.id AND u.texture_part = 'lower'), sd.lower_tex)
       WHERE sd.map_id = p_map
         AND sd.id IN (SELECT b.sidedef_id FROM g_line_buttons b WHERE b.map_id = p_map
                          AND EXISTS (SELECT 1 FROM g_line_special_events e WHERE e.map_id = b.map_id AND e.line_id = b.line_id));
      MERGE INTO g_render_segs rs
      USING (SELECT rs2.seg_id, sd.upper_tex, sd.mid_tex, sd.lower_tex
               FROM g_render_segs rs2 JOIN linedefs ld ON ld.map_id = rs2.map_id AND ld.id = rs2.linedef_id
               JOIN g_sidedefs sd ON sd.map_id = ld.map_id
                AND sd.id = CASE WHEN rs2.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END
              WHERE rs2.map_id = p_map) q
         ON (rs.map_id = p_map AND rs.seg_id = q.seg_id)
       WHEN MATCHED THEN UPDATE SET rs.upper_tex = q.upper_tex, rs.mid_tex = q.mid_tex, rs.lower_tex = q.lower_tex;
    END IF;

    IF BITAND(v_flags, 64) <> 0 THEN
      INSERT INTO g_line_activations (map_id, line_id)
      SELECT DISTINCT e.map_id, e.line_id
        FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
        JOIN line_special_defs d ON d.special = ld.special AND (d.cross_once OR d.use_once)
       WHERE e.map_id = p_map;
    END IF;

    IF BITAND(v_flags, 128) <> 0 THEN
      -- floor raises
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_sector_movers g_sector_movers_pk) */ INTO g_sector_movers
        (map_id, sector_id, source_line_id, mover_type, plane, direction, bottom_height, top_height, speed,
         wait_tics, countdown, next_ceiling, next_floor, target_floor_tex, moved_this_tick, crush)
      WITH events AS (
        SELECT e.map_id, e.line_id, ld.special, ld.tag, d.height_target, d.change_tex, d.mover_type, d.direction,
               d.speed, d.crush, fs.floor_tex AS front_tex
          FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
          JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'raise'
          LEFT JOIN g_sidedefs fsd ON fsd.map_id = ld.map_id AND fsd.id = ld.right_sd_id
          LEFT JOIN g_sectors fs ON fs.map_id = ld.map_id AND fs.id = fsd.sector_id
         WHERE e.map_id = p_map),
      shortest AS (
        SELECT sec.id AS sector_id, MIN(wt.height) AS shortest
          FROM g_sectors sec
          JOIN g_sidedefs sd ON sd.map_id = sec.map_id AND sd.sector_id = sec.id
          JOIN linedefs ld ON ld.map_id = sd.map_id AND (ld.right_sd_id = sd.id OR ld.left_sd_id = sd.id)
          JOIN g_sidedefs both_sides ON both_sides.map_id = ld.map_id AND both_sides.id IN (ld.right_sd_id, ld.left_sd_id)
          JOIN walltex_meta wt ON wt.name = both_sides.lower_tex
         WHERE sec.map_id = p_map AND both_sides.lower_tex IS NOT NULL AND both_sides.lower_tex <> '-'
         GROUP BY sec.id),
      neighbors AS (
        SELECT e.map_id, e.line_id, e.special, e.height_target, e.change_tex, e.mover_type, e.direction, e.speed,
               e.crush, e.front_tex, s.id AS sector_id, s.floor_height, s.ceil_height,
               other.id AS other_id, other.floor_height AS other_floor, other.ceil_height AS other_ceil,
               other.floor_tex AS other_tex
          FROM events e JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = e.tag
          JOIN sector_adjacency a ON a.map_id = p_map AND a.sector_id = s.id AND a.sector_id <> a.other_id
          JOIN g_sectors other ON other.map_id = s.map_id AND other.id = a.other_id),
      targets AS (
        SELECT n.map_id, n.line_id, n.special, n.height_target, n.change_tex, n.mover_type, n.direction, n.speed,
               n.crush, n.front_tex, n.sector_id, n.floor_height,
               LEAST(MIN(n.other_ceil), n.ceil_height) AS lowest_ceiling,
               MIN(CASE WHEN n.other_floor > n.floor_height THEN n.other_floor END) AS next_floor,
               MIN(sh.shortest) AS shortest_texture
          FROM neighbors n LEFT JOIN shortest sh ON sh.sector_id = n.sector_id
         GROUP BY n.map_id, n.line_id, n.special, n.height_target, n.change_tex, n.mover_type, n.direction, n.speed,
                  n.crush, n.front_tex, n.sector_id, n.floor_height, n.ceil_height),
      dest AS (
        SELECT t.*,
               CASE t.height_target
                 WHEN 'lowest_ceiling' THEN t.lowest_ceiling
                 WHEN 'lowest_ceiling_minus8' THEN t.lowest_ceiling - 8
                 WHEN 'plus24' THEN t.floor_height + 24
                 WHEN 'plus32' THEN t.floor_height + 32
                 WHEN 'plus512' THEN t.floor_height + 512
                 WHEN 'shortest_texture' THEN t.floor_height + t.shortest_texture
                 ELSE t.next_floor END AS destination
          FROM targets t),
      model AS (
        SELECT d.*,
               CASE WHEN d.height_target IN ('plus24', 'plus32') THEN d.front_tex ELSE
                 (SELECT MIN(n.other_tex) KEEP (DENSE_RANK FIRST ORDER BY n.other_id) FROM neighbors n
                   WHERE n.map_id = d.map_id AND n.line_id = d.line_id AND n.sector_id = d.sector_id
                     AND n.other_floor = d.destination) END AS model_tex
          FROM dest d)
      SELECT map_id, sector_id, line_id, mover_type, 'floor', direction, floor_height, destination, speed, 0, 0,
             NULL, NULL, CASE WHEN change_tex THEN model_tex END, FALSE, crush
        FROM model WHERE destination IS NOT NULL AND destination > floor_height;
      MERGE INTO g_sectors s
      USING (SELECT sec.map_id, sec.id, sec.floor_height,
                    LEAST(MIN(o.ceil_height), sec.ceil_height)
                      - CASE WHEN d.height_target = 'lowest_ceiling_minus8' THEN 8 ELSE 0 END AS dest
               FROM g_line_special_events e
               JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
               JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'raise'
                AND d.height_target IN ('lowest_ceiling', 'lowest_ceiling_minus8')
               JOIN g_sectors sec ON sec.map_id = e.map_id AND sec.tag = ld.tag AND ld.tag <> 0
               JOIN sector_adjacency a ON a.map_id = sec.map_id AND a.sector_id = sec.id
               JOIN g_sectors o ON o.map_id = a.map_id AND o.id = a.other_id
              WHERE e.map_id = p_map AND o.id <> sec.id
              GROUP BY sec.map_id, sec.id, sec.floor_height, sec.ceil_height, d.height_target) q
         ON (s.map_id = q.map_id AND s.id = q.id)
       WHEN MATCHED THEN UPDATE SET s.floor_height = q.dest
        WHERE q.dest < q.floor_height
          AND NOT EXISTS (SELECT 1 FROM g_sector_movers sm WHERE sm.map_id = s.map_id AND sm.sector_id = s.id);
    END IF;

    IF BITAND(v_flags, 256) <> 0 THEN
      -- stairs: walk outward in a line (first two-sided neighbour with the same flat), +step each
      FOR ev IN (SELECT e.map_id, e.line_id, ld.tag, NVL(d.step_height, 8) AS step_h, NVL(d.speed, 1) AS speed
                   FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
                   JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'stairs'
                  WHERE e.map_id = p_map) LOOP
        FOR st IN (SELECT id, floor_tex, floor_height FROM g_sectors WHERE map_id = p_map AND tag = ev.tag) LOOP
          DECLARE
            cur_sec NUMBER := st.id; cur_tex VARCHAR2(8) := st.floor_tex; dest NUMBER := st.floor_height + ev.step_h;
            seen VARCHAR2(4000) := ',' || st.id || ','; nid NUMBER; ntex VARCHAR2(8); stepn PLS_INTEGER := 0;
          BEGIN
            LOOP
              INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_sector_movers g_sector_movers_pk) */ INTO g_sector_movers
                (map_id, sector_id, source_line_id, mover_type, plane, direction, bottom_height, top_height, speed,
                 wait_tics, countdown, next_ceiling, next_floor, target_floor_tex, moved_this_tick)
              SELECT p_map, cur_sec, ev.line_id, 'floor_raise', 'floor', 1, s.floor_height, dest, ev.speed, 0, 0,
                     NULL, NULL, NULL, FALSE
                FROM g_sectors s WHERE s.map_id = p_map AND s.id = cur_sec AND dest > s.floor_height;
              EXIT WHEN stepn >= 24;
              BEGIN
                SELECT nid2, ntex2 INTO nid, ntex FROM (
                  SELECT nxt.id AS nid2, nxt.floor_tex AS ntex2
                    FROM sector_adjacency a JOIN g_sectors nxt ON nxt.map_id = p_map AND nxt.id = a.other_id
                   WHERE a.map_id = p_map AND a.sector_id <> a.other_id AND a.sector_id = cur_sec
                     AND nxt.floor_tex = cur_tex AND INSTR(seen, ',' || nxt.id || ',') = 0
                   ORDER BY a.linedef_id) WHERE ROWNUM = 1;
              EXCEPTION WHEN NO_DATA_FOUND THEN EXIT;
              END;
              stepn := stepn + 1; cur_sec := nid; cur_tex := ntex; dest := dest + ev.step_h;
              seen := seen || nid || ',';
            END LOOP;
          END;
        END LOOP;
      END LOOP;
    END IF;

    IF BITAND(v_flags, 512) <> 0 THEN
      -- light changes
      MERGE INTO g_sectors s
      USING (
        WITH ev AS (
          SELECT ld.tag, d.target_light, d.light_source
            FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
            JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'lights'
           WHERE e.map_id = p_map AND (d.light_source IS NULL OR d.light_source <> 'strobe')),
        neighbour_light AS (
          SELECT a.sector_id, MAX(o.light_level) AS brightest, MIN(o.light_level) AS dimmest
            FROM sector_adjacency a JOIN g_sectors o ON o.map_id = p_map AND o.id = a.other_id
           WHERE a.map_id = p_map AND a.sector_id <> a.other_id
           GROUP BY a.sector_id)
        SELECT s2.id AS sector_id,
               MAX(CASE ev.light_source WHEN 'max_neighbor' THEN nb.brightest WHEN 'min_neighbor' THEN nb.dimmest
                   ELSE ev.target_light END) AS lvl
          FROM ev JOIN g_sectors s2 ON s2.map_id = p_map AND s2.tag = ev.tag
          LEFT JOIN neighbour_light nb ON nb.sector_id = s2.id
         GROUP BY s2.id) n
      ON (s.map_id = p_map AND s.id = n.sector_id)
      WHEN MATCHED THEN UPDATE SET s.light_level = n.lvl WHERE n.lvl IS NOT NULL;
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_sector_light_fx g_sector_light_fx_pk) */
        INTO g_sector_light_fx (map_id, sector_id, special, base_light, dark_light)
      SELECT s.map_id, s.id, 3, s.light_level,
             LEAST(s.light_level, NVL((SELECT MIN(o.light_level) FROM sector_adjacency a
                                        JOIN g_sectors o ON o.map_id = a.map_id AND o.id = a.other_id
                                       WHERE a.map_id = s.map_id AND a.sector_id = s.id AND a.other_id <> s.id), 0))
        FROM g_line_special_events e
        JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
        JOIN line_special_defs d ON d.special = ld.special AND d.light_source = 'strobe'
        JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = ld.tag
       WHERE e.map_id = p_map;
      UPDATE g_render_segs rs SET f_light = (SELECT s.light_level FROM g_sectors s WHERE s.map_id = rs.map_id AND s.id = rs.fsec)
       WHERE rs.map_id = p_map AND rs.fsec IN (
         SELECT s.id FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
           JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'lights'
           JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = ld.tag WHERE e.map_id = p_map);
      UPDATE g_render_segs rs SET b_light = (SELECT s.light_level FROM g_sectors s WHERE s.map_id = rs.map_id AND s.id = rs.bsec)
       WHERE rs.map_id = p_map AND rs.bsec IN (
         SELECT s.id FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
           JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'lights'
           JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = ld.tag WHERE e.map_id = p_map);
    END IF;

    IF BITAND(v_flags, 1024) <> 0 THEN
      -- teleport the player onto the type-14 Thing in the tagged sector
      MERGE INTO g_player_state ps
      USING (
        WITH events AS (
          SELECT e.map_id, e.line_id, e.player_thing_id, ld.tag
            FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
            JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'teleport'
           WHERE e.map_id = p_map),
        tagged AS (
          SELECT e.map_id, e.line_id, e.player_thing_id, s.id AS sector_id, s.floor_height,
                 MIN(rs.x1) AS min_x, MAX(rs.x1) AS max_x, MIN(rs.y1) AS min_y, MAX(rs.y1) AS max_y
            FROM events e JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = e.tag
            JOIN g_render_segs rs ON rs.map_id = s.map_id AND rs.fsec = s.id
           GROUP BY e.map_id, e.line_id, e.player_thing_id, s.id, s.floor_height),
        candidates AS (
          SELECT t.*, th.id AS dest_id, th.x AS dest_x, th.y AS dest_y, th.angle AS dest_angle,
                 ABS(th.x - (t.min_x + t.max_x) / 2) + ABS(th.y - (t.min_y + t.max_y) / 2) AS off_centre
            FROM tagged t JOIN g_things th ON th.map_id = t.map_id
            JOIN thing_role_defs tr ON tr.thing_type = th.type AND tr.is_teleport_dest
             AND th.x BETWEEN t.min_x AND t.max_x AND th.y BETWEEN t.min_y AND t.max_y)
        SELECT * FROM (SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.map_id, c.player_thing_id
                                                      ORDER BY c.off_centre, c.dest_id) AS rn FROM candidates c)
         WHERE rn = 1) ch
      ON (ps.map_id = ch.map_id AND ps.player_thing_id = ch.player_thing_id)
      WHEN MATCHED THEN UPDATE SET
        ps.position_x = ch.dest_x, ps.position_y = ch.dest_y, ps.previous_x = ch.dest_x, ps.previous_y = ch.dest_y,
        ps.base_z = ch.floor_height + 41, ps.view_z = ch.floor_height + 41, ps.view_angle = ch.dest_angle,
        ps.previous_view_z = ch.floor_height + 41, ps.previous_view_angle = ch.dest_angle,
        ps.momentum_x = 0, ps.momentum_y = 0, ps.bob_strength = 0, ps.sector_id = ch.sector_id;
      UPDATE g_things t
         SET (x, y, z, angle) = (SELECT ps.position_x, ps.position_y, ps.view_z, ps.view_angle FROM g_player_state ps
                                  WHERE ps.map_id = t.map_id AND ps.player_thing_id = t.id)
       WHERE t.map_id = p_map
         AND EXISTS (SELECT 1 FROM g_player_state ps WHERE ps.map_id = t.map_id AND ps.player_thing_id = t.id)
         AND EXISTS (SELECT 1 FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
                       JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'teleport'
                      WHERE e.map_id = t.map_id AND e.player_thing_id = t.id);
    END IF;

    IF BITAND(v_flags, 2048) <> 0 THEN
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_sector_movers g_sector_movers_pk) */ INTO g_sector_movers
        (map_id, sector_id, source_line_id, mover_type, plane, direction, bottom_height, top_height, speed,
         wait_tics, countdown, next_ceiling, next_floor, target_floor_tex, moved_this_tick, crush)
      WITH events AS (
        SELECT e.map_id, e.line_id, ld.tag, d.height_target, d.mover_type, d.direction, d.speed, d.crush
          FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
          JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'ceiling'
         WHERE e.map_id = p_map),
      targets AS (
        SELECT e.map_id, e.line_id, e.height_target, e.mover_type, e.direction, e.speed, e.crush,
               s.id AS sector_id, s.floor_height, s.ceil_height, MAX(other.ceil_height) AS highest_ceiling
          FROM events e JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = e.tag
          LEFT JOIN sector_adjacency a ON a.map_id = p_map AND a.sector_id = s.id AND a.sector_id <> a.other_id
          LEFT JOIN g_sectors other ON other.map_id = s.map_id AND other.id = a.other_id
         GROUP BY e.map_id, e.line_id, e.height_target, e.mover_type, e.direction, e.speed, e.crush,
                  s.id, s.floor_height, s.ceil_height),
      tu AS (SELECT * FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.map_id, t.sector_id ORDER BY t.line_id) AS rn
                              FROM targets t) WHERE rn = 1)
      SELECT map_id, sector_id, line_id, mover_type, 'ceiling', direction,
             CASE height_target WHEN 'highest_ceiling' THEN ceil_height WHEN 'floor8' THEN floor_height + 8
                  ELSE floor_height END,
             CASE height_target WHEN 'highest_ceiling' THEN GREATEST(ceil_height, NVL(highest_ceiling, ceil_height))
                  ELSE ceil_height END,
             speed, 0, 0, NULL, NULL, NULL, FALSE, crush
        FROM tu
       WHERE (direction = 1 AND NVL(highest_ceiling, ceil_height) > ceil_height)
          OR (direction = -1 AND ceil_height > CASE height_target WHEN 'floor8' THEN floor_height + 8 ELSE floor_height END);
    END IF;

    IF BITAND(v_flags, 4096) <> 0 THEN
      MERGE INTO g_sector_movers m
      USING (SELECT * FROM (
               SELECT e.map_id, e.line_id, d.speed, s.id AS sector_id, s.floor_height, s.ceil_height,
                      ROW_NUMBER() OVER (PARTITION BY e.map_id, s.id ORDER BY e.line_id) AS rn
                 FROM g_line_special_events e JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
                 JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'crusher'
                 JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = ld.tag
                WHERE e.map_id = p_map)
              WHERE rn = 1 AND ceil_height > floor_height + 8) src
      ON (m.map_id = src.map_id AND m.sector_id = src.sector_id)
      WHEN MATCHED THEN UPDATE SET m.source_line_id = src.line_id, m.direction = -1, m.countdown = 0,
                                   m.next_ceiling = NULL, m.moved_this_tick = FALSE
        WHERE m.mover_type = 'crusher' AND m.direction = 2
      WHEN NOT MATCHED THEN INSERT
        (map_id, sector_id, source_line_id, mover_type, plane, direction, bottom_height, top_height, speed,
         wait_tics, countdown, next_ceiling, next_floor, target_floor_tex, moved_this_tick, crush)
        VALUES (src.map_id, src.sector_id, src.line_id, 'crusher', 'ceiling', -1, src.floor_height + 8, src.ceil_height,
                src.speed, 0, 0, NULL, NULL, NULL, FALSE, TRUE);
    END IF;

    IF BITAND(v_flags, 8192) <> 0 THEN
      UPDATE g_sector_movers m SET direction = 2, moved_this_tick = FALSE
       WHERE m.map_id = p_map AND m.direction <> 2
         AND EXISTS (SELECT 1 FROM g_line_special_events e
                       JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
                       JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'stop'
                       JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = ld.tag
                      WHERE e.map_id = p_map AND s.id = m.sector_id AND m.mover_type = d.stops_mover);
    END IF;

    DELETE FROM g_line_special_events WHERE map_id = p_map;
    SELECT (SELECT COUNT(*) FROM g_sector_movers WHERE map_id = p_map AND direction <> 2),
           (SELECT COUNT(*) FROM g_line_buttons WHERE map_id = p_map AND countdown > 0)
      INTO v_n1, v_n2 FROM dual;
    IF v_n1 > 0 THEN v_active := v_active + 1; END IF;
    IF v_n2 > 0 THEN v_active := v_active + 2; END IF;
    RETURN v_active;
  END;

  -- =====================================================================
  -- doom_cs_doors (13_cs_doors.sql): advance movers and switch buttons
  -- =====================================================================
  PROCEDURE cs_doors(p_map NUMBER, p_player NUMBER) IS
    v_any NUMBER; v_px BINARY_DOUBLE; v_py BINARY_DOUBLE; v_psec NUMBER;
    TYPE t_occ IS TABLE OF BOOLEAN INDEX BY PLS_INTEGER; occ t_occ;
    mv_dir PLS_INTEGER; tot NUMBER; stp NUMBER; carry NUMBER; cc NUMBER; cf NUMBER; cd PLS_INTEGER; ccnt NUMBER;
    v_moved NUMBER := 0;
  BEGIN
    UPDATE g_line_buttons SET just_restored = CASE WHEN countdown = 1 THEN TRUE ELSE FALSE END,
                              countdown = GREATEST(0, countdown - 1)
     WHERE map_id = p_map AND countdown >= 0;
    IF SQL%ROWCOUNT > 0 THEN
      UPDATE g_sidedefs sd
         SET upper_tex = NVL((SELECT MIN(u.original_tex) FROM g_line_buttons u WHERE u.map_id = sd.map_id
                                AND u.sidedef_id = sd.id AND u.texture_part = 'upper'), sd.upper_tex),
             mid_tex = NVL((SELECT MIN(u.original_tex) FROM g_line_buttons u WHERE u.map_id = sd.map_id
                                AND u.sidedef_id = sd.id AND u.texture_part = 'middle'), sd.mid_tex),
             lower_tex = NVL((SELECT MIN(u.original_tex) FROM g_line_buttons u WHERE u.map_id = sd.map_id
                                AND u.sidedef_id = sd.id AND u.texture_part = 'lower'), sd.lower_tex)
       WHERE sd.map_id = p_map
         AND sd.id IN (SELECT b.sidedef_id FROM g_line_buttons b WHERE b.map_id = p_map AND b.just_restored);
      SELECT COUNT(*) INTO v_any FROM g_line_buttons WHERE map_id = p_map AND just_restored;
      IF v_any > 0 THEN
        MERGE INTO g_render_segs rs
        USING (SELECT rs2.seg_id, sd.upper_tex, sd.mid_tex, sd.lower_tex
                 FROM g_render_segs rs2 JOIN linedefs ld ON ld.map_id = rs2.map_id AND ld.id = rs2.linedef_id
                 JOIN g_sidedefs sd ON sd.map_id = ld.map_id
                  AND sd.id = CASE WHEN rs2.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END
                WHERE rs2.map_id = p_map
                  AND EXISTS (SELECT 1 FROM g_line_buttons b WHERE b.map_id = rs2.map_id
                                AND b.line_id = rs2.linedef_id AND b.just_restored)) q
           ON (rs.map_id = p_map AND rs.seg_id = q.seg_id)
         WHEN MATCHED THEN UPDATE SET rs.upper_tex = q.upper_tex, rs.mid_tex = q.mid_tex, rs.lower_tex = q.lower_tex;
      END IF;
    END IF;

    -- movers
    FOR m IN (SELECT m.sector_id, m.mover_type, m.plane, m.direction, m.bottom_height, m.top_height, m.speed,
                     m.move_carry, m.wait_tics, m.countdown, s.floor_height, s.ceil_height
                FROM g_sector_movers m JOIN g_sectors s ON s.map_id = m.map_id AND s.id = m.sector_id
               WHERE m.map_id = p_map AND m.direction <> 2) LOOP
      mv_dir := m.direction;
      IF m.plane = 'ceiling' AND m.direction = -1
         AND m.mover_type NOT IN ('door_close_open', 'door_close', 'crusher', 'ceiling_lower') THEN
        IF v_psec IS NULL AND occ.COUNT = 0 THEN
        SELECT x, y INTO v_px, v_py FROM g_things WHERE map_id = p_map AND id = p_player;
        v_psec := NVL(sector_at(p_map, v_px, v_py), -1);
        FOR o IN (SELECT DISTINCT NVL(ai.sector_id, rt.sector_id) AS sid
                    FROM g_monster_ai ai
                    JOIN g_thing_health h ON h.map_id = ai.map_id AND h.thing_id = ai.thing_id AND h.alive
                    JOIN g_render_things rt ON rt.map_id = ai.map_id AND rt.thing_id = ai.thing_id
                   WHERE ai.map_id = p_map
                  UNION
                  SELECT ps.sector_id FROM g_player_state ps
                   WHERE ps.map_id = p_map AND ps.player_thing_id <> p_player AND ps.alive AND ps.sector_id IS NOT NULL) LOOP
          IF o.sid IS NOT NULL THEN occ(o.sid) := TRUE; END IF;
        END LOOP;
        occ(-999) := TRUE;   -- marks the set as loaded
      END IF;
        IF v_psec = m.sector_id OR occ.EXISTS(m.sector_id) THEN mv_dir := 1; END IF;
      END IF;
      tot := m.speed + m.move_carry;
      stp := TRUNC(tot);
      carry := tot - stp;
      cc := m.ceil_height; cf := m.floor_height;
      IF m.plane = 'ceiling' THEN
        IF mv_dir = 1 THEN cc := LEAST(m.top_height, m.ceil_height + stp);
        ELSIF mv_dir = -1 THEN cc := GREATEST(m.bottom_height, m.ceil_height - stp); END IF;
        IF mv_dir = -1 AND m.bottom_height IS NULL THEN cc := m.ceil_height - stp; END IF;
      END IF;
      IF m.plane = 'floor' THEN
        IF mv_dir = 1 THEN cf := LEAST(m.top_height, m.floor_height + stp);
        ELSIF mv_dir = -1 THEN cf := GREATEST(m.bottom_height, m.floor_height - stp); END IF;
        IF mv_dir = -1 AND m.bottom_height IS NULL THEN cf := m.floor_height - stp; END IF;
      END IF;
      IF mv_dir = 1 AND ((m.plane = 'ceiling' AND cc >= m.top_height) OR (m.plane = 'floor' AND cf >= m.top_height)) THEN
        cd := CASE WHEN m.mover_type IN ('door_raise', 'door_manual_raise', 'platform_perpetual') THEN 0
                   WHEN m.mover_type = 'crusher' THEN -1 ELSE 2 END;
      ELSIF mv_dir = 0 AND m.countdown <= 1 THEN
        cd := CASE WHEN m.mover_type IN ('platform', 'door_close_open') THEN 1
                   WHEN m.mover_type = 'platform_perpetual' THEN CASE WHEN m.floor_height >= m.top_height THEN -1 ELSE 1 END
                   ELSE -1 END;
      ELSIF mv_dir = -1 AND ((m.plane = 'ceiling' AND cc <= m.bottom_height) OR (m.plane = 'floor' AND cf <= m.bottom_height)) THEN
        cd := CASE WHEN m.mover_type IN ('platform', 'door_close_open', 'platform_perpetual') THEN 0
                   WHEN m.mover_type = 'crusher' THEN 1 ELSE 2 END;
      ELSE
        cd := mv_dir;
      END IF;
      IF mv_dir = 1 AND m.mover_type IN ('door_raise', 'door_manual_raise', 'platform_perpetual')
         AND ((m.plane = 'ceiling' AND cc >= m.top_height) OR (m.plane = 'floor' AND cf >= m.top_height)) THEN
        ccnt := m.wait_tics;
      ELSIF mv_dir = -1 AND m.mover_type IN ('platform', 'platform_perpetual') AND cf <= m.bottom_height THEN
        ccnt := m.wait_tics;
      ELSIF mv_dir = -1 AND m.mover_type = 'door_close_open' AND cc <= m.bottom_height THEN
        ccnt := m.wait_tics;
      ELSIF mv_dir = 0 THEN
        ccnt := GREATEST(0, m.countdown - 1);
      ELSE
        ccnt := m.countdown;
      END IF;
      UPDATE g_sector_movers
         SET direction = cd, countdown = ccnt, move_carry = CASE WHEN cd IN (0, 2) THEN 0 ELSE carry END,
             next_ceiling = cc, next_floor = cf,
             moved_this_tick = CASE WHEN cc <> m.ceil_height OR cf <> m.floor_height THEN TRUE ELSE FALSE END
       WHERE map_id = p_map AND sector_id = m.sector_id;
      IF cc <> m.ceil_height OR cf <> m.floor_height THEN v_moved := v_moved + 1; END IF;
    END LOOP;

    IF v_moved > 0 THEN
      UPDATE g_sectors s SET ceil_height = (SELECT m.next_ceiling FROM g_sector_movers m
                                             WHERE m.map_id = s.map_id AND m.sector_id = s.id)
       WHERE s.map_id = p_map
         AND EXISTS (SELECT 1 FROM g_sector_movers m WHERE m.map_id = s.map_id AND m.sector_id = s.id
                       AND m.plane = 'ceiling' AND m.moved_this_tick);
      UPDATE g_sectors s
         SET (floor_height, floor_tex) =
             (SELECT m.next_floor, CASE WHEN m.direction = 2 AND m.target_floor_tex IS NOT NULL
                                        THEN m.target_floor_tex ELSE s.floor_tex END
                FROM g_sector_movers m WHERE m.map_id = s.map_id AND m.sector_id = s.id)
       WHERE s.map_id = p_map
         AND EXISTS (SELECT 1 FROM g_sector_movers m WHERE m.map_id = s.map_id AND m.sector_id = s.id
                       AND m.plane = 'floor' AND m.moved_this_tick);
      -- PIT_ChangeSector crush
      MERGE INTO g_thing_health h
      USING (SELECT DISTINCT t.id
               FROM g_sector_movers m
               JOIN g_sectors s ON s.map_id = m.map_id AND s.id = m.sector_id
               JOIN g_render_things rt ON rt.map_id = m.map_id AND rt.sector_id = m.sector_id
               JOIN g_things t ON t.map_id = rt.map_id AND t.id = rt.thing_id
               JOIN thing_combat_defs d ON d.thing_type = t.type AND NOT d.explodes
               JOIN g_player_state pc ON pc.map_id = m.map_id AND pc.player_thing_id = p_player
              WHERE m.map_id = p_map AND m.crush AND m.moved_this_tick
                AND ((m.plane = 'ceiling' AND m.direction = -1) OR (m.plane = 'floor' AND m.direction = 1))
                AND s.ceil_height - s.floor_height < d.height AND MOD(pc.level_tics, 4) = 0) q
         ON (h.map_id = p_map AND h.thing_id = q.id)
       WHEN MATCHED THEN UPDATE SET h.health = h.health - 10,
                                    h.alive = CASE WHEN h.health - 10 > 0 THEN TRUE ELSE FALSE END
        WHERE h.alive;
      MERGE INTO g_player_state ps
      USING (SELECT ps2.map_id, ps2.player_thing_id,
                    LEAST(ps2.armor, CASE ps2.armor_class WHEN 2 THEN 5 WHEN 1 THEN 3 ELSE 0 END) AS saved
               FROM g_sector_movers m
               JOIN g_sectors s ON s.map_id = m.map_id AND s.id = m.sector_id
               JOIN g_player_state ps2 ON ps2.map_id = m.map_id AND ps2.sector_id = m.sector_id
              WHERE m.map_id = p_map AND m.crush AND m.moved_this_tick
                AND ((m.plane = 'ceiling' AND m.direction = -1) OR (m.plane = 'floor' AND m.direction = 1))
                AND s.ceil_height - s.floor_height < 56
                AND ps2.alive AND NOT ps2.god_mode AND ps2.invuln_tics <= 0 AND MOD(ps2.level_tics, 4) = 0) d
         ON (ps.map_id = d.map_id AND ps.player_thing_id = d.player_thing_id)
       WHEN MATCHED THEN UPDATE SET
         ps.armor = ps.armor - d.saved,
         ps.armor_class = CASE WHEN ps.armor - d.saved <= 0 THEN 0 ELSE ps.armor_class END,
         ps.health = GREATEST(0, ps.health - (10 - d.saved)),
         ps.damage_count = LEAST(100, ps.damage_count + (10 - d.saved)),
         ps.pain_face_tics = 12,
         ps.alive = CASE WHEN ps.health - (10 - d.saved) > 0 THEN TRUE ELSE FALSE END,
         ps.killer_id = CASE WHEN ps.health - (10 - d.saved) <= 0 THEN -1 ELSE ps.killer_id END;
      UPDATE g_render_segs rs
         SET (f_floor, f_ceil, f_ceil_tex, f_light) =
             (SELECT s.floor_height, s.ceil_height, s.ceil_tex, s.light_level FROM g_sectors s
               WHERE s.map_id = rs.map_id AND s.id = rs.fsec)
       WHERE rs.map_id = p_map
         AND rs.fsec IN (SELECT m.sector_id FROM g_sector_movers m WHERE m.map_id = p_map AND m.moved_this_tick);
      UPDATE g_render_segs rs
         SET (b_floor, b_ceil, b_ceil_tex, b_light) =
             (SELECT s.floor_height, s.ceil_height, s.ceil_tex, s.light_level FROM g_sectors s
               WHERE s.map_id = rs.map_id AND s.id = rs.bsec)
       WHERE rs.map_id = p_map
         AND rs.bsec IN (SELECT m.sector_id FROM g_sector_movers m WHERE m.map_id = p_map AND m.moved_this_tick);
    END IF;
  END;

  -- =====================================================================
  -- Movement-gated stages: discover, cross, pickups (17, 37, 18, 19)
  -- =====================================================================
  PROCEDURE cs_discover(p_map NUMBER, p_player NUMBER) IS
  BEGIN
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_mapped_lines g_mapped_lines_pk) */ INTO g_mapped_lines (map_id, line_id)
    SELECT DISTINCT p_map, q.linedef_id
      FROM (SELECT lg.linedef_id FROM g_player_state ps JOIN linedef_geom lg ON lg.map_id = ps.map_id AND lg.fsec = ps.sector_id
             WHERE ps.map_id = p_map AND ps.player_thing_id = p_player
            UNION ALL
            SELECT lg.linedef_id FROM g_player_state ps JOIN linedef_geom lg ON lg.map_id = ps.map_id AND lg.bsec = ps.sector_id
             WHERE ps.map_id = p_map AND ps.player_thing_id = p_player) q
     WHERE NOT EXISTS (SELECT 1 FROM g_mapped_lines m WHERE m.map_id = p_map AND m.line_id = q.linedef_id);
  END;

  -- doom_cs_cross: special lines crossed by this tic's accepted movement
  PROCEDURE cs_cross(p_map NUMBER, p_player NUMBER) IS
    ox BINARY_DOUBLE; oy BINARY_DOUBLE; nx BINARY_DOUBLE; ny BINARY_DOUBLE;
    li PLS_INTEGER; e BINARY_DOUBLE; ff BOOLEAN; old_side BINARY_DOUBLE; new_side BINARY_DOUBLE;
    v1s BINARY_DOUBLE; v2s BINARY_DOUBLE; v_act NUMBER;
  BEGIN
    SELECT previous_x, previous_y, position_x, position_y INTO ox, oy, nx, ny
      FROM g_player_state WHERE map_id = p_map AND player_thing_id = p_player;
    FOR q IN 0 .. l_cross_n - 1 LOOP
      li := l_cross_list(q);
      e := (l_x2(li) - l_x1(li)) * (oy - l_y1(li)) - (l_y2(li) - l_y1(li)) * (ox - l_x1(li));
      ff := e < 0; old_side := ABS(e);
      new_side := (l_x2(li) - l_x1(li)) * (ny - l_y1(li)) - (l_y2(li) - l_y1(li)) * (nx - l_x1(li));
      v1s := (nx - ox) * (l_y1(li) - oy) - (ny - oy) * (l_x1(li) - ox);
      v2s := (nx - ox) * (l_y2(li) - oy) - (ny - oy) * (l_x2(li) - ox);
      IF old_side > 1e-7d AND new_side <> 0 AND ((ff AND new_side > 0) OR (NOT ff AND new_side < 0))
         AND v1s * v2s < 0 THEN
        v_act := 0;
        IF l_cross_once(li) THEN
          SELECT COUNT(*) INTO v_act FROM g_line_activations WHERE map_id = p_map AND line_id = li;
        END IF;
        IF v_act = 0 THEN
          INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_line_special_events g_line_special_events_pk) */
            INTO g_line_special_events (map_id, player_thing_id, line_id, trigger_type, from_front)
          VALUES (p_map, p_player, li, 'cross', ff);
        END IF;
      END IF;
    END LOOP;
  END;

  -- doom_cs_pickups
  PROCEDURE cs_pickups(p_map NUMBER, p_player NUMBER) IS
    v_n NUMBER;
    v_reach BINARY_DOUBLE := k('PICKUP_REACH');
    v_drop BINARY_DOUBLE := k('DROPPED_THING_ID_BASE');
    v_bonus BINARY_DOUBLE := k('BONUSADD');
    v_msgt BINARY_DOUBLE := k('MESSAGE_TICS');
    v_bul NUMBER; v_she NUMBER; v_roc NUMBER; v_cel NUMBER;
  BEGIN
    INSERT INTO g_pickup_touches (map_id, player_thing_id, thing_id, kind, amount, cap, is_set_min, weapon_id, armor_class)
    WITH params AS (
      SELECT /*+ INLINE */ ps.map_id, TO_BINARY_DOUBLE(ps.position_x) AS px, TO_BINARY_DOUBLE(ps.position_y) AS py,
             g.skill_bit AS skill, g.skill AS skill_level, ps.player_thing_id
        FROM g_player_state ps
        JOIN g_game_tic_commands g ON g.map_id = ps.map_id AND g.player_thing_id = ps.player_thing_id
       WHERE ps.map_id = p_map AND ps.player_thing_id = p_player
         AND (ABS(ps.position_x - ps.previous_x) > k_pos_eps OR ABS(ps.position_y - ps.previous_y) > k_pos_eps)),
    eligible AS (
      SELECT t.id AS thing_id, t.type AS thing_type, d.kind,
             SQRT((t.x - p.px) * (t.x - p.px) + (t.y - p.py) * (t.y - p.py)) AS dist
        FROM params p
        JOIN g_things t ON t.map_id = p.map_id
        JOIN pickup_defs d ON d.thing_type = t.type
        JOIN g_player_state ps ON ps.map_id = p.map_id AND ps.player_thing_id = p.player_thing_id
       WHERE BITAND(t.flags, p.skill) <> 0 AND BITAND(t.flags, 16) = 0
         AND t.x BETWEEN p.px - (v_reach + 1d) AND p.px + (v_reach + 1d)
         AND t.y BETWEEN p.py - (v_reach + 1d) AND p.py + (v_reach + 1d)
         AND SQRT((t.x - p.px) * (t.x - p.px) + (t.y - p.py) * (t.y - p.py)) <= v_reach
         AND NOT EXISTS (SELECT 1 FROM g_picked_up_items pu WHERE pu.map_id = t.map_id AND pu.thing_id = t.id)
         AND (   (d.kind = 'health' AND (NOT d.only_when_below_cap OR ps.health < d.cap))
              OR (d.kind = 'armor' AND (NOT d.is_set_min OR ps.armor < d.amount))
              OR (d.kind IN ('bullets', 'shells', 'rockets', 'cells')
                  AND CASE d.kind WHEN 'bullets' THEN ps.ammo_bullets WHEN 'shells' THEN ps.ammo_shells
                                  WHEN 'rockets' THEN ps.ammo_rockets ELSE ps.ammo_cells END
                      < (SELECT CASE WHEN ps.backpack THEN ad.backpack_cap ELSE ad.cap END
                           FROM ammo_defs ad WHERE ad.ammo_type = d.kind))
              OR (d.kind = 'weapon' AND NOT EXISTS (
                    SELECT 1 FROM g_player_weapon_owned o WHERE o.map_id = p.map_id
                       AND o.player_thing_id = p.player_thing_id AND o.weapon_id = d.weapon_id))
              OR d.kind IN ('backpack', 'key_blue', 'key_yellow', 'key_red', 'radsuit', 'invis', 'lightamp',
                            'powermap', 'invuln'))),
    ranked AS (
      SELECT e.*, ROW_NUMBER() OVER (PARTITION BY e.kind ORDER BY e.dist, e.thing_id) AS rn FROM eligible e),
    selected_items AS (SELECT DISTINCT thing_id, thing_type FROM ranked WHERE rn = 1)
    SELECT p.map_id, p.player_thing_id, s.thing_id, d.kind,
           CASE WHEN d.kind IN ('bullets', 'shells', 'rockets', 'cells') THEN
                  NVL(CASE WHEN s.thing_id >= v_drop THEN d.dropped_amount END, d.amount)
                  * CASE WHEN p.skill_level IN (0, 4) THEN 2 ELSE 1 END
                WHEN d.kind = 'backpack' THEN CASE WHEN p.skill_level IN (0, 4) THEN 2 ELSE 1 END
                ELSE d.amount END,
           d.cap, d.is_set_min, d.weapon_id, d.armor_class
      FROM selected_items s JOIN pickup_defs d ON d.thing_type = s.thing_type CROSS JOIN params p;
    IF SQL%ROWCOUNT = 0 THEN RETURN; END IF;

    MERGE INTO g_player_state ps
    USING (
      SELECT MAX(CASE WHEN kind = 'health' AND is_set_min THEN amount END) AS health_min,
             SUM(CASE WHEN kind = 'health' AND NOT is_set_min THEN amount END) AS health_add,
             MIN(CASE WHEN kind = 'health' AND NOT is_set_min THEN cap END) AS health_cap,
             MAX(CASE WHEN kind = 'armor' AND is_set_min THEN amount END) AS armor_set,
             SUM(CASE WHEN kind = 'armor' AND NOT is_set_min THEN amount END) AS armor_add,
             MIN(CASE WHEN kind = 'armor' AND NOT is_set_min THEN cap END) AS armor_cap,
             MAX(CASE WHEN kind = 'armor' AND is_set_min THEN armor_class END) AS set_class,
             MAX(CASE WHEN kind = 'armor' AND NOT is_set_min THEN 1 ELSE 0 END) AS got_armor_bonus,
             MAX(CASE WHEN kind = 'backpack' THEN 1 ELSE 0 END) AS got_backpack,
             MAX(CASE WHEN kind = 'key_blue' THEN 1 ELSE 0 END) AS got_blue,
             MAX(CASE WHEN kind = 'key_yellow' THEN 1 ELSE 0 END) AS got_yellow,
             MAX(CASE WHEN kind = 'key_red' THEN 1 ELSE 0 END) AS got_red,
             MAX(CASE WHEN kind = 'radsuit' THEN amount END) AS got_radsuit,
             MAX(CASE WHEN kind = 'invis' THEN amount END) AS got_invis,
             MAX(CASE WHEN kind = 'lightamp' THEN amount END) AS got_lightamp,
             MAX(CASE WHEN kind = 'powermap' THEN amount END) AS got_powermap,
             MAX(CASE WHEN kind = 'invuln' THEN amount END) AS got_invuln,
             COUNT(*) AS taken, MIN(pm.message) AS message
        FROM g_pickup_touches pt
        LEFT JOIN g_things t ON t.map_id = pt.map_id AND t.id = pt.thing_id
        LEFT JOIN pickup_messages pm ON pm.thing_type = t.type
       WHERE pt.map_id = p_map AND pt.player_thing_id = p_player) s
    ON (ps.map_id = p_map AND ps.player_thing_id = p_player)
    WHEN MATCHED THEN UPDATE SET
      ps.bonus_count = LEAST(100, ps.bonus_count + v_bonus * s.taken),
      ps.health = CASE WHEN s.health_min IS NOT NULL THEN GREATEST(ps.health, s.health_min)
                       WHEN s.health_add IS NOT NULL THEN LEAST(s.health_cap, ps.health + s.health_add)
                       ELSE ps.health END,
      ps.armor = CASE WHEN s.armor_set IS NOT NULL THEN s.armor_set
                      WHEN s.armor_add IS NOT NULL THEN LEAST(s.armor_cap, ps.armor + s.armor_add)
                      ELSE ps.armor END,
      ps.armor_class = CASE WHEN s.set_class IS NOT NULL THEN s.set_class
                            WHEN s.got_armor_bonus = 1 AND ps.armor_class = 0 THEN 1 ELSE ps.armor_class END,
      ps.backpack = CASE WHEN ps.backpack OR s.got_backpack = 1 THEN TRUE ELSE FALSE END,
      ps.key_blue = CASE WHEN ps.key_blue OR s.got_blue = 1 THEN TRUE ELSE FALSE END,
      ps.key_yellow = CASE WHEN ps.key_yellow OR s.got_yellow = 1 THEN TRUE ELSE FALSE END,
      ps.key_red = CASE WHEN ps.key_red OR s.got_red = 1 THEN TRUE ELSE FALSE END,
      ps.radsuit_tics = GREATEST(ps.radsuit_tics, NVL(s.got_radsuit, 0)),
      ps.invis_tics = GREATEST(ps.invis_tics, NVL(s.got_invis, 0)),
      ps.light_amp_tics = GREATEST(ps.light_amp_tics, NVL(s.got_lightamp, 0)),
      ps.power_map = CASE WHEN ps.power_map OR NVL(s.got_powermap, 0) > 0 THEN TRUE ELSE FALSE END,
      ps.invuln_tics = GREATEST(ps.invuln_tics, NVL(s.got_invuln, 0)),
      ps.message = NVL(s.message, ps.message),
      ps.message_tics = CASE WHEN s.message IS NOT NULL THEN v_msgt ELSE ps.message_tics END;

    SELECT MAX(CASE WHEN ad.ammo_type = 'bullets' THEN LEAST(CASE WHEN ps.backpack THEN ad.backpack_cap ELSE ad.cap END, ps.ammo_bullets + g.amount) END),
           MAX(CASE WHEN ad.ammo_type = 'shells' THEN LEAST(CASE WHEN ps.backpack THEN ad.backpack_cap ELSE ad.cap END, ps.ammo_shells + g.amount) END),
           MAX(CASE WHEN ad.ammo_type = 'rockets' THEN LEAST(CASE WHEN ps.backpack THEN ad.backpack_cap ELSE ad.cap END, ps.ammo_rockets + g.amount) END),
           MAX(CASE WHEN ad.ammo_type = 'cells' THEN LEAST(CASE WHEN ps.backpack THEN ad.backpack_cap ELSE ad.cap END, ps.ammo_cells + g.amount) END)
      INTO v_bul, v_she, v_roc, v_cel
      FROM ammo_defs ad
      JOIN g_player_state ps ON ps.map_id = p_map AND ps.player_thing_id = p_player
      JOIN (SELECT ad2.ammo_type,
                   SUM(CASE WHEN pt.kind = ad2.ammo_type THEN pt.amount
                            WHEN pt.kind = 'backpack' THEN ad2.backpack_gives * pt.amount END) AS amount
              FROM ammo_defs ad2
              LEFT JOIN g_pickup_touches pt ON pt.map_id = p_map AND pt.player_thing_id = p_player
             GROUP BY ad2.ammo_type) g ON g.ammo_type = ad.ammo_type;
    UPDATE g_player_state
       SET ammo_bullets = NVL(v_bul, ammo_bullets), ammo_shells = NVL(v_she, ammo_shells),
           ammo_rockets = NVL(v_roc, ammo_rockets), ammo_cells = NVL(v_cel, ammo_cells)
     WHERE map_id = p_map AND player_thing_id = p_player;

    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_picked_up_items g_picked_up_items_pk) */ INTO g_picked_up_items (map_id, thing_id)
    SELECT DISTINCT map_id, thing_id FROM g_pickup_touches WHERE map_id = p_map AND player_thing_id = p_player;
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_pickup_grants g_pickup_grants_pk) */ INTO g_pickup_grants (map_id, player_thing_id, weapon_id)
    SELECT DISTINCT pt.map_id, pt.player_thing_id, pt.weapon_id FROM g_pickup_touches pt
     WHERE pt.map_id = p_map AND pt.player_thing_id = p_player AND pt.kind = 'weapon'
       AND NOT EXISTS (SELECT 1 FROM g_player_weapon_owned o WHERE o.map_id = pt.map_id
                         AND o.player_thing_id = pt.player_thing_id AND o.weapon_id = pt.weapon_id);
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_player_weapon_owned g_player_weapon_owned_pk) */
      INTO g_player_weapon_owned (map_id, player_thing_id, weapon_id)
    SELECT map_id, player_thing_id, weapon_id FROM g_pickup_grants WHERE map_id = p_map AND player_thing_id = p_player;
  END;

  -- =====================================================================
  -- doom_cs_weapon (03_weapon_decision.sql, 20, 21): psprite state machine
  -- =====================================================================
  FUNCTION cs_weapon(p_map NUMBER, p_player NUMBER) RETURN NUMBER IS
    attack BOOLEAN; sw NUMBER; bob BINARY_DOUBLE; lt NUMBER;
    cur NUMBER; pend NUMBER; st VARCHAR2(8); seq NUMBER; tics NUMBER; fseq NUMBER; ftics NUMBER;
    sx BINARY_FLOAT; sy BINARY_FLOAT; serial NUMBER; atype VARCHAR2(16); aper NUMBER; ammo NUMBER;
    ready_t NUMBER; fire0_t NUMBER; fire0_a BOOLEAN; next_s NUMBER; next_t NUMBER; next_a BOOLEAN; next_r BOOLEAN;
    flash0_t NUMBER; fnext_s NUMBER; fnext_t NUMBER; owned NUMBER;
    has_ammo BOOLEAN; switch_req BOOLEAN; advancing BOOLEAN; falls_off BOOLEAN; refires BOOLEAN;
    starts_fire BOOLEAN; down_done BOOLEAN; up_done BOOLEAN; flash_adv BOOLEAN; fires BOOLEAN;
    n_state VARCHAR2(8); n_seq NUMBER; n_tics NUMBER; n_cur NUMBER; n_pend NUMBER; n_sx BINARY_DOUBLE; n_sy BINARY_DOUBLE;
    n_fseq NUMBER; n_ftics NUMBER; v_atype VARCHAR2(16); v_aper NUMBER; v_shot NUMBER;
  BEGIN
    SELECT g.attack_held,
           NVL(g.weapon_switch_to, (SELECT MIN(pg.weapon_id) FROM g_pickup_grants pg
                                     WHERE pg.map_id = g.map_id AND pg.player_thing_id = g.player_thing_id)),
           ps.bob_strength, ps.level_tics,
           pw.current_weapon, pw.pending_weapon, pw.state, pw.seq_index, pw.tics, pw.flash_seq_index, pw.flash_tics,
           pw.sx, pw.sy, pw.shot_serial, wd.ammo_type, wd.ammo_per_shot,
           CASE wd.ammo_type WHEN 'bullets' THEN ps.ammo_bullets WHEN 'shells' THEN ps.ammo_shells
                             WHEN 'rockets' THEN ps.ammo_rockets WHEN 'cells' THEN ps.ammo_cells ELSE 999999 END,
           ready0.tics, fire0.tics, fire0.is_attack_frame, nextf.seq_index, nextf.tics, nextf.is_attack_frame,
           nextf.refire_check, flash0.tics, flashnext.seq_index, flashnext.tics
      INTO attack, sw, bob, lt, cur, pend, st, seq, tics, fseq, ftics, sx, sy, serial, atype, aper, ammo,
           ready_t, fire0_t, fire0_a, next_s, next_t, next_a, next_r, flash0_t, fnext_s, fnext_t
      FROM g_game_tic_commands g
      JOIN g_player_state ps ON ps.map_id = g.map_id AND ps.player_thing_id = g.player_thing_id
      JOIN g_player_weapons pw ON pw.map_id = g.map_id AND pw.player_thing_id = g.player_thing_id
      JOIN weapon_defs wd ON wd.weapon_id = pw.current_weapon
      LEFT JOIN weapon_frames ready0 ON ready0.weapon_id = pw.current_weapon AND ready0.state = 'ready' AND ready0.seq_index = 0
      LEFT JOIN weapon_frames fire0 ON fire0.weapon_id = pw.current_weapon AND fire0.state = 'fire' AND fire0.seq_index = 0
      LEFT JOIN weapon_frames nextf ON nextf.weapon_id = pw.current_weapon AND nextf.state = 'fire' AND nextf.seq_index = pw.seq_index + 1
      LEFT JOIN weapon_frames flash0 ON flash0.weapon_id = pw.current_weapon AND flash0.state = 'flash' AND flash0.seq_index = 0
      LEFT JOIN weapon_frames flashnext ON flashnext.weapon_id = pw.current_weapon AND flashnext.state = 'flash'
             AND flashnext.seq_index = pw.flash_seq_index + 1
     WHERE g.map_id = p_map AND g.player_thing_id = p_player;
    has_ammo := ammo >= aper;
    owned := 0;
    IF sw IS NOT NULL AND sw <> cur THEN
      SELECT COUNT(*) INTO owned FROM g_player_weapon_owned WHERE map_id = p_map AND player_thing_id = p_player AND weapon_id = sw;
    END IF;
    switch_req := sw IS NOT NULL AND sw <> cur AND owned > 0;
    advancing := st = 'fire' AND tics <= 1;
    falls_off := advancing AND next_s IS NULL;
    refires := advancing AND next_s IS NOT NULL AND NVL(next_r, FALSE) AND attack AND has_ammo;
    starts_fire := st = 'ready' AND attack AND has_ammo AND NOT switch_req;
    down_done := st = 'down' AND sy + 6 >= 128;
    up_done := st = 'up' AND sy - 6 <= 32;
    flash_adv := fseq IS NOT NULL AND ftics <= 1;
    -- n_state
    IF switch_req THEN n_state := 'down';
    ELSIF st = 'down' THEN n_state := CASE WHEN down_done THEN 'up' ELSE 'down' END;
    ELSIF st = 'up' THEN n_state := CASE WHEN up_done THEN 'ready' ELSE 'up' END;
    ELSIF st = 'ready' THEN n_state := CASE WHEN starts_fire THEN 'fire' ELSE 'ready' END;
    ELSIF st = 'fire' AND advancing AND falls_off THEN n_state := 'ready';
    ELSE n_state := st; END IF;
    -- n_seq
    IF switch_req THEN n_seq := seq;
    ELSIF st = 'up' AND up_done THEN n_seq := 0;
    ELSIF st = 'ready' THEN n_seq := 0;
    ELSIF st = 'fire' AND advancing THEN n_seq := CASE WHEN falls_off OR refires THEN 0 ELSE next_s END;
    ELSE n_seq := seq; END IF;
    -- n_tics
    IF switch_req THEN n_tics := tics;
    ELSIF st = 'up' THEN n_tics := CASE WHEN up_done THEN ready_t ELSE tics END;
    ELSIF st = 'ready' THEN n_tics := CASE WHEN starts_fire THEN fire0_t ELSE tics END;
    ELSIF st = 'fire' AND advancing THEN
      n_tics := CASE WHEN falls_off THEN ready_t WHEN refires THEN fire0_t ELSE next_t END;
    ELSIF st = 'fire' THEN n_tics := tics - 1;
    ELSE n_tics := tics; END IF;
    fires := (st = 'ready' AND starts_fire AND NVL(fire0_a, FALSE))
          OR (st = 'fire' AND advancing AND NOT falls_off AND NOT refires AND NVL(next_a, FALSE))
          OR (st = 'fire' AND advancing AND refires AND NVL(fire0_a, FALSE));
    n_cur := CASE WHEN st = 'down' AND down_done AND NOT switch_req THEN pend ELSE cur END;
    IF switch_req THEN n_pend := sw;
    ELSIF st = 'down' AND down_done THEN n_pend := NULL;
    ELSE n_pend := pend; END IF;
    IF n_state = 'ready' THEN
      n_sx := 1d + bob * COS(2d * c_pi * MOD(lt, 64) / 64d);
      n_sy := 32d + bob * SIN(2d * c_pi * MOD(lt, 32) / 64d);
    ELSE
      n_sx := sx;
      IF n_state = 'down' THEN n_sy := LEAST(128, sy + 6);
      ELSIF n_state = 'up' THEN n_sy := GREATEST(32, sy - 6);
      ELSE n_sy := sy; END IF;
    END IF;
    IF fires THEN n_fseq := CASE WHEN flash0_t IS NOT NULL THEN 0 END; n_ftics := NVL(flash0_t, 0);
    ELSIF fseq IS NULL THEN n_fseq := NULL; n_ftics := 0;
    ELSIF NOT flash_adv THEN n_fseq := fseq; n_ftics := ftics - 1;
    ELSE n_fseq := fnext_s; n_ftics := NVL(fnext_t, 0); END IF;
    v_shot := serial + CASE WHEN fires THEN 1 ELSE 0 END;
    UPDATE g_player_weapons
       SET state = n_state, seq_index = n_seq, tics = n_tics, current_weapon = n_cur, pending_weapon = n_pend,
           flash_seq_index = n_fseq, flash_tics = n_ftics, sx = n_sx, sy = n_sy, shot_serial = v_shot,
           fired_this_tick = fires
     WHERE map_id = p_map AND player_thing_id = p_player;
    IF fires THEN
      SELECT ammo_type, ammo_per_shot INTO v_atype, v_aper FROM weapon_defs WHERE weapon_id = n_cur;
      UPDATE g_player_state
         SET ammo_bullets = ammo_bullets - CASE WHEN v_atype = 'bullets' THEN v_aper ELSE 0 END,
             ammo_shells  = ammo_shells  - CASE WHEN v_atype = 'shells'  THEN v_aper ELSE 0 END,
             ammo_rockets = ammo_rockets - CASE WHEN v_atype = 'rockets' THEN v_aper ELSE 0 END,
             ammo_cells   = ammo_cells   - CASE WHEN v_atype = 'cells'   THEN v_aper ELSE 0 END
       WHERE map_id = p_map AND player_thing_id = p_player;
    END IF;
    UPDATE g_world_effects SET age = age + 1 WHERE map_id = p_map;
    IF SQL%ROWCOUNT > 0 THEN
      DELETE FROM g_world_effects
       WHERE map_id = p_map
         AND age >= CASE WHEN effect_type = 'blood' THEN 24 WHEN effect_type = 'bfg_spray' THEN 32
                         WHEN effect_type = 'ifog' THEN 30 WHEN effect_type = 'tfog' THEN 72 ELSE 16 END;
    END IF;
    RETURN v_shot;
  END;

  -- =====================================================================
  -- doom_cs_hitscan_fire (22): P_BulletSlope + P_GunShot per pellet
  -- =====================================================================
  FUNCTION cs_hitscan_fire(p_map NUMBER, p_player NUMBER) RETURN NUMBER IS
    va BINARY_DOUBLE; shoot_z BINARY_DOUBLE; serial NUMBER; npel NUMBER; maxr BINARY_DOUBLE; ddc NUMBER; ddm NUMBER;
    px BINARY_DOUBLE; py BINARY_DOUBLE; ang_f BINARY_FLOAT; basez_f BINARY_FLOAT;
    t_id t_num; t_x t_dbl; t_y t_dbl; t_r t_dbl; t_bz t_dbl; t_h t_dbl; t_sec t_num; t_nb t_bool;
    -- aim candidates
    c_pri t_int; c_tid t_num; c_dist t_dbl; c_ang t_dbl; c_idx t_int; nc PLS_INTEGER := 0;
    ra BINARY_DOUBLE; ca BINARY_DOUBLE; sa BINARY_DOUBLE; along BINARY_DOUBLE; perp BINARY_DOUBLE; perp2 BINARY_DOUBLE;
    dist BINARY_DOUBLE; best PLS_INTEGER; tmp PLS_INTEGER; swp BOOLEAN;
    slope BINARY_DOUBLE := 0d; solid BOOLEAN; maxb BINARY_DOUBLE; mint BINARY_DOUBLE; den BINARY_DOUBLE;
    rt BINARY_DOUBLE; lu BINARY_DOUBLE; ob BINARY_DOUBLE; ot BINARY_DOUBLE; f PLS_INTEGER; b PLS_INTEGER;
    bslope BINARY_DOUBLE; tslope BINARY_DOUBLE; ttop BINARY_DOUBLE; tbot BINARY_DOUBLE; v BINARY_DOUBLE;
    r1 NUMBER; r2 NUMBER; dmg NUMBER; pang BINARY_DOUBLE; z BINARY_DOUBLE;
    h_kind PLS_INTEGER; h_dist BINARY_DOUBLE; h_tid NUMBER; h_lid NUMBER; h_sec NUMBER; h_nb BOOLEAN; h_ff BOOLEAN;
    better BOOLEAN; nimp NUMBER := 0;
    v_aims BINARY_DOUBLE := k('AIM_SPREAD_DEGREES');
    v_auto BINARY_DOUBLE := k('AUTOAIM_SLOPE');
    v_unb BINARY_DOUBLE := k('SLOPE_UNBOUNDED');
    v_spread BINARY_DOUBLE := k('GUNSHOT_SPREAD_UNITS');
  BEGIN
    BEGIN
      SELECT t.angle, ps.base_z, pw.shot_serial, wd.pellet_count, wd.max_range, wd.dmg_dice_count, wd.dmg_dice_mult,
             t.x, t.y
        INTO ang_f, basez_f, serial, npel, maxr, ddc, ddm, px, py
        FROM g_player_weapons pw
        JOIN weapon_defs wd ON wd.weapon_id = pw.current_weapon
        JOIN g_things t ON t.map_id = pw.map_id AND t.id = pw.player_thing_id
        JOIN g_player_state ps ON ps.map_id = pw.map_id AND ps.player_thing_id = pw.player_thing_id
       WHERE pw.map_id = p_map AND pw.player_thing_id = p_player AND pw.fired_this_tick AND wd.pellet_count > 0;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN 0;
    END;
    va := TO_BINARY_DOUBLE(ang_f) * c_rad;
    shoot_z := TO_BINARY_DOUBLE(basez_f) - k_viewheight + k_player_height / 2d + k('ATTACK_Z_OFFSET');
    -- targets: live actors (their render sector's floor) plus other live players
    SELECT t.id, t.x, t.y, d.radius, s.floor_height, rt2.thing_height, rt2.sector_id, d.no_blood
      BULK COLLECT INTO t_id, t_x, t_y, t_r, t_bz, t_h, t_sec, t_nb
      FROM g_thing_health h
      JOIN g_things t ON t.map_id = h.map_id AND t.id = h.thing_id
      JOIN thing_combat_defs d ON d.thing_type = t.type
      JOIN g_render_things rt2 ON rt2.map_id = t.map_id AND rt2.thing_id = t.id
      JOIN g_sectors s ON s.map_id = rt2.map_id AND s.id = rt2.sector_id
     WHERE h.map_id = p_map AND h.alive
    UNION ALL
    SELECT ps.player_thing_id, t.x, t.y, k_player_radius, ps.base_z - k_viewheight, k_player_height, ps.sector_id, FALSE
      FROM g_player_state ps JOIN g_things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
     WHERE ps.map_id = p_map AND ps.player_thing_id <> p_player AND ps.alive;
    load_sectors(p_map);
    -- aim rays (priority 0: straight, 1: +spread, 2: -spread)
    FOR pri IN 0 .. 2 LOOP
      ra := CASE pri WHEN 0 THEN 0d WHEN 1 THEN v_aims * c_rad ELSE (-v_aims) * c_rad END;
      ca := COS(va + ra); sa := SIN(va + ra);
      FOR i IN 1 .. t_id.COUNT LOOP
        along := (t_x(i) - px) * ca + (t_y(i) - py) * sa;
        perp := -(t_x(i) - px) * sa + (t_y(i) - py) * ca;
        perp2 := perp * perp;
        IF along > 0 AND along <= maxr + t_r(i) AND perp2 <= t_r(i) * t_r(i) THEN
          dist := along - SQRT(GREATEST(0d, t_r(i) * t_r(i) - perp2));
          IF dist > 0 AND dist <= maxr THEN
            nc := nc + 1; c_pri(nc) := pri; c_tid(nc) := t_id(i); c_dist(nc) := dist; c_ang(nc) := ra; c_idx(nc) := i;
          END IF;
        END IF;
      END LOOP;
    END LOOP;
    -- order by (priority, distance, thing_id) and take the first visible
    FOR i IN 2 .. nc LOOP
      FOR j IN REVERSE 2 .. i LOOP
        swp := c_pri(j) < c_pri(j - 1)
               OR (c_pri(j) = c_pri(j - 1) AND (c_dist(j) < c_dist(j - 1)
                   OR (c_dist(j) = c_dist(j - 1) AND c_tid(j) < c_tid(j - 1))));
        EXIT WHEN NOT swp;
        tmp := c_pri(j); c_pri(j) := c_pri(j - 1); c_pri(j - 1) := tmp;
        v := c_dist(j); c_dist(j) := c_dist(j - 1); c_dist(j - 1) := v;
        v := c_ang(j); c_ang(j) := c_ang(j - 1); c_ang(j - 1) := v;
        tmp := c_idx(j); c_idx(j) := c_idx(j - 1); c_idx(j - 1) := tmp;
        dmg := c_tid(j); c_tid(j) := c_tid(j - 1); c_tid(j - 1) := dmg;
      END LOOP;
    END LOOP;
    FOR c IN 1 .. nc LOOP
      ca := COS(va + c_ang(c)); sa := SIN(va + c_ang(c));
      solid := FALSE; maxb := NULL; mint := NULL;
      FOR li IN 0 .. l_n - 1 LOOP
        den := ca * (l_y2(li) - l_y1(li)) - sa * (l_x2(li) - l_x1(li));
        IF den <> 0 THEN
          rt := ((l_x1(li) - px) * (l_y2(li) - l_y1(li)) - (l_y1(li) - py) * (l_x2(li) - l_x1(li))) / den;
          IF rt > 0 AND rt < c_dist(c) THEN
            lu := ((l_x1(li) - px) * sa - (l_y1(li) - py) * ca) / den;
            IF lu >= 0 AND lu <= 1 THEN
              f := l_fsec(li); b := l_bsec(li);
              IF f = -1 OR b = -1 THEN solid := TRUE;
              ELSE
                ob := GREATEST(s_fl(f), s_fl(b)); ot := LEAST(s_ce(f), s_ce(b));
                IF ob >= ot THEN solid := TRUE; END IF;
                IF s_fl(f) <> s_fl(b) THEN
                  v := (ob - shoot_z) / rt;
                  IF maxb IS NULL OR v > maxb THEN maxb := v; END IF;
                END IF;
                IF s_ce(f) <> s_ce(b) THEN
                  v := (ot - shoot_z) / rt;
                  IF mint IS NULL OR v < mint THEN mint := v; END IF;
                END IF;
              END IF;
            END IF;
          END IF;
        END IF;
      END LOOP;
      bslope := GREATEST(-v_auto, NVL(maxb, -v_unb));
      tslope := LEAST(v_auto, NVL(mint, v_unb));
      ttop := (t_bz(c_idx(c)) + t_h(c_idx(c)) - shoot_z) / c_dist(c);
      tbot := (t_bz(c_idx(c)) - shoot_z) / c_dist(c);
      IF NOT solid AND tslope > bslope AND ttop >= bslope AND tbot <= tslope THEN
        slope := (LEAST(ttop, tslope) + GREATEST(tbot, bslope)) / 2d;
        EXIT;
      END IF;
    END LOOP;
    DELETE FROM g_hitscan_hits WHERE map_id = p_map AND player_thing_id = p_player AND shot_serial = serial;
    -- pellets
    FOR pel IN 0 .. npel - 1 LOOP
      r1 := prandom(serial, pel, 2); r2 := prandom(serial, pel, 3);
      dmg := ddm * (MOD(prandom(serial, pel, 4), ddc) + 1);
      pang := va + ((r1 - r2) * 360 / v_spread) * c_rad;
      ca := COS(pang); sa := SIN(pang);
      h_kind := -1;
      FOR i IN 1 .. t_id.COUNT LOOP
        along := (t_x(i) - px) * ca + (t_y(i) - py) * sa;
        perp := -(t_x(i) - px) * sa + (t_y(i) - py) * ca;
        perp2 := perp * perp;
        IF along > 0 AND perp2 <= t_r(i) * t_r(i) THEN
          dist := along - SQRT(GREATEST(0d, t_r(i) * t_r(i) - perp2));
          IF dist > 0 AND dist <= maxr THEN
            z := shoot_z + slope * dist;
            IF z >= t_bz(i) AND z <= t_bz(i) + t_h(i) THEN
              better := h_kind = -1 OR dist < h_dist OR (dist = h_dist AND (h_kind = 1 OR t_id(i) < h_tid));
              IF better THEN
                h_kind := 0; h_dist := dist; h_tid := t_id(i); h_lid := NULL; h_sec := t_sec(i); h_nb := t_nb(i); h_ff := NULL;
              END IF;
            END IF;
          END IF;
        END IF;
      END LOOP;
      FOR li IN 0 .. l_n - 1 LOOP
        den := ca * (l_y2(li) - l_y1(li)) - sa * (l_x2(li) - l_x1(li));
        IF den <> 0 THEN
          dist := ((l_x1(li) - px) * (l_y2(li) - l_y1(li)) - (l_y1(li) - py) * (l_x2(li) - l_x1(li))) / den;
          IF dist > 0 AND dist <= maxr AND (h_kind = -1 OR dist <= h_dist) THEN
            lu := ((l_x1(li) - px) * sa - (l_y1(li) - py) * ca) / den;
            IF lu >= 0 AND lu <= 1 THEN
              f := l_fsec(li); b := l_bsec(li);
              z := shoot_z + slope * dist;
              IF f = -1 OR b = -1 THEN solid := TRUE;
              ELSE
                ob := GREATEST(s_fl(f), s_fl(b)); ot := LEAST(s_ce(f), s_ce(b));
                solid := z <= ob OR z >= ot;
              END IF;
              IF solid THEN
                better := h_kind = -1 OR dist < h_dist OR (dist = h_dist AND h_kind = 1 AND li < h_lid);
                IF better THEN
                  h_kind := 1; h_dist := dist; h_tid := NULL; h_lid := li;
                  h_sec := CASE WHEN f <> -1 THEN f WHEN b <> -1 THEN b END; h_nb := TRUE;
                  h_ff := ((l_x2(li) - l_x1(li)) * (py - l_y1(li)) - (l_y2(li) - l_y1(li)) * (px - l_x1(li))) < 0;
                END IF;
              END IF;
            END IF;
          END IF;
        END IF;
      END LOOP;
      IF h_kind >= 0 THEN
        INSERT INTO g_hitscan_hits (map_id, player_thing_id, shot_serial, pellet, damage, thing_id, sector_id, no_blood,
                                    distance, angle, slope, hit_kind, px, py, shoot_z, line_id, line_from_front)
        VALUES (p_map, p_player, serial, pel, dmg, h_tid, h_sec, h_nb, h_dist, pang, slope,
                CASE WHEN h_kind = 0 THEN 'target' ELSE 'wall' END, px, py, shoot_z, h_lid, h_ff);
        nimp := nimp + 1;
      END IF;
    END LOOP;
    RETURN nimp;
  END;

  -- doom_cs_hitscan_apply (23)
  PROCEDURE cs_hitscan_apply(p_map NUMBER, p_player NUMBER, p_shot NUMBER) IS
    v_drop NUMBER := k('DROPPED_THING_ID_BASE');
  BEGIN
    MERGE INTO g_thing_health h
    USING (SELECT thing_id, SUM(damage) AS damage FROM g_hitscan_hits
            WHERE map_id = p_map AND player_thing_id = p_player AND shot_serial = p_shot AND hit_kind = 'target'
            GROUP BY thing_id) d
       ON (h.map_id = p_map AND h.thing_id = d.thing_id)
     WHEN MATCHED THEN UPDATE SET h.health = h.health - d.damage,
                                  h.alive = CASE WHEN h.health - d.damage > 0 THEN TRUE ELSE FALSE END;
    -- pellets that hit another player (deathmatch)
    MERGE INTO g_player_state ps
    USING (
      WITH hits AS (
        SELECT hh.thing_id AS victim_id, SUM(hh.damage) AS raw_dmg,
               TO_BINARY_DOUBLE(MAX(hh.px)) AS sx, TO_BINARY_DOUBLE(MAX(hh.py)) AS sy
          FROM g_hitscan_hits hh
          JOIN g_player_state v ON v.map_id = hh.map_id AND v.player_thing_id = hh.thing_id
         WHERE hh.map_id = p_map AND hh.player_thing_id = p_player AND hh.shot_serial = p_shot
           AND hh.hit_kind = 'target' AND hh.damage > 0
         GROUP BY hh.thing_id),
      scaled AS (
        SELECT h.victim_id, h.sx, h.sy, TRUNC(h.raw_dmg / CASE WHEN g.skill = 0 THEN 2 ELSE 1 END) AS dmg,
               v.armor, v.armor_class, CASE WHEN v.god_mode OR v.invuln_tics > 0 THEN 1 ELSE 0 END AS blocked,
               TO_BINARY_DOUBLE(vt.x) AS vx, TO_BINARY_DOUBLE(vt.y) AS vy, pw.current_weapon
          FROM hits h
          JOIN g_player_state v ON v.map_id = p_map AND v.player_thing_id = h.victim_id
          JOIN g_game_tic_commands g ON g.map_id = v.map_id AND g.player_thing_id = v.player_thing_id
          JOIN g_things vt ON vt.map_id = v.map_id AND vt.id = v.player_thing_id
          JOIN g_player_weapons pw ON pw.map_id = p_map AND pw.player_thing_id = p_player),
      sd AS (SELECT sc.*, SQRT((sc.vx - sc.sx) * (sc.vx - sc.sx) + (sc.vy - sc.sy) * (sc.vy - sc.sy)) AS dist FROM scaled sc)
      SELECT s.victim_id, s.blocked, s.dmg,
             CASE WHEN s.blocked = 1 THEN 0
                  ELSE LEAST(s.armor, CASE s.armor_class WHEN 2 THEN FLOOR(s.dmg / 2) WHEN 1 THEN FLOOR(s.dmg / 3) ELSE 0 END)
             END AS saved,
             CASE WHEN s.current_weapon = 8 OR s.dist = 0 THEN 0d ELSE s.dmg * 0.125d * (s.vx - s.sx) / s.dist END AS thrust_x,
             CASE WHEN s.current_weapon = 8 OR s.dist = 0 THEN 0d ELSE s.dmg * 0.125d * (s.vy - s.sy) / s.dist END AS thrust_y
        FROM sd s) a
    ON (ps.map_id = p_map AND ps.player_thing_id = a.victim_id)
    WHEN MATCHED THEN UPDATE SET
      ps.armor = ps.armor - a.saved,
      ps.armor_class = CASE WHEN ps.armor - a.saved <= 0 THEN 0 ELSE ps.armor_class END,
      ps.health = GREATEST(0, ps.health - CASE WHEN a.blocked = 1 THEN 0 ELSE a.dmg - a.saved END),
      ps.damage_count = LEAST(100, ps.damage_count + CASE WHEN a.blocked = 1 THEN 0 ELSE a.dmg - a.saved END),
      ps.alive = CASE WHEN GREATEST(0, ps.health - CASE WHEN a.blocked = 1 THEN 0 ELSE a.dmg - a.saved END) > 0
                      THEN TRUE ELSE FALSE END,
      ps.pain_face_tics = CASE WHEN a.blocked = 0 AND a.dmg - a.saved > 0 THEN 12 ELSE ps.pain_face_tics END,
      ps.killer_id = CASE WHEN ps.alive AND a.blocked = 0 AND ps.health - (a.dmg - a.saved) <= 0
                          THEN p_player ELSE ps.killer_id END,
      ps.momentum_x = ps.momentum_x + a.thrust_x,
      ps.momentum_y = ps.momentum_y + a.thrust_y;
    -- P_DamageMobj's thrust for bullets (not the chainsaw)
    MERGE INTO g_things t
    USING (SELECT hh.thing_id,
                  SUM(hh.damage) * 12.5 / GREATEST(1, cd.mass) AS push,
                  TO_BINARY_DOUBLE(v.x - pt.x) AS dx, TO_BINARY_DOUBLE(v.y - pt.y) AS dy,
                  TO_BINARY_DOUBLE(NULLIF(SQRT((v.x - pt.x) * (v.x - pt.x) + (v.y - pt.y) * (v.y - pt.y)), 0)) AS dist
             FROM g_hitscan_hits hh
             JOIN g_things v ON v.map_id = hh.map_id AND v.id = hh.thing_id
             JOIN thing_combat_defs cd ON cd.thing_type = v.type
             JOIN g_things pt ON pt.map_id = hh.map_id AND pt.id = p_player
             JOIN g_player_weapons pw ON pw.map_id = hh.map_id AND pw.player_thing_id = p_player
            WHERE hh.map_id = p_map AND hh.player_thing_id = p_player AND hh.shot_serial = p_shot
              AND hh.hit_kind = 'target' AND hh.damage > 0 AND pw.current_weapon <> 8
              AND NOT EXISTS (SELECT 1 FROM g_player_state ps WHERE ps.map_id = hh.map_id AND ps.player_thing_id = hh.thing_id)
            GROUP BY hh.thing_id, cd.mass, v.x, v.y, pt.x, pt.y) s
       ON (t.map_id = p_map AND t.id = s.thing_id)
     WHEN MATCHED THEN UPDATE SET t.mom_x = t.mom_x + TO_BINARY_DOUBLE(s.push) * s.dx / s.dist,
                                  t.mom_y = t.mom_y + TO_BINARY_DOUBLE(s.push) * s.dy / s.dist
      WHERE s.dist IS NOT NULL;
    -- pain rolls: any damaging pellet's successful roll puts a survivor into pain; a miss still alerts
    MERGE INTO g_monster_ai ai
    USING (SELECT hit.thing_id, hit.flinches, fp.tics AS pain_tics, fs.tics AS see_tics
             FROM (SELECT hh.thing_id, t.type,
                          MAX(CASE WHEN doom_game.prandom(hh.thing_id, p_shot, 1) < cd.pain_chance THEN 1 ELSE 0 END) AS flinches
                     FROM g_hitscan_hits hh
                     JOIN g_things t ON t.map_id = hh.map_id AND t.id = hh.thing_id
                     JOIN thing_combat_defs cd ON cd.thing_type = t.type
                    WHERE hh.map_id = p_map AND hh.player_thing_id = p_player AND hh.shot_serial = p_shot
                      AND hh.hit_kind = 'target' AND hh.damage > 0
                    GROUP BY hh.thing_id, t.type) hit
             JOIN g_thing_health h ON h.map_id = p_map AND h.thing_id = hit.thing_id
             LEFT JOIN thing_ai_frames fp ON fp.thing_type = hit.type AND fp.state = 'pain' AND fp.seq_index = 0
             LEFT JOIN thing_ai_frames fs ON fs.thing_type = hit.type AND fs.state = 'see' AND fs.seq_index = 0
            WHERE h.alive
              AND NOT EXISTS (SELECT 1 FROM thing_combat_defs bd WHERE bd.thing_type = hit.type AND bd.explodes)) hit
       ON (ai.map_id = p_map AND ai.thing_id = hit.thing_id)
     WHEN MATCHED THEN UPDATE SET
       ai.state = CASE WHEN hit.flinches = 1 THEN 'pain' ELSE 'see' END,
       ai.seq_index = CASE WHEN hit.flinches = 1 THEN 0 ELSE ai.seq_index END,
       ai.state_tics = CASE WHEN hit.flinches = 1 THEN NVL(hit.pain_tics, ai.state_tics) ELSE NVL(hit.see_tics, ai.state_tics) END
      WHERE ai.state NOT IN ('die', 'dead') AND (hit.flinches = 1 OR ai.state = 'stand');
    -- puffs and blood
    MERGE INTO g_world_effects w
    USING (SELECT map_id, shot_serial * 16 + pellet AS effect_id,
                  CASE WHEN hit_kind = 'target' AND NOT no_blood THEN 'blood' ELSE 'puff' END AS effect_type,
                  px + GREATEST(0d, TO_BINARY_DOUBLE(distance - CASE WHEN hit_kind = 'target' THEN 10 ELSE 4 END)) * COS(angle) AS x,
                  py + GREATEST(0d, TO_BINARY_DOUBLE(distance - CASE WHEN hit_kind = 'target' THEN 10 ELSE 4 END)) * SIN(angle) AS y,
                  shoot_z + slope * GREATEST(0d, TO_BINARY_DOUBLE(distance - CASE WHEN hit_kind = 'target' THEN 10 ELSE 4 END)) AS z,
                  sector_id
             FROM g_hitscan_hits
            WHERE map_id = p_map AND player_thing_id = p_player AND shot_serial = p_shot) q
       ON (w.map_id = q.map_id AND w.effect_id = q.effect_id)
     WHEN MATCHED THEN UPDATE SET w.effect_type = q.effect_type, w.x = q.x, w.y = q.y, w.z = q.z,
                                  w.sector_id = q.sector_id, w.age = 0
     WHEN NOT MATCHED THEN INSERT (map_id, effect_id, effect_type, x, y, z, sector_id, age)
       VALUES (q.map_id, q.effect_id, q.effect_type, q.x, q.y, q.z, q.sector_id, 0);
    -- drops of the monsters that just died
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_things g_things_pk) */
      INTO g_things (map_id, id, x, y, angle, spawn_x, spawn_y, spawn_angle, type, flags)
    SELECT t.map_id, v_drop + t.id, t.x, t.y, t.angle, ROUND(TO_BINARY_DOUBLE(t.x)), ROUND(TO_BINARY_DOUBLE(t.y)),
           ROUND(TO_BINARY_DOUBLE(t.angle)), cd.drops_thing_type, 7
      FROM (SELECT DISTINCT hh.map_id, hh.thing_id FROM g_hitscan_hits hh
              JOIN g_thing_health th ON th.map_id = hh.map_id AND th.thing_id = hh.thing_id
             WHERE hh.map_id = p_map AND hh.player_thing_id = p_player AND hh.shot_serial = p_shot
               AND hh.hit_kind = 'target' AND NOT th.alive) jd
      JOIN g_things t ON t.map_id = jd.map_id AND t.id = jd.thing_id
      JOIN thing_combat_defs cd ON cd.thing_type = t.type AND cd.drops_thing_type IS NOT NULL;
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_render_things g_render_things_pk) */
      INTO g_render_things (map_id, thing_id, sector_id, sprite, frame, fullbright, spawn_ceiling, thing_height)
    SELECT d.map_id, v_drop + d.thing_id, d.sector_id, ts.sprite, ts.frame, ts.fullbright, ts.spawn_ceiling, ts.thing_height
      FROM (SELECT jd.map_id, jd.thing_id, NVL(ai.sector_id, rt.sector_id) AS sector_id, cd.drops_thing_type AS drop_type
              FROM (SELECT DISTINCT hh.map_id, hh.thing_id FROM g_hitscan_hits hh
                      JOIN g_thing_health th ON th.map_id = hh.map_id AND th.thing_id = hh.thing_id
                     WHERE hh.map_id = p_map AND hh.player_thing_id = p_player AND hh.shot_serial = p_shot
                       AND hh.hit_kind = 'target' AND NOT th.alive) jd
              JOIN g_things t ON t.map_id = jd.map_id AND t.id = jd.thing_id
              JOIN thing_combat_defs cd ON cd.thing_type = t.type AND cd.drops_thing_type IS NOT NULL
              LEFT JOIN g_monster_ai ai ON ai.map_id = jd.map_id AND ai.thing_id = jd.thing_id
              LEFT JOIN g_render_things rt ON rt.map_id = jd.map_id AND rt.thing_id = jd.thing_id) d
      JOIN thing_sprite_defs ts ON ts.thing_type = d.drop_type
     WHERE d.sector_id IS NOT NULL;
    -- gun-activated lines (G1/GR)
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_line_special_events g_line_special_events_pk) */
      INTO g_line_special_events (map_id, player_thing_id, line_id, trigger_type, from_front)
    SELECT DISTINCT hh.map_id, hh.player_thing_id, hh.line_id, 'shoot', NVL(hh.line_from_front, TRUE)
      FROM g_hitscan_hits hh
      JOIN linedefs ld ON ld.map_id = hh.map_id AND ld.id = hh.line_id
      JOIN line_special_defs d ON d.special = ld.special AND d.shoot_activated
     WHERE hh.map_id = p_map AND hh.player_thing_id = p_player AND hh.shot_serial = p_shot AND hh.hit_kind = 'wall';
    DELETE FROM g_hitscan_hits WHERE map_id = p_map AND player_thing_id = p_player AND shot_serial = p_shot;
  END;

  -- =====================================================================
  -- doom_cs_projectiles (24): spawn, sweep, damage, advance every missile
  -- =====================================================================
  PROCEDURE cs_projectiles(p_map NUMBER, p_player NUMBER) IS
    v_sz BINARY_DOUBLE := k('MISSILE_SPAWN_Z');
    v_shadow BINARY_DOUBLE := k('SHADOW_SPREAD_UNITS');
    v_ahead BINARY_DOUBLE := k('MISSILE_SPAWN_AHEAD');
    v_nm_speed BINARY_DOUBLE := k('NIGHTMARE_MISSILE_SPEED');
    v_melee BINARY_DOUBLE := k('MELEE_REACH');
    v_aims BINARY_DOUBLE := k('AIM_SPREAD_DEGREES');
    v_fxbase NUMBER := k('PROJECTILE_EFFECT_ID_BASE');
    v_skill NUMBER; v_shadowed BOOLEAN; v_lt NUMBER; v_max NUMBER; v_rn PLS_INTEGER;
    err BINARY_DOUBLE; dx BINARY_DOUBLE; dy BINARY_DOUBLE; dz BINARY_DOUBLE; hl BINARY_DOUBLE; spd BINARY_DOUBLE;
    -- flying
    f_id t_num; f_owner t_num; f_type t_str; f_x t_flt; f_y t_flt; f_z t_flt; f_vx t_flt; f_vy t_flt; f_vz t_flt;
    f_r t_dbl; f_otype t_num;
    -- targets
    a_id t_num; a_type t_num; a_x t_dbl; a_y t_dbl; a_r t_dbl; a_bz t_dbl; a_h t_dbl;
    p_id t_num; p_x t_dbl; p_y t_dbl; p_bz t_dbl;
    tt BINARY_DOUBLE; ex BINARY_DOUBLE; ey BINARY_DOUBLE; zz BINARY_DOUBLE; vv BINARY_FLOAT;
    best_t BINARY_DOUBLE; best_pri PLS_INTEGER; best_tid NUMBER; best_player BOOLEAN;
    den_f BINARY_FLOAT; t_f BINARY_FLOAT; u_f BINARY_FLOAT; z_f BINARY_FLOAT; wall_t BINARY_FLOAT;
    lx1 BINARY_FLOAT; ly1 BINARY_FLOAT; lx2 BINARY_FLOAT; ly2 BINARY_FLOAT; f PLS_INTEGER; b PLS_INTEGER;
    denom_f BINARY_FLOAT; blk BOOLEAN; cand_better BOOLEAN; v_any NUMBER; gcand t_int; gn PLS_INTEGER; li PLS_INTEGER;
  BEGIN
    DELETE FROM g_projectile_damage WHERE map_id = p_map;
    DELETE FROM g_projectile_impacts WHERE map_id = p_map;
    SELECT skill INTO v_skill FROM g_game_tic_commands WHERE map_id = p_map AND player_thing_id = p_player;
    SELECT CASE WHEN invis_tics > 0 THEN TRUE ELSE FALSE END, level_tics INTO v_shadowed, v_lt
      FROM g_player_state WHERE map_id = p_map AND player_thing_id = p_player;

    -- monster missiles (A_TroopAttack and friends): in melee range a biter bites instead
    SELECT NVL(MAX(projectile_id), 0) INTO v_max FROM g_monster_projectiles WHERE map_id = p_map;
    v_rn := 0;
    FOR s IN (SELECT ai.thing_id, TO_BINARY_DOUBLE(t.x) AS sx, TO_BINARY_DOUBLE(t.y) AS sy,
                     TO_BINARY_DOUBLE(CASE WHEN d.floats THEN t.z ELSE TO_BINARY_FLOAT(s.floor_height) END) + v_sz AS sz,
                     TO_BINARY_DOUBLE(pt.x) AS tx, TO_BINARY_DOUBLE(pt.y) AS ty,
                     TO_BINARY_DOUBLE(pt.z) - (k_viewheight - k_player_height / 2d) AS tz,
                     NVL(ai.sector_id, rt.sector_id) AS sector_id, d.missile_type, d.missile_speed, d.missile_dice,
                     pd.dmg_dice_count
                FROM g_monster_ai ai
                JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
                JOIN thing_combat_defs d ON d.thing_type = t.type AND d.missile_type IS NOT NULL
                JOIN projectile_defs pd ON pd.projectile_type = d.missile_type
                JOIN g_things pt ON pt.map_id = ai.map_id AND pt.id = NVL(ai.target_thing_id, p_player)
                LEFT JOIN g_render_things rt ON rt.map_id = ai.map_id AND rt.thing_id = ai.thing_id
                JOIN g_sectors s ON s.map_id = ai.map_id AND s.id = NVL(ai.sector_id, rt.sector_id)
               WHERE ai.map_id = p_map AND ai.fired_this_tick
                 AND (d.melee_mult IS NULL
                      OR SQRT((pt.x - t.x) * (pt.x - t.x) + (pt.y - t.y) * (pt.y - t.y)) > v_melee)
               ORDER BY ai.thing_id) LOOP
      v_rn := v_rn + 1;
      IF v_shadowed THEN
        err := ((prandom(s.thing_id, v_lt, 5) - prandom(s.thing_id, v_lt, 6)) * 360 / v_shadow) * c_rad;
      ELSE err := 0d; END IF;
      dx := (s.tx - s.sx) * COS(err) - (s.ty - s.sy) * SIN(err);
      dy := (s.tx - s.sx) * SIN(err) + (s.ty - s.sy) * COS(err);
      dz := s.tz - s.sz;
      hl := SQRT((s.tx - s.sx) * (s.tx - s.sx) + (s.ty - s.sy) * (s.ty - s.sy));
      IF hl > 0 THEN
        spd := CASE WHEN v_skill = 4 THEN v_nm_speed ELSE s.missile_speed END;
        INSERT INTO g_monster_projectiles (map_id, projectile_id, owner_thing_id, projectile_type, x, y, z, vx, vy, vz,
                                           sector_id, state, age, damage, impact_player)
        VALUES (p_map, v_max + v_rn, s.thing_id, s.missile_type,
                s.sx + v_ahead * dx / hl, s.sy + v_ahead * dy / hl, s.sz,
                spd * dx / hl, spd * dy / hl, spd * dz / hl, s.sector_id, 'fly', 0,
                s.missile_dice * (MOD(prandom(s.thing_id, v_lt, 7), s.dmg_dice_count) + 1), FALSE);
      END IF;
    END LOOP;

    -- player rockets / plasma / BFG
    SELECT NVL(MAX(projectile_id), 0) INTO v_max FROM g_monster_projectiles WHERE map_id = p_map;
    v_rn := 0;
    FOR s IN (SELECT pw.player_thing_id, TO_BINARY_DOUBLE(t.x) AS sx, TO_BINARY_DOUBLE(t.y) AS sy,
                     TO_BINARY_DOUBLE(t.z) - (k_viewheight - v_sz) AS sz, TO_BINARY_DOUBLE(t.angle) * c_rad AS angle,
                     wd.projectile_type, pd.speed,
                     pd.dmg_dice_mult * (MOD(doom_game.prandom(pw.shot_serial, pw.player_thing_id, pd.dmg_random_id),
                                             pd.dmg_dice_count) + 1) AS damage,
                     rt.sector_id
                FROM g_player_weapons pw
                JOIN weapon_defs wd ON wd.weapon_id = pw.current_weapon AND wd.projectile_type IS NOT NULL
                JOIN projectile_defs pd ON pd.projectile_type = wd.projectile_type
                JOIN g_things t ON t.map_id = pw.map_id AND t.id = pw.player_thing_id
                LEFT JOIN g_render_things rt ON rt.map_id = t.map_id AND rt.thing_id = t.id
               WHERE pw.map_id = p_map AND pw.fired_this_tick
               ORDER BY pw.player_thing_id) LOOP
      v_rn := v_rn + 1;
      DECLARE
        b_key1 BINARY_DOUBLE; b_along BINARY_DOUBLE; b_tz BINARY_DOUBLE; b_id NUMBER; found BOOLEAN := FALSE;
        ca BINARY_DOUBLE := COS(s.angle); sa BINARY_DOUBLE := SIN(s.angle); tn BINARY_DOUBLE := TAN(v_aims * c_rad);
        al BINARY_DOUBLE; lat BINARY_DOUBLE; key1 BINARY_DOUBLE;
      BEGIN
        FOR tg IN (SELECT mt.id, TO_BINARY_DOUBLE(mt.x) AS tx, TO_BINARY_DOUBLE(mt.y) AS ty,
                          TO_BINARY_DOUBLE(sec.floor_height + rt2.thing_height / 2) AS tz, cd.radius
                     FROM g_thing_health h
                     JOIN g_things mt ON mt.map_id = h.map_id AND mt.id = h.thing_id
                     JOIN thing_combat_defs cd ON cd.thing_type = mt.type
                     JOIN g_render_things rt2 ON rt2.map_id = mt.map_id AND rt2.thing_id = mt.id
                     LEFT JOIN g_monster_ai ai ON ai.map_id = mt.map_id AND ai.thing_id = mt.id
                     JOIN g_sectors sec ON sec.map_id = mt.map_id AND sec.id = NVL(ai.sector_id, rt2.sector_id)
                    WHERE h.map_id = p_map AND h.alive) LOOP
          al := (tg.tx - s.sx) * ca + (tg.ty - s.sy) * sa;
          lat := -(tg.tx - s.sx) * sa + (tg.ty - s.sy) * ca;
          IF al > 0 AND ABS(lat) <= tg.radius + al * tn THEN
            key1 := ABS(lat) / al;
            IF NOT found OR key1 < b_key1 OR (key1 = b_key1 AND (al < b_along OR (al = b_along AND tg.id < b_id))) THEN
              found := TRUE; b_key1 := key1; b_along := al; b_tz := tg.tz; b_id := tg.id;
            END IF;
          END IF;
        END LOOP;
        INSERT INTO g_monster_projectiles (map_id, projectile_id, owner_thing_id, projectile_type, x, y, z, vx, vy, vz,
                                           sector_id, state, age, damage, impact_player)
        VALUES (p_map, v_max + v_rn, s.player_thing_id, s.projectile_type, s.sx, s.sy, s.sz,
                s.speed * ca, s.speed * sa,
                s.speed * CASE WHEN found AND b_along <> 0 THEN (b_tz - s.sz) / b_along ELSE 0d END,
                s.sector_id, 'fly', 0, s.damage, FALSE);
      END;
    END LOOP;

    -- swept collision against players, actors and walls
    SELECT mp.projectile_id, mp.owner_thing_id, mp.projectile_type, mp.x, mp.y, mp.z, mp.vx, mp.vy, mp.vz, pd.radius, ot.type
      BULK COLLECT INTO f_id, f_owner, f_type, f_x, f_y, f_z, f_vx, f_vy, f_vz, f_r, f_otype
      FROM g_monster_projectiles mp JOIN projectile_defs pd ON pd.projectile_type = mp.projectile_type
      LEFT JOIN g_things ot ON ot.map_id = mp.map_id AND ot.id = mp.owner_thing_id
     WHERE mp.map_id = p_map AND mp.state = 'fly';
    IF f_id.COUNT > 0 THEN
      SELECT ps.player_thing_id, t.x, t.y, TO_BINARY_DOUBLE(ps.base_z) - k_viewheight
        BULK COLLECT INTO p_id, p_x, p_y, p_bz
        FROM g_player_state ps JOIN g_things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
       WHERE ps.map_id = p_map AND ps.alive;
      SELECT /*+ LEADING(h t cd rt ai sec) USE_NL(t) USE_NL(cd) USE_NL(rt) USE_NL(ai) USE_NL(sec) */
             h.thing_id, t.type, t.x, t.y, cd.radius, sec.floor_height, rt.thing_height
        BULK COLLECT INTO a_id, a_type, a_x, a_y, a_r, a_bz, a_h
        FROM g_thing_health h
        JOIN g_things t ON t.map_id = h.map_id AND t.id = h.thing_id
        JOIN thing_combat_defs cd ON cd.thing_type = t.type
        JOIN g_render_things rt ON rt.map_id = t.map_id AND rt.thing_id = t.id
        LEFT JOIN g_monster_ai ai ON ai.map_id = t.map_id AND ai.thing_id = t.id
        JOIN g_sectors sec ON sec.map_id = t.map_id AND sec.id = NVL(ai.sector_id, rt.sector_id)
       WHERE h.map_id = p_map AND h.alive;
      load_sectors(p_map);
      FOR i IN 1 .. f_id.COUNT LOOP
        best_pri := -1;
        denom_f := f_vx(i) * f_vx(i) + f_vy(i) * f_vy(i);          -- real arithmetic, as the reference
        FOR j IN 1 .. p_id.COUNT LOOP
          IF p_id(j) <> f_owner(i) THEN
            IF denom_f = 0 THEN tt := 0d;
            ELSE tt := LEAST(1d, GREATEST(0d, ((p_x(j) - f_x(i)) * f_vx(i) + (p_y(j) - f_y(i)) * f_vy(i)) / denom_f)); END IF;
            ex := f_x(i) + tt * f_vx(i) - p_x(j); ey := f_y(i) + tt * f_vy(i) - p_y(j);
            zz := f_z(i) + tt * f_vz(i);
            IF ex * ex + ey * ey <= (f_r(i) + k_player_radius) * (f_r(i) + k_player_radius)
               AND zz >= p_bz(j) AND zz <= p_bz(j) + k_player_height THEN
              IF best_pri = -1 OR tt < best_t OR (tt = best_t AND p_id(j) < best_tid) THEN
                best_pri := 0; best_t := tt; best_tid := p_id(j); best_player := TRUE;
              END IF;
            END IF;
          END IF;
        END LOOP;
        FOR j IN 1 .. a_id.COUNT LOOP
          IF a_id(j) <> f_owner(i)
             AND (f_type(i) IN ('rocket', 'plasma', 'bfg')
                  OR (f_type(i) IN ('imp_fireball', 'baron_fireball', 'caco_fireball')
                      AND (f_otype(i) IS NULL OR f_otype(i) <> a_type(j)))) THEN
            IF denom_f = 0 THEN tt := 0d;
            ELSE tt := LEAST(1d, GREATEST(0d, ((a_x(j) - f_x(i)) * f_vx(i) + (a_y(j) - f_y(i)) * f_vy(i)) / denom_f)); END IF;
            ex := f_x(i) + tt * f_vx(i) - a_x(j); ey := f_y(i) + tt * f_vy(i) - a_y(j);
            zz := f_z(i) + tt * f_vz(i);
            IF ex * ex + ey * ey <= (f_r(i) + a_r(j)) * (f_r(i) + a_r(j))
               AND zz >= a_bz(j) AND zz <= a_bz(j) + a_h(j) THEN
              IF best_pri = -1 OR tt < best_t OR (tt = best_t AND (best_pri > 0 OR a_id(j) < best_tid)) THEN
                best_pri := 0; best_t := tt; best_tid := a_id(j); best_player := FALSE;
              END IF;
            END IF;
          END IF;
        END LOOP;
        -- walls, in single precision like the reference (real op int stays real)
        wall_t := NULL;
        grid_seg(f_x(i), f_y(i), TO_BINARY_DOUBLE(f_x(i)) + f_vx(i), TO_BINARY_DOUBLE(f_y(i)) + f_vy(i), gcand, gn);
        FOR q IN 0 .. gn - 1 LOOP
          li := gcand(q);
          lx1 := l_x1(li); ly1 := l_y1(li); lx2 := l_x2(li); ly2 := l_y2(li);
          den_f := f_vx(i) * (ly2 - ly1) - f_vy(i) * (lx2 - lx1);
          IF ABS(den_f) > 1e-9f THEN
            t_f := ((lx1 - f_x(i)) * (ly2 - ly1) - (ly1 - f_y(i)) * (lx2 - lx1)) / den_f;
            IF t_f >= 0 AND t_f <= 1 THEN
              u_f := ((lx1 - f_x(i)) * f_vy(i) - (ly1 - f_y(i)) * f_vx(i)) / den_f;
              IF u_f >= 0 AND u_f <= 1 THEN
                f := l_fsec(li); b := l_bsec(li);
                IF l_lsd(li) = -1 OR l_rsd(li) = -1 OR f = -1 OR b = -1 THEN blk := TRUE;
                ELSE
                  z_f := f_z(i) + t_f * f_vz(i);
                  blk := z_f <= GREATEST(s_fl(f), s_fl(b)) OR z_f >= LEAST(s_ce(f), s_ce(b));
                END IF;
                IF blk AND (wall_t IS NULL OR t_f < wall_t) THEN wall_t := t_f; END IF;
              END IF;
            END IF;
          END IF;
        END LOOP;
        IF wall_t IS NOT NULL THEN
          IF best_pri = -1 OR TO_BINARY_DOUBLE(wall_t) < best_t THEN
            best_pri := 1; best_t := wall_t; best_tid := NULL; best_player := FALSE;
          END IF;
        END IF;
        IF best_pri >= 0 THEN
          INSERT INTO g_projectile_impacts (map_id, projectile_id, projectile_type, owner_thing_id, x, y, z,
                                            target_player, target_thing_id, target_player_thing_id)
          VALUES (p_map, f_id(i), f_type(i), f_owner(i), f_x(i) + best_t * f_vx(i), f_y(i) + best_t * f_vy(i),
                  f_z(i) + best_t * f_vz(i), best_player, best_tid, CASE WHEN best_player THEN best_tid END);
        END IF;
      END LOOP;
    END IF;

    -- direct hits
    INSERT INTO g_projectile_damage (map_id, projectile_id, damage_kind, hit_index, thing_id, damage)
    SELECT i.map_id, i.projectile_id, 'direct', -1, i.target_thing_id, mp.damage
      FROM g_projectile_impacts i
      JOIN g_monster_projectiles mp ON mp.map_id = i.map_id AND mp.projectile_id = i.projectile_id
     WHERE i.map_id = p_map AND i.target_thing_id IS NOT NULL
       AND i.projectile_type IN ('rocket', 'plasma', 'bfg', 'imp_fireball', 'baron_fireball', 'caco_fireball');

    SELECT COUNT(*) INTO v_any FROM g_projectile_impacts i JOIN projectile_defs pd ON pd.projectile_type = i.projectile_type
     WHERE i.map_id = p_map AND pd.blast_radius IS NOT NULL;
    IF v_any > 0 THEN
      -- radius damage (P_RadiusAttack spares nobody, the shooter included)
      INSERT INTO g_projectile_damage (map_id, projectile_id, damage_kind, hit_index, thing_id, damage)
      WITH explosions AS (
        SELECT i.* FROM g_projectile_impacts i JOIN projectile_defs pd ON pd.projectile_type = i.projectile_type
         AND pd.blast_radius IS NOT NULL WHERE i.map_id = p_map),
      victims AS (
        SELECT h.map_id, h.thing_id, TO_BINARY_DOUBLE(t.x) AS x, TO_BINARY_DOUBLE(t.y) AS y, cd.radius
          FROM g_thing_health h JOIN g_things t ON t.map_id = h.map_id AND t.id = h.thing_id
          JOIN thing_combat_defs cd ON cd.thing_type = t.type
         WHERE h.map_id = p_map AND h.alive
        UNION ALL
        SELECT ps.map_id, ps.player_thing_id, TO_BINARY_DOUBLE(t.x), TO_BINARY_DOUBLE(t.y), k_player_radius
          FROM g_player_state ps JOIN g_things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
         WHERE ps.map_id = p_map AND ps.alive),
      blocking AS (
        SELECT TO_BINARY_DOUBLE(ld.x1) AS x1, TO_BINARY_DOUBLE(ld.y1) AS y1,
               TO_BINARY_DOUBLE(ld.x2) AS x2, TO_BINARY_DOUBLE(ld.y2) AS y2
          FROM linedef_geom ld
          LEFT JOIN g_sectors fr ON fr.map_id = ld.map_id AND fr.id = ld.fsec
          LEFT JOIN g_sectors bk ON bk.map_id = ld.map_id AND bk.id = ld.bsec
         WHERE ld.map_id = p_map
           AND (ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR fr.id IS NULL OR bk.id IS NULL
                OR LEAST(fr.ceil_height, bk.ceil_height) <= GREATEST(fr.floor_height, bk.floor_height))),
      radial AS (
        SELECT e.map_id, e.projectile_id, v.thing_id,
               GREATEST(0, pd.blast_radius - GREATEST(0, ROUND(FLOOR(GREATEST(ABS(v.x - e.x), ABS(v.y - e.y)) - v.radius)))) AS damage
          FROM explosions e CROSS JOIN victims v
          JOIN projectile_defs pd ON pd.projectile_type = e.projectile_type AND pd.blast_radius IS NOT NULL
         WHERE GREATEST(ABS(v.x - e.x), ABS(v.y - e.y)) - v.radius < pd.blast_radius
           AND NOT EXISTS (
             SELECT 1 FROM blocking b
              WHERE ((e.x - b.x1) * (b.y2 - b.y1) - (e.y - b.y1) * (b.x2 - b.x1))
                  * ((v.x - b.x1) * (b.y2 - b.y1) - (v.y - b.y1) * (b.x2 - b.x1)) < 0
                AND ((b.x1 - e.x) * (v.y - e.y) - (b.y1 - e.y) * (v.x - e.x))
                  * ((b.x2 - e.x) * (v.y - e.y) - (b.y2 - e.y) * (v.x - e.x)) < 0))
      SELECT map_id, projectile_id, 'splash', thing_id, thing_id, damage FROM radial WHERE damage > 0;
    END IF;

    -- BFG spray: spray_rays rays across spray_arc_degrees, 15d8 a ray
    SELECT COUNT(*) INTO v_any FROM g_monster_projectiles mp JOIN projectile_defs pd ON pd.projectile_type = mp.projectile_type
     WHERE mp.map_id = p_map AND mp.state = 'explode' AND pd.spray_at_tic IS NOT NULL AND mp.age = pd.spray_at_tic;
    IF v_any > 0 THEN
      INSERT INTO g_projectile_damage (map_id, projectile_id, damage_kind, hit_index, thing_id, damage)
      WITH bfg AS (
        SELECT mp.map_id, mp.projectile_id, mp.owner_thing_id, mp.vx, mp.vy, TO_BINARY_DOUBLE(t.x) AS ox,
               TO_BINARY_DOUBLE(t.y) AS oy, pd.spray_rays, pd.spray_arc_degrees, pd.spray_range, pd.spray_dice,
               pd.spray_random_base, pd.dmg_dice_count
          FROM g_monster_projectiles mp JOIN g_things t ON t.map_id = mp.map_id AND t.id = mp.owner_thing_id
          JOIN projectile_defs pd ON pd.projectile_type = mp.projectile_type
         WHERE mp.map_id = p_map AND mp.state = 'explode' AND pd.spray_at_tic IS NOT NULL AND mp.age = pd.spray_at_tic),
      rays AS (
        SELECT b.*, r.i AS ray_index,
               ATAN2(TO_BINARY_DOUBLE(b.vy), TO_BINARY_DOUBLE(b.vx))
                 + (-b.spray_arc_degrees / 2 + (b.spray_arc_degrees / b.spray_rays) * r.i) * c_rad AS ray_angle
          FROM bfg b CROSS JOIN (SELECT LEVEL - 1 AS i FROM dual CONNECT BY LEVEL <= 64) r
         WHERE r.i < b.spray_rays),
      targets AS (
        SELECT h.thing_id, TO_BINARY_DOUBLE(t.x) AS x, TO_BINARY_DOUBLE(t.y) AS y, cd.radius
          FROM g_thing_health h JOIN g_things t ON t.map_id = h.map_id AND t.id = h.thing_id
          JOIN thing_combat_defs cd ON cd.thing_type = t.type WHERE h.map_id = p_map AND h.alive
        UNION ALL
        SELECT ps.player_thing_id, TO_BINARY_DOUBLE(t.x), TO_BINARY_DOUBLE(t.y), k_player_radius
          FROM g_player_state ps JOIN g_things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
         WHERE ps.map_id = p_map AND ps.alive),
      blocking AS (
        SELECT TO_BINARY_DOUBLE(ld.x1) AS x1, TO_BINARY_DOUBLE(ld.y1) AS y1,
               TO_BINARY_DOUBLE(ld.x2) AS x2, TO_BINARY_DOUBLE(ld.y2) AS y2
          FROM linedef_geom ld
          LEFT JOIN g_sectors fr ON fr.map_id = ld.map_id AND fr.id = ld.fsec
          LEFT JOIN g_sectors bk ON bk.map_id = ld.map_id AND bk.id = ld.bsec
         WHERE ld.map_id = p_map
           AND (ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR fr.id IS NULL OR bk.id IS NULL
                OR LEAST(fr.ceil_height, bk.ceil_height) <= GREATEST(fr.floor_height, bk.floor_height))),
      inter AS (
        SELECT r.map_id, r.projectile_id, r.ray_index, t.thing_id, r.ox, r.oy, t.x, t.y, r.spray_range, r.spray_dice,
               r.spray_random_base, r.dmg_dice_count,
               ((t.x - r.ox) * COS(r.ray_angle) + (t.y - r.oy) * SIN(r.ray_angle))
                 - SQRT(GREATEST(0d, t.radius * t.radius
                        - POWER(-(t.x - r.ox) * SIN(r.ray_angle) + (t.y - r.oy) * COS(r.ray_angle), 2))) AS distance,
               (t.x - r.ox) * COS(r.ray_angle) + (t.y - r.oy) * SIN(r.ray_angle) AS along,
               POWER(-(t.x - r.ox) * SIN(r.ray_angle) + (t.y - r.oy) * COS(r.ray_angle), 2) AS perp2, t.radius
          FROM rays r CROSS JOIN targets t
         WHERE t.thing_id <> r.owner_thing_id),
      visible AS (
        SELECT i.* FROM inter i
         WHERE i.along > 0 AND i.along <= i.spray_range + i.radius AND i.perp2 <= i.radius * i.radius
           AND i.distance > 0 AND i.distance <= i.spray_range
           AND NOT EXISTS (
             SELECT 1 FROM blocking b
              WHERE ((i.ox - b.x1) * (b.y2 - b.y1) - (i.oy - b.y1) * (b.x2 - b.x1))
                  * ((i.x - b.x1) * (b.y2 - b.y1) - (i.y - b.y1) * (b.x2 - b.x1)) < 0
                AND ((b.x1 - i.ox) * (i.y - i.oy) - (b.y1 - i.oy) * (i.x - i.ox))
                  * ((b.x2 - i.ox) * (i.y - i.oy) - (b.y2 - i.oy) * (i.x - i.ox)) < 0)),
      hits AS (
        SELECT * FROM (SELECT v.*, ROW_NUMBER() OVER (PARTITION BY projectile_id, ray_index ORDER BY distance, thing_id) AS rn
                         FROM visible v) WHERE rn = 1)
      SELECT h.map_id, h.projectile_id, 'bfg_spray', h.ray_index, h.thing_id,
             (SELECT SUM(MOD(doom_game.prandom(h.thing_id, h.projectile_id * 64 + h.ray_index, h.spray_random_base + g.i),
                             h.dmg_dice_count) + 1)
                FROM (SELECT LEVEL - 1 AS i FROM dual CONNECT BY LEVEL <= 64) g WHERE g.i < h.spray_dice)
        FROM hits h;
    END IF;

    SELECT COUNT(*) INTO v_any FROM g_projectile_damage WHERE map_id = p_map;
    IF v_any > 0 THEN
      MERGE INTO g_thing_health h
      USING (SELECT thing_id, SUM(damage) AS damage FROM g_projectile_damage WHERE map_id = p_map GROUP BY thing_id) d
         ON (h.map_id = p_map AND h.thing_id = d.thing_id)
       WHEN MATCHED THEN UPDATE SET h.health = h.health - d.damage,
                                    h.alive = CASE WHEN h.health - d.damage > 0 THEN TRUE ELSE FALSE END;
      -- P_DamageMobj's thrust, summed in 16.16 fixed point
      MERGE INTO g_things t
      USING (SELECT q.thing_id,
                    SUM(doom_game.rnd(q.push * q.dx / q.dist * 65536d)) / 65536d AS ddx,
                    SUM(doom_game.rnd(q.push * q.dy / q.dist * 65536d)) / 65536d AS ddy
               FROM (SELECT pd.thing_id, TO_BINARY_DOUBLE(pd.damage * 12.5 / GREATEST(1, cd.mass)) AS push,
                            TO_BINARY_DOUBLE(v.x - CASE WHEN pd.damage_kind = 'bfg_spray' THEN pl.x ELSE i.x END) AS dx,
                            TO_BINARY_DOUBLE(v.y - CASE WHEN pd.damage_kind = 'bfg_spray' THEN pl.y ELSE i.y END) AS dy,
                            TO_BINARY_DOUBLE(NULLIF(SQRT(
                              (v.x - CASE WHEN pd.damage_kind = 'bfg_spray' THEN pl.x ELSE i.x END)
                            * (v.x - CASE WHEN pd.damage_kind = 'bfg_spray' THEN pl.x ELSE i.x END)
                            + (v.y - CASE WHEN pd.damage_kind = 'bfg_spray' THEN pl.y ELSE i.y END)
                            * (v.y - CASE WHEN pd.damage_kind = 'bfg_spray' THEN pl.y ELSE i.y END)), 0)) AS dist
                       FROM g_projectile_damage pd
                       JOIN g_things v ON v.map_id = pd.map_id AND v.id = pd.thing_id
                       JOIN thing_combat_defs cd ON cd.thing_type = v.type
                       JOIN g_things pl ON pl.map_id = pd.map_id AND pl.id = p_player
                       LEFT JOIN g_projectile_impacts i ON i.map_id = pd.map_id AND i.projectile_id = pd.projectile_id
                      WHERE pd.map_id = p_map AND pd.damage > 0
                        AND NOT EXISTS (SELECT 1 FROM g_player_state ps WHERE ps.map_id = pd.map_id
                                          AND ps.player_thing_id = pd.thing_id)) q
              WHERE q.dist IS NOT NULL
              GROUP BY q.thing_id) s
         ON (t.map_id = p_map AND t.id = s.thing_id)
       WHEN MATCHED THEN UPDATE SET t.mom_x = t.mom_x + s.ddx, t.mom_y = t.mom_y + s.ddy;
      -- a hurt monster turns on whatever hit it
      MERGE INTO g_monster_ai ai
      USING (SELECT d.thing_id, MAX(i.owner_thing_id) KEEP (DENSE_RANK LAST ORDER BY i.projectile_id) AS owner_thing_id
               FROM g_projectile_damage d
               JOIN g_projectile_impacts i ON i.map_id = d.map_id AND i.projectile_id = d.projectile_id
              WHERE d.map_id = p_map
                AND (i.projectile_type IN ('imp_fireball', 'baron_fireball', 'caco_fireball')
                     OR EXISTS (SELECT 1 FROM g_monster_ai mo WHERE mo.map_id = i.map_id AND mo.thing_id = i.owner_thing_id))
                AND i.owner_thing_id IS NOT NULL
              GROUP BY d.thing_id) src
         ON (ai.map_id = p_map AND ai.thing_id = src.thing_id)
       WHEN MATCHED THEN UPDATE SET
         ai.target_thing_id = src.owner_thing_id,
         ai.state = CASE WHEN ai.state = 'stand' THEN 'see' ELSE ai.state END,
         ai.seq_index = CASE WHEN ai.state = 'stand' THEN 0 ELSE ai.seq_index END,
         ai.state_tics = CASE WHEN ai.state = 'stand' THEN 0 ELSE ai.state_tics END
        WHERE ai.thing_id <> src.owner_thing_id
          AND (ai.target_thing_id IS NULL OR ai.target_thing_id <> src.owner_thing_id);
      -- pain
      MERGE INTO g_monster_ai ai
      USING (SELECT hit.thing_id, hit.flinches, fp.tics AS pain_tics, fs.tics AS see_tics
               FROM (SELECT d.thing_id, t.type,
                            MAX(CASE WHEN doom_game.prandom(d.thing_id, d.projectile_id, 11) < cd.pain_chance THEN 1 ELSE 0 END) AS flinches
                       FROM g_projectile_damage d
                       JOIN g_things t ON t.map_id = d.map_id AND t.id = d.thing_id
                       JOIN thing_combat_defs cd ON cd.thing_type = t.type
                      WHERE d.map_id = p_map AND d.damage > 0
                      GROUP BY d.thing_id, t.type) hit
               JOIN g_thing_health h ON h.map_id = p_map AND h.thing_id = hit.thing_id
               LEFT JOIN thing_ai_frames fp ON fp.thing_type = hit.type AND fp.state = 'pain' AND fp.seq_index = 0
               LEFT JOIN thing_ai_frames fs ON fs.thing_type = hit.type AND fs.state = 'see' AND fs.seq_index = 0
              WHERE h.alive
                AND NOT EXISTS (SELECT 1 FROM thing_combat_defs bd WHERE bd.thing_type = hit.type AND bd.explodes)) hit
         ON (ai.map_id = p_map AND ai.thing_id = hit.thing_id)
       WHEN MATCHED THEN UPDATE SET
         ai.state = CASE WHEN hit.flinches = 1 THEN 'pain' ELSE 'see' END,
         ai.seq_index = CASE WHEN hit.flinches = 1 THEN 0 ELSE ai.seq_index END,
         ai.state_tics = CASE WHEN hit.flinches = 1 THEN NVL(hit.pain_tics, ai.state_tics) ELSE NVL(hit.see_tics, ai.state_tics) END
        WHERE ai.state NOT IN ('die', 'dead') AND (hit.flinches = 1 OR ai.state = 'stand');
      -- visible BFG spray
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_world_effects g_world_effects_pk) */
        INTO g_world_effects (map_id, effect_id, effect_type, x, y, z, sector_id, age)
      SELECT d.map_id, v_fxbase + d.projectile_id * 100 + d.hit_index, 'bfg_spray', t.x, t.y,
             sec.floor_height + rt.thing_height / 4, NVL(ai.sector_id, rt.sector_id), 0
        FROM g_projectile_damage d
        JOIN g_things t ON t.map_id = d.map_id AND t.id = d.thing_id
        JOIN g_render_things rt ON rt.map_id = t.map_id AND rt.thing_id = t.id
        LEFT JOIN g_monster_ai ai ON ai.map_id = t.map_id AND ai.thing_id = t.id
        JOIN g_sectors sec ON sec.map_id = t.map_id AND sec.id = NVL(ai.sector_id, rt.sector_id)
       WHERE d.map_id = p_map AND d.damage_kind = 'bfg_spray';
      -- damage landing on players
      MERGE INTO g_player_state ps
      USING (
        WITH landed AS (
          SELECT pd.thing_id AS victim_id, pd.damage,
                 TO_BINARY_DOUBLE(CASE WHEN pd.damage_kind = 'bfg_spray' THEN ot.x ELSE i.x END) AS ix,
                 TO_BINARY_DOUBLE(CASE WHEN pd.damage_kind = 'bfg_spray' THEN ot.y ELSE i.y END) AS iy,
                 NVL(k2.player_thing_id, -1) AS source_id
            FROM g_projectile_damage pd
            JOIN g_player_state v ON v.map_id = pd.map_id AND v.player_thing_id = pd.thing_id
            JOIN g_monster_projectiles mp ON mp.map_id = pd.map_id AND mp.projectile_id = pd.projectile_id
            LEFT JOIN g_projectile_impacts i ON i.map_id = pd.map_id AND i.projectile_id = pd.projectile_id
            LEFT JOIN g_things ot ON ot.map_id = mp.map_id AND ot.id = mp.owner_thing_id
            LEFT JOIN g_player_state k2 ON k2.map_id = mp.map_id AND k2.player_thing_id = mp.owner_thing_id
           WHERE pd.map_id = p_map AND pd.damage > 0),
        scaled AS (
          SELECT l.victim_id, FLOOR(l.damage / CASE WHEN g.skill = 0 THEN 2 ELSE 1 END) AS dmg, l.ix, l.iy, l.source_id,
                 TO_BINARY_DOUBLE(vt.x) AS vx, TO_BINARY_DOUBLE(vt.y) AS vy
            FROM landed l
            JOIN g_player_state v ON v.map_id = p_map AND v.player_thing_id = l.victim_id
            JOIN g_game_tic_commands g ON g.map_id = v.map_id AND g.player_thing_id = v.player_thing_id
            JOIN g_things vt ON vt.map_id = v.map_id AND vt.id = v.player_thing_id),
        totals AS (
          SELECT victim_id, SUM(dmg) AS dmg, SUM(FLOOR(dmg / 3)) AS green_saved, SUM(FLOOR(dmg / 2)) AS blue_saved,
                 MAX(source_id) KEEP (DENSE_RANK LAST ORDER BY dmg * 1000000 + source_id) AS source_id,
                 SUM(doom_game.rnd(CASE WHEN dist > 0 THEN dmg * 0.125d * (vx - ix) / dist ELSE 0d END * 65536d)) / 65536d AS thrust_x,
                 SUM(doom_game.rnd(CASE WHEN dist > 0 THEN dmg * 0.125d * (vy - iy) / dist ELSE 0d END * 65536d)) / 65536d AS thrust_y
            FROM (SELECT s.*, SQRT((s.vx - s.ix) * (s.vx - s.ix) + (s.vy - s.iy) * (s.vy - s.iy)) AS dist FROM scaled s)
           GROUP BY victim_id),
        absorbed AS (
          SELECT t.*, CASE WHEN ps2.god_mode OR ps2.invuln_tics > 0 THEN 1 ELSE 0 END AS blocked,
                 CASE WHEN ps2.god_mode OR ps2.invuln_tics > 0 THEN 0
                      ELSE LEAST(ps2.armor, CASE ps2.armor_class WHEN 2 THEN t.blue_saved WHEN 1 THEN t.green_saved ELSE 0 END)
                 END AS saved
            FROM totals t JOIN g_player_state ps2 ON ps2.map_id = p_map AND ps2.player_thing_id = t.victim_id)
        SELECT a.*, CASE WHEN a.blocked = 1 THEN 0 ELSE a.dmg - a.saved END AS took FROM absorbed a) a
      ON (ps.map_id = p_map AND ps.player_thing_id = a.victim_id)
      WHEN MATCHED THEN UPDATE SET
        ps.armor = ps.armor - a.saved,
        ps.armor_class = CASE WHEN ps.armor - a.saved <= 0 THEN 0 ELSE ps.armor_class END,
        ps.health = GREATEST(0, ps.health - a.took),
        ps.damage_count = LEAST(100, ps.damage_count + a.took),
        ps.alive = CASE WHEN GREATEST(0, ps.health - a.took) > 0 THEN TRUE ELSE FALSE END,
        ps.pain_face_tics = CASE WHEN a.took > 0 THEN 12 ELSE ps.pain_face_tics END,
        ps.killer_id = CASE WHEN ps.alive AND ps.health - a.took <= 0 THEN a.source_id ELSE ps.killer_id END,
        ps.momentum_x = ps.momentum_x + a.thrust_x,
        ps.momentum_y = ps.momentum_y + a.thrust_y;
    END IF;

    -- enter impact state, advance flights and explosions, retire
    MERGE INTO g_monster_projectiles mp
    USING (SELECT projectile_id, x, y, z, target_player FROM g_projectile_impacts WHERE map_id = p_map) i
       ON (mp.map_id = p_map AND mp.projectile_id = i.projectile_id)
     WHEN MATCHED THEN UPDATE SET mp.x = i.x, mp.y = i.y, mp.z = i.z, mp.state = 'explode', mp.age = 0,
                                  mp.impact_player = i.target_player
      WHERE mp.state = 'fly';
    UPDATE g_monster_projectiles mp
       SET x = x + vx, y = y + vy, z = z + vz, age = age + 1, impact_player = FALSE
     WHERE mp.map_id = p_map AND mp.state = 'fly'
       AND NOT EXISTS (SELECT 1 FROM g_projectile_impacts i WHERE i.map_id = mp.map_id AND i.projectile_id = mp.projectile_id);
    UPDATE g_monster_projectiles SET age = age + 1, impact_player = FALSE WHERE map_id = p_map AND state = 'explode';
    DELETE FROM g_monster_projectiles mp
     WHERE mp.map_id = p_map
       AND EXISTS (SELECT 1 FROM projectile_defs pd WHERE pd.projectile_type = mp.projectile_type
                     AND ((mp.state = 'explode' AND mp.age >= pd.explode_tics)
                          OR (mp.state = 'fly' AND mp.age >= pd.fly_timeout)));
  END;

  -- =====================================================================
  -- doom_cs_sound (25): one tic's sound events
  -- =====================================================================
  PROCEDURE cs_sound(p_map NUMBER, p_player NUMBER) IS
    -- The reference is one INSERT over eleven UNION ALL branches; here the same rows are built
    -- in PL/SQL from three small reads (player, monsters, impacts) and inserted at once. Keys
    -- already present are skipped (ON CONFLICT DO NOTHING); event_id order within a tic follows
    -- the insert order, as in the reference (not compared: CedarDB's own order follows its plan).
    v_odds NUMBER := k('ACTIVE_SOUND_ODDS');
    v_trim_age NUMBER := k('SOUND_TRIM_AGE_TICS'); v_trim_int NUMBER := k('SOUND_TRIM_INTERVAL_TICS');
    lt NUMBER; alive BOOLEAN; pain NUMBER; use_req BOOLEAN; px BINARY_FLOAT; py BINARY_FLOAT;
    fired BOOLEAN; weap NUMBER; serial NUMBER; picked NUMBER; granted NUMBER;
    e_key t_str; e_snd t_str; e_src t_num; e_x t_flt; e_y t_flt; n PLS_INTEGER := 0;
    have t_kint; nm VARCHAR2(8); cue VARCHAR2(8); dxf BINARY_FLOAT; dyf BINARY_FLOAT; v_any BOOLEAN := FALSE;
    r_locked BOOLEAN; r_elig BOOLEAN; r_special NUMBER; v_world BOOLEAN;
    PROCEDURE add(p_key VARCHAR2, p_snd VARCHAR2, p_src NUMBER, p_x BINARY_FLOAT, p_y BINARY_FLOAT) IS
    BEGIN
      IF p_snd IS NULL OR have.EXISTS(p_key) THEN RETURN; END IF;
      n := n + 1; e_key(n) := p_key; e_snd(n) := p_snd; e_src(n) := p_src; e_x(n) := p_x; e_y(n) := p_y;
      have(p_key) := 1;
    END;
    FUNCTION pick(p_type NUMBER, p_cue VARCHAR2, p_id NUMBER) RETURN VARCHAR2 IS
      kk VARCHAR2(64) := p_type || ':' || p_cue;
    BEGIN
      IF NOT sd_n.EXISTS(kk) THEN RETURN NULL; END IF;
      RETURN sd_name(kk || ':' || MOD(prandom(p_id, 0, 60), sd_n(kk)));
    END;
  BEGIN
    SELECT ps.level_tics, ps.alive, ps.pain_face_tics, g.use_requested, t.x, t.y, pw.fired_this_tick, pw.current_weapon,
           pw.shot_serial,
           (SELECT COUNT(*) FROM g_pickup_touches pt WHERE pt.map_id = g.map_id AND pt.player_thing_id = g.player_thing_id),
           (SELECT COUNT(*) FROM g_pickup_grants pg WHERE pg.map_id = g.map_id AND pg.player_thing_id = g.player_thing_id)
      INTO lt, alive, pain, use_req, px, py, fired, weap, serial, picked, granted
      FROM g_game_tic_commands g
      JOIN g_player_state ps ON ps.map_id = g.map_id AND ps.player_thing_id = g.player_thing_id
      JOIN g_things t ON t.map_id = g.map_id AND t.id = g.player_thing_id
      JOIN g_player_weapons pw ON pw.map_id = g.map_id AND pw.player_thing_id = g.player_thing_id
     WHERE g.map_id = p_map AND g.player_thing_id = p_player;
    -- In a deathmatch the stage runs once per player. The world cues (monsters, impacts) and the trim
    -- do not depend on the player once the first call has cleared fired_this_tick: every later call
    -- of the same tic would only re-offer keys already inserted (ON CONFLICT DO NOTHING) and delete
    -- nothing more, so they are built once a tic.
    v_world := lt IS NULL OR lt <> g_snd_lt;
    -- keys that never repeat: a monster's sight and death cues
    IF v_world THEN
      FOR r IN (SELECT event_key FROM g_sound_events
                 WHERE map_id = p_map AND (event_key LIKE 'mon-sight:%' OR event_key LIKE 'mon-death:%')) LOOP
        have(r.event_key) := 1;
      END LOOP;
    END IF;
    IF fired THEN
      add('player-fire:' || p_player || ':' || serial,
          CASE weap WHEN 1 THEN 'DSPUNCH' WHEN 2 THEN 'DSPISTOL' WHEN 3 THEN 'DSSHOTGN' WHEN 4 THEN 'DSPISTOL'
                    WHEN 5 THEN 'DSRLAUNC' WHEN 6 THEN 'DSPLASMA' WHEN 7 THEN 'DSBFG' END, p_player, px, py);
    END IF;
    IF picked > 0 THEN
      add('pickup:' || p_player || ':' || lt, CASE WHEN granted > 0 THEN 'DSWPNUP' ELSE 'DSITEMUP' END, p_player, px, py);
    END IF;
    IF use_req THEN
      r_locked := FALSE; r_elig := FALSE; r_special := NULL;
      FOR r IN (SELECT locked, eligible, special FROM g_line_use_results WHERE map_id = p_map AND player_thing_id = p_player) LOOP
        r_locked := NVL(r.locked, FALSE); r_elig := NVL(r.eligible, FALSE); r_special := r.special;
      END LOOP;
      add('use:' || p_player || ':' || lt,
          CASE WHEN r_locked THEN 'DSOOF'
               WHEN r_elig AND r_special IN (1, 26, 27, 28, 31, 32, 33, 34, 117, 118) THEN 'DSDOROPN'
               WHEN r_elig THEN 'DSSWTCHN' ELSE 'DSNOWAY' END, p_player, px, py);
    END IF;
    IF v_world THEN
    FOR m IN (SELECT /*+ LEADING(ai) USE_NL(t) USE_NL(h) */
                     ai.thing_id, ai.state, ai.state_tics, ai.seq_index, ai.fired_this_tick, t.type, t.x, t.y,
                     h.alive, h.health, h.max_health
                FROM g_monster_ai ai
                JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
                LEFT JOIN g_thing_health h ON h.map_id = ai.map_id AND h.thing_id = ai.thing_id
               WHERE ai.map_id = p_map
               ORDER BY ai.thing_id) LOOP
      IF m.fired_this_tick THEN
        v_any := TRUE;
        IF tc_attack_sound(m.type) IS NOT NULL THEN nm := tc_attack_sound(m.type);
        ELSE
          dxf := m.x - px; dyf := m.y - py;
          IF tc_missile(m.type) IS NOT NULL
             AND NOT (tc_melee(m.type) IS NOT NULL AND SQRT(dxf * dxf + dyf * dyf) <= 64) THEN nm := 'DSFIRSHT';
          ELSE nm := 'DSCLAW'; END IF;
        END IF;
        add('monster-fire:' || m.thing_id || ':' || lt, nm, m.thing_id, m.x, m.y);
      END IF;
      IF m.state <> 'stand' AND m.alive THEN
        IF NOT have.EXISTS('mon-sight:' || m.thing_id) THEN
          add('mon-sight:' || m.thing_id, pick(m.type, 'sight', m.thing_id), m.thing_id, m.x, m.y);
        END IF;
      END IF;
      IF NOT m.alive AND NOT have.EXISTS('mon-death:' || m.thing_id) THEN
        cue := CASE WHEN m.health < -m.max_health AND tc_xd(m.type) IS NOT NULL THEN 'xdeath' ELSE 'death' END;
        add('mon-death:' || m.thing_id, pick(m.type, cue, m.thing_id), m.thing_id, m.x, m.y);
      END IF;
      IF m.state = 'pain' AND fa_tics.EXISTS(m.type || ':pain:' || m.seq_index)
         AND m.state_tics = fa_tics(m.type || ':pain:' || m.seq_index) THEN
        add('mon-pain:' || m.thing_id || ':' || lt, pick(m.type, 'pain', m.thing_id), m.thing_id, m.x, m.y);
      END IF;
      IF m.state = 'see' AND m.alive
         AND MOD(prandom(m.thing_id, lt, 61) * 256 + prandom(m.thing_id, lt, 62), v_odds) = 0 THEN
        add('mon-act:' || m.thing_id || ':' || lt, pick(m.type, 'active', m.thing_id), m.thing_id, m.x, m.y);
      END IF;
    END LOOP;
    FOR i IN (SELECT projectile_id, projectile_type, owner_thing_id, x, y FROM g_projectile_impacts
               WHERE map_id = p_map ORDER BY projectile_id) LOOP
      add('impact:' || i.projectile_id, CASE i.projectile_type WHEN 'rocket' THEN 'DSRXPLOD' ELSE 'DSFIRXPL' END,
          i.owner_thing_id, i.x, i.y);
    END LOOP;
    END IF;
    IF alive AND pain > 0 AND sd_name.EXISTS('1:pain:0') THEN
      add('plr-pain:' || p_player || ':' || (lt - (12 - pain)), sd_name('1:pain:0'), p_player, px, py);
    END IF;
    IF NOT alive AND sd_name.EXISTS('1:death:0') THEN
      add('plr-death:' || p_player, sd_name('1:death:0'), p_player, px, py);
    END IF;
    FORALL i IN 1 .. n
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_sound_events g_sound_events_uk) */
        INTO g_sound_events (map_id, event_key, level_tic, sound_name, source_thing_id, source_x, source_y)
      VALUES (p_map, e_key(i), lt, e_snd(i), e_src(i), e_x(i), e_y(i));
    IF v_any THEN
      UPDATE g_monster_ai SET fired_this_tick = FALSE WHERE map_id = p_map AND fired_this_tick;
    END IF;
    -- The periodic trim: cues older than SOUND_TRIM_AGE_TICS behind the newest deathmatch player.
    -- With no deathmatch slots its cutoff is negative and it deletes nothing (single player).
    IF v_world AND lt >= 0 AND MOD(lt, v_trim_int) = 0 THEN
      DELETE FROM g_sound_events e
       WHERE e.map_id = p_map
         AND e.level_tic < (SELECT NVL(MAX(ps.level_tics), 0) - v_trim_age
                              FROM g_player_state ps
                              JOIN g_mp_players mp ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id
                             WHERE mp.map_id = p_map)
         AND e.event_key NOT LIKE 'mon-sight:%' AND e.event_key NOT LIKE 'mon-death:%'
         AND e.event_key NOT LIKE 'plr-death:%';
    END IF;
    g_snd_lt := lt;
  END;

  -- =====================================================================
  -- doom_cs_monsters (26): plan, retarget, noise, think, step, move, ...
  -- =====================================================================
  FUNCTION cs_monster_plan(p_map NUMBER) RETURN PLS_INTEGER IS
    v NUMBER;
  BEGIN
    SELECT CASE WHEN EXISTS (SELECT 1 FROM g_player_weapons pw WHERE pw.map_id = p_map AND pw.fired_this_tick) THEN 1 ELSE 0 END
         -- join-order hints: drive from the few matching monster rows (was a hash join over all
         -- g_things per EXISTS: 74 -> 34 us a call)
         + CASE WHEN EXISTS (SELECT /*+ LEADING(ai t f cd) USE_NL(t) USE_NL(f) USE_NL(cd) */ 1 FROM g_monster_ai ai
                               JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
                               JOIN thing_ai_frames f ON f.thing_type = t.type AND f.state = 'see' AND f.seq_index = ai.seq_index
                               JOIN thing_combat_defs cd ON cd.thing_type = t.type AND NOT cd.explodes
                              WHERE ai.map_id = p_map AND ai.state = 'see'
                                AND (ai.state_tics = f.tics OR ai.state_tics = FLOOR(f.tics / 2))) THEN 2 ELSE 0 END
         + CASE WHEN EXISTS (SELECT /*+ LEADING(ai t) USE_NL(t) USE_NL(d) */ 1 FROM g_monster_ai ai
                               JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
                               JOIN thing_combat_defs d ON d.thing_type = t.type
                              WHERE ai.map_id = p_map AND d.floats AND ai.state IN ('see', 'missile')) THEN 4 ELSE 0 END
         + CASE WHEN EXISTS (SELECT 1 FROM g_monster_ai WHERE map_id = p_map AND state = 'see') THEN 8 ELSE 0 END
         + CASE WHEN EXISTS (SELECT 1 FROM g_monster_ai WHERE map_id = p_map AND fired_this_tick) THEN 16 ELSE 0 END
         + CASE WHEN EXISTS (SELECT /*+ LEADING(ai t) USE_NL(t) USE_NL(cd) */ 1 FROM g_monster_ai ai
                               JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
                               JOIN thing_combat_defs cd ON cd.thing_type = t.type AND cd.explodes
                              WHERE ai.map_id = p_map AND ai.fired_this_tick) THEN 32 + 64 ELSE 0 END
      INTO v FROM dual;
    IF BITAND(v, 64) = 0 THEN
      SELECT v + CASE WHEN EXISTS (SELECT 1 FROM g_projectile_impacts WHERE map_id = p_map AND projectile_type = 'rocket')
                      THEN 64 ELSE 0 END INTO v FROM dual;
    END IF;
    RETURN v;
  END;

  PROCEDURE cs_monster_retarget(p_map NUMBER, p_player NUMBER) IS
  BEGIN
    UPDATE g_monster_ai ai SET target_thing_id = NULL
     WHERE ai.map_id = p_map AND ai.target_thing_id IS NOT NULL
       AND (EXISTS (SELECT 1 FROM g_player_state ps WHERE ps.map_id = ai.map_id
                      AND ps.player_thing_id = ai.target_thing_id
                      AND (NOT ps.alive OR EXISTS (SELECT 1 FROM g_mp_players mp WHERE mp.map_id = ps.map_id
                                                     AND mp.player_thing_id = ps.player_thing_id AND mp.role_name IS NULL)))
            OR EXISTS (SELECT 1 FROM g_thing_health th WHERE th.map_id = ai.map_id
                         AND th.thing_id = ai.target_thing_id AND NOT th.alive));
    UPDATE g_monster_ai SET target_thing_id = p_player
     WHERE map_id = p_map AND target_thing_id IS NULL AND state IN ('see', 'missile', 'pain');
  END;

  -- P_NoiseAlert: flood from the shooter's sector through open two-sided lines; a
  -- sound-blocking line (flags & 64) absorbs one level.
  PROCEDURE cs_monster_noise(p_map NUMBER) IS
    TYPE t_vis IS TABLE OF BOOLEAN INDEX BY PLS_INTEGER;
    vis t_vis; q_s t_int; q_b t_int; qh PLS_INTEGER := 0; qt PLS_INTEGER := 0;
    adj_start t_int; adj_cnt t_int; adj_to t_int; adj_blk t_int; tmp t_int;
    f PLS_INTEGER; b PLS_INTEGER; s PLS_INTEGER; bl PLS_INTEGER; nb PLS_INTEGER; pos PLS_INTEGER;
    flood t_vis; ids t_num; secs t_num;
  BEGIN
    FOR o IN (SELECT ps.sector_id FROM g_player_state ps
                JOIN g_player_weapons pw ON pw.map_id = ps.map_id AND pw.player_thing_id = ps.player_thing_id
               WHERE ps.map_id = p_map AND ps.alive AND pw.fired_this_tick AND ps.sector_id IS NOT NULL) LOOP
      IF NOT vis.EXISTS(o.sector_id * 2) THEN
        vis(o.sector_id * 2) := TRUE; q_s(qt) := o.sector_id; q_b(qt) := 0; qt := qt + 1;
      END IF;
    END LOOP;
    IF qt = 0 THEN RETURN; END IF;
    load_sectors(p_map);
    -- edges (both directions) of open two-sided lines
    FOR li IN 0 .. l_n - 1 LOOP
      f := l_fsec(li); b := l_bsec(li);
      IF f <> -1 AND b <> -1 AND LEAST(s_ce(f), s_ce(b)) - GREATEST(s_fl(f), s_fl(b)) > 0 THEN
        IF NOT adj_cnt.EXISTS(f) THEN adj_cnt(f) := 0; END IF;
        IF NOT adj_cnt.EXISTS(b) THEN adj_cnt(b) := 0; END IF;
        adj_cnt(f) := adj_cnt(f) + 1; adj_cnt(b) := adj_cnt(b) + 1;
      END IF;
    END LOOP;
    pos := 0; s := adj_cnt.FIRST;
    WHILE s IS NOT NULL LOOP adj_start(s) := pos; tmp(s) := pos; pos := pos + adj_cnt(s); s := adj_cnt.NEXT(s); END LOOP;
    FOR li IN 0 .. l_n - 1 LOOP
      f := l_fsec(li); b := l_bsec(li);
      IF f <> -1 AND b <> -1 AND LEAST(s_ce(f), s_ce(b)) - GREATEST(s_fl(f), s_fl(b)) > 0 THEN
        bl := CASE WHEN BITAND(l_flags(li), 64) <> 0 THEN 1 ELSE 0 END;
        adj_to(tmp(f)) := b; adj_blk(tmp(f)) := bl; tmp(f) := tmp(f) + 1;
        adj_to(tmp(b)) := f; adj_blk(tmp(b)) := bl; tmp(b) := tmp(b) + 1;
      END IF;
    END LOOP;
    WHILE qh < qt LOOP
      s := q_s(qh); bl := q_b(qh); qh := qh + 1;
      flood(s) := TRUE;
      IF adj_cnt.EXISTS(s) THEN
        FOR e IN adj_start(s) .. adj_start(s) + adj_cnt(s) - 1 LOOP
          nb := bl + adj_blk(e);
          IF nb <= 1 AND NOT vis.EXISTS(adj_to(e) * 2 + nb) THEN
            vis(adj_to(e) * 2 + nb) := TRUE; q_s(qt) := adj_to(e); q_b(qt) := nb; qt := qt + 1;
          END IF;
        END LOOP;
      END IF;
    END LOOP;
    SELECT ai.thing_id, NVL(ai.sector_id, rt.sector_id) BULK COLLECT INTO ids, secs
      FROM g_monster_ai ai
      JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
      JOIN g_render_things rt ON rt.map_id = ai.map_id AND rt.thing_id = ai.thing_id
     WHERE ai.map_id = p_map AND ai.state = 'stand'
       AND NOT EXISTS (SELECT 1 FROM thing_combat_defs cd WHERE cd.thing_type = t.type AND cd.explodes);
    FOR i IN 1 .. ids.COUNT LOOP
      IF secs(i) IS NOT NULL AND flood.EXISTS(secs(i)) THEN
        UPDATE g_monster_ai SET state = 'see', seq_index = 0, state_tics = 0 WHERE map_id = p_map AND thing_id = ids(i);
      END IF;
    END LOOP;
  END;

  -- line of sight: any blocking line (one-sided, or two-sided with no vertical opening) that
  -- crosses (ax,ay)-(bx,by) by the reference's strict side tests; p_bbox adds the reference's
  -- line/segment bounding-box filter (doom_cs_monster_think), which a crossing satisfies anyway.
  FUNCTION sight_blocked(ax BINARY_DOUBLE, ay BINARY_DOUBLE, bx BINARY_DOUBLE, by_ BINARY_DOUBLE,
                         p_bbox BOOLEAN) RETURN BOOLEAN IS
    cand t_int; nc PLS_INTEGER; li PLS_INTEGER; f PLS_INTEGER; b PLS_INTEGER;
    x0 BINARY_DOUBLE := LEAST(ax, bx); x1 BINARY_DOUBLE := GREATEST(ax, bx);
    y0 BINARY_DOUBLE := LEAST(ay, by_); y1 BINARY_DOUBLE := GREATEST(ay, by_);
    d1 BINARY_DOUBLE; d2 BINARY_DOUBLE; d3 BINARY_DOUBLE; d4 BINARY_DOUBLE;
  BEGIN
    grid_seg(ax, ay, bx, by_, cand, nc);
    FOR q IN 0 .. nc - 1 LOOP
      li := cand(q);
      IF NOT l_open(li) THEN NULL;
      ELSE
        f := l_fsec(li); b := l_bsec(li);
        IF LEAST(s_ce(f), s_ce(b)) > GREATEST(s_fl(f), s_fl(b)) THEN CONTINUE; END IF;
      END IF;
      IF NOT p_bbox OR (LEAST(l_x1(li), l_x2(li)) <= x1 AND GREATEST(l_x1(li), l_x2(li)) >= x0
                        AND LEAST(l_y1(li), l_y2(li)) <= y1 AND GREATEST(l_y1(li), l_y2(li)) >= y0) THEN
        d1 := (ax - l_x1(li)) * (l_y2(li) - l_y1(li)) - (ay - l_y1(li)) * (l_x2(li) - l_x1(li));
        d2 := (bx - l_x1(li)) * (l_y2(li) - l_y1(li)) - (by_ - l_y1(li)) * (l_x2(li) - l_x1(li));
        IF d1 * d2 < 0 THEN
          d3 := (l_x1(li) - ax) * (by_ - ay) - (l_y1(li) - ay) * (bx - ax);
          d4 := (l_x2(li) - ax) * (by_ - ay) - (l_y2(li) - ay) * (bx - ax);
          IF d3 * d4 < 0 THEN RETURN TRUE; END IF;
        END IF;
      END IF;
    END LOOP;
    RETURN FALSE;
  END;

  -- activation (sight and range) and one step of every monster's state/frame animation
  PROCEDURE cs_monster_think(p_map NUMBER, p_player NUMBER) IS
    m_id t_num; m_state t_str; m_tics t_num; m_seq t_num; m_cool t_num; m_type t_num;
    m_x t_dbl; m_y t_dbl; m_face t_dbl; m_alive t_bool; m_health t_num; m_maxh t_num; m_xd t_str;
    m_expl t_bool; m_range t_dbl; m_fast t_bool; m_fired t_bool; m_tx t_dbl; m_ty t_dbl; m_tgt t_num;
    u_id t_num; u_state t_str; u_tics t_num; u_seq t_num; u_cool t_num; u_fired t_bool; nu PLS_INTEGER := 0;
    px BINARY_DOUBLE; py BINARY_DOUBLE; v_skill NUMBER;
    visible BOOLEAN; cone BOOLEAN; dist BINARY_DOUBLE; near BOOLEAN; adv BOOLEAN; ns VARCHAR2(8); nq NUMBER;
    nt NUMBER; nc NUMBER; atk BOOLEAN; fr_t NUMBER; fr_a BOOLEAN; mx_see NUMBER; mx_mis NUMBER; mx_pain NUMBER;
    mx_die NUMBER; mx_xd NUMBER; fired BOOLEAN; dx BINARY_DOUBLE; dy BINARY_DOUBLE; sr2 BINARY_DOUBLE;
    FUNCTION maxseq(p_type NUMBER, p_state VARCHAR2) RETURN NUMBER IS
      k VARCHAR2(64) := p_type || ':' || p_state;
    BEGIN
      IF fa_max.EXISTS(k) THEN RETURN fa_max(k); END IF;
      RETURN NULL;
    END;
  BEGIN
    SELECT t.x, t.y, g.skill INTO px, py, v_skill
      FROM g_things t JOIN g_game_tic_commands g ON g.map_id = t.map_id AND g.player_thing_id = t.id
     WHERE t.map_id = p_map AND t.id = p_player;
    SELECT /*+ LEADING(ai h t) USE_NL(h) USE_NL(t) INDEX(h) INDEX(t) */
           ai.thing_id, ai.state, ai.state_tics, ai.seq_index, ai.attack_cooldown, t.type, t.x, t.y, t.angle,
           h.alive, h.health, h.max_health, ai.fired_this_tick, ai.target_thing_id
      BULK COLLECT INTO m_id, m_state, m_tics, m_seq, m_cool, m_type, m_x, m_y, m_face, m_alive, m_health, m_maxh,
           m_fired, m_tgt
      FROM g_monster_ai ai
      JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
      JOIN g_thing_health h ON h.map_id = ai.map_id AND h.thing_id = ai.thing_id
     WHERE ai.map_id = p_map AND (h.alive OR ai.state <> 'dead');
    FOR i IN 1 .. m_id.COUNT LOOP
      m_xd(i) := tc_xd(m_type(i)); m_expl(i) := NVL(tc_expl(m_type(i)), FALSE);
      m_range(i) := tc_range(m_type(i)); m_fast(i) := NVL(tc_fast(m_type(i)), FALSE);
      -- mon_target: the target's position while it lives (a thing or a player), else the player's
      m_tx(i) := px; m_ty(i) := py;
      IF m_tgt(i) IS NOT NULL AND m_tgt(i) <> p_player THEN
        FOR tg IN (SELECT tt.x, tt.y FROM g_things tt
                    WHERE tt.map_id = p_map AND tt.id = m_tgt(i)
                      AND (EXISTS (SELECT 1 FROM g_thing_health th WHERE th.map_id = p_map AND th.thing_id = tt.id AND th.alive)
                           OR EXISTS (SELECT 1 FROM g_player_state ps WHERE ps.map_id = p_map AND ps.player_thing_id = tt.id
                                        AND ps.alive))) LOOP
          m_tx(i) := tg.x; m_ty(i) := tg.y;
        END LOOP;
      END IF;
    END LOOP;
    tmark('th_sql');
    load_sectors(p_map);
    tmark('th_blk');
    sr2 := k_sight_range * k_sight_range;
    FOR i IN 1 .. m_id.COUNT LOOP
      dx := m_x(i) - m_tx(i); dy := m_y(i) - m_ty(i);
      near := dx * dx + dy * dy <= sr2;
      IF near THEN
        visible := NOT sight_blocked(m_x(i), m_y(i), m_tx(i), m_ty(i), TRUE);
        cone := (COS(m_face(i) * c_rad) * (m_tx(i) - m_x(i)) + SIN(m_face(i) * c_rad) * (m_ty(i) - m_y(i))) > 0;
      ELSE
        visible := FALSE; cone := FALSE;
      END IF;
      dist := SQRT(dx * dx + dy * dy);
      adv := m_tics(i) <= 1 OR (NOT m_alive(i) AND m_state(i) NOT IN ('die', 'dead', 'xdeath'));
      mx_see := maxseq(m_type(i), 'see'); mx_mis := maxseq(m_type(i), 'missile'); mx_pain := maxseq(m_type(i), 'pain');
      mx_die := maxseq(m_type(i), 'die'); mx_xd := maxseq(m_type(i), 'xdeath');
      IF NOT m_alive(i) AND m_state(i) NOT IN ('die', 'dead', 'xdeath') THEN
        ns := CASE WHEN m_health(i) < -m_maxh(i) AND m_xd(i) IS NOT NULL THEN 'xdeath' ELSE 'die' END; nq := 0;
      ELSIF m_state(i) = 'die' THEN
        IF m_tics(i) > 1 THEN ns := 'die'; nq := m_seq(i);
        ELSIF m_seq(i) >= mx_die THEN ns := 'dead'; nq := 0;
        ELSE ns := 'die'; nq := m_seq(i) + 1; END IF;
      ELSIF m_state(i) = 'xdeath' THEN
        IF m_tics(i) > 1 THEN ns := 'xdeath'; nq := m_seq(i);
        ELSIF m_seq(i) >= mx_xd THEN ns := 'dead'; nq := 0;
        ELSE ns := 'xdeath'; nq := m_seq(i) + 1; END IF;
      ELSIF m_expl(i) THEN ns := 'stand'; nq := 0;
      ELSIF m_state(i) = 'stand' THEN
        ns := CASE WHEN visible AND cone AND dist <= k_sight_range THEN 'see' ELSE 'stand' END; nq := 0;
      ELSIF m_tics(i) > 1 THEN ns := m_state(i); nq := m_seq(i);
      ELSIF m_state(i) = 'see' THEN
        IF visible AND dist <= m_range(i) AND m_cool(i) <= 0 THEN ns := 'missile'; nq := 0;
        ELSE ns := 'see'; nq := CASE WHEN m_seq(i) >= mx_see THEN 0 ELSE m_seq(i) + 1 END; END IF;
      ELSIF m_state(i) = 'missile' THEN
        IF m_seq(i) >= mx_mis THEN ns := 'see'; nq := 0; ELSE ns := 'missile'; nq := m_seq(i) + 1; END IF;
      ELSIF m_state(i) = 'pain' THEN
        IF m_seq(i) >= mx_pain THEN ns := 'see'; nq := 0; ELSE ns := 'pain'; nq := m_seq(i) + 1; END IF;
      ELSE ns := m_state(i); nq := m_seq(i);
      END IF;
      IF fa_tics.EXISTS(m_type(i) || ':' || ns || ':' || nq) THEN
        fr_t := fa_tics(m_type(i) || ':' || ns || ':' || nq); fr_a := fa_atk(m_type(i) || ':' || ns || ':' || nq);
      ELSE fr_t := NULL; fr_a := FALSE; END IF;
      IF NOT adv THEN nt := m_tics(i) - 1;
      ELSIF ns = 'stand' THEN nt := -1;
      ELSIF m_fast(i) AND ns IN ('see', 'missile', 'pain') AND v_skill = 4 THEN nt := GREATEST(1, FLOOR(NVL(fr_t, -1) / 2));
      ELSE nt := NVL(fr_t, -1); END IF;
      nc := CASE WHEN m_state(i) = 'missile' AND ns = 'see' THEN 30 ELSE GREATEST(0, m_cool(i) - 1) END;
      fired := adv AND fr_a;
      IF ns <> m_state(i) OR nt <> m_tics(i) OR nq <> m_seq(i) OR nc <> m_cool(i) OR fired <> m_fired(i) THEN
        nu := nu + 1; u_id(nu) := m_id(i); u_state(nu) := ns; u_tics(nu) := nt; u_seq(nu) := nq; u_cool(nu) := nc;
        u_fired(nu) := fired;
      END IF;
    END LOOP;
    tmark('th_los');
    FORALL i IN 1 .. nu
      UPDATE g_monster_ai SET state = u_state(i), state_tics = u_tics(i), seq_index = u_seq(i),
                              attack_cooldown = u_cool(i), fired_this_tick = u_fired(i)
       WHERE map_id = p_map AND thing_id = u_id(i);
  END;

  -- A_Chase's step: P_NewChaseDir's direction order, P_TryMove against walls and solid things
  FUNCTION cs_monster_step(p_map NUMBER, p_player NUMBER) RETURN BOOLEAN IS
    c_id t_num; c_x t_dbl; c_y t_dbl; c_r t_dbl; c_fl t_bool; c_md t_num; c_mc t_num; c_tx t_dbl; c_ty t_dbl;
    s_id t_num; s_x t_dbl; s_y t_dbl; s_r t_dbl; s_cx t_int; s_cy t_int;
    px BINARY_DOUBLE; py BINARY_DOUBLE; lt NUMBER; v_bit NUMBER;
    turnaround NUMBER; dxd NUMBER; dyd NUMBER; diag NUMBER; swap BOOLEAN; sweep BOOLEAN; fresh NUMBER; keep BOOLEAN;
    pri t_num; ord t_int; tmp PLS_INTEGER; p1 NUMBER; tdx BINARY_DOUBLE; tdy BINARY_DOUBLE;
    nx BINARY_DOUBLE; ny BINARY_DOUBLE; blocked BOOLEAN; found BOOLEAN; cell_x PLS_INTEGER; cell_y PLS_INTEGER;
    cand t_int; ncand PLS_INTEGER; li PLS_INTEGER; f PLS_INTEGER; b PLS_INTEGER; isblk BOOLEAN; steponly BOOLEAN;
    lx0 BINARY_DOUBLE; lx1 BINARY_DOUBLE; ly0 BINARY_DOUBLE; ly1 BINARY_DOUBLE;
    dxl BINARY_DOUBLE; dyl BINARY_DOUBLE; den BINARY_DOUBLE; tt BINARY_DOUBLE; ex BINARY_DOUBLE; ey BINARY_DOUBLE;
    d1 BINARY_DOUBLE; d2 BINARY_DOUBLE; d3 BINARY_DOUBLE; d4 BINARY_DOUBLE;
    w_id t_num; w_ox t_flt; w_oy t_flt; w_nx t_flt; w_ny t_flt; w_fa t_flt; w_md t_num; w_mc t_num; nw PLS_INTEGER := 0;
    best_d PLS_INTEGER; best_mc NUMBER; v_stepped BOOLEAN := FALSE;
    cminx BINARY_DOUBLE; cmaxx BINARY_DOUBLE; cminy BINARY_DOUBLE; cmaxy BINARY_DOUBLE; ns PLS_INTEGER;
  BEGIN
    SELECT t.x, t.y, ps.level_tics, g.skill_bit INTO px, py, lt, v_bit
      FROM g_things t
      JOIN g_player_state ps ON ps.map_id = t.map_id AND ps.player_thing_id = t.id
      JOIN g_game_tic_commands g ON g.map_id = t.map_id AND g.player_thing_id = t.id
     WHERE t.map_id = p_map AND t.id = p_player;
    SELECT ai.thing_id, t.x, t.y, d.radius, d.floats, ai.movedir, ai.movecount,
           NVL(TO_BINARY_DOUBLE(tt.x), px), NVL(TO_BINARY_DOUBLE(tt.y), py)
      BULK COLLECT INTO c_id, c_x, c_y, c_r, c_fl, c_md, c_mc, c_tx, c_ty
      FROM g_monster_ai ai
      JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
      JOIN thing_combat_defs d ON d.thing_type = t.type
      JOIN thing_ai_frames f ON f.thing_type = t.type AND f.state = 'see' AND f.seq_index = ai.seq_index
      LEFT JOIN (SELECT thing_id FROM g_thing_health WHERE map_id = p_map AND alive
                 UNION ALL SELECT player_thing_id FROM g_player_state WHERE map_id = p_map AND alive) th
        ON th.thing_id = ai.target_thing_id
      LEFT JOIN g_things tt ON tt.map_id = ai.map_id AND tt.id = th.thing_id
     WHERE ai.map_id = p_map AND ai.state = 'see' AND NOT d.explodes
       AND (ai.state_tics = f.tics OR ai.state_tics = FLOOR(f.tics / 2))
     ORDER BY ai.thing_id;
    IF c_id.COUNT = 0 THEN RETURN FALSE; END IF;
    -- solid things: live actors, solid decorations, live players. A candidate only consults the
    -- 3x3 cells around it, so things farther than two cells from every chaser cannot matter.
    cminx := c_x(1); cmaxx := c_x(1); cminy := c_y(1); cmaxy := c_y(1);
    FOR i IN 2 .. c_id.COUNT LOOP
      cminx := LEAST(cminx, c_x(i)); cmaxx := GREATEST(cmaxx, c_x(i));
      cminy := LEAST(cminy, c_y(i)); cmaxy := GREATEST(cmaxy, c_y(i));
    END LOOP;
    ns := 0;
    FOR rr IN (SELECT t.id, t.x, t.y, t.type, t.flags, h.alive
                 FROM g_things t LEFT JOIN g_thing_health h ON h.map_id = t.map_id AND h.thing_id = t.id
                WHERE t.map_id = p_map
                  AND t.x BETWEEN cminx - 3 * k_blockmap_cell AND cmaxx + 3 * k_blockmap_cell
                  AND t.y BETWEEN cminy - 3 * k_blockmap_cell AND cmaxy + 3 * k_blockmap_cell) LOOP
      IF tc_radius.EXISTS(rr.type) AND NVL(rr.alive, FALSE) THEN
        ns := ns + 1; s_id(ns) := rr.id; s_x(ns) := rr.x; s_y(ns) := rr.y; s_r(ns) := tc_radius(rr.type);
      END IF;
      IF bd_radius.EXISTS(rr.type) AND BITAND(rr.flags, v_bit) <> 0 AND BITAND(rr.flags, 16) = 0 THEN
        ns := ns + 1; s_id(ns) := rr.id; s_x(ns) := rr.x; s_y(ns) := rr.y; s_r(ns) := bd_radius(rr.type);
      END IF;
    END LOOP;
    FOR rr IN (SELECT ps.player_thing_id, t.x, t.y FROM g_player_state ps
                 JOIN g_things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
                WHERE ps.map_id = p_map AND ps.alive) LOOP
      ns := ns + 1; s_id(ns) := rr.player_thing_id; s_x(ns) := rr.x; s_y(ns) := rr.y; s_r(ns) := k_player_radius;
    END LOOP;
    FOR i IN 1 .. ns LOOP
      s_cx(i) := FLOOR(s_x(i) / k_blockmap_cell); s_cy(i) := FLOOR(s_y(i) / k_blockmap_cell);
    END LOOP;
    load_sectors(p_map);
    FOR i IN 1 .. c_id.COUNT LOOP
      turnaround := CASE WHEN c_md(i) IS NOT NULL THEN cd_opp(c_md(i)) END;
      tdx := c_tx(i) - c_x(i); tdy := c_ty(i) - c_y(i);
      dxd := CASE WHEN tdx > k_chase_deadband THEN 0 WHEN tdx < -k_chase_deadband THEN 4 END;
      dyd := CASE WHEN tdy < -k_chase_deadband THEN 6 WHEN tdy > k_chase_deadband THEN 2 END;
      diag := CASE WHEN tdx > 0 THEN CASE WHEN tdy >= 0 THEN 1 ELSE 7 END
                   ELSE CASE WHEN tdy >= 0 THEN 3 ELSE 5 END END;
      swap := prandom(c_id(i), lt, 50) > k_chase_swap OR ABS(tdy) > ABS(tdx);
      sweep := BITAND(prandom(c_id(i), lt, 51), 1) = 1;
      fresh := BITAND(prandom(c_id(i), lt, 52), k_chase_mask);
      keep := c_mc(i) > 0 AND c_md(i) IS NOT NULL;
      FOR d IN 0 .. 7 LOOP
        p1 := 99;
        IF keep AND d = c_md(i) THEN p1 := LEAST(p1, -1); END IF;
        IF dxd IS NOT NULL AND dyd IS NOT NULL AND d = diag AND (turnaround IS NULL OR diag <> turnaround) THEN p1 := LEAST(p1, 0); END IF;
        IF d = CASE WHEN swap THEN dyd ELSE dxd END AND (turnaround IS NULL OR d <> turnaround) THEN p1 := LEAST(p1, 1); END IF;
        IF d = CASE WHEN swap THEN dxd ELSE dyd END AND (turnaround IS NULL OR d <> turnaround) THEN p1 := LEAST(p1, 2); END IF;
        IF d = c_md(i) THEN p1 := LEAST(p1, 3); END IF;
        IF turnaround IS NULL OR d <> turnaround THEN p1 := LEAST(p1, 4 + CASE WHEN sweep THEN d ELSE 7 - d END); END IF;
        IF d = turnaround THEN p1 := LEAST(p1, 12); END IF;
        pri(d) := p1; ord(d) := d;
      END LOOP;
      -- directions by priority (ties cannot occur between different directions except 99s)
      FOR a IN 1 .. 7 LOOP
        FOR bb IN REVERSE 1 .. a LOOP
          EXIT WHEN pri(ord(bb)) >= pri(ord(bb - 1));
          tmp := ord(bb); ord(bb) := ord(bb - 1); ord(bb - 1) := tmp;
        END LOOP;
      END LOOP;
      found := FALSE;
      FOR o IN 0 .. 7 LOOP
        EXIT WHEN pri(ord(o)) >= 99;
        nx := c_x(i) + k_monster_step * cd_dx(ord(o)); ny := c_y(i) + k_monster_step * cd_dy(ord(o));
        blocked := FALSE;
        -- solid things in the 3x3 cells around the candidate
        cell_x := FLOOR(nx / k_blockmap_cell); cell_y := FLOOR(ny / k_blockmap_cell);
        FOR s IN 1 .. ns LOOP
          IF s_id(s) <> c_id(i) AND ABS(s_cx(s) - cell_x) <= 1 AND ABS(s_cy(s) - cell_y) <= 1
             AND ABS(s_x(s) - nx) < s_r(s) + c_r(i) AND ABS(s_y(s) - ny) < s_r(s) + c_r(i) THEN
            blocked := TRUE; EXIT;
          END IF;
        END LOOP;
        IF NOT blocked THEN
          lx1 := GREATEST(nx, c_x(i)) + c_r(i) + 2d; lx0 := LEAST(nx, c_x(i)) - c_r(i) - 2d;
          ly1 := GREATEST(ny, c_y(i)) + c_r(i) + 2d; ly0 := LEAST(ny, c_y(i)) - c_r(i) - 2d;
          grid_lines(lx0, ly0, lx1, ly1, cand, ncand);
          FOR q IN 0 .. ncand - 1 LOOP
            li := cand(q);
            IF LEAST(l_x1(li), l_x2(li)) <= lx1 AND GREATEST(l_x1(li), l_x2(li)) >= lx0
               AND LEAST(l_y1(li), l_y2(li)) <= ly1 AND GREATEST(l_y1(li), l_y2(li)) >= ly0 THEN
              f := l_fsec(li); b := l_bsec(li);
              isblk := l_lsd(li) = -1 OR l_rsd(li) = -1 OR BITAND(l_flags(li), 1) <> 0;
              steponly := FALSE;
              IF NOT isblk AND f <> -1 AND b <> -1 THEN
                IF LEAST(s_ce(f), s_ce(b)) - GREATEST(s_fl(f), s_fl(b)) < k_min_walk THEN isblk := TRUE;
                ELSIF ABS(s_fl(b) - s_fl(f)) > k_maxstep THEN isblk := TRUE; steponly := TRUE; END IF;
              END IF;
              IF isblk AND NOT (steponly AND c_fl(i)) THEN
                dxl := l_x2(li) - l_x1(li); dyl := l_y2(li) - l_y1(li);
                den := dxl * dxl + dyl * dyl;
                IF den = 0 THEN tt := 0;
                ELSE tt := LEAST(1d, GREATEST(0d, ((nx - l_x1(li)) * dxl + (ny - l_y1(li)) * dyl) / den)); END IF;
                ex := nx - (l_x1(li) + tt * dxl); ey := ny - (l_y1(li) + tt * dyl);
                IF SQRT(ex * ex + ey * ey) < c_r(i) THEN blocked := TRUE; EXIT; END IF;
                d1 := (c_x(i) - l_x1(li)) * dyl - (c_y(i) - l_y1(li)) * dxl;
                d2 := (nx - l_x1(li)) * dyl - (ny - l_y1(li)) * dxl;
                d3 := (l_x1(li) - c_x(i)) * (ny - c_y(i)) - (l_y1(li) - c_y(i)) * (nx - c_x(i));
                d4 := (l_x2(li) - c_x(i)) * (ny - c_y(i)) - (l_y2(li) - c_y(i)) * (nx - c_x(i));
                IF d1 * d2 < 0 AND d3 * d4 < 0 THEN blocked := TRUE; EXIT; END IF;
              END IF;
            END IF;
          END LOOP;
        END IF;
        IF NOT blocked THEN
          found := TRUE; best_d := ord(o);
          best_mc := CASE WHEN pri(ord(o)) = -1 THEN c_mc(i) - 1 ELSE fresh END;
          EXIT;
        END IF;
      END LOOP;
      nw := nw + 1; w_id(nw) := c_id(i); w_ox(nw) := c_x(i); w_oy(nw) := c_y(i);
      IF found THEN
        w_nx(nw) := c_x(i) + k_monster_step * cd_dx(best_d); w_ny(nw) := c_y(i) + k_monster_step * cd_dy(best_d);
        w_fa(nw) := cd_ang(best_d); w_md(nw) := best_d; w_mc(nw) := GREATEST(0, best_mc);
        IF w_nx(nw) <> w_ox(nw) OR w_ny(nw) <> w_oy(nw) THEN v_stepped := TRUE; END IF;
      ELSE
        w_nx(nw) := c_x(i); w_ny(nw) := c_y(i); w_fa(nw) := 0; w_md(nw) := NULL; w_mc(nw) := fresh;
      END IF;
    END LOOP;
    FORALL i IN 1 .. nw
      INSERT INTO g_monster_steps (map_id, thing_id, old_x, old_y, new_x, new_y, face_angle, movedir, movecount)
      VALUES (p_map, w_id(i), w_ox(i), w_oy(i), w_nx(i), w_ny(i), w_fa(i), w_md(i), w_mc(i));
    FORALL i IN 1 .. nw
      UPDATE g_monster_ai SET movedir = w_md(i), movecount = w_mc(i)
       WHERE map_id = p_map AND thing_id = w_id(i)
         AND (DECODE(movedir, w_md(i), 0, 1) = 1 OR movecount <> w_mc(i));
    RETURN v_stepped;
  END;

  -- apply the staged steps, the monster-crossable lines they crossed, and teleports
  PROCEDURE cs_monster_move(p_map NUMBER, p_player NUMBER) IS
    s_id t_num; s_ox t_flt; s_oy t_flt; s_nx t_flt; s_ny t_flt;
    li PLS_INTEGER; ff BOOLEAN; e BINARY_DOUBLE; old_side BINARY_DOUBLE; new_side BINARY_DOUBLE;
    v1s BINARY_DOUBLE; v2s BINARY_DOUBLE; v_act NUMBER; x1 BINARY_FLOAT; y1 BINARY_FLOAT; x2 BINARY_FLOAT; y2 BINARY_FLOAT;
    ddx BINARY_FLOAT; ddy BINARY_FLOAT; v_n NUMBER;
  BEGIN
    MERGE INTO g_things t
    USING (SELECT thing_id, new_x, new_y, face_angle FROM g_monster_steps
            WHERE map_id = p_map AND (new_x <> old_x OR new_y <> old_y)) ms
       ON (t.map_id = p_map AND t.id = ms.thing_id)
     WHEN MATCHED THEN UPDATE SET t.x = ms.new_x, t.y = ms.new_y, t.angle = ms.face_angle;
    SELECT thing_id, old_x, old_y, new_x, new_y BULK COLLECT INTO s_id, s_ox, s_oy, s_nx, s_ny
      FROM g_monster_steps WHERE map_id = p_map AND (new_x <> old_x OR new_y <> old_y);
    FOR i IN 1 .. s_id.COUNT LOOP
      ddx := s_nx(i) - s_ox(i); ddy := s_ny(i) - s_oy(i);       -- real - real
      FOR li IN 0 .. l_n - 1 LOOP
        IF l_mcross(li) THEN
          x1 := l_x1(li); y1 := l_y1(li); x2 := l_x2(li); y2 := l_y2(li);
          e := TO_BINARY_DOUBLE(x2 - x1) * TO_BINARY_DOUBLE(s_oy(i) - y1) - TO_BINARY_DOUBLE(y2 - y1) * TO_BINARY_DOUBLE(s_ox(i) - x1);
          ff := e < 0; old_side := ABS(e);
          new_side := TO_BINARY_DOUBLE(x2 - x1) * TO_BINARY_DOUBLE(s_ny(i) - y1) - TO_BINARY_DOUBLE(y2 - y1) * TO_BINARY_DOUBLE(s_nx(i) - x1);
          v1s := ddx * TO_BINARY_DOUBLE(y1 - s_oy(i)) - ddy * TO_BINARY_DOUBLE(x1 - s_ox(i));
          v2s := ddx * TO_BINARY_DOUBLE(y2 - s_oy(i)) - ddy * TO_BINARY_DOUBLE(x2 - s_ox(i));
          IF old_side > 1e-7d AND new_side <> 0 AND ((ff AND new_side > 0) OR (NOT ff AND new_side < 0))
             AND v1s * v2s < 0 THEN
            v_act := 0;
            IF l_cross_once(li) THEN
              SELECT COUNT(*) INTO v_act FROM g_line_activations WHERE map_id = p_map AND line_id = li;
            END IF;
            IF v_act = 0 THEN
              INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_line_special_events g_line_special_events_pk) */
                INTO g_line_special_events (map_id, player_thing_id, line_id, trigger_type, from_front)
              VALUES (p_map, s_id(i), li, 'cross', ff);
            END IF;
          END IF;
        END IF;
      END LOOP;
    END LOOP;
    -- EV_Teleport for a monster
    DELETE FROM g_monster_teleports WHERE map_id = p_map;
    INSERT INTO g_monster_teleports (map_id, thing_id, dest_x, dest_y, dest_angle, sector_id)
    SELECT map_id, thing_id, dest_x, dest_y, dest_angle, sector_id FROM (
      SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.map_id, c.thing_id ORDER BY c.off_centre, c.dest_id) AS rn
        FROM (SELECT t.map_id, t.thing_id, t.sector_id, th.id AS dest_id, th.x AS dest_x, th.y AS dest_y,
                     th.angle AS dest_angle,
                     ABS(th.x - (t.min_x + t.max_x) / 2) + ABS(th.y - (t.min_y + t.max_y) / 2) AS off_centre
                FROM (SELECT e.map_id, e.player_thing_id AS thing_id, s.id AS sector_id,
                             MIN(rs.x1) AS min_x, MAX(rs.x1) AS max_x, MIN(rs.y1) AS min_y, MAX(rs.y1) AS max_y
                        FROM g_line_special_events e
                        JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
                        JOIN line_special_defs d ON d.special = ld.special AND d.mechanic = 'teleport'
                        JOIN g_monster_ai ai ON ai.map_id = e.map_id AND ai.thing_id = e.player_thing_id
                        JOIN g_sectors s ON s.map_id = e.map_id AND s.tag = ld.tag
                        JOIN g_render_segs rs ON rs.map_id = s.map_id AND rs.fsec = s.id
                       WHERE e.map_id = p_map AND e.trigger_type = 'cross'
                       GROUP BY e.map_id, e.player_thing_id, s.id) t
                JOIN g_things th ON th.map_id = t.map_id
                JOIN thing_role_defs tr ON tr.thing_type = th.type AND tr.is_teleport_dest
                 AND th.x BETWEEN t.min_x AND t.max_x AND th.y BETWEEN t.min_y AND t.max_y) c)
     WHERE rn = 1;
    IF SQL%ROWCOUNT > 0 THEN
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_sound_events g_sound_events_uk) */
        INTO g_sound_events (map_id, event_key, level_tic, sound_name, source_thing_id, source_x, source_y)
      SELECT mt.map_id, 'mon-tele-out:' || mt.thing_id || ':' || ps.level_tics, ps.level_tics, 'DSTELEPT', mt.thing_id,
             ms.old_x, ms.old_y
        FROM g_monster_teleports mt
        JOIN g_monster_steps ms ON ms.map_id = mt.map_id AND ms.thing_id = mt.thing_id
        JOIN g_player_state ps ON ps.map_id = mt.map_id AND ps.player_thing_id = p_player
       WHERE mt.map_id = p_map
      UNION ALL
      SELECT mt.map_id, 'mon-tele-in:' || mt.thing_id || ':' || ps.level_tics, ps.level_tics, 'DSTELEPT', mt.thing_id,
             mt.dest_x, mt.dest_y
        FROM g_monster_teleports mt JOIN g_player_state ps ON ps.map_id = mt.map_id AND ps.player_thing_id = p_player
       WHERE mt.map_id = p_map;
      MERGE INTO g_things t USING (SELECT * FROM g_monster_teleports WHERE map_id = p_map) mt
         ON (t.map_id = p_map AND t.id = mt.thing_id)
       WHEN MATCHED THEN UPDATE SET t.x = mt.dest_x, t.y = mt.dest_y, t.angle = mt.dest_angle;
      MERGE INTO g_monster_ai ai USING (SELECT * FROM g_monster_teleports WHERE map_id = p_map) mt
         ON (ai.map_id = p_map AND ai.thing_id = mt.thing_id)
       WHEN MATCHED THEN UPDATE SET ai.sector_id = mt.sector_id
        WHERE ai.sector_id IS NULL OR ai.sector_id <> mt.sector_id;
    END IF;
  END;

  -- P_ZMovement's float and A_SkullAttack (cacodemons, lost souls)
  PROCEDURE cs_monster_float(p_map NUMBER, p_player NUMBER) IS
    v_skull_speed BINARY_DOUBLE := k('SKULL_CHARGE_SPEED');
    v_reach BINARY_DOUBLE := k('SKULL_HIT_REACH');
    v_ticrate NUMBER := k('TICRATE');
  BEGIN
    MERGE INTO g_things t
    USING (SELECT ai.thing_id, s.floor_height, s.ceil_height, d.height,
                  (TO_BINARY_DOUBLE(ps.base_z) - k_viewheight + k_player_height / 2d) - th.z AS delta,
                  SQRT((pt.x - th.x) * (pt.x - th.x) + (pt.y - th.y) * (pt.y - th.y)) AS dist
             FROM g_monster_ai ai
             JOIN g_things th ON th.map_id = ai.map_id AND th.id = ai.thing_id
             LEFT JOIN g_render_things rt ON rt.map_id = ai.map_id AND rt.thing_id = ai.thing_id
             JOIN g_sectors s ON s.map_id = ai.map_id AND s.id = NVL(ai.sector_id, rt.sector_id)
             JOIN g_player_state ps ON ps.map_id = ai.map_id AND ps.player_thing_id = NVL(ai.target_thing_id, p_player)
             JOIN g_things pt ON pt.map_id = ps.map_id AND pt.id = ps.player_thing_id
             JOIN thing_combat_defs d ON d.thing_type = th.type
            WHERE ai.map_id = p_map AND d.floats AND ai.state IN ('see', 'missile')) q
       ON (t.map_id = p_map AND t.id = q.thing_id)
     WHEN MATCHED THEN UPDATE SET t.z = LEAST(q.ceil_height - q.height, GREATEST(q.floor_height,
          t.z + CASE WHEN q.delta > 0 AND q.dist < q.delta * 3 THEN 4 WHEN q.delta < 0 AND q.dist < -q.delta * 3 THEN -4 ELSE 0 END));
    MERGE INTO g_things t
    USING (SELECT ai.thing_id, TO_BINARY_DOUBLE(pt.x) AS tx, TO_BINARY_DOUBLE(pt.y) AS ty,
                  SQRT((pt.x - th.x) * (pt.x - th.x) + (pt.y - th.y) * (pt.y - th.y)) AS len
             FROM g_monster_ai ai
             JOIN g_things th ON th.map_id = ai.map_id AND th.id = ai.thing_id
             JOIN g_things pt ON pt.map_id = ai.map_id AND pt.id = NVL(ai.target_thing_id, p_player)
             JOIN thing_combat_defs d ON d.thing_type = th.type AND d.skull_fly
            WHERE ai.map_id = p_map AND ai.fired_this_tick) q
       ON (t.map_id = p_map AND t.id = q.thing_id)
     WHEN MATCHED THEN UPDATE SET t.mom_x = v_skull_speed * (q.tx - t.x) / q.len, t.mom_y = v_skull_speed * (q.ty - t.y) / q.len
      WHERE q.len > 0;
    UPDATE g_monster_ai ai
       SET charge_tics = CASE WHEN ai.fired_this_tick THEN v_ticrate ELSE GREATEST(0, ai.charge_tics - 1) END
     WHERE ai.map_id = p_map AND (ai.fired_this_tick OR ai.charge_tics > 0)
       AND EXISTS (SELECT 1 FROM g_things t JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
                    WHERE t.map_id = ai.map_id AND t.id = ai.thing_id);
    MERGE INTO g_player_state ps
    USING (SELECT ps2.map_id, ps2.player_thing_id, q.dmg,
                  LEAST(ps2.armor, CASE ps2.armor_class WHEN 2 THEN TRUNC(q.dmg / 2) WHEN 1 THEN TRUNC(q.dmg / 3) ELSE 0 END) AS saved
             FROM g_player_state ps2
             JOIN (SELECT ps3.player_thing_id,
                          SUM((MOD(doom_game.prandom(t.id, ps3.level_tics, 21), d.charge_sides) + 1) * d.charge_mult) AS dmg
                     FROM g_monster_ai ai
                     JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
                     JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
                     JOIN g_player_state ps3 ON ps3.map_id = ai.map_id AND ps3.alive
                     JOIN g_things pt ON pt.map_id = ps3.map_id AND pt.id = ps3.player_thing_id
                    WHERE ai.map_id = p_map AND ai.charge_tics > 0
                      AND ABS(pt.x - t.x) < v_reach AND ABS(pt.y - t.y) < v_reach
                    GROUP BY ps3.player_thing_id) q ON q.player_thing_id = ps2.player_thing_id
            WHERE ps2.map_id = p_map AND NOT ps2.god_mode AND ps2.invuln_tics <= 0) d
       ON (ps.map_id = d.map_id AND ps.player_thing_id = d.player_thing_id)
     WHEN MATCHED THEN UPDATE SET
       ps.armor = ps.armor - d.saved,
       ps.armor_class = CASE WHEN ps.armor - d.saved <= 0 THEN 0 ELSE ps.armor_class END,
       ps.health = GREATEST(0, ps.health - (d.dmg - d.saved)),
       ps.damage_count = LEAST(100, ps.damage_count + (d.dmg - d.saved)),
       ps.pain_face_tics = 12,
       ps.alive = CASE WHEN ps.health - (d.dmg - d.saved) > 0 THEN TRUE ELSE FALSE END,
       ps.killer_id = CASE WHEN ps.health - (d.dmg - d.saved) <= 0 THEN -1 ELSE ps.killer_id END;
    UPDATE g_things t SET mom_x = 0, mom_y = 0
     WHERE t.map_id = p_map
       AND EXISTS (SELECT 1 FROM g_monster_ai ai JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
                    WHERE ai.map_id = t.map_id AND ai.thing_id = t.id AND ai.charge_tics > 0)
       AND EXISTS (SELECT 1 FROM g_player_state ps JOIN g_things pt ON pt.map_id = ps.map_id AND pt.id = ps.player_thing_id
                    WHERE ps.map_id = t.map_id AND ABS(pt.x - t.x) < v_reach AND ABS(pt.y - t.y) < v_reach);
    UPDATE g_monster_ai ai SET charge_tics = 0
     WHERE ai.map_id = p_map AND ai.charge_tics > 0 AND NOT ai.fired_this_tick
       AND EXISTS (SELECT 1 FROM g_things t JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
                    WHERE t.map_id = ai.map_id AND t.id = ai.thing_id AND t.mom_x = 0 AND t.mom_y = 0);
  END;

  -- a blocked monster opens the door (P_UseSpecialLine for monsters); live sectors for chasers
  PROCEDURE cs_monster_chase(p_map NUMBER, p_player NUMBER) IS
    m_id t_num; m_x t_flt; m_y t_flt; m_r t_dbl; ptx BINARY_FLOAT; pty BINARY_FLOAT;
    dist BINARY_DOUBLE; sx BINARY_DOUBLE; sy BINARY_DOUBLE; u BINARY_DOUBLE; den BINARY_DOUBLE;
    ex BINARY_DOUBLE; ey BINARY_DOUBLE; gap BINARY_DOUBLE; dxf BINARY_FLOAT; dyf BINARY_FLOAT;
    TYPE t_kb IS TABLE OF BOOLEAN INDEX BY PLS_INTEGER; busy t_kb; usable t_kb;
    b_sec NUMBER; ids t_num; xs t_flt; ys t_flt; secs t_num; ns NUMBER; li PLS_INTEGER;
  BEGIN
    SELECT x, y INTO ptx, pty FROM g_things WHERE map_id = p_map AND id = p_player;
    SELECT ai.thing_id, t.x, t.y, cd.radius BULK COLLECT INTO m_id, m_x, m_y, m_r
      FROM g_monster_ai ai JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
      JOIN thing_combat_defs cd ON cd.thing_type = t.type
     WHERE ai.map_id = p_map AND ai.state = 'see' AND NOT cd.explodes;
    IF m_id.COUNT > 0 THEN
      FOR r IN (SELECT sector_id FROM g_sector_movers WHERE map_id = p_map AND direction <> -1) LOOP
        busy(r.sector_id) := TRUE;
      END LOOP;
      FOR i IN 1 .. m_id.COUNT LOOP
        dxf := ptx - m_x(i); dyf := pty - m_y(i);
        dist := SQRT(dxf * dxf + dyf * dyf);                    -- real arithmetic, then widened
        IF dist <> 0 THEN
          sx := m_x(i) + (8f * dxf) / dist; sy := m_y(i) + (8f * dyf) / dist;
          FOR q IN 0 .. l_use_n - 1 LOOP
            li := l_use_list(q);
            BEGIN
              b_sec := NULL;
              IF l_lsd(li) <> -1 THEN b_sec := l_bsec(li); END IF;
              IF b_sec IS NULL OR b_sec = -1 OR NOT busy.EXISTS(b_sec) THEN
                den := (l_x2(li) - l_x1(li)) * (l_x2(li) - l_x1(li)) + (l_y2(li) - l_y1(li)) * (l_y2(li) - l_y1(li));
                IF den = 0 THEN u := 0;
                ELSE u := LEAST(1d, GREATEST(0d, ((sx - l_x1(li)) * (l_x2(li) - l_x1(li)) + (sy - l_y1(li)) * (l_y2(li) - l_y1(li))) / den)); END IF;
                ex := sx - (l_x1(li) + u * (l_x2(li) - l_x1(li))); ey := sy - (l_y1(li) + u * (l_y2(li) - l_y1(li)));
                gap := SQRT(ex * ex + ey * ey);
                IF gap < m_r(i) THEN
                  INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_line_special_events g_line_special_events_pk) */
                    INTO g_line_special_events (map_id, player_thing_id, line_id, trigger_type, from_front)
                  VALUES (p_map, m_id(i), li, 'use', TRUE);
                END IF;
              END IF;
            END;
          END LOOP;
        END IF;
      END LOOP;
    END IF;
    -- live sector for chasers that stepped this tic (or were never placed)
    SELECT ai.thing_id, t.x, t.y, ai.sector_id BULK COLLECT INTO ids, xs, ys, secs
      FROM g_monster_ai ai JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
     WHERE ai.map_id = p_map AND ai.state = 'see'
       AND (ai.sector_id IS NULL OR EXISTS (SELECT 1 FROM g_monster_steps ms WHERE ms.map_id = ai.map_id AND ms.thing_id = ai.thing_id));
    FOR i IN 1 .. ids.COUNT LOOP
      ns := sector_at(p_map, xs(i), ys(i));
      IF ns IS NOT NULL AND (secs(i) IS NULL OR secs(i) <> ns) THEN
        UPDATE g_monster_ai SET sector_id = ns WHERE map_id = p_map AND thing_id = ids(i);
      END IF;
    END LOOP;
    MERGE INTO g_render_things rt
    USING (SELECT thing_id, sector_id FROM g_monster_ai WHERE map_id = p_map AND sector_id IS NOT NULL) ai
       ON (rt.map_id = p_map AND rt.thing_id = ai.thing_id)
     WHEN MATCHED THEN UPDATE SET rt.sector_id = ai.sector_id WHERE rt.sector_id <> ai.sector_id;
  END;

  -- monsters' attack frames: hitscan pellets, bites, barrel blasts; then their effects
  PROCEDURE cs_monster_attack(p_map NUMBER, p_player NUMBER) IS
    v_spread BINARY_DOUBLE := k('HITSCAN_SPREAD_UNITS');
    v_shmiss BINARY_DOUBLE := k('SHADOW_MISS_UNITS');
    v_melee BINARY_DOUBLE := k('MELEE_REACH');
    v_shadowed BOOLEAN; v_lt NUMBER; dist BINARY_DOUBLE; visible BOOLEAN;
    r1 NUMBER; r2 NUMBER; pdmg NUMBER; serr BINARY_DOUBLE; dmg NUMBER; v_any NUMBER;
    pl_alive BOOLEAN; plx BINARY_DOUBLE; ply BINARY_DOUBLE;
  BEGIN
    DELETE FROM g_monster_attack_damage WHERE map_id = p_map;
    SELECT CASE WHEN ps.invis_tics > 0 THEN TRUE ELSE FALSE END, ps.level_tics, ps.alive, t.x, t.y
      INTO v_shadowed, v_lt, pl_alive, plx, ply
      FROM g_player_state ps JOIN g_things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
     WHERE ps.map_id = p_map AND ps.player_thing_id = p_player;
    load_sectors(p_map);
    FOR a IN (SELECT ai.thing_id, TO_BINARY_DOUBLE(t.x) AS mx, TO_BINARY_DOUBLE(t.y) AS my, d.hitscan_pellets,
                     d.melee_mult, d.melee_sides, d.explodes, d.blast_radius, d.hitscan_mult, d.hitscan_sides,
                     ai.target_thing_id
                FROM g_monster_ai ai JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
                JOIN thing_combat_defs d ON d.thing_type = t.type
               WHERE ai.map_id = p_map AND ai.fired_this_tick ORDER BY ai.thing_id) LOOP
      -- the players this attack considers: the one it is angry with, or every live player for a barrel
      FOR pp IN (SELECT ps.player_thing_id, TO_BINARY_DOUBLE(t.x) AS px, TO_BINARY_DOUBLE(t.y) AS py
                   FROM g_player_state ps JOIN g_things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
                  WHERE ps.map_id = p_map AND ps.alive AND (a.explodes OR ps.player_thing_id = p_player)
                 UNION ALL
                 SELECT p_player, plx, ply FROM dual WHERE NOT pl_alive) LOOP
        DECLARE
          tx BINARY_DOUBLE := pp.px; ty BINARY_DOUBLE := pp.py; vid NUMBER := NULL; vpl NUMBER := pp.player_thing_id;
          ttx BINARY_FLOAT; tty BINARY_FLOAT; th_alive NUMBER; tp_alive NUMBER;
        BEGIN
          IF a.target_thing_id IS NOT NULL THEN
            BEGIN
              SELECT x, y INTO ttx, tty FROM g_things WHERE map_id = p_map AND id = a.target_thing_id;
              tx := ttx; ty := tty;
            EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
            END;
            SELECT COUNT(*) INTO th_alive FROM g_thing_health WHERE map_id = p_map AND thing_id = a.target_thing_id AND alive;
            SELECT COUNT(*) INTO tp_alive FROM g_player_state WHERE map_id = p_map AND player_thing_id = a.target_thing_id AND alive;
            IF th_alive > 0 THEN vid := a.target_thing_id; END IF;
            IF tp_alive > 0 THEN vpl := a.target_thing_id; END IF;
          END IF;
          dist := SQRT((a.mx - tx) * (a.mx - tx) + (a.my - ty) * (a.my - ty));
          visible := NOT sight_blocked(a.mx, a.my, tx, ty, FALSE);
          IF a.hitscan_pellets IS NOT NULL THEN
            FOR g IN 1 .. a.hitscan_pellets LOOP
              r1 := prandom(a.thing_id, v_lt * 8 + g, 12); r2 := prandom(a.thing_id, v_lt * 8 + g, 13);
              pdmg := (MOD(prandom(a.thing_id, v_lt * 8 + g, 14), a.hitscan_sides) + 1) * a.hitscan_mult;
              IF v_shadowed THEN serr := (prandom(a.thing_id, v_lt, 15) - prandom(a.thing_id, v_lt, 16)) * 360 / v_shmiss;
              ELSE serr := 0d; END IF;
              IF visible AND dist <= k_attack_range_def
                 AND (dist <= k_player_radius
                      OR ABS((r1 - r2) * 360 / v_spread + serr)
                         <= ASIN(LEAST(1d, CASE WHEN dist = 0 THEN 1d ELSE k_player_radius / dist END)) * c_deg) THEN
                dmg := pdmg;
              ELSE dmg := 0; END IF;
              INSERT INTO g_monster_attack_damage (map_id, attacker_id, victim_id, victim_player, dmg, mx, my)
              VALUES (p_map, a.thing_id, vid, vpl, dmg, a.mx, a.my);
            END LOOP;
          END IF;
          IF a.melee_mult IS NOT NULL OR a.explodes THEN
            IF a.melee_mult IS NOT NULL AND visible AND dist <= v_melee THEN
              dmg := (MOD(prandom(a.thing_id, v_lt, 17), a.melee_sides) + 1) * a.melee_mult;
            ELSIF a.explodes AND visible AND dist < a.blast_radius THEN
              dmg := GREATEST(0, a.blast_radius - FLOOR(dist));
            ELSE dmg := 0; END IF;
            INSERT INTO g_monster_attack_damage (map_id, attacker_id, victim_id, victim_player, dmg, mx, my)
            VALUES (p_map, a.thing_id, vid, vpl, dmg, a.mx, a.my);
          END IF;
        END;
      END LOOP;
    END LOOP;
    SELECT COUNT(*) INTO v_any FROM g_monster_attack_damage WHERE map_id = p_map;
    IF v_any = 0 THEN RETURN; END IF;
    -- the staged rolls landing on a player
    MERGE INTO g_player_state ps
    USING (
      WITH players AS (
        SELECT ps2.player_thing_id, TO_BINARY_DOUBLE(t.x) AS px, TO_BINARY_DOUBLE(t.y) AS py
          FROM g_player_state ps2 JOIN g_things t ON t.map_id = ps2.map_id AND t.id = ps2.player_thing_id
         WHERE ps2.map_id = p_map AND ps2.alive),
      hurt AS (
        SELECT FLOOR(d.dmg / CASE WHEN g.skill = 0 THEN 2 ELSE 1 END) AS dmg, d.mx, d.my, d.victim_player
          FROM g_monster_attack_damage d
          JOIN g_game_tic_commands g ON g.map_id = p_map AND g.player_thing_id = d.victim_player
         WHERE d.map_id = p_map AND d.victim_id IS NULL),
      shove AS (
        SELECT h.dmg, h.victim_player,
               CASE WHEN r.dist > 0 THEN h.dmg * 0.125d * r.ddx / r.dist ELSE 0d END AS tx,
               CASE WHEN r.dist > 0 THEN h.dmg * 0.125d * r.ddy / r.dist ELSE 0d END AS ty
          FROM hurt h JOIN players pp ON pp.player_thing_id = h.victim_player
          CROSS APPLY (SELECT pp.px - h.mx AS ddx, pp.py - h.my AS ddy,
                              SQRT((pp.px - h.mx) * (pp.px - h.mx) + (pp.py - h.my) * (pp.py - h.my)) AS dist FROM dual) r),
      totaled AS (
        SELECT victim_player AS player_thing_id, SUM(dmg) AS total_dmg, SUM(FLOOR(dmg / 3)) AS green_saved,
               SUM(FLOOR(dmg / 2)) AS blue_saved,
               SUM(doom_game.rnd(tx * 65536d)) / 65536d AS thrust_x, SUM(doom_game.rnd(ty * 65536d)) / 65536d AS thrust_y
          FROM shove GROUP BY victim_player),
      absorbed AS (
        SELECT t.*, CASE WHEN ps3.god_mode OR ps3.invuln_tics > 0 THEN 1 ELSE 0 END AS blocked,
               CASE WHEN ps3.god_mode OR ps3.invuln_tics > 0 THEN 0
                    ELSE LEAST(ps3.armor, CASE ps3.armor_class WHEN 2 THEN t.blue_saved WHEN 1 THEN t.green_saved ELSE 0 END)
               END AS saved
          FROM totaled t JOIN g_player_state ps3 ON ps3.map_id = p_map AND ps3.player_thing_id = t.player_thing_id)
      SELECT a.*, CASE WHEN a.blocked = 1 THEN 0 ELSE a.total_dmg - a.saved END AS took FROM absorbed a) a
    ON (ps.map_id = p_map AND ps.player_thing_id = a.player_thing_id)
    WHEN MATCHED THEN UPDATE SET
      ps.armor = ps.armor - a.saved,
      ps.armor_class = CASE WHEN ps.armor - a.saved <= 0 THEN 0 ELSE ps.armor_class END,
      ps.health = GREATEST(0, ps.health - a.took),
      ps.damage_count = LEAST(100, ps.damage_count + a.took),
      ps.alive = CASE WHEN GREATEST(0, ps.health - a.took) > 0 THEN TRUE ELSE FALSE END,
      ps.pain_face_tics = CASE WHEN a.took > 0 THEN 12 ELSE ps.pain_face_tics END,
      ps.killer_id = CASE WHEN ps.alive AND ps.health - a.took <= 0 THEN -1 ELSE ps.killer_id END,
      ps.momentum_x = ps.momentum_x + a.thrust_x,
      ps.momentum_y = ps.momentum_y + a.thrust_y;
    -- the same rolls landing on a monster (infighting)
    MERGE INTO g_thing_health h
    USING (SELECT victim_id, SUM(dmg) AS dmg FROM g_monster_attack_damage
            WHERE map_id = p_map AND victim_id IS NOT NULL AND victim_player = p_player GROUP BY victim_id) v
       ON (h.map_id = p_map AND h.thing_id = v.victim_id)
     WHEN MATCHED THEN UPDATE SET h.health = h.health - v.dmg,
                                  h.alive = CASE WHEN h.health - v.dmg > 0 THEN TRUE ELSE FALSE END
      WHERE v.dmg > 0;
    MERGE INTO g_monster_ai ai
    USING (SELECT victim_id, MIN(attacker_id) AS attacker FROM g_monster_attack_damage
            WHERE map_id = p_map AND victim_id IS NOT NULL AND dmg > 0 AND victim_player = p_player
            GROUP BY victim_id) v
       ON (ai.map_id = p_map AND ai.thing_id = v.victim_id)
     WHEN MATCHED THEN UPDATE SET
       ai.target_thing_id = v.attacker,
       ai.state = CASE WHEN ai.state = 'stand' THEN 'see' ELSE ai.state END,
       ai.seq_index = CASE WHEN ai.state = 'stand' THEN 0 ELSE ai.seq_index END,
       ai.state_tics = CASE WHEN ai.state = 'stand' THEN 0 ELSE ai.state_tics END
      WHERE ai.thing_id <> v.attacker AND (ai.target_thing_id IS NULL OR ai.target_thing_id <> v.attacker)
        AND EXISTS (SELECT 1 FROM g_thing_health th WHERE th.map_id = ai.map_id AND th.thing_id = ai.thing_id AND th.alive);
  END;

  -- exploding-barrel radius damage
  PROCEDURE cs_monster_barrel(p_map NUMBER) IS
  BEGIN
    MERGE INTO g_thing_health h
    USING (
      WITH explosions AS (
        -- INLINE (explosions, blast): referenced 3x each; no temp-table materialisation
        SELECT /*+ INLINE */ t.id AS source_id, TO_BINARY_DOUBLE(t.x) AS ex, TO_BINARY_DOUBLE(t.y) AS ey
          FROM g_monster_ai ai JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
          JOIN thing_combat_defs cd ON cd.thing_type = t.type AND cd.explodes
         WHERE ai.map_id = p_map AND ai.fired_this_tick),
      blast AS (SELECT /*+ INLINE */ MAX(blast_radius) AS r FROM thing_combat_defs WHERE explodes),
      victims AS (
        SELECT DISTINCT h2.thing_id, TO_BINARY_DOUBLE(t.x) AS vx, TO_BINARY_DOUBLE(t.y) AS vy
          FROM explosions e CROSS JOIN blast bl
          JOIN g_things t ON t.map_id = p_map AND t.x BETWEEN e.ex - bl.r AND e.ex + bl.r
           AND t.y BETWEEN e.ey - bl.r AND e.ey + bl.r
          JOIN g_thing_health h2 ON h2.map_id = t.map_id AND h2.thing_id = t.id AND h2.alive),
      blocking_walls AS (
        SELECT DISTINCT TO_BINARY_DOUBLE(ld.x1) AS x1, TO_BINARY_DOUBLE(ld.y1) AS y1,
               TO_BINARY_DOUBLE(ld.x2) AS x2, TO_BINARY_DOUBLE(ld.y2) AS y2
          FROM explosions e CROSS JOIN blast bl
          JOIN linedef_geom ld ON ld.map_id = p_map
          LEFT JOIN g_sectors fr ON fr.map_id = ld.map_id AND fr.id = ld.fsec
          LEFT JOIN g_sectors bk ON bk.map_id = ld.map_id AND bk.id = ld.bsec
         WHERE (ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR fr.id IS NULL OR bk.id IS NULL
                OR LEAST(fr.ceil_height, bk.ceil_height) <= GREATEST(fr.floor_height, bk.floor_height))
           AND LEAST(ld.x1, ld.x2) <= e.ex + bl.r AND GREATEST(ld.x1, ld.x2) >= e.ex - bl.r
           AND LEAST(ld.y1, ld.y2) <= e.ey + bl.r AND GREATEST(ld.y1, ld.y2) >= e.ey - bl.r)
      SELECT v.thing_id, SUM(GREATEST(0, bl.r - FLOOR(SQRT((v.vx - e.ex) * (v.vx - e.ex) + (v.vy - e.ey) * (v.vy - e.ey))))) AS damage
        FROM explosions e CROSS JOIN victims v CROSS JOIN blast bl
       WHERE v.thing_id <> e.source_id
         AND SQRT((v.vx - e.ex) * (v.vx - e.ex) + (v.vy - e.ey) * (v.vy - e.ey)) < bl.r
         AND NOT EXISTS (
           SELECT 1 FROM blocking_walls b
            WHERE ((e.ex - b.x1) * (b.y2 - b.y1) - (e.ey - b.y1) * (b.x2 - b.x1))
                * ((v.vx - b.x1) * (b.y2 - b.y1) - (v.vy - b.y1) * (b.x2 - b.x1)) < 0
              AND ((b.x1 - e.ex) * (v.vy - e.ey) - (b.y1 - e.ey) * (v.vx - e.ex))
                * ((b.x2 - e.ex) * (v.vy - e.ey) - (b.y2 - e.ey) * (v.vx - e.ex)) < 0)
       GROUP BY v.thing_id) r
    ON (h.map_id = p_map AND h.thing_id = r.thing_id)
    WHEN MATCHED THEN UPDATE SET h.health = h.health - r.damage,
                                 h.alive = CASE WHEN h.health - r.damage > 0 THEN TRUE ELSE FALSE END;
  END;

  -- P_DamageMobj's thrust from rockets and barrels
  PROCEDURE cs_monster_blast(p_map NUMBER) IS
  BEGIN
    MERGE INTO g_things t
    USING (
      WITH explosions AS (
        SELECT i.projectile_id, mp.owner_thing_id AS source_id, TO_BINARY_DOUBLE(i.x) AS ex, TO_BINARY_DOUBLE(i.y) AS ey
          FROM g_projectile_impacts i
          JOIN g_monster_projectiles mp ON mp.map_id = i.map_id AND mp.projectile_id = i.projectile_id
         WHERE i.map_id = p_map AND i.projectile_type = 'rocket'
        UNION ALL
        SELECT -ai.thing_id, ai.thing_id, TO_BINARY_DOUBLE(t.x), TO_BINARY_DOUBLE(t.y)
          FROM g_monster_ai ai JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
          JOIN thing_combat_defs cd ON cd.thing_type = t.type AND cd.explodes
         WHERE ai.map_id = p_map AND ai.fired_this_tick)
      SELECT v.id AS thing_id,
             SUM(doom_game.rnd(TO_BINARY_DOUBLE(GREATEST(0, 128 - FLOOR(d.dist)) * 12.5 / GREATEST(1, cd.mass))
                               * d.dx / d.dist * 65536d)) / 65536d AS push_x,
             SUM(doom_game.rnd(TO_BINARY_DOUBLE(GREATEST(0, 128 - FLOOR(d.dist)) * 12.5 / GREATEST(1, cd.mass))
                               * d.dy / d.dist * 65536d)) / 65536d AS push_y
        FROM explosions e
        JOIN g_things v ON v.map_id = p_map
        JOIN thing_combat_defs cd ON cd.thing_type = v.type
        CROSS APPLY (SELECT TO_BINARY_DOUBLE(v.x) - e.ex AS dx, TO_BINARY_DOUBLE(v.y) - e.ey AS dy,
                            SQRT((TO_BINARY_DOUBLE(v.x) - e.ex) * (TO_BINARY_DOUBLE(v.x) - e.ex)
                               + (TO_BINARY_DOUBLE(v.y) - e.ey) * (TO_BINARY_DOUBLE(v.y) - e.ey)) AS dist FROM dual) d
       WHERE v.id <> e.source_id AND d.dist < 128 AND d.dist > 0
       GROUP BY v.id) s
    ON (t.map_id = p_map AND t.id = s.thing_id)
    WHEN MATCHED THEN UPDATE SET t.mom_x = t.mom_x + s.push_x, t.mom_y = t.mom_y + s.push_y;
  END;

  -- settled corpses and P_NightmareRespawn's pick
  FUNCTION cs_monster_deaths(p_map NUMBER, p_player NUMBER) RETURN BOOLEAN IS
    v_tics NUMBER := k('MONSTER_RESPAWN_TICS'); v_n NUMBER; v_mresp NUMBER := 0;
  BEGIN
    FOR m IN (SELECT 1 FROM g_mp_match WHERE map_id = p_map AND respawn_monsters) LOOP v_mresp := 1; END LOOP;
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_monster_deaths g_monster_deaths_pk) */
      INTO g_monster_deaths (map_id, thing_id, death_tic)
    SELECT /*+ LEADING(ai t d ps) USE_NL(t) USE_NL(d) USE_NL(ps) */ ai.map_id, ai.thing_id, ps.level_tics   -- 67 -> 25 us
      FROM g_monster_ai ai
      JOIN g_things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
      JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill
      JOIN g_player_state ps ON ps.map_id = ai.map_id AND ps.player_thing_id = p_player
     WHERE ai.map_id = p_map AND ai.state = 'dead'
       AND NOT EXISTS (SELECT 1 FROM g_monster_deaths md WHERE md.map_id = ai.map_id AND md.thing_id = ai.thing_id);
    DELETE FROM g_monster_respawns WHERE map_id = p_map;
    INSERT INTO g_monster_respawns (map_id, thing_id, old_x, old_y)
    SELECT md.map_id, md.thing_id, t.x, t.y
      FROM g_monster_deaths md
      JOIN g_things t ON t.map_id = md.map_id AND t.id = md.thing_id
      JOIN g_player_state ps ON ps.map_id = md.map_id AND ps.player_thing_id = p_player
     WHERE md.map_id = p_map
       AND ((SELECT g.skill FROM g_game_tic_commands g WHERE g.map_id = p_map AND g.player_thing_id = p_player) = 4
            -- -respawn: the same rule on any skill (the match row is read once per call)
            OR v_mresp = 1)
       AND ps.level_tics - md.death_tic >= v_tics
       AND BITAND(ps.level_tics, 31) = 0
       AND doom_game.prandom(md.thing_id, ps.level_tics, 40) <= 4
       AND NOT EXISTS (
         SELECT 1 FROM g_thing_health oh
           JOIN g_things ot ON ot.map_id = oh.map_id AND ot.id = oh.thing_id
           JOIN thing_combat_defs od ON od.thing_type = ot.type
           JOIN thing_combat_defs md2 ON md2.thing_type = t.type
          WHERE oh.map_id = md.map_id AND oh.alive AND oh.thing_id <> md.thing_id
            AND (ot.x - t.spawn_x) * (ot.x - t.spawn_x) + (ot.y - t.spawn_y) * (ot.y - t.spawn_y)
                < (od.radius + md2.radius) * (od.radius + md2.radius));
    v_n := SQL%ROWCOUNT;
    RETURN v_n > 0;
  END;

  PROCEDURE cs_monster_respawn(p_map NUMBER, p_player NUMBER) IS
    v_base NUMBER := k('MONSTER_RESPAWN_EFFECT_ID_BASE'); v_span NUMBER := k('EFFECT_ID_TIC_SPAN');
  BEGIN
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_world_effects g_world_effects_pk) */
      INTO g_world_effects (map_id, effect_id, effect_type, x, y, z, sector_id, age)
    SELECT r.map_id, v_base + r.thing_id * v_span * 2 + MOD(ps.level_tics, v_span) * 2 + e.k, 'tfog',
           CASE e.k WHEN 0 THEN r.old_x ELSE TO_BINARY_FLOAT(t.spawn_x) END,
           CASE e.k WHEN 0 THEN r.old_y ELSE TO_BINARY_FLOAT(t.spawn_y) END,
           s.floor_height, CASE e.k WHEN 0 THEN rt.sector_id ELSE rt.spawn_sector_id END, 0
      FROM g_monster_respawns r
      JOIN g_things t ON t.map_id = r.map_id AND t.id = r.thing_id
      JOIN g_render_things rt ON rt.map_id = r.map_id AND rt.thing_id = r.thing_id
      JOIN g_player_state ps ON ps.map_id = r.map_id AND ps.player_thing_id = p_player
      CROSS JOIN (SELECT 0 AS k FROM dual UNION ALL SELECT 1 FROM dual) e
      JOIN g_sectors s ON s.map_id = r.map_id
       AND s.id = CASE e.k WHEN 0 THEN rt.sector_id ELSE NVL(rt.spawn_sector_id, rt.sector_id) END
     WHERE r.map_id = p_map;
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_sound_events g_sound_events_uk) */
      INTO g_sound_events (map_id, event_key, level_tic, sound_name, source_thing_id, source_x, source_y)
    SELECT r.map_id, 'respawn-out:' || r.thing_id || ':' || ps.level_tics, ps.level_tics, 'DSTELEPT', r.thing_id, r.old_x, r.old_y
      FROM g_monster_respawns r JOIN g_player_state ps ON ps.map_id = r.map_id AND ps.player_thing_id = p_player
     WHERE r.map_id = p_map
    UNION ALL
    SELECT r.map_id, 'respawn-in:' || r.thing_id || ':' || ps.level_tics, ps.level_tics, 'DSTELEPT', r.thing_id,
           TO_BINARY_FLOAT(t.spawn_x), TO_BINARY_FLOAT(t.spawn_y)
      FROM g_monster_respawns r JOIN g_things t ON t.map_id = r.map_id AND t.id = r.thing_id
      JOIN g_player_state ps ON ps.map_id = r.map_id AND ps.player_thing_id = p_player
     WHERE r.map_id = p_map;
    DELETE FROM g_sound_events e
     WHERE e.map_id = p_map
       AND EXISTS (SELECT 1 FROM g_monster_respawns r WHERE r.map_id = e.map_id
                     AND e.event_key IN ('mon-sight:' || r.thing_id, 'mon-death:' || r.thing_id));
    UPDATE g_things t SET x = spawn_x, y = spawn_y, angle = spawn_angle
     WHERE t.map_id = p_map AND t.id IN (SELECT thing_id FROM g_monster_respawns WHERE map_id = p_map);
    UPDATE g_thing_health h SET health = max_health, alive = TRUE
     WHERE h.map_id = p_map AND h.thing_id IN (SELECT thing_id FROM g_monster_respawns WHERE map_id = p_map);
    UPDATE g_render_things rt SET sector_id = spawn_sector_id
     WHERE rt.map_id = p_map AND rt.thing_id IN (SELECT thing_id FROM g_monster_respawns WHERE map_id = p_map)
       AND rt.spawn_sector_id IS NOT NULL AND rt.sector_id <> rt.spawn_sector_id;
    MERGE INTO g_monster_ai ai
    USING (SELECT r.thing_id, rt.sector_id FROM g_monster_respawns r
             JOIN g_render_things rt ON rt.map_id = r.map_id AND rt.thing_id = r.thing_id WHERE r.map_id = p_map) q
       ON (ai.map_id = p_map AND ai.thing_id = q.thing_id)
     WHEN MATCHED THEN UPDATE SET ai.state = 'stand', ai.state_tics = -1, ai.seq_index = 0, ai.attack_cooldown = 18,
                                  ai.fired_this_tick = FALSE, ai.sector_id = q.sector_id;
    DELETE FROM g_monster_deaths d
     WHERE d.map_id = p_map AND d.thing_id IN (SELECT thing_id FROM g_monster_respawns WHERE map_id = p_map);
  END;

  PROCEDURE cs_monsters(p_map NUMBER, p_player NUMBER) IS
    pre PLS_INTEGER; plan PLS_INTEGER; stepped BOOLEAN := FALSE;
  BEGIN
    pre := cs_monster_plan(p_map);
    cs_monster_retarget(p_map, p_player);
    IF BITAND(pre, 1) <> 0 THEN cs_monster_noise(p_map); END IF;
    tmark('m_pre');
    cs_monster_think(p_map, p_player);
    tmark('m_think');
    plan := cs_monster_plan(p_map);
    DELETE FROM g_monster_steps WHERE map_id = p_map;
    IF BITAND(plan, 2) <> 0 THEN stepped := cs_monster_step(p_map, p_player); END IF;
    tmark('m_step');
    IF stepped THEN cs_monster_move(p_map, p_player); END IF;
    IF BITAND(plan, 4) <> 0 THEN cs_monster_float(p_map, p_player); END IF;
    IF BITAND(plan, 8) <> 0 THEN cs_monster_chase(p_map, p_player); END IF;
    tmark('m_chase');
    IF BITAND(plan, 16) <> 0 THEN cs_monster_attack(p_map, p_player); END IF;
    IF BITAND(plan, 32) <> 0 THEN cs_monster_barrel(p_map); END IF;
    IF BITAND(plan, 64) <> 0 THEN cs_monster_blast(p_map); END IF;
    IF cs_monster_deaths(p_map, p_player) THEN cs_monster_respawn(p_map, p_player); END IF;
    tmark('m_rest');
  END;

  -- =====================================================================
  -- doom_cs_sector_fx (28), doom_cs_thing_physics (29), doom_cs_boss (35)
  -- =====================================================================
  PROCEDURE cs_sector_fx(p_map NUMBER, p_player NUMBER) IS
    v_int NUMBER := k('DAMAGE_FLOOR_INTERVAL');
    v_go NUMBER;
  BEGIN
    UPDATE g_player_state ps SET god_mode = FALSE
     WHERE ps.map_id = p_map AND ps.player_thing_id = p_player AND ps.god_mode
       AND EXISTS (SELECT 1 FROM g_sectors s JOIN sector_special_defs sd ON sd.special = s.special AND sd.ends_level_at_low_health
                    WHERE s.map_id = ps.map_id AND s.id = ps.sector_id);
    -- the damage MERGE below only matches under these conditions; test them first
    SELECT COUNT(*) INTO v_go FROM g_player_state ps
     WHERE ps.map_id = p_map AND ps.player_thing_id = p_player AND ps.alive AND ps.radsuit_tics <= 0
       AND NOT ps.god_mode AND ps.invuln_tics <= 0 AND MOD(ps.level_tics, v_int) = 0;
    IF v_go = 0 THEN RETURN; END IF;
    MERGE INTO g_player_state ps
    USING (SELECT s.id AS sector_id, k2.amount,
                  LEAST(ps2.armor, CASE ps2.armor_class WHEN 2 THEN FLOOR(k2.amount / 2) WHEN 1 THEN FLOOR(k2.amount / 3)
                                   ELSE 0 END) AS saved
             FROM g_sectors s
             JOIN sector_special_defs sd ON sd.special = s.special AND sd.damage_per_hit IS NOT NULL
             CROSS APPLY (SELECT FLOOR(sd.damage_per_hit / CASE WHEN (SELECT g.skill FROM g_game_tic_commands g
                                   WHERE g.map_id = p_map AND g.player_thing_id = p_player) = 0 THEN 2 ELSE 1 END) AS amount
                            FROM dual) k2
             JOIN g_player_state ps2 ON ps2.map_id = s.map_id AND ps2.player_thing_id = p_player
            WHERE s.map_id = p_map) d
       ON (ps.map_id = p_map AND ps.player_thing_id = p_player AND ps.sector_id = d.sector_id)
     WHEN MATCHED THEN UPDATE SET
       ps.armor = ps.armor - d.saved,
       ps.armor_class = CASE WHEN ps.armor - d.saved <= 0 THEN 0 ELSE ps.armor_class END,
       ps.health = GREATEST(0, ps.health - (d.amount - d.saved)),
       ps.damage_count = LEAST(100, ps.damage_count + (d.amount - d.saved)),
       ps.pain_face_tics = 12,
       ps.alive = CASE WHEN ps.health - (d.amount - d.saved) > 0 THEN TRUE ELSE FALSE END,
       ps.killer_id = CASE WHEN ps.health - (d.amount - d.saved) <= 0 THEN -1 ELSE ps.killer_id END
      WHERE ps.alive AND ps.radsuit_tics <= 0 AND NOT ps.god_mode AND ps.invuln_tics <= 0
        AND MOD(ps.level_tics, v_int) = 0;
  END;

  PROCEDURE cs_thing_physics(p_map NUMBER) IS
    m_id t_num; m_x t_dbl; m_y t_dbl; m_mx t_dbl; m_my t_dbl; m_r t_dbl; m_sk t_bool; m_air t_bool;
    o_id t_num; o_x t_dbl; o_y t_dbl; o_r t_dbl;
    blocked BOOLEAN; f PLS_INTEGER; b PLS_INTEGER; isw BOOLEAN; nx BINARY_DOUBLE; ny BINARY_DOUBLE;
    cand t_int; nc PLS_INTEGER; li PLS_INTEGER; v_n NUMBER; v_small NUMBER;
  BEGIN
    SELECT NVL(SUM(CASE WHEN ABS(mom_x) > k_stopspeed OR ABS(mom_y) > k_stopspeed THEN 1 ELSE 0 END), 0),
           NVL(SUM(CASE WHEN mom_x <> 0 OR mom_y <> 0 THEN 1 ELSE 0 END), 0)
      INTO v_n, v_small FROM g_things WHERE map_id = p_map;
    IF v_n > 0 THEN
      SELECT t.id, t.x, t.y, t.mom_x, t.mom_y, cd.radius, cd.skull_fly,
             CASE WHEN cd.floats AND NVL(h.alive, FALSE) AND t.z > sec.floor_height THEN TRUE ELSE FALSE END
        BULK COLLECT INTO m_id, m_x, m_y, m_mx, m_my, m_r, m_sk, m_air
        FROM g_things t
        JOIN thing_combat_defs cd ON cd.thing_type = t.type
        JOIN g_render_things rt ON rt.map_id = t.map_id AND rt.thing_id = t.id
        LEFT JOIN g_thing_health h ON h.map_id = t.map_id AND h.thing_id = t.id
        LEFT JOIN g_monster_ai ai ON ai.map_id = t.map_id AND ai.thing_id = t.id
        JOIN g_sectors sec ON sec.map_id = t.map_id AND sec.id = NVL(ai.sector_id, rt.sector_id)
       WHERE t.map_id = p_map AND (ABS(t.mom_x) > k_stopspeed OR ABS(t.mom_y) > k_stopspeed)
         AND NOT EXISTS (SELECT 1 FROM g_player_state ps WHERE ps.map_id = t.map_id AND ps.player_thing_id = t.id);
      IF m_id.COUNT > 0 THEN
        load_sectors(p_map);
        SELECT o.id, o.x, o.y, od.radius BULK COLLECT INTO o_id, o_x, o_y, o_r
          FROM g_things o JOIN thing_combat_defs od ON od.thing_type = o.type
          JOIN g_thing_health oh ON oh.map_id = o.map_id AND oh.thing_id = o.id AND oh.alive
         WHERE o.map_id = p_map;
        FOR i IN 1 .. m_id.COUNT LOOP
          blocked := FALSE;
          nx := m_x(i) + m_mx(i); ny := m_y(i) + m_my(i);
          grid_lines(LEAST(m_x(i), nx) - m_r(i), LEAST(m_y(i), ny) - m_r(i),
                     GREATEST(m_x(i), nx) + m_r(i), GREATEST(m_y(i), ny) + m_r(i), cand, nc);
          FOR q IN 0 .. nc - 1 LOOP
            li := cand(q); f := l_fsec(li); b := l_bsec(li);
            isw := l_lsd(li) = -1 OR l_rsd(li) = -1 OR BITAND(l_flags(li), 1) <> 0
                   OR (NOT m_sk(i) AND f <> -1 AND b <> -1 AND ABS(s_fl(f) - s_fl(b)) > k_maxstep);
            IF isw AND LEAST(l_x1(li), l_x2(li)) <= GREATEST(m_x(i), nx) + m_r(i)
               AND GREATEST(l_x1(li), l_x2(li)) >= LEAST(m_x(i), nx) - m_r(i)
               AND LEAST(l_y1(li), l_y2(li)) <= GREATEST(m_y(i), ny) + m_r(i)
               AND GREATEST(l_y1(li), l_y2(li)) >= LEAST(m_y(i), ny) - m_r(i)
               AND ((nx - l_x1(li)) * (l_y2(li) - l_y1(li)) - (ny - l_y1(li)) * (l_x2(li) - l_x1(li)))
                 * ((m_x(i) - l_x1(li)) * (l_y2(li) - l_y1(li)) - (m_y(i) - l_y1(li)) * (l_x2(li) - l_x1(li))) < 0
               AND ((l_x1(li) - m_x(i)) * m_my(i) - (l_y1(li) - m_y(i)) * m_mx(i))
                 * ((l_x2(li) - m_x(i)) * m_my(i) - (l_y2(li) - m_y(i)) * m_mx(i)) < 0 THEN
              blocked := TRUE; EXIT;
            END IF;
          END LOOP;
          IF NOT blocked THEN
            FOR j IN 1 .. o_id.COUNT LOOP
              IF o_id(j) <> m_id(i) AND ABS(o_x(j) - nx) < o_r(j) + m_r(i) AND ABS(o_y(j) - ny) < o_r(j) + m_r(i) THEN
                blocked := TRUE; EXIT;
              END IF;
            END LOOP;
          END IF;
          IF blocked THEN
            UPDATE g_things SET mom_x = 0, mom_y = 0 WHERE map_id = p_map AND id = m_id(i);
          ELSIF m_sk(i) OR m_air(i) THEN
            UPDATE g_things SET x = x + mom_x, y = y + mom_y WHERE map_id = p_map AND id = m_id(i);
          ELSE
            UPDATE g_things SET x = x + mom_x, y = y + mom_y, mom_x = mom_x * k_friction, mom_y = mom_y * k_friction
             WHERE map_id = p_map AND id = m_id(i);
          END IF;
        END LOOP;
      END IF;
    END IF;
    IF v_n > 0 OR v_small > 0 THEN
      UPDATE g_things SET mom_x = 0, mom_y = 0
       WHERE map_id = p_map AND ABS(mom_x) <= k_stopspeed AND ABS(mom_y) <= k_stopspeed AND (mom_x <> 0 OR mom_y <> 0);
    END IF;
  END;

  PROCEDURE cs_boss(p_map NUMBER) IS
    v_ready NUMBER;
  BEGIN
    IF NOT g_has_boss666 THEN RETURN; END IF;     -- no lower_666 row for this map: the aggregate has no group
    SELECT NVL(MAX(CASE WHEN q.alive_bosses = 0 THEN 1 ELSE 0 END), 0) INTO v_ready
      FROM (SELECT SUM(CASE WHEN h.alive THEN 1 ELSE 0 END) AS alive_bosses
              FROM boss_actions ba
              JOIN maps m ON m.name = ba.map_name AND m.map_id = p_map
              JOIN g_things t ON t.map_id = m.map_id AND t.type = ba.boss_type
              JOIN g_thing_health h ON h.map_id = t.map_id AND h.thing_id = t.id
             WHERE ba.action = 'lower_666'
             GROUP BY ba.map_name) q;
    IF v_ready <> 0 THEN
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_sector_movers g_sector_movers_pk) */ INTO g_sector_movers
        (map_id, sector_id, source_line_id, mover_type, plane, direction, bottom_height, top_height, speed,
         wait_tics, countdown, next_ceiling, next_floor, target_floor_tex, moved_this_tick)
      SELECT p_map, sector_id, NULL, 'floor_lower', 'floor', -1, lowest_floor, floor_height, 1, 0, 0, NULL, NULL, NULL, FALSE
        FROM (SELECT s.id AS sector_id, s.floor_height, MIN(other.floor_height) AS lowest_floor
                FROM g_sectors s
                JOIN sector_adjacency a ON a.map_id = s.map_id AND a.sector_id = s.id AND a.sector_id <> a.other_id
                JOIN g_sectors other ON other.map_id = s.map_id AND other.id = a.other_id
               WHERE s.map_id = p_map AND s.tag = 666
               GROUP BY s.id, s.floor_height)
       WHERE lowest_floor < floor_height;
    END IF;
  END;

  -- =====================================================================
  -- Deathmatch (39_mp.sql, 27_cs_item_respawn.sql, 40_run_game_tic.sql's mp part)
  -- =====================================================================
  -- G_DeathMatchSpawnPlayer: a random deathmatch start no other live player stands on
  -- (a 64-unit box around each), the vanilla reborn loadout, the fog and DSTELEPT.
  PROCEDURE mp_respawn(p_map NUMBER, p_player NUMBER) IS
    v_base NUMBER := k('PLAYER_RESPAWN_EFFECT_ID_BASE'); v_span NUMBER := k('EFFECT_ID_TIC_SPAN');
    v_lt NUMBER; v_n PLS_INTEGER := 0; v_pick PLS_INTEGER;
    TYPE t_id IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    st_x t_flt; st_y t_flt; st_a t_flt;
  BEGIN
    SELECT level_tics INTO v_lt FROM g_player_state WHERE map_id = p_map AND player_thing_id = p_player;
    FOR s IN (SELECT t.id, t.x, t.y, t.angle FROM g_things t
               WHERE t.map_id = p_map AND t.type = 11
                 AND NOT EXISTS (SELECT 1 FROM g_player_state ps JOIN g_things ot ON ot.map_id = ps.map_id AND ot.id = ps.player_thing_id
                                  WHERE ps.map_id = p_map AND ps.player_thing_id <> p_player AND ps.alive
                                    AND ABS(TO_BINARY_DOUBLE(ot.x) - t.x) < 64d AND ABS(TO_BINARY_DOUBLE(ot.y) - t.y) < 64d)
               ORDER BY t.id) LOOP
      v_n := v_n + 1; st_x(v_n) := s.x; st_y(v_n) := s.y; st_a(v_n) := s.angle;
    END LOOP;
    IF v_n > 0 THEN
      v_pick := MOD(prandom(p_player, v_lt, 41), v_n) + 1;
      UPDATE g_things SET x = st_x(v_pick), y = st_y(v_pick), angle = st_a(v_pick), mom_x = 0, mom_y = 0
       WHERE map_id = p_map AND id = p_player;
    END IF;
    UPDATE g_player_state
       SET health = 100, alive = TRUE, armor = 0, armor_class = 0, backpack = FALSE,
           ammo_bullets = 50, ammo_shells = 0, ammo_rockets = 0, ammo_cells = 0,
           key_blue = FALSE, key_yellow = FALSE, key_red = FALSE,
           radsuit_tics = 0, invis_tics = 0, light_amp_tics = 0, invuln_tics = 0,
           berserk = FALSE, power_map = FALSE, god_mode = FALSE, noclip = FALSE,
           pain_face_tics = 0, damage_count = 0, bonus_count = 0,
           death_tics = 0, killer_id = NULL, sprite_frame = 'A',
           momentum_x = 0, momentum_y = 0, momentum_z = 0, bob_strength = 0
     WHERE map_id = p_map AND player_thing_id = p_player;
    DELETE FROM g_player_weapon_owned WHERE map_id = p_map AND player_thing_id = p_player;
    INSERT INTO g_player_weapon_owned (map_id, player_thing_id, weapon_id)
    SELECT p_map, p_player, 1 FROM dual UNION ALL SELECT p_map, p_player, 2 FROM dual;
    DELETE FROM g_player_weapons WHERE map_id = p_map AND player_thing_id = p_player;
    INSERT INTO g_player_weapons (map_id, player_thing_id) VALUES (p_map, p_player);
    DELETE FROM g_sound_events WHERE map_id = p_map AND event_key = 'plr-death:' || p_player;
    spawn_player(p_map, p_player);
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_world_effects g_world_effects_pk) */
      INTO g_world_effects (map_id, effect_id, effect_type, x, y, z, sector_id, age)
    SELECT ps.map_id, v_base + ps.player_thing_id * v_span + MOD(ps.level_tics, v_span), 'tfog',
           ps.position_x, ps.position_y, s.floor_height, ps.sector_id, 0
      FROM g_player_state ps JOIN g_sectors s ON s.map_id = ps.map_id AND s.id = ps.sector_id
     WHERE ps.map_id = p_map AND ps.player_thing_id = p_player;
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_sound_events g_sound_events_uk) */
      INTO g_sound_events (map_id, event_key, level_tic, sound_name, source_thing_id, source_x, source_y)
    SELECT ps.map_id, 'respawn:' || ps.player_thing_id || ':' || ps.level_tics, ps.level_tics, 'DSTELEPT',
           ps.player_thing_id, ps.position_x, ps.position_y
      FROM g_player_state ps WHERE ps.map_id = p_map AND ps.player_thing_id = p_player;
  END;

  PROCEDURE mp_configure(p_map NUMBER, p_skill NUMBER, p_timer_tics NUMBER, p_altdeath NUMBER, p_monsters NUMBER,
                         p_respawn_monsters NUMBER, p_intermission_tics NUMBER) IS
  BEGIN
    DELETE FROM g_mp_match;
    INSERT INTO g_mp_match (id, map_id, skill, state, timer_tics, altdeath, monsters, respawn_monsters,
                            intermission_tics, intermission_until)
    VALUES (0, p_map, p_skill, 'intermission', p_timer_tics, p_altdeath = 1, p_monsters = 1, p_respawn_monsters = 1,
            p_intermission_tics, SYSTIMESTAMP);
  END;

  PROCEDURE mp_open IS
  BEGIN
    UPDATE g_mp_match SET state = 'playing', intermission_until = NULL;
  END;

  PROCEDURE mp_vacate_all(p_map NUMBER) IS
  BEGIN
    UPDATE g_player_state ps
       SET alive = FALSE, health = 0, killer_id = NULL, death_tics = 36, momentum_x = 0, momentum_y = 0, momentum_z = 0
     WHERE ps.map_id = p_map
       AND ps.player_thing_id IN (SELECT mp.player_thing_id FROM g_mp_players mp WHERE mp.map_id = p_map);
    UPDATE g_mp_players SET role_name = NULL, last_seen = NULL, display_name = NULL WHERE map_id = p_map;
    DELETE FROM g_mp_join_requests WHERE map_id = p_map;
  END;

  FUNCTION mp_start(p_map NUMBER, p_skill NUMBER) RETURN NUMBER IS
    v_monsters BOOLEAN := FALSE; v_n NUMBER;
  BEGIN
    load_map(p_map);
    s_valid := FALSE;
    reset_stage(p_map, p_skill);
    DELETE FROM g_mp_players;
    INSERT INTO g_mp_players (map_id, slot, player_thing_id, skill)
    SELECT p_map, t.type, MIN(t.id), p_skill FROM g_things t
     WHERE t.map_id = p_map AND t.type IN (1, 2, 3, 4) GROUP BY t.type;
    INSERT INTO g_player_weapons (map_id, player_thing_id)
    SELECT map_id, player_thing_id FROM g_mp_players WHERE map_id = p_map AND slot >= 2;
    INSERT INTO g_player_weapon_owned (map_id, player_thing_id, weapon_id)
    SELECT mp.map_id, mp.player_thing_id, w.weapon_id
      FROM g_mp_players mp CROSS JOIN (SELECT 1 AS weapon_id FROM dual UNION ALL SELECT 2 FROM dual) w
     WHERE mp.map_id = p_map AND mp.slot >= 2;
    INSERT INTO g_player_state (map_id, player_thing_id, health, alive, ammo_bullets, previous_x, previous_y,
                                position_x, position_y, base_z, view_z, view_angle)
    SELECT t.map_id, t.id, 100, TRUE, 50, t.x, t.y, t.x, t.y, t.z, t.z, t.angle
      FROM g_mp_players mp JOIN g_things t ON t.map_id = mp.map_id AND t.id = mp.player_thing_id
     WHERE mp.map_id = p_map AND mp.slot >= 2;
    FOR m IN (SELECT monsters FROM g_mp_match) LOOP v_monsters := m.monsters; END LOOP;
    IF NOT v_monsters THEN
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_picked_up_items g_picked_up_items_pk) */
        INTO g_picked_up_items (map_id, thing_id)
      SELECT h.map_id, h.thing_id FROM g_thing_health h
        JOIN g_things t ON t.map_id = h.map_id AND t.id = h.thing_id
        JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill
       WHERE h.map_id = p_map;
      DELETE FROM g_monster_ai ai WHERE ai.map_id = p_map
         AND EXISTS (SELECT 1 FROM g_things t JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill
                      WHERE t.map_id = ai.map_id AND t.id = ai.thing_id);
      DELETE FROM g_thing_health h WHERE h.map_id = p_map
         AND EXISTS (SELECT 1 FROM g_things t JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill
                      WHERE t.map_id = h.map_id AND t.id = h.thing_id);
    END IF;
    DELETE FROM g_mp_inputs WHERE map_id = p_map;
    FOR s IN (SELECT player_thing_id FROM g_mp_players WHERE map_id = p_map AND slot BETWEEN 1 AND 4 ORDER BY slot) LOOP
      mp_respawn(p_map, s.player_thing_id);
    END LOOP;
    mp_vacate_all(p_map);
    SELECT COUNT(*) INTO v_n FROM g_mp_players WHERE map_id = p_map;
    RETURN v_n;
  END;

  -- the owner-side core of api_join: claim a free slot (and ask the next tic to spawn it)
  FUNCTION mp_claim(p_map NUMBER, p_slot NUMBER, p_role VARCHAR2) RETURN NUMBER IS
    v_pid NUMBER;
  BEGIN
    UPDATE g_mp_players SET role_name = p_role, claimed_at = SYSTIMESTAMP, last_seen = SYSTIMESTAMP
     WHERE map_id = p_map AND slot = p_slot AND role_name IS NULL
     RETURNING player_thing_id INTO v_pid;
    IF v_pid IS NULL THEN RETURN -1; END IF;
    INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_mp_join_requests g_mp_join_requests_pk) */
      INTO g_mp_join_requests (map_id, slot) VALUES (p_map, p_slot);
    RETURN v_pid;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN -1;
  END;

  -- S_PLAY_* frame the other players draw this player with
  PROCEDURE cs_player_pose(p_map NUMBER, p_player NUMBER) IS
  BEGIN
    UPDATE g_player_state ps
       SET sprite_frame = (SELECT CASE
             WHEN NOT ps.alive THEN
               CASE WHEN ps.health < -100 THEN CHR(ASCII('O') + LEAST(8, TRUNC(ps.death_tics / 5)))
                    ELSE CHR(ASCII('H') + LEAST(6, TRUNC(ps.death_tics / 10))) END
             WHEN ps.pain_face_tics >= 9 THEN 'G'
             WHEN pw.flash_seq_index IS NOT NULL THEN 'F'
             WHEN pw.state NOT IN ('ready', 'up', 'down') THEN 'E'
             WHEN ps.bob_strength > TO_BINARY_FLOAT(0.05) OR ABS(ps.momentum_x) + ABS(ps.momentum_y) > TO_BINARY_FLOAT(0.1)
               THEN SUBSTR('ABCD', MOD(TRUNC(ps.level_tics / 4), 4) + 1, 1)
             ELSE 'A' END
             FROM g_player_weapons pw WHERE pw.map_id = ps.map_id AND pw.player_thing_id = ps.player_thing_id)
     WHERE ps.map_id = p_map AND ps.player_thing_id = p_player
       AND EXISTS (SELECT 1 FROM g_player_weapons pw WHERE pw.map_id = ps.map_id AND pw.player_thing_id = ps.player_thing_id);
  END;

  -- P_KillMobj's frag bookkeeping over everyone who died this tic (killer -1 = the world)
  PROCEDURE mp_frags(p_map NUMBER) IS
  BEGIN
    MERGE INTO g_player_state k
    USING (SELECT v.killer_id,
                  MIN(NVL(vs.display_name, 'PLAYER ' || vs.slot)) KEEP (DENSE_RANK FIRST ORDER BY vs.slot) AS vname
             FROM g_player_state v
             JOIN g_mp_players vs ON vs.map_id = v.map_id AND vs.player_thing_id = v.player_thing_id
            WHERE v.map_id = p_map AND NOT v.alive AND v.killer_id IS NOT NULL
              AND v.killer_id >= 0 AND v.killer_id <> v.player_thing_id
            GROUP BY v.killer_id) q
       ON (k.map_id = p_map AND k.player_thing_id = q.killer_id)
     WHEN MATCHED THEN UPDATE SET k.frags = k.frags + 1, k.message = 'YOU FRAGGED ' || q.vname, k.message_tics = 140;
    MERGE INTO g_player_state v
    USING (SELECT v2.player_thing_id,
                  MIN(CASE WHEN v2.killer_id = v2.player_thing_id THEN 'YOU KILLED YOURSELF'
                           WHEN v2.killer_id < 0 THEN 'YOU DIED'
                           ELSE NVL(ks.display_name, 'PLAYER ' || ks.slot) || ' FRAGGED YOU' END) AS msg,
                  MIN(CASE WHEN v2.killer_id = v2.player_thing_id OR v2.killer_id < 0 THEN 1 ELSE 0 END) AS lose
             FROM g_player_state v2
             JOIN g_mp_players ks ON ks.map_id = v2.map_id
              AND ks.player_thing_id = CASE WHEN v2.killer_id >= 0 THEN v2.killer_id ELSE v2.player_thing_id END
            WHERE v2.map_id = p_map AND NOT v2.alive AND v2.killer_id IS NOT NULL
            GROUP BY v2.player_thing_id) q
       ON (v.map_id = p_map AND v.player_thing_id = q.player_thing_id)
     WHEN MATCHED THEN UPDATE SET v.frags = v.frags - q.lose, v.message = q.msg, v.message_tics = 140,
                                  v.killer_id = NULL;
  END;

  -- P_RespawnSpecials (-altdeath): a taken map item returns 30 s later, oldest first, one a tic
  PROCEDURE cs_item_respawn(p_map NUMBER, p_player NUMBER) IS
    v_alt BOOLEAN := FALSE; v_due NUMBER := -1;
    v_tics NUMBER := k('ITEM_RESPAWN_TICS'); v_drop NUMBER := k('DROPPED_THING_ID_BASE');
    v_fog NUMBER := k('ITEM_FOG_EFFECT_ID_BASE'); v_span NUMBER := k('EFFECT_ID_TIC_SPAN');
  BEGIN
    FOR m IN (SELECT altdeath FROM g_mp_match WHERE map_id = p_map AND state = 'playing') LOOP v_alt := m.altdeath; END LOOP;
    IF NOT v_alt THEN RETURN; END IF;
    INSERT INTO g_item_respawns (map_id, thing_id, respawn_tic)
    SELECT pu.map_id, pu.thing_id, ps.level_tics + v_tics
      FROM g_picked_up_items pu
      JOIN g_things t ON t.map_id = pu.map_id AND t.id = pu.thing_id
      JOIN g_player_state ps ON ps.map_id = pu.map_id AND ps.player_thing_id = p_player
     WHERE pu.map_id = p_map AND pu.thing_id < v_drop
       AND EXISTS (SELECT 1 FROM pickup_defs d WHERE d.thing_type = t.type)
       AND NOT EXISTS (SELECT 1 FROM g_item_respawns r WHERE r.map_id = pu.map_id AND r.thing_id = pu.thing_id);
    FOR r IN (SELECT r.thing_id FROM g_item_respawns r
                JOIN g_player_state ps ON ps.map_id = r.map_id AND ps.player_thing_id = p_player
               WHERE r.map_id = p_map AND ps.level_tics >= r.respawn_tic
               ORDER BY r.respawn_tic, r.thing_id FETCH FIRST 1 ROW ONLY) LOOP
      v_due := r.thing_id;
    END LOOP;
    IF v_due >= 0 THEN
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_world_effects g_world_effects_pk) */
        INTO g_world_effects (map_id, effect_id, effect_type, x, y, z, sector_id, age)
      SELECT t.map_id, v_fog + t.id * v_span + MOD(ps.level_tics, v_span), 'ifog', t.x, t.y, s.floor_height,
             rt.sector_id, 0
        FROM g_things t
        JOIN g_render_things rt ON rt.map_id = t.map_id AND rt.thing_id = t.id
        JOIN g_sectors s ON s.map_id = rt.map_id AND s.id = rt.sector_id
        JOIN g_player_state ps ON ps.map_id = t.map_id AND ps.player_thing_id = p_player
       WHERE t.map_id = p_map AND t.id = v_due;
      INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(g_sound_events g_sound_events_uk) */
        INTO g_sound_events (map_id, event_key, level_tic, sound_name, source_thing_id, source_x, source_y)
      SELECT t.map_id, 'itemrespawn:' || t.id || ':' || ps.level_tics, ps.level_tics, 'DSITMBK', t.id, t.x, t.y
        FROM g_things t JOIN g_player_state ps ON ps.map_id = t.map_id AND ps.player_thing_id = p_player
       WHERE t.map_id = p_map AND t.id = v_due;
      DELETE FROM g_picked_up_items WHERE map_id = p_map AND thing_id = v_due;
      DELETE FROM g_item_respawns WHERE map_id = p_map AND thing_id = v_due;
    END IF;
  END;

  -- G_ExitLevel's reasons for a deathmatch: -timer, an exit line used or crossed by a player,
  -- a held slot worn down on the E1M8 floor, the map's boss dead
  FUNCTION mp_level_done(p_map NUMBER) RETURN NUMBER IS
    v_playing BOOLEAN := FALSE; v NUMBER := 0;
  BEGIN
    FOR m IN (SELECT state FROM g_mp_match WHERE map_id = p_map) LOOP v_playing := m.state = 'playing'; END LOOP;
    IF NOT v_playing THEN RETURN 0; END IF;
    SELECT CASE WHEN m.timer_tics > 0 AND NVL(MAX(ps.level_tics), 0) >= m.timer_tics THEN 1 ELSE 0 END INTO v
      FROM g_mp_match m
      LEFT JOIN g_mp_players mp ON mp.map_id = m.map_id
      LEFT JOIN g_player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id
     WHERE m.map_id = p_map GROUP BY m.timer_tics;
    IF v = 1 THEN RETURN 1; END IF;
    SELECT CASE WHEN EXISTS (
             SELECT 1 FROM g_line_special_events e
               JOIN g_mp_players mp ON mp.map_id = e.map_id AND mp.player_thing_id = e.player_thing_id
               JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
               JOIN line_special_defs d ON d.special = ld.special
              WHERE e.map_id = p_map AND e.trigger_type = 'cross' AND d.is_exit
             UNION ALL
             SELECT 1 FROM g_line_use_results ur
               JOIN g_mp_players mp ON mp.map_id = ur.map_id AND mp.player_thing_id = ur.player_thing_id
               JOIN g_game_tic_commands c ON c.map_id = ur.map_id AND c.player_thing_id = ur.player_thing_id
               JOIN line_special_defs d ON d.special = ur.special
              WHERE ur.map_id = p_map AND ur.eligible AND c.use_requested AND d.is_exit
             UNION ALL
             SELECT 1 FROM g_player_state ps
               JOIN g_mp_players mp ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id
               JOIN g_sectors s ON s.map_id = ps.map_id AND s.id = ps.sector_id
               JOIN sector_special_defs sd ON sd.special = s.special
              WHERE ps.map_id = p_map AND mp.role_name IS NOT NULL AND ps.health <= sd.exit_at_health
             UNION ALL
             SELECT 1 FROM (SELECT SUM(CASE WHEN h.alive THEN 1 ELSE 0 END) AS alive_bosses
                              FROM boss_actions ba
                              JOIN maps m ON m.name = ba.map_name AND m.map_id = p_map
                              JOIN g_things t ON t.map_id = m.map_id AND t.type = ba.boss_type
                              JOIN g_thing_health h ON h.map_id = t.map_id AND h.thing_id = t.id
                             WHERE ba.action = 'exit_level' GROUP BY ba.map_name) q
              WHERE q.alive_bosses = 0) THEN 1 ELSE 0 END INTO v FROM dual;
    RETURN v;
  END;

  -- P_DeathThink's respawn and the PLAY frame, per player
  PROCEDURE tic_dm_player(p_map NUMBER, p_player NUMBER) IS
    v_rs NUMBER := 0;
  BEGIN
    cs_player_pose(p_map, p_player);
    SELECT NVL(MAX(CASE WHEN NOT ps.alive AND ps.death_tics > 35 AND (g.attack_held OR g.use_requested) THEN 1 ELSE 0 END), 0)
      INTO v_rs
      FROM g_player_state ps
      JOIN g_game_tic_commands g ON g.map_id = ps.map_id AND g.player_thing_id = ps.player_thing_id
     WHERE ps.map_id = p_map AND ps.player_thing_id = p_player;
    IF v_rs = 1 THEN mp_respawn(p_map, p_player); END IF;
  END;

  -- the input rows one client appended since the last tic, folded into its command
  PROCEDURE mp_begin_player(p_map NUMBER, p_skill NUMBER, p_player NUMBER, p_upto NUMBER) IS
    f BINARY_FLOAT; s BINARY_FLOAT; r BOOLEAN; t BINARY_FLOAT; a BOOLEAN; w NUMBER; u BOOLEAN;
  BEGIN
    SELECT NVL(MAX(move_fwd) KEEP (DENSE_RANK LAST ORDER BY seq), 0),
           NVL(MAX(move_strafe) KEEP (DENSE_RANK LAST ORDER BY seq), 0),
           NVL(MAX(CASE WHEN running THEN 1 ELSE 0 END) KEEP (DENSE_RANK LAST ORDER BY seq), 0) = 1,
           NVL(SUM(turn_degrees), 0),
           NVL(MAX(CASE WHEN attack_held THEN 1 ELSE 0 END), 0) = 1,
           MAX(weapon_switch_to),
           NVL(MAX(CASE WHEN use_requested THEN 1 ELSE 0 END), 0) = 1
      INTO f, s, r, t, a, w, u
      FROM g_mp_inputs WHERE map_id = p_map AND player_thing_id = p_player AND seq <= p_upto;
    cs_begin(p_map, p_player, p_skill, f, s, r, t, a, w, u);
  END;

  PROCEDURE mp_spawn_if_requested(p_map NUMBER, p_player NUMBER) IS
    v NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v FROM g_mp_join_requests r
      JOIN g_mp_players mp ON mp.map_id = r.map_id AND mp.slot = r.slot
     WHERE mp.map_id = p_map AND mp.player_thing_id = p_player;
    IF v > 0 THEN
      UPDATE g_player_state SET frags = 0 WHERE map_id = p_map AND player_thing_id = p_player;
      mp_respawn(p_map, p_player);
      DELETE FROM g_mp_join_requests WHERE map_id = p_map
         AND slot IN (SELECT mp.slot FROM g_mp_players mp WHERE mp.map_id = p_map AND mp.player_thing_id = p_player);
    END IF;
  END;

  -- =====================================================================
  -- doom_run_tic_core (40): one tic for one to four players (p2..p4 NULL in single player),
  -- the same stage order and gates as the reference; doom_run_game_tic / doom_run_mp_tic
  -- =====================================================================
  FUNCTION bor(a PLS_INTEGER, b PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN RETURN a + b - BITAND(a, b); END;

  FUNCTION tic_use(p_map NUMBER, p NUMBER, p_plan PLS_INTEGER) RETURN BOOLEAN IS
  BEGIN
    IF BITAND(p_plan, 1) <> 0 THEN RETURN cs_use(p_map, p); END IF;
    RETURN FALSE;
  END;

  FUNCTION tic_move(p_map NUMBER, p NUMBER) RETURN PLS_INTEGER IS
    v_mode VARCHAR2(8);
  BEGIN
    v_mode := cs_movement_mode(p_map, p);
    IF v_mode = 'full' THEN cs_move(p_map, p); RETURN 1; END IF;
    IF v_mode = 'turn' THEN cs_turn(p_map, p); RETURN 2; END IF;
    RETURN 0;
  END;

  FUNCTION tic_secrets(p_map NUMBER, p NUMBER, p_plan PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN
    IF BITAND(p_plan, 8) <> 0 THEN
      cs_secret(p_map, p);
      cs_discover(p_map, p);
      cs_cross(p_map, p);
      cs_pickups(p_map, p);
      RETURN cs_plan(p_map, p);
    END IF;
    RETURN p_plan;
  END;

  FUNCTION tic_weapon(p_map NUMBER, p NUMBER, p_plan PLS_INTEGER) RETURN PLS_INTEGER IS
    v_out PLS_INTEGER := p_plan; shot NUMBER; impacts NUMBER;
  BEGIN
    IF BITAND(p_plan, 16) <> 0 THEN
      shot := cs_weapon(p_map, p);
      v_out := cs_plan(p_map, p);
      IF BITAND(v_out, 32) <> 0 THEN
        impacts := cs_hitscan_fire(p_map, p);
        IF impacts >= 0 THEN cs_hitscan_apply(p_map, p, shot); END IF;
      END IF;
    END IF;
    RETURN v_out;
  END;

  FUNCTION run_tic_core(p_map NUMBER, p_skill NUMBER, p1 NUMBER, p2 NUMBER, p3 NUMBER, p4 NUMBER) RETURN NUMBER IS
    fired PLS_INTEGER := 1; sound_due BOOLEAN; use_queued BOOLEAN; active PLS_INTEGER := 0; did PLS_INTEGER;
    dm BOOLEAN := p2 IS NOT NULL; has3 BOOLEAN := p3 IS NOT NULL; has4 BOOLEAN := p4 IS NOT NULL;
    plan1 PLS_INTEGER; plan2 PLS_INTEGER := 0; plan3 PLS_INTEGER := 0; plan4 PLS_INTEGER := 0; plans PLS_INTEGER;
    pm NUMBER := p1; d PLS_INTEGER;
  BEGIN
    g_snd_lt := -1;
    cs_clock(p_map, p1);
    IF dm THEN cs_clock(p_map, p2); END IF;
    IF has3 THEN cs_clock(p_map, p3); END IF;
    IF has4 THEN cs_clock(p_map, p4); END IF;
    fired := bor(fired, 2);
    plan1 := cs_plan(p_map, p1);
    IF dm THEN plan2 := cs_plan(p_map, p2); END IF;
    IF has3 THEN plan3 := cs_plan(p_map, p3); END IF;
    IF has4 THEN plan4 := cs_plan(p_map, p4); END IF;
    fired := bor(fired, 4);
    plans := bor(bor(plan1, plan2), bor(plan3, plan4));
    sound_due := BITAND(plans, 128) <> 0;
    tmark('begin');
    use_queued := tic_use(p_map, p1, plan1);
    IF dm THEN use_queued := tic_use(p_map, p2, plan2) OR use_queued; END IF;
    IF has3 THEN use_queued := tic_use(p_map, p3, plan3) OR use_queued; END IF;
    IF has4 THEN use_queued := tic_use(p_map, p4, plan4) OR use_queued; END IF;
    IF BITAND(plans, 1) <> 0 THEN fired := bor(fired, 8); END IF;
    IF BITAND(plans, 2) <> 0 OR use_queued THEN
      active := cs_activate_specials(p_map);
      fired := bor(fired, 16);
    END IF;
    IF BITAND(plans, 4) <> 0 OR active <> 0 THEN
      cs_doors(p_map, p1);
      fired := bor(fired, 32);
    END IF;
    s_valid := FALSE;                       -- specials and movers may have moved planes; later stages don't
    tmark('doors');
    did := tic_move(p_map, p1);
    IF did = 1 THEN fired := bor(fired, 128); END IF;
    IF did = 2 THEN fired := bor(fired, 256); END IF;
    IF dm THEN d := tic_move(p_map, p2); END IF;
    IF has3 THEN d := tic_move(p_map, p3); END IF;
    IF has4 THEN d := tic_move(p_map, p4); END IF;
    cs_death(p_map, p1);
    IF dm THEN cs_death(p_map, p2); END IF;
    IF has3 THEN cs_death(p_map, p3); END IF;
    IF has4 THEN cs_death(p_map, p4); END IF;
    tmark('move');
    plan1 := cs_plan(p_map, p1);
    IF dm THEN plan2 := cs_plan(p_map, p2); END IF;
    IF has3 THEN plan3 := cs_plan(p_map, p3); END IF;
    IF has4 THEN plan4 := cs_plan(p_map, p4); END IF;
    plans := bor(bor(plan1, plan2), bor(plan3, plan4));
    sound_due := sound_due OR BITAND(plans, 128) <> 0;
    IF BITAND(plans, 8) <> 0 THEN fired := bor(fired, 512 + 1024 + 2048); END IF;
    plan1 := tic_secrets(p_map, p1, plan1);
    IF dm THEN plan2 := tic_secrets(p_map, p2, plan2); END IF;
    IF has3 THEN plan3 := tic_secrets(p_map, p3, plan3); END IF;
    IF has4 THEN plan4 := tic_secrets(p_map, p4, plan4); END IF;
    plans := bor(bor(plan1, plan2), bor(plan3, plan4));
    sound_due := sound_due OR BITAND(plans, 128) <> 0;
    IF BITAND(plans, 16) <> 0 THEN fired := bor(fired, 4096); END IF;
    tmark('secrets');
    plan1 := tic_weapon(p_map, p1, plan1);
    IF dm THEN plan2 := tic_weapon(p_map, p2, plan2); END IF;
    IF has3 THEN plan3 := tic_weapon(p_map, p3, plan3); END IF;
    IF has4 THEN plan4 := tic_weapon(p_map, p4, plan4); END IF;
    plans := bor(bor(plan1, plan2), bor(plan3, plan4));
    sound_due := sound_due OR BITAND(plans, 128) <> 0;
    IF BITAND(plans, 32) <> 0 THEN fired := bor(fired, 8192 + 16384); END IF;
    tmark('weapon');
    IF dm THEN
      -- the player the world stages see: a different live, held slot every tic
      FOR q IN (SELECT x.player_thing_id FROM (
                  SELECT mp.player_thing_id, ps.level_tics,
                         ROW_NUMBER() OVER (ORDER BY mp.slot) AS rn, COUNT(*) OVER () AS n
                    FROM g_mp_players mp
                    JOIN g_player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id
                   WHERE mp.map_id = p_map AND mp.role_name IS NOT NULL AND ps.alive) x
                 WHERE x.rn = MOD(x.level_tics, x.n) + 1) LOOP
        pm := q.player_thing_id;
      END LOOP;
    END IF;
    IF BITAND(plans, 64) <> 0 THEN
      cs_projectiles(p_map, pm);
      fired := bor(fired, 32768);
      plan1 := cs_plan(p_map, p1);
      IF dm THEN plan2 := cs_plan(p_map, p2); END IF;
      IF has3 THEN plan3 := cs_plan(p_map, p3); END IF;
      IF has4 THEN plan4 := cs_plan(p_map, p4); END IF;
      sound_due := sound_due OR BITAND(bor(bor(plan1, plan2), bor(plan3, plan4)), 128) <> 0;
    END IF;
    tmark('proj');
    IF sound_due THEN
      cs_sound(p_map, p1);
      IF dm THEN cs_sound(p_map, p2); END IF;
      IF has3 THEN cs_sound(p_map, p3); END IF;
      IF has4 THEN cs_sound(p_map, p4); END IF;
      fired := bor(fired, 65536);
    END IF;
    tmark('sound');
    cs_monsters(p_map, pm);
    fired := bor(fired, 131072);
    IF dm THEN cs_item_respawn(p_map, p1); END IF;
    cs_sector_fx(p_map, p1);
    IF dm THEN cs_sector_fx(p_map, p2); END IF;
    IF has3 THEN cs_sector_fx(p_map, p3); END IF;
    IF has4 THEN cs_sector_fx(p_map, p4); END IF;
    fired := bor(fired, 262144);
    cs_thing_physics(p_map);
    cs_boss(p_map);
    fired := bor(fired, 524288);
    tmark('fx');
    IF dm THEN
      mp_frags(p_map);
      tic_dm_player(p_map, p1);
      tic_dm_player(p_map, p2);
      IF has3 THEN tic_dm_player(p_map, p3); END IF;
      IF has4 THEN tic_dm_player(p_map, p4); END IF;
      tmark('dm');
    END IF;
    MERGE INTO g_tic_trace t USING (SELECT p_map AS map_id, p1 AS player_thing_id, fired AS stages FROM dual) s
       ON (t.map_id = s.map_id AND t.player_thing_id = s.player_thing_id)
     WHEN MATCHED THEN UPDATE SET t.stages = s.stages WHERE t.stages <> s.stages
     WHEN NOT MATCHED THEN INSERT (map_id, player_thing_id, stages) VALUES (s.map_id, s.player_thing_id, s.stages);
    tmark('tail');
    RETURN CASE WHEN sound_due THEN 1 ELSE 0 END;
  END;

  FUNCTION run_tic(p_map NUMBER, p_player NUMBER, p_skill NUMBER,
                   p_fwd BINARY_FLOAT, p_strafe BINARY_FLOAT, p_running NUMBER,
                   p_turn BINARY_FLOAT, p_attack NUMBER, p_switch NUMBER, p_use NUMBER) RETURN NUMBER IS
  BEGIN
    load_map(p_map);
    s_valid := FALSE;                       -- sector heights are re-read every tic
    tmark(NULL);
    cs_begin(p_map, p_player, p_skill, p_fwd, p_strafe, p_running = 1, p_turn, p_attack = 1, p_switch, p_use = 1);
    RETURN run_tic_core(p_map, p_skill, p_player, NULL, NULL, NULL);
  END;

  -- doom_run_mp_tic: fold every client's input rows, spawn newly claimed slots, run the shared
  -- tic for every slot; returns 1 when this tic ended the level
  FUNCTION run_mp_tic(p_map NUMBER, p_skill NUMBER, p1 NUMBER, p2 NUMBER, p3 NUMBER, p4 NUMBER) RETURN NUMBER IS
    v_upto NUMBER; v_r NUMBER; v_req t_int;
    v_bit NUMBER := CASE WHEN p_skill <= 1 THEN 1 WHEN p_skill = 2 THEN 2 ELSE 4 END;
  BEGIN
    load_map(p_map);
    s_valid := FALSE;
    tmark(NULL);
    SELECT NVL(MAX(seq), 0) INTO v_upto FROM g_mp_inputs WHERE map_id = p_map;
    -- slots claimed since the last tic, respawned in slot-argument order (one read for all)
    FOR r IN (SELECT mp.player_thing_id FROM g_mp_join_requests jr
                JOIN g_mp_players mp ON mp.map_id = jr.map_id AND mp.slot = jr.slot
               WHERE jr.map_id = p_map) LOOP
      v_req(r.player_thing_id) := 1;
    END LOOP;
    IF v_req.COUNT > 0 THEN
      IF v_req.EXISTS(p1) THEN mp_spawn_if_requested(p_map, p1); END IF;
      IF p2 IS NOT NULL AND v_req.EXISTS(p2) THEN mp_spawn_if_requested(p_map, p2); END IF;
      IF p3 IS NOT NULL AND v_req.EXISTS(p3) THEN mp_spawn_if_requested(p_map, p3); END IF;
      IF p4 IS NOT NULL AND v_req.EXISTS(p4) THEN mp_spawn_if_requested(p_map, p4); END IF;
    END IF;
    -- doom_mp_begin_player for every slot at once: each player's input rows folded (latest
    -- movement, summed turn, any press; no rows = an empty command), then doom_cs_begin's
    -- statements set-based
    DELETE FROM g_pickup_touches WHERE map_id = p_map AND player_thing_id IN (p1, p2, p3, p4);
    DELETE FROM g_pickup_grants WHERE map_id = p_map AND player_thing_id IN (p1, p2, p3, p4);
    MERGE INTO g_game_tic_commands g
    USING (SELECT pl.pid,
                  NVL(MAX(i.move_fwd) KEEP (DENSE_RANK LAST ORDER BY i.seq), 0) AS f,
                  NVL(MAX(i.move_strafe) KEEP (DENSE_RANK LAST ORDER BY i.seq), 0) AS st,
                  NVL(MAX(CASE WHEN i.running THEN 1 ELSE 0 END) KEEP (DENSE_RANK LAST ORDER BY i.seq), 0) AS rn,
                  NVL(SUM(i.turn_degrees), 0) AS t,
                  NVL(MAX(CASE WHEN i.attack_held THEN 1 ELSE 0 END), 0) AS atk,
                  MAX(i.weapon_switch_to) AS sw,
                  NVL(MAX(CASE WHEN i.use_requested THEN 1 ELSE 0 END), 0) AS u
             FROM (SELECT p1 AS pid FROM dual UNION ALL SELECT p2 FROM dual WHERE p2 IS NOT NULL
                   UNION ALL SELECT p3 FROM dual WHERE p3 IS NOT NULL
                   UNION ALL SELECT p4 FROM dual WHERE p4 IS NOT NULL) pl
             LEFT JOIN g_mp_inputs i ON i.map_id = p_map AND i.player_thing_id = pl.pid AND i.seq <= v_upto
            GROUP BY pl.pid) q
       ON (g.map_id = p_map AND g.player_thing_id = q.pid)
     WHEN MATCHED THEN UPDATE SET g.command_serial = g.command_serial + 1, g.skill = p_skill, g.skill_bit = v_bit,
                                  g.move_fwd = q.f, g.move_strafe = q.st, g.running = q.rn = 1,
                                  g.turn_degrees = q.t, g.attack_held = q.atk = 1, g.weapon_switch_to = q.sw,
                                  g.use_requested = q.u = 1, g.movement_mode = 'idle'
     WHEN NOT MATCHED THEN INSERT (map_id, player_thing_id, command_serial, skill, skill_bit, move_fwd, move_strafe,
                                   running, turn_degrees, attack_held, weapon_switch_to, use_requested, movement_mode)
          VALUES (p_map, q.pid, 1, p_skill, v_bit, q.f, q.st, q.rn = 1, q.t, q.atk = 1, q.sw, q.u = 1, 'idle');
    DELETE FROM g_mp_inputs WHERE map_id = p_map AND seq <= v_upto;
    tmark('mp_in');
    v_r := run_tic_core(p_map, p_skill, p1, p2, p3, p4);
    v_r := mp_level_done(p_map);
    tmark('done');
    RETURN v_r;
  END;
END doom_game;
/
