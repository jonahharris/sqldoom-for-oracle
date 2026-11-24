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
)
