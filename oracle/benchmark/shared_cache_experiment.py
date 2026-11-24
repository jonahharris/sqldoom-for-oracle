#!/usr/bin/env python3
"""Option B of the hybrid memory study: can wall texels live in the SGA, shared by all sessions,
and be fetched per frame instead of being held in every session's package state?

    python benchmark/shared_cache_experiment.py [--json benchmark/results/shared_cache_experiment.json]

Measured per "frame" = the wall working set of a real frame (tests/hybrid_debugsum.py on an
instrumented build, tics 1..1200 step 10: mean 11.6 textures / 449 columns / 54k texels, max 24 /
883 / 104k):
  rc_tex   PL/SQL function result cache (SGA), one call per texture returning its column-major texels
           (INDEX BY collection, copied into the session on every call)
  rc_col   result cache, one call per touched texture column (h texels)
  sql_pk   buffer-cached heap table DOOM_RCX_COLS (name, u) -> RAW column: one PK SELECT per column
           (what MEMOPTIMIZE FOR READ would accelerate; the PL/SQL->SQL call per row remains)
  sql_bulk one BULK COLLECT per texture of its touched column range
  conv     RAW column -> PLS_INTEGER texels (needed after sql_*; the hot loops index integer arrays)
Also: SGA bytes of the result cache holding the run's textures, session memory after the frames.
result_cache_max_size / _max_result are raised with SCOPE=MEMORY for the test and restored.
The helper package DOOM_RCX and table DOOM_RCX_COLS are dropped at the end.
"""
import argparse, json, sys
from pathlib import Path
import oracledb

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora  # noqa: E402

SYS = dict(user="system", password="DoomSys_26ai", dsn=doomora.DSN)

PKG = """
CREATE OR REPLACE PACKAGE doom_rcx AS
  TYPE t_i IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
  FUNCTION tex(p_name VARCHAR2) RETURN t_i RESULT_CACHE;
  FUNCTION col(p_name VARCHAR2, p_u PLS_INTEGER) RETURN t_i RESULT_CACHE;
  FUNCTION run(p_mode VARCHAR2, p_ntex PLS_INTEGER, p_ncol PLS_INTEGER, p_reps PLS_INTEGER) RETURN NUMBER;
END;"""
BODY = """
CREATE OR REPLACE PACKAGE BODY doom_rcx AS
  TYPE t_v IS TABLE OF VARCHAR2(16) INDEX BY PLS_INTEGER;
  TYPE t_tt IS TABLE OF t_i INDEX BY PLS_INTEGER;
  TYPE t_r IS TABLE OF RAW(2000) INDEX BY PLS_INTEGER;
  hv PLS_INTEGER;
  FUNCTION hexval(h VARCHAR2) RETURN PLS_INTEGER IS BEGIN RETURN TO_NUMBER(h, 'XX'); END;
  FUNCTION tex(p_name VARCHAR2) RETURN t_i RESULT_CACHE IS
    b BLOB; w PLS_INTEGER; h PLS_INTEGER; r t_i; hx VARCHAR2(32767);
  BEGIN
    SELECT palette_indices, width, height INTO b, w, h FROM walltex_meta WHERE name = p_name;
    FOR rr IN 0 .. h - 1 LOOP
      hx := RAWTOHEX(DBMS_LOB.SUBSTR(b, w, rr * w + 1));
      FOR u IN 0 .. w - 1 LOOP r(u * h + rr) := TO_NUMBER(SUBSTR(hx, 2 * u + 1, 2), 'XX'); END LOOP;
    END LOOP;
    RETURN r;
  END;
  FUNCTION col(p_name VARCHAR2, p_u PLS_INTEGER) RETURN t_i RESULT_CACHE IS
    b BLOB; w PLS_INTEGER; h PLS_INTEGER; r t_i;
  BEGIN
    SELECT palette_indices, width, height INTO b, w, h FROM walltex_meta WHERE name = p_name;
    FOR rr IN 0 .. h - 1 LOOP r(rr) := TO_NUMBER(RAWTOHEX(DBMS_LOB.SUBSTR(b, 1, rr * w + MOD(p_u, w) + 1)), 'XX'); END LOOP;
    RETURN r;
  END;
  FUNCTION run(p_mode VARCHAR2, p_ntex PLS_INTEGER, p_ncol PLS_INTEGER, p_reps PLS_INTEGER) RETURN NUMBER IS
    names t_v; ws t_i; t0 TIMESTAMP(6) WITH TIME ZONE; d INTERVAL DAY TO SECOND; tt t_tt; c t_i; acc PLS_INTEGER := 0;
    pr RAW(2000); rs t_r; per PLS_INTEGER := CEIL(p_ncol / p_ntex); hx VARCHAR2(4000); k PLS_INTEGER;
  BEGIN
    SELECT name, width BULK COLLECT INTO names, ws FROM (
      SELECT DISTINCT w.name, w.width FROM walltex_meta w JOIN render_segs_ext s
        ON w.name IN (s.upper_tex, s.mid_tex, s.lower_tex) WHERE s.map_id = 1 AND w.height = 128 ORDER BY w.name)
      WHERE ROWNUM <= p_ntex;
    t0 := SYSTIMESTAMP;
    FOR rep IN 1 .. p_reps LOOP
      tt.DELETE;
      FOR i IN 1 .. names.COUNT LOOP
        IF p_mode = 'rc_tex' THEN tt(i) := tex(names(i)); acc := acc + tt(i)(0);
        ELSIF p_mode = 'rc_col' THEN
          FOR u IN 0 .. per - 1 LOOP c := col(names(i), u); acc := acc + c(0); END LOOP;
        ELSIF p_mode = 'sql_pk' THEN
          FOR uu IN 0 .. per - 1 LOOP
            SELECT pix INTO pr FROM doom_rcx_cols WHERE name = names(i) AND u = MOD(uu, ws(i)); acc := acc + UTL_RAW.LENGTH(pr);
          END LOOP;
        ELSIF p_mode = 'sql_bulk' THEN
          SELECT pix BULK COLLECT INTO rs FROM doom_rcx_cols WHERE name = names(i) AND u BETWEEN 0 AND per - 1;
          acc := acc + rs.COUNT;
        ELSIF p_mode = 'conv' THEN
          SELECT pix BULK COLLECT INTO rs FROM doom_rcx_cols WHERE name = names(i) AND u BETWEEN 0 AND per - 1;
          IF rep = 1 THEN t0 := SYSTIMESTAMP; END IF;
          k := 0;
          FOR j IN 1 .. rs.COUNT LOOP
            hx := RAWTOHEX(rs(j));
            FOR rr IN 0 .. 127 LOOP c(k) := TO_NUMBER(SUBSTR(hx, 2 * rr + 1, 2), 'XX'); k := k + 1; END LOOP;
          END LOOP;
        END IF;
      END LOOP;
    END LOOP;
    d := SYSTIMESTAMP - t0;
    hv := acc;
    RETURN (EXTRACT(SECOND FROM d) + 60 * EXTRACT(MINUTE FROM d) + 3600 * EXTRACT(HOUR FROM d)) * 1000 / p_reps;
  END;
END;"""


def mystat(cur):
    cur.execute("""SELECT n.name, s.value FROM v$mystat s JOIN v$statname n ON n.statistic# = s.statistic#
                   WHERE n.name IN ('session pga memory', 'session uga memory')""")
    return {k: round(v / 1048576, 2) for k, v in cur.fetchall()}


def rc_mem(scur):
    scur.execute("SELECT name, value FROM v$result_cache_statistics WHERE name IN "
                 "('Block Size (Bytes)', 'Block Count Current', 'Create Count Success', 'Find Count')")
    st = {k: int(v) for k, v in scur.fetchall()}
    scur.execute("SELECT ROUND(SUM(bytes) / 1048576, 2) FROM v$sgastat WHERE name LIKE 'Result Cache%'")
    st["sgastat_result_cache_mb"] = float(scur.fetchone()[0] or 0)
    st["result_cache_mb"] = round(st.get("Block Size (Bytes)", 0) * st.get("Block Count Current", 0) / 1048576, 2)
    return st


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--json")
    a = ap.parse_args()
    sconn = oracledb.connect(**SYS); scur = sconn.cursor()
    scur.execute("SELECT name, value FROM v$parameter WHERE name IN ('result_cache_max_size', 'result_cache_max_result')")
    orig = dict(scur.fetchall())
    scur.execute("ALTER SYSTEM SET result_cache_max_size = 128M SCOPE = MEMORY")
    scur.execute("ALTER SYSTEM SET result_cache_max_result = 50 SCOPE = MEMORY")
    scur.execute("BEGIN DBMS_RESULT_CACHE.FLUSH; END;")
    conn = doomora.connect(); cur = conn.cursor()
    res = {"working_set": {"mean": {"textures": 11.6, "columns": 449, "texels": 53700},
                           "max": {"textures": 24, "columns": 883, "texels": 104064}}}
    try:
        cur.execute(PKG); cur.execute(BODY)
        cur.execute("SELECT COUNT(*) FROM user_tables WHERE table_name = 'DOOM_RCX_COLS'")
        if cur.fetchone()[0]: cur.execute("DROP TABLE doom_rcx_cols PURGE")
        cur.execute("CREATE TABLE doom_rcx_cols (name VARCHAR2(16), u NUMBER, pix RAW(2000), PRIMARY KEY (name, u))")
        cur.execute("""DECLARE b BLOB; hx VARCHAR2(32767); cx VARCHAR2(32767); BEGIN
          FOR t IN (SELECT DISTINCT w.name, w.width, w.height FROM walltex_meta w JOIN render_segs_ext s
                      ON w.name IN (s.upper_tex, s.mid_tex, s.lower_tex) WHERE s.map_id = 1 AND w.height = 128) LOOP
            SELECT palette_indices INTO b FROM walltex_meta WHERE name = t.name;
            FOR u IN 0 .. t.width - 1 LOOP
              cx := NULL;
              FOR r IN 0 .. t.height - 1 LOOP cx := cx || RAWTOHEX(DBMS_LOB.SUBSTR(b, 1, r * t.width + u + 1)); END LOOP;
              INSERT INTO doom_rcx_cols VALUES (t.name, u, HEXTORAW(cx));
            END LOOP;
          END LOOP; COMMIT; END;""")
        m0 = mystat(cur)
        out = {}
        for label, nt, nc in (("mean", 12, 449), ("max", 24, 883)):
            for mode in ("rc_tex", "rc_col", "sql_pk", "sql_bulk", "conv"):
                cur.execute("SELECT doom_rcx.run(:m, :t, :c, 1) FROM dual", m=mode, t=nt, c=nc)   # populate / warm
                cur.execute("SELECT doom_rcx.run(:m, :t, :c, 1) FROM dual", m=mode, t=nt, c=nc)
                cur.execute("SELECT doom_rcx.run(:m, :t, :c, 20) FROM dual", m=mode, t=nt, c=nc)
                out[f"{mode}_{label}_ms_per_frame"] = round(cur.fetchone()[0], 3)
                print(mode, label, out[f"{mode}_{label}_ms_per_frame"], "ms/frame", flush=True)
        res["per_frame_ms"] = out
        res["session_mem_mb_before"] = m0; res["session_mem_mb_after"] = mystat(cur)
        scur.execute("BEGIN DBMS_RESULT_CACHE.FLUSH; END;")
        cur.execute("SELECT doom_rcx.run('rc_tex', 1000, 1000, 1) FROM dual")   # all map-1 textures of height 128
        cur.execute("""SELECT COUNT(*), SUM(w.width * w.height) FROM (SELECT DISTINCT w.name, w.width, w.height FROM walltex_meta w
                       JOIN render_segs_ext s ON w.name IN (s.upper_tex, s.mid_tex, s.lower_tex)
                       WHERE s.map_id = 1 AND w.height = 128) w""")
        n, tx = cur.fetchone()
        res["rc_all_map1_textures"] = {"textures": n, "texels": tx, **rc_mem(scur)}
        res["rc_all_map1_textures"]["bytes_per_texel"] = round(res["rc_all_map1_textures"]["result_cache_mb"] * 1048576 / tx, 2)
        print(json.dumps(res, indent=1))
        if a.json: Path(a.json).write_text(json.dumps(res, indent=1))
    finally:
        for stmt in ("DROP PACKAGE doom_rcx", "DROP TABLE doom_rcx_cols PURGE"):
            try: cur.execute(stmt)
            except oracledb.DatabaseError: pass
        scur.execute("BEGIN DBMS_RESULT_CACHE.FLUSH; END;")
        scur.execute(f"ALTER SYSTEM SET result_cache_max_size = {orig['result_cache_max_size']} SCOPE = MEMORY")
        scur.execute(f"ALTER SYSTEM SET result_cache_max_result = {orig['result_cache_max_result']} SCOPE = MEMORY")


if __name__ == "__main__":
    main()
