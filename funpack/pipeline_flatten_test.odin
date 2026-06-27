package funpack

import "core:strings"
import "core:testing"

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
	for consumer in route.consumers {
		testing.expect(t, consumer.ordinal > route.producers[0].ordinal)
	}
	testing.expect(t, has_behavior_consumer(route, "tally"))
	testing.expect(t, has_behavior_consumer(route, "serve"))
}

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
	verdict := flatten_unit(
		SCORE_BEHAVIOR + TALLY_BEHAVIOR +
		"pipeline Game {\n" +
		"  scoring: [score, tally]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Flatten_Error.None)
}

@(test)
test_closure_rejects_unconsumed_signal :: proc(t: ^testing.T) {
	verdict := flatten_unit(
		SCORE_BEHAVIOR +
		"pipeline Game {\n" +
		"  scoring: [score]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Flatten_Error.Unclosed_Signal)
	testing.expect_value(t, verdict.signal, "Goal")
}

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
	source := strings.concatenate({SNAKE_CLOSURE_HEADER,
		"pipeline Snake {\n" +
		"  eat: [detect_eat]\n" +
		"}\n"}, context.temp_allocator)
	verdict := flatten_of(source)
	testing.expect_value(t, verdict.err, Flatten_Error.Unclosed_Signal)
	testing.expect_value(t, verdict.signal, "Eaten")
}

@(test)
test_closure_rejects_orphaned_live_snake_signal :: proc(t: ^testing.T) {
	source, ok := snake_source()
	if !ok {
		return
	}
	variant, found := golden_variant(
		source,
		"death:   [detect_death, apply_death]",
		"death:   [detect_death]",
	)
	testing.expect(t, found)
	verdict := flatten_of(variant)
	testing.expect_value(t, verdict.err, Flatten_Error.Unclosed_Signal)
	testing.expect_value(t, verdict.signal, "Died")
}

@(test)
test_closure_passes_snake_eat_stage_with_consumer :: proc(t: ^testing.T) {
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
	verdict := flatten_unit(
		SCORE_BEHAVIOR + TALLY_BEHAVIOR +
		"pipeline Game {\n" +
		"  scoring: [tally, score]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Flatten_Error.Unclosed_Signal)
	testing.expect_value(t, verdict.signal, "Goal")
}

stub_signal :: proc() -> Type {
	return list_of(user_type_of("Goal", .Signal))
}

stub_ball :: proc() -> Type {
	return user_type_of("Ball", .Thing)
}

stage_with :: proc(name: string, members: ..string) -> Pipeline_Stage {
	list := make([]string, len(members), context.temp_allocator)
	copy(list, members)
	return Pipeline_Stage{name = name, behaviors = list}
}

pipeline_with :: proc(name: string, stages: ..Pipeline_Stage) -> Pipeline_Node {
	list := make([]Pipeline_Stage, len(stages), context.temp_allocator)
	copy(list, stages)
	return Pipeline_Node{name = name, stages = list}
}

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

stub_term :: proc(name: string, emits: Type = nil, consumes: Type = nil) -> Term_Schema {
	params := make([dynamic]Type, 0, 2, context.temp_allocator)
	append(&params, stub_ball())
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
	verdict := stage_flatten(nested_typed())
	testing.expect_value(t, verdict.err, Flatten_Error.None)
	order := verdict.flat.order
	testing.expect_value(t, len(order), 4)
	if len(order) == 4 {
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
	typed := nested_typed()
	typed.ast.pipelines[0].stages[0] = stage_with("emit", "score", "ghost")
	verdict := stage_flatten(typed)
	testing.expect_value(t, verdict.err, Flatten_Error.Unknown_Member)
}

@(test)
test_flatten_rejects_recursive_sub_pipeline :: proc(t: ^testing.T) {
	typed := nested_typed()
	typed.ast.pipelines[0].stages[0] = stage_with("emit", "score", "Loop")
	typed.ast.pipelines[1] = pipeline_with("Loop", stage_with("back", "Game"))
	verdict := stage_flatten(typed)
	testing.expect_value(t, verdict.err, Flatten_Error.Recursive_Pipeline)
}

@(test)
test_flatten_no_pipeline_is_vacuous_pass :: proc(t: ^testing.T) {
	source := strings.concatenate({FLATTEN_UNIT_HEADER, SCORE_BEHAVIOR}, context.temp_allocator)
	verdict := flatten_of(source)
	testing.expect_value(t, verdict.err, Flatten_Error.None)
	testing.expect_value(t, len(verdict.flat.order), 0)
}

@(test)
test_flatten_signal_only_consumed_is_closed_vacuously :: proc(t: ^testing.T) {
	verdict := flatten_unit(
		TALLY_BEHAVIOR +
		"pipeline Game {\n" +
		"  scoring: [tally]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Flatten_Error.None)
}

FLATTEN_SIM_HEADER :: "import engine.math.{Fixed, Vec2}\n" +
	"import engine.world.{View, Spawn, Despawn}\n" +
	"import engine.render.{Draw, Color}\n" +
	"import engine.rand.{Rng}\n" +
	"data Cell { x: Int, y: Int }\n" +
	"thing Snake { head: Cell = Cell{x: 0, y: 0} }\n" +
	"thing Food { cell: Cell }\n" +
	"signal Eaten { cell: Cell }\n"

flatten_sim :: proc(body: string) -> Flatten_Verdict {
	source := strings.concatenate({FLATTEN_SIM_HEADER, body}, context.temp_allocator)
	return flatten_of(source)
}

@(test)
test_despawn_return_records_no_route :: proc(t: ^testing.T) {
	verdict := flatten_sim(
		"behavior detect_eat on Snake {\n" +
		"  fn step(self: Snake) -> [Eaten] {\n" +
		"    return [Eaten{cell: self.head}]\n" +
		"  }\n" +
		"}\n" +
		"behavior despawn_eaten on Food {\n" +
		"  fn step(self: Food, eaten: [Eaten]) -> [Despawn] {\n" +
		"    return [Despawn()]\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  eat: [detect_eat, despawn_eaten]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Flatten_Error.None)
	testing.expect_value(t, len(verdict.flat.routes), 1)
	testing.expect_value(t, verdict.flat.routes[0].signal, "Eaten")
	_, despawn_routed := find_route(verdict.flat, "Despawn")
	testing.expect(t, !despawn_routed)
}

@(test)
test_hunt_vacuous_closure_zero_routes :: proc(t: ^testing.T) {
	verdict := flatten_sim(
		"behavior setup on Snake {\n" +
		"  fn step(rng: Rng) -> (Rng, [Spawn]) {\n" +
		"    return (rng, [Spawn( Food{cell: Cell{x: 0, y: 0}} )])\n" +
		"  }\n" +
		"}\n" +
		"behavior seek on Snake {\n" +
		"  fn step(self: Snake) -> Snake {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n" +
		"behavior draw_hunter on Snake {\n" +
		"  fn step(self: Snake) -> [Draw] {\n" +
		"    return [Draw::Rect{at: Vec2{x: 0.0, y: 0.0}, size: Vec2{x: 4.0, y: 4.0}, color: Color::White}]\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  startup: [setup]\n" +
		"  seek: [seek]\n" +
		"  render: [draw_hunter]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Flatten_Error.None)
	testing.expect_value(t, len(verdict.flat.routes), 0)
	testing.expect_value(t, len(verdict.flat.order), 3)
}

@(test)
test_startup_tuple_spawn_records_no_route :: proc(t: ^testing.T) {
	verdict := flatten_sim(
		"behavior setup on Snake {\n" +
		"  fn step(rng: Rng) -> (Rng, [Spawn]) {\n" +
		"    return (rng, [Spawn( Food{cell: Cell{x: 0, y: 0}} )])\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  startup: [setup]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Flatten_Error.None)
	testing.expect_value(t, len(verdict.flat.routes), 0)
}

stub_signal_tuple :: proc() -> Type {
	return tuple_of({engine_type_of(.Rng), list_of(user_type_of("Eaten", .Signal))})
}

orphan_tuple_signal_typed :: proc() -> Typed_Ast {
	env: Type_Env
	env.records = make(map[string]Record_Schema, context.temp_allocator)
	env.enums = make(map[string]Enum_Schema, context.temp_allocator)
	env.terms = make(map[string]Term_Schema, context.temp_allocator)
	env.terms["emit_in_tuple"] = stub_term("emit_in_tuple", emits = stub_signal_tuple())

	pipelines := make([]Pipeline_Node, 1, context.temp_allocator)
	pipelines[0] = pipeline_with("Game", stage_with("eat", "emit_in_tuple"))
	signals := make([]Signal_Node, 1, context.temp_allocator)
	signals[0] = Signal_Node{name = "Eaten"}
	return Typed_Ast{ast = Ast{pipelines = pipelines, signals = signals}, env = env}
}

@(test)
test_closure_rejects_tuple_wrapped_orphan_signal :: proc(t: ^testing.T) {
	verdict := stage_flatten(orphan_tuple_signal_typed())
	testing.expect_value(t, verdict.err, Flatten_Error.Unclosed_Signal)
	testing.expect_value(t, verdict.signal, "Eaten")
}

find_route :: proc(flat: Flattened_Pipeline, signal: string) -> (Signal_Route, bool) {
	for route in flat.routes {
		if route.signal == signal {
			return route, true
		}
	}
	return Signal_Route{}, false
}

has_behavior_consumer :: proc(route: Signal_Route, behavior: string) -> bool {
	for consumer in route.consumers {
		if consumer.behavior == behavior {
			return true
		}
	}
	return false
}
