#!/usr/bin/env python3
"""Initialise the Oracle Doom database end to end (idempotent; ~4-6 minutes).

    python oracle/client/setup_db.py [--skip-baseline]

Steps:
  0. wait for the container to accept connections
  1. sql/00_user.sql as SYSTEM            privileges for V$ views / DBMS_XPLAN
  2. load_wad.py                          01_schema + 03_catalogs + WAD (every map: E1M1..E4M9,
                                          map_id 1..36 in WAD order) + derived tables
  3. load_state.py --create               02_state_schema + per-tic recorded state (reference_data/e1m1)
  4. precompute_textures.py               04_precompute: screen dims, BSP rank steps, lit texture
                                          strings, packed status bar, render_segs_ext, ...
  5. 05_baseline_support.sql              support objects for the baseline renderer
  6. install_hybrid.py                    06_hybrid.sql: doom_hybrid package for render_hybrid.sql
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ORA = HERE.parent
sys.path.insert(0, str(HERE))
import oradb  # noqa: E402

PY = sys.executable


def step(title, cmd):
    print(f"[setup] {title}", flush=True)
    t = time.perf_counter()
    subprocess.run(cmd, check=True)
    print(f"[setup]   done in {time.perf_counter() - t:.1f}s", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-baseline", action="store_true")
    ap.add_argument("--wad", default=str(ORA / "wad" / "freedoom1.wad"))
    ap.add_argument("--maps", nargs="*", default=[], help="map names (default: every map of the WAD)")
    a = ap.parse_args()
    print("[setup] waiting for Oracle ...", flush=True)
    for i in range(120):
        try:
            oradb.connect(user="system", password="DoomSys_26ai").close()
            break
        except Exception:
            time.sleep(5)
    else:
        sys.exit("Oracle did not come up (docker compose -f oracle/docker-compose.yml up -d oracle)")
    c = oradb.connect(user="system", password="DoomSys_26ai")
    oradb.run_script(c.cursor(), oradb.SQL_DIR / "00_user.sql")
    c.close()
    step("load WAD", [PY, str(HERE / "load_wad.py"), a.wad, *a.maps])
    step("load recorded state", [PY, str(HERE / "load_state.py"), "--run", "e1m1", "--create"])
    step("precompute (04_precompute.sql + texture strings)", [PY, str(HERE / "precompute_textures.py")])
    if not a.skip_baseline:
        print("[setup] baseline support (05_baseline_support.sql)", flush=True)
        t = time.perf_counter()
        c = oradb.connect()
        oradb.run_script(c.cursor(), oradb.SQL_DIR / "05_baseline_support.sql")
        c.commit()
        print(f"[setup]   done in {time.perf_counter() - t:.1f}s", flush=True)
    step("hybrid renderer package (06_hybrid.sql)", [PY, str(HERE / "install_hybrid.py")])
    print("[setup] complete")


if __name__ == "__main__":
    main()
