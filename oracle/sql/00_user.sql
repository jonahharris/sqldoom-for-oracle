-- Run as SYSTEM in FREEPDB1 (client/setup_db.py does this). The gvenzl image already creates
-- the DOOM application user (APP_USER in docker-compose.yml); this grants what the project needs:
-- dynamic performance views for benchmarking (V$SQL, V$MYSTAT, ...) and plan inspection
-- (DBMS_XPLAN.DISPLAY_CURSOR with ALLSTATS LAST). No licensed management packs are used.
GRANT SELECT_CATALOG_ROLE TO doom;
GRANT SELECT ANY DICTIONARY TO doom;
GRANT ALTER SESSION TO doom;
ALTER USER doom QUOTA UNLIMITED ON users;
