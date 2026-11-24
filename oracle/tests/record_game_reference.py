"""Record ground truth for the GAME (not the renderer) from CedarDB SQLDoom.

Replays the TPC-DOOM E1M1 command stream exactly as record_reference.py does
(set_screen 'game', enter_level, IDDQD + IDKFA, then 1,200 x run_game_tic:
execute_game_tic, fetch_sound_events when the tic made sounds, finish_game_tic,
camera_pose) and after the level start (tic 0) and after every tic snapshots
EVERY table the game tic reads or writes, plus what the client API returned.

Output (oracle/reference_data/e1m1_game/):
  tables/<table>.parquet  rows with a leading `tic` column. Tables are stored as
                          "snapshot when changed": a tic appears in the file only when
                          the table's content differs from the previous tic; changes.json
                          lists those tics per table (an empty snapshot is a listed tic
                          with no rows). SPARSE tables (sidedefs, render_segs) store the
                          rows that differ from the tic-0 baseline instead (tic 0 holds
                          the full baseline).
  changes.json            {table: [tics with a stored snapshot]}, keys, sparse flags
  tics.json               per tic: command, sound_due, sound events fetched, the
                          finish_game_tic snapshot dict, camera pose, CedarDB timings
  run.json                map/player/skill/tics

Usage: record_game_reference.py [--dsn postgresql://...] [--out DIR] [--tics 1200]
       record_game_reference.py --timing-only     (test T timing, no snapshots)
"""
import argparse, hashlib, json, sys, time
from pathlib import Path
import psycopg2, pyarrow as pa, pyarrow.parquet as pq

HERE = Path(__file__).resolve().parent
SQLDOOM = HERE.parents[1] / "reference" / "sqldoom"
sys.path.insert(0, str(SQLDOOM))
import doom_sql as sql  # noqa: E402

SKILL = 2
DEFAULT_DSN = "postgresql://postgres:postgres_doom_reference_pw@localhost:55433/postgres"

# table -> key columns (ordering / identity). Every map-scoped table the tic or
# the level start touches.
TABLES = {
    "sectors": ("id",), "sidedefs": ("id",), "render_segs": ("seg_id",),
    "things": ("id",), "render_things": ("thing_id",),
    "player_state": ("player_thing_id",), "player_weapons": ("player_thing_id",),
    "player_weapon_owned": ("player_thing_id", "weapon_id"),
    "monster_ai": ("thing_id",), "thing_health": ("thing_id",),
    "world_effects": ("effect_id",), "monster_projectiles": ("projectile_id",),
    "projectile_impacts": ("projectile_id",),
    "projectile_damage": ("projectile_id", "damage_kind", "hit_index"),
    "hitscan_hits": ("player_thing_id", "shot_serial", "pellet"),
    "picked_up_items": ("thing_id",), "pickup_touches": ("player_thing_id", "thing_id", "kind"),
    "pickup_grants": ("player_thing_id", "weapon_id"),
    "sector_light_fx": ("sector_id",), "sector_movers": ("sector_id",),
    "line_special_events": ("player_thing_id", "line_id", "trigger_type"),
    "line_use_results": ("player_thing_id",), "line_activations": ("line_id",),
    "line_buttons": ("line_id", "sidedef_id", "texture_part"),
    "sound_events": ("event_key",), "mapped_lines": ("line_id",),
    "level_secret_discoveries": ("player_thing_id", "sector_id"),
    "game_tic_commands": ("player_thing_id",), "tic_trace": ("player_thing_id",),
    "monster_steps": ("thing_id",),
    "monster_attack_damage": ("attacker_id", "victim_player", "victim_id", "dmg", "mx", "my"),
    "monster_teleports": ("thing_id",), "monster_deaths": ("thing_id",),
    "monster_respawns": ("thing_id",), "item_respawns": ("thing_id",),
    "level_stats": ("player_thing_id",), "automap_view": ("player_thing_id",),
    "mp_players": ("slot",),
}
SPARSE = {"sidedefs", "render_segs"}
OID = {16: pa.bool_(), 17: pa.binary(), 20: pa.int64(), 21: pa.int32(), 23: pa.int32(),
       700: pa.float32(), 701: pa.float64(), 1700: pa.float64(), 1114: pa.timestamp("us"),
       1184: pa.timestamp("us", tz="UTC")}


def norm(v, t):
    if v is None:
        return None
    if t == pa.string():
        return str(v)
    if t == pa.float64() or t == pa.float32():
        return float(v)
    if t == pa.binary():
        return bytes(v)
    return v


class Recorder:
    def __init__(self, cur, map_id, tables=None, exclude=()):
        self.cur, self.map_id = cur, map_id
        self.tables = dict(tables or TABLES)
        self.exclude = set(exclude)
        self.schemas, self.cols, self.queries = {}, {}, {}
        self.prev, self.base, self.changes = {}, {}, {t: [] for t in self.tables}

    def fetch(self, table):
        cur = self.cur
        if table not in self.queries:
            cur.execute(f'SELECT * FROM "{table}" WHERE false')
            desc = [d for d in cur.description if d.name not in self.exclude]
            names = [d.name for d in desc]
            types = [OID.get(d.type_code, pa.string()) for d in desc]
            self.schemas[table] = pa.schema([pa.field("tic", pa.int32())] +
                                            [pa.field(n, t) for n, t in zip(names, types)])
            self.cols[table] = [[] for _ in range(len(names) + 1)]
            keys = self.tables[table]
            order = ", ".join(f'"{k}" NULLS FIRST' for k in keys)
            sel = ", ".join(f'"{n}"::text' if t == pa.string() else f'"{n}"' for n, t in zip(names, types))
            self.queries[table] = (f'SELECT {sel} FROM "{table}" WHERE map_id = %s ORDER BY {order}',
                                   names, types)
        q, names, types = self.queries[table]
        cur.execute(q, (self.map_id,))
        return [tuple(norm(v, t) for v, t in zip(r, types)) for r in cur.fetchall()]

    def store(self, table, tic, rows):
        cols = self.cols[table]
        for r in rows:
            cols[0].append(tic)
            for i, v in enumerate(r, 1):
                cols[i].append(v)
        self.changes[table].append(tic)

    def snapshot(self, tic):
        for table in self.tables:
            rows = self.fetch(table)
            if table in SPARSE:
                names = self.queries[table][1]
                kidx = [names.index(k) for k in self.tables[table]]
                if tic == 0:
                    self.base[table] = {tuple(r[i] for i in kidx): r for r in rows}
                    self.store(table, 0, rows)
                    self.prev[table] = []
                    continue
                base = self.base[table]
                diff = [r for r in rows if base.get(tuple(r[i] for i in kidx)) != r]
                if len(rows) != len(base):
                    raise RuntimeError(f"{table}: row count changed")
                if diff != self.prev[table]:
                    self.store(table, tic, diff)
                    self.prev[table] = diff
            else:
                if tic == 0 or rows != self.prev[table]:
                    self.store(table, tic, rows)
                    self.prev[table] = rows

    def write(self, out):
        (out / "tables").mkdir(parents=True, exist_ok=True)
        for t, s in self.schemas.items():
            arrays = [pa.array(c, type=f.type) for c, f in zip(self.cols[t], s)]
            pq.write_table(pa.Table.from_arrays(arrays, schema=s), out / "tables" / f"{t}.parquet")
        meta = {"changes": self.changes, "keys": {t: list(k) for t, k in self.tables.items()},
                "sparse": sorted(SPARSE)}
        (out / "changes.json").write_text(json.dumps(meta))


def level_start(cur, map_id, player):
    t0 = time.perf_counter()
    sql.set_screen(cur, "game")
    sql.enter_level(cur, map_id, player, SKILL)
    for code in ("IDDQD", "IDKFA"):
        sql.cheat_code(cur, map_id, player, code)
    return time.perf_counter() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=DEFAULT_DSN)
    ap.add_argument("--out", type=Path, default=HERE.parent / "reference_data" / "e1m1_game")
    ap.add_argument("--tics", type=int, default=1200)
    ap.add_argument("--commands", type=Path, default=HERE / "run-e1m1-b-commands.json")
    ap.add_argument("--timing-only", action="store_true",
                    help="test T on CedarDB: run the tics back to back, no snapshots")
    args = ap.parse_args()
    cmds = [c["command"] for c in json.loads(args.commands.read_text())]
    conn = psycopg2.connect(args.dsn); conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    stage = {s["label"]: s for s in sql.load_stages(cur)}["E1M1"]
    map_id, player = stage["map_id"], stage["player_thing_id"]
    t_start = level_start(cur, map_id, player)
    rec = None if args.timing_only else Recorder(cur, map_id)
    if rec:
        rec.snapshot(0)
    tics, event = [], 0
    t_run = time.perf_counter()
    for i in range(args.tics):
        command = (SKILL, *cmds[i % len(cmds)][1:])
        t0 = time.perf_counter()
        due = sql.execute_game_tic(cur, map_id, player, command)
        t1 = time.perf_counter()
        events = []
        if due:
            events, _ = sql.fetch_sound_events(cur, map_id, player, event)
            if events:
                event = max(e[0] for e in events)
        t2 = time.perf_counter()
        snap = sql.finish_game_tic(cur, map_id, player)
        t3 = time.perf_counter()
        tic = i + 1
        pose = tuple(float(v) for v in sql.camera_pose(cur, map_id, player, 1.0))
        rec_t = {"tic": tic, "command": list(command), "sound_due": due,
                 "events": [[e[0], e[1], float(e[2]), float(e[3])] for e in events],
                 "snapshot": snap, "pose": list(pose),
                 "ms": {"tic": (t1 - t0) * 1e3, "sound": (t2 - t1) * 1e3, "finish": (t3 - t2) * 1e3,
                        "total": (t3 - t0) * 1e3}}
        tics.append(rec_t)
        if rec:
            rec.snapshot(tic)
        if tic % 100 == 0:
            print(f"tic {tic} {time.perf_counter() - t_run:.0f}s  last tic {rec_t['ms']['total']:.1f} ms", flush=True)
    if args.timing_only:
        tot = sorted(t["ms"]["total"] for t in tics[120:])
        import statistics
        n = len(tot)
        print(json.dumps({"level_start_s": t_start, "first_tic_ms": tics[0]["ms"]["total"],
                          "warmup_max_ms": max(t["ms"]["total"] for t in tics[:120]),
                          "mean_ms": statistics.mean(tot), "p50_ms": tot[n // 2],
                          "p95_ms": tot[int(n * 0.95)], "max_ms": tot[-1],
                          "tps": 1000.0 / statistics.mean(tot)}, indent=1))
        out = HERE / "out"; out.mkdir(exist_ok=True)
        (out / "cedar_tic_timing.json").write_text(json.dumps([t["ms"] for t in tics]))
        return
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    rec.write(out)
    (out / "tics.json").write_text(json.dumps(tics))
    (out / "run.json").write_text(json.dumps({"map": "E1M1", "map_id": map_id, "player_thing_id": player,
                                              "skill": SKILL, "tics": args.tics,
                                              "level_start_s": t_start}))
    print("wrote", out)


if __name__ == "__main__":
    main()
