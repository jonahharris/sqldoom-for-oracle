#!/usr/bin/env python3
"""Test T (tic + sounds + finish snapshot) per map, CedarDB and Oracle, same command stream.

    map_tic_timing.py --db cedar|oracle [MAPS ...] [--tics 400]

Level start + IDDQD/IDKFA, then the first N TPC-DOOM commands (as the smoke scenarios); no
snapshots between tics. Warm-up: the first 50 tics are excluded. A tic CedarDB fails (E1M6's
noise flood) fails on Oracle too and is excluded from the means.
"""
import argparse, json, statistics, sys, time
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / "client"))
from scenario_defs import TPC, SMOKE_SKILL  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True, choices=["cedar", "oracle"])
    ap.add_argument("maps", nargs="*", default=["E1M1", "E1M7", "E2M4", "E3M9", "E4M2", "E4M7"])
    ap.add_argument("--tics", type=int, default=400)
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args()
    res = {}
    if a.db == "cedar":
        import record_game_reference as rgr, psycopg2
        sql = rgr.sql
        conn = psycopg2.connect(rgr.DEFAULT_DSN); conn.autocommit = True; cur = conn.cursor()
        sql.prepare_client(cur)
        stages = {s["label"]: s for s in sql.load_stages(cur)}
    else:
        import oradb, game_api
        conn = oradb.connect(); cur = conn.cursor(); game_api.setup_session(cur)
        cur.execute(game_api.STAGES_SQL); stages = {n: {"map_id": m, "player_thing_id": p} for m, n, p in cur.fetchall()}
    for name in a.maps:
        m, p = stages[name]["map_id"], stages[name]["player_thing_id"]
        skill = SMOKE_SKILL[int(name[1])]
        ms, ev, nerr = [], 0, 0
        if a.db == "cedar":
            sql.set_screen(cur, "game"); sql.enter_level(cur, m, p, skill)
            for c in ("IDDQD", "IDKFA"): sql.cheat_code(cur, m, p, c)
        else:
            game_api.level_start(cur, m, p, skill)
        for i in range(a.tics):
            cmd = list(TPC[i]); cmd[0] = skill
            t = time.perf_counter()
            try:
                if a.db == "cedar":
                    due = sql.execute_game_tic(cur, m, p, tuple(cmd))
                    if due:
                        evs, _ = sql.fetch_sound_events(cur, m, p, ev)
                        ev = max([e[0] for e in evs] + [ev])
                    sql.finish_game_tic(cur, m, p)
                else:
                    due = game_api.run_tic(cur, m, p, cmd); conn.commit()
                    if due:
                        evs = game_api.sound_events(cur, m, p, ev)
                        ev = max([e[0] for e in evs] + [ev])
                    game_api.finish_tic(cur, m, p)
            except Exception:  # noqa: BLE001
                conn.rollback(); nerr += 1; continue
            if i >= 50:
                ms.append((time.perf_counter() - t) * 1e3)
        ms.sort()
        res[name] = {"mean": statistics.mean(ms), "p50": ms[len(ms) // 2], "p95": ms[int(len(ms) * .95)],
                     "max": ms[-1], "n": len(ms), "failed": nerr}
        print(a.db, name, " ".join(f"{k}={v:.2f}" if isinstance(v, float) else f"{k}={v}" for k, v in res[name].items()),
              flush=True)
    if a.out:
        a.out.write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
