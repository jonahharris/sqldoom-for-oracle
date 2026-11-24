"""Build the line-special part of the feature coverage matrix (game-port.md) from the
recordings (scenario_evidence) and a replay summary (run_game_correctness --scenario --summary).

    coverage_matrix.py --summary tests/out/scenarios_summary.json > matrix.md

A special counts as "ported + verified" when a scenario carrying it was recorded on CedarDB, the
CedarDB run shows the special's effect (a mover of its kind, an activation, a light change, a
teleport, an exit flag ...) and the Oracle replay was equal on every tic.
"""
import argparse, json, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import scenario_evidence as se  # noqa: E402

DEFS = """1 DR Door Open Wait Close|2 W1 Door Open Stay|3 W1 Door Close Stay|4 W1 Door Open Wait Close|5 W1 Floor Raise To Lowest Ceiling|6 W1 Ceiling Crusher Fast|7 S1 Stairs Raise 8|8 W1 Stairs Raise 8|9 S1 Donut|10 W1 Lift|11 S1 Exit Level|12 W1 Lights To Max Neighbor|13 W1 Lights To 255|14 S1 Floor Raise 32 Change|15 S1 Floor Raise 24 Change|16 W1 Door Close Wait Open|17 W1 Lights Start Strobing|18 S1 Floor Raise To Next Higher|19 W1 Floor Lower To Highest|20 S1 Floor Raise To Next Higher Change|21 S1 Lift|22 W1 Floor Raise To Next Higher Change|23 S1 Floor Lower To Lowest|24 G1 Floor Raise To Lowest Ceiling|25 W1 Ceiling Crusher|26 DR Door Blue Key|27 DR Door Yellow Key|28 DR Door Red Key|29 S1 Door Open Wait Close|30 W1 Floor Raise By Shortest Texture|31 D1 Door Open Stay|32 D1 Door Blue Key|33 D1 Door Red Key|34 D1 Door Yellow Key|35 W1 Lights To 35|36 W1 Floor Lower Turbo|37 W1 Floor Lower To Lowest Change|38 W1 Floor Lower To Lowest|39 W1 Teleport|40 W1 Ceiling Raise To Highest|41 S1 Ceiling Lower To Floor|42 SR Door Close Stay|43 SR Ceiling Lower To Floor|44 W1 Ceiling Lower To Floor+8 Crush|45 SR Floor Lower To Highest|46 GR Door Open Stay|47 G1 Floor Raise To Next Change|48 Scrolling Wall Left|50 S1 Door Close Stay|51 S1 Secret Exit|52 W1 Exit Level|53 W1 Platform Perpetual Raise|54 W1 Platform Stop|55 S1 Floor Raise To Lowest Ceiling -8 Crush|56 W1 Floor Raise To Lowest Ceiling -8 Crush|57 W1 Ceiling Crusher Stop|58 W1 Floor Raise 24|59 W1 Floor Raise 24 Change|60 SR Floor Lower To Lowest|61 SR Door Open Stay|62 SR Lift|63 SR Door Open Wait Close|64 SR Floor Raise To Lowest Ceiling|65 SR Floor Raise To Lowest Ceiling -8 Crush|66 SR Floor Raise 24 Change|67 SR Floor Raise 32 Change|70 SR Floor Lower Turbo|71 S1 Floor Lower Turbo|72 WR Ceiling Lower To Floor+8 Crush|73 WR Ceiling Crusher|74 WR Ceiling Crusher Stop|75 WR Door Close Stay|76 WR Door Close Wait Open|77 WR Ceiling Crusher Fast|79 WR Lights To 35|80 WR Lights To Max Neighbor|81 WR Lights To 255|82 WR Floor Lower To Lowest|83 WR Floor Lower To Highest|84 WR Floor Lower To Lowest Change|86 WR Door Open Stay|87 WR Platform Perpetual Raise|88 WR Lift|89 WR Platform Stop|90 WR Door Open Wait Close|91 WR Floor Raise To Lowest Ceiling|92 WR Floor Raise 24|93 WR Floor Raise 24 Change|94 WR Floor Raise To Lowest Ceiling -8 Crush|96 WR Floor Raise By Shortest Texture|97 WR Teleport|98 WR Floor Lower Turbo|99 SR Door Blue Open Stay Blazing|100 W1 Stairs Raise 16 Turbo|101 S1 Floor Raise To Lowest Ceiling|102 S1 Floor Lower To Highest|103 S1 Door Open Stay|104 W1 Lights To Min Neighbor|105 WR Door Open Wait Close Blazing|106 WR Door Open Stay Blazing|107 WR Door Close Blazing|108 W1 Door Open Wait Close Blazing|109 W1 Door Open Blazing|110 W1 Door Close Blazing|111 S1 Door Open Wait Close Blazing|112 S1 Door Open Stay Blazing|113 S1 Door Close Blazing|114 SR Door Open Wait Close Blazing|115 SR Door Open Stay Blazing|116 SR Door Close Blazing|117 DR Door Blazing|118 S1 Door Open Blazing|119 W1 Floor Raise To Next|120 WR Lift Blazing|121 W1 Lift Blazing|122 S1 Lift Blazing|123 SR Lift Blazing|124 W1 Secret Exit|125 W1 Teleport Monsters Only|126 WR Teleport Monsters Only|127 S1 Stairs Raise 16 Turbo|128 WR Floor Raise To Next|129 W1 Floor Raise Turbo To Next|130 WR Floor Raise Turbo To Next|131 S1 Floor Raise Turbo To Next|132 SR Floor Raise Turbo To Next|133 S1 Door Blue Open Stay Blazing|134 SR Door Red Open Stay Blazing|135 S1 Door Red Open Stay Blazing|136 SR Door Yellow Open Stay Blazing|137 S1 Door Yellow Open Stay Blazing|138 SR Lights To 255|139 SR Lights To 35|140 S1 Floor Raise 512|141 W1 Ceiling Crusher Silent"""


def effect(e):
    bits = []
    if e["movers"]:
        bits.append(",".join(e["movers"]) + (" crush" if e["mover_crush"] else ""))
    sc = e["sectors_changed"]
    if sc["light"]:
        bits.append(f"light x{sc['light']}")
    if sc["floor_tex"]:
        bits.append("flat change")
    if e["player_jumps"]:
        bits.append("teleport")
    if e["exit_flags"]:
        bits.append("/".join(e["exit_flags"]))
    if e["line_activations"]:
        bits.append("one-shot")
    if e["switch_textures"]:
        bits.append("switch tex")
    if e["min_health"] is not None and e["min_health"] < 100:
        bits.append(f"min hp {e['min_health']}")
    return "; ".join(bits)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", type=Path, help="run_game_correctness --summary JSON")
    ap.add_argument("--logs", type=Path, nargs="*", default=[],
                    help="or replay logs: the last '[name] tics a-b: n/n equal' line per scenario wins")
    a = ap.parse_args()
    summ = json.loads(a.summary.read_text()) if a.summary else {}
    import re
    for lp in a.logs:
        for line in lp.read_text().splitlines():
            m = re.match(r"\[(\S+)\] tics (\d+)-(\d+): (\d+)/(\d+) equal(.*)", line)
            if m:
                fr = re.search(r"frames (\d+)/(\d+)", m.group(6))
                ok = m.group(4) == m.group(5) and (not fr or fr.group(1) == fr.group(2))
                summ[m.group(1)] = {"ok": ok, "tics": int(m.group(5)), "frames": fr.group(0) if fr else ""}
            m = re.match(r"\[(\S+)\] first divergence", line)
            if m:
                summ[m.group(1)] = {"ok": False}
    ev = {d.name: se.evidence(d) for d in sorted(se.ROOT.iterdir()) if (d / "run.json").exists()}
    by_special = {}
    for n, e in ev.items():
        for c in e["covers"]:
            if c.startswith("special "):
                sp = int(c.split()[1])
                by_special.setdefault(sp, []).append(n)
    print("| special | name | scenarios | CedarDB effect | Oracle equal |")
    print("|---|---|---|---|---|")
    for item in DEFS.split("|"):
        sp, name = item.split(" ", 1)
        sp = int(sp)
        scs = by_special.get(sp, [])
        eff = "; ".join(f"{n}: {effect(ev[n]) or 'no effect'}" for n in scs)
        ok = all(summ.get(n, {}).get("ok") for n in scs) if scs else None
        status = "—" if ok is None else ("yes" if ok else "**NO**")
        print(f"| {sp} | {name} | {', '.join(scs) or '—'} | {eff or '—'} | {status} |")


if __name__ == "__main__":
    main()
