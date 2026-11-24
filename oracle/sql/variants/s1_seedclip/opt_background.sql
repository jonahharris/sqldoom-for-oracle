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
  SELECT p.*,
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
seedb AS (
  -- per column: first row of the camera-sector floor seed, last row of its ceiling seed
  SELECT x.x AS col_x,
         CASE WHEN n.fd IS NULL THEN FLOOR(r.cy) + 1
              ELSE FLOOR(LEAST(167d, GREATEST(0d, r.cy - r.focal * (ps.floor_height - m.pz) / n.fd))) + 1 END AS fy0,
         CASE WHEN n.cd IS NULL THEN CEIL(r.cy) - 1
              ELSE CEIL(LEAST(167d, GREATEST(0d, r.cy - r.focal * (ps.ceil_height - m.pz) / n.cd))) - 1 END AS cy1
  FROM screen_x x CROSS JOIN rs r CROSS JOIN cam m CROSS JOIN player_sector ps
  LEFT JOIN (SELECT col_x, MIN(near_floor_depth) AS fd, MIN(near_ceil_depth) AS cd FROM pclip GROUP BY col_x) n ON n.col_x = x.x
  WHERE x.x < 320
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
  SELECT sb.col_x, ps.id, ps.floor_height, ps.light_level, 0, 0, 0, sb.fy0, 167
  FROM seedb sb CROSS JOIN player_sector ps
  UNION ALL
  SELECT sb.col_x, ps.id, ps.ceil_height, ps.light_level, CASE WHEN ps.ceil_tex = 'F_SKY1' THEN 1 ELSE 0 END, 1, 0,
         0, sb.cy1
  FROM seedb sb CROSS JOIN player_sector ps
),
pspan AS (
  -- keep spans whose plane faces the camera; collapse identical spans (reference dedup).
  -- Panel spans of the camera sector's own floor/ceiling are clipped against the seed span of
  -- their column: same sector and height => same depth key per pixel, and the seed's src 0
  -- beats src 1, so the panel span can never own the overlap (hybrid h20).
  SELECT s.col_x, s.sector_id, s.plane_z, s.plane, s.is_sky, CAST(s.y0 AS NUMBER) AS y0, CAST(s.y1 AS NUMBER) AS y1,
         MIN(s.sector_light) AS sector_light, MIN(s.src) AS src
  FROM (SELECT t.col_x, t.sector_id, t.plane_z, t.plane, t.is_sky, t.sector_light, t.src,
               CASE WHEN t.src = 1 AND t.plane = 1 AND t.sector_id = ps.id AND t.plane_z = ps.ceil_height
                    THEN GREATEST(t.y0, sb.cy1 + 1) ELSE t.y0 END AS y0,
               CASE WHEN t.src = 1 AND t.plane = 0 AND t.sector_id = ps.id AND t.plane_z = ps.floor_height
                    THEN LEAST(t.y1, sb.fy0 - 1) ELSE t.y1 END AS y1
        FROM pspan_raw t JOIN seedb sb ON sb.col_x = t.col_x CROSS JOIN player_sector ps) s
  CROSS JOIN cam m
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
  SELECT ROWNUM AS item_id, i.* FROM (
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
  SELECT e.col_x, e.a, e.b,
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
  SELECT col_x, a, b, CASE WHEN nplanes = 0 THEN best_const ELSE any_item END AS item_id
  FROM segcls WHERE n = 1 OR (n >= 2 AND nplanes = 0)
  UNION ALL
  SELECT col_x, y, y, item_id FROM contested
),
