#!/usr/bin/env python3
"""One referee per match (CedarDB doom_server.py's heartbeat in mp_referee): a second referee
refuses to start while the first one's heartbeat is fresh, SIGINT and SIGTERM release the match,
a crashed referee's heartbeat is waited out (3 s), and the clock runs at 35 tics a second.

    python oracle/tests/referee_check.py
"""
import signal
import sys
import time

import mp_lib_api as L

ENV = dict(MAP_ID=1, SKILL=2, TIMER_TICS=0, ROTATION="E1M1", MONSTERS=1)
bad = 0


def check(cond, what):
    global bad
    bad += 0 if cond else 1
    print(f"  {'ok ' if cond else 'BAD'} {what}", flush=True)


def heartbeat():
    conn, cur = L.owner()
    cur.execute("SELECT COUNT(*), MAX(doom_mp.secs_since(heartbeat)) FROM g_mp_referee")
    n, age = cur.fetchone()
    conn.close()
    return n, age


def level_tics():
    conn, cur = L.owner()
    cur.execute("SELECT level_tics FROM mp_stats")
    row = cur.fetchone()
    conn.close()
    return row[0] if row else None


def main():
    print("referee A starts")
    a = L.RefereeProcess(ENV)
    check(a.wait_for("ready in"), "A is ready")
    n, age = heartbeat()
    check(n == 1 and age is not None and age < 2, f"A's heartbeat row is fresh ({age and round(age, 2)} s)")
    # the clock: 35 tics a second
    t0, l0 = time.time(), level_tics()
    time.sleep(5)
    t1, l1 = time.time(), level_tics()
    rate = (l1 - l0) / (t1 - t0)
    check(33.5 <= rate <= 35.5, f"A runs {rate:.1f} tics/s")
    print("referee B starts while A runs")
    b = L.RefereeProcess(ENV)
    b.p.wait(30)
    check(b.p.returncode == 2 and any("another referee" in l for l in b.lines),
          f"B refuses to start (exit {b.p.returncode}): {b.lines[-1] if b.lines else ''}")
    t0, l0 = time.time(), level_tics()
    time.sleep(3)
    rate = (level_tics() - l0) / (time.time() - t0)
    check(33.5 <= rate <= 35.5, f"the world still runs at {rate:.1f} tics/s (not double speed)")
    print("SIGINT to A")
    check(a.stop(signal.SIGINT), "A stops on SIGINT within 15 s")
    check(any("stopped" in l for l in a.lines), "A logs 'stopped'")
    n, _ = heartbeat()
    check(n == 0, f"A released the match (heartbeat rows: {n})")
    print("referee C starts right away, then crashes (SIGKILL)")
    c = L.RefereeProcess(ENV)
    check(c.wait_for("ready in"), "C starts at once after a clean stop")
    c.stop(signal.SIGKILL)
    n, age = heartbeat()
    check(n == 1, f"a crashed referee leaves its heartbeat ({age and round(age, 2)} s old)")
    d = L.RefereeProcess(ENV)
    d.p.wait(30)
    check(d.p.returncode == 2, f"D, started within 3 s of the crash, refuses (exit {d.p.returncode})")
    time.sleep(3.2)
    e = L.RefereeProcess(ENV)
    check(e.wait_for("ready in"), "E, started after the 3 s wait-out, takes the match")
    print("SIGTERM to E")
    check(e.stop(signal.SIGTERM), "E stops on SIGTERM")
    n, _ = heartbeat()
    check(n == 0, f"E released the match (heartbeat rows: {n})")
    errs = [l for p in (a, c, e) for l in p.lines if "Traceback" in l or "dropped a tic" in l]
    check(not errs, f"referee logs clean ({len(errs)} problems)" + (f": {errs[0][:120]}" if errs else ""))
    L.match_cleanup()
    print("ONE REFEREE OK" if not bad else f"ONE REFEREE: {bad} problems")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
