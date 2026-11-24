-- =============================================================================
-- 07_game_schema.sql -- Oracle game state for the SQLDoom game tic (phase 1)
--
-- Every table the reference game tic (reference/sqldoom/sql/runtime/functions)
-- reads AND writes gets a g_ twin here; the static geometry and catalogs of
-- 01_schema.sql / 03_catalogs.sql are shared read-only. The renderer's tables
-- (sectors, things, render_things, render_segs, sidedefs, sector_light_fx and
-- the recorded st_*) are not touched.
--
-- Type mapping differs from 01_schema.sql on purpose: the game does float4
-- arithmetic on REAL columns (CedarDB keeps real op real / real op literal in
-- single precision and rounds every write to a REAL column), so
--   REAL -> BINARY_FLOAT, DOUBLE PRECISION -> BINARY_DOUBLE,
--   SMALLINT/INT/BIGINT -> NUMBER(5/10/19), NUMERIC(4,1) -> NUMBER(4,1),
--   BOOLEAN -> BOOLEAN, enums/TEXT -> VARCHAR2.
-- Renames: level_pars.level -> lvl (reserved word).
-- Re-runnable.
-- =============================================================================

-- ------------------------------------------------------- extra static catalogs
DROP TABLE IF EXISTS doom_constants PURGE;
CREATE TABLE doom_constants (
  name   VARCHAR2(64)  NOT NULL,
  value  BINARY_DOUBLE NOT NULL,
  source VARCHAR2(4000) NOT NULL,
  CONSTRAINT doom_constants_pk PRIMARY KEY (name)
);

DROP TABLE IF EXISTS pickup_defs PURGE;
CREATE TABLE pickup_defs (
  thing_type          NUMBER(10)   NOT NULL,
  kind                VARCHAR2(16) NOT NULL,
  amount              NUMBER(10)   NOT NULL,
  cap                 NUMBER(10)   NOT NULL,
  is_set_min          BOOLEAN DEFAULT FALSE NOT NULL,
  weapon_id           NUMBER(10),
  armor_class         NUMBER(5),
  counts_item         BOOLEAN DEFAULT FALSE NOT NULL,
  dropped_amount      NUMBER(10),
  only_when_below_cap BOOLEAN DEFAULT FALSE NOT NULL,
  CONSTRAINT pickup_defs_pk PRIMARY KEY (thing_type, kind)
);

DROP TABLE IF EXISTS pickup_messages PURGE;
CREATE TABLE pickup_messages (
  thing_type NUMBER(10)    NOT NULL,
  message    VARCHAR2(200) NOT NULL,
  CONSTRAINT pickup_messages_pk PRIMARY KEY (thing_type)
);

DROP TABLE IF EXISTS chase_dir_defs PURGE;
CREATE TABLE chase_dir_defs (
  dir         NUMBER(5)     NOT NULL,
  name        VARCHAR2(16)  NOT NULL,
  dx          BINARY_DOUBLE NOT NULL,
  dy          BINARY_DOUBLE NOT NULL,
  angle       BINARY_FLOAT  NOT NULL,
  opposite    NUMBER(5)     NOT NULL,
  is_diagonal BOOLEAN       NOT NULL,
  CONSTRAINT chase_dir_defs_pk PRIMARY KEY (dir)
);

DROP TABLE IF EXISTS thing_role_defs PURGE;
CREATE TABLE thing_role_defs (
  thing_type          NUMBER(10)   NOT NULL,
  name                VARCHAR2(64) NOT NULL,
  is_player_start     BOOLEAN DEFAULT FALSE NOT NULL,
  player_number       NUMBER(5),
  is_deathmatch_start BOOLEAN DEFAULT FALSE NOT NULL,
  is_teleport_dest    BOOLEAN DEFAULT FALSE NOT NULL,
  CONSTRAINT thing_role_defs_pk PRIMARY KEY (thing_type)
);

DROP TABLE IF EXISTS thing_blocking_defs PURGE;
CREATE TABLE thing_blocking_defs (
  thing_type NUMBER(10)   NOT NULL,
  radius     BINARY_FLOAT NOT NULL,
  CONSTRAINT thing_blocking_defs_pk PRIMARY KEY (thing_type)
);

DROP TABLE IF EXISTS sector_special_defs PURGE;
CREATE TABLE sector_special_defs (
  special                  NUMBER(10)   NOT NULL,
  name                     VARCHAR2(64) NOT NULL,
  is_secret                BOOLEAN DEFAULT FALSE NOT NULL,
  damage_per_hit           NUMBER(10),
  ends_level_at_low_health BOOLEAN DEFAULT FALSE NOT NULL,
  exit_at_health           NUMBER(10),
  CONSTRAINT sector_special_defs_pk PRIMARY KEY (special)
);

DROP TABLE IF EXISTS thing_sound_defs PURGE;
CREATE TABLE thing_sound_defs (
  thing_type NUMBER(10)  NOT NULL,
  cue        VARCHAR2(8) NOT NULL,
  variant    NUMBER(10)  NOT NULL,
  sound_name VARCHAR2(8) NOT NULL,
  CONSTRAINT thing_sound_defs_pk PRIMARY KEY (thing_type, cue, variant)
);

DROP TABLE IF EXISTS level_pars PURGE;
CREATE TABLE level_pars (
  episode  NUMBER(10) NOT NULL,
  lvl      NUMBER(10) NOT NULL,
  par_secs NUMBER(10) NOT NULL,
  CONSTRAINT level_pars_pk PRIMARY KEY (episode, lvl)
);

DROP TABLE IF EXISTS boss_actions PURGE;
CREATE TABLE boss_actions (
  map_name  VARCHAR2(8)  NOT NULL,
  boss_type NUMBER(10)   NOT NULL,
  action    VARCHAR2(16) NOT NULL,
  CONSTRAINT boss_actions_pk PRIMARY KEY (map_name)
);

-- ------------------------------------------- static derived (reference MVs)
DROP TABLE IF EXISTS linedef_geom PURGE;
CREATE TABLE linedef_geom (
  map_id      NUMBER(10) NOT NULL,
  linedef_id  NUMBER(10) NOT NULL,
  x1 NUMBER(5) NOT NULL, y1 NUMBER(5) NOT NULL, x2 NUMBER(5) NOT NULL, y2 NUMBER(5) NOT NULL,
  flags       NUMBER(10) NOT NULL,
  special     NUMBER(10) NOT NULL,
  right_sd_id NUMBER(10) NOT NULL,
  left_sd_id  NUMBER(10) NOT NULL,
  fsec        NUMBER(10),
  bsec        NUMBER(10),
  CONSTRAINT linedef_geom_pk PRIMARY KEY (map_id, linedef_id)
);
CREATE INDEX linedef_geom_f ON linedef_geom (map_id, fsec);
CREATE INDEX linedef_geom_b ON linedef_geom (map_id, bsec);

DROP TABLE IF EXISTS sector_adjacency PURGE;
CREATE TABLE sector_adjacency (
  map_id     NUMBER(10) NOT NULL,
  linedef_id NUMBER(10) NOT NULL,
  sector_id  NUMBER(10) NOT NULL,
  other_id   NUMBER(10) NOT NULL
);
CREATE INDEX sector_adjacency_ix ON sector_adjacency (map_id, sector_id);

-- ---------------------------------------------------------------- game state
DROP TABLE IF EXISTS g_sectors PURGE;
CREATE TABLE g_sectors (
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
  CONSTRAINT g_sectors_pk PRIMARY KEY (map_id, id)
);

DROP TABLE IF EXISTS g_sidedefs PURGE;
CREATE TABLE g_sidedefs (
  id        NUMBER(10)  NOT NULL,
  map_id    NUMBER(10)  NOT NULL,
  x_offset  NUMBER(5)   NOT NULL,
  y_offset  NUMBER(5)   NOT NULL,
  upper_tex VARCHAR2(8) NOT NULL,
  lower_tex VARCHAR2(8) NOT NULL,
  mid_tex   VARCHAR2(8) NOT NULL,
  sector_id NUMBER(10)  NOT NULL,
  CONSTRAINT g_sidedefs_pk PRIMARY KEY (map_id, id)
);

DROP TABLE IF EXISTS g_render_segs PURGE;
CREATE TABLE g_render_segs (
  map_id NUMBER(10) NOT NULL, seg_id NUMBER(10) NOT NULL, ssector_id NUMBER(10),
  direction NUMBER(5), linedef_id NUMBER(10),
  x1 NUMBER(5), y1 NUMBER(5), x2 NUMBER(5), y2 NUMBER(5),
  seg_u1 BINARY_DOUBLE, seg_u2 BINARY_DOUBLE, fsec NUMBER(10), bsec NUMBER(10),
  x_offset NUMBER(5), y_offset NUMBER(5),
  upper_tex VARCHAR2(8), mid_tex VARCHAR2(8), lower_tex VARCHAR2(8), flags NUMBER(10),
  f_floor NUMBER(5), f_ceil NUMBER(5), f_ceil_tex VARCHAR2(8), f_light NUMBER(5),
  b_floor NUMBER(5), b_ceil NUMBER(5), b_ceil_tex VARCHAR2(8), b_light NUMBER(5),
  light_bias NUMBER(5),
  CONSTRAINT g_render_segs_pk PRIMARY KEY (map_id, seg_id)
);
CREATE INDEX g_render_segs_f ON g_render_segs (map_id, fsec);
CREATE INDEX g_render_segs_b ON g_render_segs (map_id, bsec);

DROP TABLE IF EXISTS g_things PURGE;
CREATE TABLE g_things (
  id          NUMBER(10)   NOT NULL,
  map_id      NUMBER(10)   NOT NULL,
  x           BINARY_FLOAT NOT NULL,
  y           BINARY_FLOAT NOT NULL,
  z           BINARY_FLOAT DEFAULT 41 NOT NULL,
  angle       BINARY_FLOAT NOT NULL,
  spawn_x     NUMBER(5)    NOT NULL,
  spawn_y     NUMBER(5)    NOT NULL,
  spawn_angle NUMBER(5)    NOT NULL,
  mom_x       BINARY_FLOAT DEFAULT 0 NOT NULL,
  mom_y       BINARY_FLOAT DEFAULT 0 NOT NULL,
  type        NUMBER(10)   NOT NULL,
  flags       NUMBER(10)   NOT NULL,
  CONSTRAINT g_things_pk PRIMARY KEY (map_id, id)
);

DROP TABLE IF EXISTS g_render_things PURGE;
CREATE TABLE g_render_things (
  map_id          NUMBER(10)  NOT NULL,
  thing_id        NUMBER(10)  NOT NULL,
  sector_id       NUMBER(10)  NOT NULL,
  spawn_sector_id NUMBER(10),
  sprite          VARCHAR2(4) NOT NULL,
  frame           CHAR(1)     NOT NULL,
  fullbright      BOOLEAN     NOT NULL,
  spawn_ceiling   BOOLEAN     NOT NULL,
  thing_height    NUMBER(5)   NOT NULL,
  CONSTRAINT g_render_things_pk PRIMARY KEY (map_id, thing_id)
);

DROP TABLE IF EXISTS g_sector_light_fx PURGE;
CREATE TABLE g_sector_light_fx (
  map_id     NUMBER(10) NOT NULL,
  sector_id  NUMBER(10) NOT NULL,
  special    NUMBER(5)  NOT NULL,
  base_light NUMBER(5)  NOT NULL,
  dark_light NUMBER(5)  NOT NULL,
  CONSTRAINT g_sector_light_fx_pk PRIMARY KEY (map_id, sector_id)
);

DROP TABLE IF EXISTS g_sector_movers PURGE;
CREATE TABLE g_sector_movers (
  map_id           NUMBER(10)   NOT NULL,
  sector_id        NUMBER(10)   NOT NULL,
  source_line_id   NUMBER(10),
  mover_type       VARCHAR2(24) NOT NULL,
  plane            VARCHAR2(8)  DEFAULT 'ceiling' NOT NULL,
  direction        NUMBER(5)    NOT NULL,
  bottom_height    NUMBER(5),
  top_height       NUMBER(5)    NOT NULL,
  speed            NUMBER(4,1)  NOT NULL,
  move_carry       NUMBER(4,1)  DEFAULT 0 NOT NULL,
  wait_tics        NUMBER(10)   NOT NULL,
  countdown        NUMBER(10)   DEFAULT 0 NOT NULL,
  next_ceiling     NUMBER(5),
  next_floor       NUMBER(5),
  target_floor_tex VARCHAR2(8),
  moved_this_tick  BOOLEAN DEFAULT FALSE NOT NULL,
  crush            BOOLEAN DEFAULT FALSE NOT NULL,
  CONSTRAINT g_sector_movers_pk PRIMARY KEY (map_id, sector_id)
);

DROP TABLE IF EXISTS g_line_special_events PURGE;
CREATE TABLE g_line_special_events (
  map_id          NUMBER(10)  NOT NULL,
  player_thing_id NUMBER(10)  NOT NULL,
  line_id         NUMBER(10)  NOT NULL,
  trigger_type    VARCHAR2(8) NOT NULL,
  from_front      BOOLEAN     NOT NULL,
  CONSTRAINT g_line_special_events_pk PRIMARY KEY (map_id, player_thing_id, line_id, trigger_type)
);

DROP TABLE IF EXISTS g_line_use_results PURGE;
CREATE TABLE g_line_use_results (
  map_id          NUMBER(10) NOT NULL,
  player_thing_id NUMBER(10) NOT NULL,
  line_id         NUMBER(10),
  special         NUMBER(10),
  locked          BOOLEAN DEFAULT FALSE NOT NULL,
  eligible        BOOLEAN DEFAULT FALSE NOT NULL,
  from_front      BOOLEAN DEFAULT FALSE NOT NULL,
  CONSTRAINT g_line_use_results_pk PRIMARY KEY (map_id, player_thing_id)
);

DROP TABLE IF EXISTS g_line_activations PURGE;
CREATE TABLE g_line_activations (
  map_id  NUMBER(10) NOT NULL,
  line_id NUMBER(10) NOT NULL,
  CONSTRAINT g_line_activations_pk PRIMARY KEY (map_id, line_id)
);

DROP TABLE IF EXISTS g_line_buttons PURGE;
CREATE TABLE g_line_buttons (
  map_id        NUMBER(10)  NOT NULL,
  line_id       NUMBER(10)  NOT NULL,
  sidedef_id    NUMBER(10)  NOT NULL,
  texture_part  VARCHAR2(8) NOT NULL,
  original_tex  VARCHAR2(8) NOT NULL,
  active_tex    VARCHAR2(8) NOT NULL,
  countdown     NUMBER(10)  NOT NULL,
  just_restored BOOLEAN DEFAULT FALSE NOT NULL,
  CONSTRAINT g_line_buttons_pk PRIMARY KEY (map_id, line_id, sidedef_id, texture_part)
);

DROP TABLE IF EXISTS g_sound_events PURGE;
CREATE TABLE g_sound_events (
  event_id        NUMBER(19) GENERATED BY DEFAULT AS IDENTITY (CACHE 1000) NOT NULL,
  map_id          NUMBER(10)   NOT NULL,
  event_key       VARCHAR2(64) NOT NULL,
  level_tic       NUMBER(19)   NOT NULL,
  sound_name      VARCHAR2(8)  NOT NULL,
  source_thing_id NUMBER(10),
  source_x        BINARY_FLOAT,
  source_y        BINARY_FLOAT,
  CONSTRAINT g_sound_events_pk PRIMARY KEY (event_id),
  CONSTRAINT g_sound_events_uk UNIQUE (map_id, event_key)
);
CREATE INDEX g_sound_events_map ON g_sound_events (map_id, event_id);

DROP TABLE IF EXISTS g_world_effects PURGE;
CREATE TABLE g_world_effects (
  map_id      NUMBER(10)   NOT NULL,
  effect_id   NUMBER(19)   NOT NULL,
  effect_type VARCHAR2(16) NOT NULL,
  x           BINARY_FLOAT NOT NULL,
  y           BINARY_FLOAT NOT NULL,
  z           BINARY_FLOAT NOT NULL,
  sector_id   NUMBER(10),
  age         NUMBER(5) DEFAULT 0 NOT NULL,
  CONSTRAINT g_world_effects_pk PRIMARY KEY (map_id, effect_id)
);

DROP TABLE IF EXISTS g_monster_projectiles PURGE;
CREATE TABLE g_monster_projectiles (
  map_id          NUMBER(10)   NOT NULL,
  projectile_id   NUMBER(19)   NOT NULL,
  owner_thing_id  NUMBER(10)   NOT NULL,
  projectile_type VARCHAR2(16) NOT NULL,
  x  BINARY_FLOAT NOT NULL, y  BINARY_FLOAT NOT NULL, z  BINARY_FLOAT NOT NULL,
  vx BINARY_FLOAT NOT NULL, vy BINARY_FLOAT NOT NULL, vz BINARY_FLOAT NOT NULL,
  sector_id       NUMBER(10),
  state           VARCHAR2(8) DEFAULT 'fly' NOT NULL,
  age             NUMBER(5)   DEFAULT 0 NOT NULL,
  damage          NUMBER(5)   NOT NULL,
  impact_player   BOOLEAN DEFAULT FALSE NOT NULL,
  CONSTRAINT g_monster_projectiles_pk PRIMARY KEY (map_id, projectile_id)
);

DROP TABLE IF EXISTS g_projectile_impacts PURGE;
CREATE TABLE g_projectile_impacts (
  map_id                 NUMBER(10)   NOT NULL,
  projectile_id          NUMBER(19)   NOT NULL,
  projectile_type        VARCHAR2(16) NOT NULL,
  owner_thing_id         NUMBER(10)   NOT NULL,
  x BINARY_FLOAT NOT NULL, y BINARY_FLOAT NOT NULL, z BINARY_FLOAT NOT NULL,
  target_player          BOOLEAN DEFAULT FALSE NOT NULL,
  target_thing_id        NUMBER(10),
  target_player_thing_id NUMBER(10),
  CONSTRAINT g_projectile_impacts_pk PRIMARY KEY (map_id, projectile_id)
);

DROP TABLE IF EXISTS g_projectile_damage PURGE;
CREATE TABLE g_projectile_damage (
  map_id        NUMBER(10)   NOT NULL,
  projectile_id NUMBER(19)   NOT NULL,
  damage_kind   VARCHAR2(16) NOT NULL,
  hit_index     NUMBER(10)   NOT NULL,
  thing_id      NUMBER(10)   NOT NULL,
  damage        NUMBER(10)   NOT NULL,
  CONSTRAINT g_projectile_damage_pk PRIMARY KEY (map_id, projectile_id, damage_kind, hit_index)
);

DROP TABLE IF EXISTS g_hitscan_hits PURGE;
CREATE TABLE g_hitscan_hits (
  map_id NUMBER(10) NOT NULL, player_thing_id NUMBER(10) NOT NULL, shot_serial NUMBER(19) NOT NULL,
  pellet NUMBER(5) NOT NULL, damage NUMBER(5) NOT NULL, thing_id NUMBER(10),
  sector_id NUMBER(10), no_blood BOOLEAN NOT NULL, distance BINARY_FLOAT NOT NULL,
  angle BINARY_DOUBLE NOT NULL, slope BINARY_DOUBLE NOT NULL,
  hit_kind VARCHAR2(8) NOT NULL, px BINARY_FLOAT NOT NULL, py BINARY_FLOAT NOT NULL,
  shoot_z BINARY_FLOAT NOT NULL, line_id NUMBER(10), line_from_front BOOLEAN,
  CONSTRAINT g_hitscan_hits_pk PRIMARY KEY (map_id, player_thing_id, shot_serial, pellet)
);

DROP TABLE IF EXISTS g_item_respawns PURGE;
CREATE TABLE g_item_respawns (
  map_id      NUMBER(10) NOT NULL,
  thing_id    NUMBER(10) NOT NULL,
  respawn_tic NUMBER(19) NOT NULL,
  CONSTRAINT g_item_respawns_pk PRIMARY KEY (map_id, thing_id)
);

DROP TABLE IF EXISTS g_mapped_lines PURGE;
CREATE TABLE g_mapped_lines (
  map_id  NUMBER(10) NOT NULL,
  line_id NUMBER(10) NOT NULL,
  CONSTRAINT g_mapped_lines_pk PRIMARY KEY (map_id, line_id)
);

DROP TABLE IF EXISTS g_player_weapons PURGE;
CREATE TABLE g_player_weapons (
  map_id          NUMBER(10)  NOT NULL,
  player_thing_id NUMBER(10)  NOT NULL,
  current_weapon  NUMBER(10)  DEFAULT 2 NOT NULL,
  pending_weapon  NUMBER(10),
  state           VARCHAR2(8) DEFAULT 'up' NOT NULL,
  seq_index       NUMBER(10)  DEFAULT 0 NOT NULL,
  tics            NUMBER(5)   DEFAULT 1 NOT NULL,
  flash_seq_index NUMBER(10),
  flash_tics      NUMBER(5)   DEFAULT 0 NOT NULL,
  sx              BINARY_FLOAT DEFAULT 1 NOT NULL,
  sy              BINARY_FLOAT DEFAULT 128 NOT NULL,
  shot_serial     NUMBER(19)  DEFAULT 0 NOT NULL,
  fired_this_tick BOOLEAN DEFAULT FALSE NOT NULL,
  CONSTRAINT g_player_weapons_pk PRIMARY KEY (map_id, player_thing_id)
);

DROP TABLE IF EXISTS g_player_weapon_owned PURGE;
CREATE TABLE g_player_weapon_owned (
  map_id          NUMBER(10) NOT NULL,
  player_thing_id NUMBER(10) NOT NULL,
  weapon_id       NUMBER(10) NOT NULL,
  CONSTRAINT g_player_weapon_owned_pk PRIMARY KEY (map_id, player_thing_id, weapon_id)
);

DROP TABLE IF EXISTS g_player_state PURGE;
CREATE TABLE g_player_state (
  map_id              NUMBER(10)   NOT NULL,
  player_thing_id     NUMBER(10)   NOT NULL,
  health              NUMBER(10)   DEFAULT 100 NOT NULL,
  alive               BOOLEAN      DEFAULT TRUE NOT NULL,
  level_tics          NUMBER(19)   DEFAULT 0 NOT NULL,
  previous_x          BINARY_FLOAT DEFAULT 0 NOT NULL,
  previous_y          BINARY_FLOAT DEFAULT 0 NOT NULL,
  position_x          BINARY_FLOAT DEFAULT 0 NOT NULL,
  position_y          BINARY_FLOAT DEFAULT 0 NOT NULL,
  base_z              BINARY_FLOAT DEFAULT 41 NOT NULL,
  view_z              BINARY_FLOAT DEFAULT 41 NOT NULL,
  view_angle          BINARY_FLOAT DEFAULT 0 NOT NULL,
  momentum_x          BINARY_FLOAT DEFAULT 0 NOT NULL,
  momentum_y          BINARY_FLOAT DEFAULT 0 NOT NULL,
  bob_strength        BINARY_FLOAT DEFAULT 0 NOT NULL,
  previous_view_z     BINARY_FLOAT DEFAULT 41 NOT NULL,
  previous_view_angle BINARY_FLOAT DEFAULT 0 NOT NULL,
  sector_id           NUMBER(10),
  pain_face_tics      NUMBER(10)   DEFAULT 0 NOT NULL,
  armor               NUMBER(10)   DEFAULT 0 NOT NULL,
  armor_class         NUMBER(5)    DEFAULT 0 NOT NULL,
  backpack            BOOLEAN      DEFAULT FALSE NOT NULL,
  ammo_bullets        NUMBER(10)   DEFAULT 0 NOT NULL,
  ammo_shells         NUMBER(10)   DEFAULT 0 NOT NULL,
  ammo_rockets        NUMBER(10)   DEFAULT 0 NOT NULL,
  ammo_cells          NUMBER(10)   DEFAULT 0 NOT NULL,
  key_blue            BOOLEAN      DEFAULT FALSE NOT NULL,
  key_yellow          BOOLEAN      DEFAULT FALSE NOT NULL,
  key_red             BOOLEAN      DEFAULT FALSE NOT NULL,
  radsuit_tics        NUMBER(10)   DEFAULT 0 NOT NULL,
  invis_tics          NUMBER(10)   DEFAULT 0 NOT NULL,
  momentum_z          BINARY_FLOAT DEFAULT 0 NOT NULL,
  damage_count        NUMBER(10)   DEFAULT 0 NOT NULL,
  bonus_count         NUMBER(10)   DEFAULT 0 NOT NULL,
  light_amp_tics      NUMBER(10)   DEFAULT 0 NOT NULL,
  power_map           BOOLEAN      DEFAULT FALSE NOT NULL,
  god_mode            BOOLEAN      DEFAULT FALSE NOT NULL,
  noclip              BOOLEAN      DEFAULT FALSE NOT NULL,
  invuln_tics         NUMBER(10)   DEFAULT 0 NOT NULL,
  berserk             BOOLEAN      DEFAULT FALSE NOT NULL,
  message             VARCHAR2(200),
  message_tics        NUMBER(10)   DEFAULT 0 NOT NULL,
  frags               NUMBER(10)   DEFAULT 0 NOT NULL,
  death_tics          NUMBER(10)   DEFAULT 0 NOT NULL,
  killer_id           NUMBER(10),
  sprite_frame        CHAR(1)      DEFAULT 'A' NOT NULL,
  CONSTRAINT g_player_state_pk PRIMARY KEY (map_id, player_thing_id)
);

DROP TABLE IF EXISTS g_game_tic_commands PURGE;
CREATE TABLE g_game_tic_commands (
  map_id           NUMBER(10)   NOT NULL,
  player_thing_id  NUMBER(10)   NOT NULL,
  command_serial   NUMBER(19)   DEFAULT 0 NOT NULL,
  skill            NUMBER(10)   DEFAULT 2 NOT NULL,
  skill_bit        NUMBER(10)   DEFAULT 2 NOT NULL,
  move_fwd         BINARY_FLOAT DEFAULT 0 NOT NULL,
  move_strafe      BINARY_FLOAT DEFAULT 0 NOT NULL,
  running          BOOLEAN      DEFAULT FALSE NOT NULL,
  turn_degrees     BINARY_FLOAT DEFAULT 0 NOT NULL,
  attack_held      BOOLEAN      DEFAULT FALSE NOT NULL,
  weapon_switch_to NUMBER(10),
  use_requested    BOOLEAN      DEFAULT FALSE NOT NULL,
  movement_mode    VARCHAR2(8)  DEFAULT 'idle' NOT NULL,
  CONSTRAINT g_game_tic_commands_pk PRIMARY KEY (map_id, player_thing_id)
);

DROP TABLE IF EXISTS g_level_stats PURGE;
CREATE TABLE g_level_stats (
  map_id          NUMBER(10) NOT NULL,
  player_thing_id NUMBER(10) NOT NULL,
  skill_bit       NUMBER(10) NOT NULL,
  level_tics      NUMBER(19) DEFAULT 0 NOT NULL,
  par_tics        NUMBER(19),
  kills           NUMBER(10) DEFAULT 0 NOT NULL,
  total_kills     NUMBER(10) DEFAULT 0 NOT NULL,
  items           NUMBER(10) DEFAULT 0 NOT NULL,
  total_items     NUMBER(10) DEFAULT 0 NOT NULL,
  secrets         NUMBER(10) DEFAULT 0 NOT NULL,
  total_secrets   NUMBER(10) DEFAULT 0 NOT NULL,
  completed       BOOLEAN DEFAULT FALSE NOT NULL,
  secret_exit     BOOLEAN DEFAULT FALSE NOT NULL,
  CONSTRAINT g_level_stats_pk PRIMARY KEY (map_id, player_thing_id)
);

DROP TABLE IF EXISTS g_level_secret_discoveries PURGE;
CREATE TABLE g_level_secret_discoveries (
  map_id          NUMBER(10) NOT NULL,
  player_thing_id NUMBER(10) NOT NULL,
  sector_id       NUMBER(10) NOT NULL,
  CONSTRAINT g_level_secret_discoveries_pk PRIMARY KEY (map_id, player_thing_id, sector_id)
);

DROP TABLE IF EXISTS g_pickup_touches PURGE;
CREATE TABLE g_pickup_touches (
  map_id          NUMBER(10)   NOT NULL,
  player_thing_id NUMBER(10)   NOT NULL,
  thing_id        NUMBER(10)   NOT NULL,
  kind            VARCHAR2(16) NOT NULL,
  amount          NUMBER(10)   NOT NULL,
  cap             NUMBER(10)   NOT NULL,
  is_set_min      BOOLEAN      NOT NULL,
  weapon_id       NUMBER(10),
  armor_class     NUMBER(5),
  CONSTRAINT g_pickup_touches_pk PRIMARY KEY (map_id, player_thing_id, thing_id, kind)
);

DROP TABLE IF EXISTS g_picked_up_items PURGE;
CREATE TABLE g_picked_up_items (
  map_id   NUMBER(10) NOT NULL,
  thing_id NUMBER(10) NOT NULL,
  CONSTRAINT g_picked_up_items_pk PRIMARY KEY (map_id, thing_id)
);

DROP TABLE IF EXISTS g_pickup_grants PURGE;
CREATE TABLE g_pickup_grants (
  map_id          NUMBER(10) NOT NULL,
  player_thing_id NUMBER(10) NOT NULL,
  weapon_id       NUMBER(10) NOT NULL,
  CONSTRAINT g_pickup_grants_pk PRIMARY KEY (map_id, player_thing_id, weapon_id)
);

DROP TABLE IF EXISTS g_tic_trace PURGE;
CREATE TABLE g_tic_trace (
  map_id          NUMBER(10) NOT NULL,
  player_thing_id NUMBER(10) NOT NULL,
  stages          NUMBER(19) NOT NULL,
  CONSTRAINT g_tic_trace_pk PRIMARY KEY (map_id, player_thing_id)
);

DROP TABLE IF EXISTS g_thing_health PURGE;
CREATE TABLE g_thing_health (
  map_id     NUMBER(10) NOT NULL,
  thing_id   NUMBER(10) NOT NULL,
  health     NUMBER(10) NOT NULL,
  max_health NUMBER(10) NOT NULL,
  alive      BOOLEAN    NOT NULL,
  CONSTRAINT g_thing_health_pk PRIMARY KEY (map_id, thing_id)
);

DROP TABLE IF EXISTS g_monster_steps PURGE;
CREATE TABLE g_monster_steps (
  map_id     NUMBER(10)   NOT NULL,
  thing_id   NUMBER(10)   NOT NULL,
  old_x      BINARY_FLOAT NOT NULL,
  old_y      BINARY_FLOAT NOT NULL,
  new_x      BINARY_FLOAT NOT NULL,
  new_y      BINARY_FLOAT NOT NULL,
  face_angle BINARY_FLOAT NOT NULL,
  movedir    NUMBER(5),
  movecount  NUMBER(5) DEFAULT 0 NOT NULL,
  CONSTRAINT g_monster_steps_pk PRIMARY KEY (map_id, thing_id)
);

DROP TABLE IF EXISTS g_monster_attack_damage PURGE;
CREATE TABLE g_monster_attack_damage (
  map_id        NUMBER(10)    NOT NULL,
  attacker_id   NUMBER(10)    NOT NULL,
  victim_id     NUMBER(10),
  victim_player NUMBER(10)    NOT NULL,
  dmg           NUMBER(10)    NOT NULL,
  mx            BINARY_DOUBLE NOT NULL,
  my            BINARY_DOUBLE NOT NULL
);

DROP TABLE IF EXISTS g_monster_teleports PURGE;
CREATE TABLE g_monster_teleports (
  map_id     NUMBER(10)   NOT NULL,
  thing_id   NUMBER(10)   NOT NULL,
  dest_x     BINARY_FLOAT NOT NULL,
  dest_y     BINARY_FLOAT NOT NULL,
  dest_angle BINARY_FLOAT NOT NULL,
  sector_id  NUMBER(10)   NOT NULL,
  CONSTRAINT g_monster_teleports_pk PRIMARY KEY (map_id, thing_id)
);

DROP TABLE IF EXISTS g_monster_deaths PURGE;
CREATE TABLE g_monster_deaths (
  map_id    NUMBER(10) NOT NULL,
  thing_id  NUMBER(10) NOT NULL,
  death_tic NUMBER(19) NOT NULL,
  CONSTRAINT g_monster_deaths_pk PRIMARY KEY (map_id, thing_id)
);

DROP TABLE IF EXISTS g_monster_respawns PURGE;
CREATE TABLE g_monster_respawns (
  map_id   NUMBER(10)   NOT NULL,
  thing_id NUMBER(10)   NOT NULL,
  old_x    BINARY_FLOAT NOT NULL,
  old_y    BINARY_FLOAT NOT NULL,
  CONSTRAINT g_monster_respawns_pk PRIMARY KEY (map_id, thing_id)
);

DROP TABLE IF EXISTS g_monster_ai PURGE;
CREATE TABLE g_monster_ai (
  map_id          NUMBER(10)  NOT NULL,
  thing_id        NUMBER(10)  NOT NULL,
  state           VARCHAR2(8) DEFAULT 'stand' NOT NULL,
  state_tics      NUMBER(10)  DEFAULT -1 NOT NULL,
  seq_index       NUMBER(10)  DEFAULT 0 NOT NULL,
  sector_id       NUMBER(10),
  attack_cooldown NUMBER(10)  DEFAULT 0 NOT NULL,
  fired_this_tick BOOLEAN DEFAULT FALSE NOT NULL,
  target_thing_id NUMBER(10),
  charge_tics     NUMBER(10)  DEFAULT 0 NOT NULL,
  movedir         NUMBER(5)   DEFAULT 0,
  movecount       NUMBER(5)   DEFAULT 0 NOT NULL,
  CONSTRAINT g_monster_ai_pk PRIMARY KEY (map_id, thing_id)
);
