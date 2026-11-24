# Reference implementation analysis

Three SQL Doom implementations live under `reference/`:

| Reference | Engine | Renderer | Detailed analysis |
|---|---|---|---|
| `reference/sqldoom` | CedarDB (Postgres wire) | one ~90-CTE prepared query, `sql/renderer.sql` (1,634 lines) | this file |
| `reference/saildoom` | Apache Sail / DataFusion | port of the CedarDB renderer (stage-exact v1, one-stream rewrite, batched variant) | [ref-saildoom.md](ref-saildoom.md) |
| `reference/DoomSQL` | SQL Server (T-SQL) | independent per-column renderer in procedures | [ref-doomsql.md](ref-doomsql.md) |

**Choice of ground truth.** CedarDB SQLDoom is the most complete and most faithful of the three:
it is the only one with BSP ordering, Doom's light tables (`scalelight`/`zlight`), sector light
animation, sprite rotations, the weapon psprite and the full status bar. saildoom is a port of it
and already provides a deterministic 1,200-tic gameplay run (TPC-DOOM `run-e1m1-b`) with
published CedarDB frame digests. DoomSQL departs from Doom in several ways (linear lighting,
mirrored flats, no masked midtextures, 200-row view). CedarDB SQLDoom is therefore the
correctness reference, and it is run for real (`cedardb/cedardb` image, see
`tests/record_reference.py`). The replay reproduces 1,180 of 1,200 of the published TPC-DOOM
CedarDB frames byte for byte; the 20 others are newer-CedarDB/libm effects in the published run.

## CedarDB SQLDoom renderer (`reference/sqldoom/sql/renderer.sql`)

### Engine, boundary, output
* CedarDB, Postgres wire protocol, one prepared statement per frame with binds
  `(map_id, player_thing_id, skill, x, y, z, angle)`.
* Output: one `bytea` of 192,000 bytes (320×200 RGB) produced by `string_agg(rgb ORDER BY pix)`.
  Python only blits it.
* Canonical resolution: 320×200 = a 320×168 3-D view plus Doom's 32-row status bar
  (`screen_h = 168`, `cy = 84`), exactly vanilla's default `screenblocks` layout.

### Schema / WAD representation
* WAD lumps map 1:1 to tables (`vertexes, linedefs, sidedefs, sectors, segs, ssectors, nodes,
  things`). `node_children` holds one row per (node, side) with the child's bounding box.
* Load-time materialisation: `render_segs` (seg ⨝ vertexes ⨝ linedef ⨝ both sidedefs ⨝ both
  sectors — the per-seg wide row the renderer needs, ~1 row/seg), `node_path_steps` (every
  subsector's root-to-leaf path, one row per (subsector, ancestor); 6.3k rows for E1M1),
  `render_things` (spawn sector via BSP descent), `sector_light_fx`.
* Textures: `walltex_meta(name, width, height, palette_indices bytea)` — composited TEXTURE1/2
  textures, row-major; transparent texels are 0 (so masked midtextures render opaque/black).
  `flat_textures(name, bytea[4096])`. Sprites: `sprite_lumps(pixels, mask)` row-major with an
  opacity mask; `sprite_frames(sprite, frame, rotation → lump, flipped, offsets)`.
* `colormap_rgb(pal, level, palette_index → mapped_index, rgb)`: 14 palettes × 34 colormaps ×
  256 indices — PLAYPAL and COLORMAP pre-joined.

### Pipeline (camera → framebuffer), with E1M1 run cardinalities
Cardinalities measured over the 1,200-tic run, every 5th tic (`benchmark/cedar_stats.py`,
splicing the reference's own `@stats-cut` counting projection). Median / p95 / max.

| Stage | CTEs | Rows |
|---|---|---|
| frame state | `render_context, pos, frame_clock, animated_light, sectors_lit, weapon_runtime` | ~1 |
| frustum test per BSP child | `visible_children`: 3 half-planes (left/right FOV edge, near) vs bbox, picking the min corner by sign of the plane normal (= support function) | 1,362 → kept 354 / 1,059 / 1,188 |
| BSP order | `bsp_order`: `SUM(back ? 1<<(40-depth) : 0)` over `node_path_steps` grouped by subsector → bigint path key → `ROW_NUMBER() OVER (ORDER BY key)`; subsector kept iff all ancestors' children kept (`BOOL_AND`) | 164 / 518 / 579 subsectors |
| camera sector | `player_sector`: first seg of bsp_seq = 1 | 1 |
| seg selection | `segs_with_verts`: segs of ordered subsectors, back-face cull by 2-D cross product | 278 / 762 / 864 |
| transform/clip/project | `viewspace → visible → clipped (near plane 1e-3, in camera space before division) → projected → on_screen` | ≤ segs |
| wall parts | `heights` (+animated light, scrolling) → `wall_parts`: 7-way UNION ALL unpivot: solid, upper, upper_open (clip-only), upper_flush (clip-only), lower, lower_down (clip-only), midmask | ~1.5× segs |
| solid occlusion | `occluders → occlusion_cols` (solid seg × its screen columns) `→ min_occlusion` = MIN(bsp_seq) per column | ≤ 320 |
| wall columns | `columns`: wall part × `generate_series(FLOOR(min sx), CEIL(max sx))`, dropped where `bsp_seq > min_occlusion`; `per_column`: perspective-correct 1/z and u/z interpolation | = `wall_spans` 1,413 / 3,363 / 3,824 |
| vertical extent | `vertical → clamped_spans`: `y_top/y_bot = cy − scale·(z − pz)`, `CEIL/FLOOR` clamp, V origin and step | |
| wall pixels | `fragments`: `generate_series(y_start, y_end)` → `wall_tex` (`GET_BYTE`) | 42k / 63k / 83k |
| visplanes | `panel_cols → panel_seq (ROW_NUMBER per column by depth_x, bsp_seq, part, seg) → panel_clips` (running MAX of ceiling clip / MIN of floor clip over preceding panels via window frames, + "carried" ceiling/floor via `LATERAL … ORDER BY seq DESC LIMIT 1`) `→ plane_spans_raw` (front ceiling/floor spans per panel + 2×320 camera-sector seed spans) `→ plane_spans → plane_spans_deduped` | ~2k spans |
| plane pixels | `plane_pixels` (`generate_series(y0,y1)`) `→ plane_rays → plane_world` (per-pixel inverse projection with `COS/SIN/ATAN`) `→ plane_uv → plane_color → plane_lit` (`zlight`) | 24k / 37k / 44k |
| sprites | `thing_view` (things ∪ effects ∪ other players ∪ projectiles; frame from AI state; rotation from `ATAN2`) `→ thing_projected` (lateral `LIMIT 1` rotation pick) `→ thing_bounds → thing_pixels` (`generate_series` x × y, mask test) | 2.1k / 4.6k / 56k px |
| depth resolve | `fragment_union → ranked_fragments`: one bigint key `(depth·4096 clamped 17.12)<<34 | (2−surface)<<32 | source<<30 | stable<<14 | light<<8 | palette`, then `MIN(key) GROUP BY pix` | 64k / 87k / 123k → 53,760 |
| weapon | `psprite_layers → psprite_pixels → psprite_resolved` (topmost layer per pixel) `→ final_pixels` (FULL JOIN overlay) | 1.6k / 5k / 6.5k |
| status bar | `player_ui_state … digit_layers … ui_resolved` over precomputed `ui_static_pixels` (10,240 rows) | 10,240 |
| colour | `view_colored` (`colormap_rgb` join), `view_holes` (anti-join for uncovered pixels), `framebuffer` → `string_agg ORDER BY pix` | 64,000 |

### Technique notes (what each piece is *for*)
* **Precomputed BSP paths + bigint key.** Replaces recursive descent with one aggregate over
  ~6k rows; bit `40−depth` set for "back" choices makes the key sort front-to-back. Limits depth
  to 40 and needs a `ROW_NUMBER` sort. (Hypothesis 2's order-statistics rank removes the sort.)
* **Frustum culling** is a support-function test written out with `CASE` on the sign of each
  plane-normal component — conservative, 3 planes, per (node, side).
* **Occlusion** is only *solid-wall per-column* and only by BSP order — partial occlusion is left
  to the per-pixel depth resolve. Subtrees are never rejected hierarchically.
* **Visplanes** are reconstructed per column, Doom-style, from running clip bounds; floors and
  ceilings are emitted as per-column *vertical* spans then expanded to pixels, each pixel
  inverse-projected with transcendental functions.
* **Depth resolve** is a generic z-buffer: every wall, plane and sprite fragment competes in one
  64k–123k-row `GROUP BY pix`. Texture sampling and lighting happen *before* the resolve (the
  winning palette and light index ride in the low bits of the key), so losing fragments are
  fully shaded and discarded.
* **Lighting:** Doom's `scalelight` (walls/sprites, by 1/depth), `zlight` (planes, by depth),
  `extralight` from weapon flash / light-amp, invulnerability colormap 32, fake contrast
  (`light_bias` ±1 for axis-aligned segs). COLORMAP applied in the final join.

### Departures from vanilla Doom (all reproduced by our Oracle renderers, since this is the ground truth)
Floating-point math instead of fixed point; plane depth cap (`max_plane_depth`, 16 × focal) for
carried planes; masked midtextures opaque and tiled over the full front-sector height; Spectre
fuzz as a per-pixel hash; sky indexed by view angle and screen row; seg column range
`FLOOR..CEIL` (one column wider each side, `t` clamped).

**Sprites clipped by floors and ceilings (the z-buffer).** Vanilla draws the planes first and then each
sprite (`R_DrawSprite` / `R_DrawVisSprite`) clipped only by the *silhouettes* of the drawsegs in front of
it: per column the `sprtopclip`/`sprbottomclip` snapshot (the ceiling/floor clip right after that seg was
drawn) of the farthest seg nearer than the sprite whose silhouette applies (`SIL_BOTTOM` when the front
floor is above the back floor and above the sprite's foot `gz`, or the back floor is above the eye;
`SIL_TOP` symmetrically with `gzt`; closed sectors and masked midtextures always), never by a plane. The
reference resolves sprites in its one z-buffer against walls *and* floor/ceiling fragments. Many sprite
patches hang below their foot (top offset < height: barrel BAR1 4 px, BON1 4, BON2 2, COLU 5, ELEC 5,
corpses …), and those rows lose against the floor in front of them: items look sunk into the floor, and
a sprite poking above its ceiling is cut by it. The Oracle renderers reproduce this by default (it is the
ground truth); `doom_hybrid` has an opt-in vanilla sprite mode (`p_mode => 1`, the playable clients'
default) that implements Doom's silhouette clipping instead — see [hybrid-design.md](hybrid-design.md),
"Sprite modes".

### Largest intermediates / cost structure
`fragments` (wall pixels) and `ranked_fragments` (the z-buffer union) dominate; both are
pixel-granular and every pixel row carries texture sampling, light computation and a 64-bit key
build. The reference's own timing on this host: **16.2 ms median, 20.7 ms p95** (CedarDB using
all 12 host cores, server+fetch, hot prepared statement).

## Cross-reference summary

| Topic | CedarDB SQLDoom | saildoom | DoomSQL |
|---|---|---|---|
| BSP traversal | precomputed paths, bigint key, ROW_NUMBER | same | none (per-column 1/z sort) |
| Frustum | support-function bbox test | same | per-seg |
| Occlusion | per-column solid MIN(bsp_seq) | same | none before sort (68% of seg-columns discarded late) |
| Floors/ceilings | per-column window clips + per-pixel inverse projection | window clips via `last(…ignoreNulls)` | per seg-column between running clips |
| Depth resolve | packed-key MIN over all fragments | same, plus background fragments | none — clip windows make pixels unique |
| Textures | row-major bytea + GET_BYTE | texel table (one join for all surfaces) | per-column varbinary + SUBSTRING |
| Output | 192 KB RGB bytea | 64,000 rows | 24-bit BMP |

Two ideas from the other references survive into the Oracle design: DoomSQL's observation that
per-column clip windows make each pixel unique (no z-buffer), and saildoom's replacement of
`LATERAL … LIMIT 1` by `LAST_VALUE … IGNORE NULLS` window functions.
