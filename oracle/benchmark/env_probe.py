"""Record the Oracle environment the benchmarks ran on (analysis/environment.md)."""
import json, platform, subprocess, sys, oracledb

def q(cur, sql):
    cur.execute(sql)
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]

def main():
    sysc = oracledb.connect(user="system", password="DoomSys_26ai", dsn="localhost:1521/FREEPDB1")
    cur = sysc.cursor()
    out = {}
    out["host"] = {"platform": platform.platform(), "machine": platform.machine(), "python": sys.version.split()[0]}
    insp = json.loads(subprocess.check_output(["docker", "image", "inspect", "gvenzl/oracle-free:full"]))[0]
    out["image"] = {"id": insp["Id"], "repo_digests": insp.get("RepoDigests"), "arch": insp["Architecture"], "created": insp["Created"]}
    out["docker"] = subprocess.check_output(["docker", "version", "--format", "{{.Server.Version}} {{.Server.Arch}}"]).decode().strip()
    out["docker_ncpu_mem"] = subprocess.check_output(["docker", "info", "--format", "{{.NCPU}} {{.MemTotal}}"]).decode().strip()
    out["v$version"] = q(cur, "select banner_full from v$version")
    out["instance"] = q(cur, "select version_full, instance_name, host_name from v$instance")
    out["platform"] = q(cur, "select platform_name from v$database")
    out["params"] = q(cur, """select name, display_value from v$parameter where name in
      ('cpu_count','sga_target','sga_max_size','pga_aggregate_target','pga_aggregate_limit','memory_target',
       'inmemory_size','inmemory_force','inmemory_optimized_arithmetic','inmemory_query','db_cache_size',
       'shared_pool_size','optimizer_features_enable','parallel_max_servers','resource_manager_plan',
       'sql_transpiler','compatible','statistics_level','optimizer_adaptive_plans','result_cache_mode',
       'cpu_min_count','parallel_degree_policy','db_block_size') order by name""")
    out["options"] = q(cur, "select parameter, value from v$option where parameter in ('In-Memory Column Store','Partitioning','Advanced Compression','Parallel execution','Real Application Clusters') order by 1")
    out["im_area"] = q(cur, "select pool, alloc_bytes, used_bytes, populate_status from v$inmemory_area")
    out["os_cpu"] = q(cur, "select stat_name, value from v$osstat where stat_name in ('NUM_CPUS','NUM_CPU_CORES','PHYSICAL_MEMORY_BYTES')")
    print(json.dumps(out, indent=1, default=str))

if __name__ == "__main__":
    main()
