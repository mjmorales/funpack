// The §04/§08/§10/§23 sim-typing fixtures: the RNG-threaded tuple return and
// match-destructure (snake's pick draw), the §08 read-side View combinators
// (map/filter/concat/contains/prepend over a View and a List), the §10 Fixed
// countdown and divide-ratio (hunt's step_to / seek), and the §23 §2 Input query
// over a USER Button enum. Each fixture is a small self-contained source over a
// snake/hunt-shaped header, so a missing golden checkout never silences the
// proofs; the live goldens land in the final story. The negative fixtures pin
// that the new surface admits no implicit Int→Fixed promotion and rejects a
// malformed combinator/tuple shape.
package funpack

import "core:strings"
import "core:testing"

// SIM_HEADER declares a snake-shaped surface independent of the golden checkout:
// a Cell value, a Snake thing carrying a [Cell] body and a Fixed countdown, a
// Food thing for the View, an Eaten signal, and the engine imports the sim
// behaviors read — the §08 View read table, the §04 Spawn/Despawn commands, the
// engine.rand Rng + pick draw, and the list combinators. A fixture appends one
// fn/behavior body and types the whole source.
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

// -- (a) Tuple typing end-to-end --------------------------------------------

@(test)
test_tuple_return_checks_against_declared_pair :: proc(t: ^testing.T) {
	// AC (tuple return): a behavior declaring the §04 §1 RNG-threaded pair
	// `(Rng, [Spawn])` and returning a tuple of an Rng and a [Spawn] list checks
	// position by position against that declared return — the structural tuple
	// compatibility arm in types_compatible.
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
	// AC (tuple positional unification): a tuple return whose first position is a
	// [Spawn] where the declared pair wants an Rng rejects — the tuple arm unifies
	// positions, so a swapped pair is a Type_Mismatch, not silently accepted.
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
	// AC (tuple match-destructure + pick's (Option[Cell], Rng)): matching the
	// pick draw binds `cell` to the option's element (Cell) and `next` to the
	// second tuple position (Rng); each arm returns the declared (Rng, [Spawn])
	// pair. This is the snake `replenish`/`setup` shape end to end — pick typed,
	// its tuple destructured, the binders used in the arm bodies.
	err := typecheck_sim(
		"behavior replenish on Snake {\n" +
		"  fn step(self: Snake, rng: Rng) -> (Rng, [Spawn]) {\n" +
		"    let free = filter(all_cells(), fn(c) { return not contains(cells(self), c) })\n" +
		"    return match pick(free, rng) {\n" +
		"      (Option::Some(cell), next) => (next, [Spawn( Food{cell: cell} )])\n" +
		"      (Option::None, next) => (next, [])\n" +
		"    }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

// -- (b) pick's RNG-threaded draw signature ---------------------------------

@(test)
test_pick_returns_option_element_and_rng :: proc(t: ^testing.T) {
	// AC (pick typing): pick(list, rng) over a [Cell] yields the pair
	// (Option[Cell], Rng) — destructured here and the option element bound to a
	// Cell, written into a Food spawn. A binder typed wrong (cell used as an Rng)
	// would reject downstream; this asserts the happy destructure types clean.
	err := typecheck_sim(
		"fn draw_one(rng: Rng) -> (Rng, [Spawn]) {\n" +
		"  return match pick(all_cells(), rng) {\n" +
		"    (Option::Some(cell), next) => (next, [Spawn( Food{cell: cell} )])\n" +
		"    (Option::None, next) => (next, [])\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_pick_second_arg_must_be_rng :: proc(t: ^testing.T) {
	// AC (pick arity/type): pick's second argument is the threaded Rng handle, not
	// a list — passing a second list rejects, so the draw signature is real, not a
	// wildcard.
	err := typecheck_sim(
		"fn bad_pick() -> Bool {\n" +
		"  return match pick(all_cells(), all_cells()) {\n" +
		"    (Option::Some(cell), next) => true\n" +
		"    (Option::None, next) => false\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

// -- (c) Read-side View combinators -----------------------------------------

@(test)
test_view_map_yields_list_of_lambda_result :: proc(t: ^testing.T) {
	// AC (View map): map over a View[Food] with fn(f) -> Cell yields [Cell] —
	// `map(foods, fn(f){ f.cell })`. The result element is the lambda's result
	// type, written here into a [Cell]-returning fn.
	err := typecheck_sim(
		"fn food_cells(foods: View[Food]) -> [Cell] {\n" +
		"  return map(foods, fn(f) { return f.cell })\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_view_filter_yields_list_of_element :: proc(t: ^testing.T) {
	// AC (View filter): filter over a View[Food] with a (Food) -> Bool predicate
	// yields a [Food] list (a filtered View is a list of the element). The result
	// is mapped to its cell to land a [Cell].
	err := typecheck_sim(
		"fn eaten_cells(foods: View[Food], head: Cell) -> [Cell] {\n" +
		"  return map(filter(foods, fn(f) { return f.cell == head }), fn(f) { return f.cell })\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_concat_joins_two_lists_of_same_element :: proc(t: ^testing.T) {
	// AC (concat): concat of two [Cell] lists yields a [Cell] — the snake
	// `occupied` shape concat(cells(snake), map(foods, …)). The element types
	// unify across the two sides.
	err := typecheck_sim(
		"fn occupied(snake: Snake, foods: View[Food]) -> [Cell] {\n" +
		"  return concat(cells(snake), map(foods, fn(f) { return f.cell }))\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_contains_and_prepend_over_list_element :: proc(t: ^testing.T) {
	// AC (contains + prepend): contains([Cell], Cell) yields Bool and
	// prepend(Cell, [Cell]) yields [Cell] — the element type unifies in both. The
	// `not` over the contains result types as Bool, the if-guard condition.
	err := typecheck_sim(
		"fn cons(snake: Snake, c: Cell) -> [Cell] {\n" +
		"  if not contains(snake.body, c) { return prepend(c, snake.body) }\n" +
		"  return snake.body\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_is_empty_over_signal_list_yields_bool :: proc(t: ^testing.T) {
	// AC (is_empty): is_empty over an inbound [Eaten] signal list yields Bool —
	// the snake `grow`/`apply_death` guard. The element type is irrelevant; only
	// that the source is a read source.
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
	// AC (combinator element unification): contains([Cell], Fixed) rejects — the
	// value's type must unify with the list's element, so a Fixed against a [Cell]
	// is a Type_Mismatch, proving the element type is real.
	err := typecheck_sim(
		"fn bad_contains(snake: Snake) -> Bool {\n" +
		"  return contains(snake.body, 1.0)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

// -- §04 Despawn: zero-arg self-scoped command ------------------------------

@(test)
test_despawn_zero_arg_command_typechecks :: proc(t: ^testing.T) {
	// AC (§04 Despawn): Despawn() takes no argument — it despawns the behavior's
	// own target thing — so an Update behavior returning [Despawn()] types clean.
	// This is snake's despawn_eaten shape (a Food behavior emitting [Despawn]).
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
	// AC (§04 Despawn arity): Despawn takes ZERO arguments (its param list is
	// empty), so passing one — Despawn(self.cell) — arity-mismatches and rejects
	// with Type_Mismatch. The zero-length signature is real, not variadic; this is
	// the negative the surface watch-item calls for (a Spawn-shaped command that
	// must NOT accept an argument).
	err := typecheck_sim(
		"behavior despawn_eaten on Food {\n" +
		"  fn step(self: Food, eaten: [Eaten]) -> [Despawn] {\n" +
		"    return [Despawn(self.cell)]\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

// -- (e) Fixed countdown + divide-ratio scaling -----------------------------

@(test)
test_fixed_divide_ratio_scales_vector :: proc(t: ^testing.T) {
	// AC (§10 §1-2, §13 §2): a Fixed/Fixed ratio types as Fixed and a Vec2 scaled
	// by it stays a Vec2 — hunt's step_to `delta * (speed / d)`. The divide admits
	// Fixed/Fixed → Fixed (the saturate-on-zero is the evaluator's lowering, not
	// typing).
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
	// AC (§13 §2 countdown): the search timer countdown `self.search_t - dt` is a
	// Fixed minus a Fixed → Fixed, compared against a Fixed literal and written
	// back to the Fixed field — hunt's seek. No implicit promotion is needed since
	// both sides are already Fixed.
	err := typecheck_sim(
		"fn seek(self: Snake, dt: Fixed) -> Snake {\n" +
		"  let next = self.search_t - dt\n" +
		"  if next <= 0.0 { return self with { search_t: 0.0 } }\n" +
		"  return self with { search_t: next }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

// -- (f) Input.pressed query over a user Button enum -------------------------

// SIM_INPUT_HEADER is the §23 §2 input fixture surface: a Walker thing whose
// behavior reads the Input resource, with a user Button-kinded action enum the
// nil action-role param unifies with — the snake `dir_from_input` shape (an
// Input.pressed query keyed by a user Move:Button variant).
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
	// AC (§23 §2 + §02 bool): Input.pressed(PlayerId::P1, Move::Up) lands Bool —
	// the user Move:Button variant unifies with the query's nil action-role param,
	// and the result is consumed as an `and`-joined if-guard condition. The `not`
	// guard and the bool literal comparison ride the same surface.
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

// -- (d) No implicit Int→Fixed promotion over the new surface ----------------

@(test)
test_int_times_fixed_without_to_fixed_rejected :: proc(t: ^testing.T) {
	// AC (no implicit promotion): an Int field times a Fixed literal without the
	// explicit to_fixed lift rejects with Type_Mismatch — Cell.x is Int, `8.0` is
	// Fixed, and there is no implicit Int→Fixed (§10). The cure is `to_fixed(c.x)
	// * 8.0`, the snake cell_rect bridge.
	err := typecheck_sim(
		"fn bad_scale(c: Cell) -> Fixed {\n" +
		"  return c.x * 8.0\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_to_fixed_bridges_int_to_fixed :: proc(t: ^testing.T) {
	// The positive control: the explicit to_fixed(c.x) * 8.0 bridge types clean —
	// proof the negative above rejects for the missing lift, not an incidental
	// header gap. to_fixed lands a Fixed, and Fixed * Fixed is Fixed.
	err := typecheck_sim(
		"fn good_scale(c: Cell) -> Fixed {\n" +
		"  return to_fixed(c.x) * 8.0\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_int_compared_to_fixed_rejected :: proc(t: ^testing.T) {
	// AC (no implicit promotion in equality): an Int compared to a Fixed rejects —
	// equality demands same-typed sides (§10), so Cell.x (Int) == a Fixed literal
	// is a Type_Mismatch even over the new combinator/View surface.
	err := typecheck_sim(
		"fn bad_eq(c: Cell) -> Bool {\n" +
		"  return c.x == 8.0\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}
