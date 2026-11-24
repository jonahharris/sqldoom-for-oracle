"""Line-level profile of the hybrid renderer with DBMS_PROFILER (creates the profiler tables in
the doom schema from $ORACLE_HOME/rdbms/admin/proftab.sql's DDL if missing).

    python tests/hybrid_lineprof.py [tic] [frames] [top]
Profiles `frames` hot renders of one tic and prints the most expensive source lines of
DOOM_HYBRID (total ms per frame, executions per frame).
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora

DDL = [
 """create table plsql_profiler_runs (runid number primary key, related_run number, run_owner varchar2(128),
    run_date date, run_comment varchar2(2047), run_total_time number, run_system_info varchar2(2047),
    run_comment1 varchar2(2047), spare1 varchar2(256))""",
 """create table plsql_profiler_units (runid number references plsql_profiler_runs, unit_number number,
    unit_type varchar2(128), unit_owner varchar2(128), unit_name varchar2(128), unit_timestamp date,
    total_time number default 0 not null, spare1 number, spare2 number, primary key (runid, unit_number))""",
 """create table plsql_profiler_data (runid number, unit_number number, line# number not null,
    total_occur number, total_time number, min_time number, max_time number, spare1 number, spare2 number,
    spare3 number, spare4 number, primary key (runid, unit_number, line#),
    foreign key (runid, unit_number) references plsql_profiler_units)""",
 "create sequence plsql_profiler_runnumber start with 1 nocache",
]
tic = int(sys.argv[1]) if len(sys.argv) > 1 else 500
frames = int(sys.argv[2]) if len(sys.argv) > 2 else 5
top = int(sys.argv[3]) if len(sys.argv) > 3 else 40
conn = doomora.connect(); cur = conn.cursor()
cur.execute("select count(*) from user_tables where table_name = 'PLSQL_PROFILER_RUNS'")
if cur.fetchone()[0] == 0:
    for d in DDL: cur.execute(d)
r = doomora.Renderer(conn, "render_hybrid.sql"); poses = doomora.load_poses()
r.render(tic, poses[tic])
runid = cur.var(int)
cur.execute("begin :r := 0; dbms_profiler.start_profiler('hybrid', run_number => :r); end;", r=runid)
for _ in range(frames):
    r.render(tic, poses[tic])
cur.execute("begin dbms_profiler.stop_profiler; dbms_profiler.flush_data; end;")
rid = runid.getvalue()
cur.execute("""select d.line#, d.total_occur / :f, d.total_time / 1e6 / :f, s.text
               from plsql_profiler_data d join plsql_profiler_units u on u.runid = d.runid and u.unit_number = d.unit_number
               left join user_source s on s.name = u.unit_name and s.type = u.unit_type and s.line = d.line#
               where d.runid = :r and u.unit_name = 'DOOM_HYBRID' and u.unit_type = 'PACKAGE BODY'
               order by d.total_time desc fetch first :t rows only""", f=frames, r=rid, t=top)
tot = 0
rows = cur.fetchall()
cur.execute("""select sum(d.total_time) / 1e6 / :f from plsql_profiler_data d join plsql_profiler_units u
               on u.runid = d.runid and u.unit_number = d.unit_number where d.runid = :r and u.unit_name = 'DOOM_HYBRID'""",
            f=frames, r=rid)
print(f"run {rid}: profiled PL/SQL time per frame {cur.fetchone()[0]:.1f} ms (profiler overhead inflates it)")
for line, occ, ms, text in rows:
    print(f"{line:5d} {ms:7.2f} ms {occ:9.0f}x  {(text or '').strip()[:110]}")
