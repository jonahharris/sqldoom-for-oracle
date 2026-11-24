#!/usr/bin/env python3
"""Install the hybrid renderer (sql/06_hybrid.sql) into the doom schema.

    python oracle/client/install_hybrid.py [--interpreted]

06_hybrid.sql is a sequence of units separated by lines containing only '/': ALTER SESSION
statements, CREATE TYPE and CREATE OR REPLACE PACKAGE [BODY] blocks. client/oradb.run_script
splits on ';' and cannot run PL/SQL, so this loader executes each unit as one statement.

The units are compiled with PLSQL_CODE_TYPE=NATIVE (the brief). On platforms without native
PL/SQL compilation (e.g. Oracle Free on linux/arm64) Oracle records PLS-00924 and the unit stays
VALID but runs interpreted; the loader reports what USER_PLSQL_OBJECT_SETTINGS / USER_ERRORS say.
"""
import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import oradb  # noqa: E402


def units(text):
    cur = []
    for line in text.splitlines():
        if line.strip() == "/":
            u = "\n".join(cur).strip()
            if u:
                yield u
            cur = []
        else:
            cur.append(line)
    u = "\n".join(cur).strip()
    if u:
        yield u


def strip_comments(u):
    return "\n".join(l for l in u.splitlines() if not l.lstrip().startswith("--")).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=str(oradb.SQL_DIR / "06_hybrid.sql"))
    ap.add_argument("--interpreted", action="store_true", help="compile with PLSQL_CODE_TYPE=INTERPRETED")
    a = ap.parse_args()
    conn = oradb.connect()
    cur = conn.cursor()
    for u in units(Path(a.file).read_text(encoding="utf-8")):
        stmt = strip_comments(u)
        if not stmt:
            continue
        if a.interpreted and stmt.upper().startswith("ALTER SESSION SET PLSQL_CODE_TYPE"):
            stmt = "ALTER SESSION SET plsql_code_type = INTERPRETED"
        if not stmt.upper().startswith(("CREATE OR REPLACE PACKAGE", "CREATE OR REPLACE FUNCTION",
                                        "CREATE OR REPLACE PROCEDURE", "CREATE TYPE", "CREATE OR REPLACE TYPE")):
            stmt = stmt.rstrip(";")
        cur.execute(stmt)
    cur.execute("""SELECT o.object_name, o.object_type, o.status, s.plsql_code_type, s.plsql_optimize_level
                   FROM user_objects o LEFT JOIN user_plsql_object_settings s
                     ON s.name = o.object_name AND s.type = o.object_type
                   WHERE o.object_name = 'DOOM_HYBRID' ORDER BY o.object_type""")
    bad = False
    for name, typ, status, code, lvl in cur.fetchall():
        print(f"[install_hybrid] {name} {typ}: {status}, plsql_code_type={code}, optimize_level={lvl}")
        bad |= status != "VALID"
    cur.execute("""SELECT type, line, position, attribute, text FROM user_errors
                   WHERE name = 'DOOM_HYBRID' ORDER BY type, sequence""")
    errs = cur.fetchall()
    native_unsupported = any("PLS-00924" in e[4] for e in errs)
    for typ, line, pos, attr, text in errs:
        if "PLS-00924" in text:
            continue
        print(f"[install_hybrid] {typ} {line}:{pos} {attr}: {text}")
    if native_unsupported:
        print("[install_hybrid] note: PLS-00924 'native compilation is not supported on this platform' -- "
              "units are VALID and execute as interpreted M-code (setting recorded as NATIVE)")
    if bad:
        sys.exit("[install_hybrid] FAILED")
    print("[install_hybrid] ok")


if __name__ == "__main__":
    main()
