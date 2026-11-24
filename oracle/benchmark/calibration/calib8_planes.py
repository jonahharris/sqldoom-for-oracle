"""Plane-pixel micro-benchmark: cost of the per-pixel flat lookup variants (53,760 px)."""
import oracledb, time, statistics, random
c = oracledb.connect(user="doom", password="doom", dsn="localhost:1521/FREEPDB1")
cur = c.cursor(); cur.arraysize = 1000
cur.execute("select bitand(-1,63), bitand(-64,63), bitand(-65,63), mod(-1,64) from dual"); print("bitand:", cur.fetchone())
def ex(s):
    try: cur.execute(s)
    except oracledb.DatabaseError: pass
ex("drop table cal_pspans purge"); ex("drop table cal_flat_texel purge")
# 320 vertical plane spans (one per column) each 84 rows, plus flat strings for one lit flat
cur.execute("""create table cal_pspans as
  select x, 85 y0, 167 y1, x - 160.5d ax, 0.37d + x/1000d ay, -2041.6d cz, f.s s0, g.s s1, h.s s2, k.s s3
  from screen_x, (select s from flat_lit where flat_id=1 and light=5 and q=0) f, (select s from flat_lit where flat_id=1 and light=5 and q=1) g,
       (select s from flat_lit where flat_id=1 and light=5 and q=2) h, (select s from flat_lit where flat_id=1 and light=5 and q=3) k""")
cur.execute("""create table cal_flat_texel (fl number, p number, idx number, constraint cal_ft_pk primary key (fl, p)) organization index""")
cur.execute("""insert into cal_flat_texel select 1, (q*1024)+l.n-1, ascii(substr(s, l.n, 1))-256 from flat_lit, (select level n from dual connect by level<=1024) l where flat_id=1 and light=5""")
c.commit()
for t in ("CAL_PSPANS", "CAL_FLAT_TEXEL"): cur.callproc("dbms_stats.gather_table_stats", ["DOOM", t])
J = "from cal_pspans s join screen_y y on y.y between s.y0 and s.y1"
D = "(s.cz/(84d - y.yd))"
WX = f"(1056.25d + {D}*s.ax)"; WY = f"(-3400.5d + {D}*s.ay)"
Q = {
 "join_only": f"select sum(y.y) {J}",
 "depth_wx_wy": f"select sum({WX}+{WY}) {J}",
 "floor_bitand_p": f"select sum(bitand(floor({WY}),63)*64+bitand(floor({WX}),63)) {J}",
 "quarter_decode_substr": f"""select sum(ascii(substr(decode(bitand(floor({WY}),48),0,s.s0,16,s.s1,32,s.s2,s.s3),
                                bitand(floor({WY}),15)*64+bitand(floor({WX}),63)+1,1))) {J}""",
 "texel_iot_join": f"""select sum(t.idx) {J} join cal_flat_texel t on t.fl=1 and t.p=bitand(floor({WY}),63)*64+bitand(floor({WX}),63)""",
}
for name, q in Q.items():
    ts = []
    for i in range(8):
        t = time.perf_counter(); cur.execute(q); r = cur.fetchall(); ts.append((time.perf_counter() - t) * 1000)
    print(f"{name:24s} median={statistics.median(ts[2:]):7.2f}ms  ({r[0][0]})")

print("--- all-double variants")
U = f"(floor({WX}) - 64d*floor({WX}*0.015625d))"
V = f"(floor({WY}) - 64d*floor({WY}*0.015625d))"
Q2 = {
 "dbl_pos_only": f"select sum({V}*64d+{U}) {J}",
 "dbl_case_quarter_substr": f"""select sum(ascii(substr(case when {V} < 16d then s.s0 when {V} < 32d then s.s1 when {V} < 48d then s.s2 else s.s3 end,
                                  ({V} - 16d*floor({V}*0.0625d))*64d + {U} + 1d, 1))) {J}""",
 "dbl_wrapped_v_lateral": f"""select sum(ascii(substr(case when v < 16d then s.s0 when v < 32d then s.s1 when v < 48d then s.s2 else s.s3 end,
                                  (v - 16d*floor(v*0.0625d))*64d + u + 1d, 1)))
        from cal_pspans s join screen_y y on y.y between s.y0 and s.y1
        cross apply (select {V} v, {U} u from dual)""",
}
for name, q in Q2.items():
    ts = []
    for i in range(8):
        t = time.perf_counter(); cur.execute(q); r = cur.fetchall(); ts.append((time.perf_counter() - t) * 1000)
    print(f"{name:24s} median={statistics.median(ts[2:]):7.2f}ms  ({r[0][0]})")
