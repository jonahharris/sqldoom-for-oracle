-- =============================================================================
-- 12_api_admin.sql -- the account broker for the deathmatch server (run ONCE as SYSTEM in
-- FREEPDB1; client/api_install.py --admin does it with the SYSTEM password of
-- docker-compose.yml).
--
-- CedarDB's add_player.py runs `CREATE ROLE ... LOGIN PASSWORD` as the database owner, who
-- is a superuser there. On Oracle, CREATE USER / ALTER USER / DROP USER are system privileges
-- that reach every account of the PDB (ALTER USER could reset SYSTEM's password). So the game
-- owner DOOM gets none of them. Instead:
--
--   DOOM_PLAYER, DOOM_SPECTATOR   roles; DOOM grants its api_* objects to them (READ on views,
--                                 EXECUTE on the api_* functions) and nothing else
--   DOOM_ADMIN                    a schema-only account (NO AUTHENTICATION: nobody can log in
--                                 as it) holding CREATE/ALTER/DROP USER, CREATE SESSION WITH
--                                 ADMIN OPTION and the two roles WITH ADMIN OPTION
--   DOOM_ADMIN.DOOM_ACCOUNTS      a definer-rights package: create / re-password / drop ONLY
--                                 accounts it created itself (its ACCOUNTS table), with a fixed
--                                 grant set (CREATE SESSION + one of the two roles)
--   EXECUTE ON DOOM_ADMIN.DOOM_ACCOUNTS TO DOOM   the only new privilege the game owner gets
--
-- Re-runnable.
-- =============================================================================
DECLARE
  PROCEDURE x(s VARCHAR2) IS BEGIN EXECUTE IMMEDIATE s; EXCEPTION WHEN OTHERS THEN
    IF SQLCODE NOT IN (-1920, -1921, -2379, -955, -1031) THEN RAISE; END IF; END;
BEGIN
  x('CREATE ROLE doom_player');
  x('CREATE ROLE doom_spectator');
  -- CedarDB's add_spectator.py: CONNECTION LIMIT 16 for the explorer login
  x('CREATE PROFILE doom_spectator_profile LIMIT SESSIONS_PER_USER 16');
  x('CREATE USER doom_admin NO AUTHENTICATION DEFAULT TABLESPACE users QUOTA 10M ON users');
END;
/
GRANT CREATE USER, ALTER USER, DROP USER TO doom_admin
/
GRANT CREATE SESSION TO doom_admin WITH ADMIN OPTION
/
GRANT doom_player, doom_spectator TO doom_admin WITH ADMIN OPTION
/
CREATE TABLE IF NOT EXISTS doom_admin.accounts (
  username   VARCHAR2(128) PRIMARY KEY,
  kind       VARCHAR2(16)  NOT NULL CHECK (kind IN ('player', 'spectator')),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL
)
/
CREATE OR REPLACE PACKAGE doom_admin.doom_accounts AUTHID DEFINER AS
  -- 'created' or 'updated' (password reset + grants refreshed). Refuses a name that belongs to
  -- an account this package did not create.
  FUNCTION add_account(p_user VARCHAR2, p_password VARCHAR2, p_kind VARCHAR2) RETURN VARCHAR2;
  -- 'dropped' / 'absent'; only accounts this package created
  FUNCTION drop_account(p_user VARCHAR2) RETURN VARCHAR2;
  -- grant the role again to every account still present (after a reinstall); returns the count
  FUNCTION regrant RETURN NUMBER;
END doom_accounts;
/
CREATE OR REPLACE PACKAGE BODY doom_admin.doom_accounts AS
  FUNCTION norm_user(p_user VARCHAR2) RETURN VARCHAR2 IS
    u VARCHAR2(128) := UPPER(TRIM(p_user));
  BEGIN
    -- letters, digits and _ only, a letter first (add_player.py's rule), no Oracle-reserved prefix
    IF u IS NULL OR NOT REGEXP_LIKE(u, '^[A-Z][A-Z0-9_]{0,29}$')
       OR REGEXP_LIKE(u, '^(SYS|ORA|APEX|XDB|DBSNMP|GSM|DVSYS|LBAC|OJVM|AUDSYS|DOOM$|DOOM_ADMIN$)') THEN
      RAISE_APPLICATION_ERROR(-20901, 'account names are letters, digits and _ (a letter first): ' || p_user);
    END IF;
    RETURN u;
  END;

  FUNCTION role_of(p_kind VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF p_kind = 'player' THEN RETURN 'DOOM_PLAYER'; END IF;
    IF p_kind = 'spectator' THEN RETURN 'DOOM_SPECTATOR'; END IF;
    RAISE_APPLICATION_ERROR(-20902, 'kind is player or spectator');
  END;

  FUNCTION add_account(p_user VARCHAR2, p_password VARCHAR2, p_kind VARCHAR2) RETURN VARCHAR2 IS
    u VARCHAR2(128) := norm_user(p_user); r VARCHAR2(30) := role_of(p_kind);
    n_all NUMBER; n_mine NUMBER; v_kind VARCHAR2(16);
  BEGIN
    IF p_password IS NULL OR NOT REGEXP_LIKE(p_password, '^[A-Za-z0-9_!#%+.:=?@-]{8,100}$') THEN
      RAISE_APPLICATION_ERROR(-20903, 'passwords are 8-100 of A-Z a-z 0-9 _!#%+.:=?@-');
    END IF;
    SELECT COUNT(*) INTO n_all FROM all_users WHERE username = u;
    SELECT COUNT(*), MAX(kind) INTO n_mine, v_kind FROM accounts WHERE username = u;
    IF n_all > 0 AND n_mine = 0 THEN
      RAISE_APPLICATION_ERROR(-20904, u || ' exists and is not a Doom account');
    END IF;
    IF n_mine > 0 AND v_kind <> p_kind THEN
      RAISE_APPLICATION_ERROR(-20905, u || ' is a Doom ' || v_kind || ' account');
    END IF;
    IF n_all = 0 THEN
      EXECUTE IMMEDIATE 'CREATE USER ' || u || ' IDENTIFIED BY "' || p_password || '"'
                        || ' DEFAULT TABLESPACE users'
                        || CASE WHEN p_kind = 'spectator' THEN ' PROFILE doom_spectator_profile' END;
    ELSE
      EXECUTE IMMEDIATE 'ALTER USER ' || u || ' IDENTIFIED BY "' || p_password || '" ACCOUNT UNLOCK';
    END IF;
    EXECUTE IMMEDIATE 'GRANT CREATE SESSION TO ' || u;
    EXECUTE IMMEDIATE 'GRANT ' || r || ' TO ' || u;
    EXECUTE IMMEDIATE 'ALTER USER ' || u || ' DEFAULT ROLE ALL';
    IF n_mine = 0 THEN
      INSERT INTO accounts (username, kind) VALUES (u, p_kind);
      COMMIT;
    END IF;
    RETURN CASE WHEN n_all = 0 THEN 'created' ELSE 'updated' END;
  END;

  FUNCTION drop_account(p_user VARCHAR2) RETURN VARCHAR2 IS
    u VARCHAR2(128) := norm_user(p_user); n_mine NUMBER; n_all NUMBER;
  BEGIN
    SELECT COUNT(*) INTO n_mine FROM accounts WHERE username = u;
    IF n_mine = 0 THEN RETURN 'absent'; END IF;
    SELECT COUNT(*) INTO n_all FROM all_users WHERE username = u;
    IF n_all > 0 THEN
      -- ORA-01940 while the account is logged in: the caller disconnects it first
      -- (no ALTER SYSTEM here: killing sessions is not this package's business)
      EXECUTE IMMEDIATE 'DROP USER ' || u || ' CASCADE';
    END IF;
    DELETE FROM accounts WHERE username = u;
    COMMIT;
    RETURN 'dropped';
  END;

  FUNCTION regrant RETURN NUMBER IS
    n NUMBER := 0;
  BEGIN
    FOR a IN (SELECT a.username, a.kind FROM accounts a JOIN all_users u ON u.username = a.username) LOOP
      EXECUTE IMMEDIATE 'GRANT CREATE SESSION TO ' || a.username;
      EXECUTE IMMEDIATE 'GRANT ' || role_of(a.kind) || ' TO ' || a.username;
      n := n + 1;
    END LOOP;
    RETURN n;
  END;
END doom_accounts;
/
GRANT EXECUTE ON doom_admin.doom_accounts TO doom
/
