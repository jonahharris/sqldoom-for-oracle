-- @output packed
WITH
-- ============================================================================================
-- FRAME CONSTANTS AND STATE  (one row each; every per-row expression reuses them)
-- ============================================================================================
rs AS (
  SELECT /*+ MATERIALIZE */ 320 AS screen_w, 168 AS screen_h, 160d AS cx, 84d AS cy,
         160d / TAN(90d * (3.14159265358979323846d / 180d) / 2d) AS focal,
         TAN(90d * (3.14159265358979323846d / 180d) / 2d) AS tan_half_fov,
         1d / 1000d AS near,
         16d * (160d / TAN(90d * (3.14159265358979323846d / 180d) / 2d)) AS max_plane_depth
  FROM dual
),
pose_in AS (
    SELECT 1 AS i, :px AS x FROM dual UNION ALL
    SELECT 2, :py FROM dual UNION ALL
    SELECT 3, :pz FROM dual UNION ALL
    SELECT 4, :pangle FROM dual
),
pose_conv AS (
    -- CedarDB numeric-literal -> float8 (see render_baseline.sql pose_conv): the client binds the
    -- pose as NUMBER = Python repr, so scale = its decimal places; float8(mantissa) / 10^scale
    -- with mantissa rounded to 53 bits (ties to even) in exact NUMBER math.
    SELECT q.i,
           CASE WHEN q.x = 0 THEN 0d
                WHEN ABS(q.x) < 1e-4 OR ABS(q.x) >= 1e16 THEN TO_BINARY_DOUBLE(q.x)
                ELSE TO_BINARY_DOUBLE(
                       CASE WHEN ABS(q.m / q.ulp - TRUNC(q.m / q.ulp)) = 0.5
                            THEN 2 * ROUND(q.m / q.ulp / 2) ELSE ROUND(q.m / q.ulp) END * q.ulp)
                     / TO_BINARY_DOUBLE(q.p10) END AS v
    FROM (SELECT k.i, k.x, k.x * k.p10 AS m, k.p10,
                 CASE WHEN ABS(k.x * k.p10) < 9007199254740992 THEN 1
                      WHEN ABS(k.x * k.p10) < 18014398509481984 THEN 2
                      WHEN ABS(k.x * k.p10) < 36028797018963968 THEN 4
                      WHEN ABS(k.x * k.p10) < 72057594037927936 THEN 8 ELSE 16 END AS ulp
          FROM (SELECT d.i, d.x, POWER(10, CASE WHEN INSTR(d.s, '.') = 0 THEN 0 ELSE LENGTH(d.s) - INSTR(d.s, '.') END) AS p10
                FROM (SELECT i, x, TO_CHAR(ABS(x), 'TM9') AS s FROM pose_in) d) k) q
),
cam AS (
  -- pose as CedarDB sees it (pose_conv), then the view trig once per frame
  SELECT /*+ MATERIALIZE */ p.px, p.py, p.pz, p.pa * (3.14159265358979323846d / 180d) AS vr,
         COS(-(p.pa * (3.14159265358979323846d / 180d))) AS cs,   -- cos(-view_rad)
         SIN(-(p.pa * (3.14159265358979323846d / 180d))) AS sn,   -- sin(-view_rad)
         COS(p.pa * (3.14159265358979323846d / 180d)) AS cv,      -- cos(view_rad)
         SIN(p.pa * (3.14159265358979323846d / 180d)) AS sv,      -- sin(view_rad)
         CASE WHEN :skill <= 1 THEN 1 WHEN :skill = 2 THEN 2 ELSE 4 END AS skill_bit
  FROM (SELECT MAX(CASE i WHEN 1 THEN v END) AS px, MAX(CASE i WHEN 2 THEN v END) AS py,
               MAX(CASE i WHEN 3 THEN v END) AS pz, MAX(CASE i WHEN 4 THEN v END) AS pa
        FROM pose_conv) p
),
fclock AS (
  SELECT NVL(MAX(level_tics), 0) AS t FROM st_player_state
  WHERE tic = :tic AND map_id = :map_id AND player_thing_id = :player_id
),
alight AS (
  -- sector light thinkers as pure functions of the tic count (reference animated_light)
  SELECT k.sector_id, LEAST(255, GREATEST(0,
    CASE k.special
      WHEN 2  THEN CASE WHEN MOD(k.t + k.phase, 20) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 13 THEN CASE WHEN MOD(k.t, 20) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 3  THEN CASE WHEN MOD(k.t + k.phase, 40) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 12 THEN CASE WHEN MOD(k.t, 40) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 1  THEN CASE WHEN MOD(k.sector_id * 2654435761 + TRUNC(k.t / 4), 8) < 2 THEN k.dark_light ELSE k.base_light END
      WHEN 17 THEN GREATEST(k.dark_light, k.base_light
                   - MOD(MOD(MOD(TRUNC(k.t / 3), 1000) * MOD(TRUNC(k.t / 3), 1000) * 1103515245 + k.sector_id * 40503, 1009), 4)
                     * GREATEST(1, TRUNC((k.base_light - k.dark_light) / 4)))
      WHEN 8  THEN k.dark_light + 8 * CASE WHEN MOD(k.t + k.phase, 2 * k.glow_steps) < k.glow_steps
                                          THEN MOD(k.t + k.phase, 2 * k.glow_steps)
                                          ELSE 2 * k.glow_steps - MOD(k.t + k.phase, 2 * k.glow_steps) END
      ELSE k.base_light END)) AS light_level
  FROM (SELECT f.sector_id, f.base_light, f.dark_light, f.special, MOD(f.sector_id * 7919, 64) AS phase,
               GREATEST(1, TRUNC((f.base_light - f.dark_light) / 8)) AS glow_steps, fc.t
        FROM st_sector_light_fx f CROSS JOIN fclock fc WHERE f.tic = :tic AND f.map_id = :map_id) k
),
secl AS (
  SELECT /*+ MATERIALIZE */ s.id, s.floor_height, s.ceil_height, s.floor_tex, s.ceil_tex,
         NVL(a.light_level, s.light_level) AS light_level
  FROM st_sectors s LEFT JOIN alight a ON a.sector_id = s.id
  WHERE s.tic = :tic AND s.map_id = :map_id
),
wr AS (
  -- weapon runtime: psprite frames, extralight, invulnerability colormap
  SELECT /*+ MATERIALIZE */ NVL(w.sx, 1d) AS sx, NVL(w.sy, 32d) AS sy,
         CASE WHEN NVL(ps2.light_amp_tics, 0) > 0 THEN 16 ELSE NVL(w.flash_seq_index, -1) + 1 END AS extra_light,
         CASE WHEN NVL(ps2.invuln_tics, 0) > 0 THEN 1 ELSE 0 END AS invuln,
         wd.sprite, wd.flash_sprite,
         CASE WHEN NVL(w.state, 'ready') IN ('up', 'down') THEN rf.frame ELSE mf.frame END AS frame,
         CASE WHEN NVL(w.state, 'ready') IN ('up', 'down') THEN rf.fullbright ELSE mf.fullbright END AS fullbright,
         ff.frame AS flash_frame, ff.fullbright AS flash_fullbright
  FROM dual
  LEFT JOIN st_player_weapons w ON w.tic = :tic AND w.map_id = :map_id AND w.player_thing_id = :player_id
  LEFT JOIN st_player_state ps2 ON ps2.tic = :tic AND ps2.map_id = :map_id AND ps2.player_thing_id = :player_id
  JOIN weapon_defs wd ON wd.weapon_id = NVL(w.current_weapon, 2)
  LEFT JOIN weapon_frames rf ON rf.weapon_id = wd.weapon_id AND rf.state = 'ready' AND rf.seq_index = 0
  LEFT JOIN weapon_frames mf ON mf.weapon_id = wd.weapon_id AND mf.state = NVL(w.state, 'ready')
                            AND mf.seq_index = NVL(w.seq_index, 0)
  LEFT JOIN weapon_frames ff ON ff.weapon_id = wd.weapon_id AND ff.state = 'flash' AND ff.seq_index = w.flash_seq_index
),
-- ============================================================================================
-- BSP: support-function frustum test per child box, front side per node, and the
-- front-to-back rank as an order statistic over precomputed root-to-leaf steps (H2).
-- ============================================================================================
vchild AS (
  SELECT /*+ MATERIALIZE */ nc.node_id, nc.side,
    CASE WHEN (c.px BETWEEN nc.bbox_left AND nc.bbox_right AND c.py BETWEEN nc.bbox_bottom AND nc.bbox_top)
      OR (
        ((c.sn - r.tan_half_fov * c.cs) * CASE WHEN (c.sn - r.tan_half_fov * c.cs) >= 0 THEN nc.bbox_left ELSE nc.bbox_right END
         + (c.cs + r.tan_half_fov * c.sn) * CASE WHEN (c.cs + r.tan_half_fov * c.sn) >= 0 THEN nc.bbox_bottom ELSE nc.bbox_top END
         + (-c.px * c.sn - c.py * c.cs + r.tan_half_fov * (c.px * c.cs - c.py * c.sn))) <= 0.5d
        AND
        ((-c.sn - r.tan_half_fov * c.cs) * CASE WHEN (-c.sn - r.tan_half_fov * c.cs) >= 0 THEN nc.bbox_left ELSE nc.bbox_right END
         + (-c.cs + r.tan_half_fov * c.sn) * CASE WHEN (-c.cs + r.tan_half_fov * c.sn) >= 0 THEN nc.bbox_bottom ELSE nc.bbox_top END
         + (c.px * c.sn + c.py * c.cs + r.tan_half_fov * (c.px * c.cs - c.py * c.sn))) <= 0.5d
        AND
        ((-c.cs) * CASE WHEN (-c.cs) >= 0 THEN nc.bbox_left ELSE nc.bbox_right END
         + c.sn * CASE WHEN c.sn >= 0 THEN nc.bbox_bottom ELSE nc.bbox_top END
         + (r.near + c.px * c.cs - c.py * c.sn)) <= 0.5d)
    THEN 1 ELSE 0 END AS keep
  FROM node_children nc CROSS JOIN cam c CROSS JOIN rs r
  WHERE nc.map_id = :map_id
),
nfront AS (
  SELECT /*+ MATERIALIZE */ n.id AS node_id,
         CASE WHEN ROUND(c.px - n.x) * n.dy - ROUND(c.py - n.y) * n.dx > 0 THEN 'R' ELSE 'L' END AS front
  FROM nodes n CROSS JOIN cam c WHERE n.map_id = :map_id
),
bsp AS (
  SELECT /*+ MATERIALIZE */ st.ssector_id,
         1 + SUM(CASE WHEN st.side <> nf.front THEN st.sib_leaves ELSE 0 END) AS bsp_seq
  FROM bsp_steps st
  JOIN nfront nf ON nf.node_id = st.node_id
  JOIN vchild vc ON vc.node_id = st.node_id AND vc.side = st.side
  WHERE st.map_id = :map_id
  GROUP BY st.ssector_id
  HAVING MIN(vc.keep) = 1
),
player_sector AS (
  SELECT /*+ MATERIALIZE */ s.id, s.floor_height, s.ceil_height, s.ceil_tex, s.light_level
  FROM (SELECT MIN(sg.fsec) KEEP (DENSE_RANK FIRST ORDER BY b.bsp_seq, sg.seg_id) AS fsec
        FROM bsp b JOIN render_segs sg ON sg.map_id = :map_id AND sg.ssector_id = b.ssector_id) f
  JOIN secl s ON s.id = f.fsec
),
-- ============================================================================================
-- SEGS: back-face cull, camera transform, near-plane clip in camera space, projection
-- ============================================================================================
segv AS (
  SELECT s.seg_id, b.bsp_seq,
         (s.x1 - c.px) * c.cs - (s.y1 - c.py) * c.sn AS xa,
         -((s.x1 - c.px) * c.sn + (s.y1 - c.py) * c.cs) AS ya,
         (s.x2 - c.px) * c.cs - (s.y2 - c.py) * c.sn AS xb,
         -((s.x2 - c.px) * c.sn + (s.y2 - c.py) * c.cs) AS yb
  FROM render_segs_ext s
  JOIN bsp b ON b.ssector_id = s.ssector_id
  CROSS JOIN cam c
  WHERE s.map_id = :map_id
    AND (s.x2 - s.x1) * ROUND(c.py - s.y1) - (s.y2 - s.y1) * ROUND(c.px - s.x1) < 0
),
segp AS (
  SELECT q.seg_id, q.bsp_seq,
         r.cx + r.focal * (q.cy1 / q.cx1) AS sx1, r.cx + r.focal * (q.cy2 / q.cx2) AS sx2,
         1d / q.cx1 AS invx1, 1d / q.cx2 AS invx2
  FROM (SELECT v.seg_id, v.bsp_seq,
               CASE WHEN v.xa < r.near THEN r.near ELSE v.xa END AS cx1,
               CASE WHEN v.xa < r.near THEN v.ya + (r.near - v.xa) * (v.yb - v.ya) / (v.xb - v.xa) ELSE v.ya END AS cy1,
               CASE WHEN v.xb < r.near THEN r.near ELSE v.xb END AS cx2,
               CASE WHEN v.xb < r.near THEN v.yb + (r.near - v.xb) * (v.ya - v.yb) / (v.xa - v.xb) ELSE v.yb END AS cy2
        FROM segv v CROSS JOIN rs r
        WHERE v.xa > 0 OR v.xb > 0) q
  CROSS JOIN rs r
),
segh AS (
  -- on-screen segs with their CURRENT front/back sector state (doors, lifts, lights)
  SELECT /*+ MATERIALIZE */ p.seg_id, p.bsp_seq, p.sx1, p.sx2, p.invx1, p.invx2,
         s.fsec, s.bsec, s.y_offset, s.light_bias, s.seg_u1, s.seg_u2, s.peg_bottom, s.peg_top,
         s.x_offset + CASE WHEN s.scrolls = 1 THEN fc.t ELSE 0 END AS x_offset,
         NVL(o.upper_tex, s.upper_tex) AS upper_tex, NVL(o.mid_tex, s.mid_tex) AS mid_tex,
         NVL(o.lower_tex, s.lower_tex) AS lower_tex,
         f.floor_height AS f_floor, f.ceil_height AS f_ceil, f.ceil_tex AS f_ceil_tex, f.light_level AS f_light,
         b.floor_height AS b_floor, b.ceil_height AS b_ceil, b.ceil_tex AS b_ceil_tex,
         CASE WHEN NVL(f.ceil_tex, '~') = 'F_SKY1' AND NVL(b.ceil_tex, '~') = 'F_SKY1' THEN 1 ELSE 0 END AS both_sky
  FROM segp p
  JOIN render_segs_ext s ON s.map_id = :map_id AND s.seg_id = p.seg_id
  JOIN secl f ON f.id = s.fsec
  LEFT JOIN secl b ON b.id = s.bsec
  LEFT JOIN st_render_seg_tex o ON o.tic = :tic AND o.map_id = :map_id AND o.seg_id = s.seg_id
  CROSS JOIN fclock fc
  WHERE GREATEST(p.sx1, p.sx2) >= 0 AND LEAST(p.sx1, p.sx2) < 320
),
-- ============================================================================================
-- WALL PARTS (reference unpivot: drawable parts + clip-only boundaries) and solid occlusion
-- ============================================================================================
wparts AS (
  SELECT /*+ MATERIALIZE */ h.seg_id, h.bsp_seq, h.sx1, h.sx2, h.invx1, h.invx2, h.fsec, h.y_offset, h.light_bias,
         h.seg_u1, h.seg_u2, h.x_offset, h.f_floor, h.f_ceil, h.f_ceil_tex, h.f_light,
         k.part, k.pcode,
         CASE k.part WHEN 'solid' THEN h.mid_tex WHEN 'upper' THEN h.upper_tex WHEN 'lower' THEN h.lower_tex
                     WHEN 'midmask' THEN h.mid_tex END AS tex,
         CASE k.part WHEN 'solid' THEN h.f_floor WHEN 'upper' THEN h.b_ceil WHEN 'upper_open' THEN h.f_ceil
                     WHEN 'upper_flush' THEN h.f_ceil WHEN 'lower' THEN h.f_floor WHEN 'lower_down' THEN h.b_floor
                     ELSE h.f_floor END AS z_bot,
         CASE k.part WHEN 'solid' THEN h.f_ceil WHEN 'upper' THEN h.f_ceil WHEN 'upper_open' THEN h.b_ceil
                     WHEN 'upper_flush' THEN h.b_ceil WHEN 'lower' THEN h.b_floor WHEN 'lower_down' THEN h.f_floor
                     ELSE h.f_ceil END AS z_top,
         CASE k.part WHEN 'solid' THEN CASE WHEN h.peg_bottom = 1 THEN h.f_floor ELSE h.f_ceil END
                     WHEN 'upper' THEN CASE WHEN h.peg_top = 1 THEN h.f_ceil ELSE h.b_ceil END
                     WHEN 'lower' THEN CASE WHEN h.peg_bottom = 1 THEN h.f_ceil ELSE h.b_floor END
                     WHEN 'midmask' THEN CASE WHEN h.peg_bottom = 1 THEN GREATEST(h.f_floor, h.b_floor) ELSE LEAST(h.f_ceil, h.b_ceil) END
                     ELSE NULL END AS v_anchor_base,
         CASE k.part WHEN 'solid' THEN h.peg_bottom WHEN 'upper' THEN 1 - h.peg_top WHEN 'midmask' THEN h.peg_bottom
                     ELSE 0 END AS add_h
  FROM segh h
  JOIN wall_part_kind k ON 1 = CASE k.part
      WHEN 'solid'       THEN CASE WHEN h.bsec IS NULL AND h.f_ceil > h.f_floor THEN 1 END
      WHEN 'upper'       THEN CASE WHEN h.bsec IS NOT NULL AND h.b_ceil < h.f_ceil AND h.both_sky = 0 THEN 1 END
      WHEN 'upper_open'  THEN CASE WHEN h.bsec IS NOT NULL AND h.b_ceil > h.f_ceil AND h.both_sky = 0 THEN 1 END
      WHEN 'upper_flush' THEN CASE WHEN h.bsec IS NOT NULL AND h.b_ceil = h.f_ceil AND h.both_sky = 0 THEN 1 END
      WHEN 'lower'       THEN CASE WHEN h.bsec IS NOT NULL AND h.b_floor > h.f_floor THEN 1 END
      WHEN 'lower_down'  THEN CASE WHEN h.bsec IS NOT NULL AND h.b_floor <= h.f_floor THEN 1 END
      WHEN 'midmask'     THEN CASE WHEN h.bsec IS NOT NULL AND h.mid_tex IS NOT NULL AND h.mid_tex <> '-'
                                        AND h.f_ceil > h.f_floor THEN 1 END END
),
minocc AS (
  -- nearest (smallest bsp_seq) fully solid occluder per screen column
  SELECT /*+ MATERIALIZE */ x.x AS col_x, MIN(h.bsp_seq) AS min_bsp_seq
  FROM segh h
  JOIN screen_x x ON x.x BETWEEN CAST(GREATEST(0, FLOOR(LEAST(h.sx1, h.sx2))) AS NUMBER) AND CAST(LEAST(319, CEIL(GREATEST(h.sx1, h.sx2))) AS NUMBER)
  WHERE (h.bsec IS NULL OR h.b_ceil <= h.b_floor) AND h.sx1 <> h.sx2
  GROUP BY x.x
),
-- ============================================================================================
-- WALL COLUMNS: one row per (wall part, screen column) that survives solid occlusion;
-- perspective-correct 1/z and u/z, vertical extent (reference math, same operation order)
-- ============================================================================================
wcol AS (
  SELECT /*+ LEADING(w x mo) USE_NL(x) INDEX_RS_ASC(x screen_x_pk) USE_HASH(mo) */
         w.seg_id, w.part, w.pcode, w.tex, w.bsp_seq, w.fsec, w.f_floor, w.f_ceil, w.f_ceil_tex, w.f_light,
         w.light_bias, w.y_offset, w.z_bot, w.z_top, w.v_anchor_base, w.add_h,
         x.x AS col_x, td.tex_id, NVL(td.width, 64) AS tex_w, NVL(td.height, 64) AS tex_h,
         w.invx1 + t.t * (w.invx2 - w.invx1) AS invx,
         ((w.x_offset + w.seg_u1) * w.invx1) + t.t * (((w.x_offset + w.seg_u2) * w.invx2) - ((w.x_offset + w.seg_u1) * w.invx1)) AS u_over_x
  FROM wparts w
  JOIN screen_x x ON x.x BETWEEN CAST(GREATEST(0, FLOOR(LEAST(w.sx1, w.sx2))) AS NUMBER) AND CAST(LEAST(319, CEIL(GREATEST(w.sx1, w.sx2))) AS NUMBER)
  LEFT JOIN minocc mo ON mo.col_x = x.x
  LEFT JOIN tex_dim td ON td.name = w.tex
  CROSS JOIN LATERAL (SELECT LEAST(1d, GREATEST(0d, (x.xd - w.sx1) / NULLIF(w.sx2 - w.sx1, 1d / 1000000d))) AS t FROM dual) t
  WHERE w.sx1 <> w.sx2
    AND w.bsp_seq <= NVL(mo.min_bsp_seq, w.bsp_seq)
),
wvert AS (
  SELECT /*+ MATERIALIZE */ c.seg_id, c.part, c.pcode, c.tex, c.bsp_seq, c.fsec, c.f_floor, c.f_ceil, c.f_ceil_tex, c.f_light,
         c.light_bias, c.y_offset, c.v_anchor_base, c.add_h, c.col_x, c.tex_id, c.tex_w, c.tex_h, c.invx,
         1d / c.invx AS depth_x, c.u_over_x / NULLIF(c.invx, 1d / 1000000d) AS u_col, r.focal * c.invx AS scale,
         r.cy - (r.focal * c.invx) * (c.z_top - m.pz) AS y_top_f, r.cy - (r.focal * c.invx) * (c.z_bot - m.pz) AS y_bot_f
  FROM wcol c CROSS JOIN rs r CROSS JOIN cam m
),
-- ============================================================================================
-- WALL SPANS: vertical extent clamped to the view, texture V origin/step, light (per column)
-- ============================================================================================
wspan AS (
  SELECT t.*,
         (t.v_anchor_base + CASE WHEN t.add_h = 1 THEN t.tex_h ELSE 0 END)
           - (t.pz + (t.cy - t.y_start) / NULLIF(t.scale, 1d / 1000000000d)) + t.y_offset AS v0,
         1d / NULLIF(t.scale, 1d / 1000000000d) AS v_step,
         FLOOR(t.u_col - t.tex_w * FLOOR(t.u_col / t.tex_w)) AS u_i,
         CASE WHEN wr.invuln = 1 THEN 32
              ELSE GREATEST(0, LEAST(31, (15 - LEAST(15, GREATEST(0, FLOOR(t.f_light / 16d) + t.light_bias + wr.extra_light))) * 4
                   - FLOOR(LEAST(47d, GREATEST(0d, 2560d / NULLIF(t.depth_x, 0d))) / 2d))) END AS light
  FROM (SELECT v.*, m.pz, r.cy,
               CAST(CEIL(LEAST(167d, GREATEST(0d, LEAST(v.y_top_f, v.y_bot_f)))) AS NUMBER) AS y_start,
               CAST(FLOOR(LEAST(167d, GREATEST(0d, GREATEST(v.y_top_f, v.y_bot_f)))) AS NUMBER) AS y_end
        FROM wvert v CROSS JOIN cam m CROSS JOIN rs r
        WHERE v.tex IS NOT NULL AND v.tex <> '-'
          AND LEAST(v.y_top_f, v.y_bot_f) < 168 AND GREATEST(v.y_top_f, v.y_bot_f) >= 0) t
  CROSS JOIN wr
  WHERE t.y_end >= t.y_start
),
-- ============================================================================================
-- VISPLANES: per-column front-to-back clip windows over all panels (reference panel_clips),
-- carried ceiling/floor via LAST_VALUE ... IGNORE NULLS instead of LATERAL ... LIMIT 1
-- ============================================================================================
pcols AS (
  SELECT v.col_x, v.seg_id, v.bsp_seq, v.part, v.depth_x, v.y_top_f, v.y_bot_f,
         CASE WHEN v.part = 'lower_down' THEN v.y_top_f ELSE v.y_bot_f END AS f_floor_y_f,
         CASE WHEN v.part = 'upper_open' THEN v.y_bot_f ELSE v.y_top_f END AS f_ceil_y_f,
         v.fsec, v.f_light, v.f_floor, v.f_ceil,
         CASE WHEN v.f_ceil_tex = 'F_SKY1' THEN 1 WHEN v.f_ceil_tex IS NULL THEN NULL ELSE 0 END AS f_ceil_is_sky
  FROM wvert v
  WHERE v.part IN ('upper_open', 'upper_flush', 'lower_down')
     OR (LEAST(v.y_top_f, v.y_bot_f) < 168 AND GREATEST(v.y_top_f, v.y_bot_f) >= 0)
),
pclip AS (
  SELECT /*+ MATERIALIZE */ p.*,
    CAST(NVL(MAX(CASE WHEN p.part IN ('solid', 'upper') THEN FLOOR(LEAST(167d, GREATEST(0d, p.y_bot_f))) + 1
                 WHEN p.part = 'upper_flush' THEN GREATEST(0, FLOOR(LEAST(167d, p.y_bot_f)) + 1) END)
        OVER (PARTITION BY p.col_x ORDER BY p.depth_x, p.bsp_seq, p.part, p.seg_id
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS NUMBER) AS cc_before,
    CAST(NVL(MIN(CASE WHEN p.part IN ('solid', 'lower', 'lower_down') THEN LEAST(167, CEIL(GREATEST(0d, p.y_top_f)) - 1) END)
        OVER (PARTITION BY p.col_x ORDER BY p.depth_x, p.bsp_seq, p.part, p.seg_id
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 167) AS NUMBER) AS fc_before,
    -- carried ceiling / floor: the latest nearer panel whose front plane faces the camera,
    -- packed (sector, height, light, sky) into one exact NUMBER so one window carries all four
    LAST_VALUE(CASE WHEN p.f_ceil > m.pz THEN ((p.fsec * 1000000 + (p.f_ceil + 100000)) * 1000 + p.f_light) * 10
                                              + NVL(p.f_ceil_is_sky, 2) END IGNORE NULLS)
        OVER (PARTITION BY p.col_x ORDER BY p.depth_x, p.bsp_seq, p.part, p.seg_id
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS cc_pack,
    LAST_VALUE(CASE WHEN p.f_floor < m.pz THEN (p.fsec * 1000000 + (p.f_floor + 100000)) * 1000 + p.f_light END IGNORE NULLS)
        OVER (PARTITION BY p.col_x ORDER BY p.depth_x, p.bsp_seq, p.part, p.seg_id
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS cf_pack,
    MIN(CASE WHEN p.part IN ('solid', 'lower', 'lower_down') THEN p.depth_x END) OVER (PARTITION BY p.col_x) AS near_floor_depth,
    MIN(CASE WHEN p.part IN ('solid', 'upper', 'upper_open', 'upper_flush') THEN p.depth_x END) OVER (PARTITION BY p.col_x) AS near_ceil_depth
  FROM pcols p CROSS JOIN cam m
),
pspan_raw AS (
  -- ceiling fill above each panel (bounded by the panel's own top edge or, for a carried
  -- ceiling, by the plane-depth cap)
  SELECT k.col_x,
         CASE WHEN o.own = 1 THEN k.fsec ELSE k.cc_sec END AS sector_id,
         CASE WHEN o.own = 1 THEN k.f_ceil ELSE k.cc_z END AS plane_z,
         CASE WHEN o.own = 1 THEN k.f_light ELSE k.cc_light END AS sector_light,
         CASE WHEN o.own = 1 THEN k.f_ceil_is_sky ELSE NVL(NULLIF(k.cc_sky_raw, -1), 0) END AS is_sky,
         1 AS plane, 1 AS src, GREATEST(0, k.cc_before) AS y0,
         CEIL(LEAST(167d, GREATEST(0d,
           CASE WHEN o.own = 1 OR k.cc_z IS NULL THEN k.f_ceil_y_f
                ELSE LEAST(k.f_ceil_y_f, r.cy - r.focal * (k.cc_z - m.pz) / r.max_plane_depth) END))) - 1 AS y1
  FROM (SELECT q.*, TRUNC(q.cc_pack / 10000000000) AS cc_sec, MOD(TRUNC(q.cc_pack / 10000), 1000000) - 100000 AS cc_z,
               MOD(TRUNC(q.cc_pack / 10), 1000) AS cc_light,
               CASE MOD(q.cc_pack, 10) WHEN 2 THEN -1 ELSE MOD(q.cc_pack, 10) END AS cc_sky_raw,
               TRUNC(q.cf_pack / 1000000000) AS cf_sec, MOD(TRUNC(q.cf_pack / 1000), 1000000) - 100000 AS cf_z,
               MOD(q.cf_pack, 1000) AS cf_light
        FROM pclip q) k CROSS JOIN rs r CROSS JOIN cam m
  CROSS APPLY (SELECT CASE WHEN k.f_ceil > m.pz OR k.f_ceil_is_sky = 1 THEN 1 ELSE 0 END AS own FROM dual) o
  WHERE k.part IN ('solid', 'upper', 'upper_open', 'upper_flush', 'midmask')
    AND (k.f_ceil > m.pz OR k.f_ceil_is_sky = 1 OR NVL(NULLIF(k.cc_sky_raw, -1), 0) = 1 OR k.cc_before > 0)
  UNION ALL
  -- floor fill below each panel
  SELECT k.col_x,
         CASE WHEN o.own = 1 THEN k.fsec ELSE k.cf_sec END,
         CASE WHEN o.own = 1 THEN k.f_floor ELSE k.cf_z END,
         CASE WHEN o.own = 1 THEN k.f_light ELSE k.cf_light END,
         0, 0, 1,
         FLOOR(LEAST(167d, GREATEST(0d,
           CASE WHEN o.own = 1 OR k.cf_z IS NULL THEN k.f_floor_y_f
                ELSE GREATEST(k.f_floor_y_f, r.cy - r.focal * (k.cf_z - m.pz) / r.max_plane_depth) END))) + 1,
         LEAST(167, k.fc_before)
  FROM (SELECT q.*, TRUNC(q.cc_pack / 10000000000) AS cc_sec, MOD(TRUNC(q.cc_pack / 10000), 1000000) - 100000 AS cc_z,
               MOD(TRUNC(q.cc_pack / 10), 1000) AS cc_light,
               CASE MOD(q.cc_pack, 10) WHEN 2 THEN -1 ELSE MOD(q.cc_pack, 10) END AS cc_sky_raw,
               TRUNC(q.cf_pack / 1000000000) AS cf_sec, MOD(TRUNC(q.cf_pack / 1000), 1000000) - 100000 AS cf_z,
               MOD(q.cf_pack, 1000) AS cf_light
        FROM pclip q) k CROSS JOIN rs r CROSS JOIN cam m
  CROSS APPLY (SELECT CASE WHEN k.f_floor < m.pz THEN 1 ELSE 0 END AS own FROM dual) o
  WHERE k.part IN ('solid', 'midmask', 'lower', 'lower_down')
    AND (k.f_floor < m.pz OR k.fc_before < 167)
  UNION ALL
  -- camera-sector seed spans (floor and ceiling) for every column
  SELECT x.x, ps.id, ps.floor_height, ps.light_level, 0, 0, 0,
         CASE WHEN nf.d IS NULL THEN FLOOR(r.cy) + 1
              ELSE FLOOR(LEAST(167d, GREATEST(0d, r.cy - r.focal * (ps.floor_height - m.pz) / nf.d))) + 1 END,
         167
  FROM screen_x x CROSS JOIN rs r CROSS JOIN cam m CROSS JOIN player_sector ps
  LEFT JOIN (SELECT col_x, MIN(near_floor_depth) AS d FROM pclip GROUP BY col_x) nf ON nf.col_x = x.x
  WHERE x.x < 320
  UNION ALL
  SELECT x.x, ps.id, ps.ceil_height, ps.light_level, CASE WHEN ps.ceil_tex = 'F_SKY1' THEN 1 ELSE 0 END, 1, 0,
         0,
         CASE WHEN nc.d IS NULL THEN CEIL(r.cy) - 1
              ELSE CEIL(LEAST(167d, GREATEST(0d, r.cy - r.focal * (ps.ceil_height - m.pz) / nc.d))) - 1 END
  FROM screen_x x CROSS JOIN rs r CROSS JOIN cam m CROSS JOIN player_sector ps
  LEFT JOIN (SELECT col_x, MIN(near_ceil_depth) AS d FROM pclip GROUP BY col_x) nc ON nc.col_x = x.x
  WHERE x.x < 320
),
pspan AS (
  -- keep spans whose plane faces the camera; collapse identical spans (reference dedup)
  SELECT s.col_x, s.sector_id, s.plane_z, s.plane, s.is_sky, CAST(s.y0 AS NUMBER) AS y0, CAST(s.y1 AS NUMBER) AS y1,
         MIN(s.sector_light) AS sector_light, MIN(s.src) AS src
  FROM pspan_raw s CROSS JOIN cam m
  WHERE s.y1 >= s.y0
    AND ((s.plane = 0 AND s.plane_z < m.pz) OR (s.plane = 1 AND (s.plane_z > m.pz OR s.is_sky = 1)))
  GROUP BY s.col_x, s.sector_id, s.plane_z, s.plane, s.is_sky, s.y0, s.y1
),
-- ============================================================================================
-- EXACT INTERVAL-LEVEL VISIBILITY. Items = wall spans (constant depth) and plane spans
-- (depth = cz/(cy-y), or 1e7 for sky). The reference resolves every pixel with
-- MIN(packed key); here each column is cut into elementary segments at item boundaries.
-- A segment with one candidate, or only constant-key candidates, is resolved once for the
-- whole segment; only segments where a plane competes are resolved per pixel.
-- Key = qdepth*2^34 + (2-surface)*2^32 + src*2^30 + stable*2^14 (reference ranked_fragments).
-- ============================================================================================
items AS (
  SELECT /*+ MATERIALIZE */ ROWNUM AS item_id, i.* FROM (
    SELECT 1 AS kind, w.col_x, w.y_start AS y0, w.y_end AS y1,
           ROUND(GREATEST(0d, LEAST(w.depth_x, 131071d)) * 4096d) * 17179869184
             + LEAST(65535, GREATEST(0, w.seg_id * 8 + w.pcode + 32768)) * 16384 AS ckey,
           NULL AS cz, NULL AS pkey, NULL AS span_sky,
           w.tex_id, w.u_i, w.tex_h, w.light, w.v0, w.v_step, w.y_start,
           NULL AS sector_id, NULL AS plane, NULL AS sector_light
    FROM wspan w
    UNION ALL
    SELECT 2, p.col_x, p.y0, p.y1,
           CASE WHEN p.is_sky = 1 THEN ROUND(131071d * 4096d) * 17179869184 + 2 * 4294967296
                  + LEAST(p.src, 3) * 1073741824 + LEAST(65535, GREATEST(0, p.sector_id * 2 + p.plane + 32768)) * 16384 END,
           r.focal * (p.plane_z - m.pz),
           2 * 4294967296 + LEAST(p.src, 3) * 1073741824 + LEAST(65535, GREATEST(0, p.sector_id * 2 + p.plane + 32768)) * 16384,
           p.is_sky,
           NULL, NULL, NULL, NULL, NULL, NULL, NULL,
           p.sector_id, p.plane, p.sector_light
    FROM pspan p CROSS JOIN rs r CROSS JOIN cam m
  ) i
),
bpt AS (
  SELECT col_x, y0 AS b FROM items
  UNION SELECT col_x, y1 + 1 FROM items
  UNION SELECT x, 0 FROM screen_x
  UNION SELECT x, 168 FROM screen_x
),
eseg AS (
  SELECT col_x, a, b FROM (
    SELECT col_x, b AS a, LEAD(b) OVER (PARTITION BY col_x ORDER BY b) - 1 AS b FROM bpt WHERE b <= 168)
  WHERE b IS NOT NULL AND a <= 167
),
cand AS (
  SELECT e.col_x, e.a, e.b, i.item_id, i.kind, i.ckey, i.span_sky
  FROM eseg e JOIN items i ON i.col_x = e.col_x AND i.y0 <= e.a AND i.y1 >= e.b
),
segcls AS (
  SELECT /*+ MATERIALIZE */ e.col_x, e.a, e.b,
         COUNT(c.item_id) AS n,
         COUNT(CASE WHEN c.kind = 2 AND NVL(c.span_sky, 0) <> 1 THEN 1 END) AS nplanes,
         MIN(c.item_id) KEEP (DENSE_RANK FIRST ORDER BY c.ckey NULLS LAST) AS best_const,
         MIN(c.item_id) AS any_item
  FROM eseg e LEFT JOIN cand c ON c.col_x = e.col_x AND c.a = e.a
  GROUP BY e.col_x, e.a, e.b
),
contested AS (
  SELECT /*+ INDEX_RS_ASC(y screen_y_pk) */ c.col_x, y.y,
         MIN(c.item_id) KEEP (DENSE_RANK FIRST ORDER BY
           CASE WHEN c.kind = 1 OR c.span_sky = 1 THEN c.ckey
                ELSE ROUND(GREATEST(0d, LEAST(i.cz / (r.cy - y.yd), 131071d)) * 4096d) * 17179869184 + i.pkey END) AS item_id
  FROM segcls s
  JOIN cand c ON c.col_x = s.col_x AND c.a = s.a
  JOIN items i ON i.item_id = c.item_id
  JOIN screen_y y ON y.y BETWEEN s.a AND s.b
  CROSS JOIN rs r
  WHERE s.n >= 2 AND s.nplanes >= 1
    AND (c.kind = 1 OR c.span_sky = 1 OR (r.cy - y.yd <> 0 AND i.cz / (r.cy - y.yd) > r.near))
  GROUP BY c.col_x, y.y
),
fseg AS (
  -- final ownership: disjoint (column, row-range) -> item; holes have no row
  SELECT /*+ MATERIALIZE */ col_x, a, b, CASE WHEN nplanes = 0 THEN best_const ELSE any_item END AS item_id
  FROM segcls WHERE n = 1 OR (n >= 2 AND nplanes = 0)
  UNION ALL
  SELECT col_x, y, y, item_id FROM contested
),
-- Status bar (rows 168..199) as packed deltas over the precomputed background.
-- Emits rows (y, chunk, v): add to hud_static_packed for the final packed status-bar rows.
-- Semantics follow reference renderer.sql (player_ui_state .. ui_colored) exactly.
player_ui_state AS (
  SELECT ps.health, ps.alive, ps.pain_face_tics, ps.armor,
         ps.ammo_bullets, ps.ammo_shells, ps.ammo_rockets, ps.ammo_cells,
         ps.key_blue, ps.key_yellow, ps.key_red,
         ps.damage_count, ps.bonus_count, ps.radsuit_tics, ps.message, ps.message_tics, ps.backpack,
         wd.ammo_type AS current_ammo_type
  FROM st_player_state ps
  LEFT JOIN st_player_weapons w ON w.tic = ps.tic AND w.map_id = ps.map_id AND w.player_thing_id = ps.player_thing_id
  LEFT JOIN weapon_defs wd ON wd.weapon_id = COALESCE(w.current_weapon, 2)
  WHERE ps.tic = :tic AND ps.map_id = :map_id AND ps.player_thing_id = :player_id
),
active_palette AS (
  SELECT CASE
    WHEN pu.damage_count > 0 THEN LEAST(7, TRUNC((pu.damage_count + 7) / 8)) + 1
    WHEN pu.bonus_count > 0 THEN LEAST(3, TRUNC((pu.bonus_count + 7) / 8)) + 9
    WHEN pu.radsuit_tics > 128 OR BITAND(pu.radsuit_tics, 8) <> 0 THEN 13
    ELSE 0 END AS pal
  FROM player_ui_state pu
),
hud_values AS (
  -- (value, right_x, y, font, digit width) for every right-aligned number on the bar
  SELECT pu.health AS value, 90 AS right_x, 172 AS y, 'STTNUM' AS font, 14 AS dw FROM player_ui_state pu
  UNION ALL SELECT pu.armor, 221, 172, 'STTNUM', 14 FROM player_ui_state pu
  UNION ALL SELECT CASE pu.current_ammo_type WHEN 'bullets' THEN pu.ammo_bullets WHEN 'shells' THEN pu.ammo_shells
                    WHEN 'rockets' THEN pu.ammo_rockets WHEN 'cells' THEN pu.ammo_cells END, 44, 172, 'STTNUM', 14
            FROM player_ui_state pu WHERE pu.current_ammo_type IS NOT NULL
  UNION ALL SELECT pu.ammo_bullets, 288, 173, 'STYSNUM', 4 FROM player_ui_state pu
  UNION ALL SELECT pu.ammo_shells,  288, 179, 'STYSNUM', 4 FROM player_ui_state pu
  UNION ALL SELECT pu.ammo_rockets, 288, 185, 'STYSNUM', 4 FROM player_ui_state pu
  UNION ALL SELECT pu.ammo_cells,   288, 191, 'STYSNUM', 4 FROM player_ui_state pu
  UNION ALL SELECT CASE WHEN pu.backpack THEN ad.backpack_cap ELSE ad.cap END, 314,
                   CASE ad.ammo_type WHEN 'bullets' THEN 173 WHEN 'shells' THEN 179
                                     WHEN 'rockets' THEN 185 ELSE 191 END, 'STYSNUM', 4
            FROM player_ui_state pu CROSS JOIN ammo_defs ad
),
ui_layers AS (
  SELECT 1 AS layer, hv.font || SUBSTR(TO_CHAR(hv.value), d.x + 1, 1) AS patch,
         hv.right_x - (LENGTH(TO_CHAR(hv.value)) - d.x) * hv.dw AS x, hv.y
  FROM hud_values hv JOIN screen_x d ON d.x < LENGTH(TO_CHAR(hv.value))
  WHERE hv.value IS NOT NULL
  UNION ALL
  SELECT 1, k.patch, 239, k.y
  FROM player_ui_state pu
  CROSS APPLY (SELECT 'STKEYS0' AS patch, 171 AS y FROM dual WHERE pu.key_blue
               UNION ALL SELECT 'STKEYS1', 181 FROM dual WHERE pu.key_yellow
               UNION ALL SELECT 'STKEYS2', 191 FROM dual WHERE pu.key_red) k
  UNION ALL
  -- ARMS: weapon slots 2..7, yellow once owned
  SELECT 2, CASE WHEN o.weapon_id IS NOT NULL THEN 'STYSNUM' ELSE 'STGNUM' END || TO_CHAR(s.x),
         111 + MOD(s.x - 2, 3) * 12, 172 + TRUNC((s.x - 2) / 3) * 10
  FROM screen_x s
  LEFT JOIN st_player_weapon_owned o ON o.tic = :tic AND o.map_id = :map_id
        AND o.player_thing_id = :player_id AND o.weapon_id = s.x
  WHERE s.x BETWEEN 2 AND 7
  UNION ALL
  SELECT 1, CASE WHEN NOT pu.alive THEN 'STFDEAD0'
                 WHEN pu.pain_face_tics > 0 THEN
                   'STFOUCH' || TO_CHAR(LEAST(4, GREATEST(0, TRUNC((100 - GREATEST(0, LEAST(100, pu.health))) / 20))))
                 ELSE 'STFST' || TO_CHAR(LEAST(4, GREATEST(0, TRUNC((100 - GREATEST(0, LEAST(100, pu.health))) / 20)))) || '0'
            END, 143, 168
  FROM player_ui_state pu
),
ui_resolved AS (
  SELECT l.x - p.left_offset + px.dx AS x, l.y - p.top_offset + px.dy AS y,
         MAX(px.palette_index) KEEP (DENSE_RANK LAST ORDER BY l.layer) AS palette_index
  FROM ui_layers l
  JOIN ui_patches p ON p.name = l.patch
  JOIN ui_hud_pixels px ON px.name = l.patch
  GROUP BY l.x - p.left_offset + px.dx, l.y - p.top_offset + px.dy
),
hud_delta AS (
  SELECT ur.y, sx.chunk, (cm.mapped - hs.idx) * sx.w AS v
  FROM ui_resolved ur
  JOIN hud_static_idx hs ON hs.x = ur.x AND hs.y = ur.y
  JOIN cmap cm ON cm.light = 0 AND cm.idx = ur.palette_index
  JOIN screen_x sx ON sx.x = ur.x
),
-- ============================================================================================
-- BACKGROUND PIXELS: exactly one row per owned pixel; texel and COLORMAP come from pre-lit
-- NVARCHAR2 strings (palette index i = U+0100+i), all addressing in BINARY_DOUBLE.
-- ============================================================================================
pitems AS (
  -- plane item attributes resolved once per item, not per pixel; cls = plane class (height, light base)
  SELECT /*+ MATERIALIZE */ k.*, DENSE_RANK() OVER (ORDER BY k.cz, k.lbase) AS cls FROM (
  SELECT i.item_id, i.cz, i.span_sky, fd.flat_id, c.px, c.py, c.cv, c.sv, wr.invuln,
         CASE WHEN (CASE WHEN i.plane = 0 THEN s.floor_tex ELSE s.ceil_tex END) = 'F_SKY1' THEN 1 ELSE 0 END AS tex_sky,
         TO_BINARY_DOUBLE((15 - LEAST(15, GREATEST(0, FLOOR(i.sector_light / 16d) + wr.extra_light))) * 4) AS lbase
  FROM items i
  JOIN secl s ON s.id = i.sector_id
  LEFT JOIN flat_dim fd ON fd.name = CASE WHEN i.plane = 0 THEN s.floor_tex ELSE s.ceil_tex END
  CROSS JOIN wr CROSS JOIN cam c
  WHERE i.kind = 2) k
),
prow AS (
  -- per (plane class, screen row): depth, the depth-only parts of the world point and the zlight
  -- index, in the reference's operation order (wx = (px + depth*cv) + (ta*depth)*sv); valid rows only
  SELECT /*+ MATERIALIZE */ c.cls, y.y, d.depth, c.px + d.depth * c.cv AS a, c.py + d.depth * c.sv AS b,
         CASE WHEN c.invuln = 1 THEN 32d
              ELSE GREATEST(0d, LEAST(31d, c.lbase - FLOOR(80d / (LEAST(127d, FLOOR(d.depth / 16d)) + 1d)))) END AS light
  FROM (SELECT /*+ NO_MERGE */ DISTINCT cls, cz, lbase, invuln, px, py, cv, sv FROM pitems WHERE tex_sky = 0) c
  CROSS JOIN screen_y y
  CROSS APPLY (SELECT c.cz / y.dy AS depth FROM dual) d
  WHERE y.y < 168 AND y.dy <> 0d AND d.depth > 1d / 1000d
),
witems AS (
  -- wall items with their pre-lit texture column (one indexed lookup per item)
  SELECT /*+ MATERIALIZE */ /*+ USE_NL(t) INDEX(t texcol_lit_pk) */ i.item_id, t.col, i.v0, i.v_step, TO_BINARY_DOUBLE(i.y_start) AS ys,
         TO_BINARY_DOUBLE(i.tex_h) AS th
  FROM items i
  JOIN texcol_lit t ON t.tex_id = i.tex_id AND t.u = CAST(i.u_i AS NUMBER) AND t.light = CAST(i.light AS NUMBER)
  WHERE i.kind = 1
),
flused AS (
  -- only the lit flat strings of flats visible this frame; keys in BINARY_DOUBLE for the per-pixel join
  -- (driven from the distinct visible flats: IOT range scans, not a scan of all 13k lit strings)
  SELECT /*+ MATERIALIZE */ /*+ LEADING(u fl) USE_NL(fl) INDEX(fl flat_lit_pk) */
         fl.flat_id, TO_BINARY_DOUBLE(fl.light) AS light, TO_BINARY_DOUBLE(fl.q) AS q, 1d - 1024d * fl.q AS off, fl.s
  FROM (SELECT /*+ NO_MERGE */ DISTINCT flat_id FROM pitems WHERE flat_id IS NOT NULL) u
  JOIN flat_lit fl ON fl.flat_id = u.flat_id
),
skycol AS (
  -- sky: u from the ray angle of the screen column, light 0 (reference plane_uv);
  -- u computed per column first, then one indexed texcol_lit probe per column
  SELECT /*+ MATERIALIZE */ /*+ LEADING(k t) USE_NL(t) INDEX(t texcol_lit_pk) */ k.x, t.col
  FROM (SELECT /*+ NO_MERGE */ x.x, td.tex_id,
               CAST(MOD(MOD(FLOOR(((c.vr - ATAN((x.xd - r.cx) / r.focal)) / (3.14159265358979323846d / 180d)) * 2.844444d), 256) + 256, 256) AS NUMBER) AS u
        FROM screen_x x CROSS JOIN cam c CROSS JOIN rs r
        JOIN maps mp ON mp.map_id = :map_id
        JOIN tex_dim td ON td.name = mp.sky_texture
        WHERE x.x < 320) k
  JOIN texcol_lit t ON t.tex_id = k.tex_id AND t.u = k.u AND t.light = 0
),
fsegw AS (
  -- final segments with the packing weight of their column (once per segment, not per pixel)
  SELECT /*+ MATERIALIZE */ f.col_x, f.a, f.b, f.item_id, sx.chunk, sx.w, sx.ta
  FROM fseg f JOIN screen_x sx ON sx.x = f.col_x
),
bg_wall AS (
  SELECT /*+ LEADING(f w y) USE_HASH(w) USE_NL(y) INDEX_RS_ASC(y screen_y_pk) */ f.col_x AS x, y.y, f.chunk, f.w,
         ASCII(SUBSTR(w.col, (FLOOR(w.v0 + (y.yd - w.ys) * w.v_step)
                              - w.th * FLOOR(FLOOR(w.v0 + (y.yd - w.ys) * w.v_step) / w.th)) + 1d, 1)) - 256 AS v
  FROM fsegw f
  JOIN witems w ON w.item_id = f.item_id
  JOIN screen_y y ON y.y BETWEEN f.a AND f.b
),
bg_flat AS (
  -- flats: per-row depth / zlight / depth terms of the world point from prow, per pixel only the
  -- column term (ta*depth), texel coordinates and the lit flat quarter string by hash join
  SELECT /*+ LEADING(q fl) USE_HASH(fl) */ q.x, q.y, q.chunk, q.w,
         CASE WHEN q.ok = 1 THEN ASCII(SUBSTR(fl.s, q.tv * 64d + q.tu + fl.off, 1)) - 256 ELSE 0 END AS v
  FROM (
    SELECT /*+ NO_MERGE */ z.x, z.y, z.chunk, z.w, z.flat_id, z.light, z.ok,
           FLOOR(z.wy) - 64d * FLOOR(z.wy * 0.015625d) AS tv,
           FLOOR(z.wx) - 64d * FLOOR(z.wx * 0.015625d) AS tu
    FROM (
      SELECT /*+ NO_MERGE LEADING(p f y r) USE_HASH(f) USE_NL(y) INDEX_RS_ASC(y screen_y_pk) USE_HASH(r) */
             f.col_x AS x, y.y, f.chunk, f.w, p.flat_id, r.light, NVL2(r.cls, 1, 0) AS ok,
             r.a + (f.ta * r.depth) * p.sv AS wx, r.b - (f.ta * r.depth) * p.cv AS wy
      FROM pitems p
      JOIN fsegw f ON f.item_id = p.item_id
      JOIN screen_y y ON y.y BETWEEN f.a AND f.b
      LEFT JOIN prow r ON r.cls = p.cls AND r.y = y.y
      WHERE p.tex_sky = 0) z
  ) q
  LEFT JOIN flused fl ON fl.flat_id = q.flat_id AND fl.light = q.light AND fl.q = FLOOR(q.tv * 0.0625d)
),
bg_sky AS (
  SELECT /*+ LEADING(p f y k) USE_HASH(f) USE_NL(y) INDEX_RS_ASC(y screen_y_pk) */ f.col_x AS x, y.y, f.chunk, f.w,
         CASE WHEN p.span_sky = 1 OR (y.dy <> 0d AND p.cz / y.dy > 1d / 1000d)
              THEN NVL(ASCII(SUBSTR(k.col, MOD(MOD(y.y - 100, 128) + 128, 128) + 1, 1)) - 256, 0) ELSE 0 END AS v
  FROM fsegw f
  JOIN pitems p ON p.item_id = f.item_id AND p.tex_sky = 1
  JOIN screen_y y ON y.y BETWEEN f.a AND f.b
  JOIN skycol k ON k.x = f.col_x
),
bg AS (
  SELECT x, y, chunk, w, v FROM bg_wall
  UNION ALL SELECT x, y, chunk, w, v FROM bg_flat
  UNION ALL SELECT x, y, chunk, w, v FROM bg_sky
),
-- ============================================================================================
-- SPRITES (reference thing_view .. thing_pixels), depth-tested against the background owner
-- of each candidate pixel instead of a full-screen z-buffer
-- ============================================================================================
tview AS (
  SELECT t.id AS thing_id, t.x, t.y, t.angle,
         CASE WHEN NVL(d.explodes, FALSE) AND ai.state = 'die' THEN d.death_sprite
              WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead') THEN d.death_sprite
              ELSE rt.sprite END AS sprite,
         CASE WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead')
                THEN CASE WHEN h.health < -h.max_health AND d.xdeath_frame IS NOT NULL THEN d.xdeath_frame ELSE d.death_frame END
              WHEN f.frame IS NOT NULL THEN f.frame ELSE rt.frame END AS frame,
         CASE WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead') THEN d.death_fullbright
              WHEN f.frame IS NOT NULL THEN f.fullbright ELSE rt.fullbright END AS fullbright,
         TO_BINARY_FLOAT(CASE WHEN rt.spawn_ceiling THEN s.ceil_height - rt.thing_height
                              WHEN d.floats AND NVL(h.alive, TRUE) THEN t.z ELSE s.floor_height END) AS base_z,
         s.light_level AS sector_light,
         (t.x - c.px) * c.cv + (t.y - c.py) * c.sv AS depth,
         (t.x - c.px) * c.sv - (t.y - c.py) * c.cv AS side,
         MOD(MOD(FLOOR((ATAN2(t.y - c.py, t.x - c.px) / (3.14159265358979323846d / 180d) - t.angle + 202.5d) / 45d), 8) + 8, 8) + 1 AS wrot,
         CASE WHEN NVL(d.fuzzy, FALSE) THEN 1 ELSE 0 END AS fuzz
  FROM st_render_things rt
  JOIN st_things t ON t.tic = rt.tic AND t.map_id = rt.map_id AND t.id = rt.thing_id
  LEFT JOIN st_thing_health h ON h.tic = rt.tic AND h.map_id = rt.map_id AND h.thing_id = rt.thing_id
  LEFT JOIN thing_combat_defs d ON d.thing_type = t.type
  LEFT JOIN st_monster_ai ai ON ai.tic = rt.tic AND ai.map_id = rt.map_id AND ai.thing_id = rt.thing_id
  LEFT JOIN thing_ai_frames f ON f.thing_type = t.type AND f.state = ai.state AND f.seq_index = ai.seq_index
  LEFT JOIN st_picked_up_items pu ON pu.tic = rt.tic AND pu.map_id = rt.map_id AND pu.thing_id = rt.thing_id
  JOIN secl s ON s.id = NVL(ai.sector_id, rt.sector_id)
  CROSS JOIN cam c
  WHERE rt.tic = :tic AND rt.map_id = :map_id
    AND BITAND(t.flags, c.skill_bit) <> 0 AND BITAND(t.flags, 16) = 0
    AND pu.thing_id IS NULL
    AND NOT (NVL(d.explodes, FALSE) AND ai.state = 'dead')
  UNION ALL
  SELECT -e.effect_id, e.x, e.y, 0, ed.sprite,
         SUBSTR(ed.frame_sequence, LEAST(LENGTH(ed.frame_sequence) - 1, TRUNC(e.age / ed.tics_per_frame)) + 1, 1),
         ed.fullbright, TO_BINARY_FLOAT(e.z), NVL(s.light_level, ps.light_level),
         (e.x - c.px) * c.cv + (e.y - c.py) * c.sv, (e.x - c.px) * c.sv - (e.y - c.py) * c.cv, 0, 0
  FROM st_world_effects e
  JOIN effect_sprite_defs ed ON ed.effect_type = e.effect_type
  LEFT JOIN secl s ON s.id = e.sector_id
  CROSS JOIN player_sector ps CROSS JOIN cam c
  WHERE e.tic = :tic AND e.map_id = :map_id
  UNION ALL
  SELECT ot.id, ot.x, ot.y, ot.angle, 'PLAY', op.sprite_frame, FALSE, TO_BINARY_FLOAT(s.floor_height), s.light_level,
         (ot.x - c.px) * c.cv + (ot.y - c.py) * c.sv, (ot.x - c.px) * c.sv - (ot.y - c.py) * c.cv,
         MOD(MOD(FLOOR((ATAN2(ot.y - c.py, ot.x - c.px) / (3.14159265358979323846d / 180d) - ot.angle + 202.5d) / 45d), 8) + 8, 8) + 1,
         CASE WHEN op.invis_tics > 0 THEN 1 ELSE 0 END
  FROM st_player_state op
  JOIN st_things ot ON ot.tic = op.tic AND ot.map_id = op.map_id AND ot.id = op.player_thing_id
  JOIN secl s ON s.id = op.sector_id
  CROSS JOIN cam c
  WHERE op.tic = :tic AND op.map_id = :map_id AND op.player_thing_id <> :player_id
  UNION ALL
  SELECT -(1000000000000 + mp.projectile_id), mp.x, mp.y, 0,
         CASE WHEN mp.state = 'fly' THEN pd.fly_sprite ELSE pd.impact_sprite END,
         CASE WHEN mp.projectile_type = 'rocket' THEN
                CASE WHEN mp.state = 'fly' THEN 'A' WHEN mp.age < 8 THEN 'B' WHEN mp.age < 14 THEN 'C' ELSE 'D' END
              WHEN mp.projectile_type = 'plasma' THEN
                CASE WHEN mp.state = 'fly' THEN CASE WHEN MOD(mp.age, 12) < 6 THEN 'A' ELSE 'B' END
                     WHEN mp.age < 4 THEN 'A' WHEN mp.age < 8 THEN 'B' WHEN mp.age < 12 THEN 'C'
                     WHEN mp.age < 16 THEN 'D' ELSE 'E' END
              WHEN mp.projectile_type = 'bfg' THEN
                CASE WHEN mp.state = 'fly' THEN CASE WHEN MOD(mp.age, 8) < 4 THEN 'A' ELSE 'B' END
                     WHEN mp.age < 8 THEN 'A' WHEN mp.age < 16 THEN 'B' WHEN mp.age < 24 THEN 'C'
                     WHEN mp.age < 32 THEN 'D' WHEN mp.age < 40 THEN 'E' ELSE 'F' END
              ELSE CASE WHEN mp.state = 'fly' THEN CASE WHEN MOD(mp.age, 8) < 4 THEN 'A' ELSE 'B' END
                        WHEN mp.age < 5 THEN 'C' WHEN mp.age < 10 THEN 'D' ELSE 'E' END END,
         TRUE, TO_BINARY_FLOAT(mp.z), NVL(s.light_level, ps.light_level),
         (mp.x - c.px) * c.cv + (mp.y - c.py) * c.sv, (mp.x - c.px) * c.sv - (mp.y - c.py) * c.cv,
         CASE WHEN mp.state = 'fly' THEN
           MOD(MOD(FLOOR((ATAN2(mp.y - c.py, mp.x - c.px) / (3.14159265358979323846d / 180d)
                          - ATAN2(mp.vy, mp.vx) / (3.14159265358979323846d / 180d) + 202.5d) / 45d), 8) + 8, 8) + 1
           ELSE 0 END, 0
  FROM st_monster_projectiles mp
  JOIN projectile_defs pd ON pd.projectile_type = mp.projectile_type
  LEFT JOIN secl s ON s.id = mp.sector_id
  CROSS JOIN player_sector ps CROSS JOIN cam c
  WHERE mp.tic = :tic AND mp.map_id = :map_id
),
tbound AS (
  SELECT /*+ MATERIALIZE */ q.*,
         q.origin_x - q.scale * q.left_offset AS xl, q.origin_x + q.scale * (q.width - q.left_offset) AS xr,
         r.cy - q.scale * (TO_BINARY_FLOAT(q.base_z + q.top_offset) - m.pz) AS yt,
         r.cy - q.scale * (TO_BINARY_FLOAT(TO_BINARY_FLOAT(q.base_z + q.top_offset) - q.height) - m.pz) AS yb,
         CASE WHEN wr.invuln = 1 THEN 32 WHEN q.fullbright THEN 0
              ELSE GREATEST(0, LEAST(31, (15 - LEAST(15, GREATEST(0, FLOOR(q.sector_light / 16d) + wr.extra_light))) * 4
                   - FLOOR(LEAST(47d, GREATEST(0d, 2560d / NULLIF(q.depth, 0d))) / 2d))) END AS base_light,
         ROUND(GREATEST(0d, LEAST(q.depth, 131071d)) * 4096d) * 17179869184 + 4294967296
           + LEAST(65535, GREATEST(0, q.thing_id + 32768)) * 16384 AS skey
  FROM (
    SELECT tv.*, sf.lump_name, sf.flipped, sf.width, sf.height, sf.left_offset, sf.top_offset,
           r.focal / tv.depth AS scale, r.cx + r.focal * tv.side / tv.depth AS origin_x
    FROM tview tv CROSS JOIN rs r
    CROSS APPLY (SELECT f.* FROM sprite_frames f
                 WHERE f.sprite = tv.sprite AND f.frame = tv.frame AND f.rotation IN (0, tv.wrot)
                 ORDER BY CASE WHEN f.rotation = tv.wrot THEN 0 ELSE 1 END FETCH FIRST 1 ROW ONLY) sf
    WHERE tv.depth >= 4d AND ABS(tv.side) <= tv.depth * 2d
  ) q CROSS JOIN rs r CROSS JOIN cam m CROSS JOIN wr
),
spx AS (
  SELECT /*+ MATERIALIZE */ /*+ LEADING(b x sc y) USE_NL(x sc y) INDEX_RS_ASC(x screen_x_pk) INDEX_RS_ASC(y screen_y_pk) */ b.thing_id, x.x, y.y, b.depth, b.skey, b.fuzz, b.base_light,
         ASCII(SUBSTR(sc.col, LEAST(b.height - 1, GREATEST(0, FLOOR((y.yd - b.yt) / b.scale))) + 1, 1)) - 256 AS texel
  FROM tbound b
  JOIN screen_x x ON x.x BETWEEN CAST(GREATEST(0, FLOOR(b.xl)) AS NUMBER) AND CAST(LEAST(319, CEIL(b.xr) - 1) AS NUMBER)
  JOIN screen_y y ON y.y BETWEEN CAST(GREATEST(0, FLOOR(b.yt)) AS NUMBER) AND CAST(LEAST(167, CEIL(b.yb) - 1) AS NUMBER)
  JOIN sprite_col sc ON sc.lump_name = b.lump_name
   AND sc.u = CAST(CASE WHEN b.flipped THEN b.width - 1 - LEAST(b.width - 1, GREATEST(0, FLOOR((x.xd - b.xl) / b.scale)))
                   ELSE LEAST(b.width - 1, GREATEST(0, FLOOR((x.xd - b.xl) / b.scale))) END AS NUMBER)
  WHERE b.xr > 0 AND b.xl < 320 AND b.yb > 0 AND b.yt < 168
),
spvis AS (
  -- opaque sprite texels that beat the background owner's key at that pixel
  SELECT /*+ LEADING(s f i) USE_HASH(f) USE_HASH(i) */ s.x, s.y, s.skey, s.thing_id,
         CASE WHEN mpl.slot > 1 AND s.texel BETWEEN 112 AND 127
              THEN s.texel - 112 + CASE mpl.slot WHEN 2 THEN 96 WHEN 3 THEN 64 ELSE 32 END ELSE s.texel END AS pal_idx,
         CASE WHEN s.fuzz = 1 THEN 26 + MOD(s.x * 7 + s.y * 13 + ROUND(s.depth), 5) ELSE s.base_light END AS light
  FROM spx s
  LEFT JOIN fseg f ON f.col_x = s.x AND s.y BETWEEN f.a AND f.b
  LEFT JOIN items i ON i.item_id = f.item_id
  LEFT JOIN st_mp_players mpl ON mpl.tic = :tic AND mpl.map_id = :map_id AND mpl.player_thing_id = s.thing_id
  CROSS JOIN rs r
  WHERE s.texel >= 0
    AND (i.item_id IS NULL
         OR s.skey < CASE WHEN i.kind = 1 OR i.span_sky = 1 THEN i.ckey
                          WHEN r.cy - s.y = 0 OR i.cz / (r.cy - s.y) <= r.near THEN s.skey + 1
                          ELSE ROUND(GREATEST(0d, LEAST(i.cz / (r.cy - s.y), 131071d)) * 4096d) * 17179869184 + i.pkey END)
),
-- ============================================================================================
-- WEAPON PSPRITE and the pickup MESSAGE (drawn over the view, reference order)
-- ============================================================================================
wlay AS (
  -- weapon psprite layers (<= 2 rows) with integer origin and light resolved once
  SELECT /*+ MATERIALIZE */ z.layer, z.lump_name, z.width, z.height, CAST(FLOOR(z.xl) AS NUMBER) AS xl0, CAST(FLOOR(z.yt) AS NUMBER) AS yt0,
         CASE WHEN wr.invuln = 1 THEN 32 WHEN z.fullbright THEN 0
              ELSE GREATEST(0, LEAST(31, (15 - LEAST(15, GREATEST(0, FLOOR(ps.light_level / 16d) + wr.extra_light))) * 4 - 23)) END AS light
  FROM (SELECT 1 AS layer, wr.sx - sf.left_offset AS xl,
               wr.sy - sf.top_offset + r.cy - 100d - 0.5d AS yt, sf.width, sf.height, sf.lump_name,
               NVL(wr.fullbright, FALSE) AS fullbright
        FROM wr CROSS JOIN rs r JOIN sprite_frames sf ON sf.sprite = wr.sprite AND sf.frame = wr.frame AND sf.rotation = 0
        UNION ALL
        SELECT 2, wr.sx - sf.left_offset, wr.sy - sf.top_offset + r.cy - 100d - 0.5d,
               sf.width, sf.height, sf.lump_name, NVL(wr.flash_fullbright, TRUE)
        FROM wr CROSS JOIN rs r JOIN sprite_frames sf ON sf.sprite = wr.flash_sprite AND sf.frame = wr.flash_frame AND sf.rotation = 0
        WHERE wr.flash_sprite IS NOT NULL AND wr.flash_frame IS NOT NULL) z
  CROSS JOIN wr CROSS JOIN player_sector ps
),
pspx AS (
  -- x = xl0 + u straight from the sprite columns (no screen_x probe per texel column)
  SELECT /*+ LEADING(l sc y) USE_NL(sc) USE_NL(y) INDEX_RS_ASC(y screen_y_pk) */
         l.layer, l.xl0 + sc.u AS x, y.y, l.light,
         ASCII(SUBSTR(sc.col, y.y - l.yt0 + 1, 1)) - 256 AS texel
  FROM wlay l
  JOIN sprite_col sc ON sc.lump_name = l.lump_name AND sc.u BETWEEN GREATEST(0, -l.xl0) AND LEAST(l.width - 1, 319 - l.xl0)
  JOIN screen_y y ON y.y BETWEEN GREATEST(0, l.yt0) AND LEAST(167, l.yt0 + l.height - 1)
),
msg AS (
  SELECT g.pos, g.ch,
         CASE WHEN g.ch = ' ' THEN NULL ELSE 'STCFN' || LPAD(TO_CHAR(ASCII(g.ch)), 3, '0') END AS patch,
         SUM(CASE WHEN g.ch = ' ' THEN 4 ELSE NVL(up.width, 4) END)
           OVER (ORDER BY g.pos ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS pen
  FROM (SELECT d.x + 1 AS pos, SUBSTR(UPPER(pu.message), d.x + 1, 1) AS ch
        FROM player_ui_state pu JOIN screen_x d ON d.x < LENGTH(pu.message)
        WHERE pu.message IS NOT NULL AND pu.message_tics > 0) g
  LEFT JOIN ui_patches up ON up.name = 'STCFN' || LPAD(TO_CHAR(ASCII(g.ch)), 3, '0')
),
ov AS (
  -- per covered pixel: message > weapon > nearest visible sprite
  SELECT x, y, MAX(val) KEEP (DENSE_RANK LAST ORDER BY prio) AS val
  FROM (
    SELECT s.x, s.y, 1 AS prio, MIN(cm.mapped) KEEP (DENSE_RANK FIRST ORDER BY s.skey, s.light, s.pal_idx) AS val
    FROM spvis s JOIN cmap cm ON cm.light = s.light AND cm.idx = s.pal_idx
    GROUP BY s.x, s.y
    UNION ALL
    SELECT /*+ LEADING(p cm) USE_HASH(cm) */ p.x, p.y, 2, MAX(cm.mapped) KEEP (DENSE_RANK LAST ORDER BY p.layer)
    FROM pspx p JOIN cmap cm ON cm.light = p.light AND cm.idx = p.texel
    WHERE p.texel >= 0
    GROUP BY p.x, p.y
    UNION ALL
    SELECT NVL(m.pen, 0) + px.dx, 1 + px.dy, 3, cm.mapped
    FROM msg m JOIN ui_hud_pixels px ON px.name = m.patch
    JOIN cmap cm ON cm.light = 0 AND cm.idx = px.palette_index
    WHERE m.patch IS NOT NULL AND NVL(m.pen, 0) + px.dx BETWEEN 0 AND 319 AND 1 + px.dy BETWEEN 0 AND 167
  )
  GROUP BY x, y
),
-- ============================================================================================
-- FRAMEBUFFER: order-free packing, 15 palette indices per exact NUMBER (base 256)
-- ============================================================================================
packed AS (
  SELECT /*+ LEADING(b) USE_HASH(o) SWAP_JOIN_INPUTS(o) */ b.y, b.chunk, NVL(o.val, b.v) * b.w AS v
  FROM bg b LEFT JOIN ov o ON o.x = b.x AND o.y = b.y
  UNION ALL
  -- overlay pixels over holes (pixels no final segment owns)
  SELECT o.y, sx.chunk, o.val * sx.w
  FROM ov o JOIN screen_x sx ON sx.x = o.x
  WHERE NOT EXISTS (SELECT 1 FROM fseg f WHERE f.col_x = o.x AND o.y BETWEEN f.a AND f.b)
  UNION ALL SELECT y, chunk, v FROM hud_static_packed
  UNION ALL SELECT y, chunk, v FROM hud_delta
)
SELECT /*+ OPT_PARAM('_optimizer_use_feedback' 'false') OPT_PARAM('optimizer_adaptive_plans' 'false') */
       p.y, (SELECT pal FROM active_palette) AS pal, p.chunk, SUM(p.v) AS v
FROM packed p
GROUP BY p.y, p.chunk
