import oracledb, time, statistics, random
c = oracledb.connect(user="doom", password="doom", dsn="localhost:1521/FREEPDB1")
cur = c.cursor(); cur.arraysize=1000
def ex(s):
    try: cur.execute(s)
    except oracledb.DatabaseError: pass
ex("drop table cal_spans4 purge"); ex("drop table cal_x2 purge"); ex("drop table cal_y2 purge")
cur.execute("create table cal_spans4 (x number, y0 number, y1 number, v0 binary_double, vstep binary_double, tid number, dtex varchar2(4000))")
rows=[]
for x in range(320):
    idx=[random.randrange(256) for _ in range(128)]
    rows.append((x,0,167,random.random()*64,0.7+random.random(),x,''.join('%03d'%i for i in idx*3)))
cur.executemany("insert into cal_spans4 values (:1,:2,:3,:4,:5,:6,:7)", rows); c.commit()
# screen dims carrying the packing weight and chunk id
cur.execute("create table cal_x2 (x number primary key, chunk number, w number)")
cur.executemany("insert into cal_x2 values (:1,:2,:3)", [(x, x//15, 256**(x%15)) for x in range(320)]); c.commit()
for t in ['CAL_SPANS4','CAL_X2']: cur.callproc("dbms_stats.gather_table_stats",["DOOM",t])
J="from cal_spans4 s join cal_y y on y.y between s.y0 and s.y1 join cal_x2 xx on xx.x=s.x"
P="(s.v0+(y.y-s.y0)*s.vstep)"
D=f"to_number(substrb(s.dtex, 3*trunc({P})+1, 3))"
Q = {
 'dec3_sum_only': f"select sum({D}) {J}",
 'dec3_pack_sum': f"select y.y, xx.chunk, sum({D}*xx.w) {J} group by y.y, xx.chunk",
 'texel_pack_sum': f"select y.y, xx.chunk, sum(t.idx*xx.w) {J} join cal_texel t on t.tid=s.tid and t.v=mod(trunc({P}),128) group by y.y, xx.chunk",
 'dec3_pack_hex_rows': f"""select y, listagg(lpad(to_char(v,'FMXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'),30,'0')) within group (order by chunk desc) from (
     select y.y, xx.chunk, sum({D}*xx.w) v {J} group by y.y, xx.chunk) group by y""",
}
for name,q in Q.items():
    ts=[]
    for i in range(10):
        t=time.perf_counter(); cur.execute(q); r=cur.fetchall(); ts.append((time.perf_counter()-t)*1000)
    print(f"{name:22s} rows={len(r):5d} median={statistics.median(ts[2:]):7.2f}ms")
print(r[0][1][:80], len(r[0][1]))
