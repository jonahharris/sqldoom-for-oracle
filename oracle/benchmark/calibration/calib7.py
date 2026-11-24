import oracledb, time, statistics
c = oracledb.connect(user="doom", password="doom", dsn="localhost:1521/FREEPDB1")
cur = c.cursor(); cur.arraysize=1000
# 320 spans x 168 rows = 53,760 base fragments; union a 50% overlapping copy -> ~80k fragments
F = """(select y.y*320+s.x pix, (s.v0+y.y)*1e6 + s.x k from cal_spans5 s join cal_y y on y.y between s.y0 and s.y1
        union all
        select y.y*320+s.x pix, (s.v0+y.y+7)*1e6 + s.x k from cal_spans5 s join cal_y y on y.y between 0 and 83)"""
Q = {
 'fragments_count': f"select count(*) from {F}",
 'zbuf_min_groupby': f"select count(*) from (select pix, min(k) from {F} group by pix)",
 'zbuf_keep_dense': f"select count(*) from (select pix, min(k) keep (dense_rank first order by k) from {F} group by pix)",
 'zbuf_rownumber': f"select count(*) from (select pix, row_number() over (partition by pix order by k) rn from {F}) where rn=1",
}
for name,q in Q.items():
    ts=[]
    for i in range(8):
        t=time.perf_counter(); cur.execute(q); r=cur.fetchall(); ts.append((time.perf_counter()-t)*1000)
    print(f"{name:20s} {r[0][0]:6d} median={statistics.median(ts[2:]):7.2f}ms")
