#!/usr/bin/env python3
"""Deathmatch referee on Oracle (CedarDB doom_server.py).

Connects as the game owner, opens a match on MAP_ID with four free slots, installs the per-slot
frame views of every map of the rotation, and runs the shared world tic at 35 Hz. Players connect
as their own accounts (client/accounts.py) and reach the game only through the api_* functions and
views (client/api_client.py).

    MAP_ID=1 SKILL=2 python oracle/client/referee.py [--tics N] [--seconds S] [--json out.json]

Configuration (environment, the same names and defaults as doom_server.py):
    SKILL 2, ALTDEATH 1, TIMER_MINUTES 10 (or TIMER_TICS), INTERMISSION_SECONDS 10, MONSTERS 1,
    RESPAWN_MONSTERS 1, ROTATION E1M1,...,E1M7, IDLE_SECONDS 5, HOLD_MINUTES 15
    SPRITE_MODE vanilla (or cedar; --cedar-exact): how every player's frame view renders sprites --
    vanilla = Doom's sprite clipping (items stand on the floor), cedar = exactly as the CedarDB
    reference (sprites depth-tested against floors). Stored in g_mp_match.sprite_mode; players
    cannot change it.

What it does, as doom_server.py:
  * one referee per match: a heartbeat row in g_mp_referee (doom_mp.referee_claim); a second
    referee refuses to start while the heartbeat is fresh (3 s); SIGINT/SIGTERM release it; after
    a crash the next start waits the 3 seconds out
  * 35 Hz clock: one round trip per tic (doom_mp.tic: run_mp_tic as one SERIALIZABLE transaction,
    committed; a failed tic is rolled back and its inputs dropped, counted as dropped)
  * once a second: heartbeat, idle reaping (IDLE_SECONDS), seat turnover (HOLD_MINUTES while
    someone waits), the lobby queue's stale waiters; logs who came and went
  * every five seconds: tic median/p90/max, dropped tics, mp_stats, the board; api_tic_stats
  * level end (-timer, an exit): intermission for INTERMISSION_SECONDS, then doom_mp.rotate to
    the next map of the rotation with every held slot carried over
  * at start: the join path runs once (two tics around doom_mp.request_all, then vacate_all) so
    the first real join does not pay for first executions
"""
import argparse
import json
import os
import signal
import statistics
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import oradb  # noqa: E402
import game_api  # noqa: E402
import api_install  # noqa: E402

TIC_SECONDS = 1.0 / 35.0
MATCH_KEY = 0
STOPPING = False

TIC_SQL = "BEGIN :r := doom_mp.tic(:m, :s, :p1, :p2, :p3, :p4, :err); END;"
HOUSEKEEPING_SQL = """BEGIN
  doom_mp.referee_beat(:k);
  :freed := doom_mp.reap(:m, :idle);
  :turned := doom_mp.hold_turnover(:m, :hold);
  COMMIT;
END;"""
SLOTS_SQL = """SELECT mp.slot, mp.role_name, mp.display_name, ps.frags, ps.health, CASE WHEN ps.alive THEN 1 ELSE 0 END
  FROM g_mp_players mp JOIN g_player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id
 WHERE mp.map_id = :m ORDER BY mp.slot"""


def log(msg):
    print(msg, flush=True)


def _terminate(*_):
    global STOPPING
    STOPPING = True


def env_config():
    timer_tics = int(os.getenv("TIMER_TICS", int(float(os.getenv("TIMER_MINUTES", 10)) * 60 * 35)))
    return dict(
        map_id=int(os.getenv("MAP_ID", 1)), skill=int(os.getenv("SKILL", 2)),
        idle=int(os.getenv("IDLE_SECONDS", 5)), timer_tics=timer_tics,
        rotation=[m.strip().upper() for m in os.getenv("ROTATION", "E1M1,E1M2,E1M3,E1M4,E1M5,E1M6,E1M7").split(",")
                  if m.strip()],
        altdeath=os.getenv("ALTDEATH", "1") == "1", monsters=os.getenv("MONSTERS", "1") == "1",
        respawn=os.getenv("RESPAWN_MONSTERS", "1") == "1",
        intermission=float(os.getenv("INTERMISSION_SECONDS", 10)),
        hold=int(float(os.getenv("HOLD_MINUTES", 15)) * 60),
        sprite_mode=0 if os.getenv("SPRITE_MODE", "vanilla").strip().lower() in ("cedar", "exact", "cedar-exact", "0")
        else 1)


class Referee:
    def __init__(self, cfg):
        self.cfg = cfg
        self.conn = oradb.connect()
        self.cur = self.conn.cursor()
        game_api.setup_session(self.cur)
        self.map_id = cfg["map_id"]
        self.start_map = cfg["map_id"]
        self.players = {}
        self.rvar = self.cur.var(int)
        self.err = self.cur.var(str, 2000)
        self.tic_times, self.dropped, self.drop_reasons = [], 0, {}
        self.all_tics, self.late, self.n_tics, self.total_dropped, self.retried = [], 0, 0, 0, 0
        self.holders = {}
        self.housekeeping_error = None
        self.last_reap = self.last_report = self.report_at = time.perf_counter()

    # --------------------------------------------------------------- match control
    def claim(self):
        r = self.cur.var(int)
        self.cur.execute("BEGIN :r := doom_mp.referee_claim(:k, 3); END;", r=r, k=MATCH_KEY)
        return bool(r.getvalue())

    def release(self):
        try:
            self.conn.rollback()
            self.cur.execute("BEGIN doom_mp.referee_release(:k); END;", k=MATCH_KEY)
        except Exception:  # noqa: BLE001
            pass

    def mp_players(self, map_id):
        self.cur.execute("SELECT slot, player_thing_id FROM g_mp_players WHERE map_id = :m ORDER BY slot", m=map_id)
        return {int(s): int(p) for s, p in self.cur.fetchall()}

    def mp_start(self, map_id):
        n = self.cur.var(int)
        self.cur.execute("BEGIN :n := doom_game.mp_start(:m, :s); END;", n=n, m=map_id, s=self.cfg["skill"])
        self.conn.commit()
        return self.mp_players(map_id)

    def tic(self):
        p = self.players
        self.err.setvalue(0, None)
        self.cur.execute(TIC_SQL, r=self.rvar, err=self.err, m=self.map_id, s=self.cfg["skill"],
                         p1=p.get(1), p2=p.get(2), p3=p.get(3), p4=p.get(4))
        r = self.rvar.getvalue()
        if r is not None and r >= 0 and self.err.getvalue():
            self.retried += 1   # ORA-08177 on a fresh-snapshot retry (doom_mp.tic)
            if self.retried <= 3 or os.getenv("REFEREE_DEBUG"):
                log(f"[referee] tic retried: {' '.join(self.err.getvalue().split())[:300]}")
        if r is not None and r < 0:
            self.dropped += 1
            self.total_dropped += 1
            reason = (self.err.getvalue() or "?").split(" | ")[0]
            if reason not in self.drop_reasons:
                log(f"[referee] dropped a tic: {self.err.getvalue()}")
            self.drop_reasons[reason] = self.drop_reasons.get(reason, 0) + 1
            return False
        return bool(r)

    def open_match(self):
        c, cur = self.cfg, self.cur
        cur.execute("DELETE FROM g_mp_inputs")
        cur.execute("BEGIN doom_game.mp_configure(:m, :s, :t, :a, :mo, :r, :i); END;", m=self.map_id, s=c["skill"],
                    t=c["timer_tics"], a=int(c["altdeath"]), mo=int(c["monsters"]), r=int(c["respawn"]),
                    i=int(c["intermission"] * 35))
        api_install.ensure_match_columns(cur)
        cur.execute("UPDATE g_mp_match SET hold_seconds = :h, sprite_mode = :sm", h=c["hold"], sm=c["sprite_mode"])
        cur.execute("SELECT name FROM maps")
        loaded = {r[0] for r in cur.fetchall()}
        rotation = [m for m in c["rotation"] if m in loaded]
        for m in c["rotation"]:
            if m not in loaded:
                log(f"[referee] rotation: {m} is not loaded, skipped")
        cur.execute("DELETE FROM g_mp_rotation")
        for pos, name in enumerate(rotation):
            cur.execute("INSERT INTO g_mp_rotation (position, map_name) VALUES (:p, :n)", p=pos, n=name)
        self.conn.commit()
        log("[referee] match: " + ", ".join([
            f"timer {c['timer_tics'] / 35 / 60:.1f} min" if c["timer_tics"] else "no timer",
            "altdeath" if c["altdeath"] else "deathmatch 1.0",
            ("monsters" + (" respawning" if c["respawn"] else "")) if c["monsters"] else "nomonsters",
            "rotation " + (" > ".join(rotation) if rotation else "none"),
            f"intermission {c['intermission']:g} s",
            "vanilla sprites" if c["sprite_mode"] else "CedarDB-exact sprites",
            f"a seat is {c['hold'] / 60:g} min while others wait" if c["hold"] else "no seat limit"]))
        for attempt in range(30):
            try:
                self.players = self.mp_start(self.map_id)
                if not {1, 2} <= set(self.players):
                    raise SystemExit(f"map {self.map_id} has no player 1 and player 2 starts")
                cur.execute("SELECT map_id FROM maps WHERE name IN (SELECT map_name FROM g_mp_rotation) "
                            "OR map_id = :m ORDER BY map_id", m=self.map_id)
                api_install.install_frame_views(cur, [r[0] for r in cur.fetchall()])
                self.conn.commit()
                break
            except SystemExit:
                raise
            except Exception as exc:  # noqa: BLE001 - a client racing on g_mp_players
                self.conn.rollback()
                log(f"[referee] opening the match, retrying: {str(exc).splitlines()[0]}")
                time.sleep(0.2)
        else:
            raise SystemExit("could not open the match")
        log(f"[referee] deathmatch on map {self.map_id}, skill {c['skill']}: "
            + ", ".join(f"slot {s} = thing {t}" for s, t in sorted(self.players.items())) + "; all free")
        t0 = time.perf_counter()
        # warm the tic and the join path (doom_server.py): tic, request every slot, tic, vacate
        self.tic()
        cur.execute("BEGIN doom_mp.request_all(:m); COMMIT; END;", m=self.map_id)
        self.tic()
        cur.execute("BEGIN doom_game.mp_vacate_all(:m); COMMIT; END;", m=self.map_id)
        cur.execute("BEGIN doom_game.mp_open; COMMIT; END;")
        self.ready_s = time.perf_counter() - t0
        log(f"[referee] ready in {self.ready_s:.1f} s; players join with client/api_client.py")

    # --------------------------------------------------------------- housekeeping / report
    def housekeeping(self, force=False):
        if not force and time.perf_counter() - self.last_reap < 1.0:
            return
        self.last_reap = time.perf_counter()
        freed, turned = self.cur.var(int), self.cur.var(str, 4000)
        try:
            self.cur.execute(HOUSEKEEPING_SQL, k=MATCH_KEY, m=self.map_id, idle=self.cfg["idle"], hold=self.cfg["hold"],
                             freed=freed, turned=turned)
        except Exception as exc:  # noqa: BLE001 - a reap losing a race with a player's call: retry in 1 s
            self.conn.rollback()
            reason = str(exc).splitlines()[0]
            if reason != self.housekeeping_error:
                self.housekeeping_error = reason
                log(f"[referee] housekeeping skipped once: {reason}")
            return
        for item in (turned.getvalue() or "").split():
            slot, role = item.split(":", 1)
            log(f"[referee] slot {slot} turn over: {role} had it {self.cfg['hold'] / 60:g} min and someone is waiting")
        self.cur.execute(SLOTS_SQL, m=self.map_id)
        now = {r[0]: (r[1], r[2], r[3]) for r in self.cur.fetchall()}
        for slot, (role, name, frags) in now.items():
            was = self.holders.get(slot, (None, None, 0))[0]
            if role and not was:
                log(f"[referee] slot {slot} claimed by {role}" + (f' "{name}"' if name else ""))
            elif was and not role:
                log(f"[referee] slot {slot} freed ({was}, {self.holders[slot][2]} frags"
                    + (", idle" if freed.getvalue() else "") + ")")
            elif role and name and name != self.holders.get(slot, (None, None))[1]:
                log(f'[referee] slot {slot} {role} is now "{name}"')
        self.holders = now

    def report(self):
        t = sorted(self.tic_times)
        med = t[len(t) // 2] * 1e3 if t else 0
        p90 = t[int(len(t) * 0.9)] * 1e3 if t else 0
        mx = t[-1] * 1e3 if t else 0
        cur = self.cur
        cur.execute("SELECT map_name, state, timer_tics, level_tics, monsters_alive, monsters_total, monsters_awake, "
                    "projectiles, effects, items_out, items_queued, movers, input_backlog, sound_rows, sessions, "
                    "maps_played, waiting FROM mp_stats")
        st = cur.fetchone()
        clock = ""
        if st:
            left = (st[2] - st[3]) / 35 if st[2] > 0 else None
            clock = (f"{st[0]} {st[1]} " + (f"{int(left // 60)}:{int(left % 60):02d} left" if left is not None
                                            else f"{st[3] / 35:.0f} s") + f" (map {st[15] + 1} of the run)")
        log(f"[referee] {clock} | tic {med:.1f} ms p90 {p90:.1f} max {mx:.1f}, {len(t)} tics, {self.dropped} dropped"
            + ("" if not self.drop_reasons else " (" + "; ".join(f"{n}x {r[:70]}" for r, n in self.drop_reasons.items())
               + ")")
            + (f" | monsters {st[4]}/{st[5]} awake {st[6]} | projectiles {st[7]} effects {st[8]} movers {st[11]}"
               f" | items out {st[9]} queued {st[10]} | inputs waiting {st[12]} sounds {st[13]} | db sessions {st[14]}"
               f" | lobby {st[16]}" if st else ""))
        cur.execute(SLOTS_SQL, m=self.map_id)
        log("[referee]   " + "  ".join(f"P{s}[{role or 'free'}]: {frags} frags, {hp} hp{'' if alive else ' (dead)'}"
                                       for s, role, _n, frags, hp, alive in cur.fetchall()))
        now = time.perf_counter()
        interval, self.report_at = now - self.report_at, now
        cur.execute("""MERGE INTO api_tic_stats t USING (SELECT 1 AS id FROM dual) s ON (t.id = s.id)
            WHEN MATCHED THEN UPDATE SET updated_at = SYSTIMESTAMP, tic_ms = :a, tic_p90_ms = :b, tic_max_ms = :c,
                 tics = :n, dropped = :d, interval_seconds = :i
            WHEN NOT MATCHED THEN INSERT (id, updated_at, tic_ms, tic_p90_ms, tic_max_ms, tics, dropped, interval_seconds)
                 VALUES (1, SYSTIMESTAMP, :a, :b, :c, :n, :d, :i)""", a=med, b=p90, c=mx, n=len(t), d=self.dropped,
                    i=interval)
        self.conn.commit()
        self.tic_times.clear()
        self.dropped = 0
        self.drop_reasons.clear()

    def rotate(self):
        cur = self.cur
        cur.execute(SLOTS_SQL, m=self.map_id)
        log(f"[referee] level ended on map {self.map_id}: "
            + "  ".join(f"P{s}[{role or 'free'}] {frags}" for s, role, _n, frags, _h, _a in cur.fetchall()))
        cur.execute("BEGIN doom_mp.intermission_begin; COMMIT; END;")
        deadline = time.perf_counter() + self.cfg["intermission"] + 20
        over = cur.var(int)
        while not STOPPING:
            self.housekeeping()
            cur.execute("BEGIN :o := doom_mp.intermission_over; END;", o=over)
            if over.getvalue():
                break
            if time.perf_counter() > deadline:
                log("[referee] intermission never ended on the clock; moving on")
                break
            time.sleep(0.1)
        if STOPPING:
            return
        nxt = cur.var(int)
        for attempt in range(30):
            try:
                cur.execute("BEGIN :n := doom_mp.rotate; COMMIT; END;", n=nxt)
                self.map_id = int(nxt.getvalue())
                self.players = self.mp_players(self.map_id)
                break
            except Exception as exc:  # noqa: BLE001
                self.conn.rollback()
                log("[referee] rotate failed, retrying: " + str(exc).splitlines()[0])
                time.sleep(0.2 if attempt < 10 else 1.0)
        else:
            log("[referee] could not move the match on; reopening it on the start map")
            self.map_id = self.start_map
            self.players = self.mp_start(self.map_id)
            cur.execute("UPDATE g_mp_match SET map_id = :m, state = 'playing', intermission_until = NULL", m=self.map_id)
            self.conn.commit()
        cur.execute("SELECT COUNT(*) FROM g_mp_players WHERE map_id = :m AND role_name IS NOT NULL", m=self.map_id)
        held = cur.fetchone()[0]
        log(f"[referee] now on map {self.map_id}: "
            + ", ".join(f"slot {s} = thing {t}" for s, t in sorted(self.players.items()))
            + f"; {held} slot(s) carried over")

    # --------------------------------------------------------------- the clock
    def run(self, max_tics=0, max_seconds=0.0):
        started = time.perf_counter()
        next_tic = time.perf_counter()
        while not STOPPING:
            if max_tics and self.n_tics >= max_tics:
                break
            if max_seconds and time.perf_counter() - started >= max_seconds:
                break
            if 1 not in self.players:
                log(f"[referee] map {self.map_id} lost its slot rows; reopening")
                self.players = self.mp_start(self.map_id)
                continue
            t0 = time.perf_counter()
            if t0 - next_tic > TIC_SECONDS:
                self.late += 1
            level_done = self.tic()
            dt = time.perf_counter() - t0
            self.tic_times.append(dt)
            self.all_tics.append(dt * 1e3)
            self.n_tics += 1
            if level_done:
                self.rotate()
                next_tic = time.perf_counter()
                continue
            next_tic += TIC_SECONDS
            delay = next_tic - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
            elif delay < -0.5:
                next_tic = time.perf_counter()   # fell far behind (a stall): do not try to catch up
            self.housekeeping()
            if time.perf_counter() - self.last_report >= 5.0:
                self.last_report = time.perf_counter()
                self.report()
        return time.perf_counter() - started


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--tics", type=int, default=0, help="stop after this many tics (tests)")
    ap.add_argument("--seconds", type=float, default=0.0, help="stop after this many seconds (tests)")
    ap.add_argument("--json", type=Path, help="write the tic statistics here at the end")
    ap.add_argument("--cedar-exact", action="store_true",
                    help="players' frames render sprites exactly as CedarDB (SPRITE_MODE=cedar); default vanilla")
    a = ap.parse_args(argv)
    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)
    cfg = env_config()
    if a.cedar_exact:
        cfg["sprite_mode"] = 0
    ref = Referee(cfg)
    if not ref.claim():
        log("[referee] another referee is running the match (heartbeat within 3 s); stop it first, "
            "or wait 3 s if it just died")
        return 2
    wall = 0.0
    try:
        ref.open_match()
        wall = ref.run(a.tics, a.seconds)
    finally:
        ref.release()
        log("[referee] stopped")
    if a.json:
        t = sorted(ref.all_tics[35:]) or [0.0]
        a.json.write_text(json.dumps({
            "tics": ref.n_tics, "wall_s": wall, "tics_per_s": ref.n_tics / wall if wall else 0,
            "late": ref.late, "dropped": ref.total_dropped, "retried": ref.retried, "ready_s": getattr(ref, "ready_s", None),
            "tic_mean": statistics.mean(t), "tic_p50": t[len(t) // 2], "tic_p95": t[int(len(t) * 0.95)],
            "tic_max": t[-1], "tic_ms": ref.all_tics}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
