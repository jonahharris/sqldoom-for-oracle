#!/usr/bin/env python3
"""Frame latency through the web bridge vs direct (phase 6).

Direct: the player's own sessions with python-oracledb, exactly what the bridge does per browser --
one session sends api_input + reads own state + sound events/loops at 35 Hz, one session loops
api_camera(0.5) + SET TRANSACTION READ ONLY, then the slot's frame view (200 rows). Bridge: the
same through doom_web.py with tests/web_smoke.mjs (Node, the page's own oraws.js). Same account
kind, same map, same duration; run one after the other.

    web_latency.py USER PASSWORD [--seconds 8] [--bridge ws://127.0.0.1:8080/ws] [--json out.json]
"""
import argparse, json, subprocess, sys, threading, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "client"))
import api_client  # noqa: E402


def stat(v):
    v = sorted(v)
    return {"mean": round(sum(v) / len(v), 2), "p50": round(v[len(v) // 2], 2), "p95": round(v[int(len(v) * 0.95)], 2)}


def direct(user, password, seconds):
    tic = api_client.ApiPlayer(user, password)
    fr = api_client.ApiPlayer(user, password)
    pid = -1
    for _ in range(30):
        pid = tic.join()
        if pid >= 0:
            break
        time.sleep(1)
    if pid < 0:
        raise SystemExit("no free slot")
    m, slot = fr.where()
    stop = threading.Event()
    ticms = []

    def ticker():
        n, last = 0, 0
        nxt = time.perf_counter()
        while not stop.is_set():
            s = time.perf_counter()
            tic.input((1, 0, False, 2.0, n % 20 == 0, None, False))
            tic.query("SELECT alive, health, frags, position_x, position_y FROM api_player_state")
            ev = tic.query("SELECT event_id, sound_name, volume, pan FROM api_sound_events WHERE event_id > :a "
                           "ORDER BY event_id", a=last)
            if ev:
                last = max(e[0] for e in ev)
            tic.query("SELECT loop_key, sound_name, volume, pan FROM api_sound_loops")
            tic.conn.rollback()
            ticms.append((time.perf_counter() - s) * 1e3)
            n += 1
            nxt += 1 / 35
            time.sleep(max(0, nxt - time.perf_counter()))

    th = threading.Thread(target=ticker, daemon=True)
    th.start()
    rtt = []
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < seconds:
        s = time.perf_counter()
        fr.camera(0.5)
        rows = fr.frame_rows(m, slot)
        fr.end_read()
        frame, _pal = __import__("doom_client").decode_rows(rows)
        assert frame.shape == (200, 320)
        rtt.append((time.perf_counter() - s) * 1e3)
    stop.set()
    th.join()
    el = time.perf_counter() - t0
    tic.close()
    fr.close()
    return {"frames": len(rtt), "fps": round(len(rtt) / el, 1), "frame_rtt_ms": stat(rtt), "tics": len(ticms),
            "tic_rtt_ms": stat(ticms)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("user")
    ap.add_argument("password")
    ap.add_argument("--seconds", type=float, default=8)
    ap.add_argument("--bridge", default="ws://127.0.0.1:8080/ws")
    ap.add_argument("--json")
    a = ap.parse_args()
    d = direct(a.user, a.password, a.seconds)
    print("direct:", json.dumps(d), flush=True)
    time.sleep(7)          # the referee reaps the direct seat; the bridge run joins afresh
    r = subprocess.run(["node", str(HERE / "web_smoke.mjs"), a.bridge, a.user, a.password, str(a.seconds)],
                       capture_output=True, text=True, timeout=120)
    line = [l for l in r.stdout.splitlines() if l.startswith("{")]
    b = json.loads(line[-1]) if line else {"error": r.stdout[-500:] + r.stderr[-500:]}
    print("bridge:", json.dumps(b))
    if a.json:
        Path(a.json).write_text(json.dumps({"direct": d, "bridge": b}, indent=1))


if __name__ == "__main__":
    main()
