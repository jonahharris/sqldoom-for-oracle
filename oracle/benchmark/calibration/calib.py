import oracledb, time, statistics, random
c = oracledb.connect(user="doom", password="doom", dsn="localhost:1521/FREEPDB1")
cur = c.cursor()
def ex(s):
    try: cur.execute(s)
    except oracledb.DatabaseError as e:
        if 'ORA-00942' not in str(e) and 'ORA-00955' not in str(e): raise
for t in ['cal_y','cal_x','cal_spans']: ex(f"drop table {t} purge")
cur.execute("create table cal_y (y number(3) primary key) organization index")
cur.execute("insert into cal_y select level-1 from dual connect by level<=200")
cur.execute("create table cal_x (x number(3) primary key) organization index")
cur.execute("insert into cal_x select level-1 from dual connect by level<=320")
# 320 column spans, each covering 168 rows, with a 128-texel hex texture column
cur.execute("create table cal_spans (x number, y0 number, y1 number, v0 binary_double, vstep binary_double, light number, tex varchar2(512))")
rows=[]
for x in range(320):
    tex=''.join('%02x'%random.randrange(256) for _ in range(128))
    rows.append((x,0,167,random.random()*64,0.7+random.random(),random.randrange(32),tex))
cur.executemany("insert into cal_spans values (:1,:2,:3,:4,:5,:6,:7)", rows)
c.commit()
for t in ['CAL_Y','CAL_X','CAL_SPANS']: cur.callproc("dbms_stats.gather_table_stats",["DOOM",t])
cmap=''.join('%02x'%random.randrange(256) for _ in range(8192))
Q = {
 'rows_only_count': "select count(*) from cal_spans s join cal_y y on y.y between s.y0 and s.y1",
 'listagg_by_y_hex': """select y.y, listagg(substr(s.tex, 2*mod(floor(s.v0+(y.y-s.y0)*s.vstep),128)+1,2)) within group (order by s.x)
   from cal_spans s join cal_y y on y.y between s.y0 and s.y1 group by y.y""",
 'listagg_by_y_cmap': """select y.y, listagg(substr(:cm, 2*(s.light*256+to_number(substr(s.tex, 2*mod(floor(s.v0+(y.y-s.y0)*s.vstep),128)+1,2),'XX'))+1,2)) within group (order by s.x)
   from cal_spans s join cal_y y on y.y between s.y0 and s.y1 group by y.y""",
 'listagg_by_x_hex': """select s.x, listagg(substr(s.tex, 2*mod(floor(s.v0+(y.y-s.y0)*s.vstep),128)+1,2)) within group (order by y.y)
   from cal_spans s join cal_y y on y.y between s.y0 and s.y1 group by s.x""",
 'pixel_rows_fetch': """select s.x, y.y, substr(s.tex, 2*mod(floor(s.v0+(y.y-s.y0)*s.vstep),128)+1,2)
   from cal_spans s join cal_y y on y.y between s.y0 and s.y1""",
}
for name,q in Q.items():
    binds = {'cm':cmap} if ':cm' in q else {}
    cur.arraysize=1000
    ts=[]
    for i in range(12):
        t=time.perf_counter(); cur.execute(q, binds); r=cur.fetchall(); ts.append((time.perf_counter()-t)*1000)
    print(f"{name:22s} rows={len(r):6d} median={statistics.median(ts[2:]):7.2f}ms min={min(ts[2:]):7.2f}")
