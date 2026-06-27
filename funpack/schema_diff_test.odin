package funpack

import "core:testing"

sf :: proc(name: string, type_spelling: string) -> Schema_Field {
	return Schema_Field{name = name, type_spelling = type_spelling}
}

sf_default :: proc(name: string, type_spelling: string, token: string) -> Schema_Field {
	return Schema_Field{name = name, type_spelling = type_spelling, default_token = token, has_default = true}
}

sf_from :: proc(name: string, type_spelling: string, from: string) -> Schema_Field {
	return Schema_Field{name = name, type_spelling = type_spelling, migrate_from = from, has_from = true}
}

sf_with :: proc(name: string, type_spelling: string, convert: string) -> Schema_Field {
	return Schema_Field{name = name, type_spelling = type_spelling, migrate_with = convert, has_with = true}
}

expect_clean_plan :: proc(t: ^testing.T, old_schema: []Schema_Field, new_schema: []Schema_Field) -> []Migration_Action {
	plan, offender, err := diff_schemas(old_schema, new_schema, context.temp_allocator)
	testing.expect_value(t, err, Schema_Diff_Error.None)
	testing.expect_value(t, offender, "")
	return plan
}

@(test)
test_diff_additive_field_takes_declared_default :: proc(t: ^testing.T) {
	old_schema := []Schema_Field{sf("hp", "Int")}
	new_schema := []Schema_Field{sf("hp", "Int"), sf_default("mana", "Int", "=0")}
	plan := expect_clean_plan(t, old_schema, new_schema)
	testing.expect_value(t, len(plan), 2)
	testing.expect_value(t, plan[0], Migration_Action{field = "hp", op = .Carry, source = "hp"})
	testing.expect_value(t, plan[1], Migration_Action{field = "mana", op = .Default, default_token = "=0"})
}

@(test)
test_diff_additive_field_without_default_refused :: proc(t: ^testing.T) {
	old_schema := []Schema_Field{sf("hp", "Int")}
	new_schema := []Schema_Field{sf("hp", "Int"), sf("mana", "Int")}
	_, offender, err := diff_schemas(old_schema, new_schema, context.temp_allocator)
	testing.expect_value(t, err, Schema_Diff_Error.Missing_Default)
	testing.expect_value(t, offender, "mana")
}

@(test)
test_diff_removed_field_drops :: proc(t: ^testing.T) {
	old_schema := []Schema_Field{sf("hp", "Int"), sf("legacy", "Fixed")}
	new_schema := []Schema_Field{sf("hp", "Int")}
	plan := expect_clean_plan(t, old_schema, new_schema)
	testing.expect_value(t, len(plan), 1)
	testing.expect_value(t, plan[0], Migration_Action{field = "hp", op = .Carry, source = "hp"})
}

@(test)
test_diff_reorder_is_no_op :: proc(t: ^testing.T) {
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
	old_schema := []Schema_Field{sf("old_pos", "Vec2")}
	new_schema := []Schema_Field{sf_from("pos", "Vec2", "old_pos")}
	plan := expect_clean_plan(t, old_schema, new_schema)
	testing.expect_value(t, len(plan), 1)
	testing.expect_value(t, plan[0], Migration_Action{field = "pos", op = .Rename, source = "old_pos"})
}

@(test)
test_diff_rename_chain_reads_old_snapshot :: proc(t: ^testing.T) {
	old_schema := []Schema_Field{sf("a", "Int"), sf("b", "Int")}
	new_schema := []Schema_Field{sf_from("b", "Int", "a"), sf_from("c", "Int", "b")}
	plan := expect_clean_plan(t, old_schema, new_schema)
	testing.expect_value(t, len(plan), 2)
	testing.expect_value(t, plan[0], Migration_Action{field = "b", op = .Rename, source = "a"})
	testing.expect_value(t, plan[1], Migration_Action{field = "c", op = .Rename, source = "b"})
}

@(test)
test_diff_rename_chain_composes_across_hops :: proc(t: ^testing.T) {
	v1 := []Schema_Field{sf("a", "Int")}
	v2 := []Schema_Field{sf_from("b", "Int", "a")}
	v3 := []Schema_Field{sf_from("c", "Int", "b")}
	first := expect_clean_plan(t, v1, v2)
	testing.expect_value(t, len(first), 1)
	testing.expect_value(t, first[0], Migration_Action{field = "b", op = .Rename, source = "a"})
	second := expect_clean_plan(t, []Schema_Field{sf("b", "Int")}, v3)
	testing.expect_value(t, len(second), 1)
	testing.expect_value(t, second[0], Migration_Action{field = "c", op = .Rename, source = "b"})
}

@(test)
test_diff_rename_unknown_source_refused :: proc(t: ^testing.T) {
	old_schema := []Schema_Field{sf("hp", "Int")}
	new_schema := []Schema_Field{sf_from("pos", "Vec2", "ghost")}
	_, offender, err := diff_schemas(old_schema, new_schema, context.temp_allocator)
	testing.expect_value(t, err, Schema_Diff_Error.Unknown_Source)
	testing.expect_value(t, offender, "pos")
}

@(test)
test_diff_rename_type_changed_refused :: proc(t: ^testing.T) {
	old_schema := []Schema_Field{sf("old_hp", "Int")}
	new_schema := []Schema_Field{sf_from("hp", "Fixed", "old_hp")}
	_, offender, err := diff_schemas(old_schema, new_schema, context.temp_allocator)
	testing.expect_value(t, err, Schema_Diff_Error.Rename_Type_Changed)
	testing.expect_value(t, offender, "hp")
}

@(test)
test_diff_retype_converts_old_value :: proc(t: ^testing.T) {
	old_schema := []Schema_Field{sf("hp", "Int")}
	new_schema := []Schema_Field{sf_with("hp", "Fixed", "lift")}
	plan := expect_clean_plan(t, old_schema, new_schema)
	testing.expect_value(t, len(plan), 1)
	testing.expect_value(t, plan[0], Migration_Action{field = "hp", op = .Convert, source = "hp", convert = "lift"})
}

@(test)
test_diff_rename_retype_converts_from_prior_key :: proc(t: ^testing.T) {
	old_schema := []Schema_Field{sf("speed", "Int")}
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
	old_schema := []Schema_Field{sf("hp", "Int")}
	new_schema := []Schema_Field{sf("hp", "Fixed")}
	_, offender, err := diff_schemas(old_schema, new_schema, context.temp_allocator)
	testing.expect_value(t, err, Schema_Diff_Error.Retype_Without_Migrate)
	testing.expect_value(t, offender, "hp")
}

@(test)
test_diff_duplicate_field_name_refused :: proc(t: ^testing.T) {
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
	schema := []Schema_Field{sf("hp", "Int"), sf("pos", "Vec2"), sf_default("score", "Int", "=0")}
	plan := expect_clean_plan(t, schema, schema)
	testing.expect_value(t, len(plan), 3)
	for action, i in plan {
		testing.expect_value(t, action, Migration_Action{field = schema[i].name, op = .Carry, source = schema[i].name})
	}
}

@(test)
test_diff_double_diff_bit_identical :: proc(t: ^testing.T) {
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
