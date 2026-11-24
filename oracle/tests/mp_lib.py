"""Deathmatch runs: match configurations and the scripted bots that drive them.

A bot decides its command from the game state BEFORE the tic (positions, angles, life,
weapons), so its behaviour reacts to the world (it turns towards the nearest live
opponent, closes in, fires when lined up, respawns after dying, cycles weapons, presses
use now and then). The recorder (CedarDB) stores every command it sent; the Oracle replay
sends exactly those commands, so the bots never run against Oracle's state.
"""
import math
import random

# E1M1 sector 173 (floor -168, ceiling 536): four points 128 units around its widest interior point
ARENA_E1M1 = {1: (1448, 832, 0), 2: (1704, 832, 180), 3: (1576, 960, 270), 4: (1576, 704, 90)}

MATCHES = {
    # name: map, skill, slots claimed, tics, -timer tics (0 = off), altdeath, monsters, -respawn.
    # arena: after a slot (re)spawns at its deathmatch start, the recorder moves it to its arena
    # point (the same pose op on both databases, recorded per tic) so the bots meet and frag.
    "dm_e1m1_2p_roam": dict(map="E1M1", skill=2, players=2, tics=1500, timer=0, altdeath=True, monsters=True,
                            respawn=True, seed=11, frame_every=3),
    "dm_e1m1_2p": dict(map="E1M1", skill=2, players=2, tics=1500, timer=0, altdeath=True, monsters=True,
                       respawn=True, seed=21, frame_every=3, arena=ARENA_E1M1, turn_sign=1.0),
    "dm_e1m1_4p": dict(map="E1M1", skill=2, players=4, tics=1200, timer=1150, altdeath=True, monsters=False,
                       respawn=True, seed=12, frame_every=6, arena=ARENA_E1M1, turn_sign=1.0),
    "dm_e1m1_2p_duel": dict(map="E1M1", skill=2, players=2, tics=1200, timer=0, altdeath=True, monsters=False,
                            respawn=False, seed=31, frame_every=4, arena=ARENA_E1M1, loadout=True,
                            turn_sign=1.0),
    "dm_e1m2_3p_nomon": dict(map="E1M2", skill=3, players=3, tics=900, timer=0, altdeath=True, monsters=False,
                             respawn=False, seed=13, frame_every=0, turn_sign=1.0),
}

# columns that hold wall-clock time (now()), not game state
TIME_COLS = {"last_seen", "claimed_at", "intermission_until"}


def wrap180(a):
    a = (a + 180.0) % 360.0 - 180.0
    return a


class Bot:
    def __init__(self, slot, pid, seed, turn_sign=1.0):
        self.slot, self.pid, self.turn_sign = slot, pid, turn_sign
        self.rng = random.Random(seed * 100 + slot)
        self.strafe = 0.0
        self.weapon_due = 60 + 20 * slot

    def command(self, tic, me, others, owned):
        """me/others: dict(x, y, angle, alive, death_tics, health); owned: weapon ids.
        Returns (fwd, strafe, run, turn, attack, weapon, use)."""
        r = self.rng
        if not me["alive"]:
            press = me["death_tics"] > 36 + self.slot * 3
            return (0.0, 0.0, False, 0.0, False, None, press)
        live = [o for o in others if o["alive"]]
        weapon = None
        if tic >= self.weapon_due:
            self.weapon_due = tic + 90 + r.randrange(120)
            weapon = r.choice(sorted(owned)) if owned else None
        if tic % 25 == self.slot:
            self.strafe = r.choice((-1.0, 0.0, 0.0, 1.0))
        use = tic % 47 == self.slot * 5
        if not live:
            turn = r.choice((-10.0, 0.0, 10.0))
            return (1.0, self.strafe, True, turn, False, weapon, use)
        tgt = min(live, key=lambda o: (o["x"] - me["x"]) ** 2 + (o["y"] - me["y"]) ** 2)
        dx, dy = tgt["x"] - me["x"], tgt["y"] - me["y"]
        dist = math.hypot(dx, dy)
        want = math.degrees(math.atan2(dy, dx))
        diff = wrap180(want - me["angle"])
        # doom_cs_turn: view_angle - turn_degrees (a positive turn is clockwise). Bots of the
        # first recordings (dm_e1m1_2p_roam, dm_e1m1_2p, dm_e1m1_4p) used the opposite sign;
        # `turn_sign` keeps them reproducible.
        turn = -self.turn_sign * max(-24.0, min(24.0, round(diff * 8.0) / 8.0))
        fwd = 1.0 if dist > 256 else (0.5 if dist > 128 else -0.5)
        attack = abs(diff) < 6.0 and dist < 2000 and r.random() < 0.85
        if r.random() < 0.05:
            turn = r.choice((-45.0, 45.0))
        return (fwd, self.strafe, True, turn, attack, weapon, use)
