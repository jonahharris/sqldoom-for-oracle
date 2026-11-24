"""Interleaved A/B timing of hybrid package variants (hot, one connection).

    python tests/hybrid_ab.py sql/variants/c0_06_hybrid_baseline.sql sql/06_hybrid.sql [--step 10] [--rounds 3]

Each file is installed as its own package DOOM_HAB<k> (text 'doom_hybrid' renamed), warmed over
all sampled tics (static caches loaded), then the variants render the same tics in interleaved
rounds (A B A B ...), so host drift affects all of them alike. Prints per variant mean / p50 /
p95 / max of the per-tic medians (client execute+fetch, ms) and the paired mean difference.
The renamed packages are dropped at the end.
"""
import argparse, re, statistics, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora, install_hybrid  # noqa: E402

ap = argparse.ArgumentParser(); ap.add_argument("files", nargs="+")
ap.add_argument("--step", type=int, default=10); ap.add_argument("--first", type=int, default=1)
ap.add_argument("--last", type=int, default=1200); ap.add_argument("--rounds", type=int, default=3)
a = ap.parse_args()
conn = doomora.connect(); cur = conn.cursor(); poses = doomora.load_poses()
names = []
for k, f in enumerate(a.files):
    pk = f"doom_hab{k}"; names.append(pk)
    txt = re.sub(r"doom_hybrid", pk, Path(f).read_text(), flags=re.I)
    for u in install_hybrid.units(txt):
        st = install_hybrid.strip_comments(u)
        if not st: continue
        if not st.upper().startswith(("CREATE OR REPLACE PACKAGE", "CREATE TYPE")): st = st.rstrip(";")
        cur.execute(st)
    cur.execute("SELECT COUNT(*) FROM user_objects WHERE object_name = :n AND status <> 'VALID'", n=pk.upper())
    assert cur.fetchone()[0] == 0, f"{pk} invalid"
base_sql, _ = doomora.load_sql("render_hybrid.sql")
rs = []
for pk in names:
    r = doomora.Renderer(conn, "render_hybrid.sql"); r.sql = re.sub(r"doom_hybrid", pk, base_sql, flags=re.I); rs.append(r)
tics = [t for t in range(a.first, a.last + 1, a.step) if t in poses]
for r in rs:
    for t in tics: r.render(t, poses[t])           # warm: caches, cursor
times = [{t: [] for t in tics} for _ in rs]
for rnd in range(a.rounds):
    for t in tics:
        order = range(len(rs)) if (rnd + t) % 2 == 0 else reversed(range(len(rs)))
        for i in order:
            rs[i].render(t, poses[t]); times[i][t].append(rs[i].last["exec_ms"] + rs[i].last["fetch_ms"])
def pct(v, p): v = sorted(v); return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))]
med = [[statistics.median(tm[t]) for t in tics] for tm in times]
for f, m in zip(a.files, med):
    print(f"{Path(f).name:45s} mean={statistics.mean(m):.2f} p50={pct(m,50):.2f} p95={pct(m,95):.2f} max={max(m):.2f}")
for i in range(1, len(rs)):
    d = [x - y for x, y in zip(med[i], med[0])]
    print(f"{Path(a.files[i]).name} - {Path(a.files[0]).name}: mean diff {statistics.mean(d):+.3f} ms "
          f"({100 * statistics.mean(d) / statistics.mean(med[0]):+.2f}%), tics slower/faster {sum(x > 0 for x in d)}/{sum(x < 0 for x in d)}")
for pk in names: cur.execute(f"DROP PACKAGE {pk}")
