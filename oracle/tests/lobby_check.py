#!/usr/bin/env python3
"""The lobby and the seat housekeeping with a live referee (CedarDB scripts/lobby_probe.mjs, the
api_join queue, doom_mp_reap's IDLE_SECONDS and doom_server.py's HOLD_MINUTES turnover).

    python oracle/tests/lobby_check.py

Six test players. Four take the seats; two more wait: api_join answers -1, api_match shows
waiting 2 and each one's ahead_of_me (first come, first served). A seated player that stops
calling (no api_camera heartbeat) is reaped after its 15 s join grace + IDLE_SECONDS, and the
seat goes to the FIRST waiter only. A seat held longer than HOLD_MINUTES while somebody waits goes
back to the lobby and the remaining waiter gets it. A waiter that stops asking leaves the queue
after five seconds.
"""
import sys
import threading
import time

import mp_lib_api as L

NAMES = [f"LB_P{i}" for i in range(1, 7)]
ENV = dict(MAP_ID=1, SKILL=2, TIMER_TICS=0, ROTATION="E1M1", MONSTERS=0, IDLE_SECONDS=3, HOLD_MINUTES=0.75)
bad = 0


def check(cond, what):
    global bad
    bad += 0 if cond else 1
    print(f"  {'ok ' if cond else 'BAD'} {what}", flush=True)


class Seat(threading.Thread):
    """A player that keeps its slot alive the way a client does (api_camera ~10 Hz) and, when it has
    no slot, asks for one once a second (api_join)."""

    def __init__(self, name):
        super().__init__(daemon=True)
        self.name, self.p = name, L.player(name)
        self.quiet = threading.Event()
        self.stop = threading.Event()
        self.pid = -1
        self.joins = []
        self.lock = threading.Lock()

    def run(self):
        last_join = 0.0
        while not self.stop.is_set():
            if not self.quiet.is_set():
                with self.lock:
                    if self.p.slot() < 0 and time.time() - last_join >= 1.0:
                        self.pid = self.p.join()
                        self.joins.append((round(time.time(), 1), self.pid))
                        last_join = time.time()
                    elif self.p.slot() >= 0:
                        self.p.camera(1.0)
                        self.p.end_read()
            time.sleep(0.1)

    def match(self):
        with self.lock:
            return self.p.query("SELECT waiting, ahead_of_me, hold_seconds, my_seat_seconds FROM api_match")[0]

    def slot(self):
        with self.lock:
            return self.p.slot()


def main():
    L.make_accounts(NAMES)
    ref = L.RefereeProcess(ENV)
    seats = []
    try:
        if not ref.wait_for("ready in"):
            print("\n".join(ref.lines))
            return 1
        for n in NAMES[:4]:
            s = Seat(n)
            s.start()
            seats.append(s)
            time.sleep(0.3)
        time.sleep(2)
        held = {s.name: s.slot() for s in seats}
        check(sorted(held.values()) == [1, 2, 3, 4], f"four seats taken: {held}")
        w1 = Seat(NAMES[4]); w1.start(); seats.append(w1)
        time.sleep(1.5)
        w2 = Seat(NAMES[5]); w2.start(); seats.append(w2)
        time.sleep(2.5)
        m1, m2 = w1.match(), w2.match()
        check(w1.pid < 0 and w2.pid < 0, f"the fifth and sixth player wait (api_join = {w1.pid}, {w2.pid})")
        check(m1[0] == 2 and m1[1] == 0 and m2[1] == 1,
              f"api_match: waiting {m1[0]}, ahead of {NAMES[4]} {m1[1]}, ahead of {NAMES[5]} {m2[1]}")
        # a seated player goes quiet
        quiet = seats[2]
        quiet_slot = quiet.slot()
        quiet.quiet.set()
        t_quiet = time.time()
        conn, cur = L.owner()
        got = None
        while time.time() - t_quiet < 30:
            cur.execute("SELECT role_name FROM g_mp_players WHERE slot = :s", s=quiet_slot)
            role = cur.fetchone()[0]
            if role != quiet.name:
                got = (round(time.time() - t_quiet, 1), role)
                break
            time.sleep(0.2)
        check(got is not None, f"{quiet.name} (slot {quiet_slot}) lost its seat {got and got[0]} s after going quiet "
                               "(15 s join grace + IDLE_SECONDS 3)")
        check(any(f"slot {quiet_slot} freed ({quiet.name}" in l and "idle" in l for l in ref.lines),
              "the referee logged the idle reap")
        time.sleep(2.5)
        cur.execute("SELECT role_name FROM g_mp_players WHERE slot = :s", s=quiet_slot)
        taker = cur.fetchone()[0]
        check(taker == NAMES[4], f"the first waiter ({NAMES[4]}) took slot {quiet_slot}: {taker}")
        check(w2.slot() < 0, f"the second waiter still waits; ahead of it: {w2.match()[1]}")
        cur.execute("SELECT CASE WHEN alive THEN 1 ELSE 0 END FROM g_player_state ps JOIN g_mp_players mp "
                    "ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id WHERE mp.slot = :s", s=quiet_slot)
        check(cur.fetchone()[0] == 1, "the new holder was respawned by the next tic")
        # the hold limit: seats held past HOLD_MINUTES (45 s) while LB_P6 waits go back to the lobby
        t_hold = time.time()
        turned = None
        while time.time() - t_hold < 60:
            lines = [l for l in ref.lines if "turn over" in l]
            if lines and w2.slot() >= 0:
                turned = (round(time.time() - t_hold, 1), lines)
                break
            time.sleep(0.5)
        check(turned is not None and len(turned[1]) >= 1,
              f"seats held past 45 s with someone waiting went back: {turned and [l.split('] ')[1] for l in turned[1]]}")
        check(w2.slot() >= 0, f"and the waiting {NAMES[5]} got a seat (slot {w2.slot()})")
        # a waiter that stops asking leaves the queue after five seconds
        cur.execute("SELECT COUNT(*) FROM g_mp_waiting")
        n0 = cur.fetchone()[0]
        for s in seats:
            if s.slot() < 0:
                s.quiet.set()
        time.sleep(7)
        cur.execute("SELECT COUNT(*) FROM g_mp_waiting")
        n1 = cur.fetchone()[0]
        check(n0 >= 1 and n1 == 0, f"quiet waiters leave the queue after 5 s ({n0} -> {n1})")
        conn.close()
    finally:
        for s in seats:
            s.stop.set()
        for s in seats:
            s.join(3)
            s.p.close()
        ref.stop()
        L.match_cleanup()
        print("accounts:", L.drop_accounts(NAMES))
    errs = [l for l in ref.lines if "Traceback" in l or "dropped a tic" in l]
    check(not errs, f"referee log clean ({len(errs)} problems)")
    for l in ref.lines:
        if "claimed" in l or "freed" in l or "turn over" in l:
            print("    " + l)
    print("LOBBY OK" if not bad else f"LOBBY: {bad} problems")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
