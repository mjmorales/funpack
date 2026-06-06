// Loader acceptance: the golden pong artifact loads into the in-memory tables
// the sim executes over (docs/artifact-format.md), with the expected flattened
// pipeline order, the behavior-per-stage bindings, and the setup fixed-point
// literals decoded BIT-EXACT through the runtime kernel — never through a float.
//
// The fixture is `#load`-embedded at compile time, so the test never depends on
// cwd and runtime/** stays the self-contained, zero-funpack-import reader: the
// artifact bytes are the only coupling to the compiler product (spec §29, §09).
// runtime/testdata/pong.artifact is a byte-identical copy of the committed
// golden at funpack/testdata/pong.artifact.
package funpack_runtime

import "core:path/filepath"
import "core:strings"
import "core:testing"

// GOLDEN_ARTIFACT is the committed golden pong artifact, embedded at compile
// time. `#load` keeps the loader test hermetic — no filesystem, no cwd, no
// funpack source on the path.
GOLDEN_ARTIFACT := #load("testdata/pong.artifact", string)

// load_golden parses the embedded fixture into a Program against the test's
// temp allocator, failing the test on any refusal.
load_golden :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(GOLDEN_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "golden artifact must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

// The version gate is exact-match: the golden's stamp is v5, and the loader
// builds against exactly that. A wrong stamp or version is refused, never parsed
// (§1). v5 is the accept case (the yard cross-epic schema bump — singleton
// marker, physics stage, CollisionLayer tag, engine-type defaults); v4 and any
// future v6 are mismatches the loader refuses before reading any payload.
@(test)
test_load_version_gate :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, program.schema_version, ARTIFACT_SCHEMA_VERSION)

	// A v4 stamp is now a mismatch — the prior (logical-extent) schema, refused
	// before any payload.
	old_version := "funpack-artifact 4\n[meta 0]\n"
	_, old_err := load_program(old_version, context.temp_allocator)
	testing.expect_value(t, old_err, Artifact_Error.Version_Mismatch)

	// A FUTURE version (v6) is equally a mismatch — the gate is exact, not
	// floor-or-ceiling.
	future_version := "funpack-artifact 6\n[meta 0]\n"
	_, future_err := load_program(future_version, context.temp_allocator)
	testing.expect_value(t, future_err, Artifact_Error.Version_Mismatch)

	// A wrong stamp keyword is refused.
	bad_stamp := "notfunpack 2\n"
	_, stamp_err := load_program(bad_stamp, context.temp_allocator)
	testing.expect_value(t, stamp_err, Artifact_Error.Bad_Stamp)

	// Empty input is refused.
	_, empty_err := load_program("", context.temp_allocator)
	testing.expect_value(t, empty_err, Artifact_Error.Empty_Input)
}

// The §4 meta identity is name + version, no clock, no platform.
@(test)
test_load_meta :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, program.meta.name, "pong")
	testing.expect_value(t, program.meta.version, "0.1.0")
}

// The enum descriptors carry the role kind (type-constitutive, §03 §4): Side is
// unkinded (`-` → None), Steer is Axis. Variants are in declaration order.
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
	testing.expect_value(t, steer.kind, Enum_Kind.Axis) // only an Axis enum binds analog input
	testing.expect_value(t, len(steer.variants), 1)
	testing.expect_value(t, steer.variants[0].name, "Move")
}

// The data and signal schemas carry their fields with types and default flags.
// Board's fields have no default (`-`); Goal's one field is `side: Side`.
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

// The thing descriptors carry the singleton flag, the gtag set, and the
// blackboard schema with per-field defaults. Pong models the score as an
// ordinary thing (singleton false), so the singleton path is generic but
// unexercised — Scoreboard's Int fields carry a `=0` default in the golden source.
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
	testing.expect_value(t, score.singleton, false) // pong: ordinary thing, not a singleton
	// A defaulted field records its default so a Spawn may omit it (§6).
	testing.expect_value(t, score.fields[0].name, "left")
	testing.expect_value(t, score.fields[0].type, "Int")
	testing.expect_value(t, score.fields[0].has_default, true)
	testing.expect_value(t, score.fields[0].default_encoded, "0")
}

// The function table carries all 10 records (7 fn + BOARD const + bindings +
// setup), each with its kind, signature, and a non-empty interpreted body. The
// span is diagnostic provenance only — module:line, never a filesystem path.
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
	testing.expect(t, len(advance.body) == 1) // a single `return`

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

// The flattened pipeline is the ONE total order (§11): 11 contiguous steps from
// 0, starting at the startup behavior and ending at the terminal render stage.
// This is the order a tick's fold visits — the assertion the tick fold
// depends on.
@(test)
test_load_pipeline_total_order :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.pipeline), 11)

	// Ordinals are 0-based, contiguous, and gap-free.
	for step, i in program.pipeline {
		testing.expect_value(t, step.ordinal, i)
	}

	// The expected flattened order: startup, then control, collision, scoring,
	// render — each stage expanded to its behaviors in listed order (§11).
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

// Each pipeline step's behavior resolves to a [behaviors] record whose stage
// MATCHES the pipeline slot — the behavior-per-stage binding (§10, §11). A
// behavior referenced in the pipeline must exist and sit in the stage that
// confers its contract.
@(test)
test_behavior_per_stage_bindings :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.behaviors), 10)

	// Every non-startup pipeline step binds to a behavior whose stage equals the
	// pipeline slot's stage and whose on-thing/contract are the conferred pair.
	for step in program.pipeline {
		if step.stage == "startup" {
			continue // the startup step's behavior is `setup`, a [functions] record
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

	// Spot-check the conferred bindings: paddle_move writes Paddle in control as
	// Update; draw_ball writes [Draw] on Ball in render as Render (§10).
	paddle_move := find_behavior(program, "paddle_move")
	testing.expect(t, paddle_move != nil)
	testing.expect_value(t, paddle_move.on_thing, "Paddle")
	testing.expect_value(t, paddle_move.stage, "control")
	testing.expect_value(t, paddle_move.contract, "Update")
	testing.expect_value(t, len(paddle_move.params), 3) // self, input, time
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

	// paddle_bounce reads a View[Paddle] and carries both its gtags (§10).
	paddle_bounce := find_behavior(program, "paddle_bounce")
	testing.expect(t, paddle_bounce != nil)
	testing.expect_value(t, len(paddle_bounce.gtags), 2)
	testing.expect_value(t, paddle_bounce.params[1].type, "View[Paddle]")
}

// The signal routing map: Goal is produced by `score` (scoring) and consumed by
// `tally` and `serve` downstream in the flattened order — the canonical forward
// synchronous in-pipeline-order route (§12). Every consumer's ordinal
// is strictly greater than the producer's (effect closure).
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

	// Effect closure: every consumer is strictly downstream of the producer.
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

// The §13 setup [Spawn] batch: 4 commands (2 paddles + ball + scoreboard) in
// source list order. Scoreboard's defaulted fields are carried explicitly in the
// fixture (`set left =0`), so the batch has them; an omitted field would not
// appear (the runtime applies the default at spawn).
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

// THE FIXED-POINT ACCEPTANCE: the setup batch's Fixed literals decode BIT-EQUAL
// to the runtime kernel's representation of the same source literal — proving
// there is no float in the load path. The fixture carries `set x =34359738368`
// for the P1 paddle (8.0); decoding it must equal to_fixed(8) exactly, and the
// ball's Vec2 velocity components must equal the kernel's 70.0/40.0 bits.
@(test)
test_setup_fixed_literals_are_kernel_bit_exact :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}

	// P1 paddle: x = 8.0, y = 60.0, speed = 90.0 — each must equal the kernel's
	// to_fixed of the source literal, bit-for-bit (§2.3, §10.5).
	p1 := program.setup[0]
	x := spawn_field(p1, "x")
	y := spawn_field(p1, "y")
	speed := spawn_field(p1, "speed")
	testing.expect(t, x != nil && y != nil && speed != nil)
	testing.expect_value(t, x.kind, Spawn_Value_Kind.Fixed)
	testing.expect_value(t, x.fixed, to_fixed(8)) // 8.0 == 34359738368 raw
	testing.expect_value(t, y.fixed, to_fixed(60)) // 60.0
	testing.expect_value(t, speed.fixed, to_fixed(90)) // 90.0

	// The enum field stays a name token (§2.6), never coerced to a number.
	side := spawn_field(p1, "side")
	testing.expect(t, side != nil)
	testing.expect_value(t, side.kind, Spawn_Value_Kind.Variant)
	testing.expect_value(t, side.variant, "Side::Left")

	// P2 paddle: x = 152.0 — the column the funpack-side test pins.
	p2 := program.setup[1]
	p2x := spawn_field(p2, "x")
	testing.expect(t, p2x != nil)
	testing.expect_value(t, p2x.fixed, to_fixed(152))

	// Ball Vec2 fields decode both components through the kernel (§13). pos =
	// (80.0, 60.0); vel = (70.0, 40.0).
	ball := program.setup[2]
	pos := spawn_field(ball, "pos")
	vel := spawn_field(ball, "vel")
	testing.expect(t, pos != nil && vel != nil)
	testing.expect_value(t, pos.kind, Spawn_Value_Kind.Vec2)
	testing.expect_value(t, pos.vec2_x, to_fixed(80))
	testing.expect_value(t, pos.vec2_y, to_fixed(60))
	testing.expect_value(t, vel.vec2_x, to_fixed(70))
	testing.expect_value(t, vel.vec2_y, to_fixed(40))

	// Scoreboard Int fields stay Int-valued (the raw bits, not scaled): `set
	// left =0` decodes to int_val 0.
	score := program.setup[3]
	left := spawn_field(score, "left")
	testing.expect(t, left != nil)
	testing.expect_value(t, left.int_val, i64(0))
}

// The §14 bindings table: the four resolved axis bindings in source-call order
// (bindings stack), with the device source kept as its builder-call token — the
// only device-aware data in the artifact.
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

// The §15 entrypoint wiring: pipeline ↔ tick ↔ logical ↔ bindings, with the
// single fixed 60hz tick rate and the §20 §3 logical draw space (pong's
// 160x120) in integer world units.
@(test)
test_load_entrypoint :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, program.entrypoint.name, "main")
	testing.expect_value(t, program.entrypoint.pipeline, "Pong")
	testing.expect_value(t, program.entrypoint.tick_hz, 60) // the one fixed tick
	testing.expect_value(t, program.entrypoint.logical_w, 160)
	testing.expect_value(t, program.entrypoint.logical_h, 120)
	testing.expect_value(t, program.entrypoint.bindings, "bindings")
}

// parse_logical_field pins the §15 logical:WxH conversion directly: the WxH
// split into positive integer world units, and the closed rejections — a zero
// dimension, a separator-less token, and a non-integer side never produce a
// degenerate letterbox extent.
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

// The empty runtime substrate: new_world builds one Thing_Table per declared
// thing, keyed by Id, with NO rows — population happens when setup runs in the
// tick transaction. This layer produces the substrate, never a populated world.
@(test)
test_new_world_is_empty_substrate :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	testing.expect_value(t, len(world.tables), 3) // Paddle, Ball, Scoreboard

	for table in world.tables {
		// Empty: no Id minted yet — setup has not run.
		testing.expect_value(t, table.next_id, Thing_Id(0))
	}
	// The tables key by thing name in declaration order.
	testing.expect_value(t, world.tables[0].thing, "Paddle")
	testing.expect_value(t, world.tables[1].thing, "Ball")
	testing.expect_value(t, world.tables[2].thing, "Scoreboard")

	// Lookup resolves a declared thing and misses an undeclared one.
	paddle := world_find_table(&world, "Paddle")
	testing.expect(t, paddle != nil)
	testing.expect(t, world_find_table(&world, "Nonexistent") == nil)
}

// The production file-IO path loads the same Program off disk via
// core:os.read_entire_file (Odin-first IO). The on-disk copy at
// runtime/testdata/pong.artifact is byte-identical to the embedded fixture, so
// the file load and the #load yield identical tables — proving the IO wrapper
// adds no drift over the in-memory path. The path is resolved relative to this
// source file (#directory) so the test is cwd-independent.
@(test)
test_load_artifact_file_matches_embedded :: proc(t: ^testing.T) {
	path, _ := filepath.join({#directory, "testdata/pong.artifact"}, context.temp_allocator)
	program, err, io_ok := load_artifact_file(path, context.temp_allocator)
	if !testing.expect(t, io_ok, "runtime/testdata/pong.artifact must be readable") {
		return
	}
	testing.expect_value(t, err, Artifact_Error.None)
	// Same structural fingerprint as the embedded load.
	testing.expect_value(t, program.meta.name, "pong")
	testing.expect_value(t, len(program.pipeline), 11)
	testing.expect_value(t, len(program.behaviors), 10)
	testing.expect_value(t, program.entrypoint.tick_hz, 60)

	// A missing file reports io_ok false, not a parse error — IO failure and a
	// malformed artifact are distinct surfaces.
	_, _, missing_ok := load_artifact_file("testdata/does_not_exist.artifact", context.temp_allocator)
	testing.expect(t, !missing_ok)
}

// --- lookup helpers --------------------------------------------------------

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

// A representative String literal interpolation hole is retained verbatim in a
// body `string` node (§2.4): draw_score's text node carries `{self.left}
// {self.right}` with its interpolation holes intact, 26 bytes.
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

// --- v5 schema additive decode arms (the yard physics surface) -------------
// The sibling funpack epic defines v5 (singleton-spawn marker, the physics:/solve
// engine battery, the CollisionLayer enum kind, and §6 Body/Settings/Option
// composite defaults) and owns the VERSION-CEILING bump (stamp 4→5) plus the
// regenerated golden testdata. This story lands the ADDITIVE DECODE ARMS, proving
// them on a HAND-WRITTEN section string under the CURRENT v4 stamp (runtime Lore
// #8): v5 is a value-encoding + engine-stage addition over existing record shapes,
// so the additive grammar parses under v4 — the loader reconciles against a real
// emitted yard.artifact once v5 and its golden exist.

// V5_ARTIFACT is a hand-written artifact exercising every v5 additive arm under
// the v5 stamp: a CollisionLayer enum (§5), a `Body` data decl whose `body` field
// carries a §6 composite default nesting a Vec2 record + a CollisionLayer token +
// an Option::None token, a SINGLETON thing (the singleton-spawn marker), and a
// `physics:`/`solve` pipeline step that is engine-closed (no [behaviors] record).
// It is the artifact-before-artifact fixture: hand-built, not compiler-emitted.
V5_ARTIFACT :: "funpack-artifact 5\n" +
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

// The accept path: a hand-written v5-grammar artifact loads to a Program without
// error, and every v5 additive arm decodes — the singleton marker carries, the
// physics:/solve engine step is in the pipeline, the CollisionLayer enum kind
// resolves, and the §6 Body composite default is present on its field.
@(test)
test_load_v5_additive_arms :: proc(t: ^testing.T) {
	program, err := load_program(V5_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "v5-grammar artifact must load, got %v", err) {
		return
	}

	// (c) The CollisionLayer enum kind resolves (enum_kind_from_tag is total over it).
	testing.expect_value(t, len(program.enums), 1)
	layer_enum := program.enums[0]
	testing.expect_value(t, layer_enum.name, "CollisionLayer")
	testing.expect_value(t, layer_enum.kind, Enum_Kind.Collision_Layer)

	// (a) The singleton-spawn marker: `thing Walls SINGLETON …` carries singleton
	// onto the descriptor, and new_world mirrors it onto the table so the spawn
	// step knows the row is engine-spawned pre-tick-0.
	testing.expect_value(t, len(program.things), 1)
	walls := program.things[0]
	testing.expect_value(t, walls.name, "Walls")
	testing.expect_value(t, walls.singleton, true)
	world := new_world(program, context.temp_allocator)
	testing.expect_value(t, len(world.tables), 1)
	testing.expect_value(t, world.tables[0].singleton, true)

	// (b) The physics:/solve engine step is a real pipeline position with NO
	// [behaviors] record — the loader keeps the order, never resolving a user
	// behavior for the engine-closed stage.
	testing.expect_value(t, len(program.pipeline), 1)
	step := program.pipeline[0]
	testing.expect_value(t, step.stage, "physics")
	testing.expect_value(t, step.behavior, "solve")
	testing.expect(t, find_behavior(program, "solve") == nil) // engine-closed: no user record

	// (d) The §6 Body composite default on Walls.body decodes to a Record_Value
	// column nesting a Vec2 + a CollisionLayer token + Option::None — each nested
	// field decoded by the Body data decl's declared field types.
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

// The refusal path is fail-closed: a malformed section (a declared count that
// disagrees with the lead-line count) and an UNKNOWN section name are both refused
// before producing a partial Program — the load is total or it fails closed (§1).
@(test)
test_load_v5_malformed_refused :: proc(t: ^testing.T) {
	// An unknown section name is a schema mismatch — build_program refuses it.
	unknown_section := "funpack-artifact 5\n[meta 2]\nproject yard\nversion L5:0.1.0\n[gravity 0]\n"
	_, unknown_err := load_program(unknown_section, context.temp_allocator)
	testing.expect_value(t, unknown_err, Artifact_Error.Malformed_Header)

	// A declared count that over-shapes the section is a parse-layer refusal.
	bad_count := "funpack-artifact 5\n[enums 2]\nenum CollisionLayer CollisionLayer 1\nvariant Solid unit\n"
	_, count_err := load_program(bad_count, context.temp_allocator)
	testing.expect_value(t, count_err, Artifact_Error.Section_Count_Mismatch)
}

// The CollisionLayer role-kind tag maps to its closed Enum_Kind, pinned directly
// at the decoder so the v5 enum kind has a precise leaf failure signal (the §03 §4
// kind is type-constitutive — a CollisionLayer enum is the §10 collision tag set).
@(test)
test_enum_kind_collision_layer :: proc(t: ^testing.T) {
	testing.expect_value(t, enum_kind_from_tag("CollisionLayer"), Enum_Kind.Collision_Layer)
	// The closed set is otherwise unchanged: an unknown tag and `-` are None.
	testing.expect_value(t, enum_kind_from_tag("Axis"), Enum_Kind.Axis)
	testing.expect_value(t, enum_kind_from_tag("-"), Enum_Kind.None)
}

// find_node_of_kind walks a body forest pre-order for the first node of a kind —
// a test helper to reach into a reconstructed subtree.
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
