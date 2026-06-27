package funpack_runtime

import "core:path/filepath"
import "core:strings"
import "core:testing"

GOLDEN_ARTIFACT := #load("testdata/pong.artifact", string)

load_golden :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(GOLDEN_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "golden artifact must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

@(test)
test_load_version_gate :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, program.schema_version, ARTIFACT_SCHEMA_VERSION)

	old_version := "funpack-artifact 11\n[meta 0]\n"
	_, old_err := load_program(old_version, context.temp_allocator)
	testing.expect_value(t, old_err, Artifact_Error.Version_Mismatch)

	future_version := "funpack-artifact 20\n[meta 0]\n"
	_, future_err := load_program(future_version, context.temp_allocator)
	testing.expect_value(t, future_err, Artifact_Error.Version_Mismatch)

	bad_stamp := "notfunpack 2\n"
	_, stamp_err := load_program(bad_stamp, context.temp_allocator)
	testing.expect_value(t, stamp_err, Artifact_Error.Bad_Stamp)

	_, empty_err := load_program("", context.temp_allocator)
	testing.expect_value(t, empty_err, Artifact_Error.Empty_Input)
}

@(test)
test_load_meta :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, program.meta.name, "pong")
	testing.expect_value(t, program.meta.version, "0.1.0")
}

@(test)
test_load_enums :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.enums), 2)

	side := program.enums[0]
	testing.expect_value(t, side.name, "Side")
	testing.expect_value(t, side.kind, Enum_Kind.None)
	testing.expect_value(t, len(side.variants), 2)
	testing.expect_value(t, side.variants[0].name, "Left")
	testing.expect_value(t, side.variants[1].name, "Right")

	steer := program.enums[1]
	testing.expect_value(t, steer.name, "Steer")
	testing.expect_value(t, steer.kind, Enum_Kind.Axis)
	testing.expect_value(t, len(steer.variants), 1)
	testing.expect_value(t, steer.variants[0].name, "Move")
}

@(test)
test_load_data_and_signals :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.data), 1)
	board := program.data[0]
	testing.expect_value(t, board.name, "Board")
	testing.expect_value(t, board.mutable, false)
	testing.expect_value(t, len(board.fields), 2)
	testing.expect_value(t, board.fields[0].name, "w")
	testing.expect_value(t, board.fields[0].type, "Fixed")
	testing.expect_value(t, board.fields[0].has_default, false)

	testing.expect_value(t, len(program.signals), 1)
	goal := program.signals[0]
	testing.expect_value(t, goal.name, "Goal")
	testing.expect_value(t, len(goal.fields), 1)
	testing.expect_value(t, goal.fields[0].name, "side")
	testing.expect_value(t, goal.fields[0].type, "Side")
}

@(test)
test_load_things :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.things), 3)

	paddle := program.things[0]
	testing.expect_value(t, paddle.name, "Paddle")
	testing.expect_value(t, paddle.singleton, false)
	testing.expect_value(t, len(paddle.gtags), 1)
	testing.expect_value(t, paddle.gtags[0], "paddle")
	testing.expect_value(t, len(paddle.fields), 5)
	testing.expect_value(t, paddle.fields[0].name, "player")
	testing.expect_value(t, paddle.fields[2].name, "x")
	testing.expect_value(t, paddle.fields[2].type, "Fixed")

	ball := program.things[1]
	testing.expect_value(t, ball.name, "Ball")
	testing.expect_value(t, len(ball.fields), 2)
	testing.expect_value(t, ball.fields[0].name, "pos")
	testing.expect_value(t, ball.fields[0].type, "Vec2")

	score := program.things[2]
	testing.expect_value(t, score.name, "Scoreboard")
	testing.expect_value(t, score.singleton, false)
	testing.expect_value(t, score.fields[0].name, "left")
	testing.expect_value(t, score.fields[0].type, "Int")
	testing.expect_value(t, score.fields[0].has_default, true)
	testing.expect_value(t, score.fields[0].default_encoded, "0")
}

@(test)
test_load_functions :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.functions), 10)

	advance := find_function(program, "advance")
	testing.expect(t, advance != nil)
	testing.expect_value(t, advance.kind, Function_Kind.Fn)
	testing.expect_value(t, len(advance.params), 3)
	testing.expect_value(t, advance.params[0].name, "at")
	testing.expect_value(t, advance.params[2].type, "Fixed")
	testing.expect_value(t, advance.return_type, "Vec2")
	testing.expect_value(t, advance.span_module, "pong")
	testing.expect_value(t, advance.span_line, 50)
	testing.expect(t, len(advance.body) == 1)

	board := find_function(program, "BOARD")
	testing.expect(t, board != nil)
	testing.expect_value(t, board.kind, Function_Kind.Const)
	testing.expect_value(t, len(board.params), 0)

	bindings := find_function(program, "bindings")
	testing.expect(t, bindings != nil)
	testing.expect_value(t, bindings.kind, Function_Kind.Bindings)

	setup := find_function(program, "setup")
	testing.expect(t, setup != nil)
	testing.expect_value(t, setup.kind, Function_Kind.Startup)
	testing.expect_value(t, setup.return_type, "[Spawn]")
}

@(test)
test_load_pipeline_total_order :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.pipeline), 11)

	for step, i in program.pipeline {
		testing.expect_value(t, step.ordinal, i)
	}

	expected := [?]struct {
		stage:    string,
		behavior: string,
	} {
		{"startup", "setup"},
		{"control", "paddle_move"},
		{"control", "ball_move"},
		{"collision", "wall_bounce"},
		{"collision", "paddle_bounce"},
		{"scoring", "score"},
		{"scoring", "tally"},
		{"scoring", "serve"},
		{"render", "draw_paddle"},
		{"render", "draw_ball"},
		{"render", "draw_score"},
	}
	for want, i in expected {
		testing.expect_value(t, program.pipeline[i].stage, want.stage)
		testing.expect_value(t, program.pipeline[i].behavior, want.behavior)
	}
}

@(test)
test_behavior_per_stage_bindings :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.behaviors), 10)

	for step in program.pipeline {
		if step.stage == "startup" {
			continue
		}
		behavior := find_behavior(program, step.behavior)
		if !testing.expectf(t, behavior != nil, "pipeline behavior %s must have a record", step.behavior) {
			continue
		}
		testing.expectf(
			t,
			behavior.stage == step.stage,
			"behavior %s stage %s != pipeline slot %s",
			step.behavior,
			behavior.stage,
			step.stage,
		)
	}

	paddle_move := find_behavior(program, "paddle_move")
	testing.expect(t, paddle_move != nil)
	testing.expect_value(t, paddle_move.on_thing, "Paddle")
	testing.expect_value(t, paddle_move.stage, "control")
	testing.expect_value(t, paddle_move.contract, "Update")
	testing.expect_value(t, len(paddle_move.params), 3)
	testing.expect_value(t, paddle_move.params[0].name, "self")
	testing.expect_value(t, paddle_move.params[1].type, "Input")
	testing.expect_value(t, len(paddle_move.emits), 1)
	testing.expect_value(t, paddle_move.emits[0], "Paddle")

	draw_ball := find_behavior(program, "draw_ball")
	testing.expect(t, draw_ball != nil)
	testing.expect_value(t, draw_ball.on_thing, "Ball")
	testing.expect_value(t, draw_ball.stage, "render")
	testing.expect_value(t, draw_ball.contract, "Render")
	testing.expect_value(t, draw_ball.emits[0], "[Draw]")

	paddle_bounce := find_behavior(program, "paddle_bounce")
	testing.expect(t, paddle_bounce != nil)
	testing.expect_value(t, len(paddle_bounce.gtags), 2)
	testing.expect_value(t, paddle_bounce.params[1].type, "View[Paddle]")
}

@(test)
test_load_signal_routing :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.routing), 1)
	route := program.routing[0]
	testing.expect_value(t, route.signal, "Goal")
	testing.expect_value(t, len(route.producers), 1)
	testing.expect_value(t, len(route.consumers), 2)
	testing.expect_value(t, route.producers[0].behavior, "score")
	testing.expect_value(t, route.producers[0].ordinal, 5)
	testing.expect_value(t, route.consumers[0].behavior, "tally")
	testing.expect_value(t, route.consumers[1].behavior, "serve")

	producer_ordinal := route.producers[0].ordinal
	for consumer in route.consumers {
		testing.expectf(
			t,
			consumer.ordinal > producer_ordinal,
			"consumer %s at %d must be downstream of producer at %d",
			consumer.behavior,
			consumer.ordinal,
			producer_ordinal,
		)
	}
}

@(test)
test_load_setup_batch :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.setup), 4)
	testing.expect_value(t, program.setup[0].thing, "Paddle")
	testing.expect_value(t, program.setup[1].thing, "Paddle")
	testing.expect_value(t, program.setup[2].thing, "Ball")
	testing.expect_value(t, program.setup[3].thing, "Scoreboard")
}

@(test)
test_setup_fixed_literals_are_kernel_bit_exact :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}

	p1 := program.setup[0]
	x := spawn_field(p1, "x")
	y := spawn_field(p1, "y")
	speed := spawn_field(p1, "speed")
	testing.expect(t, x != nil && y != nil && speed != nil)
	testing.expect_value(t, x.kind, Spawn_Value_Kind.Fixed)
	testing.expect_value(t, x.fixed, to_fixed(8))
	testing.expect_value(t, y.fixed, to_fixed(60))
	testing.expect_value(t, speed.fixed, to_fixed(90))

	side := spawn_field(p1, "side")
	testing.expect(t, side != nil)
	testing.expect_value(t, side.kind, Spawn_Value_Kind.Variant)
	testing.expect_value(t, side.variant, "Side::Left")

	p2 := program.setup[1]
	p2x := spawn_field(p2, "x")
	testing.expect(t, p2x != nil)
	testing.expect_value(t, p2x.fixed, to_fixed(152))

	ball := program.setup[2]
	pos := spawn_field(ball, "pos")
	vel := spawn_field(ball, "vel")
	testing.expect(t, pos != nil && vel != nil)
	testing.expect_value(t, pos.kind, Spawn_Value_Kind.Vec2)
	testing.expect_value(t, pos.vec2_x, to_fixed(80))
	testing.expect_value(t, pos.vec2_y, to_fixed(60))
	testing.expect_value(t, vel.vec2_x, to_fixed(70))
	testing.expect_value(t, vel.vec2_y, to_fixed(40))

	score := program.setup[3]
	left := spawn_field(score, "left")
	testing.expect(t, left != nil)
	testing.expect_value(t, left.int_val, i64(0))
}

@(test)
test_load_bindings :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.bindings), 4)
	testing.expect_value(t, program.bindings[0].kind, "axis")
	testing.expect_value(t, program.bindings[0].player, "P1")
	testing.expect_value(t, program.bindings[0].action, "Steer::Move")
	testing.expect_value(t, program.bindings[0].source, "keys_axis(Key::W,Key::S)")
	testing.expect_value(t, program.bindings[1].source, "stick_y(Stick::Left)")
	testing.expect_value(t, program.bindings[2].player, "P2")
	testing.expect_value(t, program.bindings[2].source, "keys_axis(Key::Up,Key::Down)")
}

@(test)
test_load_entrypoint :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, program.entrypoint.name, "main")
	testing.expect_value(t, program.entrypoint.pipeline, "Pong")
	testing.expect_value(t, program.entrypoint.tick_hz, 60)
	testing.expect_value(t, program.entrypoint.logical_w, 160)
	testing.expect_value(t, program.entrypoint.logical_h, 120)
	testing.expect_value(t, program.entrypoint.bindings, "bindings")
	testing.expect(t, !program.entrypoint.has_seed)
}

@(test)
test_load_entrypoint_config_seed :: proc(t: ^testing.T) {
	seeded_section := Artifact_Section {
		name = "entrypoint",
		count = 1,
		records = []Artifact_Record {
			{lead = "entrypoint main pipeline:Pong tick_hz:60 logical:160x120 bindings:bindings seed:1234"},
		},
	}
	seeded, seeded_err := load_entrypoint(seeded_section)
	testing.expect_value(t, seeded_err, Artifact_Error.None)
	testing.expect(t, seeded.has_seed)
	testing.expect_value(t, seeded.seed, i64(1234))
	neg_section := Artifact_Section {
		name = "entrypoint",
		count = 1,
		records = []Artifact_Record {
			{lead = "entrypoint main pipeline:Pong tick_hz:60 logical:160x120 bindings:bindings seed:-7"},
		},
	}
	neg, neg_err := load_entrypoint(neg_section)
	testing.expect_value(t, neg_err, Artifact_Error.None)
	testing.expect(t, neg.has_seed)
	testing.expect_value(t, neg.seed, i64(-7))

	bare_section := Artifact_Section {
		name = "entrypoint",
		count = 1,
		records = []Artifact_Record {
			{lead = "entrypoint main pipeline:Pong tick_hz:60 logical:160x120 bindings:bindings"},
		},
	}
	bare, bare_err := load_entrypoint(bare_section)
	testing.expect_value(t, bare_err, Artifact_Error.None)
	testing.expect(t, !bare.has_seed)

	wrong_prefix := Artifact_Section {
		name = "entrypoint",
		count = 1,
		records = []Artifact_Record {
			{lead = "entrypoint main pipeline:Pong tick_hz:60 logical:160x120 bindings:bindings warp:1"},
		},
	}
	_, wrong_err := load_entrypoint(wrong_prefix)
	testing.expect_value(t, wrong_err, Artifact_Error.Bad_Field)

	non_int := Artifact_Section {
		name = "entrypoint",
		count = 1,
		records = []Artifact_Record {
			{lead = "entrypoint main pipeline:Pong tick_hz:60 logical:160x120 bindings:bindings seed:xyz"},
		},
	}
	_, non_int_err := load_entrypoint(non_int)
	testing.expect_value(t, non_int_err, Artifact_Error.Bad_Field)
}

@(test)
test_parse_logical_field_v4 :: proc(t: ^testing.T) {
	w, h, ok := parse_logical_field("160x120")
	testing.expect(t, ok)
	testing.expect_value(t, w, 160)
	testing.expect_value(t, h, 120)

	_, _, zero_ok := parse_logical_field("160x0")
	testing.expect(t, !zero_ok)
	_, _, no_sep_ok := parse_logical_field("160")
	testing.expect(t, !no_sep_ok)
	_, _, junk_ok := parse_logical_field("axb")
	testing.expect(t, !junk_ok)
}

@(test)
test_new_world_is_empty_substrate :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	testing.expect_value(t, len(world.tables), 3)

	for table in world.tables {
		testing.expect_value(t, table.next_id, Thing_Id(0))
	}
	testing.expect_value(t, world.tables[0].thing, "Paddle")
	testing.expect_value(t, world.tables[1].thing, "Ball")
	testing.expect_value(t, world.tables[2].thing, "Scoreboard")

	paddle := world_find_table(&world, "Paddle")
	testing.expect(t, paddle != nil)
	testing.expect(t, world_find_table(&world, "Nonexistent") == nil)
}

@(test)
test_load_artifact_file_matches_embedded :: proc(t: ^testing.T) {
	path, _ := filepath.join({#directory, "testdata/pong.artifact"}, context.temp_allocator)
	program, err, io_ok := load_artifact_file(path, context.temp_allocator)
	if !testing.expect(t, io_ok, "runtime/testdata/pong.artifact must be readable") {
		return
	}
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, program.meta.name, "pong")
	testing.expect_value(t, len(program.pipeline), 11)
	testing.expect_value(t, len(program.behaviors), 10)
	testing.expect_value(t, program.entrypoint.tick_hz, 60)

	_, _, missing_ok := load_artifact_file("testdata/does_not_exist.artifact", context.temp_allocator)
	testing.expect(t, !missing_ok)
}

find_function :: proc(program: Program, name: string) -> ^Function_Decl {
	for &fn in program.functions {
		if fn.name == name {
			return &fn
		}
	}
	return nil
}

find_behavior :: proc(program: Program, name: string) -> ^Behavior_Decl {
	for &b in program.behaviors {
		if b.name == name {
			return &b
		}
	}
	return nil
}

spawn_field :: proc(cmd: Spawn_Command, name: string) -> ^Spawn_Field {
	for &f in cmd.fields {
		if f.name == name {
			return &f
		}
	}
	return nil
}

@(test)
test_body_string_node_retains_interpolation :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	draw_score := find_behavior(program, "draw_score")
	testing.expect(t, draw_score != nil)
	node := find_node_of_kind(draw_score.body, .String)
	if !testing.expect(t, node != nil, "draw_score body must carry a string node") {
		return
	}
	value, decoded := decode_string(node.fields[0])
	testing.expect(t, decoded)
	testing.expect(t, strings.contains(value, "{self.left}"))
	testing.expect(t, strings.contains(value, "{self.right}"))
}

V5_ARTIFACT :: "funpack-artifact 19\n" +
	"[meta 2]\n" +
	"project yard\n" +
	"version L5:0.1.0\n" +
	"[enums 1]\n" +
	"enum CollisionLayer CollisionLayer 2\n" +
	"variant Solid unit\n" +
	"variant Ghost unit\n" +
	"[data 1]\n" +
	"data Body 3 true\n" +
	"field vel Vec2 -\n" +
	"field layer CollisionLayer -\n" +
	"field contact Option -\n" +
	"[things 1]\n" +
	"thing Walls true 0 1\n" +
	"field body Body =Body(vel=Vec2(x=0,y=0),layer=CollisionLayer::Solid,contact=Option::None)\n" +
	"[pipeline_flattened 1]\n" +
	"step 0 stage:physics behavior:solve\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Yard tick_hz:60 logical:160x120 bindings:bindings\n"

@(test)
test_load_v5_additive_arms :: proc(t: ^testing.T) {
	program, err := load_program(V5_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "v5-grammar artifact must load, got %v", err) {
		return
	}

	testing.expect_value(t, len(program.enums), 1)
	layer_enum := program.enums[0]
	testing.expect_value(t, layer_enum.name, "CollisionLayer")
	testing.expect_value(t, layer_enum.kind, Enum_Kind.Collision_Layer)

	testing.expect_value(t, len(program.things), 1)
	walls := program.things[0]
	testing.expect_value(t, walls.name, "Walls")
	testing.expect_value(t, walls.singleton, true)
	world := new_world(program, context.temp_allocator)
	testing.expect_value(t, len(world.tables), 1)
	testing.expect_value(t, world.tables[0].singleton, true)

	testing.expect_value(t, len(program.pipeline), 1)
	step := program.pipeline[0]
	testing.expect_value(t, step.stage, "physics")
	testing.expect_value(t, step.behavior, "solve")
	testing.expect(t, find_behavior(program, "solve") == nil)

	testing.expect_value(t, len(program.data), 1)
	testing.expect_value(t, program.data[0].name, "Body")
	testing.expect_value(t, len(walls.fields), 1)
	body_field := walls.fields[0]
	testing.expect_value(t, body_field.name, "body")
	testing.expect_value(t, body_field.type, "Body")
	testing.expect(t, body_field.has_default)
	decoded, ok := decode_default(&program, body_field, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	rec, is_rec := decoded.(Record_Value)
	if !testing.expect(t, is_rec) {
		return
	}
	testing.expect_value(t, rec.type_name, "Body")
	vel, vel_ok := rec.fields["vel"].(Vec2)
	testing.expect(t, vel_ok)
	testing.expect_value(t, vel.x, to_fixed(0))
	layer, layer_ok := rec.fields["layer"].(Variant_Value)
	testing.expect(t, layer_ok)
	testing.expect_value(t, layer.case_name, "Solid")
	contact, contact_ok := rec.fields["contact"].(Variant_Value)
	testing.expect(t, contact_ok)
	testing.expect_value(t, contact.case_name, "None")
}

@(test)
test_load_v5_malformed_refused :: proc(t: ^testing.T) {
	unknown_section := "funpack-artifact 19\n[meta 2]\nproject yard\nversion L5:0.1.0\n[gravity 0]\n"
	_, unknown_err := load_program(unknown_section, context.temp_allocator)
	testing.expect_value(t, unknown_err, Artifact_Error.Malformed_Header)

	bad_count := "funpack-artifact 19\n[enums 2]\nenum CollisionLayer CollisionLayer 1\nvariant Solid unit\n"
	_, count_err := load_program(bad_count, context.temp_allocator)
	testing.expect_value(t, count_err, Artifact_Error.Section_Count_Mismatch)
}

@(test)
test_enum_kind_collision_layer :: proc(t: ^testing.T) {
	testing.expect_value(t, enum_kind_from_tag("CollisionLayer"), Enum_Kind.Collision_Layer)
	testing.expect_value(t, enum_kind_from_tag("Axis"), Enum_Kind.Axis)
	testing.expect_value(t, enum_kind_from_tag("-"), Enum_Kind.None)
}

find_node_of_kind :: proc(statements: []Node, kind: Node_Kind) -> ^Node {
	for &stmt in statements {
		if found := node_search(&stmt, kind); found != nil {
			return found
		}
	}
	return nil
}

node_search :: proc(node: ^Node, kind: Node_Kind) -> ^Node {
	if node.kind == kind {
		return node
	}
	for &child in node.children {
		if found := node_search(&child, kind); found != nil {
			return found
		}
	}
	return nil
}
