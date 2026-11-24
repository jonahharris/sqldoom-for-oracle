"""Gameplay scenarios: scripted runs that exercise the branches of the game tic the
TPC-DOOM E1M1 run never reaches (movers of every kind, crushers, stairs, donuts, lights,
teleports, switches, exits, damaging floors, other monsters, weapons, nightmare ...).

A scenario is
  * a map and a skill, the cheats typed after the level start (god mode off where the
    scenario needs damage),
  * optional MAP MODS applied to the static map before the level start on BOTH databases
    and reverted afterwards: a linedef's special/tag (so a special family that E1M1-E1M3
    do not contain runs on a real line and real tagged sectors), a sector's special/tag,
    a thing's type,
  * OPS between tics: put the player at a pose (the reference's own doom_spawn_player
    then derives sector, heights and the Thing), or in front of / behind a line,
  * the command stream.

Scenarios are written with the helpers below; `resolve()` turns every geometric helper
into explicit numbers using the map geometry (read from CedarDB when recording), and the
recording stores the resolved plan (run.json), so the Oracle replay uses exactly the same
numbers. The same mods and ops are applied on each database by `CedarSide` / `OracleSide`.
"""
import math

SCENARIOS = {}


class Scn:
    def __init__(self, name, map_name, skill=2, cheats=("IDDQD", "IDKFA"), covers=(), note=""):
        self.name, self.map_name, self.skill, self.cheats = name, map_name, skill, list(cheats)
        self.covers, self.note = list(covers), note
        self.mods, self.ops, self.cmds = [], {}, []
        self.frame_every = 0          # > 0: also record/compare the player's frame every N tics
        SCENARIOS[name] = self

    def frames(self, every):
        self.frame_every = every
        return self

    # ---- map mods (before the level start, reverted after the run)
    def line(self, line_id, special, tag=None):
        self.mods.append({"kind": "line", "id": line_id, "special": special, "tag": tag})
        return self

    def sector(self, sector_id, special=None, tag=None):
        self.mods.append({"kind": "sector", "id": sector_id, "special": special, "tag": tag})
        return self

    def thing(self, thing_id, type_):
        self.mods.append({"kind": "thing", "id": thing_id, "type": type_})
        return self

    # ---- ops (before the next command; tic 0 = right after the level start)
    def _op(self, op):
        self.ops.setdefault(len(self.cmds), []).append(op)
        return self

    def pose(self, x, y, angle):
        return self._op({"op": "pose", "x": x, "y": y, "angle": angle})

    def at_line(self, line_id, dist=24.0, back=False, along=0.5):
        """Stand `dist` units in front of the line (its right side; `back` = left side),
        at fraction `along` of its length, facing it."""
        return self._op({"op": "at_line", "line": line_id, "dist": dist, "back": back, "along": along})

    def in_sector(self, sector_id, angle=90):
        return self._op({"op": "in_sector", "sector": sector_id, "angle": angle})

    def set_player(self, **cols):
        """Set player_state columns (e.g. health=20, armor=0) -- the same UPDATE on both."""
        return self._op({"op": "player", "cols": cols})

    # ---- commands
    def cmd(self, n=1, fwd=0.0, strafe=0.0, run=False, turn=0.0, atk=False, sw=None, use=False):
        for _ in range(n):
            self.cmds.append([self.skill, float(fwd), float(strafe), bool(run), float(turn), bool(atk), sw,
                              bool(use)])
        return self

    def idle(self, n):
        return self.cmd(n)

    def use(self, n=1):
        self.cmd(n, use=True)
        return self

    def walk(self, n, fwd=1.0, run=False):
        return self.cmd(n, fwd=fwd, run=run)

    def fire(self, n, sw=None):
        if sw is not None:
            self.cmd(1, sw=sw)
        return self.cmd(n, atk=True)

    def switch(self, weapon, wait=30):
        self.cmd(1, sw=weapon)
        return self.idle(wait)


# ----------------------------------------------------------------- resolution
def line_pose(geo, line_id, dist, back, along):
    x1, y1, x2, y2 = geo["lines"][line_id]
    dx, dy = x2 - x1, y2 - y1
    ln = math.hypot(dx, dy)
    nx, ny = dy / ln, -dx / ln            # right (front) side normal
    if back:
        nx, ny = -nx, -ny
    mx, my = x1 + dx * along, y1 + dy * along
    px, py = mx + nx * dist, my + ny * dist
    ang = math.degrees(math.atan2(-ny, -nx)) % 360.0
    return round(px), round(py), round(ang)


def sector_point(geo, sector_id, inside):
    """A point well inside the sector: on an 8-unit grid over the sector's bounding box,
    the point inside it (BSP test `inside(x, y)`) farthest from the sector's lines."""
    segs = geo["sector_lines"][sector_id]
    xs = [p for s in segs for p in (s[0], s[2])]
    ys = [p for s in segs for p in (s[1], s[3])]
    best, bd = None, -1.0
    for x in range(int(min(xs)) + 8, int(max(xs)) - 7, 8):
        for y in range(int(min(ys)) + 8, int(max(ys)) - 7, 8):
            d = min(seg_dist(x, y, *s) for s in segs)
            if d > bd and inside(x, y) == sector_id:
                best, bd = (x, y), d
    if best is None:
        raise RuntimeError(f"no interior point for sector {sector_id}")
    return best


def seg_dist(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy or 1)))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))


def resolve(scn, geo, inside):
    ops = {}
    for tic, lst in scn.ops.items():
        out = []
        for op in lst:
            if op["op"] == "at_line":
                x, y, a = line_pose(geo, op["line"], op["dist"], op["back"], op["along"])
                out.append({"op": "pose", "x": x, "y": y, "angle": a})
            elif op["op"] == "in_sector":
                x, y = sector_point(geo, op["sector"], inside)
                out.append({"op": "pose", "x": x, "y": y, "angle": op["angle"]})
            else:
                out.append(op)
        ops[str(tic)] = out
    return ops


CEDAR_GEO_SQL = """
SELECT l.id, v1.x, v1.y, v2.x, v2.y, r.sector_id, lf.sector_id
  FROM linedefs l
  JOIN vertexes v1 ON v1.map_id = l.map_id AND v1.id = l.v1_id
  JOIN vertexes v2 ON v2.map_id = l.map_id AND v2.id = l.v2_id
  LEFT JOIN sidedefs r ON r.map_id = l.map_id AND r.id = l.right_sd_id
  LEFT JOIN sidedefs lf ON lf.map_id = l.map_id AND lf.id = l.left_sd_id
 WHERE l.map_id = %s"""


def cedar_geometry(cur, map_id):
    cur.execute(CEDAR_GEO_SQL, (map_id,))
    geo = {"lines": {}, "sector_lines": {}}
    for lid, x1, y1, x2, y2, fs, bs in cur.fetchall():
        geo["lines"][lid] = (float(x1), float(y1), float(x2), float(y2))
        for s in (fs, bs):
            if s is not None:
                geo["sector_lines"].setdefault(s, []).append((float(x1), float(y1), float(x2), float(y2)))
    return geo


# ----------------------------------------------------------------- per-database sides
class CedarSide:
    """Mods and ops on CedarDB (psycopg2 cursor, autocommit)."""

    def __init__(self, cur, map_id, player):
        self.cur, self.map_id, self.player, self.undo = cur, map_id, player, []

    def apply_mods(self, mods):
        cur, m = self.cur, self.map_id
        for mod in mods:
            if mod["kind"] == "line":
                cur.execute("SELECT special, tag FROM linedefs WHERE map_id=%s AND id=%s", (m, mod["id"]))
                sp, tg = cur.fetchone()
                self.undo.append(("line", mod["id"], sp, tg))
                self._set_line(mod["id"], mod["special"], tg if mod["tag"] is None else mod["tag"])
            elif mod["kind"] == "sector":
                cur.execute("SELECT special, tag FROM sectors WHERE map_id=%s AND id=%s", (m, mod["id"]))
                sp, tg = cur.fetchone()
                self.undo.append(("sector", mod["id"], sp, tg))
                cur.execute("UPDATE sectors SET special=%s, tag=%s WHERE map_id=%s AND id=%s",
                            (sp if mod["special"] is None else mod["special"],
                             tg if mod["tag"] is None else mod["tag"], m, mod["id"]))
            elif mod["kind"] == "thing":
                cur.execute("SELECT type, z FROM things WHERE map_id=%s AND id=%s", (m, mod["id"]))
                tp, z = cur.fetchone()
                # CedarDB's level start does not reset z (a floater's height): keep it to restore
                self.undo.append(("thing", mod["id"], tp, z))
                cur.execute("UPDATE things SET type=%s WHERE map_id=%s AND id=%s", (mod["type"], m, mod["id"]))
        if any(mod["kind"] == "line" for mod in mods):
            # linedef_geom is a materialized view over linedefs (special): cs_use and the monster
            # stages read it, so it must see the crafted special too
            cur.execute("REFRESH MATERIALIZED VIEW linedef_geom")

    def _set_line(self, lid, special, tag):
        self.cur.execute("""
            UPDATE linedefs ld SET special=%s, tag=%s,
                   cross_activated = COALESCE((SELECT d.cross_activated FROM line_special_defs d WHERE d.special=%s), FALSE),
                   cross_once = COALESCE((SELECT d.cross_once FROM line_special_defs d WHERE d.special=%s), FALSE),
                   monster_crossable = COALESCE((SELECT d.monster_crossable FROM line_special_defs d WHERE d.special=%s), FALSE),
                   scrolls = COALESCE((SELECT d.scrolls FROM line_special_defs d WHERE d.special=%s), FALSE)
             WHERE map_id=%s AND id=%s""", (special, tag, special, special, special, special, self.map_id, lid))

    def revert(self):
        cur, m = self.cur, self.map_id
        for kind, i, a, b in reversed(self.undo):
            if kind == "line":
                self._set_line(i, a, b)
            elif kind == "sector":
                cur.execute("UPDATE sectors SET special=%s, tag=%s WHERE map_id=%s AND id=%s", (a, b, m, i))
            elif kind == "thing":
                cur.execute("UPDATE things SET type=%s, z=%s WHERE map_id=%s AND id=%s", (a, b, m, i))
        if any(u[0] == "line" for u in self.undo):
            cur.execute("REFRESH MATERIALIZED VIEW linedef_geom")
        self.undo = []

    def sector_at(self, x, y):
        self.cur.execute("SELECT doom_sector_at(%s, %s::float8, %s::float8)", (self.map_id, float(x), float(y)))
        return int(self.cur.fetchone()[0])

    def apply_op(self, op):
        cur, m, p = self.cur, self.map_id, self.player
        if op["op"] == "pose":
            cur.execute("UPDATE things SET x=%s, y=%s, angle=%s WHERE map_id=%s AND id=%s",
                        (float(op["x"]), float(op["y"]), float(op["angle"]), m, p))
            cur.execute("SELECT doom_spawn_player(%s, %s)", (m, p))
        elif op["op"] == "player":
            sets = ", ".join(f"{k}=%s" for k in op["cols"])
            cur.execute(f"UPDATE player_state SET {sets} WHERE map_id=%s AND player_thing_id=%s",
                        (*op["cols"].values(), m, p))
        elif op["op"] == "thing_health":
            cur.execute("UPDATE thing_health SET health=%s WHERE map_id=%s AND thing_id=%s",
                        (op["health"], m, op["thing"]))
        else:
            raise ValueError(op)


class OracleSide:
    """The same mods and ops on Oracle (oracledb cursor). Static map tables: linedefs and
    linedef_geom (special/tag), sectors (special/tag, copied into g_sectors by the level
    start), things (type). The session's doom_game cache is reset after the mods."""

    def __init__(self, cur, map_id, player):
        self.cur, self.map_id, self.player, self.undo = cur, map_id, player, []

    def apply_mods(self, mods):
        cur, m = self.cur, self.map_id
        for mod in mods:
            if mod["kind"] == "line":
                cur.execute("SELECT special, tag FROM linedefs WHERE map_id=:m AND id=:i", m=m, i=mod["id"])
                sp, tg = cur.fetchone()
                self.undo.append(("line", mod["id"], sp, tg))
                self._set_line(mod["id"], mod["special"], tg if mod["tag"] is None else mod["tag"])
            elif mod["kind"] == "sector":
                cur.execute("SELECT special, tag FROM sectors WHERE map_id=:m AND id=:i", m=m, i=mod["id"])
                sp, tg = cur.fetchone()
                self.undo.append(("sector", mod["id"], sp, tg))
                cur.execute("UPDATE sectors SET special=:s, tag=:t WHERE map_id=:m AND id=:i",
                            s=sp if mod["special"] is None else mod["special"],
                            t=tg if mod["tag"] is None else mod["tag"], m=m, i=mod["id"])
            elif mod["kind"] == "thing":
                cur.execute("SELECT type FROM things WHERE map_id=:m AND id=:i", m=m, i=mod["id"])
                (tp,) = cur.fetchone()
                self.undo.append(("thing", mod["id"], tp, None))
                cur.execute("UPDATE things SET type=:t WHERE map_id=:m AND id=:i", t=mod["type"], m=m, i=mod["id"])
        cur.connection.commit()
        cur.execute("BEGIN doom_game.reset_cache; END;")

    def _set_line(self, lid, special, tag):
        cur = self.cur
        cur.execute("""
            UPDATE linedefs ld SET special = :s, tag = :t,
                   cross_activated = NVL((SELECT d.cross_activated FROM line_special_defs d WHERE d.special = :s), FALSE),
                   cross_once = NVL((SELECT d.cross_once FROM line_special_defs d WHERE d.special = :s), FALSE),
                   monster_crossable = NVL((SELECT d.monster_crossable FROM line_special_defs d WHERE d.special = :s), FALSE),
                   scrolls = NVL((SELECT d.scrolls FROM line_special_defs d WHERE d.special = :s), FALSE)
             WHERE map_id = :m AND id = :i""", s=special, t=tag, m=self.map_id, i=lid)
        cur.execute("UPDATE linedef_geom SET special = :s WHERE map_id = :m AND linedef_id = :i",
                    s=special, m=self.map_id, i=lid)

    def revert(self):
        cur, m = self.cur, self.map_id
        for kind, i, a, b in reversed(self.undo):
            if kind == "line":
                self._set_line(i, a, b)
            elif kind == "sector":
                cur.execute("UPDATE sectors SET special=:s, tag=:t WHERE map_id=:m AND id=:i", s=a, t=b, m=m, i=i)
            elif kind == "thing":
                cur.execute("UPDATE things SET type=:t WHERE map_id=:m AND id=:i", t=a, m=m, i=i)
        cur.connection.commit()
        self.undo = []
        cur.execute("BEGIN doom_game.reset_cache; END;")

    def apply_op(self, op):
        cur, m, p = self.cur, self.map_id, self.player
        if op["op"] == "pose":
            cur.execute("UPDATE g_things SET x = :x, y = :y, angle = :a WHERE map_id = :m AND id = :p",
                        x=float(op["x"]), y=float(op["y"]), a=float(op["angle"]), m=m, p=p)
            cur.execute("BEGIN doom_game.spawn_player(:m, :p); END;", m=m, p=p)
        elif op["op"] == "player":
            sets = ", ".join(f"{k} = :{k}" for k in op["cols"])
            cur.execute(f"UPDATE g_player_state SET {sets} WHERE map_id = :mm AND player_thing_id = :pp",
                        mm=m, pp=p, **op["cols"])
        elif op["op"] == "thing_health":
            cur.execute("UPDATE g_thing_health SET health = :h WHERE map_id = :m AND thing_id = :t",
                        h=op["health"], m=m, t=op["thing"])
        else:
            raise ValueError(op)
        cur.connection.commit()


import scenario_defs  # noqa: E402,F401  (registers the scenarios)
