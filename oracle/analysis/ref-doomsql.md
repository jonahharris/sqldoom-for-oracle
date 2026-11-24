# Reference analysis: DoomSQL (SQL Server / T-SQL)

Source: `reference/DoomSQL` (https://github.com/sqlartist/DoomSQL, commit 41eff29) (5 commits, author's Medium write-up linked from README). Analysed read-only. Cardinality figures marked *measured* came from re-running the reference's projection logic in Python against `oracle/wad/freedoom1.wad` E1M1 (same build: 2057 segs, 682 subsectors, 681 nodes, matching the row counts in `E1M1_freedoom.sql`).

## 1. Bottom line

- **The renderer has no BSP walk.** `render_frame` projects every seg facing the camera, expands each one into (seg, screen column) rows, and sorts each column by `1/z`. Doom's `ceilingclip`/`floorclip` arrays become **windowed prefix aggregates** (`MAX/MIN ... OVER (PARTITION BY x ORDER BY inv_z DESC ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)`). This is the central idea, and it carries straight over to Oracle.
- The whole wall/flat pass is **one `INSERT ... SELECT` with a chain of CTEs** into a 64,000-row `framebuffer(y,x,pal_idx,light)`. The PK on (y,x) also checks that each pixel is written exactly once.
- The framebuffer stores the **unlit texel index plus a light level 0..31**. COLORMAP and PLAYPAL are applied only in the presentation step (`frame_bmp`). The final 8-bit index is never stored, but one join produces it: `colormap(light, pal_idx).out_idx`.
- The renderer approximates vanilla Doom in several places: float math instead of fixed point, a linear distance-light model, flats that appear mirrored in Y, a sky that fills every hole, no sky hack, no masked midtextures, and a full-height view with the status bar painted on top. It is "Doom-like", not pixel-exact vanilla.
- `render_ref.py` implements **the same approximate algorithm** in Python (the SQL is a transliteration of it). It is a good oracle for "did our SQL implement this algorithm" and a poor oracle for "is this vanilla Doom". It is also not bit-identical to the T-SQL, because of `int()` vs `FLOOR` on negative coordinates (see section 13).

## 2. Engine, schema organisation, WAD representation

- **Engine:** SQL Server 2016+ (recursive CTEs, `STRING_AGG`, `CROSS APPLY`, the `geometry` type for a map-plan view). Everything is `dbo.*` procedures, inline TVFs, a few scalar UDFs, and plain tables. There is no CLR.
- **Load path:** `wad2sql.py` parses the WAD (vanilla nodes only; XNOD/ZNOD are rejected), embeds `doom_schema.sql` and `doom_textures.sql`, and emits a ~3.8 MB script of 500-row `INSERT ... VALUES` batches. It can also emit CSV plus `BULK INSERT`. `wadtex.py` composes TEXTURE1/2 patches the way `R_GenerateComposite` does (including the "tall patch" relative topdelta). It extracts **only the textures the map references**: 158 textures (walls and flats) and 13,056 columns for E1M1. `wadsprite.py`/`gen_sprites.py` extract per-map sprites (405 frames and 16,688 columns, or 444 frames once weapon sprites are added).
- **Geometry tables:** these mirror the lumps one-to-one with real FKs: `vertex`, `sector`, `sidedef`, `linedef` (`NULL` left sidedef means one-sided), `seg`, `subsector(first_seg,last_seg)`, `node` (the 0x8000 leaf bit is split into `r_is_leaf/r_child/l_is_leaf/l_child`), and `thing`. There are two derived tables:
  - `seg_sector(seg_id, front_sector, back_sector)`, which Doom computes at load time.
  - `child_slot(ord)` with the two rows 0 and 1, which lets a recursive CTE fan out to both children.
- **Palette/light:** `playpal(pal,idx,r,g,b)` has 14×256 rows. `colormap(light_level,in_idx,out_idx)` has 34×256 rows. The view `v_palette_rgb` joins them, using palette 0 only.
- **Textures:** `texture(id,name,kind,width,height,is_masked)` and `texture_column(texture_id,u,pixels varbinary(1024),alpha varbinary(1024) NULL)`. See section 9.
- **Utilities:** `numbers(n)` holds 0..4095 and drives every range expansion. `screen_pixel(y,x)` holds the 64,000 pixels in scan order.

## 3. BSP: present, but not used for rendering

`doom_schema.sql` defines `dbo.bsp_order(@px,@py)`, a recursive CTE that walks the node tree breadth-first. Each row carries a path string with `'0'` for the near child and `'1'` for the far child. `ROW_NUMBER() OVER (ORDER BY path)` then reproduces depth-first, near-first order, which is exactly `R_RenderBSPNode`'s visiting order. `verify.py` checks that equivalence from seven viewpoints. The core trick:

```sql
SELECT is_leaf = CASE WHEN cs.ord = 0
           THEN CASE WHEN (@px - n.part_x) * n.part_dy
                        - (@py - n.part_y) * n.part_dx > 0
                     THEN n.r_is_leaf ELSE n.l_is_leaf END ...
       path = CONVERT(varchar(64), w.path + CONVERT(char(1), cs.ord))
FROM walk w JOIN dbo.node n ON n.id = w.idx AND w.is_leaf = 0
            JOIN dbo.child_slot cs ON 1 = 1
```

**Nothing in the renderer calls it.** It is used only by `wad_validate` (to check that all subsectors are reachable) and by `render_plan.py` for an SVG. The only BSP use at render time is `dbo.sector_at`, a scalar UDF with a `WHILE` loop that descends to the player's leaf once per frame to get `viewz = floor_h + 41`. The renderer comment says it plainly: "bsp_order() gives this ordering without computing depth at all; sorting by inv_z is the same thing per column."

**Is per-column sorting by inv_z correct?** For one screen column (a ray), segs do not intersect: the BSP builder split them. Ordering them by the ray-hit distance is therefore exact front-to-back order. That holds as long as inv_z is evaluated at the column centre and ties at shared vertices are resolved (`ORDER BY l.inv_z DESC, l.id`). The approach trades BSP traversal for a sort of every projected seg-column, with no early termination. That cost is the price of being set-based.

**Oracle note:** if an Oracle renderer wants BSP order (for example, to cull subsectors early), Oracle recursive `WITH` supports `SEARCH DEPTH FIRST BY ... SET ord`. That removes the path-string trick, and `child_slot` (or `CROSS JOIN (SELECT 0 FROM dual UNION ALL SELECT 1 FROM dual)`) still handles the fan-out.

## 4. Pipeline trace: camera → framebuffer (`dbo.render_frame`)

All stages are CTEs inside one statement unless noted.

| Stage | CTE / object | What it does | Rows (E1M1 start, *measured*; turn 0/90/180/270°) |
|---|---|---|---|
| Camera | proc params `@px,@py,@ang`; `sector_at` gives `@viewz` | Constants: W=320, H=200, CX=160, CY=100, PROJ=160 (90° FOV), NEAR=4, FALLOFF=280 | — |
| View transform + backface cull | `xform` | Joins seg→vertex×2→linedef→seg_sector→sector(front, LEFT back)→sidedef. Computes view-space `z1,z2` (depth) and `l1,l2` (lateral) via `CROSS APPLY`. Keeps segs facing the camera (cross product > 0) and drops segs fully behind NEAR. Flags `is_solid` (one-sided only) and `shut` (two-sided with no opening, i.e. closed doors). | 2057 → 1058 after backface → 1033/626/25/451 after NEAR |
| Near clip | `clipped` | Interpolates the crossing endpoint to z=NEAR, carrying `l` and texture `u` along | same |
| Projection | `screen`, `onscreen` | `sx = CX + PROJ*l/z`. Keeps segs with `sx2 > sx1` (also a second backface test) that overlap [0, 319]. **This is the only frustum culling.** | 842 / 166 / 15 / 62 segs |
| Seg × column | `segcol` | `JOIN numbers n ON n.n BETWEEN CEILING(sx1) AND FLOOR(sx2)`. Interpolates `inv_z` and `u/z` linearly in screen x (perspective-correct u). | **6,505** / 2,245 / 942 / 1,056 (max 42 segs in one column) |
| Line heights | `lines` | Projects the ceiling and floor of the front sector, plus the opening top/bottom (`min(ceil)`, `max(floor)`), for this column. Per-column wall light: `light0 + (1/inv_z)/280`. | same |
| **Occlusion** | `occl` | Three window aggregates per column over strictly nearer rows: `closed_before = MAX(is_solid)`, `cc_raw = MAX(CEILING(y_otop))`, `fc_raw = MIN(FLOOR(y_obot))`. | same; needs a sort on (x, inv_z) |
| Visibility filter | `visible` | Clamps the bounds on one side only (see the code comment about PK violations) and keeps `closed_before = 0`. | ~2,075 / 815 / 598 / 814 (closed-column cut also counted) |
| Surface unpivot | `surface` | `CROSS APPLY (VALUES ('ceil'..),('floor'..),('mid'..),('upper'..),('lower'..))`: up to 5 spans per seg-column, filtered by solid/portal rules and `ceil_clip <= floor_clip` | ≤5× visible, typically about 2–3× |
| Raster | `pixel` | `JOIN numbers n ON n.n BETWEEN ceil_clip AND floor_clip AND n.n BETWEEN y_from AND y_to` | **≈ 40–64k** (every non-sky pixel exactly once) |
| Texture coordinates + lighting | `sampled` | Walls: `u = FLOOR(u_world) % width`, `v = FLOOR(origin_h - h_world + y_off) % height`. Flats: inverse-project the screen row to a distance `zf = (viewz-plane_h)*PROJ/(y-CY)`, then compute world `wx,wy`. Planes use per-pixel light `light0 + zf/280`. | same |
| Texel fetch + write | final `INSERT` | `JOIN texture_column ON (texture_id, u)` then `SUBSTRING(pixels, v+1, 1)`. Skips masked texels using `alpha`. | ≈ 40–64k rows into `framebuffer` |
| Sky | `dbo.render_sky` (separate statement) | 320-row `col` CTE computes the sky column `FLOOR((ang+ATN2(CX-x,PROJ))/2π*1024) % 256`. Joins `screen_pixel` with `NOT EXISTS framebuffer`. Light 0. | fills the remaining holes |
| Sprites | `dbo.render_sprites` (section 7) | Separate statement; `DELETE` then `INSERT` over the framebuffer | ~hundreds to a few thousand |
| Weapon/HUD | `render_psprite`, `render_hud` | 2D blits through `numbers × numbers` | — |
| Light + palette + encode | `dbo.frame_bmp()` | `screen_pixel LEFT JOIN framebuffer LEFT JOIN v_palette_rgb`. Two-level `STRING_AGG` of hex (per scanline, then across scanlines) builds a 24-bit bottom-up BMP (192,054 bytes) | 64,000 |

The occlusion window, verbatim:

```sql
cc_raw = COALESCE(MAX(CEILING(l.y_otop)) OVER (
    PARTITION BY l.x ORDER BY l.inv_z DESC, l.id
    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0),
```

**Where cardinality explodes:**

1. `segcol`: (seg, column) rows. There is no occlusion culling before the window sort, so in the busy turn-0 view **~68% of the 6.5k seg-columns are projected, sorted and then thrown away** by `closed_before`.
2. `pixel`: the span-to-row range join against `numbers`, which is the dominant row source (~64k).
3. `render_sky`'s anti-join over all 64,000 `screen_pixel` rows.
4. `frame_bmp`'s 64,000-row aggregate.

An earlier `frame_bmp` used `numbers CROSS JOIN numbers` (16.7M rows) and cost about 1 s. Switching to the materialised `screen_pixel` grid fixed it.

## 5. Wall projection, clipping, pegging

- Projection is done in float. Endpoints are near-clipped. `inv_z` and `u*inv_z` are interpolated linearly across screen columns, which is the same maths as Doom's `rw_scale` stepping.
- Column coverage is `CEILING(sx1)..FLOOR(sx2)`. Rows run from `CEILING(y_top)` to `FLOOR(y_bottom)`.
- There is no left/right frustum clip in view space. Segs that cross the side planes simply project off-screen and are bounded by `n.n BETWEEN 0 AND 319`.
- Pegging follows the vanilla rules: lower-unpegged middle textures anchor at `floor + texheight`; upper textures default to `back_ceil + texheight`; upper-unpegged anchors at the front ceiling; lower-unpegged lower textures anchor at the front ceiling.
- The `texture.height` lookups are correlated subqueries inside the `VALUES` constructor.
- Closed doors (`shut`) are portals whose **upper** texture covers the whole wall. The lower texture is suppressed in that case to avoid writing the same pixel twice. This is a hard-won edge case with long comments in both the SQL and the Python.

## 6. Floors and ceilings (no visplanes)

There are no visplanes and no span merging. For each visible seg-column, the front sector contributes:

- a ceiling span from the running `ceil_clip` down to `CEILING(y_ceil)-1`, only if `ceil_h > viewz`;
- a floor span from `FLOOR(y_floor)+1` down to `floor_clip`, only if `floor_h < viewz`.

This is the per-column equivalent of Doom's `markceiling`/`markfloor` filling `ceilingplane->top/bottom`. Vanilla marks a plane only when the sector changes, but painting the same pixels again produces the same result, so the reference always paints. Each flat pixel is inverse-projected individually: `zf = (viewz - plane_h)*160/(y-100)`, then world `(wx,wy)` comes from the camera basis. Sky ceilings (`F_SKY1`) are skipped and become holes.

The README explains why a per-pixel z-buffer (argmin depth) was tried and abandoned: "a distant room's ceiling plane can be nearer than the one you are standing under". Planes need clip-based visibility, not depth comparison.

## 7. Sprites, masked walls, depth resolution

- `render_sprites` (`doom_sprites_fast.sql`) **re-runs the entire wall projection** (`xform` → `segcol`) into a persistent `column_seg(x, inv_z, y_otop, y_obot, is_solid, seg_id)` table. It then builds `column_solid(x, MAX(inv_z) of solid segs)`.
- Sprite columns behind the nearest solid wall are dropped with a cheap equijoin. Survivors get a **range aggregate**: `LEFT JOIN column_seg k ON k.x = sc.x AND k.inv_z > sc.inv_z AND k.is_solid = 0` with `MAX(CEILING(y_otop))` and `MIN(FLOOR(y_obot))`. This is Doom's drawseg/sprite clipping as "every nearer portal in this column".
- Overlapping sprites resolve with `ROW_NUMBER() OVER (PARTITION BY x,y ORDER BY inv_z DESC)`, a real z-buffer. That is correct here because a billboard has a single depth. Results go to `#sprite_px`, then `DELETE` and `INSERT` into `framebuffer`.
- Rotation follows `R_ProjectSprite`: `(angle_to - thing_angle + 202.5) mod 360 / 45`. Rotation 0 is preferred, and `flip` handles mirrored lumps.
- Things are static: they are posed in their spawn frame (`mobj_type` is the info.c mapping) and do not animate.
- `thing_sector` precomputes each thing's floor and light. The original version called the `WHILE`-loop UDF `sector_at` per thing inside the query, which **forced a serial plan and cost about 1 s per frame**.
- **Masked midtextures** (grates, vines) on two-sided lines are not drawn, although their alpha masks are stored and the final `INSERT` honours `alpha`. Only solid one-sided middle textures can reach that path.
- **Depth resolution overall:** walls and flats use exact clip-window visibility (no z-buffer, each pixel written once). The sky fills holes. Sprites use a per-pixel argmin and overwrite. The weapon and HUD overwrite last.

## 8. Lighting / COLORMAP / palette

- Light level is `31 - sector.light/8 + distance/280`, clamped to 0..31. Walls use the column's `1/inv_z`; flats use per-pixel `zf`. Sprites use the thing's z, and full-bright sprites use 0. The sky is always 0.
- Vanilla instead uses 16 light levels (`light>>4`), `scalelight[level][scale>>12]` for walls and `zlight[level][dist>>20]` for planes, with fake contrast (±1 level on axis-aligned walls) and `extralight`. The reference has none of these. **Expect visible shading differences against any vanilla ground truth.**
- The colormap is applied at presentation time through `v_palette_rgb`, composed from `colormap` and `playpal` where `pal = 0`. There are no damage or pickup palettes and no invulnerability map. `framebuffer.light` and `framebuffer.pal_idx` together form the "pre-colormap" representation.

## 9. Texture representation and sampling

This is the most transferable storage decision. The header comment explains it: one row per texel would be 1.4M rows for E1M1 and tens of millions for a full IWAD. Instead **one row holds one texture column**, as a `varbinary(height)` of palette indices plus an optional alpha `varbinary` (NULL means the column is opaque). That matches Doom's own column-major format.

The renderer joins once per (pixel → texture column) and fetches the texel with `SUBSTRING(tc.pixels, v+1, 1)`. Negative u and v are corrected explicitly, because SQL Server `%` truncates toward zero:

```sql
JOIN dbo.texture_column tc ON tc.texture_id = s.texture_id
 AND tc.u = CASE WHEN s.u < 0 THEN s.u + t.width ELSE s.u END
... CONVERT(tinyint, SUBSTRING(tc.pixels,
        CASE WHEN s.v < 0 THEN s.v + t.height ELSE s.v END + 1, 1))
```

Flats are stored the same way: 64 columns of 64 bytes, column index = world x. `v_texture_texel` explodes columns back into texels for inspection only. `verify_textures.py` re-parses the generated INSERTs, simulates `SUBSTRING` 1-based semantics, and diffs every texel against the WAD.

**Oracle mapping:** `RAW(2000)` holds columns up to 2000 tall, which covers all vanilla textures (128 max). The equivalent of `SUBSTRING` is `UTL_RAW.SUBSTR`, which is a package call per pixel and could be costly in SQL. Alternatives:

- store hex in `VARCHAR2` and use `TO_NUMBER(SUBSTR(hex, 2*v+1, 2), 'XX')`, which is pure SQL;
- use a texel IOT keyed (tex, u, v). At ~1.4M rows for E1M1 this is quite feasible in Oracle and turns the fetch into an equijoin.

Benchmark before choosing.

## 10. Sky

`render_sky` reproduces vanilla's sky column mapping: 1024 columns per full turn, wrapped into the 256-wide texture, giving four repeats, with screen row = texture row. `FLOOR` is required for negative angles. Deviations from vanilla:

- The sky fills **every** unclaimed pixel, not only F_SKY1 ceilings, so missing-texture holes turn into sky.
- There is **no sky hack**: upper textures between two sky-ceiling sectors are drawn, where vanilla shows sky.
- Rows below texture height are clamped rather than wrapped.

## 11. Client/DB boundary and dynamic state

- `dbo.p_frame` (final version in `doom_sky.sql`) makes one round trip per displayed frame. It runs N game tics (`p_tick`, `p_door_tick`, weapons, pickups), then `render_frame` → `render_sky` → `render_sprites` → `render_psprite` → `render_hud`, and returns `SELECT bmp = dbo.frame_bmp()` as a single `varbinary(max)`.
- The PowerShell WinForms client (`doom_client.ps1`) sends key state with `p_input_set`, calls `p_frame` through ExecuteScalar, and decodes the BMP with System.Drawing. All computation stays in the database.
- **Dynamic map state:** the only renderer-relevant mutable state is `sector.ceil_h`, updated in place by `p_door_tick`. Door "thinkers" are rows in `dbo.door`, and all of them advance in a handful of set-based `UPDATE`s per tic. The renderer reads `sector` live, so doors needed **zero renderer changes**.
- `line_collide` caches geometry plus sector ids, not heights, so moving doors do not invalidate it.
- The player is `dbo.player(x,y,z,angle radians,...)`. `p_frame` passes only x, y and angle, and `render_frame` recomputes `viewz = floor + 41` itself. There is no view bob and no use of `player.z`.

## 12. Precomputed vs per-frame

**Precomputed at load or once:** `seg_sector`, `texture`/`texture_column` (composited), `numbers`, `screen_pixel`, `v_palette_rgb` (a view, not materialised), `thing_sector`, `line_collide`, `mobj_type`, and `sprite_frame`/`sprite_column`.

**Per frame:**

- `framebuffer` (TRUNCATE, then ~64k inserts);
- `column_seg` and `column_solid` (TRUNCATE and rebuild; this duplicates the wall projection);
- `#sprite_px`;
- the BMP string.

Nothing is cached between frames. There are no per-view-angle tables and no PVS. The REJECT lump is not loaded and BLOCKMAP is ignored.

**Largest relations:**

| Relation | Rows |
|---|---|
| `sprite_column` (static) | 16.7k |
| `texture_column` (static) | 13.1k |
| `colormap` (static) | 8.7k |
| `screen_pixel` (static) | 64k |
| `framebuffer` (per frame) | 64k |
| `segcol` (per frame, transient) | up to ~6.5k, worst views likely 10k+ |
| `pixel` / `sampled` (per frame, transient) | ~40–64k |

## 13. Performance numbers (from README / comments)

These are on unspecified hardware with a warm plan:

| Measure | Value |
|---|---|
| `render_ms` (walls and flats) | ~290 |
| `present_ms` (BMP build) | ~35 |
| First-call compile of `render_frame` | ~750–780 ms |
| `pixels_lit` with sky and HUD | ≈ 64,000 |

Other figures quoted in the comments:

- The wall query benefits from **~5× parallelism**. A non-inlinable scalar UDF anywhere in the statement makes the plan serial; this was the 1 s sprite problem.
- The old `frame_bmp` cost ~1 s per frame.
- One comment mentions a "~3 fps rasteriser". Sky is cheap (320-row angle CTE).
- `game_loop` reaches only 12–15 tics/s, because `WAITFOR` resolution is 15.6 ms. The client avoids this by batching tics inside `p_frame`.

## 14. Fidelity vs vanilla (summary of approximations)

1. Float maths throughout, with no `finetangent`/`xtoviewangle` tables or 16.16 fixed point. Edge pixels and texture columns will differ by ±1 at boundaries.
2. Light model (section 8): linear, 32 bands, no fake contrast, no LIGHTSCALE tables. Sector light specials are not run, but they are static here anyway.
3. **Flats appear Y-mirrored.** Vanilla `R_MapPlane` uses `ds_yfrac = -viewy - ...` and samples `flat[((-y)&63)*64 + (x&63)]`. The reference samples `column u = wx mod 64, row v = wy mod 64`, with no negation.
4. Sky: fills all holes, no sky hack, row clamped instead of wrapped.
5. No masked midtextures, so grates and the step-edge textures on two-sided lines are missing.
6. The view is a full 320×200 with `centery = 100`, and the status bar is painted over rows 168–199. Vanilla with a status bar renders 320×168 with `centery = 84`, so the horizon and wall heights differ from vanilla screenshots.
7. Sprite clipping is per column against portal openings ordered by depth, not against drawseg silhouettes and scale ranges. This is often equivalent and sometimes better. Sprites do not animate.
8. Visibility is exact (per-ray ordering), so no BSP-specific artifacts exist. Ties at shared-vertex columns are broken by seg id.

## 15. `render_ref.py` as an oracle

**What it is:** a pure-Python renderer, deliberately written "not idiomatic" so that each stage maps to a SQL operation. It loads the WAD directly through `wad2sql.parse_map`, `wadtex.extract`, `wadsprite.extract` and `parse_palette`, so it does not depend on the SQL data. It keeps a framebuffer of `(pal_idx, light)` tuples and shades through `palette_rgb` only at the end, writing an RGB PNG upscaled 3×1.2. It renders from player-1 start plus an optional turn angle in degrees.

**Usefulness for Oracle 8-bit palette-index frames:**

- **Pros:**
  - It is independent of any DB.
  - It already holds pre-colormap `(pal_idx, light)` per pixel. A ~5-line change can dump `colormap[light][pal_idx]` (or the raw pair) as a 64,000-byte array, giving exactly the 8-bit frame format we want.
  - Its structure maps stage-by-stage to CTEs, so intermediate stages can be diffed too.
  - It needs only PIL (not installed locally at present).
- **Cons / caveats:**
  1. **It encodes the reference's approximations**, including the light model, mirrored flats and sky behaviour. It cannot validate vanilla fidelity. If we want vanilla-exact frames, we need a fixed-point source port (Chocolate Doom or a doomgeneric screen dump) as ground truth.
  2. **It is not bit-identical to the T-SQL it describes.** It uses `int()` (truncation toward zero) where the SQL uses `FLOOR` for wall `v`, wall `u` and flat `wx/wy`. E1M1 coordinates are largely negative in y, so flats and some wall texels will differ by one texel. Sprite x coverage uses `int(x0)` where the SQL uses `n >= x0`. The ref treats shut doors as non-solid when clipping sprites, while `sprites_fast` treats them as solid.
  3. Float edge cases (`CEILING`/`FLOOR` at exact integers) will vary between Python doubles and Oracle `NUMBER`/`BINARY_DOUBLE`. Compare with a tolerance of mismatched pixels, or use `BINARY_DOUBLE` everywhere.
  4. It covers walls, flats, sky and sprites only, with no weapon or HUD and no doors (static map).

**Verdict:** take it as a starting point for **our own** Python oracle, then fix it in a fork:

- use `math.floor` everywhere;
- emit 8-bit indices;
- optionally implement vanilla lighting, flat orientation and the sky hack.

Keep the Oracle SQL and the fixed oracle in lockstep. Use a real source-port dump separately for vanilla-fidelity spot checks.

## 16. Techniques worth porting to Oracle 26ai

1. **The clip arrays as window prefix aggregates.** Oracle supports `MAX(...) OVER (PARTITION BY x ORDER BY inv_z DESC, id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)` with identical semantics. This is the core of a BSP-free, set-based renderer.
2. **Per-column ray ordering by inv_z instead of BSP traversal.** Optionally add a cheap pre-cull, for example BSP-ordered subsector pruning or a per-column "first solid" cut using `MIN(...) KEEP` / `MATCH_RECOGNIZE`, to cut the ~68% wasted seg-columns before the sort.
3. **Unpivot surfaces with a row constructor.** Oracle 23ai+ supports `VALUES` in `FROM`, and `CROSS APPLY`/`LATERAL` have existed since 12c. Constants and derived columns can flow through `CROSS APPLY (SELECT ...)` / `LATERAL` the same way.
4. **Column-major texture storage, one row per texture column.** This keeps the texel fetch as one PK equijoin plus a substring. Pick the Oracle substring primitive carefully (section 9).
5. **A materialised `numbers` table and `screen_pixel` grid** for range expansion. In Oracle, use an IOT or a heap table with a PK. Avoid `CONNECT BY LEVEL` inside the hot query.
6. **Keep scalar procedural functions out of the hot statement.** In Oracle the risk is PL/SQL context switching rather than a forced-serial plan. Precompute (`thing_sector`), use `WITH FUNCTION` or `PRAGMA UDF`, or use SQL macros.
7. **Exact visibility removes the need for a framebuffer z-buffer.** The (y,x) PK doubles as an invariant check. Keep it during development; it catches double-writes immediately.
8. **Store `(pal_idx, light)` and apply COLORMAP in one final join.** For 8-bit output, materialise `out_idx` directly. Building a BMP inside the DB is optional; for Oracle, returning a 64,000-byte `RAW`/`BLOB` of indices is simpler. `LISTAGG` limits make the two-level hex aggregation awkward, so `DBMS_LOB` or `JSON`/`RAW` assembly may be needed.
9. **Do the wall projection once.** The reference does it twice (render and sprites). Have the wall pass also write the `column_seg` equivalent, using a multi-table INSERT or a GTT, so sprites reuse it.
10. **Doors as live `sector` rows and thinkers as rows.** The renderer needs no changes for dynamic heights.
11. **Recursive-CTE BSP with path ordering** is useful for point location and validation. In Oracle, `SEARCH DEPTH FIRST` is the idiomatic replacement. `sector_at` should become a non-procedural query (recursive `WITH` taking one child), not a loop.
