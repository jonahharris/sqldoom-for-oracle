"""The level-flow scenarios (flow_lib.py). Each function is a script run on CedarDB against the
reference client API, in the order doom_client.py makes its calls; `r` logs every call.

Ground rules (as the reference client): set_screen('game') before a level, enter_level (with the
finished level as carry_from after an intermission), cheats typed as codes or keys, 35 Hz tics,
an exit reported by the tic's snapshot -> level_exit -> intermission tics (a key accelerates /
dismisses) -> after_intermission -> 'level:N' (enter it, carrying the player) or 'finale'.
Scripts may read CedarDB's state to decide (aim at a monster, retry a crossing); what they then
do is in the log as plain calls.
"""
import math

import flow_lib as fl
from flow_lib import flow
import scenario_lib as sl
from scenario_defs import TPC


def tpc(r, first, last, weapon=None):
    out = []
    for i in range(first - 1, last):
        c = list(TPC[i % len(TPC)])
        if weapon is not None and (i == first - 1 or c[6] is not None):
            c[6] = weapon
        out.append(c)
    return out


# ----------------------------------------------------------------- geometry helpers (CedarDB side)
_GEO = {}


def geo(r):
    if r.map not in _GEO:
        _GEO[r.map] = sl.cedar_geometry(r.drv.cur, r.map)
    return _GEO[r.map]


def at_line(r, line_id, dist=24.0, back=False, along=0.5):
    x, y, a = sl.line_pose(geo(r), line_id, dist, back, along)
    return r.pose(x, y, a)


def player_xy(r):
    (x, y), = r.drv.query("SELECT position_x, position_y FROM player_state WHERE map_id=%s AND player_thing_id=%s",
                          (r.map, r.player))
    return float(x), float(y)


def solid_lines(r):
    """Walls a shot or a pose must not cross: one-sided or impassable (flag 1) lines, and two-sided
    lines whose opening (current sector heights) is under 64 units (closed doors, bars, ledges)."""
    rows = r.drv.query("""SELECT v1.x, v1.y, v2.x, v2.y FROM linedefs l
                           JOIN vertexes v1 ON v1.map_id=l.map_id AND v1.id=l.v1_id
                           JOIN vertexes v2 ON v2.map_id=l.map_id AND v2.id=l.v2_id
                           LEFT JOIN sidedefs rs ON rs.map_id=l.map_id AND rs.id=l.right_sd_id
                           LEFT JOIN sidedefs ls ON ls.map_id=l.map_id AND ls.id=l.left_sd_id
                           LEFT JOIN sectors a ON a.map_id=l.map_id AND a.id=rs.sector_id
                           LEFT JOIN sectors b ON b.map_id=l.map_id AND b.id=ls.sector_id
                          WHERE l.map_id=%s AND (l.left_sd_id < 0 OR (l.flags & 1) <> 0 OR b.id IS NULL
                                OR LEAST(a.ceil_height, b.ceil_height) - GREATEST(a.floor_height, b.floor_height) < 64
                                OR ABS(a.floor_height - b.floor_height) > 24)""", (r.map,))
    return [tuple(float(v) for v in row) for row in rows]


def crosses(ax, ay, bx, by, l):
    x1, y1, x2, y2 = l

    def side(px, py, qx, qy, rx, ry):
        return (qx - px) * (ry - py) - (qy - py) * (rx - px)
    d1, d2 = side(ax, ay, bx, by, x1, y1), side(ax, ay, bx, by, x2, y2)
    d3, d4 = side(x1, y1, x2, y2, ax, ay), side(x1, y1, x2, y2, bx, by)
    return d1 * d2 < 0 and d3 * d4 < 0


def clear_spot(r, tx, ty, dist, walls, start=0, margin=40):
    """A point `dist` from (tx, ty) with no wall in between, not within 40 units of a wall
    (directions tried from `start`, so a retry looks from somewhere else)."""
    for kk in range(16):
        k = (start + kk * 5) % 16
        a = 2 * math.pi * k / 16
        px, py = tx + dist * math.cos(a), ty + dist * math.sin(a)
        if any(crosses(tx, ty, px, py, w) for w in walls):
            continue
        if min(sl.seg_dist(px, py, *w) for w in walls) < margin:
            continue
        return round(px), round(py), round(math.degrees(math.atan2(ty - py, tx - px)) % 360)
    return None


def kill(r, thing_ids, weapon=5, dist=224, hp=None, max_rounds=30):
    """Shoot each of `thing_ids` dead: stand at a clear spot facing it, fire, re-aim.
    `hp`: first lower its health (an explicit state op on both databases) so the kill is quick."""
    walls = solid_lines(r)
    r.tic(sw=weapon)
    r.idle(25)
    for tid in thing_ids:
        if hp is not None:
            r.op({"op": "thing_health", "thing": tid, "health": hp})
        for rnd in range(max_rounds):
            (x, y, alive), = r.drv.query("""SELECT t.x, t.y, h.alive FROM things t JOIN thing_health h
                                              ON h.map_id=t.map_id AND h.thing_id=t.id
                                            WHERE t.map_id=%s AND t.id=%s""", (r.map, tid))
            if not alive:
                break
            if rnd % 5 == 0:
                walls = solid_lines(r)
            d = (dist, dist * 0.7, dist * 0.45, dist * 0.3)[rnd % 4]
            spot = clear_spot(r, float(x), float(y), d, walls, start=rnd) or \
                clear_spot(r, float(x), float(y), dist / 2, walls, start=rnd)
            for dd in (96, 72, 56, 44, 40):      # a closed room (a cage): closer, nearer the walls
                spot = spot or clear_spot(r, float(x), float(y), dd, walls, start=rnd, margin=17)
            if spot is None:
                raise RuntimeError(f"no clear spot near thing {tid}")
            r.pose(*spot)
            r.tics([[r.skill, 0.0, 0.0, False, 0.0, True, None, False]] * 12)
        else:
            raise RuntimeError(f"thing {tid} survived")
    r.idle(10)


def run_to_exit(r, line_id, kind="use", tries=4):
    """Stand at an exit line and use it / walk across it; returns the exit snapshot."""
    for k in range(tries):
        back = k % 2 == 1
        if kind == "use":
            at_line(r, line_id, dist=24, back=back)
            r.idle(2)
            s = r.tics([[r.skill, 0.0, 0.0, False, 0.0, False, None, True]] + [None] * 4)
        else:
            at_line(r, line_id, dist=40, back=back)
            s = r.tics([[r.skill, 1.0, 0.0, False, 0.0, False, None, False]] * 16)
        if s is not None:
            return s
    raise RuntimeError(f"line {line_id}: no exit")


def through_intermission(r, accel_at=None, frame_every=10):
    """level_exit has run: the tally, a frame now and then, after_intermission's outcome."""
    r.frame_screen(0)
    n = r.intermission(accel_at=accel_at, frame_every=frame_every)
    r.frame_screen(n + 1)
    return r.do("after_inter", r.map)


def level_done(r, snap):
    """G_DoCompleted -> the tally -> G_WorldDone, as doom_client does after an exit tic."""
    secret = r.exit_secret(snap)
    nxt = r.do("level_exit", r.map, r.player, secret)
    return nxt


# ----------------------------------------------------------------- flows
@flow("exit_e1m1_e1m2", covers=["use exit (S1 11)", "finish_level (kills/items/secrets/time/par)", "level_stats",
                                "intermission tally (counting, pauses, waiting, dismiss)", "intermission frames",
                                "after_intermission -> next map", "carry_player (health/armor/weapons/ammo, keys dropped)",
                                "next map level start + play"])
def exit_e1m1_e1m2(r):
    r.do("stages")
    r.do("set_screen", "game")
    r.enter("E1M1", skill=2, cheats=("IDDQD", "IDKFA"))
    r.tics(tpc(r, 1, 700), frame_every=175, stop_on_exit=False)
    r.op({"op": "player", "cols": {"health": 87, "armor": 42}})
    s = run_to_exit(r, 407, "use")
    m1, p1 = r.map, r.player
    nxt = level_done(r, s)
    r.do("level_stats", m1, p1)
    out = through_intermission(r, accel_at=None, frame_every=8)
    assert out.startswith("level:"), out
    r.enter_id(int(out.split(":")[1]), carry=True)
    r.frame_game()
    r.tics(tpc(r, 1, 300, weapon=4), frame_every=100, stop_on_exit=False)


@flow("secret_exit_e1m3_e1m9_e1m4", covers=["secret exit (S1 51)", "routing ExM3 secret -> ExM9",
                                            "routing E1M9 -> E1M4", "intermission accelerated mid-count",
                                            "carry twice"])
def secret_exit(r):
    r.do("set_screen", "game")
    r.enter("E1M3", skill=2, cheats=("IDDQD", "IDKFA"))
    r.tics(tpc(r, 1, 300), frame_every=150, stop_on_exit=False)
    s = run_to_exit(r, 993, "use")
    assert s["use_secret_exit"]
    level_done(r, s)
    out = through_intermission(r, accel_at=40, frame_every=10)
    r.enter_id(int(out.split(":")[1]), carry=True)          # E1M9
    r.frame_game()
    r.tics(tpc(r, 301, 500), frame_every=100, stop_on_exit=False)
    s = run_to_exit(r, 1662, "use")
    level_done(r, s)
    out = through_intermission(r, accel_at=2, frame_every=10)
    r.enter_id(int(out.split(":")[1]), carry=True)          # E1M4
    r.frame_game()
    r.tics(tpc(r, 1, 150), frame_every=75, stop_on_exit=False)


@flow("boss_e1m8_finale1", covers=["boss specials: E1M8 barons dead -> tag 666 floor lowers (cs_boss)",
                                   "cross exit (W1 52)", "ExM8 -> no next map", "finale episode 1: text typing, "
                                   "keypress fills the page, auto-advance to the picture, keypress -> title",
                                   "finale frames"])
def boss_e1m8(r):
    r.do("set_screen", "game")
    r.enter("E1M8", skill=2, cheats=("IDDQD", "IDKFA"))
    r.idle(10)
    barons = [int(t) for (t,) in r.drv.query("""SELECT t.id FROM things t JOIN thing_health h
                                                  ON h.map_id=t.map_id AND h.thing_id=t.id
                                                WHERE t.map_id=%s AND t.type=3003 AND h.alive ORDER BY t.id""",
                                             (r.map,))]
    kill(r, barons, weapon=5, hp=60)
    r.tics([None] * 240, frame_every=60, stop_on_exit=False)    # the 666 floor going down
    s = None
    for line in (164, 165, 166, 167, 227, 228, 230, 232):
        try:
            s = run_to_exit(r, line, "cross")
            break
        except RuntimeError:
            continue
    assert s is not None
    level_done(r, s)
    out = through_intermission(r, accel_at=5, frame_every=10)
    assert out == "finale", out
    finale(r, typing=150, wait=True)


def finale(r, typing=150, wait=True, picture=60, every=25):
    r.do("finale_phase")
    for i in range(typing):
        st = r.do("finale_tic")
        if i % every == 0:
            r.frame_screen(i)
    r.do("finale_advance")                 # the whole page at once
    r.frame_screen(0)
    if wait:                               # TEXTWAIT runs out by itself
        for i in range(400):
            st = r.do("finale_tic")
            if st == "picture":
                break
    else:
        r.do("finale_advance")
    r.frame_screen(0)
    for i in range(picture):
        r.do("finale_tic")
        if i % every == 0:
            r.frame_screen(i)
    r.do("finale_advance")                 # back to the title
    r.do("screen_state")
    r.frame_screen(16)


@flow("boss_e2m8_finale2", covers=["boss exit (E2M8 cyberdemons dead -> boss_exit)", "finale episode 2"])
def boss_e2m8(r):
    r.do("set_screen", "game")
    r.enter("E2M8", skill=3, cheats=("IDDQD", "IDKFA"))
    r.idle(10)
    cybers = [int(t) for (t,) in r.drv.query("""SELECT t.id FROM things t JOIN thing_health h
                                                  ON h.map_id=t.map_id AND h.thing_id=t.id
                                                WHERE t.map_id=%s AND t.type=16 AND h.alive ORDER BY t.id""",
                                             (r.map,))]
    kill(r, cybers[:-1], weapon=5, hp=60)
    # the last one: its death must end the level by itself (boss_exit), seen on the tic it dies
    last = cybers[-1]
    r.op({"op": "thing_health", "thing": last, "health": 60})
    walls = solid_lines(r)
    s = None
    for rnd in range(40):
        (x, y), = r.drv.query("SELECT x, y FROM things WHERE map_id=%s AND id=%s", (r.map, last))
        spot = clear_spot(r, float(x), float(y), (224, 160, 112)[rnd % 3], walls, start=rnd) or \
            clear_spot(r, float(x), float(y), 112, walls, start=rnd)
        r.pose(*spot)
        s = r.tics([[r.skill, 0.0, 0.0, False, 0.0, True, None, False]] * 12)
        if s is not None:
            break
    assert s is not None and s["boss_exit"], s
    level_done(r, s)
    out = through_intermission(r, accel_at=3, frame_every=10)
    assert out == "finale", out
    finale(r, typing=60, wait=False, picture=30)


@flow("boss_e3m8_bunny", covers=["boss exit (E3M8 spider mastermind dead)", "finale episode 3: bunny scroll",
                                 "THE END stamp"])
def boss_e3m8(r):
    r.do("set_screen", "game")
    r.enter("E3M8", skill=2, cheats=("IDDQD", "IDKFA"))
    r.idle(5)
    spider = [int(t) for (t,) in r.drv.query("""SELECT t.id FROM things t JOIN thing_health h
                                                  ON h.map_id=t.map_id AND h.thing_id=t.id
                                                WHERE t.map_id=%s AND t.type=7 AND h.alive""", (r.map,))]
    r.tic(sw=5)
    r.idle(25)
    r.op({"op": "thing_health", "thing": spider[0], "health": 60})
    walls = solid_lines(r)
    s = None
    for rnd in range(40):
        (x, y), = r.drv.query("SELECT x, y FROM things WHERE map_id=%s AND id=%s", (r.map, spider[0]))
        spot = clear_spot(r, float(x), float(y), (256, 192, 128)[rnd % 3], walls, start=rnd) or \
            clear_spot(r, float(x), float(y), 128, walls, start=rnd)
        r.pose(*spot)
        s = r.tics([[r.skill, 0.0, 0.0, False, 0.0, True, None, False]] * 12)
        if s is not None:
            break
    assert s is not None and s["boss_exit"], s
    level_done(r, s)
    out = through_intermission(r, accel_at=3, frame_every=20)
    assert out == "finale", out
    r.do("finale_advance")
    r.do("finale_advance")                  # straight to the bunny
    for i in range(1320):
        r.do("finale_tic")
        if i % 40 == 0 or 1125 <= i <= 1220 and i % 5 == 0:
            r.frame_screen(i)
    r.do("finale_advance")
    r.frame_screen(0)


@flow("exit_e4m8_finale4", covers=["E4M8 exit (S1 11) -> finale episode 4", "E4 intermission (INTERPIC)"])
def exit_e4m8(r):
    r.do("set_screen", "game")
    r.enter("E4M8", skill=2, cheats=("IDDQD", "IDKFA"))
    r.tics(tpc(r, 1, 120), frame_every=60, stop_on_exit=False)
    s = run_to_exit(r, 1857, "use")
    level_done(r, s)
    out = through_intermission(r, accel_at=None, frame_every=15)
    assert out == "finale", out
    finale(r, typing=40, wait=False, picture=20)


@flow("save_load_e1m2", covers=["menu: Esc -> main -> Save -> slot", "save_game", "play on", "menu Load (slot names drawn)",
                                "load_game (world restored, render caches rebuilt)", "play on after load",
                                "an empty slot does not load"])
def save_load(r):
    r.do("set_screen", "game")
    r.enter("E1M2", skill=2, cheats=("IDDQD", "IDKFA"))
    r.tics(tpc(r, 1, 400), frame_every=200, stop_on_exit=False)
    r.do("set_screen", "main")            # Escape
    r.frame_screen(0)
    for k in ("down", "down", "down"):
        r.do("menu", k)
    act, st = r.do("menu", "enter")       # -> save screen
    r.frame_screen(8)
    r.do("menu", "down")
    act, st = r.do("menu", "enter")       # 'save:1'
    assert act == "save:1", act
    r.do("save", 1, r.map, r.player, r.skill, "E1M2")
    r.tics(tpc(r, 401, 700), frame_every=150, stop_on_exit=False)
    m_saved = r.map
    # a second save of another level, so the load screen lists two names
    r.do("set_screen", "game")
    r.enter("E1M3", skill=2, cheats=("IDDQD",))
    r.tics(tpc(r, 1, 120), stop_on_exit=False)
    r.do("set_screen", "main")
    for k in ("down", "down", "down", "enter", "down", "down", "down"):
        r.do("menu", k)
    act, st = r.do("menu", "enter")
    assert act == "save:3", act
    r.do("save", 3, r.map, r.player, r.skill, "E1M3 base")
    # load slot 1 from the menu: an empty slot first (nothing happens), then slot 1
    r.do("set_screen", "main")
    for k in ("down", "down", "enter"):
        r.do("menu", k)
    r.frame_screen(0)
    act, st = r.do("menu", "enter")       # slot 0: empty
    assert act == "none", act
    r.do("menu", "down")
    act, st = r.do("menu", "enter")       # 'load:1'
    assert act == "load:1", act
    got = r.do("load", 1)
    assert got["map_id"] == m_saved
    m, p = r.stage("E1M2")
    r.map, r.player, r.skill, r.event = m, p, got["skill"], 0      # session.resync
    r.touch(m)
    r.frame_game()
    r.tics(tpc(r, 401, 700), frame_every=100, stop_on_exit=False)
    # the load rebuilt E1M2's render_things with the save's positions as spawn sectors; a level
    # start keeps that (checked here), then the map is put back as loaded for later recordings
    r.enter("E1M2")
    r.idle(5)
    r.do("restore_render_things", m, p)


@flow("menus_newgame", covers=["title -> main", "cursor up/down/wrap", "help pages (HELP1, CREDIT)", "episode/skill menus",
                               "new game start (E2M1, skill from the menu)", "quit action", "skull blink frames",
                               "Esc back to the game"])
def menus(r):
    r.do("set_screen", "game")
    r.enter("E1M1", skill=2)
    r.do("set_screen", "title")
    r.frame_screen(0)
    r.do("menu", "enter")                 # any key: title -> main
    r.frame_screen(0)
    r.frame_screen(8)
    for k in ("up", "up", "down", "down", "up", "up"):     # 5, 4, 5, 0, 5, 4
        r.do("menu", k)
        r.frame_screen(0)
    r.do("menu", "enter")                 # cursor 4: read this -> help1
    r.frame_screen(0)
    r.do("menu", "enter")                 # help2
    r.frame_screen(0)
    r.do("menu", "enter")                 # back to main (cursor 4)
    r.do("menu", "down")
    act, _ = r.do("menu", "enter")        # cursor 5: quit
    assert act == "quit", act
    r.do("menu", "escape")                # main -> game
    r.do("set_screen", "main")
    for k in ("up", "up", "up", "up", "up", "up"):      # back round to cursor 0
        r.do("menu", k)
    r.do("menu", "enter")                 # new game -> episode
    r.frame_screen(0)
    r.do("menu", "down")
    r.do("menu", "escape")                # back to main
    r.do("menu", "enter")
    r.do("menu", "down")
    act, st = r.do("menu", "enter")       # episode 2 -> skill (cursor 2)
    r.frame_screen(0)
    r.do("menu", "escape")                # skill -> episode
    r.do("menu", "enter")
    r.do("menu", "up")
    act, st = r.do("menu", "enter")       # 'start' at skill 1
    assert act == "start", act
    r.frame_screen(0)
    r.enter(f"E{st['episode']}M1", skill=st["skill"])
    r.frame_game()
    r.tics(tpc(r, 1, 200), frame_every=100, stop_on_exit=False)


@flow("cheat_keys", covers=["doom_cheat_key: IDDQD, IDKFA, IDFA, IDBEHOLDV/S/I/R/A/L, IDCHOPPERS, IDMYPOS, IDCLIP, "
                            "IDSPISPOPD, IDDT -> automap cheat, IDMUS, IDCLEV warp", "cheat buffer (12 chars, reset on "
                            "a match, reset by a level start)", "weapon slot/cycle queries"])
def cheat_keys(r):
    r.do("set_screen", "game")
    r.enter("E1M1", skill=2)
    r.idle(3)

    def typ(word):
        res = None
        for ch in word:
            res = r.do("cheat_key", r.map, r.player, ch)
        return res

    for word in ("xyziddqd", "idkfa", "idbeholdv", "idbeholds", "idbeholdi", "idbeholdr", "idbeholdl", "idbeholda",
                 "idchoppers", "idmypos", "idclip", "idspispopd", "idfa", "abcdefghijklmnop", "idmus19"):
        res = typ(word)
        r.idle(4)
    r.frame_game()
    res = typ("iddt")
    assert res == "iddt", res
    r.do("automap", "toggle", r.map, r.player, "cheat")
    r.frame_automap()
    for slot in (1, 3, 4, 5, 6, 7, 2):
        w = r.do("weapon_slot", r.map, r.player, slot)
        r.tic(sw=w)
        r.idle(20)
    for step in (1, 1, -1, -1, -1):
        w = r.do("weapon_cycle", r.map, r.player, step)
        r.tic(sw=w)
        r.idle(20)
    r.tics(tpc(r, 1, 200), frame_every=100, stop_on_exit=False)
    res = typ("idclev12")
    assert res == "warp:E1M2", res
    r.enter("E1M2")                        # the warp: a stage change, no carry
    r.idle(3)
    typ("idclev1")                         # incomplete: still buffered
    r.tics(tpc(r, 1, 100), frame_every=50, stop_on_exit=False)


@flow("automap_views", covers=["automap frames: follow, zoom, pan, follow toggle, grid, fit (Home), computer map "
                               "(IDBEHOLDA), IDDT 1 and 2 (things)", "automap on maps of every episode"])
def automap(r):
    for name, n in (("E1M1", 400), ("E2M2", 200), ("E3M3", 200), ("E4M4", 200)):
        r.do("set_screen", "game")
        r.enter(name, skill=2, cheats=("IDDQD", "IDKFA"))
        r.tics(tpc(r, 1, n), stop_on_exit=False)
        m, p = r.map, r.player
        r.frame_automap()
        r.do("automap", "zoom", m, p, 1.25)
        r.do("automap", "zoom", m, p, 1.25)
        r.frame_automap()
        r.do("automap", "pan", m, p, 96.0, -40.0)
        r.frame_automap()
        r.do("automap", "zoom", m, p, 1 / 1.15)
        r.do("automap", "toggle", m, p, "grid")
        r.frame_automap()
        r.do("automap", "toggle", m, p, "follow")
        r.frame_automap()
        r.do("automap", "fit", m, p)
        r.frame_automap()
        r.do("cheat", m, p, "IDBEHOLDA")
        r.frame_automap()
        r.do("automap", "toggle", m, p, "cheat")
        r.frame_automap()
        r.do("automap", "toggle", m, p, "cheat")
        r.frame_automap()
        r.do("automap", "toggle", m, p, "grid")
        r.do("automap", "toggle", m, p, "follow")
        for i in range(3):
            r.tics(tpc(r, n + 1 + 20 * i, n + 20 * (i + 1)), stop_on_exit=False)
            r.frame_automap()
        r.do("automap", "zoom", m, p, 100.0)
        r.frame_automap()
        r.do("automap", "zoom", m, p, 0.0001)
        r.frame_automap()


@flow("demo_record_play", covers=["demo record (G_WriteDemoTiccmd)", "demo playback replaces the client's command",
                                  "demo end", "attract loop: title page, demo, credit page, wrap",
                                  "attract stop by a key"])
def demo(r):
    r.do("set_screen", "game")
    r.enter("E1M1", skill=2)
    did = r.do("demo_begin", "e1m1-demo", r.map, r.player, r.skill)
    r.enter("E1M1")                        # F9 restarts the level to record from its start
    for c in ("IDDQD", "IDKFA"):
        r.do("cheat", r.map, r.player, c)
    r.tics(tpc(r, 1, 250), frame_every=125, stop_on_exit=False)
    r.do("demo_stop")
    hdr = r.do("demo_play", "e1m1-demo")
    r.skill = hdr["skill"]
    r.enter("E1M1")
    for c in ("IDDQD", "IDKFA"):
        r.do("cheat", r.map, r.player, c)
    for i in range(260):                   # the client keeps sending (empty) commands
        res = r.tic()
        if (i + 1) % 125 == 0:
            r.frame_game()
        if not res["snapshot"]["demo_active"]:
            break
    r.idle(5)
    # attract loop: title (170 tics), the demo, credit (200 tics), the demo again ...
    r.do("set_screen", "title")
    r.do("attract_start")
    r.frame_screen(0)
    playing = False
    for i in range(900):
        if not playing:
            out = r.do("attract_tic")
            if out == "page":
                r.frame_screen(0)
            elif out.startswith("demo:"):
                hdr = r.do("demo_header", int(out.split(":")[1]))
                r.skill = hdr["skill"]
                r.enter(next(k for k, s in r.drv.stages.items() if s["map_id"] == hdr["map_id"]))
                playing = True
        else:
            res = r.tic()
            if i % 100 == 0:
                r.frame_game()
            if not res["snapshot"]["demo_active"]:
                playing = False
                r.do("screen_state")
                r.frame_screen(0)
    r.do("attract_stop")
    r.do("screen_state")


@flow("death_restart", covers=["player death (no god mode)", "restart on use: pistol start of the same level",
                               "carry from a dead player carries nothing"])
def death_restart(r):
    r.do("set_screen", "game")
    r.enter("E1M1", skill=2, cheats=("IDKFA",))
    r.op({"op": "player", "cols": {"health": 25, "armor": 0}})
    for _ in range(60):
        s = r.tics(tpc(r, 1, 1200)[_ * 20:(_ + 1) * 20], stop_on_exit=False)
        (alive,), = r.drv.query("SELECT alive FROM player_state WHERE map_id=%s AND player_thing_id=%s",
                                (r.map, r.player))
        if not alive:
            break
    r.idle(40, frame_every=20)
    m1, p1 = r.map, r.player
    r.enter("E1M1")                        # P_DeathThink: use restarts the level
    r.frame_game()
    r.idle(20)
    # a level entered "carrying" from a dead player gets the reborn loadout only
    r.op({"op": "player", "cols": {"health": 0, "alive": False}})
    m1, p1 = r.map, r.player
    r.enter("E1M2", carry=True)
    r.idle(10)


@flow("monster_teleport", covers=["a monster crossing a monsters-only teleport line (125/126): monster_teleports, "
                                  "teleport fog, the monster at the destination"])
def monster_teleport(r):
    """Monster closets: monsters standing on 125/126 lines that lead to a teleport destination.
    The player wakes them (noise) from in front of the line and waits for one to cross."""
    candidates = [("E2M2", 482), ("E2M2", 480), ("E2M2", 501), ("E2M7", 479), ("E2M7", 322), ("E2M9", 712),
                  ("E2M1", 1595), ("E2M5", 1947)]
    for name, line in candidates:
        r.do("set_screen", "game")
        r.enter(name, skill=2, cheats=("IDDQD", "IDKFA"))
        for back in (False, True):
            at_line(r, line, dist=160, back=back)
            r.tic(sw=2)
            for k in range(40):
                r.tics([[r.skill, 0.0, 0.0, False, 0.0, k % 4 == 0, None, False]] * 10, stop_on_exit=False)
                (n,), = r.drv.query("SELECT COUNT(*) FROM monster_teleports WHERE map_id=%s", (r.map,))
                if n:
                    r.frame_game()
                    r.idle(60, frame_every=20)
                    return
    raise RuntimeError("no monster teleported")


@flow("lost_soul_charge", covers=["the lost soul's charge (skull_fly) hitting the player: 3d8 damage, the skull stops"])
def lost_soul_charge(r):
    """E1M1 with a lost soul in place of a zombieman (thing mod, as tpc_floaters); the player, god mode
    off, stands in front of it until a charge lands."""
    m, p = r.stage("E1M1")
    r.mod("E1M1", [{"kind": "thing", "id": 176, "type": 3006}])
    r.do("set_screen", "game")
    r.enter("E1M1", skill=2, cheats=("IDKFA",))
    r.op({"op": "player", "cols": {"health": 200, "armor": 0}})
    r.idle(20)
    walls = solid_lines(r)
    hit = False
    for k in range(30):
        (x, y), = r.drv.query("SELECT x, y FROM things WHERE map_id=%s AND id=176", (r.map,))
        spot = clear_spot(r, float(x), float(y), 192, walls) or clear_spot(r, float(x), float(y), 128, walls)
        r.pose(*spot)
        if k == 0:                           # pistol shots once the weapon is up: the noise wakes it
            r.tics([[r.skill, 0.0, 0.0, False, 0.0, True, None, False]] * 10, stop_on_exit=False)
        for i in range(30):
            (ct,), = r.drv.query("SELECT charge_tics FROM monster_ai WHERE map_id=%s AND thing_id=176", (r.map,))
            (h0,), = r.drv.query("SELECT health FROM player_state WHERE map_id=%s AND player_thing_id=%s",
                                 (r.map, r.player))
            r.idle(1)
            (h1,), = r.drv.query("SELECT health FROM player_state WHERE map_id=%s AND player_thing_id=%s",
                                 (r.map, r.player))
            if ct > 0 and h1 < h0:
                hit = True
                break
        if hit:
            break
        r.op({"op": "player", "cols": {"health": 200}})
    assert hit, "no charge landed"
    r.frame_game()
    r.idle(40, frame_every=10)
