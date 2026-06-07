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

// --- (camera) Draw::Camera lowering (§3: the view is a command) ------------

// The Draw::Camera record the `view` behavior returns lowers to a Draw_Camera
// draw-list command carrying the exact fields. This mirrors yard's in-source
// `view emits the camera at its shaken position` test (glue_behaviors_test):
// a Camera at {80,60} with shake {2,0} returns Draw::Camera{at: {82,60}, zoom:
// 1.0, rotation: 0.0} — the glue story proves the behavior RETURNS that record;
// this story proves the record LOWERS to the Draw_Camera command the present pass
// projects. Built as the exact post-shake record the behavior emits, lowered by
// draw_command_from_record, asserted by exact field equality.
@(test)
test_camera_record_lowers_to_draw_camera :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// The record `view` returns: at = camera.at + camera.shake = {80,60}+{2,0} = {82,60}.
	cam := camera_draw_record(Vec2{to_fixed(82), to_fixed(60)}, to_fixed(1), to_fixed(0))

	cmd, ok := draw_command_from_record(cam)
	testing.expect(t, ok)
	camera, is_camera := cmd.(Draw_Camera)
	testing.expect(t, is_camera)
	testing.expect_value(t, camera.at, Vec2{to_fixed(82), to_fixed(60)})
	testing.expect_value(t, camera.zoom, to_fixed(1))
	testing.expect_value(t, camera.rotation, to_fixed(0))
}

// A Draw::Camera with no `at` field does NOT lower (ok=false): `at` is the one
// required field (the camera center), so a malformed Camera record contributes no
// command rather than faulting the projection — the totality the lowering rests on.
@(test)
test_camera_record_without_at_does_not_lower :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fields := make(map[string]Value, context.temp_allocator)
	fields["zoom"] = to_fixed(1)
	fields["rotation"] = to_fixed(0)
	cam := Record_Value{type_name = "Draw::Camera", fields = fields}

	_, ok := draw_command_from_record(cam)
	testing.expect(t, !ok)
}

// camera_draw_record builds the Draw::Camera record the `view` behavior emits — the
// at/zoom/rotation fields the lowering reads — so the assertion is grounded in the
// record shape, not in the lowering it checks.
@(private = "file")
camera_draw_record :: proc(at: Vec2, zoom, rotation: Fixed) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["at"] = at
	fields["zoom"] = zoom
	fields["rotation"] = rotation
	return Record_Value{type_name = "Draw::Camera", fields = fields}
}

// --- (palette) record_color closed-palette lowering + fail-loud refusal ----

// color_record builds a one-color draw-ish record carrying a `color` field naming
// the given Color case — the input record_color reads. case_name is the bare
// variant name (no "Color::" prefix), matching how the evaluator boxes a Color::X.
@(private = "file")
color_record :: proc(case_name: string) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["color"] = Variant_Value{enum_type = "Color", case_name = case_name}
	return Record_Value{type_name = "Draw::Rect", fields = fields}
}

// The four members the nine-member palette adds over the original five lower to
// their Draw_Color with ok=true — the extension closes the §20 palette to the
// spec render.fun named set (White..Gray). The original five are covered by the
// draw-list render tests above; this pins the new arms.
@(test)
test_record_color_lowers_new_palette_members :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cases := []struct {
		name: string,
		want: Draw_Color,
	} {
		{"Yellow", .Yellow},
		{"Cyan", .Cyan},
		{"Magenta", .Magenta},
		{"Gray", .Gray},
	}
	for c in cases {
		got, ok := record_color(color_record(c.name), "color")
		testing.expectf(t, ok, "%s must lower with ok=true", c.name)
		testing.expect_value(t, got, c.want)
	}
}

// An ABSENT color field is the well-formed "no color stated" shape: it defaults to
// White with ok=true (pong's common case), NOT a refusal — only a PRESENT,
// out-of-palette name refuses.
@(test)
test_record_color_absent_field_defaults_white_ok :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	rec := Record_Value{type_name = "Draw::Rect", fields = make(map[string]Value, context.temp_allocator)}
	got, ok := record_color(rec, "color")
	testing.expect(t, ok)
	testing.expect_value(t, got, Draw_Color.White)
}

// An UNKNOWN color case_name REFUSES (ok=false) — fail-closed: a silent White
// fallback would mispaint any out-of-palette color (a Gray ground plane
// rendering White). The refusal must hold for any name outside the closed nine
// (a typo, a future member, or the spec's `Color::Rgb{...}` escape the named
// draw-list has no slot for). The returned ok=false is the loud signal; the
// color value is not consumed.
@(test)
test_record_color_unknown_name_refuses :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	_, ok_typo := record_color(color_record("Whtie"), "color")
	testing.expect(t, !ok_typo)
	_, ok_rgb := record_color(color_record("Rgb"), "color")
	testing.expect(t, !ok_rgb)
	_, ok_future := record_color(color_record("Chartreuse"), "color")
	testing.expect(t, !ok_future)
}

// The fail-loud refusal PROPAGATES through draw_command_from_record: a Draw::Rect
// naming an out-of-palette color does NOT lower (ok=false), so append_draw_commands
// DROPS it from the draw-list rather than emitting a White-mispainted command — the
// closed-palette contract enforced end-to-end at the projection boundary.
@(test)
test_draw_command_unknown_color_does_not_lower :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fields := make(map[string]Value, context.temp_allocator)
	fields["at"] = Vec2{to_fixed(1), to_fixed(2)}
	fields["size"] = Vec2{to_fixed(3), to_fixed(4)}
	fields["color"] = Variant_Value{enum_type = "Color", case_name = "Rgb"}
	rec := Record_Value{type_name = "Draw::Rect", fields = fields}

	_, ok := draw_command_from_record(rec)
	testing.expect(t, !ok)

	// A well-formed Gray Draw::Rect, by contrast, lowers and carries the member.
	fields["color"] = Variant_Value{enum_type = "Color", case_name = "Gray"}
	cmd, gray_ok := draw_command_from_record(rec)
	testing.expect(t, gray_ok)
	rect, is_rect := cmd.(Draw_Rect)
	testing.expect(t, is_rect)
	testing.expect_value(t, rect.color, Draw_Color.Gray)
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
		testing.expect(t, draw_cmd_equal(got.cmds[i], cmd))
	}
}

// draw_lists_equal reports whether two draw-lists are command-identical — same
// count, same commands in the same order. It folds through draw_cmd_equal (a Fixed
// component compares by raw bits, a text by its bytes, a rig by its handles/pose
// structurally), the bit-identical comparison the determinism assertion reads — the
// Draw_Cmd union is no longer simply comparable since Draw3_Rigged carries slices.
@(private = "file")
draw_lists_equal :: proc(a, b: Draw_List) -> bool {
	if len(a.cmds) != len(b.cmds) {
		return false
	}
	for cmd, i in a.cmds {
		if !draw_cmd_equal(cmd, b.cmds[i]) {
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
