"""Sampled profile of the real (uninstrumented) renderer plan: render tics in a loop for N seconds,
then group V$ACTIVE_SESSION_HISTORY samples by plan line. usage: ash_profile.py sql seconds [tics]"""
import sys, time, collections
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
name = sys.argv[1]; secs = float(sys.argv[2]) if len(sys.argv) > 2 else 60
tics = [int(t) for t in (sys.argv[3] if len(sys.argv) > 3 else "100,300,500,700,900,1100").split(",")]
conn = doomora.connect(); r = doomora.Renderer(conn, name); P = doomora.load_poses()
r.render(tics[0], P[tics[0]])
c = conn.cursor(); c.execute("SELECT prev_sql_id, prev_child_number, SYS_CONTEXT('USERENV','SID') FROM v$session WHERE sid = SYS_CONTEXT('USERENV','SID')")
sql_id, child, sid = c.fetchone()
c.execute("SELECT SYSTIMESTAMP FROM dual"); t0 = c.fetchone()[0]
end = time.time() + secs; n = 0
while time.time() < end:
    for t in tics: r.render(t, P[t]); n += 1
c.execute("""SELECT NVL(sql_plan_line_id, -1), COUNT(*) FROM v$active_session_history
             WHERE sample_time >= :t0 AND session_id = :sid AND sql_id = :q GROUP BY sql_plan_line_id""", t0=t0, sid=int(sid), q=sql_id)
cnt = dict(c.fetchall()); tot = sum(cnt.values())
c.execute("SELECT id, LPAD(' ', depth) || operation || ' ' || options, object_name, cardinality FROM v$sql_plan WHERE sql_id = :q AND child_number = :c ORDER BY id", q=sql_id, c=child)
plan = c.fetchall()
print(f"{n} frames, {tot} samples, sql_id {sql_id}")
for pid, op, obj, card in plan:
    if cnt.get(pid, 0) * 100 >= tot * 0.8 or (len(sys.argv) > 4):
        print(f"{pid:4d} {100*cnt.get(pid,0)/max(tot,1):5.1f}%  {op[:60]:60s} {obj or '':28s} {card}")
print("unattributed", cnt.get(-1, 0))
