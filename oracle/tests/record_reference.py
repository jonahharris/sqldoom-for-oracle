"""Record ground truth from the CedarDB SQLDoom reference renderer.

Replays the TPC-DOOM E1M1 command stream (saildoom/tpc-doom, 1,200 tics, skill 2,
IDDQD+IDKFA) through CedarDB SQLDoom exactly as tpc-doom/driver.py does, and per tic:

  * snapshots every dynamic table the renderer reads (state/<table>.parquet, tic column)
  * renders the reference frame as RGB (frames_rgb/NNNNN.rgb, 192,000 bytes) -- the
    digest of which can be checked against the published TPC-DOOM CedarDB run
  * renders the same frame as 8-bit palette indices AFTER COLORMAP
    (frames_idx/NNNNN.idx, 64,000 bytes), using an index-emitting variant of the
    reference renderer obtained purely by table renames (colormap_rgb -> colormap_idx
    whose 'rgb' column holds the 1-byte mapped index).

Usage: record_reference.py --dsn postgresql://... --out ../reference_data/e1m1 [--tics 1200]
"""
import argparse, hashlib, json, sys, time
from pathlib import Path
import psycopg2, pyarrow as pa, pyarrow.parquet as pq

HERE = Path(__file__).resolve().parent
SQLDOOM = HERE.parents[1] / "reference" / "sqldoom"
sys.path.insert(0, str(SQLDOOM))
import doom_sql as sql  # noqa: E402

SKILL = 2
STATE_TABLES = ("sectors", "things", "render_things", "player_state", "player_weapons",
                "player_weapon_owned", "monster_ai", "thing_health", "world_effects",
                "monster_projectiles", "picked_up_items", "sector_light_fx", "mp_players")
OID = {16: pa.bool_(), 17: pa.binary(), 20: pa.int64(), 21: pa.int32(), 23: pa.int32(),
       700: pa.float32(), 701: pa.float64(), 1700: pa.float64(), 1114: pa.timestamp("us"),
       1184: pa.timestamp("us", tz="UTC")}


def index_variant(cur):
    """Create the index-emitting lookup tables and return the variant renderer text."""
    cur.execute("DROP TABLE IF EXISTS colormap_idx")
    cur.execute("CREATE TABLE colormap_idx AS SELECT pal, level, palette_index, mapped_index, r, g, b,"
                " int2bytea(mapped_index) AS rgb FROM colormap_rgb") if False else None
    cur.execute("CREATE TABLE colormap_idx (pal smallint, level smallint, palette_index smallint,"
                " mapped_index smallint, rgb bytea, PRIMARY KEY (pal, level, palette_index))")
    cur.execute("SELECT pal, level, palette_index, mapped_index FROM colormap_rgb")
    rows = cur.fetchall()
    for i in range(0, len(rows), 2000):
        args = ",".join(cur.mogrify("(%s,%s,%s,%s,%s)", (p, l, pi, m, bytes([m]))).decode()
                        for p, l, pi, m in rows[i:i + 2000])
        cur.execute("INSERT INTO colormap_idx VALUES " + args)
    cur.execute("DROP TABLE IF EXISTS ui_static_pixels_idx")
    cur.execute("CREATE TABLE ui_static_pixels_idx (x int, y int, rgb bytea, palette_index smallint)")
    cur.execute("SELECT s.x, s.y, s.palette_index, cm.mapped_index FROM ui_static_pixels s"
                " JOIN colormap_rgb cm ON cm.pal=0 AND cm.level=0 AND cm.palette_index=s.palette_index")
    rows = cur.fetchall()
    for i in range(0, len(rows), 2000):
        args = ",".join(cur.mogrify("(%s,%s,%s,%s)", (x, y, bytes([m]), p)).decode()
                        for x, y, p, m in rows[i:i + 2000])
        cur.execute("INSERT INTO ui_static_pixels_idx VALUES " + args)
    cur.execute("ANALYZE colormap_idx"); cur.execute("ANALYZE ui_static_pixels_idx")
    body = sql.load_sql("renderer.sql")
    for a, b in (("colormap_rgb", "colormap_idx"), ("ui_static_pixels", "ui_static_pixels_idx"),
                 ("'\\x000000'::bytea", "'\\x00'::bytea")):
        assert a in body, a
        body = body.replace(a, b)
    return body


class Snapshots:
    def __init__(self):
        self.schemas, self.cols = {}, {}

    def add(self, cur, table, map_id, tic):
        cur.execute(f'SELECT * FROM "{table}" WHERE map_id = %s', (map_id,))
        rows = cur.fetchall()
        if table not in self.schemas:
            fields = [pa.field("tic", pa.int32())] + [
                pa.field(d.name, OID.get(d.type_code, pa.string())) for d in cur.description]
            self.schemas[table] = pa.schema(fields)
            self.cols[table] = [[] for _ in fields]
        cols, types = self.cols[table], [f.type for f in self.schemas[table]]
        for r in rows:
            cols[0].append(tic)
            for i, v in enumerate(r, 1):
                if v is not None and types[i] == pa.string():
                    v = str(v)
                elif v is not None and types[i] == pa.float64():
                    v = float(v)
                elif v is not None and types[i] == pa.binary():
                    v = bytes(v)
                cols[i].append(v)

    def write(self, out):
        for t, s in self.schemas.items():
            pq.write_table(pa.Table.from_arrays([pa.array(c, type=f.type) for c, f in zip(self.cols[t], s)],
                                                schema=s), out / f"{t}.parquet")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--tics", type=int, default=1200)
    ap.add_argument("--commands", type=Path, default=HERE / "run-e1m1-b-commands.json")
    args = ap.parse_args()
    cmds = [c["command"] for c in json.loads(args.commands.read_text())]
    out = args.out
    for d in ("frames_rgb", "frames_idx", "state"):
        (out / d).mkdir(parents=True, exist_ok=True)
    conn = psycopg2.connect(args.dsn); conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    stage = {s["label"]: s for s in sql.load_stages(cur)}["E1M1"]
    map_id, player = stage["map_id"], stage["player_thing_id"]
    body = index_variant(cur)
    cur.execute("DEALLOCATE ALL") if False else None
    cur.execute("PREPARE ref_idx(int,int,int,float8,float8,float8,float8) AS " + body)
    sql.set_screen(cur, "game")
    sql.enter_level(cur, map_id, player, SKILL)
    for code in ("IDDQD", "IDKFA"):
        sql.cheat_code(cur, map_id, player, code)
    sql.prepare_renderer(cur, map_id, player, SKILL)
    snaps, poses, digests = Snapshots(), [], []
    # render_segs texture columns change when switches are pressed (line_buttons); record
    # them sparsely as deltas from level start: st_render_seg_tex(tic, map_id, seg_id, ...).
    seg_q = "SELECT seg_id, upper_tex, mid_tex, lower_tex FROM render_segs WHERE map_id = %s"
    cur.execute(seg_q, (map_id,))
    seg0 = {r[0]: r[1:] for r in cur.fetchall()}
    segtex = {"tic": [], "map_id": [], "seg_id": [], "upper_tex": [], "mid_tex": [], "lower_tex": []}
    event = 0
    t0 = time.perf_counter()
    for i in range(args.tics):
        command = (SKILL, *cmds[i % len(cmds)][1:])
        if sql.execute_game_tic(cur, map_id, player, command):
            events, _ = sql.fetch_sound_events(cur, map_id, player, event)
            if events:
                event = max(e[0] for e in events)
        sql.finish_game_tic(cur, map_id, player)
        tic = i + 1
        pose = tuple(float(v) for v in sql.camera_pose(cur, map_id, player, 1.0))
        for t in STATE_TABLES:
            snaps.add(cur, t, map_id, tic)
        cur.execute(seg_q, (map_id,))
        for sid, *tex in cur.fetchall():
            if tuple(tex) != seg0[sid]:
                for k, v in zip(("tic", "map_id", "seg_id", "upper_tex", "mid_tex", "lower_tex"),
                                (tic, map_id, sid, *tex)):
                    segtex[k].append(v)
        rgb = sql.render_frame(cur, map_id, player, SKILL, pose, 320, 200, 1.0)
        cur.execute("EXECUTE ref_idx(%s,%s,%s,%s,%s,%s,%s)", (map_id, player, SKILL, *pose))
        idx = bytes(cur.fetchone()[0])
        assert len(idx) == 64000, len(idx)
        (out / "frames_rgb" / f"{tic:05d}.rgb").write_bytes(rgb)
        (out / "frames_idx" / f"{tic:05d}.idx").write_bytes(idx)
        poses.append({"tic": tic, "pose": list(pose)})
        digests.append("sha256:%s:%d" % (hashlib.sha256(rgb).hexdigest(), len(rgb)))
        if tic % 100 == 0:
            print(f"tic {tic} pose {tuple(round(v, 1) for v in pose)} {time.perf_counter() - t0:.0f}s", flush=True)
    snaps.write(out / "state")
    pq.write_table(pa.table({k: pa.array(v, type=pa.int32() if k in ("tic", "map_id", "seg_id") else pa.string())
                             for k, v in segtex.items()}), out / "state" / "render_seg_tex.parquet")
    (out / "poses.json").write_text(json.dumps(poses))
    (out / "digests.json").write_text(json.dumps(digests))
    (out / "run.json").write_text(json.dumps({"map": "E1M1", "map_id": map_id, "player_thing_id": player,
                                              "skill": SKILL, "tics": args.tics}))


if __name__ == "__main__":
    main()
