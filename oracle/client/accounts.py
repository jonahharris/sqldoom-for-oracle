#!/usr/bin/env python3
"""Provision deathmatch accounts on Oracle (CedarDB scripts/add_player.py, add_spectator.py,
setup_roles.py). Runs as the game owner (DOOM), which has no CREATE/ALTER/DROP USER of its own: it
calls the DOOM_ADMIN.DOOM_ACCOUNTS broker (sql/12_api_admin.sql), which creates the user with
CREATE SESSION and one role (DOOM_PLAYER or DOOM_SPECTATOR) and nothing else.

    python oracle/client/accounts.py player alice [password]     # prints a generated password once
    python oracle/client/accounts.py spectator [name] [password]  # default name DOOM_SPECTATOR1
    python oracle/client/accounts.py roles                        # doom_player1, doom_player2 (setup_roles.py)
    python oracle/client/accounts.py drop alice [bob ...]         # remove accounts (and their registry rows)
    python oracle/client/accounts.py list

Re-running for an existing account resets its password and refreshes its grants. Accounts are
recorded in api_roles / api_spectator_roles (and in the broker's own table); api_install.py re-grants
them on every install.
"""
import os
import secrets
import string
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import oradb  # noqa: E402

DSN = oradb.DEFAULT_DSN


def strong_password(n=20):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(n)) + "-Dm1"


def add_account(cur, user, password, kind):
    r = cur.var(str)
    cur.execute("BEGIN :r := doom_admin.doom_accounts.add_account(:u, :p, :k); END;", r=r, u=user, p=password, k=kind)
    table = "api_roles" if kind == "player" else "api_spectator_roles"
    cur.execute(f"""MERGE INTO {table} t USING (SELECT UPPER(:u) AS role_name FROM dual) s ON (t.role_name = s.role_name)
                    WHEN NOT MATCHED THEN INSERT (role_name) VALUES (s.role_name)""", u=user)
    cur.connection.commit()
    return r.getvalue()


def drop_account(cur, user):
    r = cur.var(str)
    cur.execute("BEGIN :r := doom_admin.doom_accounts.drop_account(:u); END;", r=r, u=user)
    for table in ("api_roles", "api_spectator_roles", "g_mp_waiting", "g_mp_holders"):
        cur.execute(f"DELETE FROM {table} WHERE role_name = UPPER(:u)", u=user)
    cur.execute("UPDATE g_mp_players SET role_name = NULL, display_name = NULL, last_seen = NULL "
                "WHERE role_name = UPPER(:u)", u=user)
    cur.connection.commit()
    return r.getvalue()


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    conn = oradb.connect()
    cur = conn.cursor()
    if cmd == "player":
        if not args:
            raise SystemExit(__doc__)
        user, pw = args[0], (args[1] if len(args) > 1 else strong_password())
        print(f"{add_account(cur, user, pw, 'player')} {user.upper()}")
        print(f"  password {pw}")
        print(f"  DOOM_ORA_USER={user.upper()} DOOM_ORA_PASSWORD='{pw}' DOOM_ORA_DSN={DSN}")
    elif cmd == "spectator":
        user = args[0] if args else "DOOM_SPECTATOR1"
        pw = args[1] if len(args) > 1 else strong_password(28)
        print(f"{add_account(cur, user, pw, 'spectator')} {user.upper()} (READ on the spectator relations)")
        print(f"  password {pw}")
    elif cmd == "roles":
        for i, user in enumerate(("doom_player1", "doom_player2"), 1):
            pw = os.getenv(f"DOOM_PLAYER{i}_PASSWORD") or strong_password()
            print(f"{add_account(cur, user, pw, 'player')} {user.upper()}  password {pw}")
    elif cmd == "drop":
        for user in args:
            print(f"{drop_account(cur, user)} {user.upper()}")
    elif cmd == "list":
        cur.execute("SELECT role_name, 'player' FROM api_roles UNION ALL SELECT role_name, 'spectator' "
                    "FROM api_spectator_roles ORDER BY 1")
        for row in cur.fetchall():
            print(*row)
    else:
        raise SystemExit(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
