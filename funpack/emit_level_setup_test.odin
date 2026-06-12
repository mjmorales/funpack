// The v15 level-backed [setup] fold's unit fixtures (emit_level_setup.odin):
// the batch detection (a setup() that is a lone call to a threaded
// `<level>_spawns` extern folds; every other shape falls through), the per-row
// §13 byte shape (pos spread → facing bits → params), and the declared-type
// param encoding the live dungeon/warren corpus does not fully exercise (a
// Bool param, a Fixed param, an authored facing, the Ref-param skip). The live
// corpus pins ride golden_tilemap_e2e_test.odin; these fixtures pin the closed
// encoding rules byte-exact, hand-built so every expectation derives from the
// rule, never from the implementation.
package funpack

import "core:strings"
import "core:testing"

// level_setup_thing_fixture is the placed-thing schema the param encoding
// reads declared field types from: a Guard with an Int, a Bool, a Fixed, and a
// Ref[Door] field beside its pos.
level_setup_thing_fixture :: proc() -> []Thing_Node {
	fields := make([]Field_Decl, 5, context.temp_allocator)
	fields[0] = Field_Decl{name = "pos", type = Type_Ref{name = "Vec2"}}
	fields[1] = Field_Decl{name = "hp", type = Type_Ref{name = "Int"}}
	fields[2] = Field_Decl{name = "alert", type = Type_Ref{name = "Bool"}}
	fields[3] = Field_Decl{name = "rate", type = Type_Ref{name = "Fixed"}}
	ref_args := make([]Type_Ref, 1, context.temp_allocator)
	ref_args[0] = Type_Ref{name = "Door"}
	fields[4] = Field_Decl{name = "gate", type = Type_Ref{name = "Ref", args = ref_args}}
	things := make([]Thing_Node, 1, context.temp_allocator)
	things[0] = Thing_Node{name = "Guard", fields = fields}
	return things
}

// level_setup_batch_fixture is one hand-built two-spawn batch: a Guard with an
// authored facing and the three scalar param types plus a Ref param (skipped),
// and a bare marker-style spawn (pos only). Coordinates are exact Q32.32
// constants (24 → 103079215104, 8 → 34359738368, 2.5 → 10737418240).
level_setup_batch_fixture :: proc() -> Level_Spawn_Batch {
	params := make([]Baked_Param, 4, context.temp_allocator)
	params[0] = Baked_Param{field = "hp", value = to_fixed(7)}
	params[1] = Baked_Param{field = "alert", value = to_fixed(1)}
	params[2] = Baked_Param{field = "rate", value = Fixed(10737418240)} // 2.5
	params[3] = Baked_Param{field = "gate", is_ref = true, ref_id = 42}
	spawns := make([]Baked_Spawn, 2, context.temp_allocator)
	spawns[0] = Baked_Spawn {
		thing_type = "Guard",
		id         = 1,
		has_facing = true,
		pos        = Baked_Coord{dim = .D2, x = to_fixed(24), y = to_fixed(8)},
		facing     = Fixed(6746518852), // 1.5707963… ≈ π/2, an arbitrary exact bit pattern
		params     = params,
	}
	spawns[1] = Baked_Spawn {
		thing_type = "Guard",
		id         = 0,
		pos        = Baked_Coord{dim = .D2, x = to_fixed(8), y = to_fixed(24)},
	}
	return Level_Spawn_Batch{fn_name = "fort_spawns", spawns = spawns}
}

@(test)
test_emit_level_setup_encodes_rows_by_declared_type :: proc(t: ^testing.T) {
	// AC (the §13 v15 row shape, byte-exact): pos as the vec2 spread, facing as
	// raw Fixed bits, then params in source order — the Int re-truncated to
	// decimal, the Bool as its bare token, the Fixed as raw bits — and the
	// Ref param SKIPPED (no ratified §13 encoding until the level-accessor
	// bump), so field_count counts exactly the emitted set rows (5, not 6).
	b := strings.builder_make(context.temp_allocator)
	emit_level_setup(&b, level_setup_batch_fixture(), level_setup_thing_fixture(), nil)
	expected :=
		"[setup 2]\n" +
		"spawn Guard 5\n" +
		"set pos =vec2 103079215104 34359738368\n" +
		"set facing =6746518852\n" +
		"set hp =7\n" +
		"set alert =true\n" +
		"set rate =10737418240\n" +
		"spawn Guard 1\n" +
		"set pos =vec2 34359738368 103079215104\n"
	testing.expect_value(t, strings.to_string(b), expected)
}

@(test)
test_emit_level_setup_unresolved_schema_falls_back_to_fixed_bits :: proc(t: ^testing.T) {
	// AC (fallback encoding): a placed type outside the schema lookup (own +
	// imported things) encodes its params as raw Q32.32 bits — the bake's
	// native representation — deterministically, never a guess at Int.
	b := strings.builder_make(context.temp_allocator)
	emit_level_setup(&b, level_setup_batch_fixture(), nil, nil)
	testing.expect(t, strings.contains(strings.to_string(b), "set hp =30064771072\n")) // 7 << 32
}

@(test)
test_level_setup_batch_detects_lone_extern_call :: proc(t: ^testing.T) {
	// AC (batch detection): a setup() whose body is a lone `return
	// fort_spawns()` selects the batch keyed by that name; a setup() returning
	// a literal list (pong's shape) falls through to the resolve_setup_spawns
	// path; an empty batch set never matches.
	source := "fn setup() -> [Spawn] {\n  return fort_spawns()\n}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	batches := make([]Level_Spawn_Batch, 1, context.temp_allocator)
	batches[0] = level_setup_batch_fixture()
	batch, found := level_setup_batch(ast, batches)
	testing.expect(t, found)
	testing.expect_value(t, batch.fn_name, "fort_spawns")
	_, none_found := level_setup_batch(ast, nil)
	testing.expect(t, !none_found)

	literal := "fn setup() -> [Spawn] {\n  return [Spawn(Guard{pos: Vec2{x: 1.0, y: 1.0}})]\n}\n"
	literal_ast, literal_err := stage_parse(stage_lex(literal))
	testing.expect_value(t, literal_err, Parse_Error.None)
	_, literal_found := level_setup_batch(literal_ast, batches)
	testing.expect(t, !literal_found)
}

@(test)
test_emit_level_setup_deterministic :: proc(t: ^testing.T) {
	// §29 determinism: two renders of the same batch are byte-identical —
	// every walk is slice-order, no map reaches the emission.
	first := strings.builder_make(context.temp_allocator)
	emit_level_setup(&first, level_setup_batch_fixture(), level_setup_thing_fixture(), nil)
	second := strings.builder_make(context.temp_allocator)
	emit_level_setup(&second, level_setup_batch_fixture(), level_setup_thing_fixture(), nil)
	testing.expect(t, strings.to_string(first) == strings.to_string(second))
}
