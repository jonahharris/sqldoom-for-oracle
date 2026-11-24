#!/usr/bin/env python3
"""H22: Database In-Memory. Measures the optimized renderer with the scan-oriented static
geometry tables in the IM column store vs row store, on the same instance.

    python oracle/benchmark/inmemory_experiment.py --size 256M      (restarts the container!)
    python oracle/benchmark/inmemory_experiment.py --size 0         (restore: IM disabled)

Steps: set INMEMORY_SIZE (SPFILE) and restart if it differs; mark the candidate tables
INMEMORY MEMCOMPRESS FOR QUERY LOW; force population (DBMS_INMEMORY.POPULATE) and wait until
V$IM_SEGMENTS shows them COMPLETED; time the renderer; then NO INMEMORY and time again.
"""
import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client"))
import doomora  # noqa: E402
import oradb  # noqa: E402

# scan-heavy static geometry (good IM candidates) -- texture strings are random-access (excluded)
CANDIDATES = ["BSP_STEPS", "NODE_CHILDREN", "NODES", "RENDER_SEGS_EXT", "ST_SECTORS", "ST_THINGS",
              "ST_RENDER_THINGS", "SPRITE_FRAMES"]
TICS = [100, 300, 500, 700, 900, 1100]


def sysconn():
    return oradb.connect(user="system", password="DoomSys_26ai")


def timed(renderer="render_optimized.sql", reps=4):
    conn = doomora.connect(); r = doomora.Renderer(conn, renderer); poses = doomora.load_poses()
    r.render(TICS[0], poses[TICS[0]]); r.render(TICS[0], poses[TICS[0]])
    ms = []
    for t in TICS:
        for _ in range(reps):
            r.render(t, poses[t]); ms.append(r.last["exec_ms"] + r.last["fetch_ms"])
    conn.close()
    return round(statistics.median(ms), 1)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--size", default="256M"); a = ap.parse_args()
    c = sysconn(); cur = c.cursor()
    cur.execute("SELECT display_value FROM v$parameter WHERE name = 'inmemory_size'")
    cur_size = cur.fetchone()[0]
    if cur_size.upper() != a.size.upper():
        print(f"[im] inmemory_size {cur_size} -> {a.size}: restarting instance", flush=True)
        cdb = oradb.connect(user="system", password="DoomSys_26ai", dsn="localhost:1521/FREE")
        cdb.cursor().execute(f"ALTER SYSTEM SET inmemory_size = {a.size} SCOPE = SPFILE")
        cdb.close(); c.close()
        subprocess.run(["docker", "restart", "sqldoom-oracle"], check=True)
        for _ in range(120):
            try:
                c = sysconn(); break
            except Exception:
                time.sleep(5)
        cur = c.cursor()
    if a.size in ("0", "0M"):
        print("[im] In-Memory disabled"); return
    d = doomora.connect(); dc = d.cursor()
    res = {"inmemory_size": a.size, "tables": CANDIDATES}
    for t in CANDIDATES:
        dc.execute(f"ALTER TABLE {t} INMEMORY MEMCOMPRESS FOR QUERY LOW PRIORITY HIGH")
        dc.callproc("DBMS_INMEMORY.POPULATE", ["DOOM", t])
    for _ in range(120):
        cur.execute("SELECT segment_name, populate_status, bytes_not_populated FROM v$im_segments WHERE owner = 'DOOM'")
        rows = cur.fetchall()
        if len(rows) >= len(CANDIDATES) and all(r[1] == "COMPLETED" and r[2] == 0 for r in rows):
            break
        time.sleep(2)
    cur.execute("SELECT segment_name, populate_status, inmemory_size, bytes FROM v$im_segments WHERE owner = 'DOOM' ORDER BY 1")
    res["v$im_segments"] = [list(r) for r in cur.fetchall()]
    print("[im] populated:", res["v$im_segments"], flush=True)
    res["inmemory_ms"] = timed()
    for t in CANDIDATES:
        dc.execute(f"ALTER TABLE {t} NO INMEMORY")
    res["rowstore_ms_same_instance"] = timed()
    print(json.dumps(res, indent=1))
    (HERE / "results").mkdir(exist_ok=True)
    (HERE / "results" / f"inmemory_{a.size}.json").write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
