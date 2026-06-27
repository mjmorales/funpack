package funpack

import "core:strings"
import "core:testing"

SIM_HEADER :: "import engine.math.{Fixed, Vec2, to_fixed, length}\n" +
	"import engine.world.{View, Spawn, Despawn}\n" +
	"import engine.rand.{Rng, pick}\n" +
	"import engine.list.{prepend, init, contains, map, filter, concat, is_empty}\n" +
	"data Cell { x: Int, y: Int }\n" +
	"thing Snake { head: Cell = Cell{x: 0, y: 0}, body: [Cell] = [], search_t: Fixed = 0.0 }\n" +
	"thing Food { cell: Cell }\n" +
	"signal Eaten { cell: Cell }\n" +
	"fn cells(snake: Snake) -> [Cell] { return prepend(snake.head, snake.body) }\n" +
	"fn all_cells() -> [Cell] { return [] }\n"

typecheck_sim :: proc(body: string) -> Type_Error {
	source := strings.concatenate({SIM_HEADER, body}, context.temp_allocator)
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .Unsupported_Expr
	}
	_, err := stage_typecheck(ast)
	return err
}

@(test)
test_tuple_return_checks_against_declared_pair :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"behavior place on Snake {\n" +
		"  fn step(self: Snake, rng: Rng) -> (Rng, [Spawn]) {\n" +
		"    return (rng, [Spawn( Food{cell: self.head} )])\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_tuple_return_wrong_position_rejected :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"behavior place on Snake {\n" +
		"  fn step(self: Snake, rng: Rng) -> (Rng, [Spawn]) {\n" +
		"    return ([Spawn( Food{cell: self.head} )], rng)\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_tuple_match_destructures_pick_pair :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"behavior replenish on Snake {\n" +
		"  fn step(self: Snake, rng: Rng) -> (Rng, [Spawn]) {\n" +
		"    let free = filter(all_cells(), fn(c) { return not contains(cells(self), c) })\n" +
		"    return match rng.pick(free) {\n" +
		"      (Option::Some(cell), next) => (next, [Spawn( Food{cell: cell} )])\n" +
		"      (Option::None, next) => (next, [])\n" +
		"    }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_pick_returns_option_element_and_rng :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"fn draw_one(rng: Rng) -> (Rng, [Spawn]) {\n" +
		"  return match pick(rng, all_cells()) {\n" +
		"    (Option::Some(cell), next) => (next, [Spawn( Food{cell: cell} )])\n" +
		"    (Option::None, next) => (next, [])\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_pick_receiver_must_be_rng :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"fn bad_pick() -> Bool {\n" +
		"  return match pick(all_cells(), all_cells()) {\n" +
		"    (Option::Some(cell), next) => true\n" +
		"    (Option::None, next) => false\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_view_map_yields_list_of_lambda_result :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"fn food_cells(foods: View[Food]) -> [Cell] {\n" +
		"  return map(foods, fn(f) { return f.cell })\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_view_filter_yields_list_of_element :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"fn eaten_cells(foods: View[Food], head: Cell) -> [Cell] {\n" +
		"  return map(filter(foods, fn(f) { return f.cell == head }), fn(f) { return f.cell })\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_concat_joins_two_lists_of_same_element :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"fn occupied(snake: Snake, foods: View[Food]) -> [Cell] {\n" +
		"  return concat(cells(snake), map(foods, fn(f) { return f.cell }))\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_contains_and_prepend_over_list_element :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"fn cons(snake: Snake, c: Cell) -> [Cell] {\n" +
		"  if not contains(snake.body, c) { return prepend(c, snake.body) }\n" +
		"  return snake.body\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_is_empty_over_signal_list_yields_bool :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"behavior grow on Snake {\n" +
		"  fn step(self: Snake, eaten: [Eaten]) -> Snake {\n" +
		"    if is_empty(eaten) { return self }\n" +
		"    return self\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_contains_wrong_element_type_rejected :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"fn bad_contains(snake: Snake) -> Bool {\n" +
		"  return contains(snake.body, 1.0)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_despawn_zero_arg_command_typechecks :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"behavior despawn_eaten on Food {\n" +
		"  fn step(self: Food, eaten: [Eaten]) -> [Despawn] {\n" +
		"    if is_empty(eaten) { return [] }\n" +
		"    return [Despawn()]\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_despawn_with_argument_rejected :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"behavior despawn_eaten on Food {\n" +
		"  fn step(self: Food, eaten: [Eaten]) -> [Despawn] {\n" +
		"    return [Despawn(self.cell)]\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_fixed_divide_ratio_scales_vector :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"fn step_to(from: Vec2, to: Vec2, speed: Fixed) -> Vec2 {\n" +
		"  let delta = to - from\n" +
		"  let d = length(delta)\n" +
		"  if d <= speed { return to }\n" +
		"  return from + delta * (speed / d)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_fixed_countdown_folds_by_dt :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"fn seek(self: Snake, dt: Fixed) -> Snake {\n" +
		"  let next = self.search_t - dt\n" +
		"  if next <= 0.0 { return self with { search_t: 0.0 } }\n" +
		"  return self with { search_t: next }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

SIM_INPUT_HEADER :: "import engine.math.{Vec2}\n" +
	"import engine.input.{Input, PlayerId}\n" +
	"thing Walker { dir: Vec2 }\n" +
	"enum Move: Button { Up, Down }\n"

typecheck_sim_input :: proc(body: string) -> Type_Error {
	source := strings.concatenate({SIM_INPUT_HEADER, body}, context.temp_allocator)
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .Unsupported_Expr
	}
	_, err := stage_typecheck(ast)
	return err
}

@(test)
test_input_pressed_over_user_button_enum :: proc(t: ^testing.T) {
	err := typecheck_sim_input(
		"behavior turn on Walker {\n" +
		"  fn step(self: Walker, input: Input) -> Walker {\n" +
		"    if input.pressed(PlayerId::P1, Move::Up) and not input.pressed(PlayerId::P1, Move::Down) {\n" +
		"      return self\n" +
		"    }\n" +
		"    return self\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_int_times_fixed_without_to_fixed_rejected :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"fn bad_scale(c: Cell) -> Fixed {\n" +
		"  return c.x * 8.0\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_to_fixed_bridges_int_to_fixed :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"fn good_scale(c: Cell) -> Fixed {\n" +
		"  return to_fixed(c.x) * 8.0\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_int_compared_to_fixed_rejected :: proc(t: ^testing.T) {
	err := typecheck_sim(
		"fn bad_eq(c: Cell) -> Bool {\n" +
		"  return c.x == 8.0\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

LAST_HEADER :: "import engine.prelude.{Option, or_else}\n" +
	"import engine.list.last\n" +
	"data Cell { x: Int, y: Int }\n"

@(test)
test_last_types_and_evaluates :: proc(t: ^testing.T) {
	typed_source := LAST_HEADER +
		"fn route_end(steps: [Cell], fallback: Cell) -> Cell {\n" +
		"  return or_else(last(steps), fallback)\n" +
		"}\n"
	typed_ast, typed_parse := stage_parse(stage_lex(typed_source))
	testing.expect_value(t, typed_parse, Parse_Error.None)
	_, typed_err := stage_typecheck(typed_ast)
	testing.expect_value(t, typed_err, Type_Error.None)

	arity_source := LAST_HEADER +
		"fn bad(steps: [Cell]) -> Bool {\n" +
		"  return last(steps, fn(c) { return true })\n" +
		"}\n"
	arity_ast, arity_parse := stage_parse(stage_lex(arity_source))
	testing.expect_value(t, arity_parse, Parse_Error.None)
	_, arity_err := stage_typecheck(arity_ast)
	testing.expect_value(t, arity_err, Type_Error.Type_Mismatch)

	report, err := run_test_pipeline(LAST_HEADER +
		"test \"last reads the final element, None when empty\" {\n" +
		"  assert last([Cell{x: 1, y: 0}, Cell{x: 2, y: 0}]) == Option::Some(Cell{x: 2, y: 0})\n" +
		"  assert last([]) == Option::None\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}
