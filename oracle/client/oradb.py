"""Shared Oracle helpers for the SQL Doom data-layer loaders."""
import os
from pathlib import Path

import oracledb

ORACLE_DIR = Path(__file__).resolve().parents[1]
SQL_DIR = ORACLE_DIR / "sql"

DEFAULT_DSN = os.getenv("DOOM_ORA_DSN", "localhost:1521/FREEPDB1")
DEFAULT_USER = os.getenv("DOOM_ORA_USER", "doom")
DEFAULT_PASSWORD = os.getenv("DOOM_ORA_PASSWORD", "doom")


def connect(dsn=DEFAULT_DSN, user=DEFAULT_USER, password=DEFAULT_PASSWORD):
    return oracledb.connect(user=user, password=password, dsn=dsn)


def split_statements(sql: str):
    """Split a plain-SQL script (no PL/SQL blocks) on ';', dropping -- comments
    and respecting '...' string literals."""
    out, cur = [], []
    in_str = in_comment = False
    i, n = 0, len(sql)
    while i < n:
        ch = sql[i]
        if in_comment:
            if ch == "\n":
                in_comment = False
                cur.append(ch)
        elif in_str:
            cur.append(ch)
            if ch == "'":
                if sql[i + 1:i + 2] == "'":
                    cur.append("'")
                    i += 1
                else:
                    in_str = False
        elif ch == "-" and sql[i + 1:i + 2] == "-":
            in_comment = True
            i += 1
        elif ch == "'":
            in_str = True
            cur.append(ch)
        elif ch == ";":
            stmt = "".join(cur).strip()
            if stmt:
                out.append(stmt)
            cur = []
        else:
            cur.append(ch)
        i += 1
    tail = "".join(cur).strip()
    if tail:
        out.append(tail)
    return out


def run_script(cur, path: Path):
    for stmt in split_statements(Path(path).read_text(encoding="utf-8")):
        cur.execute(stmt)


def gather_stats(cur, tables):
    for t in tables:
        cur.execute(
            "BEGIN DBMS_STATS.GATHER_TABLE_STATS(ownname => USER, tabname => :t,"
            " cascade => TRUE, no_invalidate => FALSE); END;", t=t.upper())
