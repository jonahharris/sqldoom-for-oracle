"""Feasibility of 26ai VECTOR arithmetic and the MODEL clause for renderer work."""
import oracledb, time, statistics
c = oracledb.connect(user="doom", password="doom", dsn="localhost:1521/FREEPDB1"); cur = c.cursor()
def t(q, n=8):
    ts = []
    for _ in range(n):
        s = time.perf_counter(); cur.execute(q); r = cur.fetchall(); ts.append((time.perf_counter() - s) * 1e3)
    return statistics.median(ts[2:]), r[:1]
# 1) VECTOR: which element-wise ops exist? (needed: mul/add for affine spans, floor, gather)
for expr in ["TO_VECTOR('[1.5,2.5]', 2, FLOAT64) + TO_VECTOR('[1,1]', 2, FLOAT64)",
             "TO_VECTOR('[1.5,2.5]', 2, FLOAT64) * TO_VECTOR('[2,2]', 2, FLOAT64)",
             "FLOOR(TO_VECTOR('[1.5,2.5]', 2, FLOAT64))"]:
    try:
        cur.execute(f"SELECT FROM_VECTOR({expr}) FROM dual"); print("VECTOR ok :", expr, cur.fetchone())
    except oracledb.DatabaseError as e:
        print("VECTOR n/a:", expr, "->", e.args[0].message.splitlines()[0])
# 2) one 320-wide affine scanline as a vector op vs 320 rows of arithmetic
q_vec = """SELECT SUM(LENGTH(FROM_VECTOR(TO_VECTOR(:v, 320, FLOAT64) * TO_VECTOR(:w, 320, FLOAT64)))) FROM screen_y WHERE y < 168"""
vec = "[" + ",".join(str(i + 0.5) for i in range(320)) + "]"
ts = []
for _ in range(8):
    s = time.perf_counter(); cur.execute(q_vec, v=vec, w=vec); cur.fetchall(); ts.append((time.perf_counter() - s) * 1e3)
print(f"168 scanline vector multiplies (+ text round trip): {statistics.median(ts[2:]):.1f} ms")
print("53,760 row multiplies: %.1f ms" % t("SELECT SUM(x.xd * y.yd) FROM screen_x x, screen_y y WHERE y.y < 168")[0])
# 3) MODEL clause running MAX (pclip-like clip window) vs analytic window, 6,400 rows
base = "SELECT MOD(level, 320) c, level k, MOD(level * 7919, 167) v FROM dual CONNECT BY level <= 6400"
print("window running MAX : %.1f ms" % t(f"SELECT SUM(m) FROM (SELECT MAX(v) OVER (PARTITION BY c ORDER BY k ROWS UNBOUNDED PRECEDING) m FROM ({base}))")[0])
print("MODEL running MAX  : %.1f ms" % t(f"""SELECT SUM(m) FROM (SELECT * FROM (SELECT c, ROW_NUMBER() OVER (PARTITION BY c ORDER BY k) rn, v FROM ({base}))
  MODEL PARTITION BY (c) DIMENSION BY (rn) MEASURES (v, 0 m) RULES (m[ANY] ORDER BY rn = GREATEST(v[CV()], NVL(m[CV()-1], 0))))""")[0])
