import oracledb, time, statistics, random
c = oracledb.connect(user="doom", password="doom", dsn="localhost:1521/FREEPDB1")
cur = c.cursor(); cur.arraysize=1000
def ex(s):
    try: cur.execute(s)
    except oracledb.DatabaseError: pass
ex("drop table cal_spans5 purge")
cur.execute("create table cal_spans5 (x number, y0 number, y1 number, v0 binary_double, vstep binary_double, ntex nvarchar2(2000), utex varchar2(4000), c0 binary_double)")
rows=[]; truth={}
for x in range(320):
    idx=[random.randrange(256) for _ in range(128)]*3
    s=''.join(chr(0x80+i) for i in idx)
    v0=random.random()*64; st=0.7+random.random()
    rows.append((x,0,167,v0,st,s,s,v0+1)); truth[x]=idx
cur.setinputsizes(None,None,None,None,None,oracledb.DB_TYPE_NVARCHAR,None,None)
cur.executemany("insert into cal_spans5 values (:1,:2,:3,:4,:5,:6,:7,:8)", rows); c.commit()
cur.callproc("dbms_stats.gather_table_stats",["DOOM","CAL_SPANS5"])
cur.execute("select ascii(substr(ntex,1,1)), ascii(substrb(utex,1,2)), unistr('\\0080') from cal_spans5 where x=0"); print(cur.fetchone(), truth[0][0])
J="from cal_spans5 s join cal_y y on y.y between s.y0 and s.y1 join cal_x2 xx on xx.x=s.x"
P="(s.v0+(y.y-s.y0)*s.vstep)"
Q = {
 'base_join_sum_y': f"select sum(y.y) {J}",
 'n_ascii': f"select sum(ascii(substr(s.ntex,{P}+1,1))) {J}",
 'u_ascii_b': f"select sum(ascii(substrb(s.utex,2*trunc({P})+1,2))) {J}",
 'u_ascii_b_c0': f"select sum(ascii(substrb(s.utex,2*trunc(s.c0+y.y*s.vstep)-1,2))) {J}",
 'u_ascii_pack': f"select y.y, xx.chunk, sum(ascii(substrb(s.utex,2*trunc(s.c0+y.y*s.vstep)-1,2))*xx.w) {J} group by y.y, xx.chunk",
}
for name,q in Q.items():
    ts=[]
    for i in range(10):
        t=time.perf_counter(); cur.execute(q); r=cur.fetchall(); ts.append((time.perf_counter()-t)*1000)
    print(f"{name:22s} median={statistics.median(ts[2:]):7.2f}ms")
