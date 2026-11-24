-- =============================================================================
-- 11_screens.sql -- the full-screen frames (package doom_screen, phase 4)
--
-- Ports of reference/sqldoom/sql/client/render_screen.sql (title, main/episode/skill
-- menus, load/save with their slot names, help pages, the intermission tally, the
-- finale's typed text over a tiled flat, its ending picture and the episode-3 bunny
-- scroll) and render_automap.sql (walls by AM_drawWalls' colour cascade, the player
-- arrow, IDDT things, the grid; Liang-Barsky clipped and stepped pixel by pixel).
--
-- Output: the renderer's row format (doom_hex_tab: y, pal = 0, 640 hex chars), the palette
-- index of each pixel AFTER COLORMAP level 0 (what colormap_rgb pal 0 / level 0 maps it to),
-- uncovered pixels 0 (black, PLAYPAL[0]). One statement per frame:
--   SELECT y, pal, hex FROM TABLE(doom_screen.render_screen(:tics))
--   SELECT y, pal, hex FROM TABLE(doom_screen.render_automap(:map, :player))
-- State is read from screen_state / g_* every call; only static WAD data (patches,
-- flats, COLORMAP, line geometry) is cached in package state. No frame is cached.
--
-- Exactness notes (CedarDB semantics reproduced):
--   * layers: ARG_MAX(palette_index, layer) -- the highest layer wins; patches of one layer
--     are painted in the reference CTE's UNION ALL order, the later one on top;
--   * the automap: ROUND(double) half away from zero, RADIANS(x) = x * (pi/180), the arrow
--     radius 8.0*16.0/7.0 is a numeric 18.285714 (scale-6 truncation); pixel priority
--     layer*256 + palette index; the live sector heights (g_sectors) and mapped lines.
-- =============================================================================
CREATE OR REPLACE PACKAGE doom_screen AUTHID DEFINER AS
  FUNCTION render_screen(p_tics NUMBER) RETURN doom_hex_tab PIPELINED;
  FUNCTION render_automap(p_map NUMBER, p_player NUMBER) RETURN doom_hex_tab PIPELINED;
  PROCEDURE reset_cache;
  -- debug: phase timings of the last frame (set_debug(1))
  PROCEDURE set_debug(p_on PLS_INTEGER);
  FUNCTION timings RETURN VARCHAR2;
END doom_screen;
/
CREATE OR REPLACE PACKAGE BODY doom_screen AS
  TYPE t_i  IS TABLE OF PLS_INTEGER   INDEX BY PLS_INTEGER;
  TYPE t_d  IS TABLE OF BINARY_DOUBLE INDEX BY PLS_INTEGER;
  TYPE t_ni IS TABLE OF PLS_INTEGER   INDEX BY VARCHAR2(16);
  TYPE t_h  IS TABLE OF VARCHAR2(2)   INDEX BY PLS_INTEGER;
  TYPE t_v  IS TABLE OF VARCHAR2(16)  INDEX BY PLS_INTEGER;

  c_rad CONSTANT BINARY_DOUBLE := 3.14159265358979323846d / 180d;

  g_init  BOOLEAN := FALSE;
  g_hex   t_h;
  g_hexv  t_ni;
  g_cm0   t_i;                 -- palette index -> COLORMAP level 0 (pal 0)
  -- ui patches: directory + lazily decoded pixels (row-major, -1 = transparent)
  g_up    t_ni;                -- name -> k
  g_w t_i; g_h t_i; g_l t_i; g_t t_i; g_base t_i;
  g_px    t_i; g_pxn PLS_INTEGER := 0;
  g_rb    t_i;                 -- patch k -> base of its per-row opaque ranges in g_ru0 / g_ru1
  g_ru0 t_i; g_ru1 t_i; g_nru PLS_INTEGER := 0;   -- first / last opaque column of a patch row (-1: none)
  g_fl    t_ni;                -- flat name -> base in g_px (4096 raw indices)
  -- automap static line data (per map)
  g_am_map PLS_INTEGER := -1;
  a_n PLS_INTEGER; a_id t_i; a_x1 t_d; a_y1 t_d; a_x2 t_d; a_y2 t_d; a_flags t_i; a_special t_i;
  a_rsec t_i; a_lsec t_i;      -- -1 when the side (sidedef) is missing
  -- framebuffer: written pixels carry the frame's stamp (no per-frame reset of 64,000 entries);
  -- a row nobody wrote is emitted as its background row (a cached hex string of static WAD data:
  -- an opaque full-screen patch or a tiled flat, after COLORMAP), else per pixel over it
  g_stamp PLS_INTEGER := 0;
  fbs t_i;                     -- stamp of the pixel's writer
  fb t_i;                      -- palette index before COLORMAP
  fl t_i;                      -- layer of the pixel's current writer
  rd t_i; rx0 t_i; rx1 t_i;    -- per row: stamp when dirty, written x range
  TYPE t_rows IS TABLE OF VARCHAR2(640) INDEX BY PLS_INTEGER;
  TYPE t_bg IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(16);
  g_bgk t_bg;                  -- background key -> slot in g_bgr (slot*200 + y)
  g_bgr t_rows; g_nbg PLS_INTEGER := 0;
  g_black VARCHAR2(640);
  bgslot PLS_INTEGER;          -- this frame's background rows (-1: black)
  -- layer items of one frame
  it_n PLS_INTEGER; it_l t_i; it_p t_v; it_x t_i; it_y t_i;

  g_debug PLS_INTEGER := 0; g_tm VARCHAR2(4000); g_tl TIMESTAMP(6);
  PROCEDURE set_debug(p_on PLS_INTEGER) IS BEGIN g_debug := p_on; END;
  FUNCTION timings RETURN VARCHAR2 IS BEGIN RETURN g_tm; END;
  PROCEDURE tmark(p_name VARCHAR2) IS
    t TIMESTAMP(6);
  BEGIN
    IF g_debug = 1 THEN
      t := SYSTIMESTAMP;
      IF p_name IS NULL THEN g_tm := NULL;
      ELSE g_tm := g_tm || p_name || '=' || TO_CHAR(EXTRACT(SECOND FROM (t - g_tl)) * 1000, 'FM9990.00') || ' '; END IF;
      g_tl := t;
    END IF;
  END;

  PROCEDURE init IS
  BEGIN
    IF g_init THEN RETURN; END IF;
    FOR i IN 0 .. 255 LOOP g_hex(i) := TO_CHAR(i, 'FM0X'); g_hexv(g_hex(i)) := i; g_cm0(i) := i; END LOOP;
    g_black := RPAD('0', 640, '0');
    FOR p IN 0 .. 63999 LOOP fbs(p) := 0; END LOOP;
    FOR y IN 0 .. 199 LOOP rd(y) := 0; END LOOP;
    FOR r IN (SELECT palette_index, mapped_index FROM colormap_rgb WHERE pal = 0 AND light_level = 0) LOOP
      g_cm0(r.palette_index) := r.mapped_index;
    END LOOP;
    FOR r IN (SELECT name, width, height, left_offset, top_offset FROM ui_patches) LOOP
      g_up(r.name) := g_up.COUNT + 1;
      g_w(g_up(r.name)) := r.width; g_h(g_up(r.name)) := r.height;
      g_l(g_up(r.name)) := r.left_offset; g_t(g_up(r.name)) := r.top_offset; g_base(g_up(r.name)) := -1;
    END LOOP;
    g_init := TRUE;
  END;

  PROCEDURE reset_cache IS
  BEGIN
    g_init := FALSE; g_up.DELETE; g_px.DELETE; g_pxn := 0; g_fl.DELETE; g_am_map := -1;
    g_rb.DELETE; g_ru0.DELETE; g_ru1.DELETE; g_nru := 0;
    g_bgk.DELETE; g_bgr.DELETE; g_nbg := 0;
  END;

  -- BLOB bytes -> g_px at base (mask: 0 -> -1)
  PROCEDURE load_bytes(b BLOB, m BLOB, base PLS_INTEGER) IS
    len PLS_INTEGER := DBMS_LOB.GETLENGTH(b); off PLS_INTEGER := 0; n PLS_INTEGER;
    hx VARCHAR2(4000); mx VARCHAR2(4000);
  BEGIN
    WHILE off < len LOOP
      n := LEAST(2000, len - off);
      hx := RAWTOHEX(DBMS_LOB.SUBSTR(b, n, off + 1));
      IF m IS NOT NULL THEN mx := RAWTOHEX(DBMS_LOB.SUBSTR(m, n, off + 1)); END IF;
      FOR k IN 0 .. n - 1 LOOP
        IF m IS NOT NULL AND SUBSTR(mx, 2 * k + 1, 2) = '00' THEN g_px(base + off + k) := -1;
        ELSE g_px(base + off + k) := g_hexv(SUBSTR(hx, 2 * k + 1, 2)); END IF;
      END LOOP;
      off := off + n;
    END LOOP;
  END;

  FUNCTION patch_base(k PLS_INTEGER) RETURN PLS_INTEGER IS
    b BLOB; m BLOB; nm VARCHAR2(16);
  BEGIN
    IF g_base(k) < 0 THEN
      nm := g_up.FIRST;
      WHILE nm IS NOT NULL AND g_up(nm) <> k LOOP nm := g_up.NEXT(nm); END LOOP;
      SELECT pixels, mask INTO b, m FROM ui_patches WHERE name = nm;
      g_base(k) := g_pxn;
      load_bytes(b, m, g_pxn);
      g_rb(k) := g_nru;
      FOR v IN 0 .. g_h(k) - 1 LOOP
        g_ru0(g_nru + v) := -1; g_ru1(g_nru + v) := -1;
        FOR u IN 0 .. g_w(k) - 1 LOOP
          IF g_px(g_pxn + v * g_w(k) + u) >= 0 THEN
            IF g_ru0(g_nru + v) < 0 THEN g_ru0(g_nru + v) := u; END IF;
            g_ru1(g_nru + v) := u;
          END IF;
        END LOOP;
      END LOOP;
      g_nru := g_nru + g_h(k);
      g_pxn := g_pxn + g_w(k) * g_h(k);
    END IF;
    RETURN g_base(k);
  END;

  FUNCTION flat_base(p_name VARCHAR2) RETURN PLS_INTEGER IS
    b BLOB;
  BEGIN
    IF NOT g_fl.EXISTS(p_name) THEN
      SELECT palette_indices INTO b FROM flat_textures WHERE name = p_name;
      g_fl(p_name) := g_pxn;
      load_bytes(b, NULL, g_pxn);
      g_pxn := g_pxn + 4096;
    END IF;
    RETURN g_fl(p_name);
  END;

  FUNCTION pwidth(p_name VARCHAR2) RETURN PLS_INTEGER IS   -- NULL when the patch is not loaded
  BEGIN
    IF p_name IS NOT NULL AND g_up.EXISTS(p_name) THEN RETURN g_w(g_up(p_name)); END IF;
    RETURN NULL;
  END;

  PROCEDURE add(p_layer PLS_INTEGER, p_patch VARCHAR2, p_x PLS_INTEGER, p_y PLS_INTEGER) IS
  BEGIN
    it_n := it_n + 1; it_l(it_n) := p_layer; it_p(it_n) := p_patch; it_x(it_n) := p_x; it_y(it_n) := p_y;
  END;

  PROCEDURE paint(p_layer PLS_INTEGER, p_patch VARCHAR2, p_x PLS_INTEGER, p_y PLS_INTEGER) IS
    k PLS_INTEGER; base PLS_INTEGER; w PLS_INTEGER; h PLS_INTEGER; dx0 PLS_INTEGER; dy0 PLS_INTEGER;
    v PLS_INTEGER; xx PLS_INTEGER; yy PLS_INTEGER; q PLS_INTEGER; pp PLS_INTEGER; u0 PLS_INTEGER; u1 PLS_INTEGER;
    q0 PLS_INTEGER;
  BEGIN
    IF p_patch IS NULL OR NOT g_up.EXISTS(p_patch) THEN RETURN; END IF;   -- JOIN ui_patches
    k := g_up(p_patch); base := patch_base(k); w := g_w(k); h := g_h(k);
    dx0 := p_x - g_l(k); dy0 := p_y - g_t(k);
    FOR v IN 0 .. h - 1 LOOP
      yy := dy0 + v;
      u0 := g_ru0(g_rb(k) + v);
      IF yy BETWEEN 0 AND 199 AND u0 >= 0 THEN
        u1 := g_ru1(g_rb(k) + v);
        IF dx0 + u0 < 0 THEN u0 := -dx0; END IF;
        IF dx0 + u1 > 319 THEN u1 := 319 - dx0; END IF;
        IF u0 <= u1 THEN
          -- the row's dirty range: the patch row's opaque span (a superset of what is written)
          IF rd(yy) <> g_stamp THEN rd(yy) := g_stamp; rx0(yy) := dx0 + u0; rx1(yy) := dx0 + u1;
          ELSE
            IF dx0 + u0 < rx0(yy) THEN rx0(yy) := dx0 + u0; END IF;
            IF dx0 + u1 > rx1(yy) THEN rx1(yy) := dx0 + u1; END IF;
          END IF;
          pp := yy * 320 + dx0; q0 := base + v * w;
          FOR u IN u0 .. u1 LOOP
            q := g_px(q0 + u);
            IF q >= 0 THEN
              IF fbs(pp + u) <> g_stamp OR fl(pp + u) <= p_layer THEN
                fbs(pp + u) := g_stamp; fb(pp + u) := q; fl(pp + u) := p_layer;
              END IF;
            END IF;
          END LOOP;
        END IF;
      END IF;
    END LOOP;
  END;

  PROCEDURE emit_init IS
  BEGIN
    g_stamp := g_stamp + 1; bgslot := -1;
  END;

  -- background rows of a full-screen (320x200, offsets 0) patch at (0, 0), the only layer-0 item:
  -- its pixels over black (render_screen.sql fills uncovered pixels black), cached; NULL if the
  -- patch is not full-screen
  FUNCTION bg_patch(p_name VARCHAR2) RETURN PLS_INTEGER IS
    k PLS_INTEGER; base PLS_INTEGER; line VARCHAR2(640); q PLS_INTEGER;
  BEGIN
    IF p_name IS NULL THEN RETURN NULL; END IF;
    IF g_bgk.EXISTS('P' || p_name) THEN RETURN g_bgk('P' || p_name); END IF;
    IF NOT g_up.EXISTS(p_name) THEN RETURN NULL; END IF;
    k := g_up(p_name);
    IF g_w(k) <> 320 OR g_h(k) <> 200 OR g_l(k) <> 0 OR g_t(k) <> 0 THEN RETURN NULL; END IF;
    base := patch_base(k);
    FOR y IN 0 .. 199 LOOP
      line := NULL;
      FOR x IN 0 .. 319 LOOP
        q := g_px(base + y * 320 + x);
        line := line || CASE WHEN q < 0 THEN '00' ELSE g_hex(g_cm0(q)) END;
      END LOOP;
      g_bgr(g_nbg * 200 + y) := line;
    END LOOP;
    g_bgk('P' || p_name) := g_nbg; g_nbg := g_nbg + 1;
    RETURN g_bgk('P' || p_name);
  END;

  -- background rows of a 64x64 flat tiled over the screen (F_TextWrite), cached
  FUNCTION bg_flat(p_name VARCHAR2) RETURN PLS_INTEGER IS
    base PLS_INTEGER; line VARCHAR2(640);
  BEGIN
    IF g_bgk.EXISTS('F' || p_name) THEN RETURN g_bgk('F' || p_name); END IF;
    base := flat_base(p_name);
    FOR y IN 0 .. 199 LOOP
      line := NULL;
      FOR x IN 0 .. 319 LOOP line := line || g_hex(g_cm0(g_px(base + MOD(y, 64) * 64 + MOD(x, 64)))); END LOOP;
      g_bgr(g_nbg * 200 + y) := line;
    END LOOP;
    g_bgk('F' || p_name) := g_nbg; g_nbg := g_nbg + 1;
    RETURN g_bgk('F' || p_name);
  END;

  -- row y of the frame: its background row, the written pixels over it
  FUNCTION out_row(y PLS_INTEGER) RETURN VARCHAR2 IS
    base VARCHAR2(640); line VARCHAR2(640); p PLS_INTEGER; a PLS_INTEGER; b PLS_INTEGER;
    x PLS_INTEGER; x2 PLS_INTEGER;
  BEGIN
    base := CASE WHEN bgslot >= 0 THEN g_bgr(bgslot * 200 + y) ELSE g_black END;
    IF rd(y) <> g_stamp THEN RETURN base; END IF;
    a := rx0(y); b := rx1(y);
    line := SUBSTR(base, 1, 2 * a);
    p := y * 320;
    x := a;
    WHILE x <= b LOOP
      IF fbs(p + x) = g_stamp THEN
        line := line || g_hex(g_cm0(fb(p + x))); x := x + 1;
      ELSE                               -- a run of background pixels: one SUBSTR
        x2 := x + 1;
        WHILE x2 <= b AND fbs(p + x2) <> g_stamp LOOP x2 := x2 + 1; END LOOP;
        line := line || SUBSTR(base, 2 * x + 1, 2 * (x2 - x)); x := x2;
      END IF;
    END LOOP;
    RETURN line || SUBSTR(base, 2 * b + 3);
  END;

  -- =====================================================================
  -- render_screen.sql
  -- =====================================================================
  FUNCTION render_screen(p_tics NUMBER) RETURN doom_hex_tab PIPELINED IS
    s screen_state%ROWTYPE;
    v_bg VARCHAR2(16); v_found BOOLEAN := FALSE;
    line VARCHAR2(640); p PLS_INTEGER; v PLS_INTEGER;
    -- finale
    f_flat VARCHAR2(8); f_patch VARCHAR2(8); f_text VARCHAR2(4000); fbase PLS_INTEGER;
    ch VARCHAR2(4); w PLS_INTEGER; line_no PLS_INTEGER; pen PLS_INTEGER; nm VARCHAR2(16); vis PLS_INTEGER;
    c PLS_INTEGER; sc PLS_INTEGER;
    -- intermission
    num_h PLS_INTEGER; lvname VARCHAR2(16); txt VARCHAR2(64); rx PLS_INTEGER; ry PLS_INTEGER;
    TYPE t_run IS RECORD (txt VARCHAR2(64), rx PLS_INTEGER, y PLS_INTEGER);
    TYPE t_runs IS TABLE OF t_run INDEX BY PLS_INTEGER;
    runs t_runs; nr PLS_INTEGER; first BOOLEAN;
  BEGIN
    init;
    FOR r IN (SELECT * FROM screen_state WHERE id = 0) LOOP s := r; v_found := TRUE; END LOOP;
    tmark(NULL); emit_init;
    it_n := 0;
    IF v_found THEN
      -- layer 0: the background (not under the finale's text page nor the bunny scroll)
      IF (s.screen <> 'finale' OR s.finale_stage <> 0) AND NOT (s.screen = 'finale' AND NVL(s.finale_episode, -1) = 3) THEN
        v_bg := CASE s.screen WHEN 'title' THEN 'TITLEPIC' WHEN 'help1' THEN 'HELP1' WHEN 'help2' THEN 'CREDIT'
                  WHEN 'intermission' THEN CASE s.inter_episode WHEN 1 THEN 'WIMAP0' WHEN 2 THEN 'WIMAP1'
                                                                 WHEN 3 THEN 'WIMAP2' ELSE 'INTERPIC' END
                  WHEN 'finale' THEN NULL ELSE 'TITLEPIC' END;
        IF s.screen = 'finale' THEN
          FOR r IN (SELECT patch FROM finale_defs WHERE episode = s.finale_episode) LOOP v_bg := r.patch; END LOOP;
        END IF;
        bgslot := NVL(bg_patch(v_bg), -1);
        IF bgslot < 0 THEN add(0, v_bg, 0, 0); END IF;   -- not opaque full-screen: painted
      END IF;
      -- decor and items (layer 1), cursor (layer 2)
      FOR r IN (SELECT patch, x, y FROM menu_decor WHERE screen = s.screen ORDER BY seq) LOOP add(1, r.patch, r.x, r.y); END LOOP;
      FOR r IN (SELECT patch, x, y FROM menu_items WHERE screen = s.screen AND patch IS NOT NULL ORDER BY idx) LOOP
        add(1, r.patch, r.x, r.y);
      END LOOP;
      FOR r IN (SELECT x, y FROM menu_items WHERE screen = s.screen AND idx = s.cursor_index) LOOP
        add(2, CASE WHEN MOD(TRUNC(p_tics / 8), 2) = 0 THEN 'M_SKULL1' ELSE 'M_SKULL2' END, r.x - 32, r.y - 5);
      END LOOP;
      -- intermission (wi_stuff.c, single player)
      IF s.screen = 'intermission' THEN
        num_h := CASE WHEN g_up.EXISTS('WINUM0') THEN g_h(g_up('WINUM0')) END;
        lvname := 'WILV' || TO_CHAR(s.inter_episode - 1) || TO_CHAR(s.inter_level - 1);
        IF g_up.EXISTS(lvname) THEN
          add(1, lvname, TRUNC((320 - g_w(g_up(lvname))) / 2), 2);
          IF g_up.EXISTS('WIF') THEN
            add(1, 'WIF', TRUNC((320 - g_w(g_up('WIF'))) / 2), 2 + TRUNC((5 * g_h(g_up(lvname))) / 4));
          END IF;
        END IF;
        add(1, 'WIOSTK', 50, 50);
        IF num_h IS NOT NULL THEN
          add(1, 'WIOSTI', 50, 50 + TRUNC((3 * num_h) / 2));
          add(1, 'WISCRT2', 50, 50 + 2 * TRUNC((3 * num_h) / 2));
        END IF;
        add(1, 'WITIME', 16, 168);
        add(1, 'WIPAR', 176, 168);
        add(1, 'WIPCNT', 270, 50);
        IF num_h IS NOT NULL THEN
          add(1, 'WIPCNT', 270, 50 + TRUNC((3 * num_h) / 2));
          add(1, 'WIPCNT', 270, 50 + 2 * TRUNC((3 * num_h) / 2));
        END IF;
        nr := 0;
        nr := nr + 1; runs(nr).txt := TO_CHAR(NVL(s.kills_pct, 0)); runs(nr).rx := 270; runs(nr).y := 50;
        IF num_h IS NOT NULL THEN
          nr := nr + 1; runs(nr).txt := TO_CHAR(NVL(s.items_pct, 0)); runs(nr).rx := 270; runs(nr).y := 50 + TRUNC((3 * num_h) / 2);
          nr := nr + 1; runs(nr).txt := TO_CHAR(NVL(s.secrets_pct, 0)); runs(nr).rx := 270; runs(nr).y := 50 + 2 * TRUNC((3 * num_h) / 2);
        END IF;
        nr := nr + 1; runs(nr).txt := TO_CHAR(TRUNC(NVL(s.time_secs, 0) / 60)) || ':' || LPAD(TO_CHAR(MOD(NVL(s.time_secs, 0), 60)), 2, '0');
        runs(nr).rx := 144; runs(nr).y := 168;
        nr := nr + 1; runs(nr).txt := TO_CHAR(TRUNC(NVL(s.par_secs, 0) / 60)) || ':' || LPAD(TO_CHAR(MOD(NVL(s.par_secs, 0), 60)), 2, '0');
        runs(nr).rx := 304; runs(nr).y := 168;
        FOR j IN 1 .. nr LOOP
          pen := runs(j).rx;
          FOR i IN REVERSE 1 .. LENGTH(runs(j).txt) LOOP
            ch := SUBSTR(runs(j).txt, i, 1);
            nm := CASE ch WHEN ':' THEN 'WICOLON' WHEN '-' THEN 'WIMINUS' ELSE 'WINUM' || ch END;
            w := pwidth(nm);
            IF w IS NOT NULL THEN pen := pen - w; add(1, nm, pen, runs(j).y); END IF;
          END LOOP;
        END LOOP;
      END IF;
      -- load / save: M_DrawSaveLoadBorder, then the slot names in the HU font (layer 2)
      IF s.screen IN ('load', 'save') THEN
        FOR r IN (SELECT idx, x, y FROM menu_items WHERE screen = s.screen ORDER BY idx) LOOP
          add(1, 'M_LSLEFT', r.x - 8, r.y + 7);
          FOR n IN 0 .. 23 LOOP add(1, 'M_LSCNTR', r.x + 8 * n, r.y + 7); END LOOP;
          add(1, 'M_LSRGHT', r.x + 8 * 24, r.y + 7);
        END LOOP;
        FOR r IN (SELECT m.x, m.y, UPPER(ss.name) AS txt FROM menu_items m LEFT JOIN save_slots ss ON ss.slot = m.idx
                   WHERE m.screen = s.screen ORDER BY m.idx) LOOP
          pen := r.x;
          FOR i IN 1 .. NVL(LENGTH(r.txt), 0) LOOP
            ch := SUBSTR(r.txt, i, 1);
            IF ch = ' ' THEN pen := pen + 4;
            ELSE
              nm := 'STCFN' || LPAD(TO_CHAR(ASCII(ch)), 3, '0');
              add(2, nm, pen, r.y);
              pen := pen + NVL(pwidth(nm), 4);
            END IF;
          END LOOP;
        END LOOP;
      END IF;
      -- finale text page: F_TextWrite over the tiled flat
      IF s.screen = 'finale' AND s.finale_stage = 0 THEN
        FOR r IN (SELECT flat, story_text FROM finale_defs WHERE episode = s.finale_episode) LOOP
          f_flat := r.flat; f_text := r.story_text;
        END LOOP;
        IF f_flat IS NOT NULL THEN
          bgslot := bg_flat(f_flat);         -- layer 0: the tiled flat
          vis := GREATEST(0, TRUNC((s.finale_count - 10) / 3));
          line_no := 0; pen := 10;
          FOR i IN 1 .. NVL(LENGTH(f_text), 0) LOOP
            ch := SUBSTR(f_text, i, 1);
            IF ch = CHR(10) THEN w := 0;
            ELSIF ch = ' ' THEN w := 4;
            ELSE nm := 'STCFN' || LPAD(TO_CHAR(ASCII(UPPER(ch))), 3, '0'); w := NVL(pwidth(nm), 4); END IF;
            IF i <= vis AND ch <> CHR(10) AND ch <> ' ' AND pen + w <= 320 THEN
              add(1, nm, pen, 10 + 11 * line_no);
            END IF;
            IF ch = CHR(10) THEN line_no := line_no + 1; pen := 10; ELSE pen := pen + w; END IF;
          END LOOP;
        END IF;
      END IF;
      -- F_BunnyScroll (episode 3's ending)
      IF s.screen = 'finale' AND s.finale_stage <> 0 AND s.finale_episode = 3 THEN
        c := s.finale_count;
        sc := LEAST(320, GREATEST(0, 320 - TRUNC((c - 230) / 2)));
        IF sc < 320 THEN add(0, 'PFUB1', -sc, 0); END IF;
        IF sc > 0 THEN add(0, 'PFUB2', 320 - sc, 0); END IF;
        IF c >= 1130 THEN add(1, 'END' || TO_CHAR(LEAST(6, GREATEST(0, TRUNC((c - 1180) / 5)))), 108, 68); END IF;
      END IF;
      -- paint: by layer, each layer in the order its rows were produced
      tmark('items'); FOR lyr IN 0 .. 2 LOOP
        first := TRUE;
        FOR i IN 1 .. it_n LOOP
          IF it_l(i) = lyr THEN
            -- the title's decor is TITLEPIC again over the TITLEPIC background: identical opaque
            -- pixels under every later item, so when it is the layer's first item it changes nothing
            IF NOT (first AND lyr = 1 AND bgslot >= 0 AND it_p(i) = v_bg AND it_x(i) = 0 AND it_y(i) = 0) THEN
              paint(lyr, it_p(i), it_x(i), it_y(i));
            END IF;
            first := FALSE;
          END IF;
        END LOOP;
      END LOOP;
    END IF;
    tmark('paint'); FOR y IN 0 .. 199 LOOP PIPE ROW (doom_hex_row(y, 0, out_row(y))); END LOOP; tmark('out');
    RETURN;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20001, 'doom_screen: NO_DATA_FOUND ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
  END;

  -- =====================================================================
  -- render_automap.sql
  -- =====================================================================
  PROCEDURE load_lines(p_map PLS_INTEGER) IS
    TYPE t_n IS TABLE OF NUMBER;
    a t_n; b t_n; c t_n; d t_n; e t_n; f t_n; g t_n; h t_n; k t_n;
  BEGIN
    IF g_am_map = p_map THEN RETURN; END IF;
    SELECT ld.id, v1.x, v1.y, v2.x, v2.y, ld.flags, ld.special, NVL(rs.sector_id, -1), NVL(ls.sector_id, -1)
      BULK COLLECT INTO a, b, c, d, e, f, g, h, k
      FROM linedefs ld
      JOIN vertexes v1 ON v1.map_id = ld.map_id AND v1.id = ld.v1_id
      JOIN vertexes v2 ON v2.map_id = ld.map_id AND v2.id = ld.v2_id
      LEFT JOIN sidedefs rs ON rs.map_id = ld.map_id AND rs.id = ld.right_sd_id
      LEFT JOIN sidedefs ls ON ls.map_id = ld.map_id AND ls.id = ld.left_sd_id
     WHERE ld.map_id = p_map;
    a_n := a.COUNT;
    a_id.DELETE; a_x1.DELETE; a_y1.DELETE; a_x2.DELETE; a_y2.DELETE; a_flags.DELETE; a_special.DELETE;
    a_rsec.DELETE; a_lsec.DELETE;
    FOR i IN 1 .. a_n LOOP
      a_id(i) := a(i); a_x1(i) := b(i); a_y1(i) := c(i); a_x2(i) := d(i); a_y2(i) := e(i);
      a_flags(i) := f(i); a_special(i) := g(i); a_rsec(i) := h(i); a_lsec(i) := k(i);
    END LOOP;
    g_am_map := p_map;
  END;

  FUNCTION rnd(x BINARY_DOUBLE) RETURN PLS_INTEGER IS   -- CedarDB ROUND(double): half away from zero
    a BINARY_DOUBLE := ABS(x); f BINARY_DOUBLE := FLOOR(a);
  BEGIN
    IF a - f >= 0.5d THEN f := f + 1d; END IF;
    RETURN CASE WHEN x < 0 THEN -f ELSE f END;
  END;

  FUNCTION render_automap(p_map NUMBER, p_player NUMBER) RETURN doom_hex_tab PIPELINED IS
    cx BINARY_DOUBLE; cy BINARY_DOUBLE; scale BINARY_DOUBLE; reveal BOOLEAN; cheat BOOLEAN; things BOOLEAN;
    grid BOOLEAN; found BOOLEAN := FALSE;
    fol BOOLEAN; zm BINARY_FLOAT; cht PLS_INTEGER; grd BOOLEAN;
    px_ BINARY_FLOAT; py_ BINARY_FLOAT; pm BOOLEAN;
    TYPE t_b IS TABLE OF BOOLEAN INDEX BY PLS_INTEGER;
    seen t_b; flo t_i; cei t_i;
    pi_ PLS_INTEGER; key t_i;
    -- segments
    sn PLS_INTEGER := 0; s_pi t_i; s_ax t_d; s_ay t_d; s_bx t_d; s_by t_d;
    tx BINARY_DOUBLE; ty BINARY_DOUBLE; ang BINARY_DOUBLE; rr BINARY_DOUBLE; ca BINARY_DOUBLE; sa BINARY_DOUBLE;
    ax BINARY_DOUBLE; ay BINARY_DOUBLE; dx BINARY_DOUBLE; dy BINARY_DOUBLE; t0 BINARY_DOUBLE; t1 BINARY_DOUBLE;
    u BINARY_DOUBLE; vv BINARY_DOUBLE; tlo BINARY_DOUBLE; thi BINARY_DOUBLE; steps BINARY_DOUBLE; ns PLS_INTEGER;
    x0 BINARY_DOUBLE; x1 BINARY_DOUBLE; y0 BINARY_DOUBLE; y1 BINARY_DOUBLE;
    xi PLS_INTEGER; yi PLS_INTEGER; lyr PLS_INTEGER; kk PLS_INTEGER;
    line VARCHAR2(640); p PLS_INTEGER; v PLS_INTEGER;
    TYPE t_sh IS TABLE OF BINARY_DOUBLE INDEX BY PLS_INTEGER;
    ar_x1 t_sh; ar_y1 t_sh; ar_x2 t_sh; ar_y2 t_sh; th_x1 t_sh; th_y1 t_sh; th_x2 t_sh; th_y2 t_sh;

    PROCEDURE seg(p_pi PLS_INTEGER, a1 BINARY_DOUBLE, a2 BINARY_DOUBLE, b1 BINARY_DOUBLE, b2 BINARY_DOUBLE) IS
    BEGIN
      sn := sn + 1; s_pi(sn) := p_pi; s_ax(sn) := a1; s_ay(sn) := a2; s_bx(sn) := b1; s_by(sn) := b2;
    END;
  BEGIN
    init;
    load_lines(p_map);
    FOR r IN (SELECT ps.position_x, ps.position_y, ps.power_map, av.follow, av.center_x, av.center_y, av.zoom,
                     av.cheat, av.grid
                FROM g_player_state ps
                LEFT JOIN g_automap_view av ON av.map_id = ps.map_id AND av.player_thing_id = ps.player_thing_id
               WHERE ps.map_id = p_map AND ps.player_thing_id = p_player) LOOP
      found := TRUE;
      fol := NVL(r.follow, TRUE);
      cx := TO_BINARY_DOUBLE(CASE WHEN fol THEN r.position_x ELSE r.center_x END);
      cy := TO_BINARY_DOUBLE(CASE WHEN fol THEN r.position_y ELSE r.center_y END);
      zm := NVL(r.zoom, 1f);
      cht := NVL(r.cheat, 0); grd := NVL(r.grid, FALSE); pm := r.power_map;
    END LOOP;
    tmark(NULL); emit_init;
    IF found THEN
      FOR r IN (SELECT 200d / value AS s FROM doom_constants WHERE name = 'AUTOMAP_WORLD_HEIGHT') LOOP
        scale := r.s * TO_BINARY_DOUBLE(zm);
      END LOOP;
      reveal := pm; cheat := cht > 0; things := cht = 2; grid := grd;
      -- walls: AM_drawWalls' cascade over the live sector heights
      FOR r IN (SELECT line_id FROM g_mapped_lines WHERE map_id = p_map) LOOP seen(r.line_id) := TRUE; END LOOP;
      FOR r IN (SELECT id, floor_height, ceil_height FROM g_sectors WHERE map_id = p_map) LOOP
        flo(r.id) := r.floor_height; cei(r.id) := r.ceil_height;
      END LOOP;
      FOR i IN 1 .. a_n LOOP
        IF (cheat OR BITAND(a_flags(i), 128) = 0) AND (seen.EXISTS(a_id(i)) OR reveal OR cheat) THEN
          pi_ := CASE WHEN NOT seen.EXISTS(a_id(i)) AND NOT cheat THEN 99
                      WHEN a_lsec(i) < 0 OR a_rsec(i) < 0 THEN 176
                      WHEN a_special(i) = 39 THEN 184
                      WHEN BITAND(a_flags(i), 32) <> 0 THEN 176
                      WHEN flo(a_rsec(i)) <> flo(a_lsec(i)) THEN 64
                      WHEN cei(a_rsec(i)) <> cei(a_lsec(i)) THEN 231
                      WHEN cheat THEN 96 END;
          IF pi_ IS NOT NULL THEN
            seg(pi_, 160d + (a_x1(i) - cx) * scale, 100d - (a_y1(i) - cy) * scale,
                     160d + (a_x2(i) - cx) * scale, 100d - (a_y2(i) - cy) * scale);
          END IF;
        END IF;
      END LOOP;
      -- the player arrow (player_arrow[], R = 8*PLAYERRADIUS/7 = numeric 18.285714)
      ar_x1(1) := -0.875d; ar_y1(1) := 0d; ar_x2(1) := 1d; ar_y2(1) := 0d;
      ar_x1(2) := 1d; ar_y1(2) := 0d; ar_x2(2) := 0.5d; ar_y2(2) := 0.25d;
      ar_x1(3) := 1d; ar_y1(3) := 0d; ar_x2(3) := 0.5d; ar_y2(3) := -0.25d;
      ar_x1(4) := -0.875d; ar_y1(4) := 0d; ar_x2(4) := -1.125d; ar_y2(4) := 0.25d;
      ar_x1(5) := -0.875d; ar_y1(5) := 0d; ar_x2(5) := -1.125d; ar_y2(5) := -0.25d;
      ar_x1(6) := -0.625d; ar_y1(6) := 0d; ar_x2(6) := -0.875d; ar_y2(6) := 0.25d;
      ar_x1(7) := -0.625d; ar_y1(7) := 0d; ar_x2(7) := -0.875d; ar_y2(7) := -0.25d;
      th_x1(1) := -0.5d; th_y1(1) := -0.7d; th_x2(1) := 1d; th_y2(1) := 0d;
      th_x1(2) := 1d; th_y1(2) := 0d; th_x2(2) := -0.5d; th_y2(2) := 0.7d;
      th_x1(3) := -0.5d; th_y1(3) := 0.7d; th_x2(3) := -0.5d; th_y2(3) := -0.7d;
      FOR r IN (SELECT x, y, angle FROM g_things WHERE map_id = p_map AND id = p_player) LOOP
        tx := TO_BINARY_DOUBLE(r.x); ty := TO_BINARY_DOUBLE(r.y);
        ang := TO_BINARY_DOUBLE(r.angle) * c_rad; rr := 18285714d / 1000000d;
        ca := COS(ang); sa := SIN(ang);
        FOR j IN 1 .. 7 LOOP
          seg(209, 160d + ((tx + rr * (ar_x1(j) * ca - ar_y1(j) * sa)) - cx) * scale,
                   100d - ((ty + rr * (ar_x1(j) * sa + ar_y1(j) * ca)) - cy) * scale,
                   160d + ((tx + rr * (ar_x2(j) * ca - ar_y2(j) * sa)) - cx) * scale,
                   100d - ((ty + rr * (ar_x2(j) * sa + ar_y2(j) * ca)) - cy) * scale);
        END LOOP;
      END LOOP;
      -- IDDT 2: every mobj (render_things that still exist) plus the player, as a 16-unit triangle
      IF things THEN
        FOR r IN (SELECT t.x, t.y, t.angle
                    FROM g_render_things rt
                    JOIN g_things t ON t.map_id = rt.map_id AND t.id = rt.thing_id
                    LEFT JOIN g_game_tic_commands gc ON gc.map_id = p_map AND gc.player_thing_id = p_player
                    LEFT JOIN g_picked_up_items pu ON pu.map_id = rt.map_id AND pu.thing_id = rt.thing_id
                    LEFT JOIN g_monster_ai ai ON ai.map_id = rt.map_id AND ai.thing_id = rt.thing_id
                   WHERE rt.map_id = p_map
                     AND BITAND(t.flags, NVL(gc.skill_bit, 2)) <> 0 AND BITAND(t.flags, 16) = 0
                     AND pu.thing_id IS NULL
                     AND NOT (EXISTS (SELECT 1 FROM thing_combat_defs cd WHERE cd.thing_type = t.type AND cd.explodes)
                              AND ai.state = 'dead')
                  UNION ALL
                  SELECT t.x, t.y, t.angle FROM g_things t WHERE t.map_id = p_map AND t.id = p_player) LOOP
          tx := TO_BINARY_DOUBLE(r.x); ty := TO_BINARY_DOUBLE(r.y);
          ang := TO_BINARY_DOUBLE(r.angle) * c_rad; rr := 16d;
          ca := COS(ang); sa := SIN(ang);
          FOR j IN 1 .. 3 LOOP
            seg(112, 160d + ((tx + rr * (th_x1(j) * ca - th_y1(j) * sa)) - cx) * scale,
                     100d - ((ty + rr * (th_x1(j) * sa + th_y1(j) * ca)) - cy) * scale,
                     160d + ((tx + rr * (th_x2(j) * ca - th_y2(j) * sa)) - cx) * scale,
                     100d - ((ty + rr * (th_x2(j) * sa + th_y2(j) * ca)) - cy) * scale);
          END LOOP;
        END LOOP;
      END IF;
      -- AM_drawGrid: 128-unit lines across the visible span
      IF grid THEN
        x0 := cx - 160d / scale; x1 := cx + 160d / scale; y0 := cy - 100d / scale; y1 := cy + 100d / scale;
        FOR kx IN CEIL(x0 / 128d) .. FLOOR(x1 / 128d) LOOP
          seg(104, 160d + (kx * 128d - cx) * scale, 100d - (y0 - cy) * scale,
                   160d + (kx * 128d - cx) * scale, 100d - (y1 - cy) * scale);
        END LOOP;
        FOR ky IN CEIL(y0 / 128d) .. FLOOR(y1 / 128d) LOOP
          seg(104, 160d + (x0 - cx) * scale, 100d - (ky * 128d - cy) * scale,
                   160d + (x1 - cx) * scale, 100d - (ky * 128d - cy) * scale);
        END LOOP;
      END IF;
      -- clip (Liang-Barsky against [0,319] x [0,199]) and step; priority layer*256 + palette index
      FOR i IN 1 .. sn LOOP
        ax := s_ax(i); ay := s_ay(i); dx := s_bx(i) - ax; dy := s_by(i) - ay;
        IF dx <> 0d OR dy <> 0d THEN
          u := CASE WHEN dx > 0d THEN (0d - ax) / dx WHEN dx < 0d THEN (319d - ax) / dx ELSE 0d END;
          vv := CASE WHEN dy > 0d THEN (0d - ay) / dy WHEN dy < 0d THEN (199d - ay) / dy ELSE 0d END;
          t0 := CASE WHEN vv > u THEN vv ELSE u END;
          u := CASE WHEN dx > 0d THEN (319d - ax) / dx WHEN dx < 0d THEN (0d - ax) / dx ELSE 1d END;
          vv := CASE WHEN dy > 0d THEN (199d - ay) / dy WHEN dy < 0d THEN (0d - ay) / dy ELSE 1d END;
          t1 := CASE WHEN vv < u THEN vv ELSE u END;
          tlo := CASE WHEN t0 > 0d THEN t0 ELSE 0d END;
          thi := CASE WHEN t1 < 1d THEN t1 ELSE 1d END;
          IF tlo <= thi THEN
            u := ABS(dx * (thi - tlo)); vv := ABS(dy * (thi - tlo));
            steps := CEIL(CASE WHEN vv > u THEN vv ELSE u END);
            IF steps < 1d THEN steps := 1d; END IF;
            ns := steps;
            lyr := CASE s_pi(i) WHEN 112 THEN 10 WHEN 209 THEN 9 WHEN 99 THEN 0 WHEN 104 THEN -1 ELSE 1 END;
            kk := lyr * 256 + s_pi(i);
            FOR g IN 0 .. ns LOOP
              u := tlo + (thi - tlo) * g / steps;
              xi := rnd(ax + dx * u); yi := rnd(ay + dy * u);
              IF xi BETWEEN 0 AND 319 AND yi BETWEEN 0 AND 199 THEN
                p := yi * 320 + xi;
                IF fbs(p) <> g_stamp THEN
                  fbs(p) := g_stamp; fl(p) := kk; fb(p) := s_pi(i);
                  IF rd(yi) <> g_stamp THEN rd(yi) := g_stamp; rx0(yi) := xi; rx1(yi) := xi;
                  ELSIF xi < rx0(yi) THEN rx0(yi) := xi; ELSIF xi > rx1(yi) THEN rx1(yi) := xi; END IF;
                ELSIF kk > fl(p) THEN fl(p) := kk; fb(p) := s_pi(i);
                END IF;
              END IF;
            END LOOP;
          END IF;
        END IF;
      END LOOP;
    END IF;
    tmark('paint'); FOR y IN 0 .. 199 LOOP PIPE ROW (doom_hex_row(y, 0, out_row(y))); END LOOP; tmark('out');
    RETURN;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20001, 'doom_screen: NO_DATA_FOUND ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
  END;
END doom_screen;
/
