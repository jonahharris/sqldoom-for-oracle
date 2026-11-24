"""Wall-pixel path, all-double positions, with framebuffer SUM packing (53,760 px)."""
import oracledb, time, statistics
c = oracledb.connect(user="doom", password="doom", dsn="localhost:1521/FREEPDB1")
cur = c.cursor(); cur.arraysize = 1000
def ex(s):
    try: cur.execute(s)
    except oracledb.DatabaseError: pass
ex("drop table cal_wspans purge")
cur.execute("""create table cal_wspans as select x.x, 0 y0, 167 y1, x.chunk, x.w,
   to_binary_double(1.3d + mod(x.x,7)) c0, to_binary_double(0.6d + mod(x.x,5)*0.1d) vstep, t.col
   from screen_x x join texcol_lit t on t.tex_id = 5 and t.u = mod(x.x, 64) and t.light = 7""")
c.commit(); cur.callproc("dbms_stats.gather_table_stats", ["DOOM", "CAL_WSPANS"])
J = "from cal_wspans s join screen_y y on y.y between s.y0 and s.y1"
P = "(s.c0 + y.yd*s.vstep)"
Q = {
 "join_only": f"select sum(y.y) {J}",
 "ascii_substr": f"select sum(ascii(substr(s.col, {P}, 1))) {J}",
 "ascii_substr_mod": f"select sum(ascii(substr(s.col, mod({P}, 128d)+1d, 1))) {J}",
 "ascii_substr_w": f"select sum(ascii(substr(s.col, {P}, 1))*s.w) {J}",
 "packed_group": f"select y.y, s.chunk, sum(ascii(substr(s.col, {P}, 1))*s.w) {J} group by y.y, s.chunk",
 "packed_group_fetch": f"select y.y, s.chunk, sum(ascii(substr(s.col, {P}, 1))*s.w) {J} group by y.y, s.chunk",
 "packed_rows_hex": f"""select y, listagg(to_char(v,'FM0XXXXXXXXXXXXXXXXXXXXXXXXXXXXX')) within group (order by chunk)
     from (select y.y, s.chunk, sum((ascii(substr(s.col, {P}, 1))-256)*s.w) v {J} group by y.y, s.chunk) group by y""",
}
for name, q in Q.items():
    ts = []
    for i in range(8):
        t = time.perf_counter(); cur.execute(q); r = cur.fetchall(); ts.append((time.perf_counter() - t) * 1000)
    print(f"{name:20s} rows={len(r):5d} median={statistics.median(ts[2:]):7.2f}ms")
