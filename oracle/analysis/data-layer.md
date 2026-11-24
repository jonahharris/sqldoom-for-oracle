# Oracle data layer for the SQL Doom renderer

Status: the Oracle tables hold exactly the data the reference renderer
(`reference/sqldoom/sql/renderer.sql`) reads. `oracle/tests/verify_data.py`
checks this: **46/46 PASS** (33 static/derived checks against CedarDB, 13 state
tables against the parquet recording).

## Files

| File | Purpose |
|---|---|
| `oracle/sql/01_schema.sql` | DDL for the static and derived tables. Drops and recreates them, so it can be re-run. |
| `oracle/sql/02_state_schema.sql` | DDL for the per-tic `st_*` state tables. PK is `(tic, <reference pk>)`. |
| `oracle/sql/03_catalogs.sql` | Gameplay catalogs. The `INSERT`s are copied verbatim from `reference/sqldoom/sql/loader/game_data.sql`, with comments removed. They run unchanged on 23ai: multi-row `VALUES`, `TRUE`/`FALSE`. |
| `oracle/client/oradb.py` | Shared helpers: connection (`doom/doom@localhost:1521/FREEPDB1`, can be overridden with `DOOM_ORA_*` env vars), script runner, `DBMS_STATS`. |
| `oracle/client/load_wad.py` | Runs 01 and 03, parses the WAD in Python, bulk-loads it with `executemany`, derives the caches in SQL, then gathers stats. |
| `oracle/client/load_state.py` | For each parquet file: truncate the `st_*` table, insert, then gather stats. `--create` runs 02 first. |
| `oracle/tests/verify_data.py` | Compares Oracle against CedarDB and against the parquet files. Exits non-zero on any FAIL. |

To (re)initialize everything:

```sh
.venv/bin/python oracle/client/load_wad.py oracle/wad/freedoom1.wad E1M1 E1M2 E1M3   # schema 01 + catalogs 03 + WAD + derived + stats
.venv/bin/python oracle/client/load_state.py --run e1m1 --create                     # schema 02 + st_* + stats
.venv/bin/python oracle/tests/verify_data.py --run e1m1
```

## Tables, row counts and sizes

Sizes are from `user_segments`: table + PK index + LOB segments, in MB, measured after a fresh load.

| table | rows | MB | | table | rows | MB |
|---|---:|---:|---|---|---:|---:|
| maps | 3 | 0.13 | | colormap_rgb | 121,856 | 8.0 |
| vertexes | 5,403 | 0.44 | | walltex_meta | 963 | 24.6 |
| sectors | 892 | 0.19 | | flat_textures | 240 | 4.4 |
| sidedefs | 7,947 | 0.56 | | sprite_frames | 1,035 | 0.19 |
| linedefs | 5,634 | 0.50 | | sprite_lumps | 853 | 18.7 |
| things | 1,030 | 0.25 | | ui_patches | 242 | 6.3 |
| segs | 8,688 | 0.63 | | ui_patch_pixels | 847,460 | 53.0 |
| ssectors | 2,607 | 0.25 | | ui_hud_pixels | 37,975 | 3.0 |
| nodes | 2,604 | 0.25 | | ui_static_pixels | 10,240 | 0.56 |
| node_children | 5,208 | 0.63 | | thing_sprite_defs | 116 | 0.13 |
| node_path_steps | 36,281 | 1.81 | | thing_combat_defs | 21 | 0.13 |
| render_segs | 8,688 | 2.31 | | thing_ai_frames | 171 | 0.13 |
| render_things | 994 | 0.13 | | effect_sprite_defs / projectile_defs | 5 / 6 | 0.13 |
| sector_light_fx | 54 | 0.13 | | weapon_defs / weapon_frames / ammo_defs | 8 / 51 / 4 | 0.13 |
| | | | | line_special_defs | 135 | 0.13 |

Per-map counts (E1M1 / E1M2 / E1M3):

| table | E1M1 | E1M2 | E1M3 |
|---|---:|---:|---:|
| render_segs | 2057 | 3650 | 2981 |
| node_path_steps | 9056 | 15501 | 11724 |
| render_things | 280 | 341 | 373 |
| sectors | 182 | 380 | 330 |
| sector_light_fx | 9 | 18 | 27 |

The state tables come from the E1M1 run: 1,200 tics, skill 2.

| table | rows | MB |
|---|---:|---:|
| st_things | 352,126 | 45 |
| st_render_things | 337,726 | 26 |
| st_sectors | 218,400 | 24 |
| st_monster_ai | 61,200 | 6 |
| st_thing_health | 61,200 | 5 |
| st_sector_light_fx | 10,800 | 0.9 |
| st_player_weapon_owned | 9,600 | 0.8 |
| st_picked_up_items | 2,830 | 0.25 |
| st_monster_projectiles | 2,031 | 0.44 |
| st_world_effects | 1,400 | 0.25 |
| st_player_state | 1,200 | 0.5 |
| st_player_weapons | 1,200 | 0.25 |
| st_mp_players | 0 | 0 |

## Renames and type mapping

- **Only one rename:** `colormap_rgb.level` became `colormap_rgb.light_level`, because `LEVEL` is reserved in Oracle. The only other reserved column word in the reference schema is `blockmaps.rows`, and that table is not loaded.
- Integer types map to `SMALLINT`→`NUMBER(5)`, `INT`→`NUMBER(10)`, `BIGINT`→`NUMBER(19)`, and `NUMERIC(4,1)`→`NUMBER(4,1)`.
- `REAL` and `DOUBLE PRECISION` both map to `BINARY_DOUBLE`.
  - A float4 value widens exactly into a double. The parquet float32 columns therefore keep the exact float32 value, which is the value CedarDB used.
  - **Caveat for the renderer port:** where the reference does `real op real` arithmetic in float4, Oracle will compute in double. Most renderer arithmetic is already cast to float8.
- `BOOLEAN` maps to the native 23ai `BOOLEAN`. Enum types map to `VARCHAR2` holding the same labels. `TIMESTAMPTZ` maps to `TIMESTAMP WITH TIME ZONE`.
- `BYTEA` maps to `BLOB`, because textures, flats, sprites and UI patches are larger than `RAW(2000)`. The 3-byte colour columns (`colormap_rgb.rgb`, `ui_static_pixels.rgb`) are `RAW(3)`.
- The reference's materialized views become ordinary tables: `node_path_steps` (PK `map_id, ssector_id, depth`), `ui_hud_pixels` (PK `name, dx, dy`) and `ui_static_pixels` (PK `x, y`).
- Left out on purpose:
  - foreign keys
  - the `wads` table (`maps.wad_id` is kept as a plain column with value 1)
  - sounds, music, menus and the runtime-only tables
  - `sector_sound_origins`, `linedef_geom` and `sector_adjacency`, which the renderer does not read
- `line_special_defs` is loaded because it supplies the `linedefs.scrolls` / `cross_*` flags.

## Semantic notes

- **Pixel layout.** Pixel BLOBs are row-major palette indices, exactly as in the reference: `offset = v*width + u`. Use `DBMS_LOB.SUBSTR(blob, 1, v*width+u+1)` (1-based) or `UTL_RAW`.
  - `walltex_meta.palette_indices` is width×height bytes. Texels that no patch covers are 0.
  - `flat_textures.palette_indices` is 64×64 = 4096 bytes.
  - `sprite_lumps.pixels`/`mask` and `ui_patches.pixels`/`mask` are width×height. `mask` is 1 where the texel is opaque and 0 where it is transparent; `pixels` is 0 where the mask is 0.
- **`colormap_rgb`.** 14 palettes × 34 light levels × 256 = 121,856 rows. `rgb` = `RAW(3)` r,g,b of `PLAYPAL[pal][COLORMAP[level][palette_index]]`.
- **Empty strings and NULL.** The reference loader already turns an empty 8-byte texture name into NULL (`_nullable_tex`), so Oracle's rule that `''` is NULL loses nothing. The `'-'` no-texture marker is stored as is.
  - The one text column the renderer could see as `''` is `player_state.message`. The renderer only uses it under `message IS NOT NULL AND message_tics > 0`, and an empty message draws no glyphs either way. The recorded values are NULL or non-empty.
- **Map ids.** Maps get ids 1..n in WAD order, like the reference's `SERIAL` on a fresh database: E1M1=1, E1M2=2, E1M3=3.
- **How the derived data is computed.** Each one copies a reference query, translated to Oracle (`load_wad.DERIVE_SQL`):
  - **render_segs:** same as `doom_materialize_render_segs`. `seg_u1`/`seg_u2` = `offs + SQRT(TO_BINARY_DOUBLE(dx²+dy²))`, IEEE-identical to the reference.
  - **render_things:** same as `doom_materialize_render_things`. Recursive BSP descent; the side test is computed in `BINARY_DOUBLE`.
  - **node_path_steps:** the reference walks from the root to each leaf collecting arrays. Oracle walks from each leaf up to the root and numbers depth from the root. The rows are identical.
  - **ui_hud_pixels / ui_static_pixels:** the materialized-view queries.
  - **linedefs flags:** same as `stamp_line_specials`.
- **sector_light_fx.** The reference computes this only in `doom_reset_stage`, i.e. when a level is entered, and only for that map. Here it is computed at load for every map with the same query. Load state equals level-start state for sector lights.
  - Strobe rows added later by line specials (`12_cs_activate_specials`) are runtime state and come from `st_sector_light_fx`.
- **Recorded state.** Tic N in the `st_*` tables is the state after game tic N, which is the state frame N was rendered from.
  - `st_things` and `st_render_things` include dropped items (`id >= 100000`).

## Verification method (`verify_data.py`)

- **Comparison rules.** For each table, both sides are fetched, normalised, sorted and compared row by row:
  - integers exactly
  - floats at a relative tolerance of 1e-9
  - BLOB/bytea byte-exact
  - booleans and strings exactly
  - CedarDB enums are cast to `::text`
- **Hash.** It also prints a sha256 of the sorted rows on each side, with floats formatted `%.9g`. All hashes match.
- **Map 1 in CedarDB is not at load state.** E1M1 is the map being played in CedarDB, so its mutable columns no longer hold load values. Where the reference itself can restore them (`doom_reset_stage` logic), the verifier projects CedarDB's E1M1 values back to load state:
  - `sectors`: the `spawn_*` columns.
  - `things`: `spawn_x/y/angle`, `mom` = 0, `z` = 41, and only `id < 100000`.
  - `render_things`: `spawn_sector_id`.
  - `sidedefs` and `render_segs` textures: `line_buttons.original_tex`.
  - `render_segs` `f_*`/`b_*`: the spawn heights and light of the front and back sectors.
- **Maps 2 and 3** are compared exactly as stored.
- **sector_light_fx** is checked two ways:
  - against the `doom_reset_stage` query, run read-only on CedarDB for maps 1–3;
  - against CedarDB's live E1M1 rows.
- **State tables:** `st_*` is compared with the parquet files on full content (row counts and every value).
- **No unavoidable mismatches remain.** The only differences are the E1M1 runtime values in CedarDB listed above, which are not part of the static data. They are handled by the projection, so nothing is excluded without being checked.

## Gap for the renderer port: render_segs is partly dynamic

In the reference, the game tic updates some `render_segs` columns:

- `f_floor`, `f_ceil`, `f_ceil_tex`, `f_light`, `b_floor`, `b_ceil`, `b_ceil_tex`, `b_light` (in `13_cs_doors`, `12_cs_activate_specials` and `04_reset_stage`);
- `upper_tex`, `mid_tex`, `lower_tex` when a switch is pressed.

The recording does not snapshot `render_segs`, `sidedefs` or `line_buttons`.

- **Planes and light: can be derived.** The runtime keeps the plane/light cache equal to the current values of the front and back sectors; at the end of the run CedarDB shows 0 rows that differ. The port should therefore join `st_sectors` on `fsec`/`bsec` instead of reading the cached columns.
- **Switch textures: cannot be derived.** The swapped texture is not in the recording. A renderer that reads static `render_segs` textures will draw the unpressed switch texture. If pixel-exact frames are needed after a switch is pressed, add `render_segs` (or `sidedefs` + `line_buttons`) to `record_reference.py`'s `STATE_TABLES`.

## Load timings

Measured on the local 26ai Free container; Python 3 with python-oracledb thin mode.

**load_wad.py: 6.5 s in total** on an idle database (a re-run under concurrent load took 18 s).

| step | time |
|---|---:|
| schema + catalogs | 0.4 s |
| WAD decode + textures/sprites/UI (incl. 847k `ui_patch_pixels` rows) | 3.8 s |
| map geometry for 3 maps | 0.1 s |
| render_segs | 0.29 s |
| render_things | 0.13 s |
| node_path_steps | 0.25 s |
| ui_hud_pixels + ui_static_pixels | 0.15 s |
| sector_light_fx + linedef flags | 0.08 s |
| DBMS_STATS | 1.3 s |

**load_state.py: 6.4 s in total** on an idle database (18 s under load) for 1.06 M rows; `st_things` alone takes 3.4 s. `DBMS_STATS` is 0.65 s of that.

**verify_data.py: about 15 s.**
