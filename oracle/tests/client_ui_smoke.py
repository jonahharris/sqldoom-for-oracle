#!/usr/bin/env python3
"""Phase 6: the desktop client's single-player flow, unattended (SDL dummy video/audio).

Drives client/doom_client.py with timed key events through everything a player does around the
tic: the title and attract loop, the menus (New Game, episode, skill), walking, typed cheats
(IDDQD, IDKFA), a weapon key, the automap (grid, zoom), Esc -> Save Game -> slot, Esc -> Load Game
-> slot, a level exit (the player placed at E1M1's exit switch by a scenario op, then Space), the
intermission (accelerated, then dismissed), the next level with the player carried over, a demo
recorded (F9) and played back (F10), IDCLEV13 (warp). Checks from the client's log that each step
happened, that every screen kind was drawn by doom_screen, that 3-D frames, sounds and music came.

    client_ui_smoke.py [--keep]
"""
import argparse, json, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = HERE / "out" / "p6"

SCRIPT = [
    {"t": 2.0, "press": "return"},           # any key ends the attract loop; title -> main menu
    {"t": 3.0, "press": "return"},           # New Game -> episode
    {"t": 4.0, "press": "return"},           # Knee-Deep in the Dead -> skill
    {"t": 5.0, "press": "return"},           # Hurt Me Plenty -> E1M1
    {"t": 6.0, "key": "w", "down": True}, {"t": 7.5, "key": "e", "down": True}, {"t": 8.0, "key": "e", "down": False},
    {"t": 9.0, "key": "w", "down": False},
    {"t": 9.2, "type": "iddqd"}, {"t": 9.6, "type": "idkfa"},
    {"t": 10.0, "press": "3"}, {"t": 10.6, "key": "lctrl", "down": True}, {"t": 11.4, "key": "lctrl", "down": False},
    {"t": 11.6, "wheel": 1},
    {"t": 12.0, "press": "tab"}, {"t": 12.5, "press": "g"}, {"t": 13.0, "press": "equals"}, {"t": 13.6, "press": "tab"},
    {"t": 14.0, "press": "escape"},          # main menu
    {"t": 14.4, "press": "down"}, {"t": 14.6, "press": "down"}, {"t": 14.8, "press": "down"},   # Save Game
    {"t": 15.2, "press": "return"}, {"t": 15.8, "press": "return"},                             # slot 0
    {"t": 16.5, "key": "s", "down": True}, {"t": 17.3, "key": "s", "down": False},
    {"t": 17.8, "press": "escape"}, {"t": 18.2, "press": "down"}, {"t": 18.4, "press": "down"},  # Load Game
    {"t": 18.8, "press": "return"}, {"t": 19.4, "press": "return"},                             # slot 0
    {"t": 20.5, "op": {"op": "pose", "x": -376, "y": 1296, "angle": 180}},   # at E1M1's exit switch
    {"t": 21.0, "press": "space"},           # use: exit
    {"t": 23.0, "press": "return"},          # snap the tally
    {"t": 24.5, "press": "return"},          # leave for E1M2
    {"t": 27.0, "press": "f9"},              # record a demo of E1M2 (restarts the level)
    {"t": 27.5, "key": "w", "down": True}, {"t": 29.0, "key": "w", "down": False},
    {"t": 29.5, "press": "f9"},              # stop recording
    {"t": 30.0, "press": "f10"},             # play it back
    {"t": 34.5, "type": "idclev13"},         # warp to E1M3
    {"t": 37.5, "quit": True},
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", action="store_true")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    script, log = OUT / "ui_script.json", OUT / "ui_smoke.json"
    script.write_text(json.dumps(SCRIPT))
    cmd = [sys.executable, str(ROOT / "oracle" / "client" / "doom_client.py"), "--headless", "--script", str(script),
           "--log", str(log)] + (["--split"] if a.split else [])
    t0 = time.perf_counter()
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    print(f"client: {time.perf_counter() - t0:.1f}s exit {r.returncode}")
    out = r.stdout + r.stderr
    if r.returncode:
        print(out[-3000:])
        sys.exit(1)
    d = json.loads(log.read_text())
    flow, screens = d["flow"], d["screens"]
    for f in flow:
        print("  ", json.dumps(f))
    print("screens drawn:", json.dumps(screens))
    print("summary:", json.dumps(d["summary"]))
    acts = [f.get("action") for f in flow if f["what"] == "menu"]
    enters = [f for f in flow if f["what"] == "enter"]
    cheats = [f["action"] for f in flow if f["what"] == "cheat"]
    checks = {
        "menus: start a new game": "start" in acts,
        "menus: save to slot 0": "save:0" in acts,
        "menus: load slot 0": "load:0" in acts,
        "E1M1 entered from the menu at skill 2": any(e["map"] == "E1M1" and e["skill"] == 2 for e in enters),
        "typed cheats answered (IDDQD, IDKFA)": sum(1 for c in cheats if c.startswith("msg:")) >= 2,
        "level exit (use) -> E1M2": any(f["what"] == "level_exit" and f["next"] == 2 for f in flow),
        "intermission done -> level:2": any(f["what"] == "intermission_done" and f["outcome"] == "level:2" for f in flow),
        "E1M2 entered with the player carried": any(e["map"] == "E1M2" and e["carry"] for e in enters),
        "demo recorded and played back": any(f["what"] == "demo_record" for f in flow)
                                          and any(f["what"] == "demo_play" for f in flow),
        "IDCLEV13 warp -> E1M3": any(c == "warp:E1M3" for c in cheats) and any(e["map"] == "E1M3" for e in enters),
        "screens drawn: title, main, episode, skill, save, load": all(screens.get(k, 0) > 0 for k in
                                                                      ("title", "main", "episode", "skill", "save", "load")),
        "automap drawn": screens.get("automap", 0) > 0,
        "intermission drawn": screens.get("intermission", 0) > 0,
        "3-D frames rendered": d["summary"].get("frames", 0) > 100,
        "sounds played": d["summary"].get("sound_events_played", 0) > 0,
        "music selected for every level": all(e.get("music") for e in enters),
        "no render errors": "[render error]" not in out,
    }
    for k, v in checks.items():
        print(f"{'ok  ' if v else 'FAIL'} {k}")
    ok = all(checks.values())
    (OUT / "ui_smoke_result.json").write_text(json.dumps({"checks": checks, "screens": screens,
                                                          "summary": d["summary"]}, indent=1))
    print("UI SMOKE", "OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
