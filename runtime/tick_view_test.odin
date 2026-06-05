// Mid-tick View read consistency (spec §08-state.md: "within a tick the
// population is fixed while blackboard writes fold forward, so a mid-tick query
// sees a stable set of rows with EVOLVING COLUMNS"; §07-pipelines.md §4:
// "Blackboard writes fold forward — a stage sees every earlier stage's writes").
//
// A behavior's View[Other] param must observe the tick's WORKING rows, so a
// later stage reads the SAME-TICK blackboard writes of an earlier stage (evolving
// columns) — NOT the prior committed version's columns. Population stays fixed:
// a Spawn queued mid-tick is invisible to a later stage's same-tick View; it is
// first queryable next tick (spawns/despawns land only at the boundary).
//
// These tests pin both clauses on a SYNTHETIC descriptor-driven program (two
// things, three stages) rather than the golden pong pair, because pong has no
// behavior that both writes a thing's column AND is read cross-thing through a
// View in a strictly later stage — the synthetic fixture isolates the exact
// read-order the clauses constrain.
package funpack_runtime

import "core:strconv"
import "core:testing"

// A later stage's View[Writer] observes an earlier stage's SAME-TICK column write
// (evolving columns, §08 / §07 §4): stage `bump` rewrites every Writer's `mark`
// from the spawned 0 to 7, then stage `observe` (a DIFFERENT thing, Reader) folds
// View[Writer] and stores the sum of the marks it saw. The sum is 7 (the bumped
// value), proving Reader read the working column, not the tick-start 0.
@(test)
test_view_sees_earlier_stage_same_tick_write :: proc(t: ^testing.T) {
	program := build_writer_reader_program(context.temp_allocator)
	world := new_world(program, context.temp_allocator)
	base := run_startup(&program, initial_version(world, context.temp_allocator), context.temp_allocator)

	// Setup spawned one Writer (mark 0) and one Reader (mark_sum 0, population 0).
	writer, writer_ok := view_at(view_of_type(&base, "Writer"), 0)
	testing.expect(t, writer_ok)
	mark0, _ := row_field(writer, "mark")
	testing.expect_value(t, mark0.(i64), i64(0))

	next := step_tick(&program, base, empty(), tick_time(context.temp_allocator), context.temp_allocator)

	// `bump` ran before `observe`: the committed Writer carries the bumped mark 7.
	bumped, _ := view_at(view_of_type(&next, "Writer"), 0)
	bumped_mark, _ := row_field(bumped, "mark")
	testing.expect_value(t, bumped_mark.(i64), i64(7))

	// Reader's View[Writer] saw the SAME-TICK write: mark_sum is the bumped 7, not
	// the tick-start 0 — the evolving-column clause.
	reader, _ := view_at(view_of_type(&next, "Reader"), 0)
	mark_sum, _ := row_field(reader, "mark_sum")
	testing.expect_value(t, mark_sum.(i64), i64(7))
}

// Population is fixed within a tick (§07 §4): a Spawn queued by an earlier stage
// is INVISIBLE to a later stage's same-tick View, and first queryable next tick.
// Stage `grow` queues a second Writer; stage `observe` folds View[Writer] and
// stores the count it saw. The count is 1 this tick (the spawn has not landed),
// and the Writer table holds 2 rows only on the NEXT tick.
@(test)
test_view_population_fixed_mid_tick_spawn_invisible :: proc(t: ^testing.T) {
	program := build_writer_reader_program(context.temp_allocator)
	world := new_world(program, context.temp_allocator)
	base := run_startup(&program, initial_version(world, context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, view_count(view_of_type(&base, "Writer")), 1)

	tick0 := step_tick(&program, base, empty(), tick_time(context.temp_allocator), context.temp_allocator)

	// Reader's View saw ONE Writer this tick — the spawn `grow` queued is invisible
	// (population fixed); the queued row lands only at the tick boundary.
	reader, _ := view_at(view_of_type(&tick0, "Reader"), 0)
	population, _ := row_field(reader, "population")
	testing.expect_value(t, population.(i64), i64(1))

	// The spawned Writer is committed: next tick the table holds 2 rows, so it is
	// first queryable one tick after it was queued.
	testing.expect_value(t, view_count(view_of_type(&tick0, "Writer")), 2)

	// Next tick, Reader's View now sees BOTH Writers — the spawn became visible at
	// the boundary, exactly one tick late.
	tick1 := step_tick(&program, tick0, empty(), tick_time(context.temp_allocator), context.temp_allocator)
	reader1, _ := view_at(view_of_type(&tick1, "Reader"), 0)
	population1, _ := row_field(reader1, "population")
	testing.expect_value(t, population1.(i64), i64(2))
}

// --- synthetic two-thing, three-stage program fixture ---------------------

// tick_time is the Time resource a synthetic behavior's `time` param binds to —
// a single dt field at the fixed 60hz step, derived through the kernel (no float).
// These behaviors do not read dt, but step_tick passes the resource regardless.
@(private = "file")
tick_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

// build_writer_reader_program builds the synthetic program these tests fold: two
// things (Writer with an Int `mark`, Reader with Int `mark_sum`/`population`),
// three interior stages in one total order — `bump` (stage 1) rewrites a Writer's
// mark, `grow` (stage 2) queues a second Writer via a [Spawn] emit, `observe`
// (stage 3) reads View[Writer] and folds the marks/count into the Reader's
// blackboard. The two fold combiners (add_mark, inc) are §9 helpers the Reader
// body names. Setup spawns one Writer (mark 0) and one Reader (zeroed).
@(private = "file")
build_writer_reader_program :: proc(allocator := context.allocator) -> Program {
	things := make([]Thing_Decl, 2, allocator)
	things[0] = Thing_Decl {
		name = "Writer",
		fields = int_fields(allocator, "mark"),
	}
	things[1] = Thing_Decl {
		name = "Reader",
		fields = int_fields(allocator, "mark_sum", "population"),
	}

	functions := make([]Function_Decl, 2, allocator)
	functions[0] = fold_combiner_fn("add_mark", "w", "mark", allocator) // acc + w.mark
	functions[1] = inc_fn("inc", allocator) // acc + 1

	behaviors := make([]Behavior_Decl, 3, allocator)
	behaviors[0] = bump_behavior(allocator)
	behaviors[1] = grow_behavior(allocator)
	behaviors[2] = observe_behavior(allocator)

	pipeline := make([]Pipeline_Step, 3, allocator)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "s1", behavior = "bump"}
	pipeline[1] = Pipeline_Step{ordinal = 1, stage = "s2", behavior = "grow"}
	pipeline[2] = Pipeline_Step{ordinal = 2, stage = "s3", behavior = "observe"}

	setup := make([]Spawn_Command, 2, allocator)
	setup[0] = Spawn_Command{thing = "Writer", fields = int_spawn_fields(allocator, {"mark", 0})}
	setup[1] = Spawn_Command {
		thing = "Reader",
		fields = int_spawn_fields(allocator, {"mark_sum", 0}, {"population", 0}),
	}

	return Program {
		things = things,
		functions = functions,
		behaviors = behaviors,
		pipeline = pipeline,
		setup = setup,
	}
}

// bump_behavior is stage `bump` on Writer: it writes the Writer's blackboard,
// returning `{ Writer mark: 7 }` so the committed (and mid-tick working) mark
// becomes 7 — the same-tick column write a later stage's View must observe.
@(private = "file")
bump_behavior :: proc(allocator := context.allocator) -> Behavior_Decl {
	params := make([]Param_Decl, 1, allocator)
	params[0] = Param_Decl{name = "self", type = "Writer"}
	emits := make([]string, 1, allocator)
	emits[0] = "Writer"

	body := make([]Node, 1, allocator)
	mark_write := record_node("Writer", allocator, Recfield_Spec{"mark", int_node(7, allocator)})
	body[0] = return_node(mark_write, allocator)
	return Behavior_Decl {
		name = "bump",
		on_thing = "Writer",
		stage = "s1",
		params = params,
		emits = emits,
		body = body,
	}
}

// grow_behavior is stage `grow` on Writer: it emits a [Spawn] of one more Writer
// (mark 0). The queued spawn lands only at the tick boundary, so a later stage's
// View must NOT see it this tick — the population-fixity clause.
@(private = "file")
grow_behavior :: proc(allocator := context.allocator) -> Behavior_Decl {
	params := make([]Param_Decl, 1, allocator)
	params[0] = Param_Decl{name = "self", type = "Writer"}
	emits := make([]string, 1, allocator)
	emits[0] = "[Spawn]"

	// return [ { Writer mark: 0 } ] — a one-element command list.
	spawn_rec := record_node("Writer", allocator, Recfield_Spec{"mark", int_node(0, allocator)})
	list := list_node(allocator, spawn_rec)
	body := make([]Node, 1, allocator)
	body[0] = return_node(list, allocator)
	return Behavior_Decl {
		name = "grow",
		on_thing = "Writer",
		stage = "s2",
		params = params,
		emits = emits,
		body = body,
	}
}

// observe_behavior is stage `observe` on Reader: it reads View[Writer] and folds
// it twice, writing `mark_sum` (sum of the marks it saw) and `population` (count
// of the rows it saw) into the Reader's blackboard. Both folds read the SAME
// mid-tick View, so the test asserts evolving columns (mark_sum) AND fixed
// population (population) off one observation.
@(private = "file")
observe_behavior :: proc(allocator := context.allocator) -> Behavior_Decl {
	params := make([]Param_Decl, 2, allocator)
	params[0] = Param_Decl{name = "self", type = "Reader"}
	params[1] = Param_Decl{name = "writers", type = "View[Writer]"}
	emits := make([]string, 1, allocator)
	emits[0] = "Reader"

	// return { Reader mark_sum: fold(writers, 0, add_mark), population: fold(writers, 0, inc) }
	mark_sum := fold_node("writers", "add_mark", allocator)
	population := fold_node("writers", "inc", allocator)
	rec := record_node(
		"Reader",
		allocator,
		Recfield_Spec{"mark_sum", mark_sum},
		Recfield_Spec{"population", population},
	)
	body := make([]Node, 1, allocator)
	body[0] = return_node(rec, allocator)
	return Behavior_Decl {
		name = "observe",
		on_thing = "Reader",
		stage = "s3",
		params = params,
		emits = emits,
		body = body,
	}
}

// fold_combiner_fn builds a two-param §9 helper `f(acc, x) = acc + x.FIELD` — the
// per-element mark accumulator the Reader's mark_sum fold names.
@(private = "file")
fold_combiner_fn :: proc(
	name, elem_param, field: string,
	allocator := context.allocator,
) -> Function_Decl {
	params := make([]Param_Decl, 2, allocator)
	params[0] = Param_Decl{name = "acc", type = "Int"}
	params[1] = Param_Decl{name = elem_param, type = "Writer"}

	// return acc + x.FIELD
	field_read := field_node(name_node(elem_param, allocator), field, allocator)
	sum := binary_node("add", name_node("acc", allocator), field_read, allocator)
	body := make([]Node, 1, allocator)
	body[0] = return_node(sum, allocator)
	return Function_Decl{name = name, kind = .Fn, params = params, body = body}
}

// inc_fn builds the count combiner `inc(acc, x) = acc + 1` — the per-element +1
// the Reader's population fold names. The element is ignored; each call bumps acc.
@(private = "file")
inc_fn :: proc(name: string, allocator := context.allocator) -> Function_Decl {
	params := make([]Param_Decl, 2, allocator)
	params[0] = Param_Decl{name = "acc", type = "Int"}
	params[1] = Param_Decl{name = "x", type = "Writer"}

	sum := binary_node("add", name_node("acc", allocator), int_node(1, allocator), allocator)
	body := make([]Node, 1, allocator)
	body[0] = return_node(sum, allocator)
	return Function_Decl{name = name, kind = .Fn, params = params, body = body}
}

// --- descriptor builders (Thing/Field/Spawn) ------------------------------

// int_fields builds a thing's Int-field schema from field names — each field an
// Int column with no default (setup supplies the values).
@(private = "file")
int_fields :: proc(allocator: Runtime_Allocator, names: ..string) -> []Field_Decl {
	fields := make([]Field_Decl, len(names), allocator)
	for n, i in names {
		fields[i] = Field_Decl{name = n, type = "Int"}
	}
	return fields
}

// Int_Spawn is one Int-valued setup field — a name plus its decoded Int value.
@(private = "file")
Int_Spawn :: struct {
	name:  string,
	value: i64,
}

// int_spawn_fields builds a Spawn_Command's supplied Int fields from name/value
// pairs — the setup-decoded values a spawned row carries (already primitive, §13).
@(private = "file")
int_spawn_fields :: proc(allocator: Runtime_Allocator, pairs: ..Int_Spawn) -> []Spawn_Field {
	fields := make([]Spawn_Field, len(pairs), allocator)
	for p, i in pairs {
		fields[i] = Spawn_Field{name = p.name, kind = .Int, int_val = p.value}
	}
	return fields
}

// --- node builders (§2.7 checked-AST subtrees) ----------------------------

// int_node builds an `.Int` literal node carrying its decimal token — the form
// decode_int parses back to the i64 value.
@(private = "file")
int_node :: proc(n: i64, allocator := context.allocator) -> Node {
	fields := make([]string, 1, allocator)
	fields[0] = fmt_i64(n, allocator)
	return Node{kind = .Int, fields = fields}
}

// name_node builds a `.Name` reference node — a param/let identifier the body
// resolves through the scope chain.
@(private = "file")
name_node :: proc(name: string, allocator := context.allocator) -> Node {
	fields := make([]string, 1, allocator)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

// field_node builds a `.Field` access node `recv.FIELD` — the descriptor-driven
// column read the fold combiner uses to read `w.mark`.
@(private = "file")
field_node :: proc(recv: Node, field: string, allocator := context.allocator) -> Node {
	fields := make([]string, 1, allocator)
	fields[0] = field
	children := make([]Node, 1, allocator)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

// binary_node builds a `.Binary` op node — `lhs OP rhs` over the kernel (the
// fold combiners' `acc + …`).
@(private = "file")
binary_node :: proc(op: string, lhs, rhs: Node, allocator := context.allocator) -> Node {
	fields := make([]string, 1, allocator)
	fields[0] = op
	children := make([]Node, 2, allocator)
	children[0] = lhs
	children[1] = rhs
	return Node{kind = .Binary, fields = fields, children = children}
}

// list_node builds a `.List` literal node over its element subtrees — the
// one-element command list `grow` returns for its [Spawn] emit.
@(private = "file")
list_node :: proc(allocator: Runtime_Allocator, elems: ..Node) -> Node {
	children := make([]Node, len(elems), allocator)
	for e, i in elems {
		children[i] = e
	}
	return Node{kind = .List, children = children}
}

// fold_node builds a `fold(LIST, 0, COMBINER)` call node — the §08 aggregate the
// Reader runs over its View[Writer] list, seeded at 0 and folded by a named §9
// helper.
@(private = "file")
fold_node :: proc(list_name, combiner: string, allocator := context.allocator) -> Node {
	children := make([]Node, 4, allocator)
	children[0] = name_node("fold", allocator) // the callee name
	children[1] = name_node(list_name, allocator) // the View list param
	children[2] = int_node(0, allocator) // the seed
	children[3] = name_node(combiner, allocator) // the combiner helper name
	return Node{kind = .Call, children = children}
}

// record_node builds a `record TYPE FIELD_COUNT` node with one `.Recfield` child
// per field — the blackboard write a behavior returns.
@(private = "file")
record_node :: proc(
	type_name: string,
	allocator: Runtime_Allocator,
	specs: ..Recfield_Spec,
) -> Node {
	fields := make([]string, 1, allocator)
	fields[0] = type_name
	children := make([]Node, len(specs), allocator)
	for spec, i in specs {
		children[i] = recfield_node(spec, allocator)
	}
	return Node{kind = .Record, fields = fields, children = children}
}

// Recfield_Spec is one `name = value` pair of a record literal — the field name
// and its already-built value subtree.
@(private = "file")
Recfield_Spec :: struct {
	name:  string,
	value: Node,
}

// recfield_node builds a `.Recfield` node `NAME = value` — one field of a record
// literal, its value the carried subtree.
@(private = "file")
recfield_node :: proc(spec: Recfield_Spec, allocator := context.allocator) -> Node {
	fields := make([]string, 1, allocator)
	fields[0] = spec.name
	children := make([]Node, 1, allocator)
	children[0] = spec.value
	return Node{kind = .Recfield, fields = fields, children = children}
}

// return_node wraps a value subtree in a `.Return` statement — the body terminator
// that yields the behavior's folded result.
@(private = "file")
return_node :: proc(value: Node, allocator := context.allocator) -> Node {
	children := make([]Node, 1, allocator)
	children[0] = value
	return Node{kind = .Return, children = children}
}

// fmt_i64 renders an i64 to its decimal token — the inverse of decode_int, so an
// `.Int` node round-trips back to the value the kernel reads. The buffer is
// allocated in the supplied arena so the returned slice outlives this call.
@(private = "file")
fmt_i64 :: proc(n: i64, allocator := context.allocator) -> string {
	buf := make([]u8, 24, allocator)
	return strconv.write_int(buf, n, 10)
}
