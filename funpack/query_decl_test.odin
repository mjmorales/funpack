// The §08 §3 query-declaration surface: the QueryDecl parse production
// (grammar/fun.ebnf §7), the §05 §3 @index/@spatial prefix directives with
// their lexical-core §5 FieldPath argument, the named wrong-placement and
// malformed-path verdicts (the @todo/@migrate mold), the check_index_paths
// typecheck gate (the path must name a declared thing and one of its fields),
// query-body typing through the shared check_fn_body window, and the gate /
// release-ban admission of query bodies. Self-contained sources per test.
package funpack

import "core:strings"
import "core:testing"

// typecheck_query runs the lex → parse → typecheck path over a source and
// returns the typecheck verdict (the typecheck_migrate idiom). Parse must
// succeed: these fixtures probe the typecheck gate, never the parser's.
typecheck_query :: proc(t: ^testing.T, source: string) -> Type_Error {
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return .None
	}
	_, err := stage_typecheck(ast)
	return err
}

@(test)
test_parse_query_decl_with_spatial :: proc(t: ^testing.T) {
	// AC (parse): the §08 §3 exemplar shape — a @spatial requirement prefixing
	// a query whose signature and Block body parse like a fn's.
	source := "@spatial(Enemy.cell)\n" +
		"query enemies_near(origin: Vec2, r: Fixed) -> [Vec2] {\n" +
		"  return [origin]\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.queries), 1)
	if len(ast.queries) != 1 {
		return
	}
	query := ast.queries[0]
	testing.expect_value(t, query.name, "enemies_near")
	testing.expect_value(t, len(query.params), 2)
	testing.expect_value(t, query.params[0].name, "origin")
	testing.expect_value(t, query.params[1].name, "r")
	testing.expect_value(t, query.return_type.name, "[]")
	testing.expect_value(t, len(query.body), 1)
	testing.expect_value(t, query.line, 2)
	testing.expect_value(t, len(query.indexes), 1)
	if len(query.indexes) != 1 {
		return
	}
	testing.expect_value(t, query.indexes[0].kind, Index_Directive_Kind.Spatial)
	testing.expect_value(t, query.indexes[0].thing, "Enemy")
	testing.expect_value(t, query.indexes[0].field, "cell")
	testing.expect_value(t, query.indexes[0].line, 1)
}

@(test)
test_parse_query_directives_carry :: proc(t: ^testing.T) {
	// A query consumes the whole accumulated directive set like any
	// declaration: @doc/@gtag/@todo plus SEVERAL @index/@spatial requirements,
	// in authored order.
	source := "@doc(\"Nearest pickups by cell.\")\n" +
		"@gtag(\"pickups\")\n" +
		"@todo(\"tune the radius\", T-0042)\n" +
		"@index(Pickup.cell)\n" +
		"@spatial(Pickup.pos)\n" +
		"query pickups_near(origin: Vec2) -> [Vec2] {\n" +
		"  return [origin]\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.queries), 1)
	if len(ast.queries) != 1 {
		return
	}
	query := ast.queries[0]
	testing.expect_value(t, query.doc, "Nearest pickups by cell.")
	testing.expect_value(t, len(query.gtags), 1)
	testing.expect_value(t, len(query.todos), 1)
	testing.expect_value(t, len(query.indexes), 2)
	if len(query.indexes) != 2 {
		return
	}
	testing.expect_value(t, query.indexes[0].kind, Index_Directive_Kind.Index)
	testing.expect_value(t, query.indexes[0].field, "cell")
	testing.expect_value(t, query.indexes[1].kind, Index_Directive_Kind.Spatial)
	testing.expect_value(t, query.indexes[1].field, "pos")
}

@(test)
test_index_wrong_target_named_verdict :: proc(t: ^testing.T) {
	// AC (placement): §08 §3 places @index/@spatial on a `query` declaration —
	// the spec names no other target — so any other consumer is the named
	// Index_Wrong_Target, the @migrate wrong-target mold.
	wrong_targets := [4]string{
		"@index(Door.gate)\nthing Door { gate: Int }\n",
		"@spatial(Door.gate)\ndata Door { gate: Int }\n",
		"@index(Door.gate)\nfn opener() -> Int {\n  return 1\n}\n",
		"@index(Door.gate)\nsignal Opened {}\n",
	}
	for source in wrong_targets {
		_, err := stage_parse(stage_lex(source))
		testing.expect_value(t, err, Parse_Error.Index_Wrong_Target)
	}
}

@(test)
test_index_malformed_path_named_verdict :: proc(t: ^testing.T) {
	// AC (named diagnostic): a path outside the closed `(Thing.field)` shape is
	// the named Malformed_Index_Path — missing parens, empty list, missing dot,
	// trailing junk — so an agent repairs the exact path shape.
	tail := "query q(origin: Vec2) -> Vec2 {\n  return origin\n}\n"
	malformed := [5]string{
		"@index\n",
		"@index()\n",
		"@index(Door)\n",
		"@index(Door.gate.extra)\n",
		"@spatial(Door, gate)\n",
	}
	for head in malformed {
		source := strings.concatenate({head, tail}, context.temp_allocator)
		_, err := stage_parse(stage_lex(source))
		testing.expect_value(t, err, Parse_Error.Malformed_Index_Path)
	}
}

@(test)
test_index_path_casing_keeps_wrong_case :: proc(t: ^testing.T) {
	// The casing-class deviations keep the parser-wide Wrong_Case verdict (the
	// parse_migrate_args precedent): a lowercase thing head, a non-snake_case
	// field — and an UpperCamel query name.
	tail := "query q(origin: Vec2) -> Vec2 {\n  return origin\n}\n"
	head_source := strings.concatenate({"@index(door.gate)\n", tail}, context.temp_allocator)
	_, head_err := stage_parse(stage_lex(head_source))
	testing.expect_value(t, head_err, Parse_Error.Wrong_Case)
	field_source := strings.concatenate({"@spatial(Door.Gate)\n", tail}, context.temp_allocator)
	_, field_err := stage_parse(stage_lex(field_source))
	testing.expect_value(t, field_err, Parse_Error.Wrong_Case)
	_, name_err := stage_parse(stage_lex("query Recent(origin: Vec2) -> Vec2 {\n  return origin\n}\n"))
	testing.expect_value(t, name_err, Parse_Error.Wrong_Case)
}

@(test)
test_query_body_admits_no_stub_hole :: proc(t: ^testing.T) {
	// QueryDecl takes a Block, never a StubExpr body (grammar/fun.ebnf §7) —
	// a `@stub` where the body brace belongs is a clean Unexpected_Token.
	_, err := stage_parse(stage_lex("query q(origin: Vec2) -> Vec2 @stub(Vec2)\n"))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_query_typechecks_against_declared_schemas :: proc(t: ^testing.T) {
	// AC (typecheck): a well-typed query over a declared thing's schema —
	// the @spatial path resolves to the thing and its field, the body returns
	// the declared type.
	err := typecheck_query(t,
		"thing Enemy { cell: Vec2 }\n" +
		"@spatial(Enemy.cell)\n" +
		"query nearest_cell(origin: Vec2) -> Vec2 {\n" +
		"  return origin\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_index_unknown_thing_named_verdict :: proc(t: ^testing.T) {
	// AC (named diagnostic): the path head must name a declared thing — an
	// undeclared name, and a `data` head (the §05 §3 index is INSTANCE-level,
	// only a thing has rows), are each Index_Unknown_Thing.
	err := typecheck_query(t,
		"@index(Ghost.cell)\n" +
		"query q(origin: Vec2) -> Vec2 {\n" +
		"  return origin\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Index_Unknown_Thing)
	data_err := typecheck_query(t,
		"data Board { cell: Vec2 }\n" +
		"@index(Board.cell)\n" +
		"query q(origin: Vec2) -> Vec2 {\n" +
		"  return origin\n" +
		"}\n")
	testing.expect_value(t, data_err, Type_Error.Index_Unknown_Thing)
}

@(test)
test_index_unknown_field_named_verdict :: proc(t: ^testing.T) {
	// AC (named diagnostic): a declared thing but a field its schema lacks is
	// Index_Unknown_Field.
	err := typecheck_query(t,
		"thing Enemy { cell: Vec2 }\n" +
		"@index(Enemy.speed)\n" +
		"query q(origin: Vec2) -> Vec2 {\n" +
		"  return origin\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Index_Unknown_Field)
}

@(test)
test_query_body_ill_typed_named_verdicts :: proc(t: ^testing.T) {
	// AC (named diagnostics): an ill-typed query body surfaces the same named
	// verdicts a fn body gets — a return off the declared type is
	// Type_Mismatch, a free name nothing declares is Unresolved_Name.
	mismatch := typecheck_query(t,
		"query q(origin: Vec2) -> Fixed {\n" +
		"  return origin\n" +
		"}\n")
	testing.expect_value(t, mismatch, Type_Error.Type_Mismatch)
	unresolved := typecheck_query(t,
		"query q(origin: Vec2) -> Vec2 {\n" +
		"  return phantom\n" +
		"}\n")
	testing.expect_value(t, unresolved, Type_Error.Unresolved_Name)
}

@(test)
test_query_callable_and_collides_like_a_term :: proc(t: ^testing.T) {
	// A query is a value-position callable (spec §08 §3: its read-set composes
	// into callers): a test calls it through the same call_check a fn rides,
	// with arguments checked against the recorded signature. One name, one
	// meaning still holds: a fn and a query under one name is Name_Collision.
	callable := typecheck_query(t,
		"query doubled(x: Fixed) -> Fixed {\n" +
		"  return x * 2.0\n" +
		"}\n" +
		"test \"query call composes\" {\n" +
		"  assert doubled(2.0) == 4.0\n" +
		"}\n")
	testing.expect_value(t, callable, Type_Error.None)
	arity := typecheck_query(t,
		"query doubled(x: Fixed) -> Fixed {\n" +
		"  return x * 2.0\n" +
		"}\n" +
		"test \"bad arity\" {\n" +
		"  assert doubled(2.0, 3.0) == 4.0\n" +
		"}\n")
	testing.expect(t, arity != .None)
	collision := typecheck_query(t,
		"fn doubled(x: Fixed) -> Fixed {\n" +
		"  return x * 2.0\n" +
		"}\n" +
		"query doubled(x: Fixed) -> Fixed {\n" +
		"  return x * 2.0\n" +
		"}\n")
	testing.expect_value(t, collision, Type_Error.Name_Collision)
}

@(test)
test_query_body_is_a_gate_unit :: proc(t: ^testing.T) {
	// A query body is a code unit the structural gates score (spec §01 P5: no
	// per-site waiver): two queries whose bodies normalize to the same AST hash
	// collide on the duplication gate exactly like two fns would.
	source := "query first_pick(x: Fixed, y: Fixed) -> Fixed {\n" +
		"  let scaled = x * 2.0 + y\n" +
		"  return scaled + 1.0\n" +
		"}\n" +
		"query second_pick(x: Fixed, y: Fixed) -> Fixed {\n" +
		"  let scaled = x * 2.0 + y\n" +
		"  return scaled + 1.0\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, stage_gates(ast), Gate_Error.Duplicate_Declaration)
}

@(test)
test_query_expression_hole_release_banned :: proc(t: ^testing.T) {
	// A §15 StubExpr expression-position hole inside a query body is found by
	// the release hole-ban walk (release_holed_decl), naming the query.
	source := "query q(origin: Vec2) -> Fixed {\n" +
		"  return @stub(Fixed, 1.0)\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	declaration, holed := release_holed_decl(ast)
	testing.expect(t, holed)
	testing.expect_value(t, declaration, "q")
}

@(test)
test_query_probe_release_banned :: proc(t: ^testing.T) {
	// A §05 §5 debug probe on a query declaration is found by the release
	// debug-directive ban walk (release_debug_decl), naming the query.
	source := "@log(origin)\n" +
		"query q(origin: Vec2) -> Vec2 {\n" +
		"  return origin\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	declaration, probed := release_debug_decl(ast)
	testing.expect(t, probed)
	testing.expect_value(t, declaration, "q")
}
