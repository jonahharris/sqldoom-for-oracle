import oracledb, time, statistics, random
c = oracledb.connect(user="doom", password="doom", dsn="localhost:1521/FREEPDB1")
cur = c.cursor(); cur.arraysize=1000
def ex(s):
    try: cur.execute(s)
    except oracledb.DatabaseError: pass
ex("drop table cal_spans3 purge")
cur.execute("create table cal_spans3 (x number, y0 number, y1 number, v0 binary_double, vstep binary_double, light number, ntex nvarchar2(2000), utex varchar2(4000))")
rows=[]
for x in range(320):
    idx=[random.randrange(256) for _ in range(128)]
    s=''.join(chr(0x100+i) for i in idx)*4  # 512 texels, wrap-free
    rows.append((x,0,167,random.random()*64,0.7+random.random(),random.randrange(32),s,s))
cur.setinputsizes(None,None,None,None,None,None,oracledb.DB_TYPE_NVARCHAR,None)
cur.executemany("insert into cal_spans3 values (:1,:2,:3,:4,:5,:6,:7,:8)", rows); c.commit()
cur.callproc("dbms_stats.gather_table_stats",["DOOM","CAL_SPANS3"])
alpha=''.join(chr(0x100+i) for i in range(256)); cm=''.join(chr(0x100+random.randrange(256)) for _ in range(256))
J="from cal_spans3 s join cal_y y on y.y between s.y0 and s.y1"
P="(s.v0+1+(y.y-s.y0)*s.vstep)"
Q = {
 'n_substr_trunc': f"select sum(length(substr(s.ntex, {P}, 1))) {J}",
 'u_substrb_floor': f"select sum(lengthb(substrb(s.utex, 2*floor({P})-1, 2))) {J}",
 'u_substr_char': f"select sum(length(substr(s.utex, {P}, 1))) {J}",
 'n_listagg_y': f"select y.y, listagg(substr(s.ntex,{P},1)) within group (order by s.x) {J} group by y.y",
 'n_listagg_y_youter': f"select /*+ leading(y s) use_nl(s) */ y.y, listagg(substr(s.ntex,{P},1)) within group (order by s.x) {J} group by y.y",
 'n_listagg_x': f"select s.x, listagg(substr(s.ntex,{P},1)) within group (order by y.y) {J} group by s.x",
 'n_listagg_x_noorder': f"select s.x, listagg(substr(s.ntex,{P},1)) {J} group by s.x",
 'translate_per_col': f"select sum(length(translate(s.ntex, :a, :c))) from cal_spans3 s",
}
for name,q in Q.items():
    b={'a':alpha,'c':cm} if ':a' in q else {}
    ts=[]
    for i in range(10):
        t=time.perf_counter(); cur.execute(q,b); r=cur.fetchall(); ts.append((time.perf_counter()-t)*1000)
    print(f"{name:22s} median={statistics.median(ts[2:]):7.2f}ms")
# order check for unordered listagg (x-major, y ascending expected)
cur.execute(f"select s.x, listagg(to_char(y.y,'FM000')||',') {J} group by s.x")
ok=all(r[1]==''.join('%03d,'%y for y in range(168)) for r in cur.fetchall()); print('noorder arrives sorted:',ok)
