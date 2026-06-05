// Render projection acceptance (spec §07 §4, §20): the terminal self→[Draw] pass
// turns a COMMITTED pong tick into the deterministic fixed-point draw-list that is
// the assertion ground truth. These tests run the GOLDEN pong program — startup
// plus a committed tick under a fixed Time dt and a recorded Input snapshot — and
// assert the draw-list by EXACT equality:
//
//   - render emits a bit-identical [Draw] list for a committed tick: the two
//     paddles and the ball as Draw::Rect, the score as a Draw::Text whose
//     `{self.left}   {self.right}` holes interpolate from the committed Scoreboard
//     columns, all in flattened-pipeline + stable-Id order;
//   - paddle_move reads the Input Steer::Move axis and Time.dt to move a paddle,
//     and that motion shows up in the paddle's Draw::Rect `at` — the draw-list of
//     the committed tick asserted by exact equality, input-driven;
//   - the projection is a pure function of the committed world: two renders of the
//     same committed tick produce an identical draw-list (the determinism surface).
package funpack_runtime

import "core:testing"

// render_dt is the fixed 60hz step the Time resource carries each tick: 1/60 in
// Q32.32 through the kernel — the same dt the tick fold advances by, no float.
@(private = "file")
render_dt :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(60))
}

// render_time is the Time resource the render pass and the fold both read: the one
// `dt` field at the fixed 60hz step. A render behavior reads only `self`, so this
// is observable-but-unused there; the fold's paddle_move consumes it.
@(private = "file")
render_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = render_dt()
	return Record_Value{type_name = "Time", fields = fields}
}

// render_startup runs setup's [Spawn] batch against the empty initial version,
// returning the populated base tick 0 reads — the pre-tick-0 population.
@(private = "file")
render_startup :: proc(program: ^Program, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	return run_startup(program, base, allocator)
}

// white_rect / white_text build the expected §20 commands from kernel-computed
// geometry, so the assertion is grounded in the fixed-point kernel, not in the
// renderer it checks.
@(private = "file")
white_rect :: proc(at, size: Vec2) -> Draw_Cmd {
	return Draw_Rect{at = at, size = size, color = .White}
}

@(private = "file")
white_text :: proc(at: Vec2, text: string) -> Draw_Cmd {
	return Draw_Text{at = at, text = text, color = .White}
}

// A committed pong tick over empty input renders the EXACT §20 draw-list: two
// paddle rects (P1 at its spawned x=8/y=60, P2 at x=152/y=60, each 4x16), the
// ball rect at its advanced position (3x3), and the score text "0   0" at (80, 8).
// The order is flattened-pipeline (draw_paddle, draw_ball, draw_score) and, within
// draw_paddle, stable Id order (P1 then P2). Asserted by exact command equality.
@(test)
test_render_committed_tick_draw_list :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := render_startup(&program, context.temp_allocator)
	dt := render_dt()

	// One tick over empty input: paddles stay put (dir 0), the ball advances by
	// vel*dt, the score stays 0/0.
	committed := step_tick(&program, base, empty(), render_time(context.temp_allocator), context.temp_allocator)

	draw := render_version(&program, committed, empty(), render_time(context.temp_allocator), context.temp_allocator)

	// The ball advanced from (80,60) by vel (70,40)*dt — the same kernel result the
	// tick fold committed.
	ball_at := Vec2 {
		fixed_add(to_fixed(80), fixed_mul(to_fixed(70), dt)),
		fixed_add(to_fixed(60), fixed_mul(to_fixed(40), dt)),
	}
	paddle_size := Vec2{to_fixed(4), to_fixed(16)}
	ball_size := Vec2{to_fixed(3), to_fixed(3)}

	want := []Draw_Cmd {
		white_rect(Vec2{to_fixed(8), to_fixed(60)}, paddle_size), // P1
		white_rect(Vec2{to_fixed(152), to_fixed(60)}, paddle_size), // P2
		white_rect(ball_at, ball_size), // ball
		white_text(Vec2{to_fixed(80), to_fixed(8)}, "0   0"), // score readout
	}

	expect_draw_list_equal(t, draw, want)
}

// paddle_move reads the Input Steer::Move axis and Time.dt to move a paddle, and
// the motion shows up in the paddle's Draw::Rect `at`. Holding P1's axis at +1 for
// one tick moves P1's y by speed*dt (clamped into the board), so P1's rect `at.y`
// is no longer the spawned 60 — the draw-list of the input-driven committed tick,
// asserted by exact equality against the kernel-computed moved position.
@(test)
test_render_paddle_move_from_input_and_dt :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := render_startup(&program, context.temp_allocator)
	dt := render_dt()

	// Hold P1's Steer::Move axis at +1 (ActionId 0 — the sole Axis variant): one
	// tick advances P1's y by dir(+1)*speed(90)*dt, clamped into [0, BOARD.h=120].
	// The snapshot and its producer intermediates live in the tick arena.
	context.allocator = context.temp_allocator
	input := with_value(empty(), .P1, ActionId(0), to_fixed(1))
	committed := step_tick(&program, base, input, render_time(context.temp_allocator), context.temp_allocator)

	draw := render_version(&program, committed, input, render_time(context.temp_allocator), context.temp_allocator)

	// P1 moved: y = clamp(60 + 1*90*dt, 0, 120) — the kernel value paddle_move
	// committed. The draw-list's first rect (P1, stable Id 0) carries it in `at`.
	moved_y := fixed_clamp(
		fixed_add(to_fixed(60), fixed_mul(fixed_mul(to_fixed(1), to_fixed(90)), dt)),
		to_fixed(0),
		to_fixed(120),
	)
	// The input actually moved the paddle off its spawn position.
	testing.expect(t, moved_y != to_fixed(60))

	first, first_ok := draw_at(draw, 0)
	testing.expect(t, first_ok)
	rect, is_rect := first.(Draw_Rect)
	testing.expect(t, is_rect)
	testing.expect_value(t, rect.at, Vec2{to_fixed(8), moved_y})
	testing.expect_value(t, rect.size, Vec2{to_fixed(4), to_fixed(16)})
	testing.expect_value(t, rect.color, Draw_Color.White)
}

// The score Text interpolates from the COMMITTED Scoreboard columns: a tick whose
// ball scored advances left 0→1, and the rendered score text reads "1   0" — the
// `{self.left}   {self.right}` holes resolved from the committed blackboard, not a
// template. This is the String-node completion exercised end to end.
@(test)
test_render_score_text_interpolates_committed_columns :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := render_startup(&program, context.temp_allocator)
	// Place the ball past the right edge (x=200 > BOARD.w=160) so this tick scores
	// a Left goal: tally bumps left 0→1, serve re-centers the ball.
	scored := place_ball_for_render(
		&program,
		base,
		Vec2{to_fixed(200), to_fixed(60)},
		Vec2{to_fixed(70), to_fixed(40)},
	)
	committed := step_tick(&program, scored, empty(), render_time(context.temp_allocator), context.temp_allocator)

	draw := render_version(&program, committed, empty(), render_time(context.temp_allocator), context.temp_allocator)

	// The last command is the score Text — left advanced to 1, right still 0.
	last, last_ok := draw_at(draw, len(draw.cmds) - 1)
	testing.expect(t, last_ok)
	text, is_text := last.(Draw_Text)
	testing.expect(t, is_text)
	testing.expect_value(t, text.text, "1   0")
	testing.expect_value(t, text.at, Vec2{to_fixed(80), to_fixed(8)})
}

// The render projection is a PURE function of the committed world: rendering the
// same committed tick twice produces an identical draw-list (the determinism
// surface §20 / §10.5). No working state, no Rng — the draw-list is reproducible.
@(test)
test_render_is_deterministic :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := render_startup(&program, context.temp_allocator)
	committed := step_tick(&program, base, empty(), render_time(context.temp_allocator), context.temp_allocator)

	first := render_version(&program, committed, empty(), render_time(context.temp_allocator), context.temp_allocator)
	second := render_version(&program, committed, empty(), render_time(context.temp_allocator), context.temp_allocator)
	testing.expect(t, draw_lists_equal(first, second))
}

// --- test helpers ---------------------------------------------------------

// draw_at reads the i-th draw command, ok=false out of range — the option-shaped
// positional read the assertions use over the draw-list.
@(private = "file")
draw_at :: proc(draw: Draw_List, i: int) -> (cmd: Draw_Cmd, ok: bool) {
	if i < 0 || i >= len(draw.cmds) {
		return nil, false
	}
	return draw.cmds[i], true
}

// expect_draw_list_equal asserts a draw-list equals an expected command sequence
// command-for-command — the exact-equality acceptance the §20 ground truth needs.
@(private = "file")
expect_draw_list_equal :: proc(t: ^testing.T, got: Draw_List, want: []Draw_Cmd) {
	if !testing.expectf(
		t,
		len(got.cmds) == len(want),
		"draw-list length: got %d, want %d",
		len(got.cmds),
		len(want),
	) {
		return
	}
	for cmd, i in want {
		testing.expect_value(t, got.cmds[i], cmd)
	}
}

// draw_lists_equal reports whether two draw-lists are command-identical — same
// count, same commands in the same order. The Draw_Cmd union compares
// structurally (a Fixed component compares by raw bits, a text by its bytes), so
// this is the bit-identical comparison the determinism assertion reads.
@(private = "file")
draw_lists_equal :: proc(a, b: Draw_List) -> bool {
	if len(a.cmds) != len(b.cmds) {
		return false
	}
	for cmd, i in a.cmds {
		if cmd != b.cmds[i] {
			return false
		}
	}
	return true
}

// place_ball_for_render commits a version identical to `prior` except the single
// Ball row carries the supplied pos/vel — the scoring-scenario fixture for the
// score-text interpolation test. It re-folds the Ball table through commit_version
// so the result is a real committed version the tick reads.
@(private = "file")
place_ball_for_render :: proc(
	program: ^Program,
	prior: World_Version,
	pos, vel: Vec2,
	allocator := context.temp_allocator,
) -> World_Version {
	prior_version := prior
	ball, _ := view_at(view_of_type(&prior_version, "Ball"), 0)
	fields := make(map[string]Field_Value, allocator)
	fields["pos"] = pos
	fields["vel"] = vel
	rows := make([]Row, 1, allocator)
	rows[0] = Row{id = ball.id, fields = fields}
	changed := make(map[string]Version_Table, allocator)
	changed["Ball"] = Version_Table {
		thing   = "Ball",
		rows    = rows,
		next_id = Thing_Id(1),
	}
	return commit_version(prior, changed, allocator)
}
