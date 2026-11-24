#!/usr/bin/env python3
"""Verify the Oracle data layer against the CedarDB reference and the parquet state.

    python oracle/tests/verify_data.py [--run e1m1] [--skip-state]

Static/derived tables (oracle/sql/01_schema.sql): for every table, row count and
an order-independent content comparison against the same table in CedarDB
(map_id 1..3 where the table has map_id). Values are normalised: integers exact,
floats at 1e-9 relative, BLOB/bytea byte-exact, booleans/strings exact. A
sha256 over the sorted normalised rows (floats printed %.9g) is shown per side.

CedarDB is a live game database: map 1 (E1M1) is the map being played, so its
mutable state (sector heights/light/floor texture, thing positions, render_things
sector, switch textures on sidedefs/render_segs, render_segs f_*/b_* plane cache,
dropped things id>=100000) is projected back to its spawn/load values in the
CedarDB query, using the spawn_* columns and line_buttons.original_tex that the
reference itself uses in doom_reset_stage. Maps 2 and 3 are compared as stored.
sector_light_fx is compared with the reference doom_reset_stage query evaluated
read-only on CedarDB for maps 1..3 (CedarDB only materialises it for the map in
play), and additionally with CedarDB's live map-1 rows.

State tables (oracle/sql/02_state_schema.sql): st_<t> vs
reference_data/<run>/state/<t>.parquet -- row counts and full content.
"""
import argparse
import datetime as dt
import decimal
import hashlib
import math
import sys
from pathlib import Path

import oracledb
import psycopg2
import pyarrow.parquet as pq

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import oradb  # noqa: E402

PG_DSN = "postgresql://postgres:postgres_doom_reference_pw@localhost:55433/postgres"
oracledb.defaults.fetch_lobs = False   # BLOB -> bytes

MAPS = "map_id IN (1,2,3)"

# name -> (oracle select list, cedar select list or None (=same), cedar FROM/WHERE override or None, key column count, has map_id)
T = {}


def spec(name, cols, cedar_cols=None, cedar_from=None, map_filter=True):
    T[name] = dict(cols=cols, cedar_cols=cedar_cols or cols, cedar_from=cedar_from,
                   map_filter=map_filter)


spec("maps", "map_id, wad_id, name, sky_texture")
spec("vertexes", "id, map_id, x, y")
spec("sectors",
     "id, map_id, floor_height, ceil_height, spawn_floor_height, spawn_ceil_height, spawn_floor_tex,"
     " spawn_light_level, floor_tex, ceil_tex, light_level, special, tag",
     "id, map_id,"
     " CASE WHEN map_id=1 THEN spawn_floor_height ELSE floor_height END,"
     " CASE WHEN map_id=1 THEN spawn_ceil_height ELSE ceil_height END,"
     " spawn_floor_height, spawn_ceil_height, spawn_floor_tex, spawn_light_level,"
     " CASE WHEN map_id=1 THEN spawn_floor_tex ELSE floor_tex END, ceil_tex,"
     " CASE WHEN map_id=1 THEN spawn_light_level ELSE light_level END, special, tag")
spec("sidedefs", "id, map_id, x_offset, y_offset, upper_tex, lower_tex, mid_tex, sector_id",
     "sd.id, sd.map_id, sd.x_offset, sd.y_offset,"
     " COALESCE(u.original_tex, sd.upper_tex), COALESCE(lo.original_tex, sd.lower_tex),"
     " COALESCE(m.original_tex, sd.mid_tex), sd.sector_id",
     "sidedefs sd"
     " LEFT JOIN line_buttons u ON u.map_id=sd.map_id AND u.sidedef_id=sd.id AND u.texture_part='upper'"
     " LEFT JOIN line_buttons m ON m.map_id=sd.map_id AND m.sidedef_id=sd.id AND m.texture_part='middle'"
     " LEFT JOIN line_buttons lo ON lo.map_id=sd.map_id AND lo.sidedef_id=sd.id AND lo.texture_part='lower'"
     " WHERE sd.map_id IN (1,2,3)")
spec("linedefs", "id, map_id, v1_id, v2_id, flags, special, tag, right_sd_id, left_sd_id,"
     " cross_activated, cross_once, monster_crossable, scrolls")
spec("things", "id, map_id, x, y, z, angle, spawn_x, spawn_y, spawn_angle, mom_x, mom_y, type, flags",
     "id, map_id,"
     " CASE WHEN map_id=1 THEN spawn_x ELSE x END, CASE WHEN map_id=1 THEN spawn_y ELSE y END,"
     " CASE WHEN map_id=1 THEN 41 ELSE z END, CASE WHEN map_id=1 THEN spawn_angle ELSE angle END,"
     " spawn_x, spawn_y, spawn_angle,"
     " CASE WHEN map_id=1 THEN 0 ELSE mom_x END, CASE WHEN map_id=1 THEN 0 ELSE mom_y END, type, flags",
     "things WHERE map_id IN (1,2,3) AND id < 100000")
spec("segs", "id, map_id, v1_id, v2_id, angle, linedef_id, direction, offs")
spec("ssectors", "id, map_id, seg_count, first_seg_id")
spec("nodes", "id, map_id, x, y, dx, dy")
spec("node_children", "map_id, node_id, side, child_kind, child_node_id, child_ssector_id,"
     " bbox_top, bbox_bottom, bbox_left, bbox_right",
     "map_id, node_id, side, child_kind::text, child_node_id, child_ssector_id,"
     " bbox_top, bbox_bottom, bbox_left, bbox_right")
spec("node_path_steps", "map_id, ssector_id, depth, node_id, side")
_RS = ("map_id, seg_id, ssector_id, direction, linedef_id, x1, y1, x2, y2, seg_u1, seg_u2, fsec, bsec,"
       " x_offset, y_offset, upper_tex, mid_tex, lower_tex, flags, f_floor, f_ceil, f_ceil_tex, f_light,"
       " b_floor, b_ceil, b_ceil_tex, b_light, light_bias")
spec("render_segs", _RS,
     "rs.map_id, rs.seg_id, rs.ssector_id, rs.direction, rs.linedef_id, rs.x1, rs.y1, rs.x2, rs.y2,"
     " rs.seg_u1, rs.seg_u2, rs.fsec, rs.bsec, rs.x_offset, rs.y_offset,"
     " COALESCE(u.original_tex, rs.upper_tex), COALESCE(m.original_tex, rs.mid_tex),"
     " COALESCE(lo.original_tex, rs.lower_tex), rs.flags,"
     " CASE WHEN rs.map_id=1 THEN fs.spawn_floor_height ELSE rs.f_floor END,"
     " CASE WHEN rs.map_id=1 THEN fs.spawn_ceil_height ELSE rs.f_ceil END, rs.f_ceil_tex,"
     " CASE WHEN rs.map_id=1 THEN fs.spawn_light_level ELSE rs.f_light END,"
     " CASE WHEN rs.map_id=1 THEN bs.spawn_floor_height ELSE rs.b_floor END,"
     " CASE WHEN rs.map_id=1 THEN bs.spawn_ceil_height ELSE rs.b_ceil END, rs.b_ceil_tex,"
     " CASE WHEN rs.map_id=1 THEN bs.spawn_light_level ELSE rs.b_light END, rs.light_bias",
     "render_segs rs"
     " JOIN linedefs ld ON ld.map_id=rs.map_id AND ld.id=rs.linedef_id"
     " LEFT JOIN sectors fs ON fs.map_id=rs.map_id AND fs.id=rs.fsec"
     " LEFT JOIN sectors bs ON bs.map_id=rs.map_id AND bs.id=rs.bsec"
     " LEFT JOIN line_buttons u ON u.map_id=rs.map_id AND u.line_id=rs.linedef_id AND u.texture_part='upper'"
     "  AND u.sidedef_id = CASE WHEN rs.direction=0 THEN ld.right_sd_id ELSE ld.left_sd_id END"
     " LEFT JOIN line_buttons m ON m.map_id=rs.map_id AND m.line_id=rs.linedef_id AND m.texture_part='middle'"
     "  AND m.sidedef_id = CASE WHEN rs.direction=0 THEN ld.right_sd_id ELSE ld.left_sd_id END"
     " LEFT JOIN line_buttons lo ON lo.map_id=rs.map_id AND lo.line_id=rs.linedef_id AND lo.texture_part='lower'"
     "  AND lo.sidedef_id = CASE WHEN rs.direction=0 THEN ld.right_sd_id ELSE ld.left_sd_id END"
     " WHERE rs.map_id IN (1,2,3)")
spec("render_things", "map_id, thing_id, sector_id, spawn_sector_id, sprite, frame, fullbright,"
     " spawn_ceiling, thing_height",
     "map_id, thing_id, CASE WHEN map_id=1 THEN spawn_sector_id ELSE sector_id END, spawn_sector_id,"
     " sprite, frame, fullbright, spawn_ceiling, thing_height",
     "render_things WHERE map_id IN (1,2,3) AND thing_id < 100000")
# Reference doom_reset_stage query, evaluated read-only (spawn light = level-start light).
spec("sector_light_fx", "map_id, sector_id, special, base_light, dark_light",
     "s.map_id, s.id, s.special::smallint, COALESCE(s.spawn_light_level, s.light_level)::smallint,"
     " LEAST(COALESCE(s.spawn_light_level, s.light_level),"
     "       COALESCE(MIN(other.spawn_light_level), 0::smallint))::smallint",
     "sectors s"
     " LEFT JOIN linedefs edge ON edge.map_id = s.map_id"
     " LEFT JOIN sidedefs r ON r.map_id = edge.map_id AND r.id = edge.right_sd_id"
     " LEFT JOIN sidedefs l ON l.map_id = edge.map_id AND l.id = edge.left_sd_id"
     " LEFT JOIN sectors other ON other.map_id = s.map_id"
     "  AND other.id = CASE WHEN r.sector_id = s.id THEN l.sector_id"
     "                      WHEN l.sector_id = s.id THEN r.sector_id END"
     " WHERE s.map_id IN (1,2,3) AND s.special IN (1,2,3,8,12,13,17)"
     " GROUP BY s.map_id, s.id, s.special, s.spawn_light_level, s.light_level")
T["sector_light_fx[live map 1]"] = dict(
    table="sector_light_fx", cols="map_id, sector_id, special, base_light, dark_light",
    cedar_cols="map_id, sector_id, special, base_light, dark_light",
    cedar_from="sector_light_fx WHERE map_id = 1", oracle_where="map_id = 1", map_filter=True)
spec("colormap_rgb", "pal, light_level, palette_index, mapped_index, r, g, b, rgb",
     "pal, level, palette_index, mapped_index, r, g, b, rgb", map_filter=False)
spec("walltex_meta", "name, width, height, palette_indices", map_filter=False)
spec("flat_textures", "name, palette_indices", map_filter=False)
spec("sprite_frames", "sprite, frame, rotation, lump_name, flipped, width, height, left_offset, top_offset",
     map_filter=False)
spec("sprite_lumps", "lump_name, pixels, mask", map_filter=False)
spec("ui_patches", "name, width, height, left_offset, top_offset, pixels, mask", map_filter=False)
spec("ui_patch_pixels", "name, dx, dy, palette_index", map_filter=False)
spec("ui_hud_pixels", "name, dx, dy, palette_index", map_filter=False)
spec("ui_static_pixels", "x, y, rgb, palette_index", map_filter=False)
spec("thing_sprite_defs", "thing_type, sprite, frame, fullbright, spawn_ceiling, thing_height", map_filter=False)
_TCD = ("thing_type, spawn_health, radius, death_sprite, death_frame, death_fullbright, no_blood,"
        " pain_chance, attack_range, xdeath_frame, mass, counts_kill, name, height, floats, skull_fly,"
        " missile_type, missile_speed, missile_dice, hitscan_pellets, melee_mult, melee_sides,"
        " fast_on_nightmare, attack_sound, explodes, drops_thing_type, blast_radius, hitscan_mult,"
        " hitscan_sides, charge_mult, charge_sides, fuzzy")
spec("thing_combat_defs", _TCD, _TCD.replace("missile_type,", "missile_type::text,"), map_filter=False)
spec("thing_ai_frames", "thing_type, state, seq_index, frame, tics, fullbright, is_attack_frame",
     "thing_type, state::text, seq_index, frame, tics, fullbright, is_attack_frame", map_filter=False)
spec("effect_sprite_defs", "effect_type, sprite, frame_sequence, tics_per_frame, fullbright",
     "effect_type::text, sprite, frame_sequence, tics_per_frame, fullbright", map_filter=False)
_PD = ("projectile_type, name, radius, speed, dmg_dice_mult, dmg_random_id, explode_tics, fly_timeout,"
       " blast_radius, spray_at_tic, spray_rays, spray_arc_degrees, spray_range, spray_dice,"
       " spray_random_base, fly_sprite, impact_sprite, dmg_dice_count")
spec("projectile_defs", _PD, _PD.replace("projectile_type,", "projectile_type::text,", 1), map_filter=False)
_WD = ("weapon_id, name, slot, ammo_type, ammo_per_shot, sprite, flash_sprite, pellet_count, max_range,"
       " dmg_dice_count, dmg_dice_mult, projectile_type, idle_loop_sound")
spec("weapon_defs", _WD, _WD.replace("ammo_type,", "ammo_type::text,").replace(
    "projectile_type,", "projectile_type::text,"), map_filter=False)
spec("weapon_frames", "weapon_id, state, seq_index, frame, tics, fullbright, is_attack_frame, refire_check",
     "weapon_id, state::text, seq_index, frame, tics, fullbright, is_attack_frame, refire_check",
     map_filter=False)
spec("ammo_defs", "ammo_type, cap, backpack_cap, backpack_gives",
     "ammo_type::text, cap, backpack_cap, backpack_gives", map_filter=False)
_LSD = ("special, name, mechanic, cross_activated, cross_once, monster_crossable, use_activated, use_once,"
        " key_required, is_exit, secret_exit, door_target, height_target, change_tex, flips_switch,"
        " shoot_activated, monster_usable, scrolls, target_light, mover_type, direction, step_height,"
        " crush, light_source, stops_mover, speed, wait_tics")
_LSD_PG = _LSD
for c in ("mechanic", "key_required", "door_target", "height_target", "mover_type", "light_source",
          "stops_mover"):
    _LSD_PG = _LSD_PG.replace(f" {c},", f" {c}::text,")
spec("line_special_defs", _LSD, _LSD_PG, map_filter=False)

STATE_TABLES = ("sectors", "things", "render_things", "player_state", "player_weapons",
                "player_weapon_owned", "monster_ai", "thing_health", "world_effects",
                "monster_projectiles", "picked_up_items", "sector_light_fx", "mp_players")


# ------------------------------------------------------------------ normalise
def norm(v):
    if v is None or isinstance(v, (bool, str, bytes)):
        return v
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(v) if v.is_integer() and abs(v) < 2 ** 53 else v
    if isinstance(v, decimal.Decimal):
        return int(v) if v == v.to_integral_value() else float(v)
    if isinstance(v, (memoryview, bytearray)):
        return bytes(v)
    if isinstance(v, dt.datetime):
        return v.astimezone(dt.timezone.utc).isoformat() if v.tzinfo else v.isoformat()
    return v


def _sk(row):
    out = []
    for v in row:
        if v is None:
            out.append((0, 0, b""))
        elif isinstance(v, bool):
            out.append((1, int(v), b""))
        elif isinstance(v, (int, float)):
            out.append((1, float(v), b""))
        elif isinstance(v, str):
            out.append((2, 0, v.encode()))
        else:
            out.append((3, 0, bytes(v)))
    return tuple(out)


def same(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b or (a == b and type(a) is type(b))
    if isinstance(a, float) or isinstance(b, float):
        if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
            return False
        return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-12)
    return a == b


def digest(rows):
    h = hashlib.sha256()
    for r in rows:
        h.update(repr(tuple(("%.9g" % v) if isinstance(v, float) else v for v in r)).encode())
    return h.hexdigest()[:12]


def compare(ora_rows, ref_rows):
    a = sorted((tuple(norm(v) for v in r) for r in ora_rows), key=_sk)
    b = sorted((tuple(norm(v) for v in r) for r in ref_rows), key=_sk)
    bad, first = 0, None
    if len(a) == len(b):
        for x, y in zip(a, b):
            if len(x) != len(y) or not all(same(p, q) for p, q in zip(x, y)):
                bad += 1
                if first is None:
                    first = (x, y)
    ok = len(a) == len(b) and bad == 0
    return ok, len(a), len(b), digest(a), digest(b), bad, first


def short(row):
    return tuple(("<%d bytes>" % len(v)) if isinstance(v, bytes) else v for v in row)


# ---------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="e1m1")
    ap.add_argument("--pg", default=PG_DSN)
    ap.add_argument("--skip-state", action="store_true")
    args = ap.parse_args()

    ora = oradb.connect()
    ocur = ora.cursor()
    ocur.arraysize = 20000
    pg = psycopg2.connect(args.pg)
    pg.set_session(isolation_level="REPEATABLE READ", readonly=True)
    pcur = pg.cursor()

    results = []
    print(f"{'table':32} {'oracle':>9} {'cedar':>9}  {'ora sha':12} {'ref sha':12} result")
    for name, s in T.items():
        table = s.get("table", name)
        where = s.get("oracle_where") or (MAPS if s["map_filter"] else None)
        ocur.execute(f"SELECT {s['cols']} FROM {table}" + (f" WHERE {where}" if where else ""))
        orows = ocur.fetchall()
        frm = s["cedar_from"] or (table + (f" WHERE {MAPS}" if s["map_filter"] else ""))
        pcur.execute(f"SELECT {s['cedar_cols']} FROM {frm}")
        prows = pcur.fetchall()
        ok, na, nb, ha, hb, bad, first = compare(orows, prows)
        results.append((name, ok))
        print(f"{name:32} {na:9d} {nb:9d}  {ha:12} {hb:12} {'PASS' if ok else 'FAIL'}"
              + ("" if ok else f"  ({bad} differing rows)"))
        if first:
            print("    oracle:", short(first[0]))
            print("    cedar :", short(first[1]))
    pg.rollback()

    if not args.skip_state:
        state_dir = Path(__file__).resolve().parents[1] / "reference_data" / args.run / "state"
        print(f"\nstate tables vs {state_dir}")
        print(f"{'table':32} {'oracle':>9} {'parquet':>9}  {'ora sha':12} {'pq sha':12} result")
        for t in STATE_TABLES:
            tab = pq.read_table(state_dir / f"{t}.parquet")
            cols = tab.column_names
            prow = list(zip(*[tab.column(c).to_pylist() for c in cols])) if tab.num_rows else []
            ocur.execute(f"SELECT {', '.join(cols)} FROM st_{t}")
            orows = ocur.fetchall()
            ok, na, nb, ha, hb, bad, first = compare(orows, prow)
            results.append(("st_" + t, ok))
            print(f"{'st_' + t:32} {na:9d} {nb:9d}  {ha:12} {hb:12} {'PASS' if ok else 'FAIL'}"
                  + ("" if ok else f"  ({bad} differing rows)"))
            if first:
                print("    oracle :", short(first[0]))
                print("    parquet:", short(first[1]))

    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} PASS" + (f"; FAIL: {', '.join(failed)}" if failed else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
