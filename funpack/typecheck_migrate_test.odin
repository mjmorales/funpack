package funpack

import "core:testing"

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
	err := typecheck_migrate(t,
		"data Player {\n" +
		"  @migrate(from: \"old_hp\")\n" +
		"  hp: Int\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_migrate_rename_live_sibling_collision_rejected :: proc(t: ^testing.T) {
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
	err := typecheck_migrate(t,
		"data Player {\n" +
		"  @migrate(from: \"hp\")\n" +
		"  hp: Int\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Migrate_From_Collision)
}

@(test)
test_migrate_type_rename_fresh_name_passes :: proc(t: ^testing.T) {
	err := typecheck_migrate(t,
		"@migrate(from: \"OldPlayer\")\n" +
		"data Player { hp: Int }\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_migrate_type_rename_live_type_collision_rejected :: proc(t: ^testing.T) {
	err := typecheck_migrate(t,
		"data OldPlayer { hp: Int }\n" +
		"@migrate(from: \"OldPlayer\")\n" +
		"data Player { hp: Int }\n")
	testing.expect_value(t, err, Type_Error.Migrate_From_Collision)
}

@(test)
test_migrate_type_rename_live_enum_collision_rejected :: proc(t: ^testing.T) {
	err := typecheck_migrate(t,
		"enum OldPlayer { Alive, Dead }\n" +
		"@migrate(from: \"OldPlayer\")\n" +
		"data Player { hp: Int }\n")
	testing.expect_value(t, err, Type_Error.Migrate_From_Collision)
}

@(test)
test_migrate_convert_admissible_passes :: proc(t: ^testing.T) {
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
	err := typecheck_migrate(t,
		"data Player {\n" +
		"  @migrate(with: missing_lift)\n" +
		"  hp: Int\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Migrate_Convert_Unknown)
}

@(test)
test_migrate_convert_wrong_arity_rejected :: proc(t: ^testing.T) {
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
