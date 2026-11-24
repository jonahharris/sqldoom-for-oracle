-- =============================================================================
-- 07f_api_schema.sql -- the deathmatch server's own tables (CedarDB schema.sql: mp_referee,
-- mp_rotation, mp_holders, mp_waiting, api_roles, api_spectator_roles, api_tic_stats; the
-- audio tables of the reference loader: sound_assets, music_assets, map_music,
-- sector_sound_origins; wads)
--
-- The registries (api_roles, api_spectator_roles) and the audio tables are CREATE IF NOT
-- EXISTS: a reinstall keeps who was provisioned (client/api_install.py re-grants them), as
-- CedarDB's runtime install does. The match tables are game state and are recreated.
-- Timestamps are wall-clock housekeeping (heartbeat, idle reaping, the lobby queue) and are
-- never read by the tic.
-- =============================================================================
DROP TABLE IF EXISTS g_mp_referee PURGE;
-- one referee per match: its heartbeat (doom_mp.referee_claim / _beat / _release)
CREATE TABLE g_mp_referee (
  map_id    NUMBER(10) NOT NULL,
  heartbeat TIMESTAMP WITH TIME ZONE NOT NULL,
  CONSTRAINT g_mp_referee_pk PRIMARY KEY (map_id)
);

DROP TABLE IF EXISTS g_mp_rotation PURGE;
CREATE TABLE g_mp_rotation (
  position NUMBER(10)   NOT NULL,
  map_name VARCHAR2(16) NOT NULL,
  CONSTRAINT g_mp_rotation_pk PRIMARY KEY (position)
);

DROP TABLE IF EXISTS g_mp_holders PURGE;
-- who held which slot when a map ended (doom_mp.rotate carries them to the next map)
CREATE TABLE g_mp_holders (
  slot         NUMBER(10)    NOT NULL,
  role_name    VARCHAR2(128) NOT NULL,
  display_name VARCHAR2(128),
  claimed_at   TIMESTAMP WITH TIME ZONE,
  CONSTRAINT g_mp_holders_pk PRIMARY KEY (slot)
);

DROP TABLE IF EXISTS g_mp_waiting PURGE;
-- the lobby queue: a caller of api_join without a slot, first come first served
CREATE TABLE g_mp_waiting (
  role_name VARCHAR2(128) NOT NULL,
  since     TIMESTAMP WITH TIME ZONE NOT NULL,
  last_seen TIMESTAMP WITH TIME ZONE NOT NULL,
  CONSTRAINT g_mp_waiting_pk PRIMARY KEY (role_name)
);

-- the provisioned accounts (re-granted on every API install)
CREATE TABLE IF NOT EXISTS api_roles (
  role_name VARCHAR2(128) NOT NULL,
  CONSTRAINT api_roles_pk PRIMARY KEY (role_name)
);
CREATE TABLE IF NOT EXISTS api_spectator_roles (
  role_name VARCHAR2(128) NOT NULL,
  CONSTRAINT api_spectator_roles_pk PRIMARY KEY (role_name)
);

-- the referee's 5-second tic report (api_tic)
CREATE TABLE IF NOT EXISTS api_tic_stats (
  id               NUMBER(10) NOT NULL,
  updated_at       TIMESTAMP WITH TIME ZONE NOT NULL,
  tic_ms           BINARY_FLOAT NOT NULL,
  tic_p90_ms       BINARY_FLOAT NOT NULL,
  tic_max_ms       BINARY_FLOAT NOT NULL,
  tics             NUMBER(10) NOT NULL,
  dropped          NUMBER(10) NOT NULL,
  interval_seconds BINARY_FLOAT NOT NULL,
  CONSTRAINT api_tic_stats_pk PRIMARY KEY (id)
);

-- the reference loader's audio (wad_loader.load_sounds / load_music; client/load_audio.py)
CREATE TABLE IF NOT EXISTS sound_assets (
  name     VARCHAR2(8) NOT NULL,
  wav_data BLOB        NOT NULL,
  CONSTRAINT sound_assets_pk PRIMARY KEY (name)
);
CREATE TABLE IF NOT EXISTS music_assets (
  name         VARCHAR2(8) NOT NULL,
  mus_data     BLOB        NOT NULL,
  midi_data    BLOB        NOT NULL,
  audio_data   BLOB,
  audio_format VARCHAR2(64),
  CONSTRAINT music_assets_pk PRIMARY KEY (name)
);
CREATE TABLE IF NOT EXISTS map_music (
  map_id     NUMBER(10)  NOT NULL,
  music_name VARCHAR2(8) NOT NULL,
  CONSTRAINT map_music_pk PRIMARY KEY (map_id)
);
-- doom_materialize_render_segs's sound origin of a sector (the average of its boundary
-- vertices), used by the mover loops (sound_loops.sql)
CREATE TABLE IF NOT EXISTS sector_sound_origins (
  map_id    NUMBER(10)   NOT NULL,
  sector_id NUMBER(10)   NOT NULL,
  x         BINARY_FLOAT NOT NULL,
  y         BINARY_FLOAT NOT NULL,
  CONSTRAINT sector_sound_origins_pk PRIMARY KEY (map_id, sector_id)
);
CREATE TABLE IF NOT EXISTS wads (
  wad_id   NUMBER(10)     NOT NULL,
  wad_type VARCHAR2(8)    NOT NULL,
  wad_path VARCHAR2(1000) NOT NULL,
  CONSTRAINT wads_pk PRIMARY KEY (wad_id)
);

-- a role holds at most one slot (CedarDB's serializable api_join makes a second concurrent
-- claim by the same role fail; here the index does: ORA-00001 -> api_join answers -1)
CREATE UNIQUE INDEX IF NOT EXISTS g_mp_players_role ON g_mp_players (role_name);
