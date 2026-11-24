import oracledb, time, statistics, random
c = oracledb.connect(user="doom", password="doom", dsn="localhost:1521/FREEPDB1")
cur = c.cursor(); cur.arraysize=1000
def ex(s):
    try: cur.execute(s)
    except oracledb.DatabaseError as e: pass
ex("drop table cal_texel purge"); ex("drop table cal_spans2 purge")
cur.execute("create table cal_spans2 as select x,y0,y1,v0,vstep,light,tex, hextoraw(tex) texr, substr(tex,1,2) short, x tid from cal_spans")
cur.execute("create table cal_texel (tid number, v number, idx number, constraint cal_texel_pk primary key(tid,v)) organization index")
cur.execute("insert into cal_texel select s.x, l.v, to_number(substr(s.tex,2*l.v+1,2),'XX') from cal_spans s, (select level-1 v from dual connect by level<=128) l")
c.commit()
for t in ['CAL_SPANS2','CAL_TEXEL']: cur.callproc("dbms_stats.gather_table_stats",["DOOM",t])
J="from cal_spans2 s join cal_y y on y.y between s.y0 and s.y1"
VB="mod(floor(s.v0+(y.y-s.y0)*s.vstep),128)"
Q = {
 'substr_long': f"select sum(length(substr(s.tex, 2*{VB}+1,2))) {J}",
 'substrb_long': f"select sum(length(substrb(s.tex, 2*{VB}+1,2))) {J}",
 'substr_short': f"select sum(length(substr(s.short, 1,2))) {J}",
 'carry_long_only': f"select sum(length(s.tex)) {J}",
 'utl_raw_substr': f"select sum(utl_raw.length(utl_raw.substr(s.texr, {VB}+1,1))) {J}",
 'texel_join': f"select sum(t.idx) {J} join cal_texel t on t.tid=s.tid and t.v={VB}",
 'texel_join_hash': f"select /*+ use_hash(t) */ sum(t.idx) {J} join cal_texel t on t.tid=s.tid and t.v={VB}",
}
for name,q in Q.items():
    ts=[]
    for i in range(10):
        t=time.perf_counter(); cur.execute(q); r=cur.fetchall(); ts.append((time.perf_counter()-t)*1000)
    print(f"{name:20s} {r[0][0]!s:>10s} median={statistics.median(ts[2:]):7.2f}ms")
