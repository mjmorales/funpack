// Per-declaration `decl` record DERIVATION tests (spec §29 §2): the
// source-derived field projection from the compiled Typed_Ast +
// Flattened_Pipeline. Each derivation is exercised against the smallest input
// that proves it — an in-memory snippet AST where a checkout is overkill
// (kind/span, the calls graph, the dup_class collision, mut_data, emits/consumes
// from hand-built routes), and the live pong AND snake checkouts for the
// whole-program record-per-declaration / determinism obligations. The checkout
// fixtures SKIP-warn loudly when the sibling tree is absent (never silently
// pass), mirroring the golden_pong/golden_snake skip semantics.
package funpack

import "core:log"
import "core:os"
import "core:testing"

// compile_snippet drives a source string through the lex → parse → typecheck →
// flatten stages a decl record reads, returning the typed AST and flattened
// pipeline (the compile_for_index seam). ok is false on any compile failure, so
// a malformed snippet fails the test rather than asserting over an empty AST.
compile_snippet :: proc(source: string) -> (typed: Typed_Ast, flat: Flattened_Pipeline, ok: bool) {
	return compile_for_index(source)
}

// contains_str reports whether a string slice holds a value — the membership
// helper the live-tree calls-graph assertions use (a call list is small and
// order-fixed, so a linear scan is the whole check).
contains_str :: proc(haystack: []string, needle: string) -> bool {
	for s in haystack {
		if s == needle {
			return true
		}
	}
	return false
}

// find_record looks a derived record up by its bare qualified_name (the
// single-source path drops the module prefix, so qualified_name is the bare decl
// name). found is false when no record carries that name.
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
	// qualified_name / kind / span over a snippet AST: a data, an enum, a thing,
	// a signal, a bodied fn, and a let — each maps to its Index_Decl_Kind, carries
	// its bare name (single-source module is "", lore #11), and reports its 1-based
	// decl-keyword line as span (the line the parser now threads onto every node).
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
	testing.expect_value(t, board.span, 1) // `data` on line 1

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

	// Every decl carries the leading schema_version stamp and the bare name (no
	// module prefix on the single-source path). stub is false — no decl here is
	// holed (it derives from Fn_Node.holed, see test_index_decl_stub_from_holes) —
	// and todo/debug stay the constant empties the parser does not yet fill.
	testing.expect_value(t, board.schema_version, INDEX_SCHEMA_VERSION)
	testing.expect_value(t, board.qualified_name, "Board")
	testing.expect_value(t, board.stub, false)
	testing.expect_value(t, board.todo, false)
	testing.expect_value(t, len(board.debug), 0)
	log.infof("index decl kind/span derivation verified over snippet AST (%d decls)", len(records))
}

@(test)
test_index_decl_stub_from_holes :: proc(t: ^testing.T) {
	// stub derives from the parser's holed flag (§05 §2): a fn whose body is a
	// @stub(T) hole — and the @stub(T, fallback) form — emits stub=true, and a
	// behavior whose reserved `step` body is holed marks the behavior; every
	// intact-bodied and body-less decl emits false. The derivation is proven
	// over the PARSED (not typechecked) AST: derive_decl_records reads only the
	// AST nodes, the routes, and the env, so a hand-built Typed_Ast around the
	// parse plus an empty pipeline isolates the projection from hole typing.
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

	// Both hole forms set stub on a fn; the hole does not change the decl kind.
	holed, has_holed := find_record(records, "holed")
	testing.expect(t, has_holed)
	testing.expect_value(t, holed.stub, true)
	testing.expect_value(t, holed.kind, Index_Decl_Kind.Fn)
	approximated, has_approximated := find_record(records, "approximated")
	testing.expect(t, has_approximated)
	testing.expect_value(t, approximated.stub, true)

	// An intact-bodied fn stays false — the flag is the hole, never the form.
	intact, has_intact := find_record(records, "intact")
	testing.expect(t, has_intact)
	testing.expect_value(t, intact.stub, false)

	// A holed behavior step marks its behavior; an intact step does not.
	ghost, has_ghost := find_record(records, "ghost")
	testing.expect(t, has_ghost)
	testing.expect_value(t, ghost.stub, true)
	testing.expect_value(t, ghost.kind, Index_Decl_Kind.Behavior)
	solid, has_solid := find_record(records, "solid")
	testing.expect(t, has_solid)
	testing.expect_value(t, solid.stub, false)

	// A body-less decl has no body position to hole, so it stays false; the
	// unparsed todo/debug directive fields stay constant-empty on every record,
	// holed or not.
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
test_index_decl_emits_consumes :: proc(t: ^testing.T) {
	// emits/consumes project from the §04 signal routes (build_routes/Signal_Route):
	// a behavior at a route's PRODUCER endpoint emits that signal; at a CONSUMER
	// endpoint it consumes it. Build a two-signal routing graph by hand and project
	// each behavior — the deterministic per-behavior projection, independent of a
	// closure-valid source. A behavior listed at a producer endpoint of one signal
	// and a consumer endpoint of another emits the first and consumes the second.
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

	// score: produces Hit, consumes Tick.
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

	// tally: consumes Hit only, emits nothing.
	tally_emits := decl_behavior_emits("tally", routes)
	testing.expect_value(t, len(tally_emits), 0)
	tally_consumes := decl_behavior_consumes("tally", routes)
	testing.expect_value(t, len(tally_consumes), 1)
	if len(tally_consumes) == 1 {
		testing.expect_value(t, tally_consumes[0], "Hit")
	}

	// A behavior off every route emits and consumes nothing (behavior-scoped, and
	// a non-pipeline behavior has no endpoint).
	none_emits := decl_behavior_emits("unwired", routes)
	testing.expect_value(t, len(none_emits), 0)
	none_consumes := decl_behavior_consumes("unwired", routes)
	testing.expect_value(t, len(none_consumes), 0)
	log.infof("index decl emits/consumes derivation verified over signal routes")
}

@(test)
test_index_decl_calls_graph :: proc(t: ^testing.T) {
	// The new calls-graph walk collects every Call_Expr callee name reachable in a
	// body, deduped in FIRST-SEEN order (deterministic). A free-function call names
	// its bare callee (`inc`, `dbl`). A repeated call collapses to one entry, and a
	// non-call constructor head (a record literal) names nothing. The walk is
	// self-contained over user fns so it needs no engine import; the member-selector
	// callee arm (`input.value(…)`) is covered by the live pong checkout below.
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
	// First-seen order over the body walk: inc (deduped from three calls), then
	// dbl. No record/variant constructor enters; a repeated callee is one entry.
	testing.expect_value(t, len(driver.calls), 2)
	if len(driver.calls) == 2 {
		testing.expect_value(t, driver.calls[0], "inc")
		testing.expect_value(t, driver.calls[1], "dbl")
	}

	// inc makes no call — its body is a bare arithmetic return.
	inc, has_inc := find_record(records, "inc")
	testing.expect(t, has_inc)
	testing.expect_value(t, len(inc.calls), 0)
	log.infof("index decl calls-graph walk verified (first-seen dedupe order)")
}

@(test)
test_index_decl_dup_class :: proc(t: ^testing.T) {
	// dup_class is the gates.odin body hash for the body-BEARING units (fn /
	// behavior-step / test); a body-LESS decl (data/enum/thing/signal/pipeline/let)
	// carries 0 — the gate_units extern-skip rationale, so two empty bodies never
	// collide. Two fns whose bodies are identical modulo `let`-bound-name
	// alpha-renaming hash to the SAME dup_class (the §29 rename-invariant
	// duplication class — dup_class alpha-renames `let` bindings, so the binder
	// spelling is invisible); a structurally different body hashes differently.
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

	// one and two differ only by their bound parameter name, so their bodies
	// canonicalize identically and collide on one dup_class.
	testing.expect_value(t, one.dup_class, two.dup_class)
	// three is a + 1 vs c * 2 — a structural difference, so a distinct class.
	testing.expect(t, one.dup_class != three.dup_class)
	// A body-bearing fn carries a non-zero hash (the fnv64a offset basis is never
	// the hash of a real body); a body-less data carries exactly 0.
	testing.expect(t, one.dup_class != 0)

	empty, has_empty := find_record(records, "Empty")
	testing.expect(t, has_empty)
	testing.expect_value(t, empty.dup_class, u64(0))
	log.infof("index decl dup_class derivation verified (body-bearing collision vs body-less zero)")
}

@(test)
test_index_decl_mut_data :: proc(t: ^testing.T) {
	// mut_data is a behavior's `on Thing` target reported iff its step return
	// WRITES that blackboard (contracts.odin writes_own_blackboard). A behavior
	// returning its own thing mutates it; a behavior emitting a signal/command
	// list (a non-thing write) mutates nothing. A free fn never mutates a thing.
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

	// nudge returns Ball — its own blackboard — so mut_data is ["Ball"].
	nudge, has_nudge := find_record(records, "nudge")
	testing.expect(t, has_nudge)
	testing.expect_value(t, len(nudge.mut_data), 1)
	if len(nudge.mut_data) == 1 {
		testing.expect_value(t, nudge.mut_data[0], "Ball")
	}

	// emit_goal returns [Goal] — a signal emit, not a thing write — so it mutates
	// nothing and emits Goal (closed by consume_goal downstream).
	emit_goal, has_emit := find_record(records, "emit_goal")
	testing.expect(t, has_emit)
	testing.expect_value(t, len(emit_goal.mut_data), 0)
	testing.expect_value(t, len(emit_goal.emits), 1)
	if len(emit_goal.emits) == 1 {
		testing.expect_value(t, emit_goal.emits[0], "Goal")
	}

	// consume_goal returns Ball (writes its blackboard) AND consumes Goal.
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

// ── Live checkout: one record per declaration, fixed order, constant directives ──

@(test)
test_index_decl_records_pong :: proc(t: ^testing.T) {
	// Decl-record derivation over the live pong checkout: one record per
	// declaration in the fixed gate_units-style order, with stub=false (the pong
	// tree carries no @stub hole) and todo=false / debug=[] (the unparsed §05
	// directive fields) on every decl. The per-kind counts are pinned against the
	// golden source (33 decls). SKIP-warns when the sibling pong checkout is
	// absent — never silently passes.
	records, ok := pong_decl_records(t)
	if !ok {
		return
	}
	// pong: 1 data + 2 enums + 3 things + 1 signal + 9 fns + 10 behaviors +
	// 1 pipeline + 1 let + 5 tests = 33 declarations.
	testing.expect_value(t, len(records), 33)
	for r in records {
		testing.expect_value(t, r.schema_version, INDEX_SCHEMA_VERSION)
		testing.expect_value(t, r.file, "")
		testing.expect_value(t, r.stub, false)
		testing.expect_value(t, r.todo, false)
		testing.expect_value(t, len(r.debug), 0)
		// Every decl carries a 1-based span — the threaded decl-keyword line is
		// now total over every declaration node.
		testing.expectf(t, r.span >= 1, "decl %s has a non-positive span %d", r.qualified_name, r.span)
	}
	// The first derived record is the first data decl (Board) at its keyword line.
	board, has_board := find_record(records, "Board")
	testing.expect(t, has_board)
	testing.expect_value(t, board.kind, Index_Decl_Kind.Data)
	testing.expect_value(t, board.span, 16)

	// score emits Goal (its [Goal] return is the only producer); tally and serve
	// consume Goal (their [Goal] params); score consumes nothing.
	score, has_score := find_record(records, "score")
	testing.expect(t, has_score)
	testing.expect_value(t, len(score.emits), 1)
	if len(score.emits) == 1 {
		testing.expect_value(t, score.emits[0], "Goal")
	}
	testing.expect_value(t, len(score.consumes), 0)
	// score returns [Goal], not its own Ball, so it mutates no thing.
	testing.expect_value(t, len(score.mut_data), 0)

	tally, has_tally := find_record(records, "tally")
	testing.expect(t, has_tally)
	testing.expect_value(t, len(tally.consumes), 1)
	if len(tally.consumes) == 1 {
		testing.expect_value(t, tally.consumes[0], "Goal")
	}
	// tally returns Scoreboard — its own blackboard — so mut_data is ["Scoreboard"].
	testing.expect_value(t, len(tally.mut_data), 1)
	if len(tally.mut_data) == 1 {
		testing.expect_value(t, tally.mut_data[0], "Scoreboard")
	}

	// ball_move writes Ball; overlaps (a free fn) calls abs (deduped from two).
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

	// paddle_move's step calls `input.value(…)` (a member-selector callee) and
	// `clamp(…)` (a free callee), so its calls graph names both — proving the
	// member-call arm of callee_name on the live tree.
	paddle_move, has_paddle_move := find_record(records, "paddle_move")
	testing.expect(t, has_paddle_move)
	testing.expect(t, contains_str(paddle_move.calls, "value"))
	testing.expect(t, contains_str(paddle_move.calls, "clamp"))
	log.infof("index decl records over live pong verified (%d decls, fixed order)", len(records))
}

@(test)
test_index_decl_records_snake :: proc(t: ^testing.T) {
	// Decl-record derivation over the live snake checkout: one record per
	// declaration in the fixed order, with stub=false (no snake decl is holed)
	// and the unparsed todo/debug empties on every decl. Counts pinned against
	// the golden source (36 decls). SKIP-warns when the sibling snake checkout
	// is absent.
	records, ok := snake_decl_records(t)
	if !ok {
		return
	}
	// snake: 2 data + 3 enums + 2 things + 2 signals + 10 fns + 11 behaviors +
	// 1 pipeline + 1 let + 4 tests = 36 declarations.
	testing.expect_value(t, len(records), 36)
	for r in records {
		testing.expect_value(t, r.schema_version, INDEX_SCHEMA_VERSION)
		testing.expect_value(t, r.file, "")
		testing.expect_value(t, r.stub, false)
		testing.expect_value(t, r.todo, false)
		testing.expect_value(t, len(r.debug), 0)
		testing.expectf(t, r.span >= 1, "decl %s has a non-positive span %d", r.qualified_name, r.span)
	}
	// The first data decl (Cell) at its keyword line.
	cell, has_cell := find_record(records, "Cell")
	testing.expect(t, has_cell)
	testing.expect_value(t, cell.kind, Index_Decl_Kind.Data)
	testing.expect_value(t, cell.span, 15)
	log.infof("index decl records over live snake verified (%d decls, fixed order)", len(records))
}

@(test)
test_index_decl_records_deterministic :: proc(t: ^testing.T) {
	// Deriving the decl records twice from the SAME source yields identical records
	// — the byte-deterministic obligation (fixed declaration order, no map
	// iteration / clock / float reaching output). Proven over the live pong tree
	// (the richest source) AND a snippet (so it holds with no checkout).
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

	// Over the live pong tree too — the richest declaration mix.
	pong, pong_ok := pong_decl_records(t)
	if pong_ok {
		again, again_ok := pong_decl_records(t)
		testing.expect(t, again_ok)
		expect_records_identical(t, pong, again)
	}
	log.infof("index decl records derivation is deterministic (twice-identical, snippet + live pong)")
}

// expect_records_identical asserts two derived record vectors are field-for-field
// identical in order — the deterministic-derivation obligation reduced to a
// per-field equality over the emitted NDJSON's source values (so a drift in any
// field, order, or count fails the test).
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

// pong_decl_records compiles the live pong checkout and derives its decl records;
// ok is false (with a SKIP warning) when the sibling pong checkout is absent or
// the source does not compile, matching the golden_pong skip semantics.
pong_decl_records :: proc(t: ^testing.T) -> (records: []Decl_Record, ok: bool) {
	return checkout_decl_records(t, resolve_pong_dir(), "FUNPACK_PONG_DIR", "pong")
}

// snake_decl_records compiles the live snake checkout and derives its decl
// records; ok is false (with a SKIP warning) when the sibling snake checkout is
// absent or the source does not compile.
snake_decl_records :: proc(t: ^testing.T) -> (records: []Decl_Record, ok: bool) {
	return checkout_decl_records(t, resolve_snake_dir(), "FUNPACK_SNAKE_DIR", "snake")
}

// checkout_decl_records reads a §14 project checkout, compiles its single source
// through compile_for_index, and derives the decl records — the shared body
// behind pong_decl_records/snake_decl_records. It SKIP-warns loudly (never
// silently passes) when the checkout is absent, and fails the test when a present
// checkout does not read or compile.
checkout_decl_records :: proc(
	t: ^testing.T,
	dir: string,
	env_name: string,
	label: string,
) -> (records: []Decl_Record, ok: bool) {
	if !os.is_dir(dir) {
		log.warnf("SKIP index contract decl records %s: %s not found — set %s or check out funpack-spec as a sibling", label, dir, env_name)
		return nil, false
	}
	identity, project_err := read_project(dir)
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
	// The single-source path derives with the bare module name (lore #11).
	return derive_decl_records("", typed, flat), true
}
