"""Record a deathmatch reference run on CedarDB SQLDoom (39_mp.sql / doom_run_mp_tic).

The match is opened as the owner, the way doom_server.py opens one: doom_mp_configure
(-timer, -altdeath, monsters, -respawn), doom_mp_start, then N slots claimed (what
api_join does for a role: role_name + claimed_at, a join request), doom_mp_open. Every
tic each claimed slot appends one input row (the prepared MP_INPUT statement of
doom_sql.py, as the client does) chosen by a scripted bot (mp_lib.Bot) from the state
before the tic, then doom_run_mp_tic(map, skill, slot1..slot4) runs the shared tic for
every slot of the map. (The referee's warm-up tic before doom_mp_open is not run.)

Recorded, after the match start and after every tic: every state table (as
record_game_reference.py, plus mp_players, mp_match, mp_join_requests, mp_inputs; wall-clock
columns excluded), the inputs, level_done, every slot's camera pose, and every
`frame_every` tics each claimed player's frame as palette indices (index-variant renderer of
record_reference.py), zlib-compressed: frames/<tic>_<slot>.idx.z.

Output: oracle/reference_data/<match>/  (match names: mp_lib.MATCHES)
Afterwards the match tables are emptied again so single-player runs see no deathmatch slots.
"""
import argparse, json, sys, time, zlib
from pathlib import Path
import psycopg2

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import record_game_reference as rgr  # noqa: E402
import record_reference as rr  # noqa: E402
import mp_lib  # noqa: E402
sql = rgr.sql

MP_TABLES = dict(rgr.TABLES)
MP_TABLES.update({"mp_match": ("id",), "mp_join_requests": ("slot",), "mp_inputs": ("seq",)})
OUT = HERE.parent / "reference_data"

STATE_Q = """
SELECT mp.slot, ps.player_thing_id, ps.position_x, ps.position_y, ps.view_angle, ps.alive, ps.death_tics, ps.health,
       mp.role_name IS NOT NULL
  FROM mp_players mp JOIN player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id
 WHERE mp.map_id = %s ORDER BY mp.slot"""


def cleanup(cur):
    for t in ("mp_inputs", "mp_join_requests", "mp_players", "mp_match"):
        cur.execute(f"DELETE FROM {t}")
    # CedarDB's level start does not reset a Thing's z; a deathmatch respawn sets the z of the
    # player 2..4 start Things (doom_spawn_player). Put the map's own value back so later
    # single-player recordings start from the map as loaded.
    cur.execute("UPDATE things SET z = 41 WHERE type IN (2, 3, 4) AND z <> 41")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("match", choices=sorted(mp_lib.MATCHES))
    ap.add_argument("--dsn", default=rgr.DEFAULT_DSN)
    ap.add_argument("--tics", type=int, default=0)
    ap.add_argument("--stop-at", type=int, default=0,
                    help="debug: stop after this tic and leave the match state in CedarDB (nothing written)")
    ap.add_argument("--players", type=int, default=0, help="override the number of claimed slots")
    ap.add_argument("--timing-only", action="store_true",
                    help="CedarDB mp tic latency: no snapshots, no frames, nothing written")
    args = ap.parse_args()
    cfg = dict(mp_lib.MATCHES[args.match])
    if args.stop_at:
        args.timing_only = True
    if args.players:
        cfg["players"] = args.players
    n_tics = args.tics or cfg["tics"]
    out = OUT / args.match
    (out / "frames").mkdir(parents=True, exist_ok=True)
    conn = psycopg2.connect(args.dsn); conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    stage = {s["label"]: s for s in sql.load_stages(cur)}[cfg["map"]]
    map_id, skill = stage["map_id"], cfg["skill"]
    frame_every = 0 if args.timing_only else cfg["frame_every"]
    if frame_every:
        body = rr.index_variant(cur)
        cur.execute("PREPARE ref_idx(int,int,int,float8,float8,float8,float8) AS " + body)
    cleanup(cur)
    cur.execute("SELECT doom_mp_configure(%s,%s,%s,%s,%s,%s,%s)",
                (map_id, skill, cfg["timer"], cfg["altdeath"], cfg["monsters"], cfg["respawn"], 350))
    players = sql.mp_start(cur, map_id, skill)
    claimed = sorted(players)[:cfg["players"]]
    for slot in claimed:
        cur.execute("UPDATE mp_players SET role_name = %s, claimed_at = now(), last_seen = now() "
                    "WHERE map_id = %s AND slot = %s", (f"bot{slot}", map_id, slot))
        cur.execute("INSERT INTO mp_join_requests (map_id, slot) VALUES (%s, %s) ON CONFLICT DO NOTHING",
                    (map_id, slot))
    cur.execute("SELECT doom_mp_open()")
    rec = rgr.Recorder(cur, map_id, tables=MP_TABLES, exclude=mp_lib.TIME_COLS)
    if not args.timing_only:
        rec.snapshot(0)
    bots = {s: mp_lib.Bot(s, players[s], cfg["seed"], cfg.get("turn_sign", -1.0)) for s in claimed}
    tics = []
    arena = cfg.get("arena")
    was_alive = {}
    t0 = time.perf_counter()
    try:
        for i in range(n_tics):
            tic = i + 1
            cur.execute(STATE_Q, (map_id,))
            st = {r[0]: dict(pid=r[1], x=float(r[2]), y=float(r[3]), angle=float(r[4]), alive=bool(r[5]),
                             death_tics=int(r[6]), health=int(r[7]), held=bool(r[8])) for r in cur.fetchall()}
            ops = []
            if arena:
                for s in claimed:
                    if st[s]["alive"] and not was_alive.get(s, False):
                        x, y, ang = arena[str(s)] if str(s) in arena else arena[s]
                        cur.execute("UPDATE things SET x=%s, y=%s, angle=%s WHERE map_id=%s AND id=%s",
                                    (float(x), float(y), float(ang), map_id, players[s]))
                        cur.execute("SELECT doom_spawn_player(%s, %s)", (map_id, players[s]))
                        lo = 1 if cfg.get("loadout") else 0
                        if lo:   # a duel loadout: chaingun + rocket launcher with ammo
                            cur.execute("INSERT INTO player_weapon_owned (map_id, player_thing_id, weapon_id) "
                                        "VALUES (%s,%s,4),(%s,%s,5) ON CONFLICT DO NOTHING",
                                        (map_id, players[s], map_id, players[s]))
                            cur.execute("UPDATE player_state SET ammo_bullets=200, ammo_rockets=30 "
                                        "WHERE map_id=%s AND player_thing_id=%s", (map_id, players[s]))
                        ops.append([s, x, y, ang, lo])
                if ops:
                    cur.execute(STATE_Q, (map_id,))
                    st = {r[0]: dict(pid=r[1], x=float(r[2]), y=float(r[3]), angle=float(r[4]), alive=bool(r[5]),
                                     death_tics=int(r[6]), health=int(r[7]), held=bool(r[8])) for r in cur.fetchall()}
            was_alive = {s: st[s]["alive"] for s in claimed}
            cur.execute("SELECT player_thing_id, weapon_id FROM player_weapon_owned WHERE map_id = %s", (map_id,))
            owned = {}
            for pid, w in cur.fetchall():
                owned.setdefault(pid, set()).add(int(w))
            inputs = {}
            for s in claimed:
                me = st[s]
                others = [v for k, v in st.items() if k != s and v["held"]]
                c = bots[s].command(tic, me, others, owned.get(me["pid"], set()))
                inputs[s] = [skill, *c]
                sql.mp_push_input(cur, map_id, players[s], tuple(inputs[s]))
            a = time.perf_counter()
            done = sql.mp_tic(cur, map_id, skill, players)
            ms = (time.perf_counter() - a) * 1e3
            poses = {s: list(sql.camera_pose(cur, map_id, players[s], 1.0)) for s in players}
            if not args.timing_only:
                rec.snapshot(tic)
            if frame_every and tic % frame_every == 0:
                for s in claimed:
                    cur.execute("EXECUTE ref_idx(%s,%s,%s,%s,%s,%s,%s)", (map_id, players[s], skill, *poses[s]))
                    idx = bytes(cur.fetchone()[0])
                    assert len(idx) == 64000
                    (out / "frames" / f"{tic:05d}_{s}.idx.z").write_bytes(zlib.compress(idx, 6))
            tics.append({"tic": tic, "ops": ops, "inputs": {str(s): v for s, v in inputs.items()}, "level_done": done,
                         "poses": {str(s): p for s, p in poses.items()}, "ms": ms})
            if tic % 100 == 0:
                cur.execute("SELECT mp.slot, ps.frags, ps.health FROM mp_players mp JOIN player_state ps "
                            "ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id "
                            "WHERE mp.map_id = %s ORDER BY 1", (map_id,))
                print(f"tic {tic} {time.perf_counter() - t0:.0f}s score {cur.fetchall()}", flush=True)
            if done:
                print(f"level done at tic {tic}")
                break
            if args.stop_at and tic >= args.stop_at:
                print(f"stopped at tic {tic}; match state left in CedarDB")
                return
    finally:
        if args.stop_at:
            return
        if args.timing_only:
            import statistics
            ms = sorted(t["ms"] for t in tics[60:])
            print(json.dumps({"match": args.match, "tics": len(tics), "mean_ms": statistics.mean(ms),
                              "p50_ms": ms[len(ms) // 2], "p95_ms": ms[int(len(ms) * .95)], "max_ms": ms[-1],
                              "first_ms": tics[0]["ms"]}))
            cleanup(cur)
            return
        rec.write(out)
        (out / "tics.json").write_text(json.dumps(tics))
        (out / "run.json").write_text(json.dumps({
            "match": args.match, "map": cfg["map"], "map_id": map_id, "skill": skill, "tics": len(tics),
            "players": {str(s): players[s] for s in players}, "claimed": claimed, "config": cfg,
            "player_thing_id": players[1]}))
        cleanup(cur)
    print("wrote", out)


if __name__ == "__main__":
    main()
