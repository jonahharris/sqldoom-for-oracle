-- @output hexrows
-- HYBRID renderer in the vanilla sprite mode (p_mode 1): the same frame as render_hybrid.sql except
-- that sprites are clipped as Doom does (by the silhouettes of the segs in front of them) instead of
-- being depth-tested against floors and ceilings. Not CedarDB-exact: for benchmarks and the clients'
-- default only; every correctness tool uses render_hybrid.sql.
SELECT y, pal, hex FROM TABLE(doom_hybrid.render_frame(:tic, :map_id, :player_id, :skill, :px, :py, :pz, :pangle, 0, 319, 1))
