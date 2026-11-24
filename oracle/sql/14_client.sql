-- =============================================================================
-- 14_client.sql -- what the desktop client's statements need beyond the game packages
-- (phase 6). Installed by client/api_install.py (also --client-only).
--
-- doom_float8: CedarDB's conversion of a client's float8 parameter. The reference client sends a
-- Python float as its shortest decimal text (psycopg2) and CedarDB turns that literal into a
-- float8 as float8(mantissa rounded to 53 bits) / float8(10^scale) -- not always the correctly
-- rounded double. python-oracledb binds a Python float as a NUMBER holding the same shortest
-- digits, so this function, given that NUMBER, returns the double CedarDB would have used
-- (the same arithmetic as doom_hybrid.pose_conv / render_optimized.sql pose_conv). The camera
-- statement (client/camera_pose.sql: the alpha between two tics) uses it for its alpha.
-- =============================================================================
CREATE OR REPLACE FUNCTION doom_float8(x NUMBER) RETURN BINARY_DOUBLE DETERMINISTIC IS
  PRAGMA UDF;
  s VARCHAR2(200); dp PLS_INTEGER; p10 NUMBER; m NUMBER; ulp NUMBER; q NUMBER; r NUMBER;
BEGIN
  IF x IS NULL THEN RETURN NULL; END IF;
  IF x = 0 THEN RETURN 0d; END IF;
  IF ABS(x) < 1e-4 OR ABS(x) >= 1e16 THEN RETURN TO_BINARY_DOUBLE(x); END IF;
  s := TO_CHAR(ABS(x), 'TM9');
  dp := INSTR(s, '.');
  p10 := POWER(10, CASE WHEN dp = 0 THEN 0 ELSE LENGTH(s) - dp END);
  m := x * p10;
  ulp := CASE WHEN ABS(m) < 9007199254740992 THEN 1 WHEN ABS(m) < 18014398509481984 THEN 2
              WHEN ABS(m) < 36028797018963968 THEN 4 WHEN ABS(m) < 72057594037927936 THEN 8 ELSE 16 END;
  q := m / ulp;
  IF ABS(q - TRUNC(q)) = 0.5 THEN r := 2 * ROUND(m / ulp / 2); ELSE r := ROUND(m / ulp); END IF;
  RETURN TO_BINARY_DOUBLE(r * ulp) / TO_BINARY_DOUBLE(p10);
END;
/
