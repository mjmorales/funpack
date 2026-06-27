package funpack

import "core:strings"
import "core:testing"

expect_canonical :: proc(t: ^testing.T, source: string, expected: string, loc := #caller_location) {
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None, loc = loc)
	if err != .None {
		return
	}
	rendered := render_canonical(ast, context.temp_allocator)
	testing.expect_value(t, rendered, expected, loc = loc)
	reparsed, reparse_err := stage_parse(stage_lex(rendered))
	testing.expect_value(t, reparse_err, Parse_Error.None, loc = loc)
	if reparse_err != .None {
		return
	}
	testing.expect(t, ast_equiv(ast, reparsed), "re-parsed AST is not equivalent to the original", loc = loc)
	testing.expect_value(t, render_canonical(reparsed, context.temp_allocator), rendered, loc = loc)
}

@(test)
test_fmt_module_doc_and_import_forms :: proc(t: ^testing.T) {
	source := "@doc(\"Module doc.\")\n\nimport engine.math.{Vec2, abs}\nimport engine.grid.grid_cells\nimport assets\n"
	expected := "@doc(\"Module doc.\")\nimport engine.math.{Vec2, abs}\nimport engine.grid.grid_cells\nimport assets\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_string_escapes_reemit_canonical_spelling :: proc(t: ^testing.T) {
	source := "@doc(\"Built by interpolation (\\\"{x}\\\"), never +.\")\nlet GREETING: String = \"say \\\"hi\\\" \\{now\\}\"\n"
	expect_canonical(t, source, source)
}

@(test)
test_fmt_let_decl_directive_block_order :: proc(t: ^testing.T) {
	source := "@gtag(\"a\")\n@doc(\"Speed.\")\n@gtag(\"b\", \"c\")\n@todo(\"note\", T-0042)\n@break(x > 1)\n@trace\nlet SPEED: Fixed = 0.5\n"
	expected := "@doc(\"Speed.\")\n@gtag(\"a\", \"b\", \"c\")\n@todo(\"note\", T-0042)\n@break(x > 1)\n@trace\nlet SPEED: Fixed = 0.5\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_expose_directive_canonical_order :: proc(t: ^testing.T) {
	source := "@expose\n@gtag(\"grid\")\n@expose\n@doc(\"Axial to pixel.\")\nfn axial_to_pixel(size: Fixed) -> Fixed {\n  return size\n}\n\nfn cube_round(x: Fixed) -> Fixed {\n  return x\n}\n"
	expected := "@doc(\"Axial to pixel.\")\n@expose\n@gtag(\"grid\")\nfn axial_to_pixel(size: Fixed) -> Fixed {\n  return size\n}\n\nfn cube_round(x: Fixed) -> Fixed {\n  return x\n}\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_todo_window_forms :: proc(t: ^testing.T) {
	source := "@todo(\"a\", 30d)\nlet A: Int = 1\n@todo(\"b\", 2026-09-01)\nlet B: Int = 2\n@todo(\"c\", 5builds)\nlet C: Int = 3\n@todo(\"d\", T-0042)\nlet D: Int = 4\n"
	expected := "@todo(\"a\", 30d)\nlet A: Int = 1\n\n@todo(\"b\", 2026-09-01)\nlet B: Int = 2\n\n@todo(\"c\", 5builds)\nlet C: Int = 3\n\n@todo(\"d\", T-0042)\nlet D: Int = 4\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_data_enum_signal_single_line :: proc(t: ^testing.T) {
	source := "data Board {\n  w: Fixed\n  h: Fixed\n}\n\ndata Vel: Num { x: Fixed }\n\nenum Side {\n  Left\n  Right\n}\n\nenum Steer: Axis { Move }\n\nenum Shape { Dot, MoveTo(Vec2, Fixed), Rgb{ r: Fixed, g: Fixed } }\n\nsignal Goal { side: Side }\n\nsignal Died {}\n"
	expected := "data Board { w: Fixed, h: Fixed }\n\ndata Vel: Num { x: Fixed }\n\nenum Side { Left, Right }\n\nenum Steer: Axis { Move }\n\nenum Shape { Dot, MoveTo(Vec2, Fixed), Rgb{r: Fixed, g: Fixed} }\n\nsignal Goal { side: Side }\n\nsignal Died {}\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_enum_variant_doc_multiline :: proc(t: ^testing.T) {
	source := "@doc(\"A 2D draw command.\")\n" +
		"enum Draw { @doc(\"A filled rectangle.\") Rect{ at: Vec2, color: Color }, @doc(\"A move-to op.\") MoveTo(Vec2), Close }\n"
	expected := "@doc(\"A 2D draw command.\")\n" +
		"enum Draw {\n" +
		"  @doc(\"A filled rectangle.\")\n" +
		"  Rect{at: Vec2, color: Color},\n" +
		"  @doc(\"A move-to op.\")\n" +
		"  MoveTo(Vec2),\n" +
		"  Close\n" +
		"}\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_enum_docless_stays_single_line :: proc(t: ^testing.T) {
	source := "enum Side {\n  Left\n  Right\n}\n\nenum Flip {\n  @doc(\"Mirror on X.\")\n  X\n  None\n}\n"
	expected := "enum Side { Left, Right }\n\nenum Flip {\n  @doc(\"Mirror on X.\")\n  X,\n  None\n}\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_thing_alignment_and_defaults :: proc(t: ^testing.T) {
	source := "thing Snake { head: Cell = Cell{x: 10, y: 10}, body: [Cell] = [], dir: Dir = Dir::Right }\n\nsingleton Scoreboard {\n  left: Int = 0\n}\n"
	expected := "thing Snake {\n  head: Cell = Cell{x: 10, y: 10}\n  body: [Cell] = []\n  dir:  Dir = Dir::Right\n}\n\nsingleton Scoreboard {\n  left: Int = 0\n}\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_fn_forms :: proc(t: ^testing.T) {
	source := "fn advance(at: Vec2, vel: Vec2, dt: Fixed) -> Vec2 {\n  return at + vel * dt\n}\n\nextern fn arena_spawns() -> [Spawn]\n\nfn drag() -> Fixed @stub(Fixed)\n\nfn launch_speed(boost: Fixed) -> Fixed @stub(Fixed, boost + 6.0)\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_extern_type :: proc(t: ^testing.T) {
	source := "@doc(\"an immutable 2D outline\")\n@expose\nextern type Sketch\n\nextern type Anchors\n\nextern fn outline(s: Sketch) -> [Vec2]\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_generic_declaration_headers :: proc(t: ^testing.T) {
	source := "enum Option[T] { Some(T), None }\n\nenum Result[T,E] { Ok(T), Err(E) }\n\ndata Ref[T] { id: Id }\n\ndata Pair[K, V] { k: K, v: V }\n\n@doc(\"a view subtree\")\nextern type View[Msg]\n"
	expected := "enum Option[T] { Some(T), None }\n\nenum Result[T, E] { Ok(T), Err(E) }\n\ndata Ref[T] { id: Id }\n\ndata Pair[K, V] { k: K, v: V }\n\n@doc(\"a view subtree\")\nextern type View[Msg]\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_fn_typed_parameters :: proc(t: ^testing.T) {
	source := "extern fn find(self: [T], pred: fn(T) -> Bool) -> Option[T]\n\nextern fn fold(self: [T], init: A, step: fn(A,T)->A) -> A\n\nextern fn thunk(supplier: fn() -> Int) -> Int\n\nextern fn pick(opts: Option[fn(T) -> Bool]) -> Bool\n\nextern fn make() -> fn(Int) -> Int\n"
	expected := "extern fn find(self: [T], pred: fn(T) -> Bool) -> Option[T]\n\nextern fn fold(self: [T], init: A, step: fn(A, T) -> A) -> A\n\nextern fn thunk(supplier: fn() -> Int) -> Int\n\nextern fn pick(opts: Option[fn(T) -> Bool]) -> Bool\n\nextern fn make() -> fn(Int) -> Int\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_behavior_and_holed_step :: proc(t: ^testing.T) {
	source := "behavior paddle_move on Paddle {\n  fn step(self: Paddle, input: Input, time: Time) -> Paddle {\n    let dir = input.value(self.player, Steer::Move)\n    return self with { y: clamp(self.y + dir * self.speed * time.dt, 0.0, BOARD.h) }\n  }\n}\n\nbehavior idle on Ball {\n  fn step(self: Ball) -> Ball @stub(Ball)\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_pipeline_alignment_battery_empty :: proc(t: ^testing.T) {
	source := "pipeline Pong {\n  startup: [setup]\n  collision: [wall_bounce, paddle_bounce]\n  physics: solve\n}\n\npipeline Drift {\n}\n"
	expected := "pipeline Pong {\n  startup:   [setup]\n  collision: [wall_bounce, paddle_bounce]\n  physics:   solve\n}\n\npipeline Drift {\n}\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_test_block :: proc(t: ^testing.T) {
	source := "@doc(\"Sums.\")\ntest \"adds small ints\" {\n  let s = add(1, 2)\n  assert s == 3\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_if_statement_single_and_multi_line :: proc(t: ^testing.T) {
	source := "fn body_after(snake: Snake) -> [Cell] {\n  let extended = prepend(snake.head, snake.body)\n  if snake.grow { return extended }\n  return init(extended)\n}\n\nfn guard(x: Fixed) -> Fixed {\n  if x > 1.0 {\n    let y = x * 2.0\n    return y\n  }\n  return x\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_precedence_parens_restored :: proc(t: ^testing.T) {
	source := "test \"parens\" {\n  assert (1 + 2) * 3 == 9\n  assert a - (b - c) == d\n  assert not (p and q)\n  assert -(x + y) < z\n  assert p and (q or r)\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_match_patterns_multiline :: proc(t: ^testing.T) {
	source := "fn classify(d: Shape2, p: (Option[Cell], Rng)) -> Int {\n  let a = match d {\n    Shape2::Box{size} => size\n    Shape2::Dot => 0\n    _ => 1\n  }\n  return match p {\n    (Option::Some(cell), next) => 1\n    (Option::None, _) => 0\n  }\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_if_expr_else_if_chain :: proc(t: ^testing.T) {
	source := "fn pick(a: Bool, b: Bool) -> Int {\n  let x = if a { 1 } else if b { 2 } else { 3 }\n  return x\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_lambda_chain_and_records :: proc(t: ^testing.T) {
	source := "fn bindings() -> Bindings {\n  return Bindings.empty()\n    .axis(P, S, keys_axis(K, J))\n    .axis(Q, S, stick_y(L))\n}\n\nfn nearest(self: Ball, paddles: View[Paddle]) -> Ball {\n  return first(paddles, fn(pad) { return overlaps(self.pos, Vec2{x: pad.x, y: pad.y}) })\n}\n"
	expected := "fn bindings() -> Bindings {\n  return Bindings.empty().axis(P, S, keys_axis(K, J)).axis(Q, S, stick_y(L))\n}\n\nfn nearest(self: Ball, paddles: View[Paddle]) -> Ball {\n  return first(paddles, fn(pad) { return overlaps(self.pos, Vec2{x: pad.x, y: pad.y}) })\n}\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_guarded_scrutinee_and_condition_parenthesized :: proc(t: ^testing.T) {
	source := "fn f(v: Vec2) -> Int {\n  if (v == Vec2{x: 1.0, y: 0.0}) { return 1 }\n  return match (v == Vec2{x: 0.0, y: 0.0}) {\n    _ => 0\n  }\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_bare_scrutinee_stays_bare :: proc(t: ^testing.T) {
	source := "fn g(side: Side) -> Int {\n  return match side {\n    Side::Left => 0\n    Side::Right => 1\n  }\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_fixed_literal_shortest_round_trip :: proc(t: ^testing.T) {
	source := "let A: Fixed = 0.5\nlet B: Fixed = 160.0\nlet C: Fixed = 0.1\nlet D: Fixed = 3.14159265\nlet E: Fixed = 0.50\nlet F: Fixed = 2.250\n"
	expected := "let A: Fixed = 0.5\n\nlet B: Fixed = 160.0\n\nlet C: Fixed = 0.1\n\nlet D: Fixed = 3.14159265\n\nlet E: Fixed = 0.5\n\nlet F: Fixed = 2.25\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_string_interpolation_verbatim :: proc(t: ^testing.T) {
	source := "test \"text\" {\n  assert msg == \"score {m.score} of {m.total}\"\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_tuple_expr_and_types :: proc(t: ^testing.T) {
	source := "fn split(rng: Rng) -> (Rng, [Spawn]) {\n  return (rng, [])\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_stub_expression_position :: proc(t: ^testing.T) {
	source := "fn approx() -> Vec2 {\n  return Vec2{x: @stub(Fixed, 0.5), y: @stub(Fixed)}\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_separators_normalize :: proc(t: ^testing.T) {
	source := "fn setup() -> [Spawn] {\n  return [\n    Spawn( Paddle{side: Side::Left} )\n    Spawn( Ball{pos: Vec2{x: 80.0, y: 60.0}} )\n  ]\n}\n"
	expected := "fn setup() -> [Spawn] {\n  return [Spawn(Paddle{side: Side::Left}), Spawn(Ball{pos: Vec2{x: 80.0, y: 60.0}})]\n}\n"
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_source_ordered_declarations :: proc(t: ^testing.T) {
	source := "fn helper() -> Int {\n  return 1\n}\n\ndata Cell { x: Int }\n\nlet SIZE: Int = 8\n\ndata Grid { size: Cell }\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_feature_interleaving_preserved :: proc(t: ^testing.T) {
	source := "thing Ball {\n  x: Fixed\n}\n\nbehavior roll on Ball {\n  fn step(self: Ball) -> Ball {\n    return self\n  }\n}\n\nsignal Bounced {}\n\nthing Paddle {\n  y: Fixed\n}\n\nbehavior track on Paddle {\n  fn step(self: Paddle) -> Paddle {\n    return self\n  }\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_query_declaration :: proc(t: ^testing.T) {
	source := "@doc(\"Enemies within radius.\")\n@spatial(Enemy.cell)\n@index(Enemy.squad)\nquery enemies_near(origin: Cell, r: Fixed) -> [Enemy] {\n  return nearest_first(within(all[Enemy], origin, r), origin)\n}\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_migrate_field_forms :: proc(t: ^testing.T) {
	source := "data Player { @migrate(from: \"old_pos\") pos: Vec2, @migrate(with: meters_to_units) reach: Fixed, @migrate(from: \"speed\", with: to_velocity) velocity: Fixed, hp: Int }\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_migrate_decl_rename :: proc(t: ^testing.T) {
	source := "@doc(\"Renamed from Old.\")\n@migrate(from: \"OldPlayer\")\ndata Player { hp: Int }\n"
	expected := source
	expect_canonical(t, source, expected)
}

@(test)
test_fmt_migrate_multiline_normalizes_inline :: proc(t: ^testing.T) {
	source := "data Player {\n  @migrate(from: \"old_pos\")\n  pos: Vec2,\n  hp: Int\n}\n"
	expected := "data Player { @migrate(from: \"old_pos\") pos: Vec2, hp: Int }\n"
	expect_canonical(t, source, expected)
}

ast_equiv :: proc(a, b: Ast) -> bool {
	if a.module_doc != b.module_doc {
		return false
	}
	if len(a.imports) != len(b.imports) ||
	   len(a.decls) != len(b.decls) ||
	   len(a.lets) != len(b.lets) ||
	   len(a.datas) != len(b.datas) ||
	   len(a.enums) != len(b.enums) ||
	   len(a.things) != len(b.things) ||
	   len(a.signals) != len(b.signals) ||
	   len(a.fns) != len(b.fns) ||
	   len(a.queries) != len(b.queries) ||
	   len(a.behaviors) != len(b.behaviors) ||
	   len(a.pipelines) != len(b.pipelines) ||
	   len(a.tests) != len(b.tests) ||
	   len(a.extern_types) != len(b.extern_types) {
		return false
	}
	for ref, i in a.decls {
		if ref != b.decls[i] {
			return false
		}
	}
	for imp, i in a.imports {
		other := b.imports[i]
		if !string_slice_equal(imp.segments, other.segments) {
			return false
		}
		if (imp.members == nil) != (other.members == nil) || !string_slice_equal(imp.members, other.members) {
			return false
		}
	}
	for decl, i in a.lets {
		other := b.lets[i]
		if decl.name != other.name || !type_ref_equiv(decl.type, other.type) || !expr_equiv(decl.value, other.value) {
			return false
		}
		if !directives_equiv(decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes, other.doc, other.exposed, other.gtags, other.todos, other.probes) {
			return false
		}
	}
	for decl, i in a.datas {
		other := b.datas[i]
		if decl.name != other.name || decl.kind != other.kind || !field_decls_equiv(decl.fields, other.fields) {
			return false
		}
		if !string_slice_equal(decl.type_params, other.type_params) {
			return false
		}
		if !migrate_equiv(decl.migrate, decl.has_migrate, other.migrate, other.has_migrate) {
			return false
		}
		if !directives_equiv(decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes, other.doc, other.exposed, other.gtags, other.todos, other.probes) {
			return false
		}
	}
	for decl, i in a.enums {
		other := b.enums[i]
		if decl.name != other.name || decl.kind != other.kind || len(decl.variants) != len(other.variants) {
			return false
		}
		if !string_slice_equal(decl.type_params, other.type_params) {
			return false
		}
		for variant, j in decl.variants {
			if !variant_decl_equiv(variant, other.variants[j]) {
				return false
			}
		}
		if !directives_equiv(decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes, other.doc, other.exposed, other.gtags, other.todos, other.probes) {
			return false
		}
	}
	for decl, i in a.things {
		other := b.things[i]
		if decl.name != other.name || decl.is_singleton != other.is_singleton || !field_decls_equiv(decl.fields, other.fields) {
			return false
		}
		if !directives_equiv(decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes, other.doc, other.exposed, other.gtags, other.todos, other.probes) {
			return false
		}
	}
	for decl, i in a.signals {
		other := b.signals[i]
		if decl.name != other.name || !field_decls_equiv(decl.fields, other.fields) {
			return false
		}
		if !directives_equiv(decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes, other.doc, other.exposed, other.gtags, other.todos, other.probes) {
			return false
		}
	}
	for decl, i in a.fns {
		other := b.fns[i]
		if !fn_node_equiv(decl, other) {
			return false
		}
		if !directives_equiv(decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes, other.doc, other.exposed, other.gtags, other.todos, other.probes) {
			return false
		}
	}
	for decl, i in a.queries {
		other := b.queries[i]
		if decl.name != other.name || !type_ref_equiv(decl.return_type, other.return_type) || !statements_equiv(decl.body, other.body) {
			return false
		}
		if len(decl.params) != len(other.params) {
			return false
		}
		for param, j in decl.params {
			if param.name != other.params[j].name || !type_ref_equiv(param.type, other.params[j].type) {
				return false
			}
		}
		if len(decl.indexes) != len(other.indexes) {
			return false
		}
		for index, j in decl.indexes {
			if index.kind != other.indexes[j].kind || index.thing != other.indexes[j].thing || index.field != other.indexes[j].field {
				return false
			}
		}
		if !directives_equiv(decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes, other.doc, other.exposed, other.gtags, other.todos, other.probes) {
			return false
		}
	}
	for decl, i in a.behaviors {
		other := b.behaviors[i]
		if decl.name != other.name || decl.target != other.target || !fn_node_equiv(decl.step, other.step) {
			return false
		}
		if !directives_equiv(decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes, other.doc, other.exposed, other.gtags, other.todos, other.probes) {
			return false
		}
	}
	for decl, i in a.pipelines {
		other := b.pipelines[i]
		if decl.name != other.name || len(decl.stages) != len(other.stages) {
			return false
		}
		for stage, j in decl.stages {
			other_stage := other.stages[j]
			if stage.name != other_stage.name ||
			   stage.is_battery != other_stage.is_battery ||
			   stage.battery != other_stage.battery ||
			   !string_slice_equal(stage.behaviors, other_stage.behaviors) {
				return false
			}
		}
		if !directives_equiv(decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes, other.doc, other.exposed, other.gtags, other.todos, other.probes) {
			return false
		}
	}
	for decl, i in a.tests {
		other := b.tests[i]
		if decl.name != other.name || decl.doc != other.doc || !statements_equiv(decl.body, other.body) {
			return false
		}
	}
	for decl, i in a.extern_types {
		other := b.extern_types[i]
		if decl.name != other.name || !string_slice_equal(decl.type_params, other.type_params) {
			return false
		}
		if !directives_equiv(decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes, other.doc, other.exposed, other.gtags, other.todos, other.probes) {
			return false
		}
	}
	return true
}

string_slice_equal :: proc(a, b: []string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for s, i in a {
		if s != b[i] {
			return false
		}
	}
	return true
}

directives_equiv :: proc(a_doc: string, a_exposed: bool, a_gtags: []string, a_todos: []Todo_Node, a_probes: []Debug_Probe, b_doc: string, b_exposed: bool, b_gtags: []string, b_todos: []Todo_Node, b_probes: []Debug_Probe) -> bool {
	if a_doc != b_doc || a_exposed != b_exposed || !string_slice_equal(a_gtags, b_gtags) {
		return false
	}
	if len(a_todos) != len(b_todos) || len(a_probes) != len(b_probes) {
		return false
	}
	for todo, i in a_todos {
		if todo.message != b_todos[i].message || todo.window != b_todos[i].window {
			return false
		}
	}
	for probe, i in a_probes {
		if probe.kind != b_probes[i].kind || !expr_equiv(probe.arg, b_probes[i].arg) {
			return false
		}
	}
	return true
}

type_ref_equiv :: proc(a, b: Type_Ref) -> bool {
	if a.name != b.name || len(a.args) != len(b.args) {
		return false
	}
	for arg, i in a.args {
		if !type_ref_equiv(arg, b.args[i]) {
			return false
		}
	}
	return true
}

field_decls_equiv :: proc(a, b: []Field_Decl) -> bool {
	if len(a) != len(b) {
		return false
	}
	for field, i in a {
		other := b[i]
		if field.name != other.name || !type_ref_equiv(field.type, other.type) || field.has_default != other.has_default {
			return false
		}
		if field.has_default && !expr_equiv(field.default, other.default) {
			return false
		}
		if !migrate_equiv(field.migrate, field.has_migrate, other.migrate, other.has_migrate) {
			return false
		}
	}
	return true
}

migrate_equiv :: proc(a: Migrate_Node, a_has: bool, b: Migrate_Node, b_has: bool) -> bool {
	if a_has != b_has {
		return false
	}
	if !a_has {
		return true
	}
	return a.has_from == b.has_from && a.from == b.from && a.has_with == b.has_with && a.with == b.with
}

variant_decl_equiv :: proc(a, b: Variant_Decl) -> bool {
	if a.name != b.name || a.payload != b.payload || a.doc != b.doc {
		return false
	}
	if len(a.tuple) != len(b.tuple) {
		return false
	}
	for type, i in a.tuple {
		if !type_ref_equiv(type, b.tuple[i]) {
			return false
		}
	}
	return field_decls_equiv(a.fields, b.fields)
}

fn_node_equiv :: proc(a, b: Fn_Node) -> bool {
	if a.name != b.name || a.is_extern != b.is_extern || a.holed != b.holed || a.has_fallback != b.has_fallback {
		return false
	}
	if len(a.params) != len(b.params) {
		return false
	}
	for param, i in a.params {
		if param.name != b.params[i].name || !type_ref_equiv(param.type, b.params[i].type) {
			return false
		}
	}
	if !type_ref_equiv(a.return_type, b.return_type) {
		return false
	}
	if a.holed {
		if !type_ref_equiv(a.hole_type, b.hole_type) {
			return false
		}
		if a.has_fallback && !expr_equiv(a.fallback, b.fallback) {
			return false
		}
	}
	return statements_equiv(a.body, b.body)
}

statements_equiv :: proc(a, b: []Statement) -> bool {
	if len(a) != len(b) {
		return false
	}
	for stmt, i in a {
		if !statement_equiv(stmt, b[i]) {
			return false
		}
	}
	return true
}

statement_equiv :: proc(a, b: Statement) -> bool {
	switch node in a {
	case Assert_Node:
		other, ok := b.(Assert_Node)
		return ok && expr_equiv(node.expr, other.expr)
	case Let_Node:
		other, ok := b.(Let_Node)
		return ok && node.name == other.name && expr_equiv(node.value, other.value)
	case Return_Node:
		other, ok := b.(Return_Node)
		return ok && expr_equiv(node.value, other.value)
	case If_Node:
		other, ok := b.(If_Node)
		return ok && expr_equiv(node.cond, other.cond) && statements_equiv(node.body, other.body)
	}
	return a == nil && b == nil
}

pattern_equiv :: proc(a, b: Pattern) -> bool {
	if a.kind != b.kind || a.type_name != b.type_name || a.variant != b.variant {
		return false
	}
	if !string_slice_equal(a.binders, b.binders) || len(a.elements) != len(b.elements) {
		return false
	}
	for element, i in a.elements {
		if !pattern_equiv(element, b.elements[i]) {
			return false
		}
	}
	return true
}

expr_slice_equiv :: proc(a, b: []Expr) -> bool {
	if len(a) != len(b) {
		return false
	}
	for expr, i in a {
		if !expr_equiv(expr, b[i]) {
			return false
		}
	}
	return true
}

record_fields_equiv :: proc(a, b: []Record_Field) -> bool {
	if len(a) != len(b) {
		return false
	}
	for field, i in a {
		if field.name != b[i].name || !expr_equiv(field.value, b[i].value) {
			return false
		}
	}
	return true
}

expr_equiv :: proc(a, b: Expr) -> bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	switch node in a {
	case ^Int_Lit_Expr:
		other, ok := b.(^Int_Lit_Expr)
		return ok && node.value == other.value
	case ^Fixed_Lit_Expr:
		other, ok := b.(^Fixed_Lit_Expr)
		return ok && node.bits == other.bits
	case ^String_Lit_Expr:
		other, ok := b.(^String_Lit_Expr)
		return ok && node.text == other.text
	case ^Name_Expr:
		other, ok := b.(^Name_Expr)
		return ok && node.name == other.name && node.class == other.class
	case ^Call_Expr:
		other, ok := b.(^Call_Expr)
		return ok && expr_equiv(node.callee, other.callee) && expr_slice_equiv(node.args, other.args)
	case ^Member_Expr:
		other, ok := b.(^Member_Expr)
		return ok && node.member == other.member && node.class == other.class && expr_equiv(node.receiver, other.receiver)
	case ^Variant_Expr:
		other, ok := b.(^Variant_Expr)
		return ok &&
			node.type_name == other.type_name &&
			node.variant == other.variant &&
			node.has_payload == other.has_payload &&
			node.has_fields == other.has_fields &&
			expr_slice_equiv(node.payload, other.payload) &&
			record_fields_equiv(node.fields, other.fields)
	case ^Record_Expr:
		other, ok := b.(^Record_Expr)
		return ok && node.type_name == other.type_name && record_fields_equiv(node.fields, other.fields)
	case ^List_Expr:
		other, ok := b.(^List_Expr)
		return ok && expr_slice_equiv(node.elements, other.elements)
	case ^Tuple_Expr:
		other, ok := b.(^Tuple_Expr)
		return ok && expr_slice_equiv(node.elements, other.elements)
	case ^Lambda_Expr:
		other, ok := b.(^Lambda_Expr)
		return ok && string_slice_equal(node.params, other.params) && expr_equiv(node.body, other.body)
	case ^Unary_Expr:
		other, ok := b.(^Unary_Expr)
		return ok && node.op.kind == other.op.kind && node.op.text == other.op.text && expr_equiv(node.operand, other.operand)
	case ^Binary_Expr:
		other, ok := b.(^Binary_Expr)
		return ok &&
			node.op.kind == other.op.kind &&
			node.op.text == other.op.text &&
			expr_equiv(node.lhs, other.lhs) &&
			expr_equiv(node.rhs, other.rhs)
	case ^With_Expr:
		other, ok := b.(^With_Expr)
		return ok && expr_equiv(node.base, other.base) && record_fields_equiv(node.fields, other.fields)
	case ^Match_Expr:
		other, ok := b.(^Match_Expr)
		if !ok || !expr_equiv(node.scrutinee, other.scrutinee) || len(node.arms) != len(other.arms) {
			return false
		}
		for arm, i in node.arms {
			if !pattern_equiv(arm.pattern, other.arms[i].pattern) || !expr_equiv(arm.body, other.arms[i].body) {
				return false
			}
		}
		return true
	case ^If_Expr:
		other, ok := b.(^If_Expr)
		return ok &&
			expr_equiv(node.cond, other.cond) &&
			expr_equiv(node.then_branch, other.then_branch) &&
			expr_equiv(node.else_branch, other.else_branch)
	case ^Stub_Expr:
		other, ok := b.(^Stub_Expr)
		return ok &&
			type_ref_equiv(node.hole_type, other.hole_type) &&
			node.has_fallback == other.has_fallback &&
			(!node.has_fallback || expr_equiv(node.fallback, other.fallback))
	case ^All_Expr:
		other, ok := b.(^All_Expr)
		return ok && node.thing == other.thing
	}
	return false
}

@(test)
test_fmt_render_is_byte_deterministic :: proc(t: ^testing.T) {
	source := "data Cell { x: Int, y: Int }\n\nfn id(c: Cell) -> Cell {\n  return c\n}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	if err != .None {
		return
	}
	first := render_canonical(ast, context.temp_allocator)
	second := render_canonical(ast, context.temp_allocator)
	testing.expect_value(t, second, first)
	testing.expect(t, strings.has_suffix(first, "\n"))
}
