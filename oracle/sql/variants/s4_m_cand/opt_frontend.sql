-- ============================================================================================
-- FRAME CONSTANTS AND STATE  (one row each; every per-row expression reuses them)
-- ============================================================================================
rs AS (
  SELECT 320 AS screen_w, 168 AS screen_h, 160d AS cx, 84d AS cy,
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
  SELECT p.px, p.py, p.pz, p.pa * (3.14159265358979323846d / 180d) AS vr,
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
  SELECT s.id, s.floor_height, s.ceil_height, s.floor_tex, s.ceil_tex,
         NVL(a.light_level, s.light_level) AS light_level
  FROM st_sectors s LEFT JOIN alight a ON a.sector_id = s.id
  WHERE s.tic = :tic AND s.map_id = :map_id
),
wr AS (
  -- weapon runtime: psprite frames, extralight, invulnerability colormap
  SELECT NVL(w.sx, 1d) AS sx, NVL(w.sy, 32d) AS sy,
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
  SELECT nc.node_id, nc.side,
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
  SELECT n.id AS node_id,
         CASE WHEN ROUND(c.px - n.x) * n.dy - ROUND(c.py - n.y) * n.dx > 0 THEN 'R' ELSE 'L' END AS front
  FROM nodes n CROSS JOIN cam c WHERE n.map_id = :map_id
),
bsp AS (
  SELECT st.ssector_id,
         1 + SUM(CASE WHEN st.side <> nf.front THEN st.sib_leaves ELSE 0 END) AS bsp_seq
  FROM bsp_steps st
  JOIN nfront nf ON nf.node_id = st.node_id
  JOIN vchild vc ON vc.node_id = st.node_id AND vc.side = st.side
  WHERE st.map_id = :map_id
  GROUP BY st.ssector_id
  HAVING MIN(vc.keep) = 1
),
player_sector AS (
  SELECT s.id, s.floor_height, s.ceil_height, s.ceil_tex, s.light_level
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
  SELECT p.seg_id, p.bsp_seq, p.sx1, p.sx2, p.invx1, p.invx2,
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
  SELECT h.seg_id, h.bsp_seq, h.sx1, h.sx2, h.invx1, h.invx2, h.fsec, h.y_offset, h.light_bias,
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
  SELECT x.x AS col_x, MIN(h.bsp_seq) AS min_bsp_seq
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
  SELECT c.seg_id, c.part, c.pcode, c.tex, c.bsp_seq, c.fsec, c.f_floor, c.f_ceil, c.f_ceil_tex, c.f_light,
         c.light_bias, c.y_offset, c.v_anchor_base, c.add_h, c.col_x, c.tex_id, c.tex_w, c.tex_h, c.invx,
         1d / c.invx AS depth_x, c.u_over_x / NULLIF(c.invx, 1d / 1000000d) AS u_col, r.focal * c.invx AS scale,
         r.cy - (r.focal * c.invx) * (c.z_top - m.pz) AS y_top_f, r.cy - (r.focal * c.invx) * (c.z_bot - m.pz) AS y_bot_f
  FROM wcol c CROSS JOIN rs r CROSS JOIN cam m
),
