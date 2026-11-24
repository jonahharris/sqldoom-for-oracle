#!/usr/bin/env python3
"""Load a Doom WAD into the Oracle 26ai SQL Doom data layer.

    python oracle/client/load_wad.py oracle/wad/freedoom1.wad E1M1 E1M2 E1M3

Recreates the static schema (oracle/sql/01_schema.sql), loads the gameplay
catalogs (oracle/sql/03_catalogs.sql), parses the WAD in Python and bulk-loads
geometry/textures/sprites/UI patches with array DML, then derives the renderer
caches in SQL exactly as the reference does:

  render_segs      <- doom_materialize_render_segs        (sql/loader/functions/00_*)
  render_things    <- doom_materialize_render_things      (sql/loader/functions/01_*)
  node_path_steps  <- MATERIALIZED VIEW node_path_steps   (sql/schema.sql)
  ui_hud_pixels    <- MATERIALIZED VIEW ui_hud_pixels     (sql/schema.sql)
  ui_static_pixels <- MATERIALIZED VIEW ui_static_pixels  (sql/schema.sql)
  linedefs flags   <- wad_sql.stamp_line_specials
  sector_light_fx  <- doom_reset_stage (level start)      (sql/runtime/functions/04_*)

WAD parsing (lump directory, patch/texture/sprite decoding, map lump layouts)
is adapted from reference/sqldoom/wad_loader.py (CedarDB SQLDoom, GPL); the
pixel compositing is vectorised with numpy but produces identical bytes.
Map ids are assigned 1..n in WAD order, as the reference's SERIAL does on a
fresh database (E1M1=1, E1M2=2, E1M3=3).
"""
import argparse
import re
import struct
import sys
import time
from pathlib import Path

import numpy as np
import oracledb

sys.path.insert(0, str(Path(__file__).resolve().parent))
import oradb  # noqa: E402

LE = "<"

# Same list/order as reference wad_loader.UI_PATCH_NAMES.
UI_PATCH_NAMES = (
    "STBAR",
    "STTNUM0", "STTNUM1", "STTNUM2", "STTNUM3", "STTNUM4",
    "STTNUM5", "STTNUM6", "STTNUM7", "STTNUM8", "STTNUM9",
    "STTMINUS", "STTPRCNT",
    "STFST00", "STFST01", "STFST02", "STFST10", "STFST11", "STFST12",
    "STFST20", "STFST21", "STFST22", "STFST30", "STFST31", "STFST32",
    "STFST40", "STFST41", "STFST42",
    "STFTL00", "STFTL10", "STFTL20", "STFTL30", "STFTL40",
    "STFTR00", "STFTR10", "STFTR20", "STFTR30", "STFTR40",
    "STFOUCH0", "STFOUCH1", "STFOUCH2", "STFOUCH3", "STFOUCH4",
    "STFEVL0", "STFEVL1", "STFEVL2", "STFEVL3", "STFEVL4",
    "STFGOD0", "STFDEAD0",
    "STYSNUM0", "STYSNUM1", "STYSNUM2", "STYSNUM3", "STYSNUM4",
    "STYSNUM5", "STYSNUM6", "STYSNUM7", "STYSNUM8", "STYSNUM9",
    "STARMS", "STGNUM2", "STGNUM3", "STGNUM4", "STGNUM5", "STGNUM6", "STGNUM7",
    "STKEYS0", "STKEYS1", "STKEYS2", "STKEYS3", "STKEYS4", "STKEYS5",
    "TITLEPIC", "CREDIT", "HELP1", "M_DOOM",
    "M_NGAME", "M_OPTION", "M_LOADG", "M_SAVEG", "M_QUITG", "M_RDTHIS",
    "M_NEWG", "M_EPISOD", "M_EPI1", "M_EPI2", "M_EPI3", "M_EPI4",
    "M_SKILL", "M_JKILL", "M_ROUGH", "M_HURT", "M_ULTRA", "M_NMARE",
    "M_SKULL1", "M_SKULL2", "M_PAUSE",
    "M_LSLEFT", "M_LSCNTR", "M_LSRGHT", "M_LGTTL", "M_SGTTL",
    "WIMAP0", "WIMAP1", "WIMAP2", "INTERPIC",
    "VICTORY2", "ENDPIC", "PFUB1", "PFUB2",
    "END0", "END1", "END2", "END3", "END4", "END5", "END6",
    "WIF", "WIENTER", "WIOSTK", "WIOSTI", "WISCRT2", "WITIME", "WIPAR",
    "WIPCNT", "WICOLON", "WIMINUS", "WISUCKS", "WIURH0", "WIURH1", "WISPLAT",
    "WINUM0", "WINUM1", "WINUM2", "WINUM3", "WINUM4",
    "WINUM5", "WINUM6", "WINUM7", "WINUM8", "WINUM9",
) + tuple(f"WILV{e}{m}" for e in range(4) for m in range(9)) + tuple(
    f"STCFN{code:03d}" for code in list(range(33, 96)) + [121])

STATIC_TABLES = (
    "maps", "vertexes", "sectors", "sidedefs", "linedefs", "things", "segs",
    "ssectors", "nodes", "node_children", "node_path_steps", "render_segs",
    "render_things", "sector_light_fx", "colormap_rgb", "walltex_meta",
    "flat_textures", "sprite_frames", "sprite_lumps", "ui_patches",
    "ui_patch_pixels", "ui_hud_pixels", "ui_static_pixels",
    "thing_sprite_defs", "thing_combat_defs", "thing_ai_frames",
    "effect_sprite_defs", "projectile_defs", "weapon_defs", "weapon_frames",
    "ammo_defs", "line_special_defs",
)


def progress(msg):
    print(f"[load_wad] {msg}", flush=True)


# ----------------------------------------------------------------- WAD parsing
def cstr8(raw8: bytes) -> str:
    return raw8.replace(b"\x00", b"").decode("ascii", errors="ignore").strip().upper()


def nullable_tex(raw8: bytes):
    s = cstr8(raw8)
    return s if s != "" else None   # '-' is kept; empty -> NULL (as reference)


def is_map_marker(name):
    return bool(re.match(r"^E[1-4]M[1-9]$", name) or re.match(r"^MAP[0-9][0-9]$", name))


def sky_lump_for_map(name):
    m = re.match(r"^E([1-4])M[1-9]$", name)
    if m:
        return "SKY" + m.group(1)
    m = re.match(r"^MAP([0-9][0-9])$", name)
    if m:
        n = int(m.group(1))
        return "SKY1" if n < 12 else "SKY2" if n < 21 else "SKY3"
    return None


class Wad:
    def __init__(self, path):
        self.data = Path(path).read_bytes()
        ident, n, dofs = struct.unpack_from(LE + "4sii", self.data, 0)
        if ident not in (b"IWAD", b"PWAD"):
            raise ValueError(f"not a WAD: {ident!r}")
        self.lumps = []
        for i in range(n):
            ofs, size, name = struct.unpack_from(LE + "ii8s", self.data, dofs + 16 * i)
            self.lumps.append({"name": cstr8(name), "ofs": ofs, "size": size})
        self.first = {}
        for l in self.lumps:
            self.first.setdefault(l["name"], l)   # first occurrence wins (reference _lump_map)
        self.names = [l["name"] for l in self.lumps]

    def raw(self, lump):
        return self.data[lump["ofs"]:lump["ofs"] + lump["size"]]

    def between(self, start, end):
        if start not in self.names or end not in self.names:
            return []
        return self.lumps[self.names.index(start) + 1:self.names.index(end)]


def decode_patch(data: bytes):
    """Doom picture -> (w, h, left, top, cols{x: [(topdelta, bytes)]})."""
    w, h, left, top = struct.unpack_from(LE + "hhhh", data, 0)
    if w <= 0 or h <= 0 or 8 + 4 * w > len(data):
        raise ValueError("invalid Doom patch dimensions")
    colofs = struct.unpack_from(LE + "%di" % w, data, 8)
    cols = {}
    for x in range(w):
        o = colofs[x]
        posts = []
        while 0 <= o < len(data):
            td = data[o]
            if td == 0xFF:
                break
            ln = data[o + 1]
            posts.append((td, data[o + 3:o + 3 + ln]))
            o += 4 + ln
        cols[x] = posts
    return w, h, left, top, cols


def patch_bitmap(w, h, cols):
    """Row-major (h, w) pixel + mask arrays (offset = v*w + u), like the reference."""
    pix = np.zeros((h, w), dtype=np.uint8)
    mask = np.zeros((h, w), dtype=np.uint8)
    for u, posts in cols.items():
        for td, px in posts:
            n = min(len(px), h - td)
            if n > 0:
                pix[td:td + n, u] = np.frombuffer(px, dtype=np.uint8, count=n)
                mask[td:td + n, u] = 1
    return pix, mask


# --------------------------------------------------------------- bulk loaders
def insert_many(cur, sql, rows, sizes=None, batch=50000):
    if not rows:
        return
    if sizes:
        cur.setinputsizes(*sizes)
    for i in range(0, len(rows), batch):
        cur.executemany(sql, rows[i:i + batch])


def load_colormap(cur, wad):
    pal_raw = wad.raw(wad.first["PLAYPAL"])
    palettes = [[tuple(pal_raw[p * 768 + i * 3:p * 768 + i * 3 + 3]) for i in range(256)]
                for p in range(max(1, len(pal_raw) // 768))]
    cm = wad.raw(wad.first["COLORMAP"])
    levels = min(34, len(cm) // 256)
    rows = []
    for p, palette in enumerate(palettes):
        for lvl in range(levels):
            for src in range(256):
                m = cm[lvl * 256 + src]
                r, g, b = palette[m]
                rows.append((p, lvl, src, m, r, g, b, bytes((r, g, b))))
    insert_many(cur, "INSERT INTO colormap_rgb (pal, light_level, palette_index, mapped_index,"
                     " r, g, b, rgb) VALUES (:1,:2,:3,:4,:5,:6,:7,:8)", rows)
    return len(rows)


def load_walls(cur, wad):
    pn = wad.raw(wad.first["PNAMES"])
    pnames = [cstr8(pn[4 + 8 * i:12 + 8 * i]) for i in range(struct.unpack_from(LE + "i", pn, 0)[0])]
    patches = {}
    for l in wad.between("P_START", "P_END"):
        if l["size"] > 0:
            try:
                patches[l["name"]] = decode_patch(wad.raw(l))
            except Exception:
                pass
    texdefs = []
    for lump_name in ("TEXTURE1", "TEXTURE2"):
        if lump_name not in wad.first:
            continue
        data = wad.raw(wad.first[lump_name])
        n = struct.unpack_from(LE + "i", data, 0)[0]
        for o in struct.unpack_from(LE + "%di" % n, data, 4):
            name = cstr8(data[o:o + 8])
            _m, width, height, _cd, pcount = struct.unpack_from(LE + "ihhih", data, o + 8)
            plist = [struct.unpack_from(LE + "hhhhh", data, o + 22 + 10 * k)[:3] for k in range(pcount)]
            texdefs.append((name, width, height, plist))
    rows = []
    for name, w, h, plist in texdefs:
        if w <= 0 or h <= 0:
            continue
        tex = np.zeros((h, w), dtype=np.uint8)
        for ox, oy, pi in plist:
            if pi < 0 or pi >= len(pnames) or pnames[pi] not in patches:
                continue
            pw, _ph, _l, _t, cols = patches[pnames[pi]]
            for x in range(pw):
                tx = ox + x
                if tx < 0 or tx >= w:
                    continue
                for td, px in cols.get(x, []):
                    arr = np.frombuffer(px, dtype=np.uint8)
                    y0 = oy + td
                    a, b = max(0, y0), min(h, y0 + len(arr))
                    if a < b:
                        tex[a:b, tx] = arr[a - y0:b - y0]
        rows.append((name, w, h, tex.tobytes()))
    insert_many(cur, "INSERT INTO walltex_meta (name, width, height, palette_indices)"
                     " VALUES (:1,:2,:3,:4)", rows,
                sizes=(None, None, None, oracledb.DB_TYPE_BLOB), batch=200)
    return len(rows)


def load_flats(cur, wad):
    rows = [(l["name"], wad.raw(l)) for l in wad.between("F_START", "F_END") if l["size"] == 4096]
    insert_many(cur, "INSERT INTO flat_textures (name, palette_indices) VALUES (:1,:2)", rows,
                sizes=(None, oracledb.DB_TYPE_BLOB), batch=500)
    return len(rows)


def load_ui_patches(cur, wad):
    lmap = {l["name"]: l for l in wad.lumps}    # last occurrence, as the reference
    rows, px_rows, skipped = [], [], []
    for name in UI_PATCH_NAMES:
        lump = lmap.get(name)
        if lump is None or lump["size"] <= 0:
            skipped.append(name)
            continue
        try:
            w, h, left, top, cols = decode_patch(wad.raw(lump))
        except (ValueError, struct.error):
            skipped.append(name)
            continue
        pix, mask = patch_bitmap(w, h, cols)
        rows.append((name, w, h, left, top, pix.tobytes(), mask.tobytes()))
        vs, us = np.nonzero(mask)
        px_rows.extend(zip([name] * len(vs), us.tolist(), vs.tolist(), pix[vs, us].tolist()))
    insert_many(cur, "INSERT INTO ui_patches (name, width, height, left_offset, top_offset,"
                     " pixels, mask) VALUES (:1,:2,:3,:4,:5,:6,:7)", rows,
                sizes=(None,) * 5 + (oracledb.DB_TYPE_BLOB, oracledb.DB_TYPE_BLOB), batch=100)
    cur.setinputsizes()
    insert_many(cur, "INSERT INTO ui_patch_pixels (name, dx, dy, palette_index)"
                     " VALUES (:1,:2,:3,:4)", px_rows, batch=100000)
    return len(rows), len(px_rows), skipped


def load_sprites(cur, wad):
    frames, lumps = {}, {}
    for l in wad.between("S_START", "S_END"):
        m = re.match(r"^([A-Z0-9]{4})([A-Z])([0-8])(?:([A-Z])([0-8]))?$", l["name"])
        if not m or l["size"] < 12:
            continue
        try:
            w, h, left, top, cols = decode_patch(wad.raw(l))
        except (ValueError, struct.error):
            continue
        sprite, f1, r1, f2, r2 = m.groups()
        frames[(sprite, f1, int(r1))] = (sprite, f1, int(r1), l["name"], False, w, h, left, top)
        if f2 is not None:
            frames[(sprite, f2, int(r2))] = (sprite, f2, int(r2), l["name"], True, w, h, left, top)
        pix, mask = patch_bitmap(w, h, cols)
        lumps[l["name"]] = (l["name"], pix.tobytes(), mask.tobytes())
    insert_many(cur, "INSERT INTO sprite_lumps (lump_name, pixels, mask) VALUES (:1,:2,:3)",
                list(lumps.values()),
                sizes=(None, oracledb.DB_TYPE_BLOB, oracledb.DB_TYPE_BLOB), batch=500)
    cur.setinputsizes()
    insert_many(cur, "INSERT INTO sprite_frames (sprite, frame, rotation, lump_name, flipped,"
                     " width, height, left_offset, top_offset) VALUES (:1,:2,:3,:4,:5,:6,:7,:8,:9)",
                list(frames.values()))
    return len(lumps), len(frames)


def load_map(cur, wad, idx, map_id, wad_id=1):
    marker = wad.lumps[idx]["name"]
    end = len(wad.lumps)
    for j in range(idx + 1, len(wad.lumps)):
        if is_map_marker(wad.lumps[j]["name"]):
            end = j
            break
    L = {wad.lumps[i]["name"]: wad.lumps[i] for i in range(idx + 1, end)}

    def recs(name, fmt):
        raw = wad.raw(L[name])
        s = struct.Struct(LE + fmt)
        return [s.unpack_from(raw, k * s.size) for k in range(len(raw) // s.size)]

    cur.execute("INSERT INTO maps (map_id, wad_id, name, sky_texture) VALUES (:1,:2,:3,:4)",
                (map_id, wad_id, marker, sky_lump_for_map(marker)))
    insert_many(cur, "INSERT INTO vertexes (id, map_id, x, y) VALUES (:1,:2,:3,:4)",
                [(i, map_id, x, y) for i, (x, y) in enumerate(recs("VERTEXES", "hh"))])
    rows = []
    for i, (fh, ch, ft, ct, light, special, tag) in enumerate(recs("SECTORS", "hh8s8shhh")):
        ft, ct = nullable_tex(ft), nullable_tex(ct)
        rows.append((i, map_id, fh, ch, fh, ch, ft, light, ft, ct, light, special, tag))
    insert_many(cur, "INSERT INTO sectors (id, map_id, floor_height, ceil_height,"
                     " spawn_floor_height, spawn_ceil_height, spawn_floor_tex, spawn_light_level,"
                     " floor_tex, ceil_tex, light_level, special, tag)"
                     " VALUES (:1,:2,:3,:4,:5,:6,:7,:8,:9,:10,:11,:12,:13)", rows)
    insert_many(cur, "INSERT INTO sidedefs (id, map_id, x_offset, y_offset, upper_tex, lower_tex,"
                     " mid_tex, sector_id) VALUES (:1,:2,:3,:4,:5,:6,:7,:8)",
                [(i, map_id, xo, yo, nullable_tex(up), nullable_tex(lo), nullable_tex(mid), sec)
                 for i, (xo, yo, up, lo, mid, sec) in enumerate(recs("SIDEDEFS", "hh8s8s8sh"))])
    insert_many(cur, "INSERT INTO linedefs (id, map_id, v1_id, v2_id, flags, special, tag,"
                     " right_sd_id, left_sd_id) VALUES (:1,:2,:3,:4,:5,:6,:7,:8,:9)",
                [(i, map_id, v1, v2, fl, sp, tg, -1 if r == 0xFFFF else r, -1 if l == 0xFFFF else l)
                 for i, (v1, v2, fl, sp, tg, r, l) in enumerate(recs("LINEDEFS", "HHHHHHH"))])
    insert_many(cur, "INSERT INTO things (id, map_id, x, y, angle, type, flags, spawn_x, spawn_y,"
                     " spawn_angle) VALUES (:1,:2,:3,:4,:5,:6,:7,:8,:9,:10)",
                [(i, map_id, float(x), float(y), float(a), t, f, x, y, a)
                 for i, (x, y, a, t, f) in enumerate(recs("THINGS", "hhhhH"))])
    insert_many(cur, "INSERT INTO segs (id, map_id, v1_id, v2_id, angle, linedef_id, direction, offs)"
                     " VALUES (:1,:2,:3,:4,:5,:6,:7,:8)",
                [(i, map_id, *r) for i, r in enumerate(recs("SEGS", "HHhHhh"))])
    insert_many(cur, "INSERT INTO ssectors (id, map_id, seg_count, first_seg_id) VALUES (:1,:2,:3,:4)",
                [(i, map_id, c, f) for i, (c, f) in enumerate(recs("SSECTORS", "HH"))])
    nodes, children = [], []
    for i, r in enumerate(recs("NODES", "hhhh hhhh hhhh HH".replace(" ", ""))):
        x, y, dx, dy = r[0:4]
        nodes.append((i, map_id, x, y, dx, dy))
        for side, bbox, child in (("R", r[4:8], r[12]), ("L", r[8:12], r[13])):
            if child & 0x8000:
                kind, cn, cs = "SSECTOR", None, child & 0x7FFF
            else:
                kind, cn, cs = "NODE", child, None
            children.append((map_id, i, side, kind, cn, cs, *bbox))
    insert_many(cur, "INSERT INTO nodes (id, map_id, x, y, dx, dy) VALUES (:1,:2,:3,:4,:5,:6)", nodes)
    insert_many(cur, "INSERT INTO node_children (map_id, node_id, side, child_kind, child_node_id,"
                     " child_ssector_id, bbox_top, bbox_bottom, bbox_left, bbox_right)"
                     " VALUES (:1,:2,:3,:4,:5,:6,:7,:8,:9,:10)", children)
    return marker


# ------------------------------------------------------------ SQL derivations
DERIVE_SQL = [
    ("linedefs flags (stamp_line_specials)", """
UPDATE linedefs ld
SET (cross_activated, cross_once, monster_crossable, scrolls) =
    (SELECT d.cross_activated, d.cross_once, d.monster_crossable, d.scrolls
     FROM line_special_defs d WHERE d.special = ld.special)
WHERE EXISTS (SELECT 1 FROM line_special_defs d WHERE d.special = ld.special)"""),

    ("render_segs (doom_materialize_render_segs)", """
INSERT INTO render_segs (
  map_id, seg_id, ssector_id, direction, linedef_id, x1, y1, x2, y2,
  seg_u1, seg_u2, fsec, bsec, x_offset, y_offset,
  upper_tex, mid_tex, lower_tex, flags,
  f_floor, f_ceil, f_ceil_tex, f_light,
  b_floor, b_ceil, b_ceil_tex, b_light, light_bias)
SELECT sg.map_id, sg.id, ss.id, sg.direction, sg.linedef_id,
       v1.x, v1.y, v2.x, v2.y,
       CASE WHEN sg.direction = 0 THEN TO_BINARY_DOUBLE(sg.offs)
            ELSE sg.offs + SQRT(TO_BINARY_DOUBLE((v2.x-v1.x)*(v2.x-v1.x) + (v2.y-v1.y)*(v2.y-v1.y))) END,
       CASE WHEN sg.direction = 0
            THEN sg.offs + SQRT(TO_BINARY_DOUBLE((v2.x-v1.x)*(v2.x-v1.x) + (v2.y-v1.y)*(v2.y-v1.y)))
            ELSE TO_BINARY_DOUBLE(sg.offs) END,
       fs.id, bs.id, front.x_offset, front.y_offset,
       front.upper_tex, front.mid_tex, front.lower_tex, ld.flags,
       fs.floor_height, fs.ceil_height, fs.ceil_tex, fs.light_level,
       bs.floor_height, bs.ceil_height, bs.ceil_tex, bs.light_level,
       CASE WHEN v1.y = v2.y THEN -1 WHEN v1.x = v2.x THEN 1 ELSE 0 END
FROM segs sg
JOIN ssectors ss ON ss.map_id = sg.map_id
  AND sg.id >= ss.first_seg_id AND sg.id < ss.first_seg_id + ss.seg_count
JOIN vertexes v1 ON v1.map_id = sg.map_id AND v1.id = sg.v1_id
JOIN vertexes v2 ON v2.map_id = sg.map_id AND v2.id = sg.v2_id
JOIN linedefs ld ON ld.map_id = sg.map_id AND ld.id = sg.linedef_id
JOIN sidedefs front ON front.map_id = sg.map_id
  AND front.id = CASE WHEN sg.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END
LEFT JOIN sidedefs back ON back.map_id = sg.map_id
  AND back.id = CASE WHEN sg.direction = 0 THEN ld.left_sd_id ELSE ld.right_sd_id END
JOIN sectors fs ON fs.map_id = sg.map_id AND fs.id = front.sector_id
LEFT JOIN sectors bs ON bs.map_id = sg.map_id AND bs.id = back.sector_id"""),

    ("render_things (doom_materialize_render_things)", """
INSERT INTO render_things (map_id, thing_id, sector_id, spawn_sector_id, sprite, frame,
                           fullbright, spawn_ceiling, thing_height)
WITH roots AS (
  SELECT map_id, MAX(id) AS node_id FROM nodes GROUP BY map_id
),
thing_bsp (map_id, thing_id, tx, ty, node_id, ssector_id) AS (
  SELECT t.map_id, t.id, t.x, t.y, r.node_id, CAST(NULL AS NUMBER)
  FROM things t
  JOIN thing_sprite_defs d ON d.thing_type = t.type
  JOIN roots r ON r.map_id = t.map_id
  UNION ALL
  SELECT b.map_id, b.thing_id, b.tx, b.ty,
         CASE WHEN nc.child_kind = 'NODE' THEN nc.child_node_id END,
         CASE WHEN nc.child_kind = 'SSECTOR' THEN nc.child_ssector_id END
  FROM thing_bsp b
  JOIN nodes n ON n.map_id = b.map_id AND n.id = b.node_id
  JOIN node_children nc
    ON nc.map_id = b.map_id AND nc.node_id = n.id
   AND nc.side = CASE WHEN (b.tx - TO_BINARY_DOUBLE(n.x)) * TO_BINARY_DOUBLE(n.dy)
                         - (b.ty - TO_BINARY_DOUBLE(n.y)) * TO_BINARY_DOUBLE(n.dx) > 0
                      THEN 'R' ELSE 'L' END
  WHERE b.node_id IS NOT NULL
),
located AS (
  SELECT b.map_id, b.thing_id, rs.fsec AS sector_id,
         ROW_NUMBER() OVER (PARTITION BY b.map_id, b.thing_id ORDER BY rs.seg_id) AS rn
  FROM thing_bsp b
  JOIN render_segs rs ON rs.map_id = b.map_id AND rs.ssector_id = b.ssector_id
  WHERE b.ssector_id IS NOT NULL
)
SELECT l.map_id, l.thing_id, l.sector_id, l.sector_id,
       d.sprite, d.frame, d.fullbright, d.spawn_ceiling, d.thing_height
FROM located l
JOIN things t ON t.map_id = l.map_id AND t.id = l.thing_id
JOIN thing_sprite_defs d ON d.thing_type = t.type
WHERE l.rn = 1"""),

    # Reference walks root->leaf collecting ARRAY paths; walking leaf->root
    # and numbering from the root gives the same (ssector, depth, node, side)
    # rows. Only leaves whose top ancestor is the root (MAX(id)) are kept.
    ("node_path_steps (materialized view)", """
INSERT INTO node_path_steps (map_id, ssector_id, depth, node_id, side)
WITH up (map_id, ssector_id, node_id, side, lvl) AS (
  SELECT nc.map_id, nc.child_ssector_id, nc.node_id, nc.side, 1
  FROM node_children nc WHERE nc.child_kind = 'SSECTOR'
  UNION ALL
  SELECT u.map_id, u.ssector_id, p.node_id, p.side, u.lvl + 1
  FROM up u
  JOIN node_children p ON p.map_id = u.map_id AND p.child_kind = 'NODE'
                      AND p.child_node_id = u.node_id
),
numbered AS (
  SELECT u.*, MAX(lvl) OVER (PARTITION BY map_id, ssector_id) AS total,
         FIRST_VALUE(node_id) OVER (PARTITION BY map_id, ssector_id ORDER BY lvl DESC) AS top
  FROM up u
)
SELECT n.map_id, n.ssector_id, n.total - n.lvl + 1, n.node_id, n.side
FROM numbered n
JOIN (SELECT map_id, MAX(id) AS root FROM nodes GROUP BY map_id) r
  ON r.map_id = n.map_id AND r.root = n.top"""),

    ("ui_hud_pixels (materialized view)", """
INSERT INTO ui_hud_pixels (name, dx, dy, palette_index)
SELECT name, dx, dy, palette_index FROM ui_patch_pixels WHERE name LIKE 'ST%'"""),

    ("ui_static_pixels (materialized view)", """
INSERT INTO ui_static_pixels (x, y, rgb, palette_index)
WITH static_layers (name, layer, x, y) AS (
  SELECT 'STBAR',    0,   0, 168 FROM dual UNION ALL
  SELECT 'STTPRCNT', 1,  90, 172 FROM dual UNION ALL
  SELECT 'STTPRCNT', 1, 221, 172 FROM dual UNION ALL
  SELECT 'STARMS',   1, 104, 168 FROM dual
), candidates AS (
  SELECT l.layer,
         l.x - p.left_offset + px.dx AS x,
         l.y - p.top_offset + px.dy AS y,
         px.palette_index,
         ROW_NUMBER() OVER (
           PARTITION BY l.x - p.left_offset + px.dx, l.y - p.top_offset + px.dy
           ORDER BY l.layer DESC, l.name) AS rn
  FROM static_layers l
  JOIN ui_patches p ON p.name = l.name
  JOIN ui_patch_pixels px ON px.name = l.name
)
SELECT c.x, c.y, cm.rgb, c.palette_index
FROM candidates c
JOIN colormap_rgb cm ON cm.pal = 0 AND cm.light_level = 0 AND cm.palette_index = c.palette_index
WHERE c.rn = 1"""),

    # doom_reset_stage at level start: sectors are at their spawn values then,
    # which is exactly the load state, so the reference query applies as is.
    ("sector_light_fx (doom_reset_stage)", """
INSERT INTO sector_light_fx (map_id, sector_id, special, base_light, dark_light)
SELECT s.map_id, s.id, s.special,
       COALESCE(s.spawn_light_level, s.light_level),
       LEAST(COALESCE(s.spawn_light_level, s.light_level), COALESCE(MIN(other.light_level), 0))
FROM sectors s
LEFT JOIN linedefs edge ON edge.map_id = s.map_id
LEFT JOIN sidedefs r ON r.map_id = edge.map_id AND r.id = edge.right_sd_id
LEFT JOIN sidedefs l ON l.map_id = edge.map_id AND l.id = edge.left_sd_id
LEFT JOIN sectors other ON other.map_id = s.map_id
  AND other.id = CASE WHEN r.sector_id = s.id THEN l.sector_id
                      WHEN l.sector_id = s.id THEN r.sector_id END
WHERE s.special IN (1, 2, 3, 8, 12, 13, 17)
GROUP BY s.map_id, s.id, s.special, s.spawn_light_level, s.light_level"""),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("wad")
    ap.add_argument("maps", nargs="*", help="map names (default: all)")
    ap.add_argument("--dsn", default=oradb.DEFAULT_DSN)
    ap.add_argument("--user", default=oradb.DEFAULT_USER)
    ap.add_argument("--password", default=oradb.DEFAULT_PASSWORD)
    args = ap.parse_args()

    t_all = time.perf_counter()
    timings = {}

    def phase(name, t0):
        timings[name] = time.perf_counter() - t0
        progress(f"{name}: {timings[name]:.2f}s")

    conn = oradb.connect(args.dsn, args.user, args.password)
    cur = conn.cursor()

    t0 = time.perf_counter()
    oradb.run_script(cur, oradb.SQL_DIR / "01_schema.sql")
    oradb.run_script(cur, oradb.SQL_DIR / "03_catalogs.sql")
    conn.commit()
    phase("schema + catalogs", t0)

    t0 = time.perf_counter()
    wad = Wad(args.wad)
    n_cm = load_colormap(cur, wad)
    n_walls = load_walls(cur, wad)
    n_flats = load_flats(cur, wad)
    n_ui, n_ui_px, skipped = load_ui_patches(cur, wad)
    cur.setinputsizes()
    n_spr, n_frames = load_sprites(cur, wad)
    cur.setinputsizes()
    conn.commit()
    progress(f"colormap {n_cm}, walls {n_walls}, flats {n_flats}, ui patches {n_ui} "
             f"({n_ui_px} px), sprite lumps {n_spr}, sprite frames {n_frames}")
    if skipped:
        progress(f"UI patches not in WAD: {', '.join(skipped)}")
    phase("textures/sprites/ui", t0)

    t0 = time.perf_counter()
    wanted = {m.upper() for m in args.maps}
    map_id = 0
    for i, l in enumerate(wad.lumps):
        if is_map_marker(l["name"]) and (not wanted or l["name"] in wanted):
            map_id += 1
            load_map(cur, wad, i, map_id)
            progress(f"map {l['name']} -> map_id {map_id}")
    conn.commit()
    phase("map geometry", t0)

    for name, sql in DERIVE_SQL:
        t0 = time.perf_counter()
        cur.execute(sql)
        progress(f"  {cur.rowcount} rows")
        conn.commit()
        phase(name, t0)

    t0 = time.perf_counter()
    oradb.gather_stats(cur, STATIC_TABLES)
    phase("DBMS_STATS", t0)
    progress(f"total {time.perf_counter() - t_all:.2f}s")
    conn.close()


if __name__ == "__main__":
    main()
