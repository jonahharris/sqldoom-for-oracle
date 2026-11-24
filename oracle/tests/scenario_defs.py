"""The scenario catalogue (see scenario_lib.py). Each scenario's `covers` lists the
features it exercises; game-port.md's coverage matrix is built from these.

Crafted lines (E1M1, sector 98 = the lift by the nukage, tag 1, floor 12 / ceiling 128,
neighbours 142 (floor -124), 147 and 150 (floor 0)):
  USE_LINE   594  two-sided, front = sector 142 (east), back = 98   -> S / D / G specials
  CROSS_IN   593  two-sided, front = 150 (north), back = 98          -> W specials (walk south into 98)
  CROSS_IN2  595  two-sided, front = 147 (south), back = 98          -> a second W line (starters / stops)
Every special is put on one of these lines, so its movers act on real tagged sectors.
"""
import json
from pathlib import Path

from scenario_lib import Scn

TPC = [c["command"] for c in json.loads((Path(__file__).resolve().parent / "run-e1m1-b-commands.json").read_text())]

USE_LINE, CROSS_IN, CROSS_IN2 = 594, 593, 595

W_SPECIALS = [2, 3, 4, 5, 6, 8, 10, 12, 13, 16, 17, 19, 22, 25, 30, 35, 36, 37, 38, 40, 44, 52, 53, 56, 58, 59,
              72, 73, 75, 76, 77, 79, 80, 81, 82, 83, 84, 86, 87, 88, 90, 91, 92, 93, 94, 96, 98, 100, 104,
              105, 106, 107, 108, 109, 110, 119, 120, 121, 124, 128, 129, 130, 141]
S_SPECIALS = [1, 7, 9, 11, 14, 15, 18, 20, 21, 23, 26, 27, 28, 29, 31, 32, 33, 34, 41, 42, 43, 45, 50, 51, 55,
              60, 61, 62, 63, 64, 65, 66, 67, 70, 71, 99, 101, 102, 103, 111, 112, 113, 114, 115, 116, 117, 118,
              122, 123, 127, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140]
G_SPECIALS = [24, 46, 47]
CRUSHERS = {6, 25, 73, 77, 141, 44, 72, 55, 56, 65, 94}


def tpc(s, first, last, weapon=None):
    """Append TPC-DOOM commands first..last (1-based, cycling past 1,200). With `weapon`, the
    run's own weapon switches (and tic 1) select that weapon instead."""
    for i in range(first - 1, last):
        c = list(TPC[i % len(TPC)])
        c[0] = s.skill
        if weapon is not None and (i == first - 1 or c[6] is not None):
            c[6] = weapon
        s.cmds.append(c)
    return s


# ---------------------------------------------------------------- crafted line specials (E1M1)
for sp in W_SPECIALS:
    god = sp not in CRUSHERS
    s = Scn(f"w{sp:03d}", "E1M1", cheats=("IDDQD", "IDKFA") if god else ("IDKFA",),
            covers=[f"special {sp}"] + ([] if god else ["crush damage"]),
            note=f"special {sp} on line {CROSS_IN} (tag 1), crossed walking south into sector 98")
    s.line(CROSS_IN, sp).at_line(CROSS_IN, dist=32).walk(8).idle(292 if sp in CRUSHERS else 242)

for sp in S_SPECIALS:
    god = sp not in CRUSHERS
    s = Scn(f"s{sp:03d}", "E1M1", cheats=("IDDQD", "IDKFA") if god else ("IDKFA",),
            covers=[f"special {sp}"], note=f"special {sp} on line {USE_LINE} (tag 1, back sector 98), used")
    s.line(USE_LINE, sp).at_line(USE_LINE, dist=24).idle(2).use().idle(12).use().idle(235)

for sp in G_SPECIALS:
    s = Scn(f"g{sp:03d}", "E1M1", covers=[f"special {sp}", "shoot-activated line"],
            note=f"special {sp} on line {USE_LINE}, shot with the pistol")
    s.line(USE_LINE, sp).at_line(USE_LINE, dist=40).switch(2, 30).fire(1).idle(40).fire(1).idle(200)

# starters + stops (two crafted lines; the second crossing stops the mover)
for start, stop in ((53, 54), (87, 89), (6, 57), (25, 74), (73, 57), (77, 74), (141, 57)):
    s = Scn(f"stop{start:03d}_{stop:03d}", "E1M1", cheats=("IDKFA",),
            covers=[f"special {start}", f"special {stop}", "mover stop", "mover resume"],
            note=f"{start} on line {CROSS_IN2}, {stop} on line {CROSS_IN}, then {start} again")
    s.line(CROSS_IN2, start).line(CROSS_IN, stop)
    s.at_line(CROSS_IN2, dist=32).walk(8).idle(110)
    s.at_line(CROSS_IN, dist=32).walk(8).idle(60)
    s.at_line(CROSS_IN2, dist=32).walk(8).idle(110)

# ---------------------------------------------------------------- natural specials
Scn("e1m1_exit", "E1M1", covers=["special 11", "use exit"]).at_line(407).idle(2).use().idle(10)
Scn("e1m1_floor23", "E1M1", covers=["special 23 (natural, tag 3: 3 sectors)", "switch texture S1"]) \
    .at_line(753).idle(2).use().idle(200)
Scn("e1m1_door117", "E1M1", covers=["special 117 blazing DR door"]).at_line(1162).idle(2).use().idle(80) \
    .use().idle(20).use().idle(200)
Scn("e1m1_lift62", "E1M1", covers=["special 62 SR lift", "button timer", "repeatable switch"]) \
    .at_line(USE_LINE).idle(2).use().idle(60).use().idle(200)
Scn("e1m1_w1door", "E1M1", covers=["special 2 W1 door (tag 5)", "one-shot cross"]) \
    .at_line(528, dist=32).walk(10).idle(60).at_line(528, dist=32).walk(10).idle(100)
Scn("e1m1_locked", "E1M1", cheats=("IDDQD",), covers=["locked door (blue key)", "use_locked"]) \
    .at_line(421).idle(2).use().idle(20).use().idle(20)

Scn("e1m2_floor19", "E1M2", covers=["special 19 natural"]).at_line(846, dist=32).walk(10).idle(200)
Scn("e1m2_floor38", "E1M2", covers=["special 38 natural (2 sectors)"]).at_line(267, dist=32).walk(10).idle(200)
Scn("e1m2_raise58", "E1M2", covers=["special 58"]).at_line(2011, dist=32).walk(10).idle(200)
Scn("e1m2_door63", "E1M2", covers=["special 63 SR door (tag)"]).at_line(1529).idle(2).use().idle(60).use() \
    .idle(230)
Scn("e1m2_turbo71", "E1M2", covers=["special 71 turbo floor"]).at_line(1284).idle(2).use().idle(150)
Scn("e1m2_floor102", "E1M2", covers=["special 102"]).at_line(1202).idle(2).use().idle(200)
Scn("e1m2_door103", "E1M2", covers=["special 103"]).at_line(93).idle(2).use().idle(150)
Scn("e1m2_door109", "E1M2", covers=["special 109 W1 blazing (2 sectors)"]).at_line(1556, dist=32).walk(10) \
    .idle(150)
Scn("e1m2_lift120", "E1M2", covers=["special 120 WR blazing lift"]).at_line(1210, dist=32).walk(6).idle(150)
Scn("e1m2_lift123", "E1M2", covers=["special 123 SR blazing lift"]).at_line(350).idle(2).use().idle(150)
Scn("e1m2_keys", "E1M2", covers=["special 27 yellow", "special 28 red"]).at_line(264).idle(2).use().idle(60) \
    .at_line(147).idle(2).use().idle(200)
Scn("e1m2_d1door31", "E1M2", covers=["special 31 D1"]).at_line(762).idle(2).use().idle(40).use().idle(120)
Scn("e1m2_teleport97", "E1M2", covers=["special 97 WR teleport", "teleport fog"]) \
    .at_line(1219, dist=32).walk(8).idle(40).at_line(126, dist=32).walk(8).idle(60)
# line 1219 (tag 18) can be walked through from its left (east) side only; 1215 and 126 block the
# player. CedarDB's teleport does not test the crossing side, so the east approach teleports.
Scn("e1m2_teleport39", "E1M2", covers=["special 39 W1 teleport", "one-shot teleport"]).line(1219, 39) \
    .at_line(1219, dist=40, back=True).walk(10).idle(40).at_line(1219, dist=40, back=True).walk(10).idle(40)
Scn("e1m2_teleport_back", "E1M2", covers=["special 97 WR teleport (natural line 1219, crossed east to west)", "teleport fog"]) \
    .at_line(1219, dist=40, back=True).walk(10).idle(30)
Scn("e1m2_teleport126", "E1M2", covers=["special 126 monsters-only teleport, crossed by the player"]) \
    .line(1219, 126).at_line(1219, dist=40, back=True).walk(10).idle(30)
Scn("e1m2_teleport125", "E1M2", covers=["special 125 monsters-only W1 teleport, crossed by the player"]) \
    .line(1219, 125).at_line(1219, dist=40, back=True).walk(10).idle(30)
Scn("e1m2_scroll48", "E1M2", covers=["special 48 scrolling wall (renderer)"]).at_line(1254, dist=160) \
    .idle(70).frames(2)
Scn("e1m3_stairs7", "E1M3", covers=["special 7 stairs (natural)"]).at_line(614).idle(2).use().idle(300)
Scn("e1m3_raise20", "E1M3", covers=["special 20 raise next higher + change"]).at_line(933).idle(2).use() \
    .idle(250)
Scn("e1m3_floor23", "E1M3", covers=["special 23 (5 sectors)"]).at_line(647).idle(2).use().idle(250)
Scn("e1m3_d1blue", "E1M3", covers=["special 32 D1 blue"]).at_line(710).idle(2).use().idle(150)
Scn("e1m3_lights138", "E1M3", covers=["special 138 SR lights"]).at_line(2024).idle(2).use().idle(40).use() \
    .idle(40)
Scn("e1m3_secret_exit", "E1M3", covers=["special 51 secret exit"]).at_line(993).idle(2).use().idle(10)
Scn("e1m3_door103", "E1M3", covers=["special 103 (2 sectors)"]).at_line(361).idle(2).use().idle(150)

# ---------------------------------------------------------------- sectors
Scn("e1m1_nukage", "E1M1", cheats=("IDKFA",), covers=["sector 7 nukage damage", "player death", "cs_death"]) \
    .in_sector(23).set_player(health=30, armor=0).idle(400)
Scn("e1m3_damage", "E1M3", cheats=("IDKFA",), covers=["sector 5 damage 10%", "sector 16 damage 20%"]) \
    .in_sector(2).set_player(health=100, armor=0).idle(200).in_sector(173).idle(200)
s = Scn("e1m1_sector_fx", "E1M1", covers=["sector light specials 1 2 3 8 12 13 17", "sector_light_fx"])
for sec, sp in ((98, 1), (103, 2), (101, 3), (102, 8), (142, 13), (150, 17), (147, 12)):
    s.sector(sec, sp)
s.idle(420)
s = Scn("e1m1_sector_damage", "E1M1", cheats=("IDKFA",),
        covers=["sector 4 damage+blink", "sector 16 damage 20%", "sector 11 end level", "radsuit-free damage"])
s.sector(98, 4).sector(142, 16).sector(150, 11)
s.in_sector(98).set_player(health=100, armor=0).idle(100).in_sector(142).idle(100).in_sector(150).idle(300)
Scn("e1m1_door_timer10", "E1M1", covers=["sector 10 door closes after 30 s"]).sector(98, 10).idle(1120)

# ---------------------------------------------------------------- monsters / weapons / skills (TPC commands)
tpc(Scn("tpc_nightmare", "E1M1", skill=4, covers=["nightmare: fast monsters", "nightmare respawn",
                                                     "monster_respawns", "rockets"]), 1, 2000, weapon=5)
tpc(Scn("tpc_skill0", "E1M1", skill=0, covers=["skill 0 (ITYTD): double ammo, half damage"]), 1, 600)
tpc(Scn("tpc_skill3", "E1M1", skill=3, covers=["skill 3 (UV)"]), 1, 600)
tpc(Scn("tpc_nogod", "E1M1", cheats=("IDKFA",), covers=["player damage without god mode", "armor",
                                                         "pain", "death"]), 1, 1200)
tpc(Scn("tpc_bfg", "E1M1", covers=["BFG9000 ball", "BFG spray", "cells"]), 1, 700, weapon=7)
tpc(Scn("tpc_plasma", "E1M1", covers=["plasma rifle"]), 1, 700, weapon=6)
tpc(Scn("tpc_chainsaw", "E1M1", covers=["chainsaw", "melee hitscan"]), 1, 600, weapon=8)
tpc(Scn("tpc_fist", "E1M1", covers=["fist"]), 1, 500, weapon=1)
s = Scn("tpc_floaters", "E1M1", covers=["lost soul charge (skull_fly)", "cacodemon float + fireball",
                                        "baron fireball", "monster float"])
s.thing(176, 3006).thing(177, 3005).thing(81, 3003).thing(82, 3005).thing(240, 3006)
tpc(s, 1, 900)


# frames as well (renderer over the live state: moving planes, lights, switch textures, flats)
for _n, _every in (("e1m1_sector_fx", 3), ("e1m1_floor23", 4), ("e1m3_stairs7", 5), ("s009", 5), ("s014", 5),
                   ("stop006_057", 4), ("e1m2_teleport97", 3), ("w017", 4), ("s138", 4), ("e1m3_raise20", 5),
                   ("e1m1_lift62", 4), ("s041", 5), ("tpc_floaters", 6), ("tpc_bfg", 6)):
    SCENARIOS_FRAMES = True
    from scenario_lib import SCENARIOS as _S
    _S[_n].frames(_every)


# ---------------------------------------------------------------- phase 4: every map of the WAD
# Smoke runs: the level start and 400 tics of the TPC-DOOM command stream (walking, turning,
# use presses, weapon switches, fire) on each of the 36 maps, frames every 50 tics. The skill
# varies by episode so every spawn filter (skill bits 1, 2, 4) and nightmare are exercised.
SMOKE_SKILL = {1: 2, 2: 3, 3: 1, 4: 4}
for _e in range(1, 5):
    for _m in range(1, 10):
        _name = f"E{_e}M{_m}"
        tpc(Scn(f"smoke_{_name.lower()}", _name, skill=SMOKE_SKILL[_e],
                covers=[f"{_name} level start", f"{_name} 400 tics", f"skill {SMOKE_SKILL[_e]}"]),
            1, 400).frames(50)
# E1M6: firing near its sound-blocking lines makes every CedarDB tic fail (doom_cs_monster_noise's
# UPDATE ... FROM matches a monster twice; the client drops the tic) -- the smoke run shows 379 of
# 400. This run walks the same path without firing, so the rest of the tic is covered on E1M6 too.
# E4M5 likewise (379 of 400).
for _name, _sk in (("E1M6", 2), ("E4M5", 4)):
    _s = Scn(f"smoke_{_name.lower()}_nofire", _name, skill=_sk, covers=[f"{_name} 400 tics without firing"]).frames(50)
    for _c in TPC[:400]:
        _c = list(_c); _c[0] = _sk; _c[5] = False
        _s.cmds.append(_c)
