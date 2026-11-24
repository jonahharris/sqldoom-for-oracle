-- Load-time precomputation for the optimized renderer. Static WAD/map data only: nothing here
-- depends on a camera pose, a tic, or a rendered frame. Re-runnable.
-- Texture strings are filled by client/precompute_textures.py (see its header for the encoding).

-- ---------------------------------------------------------------------------------------------
-- Screen dimensions: persistent, tiny, with exact statistics (H10).
--   chunk / w: framebuffer packing -- pixel x contributes idx * 256^(x mod 15) to NUMBER chunk
--   x div 15 of its row, so a row is 22 exact 38-digit NUMBERs built by an order-free SUM.
DROP TABLE IF EXISTS screen_x PURGE;
CREATE TABLE screen_x (
  x     NUMBER(3) NOT NULL,
  chunk NUMBER(2) NOT NULL,
  w     NUMBER    NOT NULL,
  xd    BINARY_DOUBLE NOT NULL,
  ta    BINARY_DOUBLE NOT NULL,   -- (x - cx) / focal: tangent of the column's ray angle (static)
  CONSTRAINT screen_x_pk PRIMARY KEY (x)
) ORGANIZATION INDEX;
INSERT INTO screen_x SELECT level-1, TRUNC((level-1)/15), POWER(256, MOD(level-1, 15)), level-1,
  (TO_BINARY_DOUBLE(level-1) - 160d) / (160d / TAN(90d * (3.14159265358979323846d / 180d) / 2d))
FROM dual CONNECT BY level <= 320;

DROP TABLE IF EXISTS screen_y PURGE;
CREATE TABLE screen_y (
  y  NUMBER(3) NOT NULL,
  yd BINARY_DOUBLE NOT NULL,
  dy BINARY_DOUBLE NOT NULL,      -- cy - y: plane depth = focal*(z - pz) / dy (static)
  CONSTRAINT screen_y_pk PRIMARY KEY (y)
) ORGANIZATION INDEX;
INSERT INTO screen_y SELECT level-1, level-1, 84d - (level-1) FROM dual CONNECT BY level <= 200;

-- ---------------------------------------------------------------------------------------------
-- BSP order as order statistics (H2). For a leaf L and each ancestor step (node, side):
--   rank(L) = 1 + SUM over steps of [side <> front_side(node)] * leaves(node, front child)
-- leaves(node, side) is static, so per frame the rank is one SUM over the path rows: no path
-- key, no bit shifts, no depth limit, no ROW_NUMBER sort.
DROP TABLE IF EXISTS bsp_steps PURGE;
CREATE TABLE bsp_steps (
  map_id     NUMBER(5) NOT NULL,
  ssector_id NUMBER(6) NOT NULL,
  depth      NUMBER(3) NOT NULL,
  node_id    NUMBER(6) NOT NULL,
  side       CHAR(1)   NOT NULL,
  sib_leaves NUMBER(6) NOT NULL,   -- leaves under the OTHER child of node_id
  CONSTRAINT bsp_steps_pk PRIMARY KEY (map_id, ssector_id, depth)
);
INSERT INTO bsp_steps (map_id, ssector_id, depth, node_id, side, sib_leaves)
WITH leaves AS (
  SELECT map_id, node_id, side, COUNT(*) AS n FROM node_path_steps GROUP BY map_id, node_id, side
)
SELECT s.map_id, s.ssector_id, s.depth, s.node_id, s.side, NVL(o.n, 0)
FROM node_path_steps s
LEFT JOIN leaves o ON o.map_id = s.map_id AND o.node_id = s.node_id
                  AND o.side = CASE s.side WHEN 'L' THEN 'R' ELSE 'L' END;

-- ---------------------------------------------------------------------------------------------
-- Texture strings (filled by client/precompute_textures.py)
DROP TABLE IF EXISTS tex_dim PURGE;
CREATE TABLE tex_dim (
  tex_id NUMBER(5) NOT NULL, name VARCHAR2(8) NOT NULL, width NUMBER(4) NOT NULL, height NUMBER(4) NOT NULL,
  CONSTRAINT tex_dim_pk PRIMARY KEY (tex_id), CONSTRAINT tex_dim_uk UNIQUE (name));

DROP TABLE IF EXISTS texcol_lit PURGE;
CREATE TABLE texcol_lit (
  tex_id NUMBER(5) NOT NULL, u NUMBER(4) NOT NULL, light NUMBER(2) NOT NULL,
  col NVARCHAR2(512) NOT NULL,
  CONSTRAINT texcol_lit_pk PRIMARY KEY (tex_id, u, light)
) ORGANIZATION INDEX COMPRESS 2 OVERFLOW;

DROP TABLE IF EXISTS flat_dim PURGE;
CREATE TABLE flat_dim (
  flat_id NUMBER(5) NOT NULL, name VARCHAR2(8) NOT NULL,
  CONSTRAINT flat_dim_pk PRIMARY KEY (flat_id), CONSTRAINT flat_dim_uk UNIQUE (name));

DROP TABLE IF EXISTS flat_lit PURGE;
CREATE TABLE flat_lit (
  flat_id NUMBER(5) NOT NULL, light NUMBER(2) NOT NULL, q NUMBER(1) NOT NULL,
  s NVARCHAR2(1024) NOT NULL,
  CONSTRAINT flat_lit_pk PRIMARY KEY (flat_id, light, q)
) ORGANIZATION INDEX OVERFLOW;

DROP TABLE IF EXISTS colormap_row PURGE;
CREATE TABLE colormap_row (
  light NUMBER(2) NOT NULL, s NVARCHAR2(256) NOT NULL,
  CONSTRAINT colormap_row_pk PRIMARY KEY (light));

DROP TABLE IF EXISTS sprite_col PURGE;
CREATE TABLE sprite_col (
  lump_name VARCHAR2(8) NOT NULL, u NUMBER(4) NOT NULL, height NUMBER(4) NOT NULL,
  col NVARCHAR2(512) NOT NULL,
  CONSTRAINT sprite_col_pk PRIMARY KEY (lump_name, u)
) ORGANIZATION INDEX OVERFLOW;
-- statistics: gathered by client/precompute_textures.py

-- ---------------------------------------------------------------------------------------------
-- Status bar background, packed (rows 168..199). The reference composites ui_static_pixels
-- (STBAR + fixed patches) under the dynamic patches every frame; the background is static, so
-- it is packed here once: v = SUM(mapped_index(level 0) * 256^(x mod 15)) per (y, x div 15).
-- Per frame only the dynamic overlay pixels contribute (new - background) * 256^(x mod 15).
DROP TABLE IF EXISTS hud_static_packed PURGE;
CREATE TABLE hud_static_packed (
  y NUMBER(3) NOT NULL, chunk NUMBER(2) NOT NULL, v NUMBER NOT NULL,
  CONSTRAINT hud_static_packed_pk PRIMARY KEY (y, chunk)
) ORGANIZATION INDEX;
INSERT INTO hud_static_packed (y, chunk, v)
SELECT s.y, sx.chunk, SUM(cm.mapped_index * sx.w)
FROM ui_static_pixels s
JOIN colormap_rgb cm ON cm.pal = 0 AND cm.light_level = 0 AND cm.palette_index = s.palette_index
JOIN screen_x sx ON sx.x = s.x
GROUP BY s.y, sx.chunk;

-- per-pixel background index, for overlay deltas
DROP TABLE IF EXISTS hud_static_idx PURGE;
CREATE TABLE hud_static_idx (
  x NUMBER(3) NOT NULL, y NUMBER(3) NOT NULL, idx NUMBER(3) NOT NULL,
  CONSTRAINT hud_static_idx_pk PRIMARY KEY (x, y)
) ORGANIZATION INDEX;
INSERT INTO hud_static_idx (x, y, idx)
SELECT s.x, s.y, cm.mapped_index
FROM ui_static_pixels s
JOIN colormap_rgb cm ON cm.pal = 0 AND cm.light_level = 0 AND cm.palette_index = s.palette_index;

-- COLORMAP as a plain lookup (light, palette index) -> mapped index, pal 0
DROP TABLE IF EXISTS cmap PURGE;
CREATE TABLE cmap (
  light NUMBER(2) NOT NULL, idx NUMBER(3) NOT NULL, mapped NUMBER(3) NOT NULL,
  CONSTRAINT cmap_pk PRIMARY KEY (light, idx)
) ORGANIZATION INDEX;
INSERT INTO cmap SELECT light_level, palette_index, mapped_index FROM colormap_rgb WHERE pal = 0;

-- ---------------------------------------------------------------------------------------------
-- Per-seg static renderer row: render_segs + linedef scroll flag + resolved texture ids/dims.
-- Dynamic values (sector heights, light, switch textures) still come from st_* per frame.
DROP TABLE IF EXISTS render_segs_ext PURGE;
CREATE TABLE render_segs_ext (
  map_id NUMBER(5) NOT NULL, seg_id NUMBER(6) NOT NULL, ssector_id NUMBER(6) NOT NULL,
  x1 NUMBER(6) NOT NULL, y1 NUMBER(6) NOT NULL, x2 NUMBER(6) NOT NULL, y2 NUMBER(6) NOT NULL,
  seg_u1 BINARY_DOUBLE NOT NULL, seg_u2 BINARY_DOUBLE NOT NULL,
  fsec NUMBER(6) NOT NULL, bsec NUMBER(6), x_offset NUMBER(6) NOT NULL, y_offset NUMBER(6) NOT NULL,
  upper_tex VARCHAR2(8), mid_tex VARCHAR2(8), lower_tex VARCHAR2(8),
  peg_bottom NUMBER(1) NOT NULL,   -- flags & 16 (ML_DONTPEGBOTTOM)
  peg_top NUMBER(1) NOT NULL,      -- flags & 8  (ML_DONTPEGTOP)
  light_bias NUMBER(2) NOT NULL, scrolls NUMBER(1) NOT NULL,
  CONSTRAINT render_segs_ext_pk PRIMARY KEY (map_id, seg_id)
);
INSERT INTO render_segs_ext
SELECT s.map_id, s.seg_id, s.ssector_id, s.x1, s.y1, s.x2, s.y2, s.seg_u1, s.seg_u2, s.fsec, s.bsec,
       s.x_offset, s.y_offset, s.upper_tex, s.mid_tex, s.lower_tex,
       CASE WHEN BITAND(s.flags, 16) <> 0 THEN 1 ELSE 0 END, CASE WHEN BITAND(s.flags, 8) <> 0 THEN 1 ELSE 0 END,
       s.light_bias, CASE WHEN ld.scrolls THEN 1 ELSE 0 END
FROM render_segs s JOIN linedefs ld ON ld.map_id = s.map_id AND ld.id = s.linedef_id;

-- The 7 wall parts of the reference unpivot (pcode = stable-id code, clip = clip-only boundary)
DROP TABLE IF EXISTS wall_part_kind PURGE;
CREATE TABLE wall_part_kind (part VARCHAR2(12) NOT NULL, pcode NUMBER(1) NOT NULL,
  CONSTRAINT wall_part_kind_pk PRIMARY KEY (part));
INSERT INTO wall_part_kind VALUES ('solid', 0), ('upper', 1), ('upper_open', 7), ('upper_flush', 7),
  ('lower', 2), ('lower_down', 3), ('midmask', 7);
