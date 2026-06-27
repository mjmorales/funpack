package funpack

import "core:log"
import "core:os"
import "core:testing"

compile_snippet :: proc(source: string) -> (typed: Typed_Ast, flat: Flattened_Pipeline, ok: bool) {
	return compile_for_index(source)
}

contains_str :: proc(haystack: []string, needle: string) -> bool {
	for s in haystack {
		if s == needle {
			return true
		}
	}
	return false
}

find_record :: proc(records: []Decl_Record, name: string) -> (record: Decl_Record, found: bool) {
	for r in records {
		if r.qualified_name == name {
			return r, true
		}
	}
	return Decl_Record{}, false
}

@(test)
test_index_decl_kind_and_span :: proc(t: ^testing.T) {
	source := `data Board { w: Int, h: Int }
enum Side { Left, Right }
thing Ball { pos: Int }
signal Goal { side: Int }
fn add(a: Int, b: Int) -> Int {
  return a + b
}
let MAX: Int = 9
`
	typed, flat, ok := compile_snippet(source)
	testing.expect(t, ok)
	if !ok {
		return
	}
	records := derive_decl_records("", typed, flat)

	board, has_board := find_record(records, "Board")
	testing.expect(t, has_board)
	testing.expect_value(t, board.kind, Index_Decl_Kind.Data)
	testing.expect_value(t, board.span, 1)

	side, has_side := find_record(records, "Side")
	testing.expect(t, has_side)
	testing.expect_value(t, side.kind, Index_Decl_Kind.Enum)
	testing.expect_value(t, side.span, 2)

	ball, has_ball := find_record(records, "Ball")
	testing.expect(t, has_ball)
	testing.expect_value(t, ball.kind, Index_Decl_Kind.Thing)
	testing.expect_value(t, ball.span, 3)

	goal, has_goal := find_record(records, "Goal")
	testing.expect(t, has_goal)
	testing.expect_value(t, goal.kind, Index_Decl_Kind.Signal)
	testing.expect_value(t, goal.span, 4)

	add, has_add := find_record(records, "add")
	testing.expect(t, has_add)
	testing.expect_value(t, add.kind, Index_Decl_Kind.Fn)
	testing.expect_value(t, add.span, 5)

	max_let, has_let := find_record(records, "MAX")
	testing.expect(t, has_let)
	testing.expect_value(t, max_let.kind, Index_Decl_Kind.Let)
	testing.expect_value(t, max_let.span, 8)

	testing.expect_value(t, board.schema_version, INDEX_SCHEMA_VERSION)
	testing.expect_value(t, board.qualified_name, "Board")
	testing.expect_value(t, board.stub, false)
	testing.expect_value(t, board.todo, false)
	testing.expect_value(t, len(board.debug), 0)
	log.infof("index decl kind/span derivation verified over snippet AST (%d decls)", len(records))
}

@(test)
test_index_decl_exposed_from_directive :: proc(t: ^testing.T) {
	source := `@expose
data Hex { q: Int, r: Int }
data Cube { x: Int, y: Int }
@doc("The package's public API.")
@expose
fn axial_to_pixel(q: Int) -> Int {
  return q
}
fn cube_round(x: Int) -> Int {
  return x
}
test "round-trips" {
  assert cube_round(1) == 1
}
`
	typed, flat, ok := compile_snippet(source)
	testing.expect(t, ok)
	if !ok {
		return
	}
	records := derive_decl_records("", typed, flat)

	hex, has_hex := find_record(records, "Hex")
	testing.expect(t, has_hex)
	testing.expect_value(t, hex.exposed, true)

	cube, has_cube := find_record(records, "Cube")
	testing.expect(t, has_cube)
	testing.expect_value(t, cube.exposed, false)

	api_fn, has_api := find_record(records, "axial_to_pixel")
	testing.expect(t, has_api)
	testing.expect_value(t, api_fn.exposed, true)
	testing.expect_value(t, api_fn.doc, "The package's public API.")

	helper, has_helper := find_record(records, "cube_round")
	testing.expect(t, has_helper)
	testing.expect_value(t, helper.exposed, false)

	block, has_block := find_record(records, "round-trips")
	testing.expect(t, has_block)
	testing.expect_value(t, block.exposed, false)

	line := emit_decl_record(api_fn, context.temp_allocator)
	decoded, decode_err := decode_index_line(line, context.temp_allocator)
	testing.expect_value(t, decode_err, Index_Read_Error.None)
	if decl, is_decl := decoded.(Decl_Record); is_decl {
		testing.expect_value(t, decl.exposed, true)
	} else {
		testing.expect(t, is_decl)
	}
}

@(test)
test_index_decl_doc_escaped_quote_round_trips :: proc(t: ^testing.T) {
	source := "@doc(\"Built by interpolation (\\\"{x}\\\"), never +.\")\nfn greet(x: Int) -> Int {\n  return x\n}\n"
	typed, flat, ok := compile_snippet(source)
	testing.expect(t, ok)
	if !ok {
		return
	}
	records := derive_decl_records("", typed, flat)
	greet, has_greet := find_record(records, "greet")
	testing.expect(t, has_greet)
	if !has_greet {
		return
	}
	raw_doc := `Built by interpolation (\"{x}\"), never +.`
	testing.expect_value(t, greet.doc, raw_doc)

	line := emit_decl_record(greet, context.temp_allocator)
	decoded, decode_err := decode_index_line(line, context.temp_allocator)
	testing.expect_value(t, decode_err, Index_Read_Error.None)
	if decl, is_decl := decoded.(Decl_Record); is_decl {
		testing.expect_value(t, decl.doc, raw_doc)
	} else {
		testing.expect(t, is_decl)
	}
}

@(test)
test_index_decl_query_record :: proc(t: ^testing.T) {
	source := `thing Enemy { cell: Vec2 }
fn shift(v: Vec2) -> Vec2 {
  return v
}
@doc("Nearest enemy cell to the origin.")
@spatial(Enemy.cell)
query nearest_cell(origin: Vec2) -> Vec2 {
  return shift(origin)
}
`
	typed, flat, ok := compile_snippet(source)
	testing.expect(t, ok)
	if !ok {
		return
	}
	records := derive_decl_records("", typed, flat)
	testing.expect_value(t, len(records), 3)

	query, has_query := find_record(records, "nearest_cell")
	testing.expect(t, has_query)
	if !has_query {
		return
	}
	testing.expect_value(t, query.schema_version, INDEX_SCHEMA_VERSION)
	testing.expect_value(t, query.kind, Index_Decl_Kind.Query)
	testing.expect_value(t, query.span, 7)
	testing.expect_value(t, query.doc, "Nearest enemy cell to the origin.")
	testing.expect_value(t, query.stub, false)
	testing.expect_value(t, query.todo, false)
	testing.expect(t, contains_str(query.calls, "shift"))
	testing.expect(t, query.dup_class != 0)
	testing.expect_value(t, len(query.emits), 0)
	testing.expect_value(t, len(query.consumes), 0)
	testing.expect_value(t, len(query.mut_data), 0)

	line := emit_decl_record(query, context.temp_allocator)
	decoded, decode_err := decode_index_line(line, context.temp_allocator)
	testing.expect_value(t, decode_err, Index_Read_Error.None)
	decoded_decl, is_decl := decoded.(Decl_Record)
	testing.expect(t, is_decl)
	if is_decl {
		testing.expect_value(t, decoded_decl.kind, Index_Decl_Kind.Query)
		testing.expect_value(t, decoded_decl.qualified_name, "nearest_cell")
	}
}

@(test)
test_index_decl_extern_type_record :: proc(t: ^testing.T) {
	source := `@doc("an immutable 2D outline")
@expose
extern type Sketch
extern type Anchors
`
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	records := derive_decl_records("", Typed_Ast{ast = ast}, Flattened_Pipeline{})
	testing.expect_value(t, len(records), 2)

	sketch, has_sketch := find_record(records, "Sketch")
	testing.expect(t, has_sketch)
	if !has_sketch {
		return
	}
	testing.expect_value(t, sketch.schema_version, INDEX_SCHEMA_VERSION)
	testing.expect_value(t, sketch.kind, Index_Decl_Kind.Extern_Type)
	testing.expect_value(t, sketch.span, 3)
	testing.expect_value(t, sketch.doc, "an immutable 2D outline")
	testing.expect_value(t, sketch.exposed, true)
	testing.expect_value(t, sketch.stub, false)
	testing.expect_value(t, sketch.todo, false)
	testing.expect_value(t, sketch.dup_class, u64(0))
	testing.expect_value(t, len(sketch.calls), 0)
	testing.expect_value(t, len(sketch.emits), 0)
	testing.expect_value(t, len(sketch.consumes), 0)
	testing.expect_value(t, len(sketch.mut_data), 0)

	anchors, has_anchors := find_record(records, "Anchors")
	testing.expect(t, has_anchors)
	testing.expect_value(t, anchors.exposed, false)

	line := emit_decl_record(sketch, context.temp_allocator)
	decoded, decode_err := decode_index_line(line, context.temp_allocator)
	testing.expect_value(t, decode_err, Index_Read_Error.None)
	decoded_decl, is_decl := decoded.(Decl_Record)
	testing.expect(t, is_decl)
	if is_decl {
		testing.expect_value(t, decoded_decl.kind, Index_Decl_Kind.Extern_Type)
		testing.expect_value(t, decoded_decl.qualified_name, "Sketch")
	}
	log.infof("index decl extern type record verified (kind Extern_Type, schema v%d)", INDEX_SCHEMA_VERSION)
}

@(test)
test_index_decl_generic_header_stays_ast_side :: proc(t: ^testing.T) {
	source := `enum Option[T] { Some(T), None }
data Ref[T] { id: Id }
extern type View[T]
`
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	records := derive_decl_records("", Typed_Ast{ast = ast}, Flattened_Pipeline{})
	testing.expect_value(t, len(records), 3)

	option, has_option := find_record(records, "Option")
	testing.expect(t, has_option)
	if has_option {
		testing.expect_value(t, option.kind, Index_Decl_Kind.Enum)
		testing.expect_value(t, option.schema_version, INDEX_SCHEMA_VERSION)
	}
	ref, has_ref := find_record(records, "Ref")
	testing.expect(t, has_ref)
	if has_ref {
		testing.expect_value(t, ref.kind, Index_Decl_Kind.Data)
	}
	view, has_view := find_record(records, "View")
	testing.expect(t, has_view)
	if has_view {
		testing.expect_value(t, view.kind, Index_Decl_Kind.Extern_Type)
	}
	log.infof("index decl generic-header records verified (bare names, schema v%d unchanged)", INDEX_SCHEMA_VERSION)
}

@(test)
test_index_decl_stub_from_holes :: proc(t: ^testing.T) {
	source := `data Board { w: Int, h: Int }
fn holed() -> Int @stub(Int)
fn approximated() -> Int @stub(Int, 0)
fn intact() -> Int {
  return 1
}
behavior ghost on Board {
  fn step(self: Board) -> Board @stub(Board)
}
behavior solid on Board {
  fn step(self: Board) -> Board {
    return self
  }
}
`
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	records := derive_decl_records("", Typed_Ast{ast = ast}, Flattened_Pipeline{})

	holed, has_holed := find_record(records, "holed")
	testing.expect(t, has_holed)
	testing.expect_value(t, holed.stub, true)
	testing.expect_value(t, holed.kind, Index_Decl_Kind.Fn)
	approximated, has_approximated := find_record(records, "approximated")
	testing.expect(t, has_approximated)
	testing.expect_value(t, approximated.stub, true)

	intact, has_intact := find_record(records, "intact")
	testing.expect(t, has_intact)
	testing.expect_value(t, intact.stub, false)

	ghost, has_ghost := find_record(records, "ghost")
	testing.expect(t, has_ghost)
	testing.expect_value(t, ghost.stub, true)
	testing.expect_value(t, ghost.kind, Index_Decl_Kind.Behavior)
	solid, has_solid := find_record(records, "solid")
	testing.expect(t, has_solid)
	testing.expect_value(t, solid.stub, false)

	board, has_board := find_record(records, "Board")
	testing.expect(t, has_board)
	testing.expect_value(t, board.stub, false)
	for r in records {
		testing.expect_value(t, r.todo, false)
		testing.expect_value(t, len(r.debug), 0)
	}
	log.infof("index decl stub derivation verified (holed fn/behavior true, intact and body-less false)")
}

@(test)
test_index_decl_debug_from_probes :: proc(t: ^testing.T) {
	source := `data Board { w: Int, h: Int }
@break(self.w > 70)
behavior paused on Board {
  fn step(self: Board) -> Board {
    return self
  }
}
@log(self.w)
@log(self.h)
@watch(self.w)
@trace
behavior noisy on Board {
  fn step(self: Board) -> Board {
    return self
  }
}
behavior quiet on Board {
  fn step(self: Board) -> Board {
    return self
  }
}
`
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	records := derive_decl_records("", Typed_Ast{ast = ast}, Flattened_Pipeline{})

	paused, has_paused := find_record(records, "paused")
	testing.expect(t, has_paused)
	testing.expect_value(t, len(paused.debug), 1)
	if len(paused.debug) == 1 {
		testing.expect_value(t, paused.debug[0], "break")
	}

	noisy, has_noisy := find_record(records, "noisy")
	testing.expect(t, has_noisy)
	testing.expect_value(t, len(noisy.debug), 4)
	if len(noisy.debug) == 4 {
		testing.expect_value(t, noisy.debug[0], "log")
		testing.expect_value(t, noisy.debug[1], "log")
		testing.expect_value(t, noisy.debug[2], "watch")
		testing.expect_value(t, noisy.debug[3], "trace")
	}

	quiet, has_quiet := find_record(records, "quiet")
	testing.expect(t, has_quiet)
	testing.expect_value(t, len(quiet.debug), 0)
	board, has_board := find_record(records, "Board")
	testing.expect(t, has_board)
	testing.expect_value(t, len(board.debug), 0)
	log.infof("index decl debug derivation verified (probe names in authored order, no dedupe, [] when probe-free)")
}

@(test)
test_index_decl_todo_from_notes :: proc(t: ^testing.T) {
	source := `data Board { w: Int, h: Int }
@todo("shrink the board", 2w)
data Pending { w: Int }
@todo("retire the alias", T-0042)
@todo("fold into Board", 2026-09-01)
fn alias() -> Int {
  return 1
}
behavior calm on Board {
  fn step(self: Board) -> Board {
    return self
  }
}
@todo("rework the step", 50builds)
behavior restless on Board {
  fn step(self: Board) -> Board {
    return self
  }
}
`
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	records := derive_decl_records("", Typed_Ast{ast = ast}, Flattened_Pipeline{})

	pending, has_pending := find_record(records, "Pending")
	testing.expect(t, has_pending)
	testing.expect_value(t, pending.todo, true)

	alias, has_alias := find_record(records, "alias")
	testing.expect(t, has_alias)
	testing.expect_value(t, alias.todo, true)
	testing.expect_value(t, alias.kind, Index_Decl_Kind.Fn)
	testing.expect_value(t, alias.stub, false)

	restless, has_restless := find_record(records, "restless")
	testing.expect(t, has_restless)
	testing.expect_value(t, restless.todo, true)

	board, has_board := find_record(records, "Board")
	testing.expect(t, has_board)
	testing.expect_value(t, board.todo, false)
	calm, has_calm := find_record(records, "calm")
	testing.expect(t, has_calm)
	testing.expect_value(t, calm.todo, false)
	log.infof("index decl todo derivation verified (note presence true across kinds, one flag for many notes, false when note-free)")
}

@(test)
test_index_decl_emits_consumes :: proc(t: ^testing.T) {
	hit := Signal_Route {
		signal    = "Hit",
		producers = {Signal_Endpoint{ordinal = 1, behavior = "score"}},
		consumers = {Signal_Endpoint{ordinal = 2, behavior = "tally"}},
	}
	tick := Signal_Route {
		signal    = "Tick",
		producers = {Signal_Endpoint{ordinal = 0, behavior = "clock"}},
		consumers = {Signal_Endpoint{ordinal = 1, behavior = "score"}},
	}
	routes := []Signal_Route{hit, tick}

	score_emits := decl_behavior_emits("score", routes)
	testing.expect_value(t, len(score_emits), 1)
	if len(score_emits) == 1 {
		testing.expect_value(t, score_emits[0], "Hit")
	}
	score_consumes := decl_behavior_consumes("score", routes)
	testing.expect_value(t, len(score_consumes), 1)
	if len(score_consumes) == 1 {
		testing.expect_value(t, score_consumes[0], "Tick")
	}

	tally_emits := decl_behavior_emits("tally", routes)
	testing.expect_value(t, len(tally_emits), 0)
	tally_consumes := decl_behavior_consumes("tally", routes)
	testing.expect_value(t, len(tally_consumes), 1)
	if len(tally_consumes) == 1 {
		testing.expect_value(t, tally_consumes[0], "Hit")
	}

	none_emits := decl_behavior_emits("unwired", routes)
	testing.expect_value(t, len(none_emits), 0)
	none_consumes := decl_behavior_consumes("unwired", routes)
	testing.expect_value(t, len(none_consumes), 0)
	log.infof("index decl emits/consumes derivation verified over signal routes")
}

@(test)
test_index_decl_calls_graph :: proc(t: ^testing.T) {
	source := `fn inc(x: Int) -> Int {
  return x + 1
}
fn dbl(x: Int) -> Int {
  return x + x
}
fn driver(a: Int) -> Int {
  let lo = inc(a)
  let hi = inc(lo)
  let m = dbl(hi)
  return inc(m)
}
`
	typed, flat, ok := compile_snippet(source)
	testing.expect(t, ok)
	if !ok {
		return
	}
	records := derive_decl_records("", typed, flat)

	driver, has_driver := find_record(records, "driver")
	testing.expect(t, has_driver)
	testing.expect_value(t, len(driver.calls), 2)
	if len(driver.calls) == 2 {
		testing.expect_value(t, driver.calls[0], "inc")
		testing.expect_value(t, driver.calls[1], "dbl")
	}

	inc, has_inc := find_record(records, "inc")
	testing.expect(t, has_inc)
	testing.expect_value(t, len(inc.calls), 0)
	log.infof("index decl calls-graph walk verified (first-seen dedupe order)")
}

@(test)
test_index_decl_dup_class :: proc(t: ^testing.T) {
	source := `fn one() -> Int {
  let m = 1 + 1
  return m + 1
}
fn two() -> Int {
  let n = 1 + 1
  return n + 1
}
fn three() -> Int {
  let p = 1 + 1
  return p * 2
}
data Empty { x: Int }
`
	typed, flat, ok := compile_snippet(source)
	testing.expect(t, ok)
	if !ok {
		return
	}
	records := derive_decl_records("", typed, flat)

	one, has_one := find_record(records, "one")
	two, has_two := find_record(records, "two")
	three, has_three := find_record(records, "three")
	testing.expect(t, has_one && has_two && has_three)

	testing.expect_value(t, one.dup_class, two.dup_class)
	testing.expect(t, one.dup_class != three.dup_class)
	testing.expect(t, one.dup_class != 0)

	empty, has_empty := find_record(records, "Empty")
	testing.expect(t, has_empty)
	testing.expect_value(t, empty.dup_class, u64(0))
	log.infof("index decl dup_class derivation verified (body-bearing collision vs body-less zero)")
}

@(test)
test_index_decl_mut_data :: proc(t: ^testing.T) {
	source := `enum Side { Left, Right }
thing Ball { pos: Int }
signal Goal { side: Side }
behavior nudge on Ball {
  fn step(self: Ball, time: Time) -> Ball {
    return self with { pos: self.pos + 1 }
  }
}
behavior emit_goal on Ball {
  fn step(self: Ball) -> [Goal] {
    return [Goal{side: Side::Left}]
  }
}
behavior consume_goal on Ball {
  fn step(self: Ball, goals: [Goal]) -> Ball {
    return self
  }
}
pipeline Loop {
  update: [nudge, emit_goal, consume_goal]
}
`
	typed, flat, ok := compile_snippet(source)
	testing.expect(t, ok)
	if !ok {
		return
	}
	records := derive_decl_records("", typed, flat)

	nudge, has_nudge := find_record(records, "nudge")
	testing.expect(t, has_nudge)
	testing.expect_value(t, len(nudge.mut_data), 1)
	if len(nudge.mut_data) == 1 {
		testing.expect_value(t, nudge.mut_data[0], "Ball")
	}

	emit_goal, has_emit := find_record(records, "emit_goal")
	testing.expect(t, has_emit)
	testing.expect_value(t, len(emit_goal.mut_data), 0)
	testing.expect_value(t, len(emit_goal.emits), 1)
	if len(emit_goal.emits) == 1 {
		testing.expect_value(t, emit_goal.emits[0], "Goal")
	}

	consume_goal, has_consume := find_record(records, "consume_goal")
	testing.expect(t, has_consume)
	testing.expect_value(t, len(consume_goal.mut_data), 1)
	if len(consume_goal.mut_data) == 1 {
		testing.expect_value(t, consume_goal.mut_data[0], "Ball")
	}
	testing.expect_value(t, len(consume_goal.consumes), 1)
	if len(consume_goal.consumes) == 1 {
		testing.expect_value(t, consume_goal.consumes[0], "Goal")
	}
	log.infof("index decl mut_data derivation verified over the blackboard-write contract")
}

@(test)
test_index_decl_records_pong :: proc(t: ^testing.T) {
	records, ok := pong_decl_records(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(records), 33)
	for r in records {
		testing.expect_value(t, r.schema_version, INDEX_SCHEMA_VERSION)
		testing.expect_value(t, r.file, "")
		testing.expect_value(t, r.stub, false)
		testing.expect_value(t, r.todo, false)
		testing.expect_value(t, len(r.debug), 0)
		testing.expectf(t, r.span >= 1, "decl %s has a non-positive span %d", r.qualified_name, r.span)
	}
	board, has_board := find_record(records, "Board")
	testing.expect(t, has_board)
	testing.expect_value(t, board.kind, Index_Decl_Kind.Data)
	testing.expect_value(t, board.span, 16)

	score, has_score := find_record(records, "score")
	testing.expect(t, has_score)
	testing.expect_value(t, len(score.emits), 1)
	if len(score.emits) == 1 {
		testing.expect_value(t, score.emits[0], "Goal")
	}
	testing.expect_value(t, len(score.consumes), 0)
	testing.expect_value(t, len(score.mut_data), 0)

	tally, has_tally := find_record(records, "tally")
	testing.expect(t, has_tally)
	testing.expect_value(t, len(tally.consumes), 1)
	if len(tally.consumes) == 1 {
		testing.expect_value(t, tally.consumes[0], "Goal")
	}
	testing.expect_value(t, len(tally.mut_data), 1)
	if len(tally.mut_data) == 1 {
		testing.expect_value(t, tally.mut_data[0], "Scoreboard")
	}

	ball_move, has_ball_move := find_record(records, "ball_move")
	testing.expect(t, has_ball_move)
	testing.expect_value(t, len(ball_move.mut_data), 1)
	if len(ball_move.mut_data) == 1 {
		testing.expect_value(t, ball_move.mut_data[0], "Ball")
	}
	overlaps, has_overlaps := find_record(records, "overlaps")
	testing.expect(t, has_overlaps)
	testing.expect_value(t, len(overlaps.calls), 1)
	if len(overlaps.calls) == 1 {
		testing.expect_value(t, overlaps.calls[0], "abs")
	}

	paddle_move, has_paddle_move := find_record(records, "paddle_move")
	testing.expect(t, has_paddle_move)
	testing.expect(t, contains_str(paddle_move.calls, "value"))
	testing.expect(t, contains_str(paddle_move.calls, "clamp"))
	log.infof("index decl records over live pong verified (%d decls, source order)", len(records))
}

@(test)
test_index_decl_records_snake :: proc(t: ^testing.T) {
	records, ok := snake_decl_records(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(records), 36)
	for r in records {
		testing.expect_value(t, r.schema_version, INDEX_SCHEMA_VERSION)
		testing.expect_value(t, r.file, "")
		testing.expect_value(t, r.stub, false)
		testing.expect_value(t, r.todo, false)
		testing.expect_value(t, len(r.debug), 0)
		testing.expectf(t, r.span >= 1, "decl %s has a non-positive span %d", r.qualified_name, r.span)
	}
	cell, has_cell := find_record(records, "Cell")
	testing.expect(t, has_cell)
	testing.expect_value(t, cell.kind, Index_Decl_Kind.Data)
	testing.expect_value(t, cell.span, 15)
	log.infof("index decl records over live snake verified (%d decls, source order)", len(records))
}

@(test)
test_index_decl_records_deterministic :: proc(t: ^testing.T) {
	source := `data Board { w: Int, h: Int }
signal Goal { side: Int }
behavior score on Board {
  fn step(self: Board) -> [Goal] {
    return [Goal{side: 1}]
  }
}
behavior tally on Board {
  fn step(self: Board, goals: [Goal]) -> Board {
    return self
  }
}
pipeline Loop {
  update: [score, tally]
}
`
	typed, flat, ok := compile_snippet(source)
	testing.expect(t, ok)
	if !ok {
		return
	}
	first := derive_decl_records("", typed, flat)
	second := derive_decl_records("", typed, flat)
	testing.expect_value(t, len(first), len(second))
	expect_records_identical(t, first, second)

	pong, pong_ok := pong_decl_records(t)
	if pong_ok {
		again, again_ok := pong_decl_records(t)
		testing.expect(t, again_ok)
		expect_records_identical(t, pong, again)
	}
	log.infof("index decl records derivation is deterministic (twice-identical, snippet + live pong)")
}

expect_records_identical :: proc(t: ^testing.T, a: []Decl_Record, b: []Decl_Record) {
	testing.expect_value(t, len(a), len(b))
	if len(a) != len(b) {
		return
	}
	for i in 0 ..< len(a) {
		testing.expect_value(t, a[i].qualified_name, b[i].qualified_name)
		testing.expect_value(t, a[i].kind, b[i].kind)
		testing.expect_value(t, a[i].span, b[i].span)
		testing.expect_value(t, a[i].dup_class, b[i].dup_class)
		testing.expect_value(t, len(a[i].emits), len(b[i].emits))
		testing.expect_value(t, len(a[i].consumes), len(b[i].consumes))
		testing.expect_value(t, len(a[i].calls), len(b[i].calls))
		testing.expect_value(t, len(a[i].mut_data), len(b[i].mut_data))
	}
}

pong_decl_records :: proc(t: ^testing.T) -> (records: []Decl_Record, ok: bool) {
	return checkout_decl_records(t, resolve_pong_dir(), "FUNPACK_PONG_DIR", "pong")
}

snake_decl_records :: proc(t: ^testing.T) -> (records: []Decl_Record, ok: bool) {
	return checkout_decl_records(t, resolve_snake_dir(), "FUNPACK_SNAKE_DIR", "snake")
}

checkout_decl_records :: proc(
	t: ^testing.T,
	dir: string,
	env_name: string,
	label: string,
) -> (records: []Decl_Record, ok: bool) {
	if !os.is_dir(dir) {
		log.warnf("SKIP index contract decl records %s: %s not found — set %s or ensure the in-repo fixture exists", label, dir, env_name)
		return nil, false
	}
	identity, project_err, _ := read_project(dir)
	testing.expect_value(t, project_err, Project_Error.None)
	if project_err != .None || len(identity.sources) == 0 {
		return nil, false
	}
	source_bytes, read_err := os.read_entire_file_from_path(identity.sources[0].path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return nil, false
	}
	typed, flat, compiled := compile_for_index(string(source_bytes))
	testing.expect(t, compiled)
	if !compiled {
		return nil, false
	}
	return derive_decl_records("", typed, flat), true
}

@(test)
test_index_decl_records_source_order :: proc(t: ^testing.T) {
	source := `fn helper() -> Int {
  return 1
}
data Cell { x: Int }
let SIZE: Int = 8
signal Moved {}
data Grid { c: Cell }
test "size" {
  assert SIZE == 8
}
`
	typed, flat, ok := compile_snippet(source)
	testing.expect(t, ok)
	if !ok {
		return
	}
	records := derive_decl_records("", typed, flat)
	expected := [?]string{"helper", "Cell", "SIZE", "Moved", "Grid", "size"}
	testing.expect_value(t, len(records), len(expected))
	if len(records) != len(expected) {
		return
	}
	for name, i in expected {
		testing.expect_value(t, records[i].qualified_name, name)
	}
	log.infof("index decl records derive in source order (interleaved kinds never re-grouped)")
}
