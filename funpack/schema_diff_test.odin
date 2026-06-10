// Per-class unit vectors for the name-keyed schema-diff kernel
// (schema_diff.odin) — one fixture per §09 §4 diff class (additive, removed,
// reorder, rename, retype, the combined form) and per refusal verdict, plus
// the snapshot-read rename-chain cases and the bit-determinism double-diff.
// These vectors are the cross-product audit root the runtime's own kernel
// copy re-asserts when the runtime epic lands restore + hot-reload (the
// fixed.odin shared-golden discipline), so they assert exact plans — never
// loosened to counts or classes.
package funpack

import "core:testing"

// sf builds the directive-free schema field every fixture starts from.
sf :: proc(name: string, type_spelling: string) -> Schema_Field {
	return Schema_Field{name = name, type_spelling = type_spelling}
}

// sf_default builds an additive-eligible field carrying a declared default.
sf_default :: proc(name: string, type_spelling: string, token: string) -> Schema_Field {
	return Schema_Field{name = name, type_spelling = type_spelling, default_token = token, has_default = true}
}

// sf_from builds a rename-form field (@migrate(from: "...")).
sf_from :: proc(name: string, type_spelling: string, from: string) -> Schema_Field {
	return Schema_Field{name = name, type_spelling = type_spelling, migrate_from = from, has_from = true}
}

// sf_with builds a retype-form field (@migrate(with: convert)).
sf_with :: proc(name: string, type_spelling: string, convert: string) -> Schema_Field {
	return Schema_Field{name = name, type_spelling = type_spelling, migrate_with = convert, has_with = true}
}

// expect_clean_plan runs the diff and asserts it succeeds, returning the plan.
expect_clean_plan :: proc(t: ^testing.T, old_schema: []Schema_Field, new_schema: []Schema_Field) -> []Migration_Action {
	plan, offender, err := diff_schemas(old_schema, new_schema, context.temp_allocator)
	testing.expect_value(t, err, Schema_Diff_Error.None)
	testing.expect_value(t, offender, "")
	return plan
}

@(test)
test_diff_additive_field_takes_declared_default :: proc(t: ^testing.T) {
	// AC (additive -> declared default): a new field absent from the old
	// schema seeds its declared default; the untouched sibling carries.
	old_schema := []Schema_Field{sf("hp", "Int")}
	new_schema := []Schema_Field{sf("hp", "Int"), sf_default("mana", "Int", "=0")}
	plan := expect_clean_plan(t, old_schema, new_schema)
	testing.expect_value(t, len(plan), 2)
	testing.expect_value(t, plan[0], Migration_Action{field = "hp", op = .Carry, source = "hp"})
	testing.expect_value(t, plan[1], Migration_Action{field = "mana", op = .Default, default_token = "=0"})
}

@(test)
test_diff_additive_field_without_default_refused :: proc(t: ^testing.T) {
	// AC (refusal: additive, no default): the §09 §4 "add non-optional field,
	// no default" breaking verdict — "make it Option or give a default".
	old_schema := []Schema_Field{sf("hp", "Int")}
	new_schema := []Schema_Field{sf("hp", "Int"), sf("mana", "Int")}
	_, offender, err := diff_schemas(old_schema, new_schema, context.temp_allocator)
	testing.expect_value(t, err, Schema_Diff_Error.Missing_Default)
	testing.expect_value(t, offender, "mana")
}

@(test)
test_diff_removed_field_drops :: proc(t: ^testing.T) {
	// AC (removed -> drop): an old field no new field sources from produces
	// no action at all — safe, automatic, never a refusal.
	old_schema := []Schema_Field{sf("hp", "Int"), sf("legacy", "Fixed")}
	new_schema := []Schema_Field{sf("hp", "Int")}
	plan := expect_clean_plan(t, old_schema, new_schema)
	testing.expect_value(t, len(plan), 1)
	testing.expect_value(t, plan[0], Migration_Action{field = "hp", op = .Carry, source = "hp"})
}

@(test)
test_diff_reorder_is_no_op :: proc(t: ^testing.T) {
	// AC (reorder -> no-op): the same fields in a different old order yield
	// the identical all-Carry plan — sourcing is by name, never position, so
	// the old schema's order is invisible.
	new_schema := []Schema_Field{sf("hp", "Int"), sf("pos", "Vec2"), sf("vel", "Vec2")}
	forward := expect_clean_plan(t, []Schema_Field{sf("hp", "Int"), sf("pos", "Vec2"), sf("vel", "Vec2")}, new_schema)
	reversed := expect_clean_plan(t, []Schema_Field{sf("vel", "Vec2"), sf("pos", "Vec2"), sf("hp", "Int")}, new_schema)
	testing.expect_value(t, len(forward), 3)
	testing.expect_value(t, len(reversed), 3)
	for action, i in forward {
		testing.expect_value(t, action.op, Migration_Op.Carry)
		testing.expect_value(t, reversed[i], action)
	}
}

@(test)
test_diff_rename_sources_prior_key :: proc(t: ^testing.T) {
	// AC (rename applied): @migrate(from:) reads the old key into the new
	// field — same type, the §05 §6 rename form.
	old_schema := []Schema_Field{sf("old_pos", "Vec2")}
	new_schema := []Schema_Field{sf_from("pos", "Vec2", "old_pos")}
	plan := expect_clean_plan(t, old_schema, new_schema)
	testing.expect_value(t, len(plan), 1)
	testing.expect_value(t, plan[0], Migration_Action{field = "pos", op = .Rename, source = "old_pos"})
}

@(test)
test_diff_rename_chain_reads_old_snapshot :: proc(t: ^testing.T) {
	// AC (rename chain, one hop): cross-field moves source the OLD snapshot,
	// never a sequentially-mutated row — old.a feeds new.b while old.b feeds
	// new.c, each action naming its own old key.
	old_schema := []Schema_Field{sf("a", "Int"), sf("b", "Int")}
	new_schema := []Schema_Field{sf_from("b", "Int", "a"), sf_from("c", "Int", "b")}
	plan := expect_clean_plan(t, old_schema, new_schema)
	testing.expect_value(t, len(plan), 2)
	testing.expect_value(t, plan[0], Migration_Action{field = "b", op = .Rename, source = "a"})
	testing.expect_value(t, plan[1], Migration_Action{field = "c", op = .Rename, source = "b"})
}

@(test)
test_diff_rename_chain_composes_across_hops :: proc(t: ^testing.T) {
	// AC (rename chain, sequential hops): a v1→v2 rename then a v2→v3 rename
	// compose — each hop's directive names its immediately-prior key, and the
	// second hop's plan sources the first hop's result.
	v1 := []Schema_Field{sf("a", "Int")}
	v2 := []Schema_Field{sf_from("b", "Int", "a")}
	v3 := []Schema_Field{sf_from("c", "Int", "b")}
	first := expect_clean_plan(t, v1, v2)
	testing.expect_value(t, len(first), 1)
	testing.expect_value(t, first[0], Migration_Action{field = "b", op = .Rename, source = "a"})
	// The second hop diffs against the schema the first hop PRODUCED — field
	// `b`, directive-free (the v2 declaration's own metadata, not v3's).
	second := expect_clean_plan(t, []Schema_Field{sf("b", "Int")}, v3)
	testing.expect_value(t, len(second), 1)
	testing.expect_value(t, second[0], Migration_Action{field = "c", op = .Rename, source = "b"})
}

@(test)
test_diff_rename_unknown_source_refused :: proc(t: ^testing.T) {
	// AC (unknown-field refusal): a @migrate naming a prior key the old
	// schema lacks states a false fact about the old world — refused, never
	// silently routed to the additive default (a mistyped rename must
	// surface, not seed a default).
	old_schema := []Schema_Field{sf("hp", "Int")}
	new_schema := []Schema_Field{sf_from("pos", "Vec2", "ghost")}
	_, offender, err := diff_schemas(old_schema, new_schema, context.temp_allocator)
	testing.expect_value(t, err, Schema_Diff_Error.Unknown_Source)
	testing.expect_value(t, offender, "pos")
}

@(test)
test_diff_rename_type_changed_refused :: proc(t: ^testing.T) {
	// AC (rename is the same-type form): a rename-only directive over a type
	// change is refused — the repair is the combined from+with form.
	old_schema := []Schema_Field{sf("old_hp", "Int")}
	new_schema := []Schema_Field{sf_from("hp", "Fixed", "old_hp")}
	_, offender, err := diff_schemas(old_schema, new_schema, context.temp_allocator)
	testing.expect_value(t, err, Schema_Diff_Error.Rename_Type_Changed)
	testing.expect_value(t, offender, "hp")
}

@(test)
test_diff_retype_converts_old_value :: proc(t: ^testing.T) {
	// AC (retype applied): @migrate(with:) routes the old value (at the
	// field's own name) through the named conversion — the plan carries the
	// fn name for the loader's interpreter, the kernel runs nothing.
	old_schema := []Schema_Field{sf("hp", "Int")}
	new_schema := []Schema_Field{sf_with("hp", "Fixed", "lift")}
	plan := expect_clean_plan(t, old_schema, new_schema)
	testing.expect_value(t, len(plan), 1)
	testing.expect_value(t, plan[0], Migration_Action{field = "hp", op = .Convert, source = "hp", convert = "lift"})
}

@(test)
test_diff_rename_retype_converts_from_prior_key :: proc(t: ^testing.T) {
	// AC (combined form): from+with sources the prior key and converts —
	// no type comparison, the conversion owns the type change.
	old_schema := []Schema_Field{sf("speed", "Int")}
	// The bare rename over a type change refuses (proven above); the combined
	// form is the sanctioned spelling.
	combined := []Schema_Field{
		sf_default("hp", "Int", "=0"),
		Schema_Field{
			name = "vel",
			type_spelling = "Fixed",
			migrate_from = "speed",
			has_from = true,
			migrate_with = "to_velocity",
			has_with = true,
		},
	}
	plan := expect_clean_plan(t, old_schema, combined)
	testing.expect_value(t, len(plan), 2)
	testing.expect_value(t, plan[0], Migration_Action{field = "hp", op = .Default, default_token = "=0"})
	testing.expect_value(t, plan[1], Migration_Action{field = "vel", op = .Convert, source = "speed", convert = "to_velocity"})
}

@(test)
test_diff_retype_with_default_converts_when_source_present :: proc(t: ^testing.T) {
	// AC (retype + default interaction, source present): a retyped field that
	// ALSO declares a default converts the old value — the directive is the
	// explicit channel and wins; the default is not consulted.
	old_schema := []Schema_Field{sf("hp", "Int")}
	new_schema := []Schema_Field{
		Schema_Field{
			name = "hp",
			type_spelling = "Fixed",
			default_token = "=4294967296",
			has_default = true,
			migrate_with = "lift",
			has_with = true,
		},
	}
	plan := expect_clean_plan(t, old_schema, new_schema)
	testing.expect_value(t, len(plan), 1)
	testing.expect_value(t, plan[0], Migration_Action{field = "hp", op = .Convert, source = "hp", convert = "lift"})
}

@(test)
test_diff_retype_with_default_refused_when_source_absent :: proc(t: ^testing.T) {
	// AC (retype + default interaction, source absent): the directive's
	// source must exist even when a default is declared — a directive-carrying
	// field is never silently additive, so the absent source is the
	// Unknown_Source refusal, not a default seed.
	old_schema := []Schema_Field{sf("mana", "Int")}
	new_schema := []Schema_Field{
		Schema_Field{
			name = "hp",
			type_spelling = "Fixed",
			default_token = "=4294967296",
			has_default = true,
			migrate_with = "lift",
			has_with = true,
		},
	}
	_, offender, err := diff_schemas(old_schema, new_schema, context.temp_allocator)
	testing.expect_value(t, err, Schema_Diff_Error.Unknown_Source)
	testing.expect_value(t, offender, "hp")
}

@(test)
test_diff_retype_without_migrate_refused :: proc(t: ^testing.T) {
	// AC (refusal: silent retype): a same-named field whose type changed with
	// no directive is the §09 §4 "change field type: breaking" verdict — the
	// repair is @migrate(with: convert).
	old_schema := []Schema_Field{sf("hp", "Int")}
	new_schema := []Schema_Field{sf("hp", "Fixed")}
	_, offender, err := diff_schemas(old_schema, new_schema, context.temp_allocator)
	testing.expect_value(t, err, Schema_Diff_Error.Retype_Without_Migrate)
	testing.expect_value(t, offender, "hp")
}

@(test)
test_diff_duplicate_field_name_refused :: proc(t: ^testing.T) {
	// AC (broken name-keyed premise): a schema declaring one name twice makes
	// the by-name diff ill-defined — refused before any classification, on
	// either side.
	dup := []Schema_Field{sf("hp", "Int"), sf("hp", "Fixed")}
	clean := []Schema_Field{sf("hp", "Int")}
	_, old_offender, old_err := diff_schemas(dup, clean, context.temp_allocator)
	testing.expect_value(t, old_err, Schema_Diff_Error.Duplicate_Field)
	testing.expect_value(t, old_offender, "hp")
	_, new_offender, new_err := diff_schemas(clean, dup, context.temp_allocator)
	testing.expect_value(t, new_err, Schema_Diff_Error.Duplicate_Field)
	testing.expect_value(t, new_offender, "hp")
}

@(test)
test_diff_identical_schemas_all_carry :: proc(t: ^testing.T) {
	// The degenerate diff — identical schemas — is the all-Carry identity
	// plan, one action per field in declaration order.
	schema := []Schema_Field{sf("hp", "Int"), sf("pos", "Vec2"), sf_default("score", "Int", "=0")}
	plan := expect_clean_plan(t, schema, schema)
	testing.expect_value(t, len(plan), 3)
	for action, i in plan {
		testing.expect_value(t, action, Migration_Action{field = schema[i].name, op = .Carry, source = schema[i].name})
	}
}

@(test)
test_diff_double_diff_bit_identical :: proc(t: ^testing.T) {
	// AC (bit-determinism): two diffs over the same schemas produce
	// element-for-element identical plans — the kernel has no map iteration,
	// no clock, and no allocation-order dependence in its output.
	old_schema := []Schema_Field{sf("a", "Int"), sf("b", "Int"), sf("legacy", "Fixed")}
	new_schema := []Schema_Field{
		sf_from("b", "Int", "a"),
		sf_with("a", "Fixed", "lift"),
		sf_default("fresh", "Int", "=7"),
	}
	first := expect_clean_plan(t, old_schema, new_schema)
	second := expect_clean_plan(t, old_schema, new_schema)
	testing.expect_value(t, len(first), len(second))
	for action, i in first {
		testing.expect_value(t, second[i], action)
	}
}
