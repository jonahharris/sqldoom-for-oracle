"""H25/H26: inline SQL vs SQL macro vs PL/SQL function (transpiler OFF/ON) vs PRAGMA UDF,
for Doom's light-index formula evaluated per row over 53,760 rows."""
import oracledb, time, statistics
c = oracledb.connect(user="doom", password="doom", dsn="localhost:1521/FREEPDB1")
cur = c.cursor(); cur.arraysize = 1000
cur.execute("""create or replace function doom_light_index_f(p_light binary_double, p_extra number, p_att number) return number is
begin
  return greatest(0, least(31, (15 - least(15, greatest(0, floor(p_light / 16) + p_extra))) * 4 - p_att));
end;""")
cur.execute("""create or replace function doom_light_index_udf(p_light binary_double, p_extra number, p_att number) return number is
  pragma udf;
begin
  return greatest(0, least(31, (15 - least(15, greatest(0, floor(p_light / 16) + p_extra))) * 4 - p_att));
end;""")
cur.execute("""create or replace function doom_light_index_m(p_light binary_double, p_extra number, p_att number) return varchar2 sql_macro(scalar) is
begin
  return 'greatest(0, least(31, (15 - least(15, greatest(0, floor(p_light / 16) + p_extra))) * 4 - p_att))';
end;""")
J = "from cal_wspans s join screen_y y on y.y between s.y0 and s.y1"
ARGS = "s.x*0.8d, mod(y.y,3)-1, mod(s.x+y.y,24)"
Q = {
 "inline": f"select sum(greatest(0, least(31, (15 - least(15, greatest(0, floor(s.x*0.8d / 16) + (mod(y.y,3)-1)))) * 4 - mod(s.x+y.y,24)))) {J}",
 "sql_macro": f"select sum(doom_light_index_m({ARGS})) {J}",
 "plsql_fn": f"select sum(doom_light_index_f({ARGS})) {J}",
 "plsql_udf": f"select sum(doom_light_index_udf({ARGS})) {J}",
}
for mode in ("OFF", "ON"):
    cur.execute(f"alter session set sql_transpiler = {mode}")
    for name, q in Q.items():
        ts = []
        for i in range(8):
            t = time.perf_counter(); cur.execute(q + f" /* {mode} */"); r = cur.fetchall(); ts.append((time.perf_counter() - t) * 1000)
        cur.execute("select plan_table_output from table(dbms_xplan.display_cursor(null, null, 'BASIC +PREDICATE +PROJECTION')) where plan_table_output like '%DOOM_LIGHT%' or plan_table_output like '%GREATEST%'")
        proj = cur.fetchall()
        transpiled = "fn call in plan" if any("DOOM_LIGHT" in p[0] for p in proj) else "expression in plan"
        print(f"transpiler={mode:3s} {name:10s} median={statistics.median(ts[2:]):7.2f}ms  result={r[0][0]}  [{transpiled}]")
