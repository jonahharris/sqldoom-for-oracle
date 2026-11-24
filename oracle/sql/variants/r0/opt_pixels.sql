-- ============================================================================================
-- BACKGROUND PIXELS: exactly one row per owned pixel; texel and COLORMAP come from pre-lit
-- NVARCHAR2 strings (palette index i = U+0100+i), all addressing in BINARY_DOUBLE.
-- ============================================================================================
pitems AS (
  -- plane item attributes resolved once per item, not per pixel
  SELECT i.item_id, i.cz, i.span_sky, fd.flat_id, c.px, c.py, c.cv, c.sv, wr.invuln,
         CASE WHEN (CASE WHEN i.plane = 0 THEN s.floor_tex ELSE s.ceil_tex END) = 'F_SKY1' THEN 1 ELSE 0 END AS tex_sky,
         TO_BINARY_DOUBLE((15 - LEAST(15, GREATEST(0, FLOOR(i.sector_light / 16d) + wr.extra_light))) * 4) AS lbase
  FROM items i
  JOIN secl s ON s.id = i.sector_id
  LEFT JOIN flat_dim fd ON fd.name = CASE WHEN i.plane = 0 THEN s.floor_tex ELSE s.ceil_tex END
  CROSS JOIN wr CROSS JOIN cam c
  WHERE i.kind = 2
),
witems AS (
  -- wall items with their pre-lit texture column (one indexed lookup per item)
  SELECT /*+ USE_NL(t) INDEX(t texcol_lit_pk) */ i.item_id, t.col, i.v0, i.v_step, TO_BINARY_DOUBLE(i.y_start) AS ys,
         TO_BINARY_DOUBLE(i.tex_h) AS th
  FROM items i
  JOIN texcol_lit t ON t.tex_id = i.tex_id AND t.u = CAST(i.u_i AS NUMBER) AND t.light = CAST(i.light AS NUMBER)
  WHERE i.kind = 1
),
flused AS (
  -- only the lit flat strings of flats visible this frame; keys in BINARY_DOUBLE for the per-pixel join
  SELECT fl.flat_id, TO_BINARY_DOUBLE(fl.light) AS light, TO_BINARY_DOUBLE(fl.q) AS q, fl.s
  FROM flat_lit fl WHERE fl.flat_id IN (SELECT flat_id FROM pitems)
),
skycol AS (
  -- sky: u from the ray angle of the screen column, light 0 (reference plane_uv)
  SELECT x.x, t.col
  FROM screen_x x CROSS JOIN cam c CROSS JOIN rs r
  JOIN maps mp ON mp.map_id = :map_id
  JOIN tex_dim td ON td.name = mp.sky_texture
  JOIN texcol_lit t ON t.tex_id = td.tex_id AND t.light = 0
   AND t.u = CAST(MOD(MOD(FLOOR(((c.vr - ATAN((x.xd - r.cx) / r.focal)) / (3.14159265358979323846d / 180d)) * (256d / 90d)), 256) + 256, 256) AS NUMBER)
),
fsegw AS (
  -- final segments with the packing weight of their column (once per segment, not per pixel)
  SELECT f.col_x, f.a, f.b, f.item_id, sx.chunk, sx.w, sx.ta
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
  -- flats: plane point per pixel, zlight per pixel, lit flat quarter string by hash join
  SELECT /*+ LEADING(q fl) USE_HASH(fl) */ q.x, q.y, q.chunk, q.w,
         CASE WHEN q.valid = 1 THEN ASCII(SUBSTR(fl.s, (q.tv - 16d * FLOOR(q.tv * 0.0625d)) * 64d + q.tu + 1d, 1)) - 256 ELSE 0 END AS v
  FROM (
    SELECT /*+ NO_MERGE */ z.x, z.y, z.chunk, z.w, z.flat_id, z.valid,
           FLOOR(z.wy) - 64d * FLOOR(z.wy * 0.015625d) AS tv,
           FLOOR(z.wx) - 64d * FLOOR(z.wx * 0.015625d) AS tu,
           CASE WHEN z.invuln = 1 THEN 32d
                ELSE GREATEST(0d, LEAST(31d, z.lbase - FLOOR(80d / (LEAST(127d, FLOOR(z.depth / 16d)) + 1d)))) END AS light
    FROM (
      SELECT /*+ NO_MERGE */ d.x, d.y, d.chunk, d.w, d.flat_id, d.lbase, d.invuln, d.depth,
             d.px + d.depth * d.cv + (d.ta * d.depth) * d.sv AS wx, d.py + d.depth * d.sv - (d.ta * d.depth) * d.cv AS wy,
             CASE WHEN d.dy <> 0d AND d.depth > 1d / 1000d THEN 1 ELSE 0 END AS valid
      FROM (
        SELECT /*+ NO_MERGE LEADING(p f y) USE_HASH(f) USE_NL(y) INDEX_RS_ASC(y screen_y_pk) */
               f.col_x AS x, y.y, f.chunk, f.w, f.ta, y.dy, p.flat_id, p.lbase, p.invuln, p.px, p.py, p.cv, p.sv,
               CASE WHEN y.dy <> 0d THEN p.cz / y.dy ELSE 0d END AS depth
        FROM pitems p
        JOIN fsegw f ON f.item_id = p.item_id
        JOIN screen_y y ON y.y BETWEEN f.a AND f.b
        WHERE p.tex_sky = 0) d
    ) z
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
  SELECT q.*,
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
  SELECT /*+ LEADING(b x sc y) USE_NL(x sc y) INDEX_RS_ASC(x screen_x_pk) INDEX_RS_ASC(y screen_y_pk) */ b.thing_id, x.x, y.y, b.depth, b.skey, b.fuzz, b.base_light,
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
pspx AS (
  SELECT l.layer, x.x, y.y,
         ASCII(SUBSTR(sc.col, y.y - FLOOR(l.yt) + 1, 1)) - 256 AS texel,
         CASE WHEN wr.invuln = 1 THEN 32 WHEN l.fullbright THEN 0
              ELSE GREATEST(0, LEAST(31, (15 - LEAST(15, GREATEST(0, FLOOR(ps.light_level / 16d) + wr.extra_light))) * 4 - 23)) END AS light
  FROM (SELECT 1 AS layer, wr.sprite, wr.frame, wr.sx - sf.left_offset AS xl,
               wr.sy - sf.top_offset + r.cy - 100d - 0.5d AS yt, sf.width, sf.height, sf.lump_name,
               NVL(wr.fullbright, FALSE) AS fullbright
        FROM wr CROSS JOIN rs r JOIN sprite_frames sf ON sf.sprite = wr.sprite AND sf.frame = wr.frame AND sf.rotation = 0
        UNION ALL
        SELECT 2, wr.flash_sprite, wr.flash_frame, wr.sx - sf.left_offset, wr.sy - sf.top_offset + r.cy - 100d - 0.5d,
               sf.width, sf.height, sf.lump_name, NVL(wr.flash_fullbright, TRUE)
        FROM wr CROSS JOIN rs r JOIN sprite_frames sf ON sf.sprite = wr.flash_sprite AND sf.frame = wr.flash_frame AND sf.rotation = 0
        WHERE wr.flash_sprite IS NOT NULL AND wr.flash_frame IS NOT NULL) l
  JOIN screen_x x ON x.x BETWEEN CAST(GREATEST(0, FLOOR(l.xl)) AS NUMBER) AND CAST(LEAST(319, FLOOR(l.xl) + l.width - 1) AS NUMBER)
  JOIN screen_y y ON y.y BETWEEN CAST(GREATEST(0, FLOOR(l.yt)) AS NUMBER) AND CAST(LEAST(167, FLOOR(l.yt) + l.height - 1) AS NUMBER)
  JOIN sprite_col sc ON sc.lump_name = l.lump_name AND sc.u = x.x - CAST(FLOOR(l.xl) AS NUMBER)
  CROSS JOIN wr CROSS JOIN player_sector ps
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
    SELECT p.x, p.y, 2, MAX(cm.mapped) KEEP (DENSE_RANK LAST ORDER BY p.layer)
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
