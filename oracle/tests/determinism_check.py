#!/usr/bin/env python3
"""Same input, same world (port of CedarDB SQLDoom's scripts/determinism_check.py), plus the same
world as CedarDB's.

Each map is played twice on Oracle from a fresh level start (enter_level + IDKFA) with the same
irregular scripted input (the reference's script(): moving, strafing, turning, firing, using,
switching weapons), and the whole mutable world is compared: player, actor health, monster AI,
Thing poses, live projectiles, sector movers. With --cedar the same playthrough also runs on
CedarDB SQLDoom and the Oracle world must equal it (floats to 1e-9 relative; the recorded
scenarios check every tic, this checks random input on every map). Tics a database fails (the
reference's noise-flood error on E1M6/E4M5) must fail on both.

    determinism_check.py [--tics 250] [--pairs 1] [--skill 3] [--maps E1M1,E2M4] [--cedar]
"""
import argparse, json, random, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "client"))

WORLD = (
    ("player_state", "position_x, position_y, view_angle, view_z, health, armor, ammo_bullets, ammo_shells, "
                     "ammo_rockets, ammo_cells", "player_thing_id"),
    ("thing_health", "thing_id, health, alive", "thing_id"),
    ("monster_ai", "thing_id, state, seq_index, state_tics, attack_cooldown, target_thing_id, sector_id", "thing_id"),
    ("things", "id, x, y, z, angle", "id"),
    ("monster_projectiles", "projectile_id, x, y, z, state, age, damage", "projectile_id"),
    ("sector_movers", "sector_id, plane, direction, countdown", "sector_id, plane"),
)


def script(skill, tics, seed):
    """The reference's fixed, irregular playthrough."""
    rng = random.Random(seed)
    return [(skill, 1.0 if rng.random() < 0.85 else 0.0, rng.choice((0.0, 0.0, 0.6, -0.6)), rng.random() < 0.6,
             rng.uniform(-7.0, 7.0), rng.random() < 0.3, rng.choice((0, 0, 0, 3, 4, 5)) or None, rng.random() < 0.06)
            for _ in range(tics)]


def norm(v):
    if isinstance(v, bool) or v is None:
        return v
    try:
        return float(v)
    except (TypeError, ValueError):
        return str(v).rstrip()


def same_rows(a, b):
    if len(a) != len(b):
        return False
    for ra, rb in zip(a, b):
        for x, y in zip(ra, rb):
            if isinstance(x, float) and isinstance(y, float):
                if not (x == y or abs(x - y) <= 1e-9 * max(1.0, abs(x), abs(y))):
                    return False
            elif x != y and not (x in ("", None) and y in ("", None)):
                return False
    return True


class OracleSide:
    def __init__(self):
        import oradb, game_api
        self.ga = game_api
        self.conn = oradb.connect()
        self.cur = self.conn.cursor()
        game_api.setup_session(self.cur)

    def maps(self):
        self.cur.execute("SELECT m.map_id, m.name, MIN(t.id) FROM maps m JOIN things t ON t.map_id = m.map_id "
                         "AND t.type = 1 GROUP BY m.map_id, m.name ORDER BY m.map_id")
        return [(int(a), b, int(c)) for a, b, c in self.cur.fetchall()]

    def play(self, m, p, skill, cmds):
        self.ga.level_start(self.cur, m, p, skill, ("IDKFA",))
        fails = []
        for i, c in enumerate(cmds):
            try:
                self.ga.run_tic(self.cur, m, p, c)
                self.conn.commit()
            except Exception:  # noqa: BLE001
                self.conn.rollback()
                fails.append(i + 1)
        return self.world(m), fails

    def world(self, m):
        out = []
        for t, cols, key in WORLD:
            self.cur.execute(f"SELECT {cols} FROM g_{t} WHERE map_id = :m ORDER BY {key}", m=m)
            out.append([tuple(norm(v) for v in r) for r in self.cur.fetchall()])
        return out


class CedarSide:
    def __init__(self):
        import psycopg2
        import record_game_reference as rgr
        self.sql, self.psycopg2 = rgr.sql, psycopg2
        self.conn = psycopg2.connect(rgr.DEFAULT_DSN)
        self.conn.autocommit = True
        self.cur = self.conn.cursor()
        self.sql.prepare_client(self.cur)

    def play(self, m, p, skill, cmds):
        self.sql.set_screen(self.cur, "game")
        self.sql.enter_level(self.cur, m, p, skill)
        self.sql.cheat_code(self.cur, m, p, "IDKFA")
        fails = []
        for i, c in enumerate(cmds):
            try:
                self.sql.execute_game_tic(self.cur, m, p, c)
            except self.psycopg2.Error:
                fails.append(i + 1)
        return self.world(m), fails

    def world(self, m):
        import numpy as np
        out = []
        for t, cols, key in WORLD:
            self.cur.execute(f"SELECT {cols} FROM {t} WHERE map_id = %s ORDER BY {key}", (m,))
            real = [d.type_code == 700 for d in self.cur.description]
            out.append([tuple(float(np.float32(v)) if (f and v is not None) else norm(v) for v, f in zip(r, real))
                        for r in self.cur.fetchall()])
        return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tics", type=int, default=250)
    ap.add_argument("--pairs", type=int, default=1)
    ap.add_argument("--skill", type=int, default=3, choices=(0, 1, 2, 3, 4))
    ap.add_argument("--maps", default="")
    ap.add_argument("--cedar", action="store_true", help="also play on CedarDB and require the same world")
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()
    o = OracleSide()
    c = CedarSide() if a.cedar else None
    want = {x.strip().upper() for x in a.maps.split(",") if x.strip()}
    maps = [mm for mm in o.maps() if not want or mm[1] in want]
    fails, results = 0, []
    for m, name, p in maps:
        for seed in range(a.pairs):
            cmds = script(a.skill, a.tics, seed)
            t0 = time.perf_counter()
            w1, f1 = o.play(m, p, a.skill, cmds)
            w2, f2 = o.play(m, p, a.skill, cmds)
            ok = same_rows(sum(w1, []), sum(w2, [])) and f1 == f2
            line = f"  {name} seed {seed}: {'reproducible' if ok else 'DIVERGED'}"
            res = {"map": name, "seed": seed, "reproducible": ok, "failed_tics": len(f1)}
            if c is not None:
                wc, fc = c.play(m, p, a.skill, cmds)
                eq = [same_rows(x, y) for x, y in zip(w1, wc)]
                cok = all(eq) and fc == f1
                res["cedar_equal"] = cok
                bad = [WORLD[i][0] for i, e in enumerate(eq) if not e]
                line += f"; vs CedarDB {'EQUAL' if cok else 'DIFFERENT ' + ','.join(bad)}"
                if fc != f1:
                    line += f" (failed tics Oracle {len(f1)} CedarDB {len(fc)})"
                ok = ok and cok
            if f1:
                line += f" ({len(f1)} tics failed on purpose: the reference's noise-flood error)"
            print(line + f"  [{time.perf_counter() - t0:.0f}s]", flush=True)
            fails += not ok
            results.append(res)
    total = len(maps) * a.pairs
    print(f"{total - fails}/{total} playthroughs " + ("reproduced and equal to CedarDB" if c else "reproduced exactly"))
    if a.json:
        a.json.write_text(json.dumps(results, indent=1))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
