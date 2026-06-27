package funpack_runtime

import "core:strconv"
import "core:testing"

@(test)
test_view_sees_earlier_stage_same_tick_write :: proc(t: ^testing.T) {
	program := build_writer_reader_program(context.temp_allocator)
	world := new_world(program, context.temp_allocator)
	base := run_startup(&program, initial_version(world, context.temp_allocator), context.temp_allocator)

	writer, writer_ok := view_at(view_of_type(&base, "Writer"), 0)
	testing.expect(t, writer_ok)
	mark0, _ := row_field(writer, "mark")
	testing.expect_value(t, mark0.(i64), i64(0))

	next := step_tick(&program, base, empty(), tick_time(context.temp_allocator), context.temp_allocator)

	bumped, _ := view_at(view_of_type(&next, "Writer"), 0)
	bumped_mark, _ := row_field(bumped, "mark")
	testing.expect_value(t, bumped_mark.(i64), i64(7))

	reader, _ := view_at(view_of_type(&next, "Reader"), 0)
	mark_sum, _ := row_field(reader, "mark_sum")
	testing.expect_value(t, mark_sum.(i64), i64(7))
}

@(test)
test_view_population_fixed_mid_tick_spawn_invisible :: proc(t: ^testing.T) {
	program := build_writer_reader_program(context.temp_allocator)
	world := new_world(program, context.temp_allocator)
	base := run_startup(&program, initial_version(world, context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, view_count(view_of_type(&base, "Writer")), 1)

	tick0 := step_tick(&program, base, empty(), tick_time(context.temp_allocator), context.temp_allocator)

	reader, _ := view_at(view_of_type(&tick0, "Reader"), 0)
	population, _ := row_field(reader, "population")
	testing.expect_value(t, population.(i64), i64(1))

	testing.expect_value(t, view_count(view_of_type(&tick0, "Writer")), 2)

	tick1 := step_tick(&program, tick0, empty(), tick_time(context.temp_allocator), context.temp_allocator)
	reader1, _ := view_at(view_of_type(&tick1, "Reader"), 0)
	population1, _ := row_field(reader1, "population")
	testing.expect_value(t, population1.(i64), i64(2))
}

@(test)
test_view_sees_earlier_same_stage_instance_write :: proc(t: ^testing.T) {
	N :: 4
	program := build_self_tally_program(N, context.temp_allocator)
	world := new_world(program, context.temp_allocator)
	base := run_startup(&program, initial_version(world, context.temp_allocator), context.temp_allocator)

	testing.expect_value(t, view_count(view_of_type(&base, "Counter")), N)
	for i in 0 ..< N {
		c, _ := view_at(view_of_type(&base, "Counter"), i)
		m, _ := row_field(c, "mark")
		d, _ := row_field(c, "done")
		testing.expect_value(t, m.(i64), i64(0))
		testing.expect_value(t, d.(i64), i64(0))
	}

	next := step_tick(&program, base, empty(), tick_time(context.temp_allocator), context.temp_allocator)

	prev := i64(-1)
	for i in 0 ..< N {
		c, _ := view_at(view_of_type(&next, "Counter"), i)
		mark, _ := row_field(c, "mark")
		testing.expect_value(t, mark.(i64), i64(i))
		testing.expect(t, mark.(i64) > prev)
		prev = mark.(i64)
	}
}

@(private = "file")
tick_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

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
	functions[0] = fold_combiner_fn("add_mark", "w", "mark", allocator)
	functions[1] = inc_fn("inc", allocator)

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

@(private = "file")
grow_behavior :: proc(allocator := context.allocator) -> Behavior_Decl {
	params := make([]Param_Decl, 1, allocator)
	params[0] = Param_Decl{name = "self", type = "Writer"}
	emits := make([]string, 1, allocator)
	emits[0] = "[Spawn]"

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

@(private = "file")
observe_behavior :: proc(allocator := context.allocator) -> Behavior_Decl {
	params := make([]Param_Decl, 2, allocator)
	params[0] = Param_Decl{name = "self", type = "Reader"}
	params[1] = Param_Decl{name = "writers", type = "View[Writer]"}
	emits := make([]string, 1, allocator)
	emits[0] = "Reader"

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

@(private = "file")
fold_combiner_fn :: proc(
	name, elem_param, field: string,
	allocator := context.allocator,
) -> Function_Decl {
	params := make([]Param_Decl, 2, allocator)
	params[0] = Param_Decl{name = "acc", type = "Int"}
	params[1] = Param_Decl{name = elem_param, type = "Writer"}

	field_read := field_node(name_node(elem_param, allocator), field, allocator)
	sum := binary_node("add", name_node("acc", allocator), field_read, allocator)
	body := make([]Node, 1, allocator)
	body[0] = return_node(sum, allocator)
	return Function_Decl{name = name, kind = .Fn, params = params, body = body}
}

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

@(private = "file")
build_self_tally_program :: proc(count: int, allocator := context.allocator) -> Program {
	things := make([]Thing_Decl, 1, allocator)
	things[0] = Thing_Decl {
		name = "Counter",
		fields = int_fields(allocator, "mark", "done"),
	}

	functions := make([]Function_Decl, 1, allocator)
	functions[0] = fold_combiner_fn("count_done", "c", "done", allocator)

	behaviors := make([]Behavior_Decl, 1, allocator)
	behaviors[0] = tally_behavior(allocator)

	pipeline := make([]Pipeline_Step, 1, allocator)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "s1", behavior = "tally"}

	setup := make([]Spawn_Command, count, allocator)
	for i in 0 ..< count {
		setup[i] = Spawn_Command {
			thing = "Counter",
			fields = int_spawn_fields(allocator, {"mark", 0}, {"done", 0}),
		}
	}

	return Program {
		things = things,
		functions = functions,
		behaviors = behaviors,
		pipeline = pipeline,
		setup = setup,
	}
}

@(private = "file")
tally_behavior :: proc(allocator := context.allocator) -> Behavior_Decl {
	params := make([]Param_Decl, 2, allocator)
	params[0] = Param_Decl{name = "self", type = "Counter"}
	params[1] = Param_Decl{name = "counters", type = "View[Counter]"}
	emits := make([]string, 1, allocator)
	emits[0] = "Counter"

	mark := fold_node("counters", "count_done", allocator)
	rec := record_node(
		"Counter",
		allocator,
		Recfield_Spec{"mark", mark},
		Recfield_Spec{"done", int_node(1, allocator)},
	)
	body := make([]Node, 1, allocator)
	body[0] = return_node(rec, allocator)
	return Behavior_Decl {
		name = "tally",
		on_thing = "Counter",
		stage = "s1",
		params = params,
		emits = emits,
		body = body,
	}
}

@(private = "file")
int_fields :: proc(allocator: Runtime_Allocator, names: ..string) -> []Field_Decl {
	fields := make([]Field_Decl, len(names), allocator)
	for n, i in names {
		fields[i] = Field_Decl{name = n, type = "Int"}
	}
	return fields
}

@(private = "file")
Int_Spawn :: struct {
	name:  string,
	value: i64,
}

@(private = "file")
int_spawn_fields :: proc(allocator: Runtime_Allocator, pairs: ..Int_Spawn) -> []Spawn_Field {
	fields := make([]Spawn_Field, len(pairs), allocator)
	for p, i in pairs {
		fields[i] = Spawn_Field{name = p.name, kind = .Int, int_val = p.value}
	}
	return fields
}

@(private = "file")
int_node :: proc(n: i64, allocator := context.allocator) -> Node {
	fields := make([]string, 1, allocator)
	fields[0] = fmt_i64(n, allocator)
	return Node{kind = .Int, fields = fields}
}

@(private = "file")
name_node :: proc(name: string, allocator := context.allocator) -> Node {
	fields := make([]string, 1, allocator)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

@(private = "file")
field_node :: proc(recv: Node, field: string, allocator := context.allocator) -> Node {
	fields := make([]string, 1, allocator)
	fields[0] = field
	children := make([]Node, 1, allocator)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

@(private = "file")
binary_node :: proc(op: string, lhs, rhs: Node, allocator := context.allocator) -> Node {
	fields := make([]string, 1, allocator)
	fields[0] = op
	children := make([]Node, 2, allocator)
	children[0] = lhs
	children[1] = rhs
	return Node{kind = .Binary, fields = fields, children = children}
}

@(private = "file")
list_node :: proc(allocator: Runtime_Allocator, elems: ..Node) -> Node {
	children := make([]Node, len(elems), allocator)
	for e, i in elems {
		children[i] = e
	}
	return Node{kind = .List, children = children}
}

@(private = "file")
fold_node :: proc(list_name, combiner: string, allocator := context.allocator) -> Node {
	children := make([]Node, 4, allocator)
	children[0] = name_node("fold", allocator)
	children[1] = name_node(list_name, allocator)
	children[2] = int_node(0, allocator)
	children[3] = name_node(combiner, allocator)
	return Node{kind = .Call, children = children}
}

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

@(private = "file")
Recfield_Spec :: struct {
	name:  string,
	value: Node,
}

@(private = "file")
recfield_node :: proc(spec: Recfield_Spec, allocator := context.allocator) -> Node {
	fields := make([]string, 1, allocator)
	fields[0] = spec.name
	children := make([]Node, 1, allocator)
	children[0] = spec.value
	return Node{kind = .Recfield, fields = fields, children = children}
}

@(private = "file")
return_node :: proc(value: Node, allocator := context.allocator) -> Node {
	children := make([]Node, 1, allocator)
	children[0] = value
	return Node{kind = .Return, children = children}
}

@(private = "file")
fmt_i64 :: proc(n: i64, allocator := context.allocator) -> string {
	buf := make([]u8, 24, allocator)
	return strconv.write_int(buf, n, 10)
}
