#!/usr/bin/env python3
"""Per-stage timing of the deathmatch tic (doom_game.run_mp_tic, debug marks) on Oracle,
tic session only (no frames): either the recorded inputs of a CedarDB match (--match) or the
scripted bots live.

    mp_profile.py [--match dm_e1m1_2p | --players N] [--tics 600] [--warmup 60] [--no-debug]
"""
import argparse, json, statistics, sys, time
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client"))
sys.path.insert(0, str(HERE))
import oradb, game_api, mp_lib  # noqa: E402
import run_game_correctness as rgc  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--match")
    ap.add_argument("--players", type=int, default=2)
    ap.add_argument("--tics", type=int, default=600)
    ap.add_argument("--warmup", type=int, default=60)
    ap.add_argument("--no-debug", action="store_true")
    a = ap.parse_args()
    if a.match:
        run = json.loads((rgc.REF.parent / a.match / "run.json").read_text())
        tics = json.loads((rgc.REF.parent / a.match / "tics.json").read_text())
    else:
        run = {"config": dict(timer=0, altdeath=True, monsters=True, respawn=True, seed=7), "map_id": 1,
               "skill": 2, "claimed": list(range(1, a.players + 1))}
        tics = None
    conn = oradb.connect(); cur = conn.cursor()
    game_api.setup_session(cur)
    rgc.mp_cleanup(cur)
    rgc.mp_open(cur, run)
    m, skill = run["map_id"], run["skill"]
    cur.execute("SELECT slot, player_thing_id FROM g_mp_players WHERE map_id = :m", m=m)
    players = {int(s): int(p) for s, p in cur.fetchall()}
    bots = {s: mp_lib.Bot(s, players[s], run["config"]["seed"]) for s in run["claimed"]}
    if not a.no_debug:
        cur.execute("BEGIN doom_game.set_debug(1); END;")
    tv = cur.var(str)
    stages, lat = defaultdict(list), []
    n = min(a.tics, len(tics)) if tics else a.tics
    for i in range(n):
        tic = i + 1
        if tics:
            inp = {int(s): c for s, c in tics[i]["inputs"].items()}
        else:
            cur.execute("SELECT mp.slot, ps.player_thing_id, ps.position_x, ps.position_y, ps.view_angle, "
                        "CASE WHEN ps.alive THEN 1 ELSE 0 END, ps.death_tics, ps.health, "
                        "CASE WHEN mp.role_name IS NOT NULL THEN 1 ELSE 0 END FROM g_mp_players mp "
                        "JOIN g_player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id "
                        "WHERE mp.map_id = :m", m=m)
            st = {r[0]: dict(pid=r[1], x=r[2], y=r[3], angle=r[4], alive=bool(r[5]), death_tics=r[6], health=r[7],
                             held=bool(r[8])) for r in cur.fetchall()}
            inp = {s: [skill, *bots[s].command(tic, st[s], [v for k, v in st.items() if k != s and v["held"]],
                                                {1, 2, 3, 4, 5})] for s in run["claimed"]}
        t0 = time.perf_counter()
        for s, c in sorted(inp.items()):
            rgc.mp_push(cur, m, players[s], c)
        rgc.mp_tic(cur, m, skill, players)
        conn.commit()
        lat.append((time.perf_counter() - t0) * 1e3)
        if not a.no_debug and i >= a.warmup:
            cur.execute("BEGIN :t := doom_game.timings; END;", t=tv)
            for kv in (tv.getvalue() or "").split():
                k, v = kv.split("=")
                stages[k].append(int(v))
    w = a.warmup
    L = sorted(lat[w:])
    print(f"mp tic (inputs + run_mp_tic + commit), {len(players)} slots, {len(run['claimed'])} claimed: "
          f"mean {statistics.mean(L):.2f} p50 {L[len(L)//2]:.2f} p95 {L[int(len(L)*.95)]:.2f} max {L[-1]:.2f} ms")
    tot = 0
    for k, v in stages.items():
        mu = sum(v) / (n - w)
        tot += mu
        print(f"  {k:10s} mean {mu:7.0f} us  max {max(v):7d}")
    if stages:
        print(f"  total      {tot:7.0f} us")
    rgc.mp_cleanup(cur)


if __name__ == "__main__":
    main()
