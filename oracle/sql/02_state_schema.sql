-- =============================================================================
-- 02_state_schema.sql -- per-tic dynamic renderer state (Oracle 26ai)
--
-- One st_<table> per dynamic table the reference renderer reads. Each has all
-- reference columns (same names/order as reference/sqldoom/sql/schema.sql) plus
-- a leading TIC column; PK = (tic, <reference PK>). Filled by
-- oracle/client/load_state.py from reference_data/<run>/state/<table>.parquet
-- (written by oracle/tests/record_reference.py: tic N = state after game tic N,
-- the state that frame N was rendered from).
--
-- Types follow 01_schema.sql: REAL -> BINARY_DOUBLE (holds the float4 value
-- exactly), enums -> VARCHAR2, TIMESTAMPTZ -> TIMESTAMP WITH TIME ZONE.
-- No renames were needed in these tables.
-- =============================================================================

DROP TABLE IF EXISTS st_sectors PURGE;
CREATE TABLE st_sectors (
  tic                NUMBER(6)   NOT NULL,
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
  CONSTRAINT st_sectors_pk PRIMARY KEY (tic, map_id, id)
);

DROP TABLE IF EXISTS st_things PURGE;
CREATE TABLE st_things (
  tic           NUMBER(6)     NOT NULL,
  id            NUMBER(10)    NOT NULL,
  map_id        NUMBER(10)    NOT NULL,
  x             BINARY_DOUBLE NOT NULL,
  y             BINARY_DOUBLE NOT NULL,
  z             BINARY_DOUBLE NOT NULL,
  angle         BINARY_DOUBLE NOT NULL,
  spawn_x       NUMBER(5)     NOT NULL,
  spawn_y       NUMBER(5)     NOT NULL,
  spawn_angle   NUMBER(5)     NOT NULL,
  mom_x         BINARY_DOUBLE NOT NULL,
  mom_y         BINARY_DOUBLE NOT NULL,
  type          NUMBER(10)    NOT NULL,
  flags         NUMBER(10)    NOT NULL,
  CONSTRAINT st_things_pk PRIMARY KEY (tic, map_id, id)
);

DROP TABLE IF EXISTS st_render_things PURGE;
CREATE TABLE st_render_things (
  tic             NUMBER(6)   NOT NULL,
  map_id          NUMBER(10)  NOT NULL,
  thing_id        NUMBER(10)  NOT NULL,
  sector_id       NUMBER(10)  NOT NULL,
  spawn_sector_id NUMBER(10),
  sprite          VARCHAR2(4) NOT NULL,
  frame           CHAR(1)     NOT NULL,
  fullbright      BOOLEAN     NOT NULL,
  spawn_ceiling   BOOLEAN     NOT NULL,
  thing_height    NUMBER(5)   NOT NULL,
  CONSTRAINT st_render_things_pk PRIMARY KEY (tic, map_id, thing_id)
);

DROP TABLE IF EXISTS st_player_state PURGE;
CREATE TABLE st_player_state (
  tic                 NUMBER(6)     NOT NULL,
  map_id              NUMBER(10)    NOT NULL,
  player_thing_id     NUMBER(10)    NOT NULL,
  health              NUMBER(10)    NOT NULL,
  alive               BOOLEAN       NOT NULL,
  level_tics          NUMBER(19)    NOT NULL,
  previous_x          BINARY_DOUBLE NOT NULL,
  previous_y          BINARY_DOUBLE NOT NULL,
  position_x          BINARY_DOUBLE NOT NULL,
  position_y          BINARY_DOUBLE NOT NULL,
  base_z              BINARY_DOUBLE NOT NULL,
  view_z              BINARY_DOUBLE NOT NULL,
  view_angle          BINARY_DOUBLE NOT NULL,
  momentum_x          BINARY_DOUBLE NOT NULL,
  momentum_y          BINARY_DOUBLE NOT NULL,
  bob_strength        BINARY_DOUBLE NOT NULL,
  previous_view_z     BINARY_DOUBLE NOT NULL,
  previous_view_angle BINARY_DOUBLE NOT NULL,
  sector_id           NUMBER(10),
  pain_face_tics      NUMBER(10)    NOT NULL,
  armor               NUMBER(10)    NOT NULL,
  armor_class         NUMBER(5)     NOT NULL,
  backpack            BOOLEAN       NOT NULL,
  ammo_bullets        NUMBER(10)    NOT NULL,
  ammo_shells         NUMBER(10)    NOT NULL,
  ammo_rockets        NUMBER(10)    NOT NULL,
  ammo_cells          NUMBER(10)    NOT NULL,
  key_blue            BOOLEAN       NOT NULL,
  key_yellow          BOOLEAN       NOT NULL,
  key_red             BOOLEAN       NOT NULL,
  radsuit_tics        NUMBER(10)    NOT NULL,
  invis_tics          NUMBER(10)    NOT NULL,
  momentum_z          BINARY_DOUBLE NOT NULL,
  damage_count        NUMBER(10)    NOT NULL,
  bonus_count         NUMBER(10)    NOT NULL,
  light_amp_tics      NUMBER(10)    NOT NULL,
  power_map           BOOLEAN       NOT NULL,
  god_mode            BOOLEAN       NOT NULL,
  noclip              BOOLEAN       NOT NULL,
  invuln_tics         NUMBER(10)    NOT NULL,
  berserk             BOOLEAN       NOT NULL,
  message             VARCHAR2(400),           -- '' would become NULL; reference uses NULL for "no message"
  message_tics        NUMBER(10)    NOT NULL,
  frags               NUMBER(10)    NOT NULL,
  death_tics          NUMBER(10)    NOT NULL,
  killer_id           NUMBER(10),
  sprite_frame        CHAR(1)       NOT NULL,
  CONSTRAINT st_player_state_pk PRIMARY KEY (tic, map_id, player_thing_id)
);

DROP TABLE IF EXISTS st_player_weapons PURGE;
CREATE TABLE st_player_weapons (
  tic             NUMBER(6)     NOT NULL,
  map_id          NUMBER(10)    NOT NULL,
  player_thing_id NUMBER(10)    NOT NULL,
  current_weapon  NUMBER(10)    NOT NULL,
  pending_weapon  NUMBER(10),
  state           VARCHAR2(8)   NOT NULL,   -- enum weapon_state
  seq_index       NUMBER(10)    NOT NULL,
  tics            NUMBER(5)     NOT NULL,
  flash_seq_index NUMBER(10),
  flash_tics      NUMBER(5)     NOT NULL,
  sx              BINARY_DOUBLE NOT NULL,
  sy              BINARY_DOUBLE NOT NULL,
  shot_serial     NUMBER(19)    NOT NULL,
  fired_this_tick BOOLEAN       NOT NULL,
  CONSTRAINT st_player_weapons_pk PRIMARY KEY (tic, map_id, player_thing_id)
);

DROP TABLE IF EXISTS st_player_weapon_owned PURGE;
CREATE TABLE st_player_weapon_owned (
  tic             NUMBER(6)  NOT NULL,
  map_id          NUMBER(10) NOT NULL,
  player_thing_id NUMBER(10) NOT NULL,
  weapon_id       NUMBER(10) NOT NULL,
  CONSTRAINT st_player_weapon_owned_pk PRIMARY KEY (tic, map_id, player_thing_id, weapon_id)
);

DROP TABLE IF EXISTS st_monster_ai PURGE;
CREATE TABLE st_monster_ai (
  tic             NUMBER(6)   NOT NULL,
  map_id          NUMBER(10)  NOT NULL,
  thing_id        NUMBER(10)  NOT NULL,
  state           VARCHAR2(8) NOT NULL,     -- enum actor_state
  state_tics      NUMBER(10)  NOT NULL,
  seq_index       NUMBER(10)  NOT NULL,
  sector_id       NUMBER(10),
  attack_cooldown NUMBER(10)  NOT NULL,
  fired_this_tick BOOLEAN     NOT NULL,
  target_thing_id NUMBER(10),
  charge_tics     NUMBER(10)  NOT NULL,
  movedir         NUMBER(5),
  movecount       NUMBER(5)   NOT NULL,
  CONSTRAINT st_monster_ai_pk PRIMARY KEY (tic, map_id, thing_id)
);

DROP TABLE IF EXISTS st_thing_health PURGE;
CREATE TABLE st_thing_health (
  tic        NUMBER(6)  NOT NULL,
  map_id     NUMBER(10) NOT NULL,
  thing_id   NUMBER(10) NOT NULL,
  health     NUMBER(10) NOT NULL,
  max_health NUMBER(10) NOT NULL,
  alive      BOOLEAN    NOT NULL,
  CONSTRAINT st_thing_health_pk PRIMARY KEY (tic, map_id, thing_id)
);

DROP TABLE IF EXISTS st_world_effects PURGE;
CREATE TABLE st_world_effects (
  tic         NUMBER(6)     NOT NULL,
  map_id      NUMBER(10)    NOT NULL,
  effect_id   NUMBER(19)    NOT NULL,
  effect_type VARCHAR2(16)  NOT NULL,       -- enum effect_kind
  x           BINARY_DOUBLE NOT NULL,
  y           BINARY_DOUBLE NOT NULL,
  z           BINARY_DOUBLE NOT NULL,
  sector_id   NUMBER(10),
  age         NUMBER(5)     NOT NULL,
  CONSTRAINT st_world_effects_pk PRIMARY KEY (tic, map_id, effect_id)
);

DROP TABLE IF EXISTS st_monster_projectiles PURGE;
CREATE TABLE st_monster_projectiles (
  tic             NUMBER(6)     NOT NULL,
  map_id          NUMBER(10)    NOT NULL,
  projectile_id   NUMBER(19)    NOT NULL,
  owner_thing_id  NUMBER(10)    NOT NULL,
  projectile_type VARCHAR2(16)  NOT NULL,   -- enum projectile_kind
  x               BINARY_DOUBLE NOT NULL,
  y               BINARY_DOUBLE NOT NULL,
  z               BINARY_DOUBLE NOT NULL,
  vx              BINARY_DOUBLE NOT NULL,
  vy              BINARY_DOUBLE NOT NULL,
  vz              BINARY_DOUBLE NOT NULL,
  sector_id       NUMBER(10),
  state           VARCHAR2(8)   NOT NULL,   -- enum projectile_state
  age             NUMBER(5)     NOT NULL,
  damage          NUMBER(5)     NOT NULL,
  impact_player   BOOLEAN       NOT NULL,
  CONSTRAINT st_monster_projectiles_pk PRIMARY KEY (tic, map_id, projectile_id)
);

DROP TABLE IF EXISTS st_picked_up_items PURGE;
CREATE TABLE st_picked_up_items (
  tic      NUMBER(6)  NOT NULL,
  map_id   NUMBER(10) NOT NULL,
  thing_id NUMBER(10) NOT NULL,
  CONSTRAINT st_picked_up_items_pk PRIMARY KEY (tic, map_id, thing_id)
);

DROP TABLE IF EXISTS st_sector_light_fx PURGE;
CREATE TABLE st_sector_light_fx (
  tic        NUMBER(6)  NOT NULL,
  map_id     NUMBER(10) NOT NULL,
  sector_id  NUMBER(10) NOT NULL,
  special    NUMBER(5)  NOT NULL,
  base_light NUMBER(5)  NOT NULL,
  dark_light NUMBER(5)  NOT NULL,
  CONSTRAINT st_sector_light_fx_pk PRIMARY KEY (tic, map_id, sector_id)
);

DROP TABLE IF EXISTS st_mp_players PURGE;
CREATE TABLE st_mp_players (
  tic             NUMBER(6)     NOT NULL,
  map_id          NUMBER(10)    NOT NULL,
  slot            NUMBER(10)    NOT NULL,
  player_thing_id NUMBER(10)    NOT NULL,
  skill           NUMBER(10)    NOT NULL,
  role_name       VARCHAR2(128),
  pose_x          BINARY_DOUBLE NOT NULL,
  pose_y          BINARY_DOUBLE NOT NULL,
  pose_z          BINARY_DOUBLE NOT NULL,
  pose_angle      BINARY_DOUBLE NOT NULL,
  last_seen       TIMESTAMP WITH TIME ZONE,
  display_name    VARCHAR2(128),
  claimed_at      TIMESTAMP WITH TIME ZONE,
  CONSTRAINT st_mp_players_pk PRIMARY KEY (tic, map_id, slot)
);


-- Sparse per-tic deltas of render_segs texture columns (switches change them in the game tic).
-- A row exists only for segs whose textures differ from level start at that tic.
DROP TABLE IF EXISTS st_render_seg_tex PURGE;
CREATE TABLE st_render_seg_tex (
  tic       NUMBER(6)   NOT NULL,
  map_id    NUMBER(5)   NOT NULL,
  seg_id    NUMBER(6)   NOT NULL,
  upper_tex VARCHAR2(8),
  mid_tex   VARCHAR2(8),
  lower_tex VARCHAR2(8),
  CONSTRAINT st_render_seg_tex_pk PRIMARY KEY (tic, map_id, seg_id)
);
