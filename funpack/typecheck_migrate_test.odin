// The §05 §6 @migrate admissibility gate (check_migrations): a rename's prior
// name must not collide with a live name — a field-level `from:` against the
// same data's current field set, a decl-level `from:` against the module's
// declared types — and a retype's conversion must be an admissible
// `fn(Old) -> New` (declared in this module, exactly one parameter, returning
// the migrated field's declared type). Each deviation has its own named
// Type_Error verdict, mirroring the layer-registry mold: pure-AST membership
// rules checked before body typing, self-contained sources per test.
package funpack

import "core:testing"

// typecheck_migrate runs the full single-module pipeline over a source — the
// same lex → parse → typecheck path the layer-registry fixtures use — and
// returns the typecheck verdict. Parse must succeed: these fixtures probe the
// typecheck gate, never the parser's.
typecheck_migrate :: proc(t: ^testing.T, source: string) -> Type_Error {
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return .None
	}
	_, err := stage_typecheck(ast)
	return err
}

@(test)
test_migrate_rename_fresh_name_passes :: proc(t: ^testing.T) {
	// AC (admissible rename): a prior key naming no current field of the data
	// passes — the old name is genuinely retired.
	err := typecheck_migrate(t,
		"data Player {\n" +
		"  @migrate(from: \"old_hp\")\n" +
		"  hp: Int\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_migrate_rename_live_sibling_collision_rejected :: proc(t: ^testing.T) {
	// AC (rename collision): a `from:` naming a CURRENT field of the same data
	// contradicts the rename — the "prior" key is still live, so the
	// name-keyed diff (spec §09 §4) would be ambiguous.
	err := typecheck_migrate(t,
		"data Player {\n" +
		"  @migrate(from: \"mana\")\n" +
		"  hp: Int\n" +
		"  mana: Int\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Migrate_From_Collision)
}

@(test)
test_migrate_rename_self_collision_rejected :: proc(t: ^testing.T) {
	// A `from:` naming the field's own (live) name renames nothing — the
	// degenerate collision, caught by the same live-field rule.
	err := typecheck_migrate(t,
		"data Player {\n" +
		"  @migrate(from: \"hp\")\n" +
		"  hp: Int\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Migrate_From_Collision)
}

@(test)
test_migrate_type_rename_fresh_name_passes :: proc(t: ^testing.T) {
	// AC (admissible type rename): a decl-level prior type name no current
	// declaration holds passes.
	err := typecheck_migrate(t,
		"@migrate(from: \"OldPlayer\")\n" +
		"data Player { hp: Int }\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_migrate_type_rename_live_type_collision_rejected :: proc(t: ^testing.T) {
	// A decl-level `from:` naming a type the module still declares is the
	// symmetric collision: the "prior" type is live, so the rename
	// contradicts itself.
	err := typecheck_migrate(t,
		"data OldPlayer { hp: Int }\n" +
		"@migrate(from: \"OldPlayer\")\n" +
		"data Player { hp: Int }\n")
	testing.expect_value(t, err, Type_Error.Migrate_From_Collision)
}

@(test)
test_migrate_type_rename_live_enum_collision_rejected :: proc(t: ^testing.T) {
	// The live set spans every declared type kind — an enum under the prior
	// name collides exactly like a data type.
	err := typecheck_migrate(t,
		"enum OldPlayer { Alive, Dead }\n" +
		"@migrate(from: \"OldPlayer\")\n" +
		"data Player { hp: Int }\n")
	testing.expect_value(t, err, Type_Error.Migrate_From_Collision)
}

@(test)
test_migrate_convert_admissible_passes :: proc(t: ^testing.T) {
	// AC (admissible conversion): `with:` resolves to a declared single-param
	// fn returning the field's declared (new) type — the spec's
	// `fn(Old) -> New` shape; the parameter's type is the migration's claim
	// about Old, not checkable against the absent prior schema.
	err := typecheck_migrate(t,
		"data Player {\n" +
		"  @migrate(with: lift)\n" +
		"  hp: Int\n" +
		"}\n" +
		"fn lift(old: Fixed) -> Int {\n" +
		"  return 1\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_migrate_convert_unknown_fn_rejected :: proc(t: ^testing.T) {
	// A conversion naming no fn this module declares cannot run at migration
	// time — the named unknown-fn verdict, never a deferred lookup.
	err := typecheck_migrate(t,
		"data Player {\n" +
		"  @migrate(with: missing_lift)\n" +
		"  hp: Int\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Migrate_Convert_Unknown)
}

@(test)
test_migrate_convert_wrong_arity_rejected :: proc(t: ^testing.T) {
	// `fn(Old) -> New` takes exactly the old value — a two-parameter fn has no
	// defined second argument at migration time.
	err := typecheck_migrate(t,
		"data Player {\n" +
		"  @migrate(with: lift)\n" +
		"  hp: Int\n" +
		"}\n" +
		"fn lift(old: Fixed, scale: Fixed) -> Int {\n" +
		"  return 1\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Migrate_Convert_Arity)
}

@(test)
test_migrate_convert_wrong_return_rejected :: proc(t: ^testing.T) {
	// The conversion must land on New — a return type differing from the
	// field's declared type would write a wrongly-typed column.
	err := typecheck_migrate(t,
		"data Player {\n" +
		"  @migrate(with: lift)\n" +
		"  hp: Int\n" +
		"}\n" +
		"fn lift(old: Int) -> Fixed {\n" +
		"  return 1.0\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Migrate_Convert_Return)
}

@(test)
test_migrate_rename_retype_combined_checks_both :: proc(t: ^testing.T) {
	// The combined form runs both halves: the fresh prior key passes the
	// collision rule and the conversion passes the shape rule.
	err := typecheck_migrate(t,
		"data Player {\n" +
		"  @migrate(from: \"speed\", with: to_velocity)\n" +
		"  vel: Fixed\n" +
		"}\n" +
		"fn to_velocity(old: Int) -> Fixed {\n" +
		"  return 1.0\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}
