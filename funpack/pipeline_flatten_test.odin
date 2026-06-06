// The §07 flatten + §04/§07 effect-closure fixtures: the pong golden flattens
// to the spec total order and passes closure (score's Goal has tally and serve
// downstream), the negative fixture proves the edge check fires when the Goal
// consumers are removed, and the nested fixture exercises the depth-first walk
// generically (a sub-pipeline stage expands in place at its position). The
// positive flatten reads the live pong golden; the negative and nested fixtures
// are small self-contained sources, so a missing golden checkout never silences
// the proofs.
package funpack

import "core:strings"
import "core:testing"

// flatten_of resolves and typechecks a source, then runs the flatten + closure
// pass, returning its verdict. A parse/typecheck failure surfaces as a
// synthetic Unknown_Member verdict so a malformed fixture is visibly distinct
// from a flatten/closure outcome; the fixtures below all typecheck clean and
// reach the flatten stage.
flatten_of :: proc(source: string) -> Flatten_Verdict {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return Flatten_Verdict{err = .Unknown_Member, signal = "<parse-failed>"}
	}
	typed, type_err := stage_typecheck(ast)
	if type_err != .None {
		return Flatten_Verdict{err = .Unknown_Member, signal = "<typecheck-failed>"}
	}
	return stage_flatten(typed)
}

// PONG_TOTAL_ORDER is the spec §07 §3 flattened total order of the pong Pong
// pipeline: startup, then the control/collision/scoring Update stages in listed
// order, then the terminal render stage — eleven behaviors, ordinals 0..10.
PONG_TOTAL_ORDER := [?]string {
	"setup",
	"paddle_move",
	"ball_move",
	"wall_bounce",
	"paddle_bounce",
	"score",
	"tally",
	"serve",
	"draw_paddle",
	"draw_ball",
	"draw_score",
}

@(test)
test_pong_golden_flattens_to_total_order :: proc(t: ^testing.T) {
	// AC: the pong Pong pipeline flattens to the spec total order setup →
	// paddle_move → ball_move → wall_bounce → paddle_bounce → score → tally →
	// serve → draw_paddle → draw_ball → draw_score, ordinals contiguous from 0.
	// The fixture reads the live golden source and SKIPs loudly when absent.
	source, ok := pong_source()
	if !ok {
		return
	}
	verdict := flatten_of(source)
	testing.expect_value(t, verdict.err, Flatten_Error.None)
	order := verdict.flat.order
	testing.expect_value(t, len(order), len(PONG_TOTAL_ORDER))
	for want, i in PONG_TOTAL_ORDER {
		if i < len(order) {
			testing.expect_value(t, order[i].behavior, want)
			testing.expect_value(t, order[i].ordinal, i)
		}
	}
}

@(test)
test_pong_golden_passes_effect_closure :: proc(t: ^testing.T) {
	// AC: the Goal signal emitted by score has tally and serve as downstream
	// consumers, so effect closure passes (no Unclosed_Signal). The routing
	// entry pins score as the sole producer and tally + serve as consumers, each
	// at an ordinal strictly greater than score's — the §07 §2 forward-flow
	// condition.
	source, ok := pong_source()
	if !ok {
		return
	}
	verdict := flatten_of(source)
	testing.expect_value(t, verdict.err, Flatten_Error.None)

	route, found := find_route(verdict.flat, "Goal")
	testing.expect(t, found)
	if !found {
		return
	}
	testing.expect_value(t, len(route.producers), 1)
	testing.expect_value(t, route.producers[0].behavior, "score")
	testing.expect_value(t, len(route.consumers), 2)
	// score precedes both consumers in the flattened order.
	for consumer in route.consumers {
		testing.expect(t, consumer.ordinal > route.producers[0].ordinal)
	}
	testing.expect(t, has_behavior_consumer(route, "tally"))
	testing.expect(t, has_behavior_consumer(route, "serve"))
}

// FLATTEN_UNIT_HEADER declares the minimal surface a flatten/closure fixture
// needs: the engine imports, a Ball thing for the producer to write, a
// Scoreboard thing for a consumer to write, and a Goal signal to route. A
// fixture appends its behaviors and the pipeline that places them in stages.
FLATTEN_UNIT_HEADER :: "import engine.math.{Fixed, Vec2}\n" +
	"import engine.world.{View, Spawn}\n" +
	"import engine.render.{Draw, Color}\n" +
	"thing Ball { x: Fixed, y: Fixed }\n" +
	"thing Scoreboard { left: Int, right: Int }\n" +
	"signal Goal { side: Fixed }\n"

flatten_unit :: proc(body: string) -> Flatten_Verdict {
	source := strings.concatenate({FLATTEN_UNIT_HEADER, body}, context.temp_allocator)
	return flatten_of(source)
}

// SCORE_BEHAVIOR emits a [Goal] signal — the producer the closure fixtures
// route. TALLY_BEHAVIOR consumes an inbound [Goal] writing the Scoreboard
// blackboard — the downstream consumer the negative fixture removes.
SCORE_BEHAVIOR :: "behavior score on Ball {\n" +
	"  fn step(self: Ball) -> [Goal] {\n" +
	"    return [Goal{side: self.x}]\n" +
	"  }\n" +
	"}\n"

TALLY_BEHAVIOR :: "behavior tally on Scoreboard {\n" +
	"  fn step(self: Scoreboard, goals: [Goal]) -> Scoreboard {\n" +
	"    return self\n" +
	"  }\n" +
	"}\n"

@(test)
test_closure_passes_with_downstream_consumer :: proc(t: ^testing.T) {
	// The positive control for the negative fixture: a scoring stage listing the
	// emitter (score) then a downstream consumer (tally) closes the Goal signal,
	// so the closure check passes. This isolates that the negative fixture
	// rejects for the missing consumer, not an incidental header gap.
	verdict := flatten_unit(
		SCORE_BEHAVIOR + TALLY_BEHAVIOR +
		"pipeline Game {\n" +
		"  scoring: [score, tally]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Flatten_Error.None)
}

@(test)
test_closure_rejects_unconsumed_signal :: proc(t: ^testing.T) {
	// AC: removing the Goal consumer (tally) from the scoring stage leaves
	// score's emitted Goal with no downstream consumer, so the effect-closure
	// edge check rejects with Unclosed_Signal, naming the unclosed signal. score
	// occupies the stage alone — it produces Goal but nothing consumes it.
	verdict := flatten_unit(
		SCORE_BEHAVIOR +
		"pipeline Game {\n" +
		"  scoring: [score]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Flatten_Error.Unclosed_Signal)
	testing.expect_value(t, verdict.signal, "Goal")
}

// SNAKE_CLOSURE_HEADER declares a snake-shaped surface: a Snake thing whose
// detect_eat emits an Eaten signal and whose grow consumes it. The negative
// fixture removes the consumer so the emitted Eaten goes unclosed, mirroring
// snake's eat stage (detect_eat → grow) with the consumer dropped.
SNAKE_CLOSURE_HEADER :: "import engine.math.{Vec2}\n" +
	"import engine.world.{View, Spawn}\n" +
	"import engine.render.{Draw, Color}\n" +
	"thing Snake { grow: Bool }\n" +
	"signal Eaten { x: Fixed }\n" +
	"behavior detect_eat on Snake {\n" +
	"  fn step(self: Snake) -> [Eaten] {\n" +
	"    return [Eaten{x: 0.0}]\n" +
	"  }\n" +
	"}\n"

@(test)
test_closure_rejects_orphaned_snake_signal :: proc(t: ^testing.T) {
	// AC (snake-shaped orphan): a snake-shaped program whose detect_eat emits an
	// Eaten with no downstream consuming stage fails the effect-closure edge
	// check with Unclosed_Signal naming Eaten. The eat stage lists only the
	// emitter — the grow consumer that would close it is absent — so the signal
	// is produced and never consumed, exactly the §04 §4 / §07 §2 violation.
	source := strings.concatenate({SNAKE_CLOSURE_HEADER,
		"pipeline Snake {\n" +
		"  eat: [detect_eat]\n" +
		"}\n"}, context.temp_allocator)
	verdict := flatten_of(source)
	testing.expect_value(t, verdict.err, Flatten_Error.Unclosed_Signal)
	testing.expect_value(t, verdict.signal, "Eaten")
}

@(test)
test_closure_passes_snake_eat_stage_with_consumer :: proc(t: ^testing.T) {
	// The positive control: re-adding the grow consumer downstream of detect_eat
	// closes the Eaten signal, so the edge check passes — proof the orphan
	// fixture rejects for the missing consumer, not an incidental header gap.
	source := strings.concatenate({SNAKE_CLOSURE_HEADER,
		"behavior grow on Snake {\n" +
		"  fn step(self: Snake, eaten: [Eaten]) -> Snake {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n" +
		"pipeline Snake {\n" +
		"  eat: [detect_eat, grow]\n" +
		"}\n"}, context.temp_allocator)
	verdict := flatten_of(source)
	testing.expect_value(t, verdict.err, Flatten_Error.None)
}

@(test)
test_closure_rejects_upstream_only_consumer :: proc(t: ^testing.T) {
	// The boundary opposite the positive: a consumer listed BEFORE the emitter
	// is not downstream — its ordinal is strictly less than the producer's, so
	// the §07 §2 forward-flow condition fails and the signal is still unclosed.
	// This pins that closure reads the flattened ORDER, not mere co-presence.
	verdict := flatten_unit(
		SCORE_BEHAVIOR + TALLY_BEHAVIOR +
		"pipeline Game {\n" +
		"  scoring: [tally, score]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Flatten_Error.Unclosed_Signal)
	testing.expect_value(t, verdict.signal, "Goal")
}

// The depth-first nested fixtures build the Typed_Ast directly. The §07 §1
// surface grammar admits only a snake_case behavior-name stage member
// (parser.odin's parse_behavior_list rejects an UpperCamel member as
// Wrong_Case), so a sub-pipeline stage reference cannot be written in source —
// the pong surface is single-level by construction. The flatten SEAM is still
// the general depth-first walk (a stage member that resolves to a pipeline name
// expands in place), so these fixtures prove that seam by constructing a nested
// pipeline model the parser would never emit, exercising sub-pipeline expansion
// without a grammar that has no such form.

// stub_signal builds a [Goal]-typed signal list — the routing edge a
// constructed term emits or consumes.
stub_signal :: proc() -> Type {
	return list_of(user_type_of("Goal", .Signal))
}

// stub_ball builds the Ball thing handle — a constructed behavior's blackboard
// write.
stub_ball :: proc() -> Type {
	return user_type_of("Ball", .Thing)
}

// stage_with builds one Pipeline_Stage with its member list cloned into the
// temp allocator, so the backing array survives the constructing proc's return
// (an inline `[]string{…}` literal would dangle once the frame unwinds).
stage_with :: proc(name: string, members: ..string) -> Pipeline_Stage {
	list := make([]string, len(members), context.temp_allocator)
	copy(list, members)
	return Pipeline_Stage{name = name, behaviors = list}
}

// pipeline_with builds one Pipeline_Node with its stage list cloned into the
// temp allocator (same dangling-slice avoidance as stage_with).
pipeline_with :: proc(name: string, stages: ..Pipeline_Stage) -> Pipeline_Node {
	list := make([]Pipeline_Stage, len(stages), context.temp_allocator)
	copy(list, stages)
	return Pipeline_Node{name = name, stages = list}
}

// nested_typed builds a Typed_Ast with a root Game pipeline whose middle stage
// member names the Inner sub-pipeline, plus the four term signatures the walk
// and routing graph read: score emits [Goal], tally/serve consume [Goal], draw
// returns nothing routed. Game is declared first, so stage_flatten roots on it.
// Every backing slice is temp-allocated so the model outlives this proc.
nested_typed :: proc() -> Typed_Ast {
	env: Type_Env
	env.records = make(map[string]Record_Schema, context.temp_allocator)
	env.enums = make(map[string]Enum_Schema, context.temp_allocator)
	env.terms = make(map[string]Term_Schema, context.temp_allocator)
	env.terms["score"] = stub_term("score", emits = stub_signal())
	env.terms["tally"] = stub_term("tally", consumes = stub_signal())
	env.terms["serve"] = stub_term("serve", consumes = stub_signal())
	env.terms["draw"] = stub_term("draw", emits = stub_ball())

	pipelines := make([]Pipeline_Node, 2, context.temp_allocator)
	pipelines[0] = pipeline_with(
		"Game",
		stage_with("emit", "score", "Inner"),
		stage_with("render", "draw"),
	)
	pipelines[1] = pipeline_with(
		"Inner",
		stage_with("consume_a", "tally"),
		stage_with("consume_b", "serve"),
	)
	signals := make([]Signal_Node, 1, context.temp_allocator)
	signals[0] = Signal_Node{name = "Goal"}
	return Typed_Ast{ast = Ast{pipelines = pipelines, signals = signals}, env = env}
}

// stub_term builds a behavior Term_Schema with the given emitted return and
// optional inbound consumed param — the typed signature the flatten routing
// graph reads (the same Term_Schema window resolve.odin records and contracts
// reads). consumes is the inbound [Goal] param when non-nil; emits is the
// return type.
stub_term :: proc(name: string, emits: Type = nil, consumes: Type = nil) -> Term_Schema {
	params := make([dynamic]Type, 0, 2, context.temp_allocator)
	append(&params, stub_ball()) // self
	if consumes != nil {
		append(&params, consumes)
	}
	sig := new(Func_Type, context.temp_allocator)
	sig.params = params[:]
	sig.result = emits
	return Term_Schema{name = name, kind = .Behavior, signature = sig, target = "Ball"}
}

@(test)
test_nested_sub_pipeline_flattens_in_place :: proc(t: ^testing.T) {
	// AC: a stage naming a sub-pipeline flattens it in place at the correct
	// position — the general depth-first walk, not a single-level special case.
	// The root Game lists a leaf (score), then a sub-pipeline (Inner), then
	// another leaf (draw). Inner expands to its own two stages between score and
	// draw, so the total order is score → tally → serve → draw, with Inner's
	// members keeping their inner stage names.
	verdict := stage_flatten(nested_typed())
	testing.expect_value(t, verdict.err, Flatten_Error.None)
	order := verdict.flat.order
	testing.expect_value(t, len(order), 4)
	if len(order) == 4 {
		// score (Game.emit), then Inner expands in place: tally (Inner.consume_a),
		// serve (Inner.consume_b), then draw (Game.render).
		testing.expect_value(t, order[0].behavior, "score")
		testing.expect_value(t, order[0].stage, "emit")
		testing.expect_value(t, order[1].behavior, "tally")
		testing.expect_value(t, order[1].stage, "consume_a")
		testing.expect_value(t, order[2].behavior, "serve")
		testing.expect_value(t, order[2].stage, "consume_b")
		testing.expect_value(t, order[3].behavior, "draw")
		testing.expect_value(t, order[3].stage, "render")
		for step, i in order {
			testing.expect_value(t, step.ordinal, i)
		}
	}
}

@(test)
test_nested_flatten_closes_across_sub_pipeline :: proc(t: ^testing.T) {
	// The nested walk feeds the SAME routing graph: score (in Game) emits Goal,
	// tally and serve (expanded from the sub-pipeline Inner) consume it
	// downstream, so closure passes across the pipeline boundary — the flatten
	// is one total order, not a per-pipeline silo.
	verdict := stage_flatten(nested_typed())
	testing.expect_value(t, verdict.err, Flatten_Error.None)
	route, found := find_route(verdict.flat, "Goal")
	testing.expect(t, found)
	if found {
		testing.expect_value(t, len(route.producers), 1)
		testing.expect_value(t, route.producers[0].behavior, "score")
		testing.expect_value(t, len(route.consumers), 2)
		testing.expect(t, has_behavior_consumer(route, "tally"))
		testing.expect(t, has_behavior_consumer(route, "serve"))
	}
}

@(test)
test_flatten_rejects_unknown_stage_member :: proc(t: ^testing.T) {
	// A stage member that names neither a leaf occupant nor a sub-pipeline is an
	// Unknown_Member reject — the flatten walk has no leaf to append and no
	// pipeline to expand. The constructed root lists `ghost`, declared in no
	// term and no pipeline.
	typed := nested_typed()
	typed.ast.pipelines[0].stages[0] = stage_with("emit", "score", "ghost")
	verdict := stage_flatten(typed)
	testing.expect_value(t, verdict.err, Flatten_Error.Unknown_Member)
}

@(test)
test_flatten_rejects_recursive_sub_pipeline :: proc(t: ^testing.T) {
	// A sub-pipeline reference that cycles (Game lists Loop, Loop lists Game) is
	// a Recursive_Pipeline reject — a pipeline tree is acyclic (spec §07 §3), so
	// the visited-set guard fires rather than recursing without bound.
	typed := nested_typed()
	typed.ast.pipelines[0].stages[0] = stage_with("emit", "score", "Loop")
	typed.ast.pipelines[1] = pipeline_with("Loop", stage_with("back", "Game"))
	verdict := stage_flatten(typed)
	testing.expect_value(t, verdict.err, Flatten_Error.Recursive_Pipeline)
}

@(test)
test_flatten_no_pipeline_is_vacuous_pass :: proc(t: ^testing.T) {
	// A source with no pipeline flattens to the empty order and passes closure
	// vacuously — there is no schedule to flatten and no emitted signal to leave
	// unconsumed.
	source := strings.concatenate({FLATTEN_UNIT_HEADER, SCORE_BEHAVIOR}, context.temp_allocator)
	verdict := flatten_of(source)
	testing.expect_value(t, verdict.err, Flatten_Error.None)
	testing.expect_value(t, len(verdict.flat.order), 0)
}

@(test)
test_flatten_signal_only_consumed_is_closed_vacuously :: proc(t: ^testing.T) {
	// A signal that is consumed but never produced is vacuously closed — closure
	// guards against an EMITTED signal with no consumer, so an
	// emitted-nowhere/consumed-somewhere signal raises no edge-check error (the
	// producer side is the closure obligation, not the consumer side). tally
	// consumes Goal with no score emitter present.
	verdict := flatten_unit(
		TALLY_BEHAVIOR +
		"pipeline Game {\n" +
		"  scoring: [tally]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Flatten_Error.None)
}

// find_route looks up a signal's routing entry by name over a flattened
// pipeline — a linear scan the closure fixtures read one signal's producers and
// consumers through.
find_route :: proc(flat: Flattened_Pipeline, signal: string) -> (Signal_Route, bool) {
	for route in flat.routes {
		if route.signal == signal {
			return route, true
		}
	}
	return Signal_Route{}, false
}

// has_behavior_consumer reports whether a behavior appears among a route's
// consumer endpoints — the fixtures assert membership without depending on
// consumer order.
has_behavior_consumer :: proc(route: Signal_Route, behavior: string) -> bool {
	for consumer in route.consumers {
		if consumer.behavior == behavior {
			return true
		}
	}
	return false
}
