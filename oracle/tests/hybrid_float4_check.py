"""Check that PL/SQL BINARY_FLOAT arithmetic reproduces SQL's for the sprite tops (CedarDB
real + smallint): TO_BINARY_FLOAT(base_z + top_offset) and TO_BINARY_FLOAT(that - height), for every
distinct base_z candidate in the recorded state x every (top_offset, height) in sprite_frames."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "client"))
import doomora
conn = doomora.connect(); cur = conn.cursor()
out = cur.var(str)
cur.execute("""
DECLARE
  TYPE t_f IS TABLE OF BINARY_FLOAT; TYPE t_n IS TABLE OF NUMBER;
  bz t_f; tp t_n; ht t_n; s1 t_f; s2 t_f; f1 BINARY_FLOAT; f2 BINARY_FLOAT; bad PLS_INTEGER := 0;
BEGIN
  SELECT b.bz, f.top_offset, f.height, TO_BINARY_FLOAT(b.bz + f.top_offset),
         TO_BINARY_FLOAT(TO_BINARY_FLOAT(b.bz + f.top_offset) - f.height)
    BULK COLLECT INTO bz, tp, ht, s1, s2
    FROM (SELECT DISTINCT bz FROM (
            SELECT TO_BINARY_FLOAT(z) AS bz FROM st_things
            UNION ALL SELECT TO_BINARY_FLOAT(z) FROM st_world_effects
            UNION ALL SELECT TO_BINARY_FLOAT(z) FROM st_monster_projectiles
            UNION ALL SELECT TO_BINARY_FLOAT(floor_height) FROM st_sectors
            UNION ALL SELECT TO_BINARY_FLOAT(s.ceil_height - h.thing_height)
                      FROM (SELECT DISTINCT ceil_height FROM st_sectors) s
                      CROSS JOIN (SELECT DISTINCT thing_height FROM st_render_things) h)) b
    CROSS JOIN (SELECT DISTINCT top_offset, height FROM sprite_frames) f;
  FOR i IN 1 .. bz.COUNT LOOP
    f1 := bz(i) + TO_BINARY_FLOAT(tp(i));
    f2 := f1 - TO_BINARY_FLOAT(ht(i));
    IF NOT (f1 = s1(i) AND f2 = s2(i)) THEN bad := bad + 1; END IF;
  END LOOP;
  :out := bz.COUNT || ' combinations, ' || bad || ' mismatches';
END;""", out=out)
print("float4 check:", out.getvalue())
