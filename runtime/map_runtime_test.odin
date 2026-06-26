// Dual-interpreter parity proof for engine.map: the runtime interpreter evaluates
// the eight Map methods with the SAME insertion-ordered, immutable-rebuild
// semantics funpack/evaluate.odin's eval_map_* does (the compiler side is pinned
// in funpack/map_eval_test.odin). Map values are hand-built and the builtins /
// method-form dispatch are driven over synthetic node forests, the
// interp_combinators_test discipline.
package funpack_runtime

import "core:strconv"
import "core:testing"

// --- synthetic-node + value builders --------------------------------------

@(private = "file")
mr_name_node :: proc(name: string) -> Node {
	fields := make([]string, 1, context.temp_allocator)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

@(private = "file")
mr_int_node :: proc(n: i64) -> Node {
	fields := make([]string, 1, context.temp_allocator)
	buf := make([]u8, 24, context.temp_allocator)
	fields[0] = strconv.write_int(buf, n, 10)
	return Node{kind = .Int, fields = fields}
}

// mr_call_node builds a `call` node: child[0] the callee `name`, children[1:] the
// arg nodes — the free-call form get(m, k) / set(m, k, v).
@(private = "file")
mr_call_node :: proc(callee: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = mr_name_node(callee)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

// mr_method_call builds the §02 §4 method form `recv.method(args)`: a `call` whose
// callee is a `field` node over the receiver, the args following. Routes through
// eval -> eval_call -> eval_method_call -> eval_map_method.
@(private = "file")
mr_method_call :: proc(recv: Node, method: string, args: ..Node) -> Node {
	field_fields := make([]string, 1, context.temp_allocator)
	field_fields[0] = method
	field_children := make([]Node, 1, context.temp_allocator)
	field_children[0] = recv
	field := Node{kind = .Field, fields = field_fields, children = field_children}
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = field
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
mr_interp :: proc() -> Interp {
	program := new(Program, context.temp_allocator)
	return Interp{program = program, allocator = context.temp_allocator}
}

// mr_map builds a Map_Value from alternating key, value pairs in insertion order.
@(private = "file")
mr_map :: proc(pairs: ..Value) -> Value {
	entries := make([]Map_Entry, len(pairs) / 2, context.temp_allocator)
	for i := 0; i < len(pairs); i += 2 {
		entries[i / 2] = Map_Entry{key = pairs[i], value = pairs[i + 1]}
	}
	return Map_Value{entries = entries}
}

@(private = "file")
mr_scope :: proc(bindings: ..struct {
		name: string,
		val:  Value,
	}) -> Env {
	names := make(map[string]Value, context.temp_allocator)
	for b in bindings {
		names[b.name] = b.val
	}
	return Env{names = names}
}

// mr_expect_some asserts a result is Option::Some carrying the expected i64/bool.
@(private = "file")
mr_expect_some_bool :: proc(t: ^testing.T, v: Value, want: bool) {
	variant, ok := v.(Variant_Value)
	testing.expect(t, ok && variant.enum_type == "Option" && variant.case_name == "Some")
	if ok && variant.payload != nil {
		got, is_bool := variant.payload^.(bool)
		testing.expect(t, is_bool && got == want)
	}
}

@(private = "file")
mr_is_none :: proc(v: Value) -> bool {
	variant, ok := v.(Variant_Value)
	return ok && variant.enum_type == "Option" && variant.case_name == "None"
}

// --- the map method fixtures ----------------------------------------------

@(test)
test_runtime_map_set_get_roundtrip :: proc(t: ^testing.T) {
	// AC: set then get round-trips in the runtime — the dual of the compiler's
	// test_map_set_get_roundtrip. set(empty, 1, true) yields a one-entry map; get(1)
	// reads Some(true), get(2) reads None.
	interp := mr_interp()
	env := mr_scope({"m", mr_map()}, {"v", true})
	set_node := mr_call_node("set", mr_name_node("m"), mr_int_node(1), mr_name_node("v"))
	m1, set_ok := builtin_map_set(&interp, &set_node, &env)
	testing.expect(t, set_ok)
	map1, is_map := m1.(Map_Value)
	testing.expect(t, is_map)
	testing.expect_value(t, len(map1.entries), 1)

	env1 := mr_scope({"m1", m1})
	hit_node := mr_call_node("get", mr_name_node("m1"), mr_int_node(1))
	hit, hit_ok := builtin_get(&interp, &hit_node, &env1)
	testing.expect(t, hit_ok)
	mr_expect_some_bool(t, hit, true)

	miss_node := mr_call_node("get", mr_name_node("m1"), mr_int_node(2))
	miss, miss_ok := builtin_get(&interp, &miss_node, &env1)
	testing.expect(t, miss_ok)
	testing.expect(t, mr_is_none(miss))
}

@(test)
test_runtime_map_set_replaces_in_place :: proc(t: ^testing.T) {
	// AC: re-setting an existing key updates its value without growing the map or
	// moving the key — len stays 1, get reads the latest value (the in-place rebuild
	// the compiler's test_map_set_replaces_in_place also pins).
	interp := mr_interp()
	env := mr_scope({"m", mr_map(i64(1), true)}, {"v", false})
	set_node := mr_call_node("set", mr_name_node("m"), mr_int_node(1), mr_name_node("v"))
	m2, ok := builtin_map_set(&interp, &set_node, &env)
	testing.expect(t, ok)
	map2 := m2.(Map_Value)
	testing.expect_value(t, len(map2.entries), 1)

	env2 := mr_scope({"m2", m2})
	get_node := mr_call_node("get", mr_name_node("m2"), mr_int_node(1))
	got, got_ok := builtin_get(&interp, &get_node, &env2)
	testing.expect(t, got_ok)
	mr_expect_some_bool(t, got, false)
}

@(test)
test_runtime_map_has_and_remove :: proc(t: ^testing.T) {
	// AC: has is the membership predicate; remove drops the key and closes the gap,
	// preserving insertion order among the rest (the compiler's
	// test_map_has_membership / test_map_remove_closes_gap dual).
	interp := mr_interp()
	m := mr_map(i64(1), true, i64(2), false)
	env := mr_scope({"m", m})

	has_node := mr_call_node("has", mr_name_node("m"), mr_int_node(1))
	has, has_ok := builtin_map_has(&interp, &has_node, &env)
	testing.expect(t, has_ok && has.(bool) == true)

	missing_node := mr_call_node("has", mr_name_node("m"), mr_int_node(9))
	missing, missing_ok := builtin_map_has(&interp, &missing_node, &env)
	testing.expect(t, missing_ok && missing.(bool) == false)

	rm_node := mr_call_node("remove", mr_name_node("m"), mr_int_node(1))
	rm, rm_ok := builtin_map_remove(&interp, &rm_node, &env)
	testing.expect(t, rm_ok)
	rm_map := rm.(Map_Value)
	testing.expect_value(t, len(rm_map.entries), 1)
	testing.expect_value(t, rm_map.entries[0].key.(i64), i64(2))
}

@(test)
test_runtime_map_keys_values_insertion_order :: proc(t: ^testing.T) {
	// AC: keys() and values() project in INSERTION order, not sorted — a map built
	// set(2) before set(1) yields keys [2, 1], values pairing positionally (the
	// determinism contract; the compiler's test_map_keys_values_insertion_order dual).
	interp := mr_interp()
	env := mr_scope({"m", mr_map(i64(2), false, i64(1), true)})

	keys_node := mr_call_node("keys", mr_name_node("m"))
	keys, keys_ok := builtin_map_keys(&interp, &keys_node, &env)
	testing.expect(t, keys_ok)
	keys_list := keys.(List_Value)
	testing.expect_value(t, len(keys_list.elements), 2)
	testing.expect_value(t, keys_list.elements[0].(i64), i64(2))
	testing.expect_value(t, keys_list.elements[1].(i64), i64(1))

	values_node := mr_call_node("values", mr_name_node("m"))
	values, values_ok := builtin_map_values(&interp, &values_node, &env)
	testing.expect(t, values_ok)
	values_list := values.(List_Value)
	testing.expect_value(t, values_list.elements[0].(bool), false)
	testing.expect_value(t, values_list.elements[1].(bool), true)
}

@(test)
test_runtime_map_equality_is_positional :: proc(t: ^testing.T) {
	// AC: values_equal is positional over the pairs — same order equal, the same
	// entries in a different order NOT equal (the List model; the dual of the
	// compiler's value_equal Map arm and test_map_equality_is_positional).
	same_order := values_equal(mr_map(i64(1), true, i64(2), false), mr_map(i64(1), true, i64(2), false))
	testing.expect(t, same_order)
	diff_order := values_equal(mr_map(i64(1), true, i64(2), false), mr_map(i64(2), false, i64(1), true))
	testing.expect(t, !diff_order)
}

@(test)
test_runtime_map_method_form_and_static_empty :: proc(t: ^testing.T) {
	// AC: the method form m.get(k) dispatches through eval -> eval_method_call ->
	// eval_map_method, and the idiomatic Map.empty() static constructor builds the
	// empty map through eval_engine_constructor — the two reach the same value cores
	// the free builtins do (the chaining idiom Map.empty().set(...).get(...) rests on
	// this method dispatch).
	interp := mr_interp()
	env := mr_scope({"m1", mr_map(i64(1), true)})
	method_get := mr_method_call(mr_name_node("m1"), "get", mr_int_node(1))
	got, got_ok := eval(&interp, &method_get, &env)
	testing.expect(t, got_ok)
	mr_expect_some_bool(t, got, true)

	empty_call := mr_method_call(mr_name_node("Map"), "empty")
	empty_env := mr_scope()
	empty_val, empty_ok := eval(&interp, &empty_call, &empty_env)
	testing.expect(t, empty_ok)
	empty_map, is_map := empty_val.(Map_Value)
	testing.expect(t, is_map)
	testing.expect_value(t, len(empty_map.entries), 0)
}

@(test)
test_runtime_map_cell_tile_record_keys :: proc(t: ^testing.T) {
	// AC: the decision's canonical Map[Cell, Tile] — a record key uses values_equal
	// (structural), so a Cell{x,y} key reads back its Tile and a different cell reads
	// None, exactly as the compiler's test_map_cell_tile_keyed_state. This is the
	// keyed-state shape gameplay (a stored dungeon floor) rests on.
	interp := mr_interp()
	cell00 := Record_Value {
		type_name = "Cell",
		fields    = mr_cell_fields(0, 0),
	}
	cell10 := Record_Value {
		type_name = "Cell",
		fields    = mr_cell_fields(1, 0),
	}
	wall := Variant_Value{enum_type = "Tile", case_name = "Wall"}
	m := mr_map(cell00, wall)
	env := mr_scope({"m", m}, {"k", cell00}, {"other", cell10})

	hit_node := mr_call_node("get", mr_name_node("m"), mr_name_node("k"))
	hit, hit_ok := builtin_get(&interp, &hit_node, &env)
	testing.expect(t, hit_ok)
	hit_variant, is_variant := hit.(Variant_Value)
	testing.expect(t, is_variant && hit_variant.case_name == "Some")
	if is_variant && hit_variant.payload != nil {
		tile, is_tile := hit_variant.payload^.(Variant_Value)
		testing.expect(t, is_tile && tile.enum_type == "Tile" && tile.case_name == "Wall")
	}

	miss_node := mr_call_node("get", mr_name_node("m"), mr_name_node("other"))
	miss, miss_ok := builtin_get(&interp, &miss_node, &env)
	testing.expect(t, miss_ok)
	testing.expect(t, mr_is_none(miss))
}

@(private = "file")
mr_cell_fields :: proc(x, y: i64) -> map[string]Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["x"] = x
	fields["y"] = y
	return fields
}
