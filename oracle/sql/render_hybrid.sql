-- @output hexrows
-- HYBRID renderer (H27): one prepared SELECT over a pipelined PL/SQL function (sql/06_hybrid.sql).
-- Binds :tic :map_id :player_id :skill :px :py :pz :pangle (same as render_optimized.sql).
SELECT y, pal, hex FROM TABLE(doom_hybrid.render_frame(:tic, :map_id, :player_id, :skill, :px, :py, :pz, :pangle))
