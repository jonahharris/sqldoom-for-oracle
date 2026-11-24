#!/usr/bin/env python3
"""Load recorded per-tic reference state into the Oracle st_* tables.

    python oracle/client/load_state.py [--run e1m1] [--create]

Reads oracle/reference_data/<run>/state/<table>.parquet (written by
oracle/tests/record_reference.py; column 'tic' + all reference columns) and
loads each into st_<table>: TRUNCATE, then array-DML INSERT, then DBMS_STATS.
--create (re)creates the tables first from oracle/sql/02_state_schema.sql.
float32 parquet columns are widened exactly into BINARY_DOUBLE.
"""
import argparse
import sys
import time
from pathlib import Path

import pyarrow.parquet as pq

sys.path.insert(0, str(Path(__file__).resolve().parent))
import oradb  # noqa: E402

STATE_TABLES = ("sectors", "things", "render_things", "player_state", "player_weapons",
                "player_weapon_owned", "monster_ai", "thing_health", "world_effects",
                "monster_projectiles", "picked_up_items", "sector_light_fx", "mp_players",
                "render_seg_tex")
BATCH = 50000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="e1m1")
    ap.add_argument("--create", action="store_true", help="run 02_state_schema.sql first")
    ap.add_argument("--dsn", default=oradb.DEFAULT_DSN)
    ap.add_argument("--user", default=oradb.DEFAULT_USER)
    ap.add_argument("--password", default=oradb.DEFAULT_PASSWORD)
    args = ap.parse_args()
    state_dir = oradb.ORACLE_DIR / "reference_data" / args.run / "state"

    t_all = time.perf_counter()
    conn = oradb.connect(args.dsn, args.user, args.password)
    cur = conn.cursor()
    if args.create:
        oradb.run_script(cur, oradb.SQL_DIR / "02_state_schema.sql")
    for t in STATE_TABLES:
        t0 = time.perf_counter()
        tab = pq.read_table(state_dir / f"{t}.parquet")
        cols = tab.column_names
        rows = list(zip(*[tab.column(c).to_pylist() for c in cols])) if tab.num_rows else []
        cur.execute(f"TRUNCATE TABLE st_{t}")
        sql = (f"INSERT INTO st_{t} ({', '.join(cols)}) VALUES ("
               + ", ".join(f":{i + 1}" for i in range(len(cols))) + ")")
        for i in range(0, len(rows), BATCH):
            cur.executemany(sql, rows[i:i + BATCH])
        conn.commit()
        print(f"[load_state] st_{t}: {len(rows)} rows in {time.perf_counter() - t0:.2f}s", flush=True)
    t0 = time.perf_counter()
    oradb.gather_stats(cur, [f"st_{t}" for t in STATE_TABLES])
    print(f"[load_state] DBMS_STATS: {time.perf_counter() - t0:.2f}s")
    print(f"[load_state] total {time.perf_counter() - t_all:.2f}s")
    conn.close()


if __name__ == "__main__":
    main()
