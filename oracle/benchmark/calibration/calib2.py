import oracledb, time, statistics, random
c = oracledb.connect(user="doom", password="doom", dsn="localhost:1521/FREEPDB1")
cur = c.cursor(); cur.arraysize=1000
J="from cal_spans s join cal_y y on y.y between s.y0 and s.y1"
V="mod(floor(s.v0+(y.y-s.y0)*s.vstep),128)"
VB="mod(floor(s.v0+to_binary_double(y.y-s.y0)*s.vstep),128d)"
Q = {
 'count': f"select count(*) {J}",
 'sum_v_number_mix': f"select sum({V}) {J}",
 'sum_v_bdouble': f"select sum({VB}) {J}",
 'sum_v_trunc': f"select sum(trunc(s.v0+(y.y-s.y0)*s.vstep)) {J}",
 'sum_substr_len': f"select sum(length(substr(s.tex, 2*{VB}+1,2))) {J}",
 'sum_ascii_substr': f"select sum(ascii(substr(s.tex, 2*{VB}+1,1))) {J}",
 'listagg_const': f"select y.y, listagg('ab') within group (order by s.x) {J} group by y.y",
 'listagg_nosort_x': f"select y.y, listagg('ab') {J} group by y.y",
 'listagg_substr_y': f"select y.y, listagg(substr(s.tex, 2*{VB}+1,2)) within group (order by s.x) {J} group by y.y",
 'listagg_substr_x_noorder': f"select s.x, listagg(substr(s.tex, 2*{VB}+1,2)) {J} group by s.x",
 'xmlagg': f"select y.y, xmlagg(xmlelement(e, substr(s.tex,2*{VB}+1,2)) order by s.x).getstringval() {J} group by y.y",
}
for name,q in Q.items():
    ts=[]
    for i in range(10):
        t=time.perf_counter(); cur.execute(q); r=cur.fetchall(); ts.append((time.perf_counter()-t)*1000)
    print(f"{name:26s} rows={len(r):5d} median={statistics.median(ts[2:]):7.2f}ms")
