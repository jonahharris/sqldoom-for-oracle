-- @output hexrows
-- HYBRID renderer, column range: the same frame as render_hybrid.sql restricted to screen columns
-- :x0 .. :x1 (rows carry 2 * (x1 - x0 + 1) hex chars). doomora.SplitRenderer runs two of these
-- on two sessions in parallel (one per Oracle Free CPU) and joins the halves of each row.
SELECT y, pal, hex FROM TABLE(doom_hybrid.render_frame(:tic, :map_id, :player_id, :skill, :px, :py, :pz, :pangle, :x0, :x1))
