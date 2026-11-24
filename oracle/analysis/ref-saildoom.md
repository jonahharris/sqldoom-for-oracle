# Reference analysis: SailDoom renderer (SQLDoom on Apache Sail / DataFusion)

Source: `reference/saildoom` (port of CedarDB's SQLDoom, `reference/sqldoom`).
Scope: the 3-D view renderer and its status-bar compositing. Game logic is covered only as far as
it decides what state the renderer reads. All paths below are relative to `reference/saildoom/`
unless they start with `sqldoom/`.

## 1. Executive summary

- **Three renderer SQL files.**
  - `sql/renderer_v1.sql` (about 106 CTEs) is a stage-by-stage port of `sqldoom/sql/renderer.sql`
    (about 90 CTEs; the report calls it "89-CTE"). It is pixel-exact, takes 9.8 s per frame, and
    keeps the original CTE names so that `reference/cte_diff.py` can diff each stage against
    CedarDB.
  - `sql/renderer.sql` (about 45 CTEs) is a rewrite as "one stream" that reads every heavy stage
    once. It takes 1.57 s per frame, or 0.71 s once the one-row side goes first in cross joins.
  - `sql/renderer_batch.sql` is generated from `renderer.sql` by `scripts/make_batch_renderer.py`.
    It renders N frames per query, keyed by `frame_id`. With 105 frames per query it costs 41 ms
    per frame, and 25.8 ms per frame with 4 concurrent clients. On a kept plan with 4 partitions a
    single frame takes 90 ms.
- **The CedarDB original takes 32 ms per frame.** In TPC-DOOM test R the p50 is 29 ms for
  CedarDB and 99.5 ms for Sail.
- **Planning dominates, not execution.** About one third of a frame's request is parsing and one
  third is physical planning. The data volume per frame is tiny (around 10^5 rows at peak). Every
  big win came from not re-planning (batching, plan cache, slots) or from not recomputing CTEs.
- **The algorithm is unchanged from CedarDB.** The structure is:
  1. precomputed BSP root-to-leaf paths, giving a per-frame front-to-back order of subsectors as
     a packed bigint sort key;
  2. per-seg projection, exploded into screen columns;
  3. occlusion and visplane clipping done as window functions per column;
  4. spans exploded into pixels;
  5. one join to a texel table;
  6. per-pixel lighting arithmetic;
  7. one `GROUP BY pix` with `MIN(packed 64-bit key)` as the z-buffer;
  8. a join to `colormap_rgb`.

## 2. Engine and runtime

- **Engine.** Apache Sail (Rust, on DataFusion 55.1.0) is spoken to over Spark Connect from
  PySpark 4.2. The dialect is Spark SQL.
- **Fork.** The authors use their own fork, `querygraph/sail work/recursive-cte`. It adds:
  - recursive CTEs, and computing a multiply-referenced CTE once (Sail main inlines a CTE at every
    reference);
  - "slot views": temp views whose rows are held in server memory;
  - a physical plan cache (`spark.sail.planCache`) and `spark.sail.targetPartitions`.
- **Tables.** Data lives in Parquet produced by exporting CedarDB (`reference/export_cedar.py`).
  `saildoom/engine.py::cut_map` cuts it per map and registers it as temp views under SQLDoom's
  table names.
- **Parameter substitution.** `saildoom/sqlmacro.py` expands macros and folds `${param}`
  literals, roughly like a C preprocessor:
  - `GS(a,b)` becomes a guarded `explode(sequence(a,b))`;
  - `PGINT(x)` becomes `CAST(bround(x) AS INT)`;
  - `DOOM_LIGHT_INDEX`, `DOOM_LIGHT_SCALE` and `DOOM_LIGHT_ZDEPTH` are inlined;
  - `${W}`, `${FOCAL}` and the other render constants become literals (`engine.CONSTANTS`).

## 3. Schema organization (what the renderer reads)

`engine.RENDER_TABLES` lists 38 views. They split into three groups.

**Static, precomputed at WAD load (CedarDB loader):**

| Table | Contents |
|---|---|
| `nodes(id,x,y,dx,dy)` | BSP partition lines |
| `node_children(node_id, side 'L'/'R', child_kind, child_node_id, child_ssector_id, bbox_top/bottom/left/right)` | each child's bounding box |
| `node_path_steps(ssector_id, depth, node_id, side)` | Materialized view, built by a recursive walk from the root (`sqldoom/sql/schema.sql:213`). One row per (subsector, ancestor node), giving the side taken at that node. About 6k rows for E1M1. |
| `linedefs.scrolls` | Boolean: wall scroll special 48 |
| `walltex_meta(name,width,height,tex_id)` | wall texture metadata |
| `flat_textures(name,flat_id)` | flat metadata |
| `sprite_frames(sprite,frame,rotation,lump_name,flipped,width,height,left_offset,top_offset)` | sprite frame directory |
| `sprite_lumps(lump_name,lump_id)` | sprite lump ids |
| `texels(tkey BIGINT, palette_index)` | Port-only. One unified texel table, described in section 4. |
| `colormap_rgb(pal, level, palette_index, rgb)` | rgb packed as an int `r<<16\|g<<8\|b` by `_rgb_int`; CedarDB stores a 3-byte bytea |
| `ui_static_pixels(x,y,palette_index,rgb)`, `ui_hud_pixels(name,dx,dy,palette_index)`, `ui_patches` | status bar background and glyph pixels |
| definition tables | `weapon_defs`, `weapon_frames`, `thing_combat_defs`, `thing_ai_frames`, `effect_sprite_defs`, `projectile_defs`, `ammo_defs`, `maps` (sky texture) |

**Dynamic, written by the game tic.** These are `engine.STATE_TABLES`, the "dynamic map state
read per frame":

| Table | What the renderer reads from it |
|---|---|
| `render_segs` | Denormalized: one row per seg with geometry `x1..y2`, texture u coordinates `seg_u1/seg_u2`, `fsec`/`bsec`, the three texture names, `flags`, and front/back floor, ceiling, ceiling texture and light, plus a precomputed `light_bias` (Doom's fake contrast for axis-aligned walls). Heights are rewritten by movers (doors, lifts), which is why it is a state table. All maps together: 141,000 rows. |
| `sectors` | floor/ceiling heights, flat names, light |
| `sector_light_fx` | base/dark light and special, so flicker and glow are a pure function of `level_tics` |
| `things` | x, y, z, angle, flags |
| `render_things` | per-thing BSP sector and the base sprite/frame, resolved at load |
| `thing_health`, `monster_ai` | state and seq_index, which select the sprite frame |
| `picked_up_items` | items to hide |
| `world_effects` | puffs and blood |
| `monster_projectiles` | projectiles in flight or impacting |
| `player_state` | `level_tics`, powerup tics, palette counters, HUD numbers, message, other players |
| `player_weapons`, `player_weapon_owned` | psprite state and weapon slots |
| `mp_players` | colour translation slot |

**Per frame:** the pose `(px, py, pz, angle)`, `map_id`, `player`, `skill`. `pz` is the absolute
eye height `view_z` and the angle is in degrees.

## 4. WAD and texture representation

- **CedarDB original.** Textures are blobs: `walltex_meta.palette_indices`,
  `flat_textures.palette_indices` and `sprite_lumps.pixels/mask` (bytea, row-major palette
  indices). They are sampled with `GET_BYTE(blob, v*width+u)` inside the pipeline. Wall textures
  are composited from patches at load. Index 0 is an opaque colour (`wad_loader._decode_patch`), so
  wall and mid textures have no alpha.
- **SailDoom: blobs become rows.** `export_cedar.py` expands the blobs into
  `walltex_texels(tex_id, off, palette_index)` (every texel), `flat_texels(flat_id, off, ...)`
  (every texel) and `sprite_texels(lump_id, off, ...)`. Sprite texels are opaque only
  (`mask <> 0`), so an inner join on them doubles as the mask test.
- **Per-map cut.** `engine.cut_map` keeps only the textures the map's sidedefs, sky and sectors
  can show, including the SW1/SW2 switch twins. It then builds one table:

  ```
  tkey = space << 40 | id << 20 | offset      -- space 1 = walls+sky, 2 = flats, 3 = sprites
  ```

  The table is sorted by `tkey`. Per the docstring this leaves "thousands of texels instead of
  millions".
- **One lookup.** All texture lookups (walls, sky, flats, sprites, weapon psprite) are one
  `LEFT JOIN texels tx ON tx.tkey = f.tkey` in `sampled`.
- **Sky.** The sky is a wall texture (`maps.sky_texture`). Its `tex_id` and width are folded in as
  `${sky_tex_id}` and `${sky_w}` from `meta.json`.

## 5. Pipeline trace: CTE names per stage (`sql/renderer.sql`)

### 5.0 Frame context

- `frame_clock` is `MAX(level_tics)` from `player_state`.
- `animated_light` evaluates every Doom light special as a closed-form function of `t`: strobes
  (2, 13, 3, 12), flicker (1), fire flicker (17), glow (8).
- `sectors_lit` is `sectors` with `animated_light` applied.
- `weapon_runtime` is the psprite state, plus:
  - `extra_light`: the weapon flash, or 16 with the light-amp visor;
  - `invuln`.

### 5.1 Camera to visibility: BSP and frustum

**`visible_children`.** This is a conservative frustum test for every `node_children` row. A
child box is kept if:
- the camera is inside the box, or
- the box is not entirely outside any of three half-planes (left FOV edge, right FOV edge, near
  plane).

Each half-plane is tested with the box's corner that minimizes it, which avoids enumerating four
corners:

```sql
((SIN(-vr) - TANH*COS(-vr)) * (CASE WHEN (SIN(-vr) - TANH*COS(-vr)) >= 0 THEN bbox_left ELSE bbox_right END)
 + (COS(-vr) + TANH*SIN(-vr)) * (CASE WHEN ... >= 0 THEN bbox_bottom ELSE bbox_top END)
 + (-px*SIN(-vr) - py*COS(-vr) + TANH*(px*COS(-vr) - py*SIN(-vr)))) <= 0.5
```

**`bsp_order`.** This replaces recursion. For every precomputed path step, decide which side of
that node the camera is on, using the integer cross product
`bround(px-n.x)*n.dy - bround(py-n.y)*n.dx > 0 → 'R'`. The back side adds `1 << (40 - depth)` to
the subsector's key:

```sql
SUM(CASE WHEN st.side = front_side THEN 0 ELSE shiftleft(1, 40 - st.depth) END) AS sort_key,
bool_and(vc.keep) AS visible            -- culled if any ancestor child box is culled
... GROUP BY st.ssector_id ...  ROW_NUMBER() OVER (ORDER BY sort_key) AS bsp_seq
```

Sorting by this key gives the exact front-to-back BSP traversal order. Subsectors under any culled
box are dropped. `bsp_seq = 1` is the camera's subsector.

### 5.2 Geometry

- **`seg_stream`.** `render_segs` is joined to `bsp_order`. Two windows run over the stream:
  - `ps_key = MIN(CASE WHEN bsp_seq = 1 THEN seg_id<<24 | fsec END) OVER ()` finds the camera
    sector. It replaces the original's `player_sector ... ORDER BY seg_id LIMIT 1`.
  - `rn` marks the lowest seg.
- **`seg_seeded`.** The lowest seg is exploded into 321 rows:
  `explode(CASE WHEN rn=1 THEN sequence(-1, W-1) ELSE array(-1) END) AS seed_x`. The
  `seed_x >= 0` rows are the 320 screen columns, which ride along through every later stage
  (every filter is written `seed_x >= 0 OR ...`). This avoids joining a `generate_series(0,319)`
  back onto the stream to make the camera sector's near floor and ceiling and the background.
- **`seg_ps`.** Joins the camera sector (`sectors_lit`) via `ps_key & 0xFFFFFF`.
- **`segs_view`.** Back-face culling with an integer cross product,
  `(x2-x1)*bround(py-y1) - (y2-y1)*bround(px-x1) < 0`, so of a two-sided line's two segs only the
  one facing the camera survives. It also does the world-to-view rotation:
  `vx = (x-px)cos(-vr) - (y-py)sin(-vr)`, `vy = -((x-px)sin(-vr) + (y-py)cos(-vr))`.
- **`segs_clipped`.** Keeps segs with `vx1 > 0 OR vx2 > 0`, then clips the endpoint to the near
  plane `NEAR = 1e-3` by linear interpolation.

### 5.3 Projection

- **`segs_projected`.**
  - `screen_x = CX + FOCAL*(cy/cx)`, with `CX=160`, `FOCAL = 160/tan(45°) = 160`, and a
    320x168 view.
  - `invx = 1/cx` is computed for perspective-correct interpolation.
- **`heights`.** Applies `screen_x` overlap with `[0, W)` (the original's `on_screen`), the
  scrolling texture offset `x_offset + t`, and the animated front light.
- **`parts`.** One `explode(array(named_struct(...)...))` per seg gives up to 7 wall parts plus
  one pseudo-part:

  | Part | Meaning |
  |---|---|
  | `solid` | one-sided wall |
  | `upper` | upper texture |
  | `upper_open` | clip-only, no texture |
  | `upper_flush` | clip-only, no texture |
  | `lower` | lower texture |
  | `lower_down` | clip-only, no texture |
  | `midmask` | masked mid texture |
  | `occl` | pseudo-part marking columns a one-sided or closed-door seg seals |

  Each part carries `z_bot`, `z_top` and the texture-V anchor (the lower/upper unpegged flags 16
  and 8). Sky hack: there are no upper parts when both ceilings are `F_SKY1`.
- **`part_cols`.** Each part is exploded over its covered screen columns:
  `sequence(max(0,floor(min(sx1,sx2))), min(W-1,ceil(max(sx1,sx2))))`.
  - Seed rows explode to their own `seed_x`.
  - The texture's width and height come from `walltex_meta`.
- **`columns`.** Occlusion:
  `MIN(CASE WHEN part='occl' THEN bsp_seq END) OVER (PARTITION BY col_x)`. Any part with a larger
  `bsp_seq` in that column is dropped. This is coarse occlusion: only a full solid occluder prunes,
  and partial overlap is left to the z-buffer. `t` is clamped to `[0,1]` to avoid T-junction
  cracks.
- **`per_column` and `per_column2`.** Perspective-correct `invx` and `u/x` are interpolated
  linearly in screen space, then:
  - `depth_x = 1/invx`;
  - `u_col = u_over_x/invx`;
  - `scale = FOCAL*invx`.
- **`vertical`.** `y_top_f = CY - scale*(z_top - pz)`, `y_bot_f` likewise, and `v_anchor_z`.

### 5.4 Raster: visplanes as per-column window scans

Doom's visplanes become a front-to-back scan in each column.

- **`panel`.** Sets `is_panel` and the clamped wall span `y_start`/`y_end`.
- **`panel_win`.** All windows are
  `PARTITION BY col_x ORDER BY depth_x, bsp_seq, part, seg_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING`:
  - `cc_before`: running `MAX` of ceiling clip (bottom of nearer solid/upper walls);
  - `fc_before`: running `MIN` of floor clip (top of nearer solid/lower walls);
  - `pc` and `pf`: `last(named_struct(sec,z,light,sky), ignoreNulls)`, the carried ceiling
    (nearest earlier panel whose ceiling is above the eye) and the carried floor;
  - `near_floor_depth` and `near_ceil_depth`: `MIN(depth_x) OVER (PARTITION BY col_x)` over
    floor-bounding and ceiling-bounding parts.
- **`panel_bounds`.**
  - `ceil_y1` and `floor_y0`. A carried plane is capped at `MAXPD = 16*FOCAL = 2560` map units to
    stop aliasing to the horizon.
  - Wall texture V: `v0 = v_anchor_z - (pz + (CY - y_start)/scale) + y_offset`, and
    `v_step = 1/scale`.
- **`spans`.** One `explode(array(...))` per row emits span structs of three kinds:

  | Kind | Spans |
  |---|---|
  | 0 | wall span |
  | 1 | plane span: front ceiling down to the panel, front floor up to the panel, and for seed rows the camera sector's floor and ceiling bounded by the nearest panel depth |
  | 2 | background: the full column, seed rows only |

- **`spans_dedup`.** `GROUP BY (kind, col_x, y0, y1, sector_id, plane_z, plane, span_sky, stable_id)`
  with `MIN` for the rest. This collapses identical plane spans before expansion: about 2k span
  rows instead of about 90k pixel rows, per the original's comment. It also applies the
  visible-side rule: a floor only when `plane_z < pz`; a ceiling only when `plane_z > pz` or sky.
- **`spans_tex`.** Plane spans get the flat name and `flat_id` from `sectors_lit` and
  `flat_textures`.
- **`span_pixels`.** `GS(y0, y1)` explodes every span into pixels. This is the largest
  intermediate relation.
- **`plane_geom`.** Plane depth is the inverse of the wall projection,
  `pdepth = FOCAL*(plane_z - pz)/(CY - y)`. Sky depth is the sentinel `1e7`.
  `tan_alpha = (x-CX)/FOCAL`. Rows with depth at or below `NEAR` are dropped.
- **`plane_uv`.**
  - Walls: `u = floor(u_col mod tex_w)` and `v = floor(v0 + (y-ystart)*v_step) mod tex_h`, using
    a positive modulo.
  - Flats: world `wx = px + d*cos(vr) + tan_alpha*d*sin(vr)` and
    `wy = py + d*sin(vr) - tan_alpha*d*cos(vr)`, then `mod 64` with a positive modulo.
  - Sky: `u = floor(degrees(vr - atan(tan_alpha)) * 256/90) mod 256` and `v = (y-100) mod 128`.
- **`view_fragments`.** Builds `tkey` and `stable_id`. For walls,
  `stable_id = seg_id*8 + part code`; for planes it is `sector*2 + (ceil?1:0)`.

### 5.5 Sprites

- **`thing_src`.** A `UNION ALL` of four sources:
  0. Things: dead/alive frame logic and `picked_up_items` anti-join; skill and multiplayer flag
     filters.
  1. World effects: frame taken from `frame_sequence` by age.
  2. Other players.
  3. Projectiles: per-type frame tables.

  For each it computes:
  - `depth = (x-px)cos(vr) + (y-py)sin(vr)`;
  - `side`;
  - `wanted_rotation = ((floor((deg(atan2) - angle + 202.5)/45) % 8 + 8) % 8) + 1`.
- **`thing_view`.** Adds the base z (floor, ceiling-hung or floating) and the sector light.
- **`thing_frame_choice`.** `ROW_NUMBER() OVER (PARTITION BY thing_id ORDER BY rotation =
  wanted ? 0 : 1)`. This replaces `LATERAL ... LIMIT 1`.
- **`thing_bounds`.** Projected rectangle: `scale = FOCAL/depth`, rejecting `depth < 4` and
  `|side| > 2*depth`.
- **`thing_cells`.** Rectangle exploded with `GS` over x and then y.
- **`sprite_fragments`.** Packs `u` and `v`, honouring `flipped`, into `tkey` space 3. The
  `mp_players` slot is carried for the green-to-colour translation of PLAY sprites.
- There is **no sprite clipping against walls** (no drawsegs). Sprites are depth-tested per pixel
  in the resolve. Sprites are also not attached to BSP visibility: every thing in the map is
  projected, and only the depth and side rejects cull.
- **`psprite_fragments`.** The weapon, plus its flash as layer 2, in screen space. Screen
  position is `sx - left_offset` and `sy - top_offset + CY - 100 - 0.5`.

### 5.6 Texture, light and depth resolve

- **`fragments`.** The union of view, sprite and psprite fragments, plus
  `cam_light = MAX(ps_light) OVER ()` (the camera sector light, carried on seed rows) and the
  weapon's `extra_light` and `invuln`. The one-row `weapon_runtime` comes first in the cross join
  (a Sail lesson; see section 9).
- **`sampled`.** `LEFT JOIN texels ON tkey`. Sprite and psprite fragments with no texel row are
  dropped (`WHERE kind IN (0,1,2) OR tx.tkey IS NOT NULL`), which is the transparency test. Walls
  and planes with no texel keep palette 0. The light index is then:

  | Fragment | `light_index` |
  |---|---|
  | invulnerable | 32 |
  | wall | `DOOM_LIGHT_INDEX(sector_light, light_bias + extra, DOOM_LIGHT_SCALE(depth))` |
  | plane | `DOOM_LIGHT_INDEX(light, extra, DOOM_LIGHT_ZDEPTH(depth))` |
  | sky | 0 |
  | sprite | scale-based, fullbright → 0, Spectre fuzz → `26 + ((x*7 + y*13 + PGINT(depth)) % 5)` |
  | psprite | `DOOM_LIGHT_INDEX(cam_light, extra, 23)` |

  The light macros:

  ```
  DOOM_LIGHT_INDEX(l,e,a)  = clamp(0,31, (15 - clamp(0,15, floor(l/16)+e))*4 - a)
  DOOM_LIGHT_SCALE(d)      = floor(clamp(0,47, 2560/d)/2)
  DOOM_LIGHT_ZDEPTH(d)     = floor(80/(min(127, floor(d/16))+1))
  ```

- **`resolved`.** One `GROUP BY pix` acts as the z-buffer. Smaller packed key wins:

  ```sql
  MIN(CASE WHEN kind IN (0,1,3) THEN
      shiftleft(bround(clamp(depth,0,131071)*4096), 34)   -- depth, 1/4096 unit fixed point
    | shiftleft(kind rank: wall 0, sprite 1, plane 2, 32)  -- tie-break: wall > sprite > plane
    | shiftleft(LEAST(source_priority,3), 30)              -- seed plane (0) beats panel plane (1)
    | shiftleft(clamp(stable_id+32768,0,65535), 14)        -- deterministic tie-break
    | shiftleft(light_index, 8) | palette_index END) AS wk,   -- payload rides in the low bits
  MAX(CASE WHEN kind = 4 THEN layer<<16 | light<<8 | palette END) AS pk   -- psprite overlay
  ```

  The payload (light and palette) is decoded from the winning key with shifts and masks. There is
  no `ROW_NUMBER` and no sort.
- **Holes.** Background fragments (kind 2) guarantee a row for every view pixel. They are excluded
  from `MIN`, so an uncovered pixel gets `wk` NULL and falls through to black. This replaces the
  original's `view_holes` `NOT EXISTS` over a 320x168 grid.

### 5.7 HUD and framebuffer

- **Status bar.**
  - `hud` holds the player numbers and the palette number `pal`, which follows
    `ST_doPaletteStuff`: damage gives palettes 1..8, bonus 9..12, radiation suit 13.
  - `hud_numbers`, then `hud_layers` (digits, keys, face, arms), then `hud_pixels` with
    `max_by(palette_index, layer)` per pixel.
  - `message_pixels` places the pickup message. The pen position is a running `SUM` of glyph
    widths over a window.
- **`frame_index`.** A view branch (`resolved` left-joined to the message) `UNION ALL` a
  status-bar branch (`hud CROSS JOIN ui_static_pixels` left-joined to the HUD overlay), giving
  `(pix, level, palette_index, fallback rgb)`.
- **Final select.**
  `LEFT JOIN colormap_rgb ON pal = hud.pal AND level AND palette_index ... ORDER BY pix`.
- **Output.** 64,000 rows of `(pix = y*320+x, rgb INT)`. The client unpacks them to 192,000 RGB
  bytes with numpy (`engine.render`, `render.ReusedRenderer.frame`). The 3-D view is rows
  0..167; the status bar is rows 168..199.

## 6. Client/DB boundary

- **SQLDoom's client loop.** The client calls `camera_pose` (`sqldoom/sql/client/camera_pose.sql`)
  to interpolate between tics: `previous_x + (x - previous_x)*alpha`, with the angle wrapped. It
  then executes the prepared `RENDER_FOLDED_STATEMENT` with `(x, y, z, angle)`.
- **On CedarDB**, the renderer returns one row: `string_agg(rgb, '' ORDER BY pix)`, a
  192,000-byte bytea.
- **On Sail**, `saildoom/backend.py` intercepts `doom_render_frame[_folded]` and forwards to
  `saildoom/api/render.py`. That module offers three renderers:

  | Class | How it renders |
  |---|---|
  | `Renderer` | Re-plans `renderer.sql` per pose with literals. |
  | `ReusedRenderer` (default) | Runs `renderer_batch.sql` with `frames = frame_pose`, a one-row slot. The state tables are slots refilled only when their version changes, so the plan is cached once per (map, player, skill). |
  | `RenderProcess` | The same, in a separate process. |

- The pose is passed as `CAST(<repr(float)> AS DOUBLE)`, deliberately through decimal text, to
  reproduce CedarDB's decimal-to-double rounding.

## 7. Precomputed vs per-frame

| Precomputed (load or map cut) | Per frame |
|---|---|
| BSP paths (`node_path_steps`) and child bboxes | `visible_children` (every child row) and `bsp_order` (GROUP BY over about 6k path steps) |
| Denormalized `render_segs` (seg, side and sector heights, tex names, `seg_u1/u2`, `light_bias`). Height columns are updated by the tic, not by the renderer. | All projection, clipping, columns, windows, spans, pixels |
| Texel table with packed `tkey`, cut per map | UV math per pixel, one join |
| `colormap_rgb` (14 palettes × levels × 256) as int rgb | Light index per pixel |
| `ui_static_pixels` (status bar background with rgb) | HUD digits and glyphs |
| `render_things` (thing sector at spawn) | Thing transform, rotation pick, rectangle explode |
| Light-effect parameters (`sector_light_fx`) | Closed-form light animation from `level_tics` |

## 8. Intermediate relation sizes

The repo reports no per-stage row counts directly. `scripts/profile_stages.py` prints them per CTE
when run. Collected figures:

| Relation | Size |
|---|---|
| `node_path_steps` | about 6k rows (E1M1) |
| `visible_children` | every `node_children` row of the map |
| visible seg parts (`wall_parts_tex`) | "a few hundred rows" |
| plane spans | about 2k after dedup, against about 90k plane pixel rows |
| things through the light math | about 50 things, against about 8,000 sprite pixels (the original's per-thing light) |
| `fragments` | about 165,000 rows (the "big CROSS JOIN one_row built the 165,000-row side, 164,700 one-row batches" case) |
| output | 64,000 rows (53,760 view + 10,240 status bar) |
| `render_segs`, all maps | 141,000 rows (one map is a few thousand) |

The fragment count implies wall pixels, plane pixels, background pixels (53,760, one per view
pixel) and sprite pixels together come to about 3x the view size.

The original has a `@stats-cut` debug overlay (`sqldoom/sql/client/render_stats_tail.sql`) that
counts `bsp_order`, `segs_with_verts`, `clamped_spans`, `fragments`, `plane_fragments`,
`sprite_fragments`, `ranked_fragments`, `resolved`, `view_holes` and `thing_view` inside the live
pipeline. Copy this for Oracle instrumentation.

## 9. Performance numbers

All measured on an M1 Max with 10 cores.

| Variant | Frame |
|---|---|
| CedarDB original | 32 ms (TPC-DOOM p50 29.2 ms, p95 36.5) |
| `renderer_v1` on Sail main | 9,800–10,183 ms (4,118 ms on the fork with shared CTEs) |
| `renderer.sql` | 1,570 ms; one-row side first in cross joins: 708 ms; fork: 733 ms |
| Batch, 35 frames per query | 58 ms per frame |
| Batch, 105 frames per query | 41 ms per frame (24.3 fps); fork: 39.3 ms |
| Batch, 105 frames, 2 or 4 clients | 29.5 ms per frame (33.9 fps); 25.8 ms per frame (38.8 fps) |
| Single frame, re-planned | 0.83 s |
| Single frame, kept plan | 0.17 s; with 4 partitions: 0.09 s |
| In the client | 0.11 s; 9.7 frames/s during play |
| TPC-DOOM test R, Sail p50 | 99.5 ms on the M1 Max, 166.6 ms on an 18-core Xeon |

## 10. (a) Every difference from the CedarDB original, and why

The why is one of three things. **[I]** is Sail's CTE inlining (a CTE referenced k times is
computed k times). **[P]** is planning cost. **[D]** is dialect or semantics. **[S]** is a Sail
bug workaround.

1. **Constants and parameters.** The original binds `$1..$7` and builds `render_context`, `pos`,
   `render_settings` and `cam` CTEs that are cross-joined everywhere. The port folds them in as
   literals, and the batch version reads a `cams` relation. [I][P]
2. **`WITH RECURSIVE` is dropped.** Nothing in the renderer recurses; the BSP paths are
   precomputed. [D]
3. **`player_sector`.** The original is `bsp_order ⋈ render_segs ⋈ sectors_lit ... ORDER BY
   seg_id LIMIT 1`, re-reading `render_segs`. The port uses a window over `seg_stream`:
   `MIN(seg_id<<24 | fsec) OVER ()` where `bsp_seq = 1`. [I]
4. **Seed rows.** The original builds the near floor and ceiling from
   `player_sector × generate_series(0,319) ⟕ nearest_floor_panel / nearest_ceiling_panel`
   (GROUP BYs over `panel_cols`). The port carries 320 seed rows through the stream from the start
   and reads the nearest depths as `MIN() OVER (PARTITION BY col_x)`. [I]
5. **`heights`, `seg_light_bias`, `seg_bsp`.** The original re-joins `render_segs` three times,
   using `seg_id + 0` as a CedarDB optimizer hack. The port carries every seg column from the
   first scan. The original's animated back-sector light `alb` is dropped as unused. [I]
6. **`wall_parts`.** The original is a 7-branch `UNION ALL` over `heights`, which is 7 references.
   The port is one `explode(array(named_struct...))` per seg row. [I]
7. **Occlusion.** The original is `occluders → occlusion_cols` (generate_series), then
   `min_occlusion` GROUP BY, then `LEFT JOIN` in `columns`. The port is an `occl` pseudo-part in
   the same explode, plus `MIN(...) OVER (PARTITION BY col_x)`. [I]
8. **Visplane clipping.** The original is `panel_seq` (`ROW_NUMBER`) plus two
   `LEFT JOIN LATERAL (... WHERE q.seq < p.seq AND f_ceil > pz ORDER BY seq DESC LIMIT 1)`
   self-joins in `panel_clips`. The port uses a running-window `last(struct, true) ROWS ...
   1 PRECEDING`. This is the single biggest structural change. [I][D]
9. **`panel_cols ⋈ heights`.** The join back is gone; the columns are carried. [I]
10. **Planes and walls.** The original's `plane_spans_raw` is a 4-branch `UNION ALL`, and walls
    flow separately through `clamped_spans → fragments → wall_tex → colored`. The port emits all
    span kinds from one explode per `panel_bounds` row, then has one `spans_dedup` (walls pass
    through) and one pixel explode. [I]
11. **Texture sampling.** The original uses `GET_BYTE(blob, v*w+u)` with range guards. The port
    joins a unified texel table on a packed key, and sprite opacity becomes join existence instead
    of `GET_BYTE(mask) <> 0`. Spark has no `GET_BYTE`, and a relational engine "joins on a texel
    far better than it carries a 16 KB blob through a join" (`export_cedar.py`). [D]
12. **Sprite frame pick.** `LATERAL ... ORDER BY ... LIMIT 1` becomes `ROW_NUMBER() ... pick = 1`.
    [D]
13. **Sprite lighting.** The original computes `base_light` once per thing (`thing_bounds_lit`, an
    explicit optimization). The port computes `DOOM_LIGHT_INDEX` per fragment in `sampled`, to keep
    one uniform resolve CTE. Effects and projectiles fall back to `cam_light` when they have no
    sector, which the port notes. [I] (a small regression of the original's optimization)
14. **Psprite resolve.** The original has `psprite_resolved` (`ROW_NUMBER` by layer), then
    `FULL JOIN` with `resolved` in `final_pixels`. The port folds it into the same `GROUP BY pix`
    as `MAX(layer<<16 | light<<8 | palette)`. [I]
15. **Holes.** The original's `view_holes` is a `NOT EXISTS` over a generated 320x168 grid. The
    port uses kind-2 background fragments. [I]
16. **Framebuffer.** The original computes `pix = y*4096+x`, has a fake `generate_series(0,255999)
    WHERE g+0<0` UNION branch ("hack to trick the optimizer"), and ends with
    `string_agg(rgb bytea ORDER BY pix)`. The port returns 64,000 `(pix = y*320+x, rgb int)` rows
    `ORDER BY pix`. Its comment says "a table of exact RGB values, as SQLDoom's own rule 3 allows".
    `colormap_rgb.rgb` is an int, not bytea. [D]
17. **HUD.** The original's `ui_layers`, `ui_resolved` (ARG_MAX), `ui_colored` and
    `message_colored` each join `palette_map`. The port uses `max_by(palette_index, layer)` and one
    final `colormap_rgb` join for view and status bar together. [I] DDD notes that `ARG_MAX` ties
    are arbitrary in CedarDB; secondary keys make them deterministic.
18. **Dialect rules.** [D]
    - Integer `/` becomes `DIV`.
    - Float-to-int cast becomes `PGINT` (`bround`, half-even), with explicit `FLOOR`/`CEIL` casts.
    - `generate_series` becomes `GS`, guarded because `sequence(a,b)` counts down when `a > b`.
    - Positive modulo via `((x % n) + n) % n`.
    - Three-valued logic is preserved: `NOT (explodes AND state='dead')`.
19. **Struct arrays in CASE.** Every branch's array items are made nullable, wrapping the seed
    struct in a never-NULL `CASE`, because of Sail bugs #2742 and #2747. [S]
20. **Cross-join order.** The one-row side goes first (`frame_clock CROSS JOIN segs_projected`,
    `weapon_runtime CROSS JOIN fragments`). Sail emits one batch per left row. [S/P]
21. **Per-map data cut.** Map tables are pre-filtered and texels limited to the map's textures, so
    `map_id` filters are mostly no-ops. [P]
22. **Batch form** (`renderer_batch.sql`). Every CTE carries `frame_id`, every window and GROUP BY
    adds `frame_id`, and every state table carries a `tic` column joined to `cams.tic` and bounded
    by `${tic_lo}..${tic_hi}`. The plan is the same for 1 or 105 frames. [P]
23. **Known renderer bug unique to the port.** At tic 730 of `run-e1m1-b`, the floor under the
    player is drawn with the wrong flat (17,443 px). It reproduces from CedarDB's own state, so it
    is the port's renderer. The likely suspects are the seed / `ps_key` camera-sector logic and
    `spans_dedup` merging seed and panel spans with `MIN(sector_light)`. Test this pose.

## 11. (b) Scenarios, test camera poses, and frame comparison

### What is in the repo, and what is not

**Not checked in** (`reference/` holds only scripts):
- `reference/cedar-e1m1/`, `reference/run-e1m1/` and `reference/run-e1m1-b/`;
- `data/freedoom1`;
- trace directories.

They must be regenerated against a CedarDB with SQLDoom loaded, using the scripts below.

**Checked in and directly reusable:**
- `tpc-doom/inputs/run-e1m1-b-commands.json`: 1,200 tic commands, SHA-256 `593c517b…f7ed94`.
  The format is
  `[{"tic": n, "command": [skill, fwd, strafe, run, turn, attack, weapon|null, use]}, ...]`.
- `tpc-doom/results/0001-*/cedardb-run{1,2,3}.json` and `sail-run*.json`, which contain:
  - `snapshots[i]`: the state after tic `i+1`, including `x, y, z, angle`. These are
    `player_state.position_x, position_y, view_z, view_angle`, which is exactly the camera pose
    at `alpha = 1.0`.
  - `frames[i]`: `"sha256:<hex>:192000"` digests of CedarDB's frame after each tic, 320×200×3 RGB.
- `tpc-doom/results/0001-*/frame-differences.json`: the tics where Sail differs, with pixel
  count, bounding box and cause. These are libm-sensitive poses, useful as numerical-robustness
  tests: for example tic 47 (28 px), tic 55, tic 91, tic 102, and tic 730 (the wrong-flat bug).
- `docs/blog/sail-runs-doom/assets/saildoom-tic-{300,450,620}-*.png`: visual references
  (Sail-rendered) for tics 300, 450 and 620 of the same run.

### Example poses

From `cedardb-run1.json`. The order is `(x, y, z = view_z, angle°)`. Values are float32, as
CedarDB `real`. Map E1M1 of Freedoom 0.13 `freedoom1.wad`, skill 2, player thing from
`load_stages`.

| Tic | x | y | z | angle | Note |
|---|---|---|---|---|---|
| 1 | -414.4375 | 256.0 | 41.094303 | 0.0 | start |
| 120 | 169.37871 | 30.595383 | 41.0 | 309.74954 | end of warm-up |
| 300 | 240.54483 | 245.18599 | -87.0 | 350.55923 | corridor (blog PNG) |
| 450 | 799.53156 | 601.45654 | -87.0 | 88.177124 | fight (blog PNG) |
| 620 | 1207.4082 | 943.0273 | -119.0 | 321.74557 | courtyard, imps |
| 730 | 1584.0486 | 1059.311 | -103.0 | 198.98091 | wrong-flat bug pose |
| 1200 | 681.29254 | 1713.5222 | -87.0 | 143.65121 | end |

### Data formats of the (regenerable) reference sets

- **`reference/cedar_reference.py`** (`--sqldoom --dsn --out reference/cedar-e1m1`).
  - Scripted commands, `scripted_command(n)`: forward 70 tics, turn, run, strafe, fire, turn
    back, forward with use.
  - Every 35 tics it writes `frames/E1M1_<nnnn>.rgb` (raw 192,000 bytes, row-major 200×320×3)
    and `poses.json` entries `[{"map":"E1M1","tic":n,"pose":[x,y,z,angle]}]`.
  - `timings.json` holds `{map, map_id, player_thing_id, skill, render_ms, tic_ms}`.
  - The default pose used by the tools is `E1M1:350`.
- **`reference/record_run.py`** (`--out reference/run-e1m1 --tics 700`, bot-driven).
  - For every tic: `frames/<ttttt>.rgb`, `poses.json` (`[{"tic","pose"}]`) and `commands.json`.
  - `state/<table>.parquet` holds every `STATE_TABLES` table with a leading `tic` column. This is
    the key feature: the renderer can be fed CedarDB's exact world at any tic, isolating the
    renderer from the game.
  - `run.json` records the map, player and skill.
  - `--tour` visits specials on E2M3, E2M4 and E2M7.
- **`reference/scenarios.py`** holds API-trace scenarios (`menus`, `campaign`, `automap`) for
  `trace_api.py` / `check_api.py`. These are call sequences, not render poses, except the automap
  frames.

### Comparison methodology

| Tool | Method |
|---|---|
| `reference/compare_frame.py` | Renders one pose, reshapes both frames to (200,320,3), counts pixels where any channel differs, prints the first coordinates and affected rows, and optionally writes a PNG of Sail, CedarDB and a diff mask side by side. Also times repeated renders. |
| `reference/compare_batch.py` | Renders a recorded run in batches from `state/` snapshots and compares every tic's frame. |
| `reference/cte_diff.py` | Stage-level oracle. Cuts both WITH queries at a named CTE (`SELECT * FROM <stage>`), compares the two results as multisets on shared columns with floats rounded to 6 significant digits, and reports the first differing rows. `--all` walks stages in order until the first difference. It works only because `renderer_v1.sql` keeps the original CTE names. |
| `scripts/profile_stages.py` | `SELECT count(*)` over each cut. Times are cumulative, and row counts come per stage. |
| TPC-DOOM test E | Frames compared by SHA-256 digest. Byte-identical is required, except differences traced to libm last bits; at most 1% may differ for other reasons. |

### How to reuse for Oracle

1. Use the 1,200 `snapshots` poses as deterministic camera poses. Bind them as
   `BINARY_DOUBLE` parsed from the same decimal text. Static-geometry frames will match CedarDB
   only if the dynamic state (doors, monsters, items, light tic) is also the same.
2. For exact pixel checks without porting the game, regenerate `record_run.py` output against
   CedarDB, load `state/*.parquet` (with `tic`) into Oracle, and render tic N from snapshot N.
   Compare to `frames/N.rgb`, or to the digest in `cedardb-run1.json` (`frames[N-1]`) for the
   `run-e1m1-b` command file.
3. Port `cte_diff.py`'s idea: keep stage names aligned with the original, and diff the multisets
   per stage against CedarDB at pose `E1M1:350`.
4. Expect libm last-bit differences (Oracle's own `SIN`/`COS`/`TAN`/`ATAN2` on `BINARY_DOUBLE`
   versus glibc). Budget them the way test E does: trace each differing frame to a single `FLOOR`
   flip.

## 12. (c) Performance lessons that transfer to another engine

1. **Read each heavy stage exactly once.** The original re-reads `heights` 7 times, `panel_seq` 3
   times and `render_segs` 4 times. That is fine on CedarDB, which shares CTEs, and fatal on an
   inlining engine. In Oracle:
   - check whether the optimizer inlines or materializes each multiply-referenced CTE
     (`/*+ MATERIALIZE */` / `/*+ INLINE */`);
   - prefer the single-stream shape regardless.
2. **Replace `UNION ALL` of filters over one input with a row multiplier.** The equivalent of
   `explode(array(struct...))` in Oracle is a `CROSS JOIN` to a small constant part table with
   `CASE`, `CROSS APPLY`, or `UNPIVOT`. Wall parts, span kinds and the HUD layers all use this.
3. **Replace `LATERAL ... LIMIT 1` and self-joins with window functions over the screen column.**
   - Running `MAX`/`MIN ... ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING` gives the clip
     bands.
   - `LAST_VALUE(... IGNORE NULLS)` gives carried planes.
   - `MIN() OVER (PARTITION BY col_x)` gives occlusion and nearest panels.

   One sort by `(col_x, depth_x, bsp_seq, part, seg_id)` serves all of them, so keep the identical
   window spec so the engine shares one sort.
4. **Seed rows instead of joins back.** Carry 320 per-column rows through the stream to produce
   per-column defaults (near floor and ceiling, background).
5. **Explode as late as possible and dedupe before expanding.** Collapse spans first (about 2k
   spans against about 90k pixels). Pixel rows (about 165k fragments) are the only large
   relation. Everything before `span_pixels` is hundreds to tens of thousands of rows.
6. **Precompute the BSP walk.** Use root-to-leaf path steps plus a packed bigint sort key
   `SUM(back ? 1 << (40-depth) : 0)` plus `bool_and(visible)`, which is one GROUP BY instead of
   recursion. The frustum test needs only the minimizing bbox corner per half-plane.
7. **Pack the z-buffer resolve into one 64-bit `MIN` per pixel.** Use fixed-point depth, then type
   rank, priority, stable id, and a payload of light and palette. It is one hash aggregate with no
   window or sort. In Oracle, `MIN(packed NUMBER)` or `KEEP (DENSE_RANK FIRST ORDER BY ...)`; the
   packed integer is simpler and deterministic.
8. **One texel table with a packed integer key, cut to the map.** Sprite texels hold only opaque
   texels, so the join is the alpha test. In Oracle, an IOT or clustered heap on `tkey`, or keeping
   blobs with `UTL_RAW.SUBSTR` / `DBMS_LOB.SUBSTR`, is a decision to benchmark. SailDoom chose rows
   because its engine lacked byte access.
9. **Compute per-object values per object, not per pixel.** The original's `thing_bounds_lit`
   gives about 50 rows instead of about 8,000. The port regressed this for uniformity.
10. **Background fragments instead of a hole anti-join.** Every pixel is guaranteed a row; NULL
    winner means black.
11. **Planning cost can dominate small, wide queries.** About 58 µs per expression to
    parse/resolve on Sail. The fixes:
    - plan once and reuse (prepared statement plus binds, or a cached plan reading a "pose"
      table);
    - batch many frames per query (a `frames` relation, `PARTITION BY frame_id`).

    For Oracle, ensure soft parses (binds, not literals). Note SailDoom first folded literals
    because its engine re-planned anyway, and that bind peeking on the pose is harmless because
    plan shape does not depend on it.
12. **Deep filter-on-derived-expression CTE chains can optimize superlinearly.** On Sail: 10
    levels 26 ms, 50 levels 1.2 s, 100 levels 26 s. Keep the chain shallow; derived columns in one
    projection are fine.
13. **Parallelism.** Small frames (64k output pixels) lose to repartitioning. Sail's best was 4
    partitions per frame (tic: 1 partition, 680 → 48 ms). Concurrency across clients scaled
    better than intra-query parallelism. For Oracle, start serial (no PX) and test a low DOP.
14. **Join order and build side.** "One-row side first" is Sail-specific, but the general lesson
    is that tiny dimension relations (pose, clock, weapon state) should be broadcast or constant,
    never drive per-row overhead. Without statistics, Sail built hash tables on the larger side
    (45 joins in the tic). Gather stats on the small state tables, or hint.
15. **Avoid wide NULL-padded struct and union layouts.** They cost planning (literal comparisons)
    and memory. Use narrow relations per kind.
16. **Output shape.** 64,000 `(pix, rgb)` rows plus client packing worked, while CedarDB
    aggregates one 192 KB bytea. In Oracle, compare row fetch with array size against
    server-side aggregation into a BLOB (for example `LISTAGG` limits, or a PL/SQL or JSON
    aggregation).
17. **Exactness traps.**
    - Postgres float→int casts round half-even, while CedarDB integer casts truncate.
    - Oracle `CAST(x AS INTEGER)` / `ROUND` round half away from zero, so emulate half-even where
      the original used `::bigint` or `::int` on floats (`PGINT` sites: the BSP side test,
      back-face test, fuzz).
    - Integer division needs `TRUNC(a/b)`.
    - Positive modulo needs `MOD(MOD(x,n)+n,n)`. Oracle `MOD` uses the dividend's sign, like `%`.
    - `generate_series(a,b)` must be empty when `a > b`.
    - Pose decimal-literal-to-double conversion (`215.18106079101562 → 0x406ae5cb3fffffff`).
    - CedarDB `real` arithmetic stays single precision; the camera interpolates `real - real`.
    - libm last bits flip `FLOOR` boundaries (5 of 526 frames, 1–8 px; 49 of 1,200 frames,
      1–273 px).
