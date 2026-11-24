#!/usr/bin/env python3
"""Load-time texture representations for the optimized renderer (static WAD data only).

Every texel is encoded as ONE UTF-16 code unit in an NVARCHAR2 string: palette index i is
character U+0100+i, so in SQL  ASCII(SUBSTR(s, pos, 1)) - 256 = i  is an O(1) lookup (AL16UTF16
is fixed width) and SUBSTR truncates a fractional position (a free FLOOR for pos >= 1).
Lighting is applied at load time: a "lit" string holds COLORMAP[light][texel], so the renderer
never applies COLORMAP per pixel.

Tables (created by sql/04_precompute.sql):
  tex_dim(tex_id, name, width, height)                         wall textures referenced by maps
  texcol_lit(tex_id, u, light, col)                            column u of texture, lit, top->bottom
  flat_dim(flat_id, name)
  flat_lit(flat_id, light, q, s)                               rows 16q..16q+15 of the flat, lit,
                                                               row-major (pos = (v mod 16)*64+u+1)
  colormap_row(light, s)                                       256 chars: COLORMAP row (pal 0)
  sprite_col(lump_name, u, height, col)                        unlit sprite column; U+00FF = transparent
Lights 0..33 are the COLORMAP rows the reference uses (0..31 shading, 32 invulnerability, 33).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import oradb  # noqa: E402

OFF = 0x100
TRANSPARENT = "ÿ"
BATCH = 20000


def enc(idx_bytes):
    return "".join(chr(OFF + b) for b in idx_bytes)


def main():
    t0 = time.perf_counter()
    conn = oradb.connect()
    cur = conn.cursor()
    oradb.run_script(cur, oradb.SQL_DIR / "04_precompute.sql")
    cur.execute("SELECT light_level, palette_index, mapped_index FROM colormap_rgb WHERE pal = 0")
    cmap = {}
    for lvl, pi, mi in cur:
        cmap.setdefault(int(lvl), [0] * 256)[int(pi)] = int(mi)
    lights = sorted(cmap)
    # str.translate tables: texel char -> lit char, per light
    trans = {l: {OFF + i: OFF + cmap[l][i] for i in range(256)} for l in lights}
    cur.setinputsizes(None, oradb.oracledb.DB_TYPE_NVARCHAR)
    cur.executemany("INSERT INTO colormap_row (light, s) VALUES (:1, :2)",
                    [(l, enc(bytes(cmap[l]))) for l in lights])

    # ---- wall textures referenced by any loaded map (+ sky textures)
    cur.execute("""SELECT w.name, w.width, w.height, w.palette_indices FROM walltex_meta w
                   WHERE w.name IN (SELECT upper_tex FROM render_segs UNION SELECT mid_tex FROM render_segs
                                    UNION SELECT lower_tex FROM render_segs UNION SELECT sky_texture FROM maps)
                   ORDER BY w.name""")
    texs = [(n, int(w), int(h), lob.read()) for n, w, h, lob in cur.fetchall()]
    cur.executemany("INSERT INTO tex_dim (tex_id, name, width, height) VALUES (:1, :2, :3, :4)",
                    [(i + 1, n, w, h) for i, (n, w, h, _) in enumerate(texs)])
    rows = []
    ins = "INSERT INTO texcol_lit (tex_id, u, light, col) VALUES (:1, :2, :3, :4)"
    cur.setinputsizes(None, None, None, oradb.oracledb.DB_TYPE_NVARCHAR)
    n_rows = 0
    for tid, (name, w, h, data) in enumerate(texs, 1):
        for u in range(w):
            col = enc(data[u::w][:h])  # row-major -> column u, rows 0..h-1
            for l in lights:
                rows.append((tid, u, l, col.translate(trans[l])))
            if len(rows) >= BATCH:
                cur.executemany(ins, rows); n_rows += len(rows); rows = []
    if rows:
        cur.executemany(ins, rows); n_rows += len(rows); rows = []
    conn.commit()
    print(f"[precompute] texcol_lit: {len(texs)} textures, {n_rows} rows ({time.perf_counter() - t0:.1f}s)")

    # ---- flats used by any sector (static or dynamic floor/ceil texture names)
    cur.execute("""SELECT f.name, f.palette_indices FROM flat_textures f
                   WHERE f.name IN (SELECT floor_tex FROM sectors UNION SELECT ceil_tex FROM sectors
                                    UNION SELECT spawn_floor_tex FROM sectors
                                    UNION SELECT floor_tex FROM st_sectors UNION SELECT ceil_tex FROM st_sectors)
                   ORDER BY f.name""")
    flats = [(n, lob.read()) for n, lob in cur.fetchall()]
    cur.setinputsizes(None, None)
    cur.executemany("INSERT INTO flat_dim (flat_id, name) VALUES (:1, :2)",
                    [(i + 1, n) for i, (n, _) in enumerate(flats)])
    cur.setinputsizes(None, None, None, oradb.oracledb.DB_TYPE_NVARCHAR)
    for fid, (name, data) in enumerate(flats, 1):
        s = enc(data[:4096].ljust(4096, b"\0"))
        for l in lights:
            lit = s.translate(trans[l])
            rows.extend((fid, l, q, lit[q * 1024:(q + 1) * 1024]) for q in range(4))
    cur.executemany("INSERT INTO flat_lit (flat_id, light, q, s) VALUES (:1, :2, :3, :4)", rows)
    rows = []
    conn.commit()
    print(f"[precompute] flat_lit: {len(flats)} flats ({time.perf_counter() - t0:.1f}s)")

    # ---- sprite columns (unlit; lighting is per thing, applied via colormap_row)
    cur.execute("SELECT f.lump_name, MAX(f.width), MAX(f.height) FROM sprite_frames f GROUP BY f.lump_name")
    dims = {n: (int(w), int(h)) for n, w, h in cur.fetchall()}
    cur.execute("SELECT lump_name, pixels, mask FROM sprite_lumps")
    cur2 = conn.cursor()
    cur2.setinputsizes(None, None, None, oradb.oracledb.DB_TYPE_NVARCHAR)
    n_sc = 0
    for name, px, mk in cur.fetchall():
        if name not in dims:
            continue
        w, h = dims[name]
        px, mk = px.read(), mk.read()
        for u in range(w):
            col = "".join(chr(OFF + px[v * w + u]) if mk[v * w + u] else TRANSPARENT for v in range(h))
            rows.append((name, u, h, col))
        if len(rows) >= BATCH:
            cur2.executemany("INSERT INTO sprite_col (lump_name, u, height, col) VALUES (:1, :2, :3, :4)", rows)
            n_sc += len(rows); rows = []
    if rows:
        cur2.executemany("INSERT INTO sprite_col (lump_name, u, height, col) VALUES (:1, :2, :3, :4)", rows)
        n_sc += len(rows); rows = []
    conn.commit()
    print(f"[precompute] sprite_col: {n_sc} rows ({time.perf_counter() - t0:.1f}s)")
    oradb.gather_stats(cur, ["screen_x", "screen_y", "bsp_steps", "hud_static_packed", "hud_static_idx", "cmap", "render_segs_ext", "wall_part_kind", "tex_dim", "texcol_lit", "flat_dim", "flat_lit", "colormap_row", "sprite_col"])
    print(f"[precompute] done in {time.perf_counter() - t0:.1f}s")


if __name__ == "__main__":
    main()
