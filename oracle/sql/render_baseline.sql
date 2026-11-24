-- @output hexrows
-- =============================================================================
-- render_baseline.sql -- stage-by-stage Oracle port of the CedarDB SQLDoom
-- renderer (reference/sqldoom/sql/renderer.sql). Correctness baseline: same CTE
-- names and stages as the reference; later optimisations are measured against it.
--
-- Binds: :tic :map_id :player_id :skill :px :py :pz :pangle
-- Output: 200 rows (y, pal, hex): hex = 320 palette indices after COLORMAP
--         (two hex digits each), pal = the frame's PLAYPAL number.
-- Support objects: sql/05_baseline_support.sql (nums, blob_chunks,
--                  render_segs_static).
--
-- Translation rules (CedarDB semantics -> Oracle):
--  * float8 math in BINARY_DOUBLE; numeric literals that CedarDB converts to
--    float8 are written as exact BINARY_DOUBLE literals (all exact here, except
--    sky_columns/sky_degrees = numeric 2.844444, written 2.844444d).
--  * float8 -> int casts round half to even: ROUND(binary_double) does that.
--  * int / int truncates: TRUNC(a / b).  % : MOD (sign of the dividend).
--  * LEAST/GREATEST ignore NULLs in CedarDB; written with explicit NULL handling
--    where an argument can be NULL.
--  * IS DISTINCT FROM 'x' -> (c IS NULL OR c <> 'x').  BOOL_AND -> MIN(CASE).
--  * ARG_MAX(v, k) -> MAX(v) KEEP (DENSE_RANK LAST ORDER BY k).
--  * generate_series(a, b) -> JOIN nums g ON g.n BETWEEN a AND b.
--  * GET_BYTE(blob, off) -> blob_chunks (see 05_baseline_support.sql).
--  * real (float4) arithmetic (thing base_z + offsets) -> TO_BINARY_FLOAT
--    rounding after each step.
--  * Camera pose: the reference client sends the pose floats as SQL literals
--    (Python repr). CedarDB turns such a numeric literal into float8 as
--    float8(integer mantissa) / 10^scale, which is not always the nearest
--    double. pos reproduces that conversion from the bound BINARY_DOUBLE.
--  * Light functions (43_render_light.sql) are inlined.
-- =============================================================================
WITH
-- ---------------------------------------------------------------- binds
params AS (
    SELECT :tic AS tic, :map_id AS map_id, :player_id AS player_id, :skill AS skill,
           TO_BINARY_DOUBLE(:px) AS px, TO_BINARY_DOUBLE(:py) AS py,
           TO_BINARY_DOUBLE(:pz) AS pz, TO_BINARY_DOUBLE(:pangle) AS pangle
    FROM dual
),
-- ---------------------------------------------------- tic-filtered dynamic state
sectors AS (
    SELECT s.id, s.map_id, s.floor_height, s.ceil_height, s.spawn_floor_height,
           s.spawn_ceil_height, s.spawn_floor_tex, s.spawn_light_level, s.floor_tex,
           s.ceil_tex, s.light_level, s.special, s.tag
    FROM st_sectors s JOIN params p ON s.tic = p.tic
),
things AS (
    SELECT t.id, t.map_id, t.x, t.y, t.z, t.angle, t.spawn_x, t.spawn_y, t.spawn_angle,
           t.mom_x, t.mom_y, t.type, t.flags
    FROM st_things t JOIN params p ON t.tic = p.tic
),
render_things AS (
    SELECT r.map_id, r.thing_id, r.sector_id, r.spawn_sector_id, r.sprite, r.frame,
           r.fullbright, r.spawn_ceiling, r.thing_height
    FROM st_render_things r JOIN params p ON r.tic = p.tic
),
player_state AS (
    SELECT s.* FROM st_player_state s JOIN params p ON s.tic = p.tic
),
player_weapons AS (
    SELECT w.* FROM st_player_weapons w JOIN params p ON w.tic = p.tic
),
player_weapon_owned AS (
    SELECT o.map_id, o.player_thing_id, o.weapon_id
    FROM st_player_weapon_owned o JOIN params p ON o.tic = p.tic
),
monster_ai AS (
    SELECT a.* FROM st_monster_ai a JOIN params p ON a.tic = p.tic
),
thing_health AS (
    SELECT h.map_id, h.thing_id, h.health, h.max_health, h.alive
    FROM st_thing_health h JOIN params p ON h.tic = p.tic
),
world_effects AS (
    SELECT e.map_id, e.effect_id, e.effect_type, e.x, e.y, e.z, e.sector_id, e.age
    FROM st_world_effects e JOIN params p ON e.tic = p.tic
),
monster_projectiles AS (
    SELECT m.* FROM st_monster_projectiles m JOIN params p ON m.tic = p.tic
),
picked_up_items AS (
    SELECT u.map_id, u.thing_id FROM st_picked_up_items u JOIN params p ON u.tic = p.tic
),
sector_light_fx AS (
    SELECT f.map_id, f.sector_id, f.special, f.base_light, f.dark_light
    FROM st_sector_light_fx f JOIN params p ON f.tic = p.tic
),
mp_players AS (
    SELECT m.* FROM st_mp_players m JOIN params p ON m.tic = p.tic
),
-- render_segs: the game tic keeps f_*/b_* equal to the current front/back
-- sector, and switches overwrite the texture columns (st_render_seg_tex).
render_segs AS (
    SELECT s.map_id, s.seg_id, s.ssector_id, s.direction, s.linedef_id,
           s.x1, s.y1, s.x2, s.y2, s.seg_u1, s.seg_u2, s.fsec, s.bsec,
           s.x_offset, s.y_offset,
           CASE WHEN o.seg_id IS NULL THEN s.upper_tex ELSE o.upper_tex END AS upper_tex,
           CASE WHEN o.seg_id IS NULL THEN s.mid_tex   ELSE o.mid_tex   END AS mid_tex,
           CASE WHEN o.seg_id IS NULL THEN s.lower_tex ELSE o.lower_tex END AS lower_tex,
           s.flags,
           fs.floor_height AS f_floor, fs.ceil_height AS f_ceil, fs.ceil_tex AS f_ceil_tex,
           fs.light_level AS f_light,
           bs.floor_height AS b_floor, bs.ceil_height AS b_ceil, bs.ceil_tex AS b_ceil_tex,
           bs.light_level AS b_light,
           s.light_bias
    FROM render_segs_static s
    CROSS JOIN params p
    LEFT JOIN st_sectors fs ON fs.tic = p.tic AND fs.map_id = s.map_id AND fs.id = s.fsec
    LEFT JOIN st_sectors bs ON bs.tic = p.tic AND bs.map_id = s.map_id AND bs.id = s.bsec
    LEFT JOIN st_render_seg_tex o ON o.tic = p.tic AND o.map_id = s.map_id AND o.seg_id = s.seg_id
),
-- ------------------------------------------------------------------ reference
render_context AS (
    SELECT p.map_id AS map_id,
           p.player_id AS player_thing_id,
           p.skill AS skill,
           CASE WHEN p.skill <= 1 THEN 1 WHEN p.skill = 2 THEN 2 ELSE 4 END AS skill_bit
    FROM params p
),
pose_in AS (
    SELECT 1 AS i, px AS v FROM params UNION ALL
    SELECT 2, py FROM params UNION ALL
    SELECT 3, pz FROM params UNION ALL
    SELECT 4, pangle FROM params
),
pose_conv AS (
    -- CedarDB numeric-literal -> float8: float8(mantissa) / 10^scale, where the
    -- literal is Python's repr (shortest round-trip decimal): its scale is the
    -- smallest k whose nearest k-decimal value (ties to even, like repr) still
    -- converts back to v; mantissa = that value * 10^k.
    SELECT q.i,
           CASE WHEN q.v = 0 THEN 0d
                WHEN ABS(q.v) < 1e-4d OR ABS(q.v) >= 1e16d THEN q.v
                -- float8(mantissa): round to 53 bits, ties to even, in exact NUMBER math
                ELSE TO_BINARY_DOUBLE(
                       CASE WHEN ABS(k.m / u.ulp - TRUNC(k.m / u.ulp)) = 0.5
                            THEN 2 * ROUND(k.m / u.ulp / 2) ELSE ROUND(k.m / u.ulp) END * u.ulp)
                     / TO_BINARY_DOUBLE(POWER(10, k.k))
           END AS v
    FROM (SELECT e.i, e.v,
                 -- exact decimal of v (TO_NUMBER(binary_double) keeps only ~17 digits):
                 -- the 53-bit integer mantissa times 2^(e-52)
                 TO_NUMBER(e.v * POWER(2d, 52 - e.e)) * POWER(2, e.e - 52) AS n,
                 POWER(2, e.e - 53) AS half_ulp
          FROM (SELECT f.i, f.v, f.e0
                         - CASE WHEN POWER(2, f.e0) > ABS(f.a) THEN 1 ELSE 0 END
                         + CASE WHEN POWER(2, f.e0 + 1) <= ABS(f.a) THEN 1 ELSE 0 END AS e
                FROM (SELECT i, v, TO_NUMBER(v) AS a,
                             CASE WHEN v = 0 THEN 0 ELSE FLOOR(LOG(2, ABS(TO_NUMBER(v)))) END AS e0
                      FROM pose_in) f) e) q
    CROSS APPLY (SELECT MIN(c.k) AS k, MIN(c.m) KEEP (DENSE_RANK FIRST ORDER BY c.k) AS m
                 FROM (SELECT g.n AS k,
                              CASE WHEN ABS(q.n * POWER(10, g.n) - TRUNC(q.n * POWER(10, g.n))) = 0.5
                                   THEN 2 * ROUND(q.n * POWER(10, g.n) / 2)
                                   ELSE ROUND(q.n * POWER(10, g.n)) END AS m
                       FROM nums g WHERE g.n <= 40) c
                 -- round-trip test done exactly (TO_BINARY_DOUBLE(NUMBER) is not
                 -- always correctly rounded): |decimal - v| < ulp(v) / 2
                 WHERE ABS(c.m / POWER(10, c.k) - q.n) < q.half_ulp) k
    CROSS APPLY (SELECT CASE WHEN ABS(k.m) < 9007199254740992 THEN 1
                             WHEN ABS(k.m) < 18014398509481984 THEN 2
                             WHEN ABS(k.m) < 36028797018963968 THEN 4
                             WHEN ABS(k.m) < 72057594037927936 THEN 8 ELSE 16 END AS ulp
                 FROM dual) u
),
pos AS (
    SELECT MAX(CASE i WHEN 1 THEN v END) AS x, MAX(CASE i WHEN 2 THEN v END) AS y,
           MAX(CASE i WHEN 3 THEN v END) AS z, MAX(CASE i WHEN 4 THEN v END) AS angle
    FROM pose_conv
),
frame_clock AS (
    SELECT COALESCE(MAX(ps.level_tics), 0) AS t
    FROM player_state ps CROSS JOIN render_context rc
    WHERE ps.map_id = rc.map_id AND ps.player_thing_id = rc.player_thing_id
),
animated_light AS (
    SELECT k.sector_id,
      LEAST(255, GREATEST(0,
    CASE k.special
      WHEN 2  THEN CASE WHEN MOD(k.t + k.phase, 20) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 13 THEN CASE WHEN MOD(k.t, 20) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 3  THEN CASE WHEN MOD(k.t + k.phase, 40) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 12 THEN CASE WHEN MOD(k.t, 40) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 1  THEN CASE WHEN MOD(k.sector_id * 2654435761 + TRUNC(k.t / 4), 8) < 2
                        THEN k.dark_light ELSE k.base_light END
      WHEN 17 THEN GREATEST(k.dark_light,
                     k.base_light - MOD(MOD(MOD(TRUNC(k.t / 3), 1000) * MOD(TRUNC(k.t / 3), 1000)
                                            * 1103515245 + k.sector_id * 40503, 1009), 4)
                       * GREATEST(1, TRUNC((k.base_light - k.dark_light) / 4)))
      WHEN 8  THEN (k.dark_light + 8 * (
                      CASE WHEN MOD(k.t + k.phase, 2 * k.glow_steps) < k.glow_steps
                           THEN MOD(k.t + k.phase, 2 * k.glow_steps)
                           ELSE 2 * k.glow_steps - MOD(k.t + k.phase, 2 * k.glow_steps)
                      END))
      ELSE k.base_light
    END
      )) AS light_level
    FROM (
      SELECT f.sector_id, f.base_light, f.dark_light, f.special,
             MOD(f.sector_id * 7919, 64) AS phase,
             GREATEST(1, TRUNC((f.base_light - f.dark_light) / 8)) AS glow_steps,
             fc.t
      FROM sector_light_fx f
      CROSS JOIN render_context rc
      CROSS JOIN frame_clock fc
      WHERE f.map_id = rc.map_id
    ) k
),
sectors_lit AS (
    SELECT s.map_id, s.id, s.floor_height, s.ceil_height,
           s.spawn_floor_height, s.spawn_ceil_height, s.spawn_floor_tex,
           s.spawn_light_level, s.floor_tex, s.ceil_tex,
           COALESCE(a.light_level, s.light_level) AS light_level,
           s.special, s.tag
    FROM sectors s
    CROSS JOIN render_context rc
    LEFT JOIN animated_light a ON a.sector_id = s.id
    WHERE s.map_id = rc.map_id
),
scrolling_segs AS (
    SELECT ld.id AS linedef_id
    FROM linedefs ld CROSS JOIN render_context rc
    WHERE ld.map_id = rc.map_id AND ld.scrolls
),
render_settings AS (
    SELECT
      320 AS screen_w,
      168 AS screen_h,
      fov_rad,
      160 AS cx,
      84 AS cy,
      160d / TAN(fov_rad / 2d) AS focal,
      TAN(fov_rad / 2d) AS tan_half_fov,
      1e-3d AS near,
      16d * (160d / TAN(fov_rad / 2d)) AS max_plane_depth,
      202.5d AS rotation_offset,
      45d AS rotation_span,
      32 AS light_index_invuln,
      23 AS light_psprite_bias,
      256 AS sky_columns,
      90 AS sky_degrees,
      2.844444d AS sky_ratio,          -- numeric 256.0/90.0 in CedarDB = 2.844444
      128 AS sky_rows,
      100 AS sky_horizon_y,
      64 AS flat_size
    FROM (SELECT 90d * (3.14159265358979323846d / 180d) AS fov_rad FROM dual)
),
cam AS (
    SELECT pos.x AS px, pos.y AS py, pos.z AS pz,
           pos.angle * (3.14159265358979323846d / 180d) AS view_rad
    FROM pos
),
weapon_runtime AS (
    SELECT rc.map_id, rc.player_thing_id,
           COALESCE(w.sx, 1d) AS sx, COALESCE(w.sy, 32d) AS sy,
           CASE WHEN COALESCE(ps2.light_amp_tics, 0) > 0 THEN 16
                ELSE COALESCE(w.flash_seq_index, -1) + 1 END AS extra_light,
           COALESCE(ps2.invuln_tics, 0) > 0 AS invuln,
           wd.sprite, wd.flash_sprite,
           CASE WHEN COALESCE(w.state, 'ready') IN ('up', 'down')
                THEN rf.frame ELSE mf.frame END AS frame,
           CASE WHEN COALESCE(w.state, 'ready') IN ('up', 'down')
                THEN rf.fullbright ELSE mf.fullbright END AS fullbright,
           ff.frame AS flash_frame, ff.fullbright AS flash_fullbright
    FROM render_context rc
    LEFT JOIN player_weapons w ON w.map_id = rc.map_id
      AND w.player_thing_id = rc.player_thing_id
    LEFT JOIN player_state ps2 ON ps2.map_id = rc.map_id
      AND ps2.player_thing_id = rc.player_thing_id
    JOIN weapon_defs wd ON wd.weapon_id = COALESCE(w.current_weapon, 2)
    LEFT JOIN weapon_frames rf ON rf.weapon_id = wd.weapon_id
      AND rf.state = 'ready' AND rf.seq_index = 0
    LEFT JOIN weapon_frames mf ON mf.weapon_id = wd.weapon_id
      AND mf.state = COALESCE(w.state, 'ready') AND mf.seq_index = COALESCE(w.seq_index, 0)
    LEFT JOIN weapon_frames ff ON ff.weapon_id = wd.weapon_id
      AND ff.state = 'flash' AND ff.seq_index = w.flash_seq_index
),
visible_children AS (
  SELECT
    nc.map_id, nc.node_id, nc.side,
    (c.px BETWEEN nc.bbox_left AND nc.bbox_right
     AND c.py BETWEEN nc.bbox_bottom AND nc.bbox_top)
    OR (
      ((SIN(-c.view_rad) - rs.tan_half_fov*COS(-c.view_rad))
         * (CASE WHEN (SIN(-c.view_rad) - rs.tan_half_fov*COS(-c.view_rad)) >= 0
                 THEN nc.bbox_left ELSE nc.bbox_right END)
       + (COS(-c.view_rad) + rs.tan_half_fov*SIN(-c.view_rad))
         * (CASE WHEN (COS(-c.view_rad) + rs.tan_half_fov*SIN(-c.view_rad)) >= 0
                 THEN nc.bbox_bottom ELSE nc.bbox_top END)
       + (-c.px*SIN(-c.view_rad) - c.py*COS(-c.view_rad)
          + rs.tan_half_fov*(c.px*COS(-c.view_rad) - c.py*SIN(-c.view_rad)))
      ) <= 0.5d
      AND
      ((-SIN(-c.view_rad) - rs.tan_half_fov*COS(-c.view_rad))
         * (CASE WHEN (-SIN(-c.view_rad) - rs.tan_half_fov*COS(-c.view_rad)) >= 0
                 THEN nc.bbox_left ELSE nc.bbox_right END)
       + (-COS(-c.view_rad) + rs.tan_half_fov*SIN(-c.view_rad))
         * (CASE WHEN (-COS(-c.view_rad) + rs.tan_half_fov*SIN(-c.view_rad)) >= 0
                 THEN nc.bbox_bottom ELSE nc.bbox_top END)
       + (c.px*SIN(-c.view_rad) + c.py*COS(-c.view_rad)
          + rs.tan_half_fov*(c.px*COS(-c.view_rad) - c.py*SIN(-c.view_rad)))
      ) <= 0.5d
      AND
      ((-COS(-c.view_rad))
         * (CASE WHEN (-COS(-c.view_rad)) >= 0 THEN nc.bbox_left ELSE nc.bbox_right END)
       + (SIN(-c.view_rad))
         * (CASE WHEN SIN(-c.view_rad) >= 0 THEN nc.bbox_bottom ELSE nc.bbox_top END)
       + (rs.near + c.px*COS(-c.view_rad) - c.py*SIN(-c.view_rad))
      ) <= 0.5d
    ) AS keep
  FROM node_children nc
  CROSS JOIN cam c
  CROSS JOIN render_settings rs
  CROSS JOIN render_context rctx
  WHERE nc.map_id = rctx.map_id
),
bsp_order AS (
  SELECT s.ssector_id, ROW_NUMBER() OVER (ORDER BY s.sort_key) AS bsp_seq
  FROM (
    SELECT st.ssector_id,
           SUM(CASE WHEN st.side = fs.front_side THEN 0
                    ELSE POWER(2, 40 - st.depth) END) AS sort_key,
           MIN(CASE WHEN vc.keep THEN 1 ELSE 0 END) AS visible
    FROM node_path_steps st
    CROSS JOIN render_context rc
    JOIN nodes n ON n.map_id = st.map_id AND n.id = st.node_id
    CROSS JOIN pos p
    CROSS APPLY (
      SELECT CASE
               WHEN TO_NUMBER(ROUND(p.x - n.x)) * n.dy - TO_NUMBER(ROUND(p.y - n.y)) * n.dx > 0
                 THEN 'R' ELSE 'L'
             END AS front_side
      FROM dual
    ) fs
    JOIN visible_children vc ON vc.map_id = st.map_id AND vc.node_id = st.node_id
      AND vc.side = st.side
    WHERE st.map_id = rc.map_id
    GROUP BY st.ssector_id
  ) s
  WHERE s.visible = 1
),
player_sector AS (
  SELECT sec.*
  FROM bsp_order bo
  CROSS JOIN render_context rc
  JOIN render_segs sg ON sg.map_id = rc.map_id
    AND sg.ssector_id = bo.ssector_id
  JOIN sectors_lit sec ON sec.map_id = rc.map_id AND sec.id = sg.fsec
  WHERE bo.bsp_seq = 1
  ORDER BY sg.seg_id
  FETCH FIRST 1 ROW ONLY
),
segs_with_verts AS (
  SELECT
    s.seg_id, s.direction, s.linedef_id, s.map_id,
    s.x1, s.y1, s.x2, s.y2,
    s.seg_u1, s.seg_u2
  FROM render_segs s
  JOIN bsp_order bo ON bo.ssector_id = s.ssector_id
  CROSS JOIN pos
  CROSS JOIN render_context rc
  WHERE s.map_id = rc.map_id
    AND (s.x2 - s.x1) * TO_NUMBER(ROUND(pos.y - s.y1))
      - (s.y2 - s.y1) * TO_NUMBER(ROUND(pos.x - s.x1)) < 0
),
viewspace AS (
    SELECT
        s.seg_id, s.direction, s.linedef_id, s.map_id,
        s.seg_u1, s.seg_u2,
        (s.x1 - c.px) * COS(-c.view_rad) - (s.y1 - c.py) * SIN(-c.view_rad) AS x1,
        -((s.x1 - c.px) * SIN(-c.view_rad) + (s.y1 - c.py) * COS(-c.view_rad)) AS y1,
        (s.x2 - c.px) * COS(-c.view_rad) - (s.y2 - c.py) * SIN(-c.view_rad) AS x2,
        -((s.x2 - c.px) * SIN(-c.view_rad) + (s.y2 - c.py) * COS(-c.view_rad)) AS y2
    FROM segs_with_verts s CROSS JOIN cam c
),
visible AS (
    SELECT * FROM viewspace WHERE x1 > 0 OR x2 > 0
),
clipped AS (
    SELECT
        v.seg_id, v.direction, v.linedef_id, v.map_id, v.seg_u1, v.seg_u2,
        CASE WHEN v.x1 < rs.near THEN rs.near ELSE v.x1 END AS cx1,
        CASE WHEN v.x1 < rs.near THEN v.y1 + (rs.near - v.x1)*(v.y2 - v.y1)/(v.x2 - v.x1) ELSE v.y1 END AS cy1,
        CASE WHEN v.x2 < rs.near THEN rs.near ELSE v.x2 END AS cx2,
        CASE WHEN v.x2 < rs.near THEN v.y2 + (rs.near - v.x2)*(v.y1 - v.y2)/(v.x1 - v.x2) ELSE v.y2 END AS cy2
    FROM visible v, render_settings rs
),
projected AS (
    SELECT
        c.seg_id, c.direction, c.linedef_id, c.map_id,
        c.cx1, c.cy1, c.cx2, c.cy2,
        rs.cx + rs.focal*(c.cy1/c.cx1) AS screen_x1,
        rs.cx + rs.focal*(c.cy2/c.cx2) AS screen_x2,
        1d/c.cx1 AS invx1,
        1d/c.cx2 AS invx2,
        c.seg_u1, c.seg_u2
    FROM clipped c, render_settings rs
),
on_screen AS (
  SELECT p.*
  FROM projected p
  CROSS JOIN render_settings rs
  WHERE GREATEST(p.screen_x1, p.screen_x2) >= 0
    AND LEAST(p.screen_x1, p.screen_x2) < rs.screen_w
),
heights AS (
  SELECT
    p.*, s.fsec, s.bsec,
    (s.x_offset + CASE WHEN sc.linedef_id IS NULL THEN 0 ELSE fc.t END) AS x_offset,
    s.y_offset,
    s.upper_tex, s.mid_tex, s.lower_tex, s.flags,
    s.f_floor, s.f_ceil, s.f_ceil_tex,
    COALESCE(alf.light_level, s.f_light) AS f_light,
    s.b_floor, s.b_ceil, s.b_ceil_tex,
    COALESCE(alb.light_level, s.b_light) AS b_light
  FROM on_screen p
  JOIN render_segs s ON s.map_id = p.map_id AND s.seg_id = p.seg_id
  CROSS JOIN frame_clock fc
  LEFT JOIN animated_light alf ON alf.sector_id = s.fsec
  LEFT JOIN animated_light alb ON alb.sector_id = s.bsec
  LEFT JOIN scrolling_segs sc ON sc.linedef_id = s.linedef_id
),
seg_light_bias AS (
  SELECT s.seg_id, s.light_bias
  FROM render_segs s
  CROSS JOIN render_context rc
  WHERE s.map_id = rc.map_id
),
seg_bsp AS (
  SELECT s.seg_id, bo.bsp_seq
  FROM render_segs s
  JOIN bsp_order bo ON bo.ssector_id = s.ssector_id
  CROSS JOIN render_context rc
  WHERE s.map_id = rc.map_id
),
occluders AS (
  SELECT h.seg_id, h.screen_x1, h.screen_x2, sb.bsp_seq
  FROM heights h
  JOIN seg_bsp sb ON sb.seg_id = h.seg_id
  WHERE h.bsec IS NULL OR h.b_ceil <= h.b_floor
),
occlusion_cols AS (
  SELECT g.n AS col_x, o.bsp_seq
  FROM occluders o
  CROSS JOIN render_settings rs
  JOIN nums g ON g.n BETWEEN GREATEST(0, FLOOR(LEAST(o.screen_x1, o.screen_x2)))
                         AND LEAST(rs.screen_w - 1, CEIL(GREATEST(o.screen_x1, o.screen_x2)))
  WHERE o.screen_x1 <> o.screen_x2
),
min_occlusion AS (
  SELECT col_x, MIN(bsp_seq) AS min_bsp_seq
  FROM occlusion_cols
  GROUP BY col_x
),
wall_parts AS (
  SELECT seg_id, 'solid' AS part, mid_tex AS tex, x_offset, y_offset, flags,
         f_floor AS z_bot, f_ceil AS z_top,
         CASE WHEN BITAND(flags, 16) <> 0 THEN f_floor ELSE f_ceil END AS v_anchor_base,
         BITAND(flags, 16) <> 0 AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NULL
  AND f_ceil > f_floor
  UNION ALL
  SELECT seg_id, 'upper', upper_tex, x_offset, y_offset, flags,
         b_ceil AS z_bot, f_ceil AS z_top,
         CASE WHEN BITAND(flags, 8) <> 0 THEN f_ceil ELSE b_ceil END AS v_anchor_base,
         BITAND(flags, 8) = 0 AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_ceil < f_ceil
  AND ((f_ceil_tex IS NULL OR f_ceil_tex <> 'F_SKY1')
       OR (b_ceil_tex IS NULL OR b_ceil_tex <> 'F_SKY1'))
  UNION ALL
  SELECT seg_id, 'upper_open', CAST(NULL AS VARCHAR2(8)), x_offset, y_offset, flags,
         f_ceil AS z_bot, b_ceil AS z_top,
         b_ceil AS v_anchor_base, FALSE AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_ceil > f_ceil
  AND ((f_ceil_tex IS NULL OR f_ceil_tex <> 'F_SKY1')
       OR (b_ceil_tex IS NULL OR b_ceil_tex <> 'F_SKY1'))
  UNION ALL
  SELECT seg_id, 'upper_flush', CAST(NULL AS VARCHAR2(8)), x_offset, y_offset, flags,
         f_ceil AS z_bot, b_ceil AS z_top,
         b_ceil AS v_anchor_base, FALSE AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_ceil = f_ceil
  AND ((f_ceil_tex IS NULL OR f_ceil_tex <> 'F_SKY1')
       OR (b_ceil_tex IS NULL OR b_ceil_tex <> 'F_SKY1'))
  UNION ALL
  SELECT seg_id, 'lower', lower_tex, x_offset, y_offset, flags,
         f_floor AS z_bot, b_floor AS z_top,
         CASE WHEN BITAND(flags, 16) <> 0 THEN f_ceil ELSE b_floor END AS v_anchor_base,
         FALSE AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_floor > f_floor
  UNION ALL
  SELECT seg_id, 'lower_down', CAST(NULL AS VARCHAR2(8)), x_offset, y_offset, flags,
         b_floor AS z_bot, f_floor AS z_top,
         f_floor AS v_anchor_base, FALSE AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_floor <= f_floor
  UNION ALL
  SELECT seg_id, 'midmask', mid_tex, x_offset, y_offset, flags,
         f_floor AS z_bot, f_ceil AS z_top,
         CASE WHEN BITAND(flags, 16) <> 0 THEN GREATEST(f_floor, b_floor)
              ELSE LEAST(f_ceil, b_ceil) END AS v_anchor_base,
         BITAND(flags, 16) <> 0 AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2
  FROM heights
  WHERE bsec IS NOT NULL
  AND mid_tex IS NOT NULL
  AND mid_tex <> '-'
  AND f_ceil > f_floor
),
wall_parts_tex AS (
  -- tex_pi (the bytea) is replaced by tex_found + tex_len; the bytes are read
  -- from blob_chunks (kind 'W', name = tex).
  SELECT wp.*,
         COALESCE(m.width, 64)  AS tex_w,
         COALESCE(m.height, 64) AS tex_h,
         m.width                AS tex_width,
         m.name                 AS tex_found,
         m.width * m.height     AS tex_len
  FROM wall_parts wp
  LEFT JOIN walltex_meta m ON m.name = wp.tex
),
columns AS (
  SELECT
    w.*,
    sb.bsp_seq,
    (w.x_offset + w.seg_u1) AS u1,
    (w.x_offset + w.seg_u2) AS u2,
    g.n AS col_x,
    g.n AS screen_x_clamped,
    LEAST(1d, GREATEST(0d,
      (g.n - w.screen_x1) / NULLIF(w.screen_x2 - w.screen_x1, 1e-6d))) AS t
  FROM wall_parts_tex w
  CROSS JOIN render_settings rs
  JOIN seg_bsp sb ON sb.seg_id = w.seg_id
  CROSS APPLY (
    SELECT
      NOT (GREATEST(w.screen_x1, w.screen_x2) < 0 OR LEAST(w.screen_x1, w.screen_x2) >= rs.screen_w) AS on_screen,
      GREATEST(0, TO_NUMBER(FLOOR(LEAST(w.screen_x1, w.screen_x2))))    AS x_lo,
      LEAST(rs.screen_w - 1, TO_NUMBER(CEIL(GREATEST(w.screen_x1, w.screen_x2)))) AS x_hi
    FROM dual
  ) b
  JOIN nums g ON g.n BETWEEN b.x_lo AND b.x_hi
  LEFT JOIN min_occlusion mo ON mo.col_x = g.n
  WHERE b.on_screen
    AND w.screen_x1 <> w.screen_x2
    AND sb.bsp_seq <= COALESCE(mo.min_bsp_seq, sb.bsp_seq)
),
per_column AS (
  SELECT
    c.*,
    iv.invx,
    iv.u_over_x,
    1d / iv.invx                         AS depth_x,
    iv.u_over_x / NULLIF(iv.invx, 1e-6d) AS u_col,
    rs.focal * iv.invx                   AS scale
  FROM columns c
  CROSS JOIN render_settings rs
  CROSS APPLY (
    SELECT
      c.invx1 + c.t * (c.invx2 - c.invx1)                              AS invx,
      (c.u1 * c.invx1) + c.t * ((c.u2 * c.invx2) - (c.u1 * c.invx1)) AS u_over_x
    FROM dual
  ) iv
),
vertical AS (
  SELECT
    p.*,
    c.pz AS view_z, rs.cy AS screen_cy,
    (rs.cy - p.scale * (p.z_top - c.pz)) AS y_top_f,
    (rs.cy - p.scale * (p.z_bot - c.pz)) AS y_bot_f,
    p.v_anchor_base
      + CASE WHEN p.v_anchor_add_tex_h THEN p.tex_h ELSE 0 END
      AS v_anchor_z
  FROM per_column p
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
),
clamped_spans AS (
  SELECT
    t.*,
    t.v_anchor_z
      - (t.view_z + (t.screen_cy - TO_BINARY_DOUBLE(t.y_start)) / NULLIF(t.scale, 1e-9d))
      + TO_BINARY_DOUBLE(t.y_offset) AS v0,
    1d / NULLIF(t.scale, 1e-9d) AS v_step
  FROM (
    SELECT
      v.*,
      TO_NUMBER(CEIL(
        LEAST(rs.screen_h - 1d, GREATEST(0d, LEAST(v.y_top_f, v.y_bot_f)))
      )) AS y_start,
      TO_NUMBER(FLOOR(
        LEAST(rs.screen_h - 1d, GREATEST(0d, GREATEST(v.y_top_f, v.y_bot_f)))
      )) AS y_end
    FROM vertical v
    CROSS JOIN render_settings rs
    WHERE LEAST(v.y_top_f, v.y_bot_f) < rs.screen_h
      AND GREATEST(v.y_top_f, v.y_bot_f) >= 0
  ) t
  WHERE t.y_end >= t.y_start
),
clamped_spans_lit AS (
  SELECT c.*,
         CASE WHEN wr.invuln THEN rs.light_index_invuln
              ELSE -- doom_light_index(f_light, light_bias + extra_light, doom_light_scale(depth_x))
                GREATEST(0, LEAST(31,
                  (15 - LEAST(15, GREATEST(0, FLOOR(c.f_light / 16) + (b.light_bias + wr.extra_light)))) * 4
                  - CASE WHEN c.depth_x = 0 THEN 0
                         ELSE TO_NUMBER(FLOOR(LEAST(47d, GREATEST(0d, 2560d / c.depth_x)) / 2d)) END))
         END AS light_index,
         (c.seg_id * 8 + CASE c.part
            WHEN 'solid' THEN 0 WHEN 'upper' THEN 1 WHEN 'lower' THEN 2
            WHEN 'lower_down' THEN 3 ELSE 7 END) AS stable_id
  FROM clamped_spans c
  JOIN seg_light_bias b ON b.seg_id = c.seg_id
  CROSS JOIN weapon_runtime wr
  CROSS JOIN render_settings rs
),
fragments AS (
  SELECT
    c.seg_id, c.part, c.tex, c.tex_width, c.tex_found, c.tex_len, c.light_index, c.stable_id,
    c.screen_x_clamped AS x,
    g.n AS y,
    c.depth_x AS depth,
    TO_NUMBER(FLOOR(c.u_col - c.tex_w * FLOOR(c.u_col / c.tex_w))) AS u_i,
    MOD(MOD(TO_NUMBER(FLOOR(c.v0 + (g.n - c.y_start) * c.v_step)), c.tex_h) + c.tex_h, c.tex_h) AS v_i,
    c.f_light AS sector_light,
    c.fsec    AS sector_id
  FROM clamped_spans_lit c
  JOIN nums g ON g.n BETWEEN c.y_start AND c.y_end
  WHERE c.tex IS NOT NULL AND c.tex <> '-'
),
wall_tex AS (
  SELECT
    f.x, f.y, f.depth, f.light_index, f.stable_id,
    CASE
      WHEN f.tex_found IS NULL
        OR (f.v_i * f.tex_width + f.u_i) < 0
        OR (f.v_i * f.tex_width + f.u_i) >= f.tex_len
      THEN 0 ELSE
      ASCII(SUBSTR(bc.px, MOD(f.v_i * f.tex_width + f.u_i, 1000) + 1, 1)) - 256
    END AS palette_index
  FROM fragments f
  LEFT JOIN blob_chunks bc ON bc.kind = 'W' AND bc.name = f.tex
    AND bc.blk = FLOOR((f.v_i * f.tex_width + f.u_i) / 1000)
),
colored AS (
  SELECT w.x, w.y, w.depth, w.light_index, w.palette_index, w.stable_id
  FROM wall_tex w
),
-- VISPLANES
panel_cols AS (
  SELECT
    v.col_x, v.seg_id, v.bsp_seq, v.part, v.depth_x, v.y_top_f, v.y_bot_f,
    CASE WHEN v.part = 'lower_down' THEN v.y_top_f ELSE v.y_bot_f END AS f_floor_y_f,
    CASE WHEN v.part = 'upper_open' THEN v.y_bot_f ELSE v.y_top_f END AS f_ceil_y_f,
    h.fsec, h.f_light, h.f_floor, h.f_ceil,
    (h.f_ceil_tex = 'F_SKY1') AS f_ceil_is_sky
  FROM vertical v
  JOIN heights h ON h.seg_id = v.seg_id
  CROSS JOIN render_settings rs
  WHERE v.part IN ('upper_open','upper_flush','lower_down')
     OR (LEAST(v.y_top_f, v.y_bot_f) < rs.screen_h
         AND GREATEST(v.y_top_f, v.y_bot_f) >= 0)
),
panel_seq AS (
  SELECT p.*,
         ROW_NUMBER() OVER (
           PARTITION BY p.col_x
           ORDER BY p.depth_x ASC, p.bsp_seq ASC, p.part, p.seg_id
         ) AS seq
  FROM panel_cols p
),
panel_clips AS (
  SELECT
    p.*,
    COALESCE(
      MAX(CASE
            WHEN p.part IN ('solid','upper')
              THEN TO_NUMBER(FLOOR(LEAST(rs.screen_h - 1d, GREATEST(0d, p.y_bot_f)))) + 1
            WHEN p.part = 'upper_flush'
              THEN GREATEST(0, TO_NUMBER(FLOOR(LEAST(rs.screen_h - 1d, p.y_bot_f))) + 1)
          END)
        OVER (PARTITION BY p.col_x ORDER BY p.depth_x ASC, p.bsp_seq ASC, p.part, p.seg_id
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
      0
    ) AS cc_before,
    COALESCE(
      MIN(CASE WHEN p.part IN ('solid','lower','lower_down')
               THEN LEAST(rs.screen_h - 1, TO_NUMBER(CEIL(GREATEST(0d, p.y_top_f))) - 1) END)
        OVER (PARTITION BY p.col_x ORDER BY p.depth_x ASC, p.bsp_seq ASC, p.part, p.seg_id
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
      rs.screen_h - 1
    ) AS fc_before,
    pc.fsec AS carried_ceil_sec,
    pc.f_ceil AS carried_ceil_z,
    pc.f_light AS carried_ceil_light,
    COALESCE(pc.is_sky, FALSE) AS carried_ceil_is_sky,
    pf.fsec AS carried_floor_sec,
    pf.f_floor AS carried_floor_z,
    pf.f_light AS carried_floor_light
  FROM panel_seq p
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  OUTER APPLY (
    SELECT q.fsec, q.f_ceil, q.f_light, q.f_ceil_is_sky AS is_sky
    FROM panel_seq q
    WHERE q.col_x = p.col_x AND q.seq < p.seq
      AND q.f_ceil > c.pz
    ORDER BY q.seq DESC
    FETCH FIRST 1 ROW ONLY
  ) pc
  OUTER APPLY (
    SELECT q.fsec, q.f_floor, q.f_light
    FROM panel_seq q
    WHERE q.col_x = p.col_x AND q.seq < p.seq
      AND q.f_floor < c.pz
    ORDER BY q.seq DESC
    FETCH FIRST 1 ROW ONLY
  ) pf
),
nearest_floor_panel AS (
  SELECT col_x, MIN(depth_x) AS depth_x
  FROM panel_cols
  WHERE part IN ('solid','lower','lower_down')
  GROUP BY col_x
),
nearest_ceiling_panel AS (
  SELECT col_x, MIN(depth_x) AS depth_x
  FROM panel_cols
  WHERE part IN ('solid','upper','upper_open','upper_flush')
  GROUP BY col_x
),
plane_spans_raw AS (
  SELECT
    k.col_x,
    CASE WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky
         THEN k.fsec    ELSE k.carried_ceil_sec   END AS sector_id,
    CASE WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky
         THEN k.f_ceil  ELSE k.carried_ceil_z     END AS plane_z,
    CASE WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky
         THEN k.f_light ELSE k.carried_ceil_light END AS sector_light,
    CASE WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky
         THEN k.f_ceil_is_sky ELSE k.carried_ceil_is_sky END AS is_sky,
    'ceil' AS plane, 1 AS source_priority,
    GREATEST(0, k.cc_before) AS y0,
    b.y1
  FROM panel_clips k
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  CROSS APPLY (
    SELECT TO_NUMBER(CEIL(LEAST(rs.screen_h - 1d, GREATEST(0d,
      CASE
        WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky THEN k.f_ceil_y_f
        -- LEAST ignores a NULL argument in CedarDB
        ELSE CASE WHEN k.carried_ceil_z IS NULL THEN k.f_ceil_y_f
                  ELSE LEAST(k.f_ceil_y_f,
                             rs.cy - rs.focal * (k.carried_ceil_z - c.pz)
                                     / rs.max_plane_depth) END
      END
    )))) - 1 AS y1
    FROM dual
  ) b
  WHERE k.part IN ('solid','upper','upper_open','upper_flush','midmask')
    AND b.y1 >= k.cc_before
    AND (k.f_ceil > c.pz OR k.f_ceil_is_sky
         OR k.carried_ceil_is_sky OR k.cc_before > 0)
  UNION ALL
  SELECT
    k.col_x,
    CASE WHEN k.f_floor < c.pz THEN k.fsec    ELSE k.carried_floor_sec   END AS sector_id,
    CASE WHEN k.f_floor < c.pz THEN k.f_floor ELSE k.carried_floor_z     END AS plane_z,
    CASE WHEN k.f_floor < c.pz THEN k.f_light ELSE k.carried_floor_light END AS sector_light,
    FALSE AS is_sky,
    'floor' AS plane, 1 AS source_priority,
    b.y0,
    LEAST(rs.screen_h - 1, k.fc_before) AS y1
  FROM panel_clips k
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  CROSS APPLY (
    SELECT TO_NUMBER(FLOOR(LEAST(rs.screen_h - 1d, GREATEST(0d,
      CASE
        WHEN k.f_floor < c.pz THEN k.f_floor_y_f
        ELSE CASE WHEN k.carried_floor_z IS NULL THEN k.f_floor_y_f
                  ELSE GREATEST(k.f_floor_y_f,
                                rs.cy - rs.focal * (k.carried_floor_z - c.pz)
                                        / rs.max_plane_depth) END
      END
    )))) + 1 AS y0
    FROM dual
  ) b
  WHERE k.part IN ('solid','midmask','lower','lower_down')
    AND b.y0 <= k.fc_before
    AND (k.f_floor < c.pz OR k.fc_before < rs.screen_h - 1)
  UNION ALL
  SELECT
    g.n AS col_x,
    ps.id AS sector_id,
    ps.floor_height AS plane_z,
    ps.light_level AS sector_light,
    FALSE AS is_sky,
    'floor' AS plane,
    0 AS source_priority,
    CASE WHEN np.depth_x IS NULL THEN FLOOR(rs.cy) + 1
         ELSE TO_NUMBER(FLOOR(LEAST(rs.screen_h - 1d, GREATEST(0d,
           rs.cy - rs.focal * (ps.floor_height - c.pz) / np.depth_x
         )))) + 1
    END AS y0,
    rs.screen_h - 1 AS y1
  FROM render_settings rs
  CROSS JOIN cam c
  CROSS JOIN player_sector ps
  JOIN nums g ON g.n BETWEEN 0 AND rs.screen_w - 1
  LEFT JOIN nearest_floor_panel np ON np.col_x = g.n
  UNION ALL
  SELECT
    g.n AS col_x,
    ps.id AS sector_id,
    ps.ceil_height AS plane_z,
    ps.light_level AS sector_light,
    (ps.ceil_tex = 'F_SKY1') AS is_sky,
    'ceil' AS plane,
    0 AS source_priority,
    0 AS y0,
    CASE WHEN np.depth_x IS NULL THEN CEIL(rs.cy) - 1
         ELSE TO_NUMBER(CEIL(LEAST(rs.screen_h - 1d, GREATEST(0d,
           rs.cy - rs.focal * (ps.ceil_height - c.pz) / np.depth_x
         )))) - 1
    END AS y1
  FROM render_settings rs
  CROSS JOIN cam c
  CROSS JOIN player_sector ps
  JOIN nums g ON g.n BETWEEN 0 AND rs.screen_w - 1
  LEFT JOIN nearest_ceiling_panel np ON np.col_x = g.n
),
plane_spans AS (
  SELECT ps.*
  FROM plane_spans_raw ps
  CROSS JOIN cam c
  WHERE (ps.plane = 'floor' AND ps.plane_z < c.pz)
     OR (ps.plane = 'ceil'  AND (ps.plane_z > c.pz OR ps.is_sky))
),
plane_spans_deduped AS (
  SELECT col_x, sector_id, plane_z, plane, is_sky, y0, y1,
         MIN(sector_light)    AS sector_light,
         MIN(source_priority) AS source_priority
  FROM plane_spans
  WHERE y1 >= y0
  GROUP BY col_x, sector_id, plane_z, plane, is_sky, y0, y1
),
plane_pixels AS (
  SELECT ps.col_x AS x, g.n AS y, ps.sector_id, ps.plane_z, ps.sector_light,
         ps.plane, ps.is_sky, ps.source_priority
  FROM plane_spans_deduped ps
  JOIN nums g ON g.n BETWEEN ps.y0 AND ps.y1
),
plane_rays AS (
  SELECT
    pp.x, pp.y, pp.sector_id, pp.sector_light, pp.plane, pp.source_priority,
    CASE WHEN pp.is_sky THEN 1e7d
         ELSE (rs.focal * (pp.plane_z - c.pz)) / NULLIF(rs.cy - pp.y, 0)
    END AS depth_x,
    (pp.x - rs.cx) / rs.focal AS tan_alpha
  FROM plane_pixels pp
  CROSS JOIN cam c
  CROSS JOIN render_settings rs
  WHERE pp.is_sky
     OR (rs.focal * (pp.plane_z - c.pz)) / NULLIF(rs.cy - pp.y, 0) > rs.near
),
plane_world AS (
  SELECT
    pr.x, pr.y, pr.sector_id, pr.sector_light, pr.plane, pr.source_priority,
    pr.depth_x AS depth,
    (c.px + pr.depth_x * COS(c.view_rad) + (pr.tan_alpha * pr.depth_x) * SIN(c.view_rad)) AS wx,
    (c.py + pr.depth_x * SIN(c.view_rad) - (pr.tan_alpha * pr.depth_x) * COS(c.view_rad)) AS wy,
    (c.view_rad - ATAN(pr.tan_alpha)) * (180d / 3.14159265358979323846d) AS ray_deg
  FROM plane_rays pr
  CROSS JOIN cam c
),
plane_tex AS (
  SELECT
    pw.*,
    (CASE WHEN pw.plane = 'floor' THEN s.floor_tex ELSE s.ceil_tex END) AS tex_name
  FROM plane_world pw
  CROSS JOIN render_context rc
  JOIN sectors_lit s ON s.id = pw.sector_id AND s.map_id = rc.map_id
),
plane_uv AS (
  SELECT
    x, y, sector_id, sector_light, plane, source_priority, depth, tex_name,
    (tex_name = 'F_SKY1') AS is_sky,
    CASE WHEN tex_name = 'F_SKY1'
      THEN MOD(MOD(TO_NUMBER(FLOOR(ray_deg * rs.sky_ratio)), rs.sky_columns) + rs.sky_columns, rs.sky_columns)
      ELSE MOD(MOD(TO_NUMBER(FLOOR(wx)), rs.flat_size) + rs.flat_size, rs.flat_size)
    END AS u_i,
    CASE WHEN tex_name = 'F_SKY1'
      THEN MOD(MOD(y - rs.sky_horizon_y, rs.sky_rows) + rs.sky_rows, rs.sky_rows)
      ELSE MOD(MOD(TO_NUMBER(FLOOR(wy)), rs.flat_size) + rs.flat_size, rs.flat_size)
    END AS v_i
  FROM plane_tex CROSS JOIN render_settings rs
),
plane_color AS (
  SELECT
    p.x, p.y, p.depth, p.sector_id, p.plane, p.sector_light, p.is_sky,
    p.source_priority,
    CASE
      WHEN NOT p.is_sky AND ft.name IS NOT NULL
        AND (p.v_i * rs.flat_size + p.u_i) >= 0
        AND (p.v_i * rs.flat_size + p.u_i) < 4096
      THEN ASCII(SUBSTR(fc.px, MOD(p.v_i * rs.flat_size + p.u_i, 1000) + 1, 1)) - 256
      WHEN p.is_sky AND wt.name IS NOT NULL THEN
        CASE
          WHEN (p.v_i * wt.width + p.u_i) >= 0
            AND (p.v_i * wt.width + p.u_i) < wt.width * wt.height
          THEN ASCII(SUBSTR(wc.px, MOD(p.v_i * wt.width + p.u_i, 1000) + 1, 1)) - 256
          ELSE 0
        END
      ELSE 0
    END AS palette_index
  FROM plane_uv p
  CROSS JOIN render_settings rs
  LEFT JOIN flat_textures ft
    ON NOT p.is_sky AND ft.name = p.tex_name
  CROSS JOIN (SELECT m.sky_texture AS name
              FROM maps m JOIN render_context rc ON rc.map_id = m.map_id) sk
  LEFT JOIN walltex_meta wt
    ON p.is_sky AND wt.name = sk.name
  LEFT JOIN blob_chunks fc ON fc.kind = 'F' AND fc.name = ft.name
    AND fc.blk = FLOOR((p.v_i * rs.flat_size + p.u_i) / 1000)
  LEFT JOIN blob_chunks wc ON wc.kind = 'W' AND wc.name = wt.name
    AND wc.blk = FLOOR((p.v_i * wt.width + p.u_i) / 1000)
),
plane_lit AS (
  SELECT
    p.x, p.y, p.depth, p.sector_id, p.plane, p.source_priority, p.is_sky, p.palette_index,
    CASE WHEN wr.invuln THEN rs.light_index_invuln
         ELSE -- doom_light_index(sector_light, extra_light, doom_light_zdepth(depth))
           GREATEST(0, LEAST(31,
             (15 - LEAST(15, GREATEST(0, FLOOR(p.sector_light / 16) + wr.extra_light))) * 4
             - FLOOR(80 / (LEAST(127, TO_NUMBER(FLOOR(p.depth / 16d))) + 1))))
    END AS light_index
  FROM plane_color p CROSS JOIN weapon_runtime wr
  CROSS JOIN render_settings rs
),
plane_fragments AS (
  SELECT
    p.x, p.y, p.depth, p.source_priority,
    CASE WHEN p.is_sky THEN 0 ELSE p.light_index END AS light_index,
    p.palette_index,
    (p.sector_id * 2 + CASE WHEN p.plane = 'floor' THEN 0 ELSE 1 END) AS stable_id
  FROM plane_lit p
),
-- SPRITES
thing_view AS (
  SELECT
    t.id AS thing_id, t.x, t.y, t.angle,
    CASE WHEN COALESCE(d.explodes, FALSE) AND ai.state = 'die' THEN d.death_sprite
         WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead')
         THEN d.death_sprite ELSE rt.sprite END AS sprite,
    CASE WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead')
           THEN CASE WHEN h.health < -h.max_health AND d.xdeath_frame IS NOT NULL
                     THEN d.xdeath_frame ELSE d.death_frame END
         WHEN f.frame IS NOT NULL THEN f.frame
         ELSE rt.frame END AS frame,
    CASE WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead')
           THEN d.death_fullbright
         WHEN f.frame IS NOT NULL THEN f.fullbright
         ELSE rt.fullbright END AS fullbright,
    -- ::real
    TO_BINARY_DOUBLE(TO_BINARY_FLOAT(
      CASE WHEN rt.spawn_ceiling THEN TO_BINARY_DOUBLE(s.ceil_height - rt.thing_height)
           WHEN d.floats AND COALESCE(h.alive, TRUE) THEN t.z
           ELSE TO_BINARY_DOUBLE(s.floor_height) END)) AS base_z,
    s.floor_height, s.ceil_height, s.light_level AS sector_light,
    (t.x - c.px) * COS(c.view_rad)
      + (t.y - c.py) * SIN(c.view_rad) AS depth,
    (t.x - c.px) * SIN(c.view_rad)
      - (t.y - c.py) * COS(c.view_rad) AS side,
    MOD(MOD(TO_NUMBER(FLOOR((
        ATAN2(t.y - c.py, t.x - c.px) * (180d / 3.14159265358979323846d)
        - t.angle + rs.rotation_offset
      ) / rs.rotation_span)), 8) + 8, 8) + 1 AS wanted_rotation,
    COALESCE(d.fuzzy, FALSE) AS fuzz
  FROM render_things rt
  CROSS JOIN render_context rc
  CROSS JOIN render_settings rs
  JOIN things t ON t.map_id = rt.map_id AND t.id = rt.thing_id
  LEFT JOIN thing_health h ON h.map_id = rt.map_id AND h.thing_id = rt.thing_id
  LEFT JOIN thing_combat_defs d ON d.thing_type = t.type
  LEFT JOIN monster_ai ai ON ai.map_id = rt.map_id AND ai.thing_id = rt.thing_id
  LEFT JOIN thing_ai_frames f ON f.thing_type = t.type AND f.state = ai.state
    AND f.seq_index = ai.seq_index
  LEFT JOIN picked_up_items pu ON pu.map_id = rt.map_id AND pu.thing_id = rt.thing_id
  JOIN sectors_lit s ON s.map_id = rt.map_id AND s.id = COALESCE(ai.sector_id, rt.sector_id)
  CROSS JOIN cam c
  WHERE rt.map_id = rc.map_id
    AND BITAND(t.flags, rc.skill_bit) <> 0
    AND BITAND(t.flags, 16) = 0
    AND pu.thing_id IS NULL
    AND NOT (COALESCE(d.explodes, FALSE) AND ai.state = 'dead')
  UNION ALL
  SELECT
    -e.effect_id AS thing_id, e.x, e.y, 0,
    ed.sprite,
    SUBSTR(ed.frame_sequence,
           LEAST(LENGTH(ed.frame_sequence) - 1, TRUNC(e.age / ed.tics_per_frame)) + 1, 1),
    ed.fullbright, e.z,
    s.floor_height, s.ceil_height, COALESCE(s.light_level, ps.light_level),
    (e.x - c.px) * COS(c.view_rad) + (e.y - c.py) * SIN(c.view_rad),
    (e.x - c.px) * SIN(c.view_rad) - (e.y - c.py) * COS(c.view_rad),
    0, FALSE
  FROM world_effects e
  CROSS JOIN render_context rc
  CROSS JOIN cam c
  CROSS JOIN player_sector ps
  JOIN effect_sprite_defs ed ON ed.effect_type = e.effect_type
  LEFT JOIN sectors_lit s ON s.map_id = e.map_id AND s.id = e.sector_id
  WHERE e.map_id = rc.map_id
  UNION ALL
  SELECT
    ot.id, ot.x, ot.y, ot.angle,
    'PLAY', op.sprite_frame, FALSE,
    TO_BINARY_DOUBLE(s.floor_height), s.floor_height, s.ceil_height, s.light_level,
    (ot.x - c.px) * COS(c.view_rad) + (ot.y - c.py) * SIN(c.view_rad),
    (ot.x - c.px) * SIN(c.view_rad) - (ot.y - c.py) * COS(c.view_rad),
    MOD(MOD(TO_NUMBER(FLOOR((ATAN2(ot.y - c.py, ot.x - c.px) * (180d / 3.14159265358979323846d)
        - ot.angle + rs.rotation_offset) / rs.rotation_span)), 8)
        + 8, 8) + 1,
    (op.invis_tics > 0)
  FROM player_state op
  CROSS JOIN render_context rc
  CROSS JOIN render_settings rs
  JOIN things ot ON ot.map_id = op.map_id AND ot.id = op.player_thing_id
  JOIN sectors_lit s ON s.map_id = op.map_id AND s.id = op.sector_id
  CROSS JOIN cam c
  WHERE op.map_id = rc.map_id AND op.player_thing_id <> rc.player_thing_id
  UNION ALL
  SELECT
    -(1000000000000 + mp.projectile_id) AS thing_id,
    mp.x, mp.y, TO_BINARY_DOUBLE(ROUND(ATAN2(mp.vy, mp.vx) * (180d / 3.14159265358979323846d))),
    (CASE WHEN mp.state = 'fly' THEN pd.fly_sprite
          ELSE pd.impact_sprite END),
    CASE
      WHEN mp.projectile_type = 'rocket' THEN
        CASE WHEN mp.state = 'fly' THEN 'A' WHEN mp.age < 8 THEN 'B'
             WHEN mp.age < 14 THEN 'C' ELSE 'D' END
      WHEN mp.projectile_type = 'plasma' THEN
        CASE WHEN mp.state = 'fly' THEN CASE WHEN MOD(mp.age, 12) < 6 THEN 'A' ELSE 'B' END
             WHEN mp.age < 4 THEN 'A' WHEN mp.age < 8 THEN 'B'
             WHEN mp.age < 12 THEN 'C' WHEN mp.age < 16 THEN 'D' ELSE 'E' END
      WHEN mp.projectile_type = 'bfg' THEN
        CASE WHEN mp.state = 'fly' THEN CASE WHEN MOD(mp.age, 8) < 4 THEN 'A' ELSE 'B' END
             WHEN mp.age < 8 THEN 'A' WHEN mp.age < 16 THEN 'B'
             WHEN mp.age < 24 THEN 'C' WHEN mp.age < 32 THEN 'D'
             WHEN mp.age < 40 THEN 'E' ELSE 'F' END
      ELSE CASE WHEN mp.state = 'fly'
             THEN CASE WHEN MOD(mp.age, 8) < 4 THEN 'A' ELSE 'B' END
             WHEN mp.age < 5 THEN 'C' WHEN mp.age < 10 THEN 'D' ELSE 'E' END
    END,
    TRUE, mp.z,
    COALESCE(s.floor_height, ps.floor_height),
    COALESCE(s.ceil_height, ps.ceil_height),
    COALESCE(s.light_level, ps.light_level),
    (mp.x - c.px) * COS(c.view_rad) + (mp.y - c.py) * SIN(c.view_rad),
    (mp.x - c.px) * SIN(c.view_rad) - (mp.y - c.py) * COS(c.view_rad),
    CASE WHEN mp.state = 'fly' THEN
      MOD(MOD(TO_NUMBER(FLOOR((ATAN2(mp.y - c.py, mp.x - c.px) * (180d / 3.14159265358979323846d)
          - ATAN2(mp.vy, mp.vx) * (180d / 3.14159265358979323846d) + rs.rotation_offset)
          / rs.rotation_span)), 8) + 8, 8) + 1
      ELSE 0 END, FALSE
  FROM monster_projectiles mp
  CROSS JOIN render_context rc
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  CROSS JOIN player_sector ps
  JOIN projectile_defs pd ON pd.projectile_type = mp.projectile_type
  LEFT JOIN sectors_lit s ON s.map_id = mp.map_id AND s.id = mp.sector_id
  WHERE mp.map_id = rc.map_id
),
thing_projected AS (
  SELECT
    tv.*, sf.lump_name, sf.flipped, sf.width, sf.height,
    sf.left_offset, sf.top_offset,
    rs.focal / tv.depth AS scale,
    rs.cx + rs.focal * tv.side / tv.depth AS origin_x
  FROM thing_view tv
  CROSS JOIN render_settings rs
  CROSS APPLY (
    SELECT f.*
    FROM sprite_frames f
    WHERE f.sprite = tv.sprite AND f.frame = tv.frame
      AND f.rotation IN (0, tv.wanted_rotation)
    ORDER BY CASE WHEN f.rotation = tv.wanted_rotation THEN 0 ELSE 1 END
    FETCH FIRST 1 ROW ONLY
  ) sf
  JOIN sprite_lumps sl ON sl.lump_name = sf.lump_name
  WHERE tv.depth >= 4d
    AND ABS(tv.side) <= tv.depth * 2d
),
thing_bounds AS (
  SELECT
    tp.*,
    tp.origin_x - tp.scale * tp.left_offset AS x_left_f,
    tp.origin_x + tp.scale * (tp.width - tp.left_offset) AS x_right_f,
    -- base_z + top_offset (- height) is real (float4) arithmetic
    rs.cy - tp.scale * (TO_BINARY_DOUBLE(TO_BINARY_FLOAT(tp.base_z + tp.top_offset)) - c.pz) AS y_top_f,
    rs.cy - tp.scale
      * (TO_BINARY_DOUBLE(TO_BINARY_FLOAT(
           TO_BINARY_DOUBLE(TO_BINARY_FLOAT(tp.base_z + tp.top_offset)) - tp.height)) - c.pz) AS y_bottom_f
  FROM thing_projected tp
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
),
thing_bounds_lit AS (
  SELECT tb.*,
         CASE WHEN wr.invuln THEN rs.light_index_invuln
              WHEN tb.fullbright THEN 0
              ELSE -- doom_light_index(sector_light, extra_light, doom_light_scale(depth))
                GREATEST(0, LEAST(31,
                  (15 - LEAST(15, GREATEST(0, FLOOR(tb.sector_light / 16) + wr.extra_light))) * 4
                  - CASE WHEN tb.depth = 0 THEN 0
                         ELSE TO_NUMBER(FLOOR(LEAST(47d, GREATEST(0d, 2560d / tb.depth)) / 2d)) END))
         END AS base_light
  FROM thing_bounds tb
  CROSS JOIN weapon_runtime wr CROSS JOIN render_settings rs
),
thing_pixels AS (
  SELECT
    tb.thing_id, gx.n AS x, gy.n AS y,
    tb.depth, tb.sector_light, tb.fullbright, tb.fuzz, tb.base_light,
    CASE WHEN mpl.slot > 1 AND px.raw_pi BETWEEN 112 AND 127
         THEN px.raw_pi - 112 + CASE mpl.slot WHEN 2 THEN 96 WHEN 3 THEN 64 ELSE 32 END
         ELSE px.raw_pi END AS palette_index
  FROM thing_bounds_lit tb
  CROSS JOIN render_settings rs
  CROSS JOIN render_context rc
  LEFT JOIN mp_players mpl ON mpl.map_id = rc.map_id AND mpl.player_thing_id = tb.thing_id
  JOIN nums gx ON gx.n BETWEEN GREATEST(0, TO_NUMBER(FLOOR(tb.x_left_f)))
                           AND LEAST(rs.screen_w - 1, TO_NUMBER(CEIL(tb.x_right_f)) - 1)
  JOIN nums gy ON gy.n BETWEEN GREATEST(0, TO_NUMBER(FLOOR(tb.y_top_f)))
                           AND LEAST(rs.screen_h - 1, TO_NUMBER(CEIL(tb.y_bottom_f)) - 1)
  CROSS APPLY (
    SELECT
      LEAST(tb.width - 1, GREATEST(0,
        TO_NUMBER(FLOOR((gx.n - tb.x_left_f) / tb.scale))
      )) AS raw_u,
      LEAST(tb.height - 1, GREATEST(0,
        TO_NUMBER(FLOOR((gy.n - tb.y_top_f) / tb.scale))
      )) AS v_i
    FROM dual
  ) uv
  CROSS APPLY (
    SELECT uv.v_i * tb.width
             + CASE WHEN tb.flipped THEN tb.width - 1 - uv.raw_u
                    ELSE uv.raw_u END AS off
    FROM dual
  ) o
  JOIN blob_chunks pc ON pc.kind = 'P' AND pc.name = tb.lump_name AND pc.blk = FLOOR(o.off / 1000)
  JOIN blob_chunks mc ON mc.kind = 'M' AND mc.name = tb.lump_name AND mc.blk = FLOOR(o.off / 1000)
  CROSS APPLY (
    SELECT ASCII(SUBSTR(pc.px, MOD(o.off, 1000) + 1, 1)) - 256 AS raw_pi,
           ASCII(SUBSTR(mc.px, MOD(o.off, 1000) + 1, 1)) - 256 AS mask
    FROM dual
  ) px
  WHERE tb.x_right_f > 0 AND tb.x_left_f < rs.screen_w
    AND tb.y_bottom_f > 0 AND tb.y_top_f < rs.screen_h
    AND px.mask <> 0
),
sprite_fragments AS (
  SELECT
    sp.x, sp.y, sp.depth, sp.thing_id AS stable_id, sp.palette_index,
    CASE WHEN sp.fuzz THEN
      26 + MOD(sp.x * 7 + sp.y * 13 + TO_NUMBER(ROUND(sp.depth)), 5)
    ELSE sp.base_light
    END AS light_index
  FROM thing_pixels sp
),
fragment_union AS (
  SELECT x, y, depth, light_index, palette_index,
         2 AS surface_priority, 0 AS source_priority, stable_id
  FROM colored
  UNION ALL
  SELECT x, y, depth, light_index, palette_index,
         1, 0, stable_id
  FROM sprite_fragments
  UNION ALL
  SELECT x, y, depth, light_index, palette_index,
         0, source_priority, stable_id
  FROM plane_fragments
),
ranked_fragments AS (
  -- bigint key: shifts as multiplications by powers of two, the fields never
  -- overlap so | is +.
  SELECT u.y * rs.screen_w + u.x AS pix,
         TO_NUMBER(ROUND(GREATEST(0d, LEAST(u.depth, 131071d)) * 4096d)) * 17179869184   -- << 34
         + (2 - u.surface_priority) * 4294967296                                         -- << 32
         + LEAST(u.source_priority, 3) * 1073741824                                      -- << 30
         + LEAST(65535, GREATEST(0, u.stable_id + 32768)) * 16384                        -- << 14
         + u.light_index * 256                                                           -- << 8
         + u.palette_index AS winner_key
  FROM fragment_union u CROSS JOIN render_settings rs
),
resolved AS (
  SELECT MOD(w.pix, rs.screen_w) AS x, TRUNC(w.pix / rs.screen_w) AS y,
         MOD(TRUNC(w.winner_key / 256), 64) AS light_index,
         MOD(w.winner_key, 256) AS palette_index
  FROM (SELECT pix, MIN(winner_key) AS winner_key
        FROM ranked_fragments GROUP BY pix) w
  CROSS JOIN render_settings rs
),
-- psprites
psprite_layers AS (
  SELECT 1 AS layer, wr.sprite, wr.frame AS frame,
         wr.sx AS sx, wr.sy AS sy,
         COALESCE(wr.fullbright, FALSE) AS fullbright
  FROM weapon_runtime wr
  UNION ALL
  SELECT 2, wr.flash_sprite, wr.flash_frame AS frame,
         wr.sx, wr.sy, COALESCE(wr.flash_fullbright, TRUE)
  FROM weapon_runtime wr
  WHERE wr.flash_sprite IS NOT NULL AND wr.flash_frame IS NOT NULL
),
psprite_patches AS (
  SELECT p.*, sf.width, sf.height, sf.left_offset, sf.top_offset, sf.lump_name,
         p.sx - sf.left_offset AS x_left_f,
         p.sy - sf.top_offset + rs.cy - 100 - 0.5d AS y_top_f
  FROM psprite_layers p
  CROSS JOIN render_settings rs
  JOIN sprite_frames sf ON sf.sprite = p.sprite AND sf.frame = p.frame
    AND sf.rotation = 0
  JOIN sprite_lumps sl ON sl.lump_name = sf.lump_name
),
psprite_pixels AS (
  SELECT q.layer, gx.n AS x, gy.n AS y, q.fullbright,
         ASCII(SUBSTR(pc.px, MOD(o.off, 1000) + 1, 1)) - 256 AS palette_index
  FROM psprite_patches q
  CROSS JOIN render_settings rs
  JOIN nums gx ON gx.n BETWEEN GREATEST(0, TO_NUMBER(FLOOR(q.x_left_f)))
                           AND LEAST(rs.screen_w - 1, TO_NUMBER(FLOOR(q.x_left_f)) + q.width - 1)
  JOIN nums gy ON gy.n BETWEEN GREATEST(0, TO_NUMBER(FLOOR(q.y_top_f)))
                           AND LEAST(rs.screen_h - 1, TO_NUMBER(FLOOR(q.y_top_f)) + q.height - 1)
  CROSS APPLY (
    SELECT (gy.n - TO_NUMBER(FLOOR(q.y_top_f))) * q.width
           + (gx.n - TO_NUMBER(FLOOR(q.x_left_f))) AS off
    FROM dual
  ) o
  JOIN blob_chunks pc ON pc.kind = 'P' AND pc.name = q.lump_name AND pc.blk = FLOOR(o.off / 1000)
  JOIN blob_chunks mc ON mc.kind = 'M' AND mc.name = q.lump_name AND mc.blk = FLOOR(o.off / 1000)
  WHERE ASCII(SUBSTR(mc.px, MOD(o.off, 1000) + 1, 1)) - 256 <> 0
),
psprite_resolved AS (
  SELECT p.x, p.y, p.palette_index,
    CASE WHEN wr.invuln THEN rs.light_index_invuln
         WHEN p.fullbright THEN 0
         ELSE -- doom_light_index(ps.light_level, extra_light, light_psprite_bias)
           GREATEST(0, LEAST(31,
             (15 - LEAST(15, GREATEST(0, FLOOR(ps.light_level / 16) + wr.extra_light))) * 4
             - rs.light_psprite_bias))
    END AS light_index
  FROM (
    SELECT pp.*, ROW_NUMBER() OVER (
      PARTITION BY pp.x, pp.y ORDER BY pp.layer DESC) AS rn
    FROM psprite_pixels pp
  ) p
  CROSS JOIN player_sector ps CROSS JOIN weapon_runtime wr
  CROSS JOIN render_settings rs
  WHERE p.rn = 1
),
final_pixels AS (
  SELECT COALESCE(p.x, r.x) AS x, COALESCE(p.y, r.y) AS y,
         COALESCE(p.light_index, r.light_index) AS light_index,
         COALESCE(p.palette_index, r.palette_index) AS palette_index
  FROM resolved r FULL JOIN psprite_resolved p ON p.x = r.x AND p.y = r.y
),
-- STATUS BAR
player_ui_state AS (
  SELECT ps.health, ps.alive, ps.pain_face_tics, ps.armor,
         ps.ammo_bullets, ps.ammo_shells, ps.ammo_rockets, ps.ammo_cells,
         ps.key_blue, ps.key_yellow, ps.key_red,
         ps.damage_count, ps.bonus_count, ps.radsuit_tics,
         ps.message, ps.message_tics, ps.backpack,
         wd.ammo_type AS current_ammo_type
  FROM player_state ps
  CROSS JOIN render_context rc
  LEFT JOIN player_weapons w ON w.map_id = ps.map_id
    AND w.player_thing_id = ps.player_thing_id
  LEFT JOIN weapon_defs wd ON wd.weapon_id = COALESCE(w.current_weapon, 2)
  WHERE ps.map_id = rc.map_id AND ps.player_thing_id = rc.player_thing_id
),
active_palette AS (
  SELECT CASE
    WHEN pu.damage_count > 0
      THEN LEAST(7, TRUNC((pu.damage_count + 7) / 8)) + 1
    WHEN pu.bonus_count > 0
      THEN LEAST(3, TRUNC((pu.bonus_count + 7) / 8)) + 9
    WHEN pu.radsuit_tics > 128 OR BITAND(pu.radsuit_tics, 8) <> 0
      THEN 13
    ELSE 0
  END AS pal
  FROM player_ui_state pu
),
palette_map AS (
  -- index-emitting form: mapped_index (PLAYPAL index after COLORMAP) instead of rgb
  SELECT cm.light_level AS "LEVEL", cm.palette_index, cm.mapped_index
  FROM colormap_rgb cm
  CROSS JOIN active_palette ap
  WHERE cm.pal = ap.pal
),
weapon_ownership AS (
  SELECT slot.n AS weapon_id,
         EXISTS (
           SELECT 1 FROM player_weapon_owned o CROSS JOIN render_context rc
           WHERE o.map_id = rc.map_id AND o.player_thing_id = rc.player_thing_id
             AND o.weapon_id = slot.n
         ) AS owned
  FROM nums slot WHERE slot.n BETWEEN 2 AND 7
),
weapon_layers AS (
  SELECT 2 AS layer,
         (CASE WHEN owned THEN 'STYSNUM' ELSE 'STGNUM' END)
           || TO_CHAR(weapon_id) AS patch,
         111 + MOD(weapon_id - 2, 3) * 12 AS x,
         172 + TRUNC((weapon_id - 2) / 3) * 10 AS y
  FROM weapon_ownership
),
ui_face AS (
  SELECT
    CASE
      WHEN NOT pu.alive THEN 'STFDEAD0'
      WHEN pu.pain_face_tics > 0 THEN
        'STFOUCH' || TO_CHAR(LEAST(4, GREATEST(0, TRUNC((100 - GREATEST(0, LEAST(100, pu.health))) / 20))))
      ELSE
        'STFST' || TO_CHAR(LEAST(4, GREATEST(0, TRUNC((100 - GREATEST(0, LEAST(100, pu.health))) / 20)))) || '0'
    END AS face_patch
  FROM player_ui_state pu
),
status_bar AS (
  SELECT
    rs.screen_h     AS top_y,
    rs.screen_h + 4 AS digit_y,
    90  AS health_right_x,
    221 AS armor_right_x,
    44  AS ammo_right_x,
    288 AS ammo_box_right_x,
    314 AS max_ammo_right_x,
    239 AS key_x,
    143 AS face_x,
    14  AS tall_digit_w,
    4   AS short_digit_w
  FROM render_settings rs
),
health_digits AS (SELECT pu.health AS value, sb.health_right_x AS right_x
                  FROM player_ui_state pu CROSS JOIN status_bar sb),
armor_digits AS (SELECT pu.armor AS value, sb.armor_right_x AS right_x
                 FROM player_ui_state pu CROSS JOIN status_bar sb),
ammo_digits AS (
  SELECT
    CASE pu.current_ammo_type
      WHEN 'bullets' THEN pu.ammo_bullets WHEN 'shells' THEN pu.ammo_shells
      WHEN 'rockets' THEN pu.ammo_rockets WHEN 'cells' THEN pu.ammo_cells
    END AS value,
    sb.ammo_right_x AS right_x
  FROM player_ui_state pu CROSS JOIN status_bar sb
  WHERE pu.current_ammo_type IS NOT NULL
),
ammo_type_values AS (
  SELECT pu.ammo_bullets AS value, sb.ammo_box_right_x AS right_x, 173 AS y
  FROM player_ui_state pu CROSS JOIN status_bar sb
  UNION ALL
  SELECT pu.ammo_shells, sb.ammo_box_right_x, 179
  FROM player_ui_state pu CROSS JOIN status_bar sb
  UNION ALL
  SELECT pu.ammo_rockets, sb.ammo_box_right_x, 185
  FROM player_ui_state pu CROSS JOIN status_bar sb
  UNION ALL
  SELECT pu.ammo_cells, sb.ammo_box_right_x, 191
  FROM player_ui_state pu CROSS JOIN status_bar sb
),
ammo_max_values AS (
  SELECT (CASE WHEN pu.backpack THEN ad.backpack_cap ELSE ad.cap END) AS value,
         sb.max_ammo_right_x AS right_x,
         (CASE ad.ammo_type WHEN 'bullets' THEN 173 WHEN 'shells' THEN 179
                            WHEN 'rockets' THEN 185 ELSE 191 END) AS y
  FROM player_ui_state pu CROSS JOIN status_bar sb
  CROSS JOIN ammo_defs ad
),
key_layers AS (
  SELECT 1 AS layer, 'STKEYS0' AS patch, sb.key_x AS x, 171 AS y
  FROM player_ui_state pu CROSS JOIN status_bar sb WHERE pu.key_blue
  UNION ALL SELECT 1, 'STKEYS1', sb.key_x, 181
  FROM player_ui_state pu CROSS JOIN status_bar sb WHERE pu.key_yellow
  UNION ALL SELECT 1, 'STKEYS2', sb.key_x, 191
  FROM player_ui_state pu CROSS JOIN status_bar sb WHERE pu.key_red
),
digit_layers AS (
  SELECT 1 AS layer,
    'STTNUM' || SUBSTR(TO_CHAR(hd.value), gs.n, 1) AS patch,
    hd.right_x - (LENGTH(TO_CHAR(hd.value)) - gs.n + 1) * sb.tall_digit_w AS x,
    sb.digit_y AS y
  FROM health_digits hd CROSS JOIN status_bar sb
  JOIN nums gs ON gs.n BETWEEN 1 AND LENGTH(TO_CHAR(hd.value))
  UNION ALL
  SELECT 1, 'STTNUM' || SUBSTR(TO_CHAR(ad.value), gs.n, 1) AS patch,
    ad.right_x - (LENGTH(TO_CHAR(ad.value)) - gs.n + 1) * sb.tall_digit_w AS x,
    sb.digit_y AS y
  FROM armor_digits ad CROSS JOIN status_bar sb
  JOIN nums gs ON gs.n BETWEEN 1 AND LENGTH(TO_CHAR(ad.value))
  UNION ALL
  SELECT 1, 'STTNUM' || SUBSTR(TO_CHAR(am.value), gs.n, 1) AS patch,
    am.right_x - (LENGTH(TO_CHAR(am.value)) - gs.n + 1) * sb.tall_digit_w AS x,
    sb.digit_y AS y
  FROM ammo_digits am CROSS JOIN status_bar sb
  JOIN nums gs ON gs.n BETWEEN 1 AND LENGTH(TO_CHAR(am.value))
  UNION ALL
  SELECT 1, 'STYSNUM' || SUBSTR(TO_CHAR(at.value), gs.n, 1) AS patch,
    at.right_x - (LENGTH(TO_CHAR(at.value)) - gs.n + 1) * sb.short_digit_w AS x,
    at.y
  FROM ammo_type_values at CROSS JOIN status_bar sb
  JOIN nums gs ON gs.n BETWEEN 1 AND LENGTH(TO_CHAR(at.value))
  UNION ALL
  SELECT 1, 'STYSNUM' || SUBSTR(TO_CHAR(mx.value), gs.n, 1) AS patch,
    mx.right_x - (LENGTH(TO_CHAR(mx.value)) - gs.n + 1) * sb.short_digit_w AS x,
    mx.y
  FROM ammo_max_values mx CROSS JOIN status_bar sb
  JOIN nums gs ON gs.n BETWEEN 1 AND LENGTH(TO_CHAR(mx.value))
),
ui_layers AS (
  SELECT layer, patch, x, y FROM digit_layers
  UNION ALL SELECT layer, patch, x, y FROM key_layers
  UNION ALL SELECT layer, patch, x, y FROM weapon_layers
  UNION ALL SELECT 1, face_patch, sb.face_x, sb.top_y
  FROM ui_face CROSS JOIN status_bar sb
),
ui_layer_patches AS (
  SELECT l.layer, l.patch, l.x - p.left_offset AS dest_x,
         l.y - p.top_offset AS dest_y
  FROM ui_layers l
  JOIN ui_patches p ON p.name = l.patch
),
ui_pixels AS (
  SELECT ulp.layer, ulp.dest_x + px.dx AS x, ulp.dest_y + px.dy AS y,
         px.palette_index
  FROM ui_layer_patches ulp
  JOIN ui_hud_pixels px ON px.name = ulp.patch
),
ui_resolved AS (
  SELECT x, y, MAX(palette_index) KEEP (DENSE_RANK LAST ORDER BY layer) AS palette_index
  FROM ui_pixels GROUP BY x, y
),
ui_colored AS (
  -- index form of the reference: s.rgb = COLORMAP[0][s.palette_index] (pal 0)
  SELECT s.x, s.y,
         COALESCE(ovcm.mapped_index,
                  CASE WHEN ap.pal = 0 THEN s0.mapped_index ELSE barcm.mapped_index END,
                  s0.mapped_index) AS idx
  FROM ui_static_pixels s
  CROSS JOIN active_palette ap
  JOIN colormap_rgb s0 ON s0.pal = 0 AND s0.light_level = 0
   AND s0.palette_index = s.palette_index
  LEFT JOIN ui_resolved ur ON ur.x = s.x AND ur.y = s.y
  LEFT JOIN palette_map ovcm
    ON ovcm."LEVEL" = 0 AND ovcm.palette_index = ur.palette_index
  LEFT JOIN palette_map barcm
    ON ap.pal <> 0 AND barcm."LEVEL" = 0
   AND barcm.palette_index = s.palette_index
),
view_colored AS (
  SELECT r.x, r.y, COALESCE(cm.mapped_index, 0) AS idx
  FROM final_pixels r
  LEFT JOIN palette_map cm
    ON cm."LEVEL" = r.light_index
   AND cm.palette_index = r.palette_index
),
view_holes AS (
  SELECT sx.n AS x, sy.n AS y, 0 AS idx
  FROM render_settings rs
  JOIN nums sx ON sx.n BETWEEN 0 AND rs.screen_w - 1
  JOIN nums sy ON sy.n BETWEEN 0 AND rs.screen_h - 1
  WHERE NOT EXISTS (
    SELECT 1 FROM final_pixels f WHERE f.x = sx.n AND f.y = sy.n
  )
),
message_glyphs AS (
  SELECT gs.n AS pos,
         SUBSTR(UPPER(pu.message), gs.n, 1) AS ch
  FROM player_ui_state pu
  JOIN nums gs ON gs.n BETWEEN 1 AND LENGTH(pu.message)
  WHERE pu.message IS NOT NULL AND pu.message_tics > 0
),
message_placed AS (
  SELECT g.pos, g.ch,
         CASE WHEN g.ch = ' ' THEN NULL
              ELSE 'STCFN' || LPAD(TO_CHAR(ASCII(g.ch)), 3, '0') END AS patch,
         SUM(CASE WHEN g.ch = ' ' THEN 4
                  ELSE COALESCE(gp.width, 4)
             END) OVER (ORDER BY g.pos ROWS BETWEEN UNBOUNDED PRECEDING
                                             AND 1 PRECEDING) AS pen
  FROM message_glyphs g
  LEFT JOIN ui_patches gp ON gp.name = 'STCFN' || LPAD(TO_CHAR(ASCII(g.ch)), 3, '0')
),
message_pixels AS (
  SELECT COALESCE(mp.pen, 0) + px.dx AS x, 1 + px.dy AS y,
         px.palette_index
  FROM message_placed mp
  JOIN ui_hud_pixels px ON px.name = mp.patch
  WHERE mp.patch IS NOT NULL
),
message_colored AS (
  SELECT m.x, m.y, cm.mapped_index AS idx
  FROM message_pixels m
  CROSS JOIN render_context rc
  JOIN palette_map cm ON cm."LEVEL" = 0 AND cm.palette_index = m.palette_index
  WHERE m.x BETWEEN 0 AND 319 AND m.y BETWEEN 0 AND 167
),
framebuffer AS (
  SELECT v.x, v.y, COALESCE(m.idx, v.idx) AS idx
  FROM view_colored v
  LEFT JOIN message_colored m ON m.x = v.x AND m.y = v.y
  UNION ALL
  SELECT h.x, h.y, COALESCE(m.idx, h.idx) AS idx
  FROM view_holes h
  LEFT JOIN message_colored m ON m.x = h.x AND m.y = h.y
  UNION ALL
  SELECT x, y, idx FROM ui_colored
)
-- @final
SELECT f.y, (SELECT MAX(pal) FROM active_palette) AS pal,
       LISTAGG(TO_CHAR(f.idx, 'FM0X'), '') WITHIN GROUP (ORDER BY f.x) AS hex
FROM framebuffer f
GROUP BY f.y
ORDER BY f.y
