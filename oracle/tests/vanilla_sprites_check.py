#!/usr/bin/env python3
"""Vanilla sprite clipping vs the CedarDB-exact renderer, frame by frame.

doom_hybrid.render_frame(..., p_mode) renders sprites either exactly as CedarDB SQLDoom does
(p_mode 0: one z-buffer over walls, planes and sprites, so the rows of a sprite below its floor line
lose against the floor in front of it) or as vanilla Doom does (p_mode 1: planes never occlude
sprites; a sprite column is clipped by the silhouettes of the segs in front of it, R_DrawSprite).
This tool renders chosen frames in both modes (and in the debug mode 2 = mode 1 without the
silhouette clip) and checks, per frame, with the renderer's own z-buffer (doom_hybrid.debug_info):

  * every pixel that differs between the modes is a sprite pixel in vanilla mode that was a floor
    or ceiling pixel in exact mode -- no wall pixel, no status-bar pixel changes, no sprite pixel is
    lost, no new sprite pixel appears over a wall;
  * the plane a new sprite pixel covers is one vanilla Doom draws the sprite over: a floor no higher
    than the sprite's foot z (gz), or a ceiling no lower than the ceiling of the sprite's sector. A
    nearer, higher floor (a ledge in front of a sprite on a lower floor) or a lower ceiling edge is
    a silhouette vanilla clips by; a sprite pixel over one would be a violation;
  * "ledge-clipped" pixels: drawn by mode 2 (sprites over every plane) but clipped in mode 1 -- the
    silhouette clip at work (a sprite behind a higher floor edge); none of them may be a sprite pixel
    in exact mode either.

PNGs (exact | vanilla | diff) go to tests/out/vanilla/: in the diff panel the vanilla frame is
greyed, pixels vanilla adds are magenta and ledge-clipped pixels (mode 2 would draw them) cyan.

    vanilla_sprites_check.py                          # recorded TPC-DOOM E1M1 run (Freedoom), every 10th tic
    vanilla_sprites_check.py --tics 300,577 --png 300,577
    vanilla_sprites_check.py --step 5 --png-top 4     # PNGs of the 4 frames with most added pixels
                                                       # and of the 2 with most ledge-clipped pixels
    vanilla_sprites_check.py --live E1M1 --pose x,y,z,angle [--pose ...] --png-all --wad oracle/wad/doom1.wad
    vanilla_sprites_check.py --live E1M1 --near-things 2035,2014,2015 --png-top 2  # poses facing those things

--live renders the live game state (doom_hybrid_live, after a level start) at the given poses; the
other modes the recorded state (st_* tables, doom_hybrid) at the recorded poses.
"""
import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client"))
import doomora  # noqa: E402
import render as render_mod  # noqa: E402

OUT = HERE / "out" / "vanilla"
VIEW_H = 168
SQL = ("SELECT y, pal, hex FROM TABLE({pkg}.render_frame(:tic, :map_id, :player_id, :skill, :px, :py, :pz, :pangle, "
       "0, 319, :smode))")


class Renderer:
    def __init__(self, conn, pkg, map_id, player, skill):
        self.cur = conn.cursor()
        self.cur.arraysize = 8000
        self.cur.prefetchrows = 8001
        self.pkg, self.map_id, self.player, self.skill = pkg, map_id, player, skill
        self.sql = SQL.format(pkg=pkg)

    def frame(self, tic, pose, mode):
        x, y, z, a = pose
        self.cur.execute(self.sql, tic=tic, map_id=self.map_id, player_id=self.player, skill=self.skill,
                         px=float(x), py=float(y), pz=float(z), pangle=float(a), smode=mode)
        return doomora.decode_hexrows(self.cur.fetchall())

    def debug(self, what):
        self.cur.execute(f"SELECT y, pal, hex FROM TABLE({self.pkg}.debug_info(:w))", w=what)
        return self.cur.fetchall()

    def zbuf(self):
        """(class, stable, vanilla-sprite flag) arrays [168, 320] of the last frame."""
        cls = np.full((VIEW_H, 320), -1, np.int32)
        stb = np.zeros((VIEW_H, 320), np.int32)
        van = np.zeros((VIEW_H, 320), np.int8)
        for y, x, h in self.debug("zbuf"):
            c, s, _d, v = h.split(",")
            cls[int(y), int(x)], stb[int(y), int(x)], van[int(y), int(x)] = int(float(c)), int(float(s)), int(float(v))
        return cls, stb, van

    def sprites(self):
        out = {}
        for _i, st, h in self.debug("sprites"):
            gz, gzt, sec, d = h.split(",")
            out.setdefault(int(st), []).append((float(gz), float(gzt), int(sec) if sec else None, float(d)))
        return out

    def sectors(self):
        return {int(i): tuple(float(v) for v in h.split(",")) for i, _p, h in self.debug("sectors")}   # floor, ceil, sky


def is_sprite(c):
    return (c >= 4) & (c <= 7)


def is_plane(c):
    return c >= 8


def ray_sectors(r, pose, x, d0, d1, step=2.0):
    """Sectors along screen column x's ray (top view) from depth d0 to d1: [(depth, sector)]."""
    px, py, _pz, ang = pose
    cv, sv = math.cos(math.radians(ang)), math.sin(math.radians(ang))
    ta = (x - 160) / 160.0
    step = max(step, (d1 - d0) / 150.0)       # at most ~150 samples (the JSON bind stays small)
    ds = [d0 + k * step for k in range(int((d1 - d0) / step) + 1)] + [d1]
    pts = [[i, px + d * (cv + ta * sv), py + d * (sv - ta * cv)] for i, d in enumerate(ds)]
    r.cur.execute("SELECT doom_game.sector_at(:m, jt.x, jt.y) FROM JSON_TABLE(:j, '$[*]' COLUMNS ("
                  "i NUMBER PATH '$[0]', x NUMBER PATH '$[1]', y NUMBER PATH '$[2]')) jt ORDER BY jt.i",
                  m=r.map_id, j=json.dumps(pts))
    return [(d, row[0]) for d, row in zip(ds, r.cur.fetchall())]


def vanilla_clips(r, pose, secs, x, y, ceil, plane_h, gz, gzt, dsp, cache):
    """Would vanilla Doom clip sprite pixel (x, y) here? Independent of the renderer: walk the column's
    ray over the map from the plane point the exact frame shows (depth from its height and row) to the
    sprite's depth; vanilla clips the pixel when the walk crosses a step down of the floor (a ledge:
    front floor F > back floor, the sprite's gz below F) whose edge row is above the pixel, or a step
    up of the ceiling (front ceiling C < back ceiling, gzt above C) whose edge row is below it."""
    pz = pose[2]
    if 84 - y == 0:
        return False
    dp = 160.0 * (plane_h - pz) / (84 - y)
    if not (0 < dp < dsp):
        return False
    key = (x, round(dsp, 3))
    if key not in cache:
        cache[key] = ray_sectors(r, pose, x, 0.5, dsp)
    prev = None
    for d, sec in cache[key]:
        if d < dp - 2.0 or sec is None or sec not in secs:
            prev = None if d < dp - 2.0 else prev
            continue
        if prev is not None and sec != prev:
            fa, ca = secs[prev][:2]
            fb, cb = secs[sec][:2]
            if not ceil and fa > fb and gz < fa and y > 84 + 160.0 * (pz - fa) / d:
                return True
            if ceil and ca < cb and gzt > ca and y < 84 - 160.0 * (ca - pz) / d:
                return True
        prev = sec
    return False


def check_frame(r, tic, pose):
    """Render one pose in the three modes; returns (result dict, frames, masks)."""
    fe, pal_e = r.frame(tic, pose, 0)
    ze = r.zbuf()
    fv, pal_v = r.frame(tic, pose, 1)
    zv = r.zbuf()
    spr = r.sprites()
    secs = r.sectors()
    f2, _ = r.frame(tic, pose, 2)
    z2 = r.zbuf()
    res = {"tic": tic, "pose": list(pose), "pal_equal": pal_e == pal_v}
    diff = fe != fv
    res["hud_diff"] = int(diff[VIEW_H:].sum())
    d = diff[:VIEW_H]
    ce, se, _ = ze
    cv, sv, vv = zv
    c2 = z2[0]
    res["diff"] = int(d.sum())
    added = d & is_sprite(cv) & (vv == 1) & is_plane(ce)
    res["added"] = int(added.sum())
    res["other_diff"] = None   # set below
    # classes of every pixel: walls identical, exact sprites kept
    res["wall_changed"] = int(((ce <= 3) & (ce >= 0) & (cv != ce)).sum() + ((cv <= 3) & (cv >= 0) & (ce != cv)).sum())
    lost = is_sprite(ce) & ~is_sprite(cv)
    # The one place vanilla legitimately removes a sprite pixel the exact frame shows: the reference
    # gives a sky ceiling the farthest depth, so a sprite poking above a nearer sky ceiling edge wins
    # the z-test there, while Doom clips it by that edge's silhouette (SIL_TOP). Counted apart.
    sky_px = np.zeros_like(lost)
    for y, x in zip(*np.nonzero(lost & is_plane(cv))):
        ps = int(sv[y, x]) - 32768
        if ps % 2 == 1 and secs.get(ps // 2, (0, 0, 0))[2] == 1:
            sky_px[y, x] = True
    res["sky_edge_clipped"] = int(sky_px.sum())
    res["sprite_lost"] = int((lost & ~sky_px).sum())
    res["sprite_changed"] = int((is_sprite(ce) & is_sprite(cv) & (se != sv)).sum())
    # the plane under every added pixel: a floor not above the sprite's gz, or a ceiling not below
    # the ceiling of the sprite's own sector
    viol = []
    unusual = 0     # over a plane the simple rule does not explain, but vanilla does not clip there either
    cache = {}
    ys, xs = np.nonzero(added)
    for y, x in zip(ys.tolist(), xs.tolist()):
        ps = int(se[y, x]) - 32768
        sec, ceil = ps // 2, ps % 2
        if sec not in secs:
            viol.append((y, x, "unknown plane sector", sec))
            continue
        cands = spr.get(int(sv[y, x]), [])
        ok = False
        for gz, gzt, ssec, _dd in cands:
            if ceil == 0:
                ok = ok or secs[sec][0] <= gz + 1e-6
            else:
                own = secs.get(ssec, (None, -1e18))[1] if ssec is not None else -1e18
                ok = ok or secs[sec][1] >= own - 1e-6
        if not ok and not any(vanilla_clips(r, pose, secs, x, y, ceil, secs[sec][ceil], gz, gzt, dd, cache)
                              for gz, gzt, _ss, dd in cands):
            unusual += 1
            ok = True
        if not ok:
            viol.append((y, x, "ceiling" if ceil else "floor", sec, secs[sec],
                         [(gz, gzt, ssec, secs.get(ssec)) for gz, gzt, ssec, _ in cands][:2]))
    res["rule_violations"] = len(viol)
    res["over_other_planes"] = unusual
    res["violation_samples"] = [list(map(str, v)) for v in viol[:5]]
    ledge = is_sprite(c2) & ~is_sprite(cv)
    res["ledge_clipped"] = int(ledge.sum())
    res["ledge_clipped_exact_sprite"] = int((ledge & is_sprite(ce) & ~sky_px).sum())
    res["sprites_added_by"] = sorted({int(s) - 32768 for s in sv[added].tolist()})
    res["other_diff"] = int((d & ~added & ~sky_px).sum())
    res["ok"] = (res["hud_diff"] == 0 and res["other_diff"] == 0 and res["wall_changed"] == 0
                 and res["sprite_lost"] == 0 and res["rule_violations"] == 0 and res["ledge_clipped_exact_sprite"] == 0
                 and res["pal_equal"])
    return res, (fe, fv, pal_e), (added, ledge)


def save_png(path, pals, fe, fv, pal, added, ledge, title):
    rgb_e, rgb_v = pals[pal][fe], pals[pal][fv]
    grey = rgb_v.mean(axis=2, keepdims=True).astype(np.uint8).repeat(3, axis=2) // 2
    dif = grey.copy()
    dif[:VIEW_H][ledge] = (0, 230, 230)
    dif[:VIEW_H][added] = (255, 0, 255)
    gap = np.zeros((200, 4, 3), np.uint8)
    img = Image.fromarray(np.concatenate([rgb_e, gap, rgb_v, gap, dif], axis=1))
    img = img.resize((img.width * 2, img.height * 2), Image.NEAREST)
    canvas = Image.new("RGB", (img.width, img.height + 18), (0, 0, 0))
    canvas.paste(img, (0, 18))
    ImageDraw.Draw(canvas).text((4, 3), title, fill=(255, 255, 255))
    canvas.save(path)


def live_setup(conn, map_name, skill):
    sys.path.insert(0, str(HERE.parent / "client"))
    import game_api
    cur = conn.cursor()
    game_api.setup_session(cur)
    cur.execute(game_api.STAGES_SQL)
    stage = {n: (m, p) for m, n, p in cur.fetchall()}
    m, p = stage[map_name.upper()]
    game_api.level_start(cur, m, p, skill)
    return m, p


def poses_near_things(conn, map_id, types, dists=(128,), dirs=8, eye=41):
    """Camera poses facing each thing of the given types: from points around it (in a sector, on
    that sector's floor + eye), looking at it."""
    cur = conn.cursor()
    cur.execute("SELECT t.id, t.type, t.x, t.y FROM g_things t WHERE t.map_id = :m AND t.type IN ("
                + ",".join(str(int(t)) for t in types) + ") ORDER BY t.id", m=map_id)
    things = cur.fetchall()
    # one-sided lines (and two-sided ones closed to the eye): a camera must see the thing over open
    # space, never from the void outside the map (where the BSP still names a sector)
    cur.execute("""SELECT l.x1, l.y1, l.x2, l.y2 FROM linedef_geom l
                     LEFT JOIN g_sectors f ON f.map_id = l.map_id AND f.id = l.fsec
                     LEFT JOIN g_sectors b ON b.map_id = l.map_id AND b.id = l.bsec
                    WHERE l.map_id = :m AND (l.bsec IS NULL OR l.fsec IS NULL
                          OR LEAST(f.ceil_height, b.ceil_height) - GREATEST(f.floor_height, b.floor_height) < 56)""", m=map_id)
    walls = np.array(cur.fetchall(), float).reshape(-1, 4)

    def blocked(ax, ay, bx, by):
        x1, y1, x2, y2 = walls.T
        d1 = (x2 - x1) * (ay - y1) - (y2 - y1) * (ax - x1)
        d2 = (x2 - x1) * (by - y1) - (y2 - y1) * (bx - x1)
        d3 = (bx - ax) * (y1 - ay) - (by - ay) * (x1 - ax)
        d4 = (bx - ax) * (y2 - ay) - (by - ay) * (x2 - ax)
        return bool(np.any((d1 * d2 < 0) & (d3 * d4 < 0)))

    cur.execute("SELECT fsec, bsec, x1, y1, x2, y2 FROM linedef_geom WHERE map_id = :m", m=map_id)
    lines = [(f, b, float(x1), float(y1), float(x2), float(y2)) for f, b, x1, y1, x2, y2 in cur.fetchall()]

    def inside(sec, px_, py_):
        """Point-in-polygon over the sector's boundary lines (sector_at follows the BSP, which also
        answers for points in the void outside the map)."""
        n = 0
        for f, b, x1, y1, x2, y2 in lines:
            if (f == sec) == (b == sec):
                continue
            if (y1 > py_) != (y2 > py_) and px_ < x1 + (py_ - y1) * (x2 - x1) / (y2 - y1):
                n += 1
        return n % 2 == 1

    out = []
    for tid, typ, tx, ty in things:
        for dist in dists:
            for k in range(dirs):
                ang = 2 * math.pi * k / dirs
                cx, cy = float(tx) + dist * math.cos(ang), float(ty) + dist * math.sin(ang)
                cur.execute("SELECT doom_game.sector_at(:m, :x, :y) FROM dual", m=map_id, x=cx, y=cy)
                sec = cur.fetchone()[0]
                if sec is None:
                    continue
                cur.execute("SELECT floor_height, ceil_height FROM g_sectors WHERE map_id = :m AND id = :s",
                            m=map_id, s=sec)
                row = cur.fetchone()
                if not row or row[1] - row[0] < eye + 8:
                    continue
                if blocked(cx, cy, float(tx), float(ty)) or not inside(sec, cx, cy):
                    continue
                face = math.degrees(math.atan2(float(ty) - cy, float(tx) - cx)) % 360
                out.append(((round(cx, 3), round(cy, 3), float(row[0]) + eye, round(face, 3)), int(tid), int(typ)))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--tics", help="comma-separated recorded tics (default: every --step-th)")
    ap.add_argument("--step", type=int, default=10)
    ap.add_argument("--png", default="", help="tics (recorded) or pose indexes (--live) to write PNGs of")
    ap.add_argument("--png-top", type=int, default=0, help="PNGs of the N frames with most added pixels "
                                                          "(+ N/2 with most ledge-clipped pixels)")
    ap.add_argument("--png-all", action="store_true")
    ap.add_argument("--live", metavar="MAP", help="live state after a level start on MAP (doom_hybrid_live)")
    ap.add_argument("--pose", action="append", default=[], help="--live: x,y,z,angle (repeatable)")
    ap.add_argument("--near-things", help="--live: comma-separated thing types; poses facing each of them")
    ap.add_argument("--max-poses", type=int, default=60, help="--near-things: at most this many poses")
    ap.add_argument("--skill", type=int, default=2)
    ap.add_argument("--wad", default=str(HERE.parent / "wad" / "freedoom1.wad"), help="PLAYPAL source for PNGs")
    ap.add_argument("--label", default=None)
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    conn = doomora.connect()
    pals = render_mod.playpals(a.wad)
    items = []   # (key, tic, pose, note)
    if a.live:
        map_id, player = live_setup(conn, a.live, a.skill)
        r = Renderer(conn, "doom_hybrid_live", map_id, player, a.skill)
        for i, p in enumerate(a.pose):
            items.append((f"{a.live.lower()}_p{i}", -1, tuple(float(v) for v in p.split(",")), "pose"))
        if a.near_things:
            near = poses_near_things(conn, map_id, [int(t) for t in a.near_things.split(",")])
            for i, (pose, tid, typ) in enumerate(near[:a.max_poses]):
                items.append((f"{a.live.lower()}_t{tid}_{i}", -1, pose, f"thing {tid} type {typ}"))
    else:
        r = Renderer(conn, "doom_hybrid", 1, 157, 2)
        poses = doomora.load_poses()
        tics = [int(t) for t in a.tics.split(",")] if a.tics else list(range(1, 1201, a.step))
        for t in tics:
            items.append((f"tic{t:04d}", t, poses[t], "recorded"))
    label = a.label or (f"live_{a.live.lower()}" if a.live else "recorded")
    results, keep = [], {}
    want_png = {s.strip() for s in a.png.split(",") if s.strip()}
    for key, tic, pose, note in items:
        res, frames, masks = check_frame(r, tic, pose)
        res["key"], res["note"] = key, note
        results.append(res)
        flag = "ok" if res["ok"] else "FAIL"
        if res["diff"] or not res["ok"] or res["ledge_clipped"]:
            print(f"{key:>18s} {flag}: diff {res['diff']:5d} = added {res['added']:5d} + other {res['other_diff']}; "
                  f"ledge-clipped {res['ledge_clipped']:4d}; walls changed {res['wall_changed']}, sprites lost "
                  f"{res['sprite_lost']}, rule violations {res['rule_violations']}"
                  + (f"  {res['violation_samples'][:2]}" if res["rule_violations"] else ""), flush=True)
        tag = str(tic) if tic >= 0 else key.split("_p")[-1]
        if a.png_all or tag in want_png or key in want_png or a.png_top:
            keep[key] = (frames, masks, res)
            if a.png_top and not (a.png_all or tag in want_png or key in want_png):
                # keep only the current best candidates in memory
                top = sorted(keep, key=lambda k: -keep[k][2]["added"])[:a.png_top]
                ltop = sorted(keep, key=lambda k: -keep[k][2]["ledge_clipped"])[:max(1, a.png_top // 2)]
                for k in list(keep):
                    if k not in top and k not in ltop and k not in want_png and \
                            str(keep[k][2]["tic"]) not in want_png:
                        del keep[k]
    written = []
    for key, ((fe, fv, pal), (added, ledge), res) in keep.items():
        if not (a.png_all or key in want_png or str(res["tic"]) in want_png or a.png_top):
            continue
        path = OUT / f"{label}_{key}.png"
        title = (f"{key}  exact | vanilla | diff: +{res['added']} sprite px over planes (magenta), "
                 f"{res['ledge_clipped']} px clipped by seg silhouettes (cyan)")
        save_png(path, pals, fe, fv, pal, added, ledge, title)
        written.append(str(path))
    n = len(results)
    summ = {"label": label, "frames": n, "ok": sum(r_["ok"] for r_ in results),
            "frames_differing": sum(1 for r_ in results if r_["diff"]),
            "added_px": sum(r_["added"] for r_ in results), "other_diff_px": sum(r_["other_diff"] for r_ in results),
            "wall_changed_px": sum(r_["wall_changed"] for r_ in results),
            "sprite_lost_px": sum(r_["sprite_lost"] for r_ in results),
            "sky_edge_clipped_px": sum(r_["sky_edge_clipped"] for r_ in results),
            "rule_violations": sum(r_["rule_violations"] for r_ in results),
            "ledge_clipped_px": sum(r_["ledge_clipped"] for r_ in results),
            "frames_with_ledge_clip": sum(1 for r_ in results if r_["ledge_clipped"]),
            "hud_diff_px": sum(r_["hud_diff"] for r_ in results), "pngs": written}
    print(json.dumps(summ, indent=1))
    (a.json or OUT / f"{label}.json").write_text(json.dumps({"summary": summ, "frames": results}, indent=1))
    print("VANILLA SPRITES OK" if summ["ok"] == n else "VANILLA SPRITES: FAILURES")
    return 0 if summ["ok"] == n else 1


if __name__ == "__main__":
    sys.exit(main())
