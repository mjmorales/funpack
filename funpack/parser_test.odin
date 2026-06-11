package funpack

import "core:testing"

@(test)
test_parse_module_doc :: proc(t: ^testing.T) {
	tokens := stage_lex("@doc(\"the module doc\")\nimport engine.list.fold\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.module_doc, "the module doc")
}

// A blank line between the file-leading @doc and the first import must not drop
// the module doc: the import check skips any run of newlines after the doc's
// terminator.
@(test)
test_parse_module_doc_blank_line_before_import :: proc(t: ^testing.T) {
	tokens := stage_lex("@doc(\"the module doc\")\n\nimport engine.list.fold\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.module_doc, "the module doc")
}

// Several blank lines between the @doc and the first import attribute the same
// way — the skip is over a run of newlines, not a single one.
@(test)
test_parse_module_doc_many_blank_lines_before_import :: proc(t: ^testing.T) {
	tokens := stage_lex("@doc(\"the module doc\")\n\n\n\nimport engine.list.fold\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.module_doc, "the module doc")
}

// A file-leading @doc followed (across a blank line) by a declaration keyword
// rather than an import is that declaration's doc, NOT the module doc — the
// blank-line skip must not misfile the doc when no import follows.
@(test)
test_parse_first_doc_before_decl_not_module_doc :: proc(t: ^testing.T) {
	tokens := stage_lex("@doc(\"the data doc\")\n\ndata Pt { x: Int }\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.module_doc, "")
	testing.expect_value(t, len(ast.datas), 1)
	testing.expect_value(t, ast.datas[0].doc, "the data doc")
}

@(test)
test_parse_per_test_doc_attaches :: proc(t: ^testing.T) {
	tokens := stage_lex("@doc(\"module\")\nimport assets\n@doc(\"the test doc\")\ntest \"x\" {\n}\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.module_doc, "module")
	testing.expect_value(t, len(ast.tests), 1)
	testing.expect_value(t, ast.tests[0].doc, "the test doc")
}

@(test)
test_parse_import_whole_module :: proc(t: ^testing.T) {
	tokens := stage_lex("import assets\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.imports), 1)
	testing.expect_value(t, len(ast.imports[0].segments), 1)
	testing.expect_value(t, ast.imports[0].segments[0], "assets")
	testing.expect_value(t, len(ast.imports[0].members), 0)
}

@(test)
test_parse_import_single_member :: proc(t: ^testing.T) {
	tokens := stage_lex("import engine.prelude.Option\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.imports[0].segments), 3)
	testing.expect_value(t, ast.imports[0].segments[2], "Option")
	testing.expect_value(t, len(ast.imports[0].members), 0)
}

@(test)
test_parse_import_member_group :: proc(t: ^testing.T) {
	tokens := stage_lex("import engine.math.{Vec2, abs, MAX}\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.imports[0].segments), 2)
	testing.expect_value(t, ast.imports[0].segments[1], "math")
	testing.expect_value(t, len(ast.imports[0].members), 3)
	testing.expect_value(t, ast.imports[0].members[0], "Vec2")
	testing.expect_value(t, ast.imports[0].members[2], "MAX")
}

@(test)
test_parse_import_group_newline_separated :: proc(t: ^testing.T) {
	// Members separate by `,` or newline — both legal (spec §02).
	tokens := stage_lex("import engine.math.{\n  Vec2\n  abs,\n  fold\n}\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.imports[0].members), 3)
}

@(test)
test_parse_import_interior_segment_wrong_case :: proc(t: ^testing.T) {
	// An interior path segment is a module name — snake_case only.
	tokens := stage_lex("import Engine.math.fold\n")
	_, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_test_body_let_then_assert :: proc(t: ^testing.T) {
	tokens := stage_lex("test \"quat\" {\nlet v = 1.0\nassert to_fixed(2) == 2.0\n}\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.tests[0].body), 2)
	let_node, is_let := ast.tests[0].body[0].(Let_Node)
	testing.expect(t, is_let)
	testing.expect_value(t, let_node.name, "v")
	_, value_is_fixed := let_node.value.(^Fixed_Lit_Expr)
	testing.expect(t, value_is_fixed)
	_, is_assert := ast.tests[0].body[1].(Assert_Node)
	testing.expect(t, is_assert)
}

@(test)
test_parse_let_wrong_case_name :: proc(t: ^testing.T) {
	tokens := stage_lex("test \"x\" {\nlet Vec = 1.0\n}\n")
	_, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_match_well_formed :: proc(t: ^testing.T) {
	// A well-formed match over the minimal pattern set — variant with
	// binders, bare variant, wildcard — parses to Parse_Error.None
	// (spec §02 §5).
	source := "match seen {\n" +
		"  Option::Some(p) => p\n" +
		"  Option::None => 0\n" +
		"  _ => 1\n" +
		"}\n"
	p := Parser{tokens = stage_lex(source)}
	expr, err := parse_match_from_keyword(&p)
	testing.expect_value(t, err, Parse_Error.None)
	m, is_match := expr.(^Match_Expr)
	testing.expect(t, is_match)
	if !is_match {
		return
	}
	testing.expect_value(t, len(m.arms), 3)
	testing.expect_value(t, m.arms[0].pattern.kind, Pattern_Kind.Variant_Binds)
	testing.expect_value(t, m.arms[0].pattern.type_name, "Option")
	testing.expect_value(t, m.arms[0].pattern.variant, "Some")
	// The payload is now a nested sub-pattern (grammar §13): Option::Some(p) carries
	// one element, the Bare_Binder `p`.
	testing.expect_value(t, len(m.arms[0].pattern.elements), 1)
	testing.expect_value(t, m.arms[0].pattern.elements[0].kind, Pattern_Kind.Bare_Binder)
	testing.expect_value(t, len(m.arms[0].pattern.elements[0].binders), 1)
	testing.expect_value(t, m.arms[0].pattern.elements[0].binders[0], "p")
	testing.expect_value(t, m.arms[1].pattern.kind, Pattern_Kind.Bare_Variant)
	testing.expect_value(t, m.arms[2].pattern.kind, Pattern_Kind.Wildcard)
	// The scrutinee is the bare value name, not a record literal off it.
	scrutinee, is_name := m.scrutinee.(^Name_Expr)
	testing.expect(t, is_name)
	if is_name {
		testing.expect_value(t, scrutinee.name, "seen")
	}
}

@(test)
test_parse_match_struct_payload_destructure :: proc(t: ^testing.T) {
	// The yard `box_size` shape (spec §02 §5): a struct-payload field-pun arm
	// `Shape2::Box{size} => size` binds the field `size` by name, parallel to
	// the value-side struct-payload Variant_Expr. A wildcard arm follows.
	source := "match shape {\n" +
		"  Shape2::Box{size} => size\n" +
		"  _ => fallback\n" +
		"}\n"
	p := Parser{tokens = stage_lex(source)}
	expr, err := parse_match_from_keyword(&p)
	testing.expect_value(t, err, Parse_Error.None)
	m, is_match := expr.(^Match_Expr)
	testing.expect(t, is_match)
	if !is_match {
		return
	}
	testing.expect_value(t, len(m.arms), 2)
	pat := m.arms[0].pattern
	testing.expect_value(t, pat.kind, Pattern_Kind.Struct_Binds)
	testing.expect_value(t, pat.type_name, "Shape2")
	testing.expect_value(t, pat.variant, "Box")
	// The field-pun binder is the single field name `size` (binds `size` to the
	// `size` field).
	testing.expect_value(t, len(pat.binders), 1)
	testing.expect_value(t, pat.binders[0], "size")
	testing.expect_value(t, m.arms[1].pattern.kind, Pattern_Kind.Wildcard)
}

@(test)
test_parse_match_struct_payload_multi_field :: proc(t: ^testing.T) {
	// A struct-payload field-pun arm binds every named field, in source order —
	// the binder list pins more than one pun.
	expr, err := parse_expr_text("match shape { Shape2::Rect{w, h} => w, _ => h }")
	testing.expect_value(t, err, Parse_Error.None)
	m, is_match := expr.(^Match_Expr)
	testing.expect(t, is_match)
	if !is_match {
		return
	}
	pat := m.arms[0].pattern
	testing.expect_value(t, pat.kind, Pattern_Kind.Struct_Binds)
	testing.expect_value(t, len(pat.binders), 2)
	testing.expect_value(t, pat.binders[0], "w")
	testing.expect_value(t, pat.binders[1], "h")
}

@(test)
test_parse_match_struct_payload_wrong_case_field_rejected :: proc(t: ^testing.T) {
	// A field-pun binder is a value name — snake_case (spec §02); an UpperCamel
	// field name in the pun position rejects as Wrong_Case.
	_, err := parse_expr_text("match shape { Shape2::Box{Size} => 0, _ => 1 }")
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_match_comma_separated_arms :: proc(t: ^testing.T) {
	// `,` is a legal arm separator (Sep), so the inline one-line form
	// parses too (spec §02 §5).
	expr, err := parse_expr_text("match self { Screen::Hud => 1, _ => 2 }")
	testing.expect_value(t, err, Parse_Error.None)
	m, is_match := expr.(^Match_Expr)
	testing.expect(t, is_match)
	if is_match {
		testing.expect_value(t, len(m.arms), 2)
	}
}

@(test)
test_parse_match_missing_arrow_rejected :: proc(t: ^testing.T) {
	// A malformed arm — the `=>` separator omitted — rejects at parse.
	expr, err := parse_expr_text("match seen {\n  Option::None 0\n}\n")
	testing.expect(t, err != .None)
	testing.expect(t, expr == nil)
}

@(test)
test_parse_match_bad_pattern_case_rejected :: proc(t: ^testing.T) {
	// A bad pattern — a snake_case head where the variant pattern demands
	// an UpperCamel enum type — rejects as Wrong_Case (spec §02).
	_, err := parse_expr_text("match seen {\n  option::None => 0\n}\n")
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

// parse_match_from_keyword consumes the leading `match` token then
// delegates to parse_match — mirroring how parse_atom dispatches the
// keyword, for a test that drives parse_match directly.
parse_match_from_keyword :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	expect(p, .Match) or_return
	return parse_match(p)
}

@(test)
test_parse_golden_prefix :: proc(t: ^testing.T) {
	// The golden file's opening shape: module doc, the three import
	// forms, a documented test block.
	source := "@doc(\"contract\")\n" +
		"import engine.prelude.Option\n" +
		"import engine.math.{to_fixed, pi}\n" +
		"import engine.list.fold\n" +
		"\n" +
		"@doc(\"literals\")\n" +
		"test \"literals and explicit conversion\" {\n" +
		"  assert to_fixed(2) == 2.0\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.module_doc, "contract")
	testing.expect_value(t, len(ast.imports), 3)
	testing.expect_value(t, len(ast.tests), 1)
	testing.expect_value(t, ast.tests[0].doc, "literals")
	testing.expect_value(t, len(ast.tests[0].body), 1)
}

@(test)
test_parse_data_decl_with_fields :: proc(t: ^testing.T) {
	// `data Name { field: T = default … }` (spec §03 §1): a plain field and
	// a defaulted field, both kept in declaration order.
	ast, err := stage_parse(stage_lex("data Board { w: Fixed, h: Fixed = 120.0 }\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.datas), 1)
	d := ast.datas[0]
	testing.expect_value(t, d.name, "Board")
	testing.expect_value(t, d.kind, "")
	testing.expect_value(t, len(d.fields), 2)
	testing.expect_value(t, d.fields[0].name, "w")
	testing.expect_value(t, d.fields[0].type.name, "Fixed")
	testing.expect(t, !d.fields[0].has_default)
	testing.expect(t, d.fields[1].has_default)
}

@(test)
test_parse_enum_as_role_kind :: proc(t: ^testing.T) {
	// The §03/§06 enum-as-role form `enum Steer: Axis { Move }`: a kind
	// ascription after the type name, contextual (Axis is not reserved).
	ast, err := stage_parse(stage_lex("enum Steer: Axis { Move }\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.enums), 1)
	e := ast.enums[0]
	testing.expect_value(t, e.name, "Steer")
	testing.expect_value(t, e.kind, "Axis")
	testing.expect_value(t, len(e.variants), 1)
	testing.expect_value(t, e.variants[0].name, "Move")
	testing.expect_value(t, e.variants[0].payload, Variant_Payload.Plain)
}

@(test)
test_parse_enum_payload_variants :: proc(t: ^testing.T) {
	// Plain, tuple-payload, and struct-payload variants in one enum
	// (spec §03 §2).
	source := "enum PathOp {\n" +
		"  Close\n" +
		"  MoveTo(Vec2)\n" +
		"  CubicTo{ c1: Vec2, to: Vec2 }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	e := ast.enums[0]
	testing.expect_value(t, len(e.variants), 3)
	testing.expect_value(t, e.variants[0].payload, Variant_Payload.Plain)
	testing.expect_value(t, e.variants[1].payload, Variant_Payload.Tuple)
	testing.expect_value(t, len(e.variants[1].tuple), 1)
	testing.expect_value(t, e.variants[2].payload, Variant_Payload.Struct)
	testing.expect_value(t, len(e.variants[2].fields), 2)
}

// ── §05 §1 @doc on enum variants ──────────────────────────────────────────────
// A variant admits exactly @doc ("each `Draw` variant carries a @doc" —
// fun.ebnf §4 Variant ::= Directive* UPPER_IDENT VariantPayload?); the carry is
// Variant_Decl.doc. Every other directive in variant position is a keyed
// wrong-target verdict: @migrate/@index/@spatial keep their directive-keyed
// verdicts, the rest of the declaration family is
// Variant_Directive_Wrong_Target — the @migrate Migrate_Wrong_Target mold.

@(test)
test_parse_variant_doc_carried :: proc(t: ^testing.T) {
	// The stdlib render.fun shape: each @doc on its own line above its variant
	// (struct, tuple, and plain payloads), the enum's own @doc untouched, and a
	// doc-less variant carrying "".
	source := "@doc(\"A 2D draw command.\")\n" +
		"enum Draw {\n" +
		"  @doc(\"A filled rectangle.\")\n" +
		"  Rect{ at: Vec2, color: Color },\n" +
		"  @doc(\"A move-to op.\")\n" +
		"  MoveTo(Vec2),\n" +
		"  Close\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	if err != .None {
		return
	}
	e := ast.enums[0]
	testing.expect_value(t, e.doc, "A 2D draw command.")
	testing.expect_value(t, len(e.variants), 3)
	testing.expect_value(t, e.variants[0].doc, "A filled rectangle.")
	testing.expect_value(t, e.variants[0].payload, Variant_Payload.Struct)
	testing.expect_value(t, e.variants[1].doc, "A move-to op.")
	testing.expect_value(t, e.variants[1].payload, Variant_Payload.Tuple)
	testing.expect_value(t, e.variants[2].doc, "")
	testing.expect_value(t, e.variants[2].payload, Variant_Payload.Plain)
}

@(test)
test_parse_variant_doc_inline :: proc(t: ^testing.T) {
	// The grammar puts no line break between a variant's directives and its
	// name (fun.ebnf §4), so the inline spelling parses too — attached to the
	// variant that follows, the field-level inline-@migrate mold.
	source := "enum Side { @doc(\"The left side.\") Left, Right }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	if err != .None {
		return
	}
	e := ast.enums[0]
	testing.expect_value(t, len(e.variants), 2)
	testing.expect_value(t, e.variants[0].doc, "The left side.")
	testing.expect_value(t, e.variants[1].doc, "")
}

@(test)
test_parse_variant_gtag_rejected :: proc(t: ^testing.T) {
	// @gtag labels an indexed declaration (spec §05 §1); a variant is not a
	// decl record, so a variant-position @gtag is the named wrong-target
	// verdict, never a silently dropped label.
	source := "enum Side { @gtag(\"side\") Left, Right }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Variant_Directive_Wrong_Target)
}

@(test)
test_parse_variant_todo_rejected :: proc(t: ^testing.T) {
	// @todo notes are index-recorded per declaration (spec §05 §2, §29 §2) —
	// no variant target exists.
	source := "enum Side {\n  @todo(\"rename\", T-0042)\n  Left\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Variant_Directive_Wrong_Target)
}

@(test)
test_parse_variant_probe_rejected :: proc(t: ^testing.T) {
	// The §05 §5 debug probes observe declarations and fields (fun.ebnf §1
	// Annotation positions), never a variant — the Variant production admits
	// Directive*, not Annotation*, so a probe there is wrong-target.
	source := "enum Side { @log(side) Left, Right }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Variant_Directive_Wrong_Target)
}

@(test)
test_parse_variant_expose_rejected :: proc(t: ^testing.T) {
	// @expose publishes a DECLARATION into the external contract (spec §05
	// §4); a variant ships with its enum, so a variant-level @expose is
	// wrong-target.
	source := "enum Side { @expose Left, Right }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Variant_Directive_Wrong_Target)
}

@(test)
test_parse_variant_migrate_rejected :: proc(t: ^testing.T) {
	// @migrate keeps its directive-keyed verdict on a variant — the
	// schema-evolution channel targets data fields and renamed type
	// declarations only (spec §05 §6), mirroring the field-body rejection.
	source := "enum Side { @migrate(from: \"L\") Left, Right }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Migrate_Wrong_Target)
}

@(test)
test_parse_variant_index_rejected :: proc(t: ^testing.T) {
	// @index/@spatial keep their directive-keyed verdict on a variant — §08
	// §3 places the index requirement on a `query` declaration only.
	source := "enum Side { @index(Enemy.cell) Left, Right }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Index_Wrong_Target)
}

@(test)
test_parse_variant_doc_dangling_rejected :: proc(t: ^testing.T) {
	// A @doc with no variant following it documents nothing — dangling at the
	// body's close is the wrong-target verdict (the dangling-@migrate mold).
	source := "enum Side {\n  Left\n  @doc(\"nothing follows\")\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Variant_Directive_Wrong_Target)
}

// fun.ll1.md §2 classifies `thing`/`singleton`/`data`/`enum`/`on` as CONTEXTUAL
// keywords: a keyword only where it opens a module-level declaration (or, for
// `on`, separates a behavior header), an ordinary §02 snake_case value name
// everywhere else. This proves the value-position direction the contextual rule
// adds — a binding name, an expression-position read, a member access, and a
// field name — all five words legal as identifiers. The declaration-position
// direction (keyword still selects the production) is held by
// test_parse_data_decl_with_fields / test_parse_enum_as_role_kind /
// test_parse_thing_and_singleton, which parse unchanged.
@(test)
test_contextual_keywords_legal_in_value_position :: proc(t: ^testing.T) {
	// A no-ascription `let <word> = …` binding: each contextual keyword is a legal
	// binding name (the latent restriction this story removes — the hard-keyword
	// lexer path rejected `let thing = …` before). The let value reads `on`, a
	// fifth contextual word, as an ordinary Name_Expr.
	source := "test \"contextual words bind\" {\n" +
		"  let thing = 1\n" +
		"  let singleton = 2\n" +
		"  let data = 3\n" +
		"  let enum = 4\n" +
		"  let on = thing\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.tests), 1)
	body := ast.tests[0].body
	testing.expect_value(t, len(body), 5)
	names := [5]string{"thing", "singleton", "data", "enum", "on"}
	for want, idx in names {
		let_node, is_let := body[idx].(Let_Node)
		testing.expect(t, is_let)
		if is_let {
			testing.expect_value(t, let_node.name, want)
		}
	}
	// The `on` binding's value is the bare value name `thing` — a Name_Expr, proof
	// a contextual word reads as an identifier in expression position, not a
	// keyword.
	on_let, on_is_let := body[4].(Let_Node)
	testing.expect(t, on_is_let)
	if on_is_let {
		name_expr, is_name := on_let.value.(^Name_Expr)
		testing.expect(t, is_name)
		if is_name {
			testing.expect_value(t, name_expr.name, "thing")
			testing.expect_value(t, name_expr.class, Ident_Class.Snake_Case)
		}
	}

	// A member-access receiver dotted into a contextual word: `s.data` reads the
	// `data` field, an Ident in member position.
	member_expr, member_err := parse_expr_text("s.data")
	testing.expect_value(t, member_err, Parse_Error.None)
	member, is_member := member_expr.(^Member_Expr)
	testing.expect(t, is_member)
	if is_member {
		testing.expect_value(t, member.member, "data")
	}

	// A contextual word as a data FIELD name: `enum: Bool` is a legal field, the
	// word an Ident the field grammar consumes.
	field_ast, field_err := stage_parse(stage_lex("data Flags { enum: Bool, thing: Int }\n"))
	testing.expect_value(t, field_err, Parse_Error.None)
	testing.expect_value(t, len(field_ast.datas), 1)
	testing.expect_value(t, len(field_ast.datas[0].fields), 2)
	testing.expect_value(t, field_ast.datas[0].fields[0].name, "enum")
	testing.expect_value(t, field_ast.datas[0].fields[1].name, "thing")

	// And the declaration-position direction in the SAME test: a `thing` opener
	// immediately after the field-name `thing` above still selects the thing
	// production — the word is the keyword only at the start of a module-level
	// statement.
	decl_ast, decl_err := stage_parse(stage_lex("thing Paddle { y: Fixed }\n"))
	testing.expect_value(t, decl_err, Parse_Error.None)
	testing.expect_value(t, len(decl_ast.things), 1)
	testing.expect_value(t, decl_ast.things[0].name, "Paddle")
	testing.expect(t, !decl_ast.things[0].is_singleton)
}

// fun.ll1.md §2 also lists `query` and `mut` as contextual keywords. `query`'s
// §08 §3 declaration production exists (parse_query), so it is in
// is_decl_opener_keyword and a module-level `query` opener dispatches to the
// query production — while staying an ordinary value name everywhere else, like
// `data`/`thing`. `mut`'s production does NOT exist (`mut data` (§03 §7) is
// unparsed — emit_data hardcodes mut=false), so it stays OUT of the set: a word
// arms a block only if its declaration parses. This pins both directions for
// each word — the value half (value-position legality, since query/mut never
// were hard keywords) and the declaration half (`query` dispatches its
// production; `mut` is a clean Unexpected_Token until its production lands and
// flips its expectation here).
@(test)
test_query_mut_contextual_value_only :: proc(t: ^testing.T) {
	// Value position: `let query = …` / `let mut = …` bind as ordinary snake_case
	// names; `mut`'s value reads the bare name `query` as a Name_Expr.
	source := "test \"query and mut bind\" {\n" +
		"  let query = 1\n" +
		"  let mut = query\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.tests), 1)
	body := ast.tests[0].body
	testing.expect_value(t, len(body), 2)
	q_let, q_is := body[0].(Let_Node)
	testing.expect(t, q_is)
	if q_is {
		testing.expect_value(t, q_let.name, "query")
	}
	m_let, m_is := body[1].(Let_Node)
	testing.expect(t, m_is)
	if m_is {
		testing.expect_value(t, m_let.name, "mut")
		name_expr, is_name := m_let.value.(^Name_Expr)
		testing.expect(t, is_name)
		if is_name {
			testing.expect_value(t, name_expr.name, "query")
			testing.expect_value(t, name_expr.class, Ident_Class.Snake_Case)
		}
	}

	// Field-name position: both legal as data field names, Idents the field grammar
	// consumes.
	field_ast, field_err := stage_parse(stage_lex("data Q { query: Int, mut: Bool }\n"))
	testing.expect_value(t, field_err, Parse_Error.None)
	testing.expect_value(t, len(field_ast.datas), 1)
	testing.expect_value(t, len(field_ast.datas[0].fields), 2)
	testing.expect_value(t, field_ast.datas[0].fields[0].name, "query")
	testing.expect_value(t, field_ast.datas[0].fields[1].name, "mut")

	// Declaration position: a module-level `query` opener now dispatches the
	// §08 §3 query production — `query Recent { … }` reaches parse_query and
	// fails on its UpperCamel name (a query name is snake_case), the
	// production's own verdict, not a generic token error. `mut` stays
	// DEFERRED: no production, so a clean Unexpected_Token — the guard that
	// keeps that deferral honest until `mut data` lands.
	_, q_decl_err := stage_parse(stage_lex("query Recent { since: Int }\n"))
	testing.expect_value(t, q_decl_err, Parse_Error.Wrong_Case)
	_, m_decl_err := stage_parse(stage_lex("mut Board { score: Int }\n"))
	testing.expect_value(t, m_decl_err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_thing_and_singleton :: proc(t: ^testing.T) {
	// `thing` and `singleton` share the body grammar; only the is_singleton
	// flag tells them apart (spec §06 §1–2). Scoreboard's Int fields carry
	// `= 0` defaults.
	source := "thing Ball { pos: Vec2, vel: Vec2 }\n" +
		"singleton Scoreboard { left: Int = 0, right: Int = 0 }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.things), 2)
	testing.expect_value(t, ast.things[0].name, "Ball")
	testing.expect(t, !ast.things[0].is_singleton)
	testing.expect_value(t, ast.things[1].name, "Scoreboard")
	testing.expect(t, ast.things[1].is_singleton)
	testing.expect(t, ast.things[1].fields[0].has_default)
}

@(test)
test_parse_signal_decl :: proc(t: ^testing.T) {
	// `signal Name { field: T }` (spec §03 §6, §06 §5).
	ast, err := stage_parse(stage_lex("signal Goal { side: Side }\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.signals), 1)
	testing.expect_value(t, ast.signals[0].name, "Goal")
	testing.expect_value(t, len(ast.signals[0].fields), 1)
	testing.expect_value(t, ast.signals[0].fields[0].type.name, "Side")
}

@(test)
test_parse_module_let_decl :: proc(t: ^testing.T) {
	// A module-level constant `let NAME: T = expr` (spec §02 §6–7), distinct
	// from a test-body let in carrying an explicit type ascription.
	ast, err := stage_parse(stage_lex("let BOARD: Board = Board{ w: 160.0, h: 120.0 }\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.lets), 1)
	testing.expect_value(t, ast.lets[0].name, "BOARD")
	testing.expect_value(t, ast.lets[0].type.name, "Board")
	_, value_is_record := ast.lets[0].value.(^Record_Expr)
	testing.expect(t, value_is_record)
}

@(test)
test_parse_top_level_fn_multistatement_body :: proc(t: ^testing.T) {
	// A top-level fn with a multi-statement body — a let then a return —
	// generalizing the single-return lambda the Pratt cascade carries.
	source := "fn advance(at: Vec2, vel: Vec2, dt: Fixed) -> Vec2 {\n" +
		"  let step = vel * dt\n" +
		"  return at + step\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 1)
	f := ast.fns[0]
	testing.expect_value(t, f.name, "advance")
	testing.expect_value(t, len(f.params), 3)
	testing.expect_value(t, f.params[2].name, "dt")
	testing.expect_value(t, f.return_type.name, "Vec2")
	testing.expect_value(t, len(f.body), 2)
	_, first_is_let := f.body[0].(Let_Node)
	testing.expect(t, first_is_let)
	_, second_is_return := f.body[1].(Return_Node)
	testing.expect(t, second_is_return)
}

@(test)
test_parse_fn_if_early_return_body :: proc(t: ^testing.T) {
	// An `if cond { return … }` early-return guard as a statement form in a
	// fn body (spec §02 §5). The condition ends in a field access whose
	// trailing `{` opens the guard block, not a record literal.
	source := "fn goal_side(at: Vec2) -> Option[Side] {\n" +
		"  if at.x < 0.0 { return Option::Some(Side::Right) }\n" +
		"  return Option::None\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	testing.expect_value(t, len(f.body), 2)
	if_node, first_is_if := f.body[0].(If_Node)
	testing.expect(t, first_is_if)
	if first_is_if {
		// The guard condition is the `at.x < 0.0` comparison, and the guarded
		// body holds the single early return.
		_, cond_is_binary := if_node.cond.(^Binary_Expr)
		testing.expect(t, cond_is_binary)
		testing.expect_value(t, len(if_node.body), 1)
		_, body_is_return := if_node.body[0].(Return_Node)
		testing.expect(t, body_is_return)
	}
}

@(test)
test_parse_behavior_with_reserved_step :: proc(t: ^testing.T) {
	// `behavior name on Thing { fn step(…) -> … { … } }` (spec §06 §3): the
	// reserved `step` entry point, its target, and its read parameters.
	source := "behavior paddle_move on Paddle {\n" +
		"  fn step(self: Paddle, input: Input, time: Time) -> Paddle {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.behaviors), 1)
	b := ast.behaviors[0]
	testing.expect_value(t, b.name, "paddle_move")
	testing.expect_value(t, b.target, "Paddle")
	testing.expect_value(t, b.step.name, "step")
	testing.expect_value(t, len(b.step.params), 3)
	testing.expect_value(t, b.step.return_type.name, "Paddle")
}

@(test)
test_parse_behavior_non_step_entry_rejected :: proc(t: ^testing.T) {
	// `step` is the built-in, reserved entry point (spec §06 §3); a behavior
	// names no other, so a `fn update(…)` body is rejected at parse.
	source := "behavior bad on Paddle {\n" +
		"  fn update(self: Paddle) -> Paddle {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_fn_stub_body :: proc(t: ^testing.T) {
	// A fn body may BE a typed hole (spec §05 §2; fun.ebnf §7 FnBody ::=
	// Block | StubExpr): `@stub(T)` records the hole flag and the declared T,
	// leaves the body empty, and carries no fallback.
	source := "fn serve(b: Ball) -> Ball @stub(Ball)\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 1)
	f := ast.fns[0]
	testing.expect_value(t, f.name, "serve")
	testing.expect_value(t, f.holed, true)
	testing.expect_value(t, f.hole_type.name, "Ball")
	testing.expect_value(t, f.has_fallback, false)
	testing.expect_value(t, len(f.body), 0)
}

@(test)
test_parse_fn_stub_body_with_fallback :: proc(t: ^testing.T) {
	// The two-argument form `@stub(T, fallback)` additionally records the
	// approximation expression (spec §05 §2).
	source := "fn speed() -> Fixed @stub(Fixed, 1.5)\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	testing.expect_value(t, f.holed, true)
	testing.expect_value(t, f.hole_type.name, "Fixed")
	testing.expect_value(t, f.has_fallback, true)
	_, fallback_is_fixed := f.fallback.(^Fixed_Lit_Expr)
	testing.expect(t, fallback_is_fixed)
}

@(test)
test_parse_fn_stub_body_generic_hole_type :: proc(t: ^testing.T) {
	// The declared hole type is a full Type_Ref — a generic application
	// parses like any `-> R` ascription would.
	source := "fn pick() -> Option[Side] @stub(Option[Side])\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	testing.expect_value(t, f.holed, true)
	testing.expect_value(t, f.hole_type.name, "Option")
	testing.expect_value(t, len(f.hole_type.args), 1)
	testing.expect_value(t, f.hole_type.args[0].name, "Side")
}

@(test)
test_parse_behavior_step_stub_body :: proc(t: ^testing.T) {
	// A behavior's reserved `step` entry point may be holed exactly like a fn
	// (parse_fn_rest is shared): the hole lands on Behavior_Node.step.
	source := "behavior serve on Ball {\n" +
		"  fn step(self: Ball) -> Ball @stub(Ball)\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.behaviors), 1)
	b := ast.behaviors[0]
	testing.expect_value(t, b.step.name, "step")
	testing.expect_value(t, b.step.holed, true)
	testing.expect_value(t, b.step.hole_type.name, "Ball")
	testing.expect_value(t, b.step.has_fallback, false)
}

@(test)
test_parse_stub_as_prefix_directive_rejected :: proc(t: ^testing.T) {
	// @stub is NOT a leading prefix directive (spec §05: it stands in
	// body/expression position only) — a declaration-prefixing `@stub` is a
	// parse error, never silently accepted.
	source := "@stub(Ball)\nfn serve(b: Ball) -> Ball {\n  return b\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_stub_inside_block_rejected :: proc(t: ^testing.T) {
	// The hole stands FOR the body, never inside one (fun.ebnf §7: FnBody is
	// Block OR StubExpr) — a `@stub(…)` as a block statement is a parse error.
	source := "fn serve(b: Ball) -> Ball {\n  @stub(Ball)\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_stub_missing_type_rejected :: proc(t: ^testing.T) {
	// `@stub()` declares no T to typecheck callers against — the hole type is
	// mandatory (spec §05 §2).
	source := "fn serve(b: Ball) -> Ball @stub()\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_non_stub_directive_in_body_position_rejected :: proc(t: ^testing.T) {
	// Only @stub may stand for a body: any other directive after `-> R` is an
	// Unexpected_Token in parse_stub_body's name check.
	source := "fn serve(b: Ball) -> Ball @doc(\"not a body\")\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_stub_expr_atom_bare :: proc(t: ^testing.T) {
	// A typed hole may stand in EXPRESSION position (spec §05 §2; fun.ebnf §15:
	// StubExpr is an Atom): `base + @stub(Fixed)` parses the hole as the
	// binary's rhs operand, the enclosing fn stays INTACT (holed false, body
	// present), and the bare form carries no fallback.
	source := "fn boost(base: Fixed) -> Fixed {\n  return base + @stub(Fixed)\n}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 1)
	f := ast.fns[0]
	testing.expect_value(t, f.holed, false)
	testing.expect_value(t, len(f.body), 1)
	ret, is_return := f.body[0].(Return_Node)
	testing.expect(t, is_return)
	if !is_return {
		return
	}
	binary, is_binary := ret.value.(^Binary_Expr)
	testing.expect(t, is_binary)
	if !is_binary {
		return
	}
	hole, is_stub := binary.rhs.(^Stub_Expr)
	testing.expect(t, is_stub)
	if !is_stub {
		return
	}
	testing.expect_value(t, hole.hole_type.name, "Fixed")
	testing.expect_value(t, hole.has_fallback, false)
}

@(test)
test_parse_stub_expr_atom_with_fallback :: proc(t: ^testing.T) {
	// The two-argument expression form `@stub(T, fallback)` records the
	// fallback approximation, here as a top-level `let` initializer — any
	// expression position admits the Atom.
	source := "let SPEED: Fixed = @stub(Fixed, 1.5)\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.lets), 1)
	hole, is_stub := ast.lets[0].value.(^Stub_Expr)
	testing.expect(t, is_stub)
	if !is_stub {
		return
	}
	testing.expect_value(t, hole.hole_type.name, "Fixed")
	testing.expect_value(t, hole.has_fallback, true)
	_, fallback_is_fixed := hole.fallback.(^Fixed_Lit_Expr)
	testing.expect(t, fallback_is_fixed)
}

@(test)
test_parse_stub_expr_atom_nested_positions :: proc(t: ^testing.T) {
	// The StubExpr Atom rides the Pratt cascade like any other atom: holes
	// nest inside a record literal's fields (one per field, bare and fallback
	// forms side by side), proving the production composes rather than being a
	// top-of-expression special case.
	source := "fn place() -> Vec2 {\n  return Vec2{x: @stub(Fixed), y: @stub(Fixed, 1.0)}\n}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	ret, is_return := ast.fns[0].body[0].(Return_Node)
	testing.expect(t, is_return)
	if !is_return {
		return
	}
	record, is_record := ret.value.(^Record_Expr)
	testing.expect(t, is_record)
	if !is_record {
		return
	}
	testing.expect_value(t, len(record.fields), 2)
	x_hole, x_is_stub := record.fields[0].value.(^Stub_Expr)
	testing.expect(t, x_is_stub)
	if x_is_stub {
		testing.expect_value(t, x_hole.has_fallback, false)
	}
	y_hole, y_is_stub := record.fields[1].value.(^Stub_Expr)
	testing.expect(t, y_is_stub)
	if y_is_stub {
		testing.expect_value(t, y_hole.has_fallback, true)
	}
}

@(test)
test_parse_stub_expr_atom_in_call_args :: proc(t: ^testing.T) {
	// A hole standing as a call argument parses through CallArgs like any
	// expression — `clamp(@stub(Fixed, 0.5), limit)` carries the hole at
	// argument position 0.
	source := "fn capped(limit: Fixed) -> Fixed {\n  return clamp(@stub(Fixed, 0.5), limit)\n}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	ret, is_return := ast.fns[0].body[0].(Return_Node)
	testing.expect(t, is_return)
	if !is_return {
		return
	}
	call, is_call := ret.value.(^Call_Expr)
	testing.expect(t, is_call)
	if !is_call {
		return
	}
	testing.expect_value(t, len(call.args), 2)
	_, arg_is_stub := call.args[0].(^Stub_Expr)
	testing.expect(t, arg_is_stub)
}

@(test)
test_parse_non_stub_directive_in_expression_rejected :: proc(t: ^testing.T) {
	// Only @stub names a value (spec §05: every other directive prefixes a
	// declaration) — a `@doc(…)` in expression position is an Unexpected_Token
	// in parse_stub_parts' name check, never silently accepted.
	source := "fn boost() -> Fixed {\n  return @doc(\"not a value\")\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_stub_expr_missing_type_rejected :: proc(t: ^testing.T) {
	// `@stub()` in expression position declares no T for the hole to ascribe —
	// the hole type is mandatory in both positions (spec §05 §2).
	source := "fn boost() -> Fixed {\n  return @stub()\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_stub_expr_missing_separator_rejected :: proc(t: ^testing.T) {
	// The fallback is comma-separated from the declared T (fun.ebnf §15:
	// StubExpr ::= '@stub' '(' Type (',' Expr)? ')') — two bare tokens inside
	// the parens are an Unexpected_Token at the missing `)`.
	source := "fn boost() -> Fixed {\n  return @stub(Fixed 1.0)\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_pipeline_ordered_named_stages :: proc(t: ^testing.T) {
	// `pipeline Name { stage: [behaviors] … }` (spec §07 §1): stages keep
	// source order, and each stage value is a behavior-name list.
	source := "pipeline Pong {\n" +
		"  startup:   [setup]\n" +
		"  control:   [paddle_move, ball_move]\n" +
		"  scoring:   [score, tally, serve]\n" +
		"  render:    [draw_paddle, draw_ball, draw_score]\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.pipelines), 1)
	pl := ast.pipelines[0]
	testing.expect_value(t, pl.name, "Pong")
	testing.expect_value(t, len(pl.stages), 4)
	// Stage order is the contract — the slice preserves source order.
	testing.expect_value(t, pl.stages[0].name, "startup")
	testing.expect_value(t, len(pl.stages[0].behaviors), 1)
	testing.expect_value(t, pl.stages[1].name, "control")
	testing.expect_value(t, len(pl.stages[1].behaviors), 2)
	testing.expect_value(t, pl.stages[2].behaviors[1], "tally")
	testing.expect_value(t, pl.stages[3].name, "render")
	testing.expect_value(t, len(pl.stages[3].behaviors), 3)
}

@(test)
test_parse_pipeline_bare_battery_stage :: proc(t: ^testing.T) {
	// The yard `physics: solve` shape (spec §07 §1): a stage whose value is a
	// single bare battery name, not a `[behavior, …]` list. The battery stage
	// is_battery is set and its name lives in `battery`; behavior-list stages
	// around it keep the list form. The battery name is recorded as written,
	// not validated here.
	source := "pipeline Yard {\n" +
		"  control:  [drive]\n" +
		"  physics:  solve\n" +
		"  delivery: [deliver, tally]\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.pipelines), 1)
	pl := ast.pipelines[0]
	testing.expect_value(t, len(pl.stages), 3)
	// The bordering stages stay behavior-list stages.
	testing.expect_value(t, pl.stages[0].name, "control")
	testing.expect(t, !pl.stages[0].is_battery)
	testing.expect_value(t, len(pl.stages[0].behaviors), 1)
	// The `physics: solve` stage is a single-battery stage.
	battery := pl.stages[1]
	testing.expect_value(t, battery.name, "physics")
	testing.expect(t, battery.is_battery)
	testing.expect_value(t, battery.battery, "solve")
	testing.expect_value(t, len(battery.behaviors), 0)
	testing.expect_value(t, pl.stages[2].name, "delivery")
	testing.expect(t, !pl.stages[2].is_battery)
	testing.expect_value(t, len(pl.stages[2].behaviors), 2)
}

@(test)
test_parse_pipeline_battery_wrong_case_rejected :: proc(t: ^testing.T) {
	// A battery name is a value name — snake_case (spec §07); an UpperCamel
	// battery name rejects as Wrong_Case.
	_, err := stage_parse(stage_lex("pipeline Yard {\n  physics: Solve\n}\n"))
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_fn_tuple_of_command_lists_return_type :: proc(t: ^testing.T) {
	// The yard `deliver` return signature (spec §02 §3; §04 §1): a tuple of two
	// list types `([Despawn], [Delivered])`. The tuple is the head "()" with two
	// args, each a list head "[]" whose single arg is the element command type —
	// composing the existing tuple-type and list-type productions, no new
	// grammar. The tuple VALUE `([Despawn()], [Delivered{}])` is two List_Expr.
	source := "fn step(self: Crate, pads: [Trigger]) -> ([Despawn], [Delivered]) {\n" +
		"  return ([Despawn()], [Delivered{}])\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	rt := f.return_type
	testing.expect_value(t, rt.name, "()")
	testing.expect_value(t, len(rt.args), 2)
	// Each tuple element is a list type `[T]` (head "[]") of one command type.
	testing.expect_value(t, rt.args[0].name, "[]")
	testing.expect_value(t, len(rt.args[0].args), 1)
	testing.expect_value(t, rt.args[0].args[0].name, "Despawn")
	testing.expect_value(t, rt.args[1].name, "[]")
	testing.expect_value(t, rt.args[1].args[0].name, "Delivered")
	// The return value is a Tuple_Expr of two List_Expr (both already parse).
	ret, is_return := f.body[0].(Return_Node)
	testing.expect(t, is_return)
	if is_return {
		tuple, is_tuple := ret.value.(^Tuple_Expr)
		testing.expect(t, is_tuple)
		if is_tuple {
			testing.expect_value(t, len(tuple.elements), 2)
			_, first_is_list := tuple.elements[0].(^List_Expr)
			testing.expect(t, first_is_list)
			_, second_is_list := tuple.elements[1].(^List_Expr)
			testing.expect(t, second_is_list)
		}
	}
}

@(test)
test_parse_gtag_directive_retained :: proc(t: ^testing.T) {
	// `@gtag("…", …)` is parsed and retained on the declaration it precedes,
	// alongside @doc (spec §05). Multiple labels accumulate.
	source := "@doc(\"a ball\")\n" +
		"@gtag(\"ball\", \"score\")\n" +
		"thing Ball { pos: Vec2, vel: Vec2 }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.things[0].doc, "a ball")
	testing.expect_value(t, len(ast.things[0].gtags), 2)
	testing.expect_value(t, ast.things[0].gtags[0], "ball")
	testing.expect_value(t, ast.things[0].gtags[1], "score")
}

@(test)
test_parse_expose_on_fn :: proc(t: ^testing.T) {
	// `@expose` (spec §05 §4) is a bare prefix directive carried on the
	// declaration it precedes — the §30 §6 exemplar shape: a @doc'd, @expose'd
	// fn beside an unmarked package-private sibling. Only the marked fn
	// records the flag.
	source := "@doc(\"the package's public API\")\n" +
		"@expose\n" +
		"fn axial_to_pixel(cell: Int, size: Fixed) -> Fixed {\n" +
		"  return size\n" +
		"}\n" +
		"\n" +
		"fn cube_round(x: Fixed) -> Fixed {\n" +
		"  return x\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 2)
	testing.expect_value(t, ast.fns[0].doc, "the package's public API")
	testing.expect(t, ast.fns[0].exposed)
	testing.expect(t, !ast.fns[1].exposed)
}

@(test)
test_parse_expose_on_every_declaration_form :: proc(t: ^testing.T) {
	// `@expose` rides the grammar's Annotation* prefix (fun.ebnf §1), so every
	// importable declaration form carries the flag: thing, data, signal, enum,
	// let, extern fn, and query alike record exposed = true.
	source := "@expose\nthing Ball { pos: Vec2 }\n" +
		"@expose\ndata Hex { q: Int, r: Int }\n" +
		"@expose\nsignal Hit { side: Int }\n" +
		"@expose\nenum Side { Left, Right }\n" +
		"@expose\nlet LIMIT: Int = 3\n" +
		"@expose\nextern fn arena_count() -> Int\n" +
		"@expose\nquery hex_count(q: Int) -> Int {\n" +
		"  return q\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect(t, ast.things[0].exposed)
	testing.expect(t, ast.datas[0].exposed)
	testing.expect(t, ast.signals[0].exposed)
	testing.expect(t, ast.enums[0].exposed)
	testing.expect(t, ast.lets[0].exposed)
	testing.expect(t, ast.fns[0].exposed)
	testing.expect(t, ast.queries[0].exposed)
}

@(test)
test_parse_expose_accumulates_with_directive_block :: proc(t: ^testing.T) {
	// @expose joins the shared prefix block (spec §05): the declaration
	// consumes the whole accumulated set — doc, gtags, and the exposed flag —
	// regardless of authored order, and a repeated @expose is idempotent (a
	// flag, never an accumulating family).
	source := "@gtag(\"grid\")\n" +
		"@expose\n" +
		"@doc(\"axial coords\")\n" +
		"@expose\n" +
		"data Hex { q: Int, r: Int }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	d := ast.datas[0]
	testing.expect_value(t, d.doc, "axial coords")
	testing.expect_value(t, len(d.gtags), 1)
	testing.expect(t, d.exposed)
}

@(test)
test_parse_expose_does_not_leak_to_next_declaration :: proc(t: ^testing.T) {
	// A declaration consumes its leading directives whole (stage_parse resets
	// the accumulator), so an @expose on one declaration never bleeds onto the
	// next — the package-private default stays the default.
	source := "@expose\n" +
		"fn shown() -> Int {\n" +
		"  return 1\n" +
		"}\n" +
		"\n" +
		"data Hidden { q: Int }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect(t, ast.fns[0].exposed)
	testing.expect(t, !ast.datas[0].exposed)
}

@(test)
test_parse_expose_with_arg_rejected :: proc(t: ^testing.T) {
	// @expose is bare (lexical-core §5): a parenthesized argument is the named
	// Expose_Unexpected_Arg verdict — the @trace mold — never silently
	// consumed.
	source := "@expose(\"api\")\n" +
		"fn shown() -> Int {\n" +
		"  return 1\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Expose_Unexpected_Arg)
}

@(test)
test_parse_break_probe_on_behavior :: proc(t: ^testing.T) {
	// `@break(<pred>)` (spec §05 §5, §28 §4) carries a funpack PREDICATE over
	// self/signals/resources and rides the declaration it prefixes, like
	// @gtag. The argument is an ordinary parsed expression — here a Binary_Expr
	// comparison — and the probe records the directive's source line.
	source := "@break(self.pos.x > 70.0)\n" +
		"behavior move on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.behaviors[0].probes), 1)
	probe := ast.behaviors[0].probes[0]
	testing.expect_value(t, probe.kind, Debug_Probe_Kind.Break)
	testing.expect_value(t, probe.line, 1)
	_, is_binary := probe.arg.(^Binary_Expr)
	testing.expect(t, is_binary)
}

@(test)
test_parse_log_probe_on_behavior :: proc(t: ^testing.T) {
	// `@log(<expr>)` (spec §05 §5, §28 §4) carries the funpack expression
	// whose value is emitted each step — the `@log(self.head)` shape that
	// replaces print-debugging. The argument parses as a member access.
	source := "@log(self.head)\n" +
		"behavior crawl on Snake {\n" +
		"  fn step(self: Snake) -> Snake {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.behaviors[0].probes), 1)
	probe := ast.behaviors[0].probes[0]
	testing.expect_value(t, probe.kind, Debug_Probe_Kind.Log)
	_, is_member := probe.arg.(^Member_Expr)
	testing.expect(t, is_member)
}

@(test)
test_parse_watch_probe_on_behavior :: proc(t: ^testing.T) {
	// `@watch(<expr>)` (spec §05 §5, §28 §4) names the value whose change
	// fires watch_fired; the argument shape is the same funpack expression
	// @log takes.
	source := "@watch(self.score)\n" +
		"behavior tally on Scoreboard {\n" +
		"  fn step(self: Scoreboard) -> Scoreboard {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.behaviors[0].probes), 1)
	probe := ast.behaviors[0].probes[0]
	testing.expect_value(t, probe.kind, Debug_Probe_Kind.Watch)
	_, is_member := probe.arg.(^Member_Expr)
	testing.expect(t, is_member)
}

@(test)
test_parse_trace_probe_on_pipeline :: proc(t: ^testing.T) {
	// `@trace` (spec §05 §5, §28 §4) takes NO argument — it records the full
	// per-step (in -> out) transition of what it prefixes (a behavior or a
	// pipeline stage). Parsed bare, its probe carries a nil arg.
	source := "@trace\n" +
		"pipeline Game {\n" +
		"  update: [move]\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.pipelines[0].probes), 1)
	probe := ast.pipelines[0].probes[0]
	testing.expect_value(t, probe.kind, Debug_Probe_Kind.Trace)
	testing.expect(t, probe.arg == nil)
}

@(test)
test_parse_probes_accumulate_with_doc_and_gtag :: proc(t: ^testing.T) {
	// Debug probes accumulate in the same prefix block as @doc/@gtag
	// (spec §05): the declaration consumes the whole set, probes in source
	// order, without disturbing the doc or the gtag labels.
	source := "@doc(\"the ball mover\")\n" +
		"@gtag(\"ball\")\n" +
		"@log(self.pos)\n" +
		"@trace\n" +
		"behavior move on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	b := ast.behaviors[0]
	testing.expect_value(t, b.doc, "the ball mover")
	testing.expect_value(t, len(b.gtags), 1)
	testing.expect_value(t, len(b.probes), 2)
	testing.expect_value(t, b.probes[0].kind, Debug_Probe_Kind.Log)
	testing.expect_value(t, b.probes[1].kind, Debug_Probe_Kind.Trace)
}

@(test)
test_parse_break_probe_missing_arg_rejected :: proc(t: ^testing.T) {
	// A bare `@break` with no `(pred)` is malformed (spec §05 §5: the
	// predicate is mandatory) — the named Probe_Missing_Arg diagnostic, not a
	// generic Unexpected_Token.
	source := "@break\n" +
		"behavior move on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Missing_Arg)
}

@(test)
test_parse_log_probe_empty_args_rejected :: proc(t: ^testing.T) {
	// `@log()` with empty parens has no value to emit — Probe_Missing_Arg,
	// the same named verdict as the parenless form.
	source := "@log()\n" +
		"behavior move on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Missing_Arg)
}

@(test)
test_parse_watch_probe_missing_arg_rejected :: proc(t: ^testing.T) {
	// A bare `@watch` with no `(expr)` names nothing to watch —
	// Probe_Missing_Arg.
	source := "@watch\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Missing_Arg)
}

@(test)
test_parse_trace_probe_with_arg_rejected :: proc(t: ^testing.T) {
	// `@trace(expr)` is malformed — @trace takes no argument (spec §05 §5;
	// grammar/fun.ebnf §1 DebugDirective) — and reports the named
	// Probe_Unexpected_Arg diagnostic.
	source := "@trace(self.pos)\n" +
		"behavior move on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Unexpected_Arg)
}

@(test)
test_parse_todo_all_duration_units :: proc(t: ^testing.T) {
	// The relative-duration window `<int>` + unit (spec §05 §2, §29 §4)
	// admits exactly six units — h/d/w/mo/q/y. All six parse, each recording
	// the count and the unit as written; multiple @todo notes accumulate on
	// the one declaration they prefix.
	source := "@todo(\"hours\", 1h)\n" +
		"@todo(\"days\", 30d)\n" +
		"@todo(\"weeks\", 2w)\n" +
		"@todo(\"months\", 3mo)\n" +
		"@todo(\"quarters\", 1q)\n" +
		"@todo(\"years\", 1y)\n" +
		"data Board { score: Int }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	todos := ast.datas[0].todos
	testing.expect_value(t, len(todos), 6)
	units := [6]string{"h", "d", "w", "mo", "q", "y"}
	amounts := [6]i64{1, 30, 2, 3, 1, 1}
	for unit, idx in units {
		testing.expect_value(t, todos[idx].window.form, Todo_Window_Form.Duration)
		testing.expect_value(t, todos[idx].window.unit, unit)
		testing.expect_value(t, todos[idx].window.amount, amounts[idx])
	}
}

@(test)
test_parse_todo_date_window :: proc(t: ^testing.T) {
	// The absolute-date window is ISO-8601 `YYYY-MM-DD` (spec §05 §2). The
	// parser records the three components verbatim — no expiry evaluation:
	// the build-clock is a recorded input to `funpack build` (spec §29 §4),
	// not something the parse stage holds.
	source := "@todo(\"ship the tutorial\", 2026-09-01)\n" +
		"thing Ball { pos: Vec2 }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	todos := ast.things[0].todos
	testing.expect_value(t, len(todos), 1)
	testing.expect_value(t, todos[0].message, "ship the tutorial")
	testing.expect_value(t, todos[0].window.form, Todo_Window_Form.Date)
	testing.expect_value(t, todos[0].window.year, i64(2026))
	testing.expect_value(t, todos[0].window.month, i64(9))
	testing.expect_value(t, todos[0].window.day, i64(1))
}

@(test)
test_parse_todo_build_count_window :: proc(t: ^testing.T) {
	// The build-count window `<int>builds` (spec §05 §2) shares its leading
	// Int_Lit with the duration form; the trailing `builds` unit tells them
	// apart (the §05 disambiguation rule).
	source := "@todo(\"rebalance\", 50builds)\n" +
		"fn tick(n: Int) -> Int {\n" +
		"  return n\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	todos := ast.fns[0].todos
	testing.expect_value(t, len(todos), 1)
	testing.expect_value(t, todos[0].window.form, Todo_Window_Form.Build_Count)
	testing.expect_value(t, todos[0].window.amount, i64(50))
}

@(test)
test_parse_todo_task_ref_with_doc_and_gtag :: proc(t: ^testing.T) {
	// The task-ref window `T-<digits>` — the recommended default (spec §05
	// §2) — keeps its digits as WRITTEN (zero padding included: the ref
	// resolves against the operator's task tooling, whose ids are spelled
	// strings), records the `@` token's source line for provenance, and rides
	// the same prefix block as @doc/@gtag without disturbing either.
	source := "@doc(\"the ball\")\n" +
		"@gtag(\"ball\")\n" +
		"@todo(\"rebalance drops\", T-0042)\n" +
		"thing Ball { pos: Vec2 }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	thing := ast.things[0]
	testing.expect_value(t, thing.doc, "the ball")
	testing.expect_value(t, len(thing.gtags), 1)
	testing.expect_value(t, len(thing.todos), 1)
	todo := thing.todos[0]
	testing.expect_value(t, todo.message, "rebalance drops")
	testing.expect_value(t, todo.window.form, Todo_Window_Form.Task_Ref)
	testing.expect_value(t, todo.window.task, "0042")
	testing.expect_value(t, todo.line, 3)
}

@(test)
test_parse_todo_multiple_accumulate :: proc(t: ^testing.T) {
	// Multiple @todo notes accumulate like @gtag labels (spec §05): the
	// declaration consumes the whole set in source order, window forms mixed
	// freely.
	source := "@todo(\"first\", 30d)\n" +
		"@todo(\"second\", T-7)\n" +
		"behavior move on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	todos := ast.behaviors[0].todos
	testing.expect_value(t, len(todos), 2)
	testing.expect_value(t, todos[0].message, "first")
	testing.expect_value(t, todos[0].window.form, Todo_Window_Form.Duration)
	testing.expect_value(t, todos[1].message, "second")
	testing.expect_value(t, todos[1].window.form, Todo_Window_Form.Task_Ref)
}

@(test)
test_parse_todo_unknown_unit_rejected :: proc(t: ^testing.T) {
	// `30x` names no duration unit (the closed set is h/d/w/mo/q/y, spec §05
	// §2) and is not `builds` — the named Malformed_Todo_Window verdict, not
	// a generic token error.
	source := "@todo(\"m\", 30x)\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_todo_missing_window_rejected :: proc(t: ^testing.T) {
	// The window is MANDATORY (spec §05 §2: past it the directive is a
	// compile error — a @todo with no expiry can rot forever). A
	// message-only @todo is Malformed_Todo_Window.
	source := "@todo(\"m\")\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_todo_bad_date_shape_rejected :: proc(t: ^testing.T) {
	// `2026-9-01` is not the ISO shape — the month is the zero-padded
	// two-digit spelling, the one obvious spelling (spec §05 §2).
	source := "@todo(\"m\", 2026-9-01)\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_todo_month_out_of_range_rejected :: proc(t: ^testing.T) {
	// Month 13 fails the 1–12 range check. Range is parse-side; calendar
	// validity (a Feb 30) deliberately is not — that belongs to the window
	// evaluator (spec §29 §4).
	source := "@todo(\"m\", 2026-13-01)\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_todo_bare_count_rejected :: proc(t: ^testing.T) {
	// A bare `30` names no unit — neither a duration nor a build count
	// (spec §05 §2: one obvious spelling each), so it matches no form.
	source := "@todo(\"m\", 30)\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_todo_lowercase_task_ref_rejected :: proc(t: ^testing.T) {
	// `t-0042` is no task ref: the form leads with the literal uppercase `T`
	// (spec §05 §2).
	source := "@todo(\"m\", t-0042)\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_todo_quoted_window_rejected :: proc(t: ^testing.T) {
	// A quoted window `"30d"` is a string, not one of the four bare forms —
	// Malformed_Todo_Window, never a silent unquote.
	source := "@todo(\"m\", \"30d\")\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_list_newline_separated_elements :: proc(t: ^testing.T) {
	// The pong `setup` shape: a multi-line list whose `Spawn(…)` elements are
	// separated by newline alone (no commas). Each element is a call.
	source := "fn setup() -> [Spawn] {\n" +
		"  return [\n" +
		"    Spawn( Ball{pos: Vec2{x: 80.0, y: 60.0}, vel: Vec2{x: 70.0, y: 40.0}} )\n" +
		"    Spawn( Scoreboard{left: 0, right: 0} )\n" +
		"  ]\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	ret, is_return := f.body[0].(Return_Node)
	testing.expect(t, is_return)
	if is_return {
		list, is_list := ret.value.(^List_Expr)
		testing.expect(t, is_list)
		if is_list {
			testing.expect_value(t, len(list.elements), 2)
			_, first_is_call := list.elements[0].(^Call_Expr)
			testing.expect(t, first_is_call)
		}
	}
}

@(test)
test_parse_fn_tuple_return_type :: proc(t: ^testing.T) {
	// The snake `setup`/`step` return signature (spec §02 §3; §04 §1 — every
	// draw returns `(value, next_rng)`): a tuple type in return position. It is
	// recorded as the head "()" with its positional element Type_Refs as args,
	// mirroring the list head "[]".
	source := "fn setup(rng: Rng) -> (Rng, [Spawn]) {\n" +
		"  return (rng, [])\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	testing.expect_value(t, f.return_type.name, "()")
	testing.expect_value(t, len(f.return_type.args), 2)
	// First element is the bare `Rng`, second is the list `[Spawn]` (head "[]").
	testing.expect_value(t, f.return_type.args[0].name, "Rng")
	testing.expect_value(t, f.return_type.args[1].name, "[]")
	testing.expect_value(t, f.return_type.args[1].args[0].name, "Spawn")
}

@(test)
test_parse_nested_tuple_return_type :: proc(t: ^testing.T) {
	// A tuple element may itself be a tuple — the head recurses by
	// construction, so `(Rng, (A, B))` records a tuple whose second arg is
	// again the head "()".
	source := "fn step(rng: Rng) -> (Rng, (Food, Snake)) {\n" +
		"  return rng\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	testing.expect_value(t, f.return_type.name, "()")
	testing.expect_value(t, len(f.return_type.args), 2)
	testing.expect_value(t, f.return_type.args[1].name, "()")
	testing.expect_value(t, len(f.return_type.args[1].args), 2)
	testing.expect_value(t, f.return_type.args[1].args[0].name, "Food")
	testing.expect_value(t, f.return_type.args[1].args[1].name, "Snake")
}

@(test)
test_parse_variant_in_if_condition_leaves_guard_brace :: proc(t: ^testing.T) {
	// The snake `dir_from_input` shape (spec §02 §5): an `if` condition ending in
	// a bare variant comparison (`current != Dir::Down`) must leave the trailing
	// `{` for the guard block, not consume it as a struct-payload variant
	// `Dir::Down{…}`. In the no-struct-literal context an `if`-guard condition
	// shares with a match scrutinee, a `{` after a variant opens the block.
	source := "fn turn(current: Dir) -> Dir {\n" +
		"  if current != Dir::Down { return Dir::Up }\n" +
		"  return current\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	guard, is_if := f.body[0].(If_Node)
	testing.expect(t, is_if)
	if is_if {
		// The condition is the `!=` comparison; its rhs is a BARE variant (no
		// struct payload) — the brace went to the guard block, which holds the
		// return.
		cond, is_binary := guard.cond.(^Binary_Expr)
		testing.expect(t, is_binary)
		if is_binary {
			rhs, is_variant := cond.rhs.(^Variant_Expr)
			testing.expect(t, is_variant)
			if is_variant {
				testing.expect_value(t, rhs.variant, "Down")
				testing.expect(t, !rhs.has_fields)
			}
		}
		testing.expect_value(t, len(guard.body), 1)
		_, body_is_return := guard.body[0].(Return_Node)
		testing.expect(t, body_is_return)
	}
}

@(test)
test_parse_variant_in_match_scrutinee_leaves_block_brace :: proc(t: ^testing.T) {
	// The match-scrutinee analogue: a scrutinee ending in a bare variant compare
	// (`x == Dir::Up`) leaves the `{` for the match block, not a struct payload.
	source := "fn pick(x: Dir) -> Bool {\n" +
		"  return match x == Dir::Up {\n" +
		"    Bool::True => true\n" +
		"    Bool::False => false\n" +
		"  }\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
}

// ── §05 §6 @migrate — the schema-evolution directive ─────────────────────────
// The three closed argument forms (rename / retype / both) on data fields, the
// decl-level renamed-type form, and the named Malformed_Migrate /
// Migrate_Wrong_Target verdicts for every deviation — mirroring the @todo
// window molds: closed shapes, one named diagnostic per malformation class.

@(test)
test_parse_migrate_rename_field :: proc(t: ^testing.T) {
	// The rename form on its own line above the field (spec §05 §6 table row
	// 1): the field carries the prior key; an unprefixed sibling carries none.
	source := "data Player {\n" +
		"  @migrate(from: \"old_pos\")\n" +
		"  pos: Int\n" +
		"  hp: Int\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	fields := ast.datas[0].fields
	testing.expect_value(t, len(fields), 2)
	testing.expect(t, fields[0].has_migrate)
	testing.expect(t, fields[0].migrate.has_from)
	testing.expect_value(t, fields[0].migrate.from, "old_pos")
	testing.expect(t, !fields[0].migrate.has_with)
	testing.expect_value(t, fields[0].migrate.line, 2)
	testing.expect(t, !fields[1].has_migrate)
}

@(test)
test_parse_migrate_retype_field_inline :: proc(t: ^testing.T) {
	// The retype form inline before its field (spec §05 §6 table row 2): the
	// conversion fn's name is carried; no prior key.
	source := "data Player { @migrate(with: meters_to_units) pos: Fixed }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	field := ast.datas[0].fields[0]
	testing.expect(t, field.has_migrate)
	testing.expect(t, !field.migrate.has_from)
	testing.expect(t, field.migrate.has_with)
	testing.expect_value(t, field.migrate.with, "meters_to_units")
}

@(test)
test_parse_migrate_rename_retype_field :: proc(t: ^testing.T) {
	// The combined form (spec §05 §6 table row 3): both halves carried, in the
	// table's fixed from-then-with order.
	source := "data Player {\n" +
		"  @migrate(from: \"speed\", with: to_velocity)\n" +
		"  vel: Fixed\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	field := ast.datas[0].fields[0]
	testing.expect(t, field.has_migrate)
	testing.expect_value(t, field.migrate.from, "speed")
	testing.expect_value(t, field.migrate.with, "to_velocity")
}

@(test)
test_parse_migrate_renamed_type_decl :: proc(t: ^testing.T) {
	// The decl-level form — a renamed TYPE declaration (spec §05 §6 "or a
	// renamed type declaration"): the data node carries the prior type name,
	// alongside its other prefix directives.
	source := "@doc(\"the player\")\n" +
		"@migrate(from: \"OldPlayer\")\n" +
		"data Player { hp: Int }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	decl := ast.datas[0]
	testing.expect_value(t, decl.doc, "the player")
	testing.expect(t, decl.has_migrate)
	testing.expect(t, decl.migrate.has_from)
	testing.expect_value(t, decl.migrate.from, "OldPlayer")
	testing.expect(t, !decl.migrate.has_with)
	testing.expect_value(t, decl.migrate.line, 2)
}

@(test)
test_parse_migrate_with_before_from_rejected :: proc(t: ^testing.T) {
	// The combined form is from-then-with — the spec table's one spelling
	// (the formatter's canonical order); the reversed order matches no form.
	source := "data Player { @migrate(with: lift, from: \"old\") hp: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_empty_args_rejected :: proc(t: ^testing.T) {
	// An empty argument list names neither a prior key nor a conversion —
	// no form, the named verdict.
	source := "data Player { @migrate() hp: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_missing_args_rejected :: proc(t: ^testing.T) {
	// A bare @migrate carries nothing to migrate by — the argument list is
	// mandatory, like a @todo's window.
	source := "data Player { @migrate hp: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_unquoted_from_rejected :: proc(t: ^testing.T) {
	// `from:` is the prior name AS A STRING (spec §05 §6) — a bare identifier
	// is not the form, never a silent quote.
	source := "data Player { @migrate(from: old_pos) pos: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_empty_from_rejected :: proc(t: ^testing.T) {
	// An empty prior name names no key to read the old value from.
	source := "data Player { @migrate(from: \"\") pos: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_unknown_key_rejected :: proc(t: ^testing.T) {
	// The key vocabulary is closed to `from`/`with` — any other key matches
	// no form.
	source := "data Player { @migrate(to: \"new_pos\") pos: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_duplicate_from_rejected :: proc(t: ^testing.T) {
	// After a rename key only `with:` may follow — a second `from` falls
	// outside the three closed forms.
	source := "data Player { @migrate(from: \"a\", from: \"b\") pos: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_wrong_case_convert_rejected :: proc(t: ^testing.T) {
	// The conversion is a fn — snake_case (spec §02); a wrong-cased name keeps
	// the parser-wide Wrong_Case verdict rather than the migrate-shape one.
	source := "data Player { @migrate(with: Lift) pos: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_migrate_on_thing_field_rejected :: proc(t: ^testing.T) {
	// The schema-evolution channel is the name-keyed `data` schema (spec §09
	// §4): a @migrate inside a thing body is the named wrong-target verdict,
	// never a silently-accepted directive.
	source := "thing Ball { @migrate(from: \"p\") pos: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Migrate_Wrong_Target)
}

@(test)
test_parse_migrate_on_signal_field_rejected :: proc(t: ^testing.T) {
	// A signal is per-tick, never persisted — its fields admit no migration.
	source := "signal Goal { @migrate(from: \"s\") side: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Migrate_Wrong_Target)
}

@(test)
test_parse_migrate_prefix_non_data_decl_rejected :: proc(t: ^testing.T) {
	// The decl-level form marks a renamed `data` type only — an enum (or any
	// other declaration) consuming a pending @migrate is the wrong target.
	source := "@migrate(from: \"OldColor\")\n" +
		"enum Color { Red, Blue }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Migrate_Wrong_Target)
}

@(test)
test_parse_migrate_decl_level_retype_rejected :: proc(t: ^testing.T) {
	// A type declaration admits the RENAME form only (spec §05 §6: "a renamed
	// type declaration") — there is no decl-level value to convert, so a
	// `with:` there is the wrong target, not a silently-dropped conversion.
	source := "@migrate(with: lift)\n" +
		"data Player { hp: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Migrate_Wrong_Target)
}

@(test)
test_parse_migrate_dangling_in_body_rejected :: proc(t: ^testing.T) {
	// A @migrate with no field following it migrates nothing — dangling at the
	// body's close is the wrong-target verdict.
	source := "data Player {\n" +
		"  hp: Int\n" +
		"  @migrate(from: \"old\")\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Migrate_Wrong_Target)
}

@(test)
test_parse_migrate_duplicate_before_field_rejected :: proc(t: ^testing.T) {
	// One @migrate per field: a second before the same field is malformed,
	// never a silent overwrite.
	source := "data Player {\n" +
		"  @migrate(from: \"a\")\n" +
		"  @migrate(from: \"b\")\n" +
		"  pos: Int\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

// The Ast's source-ordered declaration sequence: one Decl_Ref per declaration
// in parse order, each pointing at its per-kind slot — so the author's
// cross-kind interleaving survives the parse (ADR
// 2026-06-10-formatter-canon-source-ordered-declarations). Imports are the
// module header, never a sequence entry.
@(test)
test_parse_decl_sequence_source_order :: proc(t: ^testing.T) {
	source := "import assets\n" +
		"fn helper() -> Int {\n  return 1\n}\n" +
		"data Cell { x: Int }\n" +
		"let SIZE: Int = 8\n" +
		"thing Board { c: Cell }\n" +
		"enum Side { Left, Right }\n" +
		"signal Moved {}\n" +
		"query cells() -> [Cell] {\n  return []\n}\n" +
		"behavior hold on Board {\n  fn step(self: Board) -> Board {\n    return self\n  }\n}\n" +
		"pipeline Loop {\n  update: [hold]\n}\n" +
		"data Grid { c: Cell }\n" +
		"test \"t\" {\n  assert SIZE == 8\n}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	expected := [?]Decl_Ref {
		{kind = .Fn, index = 0},
		{kind = .Data, index = 0},
		{kind = .Let, index = 0},
		{kind = .Thing, index = 0},
		{kind = .Enum, index = 0},
		{kind = .Signal, index = 0},
		{kind = .Query, index = 0},
		{kind = .Behavior, index = 0},
		{kind = .Pipeline, index = 0},
		{kind = .Data, index = 1},
		{kind = .Test, index = 0},
	}
	testing.expect_value(t, len(ast.decls), len(expected))
	if len(ast.decls) != len(expected) {
		return
	}
	for ref, i in expected {
		testing.expect_value(t, ast.decls[i], ref)
	}
	// The second data declaration's slot resolves to the node it marked.
	testing.expect_value(t, ast.datas[ast.decls[9].index].name, "Grid")
	// An extern fn joins ast.fns AND the sequence like a bodied fn.
	extern_ast, extern_err := stage_parse(stage_lex("data A { x: Int }\nextern fn arena_spawns() -> Int\n"))
	testing.expect_value(t, extern_err, Parse_Error.None)
	testing.expect_value(t, len(extern_ast.decls), 2)
	if len(extern_ast.decls) == 2 {
		testing.expect_value(t, extern_ast.decls[1], Decl_Ref{kind = .Fn, index = 0})
	}
}

@(test)
test_parse_extern_type_decl :: proc(t: ^testing.T) {
	// `extern type Name` (spec §02 §7, §26 §2) parses into its dedicated
	// Extern_Type_Node carrier: the opaque type is the name alone — no fields,
	// no body — and it joins the source-ordered declaration sequence under its
	// own kind, with the span anchored on the `extern` keyword's line.
	source := "data A { x: Int }\nextern type Sketch\nextern type Anchors\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.extern_types), 2)
	if len(ast.extern_types) != 2 {
		return
	}
	testing.expect_value(t, ast.extern_types[0].name, "Sketch")
	testing.expect_value(t, ast.extern_types[0].line, 2)
	testing.expect_value(t, ast.extern_types[1].name, "Anchors")
	testing.expect_value(t, len(ast.decls), 3)
	if len(ast.decls) == 3 {
		testing.expect_value(t, ast.decls[1], Decl_Ref{kind = .Extern_Type, index = 0})
		testing.expect_value(t, ast.decls[2], Decl_Ref{kind = .Extern_Type, index = 1})
	}
}

@(test)
test_parse_extern_type_carries_directive_block :: proc(t: ^testing.T) {
	// An extern type consumes the shared §05 prefix block like every other
	// declaration form: @doc, @gtag, and the @expose flag land on the node and
	// never bleed onto the next declaration.
	source := "@doc(\"an immutable 2D outline\")\n" +
		"@gtag(\"geometry\")\n" +
		"@expose\n" +
		"extern type Sketch\n" +
		"\n" +
		"extern type Anchors\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.extern_types), 2)
	if len(ast.extern_types) != 2 {
		return
	}
	testing.expect_value(t, ast.extern_types[0].doc, "an immutable 2D outline")
	testing.expect_value(t, len(ast.extern_types[0].gtags), 1)
	testing.expect(t, ast.extern_types[0].exposed)
	testing.expect_value(t, ast.extern_types[1].doc, "")
	testing.expect(t, !ast.extern_types[1].exposed)
}

@(test)
test_parse_extern_type_wrong_case_rejected :: proc(t: ^testing.T) {
	// A declared type name is UPPER_IDENT (lexical-core.ebnf §2) — a
	// snake_case extern type name is the named Wrong_Case verdict, the same
	// casing-is-structural rule every type declaration enforces.
	_, err := stage_parse(stage_lex("extern type sketch\n"))
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_extern_family_closed :: proc(t: ^testing.T) {
	// The §02 §7 extern family is closed (fun.ebnf §8: ExternDecl ::= 'extern'
	// (ExternFn | ExternType)): an `extern` prefixing anything else — a data
	// declaration, or nothing at all — is the named Malformed_Extern verdict,
	// never a generic token error.
	_, data_err := stage_parse(stage_lex("extern data Foo { x: Int }\n"))
	testing.expect_value(t, data_err, Parse_Error.Malformed_Extern)
	_, bare_err := stage_parse(stage_lex("extern\n"))
	testing.expect_value(t, bare_err, Parse_Error.Malformed_Extern)
}

@(test)
test_parse_extern_type_trailing_junk_rejected :: proc(t: ^testing.T) {
	// Trailing junk after a well-formed `extern type Name` header stays the
	// generic Unexpected_Token (the named diagnostics cover the malformed
	// family and the casing deviation): an opaque type has no body, so a brace
	// where the terminator belongs is rejected — with or without the §03 §3
	// generic header in between.
	_, brace_err := stage_parse(stage_lex("extern type Sketch { x: Int }\n"))
	testing.expect_value(t, brace_err, Parse_Error.Unexpected_Token)
	_, generic_brace_err := stage_parse(stage_lex("extern type View[T] { x: Int }\n"))
	testing.expect_value(t, generic_brace_err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_generic_data_header :: proc(t: ^testing.T) {
	// The §03 §3 generic declaration header on a data declaration (fun.ebnf §4:
	// DataDecl ::= 'data' UPPER_IDENT TypeParams? KindAsc? RecordBody): the
	// declared parameter names land on the node in source order, and the body's
	// field types reference the binder as ordinary Type_Refs (the stdlib
	// world.fun `data Ref[T] { id: Id }` / ui.fun `data Choice[T] { value: T }`
	// shapes).
	source := "data Ref[T] { id: Id }\ndata Choice[T] { label: String, value: T }\ndata Pair[K, V] { k: K, v: V }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.datas), 3)
	if len(ast.datas) != 3 {
		return
	}
	testing.expect_value(t, ast.datas[0].name, "Ref")
	testing.expect_value(t, len(ast.datas[0].type_params), 1)
	if len(ast.datas[0].type_params) == 1 {
		testing.expect_value(t, ast.datas[0].type_params[0], "T")
	}
	// The binder is usable in the body's field types: `value: T` parses as the
	// plain named Type_Ref "T".
	testing.expect_value(t, len(ast.datas[1].fields), 2)
	if len(ast.datas[1].fields) == 2 {
		testing.expect_value(t, ast.datas[1].fields[1].type.name, "T")
	}
	testing.expect_value(t, len(ast.datas[2].type_params), 2)
	if len(ast.datas[2].type_params) == 2 {
		testing.expect_value(t, ast.datas[2].type_params[0], "K")
		testing.expect_value(t, ast.datas[2].type_params[1], "V")
	}
}

@(test)
test_parse_generic_enum_header :: proc(t: ^testing.T) {
	// The §03 §3 generic declaration header on an enum (fun.ebnf §4: EnumDecl
	// ::= 'enum' UPPER_IDENT TypeParams? KindAsc? '{' … '}') — the prelude's
	// two engine containers, with the binder referenced in variant payloads.
	source := "enum Option[T] { Some(T), None }\nenum Result[T, E] { Ok(T), Err(E) }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.enums), 2)
	if len(ast.enums) != 2 {
		return
	}
	testing.expect_value(t, ast.enums[0].name, "Option")
	testing.expect_value(t, len(ast.enums[0].type_params), 1)
	if len(ast.enums[0].type_params) == 1 {
		testing.expect_value(t, ast.enums[0].type_params[0], "T")
	}
	testing.expect_value(t, len(ast.enums[0].variants), 2)
	if len(ast.enums[0].variants) == 2 {
		// Some(T)'s tuple payload references the binder as a plain Type_Ref.
		testing.expect_value(t, len(ast.enums[0].variants[0].tuple), 1)
		if len(ast.enums[0].variants[0].tuple) == 1 {
			testing.expect_value(t, ast.enums[0].variants[0].tuple[0].name, "T")
		}
	}
	testing.expect_value(t, len(ast.enums[1].type_params), 2)
	if len(ast.enums[1].type_params) == 2 {
		testing.expect_value(t, ast.enums[1].type_params[0], "T")
		testing.expect_value(t, ast.enums[1].type_params[1], "E")
	}
}

@(test)
test_parse_generic_extern_type_header :: proc(t: ^testing.T) {
	// The §03 §3 generic header on an extern type (fun.ebnf §8: ExternType ::=
	// 'type' UPPER_IDENT TypeParams?) — the stdlib `extern type View[T]` /
	// `extern type View[Msg]` shapes the wave-1 reject fixture deliberately
	// pinned as Unexpected_Token until this story admitted them.
	source := "extern type View[T]\nextern type Widget[Msg]\nextern type Theme\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.extern_types), 3)
	if len(ast.extern_types) != 3 {
		return
	}
	testing.expect_value(t, ast.extern_types[0].name, "View")
	testing.expect_value(t, len(ast.extern_types[0].type_params), 1)
	if len(ast.extern_types[0].type_params) == 1 {
		testing.expect_value(t, ast.extern_types[0].type_params[0], "T")
	}
	testing.expect_value(t, len(ast.extern_types[1].type_params), 1)
	if len(ast.extern_types[1].type_params) == 1 {
		testing.expect_value(t, ast.extern_types[1].type_params[0], "Msg")
	}
	// The bare form keeps its nil header.
	testing.expect_value(t, len(ast.extern_types[2].type_params), 0)
}

@(test)
test_parse_generic_header_then_kind_order :: proc(t: ^testing.T) {
	// The fun.ebnf §4 declaration order is TypeParams? KindAsc? — the header
	// binds tight to the name, the kind ascription follows it.
	ast, err := stage_parse(stage_lex("data Vel[T]: Num { x: T }\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.datas), 1)
	if len(ast.datas) != 1 {
		return
	}
	testing.expect_value(t, len(ast.datas[0].type_params), 1)
	testing.expect_value(t, ast.datas[0].kind, "Num")
}

@(test)
test_parse_generic_header_closed_decl_kinds :: proc(t: ^testing.T) {
	// Only the engine-container decl kinds the grammar names admit a generic
	// header — data, enum, extern type (fun.ebnf §4/§8). Every other declared
	// type form (ThingDecl, SignalDecl — fun.ebnf §5) has no TypeParams slot,
	// so a post-name `[` keeps that production's generic token error.
	_, thing_err := stage_parse(stage_lex("thing Foo[T] { x: Int }\n"))
	testing.expect_value(t, thing_err, Parse_Error.Unexpected_Token)
	_, signal_err := stage_parse(stage_lex("signal Hit[T] { amount: T }\n"))
	testing.expect_value(t, signal_err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_malformed_type_params_rejected :: proc(t: ^testing.T) {
	// A mis-shaped §03 §3 header is the named Malformed_Type_Params verdict
	// (fun.ebnf §4: TypeParams ::= '[' UPPER_IDENT (',' UPPER_IDENT)* ']'):
	// empty brackets, a trailing comma, a missing comma between parameters, a
	// non-identifier parameter, or a never-closed header. The one casing-class
	// deviation — a lowercase parameter name — keeps the parser-wide Wrong_Case
	// verdict (the Malformed_Index_Path split).
	_, empty_err := stage_parse(stage_lex("enum Option[] { None }\n"))
	testing.expect_value(t, empty_err, Parse_Error.Malformed_Type_Params)
	_, trailing_err := stage_parse(stage_lex("data Ref[T,] { id: Id }\n"))
	testing.expect_value(t, trailing_err, Parse_Error.Malformed_Type_Params)
	_, missing_comma_err := stage_parse(stage_lex("data Pair[K V] { k: K }\n"))
	testing.expect_value(t, missing_comma_err, Parse_Error.Malformed_Type_Params)
	_, number_err := stage_parse(stage_lex("extern type View[1]\n"))
	testing.expect_value(t, number_err, Parse_Error.Malformed_Type_Params)
	_, unclosed_err := stage_parse(stage_lex("extern type View[T\n"))
	testing.expect_value(t, unclosed_err, Parse_Error.Malformed_Type_Params)
	_, case_err := stage_parse(stage_lex("enum Option[t] { None }\n"))
	testing.expect_value(t, case_err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_fn_type_param :: proc(t: ^testing.T) {
	// The §02 §3 function type in parameter position (fun.ebnf §11: FnType ::=
	// 'fn' '(' (Type (',' Type)*)? ')' '->' Type) — the stdlib list.fun
	// combinator signatures. The head is "fn"; the args are the parameter
	// types followed by the result (the LAST arg is always the result).
	source := "extern fn find(self: [T], pred: fn(T) -> Bool) -> Option[T]\nextern fn fold(self: [T], init: A, step: fn(A, T) -> A) -> A\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 2)
	if len(ast.fns) != 2 {
		return
	}
	pred := ast.fns[0].params[1].type
	testing.expect_value(t, pred.name, "fn")
	testing.expect_value(t, len(pred.args), 2)
	if len(pred.args) == 2 {
		testing.expect_value(t, pred.args[0].name, "T")
		testing.expect_value(t, pred.args[1].name, "Bool")
	}
	step := ast.fns[1].params[2].type
	testing.expect_value(t, step.name, "fn")
	testing.expect_value(t, len(step.args), 3)
	if len(step.args) == 3 {
		testing.expect_value(t, step.args[0].name, "A")
		testing.expect_value(t, step.args[1].name, "T")
		testing.expect_value(t, step.args[2].name, "A")
	}
}

@(test)
test_parse_fn_type_general_type_position :: proc(t: ^testing.T) {
	// The grammar admits FnType wherever a Type stands (fun.ll1.md §3:
	// FIRST(Type) = { Ʉ, '[', fn }), not just in parameter position: a
	// zero-parameter form, a return position, a generic argument, a list
	// element, and a nested fn-typed result all parse.
	source := "extern fn thunk(supplier: fn() -> Int) -> Int\nextern fn make() -> fn(Int) -> Int\nextern fn pick(opts: Option[fn(T) -> Bool]) -> Bool\nextern fn many(steps: [fn(Int) -> Int]) -> Int\nextern fn curry(f: fn(Int) -> fn(Int) -> Int) -> Int\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 5)
	if len(ast.fns) != 5 {
		return
	}
	// fn() -> Int: a zero-parameter function type carries exactly one arg —
	// its result.
	thunk := ast.fns[0].params[0].type
	testing.expect_value(t, thunk.name, "fn")
	testing.expect_value(t, len(thunk.args), 1)
	// Return position.
	testing.expect_value(t, ast.fns[1].return_type.name, "fn")
	// Generic argument and list element keep their heads; the fn rides inside.
	testing.expect_value(t, ast.fns[2].params[0].type.name, "Option")
	testing.expect_value(t, ast.fns[2].params[0].type.args[0].name, "fn")
	testing.expect_value(t, ast.fns[3].params[0].type.name, "[]")
	testing.expect_value(t, ast.fns[3].params[0].type.args[0].name, "fn")
	// A nested fn-typed result: the outer "fn"'s last arg is itself "fn".
	curry := ast.fns[4].params[0].type
	testing.expect_value(t, curry.name, "fn")
	testing.expect_value(t, len(curry.args), 2)
	if len(curry.args) == 2 {
		testing.expect_value(t, curry.args[1].name, "fn")
	}
}

@(test)
test_parse_malformed_fn_type_rejected :: proc(t: ^testing.T) {
	// A mis-shaped §02 §3 function type is the named Malformed_Fn_Type verdict
	// (fun.ebnf §11; the Malformed_Type_Params mold): a missing `(` after
	// `fn`, a missing `->` before the result, a trailing comma, a missing
	// comma between parameters, and a never-closed parameter list. An element
	// type's OWN errors keep their verdicts — a lowercase parameter type stays
	// the parser-wide Wrong_Case.
	_, no_parens_err := stage_parse(stage_lex("extern fn f(g: fn Int -> Int) -> Int\n"))
	testing.expect_value(t, no_parens_err, Parse_Error.Malformed_Fn_Type)
	_, no_arrow_err := stage_parse(stage_lex("extern fn f(g: fn(Int) Int) -> Int\n"))
	testing.expect_value(t, no_arrow_err, Parse_Error.Malformed_Fn_Type)
	_, trailing_err := stage_parse(stage_lex("extern fn f(g: fn(Int,) -> Int) -> Int\n"))
	testing.expect_value(t, trailing_err, Parse_Error.Malformed_Fn_Type)
	_, missing_comma_err := stage_parse(stage_lex("extern fn f(g: fn(Int Int) -> Int) -> Int\n"))
	testing.expect_value(t, missing_comma_err, Parse_Error.Malformed_Fn_Type)
	_, unclosed_err := stage_parse(stage_lex("extern fn f(g: fn(Int -> Int) -> Int\n"))
	testing.expect_value(t, unclosed_err, Parse_Error.Malformed_Fn_Type)
	_, case_err := stage_parse(stage_lex("extern fn f(g: fn(int) -> Int) -> Int\n"))
	testing.expect_value(t, case_err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_fn_keyword_param_name_rejected :: proc(t: ^testing.T) {
	// `fn` stays a RESERVED keyword in value-name position (fun.ll1.md §2;
	// fun.ebnf §7: Param ::= LOWER_IDENT ':' Type admits no keyword) — so a
	// `fn: fn(Int, Int) -> Cell` parameter is FAIL-CLOSED: the fn-type
	// production does not smuggle the keyword into the identifier namespace.
	// A spec file carrying this spelling is fixed spec-side (grid.fun's
	// parameter is named `builder`), never by a parser carve-out; this pin
	// keeps the keyword reserved.
	_, err := stage_parse(stage_lex("extern fn grid_cells(w: Int, h: Int, fn: fn(Int, Int) -> Cell) -> [Cell]\n"))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_string_escapes_carried_raw :: proc(t: ^testing.T) {
	// The closed lexical-core §4 escapes parse in every string position and
	// carry the RAW spelling, backslash included — the stdlib @doc shape and
	// an expression-position literal both land verbatim in the AST.
	ast, err := stage_parse(stage_lex("@doc(\"Built by interpolation (\\\"{x}\\\"), never +.\")\nlet GREETING: String = \"say \\\"hi\\\" \\{now\\}\"\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.lets), 1)
	testing.expect_value(t, ast.lets[0].doc, `Built by interpolation (\"{x}\"), never +.`)
	lit, is_string := ast.lets[0].value.(^String_Lit_Expr)
	testing.expect(t, is_string)
	if is_string {
		testing.expect_value(t, lit.text, `say \"hi\" \{now\}`)
	}
}

@(test)
test_parse_malformed_string_escape_named_verdict :: proc(t: ^testing.T) {
	// A backslash escape outside the closed §4 set is the named
	// Malformed_String_Escape verdict (the Malformed_Fn_Type mold) in every
	// string position — a @doc argument, an expression literal, a test name —
	// for the unknown-escape and trailing-backslash shapes alike. An
	// UNTERMINATED string keeps its existing Unexpected_Token verdict.
	_, doc_err := stage_parse(stage_lex("@doc(\"a \\n newline\")\nfn f() -> Int {\n  return 1\n}\n"))
	testing.expect_value(t, doc_err, Parse_Error.Malformed_String_Escape)
	_, expr_err := stage_parse(stage_lex("let S: String = \"no \\\\ backslash\"\n"))
	testing.expect_value(t, expr_err, Parse_Error.Malformed_String_Escape)
	_, name_err := stage_parse(stage_lex("test \"bad \\q\" {\n  assert true\n}\n"))
	testing.expect_value(t, name_err, Parse_Error.Malformed_String_Escape)
	_, trailing_err := stage_parse(stage_lex("let S: String = \"dangling\\"))
	testing.expect_value(t, trailing_err, Parse_Error.Malformed_String_Escape)
	_, unterminated_err := stage_parse(stage_lex("let S: String = \"open\n"))
	testing.expect_value(t, unterminated_err, Parse_Error.Unexpected_Token)
}
