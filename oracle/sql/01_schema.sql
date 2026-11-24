-- =============================================================================
-- 01_schema.sql -- Oracle 26ai static/derived data layer for the SQL Doom renderer
--
-- Mirrors the tables reference/sqldoom/sql/schema.sql (CedarDB SQLDoom) defines
-- that reference/sqldoom/sql/renderer.sql reads, plus the inputs needed to derive
-- them (segs, ssectors, vertexes, sidedefs, line_special_defs).
-- Re-runnable: every table is dropped (IF EXISTS ... PURGE) and recreated.
--
-- Type mapping (reference -> Oracle):
--   SMALLINT -> NUMBER(5), INT -> NUMBER(10), BIGINT -> NUMBER(19)
--   REAL / DOUBLE PRECISION -> BINARY_DOUBLE (float4 values widen exactly)
--   NUMERIC(4,1) -> NUMBER(4,1)
--   BOOLEAN -> BOOLEAN (23ai native)
--   VARCHAR(n)/CHAR(n) -> VARCHAR2(n)/CHAR(n); TEXT -> VARCHAR2(n) sized to data
--   enum types (weapon_state, actor_state, projectile_kind, ...) -> VARCHAR2
--   BYTEA -> BLOB (pixel arrays exceed RAW(2000)); colormap rgb -> RAW(3)
--   materialized views node_path_steps, ui_hud_pixels, ui_static_pixels ->
--   plain tables filled by the loader (natural primary keys added).
--
-- Renames (Oracle reserved words):
--   colormap_rgb.level -> colormap_rgb.light_level
--
-- Omitted from the reference: foreign keys (no renderer semantics), the wads
-- table (maps.wad_id is kept as a plain column), audio/menu/runtime tables.
-- Empty-string texture names: the reference loader already maps an empty
-- 8-byte name to NULL (_nullable_tex), so Oracle's ''-is-NULL rule changes
-- nothing; the '-' "no texture" marker is stored verbatim.
-- =============================================================================

-- ----------------------------------------------------------------- map geometry
DROP TABLE IF EXISTS maps PURGE;
CREATE TABLE maps (
  map_id        NUMBER(10)   NOT NULL,
  wad_id        NUMBER(10),
  name          VARCHAR2(8)  NOT NULL,
  sky_texture   VARCHAR2(8),
  CONSTRAINT maps_pk PRIMARY KEY (map_id)
);

DROP TABLE IF EXISTS vertexes PURGE;
CREATE TABLE vertexes (
  id            NUMBER(10) NOT NULL,
  map_id        NUMBER(10) NOT NULL,
  x             NUMBER(5)  NOT NULL,
  y             NUMBER(5)  NOT NULL,
  CONSTRAINT vertexes_pk PRIMARY KEY (map_id, id)
);

DROP TABLE IF EXISTS sectors PURGE;
CREATE TABLE sectors (
  id                 NUMBER(10)  NOT NULL,
  map_id             NUMBER(10)  NOT NULL,
  floor_height       NUMBER(5)   NOT NULL,
  ceil_height        NUMBER(5)   NOT NULL,
  spawn_floor_height NUMBER(5)   NOT NULL,
  spawn_ceil_height  NUMBER(5)   NOT NULL,
  spawn_floor_tex    VARCHAR2(8) NOT NULL,
  spawn_light_level  NUMBER(5)   NOT NULL,
  floor_tex          VARCHAR2(8) NOT NULL,
  ceil_tex           VARCHAR2(8) NOT NULL,
  light_level        NUMBER(5)   NOT NULL,
  special            NUMBER(10)  NOT NULL,
  tag                NUMBER(10)  NOT NULL,
  CONSTRAINT sectors_pk PRIMARY KEY (map_id, id)
);

DROP TABLE IF EXISTS sidedefs PURGE;
CREATE TABLE sidedefs (
  id            NUMBER(10)  NOT NULL,
  map_id        NUMBER(10)  NOT NULL,
  x_offset      NUMBER(5)   NOT NULL,
  y_offset      NUMBER(5)   NOT NULL,
  upper_tex     VARCHAR2(8) NOT NULL,
  lower_tex     VARCHAR2(8) NOT NULL,
  mid_tex       VARCHAR2(8) NOT NULL,
  sector_id     NUMBER(10)  NOT NULL,
  CONSTRAINT sidedefs_pk PRIMARY KEY (map_id, id)
);

DROP TABLE IF EXISTS linedefs PURGE;
CREATE TABLE linedefs (
  id                NUMBER(10) NOT NULL,
  map_id            NUMBER(10) NOT NULL,
  v1_id             NUMBER(10) NOT NULL,
  v2_id             NUMBER(10) NOT NULL,
  flags             NUMBER(10) NOT NULL,
  special           NUMBER(10) NOT NULL,
  tag               NUMBER(10) NOT NULL,
  right_sd_id       NUMBER(10) NOT NULL,   -- -1 = no side
  left_sd_id        NUMBER(10) NOT NULL,   -- -1 = no side
  cross_activated   BOOLEAN DEFAULT FALSE NOT NULL,
  cross_once        BOOLEAN DEFAULT FALSE NOT NULL,
  monster_crossable BOOLEAN DEFAULT FALSE NOT NULL,
  scrolls           BOOLEAN DEFAULT FALSE NOT NULL,  -- stamped from line_special_defs
  CONSTRAINT linedefs_pk PRIMARY KEY (map_id, id)
);

DROP TABLE IF EXISTS things PURGE;
CREATE TABLE things (
  id            NUMBER(10)    NOT NULL,
  map_id        NUMBER(10)    NOT NULL,
  x             BINARY_DOUBLE NOT NULL,
  y             BINARY_DOUBLE NOT NULL,
  z             BINARY_DOUBLE DEFAULT 41 NOT NULL,
  angle         BINARY_DOUBLE NOT NULL,
  spawn_x       NUMBER(5)     NOT NULL,
  spawn_y       NUMBER(5)     NOT NULL,
  spawn_angle   NUMBER(5)     NOT NULL,
  mom_x         BINARY_DOUBLE DEFAULT 0 NOT NULL,
  mom_y         BINARY_DOUBLE DEFAULT 0 NOT NULL,
  type          NUMBER(10)    NOT NULL,
  flags         NUMBER(10)    NOT NULL,
  CONSTRAINT things_pk PRIMARY KEY (map_id, id)
);

DROP TABLE IF EXISTS segs PURGE;
CREATE TABLE segs (
  id            NUMBER(10) NOT NULL,
  map_id        NUMBER(10) NOT NULL,
  v1_id         NUMBER(10) NOT NULL,
  v2_id         NUMBER(10) NOT NULL,
  angle         NUMBER(5)  NOT NULL,
  linedef_id    NUMBER(10) NOT NULL,
  direction     NUMBER(5)  NOT NULL,  -- 0=normal, 1=reversed
  offs          NUMBER(5)  NOT NULL,
  CONSTRAINT segs_pk PRIMARY KEY (map_id, id)
);

DROP TABLE IF EXISTS ssectors PURGE;
CREATE TABLE ssectors (
  id            NUMBER(10) NOT NULL,
  map_id        NUMBER(10) NOT NULL,
  seg_count     NUMBER(5)  NOT NULL,
  first_seg_id  NUMBER(5)  NOT NULL,
  CONSTRAINT ssectors_pk PRIMARY KEY (map_id, id)
);

DROP TABLE IF EXISTS nodes PURGE;
CREATE TABLE nodes (
  id     NUMBER(10) NOT NULL,
  map_id NUMBER(10) NOT NULL,
  x      NUMBER(5),
  y      NUMBER(5),
  dx     NUMBER(5),
  dy     NUMBER(5),
  CONSTRAINT nodes_pk PRIMARY KEY (map_id, id)
);

DROP TABLE IF EXISTS node_children PURGE;
CREATE TABLE node_children (
  map_id           NUMBER(10)  NOT NULL,
  node_id          NUMBER(10)  NOT NULL,
  side             CHAR(1)     NOT NULL,  -- 'R' / 'L'
  child_kind       VARCHAR2(7) NOT NULL,  -- enum bsp_child: 'NODE' / 'SSECTOR'
  child_node_id    NUMBER(10),
  child_ssector_id NUMBER(10),
  bbox_top         NUMBER(5),
  bbox_bottom      NUMBER(5),
  bbox_left        NUMBER(5),
  bbox_right       NUMBER(5),
  CONSTRAINT node_children_pk PRIMARY KEY (map_id, node_id, side)
);

-- Reference: materialized view. Every subsector's path from the BSP root.
DROP TABLE IF EXISTS node_path_steps PURGE;
CREATE TABLE node_path_steps (
  map_id     NUMBER(10) NOT NULL,
  ssector_id NUMBER(10) NOT NULL,
  depth      NUMBER(10) NOT NULL,
  node_id    NUMBER(10) NOT NULL,
  side       CHAR(1)    NOT NULL,
  CONSTRAINT node_path_steps_pk PRIMARY KEY (map_id, ssector_id, depth)
);

-- ------------------------------------------------------------ renderer caches
DROP TABLE IF EXISTS render_segs PURGE;
CREATE TABLE render_segs (
  map_id       NUMBER(10) NOT NULL,
  seg_id       NUMBER(10) NOT NULL,
  ssector_id   NUMBER(10),
  direction    NUMBER(5),
  linedef_id   NUMBER(10),
  x1           NUMBER(5),
  y1           NUMBER(5),
  x2           NUMBER(5),
  y2           NUMBER(5),
  seg_u1       BINARY_DOUBLE,
  seg_u2       BINARY_DOUBLE,
  fsec         NUMBER(10),
  bsec         NUMBER(10),
  x_offset     NUMBER(5),
  y_offset     NUMBER(5),
  upper_tex    VARCHAR2(8),
  mid_tex      VARCHAR2(8),
  lower_tex    VARCHAR2(8),
  flags        NUMBER(10),
  f_floor      NUMBER(5),
  f_ceil       NUMBER(5),
  f_ceil_tex   VARCHAR2(8),
  f_light      NUMBER(5),
  b_floor      NUMBER(5),
  b_ceil       NUMBER(5),
  b_ceil_tex   VARCHAR2(8),
  b_light      NUMBER(5),
  light_bias   NUMBER(5),
  CONSTRAINT render_segs_pk PRIMARY KEY (map_id, seg_id)
);

DROP TABLE IF EXISTS render_things PURGE;
CREATE TABLE render_things (
  map_id          NUMBER(10)  NOT NULL,
  thing_id        NUMBER(10)  NOT NULL,
  sector_id       NUMBER(10)  NOT NULL,
  spawn_sector_id NUMBER(10),
  sprite          VARCHAR2(4) NOT NULL,
  frame           CHAR(1)     NOT NULL,
  fullbright      BOOLEAN     NOT NULL,
  spawn_ceiling   BOOLEAN     NOT NULL,
  thing_height    NUMBER(5)   NOT NULL,
  CONSTRAINT render_things_pk PRIMARY KEY (map_id, thing_id)
);

-- Level-start animated-light endpoints (reference: doom_reset_stage).
DROP TABLE IF EXISTS sector_light_fx PURGE;
CREATE TABLE sector_light_fx (
  map_id      NUMBER(10) NOT NULL,
  sector_id   NUMBER(10) NOT NULL,
  special     NUMBER(5)  NOT NULL,
  base_light  NUMBER(5)  NOT NULL,
  dark_light  NUMBER(5)  NOT NULL,
  CONSTRAINT sector_light_fx_pk PRIMARY KEY (map_id, sector_id)
);

-- ------------------------------------------------------------ textures / art
-- RENAMED: level -> light_level (LEVEL is reserved in Oracle).
DROP TABLE IF EXISTS colormap_rgb PURGE;
CREATE TABLE colormap_rgb (
  pal            NUMBER(5) DEFAULT 0 NOT NULL,
  light_level    NUMBER(5) NOT NULL,
  palette_index  NUMBER(5) NOT NULL,
  mapped_index   NUMBER(5) NOT NULL,
  r              NUMBER(5) NOT NULL,
  g              NUMBER(5) NOT NULL,
  b              NUMBER(5) NOT NULL,
  rgb            RAW(3)    NOT NULL,
  CONSTRAINT colormap_rgb_pk PRIMARY KEY (pal, light_level, palette_index)
);

-- palette_indices: width*height bytes, row-major, offset = v*width + u.
DROP TABLE IF EXISTS walltex_meta PURGE;
CREATE TABLE walltex_meta (
  name            VARCHAR2(8) NOT NULL,
  width           NUMBER(10)  NOT NULL,
  height          NUMBER(10)  NOT NULL,
  palette_indices BLOB        NOT NULL,
  CONSTRAINT walltex_meta_pk PRIMARY KEY (name)
);

-- palette_indices: 4096 bytes, 64x64 row-major, offset = v*64 + u.
DROP TABLE IF EXISTS flat_textures PURGE;
CREATE TABLE flat_textures (
  name            VARCHAR2(8) NOT NULL,
  palette_indices BLOB        NOT NULL,
  CONSTRAINT flat_textures_pk PRIMARY KEY (name)
);

DROP TABLE IF EXISTS sprite_frames PURGE;
CREATE TABLE sprite_frames (
  sprite      VARCHAR2(4) NOT NULL,
  frame       CHAR(1)     NOT NULL,
  rotation    NUMBER(5)   NOT NULL,
  lump_name   VARCHAR2(8) NOT NULL,
  flipped     BOOLEAN     NOT NULL,
  width       NUMBER(5)   NOT NULL,
  height      NUMBER(5)   NOT NULL,
  left_offset NUMBER(5)   NOT NULL,
  top_offset  NUMBER(5)   NOT NULL,
  CONSTRAINT sprite_frames_pk PRIMARY KEY (sprite, frame, rotation)
);

-- pixels/mask: width*height bytes row-major (offset = v*width + u); mask 1 = opaque.
DROP TABLE IF EXISTS sprite_lumps PURGE;
CREATE TABLE sprite_lumps (
  lump_name VARCHAR2(8) NOT NULL,
  pixels    BLOB        NOT NULL,
  mask      BLOB        NOT NULL,
  CONSTRAINT sprite_lumps_pk PRIMARY KEY (lump_name)
);

DROP TABLE IF EXISTS ui_patches PURGE;
CREATE TABLE ui_patches (
  name        VARCHAR2(8) NOT NULL,
  width       NUMBER(5)   NOT NULL,
  height      NUMBER(5)   NOT NULL,
  left_offset NUMBER(5)   NOT NULL,
  top_offset  NUMBER(5)   NOT NULL,
  pixels      BLOB        NOT NULL,
  mask        BLOB        NOT NULL,
  CONSTRAINT ui_patches_pk PRIMARY KEY (name)
);

DROP TABLE IF EXISTS ui_patch_pixels PURGE;
CREATE TABLE ui_patch_pixels (
  name          VARCHAR2(8) NOT NULL,
  dx            NUMBER(5)   NOT NULL,
  dy            NUMBER(5)   NOT NULL,
  palette_index NUMBER(5)   NOT NULL,
  CONSTRAINT ui_patch_pixels_pk PRIMARY KEY (name, dx, dy)
);

-- Reference: materialized view (ui_patch_pixels WHERE name LIKE 'ST%').
DROP TABLE IF EXISTS ui_hud_pixels PURGE;
CREATE TABLE ui_hud_pixels (
  name          VARCHAR2(8) NOT NULL,
  dx            NUMBER(5)   NOT NULL,
  dy            NUMBER(5)   NOT NULL,
  palette_index NUMBER(5)   NOT NULL,
  CONSTRAINT ui_hud_pixels_pk PRIMARY KEY (name, dx, dy)
);

-- Reference: materialized view (static status-bar layers, resolved to RGB).
DROP TABLE IF EXISTS ui_static_pixels PURGE;
CREATE TABLE ui_static_pixels (
  x             NUMBER(10) NOT NULL,
  y             NUMBER(10) NOT NULL,
  rgb           RAW(3)     NOT NULL,
  palette_index NUMBER(5)  NOT NULL,
  CONSTRAINT ui_static_pixels_pk PRIMARY KEY (x, y)
);

-- ------------------------------------------------- gameplay catalogs (03_catalogs.sql)
DROP TABLE IF EXISTS thing_sprite_defs PURGE;
CREATE TABLE thing_sprite_defs (
  thing_type    NUMBER(10)  NOT NULL,
  sprite        VARCHAR2(4) NOT NULL,
  frame         CHAR(1)     NOT NULL,
  fullbright    BOOLEAN     NOT NULL,
  spawn_ceiling BOOLEAN     NOT NULL,
  thing_height  NUMBER(5)   NOT NULL,
  CONSTRAINT thing_sprite_defs_pk PRIMARY KEY (thing_type)
);

DROP TABLE IF EXISTS projectile_defs PURGE;
CREATE TABLE projectile_defs (
  projectile_type   VARCHAR2(16)  NOT NULL,  -- enum projectile_kind
  name              VARCHAR2(64)  NOT NULL,
  radius            BINARY_DOUBLE NOT NULL,
  speed             BINARY_DOUBLE,
  dmg_dice_mult     NUMBER(10),
  dmg_random_id     NUMBER(5),
  explode_tics      NUMBER(5)     NOT NULL,
  fly_timeout       NUMBER(5)     NOT NULL,
  blast_radius      BINARY_DOUBLE,
  spray_at_tic      NUMBER(5),
  spray_rays        NUMBER(5),
  spray_arc_degrees BINARY_DOUBLE,
  spray_range       BINARY_DOUBLE,
  spray_dice        NUMBER(5),
  spray_random_base NUMBER(5),
  fly_sprite        VARCHAR2(4),
  impact_sprite     VARCHAR2(4),
  dmg_dice_count    NUMBER(5) DEFAULT 8 NOT NULL,
  CONSTRAINT projectile_defs_pk PRIMARY KEY (projectile_type)
);

DROP TABLE IF EXISTS thing_combat_defs PURGE;
CREATE TABLE thing_combat_defs (
  thing_type        NUMBER(10)    NOT NULL,
  spawn_health      NUMBER(10)    NOT NULL,
  radius            BINARY_DOUBLE NOT NULL,
  death_sprite      VARCHAR2(4)   NOT NULL,
  death_frame       CHAR(1)       NOT NULL,
  death_fullbright  BOOLEAN       NOT NULL,
  no_blood          BOOLEAN       DEFAULT FALSE NOT NULL,
  pain_chance       NUMBER(5)     DEFAULT 0 NOT NULL,
  attack_range      BINARY_DOUBLE DEFAULT 2048 NOT NULL,
  xdeath_frame      CHAR(1),
  mass              NUMBER(10)    DEFAULT 100 NOT NULL,
  counts_kill       BOOLEAN       DEFAULT FALSE NOT NULL,
  name              VARCHAR2(64),
  height            NUMBER(5)     DEFAULT 56 NOT NULL,
  floats            BOOLEAN       DEFAULT FALSE NOT NULL,
  skull_fly         BOOLEAN       DEFAULT FALSE NOT NULL,
  missile_type      VARCHAR2(16),            -- enum projectile_kind
  missile_speed     BINARY_DOUBLE,
  missile_dice      NUMBER(5),
  hitscan_pellets   NUMBER(5),
  melee_mult        NUMBER(5),
  melee_sides       NUMBER(5),
  fast_on_nightmare BOOLEAN       DEFAULT FALSE NOT NULL,
  attack_sound      VARCHAR2(8),
  explodes          BOOLEAN       DEFAULT FALSE NOT NULL,
  drops_thing_type  NUMBER(10),
  blast_radius      BINARY_DOUBLE,
  hitscan_mult      NUMBER(5),
  hitscan_sides     NUMBER(5),
  charge_mult       NUMBER(5),
  charge_sides      NUMBER(5),
  fuzzy             BOOLEAN       DEFAULT FALSE NOT NULL,
  CONSTRAINT thing_combat_defs_pk PRIMARY KEY (thing_type)
);

DROP TABLE IF EXISTS weapon_defs PURGE;
CREATE TABLE weapon_defs (
  weapon_id       NUMBER(10)    NOT NULL,
  name            VARCHAR2(64)  NOT NULL,
  slot            NUMBER(10)    NOT NULL,
  ammo_type       VARCHAR2(16),            -- enum ammo_kind
  ammo_per_shot   NUMBER(10)    DEFAULT 0 NOT NULL,
  sprite          VARCHAR2(4)   NOT NULL,
  flash_sprite    VARCHAR2(4),
  pellet_count    NUMBER(10)    NOT NULL,
  max_range       BINARY_DOUBLE NOT NULL,
  dmg_dice_count  NUMBER(10)    NOT NULL,
  dmg_dice_mult   NUMBER(10)    NOT NULL,
  projectile_type VARCHAR2(16),            -- enum projectile_kind
  idle_loop_sound VARCHAR2(8),
  CONSTRAINT weapon_defs_pk PRIMARY KEY (weapon_id)
);

DROP TABLE IF EXISTS weapon_frames PURGE;
CREATE TABLE weapon_frames (
  weapon_id       NUMBER(10)   NOT NULL,
  state           VARCHAR2(8)  NOT NULL,   -- enum weapon_state
  seq_index       NUMBER(10)   NOT NULL,
  frame           CHAR(1)      NOT NULL,
  tics            NUMBER(10)   NOT NULL,
  fullbright      BOOLEAN DEFAULT FALSE NOT NULL,
  is_attack_frame BOOLEAN DEFAULT FALSE NOT NULL,
  refire_check    BOOLEAN DEFAULT FALSE NOT NULL,
  CONSTRAINT weapon_frames_pk PRIMARY KEY (weapon_id, state, seq_index)
);

DROP TABLE IF EXISTS thing_ai_frames PURGE;
CREATE TABLE thing_ai_frames (
  thing_type      NUMBER(10)  NOT NULL,
  state           VARCHAR2(8) NOT NULL,    -- enum actor_state
  seq_index       NUMBER(10)  NOT NULL,
  frame           CHAR(1)     NOT NULL,
  tics            NUMBER(10)  NOT NULL,
  fullbright      BOOLEAN DEFAULT FALSE NOT NULL,
  is_attack_frame BOOLEAN DEFAULT FALSE NOT NULL,
  CONSTRAINT thing_ai_frames_pk PRIMARY KEY (thing_type, state, seq_index)
);

DROP TABLE IF EXISTS effect_sprite_defs PURGE;
CREATE TABLE effect_sprite_defs (
  effect_type    VARCHAR2(16) NOT NULL,    -- enum effect_kind
  sprite         VARCHAR2(4)  NOT NULL,
  frame_sequence VARCHAR2(32) NOT NULL,
  tics_per_frame NUMBER(5)    NOT NULL,
  fullbright     BOOLEAN      NOT NULL,
  CONSTRAINT effect_sprite_defs_pk PRIMARY KEY (effect_type)
);

DROP TABLE IF EXISTS ammo_defs PURGE;
CREATE TABLE ammo_defs (
  ammo_type      VARCHAR2(16) NOT NULL,    -- enum ammo_kind
  cap            NUMBER(10)   NOT NULL,
  backpack_cap   NUMBER(10)   NOT NULL,
  backpack_gives NUMBER(10)   NOT NULL,
  CONSTRAINT ammo_defs_pk PRIMARY KEY (ammo_type)
);

-- Needed at load time to stamp linedefs.cross_activated/cross_once/
-- monster_crossable/scrolls (renderer reads linedefs.scrolls).
DROP TABLE IF EXISTS line_special_defs PURGE;
CREATE TABLE line_special_defs (
  special           NUMBER(10)   NOT NULL,
  name              VARCHAR2(64) NOT NULL,
  mechanic          VARCHAR2(16),            -- enum special_mechanic
  cross_activated   BOOLEAN DEFAULT FALSE NOT NULL,
  cross_once        BOOLEAN DEFAULT FALSE NOT NULL,
  monster_crossable BOOLEAN DEFAULT FALSE NOT NULL,
  use_activated     BOOLEAN DEFAULT FALSE NOT NULL,
  use_once          BOOLEAN DEFAULT FALSE NOT NULL,
  key_required      VARCHAR2(8),             -- enum key_color
  is_exit           BOOLEAN DEFAULT FALSE NOT NULL,
  secret_exit       BOOLEAN DEFAULT FALSE NOT NULL,
  door_target       VARCHAR2(8),             -- enum door_target
  height_target     VARCHAR2(24),            -- enum height_target
  change_tex        BOOLEAN DEFAULT FALSE NOT NULL,
  flips_switch      BOOLEAN DEFAULT FALSE NOT NULL,
  shoot_activated   BOOLEAN DEFAULT FALSE NOT NULL,
  monster_usable    BOOLEAN DEFAULT FALSE NOT NULL,
  scrolls           BOOLEAN DEFAULT FALSE NOT NULL,
  target_light      NUMBER(5),
  mover_type        VARCHAR2(24),            -- enum mover_kind
  direction         NUMBER(5),
  step_height       NUMBER(5),
  crush             BOOLEAN DEFAULT FALSE NOT NULL,
  light_source      VARCHAR2(16),            -- enum light_source
  stops_mover       VARCHAR2(24),            -- enum mover_kind
  speed             NUMBER(4,1),
  wait_tics         NUMBER(10),
  CONSTRAINT line_special_defs_pk PRIMARY KEY (special)
);
