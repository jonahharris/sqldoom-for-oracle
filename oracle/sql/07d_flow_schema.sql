-- =============================================================================
-- 07d_flow_schema.sql -- level flow, screens, save/load, demos (phase 4)
--
-- The tables of reference/sqldoom/sql/schema.sql that the meta game flow reads and
-- writes (06 finish_level, 30 carry_player, 31 menu, 32 save/load, 33 intermission,
-- 36 finale, 38 doom_cheat_key, 41 flow, 44 automap_view), with the type mapping of
-- 07_game_schema.sql (REAL -> BINARY_FLOAT, BOOLEAN -> BOOLEAN, enums/TEXT -> VARCHAR2).
--   screen_state   one row (id 0): which full-screen state is up, the intermission tally
--                  machine, the finale, demo record/playback, the attract loop, the cheat
--                  sequence buffer. CedarDB's cheat_buffer is TEXT NOT NULL DEFAULT '':
--                  Oracle has no empty string, so '' is NULL here (compared as equal).
--   g_automap_view the automap camera per (map, player)
--   demos, demo_tics, save_slots, save_* (CedarDB: CREATE TABLE save_x AS SELECT 0 AS
--                  slot, * FROM x WHERE FALSE -- the same over the g_ twins here)
--   menu_items, menu_decor, finale_defs: static catalogs (07e_flow_catalogs.sql)
-- Re-runnable.
-- =============================================================================
DROP TABLE IF EXISTS screen_state PURGE;
CREATE TABLE screen_state (
  id               NUMBER(10)   NOT NULL,
  screen           VARCHAR2(16) NOT NULL,
  cursor_index     NUMBER(10)   DEFAULT 0 NOT NULL,
  episode          NUMBER(10)   DEFAULT 1 NOT NULL,
  skill            NUMBER(10)   DEFAULT 2 NOT NULL,
  tics             NUMBER(10)   DEFAULT 0 NOT NULL,
  inter_episode    NUMBER(10), inter_level NUMBER(10), inter_next NUMBER(10),
  kills_pct        NUMBER(10), items_pct NUMBER(10), secrets_pct NUMBER(10),
  time_secs        NUMBER(10), par_secs NUMBER(10),
  sp_state         NUMBER(10)   DEFAULT 0 NOT NULL,
  cnt_pause        NUMBER(10)   DEFAULT 0 NOT NULL,
  accelerate       BOOLEAN      DEFAULT FALSE NOT NULL,
  tgt_kills        NUMBER(10), tgt_items NUMBER(10), tgt_secrets NUMBER(10),
  tgt_time         NUMBER(10), tgt_par NUMBER(10),
  next_map_id      NUMBER(10),
  secret_exit      BOOLEAN      DEFAULT FALSE NOT NULL,
  finale_episode   NUMBER(10),
  finale_count     NUMBER(10)   DEFAULT 0 NOT NULL,
  finale_stage     NUMBER(10)   DEFAULT 0 NOT NULL,
  demo_recording   NUMBER(10),
  demo_playing     NUMBER(10),
  demo_tic         NUMBER(10)   DEFAULT 0 NOT NULL,
  attract_step     NUMBER(10)   DEFAULT -1 NOT NULL,
  attract_pagetic  BINARY_FLOAT DEFAULT 0 NOT NULL,
  cheat_buffer     VARCHAR2(64),
  CONSTRAINT screen_state_pk PRIMARY KEY (id)
);
INSERT INTO screen_state (id, screen) VALUES (0, 'title');

DROP TABLE IF EXISTS g_automap_view PURGE;
CREATE TABLE g_automap_view (
  map_id          NUMBER(10)   NOT NULL,
  player_thing_id NUMBER(10)   NOT NULL,
  center_x        BINARY_FLOAT DEFAULT 0 NOT NULL,
  center_y        BINARY_FLOAT DEFAULT 0 NOT NULL,
  zoom            BINARY_FLOAT DEFAULT 1 NOT NULL,
  follow          BOOLEAN      DEFAULT TRUE NOT NULL,
  grid            BOOLEAN      DEFAULT FALSE NOT NULL,
  cheat           NUMBER(5)    DEFAULT 0 NOT NULL,
  CONSTRAINT g_automap_view_pk PRIMARY KEY (map_id, player_thing_id)
);

DROP TABLE IF EXISTS demo_tics PURGE;
DROP TABLE IF EXISTS demos PURGE;
CREATE TABLE demos (
  demo_id         NUMBER(10)    NOT NULL,
  name            VARCHAR2(200) NOT NULL,
  map_id          NUMBER(10)    NOT NULL,
  player_thing_id NUMBER(10)    NOT NULL,
  skill           NUMBER(10)    NOT NULL,
  tic_count       NUMBER(10)    DEFAULT 0 NOT NULL,
  recorded_at     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT demos_pk PRIMARY KEY (demo_id)
);
CREATE TABLE demo_tics (
  demo_id          NUMBER(10)   NOT NULL,
  tic              NUMBER(10)   NOT NULL,
  move_fwd         BINARY_FLOAT NOT NULL,
  move_strafe      BINARY_FLOAT NOT NULL,
  running          BOOLEAN      NOT NULL,
  turn_degrees     BINARY_FLOAT NOT NULL,
  attack_held      BOOLEAN      NOT NULL,
  weapon_switch_to NUMBER(10),
  use_requested    BOOLEAN      NOT NULL,
  CONSTRAINT demo_tics_pk PRIMARY KEY (demo_id, tic)
);

DROP TABLE IF EXISTS save_slots PURGE;
CREATE TABLE save_slots (
  slot            NUMBER(10)    NOT NULL,
  saved_at        TIMESTAMP     NOT NULL,
  name            VARCHAR2(200) NOT NULL,
  map_id          NUMBER(10)    NOT NULL,
  player_thing_id NUMBER(10)    NOT NULL,
  map_name        VARCHAR2(16),
  skill           NUMBER(10)    NOT NULL,
  CONSTRAINT save_slots_pk PRIMARY KEY (slot)
);

DROP TABLE IF EXISTS save_player_state PURGE;
CREATE TABLE save_player_state AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_player_state t WHERE 1 = 0;
DROP TABLE IF EXISTS save_player_weapons PURGE;
CREATE TABLE save_player_weapons AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_player_weapons t WHERE 1 = 0;
DROP TABLE IF EXISTS save_player_weapon_owned PURGE;
CREATE TABLE save_player_weapon_owned AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_player_weapon_owned t WHERE 1 = 0;
DROP TABLE IF EXISTS save_things PURGE;
CREATE TABLE save_things AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_things t WHERE 1 = 0;
DROP TABLE IF EXISTS save_thing_health PURGE;
CREATE TABLE save_thing_health AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_thing_health t WHERE 1 = 0;
DROP TABLE IF EXISTS save_monster_ai PURGE;
CREATE TABLE save_monster_ai AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_monster_ai t WHERE 1 = 0;
DROP TABLE IF EXISTS save_monster_projectiles PURGE;
CREATE TABLE save_monster_projectiles AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_monster_projectiles t WHERE 1 = 0;
DROP TABLE IF EXISTS save_world_effects PURGE;
CREATE TABLE save_world_effects AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_world_effects t WHERE 1 = 0;
DROP TABLE IF EXISTS save_sectors PURGE;
CREATE TABLE save_sectors AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_sectors t WHERE 1 = 0;
DROP TABLE IF EXISTS save_sidedefs PURGE;
CREATE TABLE save_sidedefs AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_sidedefs t WHERE 1 = 0;
DROP TABLE IF EXISTS save_sector_movers PURGE;
CREATE TABLE save_sector_movers AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_sector_movers t WHERE 1 = 0;
DROP TABLE IF EXISTS save_line_buttons PURGE;
CREATE TABLE save_line_buttons AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_line_buttons t WHERE 1 = 0;
DROP TABLE IF EXISTS save_line_activations PURGE;
CREATE TABLE save_line_activations AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_line_activations t WHERE 1 = 0;
DROP TABLE IF EXISTS save_picked_up_items PURGE;
CREATE TABLE save_picked_up_items AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_picked_up_items t WHERE 1 = 0;
DROP TABLE IF EXISTS save_level_secret_discoveries PURGE;
CREATE TABLE save_level_secret_discoveries AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_level_secret_discoveries t WHERE 1 = 0;
DROP TABLE IF EXISTS save_level_stats PURGE;
CREATE TABLE save_level_stats AS SELECT CAST(0 AS NUMBER(10)) AS slot, t.* FROM g_level_stats t WHERE 1 = 0;

-- ------------------------------------------------------------ static catalogs
DROP TABLE IF EXISTS menu_items PURGE;
CREATE TABLE menu_items (
  screen VARCHAR2(16) NOT NULL,
  idx    NUMBER(10)   NOT NULL,
  patch  VARCHAR2(16),
  x      NUMBER(10)   NOT NULL,
  y      NUMBER(10)   NOT NULL,
  CONSTRAINT menu_items_pk PRIMARY KEY (screen, idx)
);
DROP TABLE IF EXISTS menu_decor PURGE;
CREATE TABLE menu_decor (
  screen VARCHAR2(16) NOT NULL,
  seq    NUMBER(10)   NOT NULL,
  patch  VARCHAR2(16) NOT NULL,
  x      NUMBER(10)   NOT NULL,
  y      NUMBER(10)   NOT NULL,
  CONSTRAINT menu_decor_pk PRIMARY KEY (screen, seq)
);
DROP TABLE IF EXISTS finale_defs PURGE;
CREATE TABLE finale_defs (
  episode    NUMBER(10)     NOT NULL,
  flat       VARCHAR2(8)    NOT NULL,
  patch      VARCHAR2(8)    NOT NULL,
  story_text VARCHAR2(4000) NOT NULL,
  CONSTRAINT finale_defs_pk PRIMARY KEY (episode)
)
