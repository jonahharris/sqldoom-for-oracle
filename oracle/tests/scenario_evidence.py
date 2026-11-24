"""What each recorded scenario actually exercised on CedarDB (from the recording itself), so
the coverage matrix only claims a branch when the reference run took it.

    scenario_evidence.py [--json out.json]   (reads reference_data/scenarios/*)

Per scenario: mover types and planes seen in sector_movers (and whether any crushed), sectors
whose floor/ceiling/light/flat changed, line activations (one-shot), switch textures
(line_buttons), world effect types (tfog/ifog/puffs/blood/bfg...), projectile types, monster
teleports / respawns, player teleports (position jump > 64 in a tic), the lowest player
health, deaths, exits flagged by finish_game_tic, kills.
"""
import argparse, json, math
from pathlib import Path
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1] / "reference_data" / "scenarios"


def rows(d, t):
    p = d / "tables" / f"{t}.parquet"
    return pq.read_table(p).to_pylist() if p.exists() else []


def evidence(d):
    run = json.loads((d / "run.json").read_text())
    tics = json.loads((d / "tics.json").read_text())
    ev = {"tics": run["tics"], "map": run["map"], "skill": run["skill"], "covers": run["covers"]}
    sm = rows(d, "sector_movers")
    ev["movers"] = sorted({f"{r['mover_type']}/{r['plane']}" for r in sm})
    ev["mover_crush"] = any(r["crush"] for r in sm)
    sec = rows(d, "sectors")
    base = {r["id"]: r for r in sec if r["tic"] == 0}
    ch = {"floor": set(), "ceil": set(), "light": set(), "floor_tex": set()}
    for r in sec:
        b = base.get(r["id"])
        if b:
            for k, c in (("floor", "floor_height"), ("ceil", "ceil_height"), ("light", "light_level"),
                         ("floor_tex", "floor_tex")):
                if r[c] != b[c]:
                    ch[k].add(r["id"])
    ev["sectors_changed"] = {k: len(v) for k, v in ch.items()}
    ev["line_activations"] = len({r["line_id"] for r in rows(d, "line_activations")})
    ev["switch_textures"] = len({(r["line_id"], r["texture_part"]) for r in rows(d, "line_buttons")})
    ev["effects"] = sorted({r["effect_type"] for r in rows(d, "world_effects")})
    ev["projectiles"] = sorted({r["projectile_type"] for r in rows(d, "monster_projectiles")})
    ev["monster_teleports"] = len({r["thing_id"] for r in rows(d, "monster_teleports")})
    ev["monster_respawns"] = len({r["thing_id"] for r in rows(d, "monster_respawns")})
    ps = rows(d, "player_state")
    ev["min_health"] = min((r["health"] for r in ps), default=None)
    ev["player_died"] = any(not r["alive"] for r in ps)
    tele = 0
    for a, b in zip(tics, tics[1:]):
        if str(a["tic"]) in run.get("ops", {}):
            continue        # a scripted pose op, not a teleport
        if math.hypot(b["snapshot"]["x"] - a["snapshot"]["x"], b["snapshot"]["y"] - a["snapshot"]["y"]) > 64:
            tele += 1
    ev["player_jumps"] = tele
    ev["exit_flags"] = sorted({k for t in tics for k in ("use_exit", "use_secret_exit", "cross_exit",
                                                          "cross_secret_exit", "sector_exit") if t["snapshot"].get(k)})
    ev["locked"] = any(t["snapshot"].get("use_locked") for t in tics)
    th = rows(d, "thing_health")
    ev["kills"] = len({r["thing_id"] for r in th if not r["alive"]})
    return ev


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()
    out = {}
    for d in sorted(ROOT.iterdir()):
        if (d / "run.json").exists():
            out[d.name] = e = evidence(d)
            print(f"{d.name:20s} movers={','.join(e['movers']) or '-'}{' CRUSH' if e['mover_crush'] else ''} "
                  f"sec={e['sectors_changed']} act={e['line_activations']} sw={e['switch_textures']} "
                  f"fx={','.join(e['effects'])} proj={','.join(e['projectiles'])} mtel={e['monster_teleports']} "
                  f"mresp={e['monster_respawns']} minhp={e['min_health']} died={e['player_died']} "
                  f"jumps={e['player_jumps']} exits={e['exit_flags']} locked={e['locked']} kills={e['kills']}")
    if a.json:
        a.json.write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
