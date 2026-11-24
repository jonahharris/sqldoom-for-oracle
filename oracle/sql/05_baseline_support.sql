-- =============================================================================
-- 05_baseline_support.sql -- support objects for oracle/sql/render_baseline.sql
--
-- Re-runnable (drops and recreates), plain SQL only (no PL/SQL blocks), so it
-- runs through client/oradb.run_script as well as SQL*Plus / SQLcl.
--
--  nums               IOT 0..4095. Replaces every generate_series(a, b) of the
--                     reference: JOIN nums g ON g.n BETWEEN a AND b (a > b gives
--                     no rows, exactly like generate_series).
--
--  blob_chunks        Replaces GET_BYTE(bytea, off). Every pixel BLOB the renderer
--                     samples is cut into 1000-byte blocks; each block is stored
--                     as an NVARCHAR2(1000) in which byte b is the character
--                     U+0100+b (AL16UTF16 is fixed width, so SUBSTR is O(1)).
--                       GET_BYTE(blob, off)
--                         = ASCII(SUBSTR(c.px, MOD(off, 1000) + 1, 1)) - 256
--                       with c the row (kind, name, blk = FLOOR(off / 1000)).
--                     The lookup is keyed on the flat byte offset, not on a
--                     (row, column) pair, so the reference's bounds semantics
--                     (offset < 0 or >= OCTET_LENGTH -> no byte) carry over
--                     exactly: a missing block or a SUBSTR past the end of the
--                     last block yields NULL.
--                     kind: 'W' walltex_meta.palette_indices, 'F' flat_textures,
--                           'P' sprite_lumps.pixels, 'M' sprite_lumps.mask.
--                     Rows: ~24k (13.3 MB walltex + 1 MB flats + 2x4.5 MB sprites).
--
--  render_segs_static View over the static render_segs table. The renderer
--                     defines a per-tic CTE named render_segs (current front /
--                     back sector heights, light and ceiling flat from
--                     st_sectors, plus st_render_seg_tex overrides); a WITH
--                     element cannot read a table of its own name (ORA-32039),
--                     so the CTE reads the table through this view.
-- =============================================================================

DROP TABLE IF EXISTS nums PURGE;
CREATE TABLE nums (n, CONSTRAINT nums_pk PRIMARY KEY (n))
  ORGANIZATION INDEX
AS SELECT CAST(LEVEL - 1 AS NUMBER(10)) AS n FROM dual CONNECT BY LEVEL <= 4096;

DROP TABLE IF EXISTS blob_chunks PURGE;
CREATE TABLE blob_chunks (
  kind  CHAR(1)         NOT NULL,
  name  VARCHAR2(8)     NOT NULL,
  blk   NUMBER(10)      NOT NULL,
  px    NVARCHAR2(1000) NOT NULL,
  CONSTRAINT blob_chunks_pk PRIMARY KEY (kind, name, blk)
) ORGANIZATION INDEX OVERFLOW;

INSERT /*+ APPEND */ INTO blob_chunks (kind, name, blk, px)
WITH src AS (
  SELECT 'W' AS kind, name, palette_indices AS b FROM walltex_meta
  UNION ALL SELECT 'F', name, palette_indices FROM flat_textures
  UNION ALL SELECT 'P', lump_name, pixels FROM sprite_lumps
  UNION ALL SELECT 'M', lump_name, mask FROM sprite_lumps
)
SELECT s.kind, s.name, g.n,
       UTL_RAW.CAST_TO_NVARCHAR2(HEXTORAW(REGEXP_REPLACE(
         RAWTOHEX(DBMS_LOB.SUBSTR(s.b, 1000, g.n * 1000 + 1)), '(..)', '01\1')))
FROM src s
JOIN nums g ON g.n < CEIL(DBMS_LOB.GETLENGTH(s.b) / 1000);

COMMIT;

CREATE OR REPLACE VIEW render_segs_static AS SELECT * FROM render_segs;

CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'NUMS');
CALL DBMS_STATS.GATHER_TABLE_STATS(USER, 'BLOB_CHUNKS');
