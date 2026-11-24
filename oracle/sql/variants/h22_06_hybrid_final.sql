-- =============================================================================================
-- 06_hybrid.sql -- HYBRID renderer (H27): per-frame state retrieval in SQL, geometry, visibility
-- and per-pixel raster loops in PL/SQL. Entry point: sql/render_hybrid.sql (one prepared SELECT).
--
-- Install with client/install_hybrid.py (units are separated by lines containing only '/').
-- Re-runnable. Output is pixel-identical to render_optimized.sql / render_baseline.sql (the
-- CedarDB SQLDoom reference); see analysis/hybrid-design.md.
--
-- Boundary:
--   SQL    : pose-independent per-frame state (st_* tables: sectors + animated light, weapon,
--            player/HUD state, seg texture overrides, owned weapons) and the sprite list
--            (thing_view .. thing_bounds incl. float4 tops), BULK COLLECTed.
--   PL/SQL : pose conversion, BSP order + frustum (pruned front-first traversal), seg
--            transform/clip/projection, wall parts, solid occlusion, wall columns (z-tested and
--            shaded as they are generated), visplane clip windows, plane spans, a per-pixel
--            exact key z-buffer (walls, planes, sprites) with texturing/lighting of winning
--            fragments and exact interval-level culling of provably losing span parts (covered
--            wall bands, camera-sector seed overlap), weapon psprite, pickup message, status
--            bar, hex row output. Round 2 (h11..h22): analysis/optimization-log.md.
--   Static package caches (immutable WAD data, loaded on first call per map): BSP, segs,
--   texel arrays (lazily per texture/flat/sprite lump), COLORMAP, status-bar background.
-- =============================================================================================
ALTER SESSION SET plsql_code_type = NATIVE
/
ALTER SESSION SET plsql_optimize_level = 3
/
CREATE TYPE IF NOT EXISTS doom_hex_row AS OBJECT (y NUMBER, pal NUMBER, hex VARCHAR2(640))
/
CREATE TYPE IF NOT EXISTS doom_hex_tab AS TABLE OF doom_hex_row
/
CREATE OR REPLACE PACKAGE doom_hybrid AUTHID DEFINER AS
  -- one frame: 200 rows (y, pal, 640 hex chars = 320 palette indices)
  FUNCTION render_frame(p_tic NUMBER, p_map_id NUMBER, p_player_id NUMBER, p_skill NUMBER,
                        p_px NUMBER, p_py NUMBER, p_pz NUMBER, p_pangle NUMBER)
    RETURN doom_hex_tab PIPELINED;
  -- debug: 1 = record per-phase timings of the last frame (read with timings())
  PROCEDURE set_debug(p_on PLS_INTEGER);
  FUNCTION timings RETURN VARCHAR2;
  -- drop all static caches (next call reloads)
  PROCEDURE reset_cache;
END doom_hybrid;
/
CREATE OR REPLACE PACKAGE BODY doom_hybrid AS
  TYPE t_i  IS TABLE OF PLS_INTEGER   INDEX BY PLS_INTEGER;
  TYPE t_d  IS TABLE OF BINARY_DOUBLE INDEX BY PLS_INTEGER;
  TYPE t_v  IS TABLE OF VARCHAR2(16)  INDEX BY PLS_INTEGER;
  TYPE t_h  IS TABLE OF VARCHAR2(2)   INDEX BY PLS_INTEGER;
  TYPE t_ni IS TABLE OF PLS_INTEGER   INDEX BY VARCHAR2(16);

  c_pi180 CONSTANT BINARY_DOUBLE := 3.14159265358979323846d / 180d;
  c_cx    CONSTANT BINARY_DOUBLE := 160d;
  c_cy    CONSTANT BINARY_DOUBLE := 84d;
  c_big   CONSTANT PLS_INTEGER   := 1073741824;
  c_qsky  CONSTANT BINARY_DOUBLE := 536866816d * 1048576d; -- ROUND(131071 * 4096) * 2^20
  -- z-buffer key: ROUND(clamp(depth) * 4096) * 2^20 + ((2 - surface) * 4 + src) * 2^16 + stable
  -- (< 2^49, exact in a double): the reference's 64-bit key without the light/palette bits,
  -- which are compared (shade_lp) only when two fragments tie on this key.
  c_zinit CONSTANT BINARY_DOUBLE := 1e300d;              -- empty z-buffer pixel
  c_zinv  CONSTANT BINARY_DOUBLE := 1e301d;              -- invalid plane row: never wins
  -- owner id ranges in the z-buffer
  c_opl   CONSTANT PLS_INTEGER := 100000;                -- planes  100000 + i
  c_osp   CONSTANT PLS_INTEGER := 200000;                -- sprites 200000 + i
  -- wall part kinds, numbered in the reference's ORDER BY part (string) order
  K_LOWER CONSTANT PLS_INTEGER := 1; K_LOWER_DOWN CONSTANT PLS_INTEGER := 2;
  K_MIDMASK CONSTANT PLS_INTEGER := 3; K_SOLID CONSTANT PLS_INTEGER := 4;
  K_UPPER CONSTANT PLS_INTEGER := 5; K_UPPER_FLUSH CONSTANT PLS_INTEGER := 6;
  K_UPPER_OPEN CONSTANT PLS_INTEGER := 7;

  -- ------------------------------------------------------------------ debug timing
  g_debug PLS_INTEGER := 0;
  g_tm    VARCHAR2(4000);
  g_t0    TIMESTAMP(6);
  g_tl    TIMESTAMP(6);

  -- ------------------------------------------------------------------ static caches
  g_map    PLS_INTEGER;
  g_focal  BINARY_DOUBLE; g_thf BINARY_DOUBLE; g_near BINARY_DOUBLE; g_mpd BINARY_DOUBLE;
  g_ta     t_d;          -- screen_x.ta (x - cx) / focal
  g_atn    t_d;          -- ATAN((x - cx) / focal): ray angle of column x (sky)
  g_yd     t_d;          -- 0..319 as double
  g_dy     t_d;          -- cy - y
  g_hex    t_h;          -- 0..255 -> 'XX'
  TYPE t_h4 IS TABLE OF VARCHAR2(4) INDEX BY PLS_INTEGER;
  g_hex2   t_h4;         -- a*256+b -> 'AABB' (two pixels per concatenation)
  g_hexval t_ni;         -- 'XX' -> 0..255
  g_cmap   t_i;          -- light*256 + idx -> mapped (pal 0), 0 when missing
  g_cmapk  t_i;          -- layer*256 + idx (status-bar patch key) -> g_cmap(idx)
  g_zl     t_i;          -- FLOOR(80 / (k + 1)), k = 0..127
  g_skyv   t_i;          -- MOD(MOD(y - 100, 128) + 128, 128)
  g_m64    t_i;          -- i mod 64        for i in [-131072, 131071]
  g_m64y   t_i;          -- (i mod 64) * 64
  g_lt256  t_i;          -- lbase*128 + zlight -> clamp(lbase - zlight, 0, 31) * 256; 64*128+k -> 32*256
  g_hudfb  t_i;          -- status-bar background rows as a framebuffer template
  -- BSP
  g_nd_x t_d; g_nd_y t_d; g_nd_dx t_d; g_nd_dy t_d; g_nd_ids t_i; g_nnd PLS_INTEGER;
  g_ch t_i; g_root PLS_INTEGER; g_nc_key t_i; g_nc_l t_d; g_nc_r t_d; g_nc_b t_d; g_nc_t t_d; g_nnc PLS_INTEGER;
  -- segs (render_segs_ext, ordered by ssector, seg_id)
  g_sg_from t_i; g_sg_cnt t_i;
  g_sg_id t_i; g_sg_x1 t_d; g_sg_y1 t_d; g_sg_x2 t_d; g_sg_y2 t_d; g_sg_u1 t_d; g_sg_u2 t_d;
  g_sg_fsec t_i; g_sg_bsec t_i; g_sg_xoff t_i; g_sg_yoff t_i;
  g_sg_up t_v; g_sg_mid t_v; g_sg_lo t_v; g_sg_upc t_i; g_sg_midc t_i; g_sg_loc t_i; g_sg_pegb t_i; g_sg_pegt t_i; g_sg_lbias t_i; g_sg_scroll t_i;
  -- textures: one texel store; walls column-major, flats row-major, sprites row-major (-1 = clear)
  g_tx t_i; g_txn PLS_INTEGER := 0;
  g_wt_idx t_ni; g_wt_name t_v; g_wt_w t_i; g_wt_h t_i; g_wt_base t_i;
  g_fl_idx t_ni; g_fl_name t_v; g_fl_base t_i;
  g_sp_base t_ni;
  g_sf_idx t_ni; g_sf_lump t_v; g_sf_flip t_i; g_sf_w t_i; g_sf_h t_i; g_sf_left t_i; g_sf_top t_i; g_sf_base t_i;
  g_sky PLS_INTEGER;     -- wall texture index of the map's sky (0 = missing)
  -- status bar
  g_hud t_i;             -- (y-168)*320 + x -> background mapped index (-1 = none)
  g_up_idx t_ni; g_up_w t_i; g_up_left t_i; g_up_top t_i;
  g_px_from t_ni; g_px_cnt t_ni; g_px_dx t_i; g_px_dy t_i; g_px_pi t_i; g_npx PLS_INTEGER := 0;
  g_am_type t_v; g_am_cap t_i; g_am_bcap t_i; g_nam PLS_INTEGER;

  -- ------------------------------------------------------------------ per-frame state
  px BINARY_DOUBLE; py BINARY_DOUBLE; pz BINARY_DOUBLE; vr BINARY_DOUBLE;
  cs BINARY_DOUBLE; sn BINARY_DOUBLE; cv BINARY_DOUBLE; sv BINARY_DOUBLE;
  f_extra PLS_INTEGER; f_invuln PLS_INTEGER; f_t NUMBER;
  -- sectors (secl)
  s_ok t_i; s_floor t_i; s_ceil t_i; s_light t_i; s_csky t_i; s_ftex t_v; s_ctex t_v;
  s_fcode t_i; s_ccode t_i; s_lb t_i; s_fb t_i; s_cb t_i; s_sf t_i; s_sc t_i;
  zmap t_i; nz PLS_INTEGER; zt_vlo t_i; zt_vhi t_i; bt t_i; bk t_d; bb t_i; bkb t_d; zt_q t_d; zt_d t_d; zt_l t_i; zt_a t_d; zt_b t_d; zt_fast t_i;
  ps_ok BOOLEAN; ps_id PLS_INTEGER;
  -- seg texture overrides
  o_up t_v; o_mid t_v; o_lo t_v;
  -- z-buffer
  zq t_d; zo t_i;
  g_zq0 t_d; g_zo0 t_i; g_fb0 t_i;
  fb t_i; hb t_i;
  nw PLS_INTEGER;   -- wall spans (debug count)
  -- plane items
  pl_x t_i; pl_y0 t_i; pl_y1 t_i; pl_sky t_i; pl_s t_i; pl_tex t_i; pl_lb t_i; pl_zi t_i; pl_z t_i; pl_fb t_i; np PLS_INTEGER;
  -- sprite items
  sp_xl t_d; sp_xr t_d; sp_yt t_d; sp_yb t_d; sp_sc t_d; sp_w t_i; sp_h t_i; sp_fl t_i; sp_base t_i;
  sp_q t_d; sp_s t_i; sp_l t_i; sp_fz t_i; sp_rd t_i; sp_slot t_i; nsp PLS_INTEGER;
  skyu t_i;

  -- =========================================================================== helpers
  PROCEDURE tmark(p_name VARCHAR2) IS
    t TIMESTAMP(6) := SYSTIMESTAMP;
    d INTERVAL DAY TO SECOND;
  BEGIN
    IF g_debug = 1 THEN
      d := t - g_tl;
      g_tm := g_tm || p_name || '=' || TO_CHAR(EXTRACT(SECOND FROM d) * 1000, 'FM9990.00') || ' ';
      g_tl := SYSTIMESTAMP;
    END IF;
  END;

  PROCEDURE set_debug(p_on PLS_INTEGER) IS BEGIN g_debug := p_on; END;
  FUNCTION timings RETURN VARCHAR2 IS BEGIN RETURN g_tm; END;

  PROCEDURE reset_cache IS
  BEGIN
    g_map := NULL; g_tx.DELETE; g_txn := 0; g_wt_idx.DELETE; g_wt_base.DELETE; g_fl_idx.DELETE;
    g_fl_base.DELETE; g_sp_base.DELETE; g_px_from.DELETE; g_px_cnt.DELETE; g_npx := 0;
    g_nd_ids.DELETE; g_nc_key.DELETE; g_ch.DELETE;
    g_sg_from.DELETE; g_sg_cnt.DELETE; g_sg_id.DELETE; g_sf_idx.DELETE;
  END;

  -- BLOB bytes -> texel store. mode 1: wall (column-major, w x h); 2: flat/raw row-major;
  -- 3: sprite (row-major, mask blob m: 0 -> -1)
  PROCEDURE load_bytes(b BLOB, m BLOB, p_mode PLS_INTEGER, w PLS_INTEGER, h PLS_INTEGER, base PLS_INTEGER) IS
    len PLS_INTEGER := DBMS_LOB.GETLENGTH(b);
    off PLS_INTEGER := 0;
    n PLS_INTEGER; hx VARCHAR2(4000); mx VARCHAR2(4000); v PLS_INTEGER; o PLS_INTEGER;
    u PLS_INTEGER; r PLS_INTEGER;
  BEGIN
    WHILE off < len LOOP
      n := LEAST(2000, len - off);
      hx := RAWTOHEX(DBMS_LOB.SUBSTR(b, n, off + 1));
      IF p_mode = 3 THEN mx := RAWTOHEX(DBMS_LOB.SUBSTR(m, n, off + 1)); END IF;
      FOR k IN 0 .. n - 1 LOOP
        v := g_hexval(SUBSTR(hx, 2 * k + 1, 2));
        o := off + k;
        IF p_mode = 1 THEN
          r := TRUNC(o / w); u := o - r * w;
          g_tx(base + u * h + r) := v;
        ELSIF p_mode = 2 THEN
          g_tx(base + o) := v;
        ELSE
          IF SUBSTR(mx, 2 * k + 1, 2) = '00' THEN g_tx(base + o) := -1; ELSE g_tx(base + o) := v; END IF;
        END IF;
      END LOOP;
      off := off + n;
    END LOOP;
  END;

  FUNCTION wall_base(i PLS_INTEGER) RETURN PLS_INTEGER IS
    b BLOB;
  BEGIN
    IF g_wt_base(i) < 0 THEN
      SELECT palette_indices INTO b FROM walltex_meta WHERE name = g_wt_name(i);
      g_wt_base(i) := g_txn;
      load_bytes(b, NULL, 1, g_wt_w(i), g_wt_h(i), g_txn);
      g_txn := g_txn + g_wt_w(i) * g_wt_h(i);
    END IF;
    RETURN g_wt_base(i);
  END;

  FUNCTION flat_base(i PLS_INTEGER) RETURN PLS_INTEGER IS
    b BLOB;
  BEGIN
    IF g_fl_base(i) < 0 THEN
      SELECT palette_indices INTO b FROM flat_textures WHERE name = g_fl_name(i);
      g_fl_base(i) := g_txn;
      load_bytes(b, NULL, 2, 64, 64, g_txn);
      g_txn := g_txn + 4096;
    END IF;
    RETURN g_fl_base(i);
  END;

  FUNCTION sprite_base(p_lump VARCHAR2) RETURN PLS_INTEGER IS
    b BLOB; m BLOB; base PLS_INTEGER;
  BEGIN
    IF NOT g_sp_base.EXISTS(p_lump) THEN
      SELECT pixels, mask INTO b, m FROM sprite_lumps WHERE lump_name = p_lump;
      base := g_txn;
      load_bytes(b, m, 3, 0, 0, base);
      g_txn := g_txn + DBMS_LOB.GETLENGTH(b);
      g_sp_base(p_lump) := base;
    END IF;
    RETURN g_sp_base(p_lump);
  END;

  -- wall texture code of a name: -1 = no texture (NULL or '-'), 0 = unknown name, else index
  FUNCTION wcode(p_name VARCHAR2) RETURN PLS_INTEGER IS
  BEGIN
    IF p_name IS NULL OR p_name = '-' THEN RETURN -1; END IF;
    IF g_wt_idx.EXISTS(p_name) THEN RETURN g_wt_idx(p_name); END IF;
    RETURN 0;
  END;

  PROCEDURE load_patch_pixels(p_name VARCHAR2) IS
    TYPE t_n IS TABLE OF NUMBER;
    dxs t_n; dys t_n; pis t_n;
  BEGIN
    IF g_px_from.EXISTS(p_name) THEN RETURN; END IF;
    SELECT dx, dy, palette_index BULK COLLECT INTO dxs, dys, pis FROM ui_hud_pixels WHERE name = p_name;
    g_px_from(p_name) := g_npx + 1;
    g_px_cnt(p_name) := dxs.COUNT;
    FOR k IN 1 .. dxs.COUNT LOOP
      g_npx := g_npx + 1;
      g_px_dx(g_npx) := dxs(k); g_px_dy(g_npx) := dys(k); g_px_pi(g_npx) := pis(k);
    END LOOP;
  END;

  -- CedarDB numeric literal -> float8 (render_optimized.sql pose_conv): the bind is a NUMBER
  -- holding Python's repr digits; scale = its decimal places; mantissa rounded to 53 bits
  -- (ties to even) in exact NUMBER math, then float8(mantissa) / float8(10^scale).
  FUNCTION pose_conv(x NUMBER) RETURN BINARY_DOUBLE IS
    s VARCHAR2(200); dp PLS_INTEGER; p10 NUMBER; m NUMBER; ulp NUMBER; q NUMBER; r NUMBER;
  BEGIN
    IF x = 0 THEN RETURN 0d; END IF;
    IF ABS(x) < 1e-4 OR ABS(x) >= 1e16 THEN RETURN TO_BINARY_DOUBLE(x); END IF;
    s := TO_CHAR(ABS(x), 'TM9');
    dp := INSTR(s, '.');
    p10 := POWER(10, CASE WHEN dp = 0 THEN 0 ELSE LENGTH(s) - dp END);
    m := x * p10;
    ulp := CASE WHEN ABS(m) < 9007199254740992 THEN 1 WHEN ABS(m) < 18014398509481984 THEN 2
                WHEN ABS(m) < 36028797018963968 THEN 4 WHEN ABS(m) < 72057594037927936 THEN 8 ELSE 16 END;
    q := m / ulp;
    IF ABS(q - TRUNC(q)) = 0.5 THEN r := 2 * ROUND(m / ulp / 2); ELSE r := ROUND(m / ulp); END IF;
    RETURN TO_BINARY_DOUBLE(r * ulp) / TO_BINARY_DOUBLE(p10);
  END;

  -- =========================================================================== static load
  PROCEDURE load_static(p_map PLS_INTEGER) IS
    TYPE t_n IS TABLE OF NUMBER;
    TYPE t_bd IS TABLE OF BINARY_DOUBLE;
    TYPE t_s IS TABLE OF VARCHAR2(16);
    a t_n; b t_n; c t_n; d t_n; e t_n; f t_n; g t_n; h t_n; ii t_n; jj t_n; kk t_n; ll t_n;
    mm t_n; nn t_n; oo t_n; pp t_n;
    da t_bd; db t_bd;
    s1 t_s; s2 t_s; s3 t_s;
    sky VARCHAR2(16);
    prev PLS_INTEGER;
  BEGIN
    reset_cache;
    SELECT 160d / TAN(90d * (3.14159265358979323846d / 180d) / 2d),
           TAN(90d * (3.14159265358979323846d / 180d) / 2d), 1d / 1000d,
           16d * (160d / TAN(90d * (3.14159265358979323846d / 180d) / 2d))
      INTO g_focal, g_thf, g_near, g_mpd FROM dual;
    FOR r IN (SELECT x, ta FROM screen_x) LOOP g_ta(r.x) := r.ta; END LOOP;
    FOR y IN 0 .. 319 LOOP g_yd(y) := y; END LOOP;     -- integer -> double (x and y)
    FOR xx IN 0 .. 319 LOOP g_atn(xx) := ATAN((g_yd(xx) - c_cx) / g_focal); END LOOP;
    FOR y IN 0 .. 199 LOOP
      g_dy(y) := 84d - y;
      g_skyv(y) := MOD(MOD(y - 100, 128) + 128, 128);
    END LOOP;
    FOR i IN 0 .. 255 LOOP g_hex(i) := TO_CHAR(i, 'FM0X'); g_hexval(g_hex(i)) := i; END LOOP;
    FOR i IN 0 .. 255 LOOP FOR j IN 0 .. 255 LOOP g_hex2(i * 256 + j) := g_hex(i) || g_hex(j); END LOOP; END LOOP;
    FOR i IN 0 .. 64 * 256 - 1 LOOP g_cmap(i) := 0; END LOOP;
    FOR r IN (SELECT light, idx, mapped FROM cmap) LOOP g_cmap(r.light * 256 + r.idx) := r.mapped; END LOOP;
    FOR i IN 0 .. 4 * 256 - 1 LOOP g_cmapk(i) := g_cmap(MOD(i, 256)); END LOOP;
    FOR k IN 0 .. 127 LOOP g_zl(k) := FLOOR(80 / (k + 1)); END LOOP;
    FOR i IN -131072 .. 131071 LOOP g_m64(i) := MOD(MOD(i, 64) + 64, 64); g_m64y(i) := g_m64(i) * 64; END LOOP;
    FOR lb IN 0 .. 63 LOOP FOR zl IN 0 .. 127 LOOP g_lt256(lb * 128 + zl) := GREATEST(0, LEAST(31, lb - zl)) * 256; END LOOP; END LOOP;
    FOR zl IN 0 .. 127 LOOP g_lt256(64 * 128 + zl) := 32 * 256; END LOOP;
    -- nodes
    SELECT id, x, y, dx, dy BULK COLLECT INTO a, b, c, d, e FROM nodes WHERE map_id = p_map;
    g_nnd := a.COUNT;
    FOR k IN 1 .. a.COUNT LOOP
      g_nd_ids(k) := a(k); g_nd_x(a(k)) := b(k); g_nd_y(a(k)) := c(k); g_nd_dx(a(k)) := d(k); g_nd_dy(a(k)) := e(k);
    END LOOP;
    SELECT node_id * 2 + CASE side WHEN 'R' THEN 1 ELSE 0 END, bbox_left, bbox_right, bbox_bottom, bbox_top
      BULK COLLECT INTO a, b, c, d, e FROM node_children WHERE map_id = p_map;
    g_nnc := a.COUNT;
    FOR k IN 1 .. a.COUNT LOOP
      g_nc_key(k) := a(k); g_nc_l(a(k)) := b(k); g_nc_r(a(k)) := c(k); g_nc_b(a(k)) := d(k); g_nc_t(a(k)) := e(k);
    END LOOP;
    -- child of (node, side): node id >= 0, or -(subsector + 1); root = the node that is no child
    SELECT node_id * 2 + CASE side WHEN 'R' THEN 1 ELSE 0 END,
           CASE WHEN child_kind = 'NODE' THEN child_node_id ELSE -(child_ssector_id + 1) END
      BULK COLLECT INTO a, b FROM node_children WHERE map_id = p_map;
    FOR k IN 1 .. a.COUNT LOOP g_ch(a(k)) := b(k); END LOOP;
    SELECT MAX(n.id) INTO g_root FROM nodes n WHERE n.map_id = p_map
       AND NOT EXISTS (SELECT 1 FROM node_children c WHERE c.map_id = p_map AND c.child_kind = 'NODE' AND c.child_node_id = n.id);
    -- segs
    SELECT ssector_id, seg_id, x1, y1, x2, y2, seg_u1, seg_u2, fsec, NVL(bsec, -1), x_offset, y_offset,
           upper_tex, mid_tex, lower_tex, peg_bottom, peg_top, light_bias, scrolls
      BULK COLLECT INTO a, b, c, d, e, f, da, db, g, h, ii, jj, s1, s2, s3, kk, ll, mm, nn
      FROM render_segs_ext WHERE map_id = p_map ORDER BY ssector_id, seg_id;
    prev := -1;
    FOR k IN 1 .. a.COUNT LOOP
      IF a(k) <> prev THEN g_sg_from(a(k)) := k; g_sg_cnt(a(k)) := 0; prev := a(k); END IF;
      g_sg_cnt(a(k)) := g_sg_cnt(a(k)) + 1;
      g_sg_id(k) := b(k); g_sg_x1(k) := c(k); g_sg_y1(k) := d(k); g_sg_x2(k) := e(k); g_sg_y2(k) := f(k);
      g_sg_u1(k) := da(k); g_sg_u2(k) := db(k); g_sg_fsec(k) := g(k); g_sg_bsec(k) := h(k);
      g_sg_xoff(k) := ii(k); g_sg_yoff(k) := jj(k); g_sg_up(k) := s1(k); g_sg_mid(k) := s2(k); g_sg_lo(k) := s3(k);
      g_sg_pegb(k) := kk(k); g_sg_pegt(k) := ll(k); g_sg_lbias(k) := mm(k); g_sg_scroll(k) := nn(k);
    END LOOP;
    -- texture directories (texels load lazily)
    SELECT name, width, height BULK COLLECT INTO s1, a, b FROM walltex_meta;
    FOR k IN 1 .. s1.COUNT LOOP
      g_wt_idx(s1(k)) := k; g_wt_name(k) := s1(k); g_wt_w(k) := a(k); g_wt_h(k) := b(k); g_wt_base(k) := -1;
    END LOOP;
    SELECT sprite || frame || TO_CHAR(rotation), lump_name, CASE WHEN flipped THEN 1 ELSE 0 END,
           width, height, left_offset, top_offset
      BULK COLLECT INTO s1, s2, a, b, c, d, e FROM sprite_frames;
    FOR k IN 1 .. s1.COUNT LOOP
      g_sf_idx(s1(k)) := k; g_sf_lump(k) := s2(k); g_sf_flip(k) := a(k); g_sf_w(k) := b(k); g_sf_h(k) := c(k);
      g_sf_left(k) := d(k); g_sf_top(k) := e(k); g_sf_base(k) := -1;
    END LOOP;
    FOR k IN 1 .. g_sg_id.COUNT LOOP     -- static seg textures -> wall texture codes
      g_sg_upc(k) := wcode(g_sg_up(k)); g_sg_midc(k) := wcode(g_sg_mid(k)); g_sg_loc(k) := wcode(g_sg_lo(k));
    END LOOP;
    SELECT name BULK COLLECT INTO s1 FROM flat_textures;
    FOR k IN 1 .. s1.COUNT LOOP g_fl_idx(s1(k)) := k; g_fl_name(k) := s1(k); g_fl_base(k) := -1; END LOOP;
    SELECT MAX(sky_texture) INTO sky FROM maps WHERE map_id = p_map;
    g_sky := CASE WHEN sky IS NOT NULL AND g_wt_idx.EXISTS(sky) THEN g_wt_idx(sky) ELSE 0 END;
    -- status bar background
    FOR i IN 0 .. 32 * 320 - 1 LOOP g_hud(i) := -1; END LOOP;
    FOR r IN (SELECT x, y, idx FROM hud_static_idx WHERE y BETWEEN 168 AND 199 AND x BETWEEN 0 AND 319) LOOP
      g_hud((r.y - 168) * 320 + r.x) := r.idx;
    END LOOP;
    FOR i IN 0 .. 32 * 320 - 1 LOOP g_hudfb(168 * 320 + i) := GREATEST(g_hud(i), 0); END LOOP;
    SELECT name, width, left_offset, top_offset BULK COLLECT INTO s1, a, b, c FROM ui_patches;
    FOR k IN 1 .. s1.COUNT LOOP g_up_idx(s1(k)) := k; g_up_w(k) := a(k); g_up_left(k) := b(k); g_up_top(k) := c(k); END LOOP;
    SELECT ammo_type, cap, backpack_cap BULK COLLECT INTO s1, a, b FROM ammo_defs;
    g_nam := s1.COUNT;
    FOR k IN 1 .. s1.COUNT LOOP g_am_type(k) := s1(k); g_am_cap(k) := a(k); g_am_bcap(k) := b(k); END LOOP;
    -- z-buffer templates
    FOR p IN 0 .. 168 * 320 - 1 LOOP g_zq0(p) := c_zinit; g_zo0(p) := 0; g_fb0(p) := 0; END LOOP;
    g_map := p_map;
  END;

  -- =========================================================================== shading
  -- light*256 + palette of owner o at (x, y): used for exact tie-breaks and the final pass
  FUNCTION shade_lp(o PLS_INTEGER, x PLS_INTEGER, y PLS_INTEGER) RETURN PLS_INTEGER IS
    i PLS_INTEGER; vv BINARY_DOUBLE; th BINARY_DOUBLE; t PLS_INTEGER; depth BINARY_DOUBLE;
    wx BINARY_DOUBLE; wy BINARY_DOUBLE; tu PLS_INTEGER; tv PLS_INTEGER; lt PLS_INTEGER; k BINARY_DOUBLE;
    u PLS_INTEGER; v PLS_INTEGER; off PLS_INTEGER; ww PLS_INTEGER; hh PLS_INTEGER;
  BEGIN
    IF o < c_opl THEN
      -- walls never tie (unique key per column), so no wall owner is ever compared
      RAISE_APPLICATION_ERROR(-20002, 'doom_hybrid: unexpected wall key tie');
    ELSIF o < c_osp THEN
      i := o - c_opl;
      IF pl_tex(i) = -2 THEN
        -- sky: light 0, texel of the rotated sky column
        IF g_sky = 0 THEN RETURN 0; END IF;
        ww := g_wt_w(g_sky); hh := g_wt_h(g_sky);
        u := skyu(x); v := g_skyv(y);
        off := v * ww + u;
        IF off < 0 OR off >= ww * hh THEN RETURN 0; END IF;
        IF u >= ww THEN v := TRUNC(off / ww); u := off - v * ww; END IF;
        RETURN g_tx(wall_base(g_sky) + u * hh + v);
      END IF;
      IF pl_sky(i) = 1 THEN depth := 1e7d; ELSE depth := zt_d(pl_zi(i) + y); END IF;
      IF f_invuln = 1 THEN lt := 32;
      ELSE
        k := FLOOR(depth / 16d);
        IF k > 127d THEN k := 127d; END IF;
        lt := GREATEST(0, LEAST(31, pl_lb(i) - g_zl(k)));
      END IF;
      IF pl_tex(i) <= 0 THEN RETURN lt * 256; END IF;
      wx := px + depth * cv + (g_ta(x) * depth) * sv;
      wy := py + depth * sv - (g_ta(x) * depth) * cv;
      tu := FLOOR(wx) - 64d * FLOOR(wx * 0.015625d);
      tv := FLOOR(wy) - 64d * FLOOR(wy * 0.015625d);
      RETURN lt * 256 + g_tx(pl_fb(i) + tv * 64 + tu);
    ELSE
      i := o - c_osp;
      vv := FLOOR((g_yd(x) - sp_xl(i)) / sp_sc(i));
      u := LEAST(sp_w(i) - 1, GREATEST(0d, vv));
      IF sp_fl(i) = 1 THEN u := sp_w(i) - 1 - u; END IF;
      vv := FLOOR((g_yd(y) - sp_yt(i)) / sp_sc(i));
      v := LEAST(sp_h(i) - 1, GREATEST(0d, vv));
      t := g_tx(sp_base(i) + v * sp_w(i) + u);
      IF sp_slot(i) > 1 AND t BETWEEN 112 AND 127 THEN
        t := t - 112 + CASE sp_slot(i) WHEN 2 THEN 96 WHEN 3 THEN 64 ELSE 32 END;
      END IF;
      IF sp_fz(i) = 1 THEN lt := 26 + MOD(x * 7 + y * 13 + sp_rd(i), 5); ELSE lt := sp_l(i); END IF;
      RETURN lt * 256 + t;
    END IF;
  END;

  -- =========================================================================== frame
  PROCEDURE build_frame(p_tic NUMBER, p_map PLS_INTEGER, p_player NUMBER, p_skill NUMBER,
                        p_px NUMBER, p_py NUMBER, p_pz NUMBER, p_pangle NUMBER, p_pal OUT NUMBER) IS
    TYPE t_n IS TABLE OF NUMBER;
    TYPE t_bd IS TABLE OF BINARY_DOUBLE;
    TYPE t_s IS TABLE OF VARCHAR2(16);
    a t_n; b t_n; c t_n; d t_n; e t_n; f t_n; g t_n; h t_n; ii t_n; jj t_n; kk t_n;
    s1 t_s; s2 t_s; s3 t_s;
    d1 t_bd; d2 t_bd; d3 t_bd; d4 t_bd; d5 t_bd; d6 t_bd;
    TYPE t_bfl IS TABLE OF BINARY_FLOAT; bf1 t_bfl; ft1 BINARY_FLOAT; ft2 BINARY_FLOAT;
    sfk VARCHAR2(16); sfi PLS_INTEGER; dsc BINARY_DOUBLE; dox BINARY_DOUBLE; dxl BINARY_DOUBLE; dxr BINARY_DOUBLE;
    dyt BINARY_DOUBLE; dyb BINARY_DOUBLE;
    pa BINARY_DOUBLE; skill_bit PLS_INTEGER;
    -- weapon/state
    w_sx BINARY_DOUBLE; w_sy BINARY_DOUBLE; w_spr VARCHAR2(16); w_fspr VARCHAR2(16);
    w_frame VARCHAR2(4); w_fb PLS_INTEGER; w_fframe VARCHAR2(4); w_ffb PLS_INTEGER;
    has_ps PLS_INTEGER; u_health NUMBER; u_alive PLS_INTEGER; u_pain NUMBER; u_armor NUMBER;
    u_bul NUMBER; u_she NUMBER; u_roc NUMBER; u_cel NUMBER; u_kb PLS_INTEGER; u_ky PLS_INTEGER; u_kr PLS_INTEGER;
    u_msg VARCHAR2(400); u_mtics NUMBER; u_bp PLS_INTEGER; u_ammo VARCHAR2(16); u_pal NUMBER; u_owned PLS_INTEGER;
    -- BSP
    vis t_i; nvis PLS_INTEGER := 0; stk t_i; sp_ PLS_INTEGER; fr PLS_INTEGER; seq PLS_INTEGER; ok BOOLEAN; ssid PLS_INTEGER;
    a1 BINARY_DOUBLE; b1 BINARY_DOUBLE; c1 BINARY_DOUBLE; a2 BINARY_DOUBLE; b2 BINARY_DOUBLE; c2 BINARY_DOUBLE;
    a3 BINARY_DOUBLE; b3 BINARY_DOUBLE; c3 BINARY_DOUBLE; kk2 PLS_INTEGER; tst BINARY_DOUBLE;
    -- segs
    nh PLS_INTEGER := 0;
    h_k t_i; h_seq t_i; h_sx1 t_d; h_sx2 t_d; h_ix1 t_d; h_ix2 t_d; h_ff t_i; h_fc t_i; h_bf t_i; h_bc t_i;
    h_bsec t_i; h_fsky t_i; h_fl t_i; h_xoff t_i; h_up t_i; h_mid t_i; h_lo t_i; h_bsky t_i;
    xa BINARY_DOUBLE; ya BINARY_DOUBLE; xb BINARY_DOUBLE; yb BINARY_DOUBLE;
    cx1 BINARY_DOUBLE; cy1 BINARY_DOUBLE; cx2 BINARY_DOUBLE; cy2 BINARY_DOUBLE;
    sx1 BINARY_DOUBLE; sx2 BINARY_DOUBLE; k PLS_INTEGER; fs PLS_INTEGER; bs PLS_INTEGER;
    minocc t_i; lo PLS_INTEGER; hi PLS_INTEGER;
    -- parts
    np_ PLS_INTEGER; q_kind t_i; q_tex t_i; q_zb t_d; q_zt t_d; q_vab t_i; q_addh t_i; q_pcode t_i;
    tt BINARY_DOUBLE; invx BINARY_DOUBLE; uox BINARY_DOUBLE; depth BINARY_DOUBLE; ucol BINARY_DOUBLE;
    scale BINARY_DOUBLE; ytf BINARY_DOUBLE; ybf BINARY_DOUBLE; uo1 BINARY_DOUBLE; uo2 BINARY_DOUBLE;
    ys BINARY_DOUBLE; ye BINARY_DOUBLE; tw PLS_INTEGER; th PLS_INTEGER; ui BINARY_DOUBLE; lt PLS_INTEGER;
    tcode PLS_INTEGER; kind PLS_INTEGER; vis_v BOOLEAN; lv BINARY_DOUBLE;
    -- pcols
    npc PLS_INTEGER := 0; pc_h t_i; pc_kind t_i; pc_d t_d; pc_yt t_d; pc_yb t_d; pcn t_i;
    pc_k2 t_i; od t_d; ok2 t_i; dpc BINARY_DOUBLE; k2 PLS_INTEGER;
    h_ca t_i; h_fbw t_i; h_own t_i; h_fsec t_i; cc_i PLS_INTEGER; cf_i PLS_INTEGER;
    q_dzt t_d; q_dzb t_d; q_k2 t_i; q_open t_i; q_tw t_i; q_th t_i; q_cb t_i; q_va t_d; q_st t_i;
    sid PLS_INTEGER; yoff PLS_INTEGER; seqi PLS_INTEGER; lbase PLS_INTEGER; ix1 BINARY_DOUBLE; dix BINARY_DOUBLE;
    dsx BINARY_DOUBLE; duo BINARY_DOUBLE; qd BINARY_DOUBLE; pstr PLS_INTEGER; wy0 PLS_INTEGER; wy1 PLS_INTEGER; kq BINARY_DOUBLE; vv2 BINARY_DOUBLE; sa0 PLS_INTEGER; sa1 PLS_INTEGER; tbn PLS_INTEGER; kt BINARY_DOUBLE; ce PLS_INTEGER; r0 PLS_INTEGER; r1 PLS_INTEGER;
    ord t_i; no PLS_INTEGER; r PLS_INTEGER; j PLS_INTEGER; rh PLS_INTEGER; jh PLS_INTEGER; lessp BOOLEAN;
    cc_max PLS_INTEGER; fc_min PLS_INTEGER; cc_sky PLS_INTEGER; sf_y0 PLS_INTEGER; sc_y1 PLS_INTEGER; psx PLS_INTEGER;
    ccb PLS_INTEGER; fcb PLS_INTEGER; own BOOLEAN; nfd BINARY_DOUBLE; ncd BINARY_DOUBLE;
    y0 PLS_INTEGER; y1 PLS_INTEGER; sec PLS_INTEGER; z PLS_INTEGER; sl PLS_INTEGER; sk PLS_INTEGER; v PLS_INTEGER;
    -- z
    q BINARY_DOUBLE; s PLS_INTEGER; p PLS_INTEGER; x PLS_INTEGER; cz BINARY_DOUBLE; o PLS_INTEGER;
    xl0 PLS_INTEGER; yt0 PLS_INTEGER; tx PLS_INTEGER; vrow t_i; ucol_i t_i; nrun PLS_INTEGER; vrw PLS_INTEGER; rv t_i; ry0 t_i; ry1 t_i; spk t_i; uq BOOLEAN; sp_stb t_i;
    zi PLS_INTEGER; md BINARY_DOUBLE; sd BINARY_DOUBLE; lbx PLS_INTEGER; tad BINARY_DOUBLE; cb PLS_INTEGER; lb PLS_INTEGER; v0d BINARY_DOUBLE; ysd BINARY_DOUBLE;
    vsd BINARY_DOUBLE; thd BINARY_DOUBLE; vv BINARY_DOUBLE; pv BINARY_DOUBLE; cc PLS_INTEGER; zc BINARY_DOUBLE; wx BINARY_DOUBLE; wy BINARY_DOUBLE; tu PLS_INTEGER; tv PLS_INTEGER;
    cbx PLS_INTEGER; yn PLS_INTEGER; skyw PLS_INTEGER; skyh PLS_INTEGER; skyb PLS_INTEGER; i PLS_INTEGER; y PLS_INTEGER;
    msgv t_i; uiv t_i; ch VARCHAR2(4); pen PLS_INTEGER; pname VARCHAR2(16); pidx PLS_INTEGER; strv VARCHAR2(40);
    mx_ PLS_INTEGER; my_ PLS_INTEGER;
    wl_lump t_v; wl_w t_i; wl_h t_i; wl_x t_i; wl_y t_i; wl_fb t_i; nwl PLS_INTEGER;

    PROCEDURE ui_patch(p_layer PLS_INTEGER, p_name VARCHAR2, p_x PLS_INTEGER, p_y PLS_INTEGER) IS
      ix PLS_INTEGER; xx PLS_INTEGER; yy PLS_INTEGER; key PLS_INTEGER; pp PLS_INTEGER;
    BEGIN
      IF NOT g_up_idx.EXISTS(p_name) THEN RETURN; END IF;
      ix := g_up_idx(p_name);
      load_patch_pixels(p_name);
      FOR m IN g_px_from(p_name) .. g_px_from(p_name) + g_px_cnt(p_name) - 1 LOOP
        xx := p_x - g_up_left(ix) + g_px_dx(m);
        yy := p_y - g_up_top(ix) + g_px_dy(m);
        IF xx BETWEEN 0 AND 319 AND yy BETWEEN 168 AND 199 THEN
          pp := (yy - 168) * 320 + xx;
          IF g_hud(pp) >= 0 THEN
            key := p_layer * 256 + g_px_pi(m);
            IF NOT uiv.EXISTS(pp) OR uiv(pp) < key THEN uiv(pp) := key; END IF;
          END IF;
        END IF;
      END LOOP;
    END;

    PROCEDURE ui_value(p_val NUMBER, p_rx PLS_INTEGER, p_y PLS_INTEGER, p_font VARCHAR2, p_dw PLS_INTEGER) IS
      sv_ VARCHAR2(64);
    BEGIN
      IF p_val IS NULL THEN RETURN; END IF;
      sv_ := TO_CHAR(p_val);
      FOR dd IN 0 .. LEAST(LENGTH(sv_), 320) - 1 LOOP
        ui_patch(1, p_font || SUBSTR(sv_, dd + 1, 1), p_rx - (LENGTH(sv_) - dd) * p_dw, p_y);
      END LOOP;
    END;
  BEGIN
    IF g_debug = 1 THEN g_tm := NULL; g_t0 := SYSTIMESTAMP; g_tl := g_t0; END IF;
    IF g_map IS NULL OR g_map <> p_map THEN load_static(p_map); tmark('load'); END IF;

    -- ------------------------------------------------------------ camera (pose as CedarDB sees it)
    px := pose_conv(p_px); py := pose_conv(p_py); pz := pose_conv(p_pz); pa := pose_conv(p_pangle);
    vr := pa * c_pi180;
    cs := COS(-vr); sn := SIN(-vr); cv := COS(vr); sv := SIN(vr);
    skill_bit := CASE WHEN p_skill <= 1 THEN 1 WHEN p_skill = 2 THEN 2 ELSE 4 END;

    -- ------------------------------------------------------------ per-frame state (SQL)
    SELECT NVL(ps.level_tics, 0), NVL(w.sx, 1d), NVL(w.sy, 32d),
           CASE WHEN NVL(ps.light_amp_tics, 0) > 0 THEN 16 ELSE NVL(w.flash_seq_index, -1) + 1 END,
           CASE WHEN NVL(ps.invuln_tics, 0) > 0 THEN 1 ELSE 0 END,
           wd.sprite, wd.flash_sprite,
           CASE WHEN NVL(w.state, 'ready') IN ('up', 'down') THEN rf.frame ELSE mf.frame END,
           CASE WHEN (CASE WHEN NVL(w.state, 'ready') IN ('up', 'down') THEN rf.fullbright ELSE mf.fullbright END)
                THEN 1 ELSE 0 END,
           ff.frame, CASE WHEN ff.fullbright IS NULL OR ff.fullbright THEN 1 ELSE 0 END,
           CASE WHEN ps.player_thing_id IS NULL THEN 0 ELSE 1 END,
           ps.health, CASE WHEN ps.alive THEN 1 ELSE 0 END, ps.pain_face_tics, ps.armor,
           ps.ammo_bullets, ps.ammo_shells, ps.ammo_rockets, ps.ammo_cells,
           CASE WHEN ps.key_blue THEN 1 ELSE 0 END, CASE WHEN ps.key_yellow THEN 1 ELSE 0 END,
           CASE WHEN ps.key_red THEN 1 ELSE 0 END,
           ps.message, ps.message_tics, CASE WHEN ps.backpack THEN 1 ELSE 0 END, wd.ammo_type,
           CASE WHEN ps.player_thing_id IS NULL THEN NULL
                WHEN ps.damage_count > 0 THEN LEAST(7, TRUNC((ps.damage_count + 7) / 8)) + 1
                WHEN ps.bonus_count > 0 THEN LEAST(3, TRUNC((ps.bonus_count + 7) / 8)) + 9
                WHEN ps.radsuit_tics > 128 OR BITAND(ps.radsuit_tics, 8) <> 0 THEN 13 ELSE 0 END,
           (SELECT NVL(SUM(POWER(2, o.weapon_id)), 0) FROM st_player_weapon_owned o
             WHERE o.tic = p_tic AND o.map_id = p_map AND o.player_thing_id = p_player AND o.weapon_id BETWEEN 2 AND 7)
      INTO f_t, w_sx, w_sy, f_extra, f_invuln, w_spr, w_fspr, w_frame, w_fb, w_fframe, w_ffb,
           has_ps, u_health, u_alive, u_pain, u_armor, u_bul, u_she, u_roc, u_cel, u_kb, u_ky, u_kr,
           u_msg, u_mtics, u_bp, u_ammo, u_pal, u_owned
      FROM dual
      LEFT JOIN st_player_weapons w ON w.tic = p_tic AND w.map_id = p_map AND w.player_thing_id = p_player
      LEFT JOIN st_player_state ps ON ps.tic = p_tic AND ps.map_id = p_map AND ps.player_thing_id = p_player
      JOIN weapon_defs wd ON wd.weapon_id = NVL(w.current_weapon, 2)
      LEFT JOIN weapon_frames rf ON rf.weapon_id = wd.weapon_id AND rf.state = 'ready' AND rf.seq_index = 0
      LEFT JOIN weapon_frames mf ON mf.weapon_id = wd.weapon_id AND mf.state = NVL(w.state, 'ready')
                                AND mf.seq_index = NVL(w.seq_index, 0)
      LEFT JOIN weapon_frames ff ON ff.weapon_id = wd.weapon_id AND ff.state = 'flash' AND ff.seq_index = w.flash_seq_index;
    p_pal := u_pal;

    -- sectors with animated light (reference animated_light), current heights/textures
    SELECT s.id, s.floor_height, s.ceil_height, s.floor_tex, s.ceil_tex,
           NVL(LEAST(255, GREATEST(0,
             CASE k.special
               WHEN 2  THEN CASE WHEN MOD(f_t + k.phase, 20) < 5 THEN k.base_light ELSE k.dark_light END
               WHEN 13 THEN CASE WHEN MOD(f_t, 20) < 5 THEN k.base_light ELSE k.dark_light END
               WHEN 3  THEN CASE WHEN MOD(f_t + k.phase, 40) < 5 THEN k.base_light ELSE k.dark_light END
               WHEN 12 THEN CASE WHEN MOD(f_t, 40) < 5 THEN k.base_light ELSE k.dark_light END
               WHEN 1  THEN CASE WHEN MOD(k.sector_id * 2654435761 + TRUNC(f_t / 4), 8) < 2 THEN k.dark_light ELSE k.base_light END
               WHEN 17 THEN GREATEST(k.dark_light, k.base_light
                            - MOD(MOD(MOD(TRUNC(f_t / 3), 1000) * MOD(TRUNC(f_t / 3), 1000) * 1103515245 + k.sector_id * 40503, 1009), 4)
                              * GREATEST(1, TRUNC((k.base_light - k.dark_light) / 4)))
               WHEN 8  THEN k.dark_light + 8 * CASE WHEN MOD(f_t + k.phase, 2 * k.glow_steps) < k.glow_steps
                                                   THEN MOD(f_t + k.phase, 2 * k.glow_steps)
                                                   ELSE 2 * k.glow_steps - MOD(f_t + k.phase, 2 * k.glow_steps) END
               ELSE k.base_light END)), s.light_level)
      BULK COLLECT INTO a, b, c, s1, s2, d
      FROM st_sectors s
      LEFT JOIN (SELECT f.sector_id, f.base_light, f.dark_light, f.special, MOD(f.sector_id * 7919, 64) AS phase,
                        GREATEST(1, TRUNC((f.base_light - f.dark_light) / 8)) AS glow_steps
                 FROM st_sector_light_fx f WHERE f.tic = p_tic AND f.map_id = p_map) k ON k.sector_id = s.id
      WHERE s.tic = p_tic AND s.map_id = p_map;
    s_ok.DELETE;
    FOR i IN 1 .. a.COUNT LOOP
      s_ok(a(i)) := 1; s_floor(a(i)) := b(i); s_ceil(a(i)) := c(i); s_ftex(a(i)) := s1(i); s_ctex(a(i)) := s2(i);
      s_light(a(i)) := d(i); s_csky(a(i)) := CASE WHEN s2(i) = 'F_SKY1' THEN 1 ELSE 0 END;
      -- flat code of the plane texture names: -2 sky, flat index, 0 unknown
      IF s1(i) = 'F_SKY1' THEN s_fcode(a(i)) := -2; ELSIF g_fl_idx.EXISTS(s1(i)) THEN s_fcode(a(i)) := g_fl_idx(s1(i)); ELSE s_fcode(a(i)) := 0; END IF;
      IF s2(i) = 'F_SKY1' THEN s_ccode(a(i)) := -2; ELSIF g_fl_idx.EXISTS(s2(i)) THEN s_ccode(a(i)) := g_fl_idx(s2(i)); ELSE s_ccode(a(i)) := 0; END IF;
      s_fb(a(i)) := -1; s_cb(a(i)) := -1;
      k := s_fcode(a(i)); IF k > 0 THEN s_fb(a(i)) := g_fl_base(k); IF s_fb(a(i)) < 0 THEN s_fb(a(i)) := flat_base(k); END IF; END IF;
      k := s_ccode(a(i)); IF k > 0 THEN s_cb(a(i)) := g_fl_base(k); IF s_cb(a(i)) < 0 THEN s_cb(a(i)) := flat_base(k); END IF; END IF;
      s_lb(a(i)) := (15 - LEAST(15, GREATEST(0, FLOOR(d(i) / 16d) + f_extra))) * 4;
      -- panel plane keys: source 1 (class 9), stable sector*2 + (0 floor | 1 ceiling) + 32768
      s_sf(a(i)) := 9 * 65536 + LEAST(65535, GREATEST(0, a(i) * 2 + 32768));
      s_sc(a(i)) := 9 * 65536 + LEAST(65535, GREATEST(0, a(i) * 2 + 32769));
    END LOOP;
    o_up.DELETE; o_mid.DELETE; o_lo.DELETE;
    SELECT seg_id, upper_tex, mid_tex, lower_tex BULK COLLECT INTO a, s1, s2, s3
      FROM st_render_seg_tex WHERE tic = p_tic AND map_id = p_map;
    FOR i IN 1 .. a.COUNT LOOP o_up(a(i)) := s1(i); o_mid(a(i)) := s2(i); o_lo(a(i)) := s3(i); END LOOP;
    tmark('state');

    -- ------------------------------------------------------------ BSP: frustum keep per child, front side per node
    a1 := (sn - g_thf * cs); b1 := (cs + g_thf * sn); c1 := (-px * sn - py * cs + g_thf * (px * cs - py * sn));
    a2 := (-sn - g_thf * cs); b2 := (-cs + g_thf * sn); c2 := (px * sn + py * cs + g_thf * (px * cs - py * sn));
    a3 := (-cs); b3 := sn; c3 := (g_near + px * cs - py * sn);
    -- Front-first depth-first traversal of the kept tree. The reference's order statistic
    -- rank(leaf) = 1 + sum over its path of [side <> front] * leaves(front child) is exactly the
    -- position of the leaf in this traversal, so numbering the visible leaves 1, 2, ... in
    -- visiting order gives the same order (seq is only compared, never used as a value).
    -- A child box is tested (frustum, camera inside) only when its parent is reached.
    nvis := 0; sp_ := 1; stk(1) := g_root;
    WHILE sp_ > 0 LOOP
      k := stk(sp_); sp_ := sp_ - 1;
      IF k < 0 THEN
        nvis := nvis + 1; vis(nvis) := -k - 1;     -- subsector
        CONTINUE;
      END IF;
      IF ROUND(px - g_nd_x(k)) * g_nd_dy(k) - ROUND(py - g_nd_y(k)) * g_nd_dx(k) > 0 THEN fr := 1; ELSE fr := 0; END IF;
      -- push the back child first so that the front child is visited first
      FOR o2 IN 0 .. 1 LOOP
        kk2 := k * 2 + CASE WHEN o2 = 0 THEN 1 - fr ELSE fr END;
        IF px BETWEEN g_nc_l(kk2) AND g_nc_r(kk2) AND py BETWEEN g_nc_b(kk2) AND g_nc_t(kk2) THEN
          ok := TRUE;
        ELSE
          ok := FALSE;
          tst := a1 * CASE WHEN a1 >= 0 THEN g_nc_l(kk2) ELSE g_nc_r(kk2) END
               + b1 * CASE WHEN b1 >= 0 THEN g_nc_b(kk2) ELSE g_nc_t(kk2) END + c1;
          IF tst <= 0.5d THEN
            tst := a2 * CASE WHEN a2 >= 0 THEN g_nc_l(kk2) ELSE g_nc_r(kk2) END
                 + b2 * CASE WHEN b2 >= 0 THEN g_nc_b(kk2) ELSE g_nc_t(kk2) END + c2;
            IF tst <= 0.5d THEN
              tst := a3 * CASE WHEN a3 >= 0 THEN g_nc_l(kk2) ELSE g_nc_r(kk2) END
                   + b3 * CASE WHEN b3 >= 0 THEN g_nc_b(kk2) ELSE g_nc_t(kk2) END + c3;
              IF tst <= 0.5d THEN ok := TRUE; END IF;
            END IF;
          END IF;
        END IF;
        IF ok THEN sp_ := sp_ + 1; stk(sp_) := g_ch(kk2); END IF;
      END LOOP;
    END LOOP;
    tmark('bsp');

    -- player sector: first seg (lowest seg_id) of the nearest visible subsector
    ps_ok := FALSE;
    IF nvis > 0 THEN
      ssid := vis(1);
      IF g_sg_from.EXISTS(ssid) THEN
        k := g_sg_fsec(g_sg_from(ssid));
        IF s_ok.EXISTS(k) THEN ps_ok := TRUE; ps_id := k; END IF;
      END IF;
    END IF;

    -- ------------------------------------------------------------ segs: cull, transform, clip, project
    FOR seq IN 1 .. nvis LOOP
      ssid := vis(seq);
      IF g_sg_from.EXISTS(ssid) THEN
        FOR sg IN g_sg_from(ssid) .. g_sg_from(ssid) + g_sg_cnt(ssid) - 1 LOOP
          IF (g_sg_x2(sg) - g_sg_x1(sg)) * ROUND(py - g_sg_y1(sg)) - (g_sg_y2(sg) - g_sg_y1(sg)) * ROUND(px - g_sg_x1(sg)) < 0 THEN
            xa := (g_sg_x1(sg) - px) * cs - (g_sg_y1(sg) - py) * sn;
            ya := -((g_sg_x1(sg) - px) * sn + (g_sg_y1(sg) - py) * cs);
            xb := (g_sg_x2(sg) - px) * cs - (g_sg_y2(sg) - py) * sn;
            yb := -((g_sg_x2(sg) - px) * sn + (g_sg_y2(sg) - py) * cs);
            IF xa > 0 OR xb > 0 THEN
              IF xa < g_near THEN cx1 := g_near; cy1 := ya + (g_near - xa) * (yb - ya) / (xb - xa);
              ELSE cx1 := xa; cy1 := ya; END IF;
              IF xb < g_near THEN cx2 := g_near; cy2 := yb + (g_near - xb) * (ya - yb) / (xa - xb);
              ELSE cx2 := xb; cy2 := yb; END IF;
              sx1 := c_cx + g_focal * (cy1 / cx1); sx2 := c_cx + g_focal * (cy2 / cx2);
              fs := g_sg_fsec(sg);
              bs := g_sg_bsec(sg);
              IF GREATEST(sx1, sx2) >= 0 AND LEAST(sx1, sx2) < 320 AND s_ok.EXISTS(fs) THEN
                nh := nh + 1;
                h_k(nh) := sg; h_seq(nh) := seq; h_sx1(nh) := sx1; h_sx2(nh) := sx2;
                h_ix1(nh) := 1d / cx1; h_ix2(nh) := 1d / cx2;
                h_ff(nh) := s_floor(fs); h_fc(nh) := s_ceil(fs); h_fl(nh) := s_light(fs); h_fsky(nh) := s_csky(fs);
                IF bs >= 0 AND s_ok.EXISTS(bs) THEN
                  h_bsec(nh) := bs; h_bf(nh) := s_floor(bs); h_bc(nh) := s_ceil(bs); h_bsky(nh) := s_csky(bs);
                ELSE
                  h_bsec(nh) := -1; h_bf(nh) := NULL; h_bc(nh) := NULL; h_bsky(nh) := 0;
                END IF;
                h_xoff(nh) := g_sg_xoff(sg) + CASE WHEN g_sg_scroll(sg) = 1 THEN f_t ELSE 0 END;
                k := g_sg_id(sg);
                IF o_up.EXISTS(k) THEN
                  h_up(nh) := wcode(NVL(o_up(k), g_sg_up(sg))); h_mid(nh) := wcode(NVL(o_mid(k), g_sg_mid(sg)));
                  h_lo(nh) := wcode(NVL(o_lo(k), g_sg_lo(sg)));
                ELSE
                  h_up(nh) := g_sg_upc(sg); h_mid(nh) := g_sg_midc(sg); h_lo(nh) := g_sg_loc(sg);
                END IF;
              END IF;
            END IF;
          END IF;
        END LOOP;
      END IF;
    END LOOP;

    -- solid occlusion: nearest (smallest bsp rank) fully solid seg per column
    FOR xx IN 0 .. 319 LOOP minocc(xx) := c_big; pcn(xx) := 0; bt(xx) := -1; bk(xx) := -1d; bb(xx) := 168; bkb(xx) := -1d; END LOOP;
    FOR i IN 1 .. nh LOOP
      IF (h_bsec(i) < 0 OR h_bc(i) <= h_bf(i)) AND h_sx1(i) <> h_sx2(i) THEN
        lo := GREATEST(0d, FLOOR(LEAST(h_sx1(i), h_sx2(i))));
        hi := LEAST(319d, CEIL(GREATEST(h_sx1(i), h_sx2(i))));
        FOR xx IN lo .. hi LOOP
          IF h_seq(i) < minocc(xx) THEN minocc(xx) := h_seq(i); END IF;
        END LOOP;
      END IF;
    END LOOP;
    tmark('segs');

    -- ------------------------------------------------------------ wall parts x columns
    -- Per seg and part, everything that does not depend on the column is computed once (same
    -- IEEE operations as per column: (zt - pz), texture size/base, V origin term, stable key,
    -- light base); per column only the perspective terms. A part's top z >= bottom z for every
    -- kind, so ytf <= ybf (scale > 0).
    -- z-buffer and framebuffer reset (walls are z-tested and shaded as they are generated)
    zq := g_zq0; fb := g_fb0;
    tmark('zinit');
    nw := 0; np := 0; nz := 0; zmap.DELETE;
    -- panels of column xx live at xx * pstr + 1 .. (a seg yields at most 3 panels per column)
    pstr := 4 * nh + 4;
    FOR i IN 1 .. nh LOOP
      sx1 := h_sx1(i); sx2 := h_sx2(i);
      IF sx1 = sx2 THEN CONTINUE; END IF;
      k := h_k(i);
      -- parts of this seg (reference unpivot)
      np_ := 0;
      IF h_bsec(i) < 0 THEN
        IF h_fc(i) > h_ff(i) THEN
          np_ := np_ + 1; q_kind(np_) := K_SOLID; q_pcode(np_) := 0; q_tex(np_) := h_mid(i);
          q_zb(np_) := h_ff(i); q_zt(np_) := h_fc(i);
          q_vab(np_) := CASE WHEN g_sg_pegb(k) = 1 THEN h_ff(i) ELSE h_fc(i) END; q_addh(np_) := g_sg_pegb(k);
        END IF;
      ELSE
        IF NOT (h_fsky(i) = 1 AND h_bsky(i) = 1) THEN
          IF h_bc(i) < h_fc(i) THEN
            np_ := np_ + 1; q_kind(np_) := K_UPPER; q_pcode(np_) := 1; q_tex(np_) := h_up(i);
            q_zb(np_) := h_bc(i); q_zt(np_) := h_fc(i);
            q_vab(np_) := CASE WHEN g_sg_pegt(k) = 1 THEN h_fc(i) ELSE h_bc(i) END; q_addh(np_) := 1 - g_sg_pegt(k);
          ELSIF h_bc(i) > h_fc(i) THEN
            np_ := np_ + 1; q_kind(np_) := K_UPPER_OPEN; q_pcode(np_) := 7; q_tex(np_) := -1;
            q_zb(np_) := h_fc(i); q_zt(np_) := h_bc(i); q_vab(np_) := NULL; q_addh(np_) := 0;
          ELSE
            np_ := np_ + 1; q_kind(np_) := K_UPPER_FLUSH; q_pcode(np_) := 7; q_tex(np_) := -1;
            q_zb(np_) := h_fc(i); q_zt(np_) := h_bc(i); q_vab(np_) := NULL; q_addh(np_) := 0;
          END IF;
        END IF;
        IF h_bf(i) > h_ff(i) THEN
          np_ := np_ + 1; q_kind(np_) := K_LOWER; q_pcode(np_) := 2; q_tex(np_) := h_lo(i);
          q_zb(np_) := h_ff(i); q_zt(np_) := h_bf(i);
          q_vab(np_) := CASE WHEN g_sg_pegb(k) = 1 THEN h_fc(i) ELSE h_bf(i) END; q_addh(np_) := 0;
        ELSE
          np_ := np_ + 1; q_kind(np_) := K_LOWER_DOWN; q_pcode(np_) := 3; q_tex(np_) := -1;
          q_zb(np_) := h_bf(i); q_zt(np_) := h_ff(i); q_vab(np_) := NULL; q_addh(np_) := 0;
        END IF;
        IF h_mid(i) <> -1 AND h_fc(i) > h_ff(i) THEN
          np_ := np_ + 1; q_kind(np_) := K_MIDMASK; q_pcode(np_) := 7; q_tex(np_) := h_mid(i);
          q_zb(np_) := h_ff(i); q_zt(np_) := h_fc(i);
          q_vab(np_) := CASE WHEN g_sg_pegb(k) = 1 THEN GREATEST(h_ff(i), h_bf(i)) ELSE LEAST(h_fc(i), h_bc(i)) END;
          q_addh(np_) := g_sg_pegb(k);
        END IF;
      END IF;
      IF np_ = 0 THEN CONTINUE; END IF;
      -- per-part constants
      sid := g_sg_id(k); yoff := g_sg_yoff(k); seqi := h_seq(i);
      FOR m IN 1 .. np_ LOOP
        q_dzt(m) := q_zt(m) - pz; q_dzb(m) := q_zb(m) - pz;
        kind := q_kind(m);
        q_k2(m) := seqi * 65536 + kind * 8192 + sid;
        q_open(m) := CASE WHEN kind IN (K_UPPER_OPEN, K_UPPER_FLUSH, K_LOWER_DOWN) THEN 1 ELSE 0 END;
        tcode := q_tex(m);
        IF tcode <> -1 THEN
          IF tcode > 0 THEN
            tw := g_wt_w(tcode); th := g_wt_h(tcode);
            cb := g_wt_base(tcode); IF cb < 0 THEN cb := wall_base(tcode); END IF;
          ELSE tw := 64; th := 64; cb := -1; END IF;
          q_tw(m) := tw; q_th(m) := th; q_cb(m) := cb;
          q_va(m) := TO_BINARY_DOUBLE(q_vab(m) + CASE WHEN q_addh(m) = 1 THEN th ELSE 0 END);
          q_st(m) := LEAST(65535, GREATEST(0, sid * 8 + q_pcode(m) + 32768));
        END IF;
      END LOOP;
      lbase := (15 - LEAST(15, GREATEST(0, FLOOR(h_fl(i) / 16d) + g_sg_lbias(k) + f_extra))) * 4;
      ix1 := h_ix1(i); dix := h_ix2(i) - h_ix1(i); dsx := sx2 - sx1;
      uo1 := (h_xoff(i) + g_sg_u1(k)) * h_ix1(i);
      uo2 := (h_xoff(i) + g_sg_u2(k)) * h_ix2(i);
      duo := uo2 - uo1;
      lo := GREATEST(0d, FLOOR(LEAST(sx1, sx2)));
      hi := LEAST(319d, CEIL(GREATEST(sx1, sx2)));
      FOR xx IN lo .. hi LOOP
        IF seqi > minocc(xx) THEN CONTINUE; END IF;
        tt := LEAST(1d, GREATEST(0d, (g_yd(xx) - sx1) / dsx));
        invx := ix1 + tt * dix;
        uox := uo1 + tt * duo;
        depth := 1d / invx;
        ucol := uox / invx;
        scale := g_focal * invx;
        lt := -1;
        FOR m IN 1 .. np_ LOOP
          ytf := c_cy - scale * q_dzt(m);
          ybf := c_cy - scale * q_dzb(m);
          IF ytf < 168 AND ybf >= 0 THEN
            -- wall span (drawable parts with a texture)
            IF q_tex(m) <> -1 THEN
              IF ytf > 0d THEN ys := CEIL(LEAST(167d, ytf)); ELSE ys := 0d; END IF;
              IF ybf < 167d THEN ye := FLOOR(ybf); ELSE ye := 167d; END IF;
              IF ye >= ys THEN
                IF lt < 0 THEN
                  -- per column: light (zlight of the wall depth) and the depth part of the key
                  IF f_invuln = 1 THEN lt := 32 * 256;
                  ELSE
                    IF depth = 0 THEN lv := 0; ELSE lv := FLOOR(LEAST(47d, GREATEST(0d, 2560d / depth)) / 2d); END IF;
                    lt := GREATEST(0, LEAST(31, lbase - lv)) * 256;
                  END IF;
                  qd := ROUND(GREATEST(0d, LEAST(depth, 131071d)) * 4096d) * 1048576d;
                END IF;
                -- wall span: z-test and shade now (eager; the z-buffer is order independent)
                nw := nw + 1;
                q := qd + q_st(m); wy0 := ys; wy1 := ye; sa0 := wy0; sa1 := wy1;
                -- covered bands: rows 0..bt(x) and bb(x)..167 are each covered contiguously by
                -- earlier wall spans, and every pixel there has zq <= the band bound (zq only
                -- decreases). A span with a larger key loses on its overlap with a band, so the
                -- overlap is skipped; the span then extends a band it touches (afterwards all
                -- its pixels have zq <= q).
                tbn := bt(xx); kt := bk(xx);
                IF sa0 <= tbn + 1 THEN
                  IF sa0 <= tbn AND q > kt THEN wy0 := tbn + 1; END IF;
                  IF sa1 > tbn THEN bt(xx) := sa1; IF q > kt THEN bk(xx) := q; END IF; END IF;
                END IF;
                tbn := bb(xx); kt := bkb(xx);
                IF sa1 >= tbn - 1 THEN
                  IF sa1 >= tbn AND q > kt THEN wy1 := tbn - 1; END IF;
                  IF sa0 < tbn THEN bb(xx) := sa0; IF q > kt THEN bkb(xx) := q; END IF; END IF;
                END IF;
                IF wy0 > wy1 THEN cb := -2; ELSE p := xx * 168 + wy0 - 1; cb := q_cb(m); END IF;
                IF cb = -2 THEN NULL;   -- fully inside covered bands: loses everywhere
                ELSIF cb >= 0 THEN
                  -- texel row FLOOR(v0 + (y - ys) * step) mod th in the texture column of ucol
                  tw := q_tw(m); th := q_th(m);
                  ui := FLOOR(ucol - tw * FLOOR(ucol / tw));
                  cb := cb + ui * th;
                  v0d := q_va(m) - (pz + (c_cy - ys) / scale) + yoff;
                  vsd := 1d / scale; thd := th; ysd := ys;
                  -- the texel row is non-decreasing in y (step > 0): when the first and last
                  -- drawn rows lie in the same texture period k, row mod th = row - k * th
                  vv := FLOOR(v0d + (g_yd(wy0) - ysd) * vsd);
                  kq := FLOOR(vv / thd);
                  vv2 := FLOOR(v0d + (g_yd(wy1) - ysd) * vsd);
                  IF vv2 < (kq + 1d) * thd THEN
                    cb := cb - kq * th;
                    IF vsd < 1d THEN
                      pv := c_zinit;
                      FOR y IN wy0 .. wy1 LOOP
                        p := p + 1;
                        IF q < zq(p) THEN
                          zq(p) := q;
                          vv := FLOOR(v0d + (g_yd(y) - ysd) * vsd);
                          IF vv <> pv THEN pv := vv; cc := g_cmap(lt + g_tx(cb + vv)); END IF;
                          fb(p) := cc;
                        END IF;
                      END LOOP;
                    ELSE
                      FOR y IN wy0 .. wy1 LOOP
                        p := p + 1;
                        IF q < zq(p) THEN
                          zq(p) := q;
                          fb(p) := g_cmap(lt + g_tx(cb + FLOOR(v0d + (g_yd(y) - ysd) * vsd)));
                        END IF;
                      END LOOP;
                    END IF;
                  ELSIF vsd < 1d THEN
                    -- magnified: consecutive rows often repeat the texel row; reuse its colour
                    pv := c_zinit;
                    FOR y IN wy0 .. wy1 LOOP
                      p := p + 1;
                      IF q < zq(p) THEN
                        zq(p) := q;
                        vv := FLOOR(v0d + (g_yd(y) - ysd) * vsd);
                        IF vv <> pv THEN pv := vv; cc := g_cmap(lt + g_tx(cb + (vv - thd * FLOOR(vv / thd)))); END IF;
                        fb(p) := cc;
                      END IF;
                    END LOOP;
                  ELSE
                    FOR y IN wy0 .. wy1 LOOP
                      p := p + 1;
                      IF q < zq(p) THEN
                        zq(p) := q;
                        vv := FLOOR(v0d + (g_yd(y) - ysd) * vsd);
                        fb(p) := g_cmap(lt + g_tx(cb + (vv - thd * FLOOR(vv / thd))));
                      END IF;
                    END LOOP;
                  END IF;
                ELSE
                  cc := g_cmap(lt);
                  FOR y IN wy0 .. wy1 LOOP
                    p := p + 1;
                    IF q < zq(p) THEN zq(p) := q; fb(p) := cc; END IF;
                  END LOOP;
                END IF;
              END IF;
            END IF;
            -- panel row for the visplane clip windows
            r := pcn(xx) + 1; pcn(xx) := r; r := xx * pstr + r;
            pc_h(r) := i; pc_kind(r) := q_kind(m); pc_d(r) := depth; pc_yt(r) := ytf; pc_yb(r) := ybf; pc_k2(r) := q_k2(m);
          ELSIF q_open(m) = 1 THEN
            r := pcn(xx) + 1; pcn(xx) := r; r := xx * pstr + r;
            pc_h(r) := i; pc_kind(r) := q_kind(m); pc_d(r) := depth; pc_yt(r) := ytf; pc_yb(r) := ybf; pc_k2(r) := q_k2(m);
          END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    tmark('walls');

    -- ------------------------------------------------------------ visplanes per column
    -- per seg flags used by the sweep (front ceiling above / floor below the eye, front sector)
    FOR i IN 1 .. nh LOOP
      h_ca(i) := CASE WHEN h_fc(i) > pz THEN 1 ELSE 0 END;
      h_fbw(i) := CASE WHEN h_ff(i) < pz THEN 1 ELSE 0 END;
      h_own(i) := CASE WHEN h_fc(i) > pz OR h_fsky(i) = 1 THEN 1 ELSE 0 END;
      h_fsec(i) := g_sg_fsec(h_k(i));
    END LOOP;
    IF ps_ok THEN psx := ps_id; ELSE psx := -1; END IF;
    FOR xx IN 0 .. 319 LOOP
      -- gather and sort panels by (depth_x, bsp_seq, part, seg_id); rows arrive in BSP order,
      -- which is nearly depth order, so the insertion sort is close to linear
      no := 0;
      nfd := c_zinit; ncd := c_zinit;
      FOR r IN xx * pstr + 1 .. xx * pstr + pcn(xx) LOOP
        kind := pc_kind(r); dpc := pc_d(r); k2 := pc_k2(r);
        IF dpc < nfd AND kind IN (K_SOLID, K_LOWER, K_LOWER_DOWN) THEN nfd := dpc; END IF;
        IF dpc < ncd AND kind IN (K_SOLID, K_UPPER, K_UPPER_OPEN, K_UPPER_FLUSH) THEN ncd := dpc; END IF;
        j := no;
        WHILE j >= 1 LOOP
          EXIT WHEN od(j) < dpc OR (od(j) = dpc AND ok2(j) < k2);
          od(j + 1) := od(j); ok2(j + 1) := ok2(j); ord(j + 1) := ord(j); j := j - 1;
        END LOOP;
        od(j + 1) := dpc; ok2(j + 1) := k2; ord(j + 1) := r; no := no + 1;
      END LOOP;
      -- camera-sector seed spans (emitted first: on key ties with panel spans of the same
      -- plane the seed's lower source priority wins, so eager shading paints it only once)
      sf_y0 := 168; sc_y1 := -1;
      IF ps_ok THEN
        IF nfd = c_zinit THEN y0 := 85;
        ELSE y0 := FLOOR(LEAST(167d, GREATEST(0d, c_cy - g_focal * (s_floor(ps_id) - pz) / nfd))) + 1; END IF;
        IF s_floor(ps_id) < pz AND 167 >= y0 THEN
          sf_y0 := y0;
          np := np + 1; pl_x(np) := xx; pl_y0(np) := y0; pl_y1(np) := 167; pl_z(np) := s_floor(ps_id); pl_sky(np) := 0;
          pl_s(np) := 8 * 65536 + LEAST(65535, GREATEST(0, ps_id * 2 + 32768));
          pl_tex(np) := s_fcode(ps_id); pl_fb(np) := s_fb(ps_id); pl_lb(np) := s_lb(ps_id);
        END IF;
        IF ncd = c_zinit THEN y1 := 83;
        ELSE y1 := CEIL(LEAST(167d, GREATEST(0d, c_cy - g_focal * (s_ceil(ps_id) - pz) / ncd))) - 1; END IF;
        IF (s_ceil(ps_id) > pz OR s_csky(ps_id) = 1) AND y1 >= 0 THEN
          sc_y1 := y1;
          np := np + 1; pl_x(np) := xx; pl_y0(np) := 0; pl_y1(np) := y1; pl_z(np) := s_ceil(ps_id); pl_sky(np) := s_csky(ps_id);
          pl_s(np) := 8 * 65536 + LEAST(65535, GREATEST(0, ps_id * 2 + 32769));
          pl_tex(np) := s_ccode(ps_id); pl_fb(np) := s_cb(ps_id); pl_lb(np) := s_lb(ps_id);
        END IF;
      END IF;
      -- Panel spans of the camera sector's floor (ceiling) are clipped against this column's seed
      -- span of the same plane: on their overlap both have the same depth key and the seed's
      -- source 0 beats the panel's source 1, so those pixels can never be owned by the panel span.
      -- carried ceiling / floor: the seg (h index) of the last panel whose front ceiling is above
      -- (floor below) the eye; 0 = none. Part kinds are numbered in the reference's part order
      -- (LOWER 1, LOWER_DOWN 2, MIDMASK 3, SOLID 4, UPPER 5, UPPER_FLUSH 6, UPPER_OPEN 7): kinds
      -- >= MIDMASK fill a ceiling above, kinds <= SOLID a floor below. The fills read the clip
      -- windows before this panel advances them. An emitted plane always satisfies the
      -- reference's (z > pz OR sky) / (z < pz) test: own planes by h_own / h_fbw, carried ones
      -- because only such planes are carried.
      cc_max := 0; fc_min := 167; cc_i := 0; cf_i := 0; cc_sky := 0;
      FOR m IN 1 .. no LOOP
        r := ord(m); kind := pc_kind(r); i := pc_h(r);
        -- ceiling fill above the panel
        IF kind >= K_MIDMASK THEN
          IF h_own(i) = 1 THEN
            IF kind = K_UPPER_OPEN THEN ytf := pc_yb(r); ELSE ytf := pc_yt(r); END IF;
            y1 := CEIL(LEAST(167d, GREATEST(0d, ytf))) - 1;
            sec := h_fsec(i);
            IF sec = psx THEN y0 := GREATEST(cc_max, sc_y1 + 1); ELSE y0 := cc_max; END IF;
            IF y1 >= y0 THEN
              np := np + 1; pl_x(np) := xx; pl_y0(np) := y0; pl_y1(np) := y1; pl_z(np) := h_fc(i); pl_sky(np) := h_fsky(i);
              pl_s(np) := s_sc(sec); pl_tex(np) := s_ccode(sec); pl_fb(np) := s_cb(sec); pl_lb(np) := s_lb(sec);
            END IF;
          ELSIF cc_i > 0 AND (cc_sky = 1 OR cc_max > 0) THEN
            z := h_fc(cc_i);
            IF kind = K_UPPER_OPEN THEN ytf := pc_yb(r); ELSE ytf := pc_yt(r); END IF;
            ytf := LEAST(ytf, c_cy - g_focal * (z - pz) / g_mpd);
            y1 := CEIL(LEAST(167d, GREATEST(0d, ytf))) - 1;
            sec := h_fsec(cc_i);
            IF sec = psx THEN y0 := GREATEST(cc_max, sc_y1 + 1); ELSE y0 := cc_max; END IF;
            IF y1 >= y0 THEN
              np := np + 1; pl_x(np) := xx; pl_y0(np) := y0; pl_y1(np) := y1; pl_z(np) := z; pl_sky(np) := cc_sky;
              pl_s(np) := s_sc(sec); pl_tex(np) := s_ccode(sec); pl_fb(np) := s_cb(sec); pl_lb(np) := s_lb(sec);
            END IF;
          END IF;
        END IF;
        -- floor fill below the panel
        IF kind <= K_SOLID THEN
          IF h_fbw(i) = 1 THEN
            IF kind = K_LOWER_DOWN THEN ybf := pc_yt(r); ELSE ybf := pc_yb(r); END IF;
            y0 := FLOOR(LEAST(167d, GREATEST(0d, ybf))) + 1;
            sec := h_fsec(i);
            IF sec = psx THEN y1 := LEAST(fc_min, sf_y0 - 1); ELSE y1 := fc_min; END IF;
            IF y1 >= y0 THEN
              np := np + 1; pl_x(np) := xx; pl_y0(np) := y0; pl_y1(np) := y1; pl_z(np) := h_ff(i); pl_sky(np) := 0;
              pl_s(np) := s_sf(sec); pl_tex(np) := s_fcode(sec); pl_fb(np) := s_fb(sec); pl_lb(np) := s_lb(sec);
            END IF;
          ELSIF fc_min < 167 AND cf_i > 0 THEN
            z := h_ff(cf_i);
            IF kind = K_LOWER_DOWN THEN ybf := pc_yt(r); ELSE ybf := pc_yb(r); END IF;
            ybf := GREATEST(ybf, c_cy - g_focal * (z - pz) / g_mpd);
            y0 := FLOOR(LEAST(167d, GREATEST(0d, ybf))) + 1;
            sec := h_fsec(cf_i);
            IF sec = psx THEN y1 := LEAST(fc_min, sf_y0 - 1); ELSE y1 := fc_min; END IF;
            IF y1 >= y0 THEN
              np := np + 1; pl_x(np) := xx; pl_y0(np) := y0; pl_y1(np) := y1; pl_z(np) := z; pl_sky(np) := 0;
              pl_s(np) := s_sf(sec); pl_tex(np) := s_fcode(sec); pl_fb(np) := s_fb(sec); pl_lb(np) := s_lb(sec);
            END IF;
          END IF;
          -- advance the floor clip (SOLID, LOWER, LOWER_DOWN)
          IF kind <> K_MIDMASK THEN
            v := LEAST(167d, CEIL(GREATEST(0d, pc_yt(r))) - 1);
            IF v < fc_min THEN fc_min := v; END IF;
          END IF;
        END IF;
        -- advance the ceiling clip (SOLID, UPPER; UPPER_FLUSH without the lower clamp first)
        IF kind = K_SOLID OR kind = K_UPPER THEN
          v := FLOOR(LEAST(167d, GREATEST(0d, pc_yb(r)))) + 1;
          IF v > cc_max THEN cc_max := v; END IF;
        ELSIF kind = K_UPPER_FLUSH THEN
          lv := FLOOR(LEAST(167d, pc_yb(r))) + 1;
          v := GREATEST(0d, lv);
          IF v > cc_max THEN cc_max := v; END IF;
        END IF;
        IF h_ca(i) = 1 THEN cc_i := i; cc_sky := h_fsky(i); END IF;
        IF h_fbw(i) = 1 THEN cf_i := i; END IF;
      END LOOP;
    END LOOP;
    tmark('planes');

    -- ------------------------------------------------------------ sprites (SQL: thing_view .. thing_bounds)
    -- thing_view (reference) in SQL: thing state of this tic, view-space depth/side and the
    -- wanted rotation (ATAN2 in SQL). Sprite frame choice and screen bounds are done in PL/SQL
    -- from a static sprite_frames cache (identical operations, float4 tops included).
    SELECT LEAST(65535, GREATEST(0, tv.thing_id + 32768)), tv.sec_id, tv.branch,
           CASE WHEN tv.fullbright THEN 1 ELSE 0 END, tv.fuzz, tv.depth, tv.side, tv.base_z,
           tv.sprite || tv.frame, tv.wrot, mpl.slot
      BULK COLLECT INTO a, b, c, d, e, d1, d2, bf1, s1, f, ii
        FROM (
          SELECT t.id AS thing_id, 1 AS branch, s.id AS sec_id,
                 CASE WHEN NVL(d.explodes, FALSE) AND ai.state = 'die' THEN d.death_sprite
                      WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead') THEN d.death_sprite
                      ELSE rt.sprite END AS sprite,
                 CASE WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead')
                        THEN CASE WHEN h.health < -h.max_health AND d.xdeath_frame IS NOT NULL THEN d.xdeath_frame ELSE d.death_frame END
                      WHEN f.frame IS NOT NULL THEN f.frame ELSE rt.frame END AS frame,
                 CASE WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead') THEN d.death_fullbright
                      WHEN f.frame IS NOT NULL THEN f.fullbright ELSE rt.fullbright END AS fullbright,
                 TO_BINARY_FLOAT(CASE WHEN rt.spawn_ceiling THEN s.ceil_height - rt.thing_height
                                      WHEN d.floats AND NVL(h.alive, TRUE) THEN t.z ELSE s.floor_height END) AS base_z,
                 (t.x - px) * cv + (t.y - py) * sv AS depth,
                 (t.x - px) * sv - (t.y - py) * cv AS side,
                 MOD(MOD(FLOOR((ATAN2(t.y - py, t.x - px) / (3.14159265358979323846d / 180d) - t.angle + 202.5d) / 45d), 8) + 8, 8) + 1 AS wrot,
                 CASE WHEN NVL(d.fuzzy, FALSE) THEN 1 ELSE 0 END AS fuzz
          FROM st_render_things rt
          JOIN st_things t ON t.tic = rt.tic AND t.map_id = rt.map_id AND t.id = rt.thing_id
          LEFT JOIN st_thing_health h ON h.tic = rt.tic AND h.map_id = rt.map_id AND h.thing_id = rt.thing_id
          LEFT JOIN thing_combat_defs d ON d.thing_type = t.type
          LEFT JOIN st_monster_ai ai ON ai.tic = rt.tic AND ai.map_id = rt.map_id AND ai.thing_id = rt.thing_id
          LEFT JOIN thing_ai_frames f ON f.thing_type = t.type AND f.state = ai.state AND f.seq_index = ai.seq_index
          LEFT JOIN st_picked_up_items pu ON pu.tic = rt.tic AND pu.map_id = rt.map_id AND pu.thing_id = rt.thing_id
          JOIN st_sectors s ON s.tic = rt.tic AND s.map_id = rt.map_id AND s.id = NVL(ai.sector_id, rt.sector_id)
          WHERE rt.tic = p_tic AND rt.map_id = p_map
            AND BITAND(t.flags, skill_bit) <> 0 AND BITAND(t.flags, 16) = 0
            AND pu.thing_id IS NULL
            AND NOT (NVL(d.explodes, FALSE) AND ai.state = 'dead')
          UNION ALL
          SELECT -e.effect_id, 2, s.id, ed.sprite,
                 SUBSTR(ed.frame_sequence, LEAST(LENGTH(ed.frame_sequence) - 1, TRUNC(e.age / ed.tics_per_frame)) + 1, 1),
                 ed.fullbright, TO_BINARY_FLOAT(e.z),
                 (e.x - px) * cv + (e.y - py) * sv, (e.x - px) * sv - (e.y - py) * cv, 0, 0
          FROM st_world_effects e
          JOIN effect_sprite_defs ed ON ed.effect_type = e.effect_type
          LEFT JOIN st_sectors s ON s.tic = e.tic AND s.map_id = e.map_id AND s.id = e.sector_id
          WHERE e.tic = p_tic AND e.map_id = p_map
          UNION ALL
          SELECT ot.id, 1, s.id, 'PLAY', op.sprite_frame, FALSE, TO_BINARY_FLOAT(s.floor_height),
                 (ot.x - px) * cv + (ot.y - py) * sv, (ot.x - px) * sv - (ot.y - py) * cv,
                 MOD(MOD(FLOOR((ATAN2(ot.y - py, ot.x - px) / (3.14159265358979323846d / 180d) - ot.angle + 202.5d) / 45d), 8) + 8, 8) + 1,
                 CASE WHEN op.invis_tics > 0 THEN 1 ELSE 0 END
          FROM st_player_state op
          JOIN st_things ot ON ot.tic = op.tic AND ot.map_id = op.map_id AND ot.id = op.player_thing_id
          JOIN st_sectors s ON s.tic = op.tic AND s.map_id = op.map_id AND s.id = op.sector_id
          WHERE op.tic = p_tic AND op.map_id = p_map AND op.player_thing_id <> p_player
          UNION ALL
          SELECT -(1000000000000 + mp.projectile_id), 2, s.id,
                 CASE WHEN mp.state = 'fly' THEN pd.fly_sprite ELSE pd.impact_sprite END,
                 CASE WHEN mp.projectile_type = 'rocket' THEN
                        CASE WHEN mp.state = 'fly' THEN 'A' WHEN mp.age < 8 THEN 'B' WHEN mp.age < 14 THEN 'C' ELSE 'D' END
                      WHEN mp.projectile_type = 'plasma' THEN
                        CASE WHEN mp.state = 'fly' THEN CASE WHEN MOD(mp.age, 12) < 6 THEN 'A' ELSE 'B' END
                             WHEN mp.age < 4 THEN 'A' WHEN mp.age < 8 THEN 'B' WHEN mp.age < 12 THEN 'C'
                             WHEN mp.age < 16 THEN 'D' ELSE 'E' END
                      WHEN mp.projectile_type = 'bfg' THEN
                        CASE WHEN mp.state = 'fly' THEN CASE WHEN MOD(mp.age, 8) < 4 THEN 'A' ELSE 'B' END
                             WHEN mp.age < 8 THEN 'A' WHEN mp.age < 16 THEN 'B' WHEN mp.age < 24 THEN 'C'
                             WHEN mp.age < 32 THEN 'D' WHEN mp.age < 40 THEN 'E' ELSE 'F' END
                      ELSE CASE WHEN mp.state = 'fly' THEN CASE WHEN MOD(mp.age, 8) < 4 THEN 'A' ELSE 'B' END
                                WHEN mp.age < 5 THEN 'C' WHEN mp.age < 10 THEN 'D' ELSE 'E' END END,
                 TRUE, TO_BINARY_FLOAT(mp.z),
                 (mp.x - px) * cv + (mp.y - py) * sv, (mp.x - px) * sv - (mp.y - py) * cv,
                 CASE WHEN mp.state = 'fly' THEN
                   MOD(MOD(FLOOR((ATAN2(mp.y - py, mp.x - px) / (3.14159265358979323846d / 180d)
                                  - ATAN2(mp.vy, mp.vx) / (3.14159265358979323846d / 180d) + 202.5d) / 45d), 8) + 8, 8) + 1
                   ELSE 0 END, 0
          FROM st_monster_projectiles mp
          JOIN projectile_defs pd ON pd.projectile_type = mp.projectile_type
          LEFT JOIN st_sectors s ON s.tic = mp.tic AND s.map_id = mp.map_id AND s.id = mp.sector_id
          WHERE mp.tic = p_tic AND mp.map_id = p_map
        ) tv
        LEFT JOIN st_mp_players mpl ON mpl.tic = p_tic AND mpl.map_id = p_map AND mpl.player_thing_id = tv.thing_id
        WHERE tv.depth >= 4d AND ABS(tv.side) <= tv.depth * 2d;
    nsp := 0;
    FOR i IN 1 .. a.COUNT LOOP
      -- effects/projectiles take the camera sector's light when their sector is unknown, and
      -- (like the reference's CROSS JOIN player_sector) vanish without a camera sector
      IF c(i) = 2 AND NOT ps_ok THEN CONTINUE; END IF;
      -- sprite_frames row: wanted rotation if present, else rotation 0 (reference ORDER BY .. LIMIT 1)
      sfk := s1(i) || TO_CHAR(f(i));
      IF f(i) <> 0 AND g_sf_idx.EXISTS(sfk) THEN sfi := g_sf_idx(sfk);
      ELSIF g_sf_idx.EXISTS(s1(i) || '0') THEN sfi := g_sf_idx(s1(i) || '0');
      ELSE CONTINUE; END IF;
      -- thing_bounds: scale, origin, x extent in double; tops in float4 (CedarDB real + smallint)
      dsc := g_focal / d1(i);
      dox := c_cx + g_focal * d2(i) / d1(i);
      dxl := dox - dsc * g_sf_left(sfi);
      dxr := dox + dsc * (g_sf_w(sfi) - g_sf_left(sfi));
      ft1 := bf1(i) + TO_BINARY_FLOAT(g_sf_top(sfi));
      ft2 := ft1 - TO_BINARY_FLOAT(g_sf_h(sfi));
      dyt := c_cy - dsc * (ft1 - pz);
      dyb := c_cy - dsc * (ft2 - pz);
      IF NOT (dxr > 0 AND dxl < 320 AND dyb > 0 AND dyt < 168) THEN CONTINUE; END IF;
      IF b(i) IS NOT NULL THEN sl := s_light(b(i)); ELSE sl := s_light(ps_id); END IF;
      nsp := nsp + 1;
      sp_xl(nsp) := dxl; sp_xr(nsp) := dxr; sp_yt(nsp) := dyt; sp_yb(nsp) := dyb;
      sp_sc(nsp) := dsc; sp_w(nsp) := g_sf_w(sfi); sp_h(nsp) := g_sf_h(sfi); sp_fl(nsp) := g_sf_flip(sfi);
      k := g_sf_base(sfi); IF k < 0 THEN k := sprite_base(g_sf_lump(sfi)); g_sf_base(sfi) := k; END IF;
      sp_base(nsp) := k;
      sp_q(nsp) := ROUND(GREATEST(0d, LEAST(d1(i), 131071d)) * 4096d) * 1048576d + (4 * 65536 + a(i));
      sp_stb(nsp) := a(i);
      IF f_invuln = 1 THEN sp_l(nsp) := 32;
      ELSIF d(i) = 1 THEN sp_l(nsp) := 0;
      ELSE
        IF d1(i) = 0 THEN lv := 0; ELSE lv := FLOOR(LEAST(47d, GREATEST(0d, 2560d / d1(i))) / 2d); END IF;
        sp_l(nsp) := GREATEST(0, LEAST(31, (15 - LEAST(15, GREATEST(0, FLOOR(sl / 16d) + f_extra))) * 4 - lv));
      END IF;
      sp_fz(nsp) := e(i); sp_rd(nsp) := ROUND(d1(i)); sp_slot(nsp) := NVL(ii(i), 0);
    END LOOP;
    tmark('sprites_sql');

    -- ------------------------------------------------------------ z-buffer (exact reference key)
    -- sky column per screen column (reference plane_uv: ray angle * 256/90)
    FOR xx IN 0 .. 319 LOOP
      skyu(xx) := MOD(MOD(FLOOR(((vr - g_atn(xx)) / c_pi180) * 2.844444d), 256) + 256, 256);
    END LOOP;
    -- Eager shading: a fragment is textured, lit and COLORMAPped when it wins the depth test.
    -- Walls arrive in BSP (front-to-back) order and plane spans are clipped to their windows,
    -- so few winners are overwritten later.
    -- Exact key ties: a wall key (depth, seg, part) is unique within a column and the class bits
    -- separate walls, sprites and planes, so walls never tie; two plane fragments with equal keys
    -- belong to the same sector, plane and source and therefore have the same light and palette
    -- (keeping the first is exact). Only sprite-vs-sprite ties need the reference's light/palette
    -- comparison (shade_lp), so the owner array zo is written by the sprite pass only and is read
    -- only after a tie with a sprite key written in this frame.
    IF g_sky > 0 THEN skyw := g_wt_w(g_sky); skyh := g_wt_h(g_sky); skyb := wall_base(g_sky); END IF;
    FOR i IN 1 .. np LOOP
      x := pl_x(i); p := x * 168 + pl_y0(i) - 1; o := c_opl + i; tcode := pl_tex(i);
      IF pl_sky(i) = 1 THEN
        q := c_qsky + pl_s(i); pl_zi(i) := 0;
        IF tcode = -2 AND g_sky > 0 AND skyu(x) < skyw AND skyh >= 128 THEN
          -- sky: light 0, rotated sky column (g_skyv < 128 <= sky height)
          cb := skyb + skyu(x) * skyh;
          FOR y IN pl_y0(i) .. pl_y1(i) LOOP
            p := p + 1;
            IF q < zq(p) THEN zq(p) := q; fb(p) := g_cmap(g_tx(cb + g_skyv(y))); END IF;
          END LOOP;
        ELSE
          FOR y IN pl_y0(i) .. pl_y1(i) LOOP
            p := p + 1;
            IF q < zq(p) THEN zq(p) := q; fb(p) := g_cmap(shade_lp(o, x, y)); END IF;
          END LOOP;
        END IF;
      ELSE
        -- per distinct plane height: row depth, z-key, zlight and the depth-only part of the
        -- plane point, tabulated once per frame and shared by every span of that height
        z := pl_z(i);
        IF zmap.EXISTS(z) THEN zi := zmap(z);
        ELSE
          nz := nz + 1; zi := nz * 200; zmap(z) := zi; cz := g_focal * (z - pz);
          zt_fast(zi) := CASE WHEN ABS(cz) * 2d + ABS(px) + ABS(py) + 64d < 131000d THEN 1 ELSE 0 END;
          -- a floor (z < pz) has positive depth only below the horizon row 84, a ceiling only
          -- above it; rows on the other side get a key that never wins (and are never shaded)
          IF z < pz THEN lo := 85; hi := 167; ELSE lo := 0; hi := 83; END IF;
          FOR yy IN 0 .. 167 LOOP zt_q(zi + yy) := c_zinv; END LOOP;
          zt_vlo(zi) := 168; zt_vhi(zi) := -1;
          FOR yy IN lo .. hi LOOP
            BEGIN
              depth := cz / g_dy(yy);
              zt_d(zi + yy) := depth;
              zt_a(zi + yy) := px + depth * cv;
              zt_b(zi + yy) := py + depth * sv;
              IF depth > g_near THEN
                IF yy < zt_vlo(zi) THEN zt_vlo(zi) := yy; END IF;
                zt_vhi(zi) := yy;
                zt_q(zi + yy) := ROUND(GREATEST(0d, LEAST(depth, 131071d)) * 4096d) * 1048576d;
                lv := FLOOR(depth / 16d); IF lv > 127d THEN lv := 127d; END IF;
                zt_l(zi + yy) := g_zl(lv);
              ELSE zt_q(zi + yy) := c_zinv; zt_l(zi + yy) := 0; END IF;
            END;
          END LOOP;
        END IF;
        pl_zi(i) := zi; sd := pl_s(i);
        -- covered bands (see walls): the plane key is monotone over the plane's valid rows
        -- zt_vlo..zt_vhi (other rows never win), so the overlap with a band loses when the
        -- key at both ends of its valid part exceeds the band bound
        sa0 := pl_y0(i); sa1 := pl_y1(i);
        IF sa0 <= bt(x) THEN
          ce := LEAST(sa1, bt(x)); r0 := GREATEST(sa0, zt_vlo(zi)); r1 := LEAST(ce, zt_vhi(zi));
          IF r0 > r1 THEN sa0 := ce + 1;
          ELSIF zt_q(zi + r0) + sd > bk(x) AND zt_q(zi + r1) + sd > bk(x) THEN sa0 := ce + 1; END IF;
        END IF;
        IF sa1 >= bb(x) AND sa0 <= sa1 THEN
          ce := GREATEST(sa0, bb(x)); r0 := GREATEST(ce, zt_vlo(zi)); r1 := LEAST(sa1, zt_vhi(zi));
          IF r0 > r1 THEN sa1 := ce - 1;
          ELSIF zt_q(zi + r0) + sd > bkb(x) AND zt_q(zi + r1) + sd > bkb(x) THEN sa1 := ce - 1; END IF;
        END IF;
        p := x * 168 + sa0 - 1;
        IF tcode > 0 AND zt_fast(zi) = 1 THEN
          -- flat: wx = (px + depth*cv) + (ta*depth)*sv, wy = (py + depth*sv) - (ta*depth)*cv (the
          -- reference's operations), texel = flat[(FLOOR(wy) mod 64)*64 + FLOOR(wx) mod 64] via mod
          -- tables (|wx|,|wy| < 131000 is guaranteed by zt_fast), zlight via a clamp table
          tad := g_ta(x); cb := pl_fb(i);
          IF f_invuln = 1 THEN lbx := 64 * 128; ELSE lbx := pl_lb(i) * 128; END IF;
          FOR y IN sa0 .. sa1 LOOP
            p := p + 1;
            q := zt_q(zi + y) + sd;
            IF q < zq(p) THEN
              zq(p) := q;
              md := tad * zt_d(zi + y);
              fb(p) := g_cmap(g_lt256(lbx + zt_l(zi + y))
                              + g_tx(cb + g_m64y(FLOOR(zt_b(zi + y) - md * cv)) + g_m64(FLOOR(zt_a(zi + y) + md * sv))));
            END IF;
          END LOOP;
        ELSE
          FOR y IN sa0 .. sa1 LOOP
            p := p + 1;
            q := zt_q(zi + y) + sd;
            IF q < zq(p) THEN zq(p) := q; fb(p) := g_cmap(shade_lp(o, x, y)); END IF;
          END LOOP;
        END IF;
      END IF;
    END LOOP;
    tmark('z_planes');
    -- a sprite key can tie only with another sprite's identical key (class bits differ from
    -- walls and planes): sprites whose key is unique in this frame (checked by stable id, then
    -- by full key) need neither the owner array nor the tie test
    spk.DELETE;
    FOR i IN 1 .. nsp LOOP
      IF spk.EXISTS(sp_stb(i)) THEN spk(sp_stb(i)) := 2; ELSE spk(sp_stb(i)) := 1; END IF;
    END LOOP;
    FOR i IN 1 .. nsp LOOP
      q := sp_q(i); o := c_osp + i;
      uq := TRUE;
      IF spk(sp_stb(i)) > 1 THEN
        FOR j2 IN 1 .. nsp LOOP
          IF j2 <> i AND sp_q(j2) = q THEN uq := FALSE; EXIT; END IF;
        END LOOP;
      END IF;
      lo := GREATEST(0d, FLOOR(sp_xl(i))); hi := LEAST(319d, CEIL(sp_xr(i)) - 1);
      y0 := GREATEST(0d, FLOOR(sp_yt(i))); y1 := LEAST(167d, CEIL(sp_yb(i)) - 1);
      IF hi < lo OR y1 < y0 THEN CONTINUE; END IF;
      -- plain sprites: COLORMAP(light, texel); translated (multiplayer) and fuzz sprites via shade_lp
      IF sp_slot(i) > 1 OR sp_fz(i) = 1 THEN lbx := -1; ELSE lbx := sp_l(i) * 256; END IF;
      IF sp_sc(i) >= 2d THEN
        -- magnified sprite: the texel row is constant over runs of screen rows; fetch the texel
        -- (and skip transparent runs) once per run and column, z-test per pixel
        nrun := 0;
        FOR y IN y0 .. y1 LOOP
          vrw := LEAST(sp_h(i) - 1, GREATEST(0d, FLOOR((g_yd(y) - sp_yt(i)) / sp_sc(i)))) * sp_w(i) + sp_base(i);
          IF nrun > 0 AND vrw = rv(nrun) THEN ry1(nrun) := y;
          ELSE nrun := nrun + 1; rv(nrun) := vrw; ry0(nrun) := y; ry1(nrun) := y; END IF;
        END LOOP;
        FOR xx IN lo .. hi LOOP
          v := LEAST(sp_w(i) - 1, GREATEST(0d, FLOOR((g_yd(xx) - sp_xl(i)) / sp_sc(i))));
          IF sp_fl(i) = 1 THEN v := sp_w(i) - 1 - v; END IF;
          cbx := xx * 168;
          FOR kr IN 1 .. nrun LOOP
            tx := g_tx(rv(kr) + v);
            IF tx >= 0 AND uq AND lbx >= 0 THEN
              cc := g_cmap(lbx + tx);
              FOR y IN ry0(kr) .. ry1(kr) LOOP
                IF q < zq(cbx + y) THEN zq(cbx + y) := q; fb(cbx + y) := cc; END IF;
              END LOOP;
            ELSIF tx >= 0 THEN
              IF lbx >= 0 THEN cc := g_cmap(lbx + tx); END IF;
              FOR y IN ry0(kr) .. ry1(kr) LOOP
                zc := zq(cbx + y);
                IF q < zc THEN
                  zq(cbx + y) := q; zo(cbx + y) := o;
                  IF lbx >= 0 THEN fb(cbx + y) := cc; ELSE fb(cbx + y) := g_cmap(shade_lp(o, xx, y)); END IF;
                ELSIF q = zc THEN
                  IF shade_lp(o, xx, y) < shade_lp(zo(cbx + y), xx, y) THEN
                    zo(cbx + y) := o; fb(cbx + y) := g_cmap(shade_lp(o, xx, y));
                  END IF;
                END IF;
              END LOOP;
            END IF;
          END LOOP;
        END LOOP;
        CONTINUE;
      END IF;
      FOR y IN y0 .. y1 LOOP
        vrow(y) := LEAST(sp_h(i) - 1, GREATEST(0d, FLOOR((g_yd(y) - sp_yt(i)) / sp_sc(i)))) * sp_w(i) + sp_base(i);
      END LOOP;
      FOR xx IN lo .. hi LOOP
        v := LEAST(sp_w(i) - 1, GREATEST(0d, FLOOR((g_yd(xx) - sp_xl(i)) / sp_sc(i))));
        IF sp_fl(i) = 1 THEN v := sp_w(i) - 1 - v; END IF;
        cbx := xx * 168;
        IF uq AND lbx >= 0 THEN
          FOR y IN y0 .. y1 LOOP
            tx := g_tx(vrow(y) + v);
            IF tx >= 0 THEN
              IF q < zq(cbx + y) THEN zq(cbx + y) := q; fb(cbx + y) := g_cmap(lbx + tx); END IF;
            END IF;
          END LOOP;
          CONTINUE;
        END IF;
        FOR y IN y0 .. y1 LOOP
          tx := g_tx(vrow(y) + v);
          IF tx >= 0 THEN
            zc := zq(cbx + y);
            IF q < zc THEN
              zq(cbx + y) := q; zo(cbx + y) := o;
              IF lbx >= 0 THEN fb(cbx + y) := g_cmap(lbx + tx); ELSE fb(cbx + y) := g_cmap(shade_lp(o, xx, y)); END IF;
            ELSIF q = zc THEN
              -- tie with another sprite's key (written by this pass): reference light/palette order
              IF shade_lp(o, xx, y) < shade_lp(zo(cbx + y), xx, y) THEN
                zo(cbx + y) := o; fb(cbx + y) := g_cmap(shade_lp(o, xx, y));
              END IF;
            END IF;
          END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    tmark('z_sprites');


    -- ------------------------------------------------------------ weapon psprite (layer 2 over layer 1)
    -- layers: weapon frame, then flash frame (rotation 0); origin as the reference psprite_patches
    nwl := 0;
    FOR li IN 1 .. 2 LOOP
      IF li = 1 THEN sfk := w_spr || w_frame || '0'; ELSE sfk := w_fspr || w_fframe || '0'; END IF;
      IF (li = 1 OR (w_fspr IS NOT NULL AND w_fframe IS NOT NULL)) AND sfk IS NOT NULL AND g_sf_idx.EXISTS(sfk) THEN
        sfi := g_sf_idx(sfk); nwl := nwl + 1;
        wl_lump(nwl) := g_sf_lump(sfi); wl_w(nwl) := g_sf_w(sfi); wl_h(nwl) := g_sf_h(sfi);
        wl_x(nwl) := FLOOR(w_sx - g_sf_left(sfi));
        wl_y(nwl) := FLOOR(w_sy - g_sf_top(sfi) + c_cy - 100d - 0.5d);
        wl_fb(nwl) := CASE WHEN li = 1 THEN w_fb ELSE w_ffb END;
      END IF;
    END LOOP;
    FOR li IN 1 .. nwl LOOP
      IF f_invuln = 1 THEN lt := 32;
      ELSIF wl_fb(li) = 1 THEN lt := 0;
      ELSIF ps_ok THEN lt := GREATEST(0, LEAST(31, (15 - LEAST(15, GREATEST(0, FLOOR(s_light(ps_id) / 16d) + f_extra))) * 4 - 23));
      ELSE CONTINUE;   -- reference: CROSS JOIN player_sector
      END IF;
      xl0 := wl_x(li); yt0 := wl_y(li); k := sprite_base(wl_lump(li));
      FOR y IN GREATEST(0, yt0) .. LEAST(167, yt0 + wl_h(li) - 1) LOOP
        FOR xx IN GREATEST(0, xl0) .. LEAST(319, xl0 + wl_w(li) - 1) LOOP
          tx := g_tx(k + (y - yt0) * wl_w(li) + (xx - xl0));
          IF tx >= 0 THEN fb(xx * 168 + y) := g_cmap(lt * 256 + tx); END IF;
        END LOOP;
      END LOOP;
    END LOOP;

    -- ------------------------------------------------------------ pickup message (top layer)
    IF has_ps = 1 AND u_msg IS NOT NULL AND u_mtics > 0 THEN
      pen := 0;
      FOR pos IN 1 .. LEAST(LENGTH(u_msg), 320) LOOP
        ch := SUBSTR(UPPER(u_msg), pos, 1);
        IF ch = ' ' THEN pen := pen + 4;
        ELSE
          pname := 'STCFN' || LPAD(TO_CHAR(ASCII(ch)), 3, '0');
          load_patch_pixels(pname);
          FOR m IN g_px_from(pname) .. g_px_from(pname) + g_px_cnt(pname) - 1 LOOP
            mx_ := pen + g_px_dx(m); my_ := 1 + g_px_dy(m);
            IF mx_ BETWEEN 0 AND 319 AND my_ BETWEEN 0 AND 167 THEN
              v := g_cmap(g_px_pi(m));
              p := mx_ * 168 + my_;
              IF NOT msgv.EXISTS(p) OR msgv(p) < v THEN msgv(p) := v; END IF;
            END IF;
          END LOOP;
          IF g_up_idx.EXISTS(pname) THEN pen := pen + g_up_w(g_up_idx(pname)); ELSE pen := pen + 4; END IF;
        END IF;
      END LOOP;
      p := msgv.FIRST;
      WHILE p IS NOT NULL LOOP fb(p) := msgv(p); p := msgv.NEXT(p); END LOOP;
    END IF;
    tmark('overlays');

    -- ------------------------------------------------------------ status bar
    hb := g_hudfb;      -- rows 168..199: static background, dynamic patches overlaid below
    IF has_ps = 1 THEN
      ui_value(u_health, 90, 172, 'STTNUM', 14);
      ui_value(u_armor, 221, 172, 'STTNUM', 14);
      IF u_ammo IS NOT NULL THEN
        ui_value(CASE u_ammo WHEN 'bullets' THEN u_bul WHEN 'shells' THEN u_she
                             WHEN 'rockets' THEN u_roc WHEN 'cells' THEN u_cel END, 44, 172, 'STTNUM', 14);
      END IF;
      ui_value(u_bul, 288, 173, 'STYSNUM', 4);
      ui_value(u_she, 288, 179, 'STYSNUM', 4);
      ui_value(u_roc, 288, 185, 'STYSNUM', 4);
      ui_value(u_cel, 288, 191, 'STYSNUM', 4);
      FOR ai IN 1 .. g_nam LOOP
        ui_value(CASE WHEN u_bp = 1 THEN g_am_bcap(ai) ELSE g_am_cap(ai) END, 314,
                 CASE g_am_type(ai) WHEN 'bullets' THEN 173 WHEN 'shells' THEN 179 WHEN 'rockets' THEN 185 ELSE 191 END,
                 'STYSNUM', 4);
      END LOOP;
      IF u_kb = 1 THEN ui_patch(1, 'STKEYS0', 239, 171); END IF;
      IF u_ky = 1 THEN ui_patch(1, 'STKEYS1', 239, 181); END IF;
      IF u_kr = 1 THEN ui_patch(1, 'STKEYS2', 239, 191); END IF;
      strv := TO_CHAR(LEAST(4, GREATEST(0, TRUNC((100 - GREATEST(0, LEAST(100, u_health))) / 20))));
      ui_patch(1, CASE WHEN u_alive = 0 THEN 'STFDEAD0'
                       WHEN u_pain > 0 THEN 'STFOUCH' || strv
                       ELSE 'STFST' || strv || '0' END, 143, 168);
    END IF;
    FOR sw IN 2 .. 7 LOOP
      ok := MOD(TRUNC(u_owned / POWER(2, sw)), 2) = 1;   -- st_player_weapon_owned bitmask
      ui_patch(2, CASE WHEN ok THEN 'STYSNUM' ELSE 'STGNUM' END || TO_CHAR(sw),
               111 + MOD(sw - 2, 3) * 12, 172 + TRUNC((sw - 2) / 3) * 10);
    END LOOP;
    p := uiv.FIRST;
    WHILE p IS NOT NULL LOOP
      hb(168 * 320 + p) := g_cmapk(uiv(p));   -- COLORMAP(0, key mod 256)
      p := uiv.NEXT(p);
    END LOOP;
    tmark('hud');
    IF g_debug = 1 THEN
      npc := 0; FOR xx IN 0 .. 319 LOOP npc := npc + pcn(xx); END LOOP;
      g_tm := g_tm || 'n_segs=' || nh || ' n_wallitems=' || nw || ' n_panels=' || npc || ' n_planespans=' || np
              || ' n_sprites=' || nsp || ' n_texels=' || g_txn || ' n_planeheights=' || nz || ' ';
    END IF;
  END;

  -- =========================================================================== entry point
  FUNCTION render_frame(p_tic NUMBER, p_map_id NUMBER, p_player_id NUMBER, p_skill NUMBER,
                        p_px NUMBER, p_py NUMBER, p_pz NUMBER, p_pangle NUMBER)
    RETURN doom_hex_tab PIPELINED IS
    pal NUMBER; line VARCHAR2(640); p PLS_INTEGER := 0;
  BEGIN
    build_frame(p_tic, p_map_id, p_player_id, p_skill, p_px, p_py, p_pz, p_pangle, pal);
    -- view rows (column-major buffer: pixel (x, y) at x*168 + y), 16 pixels per statement
    FOR y IN 0 .. 167 LOOP
      line := NULL; p := y;
      FOR c8 IN 0 .. 19 LOOP
        line := line || g_hex2(fb(p) * 256 + fb(p + 168)) || g_hex2(fb(p + 336) * 256 + fb(p + 504)) || g_hex2(fb(p + 672) * 256 + fb(p + 840)) || g_hex2(fb(p + 1008) * 256 + fb(p + 1176)) || g_hex2(fb(p + 1344) * 256 + fb(p + 1512)) || g_hex2(fb(p + 1680) * 256 + fb(p + 1848)) || g_hex2(fb(p + 2016) * 256 + fb(p + 2184)) || g_hex2(fb(p + 2352) * 256 + fb(p + 2520));
        p := p + 2688;
      END LOOP;
      PIPE ROW (doom_hex_row(y, pal, line));
    END LOOP;
    p := 168 * 320;
    FOR y IN 168 .. 199 LOOP
      line := NULL;
      FOR c8 IN 0 .. 19 LOOP
        line := line || g_hex2(hb(p) * 256 + hb(p + 1)) || g_hex2(hb(p + 2) * 256 + hb(p + 3)) || g_hex2(hb(p + 4) * 256 + hb(p + 5)) || g_hex2(hb(p + 6) * 256 + hb(p + 7)) || g_hex2(hb(p + 8) * 256 + hb(p + 9)) || g_hex2(hb(p + 10) * 256 + hb(p + 11)) || g_hex2(hb(p + 12) * 256 + hb(p + 13)) || g_hex2(hb(p + 14) * 256 + hb(p + 15));
        p := p + 16;
      END LOOP;
      PIPE ROW (doom_hex_row(y, pal, line));
    END LOOP;
    tmark('hex');
    RETURN;
  EXCEPTION
    -- inside a pipelined function NO_DATA_FOUND would silently end the row stream
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20001, 'doom_hybrid: NO_DATA_FOUND ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
  END;
END doom_hybrid;
/
