// LL(1) statement-layer parser over the golden-file surface (spec §02,
// §06, §07): a file-leading @doc as the module doc, per-declaration @doc
// and @gtag directives, import in its three forms, the §06/§07 declaration
// layer (data/enum/thing/singleton/signal/behavior/pipeline, module-level
// let, and top-level fn), and test blocks. Every production opens with a
// unique keyword, so one token of lookahead selects it. Expressions route
// through the single parse_expression seam owned by the Pratt cascade
// (expr.odin). This stage produces an AST only — no name resolution and no
// typing (those live in the resolve and typecheck stages).
package funpack

Assert_Node :: struct {
	expr: Expr,
}

Let_Node :: struct {
	name:  string,
	value: Expr,
}

// Return_Node is the mandatory value-producing statement of a fn body
// (spec §02 §6): `return expr`. There is no implicit last-expression
// return.
Return_Node :: struct {
	value: Expr,
}

// If_Node is the early-return statement form a fn body uses (spec §02 §5):
// `if cond { return … }`. The body is the same statement sequence a fn
// body is, so a guarded block can hold its own let/return; the golden pong
// surface only uses the single-`return` shape. There is no `else` arm on
// the golden surface, so this statement form omits it.
If_Node :: struct {
	cond: Expr,
	body: []Statement,
}

// Statement is the closed body-statement set across test blocks and fn
// bodies: a test body is let/assert; a fn body is let/return with an
// optional `if` early-return guard. The union is shared so one
// parse_statement_seq drives both.
Statement :: union {
	Assert_Node,
	Let_Node,
	Return_Node,
	If_Node,
}

Import_Node :: struct {
	segments: []string, // the dotted path as written, excluding any group
	members:  []string, // brace-group members; nil for the groupless forms
}

Test_Node :: struct {
	name: string,
	doc:  string, // the @doc directive preceding this test ("" when absent)
	body: []Statement,
}

// Type_Ref is the parse-only syntactic type the declaration grammar
// records: a bare name (`Fixed`, `Side`), a generic application
// (`View[Paddle]`, `Option[Side]`), or a list (`[Goal]`, `[Spawn]`). It is
// purely structural — no resolution to the checker's semantic Type
// (type.odin) happens here; that is the resolve stage's job. A list
// is modeled as the generic head "[]" with one argument, so every
// parameterized form shares one node shape.
Type_Ref :: struct {
	name: string,     // the head name; "[]" for a list type `[T]`
	args: []Type_Ref, // generic / list element arguments; empty for a bare name
}

// Field_Decl is one `name: Type` (or `name: Type = default`) entry in a
// data/thing/singleton/signal body. has_default distinguishes a defaulted
// field (spec §03 §1) from a required one; default is meaningless when
// has_default is false.
Field_Decl :: struct {
	name:        string,
	type:        Type_Ref,
	default:     Expr,
	has_default: bool,
}

// Variant_Decl is one enum variant (spec §03 §2): plain (`Left`),
// tuple-payload (`MoveTo(Vec2)`), or struct-payload (`Rgb{ r: Fixed, … }`).
// The payload shape is the closed Variant_Payload tag; tuple args live in
// `tuple`, struct fields in `fields`.
Variant_Payload :: enum {
	Plain,  // `Variant`
	Tuple,  // `Variant(T, …)`
	Struct, // `Variant{ f: T, … }`
}

Variant_Decl :: struct {
	name:    string,
	payload: Variant_Payload,
	tuple:   []Type_Ref,    // Tuple payload: positional types
	fields:  []Field_Decl,  // Struct payload: named fields
}

// Param_Decl is one `name: Type` parameter of a fn or the reserved
// behavior `step` (spec §06 §3: a behavior's params are its reads).
Param_Decl :: struct {
	name: string,
	type: Type_Ref,
}

// Let_Decl_Node is a module-level constant (spec §02 §7): `let NAME: T =
// expr`, distinct from the test-body Let_Node in that it always carries an
// explicit type ascription.
Let_Decl_Node :: struct {
	name:  string,
	type:  Type_Ref,
	value: Expr,
	doc:   string,
	gtags: []string, // @gtag("…") labels attached to this declaration
}

Data_Node :: struct {
	name:   string,
	kind:   string, // the `Name: Kind` ascription (§03 §4); "" when absent
	fields: []Field_Decl,
	doc:    string,
	gtags:  []string,
}

Enum_Node :: struct {
	name:     string,
	kind:     string, // the enum-as-role kind (`enum Steer: Axis`); "" when absent
	variants: []Variant_Decl,
	doc:      string,
	gtags:    []string,
}

// Thing_Node carries both `thing` and `singleton` (spec §06 §1–2): a
// singleton is a guaranteed-single-row thing, told apart here only by
// is_singleton so downstream stages key the row-count-1 constraint off one
// flag.
Thing_Node :: struct {
	name:         string,
	is_singleton: bool,
	fields:       []Field_Decl,
	doc:          string,
	gtags:        []string,
}

Signal_Node :: struct {
	name:   string,
	fields: []Field_Decl,
	doc:    string,
	gtags:  []string,
}

// Fn_Node is a top-level function or a behavior's reserved `step` entry
// point (spec §06 §3). The body is the shared Statement sequence
// (let/return/if). return_type is the syntactic `-> R` ascription.
Fn_Node :: struct {
	name:        string,
	params:      []Param_Decl,
	return_type: Type_Ref,
	body:        []Statement,
	doc:         string,
	gtags:       []string,
}

// Behavior_Node is a pure transition attached to a thing (spec §06 §3):
// `behavior name on Thing { fn step(…) -> … { … } }`. target is the `on
// Thing` type name; step is the single reserved entry point (the parser
// enforces the name `step`).
Behavior_Node :: struct {
	name:   string,
	target: string,
	step:   Fn_Node,
	doc:    string,
	gtags:  []string,
}

// Pipeline_Stage is one ordered named stage of a pipeline (spec §07 §1):
// `name: [behavior, …]`. Stage order is the contract, so stages travel as
// an ordered slice; the value is the behavior-name list. The golden pong
// surface uses only the `[behavior]`-list stage form (not engine-stage
// symbols or sub-pipeline names).
Pipeline_Stage :: struct {
	name:      string,
	behaviors: []string,
}

Pipeline_Node :: struct {
	name:   string,
	stages: []Pipeline_Stage,
	doc:    string,
	gtags:  []string,
}

// Directives carries the @doc / @gtag prefix block attached to a
// declaration (spec §05). It accumulates as leading directives are parsed
// and is consumed by the declaration that follows them.
Directives :: struct {
	doc:   string,
	gtags: [dynamic]string,
}

Parse_Error :: enum {
	None,
	Unexpected_Token,
	Unexpected_End,
	Wrong_Case, // an identifier whose casing class is wrong for its grammar position (spec §02)
}

Parser :: struct {
	tokens: []Token,
	pos:    int,
	// no_record_brace marks the no-struct-literal context of a match
	// scrutinee (spec §02 §5): the `{` after the scrutinee opens the
	// match block, so a name in scrutinee position must not consume it as
	// a record literal. Set only while parsing the scrutinee.
	no_record_brace: bool,
}

stage_parse :: proc(tokens: []Token) -> (ast: Ast, err: Parse_Error) {
	p := Parser{tokens = tokens}
	out := Decl_Sink {
		imports   = make([dynamic]Import_Node, 0, 8, context.temp_allocator),
		lets      = make([dynamic]Let_Decl_Node, 0, 4, context.temp_allocator),
		datas     = make([dynamic]Data_Node, 0, 4, context.temp_allocator),
		enums     = make([dynamic]Enum_Node, 0, 4, context.temp_allocator),
		things    = make([dynamic]Thing_Node, 0, 8, context.temp_allocator),
		signals   = make([dynamic]Signal_Node, 0, 4, context.temp_allocator),
		fns       = make([dynamic]Fn_Node, 0, 16, context.temp_allocator),
		behaviors = make([dynamic]Behavior_Node, 0, 16, context.temp_allocator),
		pipelines = make([dynamic]Pipeline_Node, 0, 2, context.temp_allocator),
		tests     = make([dynamic]Test_Node, 0, 8, context.temp_allocator),
	}
	module_doc := ""
	seen_decl := false
	pending := Directives{gtags = make([dynamic]string, 0, 4, context.temp_allocator)}
	skip_newlines(&p)
	for !at_end(&p) {
		if peek_kind(&p) == .At {
			parse_directive(&p, &module_doc, &pending, seen_decl) or_return
			skip_newlines(&p)
			continue
		}
		parse_declaration(&p, &out, &pending) or_return
		seen_decl = true
		// Each declaration consumes its leading directives.
		pending = Directives{gtags = make([dynamic]string, 0, 4, context.temp_allocator)}
		skip_newlines(&p)
	}
	return Ast {
			module_doc = module_doc,
			imports = out.imports[:],
			lets = out.lets[:],
			datas = out.datas[:],
			enums = out.enums[:],
			things = out.things[:],
			signals = out.signals[:],
			fns = out.fns[:],
			behaviors = out.behaviors[:],
			pipelines = out.pipelines[:],
			tests = out.tests[:],
		},
		.None
}

// Decl_Sink collects the per-kind declaration slices stage_parse builds.
// One sink threaded through parse_declaration keeps the dispatch loop flat
// and the per-kind append sites obvious.
Decl_Sink :: struct {
	imports:   [dynamic]Import_Node,
	lets:      [dynamic]Let_Decl_Node,
	datas:     [dynamic]Data_Node,
	enums:     [dynamic]Enum_Node,
	things:    [dynamic]Thing_Node,
	signals:   [dynamic]Signal_Node,
	fns:       [dynamic]Fn_Node,
	behaviors: [dynamic]Behavior_Node,
	pipelines: [dynamic]Pipeline_Node,
	tests:     [dynamic]Test_Node,
}

// parse_declaration dispatches one top-level declaration off its unique
// opening keyword (LL(1), spec §02 §7) and appends it to the matching sink
// slice, attaching the accumulated leading @doc / @gtag directives.
parse_declaration :: proc(p: ^Parser, out: ^Decl_Sink, pending: ^Directives) -> Parse_Error {
	#partial switch peek_kind(p) {
	case .Import:
		node := parse_import(p) or_return
		append(&out.imports, node)
	case .Let:
		node := parse_let_decl(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		append(&out.lets, node)
	case .Data:
		node := parse_data(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		append(&out.datas, node)
	case .Enum:
		node := parse_enum(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		append(&out.enums, node)
	case .Thing, .Singleton:
		node := parse_thing(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		append(&out.things, node)
	case .Signal:
		node := parse_signal(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		append(&out.signals, node)
	case .Fn:
		node := parse_fn_decl(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		append(&out.fns, node)
	case .Behavior:
		node := parse_behavior(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		append(&out.behaviors, node)
	case .Pipeline:
		node := parse_pipeline(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		append(&out.pipelines, node)
	case .Test:
		node := parse_test(p) or_return
		node.doc = pending.doc
		append(&out.tests, node)
	case:
		return .Unexpected_Token
	}
	return .None
}

// parse_directive parses one `@doc("…")` or `@gtag("…", …)` prefix
// directive (spec §05). The file-leading @doc documents the module
// (spec §15, fun.ll1.md §5B): the first @doc is the module doc only when it
// is followed by an `import` — imports carry no directives, so a @doc before
// one cannot be the import's. A first @doc followed instead by @gtag or a
// declaration keyword is that declaration's doc. @gtag labels accumulate; a
// declaration consumes the whole accumulated directive set.
parse_directive :: proc(p: ^Parser, module_doc: ^string, pending: ^Directives, seen_decl: bool) -> Parse_Error {
	expect(p, .At) or_return
	name := expect(p, .Ident) or_return
	switch name.text {
	case "doc":
		expect(p, .L_Paren) or_return
		str := expect(p, .String_Lit) or_return
		expect(p, .R_Paren) or_return
		terminate_statement(p) or_return
		if !seen_decl && module_doc^ == "" && peek_kind(p) == .Import {
			module_doc^ = str.text
		} else {
			pending.doc = str.text
		}
	case "gtag":
		// @gtag("ball", "score") — one or more string-literal tag labels.
		expect(p, .L_Paren) or_return
		for peek_kind(p) == .String_Lit {
			tag := advance(p) or_return
			append(&pending.gtags, tag.text)
			if peek_kind(p) == .Comma {
				p.pos += 1
			} else {
				break
			}
		}
		expect(p, .R_Paren) or_return
		terminate_statement(p) or_return
	case:
		return .Unexpected_Token
	}
	return .None
}

parse_import :: proc(p: ^Parser) -> (node: Import_Node, err: Parse_Error) {
	expect(p, .Import) or_return
	segments := make([dynamic]string, 0, 4, context.temp_allocator)
	members: []string
	for {
		tok := expect(p, .Ident) or_return
		if peek_kind(p) == .Dot {
			// An interior segment is a module name — snake_case only
			// (spec §02); the final segment may also be an UpperCamel
			// type or UPPER_SNAKE constant member.
			if tok.class != .Snake_Case {
				return node, .Wrong_Case
			}
			append(&segments, tok.text)
			p.pos += 1
			if peek_kind(p) == .L_Brace {
				members = parse_import_group(p) or_return
				break
			}
			continue
		}
		if tok.class == .Mixed {
			return node, .Wrong_Case
		}
		append(&segments, tok.text)
		break
	}
	terminate_statement(p) or_return
	return Import_Node{segments = segments[:], members = members}, .None
}

parse_import_group :: proc(p: ^Parser) -> (members: []string, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	list := make([dynamic]string, 0, 8, context.temp_allocator)
	skip_newlines(p)
	for peek_kind(p) == .Ident {
		tok := advance(p) or_return
		if tok.class == .Mixed {
			return nil, .Wrong_Case
		}
		append(&list, tok.text)
		// Members separate by `,` or newline, both legal (spec §02).
		for peek_kind(p) == .Comma || peek_kind(p) == .Newline {
			p.pos += 1
		}
	}
	expect(p, .R_Brace) or_return
	return list[:], .None
}

parse_test :: proc(p: ^Parser) -> (test: Test_Node, err: Parse_Error) {
	expect(p, .Test) or_return
	name_tok := expect(p, .String_Lit) or_return
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	body := make([dynamic]Statement, 0, 4, context.temp_allocator)
	body_loop: for {
		#partial switch peek_kind(p) {
		case .Assert:
			node := parse_assert(p) or_return
			append(&body, node)
		case .Let:
			node := parse_let(p) or_return
			append(&body, node)
		case:
			break body_loop
		}
		skip_newlines(p)
	}
	expect(p, .R_Brace) or_return
	return Test_Node{name = name_tok.text, body = body[:]}, .None
}

parse_assert :: proc(p: ^Parser) -> (node: Assert_Node, err: Parse_Error) {
	expect(p, .Assert) or_return
	expr := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Assert_Node{expr = expr}, .None
}

parse_let :: proc(p: ^Parser) -> (node: Let_Node, err: Parse_Error) {
	expect(p, .Let) or_return
	name := expect(p, .Ident) or_return
	// A binding name is a value name: snake_case, or UPPER_SNAKE for a
	// module-level constant (spec §02).
	if name.class != .Snake_Case && name.class != .Upper_Snake {
		return node, .Wrong_Case
	}
	expect(p, .Eq) or_return
	value := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Let_Node{name = name.text, value = value}, .None
}

// parse_let_decl parses a module-level constant `let NAME: T = expr`
// (spec §02 §6–7). The type ascription is mandatory at module level (the
// constant has no surrounding inference context); the name is UPPER_SNAKE
// or snake_case (spec §02: the sanctioned constant exceptions pi/tau
// classify snake_case).
parse_let_decl :: proc(p: ^Parser) -> (node: Let_Decl_Node, err: Parse_Error) {
	expect(p, .Let) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case && name.class != .Upper_Snake {
		return node, .Wrong_Case
	}
	expect(p, .Colon) or_return
	type := parse_type_ref(p) or_return
	expect(p, .Eq) or_return
	value := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Let_Decl_Node{name = name.text, type = type, value = value}, .None
}

// parse_data parses `data Name { field: T = default … }` (spec §03 §1),
// with the optional `data Name: Kind { … }` kind ascription (§03 §4). The
// kind is contextual — a bare UpperCamel name in the post-colon position,
// never a reserved word.
parse_data :: proc(p: ^Parser) -> (node: Data_Node, err: Parse_Error) {
	expect(p, .Data) or_return
	name := expect_type_name(p) or_return
	kind := parse_optional_kind(p) or_return
	fields := parse_field_list(p) or_return
	return Data_Node{name = name, kind = kind, fields = fields}, .None
}

// parse_thing parses `thing Name { … }` and `singleton Name { … }`
// (spec §06 §1–2); a singleton is told apart only by the is_singleton flag.
parse_thing :: proc(p: ^Parser) -> (node: Thing_Node, err: Parse_Error) {
	is_singleton := peek_kind(p) == .Singleton
	advance(p) or_return // `thing` or `singleton`
	name := expect_type_name(p) or_return
	fields := parse_field_list(p) or_return
	return Thing_Node{name = name, is_singleton = is_singleton, fields = fields}, .None
}

// parse_signal parses `signal Name { field: T }` (spec §03 §6, §06 §5) —
// a data value the engine routes; its body is a field list like data.
parse_signal :: proc(p: ^Parser) -> (node: Signal_Node, err: Parse_Error) {
	expect(p, .Signal) or_return
	name := expect_type_name(p) or_return
	fields := parse_field_list(p) or_return
	return Signal_Node{name = name, fields = fields}, .None
}

// parse_optional_kind reads a `: Kind` ascription after a type name
// (spec §03 §4). The kind is a contextual UpperCamel name; returns "" when
// the next token is not `:`.
parse_optional_kind :: proc(p: ^Parser) -> (kind: string, err: Parse_Error) {
	if peek_kind(p) != .Colon {
		return "", .None
	}
	p.pos += 1
	kind_tok := expect_type_name(p) or_return
	return kind_tok, .None
}

// parse_field_list parses `{ name: T (= default)? … }` — the shared body of
// data/thing/singleton/signal declarations (spec §03 §1). Fields are
// newline- or comma-separated (the body is a block, so the lexer kept the
// newlines); a defaulted field carries `= expr` (spec §03 §1: a defaulted
// field may be omitted from a literal).
parse_field_list :: proc(p: ^Parser) -> (fields: []Field_Decl, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	skip_field_separators(p)
	list := make([dynamic]Field_Decl, 0, 8, context.temp_allocator)
	for peek_kind(p) == .Ident {
		fname := advance(p) or_return
		// Field names are value names — snake_case (spec §02).
		if fname.class != .Snake_Case {
			return nil, .Wrong_Case
		}
		expect(p, .Colon) or_return
		type := parse_type_ref(p) or_return
		field := Field_Decl{name = fname.text, type = type}
		if peek_kind(p) == .Eq {
			p.pos += 1
			field.default = parse_expression(p) or_return
			field.has_default = true
		}
		append(&list, field)
		skip_field_separators(p)
	}
	expect(p, .R_Brace) or_return
	return list[:], .None
}

// parse_enum parses `enum Name { Variant, Variant(T), Variant{ f: T } }`
// (spec §03 §2), with the optional enum-as-role kind ascription
// `enum Steer: Axis { … }` (§03 §4). Variants are UpperCamel, newline- or
// comma-separated.
parse_enum :: proc(p: ^Parser) -> (node: Enum_Node, err: Parse_Error) {
	expect(p, .Enum) or_return
	name := expect_type_name(p) or_return
	kind := parse_optional_kind(p) or_return
	expect(p, .L_Brace) or_return
	skip_field_separators(p)
	variants := make([dynamic]Variant_Decl, 0, 8, context.temp_allocator)
	for peek_kind(p) == .Ident {
		variant := parse_variant(p) or_return
		append(&variants, variant)
		skip_field_separators(p)
	}
	expect(p, .R_Brace) or_return
	return Enum_Node{name = name, kind = kind, variants = variants[:]}, .None
}

// parse_variant parses one enum variant: plain `Left`, tuple-payload
// `MoveTo(Vec2)`, or struct-payload `Rgb{ r: Fixed, … }` (spec §03 §2).
parse_variant :: proc(p: ^Parser) -> (variant: Variant_Decl, err: Parse_Error) {
	name := expect(p, .Ident) or_return
	// Variant names are UPPER_IDENT (lexical-core.ebnf §2).
	if !is_upper_ident(name.class) {
		return variant, .Wrong_Case
	}
	variant.name = name.text
	#partial switch peek_kind(p) {
	case .L_Paren:
		// Tuple payload: positional types.
		p.pos += 1
		types := make([dynamic]Type_Ref, 0, 4, context.temp_allocator)
		for peek_kind(p) != .R_Paren {
			type := parse_type_ref(p) or_return
			append(&types, type)
			if peek_kind(p) == .Comma {
				p.pos += 1
			} else {
				break
			}
		}
		expect(p, .R_Paren) or_return
		variant.payload = .Tuple
		variant.tuple = types[:]
	case .L_Brace:
		// Struct payload: named fields, same shape as a data field list.
		fields := parse_field_list(p) or_return
		variant.payload = .Struct
		variant.fields = fields
	case:
		variant.payload = .Plain
	}
	return variant, .None
}

// parse_fn_decl parses a top-level function `fn name(p: T, …) -> R { … }`
// (spec §02 §7, §04). The name is snake_case; the body is the shared
// statement sequence (let/return/if early-return) — generalizing the
// single-return lambda the Pratt cascade carries (expr.odin).
parse_fn_decl :: proc(p: ^Parser) -> (node: Fn_Node, err: Parse_Error) {
	expect(p, .Fn) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case {
		return node, .Wrong_Case
	}
	fn := parse_fn_rest(p) or_return
	fn.name = name.text
	return fn, .None
}

// parse_fn_rest parses everything after a function's name: the parameter
// list, the `-> R` return type, and the brace-delimited statement body.
// Shared by top-level fns and the behavior `step` entry point.
parse_fn_rest :: proc(p: ^Parser) -> (node: Fn_Node, err: Parse_Error) {
	params := parse_param_list(p) or_return
	expect(p, .Arrow) or_return
	return_type := parse_type_ref(p) or_return
	body := parse_fn_body(p) or_return
	return Fn_Node{params = params, return_type = return_type, body = body}, .None
}

// parse_param_list parses `(name: T, …)` — a function's typed parameters
// (spec §06 §3: a behavior's params are its reads). Parameter names are
// snake_case value names.
parse_param_list :: proc(p: ^Parser) -> (params: []Param_Decl, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	list := make([dynamic]Param_Decl, 0, 4, context.temp_allocator)
	for peek_kind(p) == .Ident {
		pname := advance(p) or_return
		if pname.class != .Snake_Case {
			return nil, .Wrong_Case
		}
		expect(p, .Colon) or_return
		type := parse_type_ref(p) or_return
		append(&list, Param_Decl{name = pname.text, type = type})
		if peek_kind(p) == .Comma {
			p.pos += 1
		} else {
			break
		}
	}
	expect(p, .R_Paren) or_return
	return list[:], .None
}

// parse_fn_body parses a `{ let … / if … / return … }` statement sequence
// (spec §02 §6). A fn body produces its value only through an explicit
// `return`; an `if cond { return … }` is the early-return guard form.
parse_fn_body :: proc(p: ^Parser) -> (body: []Statement, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	stmts := make([dynamic]Statement, 0, 4, context.temp_allocator)
	body_loop: for {
		#partial switch peek_kind(p) {
		case .Let:
			node := parse_let(p) or_return
			append(&stmts, node)
		case .Return:
			node := parse_return(p) or_return
			append(&stmts, node)
		case .If:
			node := parse_if_stmt(p) or_return
			append(&stmts, node)
		case:
			break body_loop
		}
		skip_newlines(p)
	}
	expect(p, .R_Brace) or_return
	return stmts[:], .None
}

// parse_return parses `return expr` (spec §02 §6) — the mandatory
// value-producing statement of a fn body.
parse_return :: proc(p: ^Parser) -> (node: Return_Node, err: Parse_Error) {
	expect(p, .Return) or_return
	value := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Return_Node{value = value}, .None
}

// parse_if_stmt parses the early-return guard `if cond { return … }`
// (spec §02 §5). The condition parses in the no-struct-literal context (a
// trailing `{` opens the guarded block, not a record literal off the
// condition), mirroring the match-scrutinee rule (expr.odin). The body is
// the same fn-body statement sequence.
parse_if_stmt :: proc(p: ^Parser) -> (node: If_Node, err: Parse_Error) {
	expect(p, .If) or_return
	saved := p.no_record_brace
	p.no_record_brace = true
	cond := parse_expression(p) or_return
	p.no_record_brace = saved
	body := parse_fn_body(p) or_return
	return If_Node{cond = cond, body = body}, .None
}

// parse_behavior parses `behavior name on Thing { fn step(…) -> … { … } }`
// (spec §06 §3). The entry point is the reserved name `step` — a behavior
// has exactly one, and any other name is rejected here. The target is the
// `on Thing` UpperCamel type whose blackboard this behavior owns.
parse_behavior :: proc(p: ^Parser) -> (node: Behavior_Node, err: Parse_Error) {
	expect(p, .Behavior) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case {
		return node, .Wrong_Case
	}
	expect(p, .On) or_return
	target := expect_type_name(p) or_return
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	expect(p, .Fn) or_return
	step_name := expect(p, .Ident) or_return
	if step_name.text != "step" {
		// `step` is the built-in, reserved entry point (spec §06 §3); a
		// behavior names no other.
		return node, .Unexpected_Token
	}
	step := parse_fn_rest(p) or_return
	step.name = "step"
	skip_newlines(p)
	expect(p, .R_Brace) or_return
	return Behavior_Node{name = name.text, target = target, step = step}, .None
}

// parse_pipeline parses `pipeline Name { stage: [behaviors] … }`
// (spec §07 §1). Stage order is the contract, so stages keep source order;
// each stage's value on the golden surface is a `[behavior, …]` list.
parse_pipeline :: proc(p: ^Parser) -> (node: Pipeline_Node, err: Parse_Error) {
	expect(p, .Pipeline) or_return
	name := expect_type_name(p) or_return
	expect(p, .L_Brace) or_return
	skip_field_separators(p)
	stages := make([dynamic]Pipeline_Stage, 0, 8, context.temp_allocator)
	for peek_kind(p) == .Ident {
		sname := advance(p) or_return
		// Stage names are documentary value names — snake_case (spec §07).
		if sname.class != .Snake_Case {
			return node, .Wrong_Case
		}
		expect(p, .Colon) or_return
		behaviors := parse_behavior_list(p) or_return
		append(&stages, Pipeline_Stage{name = sname.text, behaviors = behaviors})
		skip_field_separators(p)
	}
	expect(p, .R_Brace) or_return
	return Pipeline_Node{name = name, stages = stages[:]}, .None
}

// parse_behavior_list parses a `[behavior_name, …]` stage value
// (spec §07 §1). Behavior names are snake_case; the list is newline- or
// comma-separated, though a stage value sits on one line in the golden
// surface.
parse_behavior_list :: proc(p: ^Parser) -> (names: []string, err: Parse_Error) {
	expect(p, .L_Bracket) or_return
	list := make([dynamic]string, 0, 4, context.temp_allocator)
	for peek_kind(p) == .Ident {
		bname := advance(p) or_return
		if bname.class != .Snake_Case {
			return nil, .Wrong_Case
		}
		append(&list, bname.text)
		for peek_kind(p) == .Comma || peek_kind(p) == .Newline {
			p.pos += 1
		}
	}
	expect(p, .R_Bracket) or_return
	return list[:], .None
}

// parse_type_ref parses a syntactic type (spec §02 §3): a bare name
// (`Fixed`), a generic application (`View[Paddle]`, `Option[Side]`), or a
// list (`[Goal]`). A list is recorded as the head "[]" with one argument,
// so every parameterized form shares one node shape. This is parse-only —
// no resolution to a checker Type.
parse_type_ref :: proc(p: ^Parser) -> (type: Type_Ref, err: Parse_Error) {
	if peek_kind(p) == .L_Bracket {
		// List type `[T]` — the head is "[]" with the element as its arg.
		p.pos += 1
		elem := parse_type_ref(p) or_return
		expect(p, .R_Bracket) or_return
		args := make([]Type_Ref, 1, context.temp_allocator)
		args[0] = elem
		return Type_Ref{name = "[]", args = args}, .None
	}
	name := expect(p, .Ident) or_return
	// Type names are UPPER_IDENT (spec §02; lexical-core.ebnf §2); the
	// wrong-case verdict fires before the construct is built.
	if !is_upper_ident(name.class) {
		return type, .Wrong_Case
	}
	type.name = name.text
	if peek_kind(p) == .L_Bracket {
		// Generic application `Name[T, …]` (spec §03 §3: generics on
		// engine/stdlib containers only).
		p.pos += 1
		args := make([dynamic]Type_Ref, 0, 4, context.temp_allocator)
		for peek_kind(p) != .R_Bracket {
			arg := parse_type_ref(p) or_return
			append(&args, arg)
			if peek_kind(p) == .Comma {
				p.pos += 1
			} else {
				break
			}
		}
		expect(p, .R_Bracket) or_return
		type.args = args[:]
	}
	return type, .None
}

// expect_type_name consumes an UpperCamel type name — the declared name of
// a data/enum/thing/signal/pipeline or a kind/target ascription (spec §02).
expect_type_name :: proc(p: ^Parser) -> (name: string, err: Parse_Error) {
	tok := expect(p, .Ident) or_return
	// A declared type name or kind/target ascription is UPPER_IDENT
	// (lexical-core.ebnf §2).
	if !is_upper_ident(tok.class) {
		return "", .Wrong_Case
	}
	return tok.text, .None
}

// skip_field_separators consumes the newline-or-comma run between fields,
// variants, or stages (spec §02 §1: both are legal separators).
skip_field_separators :: proc(p: ^Parser) {
	for peek_kind(p) == .Newline || peek_kind(p) == .Comma {
		p.pos += 1
	}
}

// check_ident_case enforces the casing-is-structural rule (spec §02): a
// name followed by `{` (record-literal constructor) or `::` (variant
// selector) stands in type position and must be UPPER_IDENT; a name
// followed by `.` is a member-access receiver — a value name or a
// type's associated module (Fixed.MAX, Quat.identity) — so any sanctioned
// class passes; a name followed by `(` is a callee — a snake_case function
// (clamp(…)) or an UPPER_IDENT command/type constructor (Spawn(…),
// Despawn()) — so any sanctioned class passes there too; any other
// value/function name must be snake_case, or UPPER_SNAKE for a bare
// constant. The casing verdict fires before the construct is parsed, so a
// wrong-case name always reports Wrong_Case rather than a generic
// Unexpected_Token.
check_ident_case :: proc(tok: Token, following: Token_Kind) -> Parse_Error {
	if tok.class == .Mixed {
		return .Wrong_Case
	}
	#partial switch following {
	case .L_Brace, .Colon_Colon:
		// A record-literal constructor or an enum-type head stands in type
		// position — an UPPER_IDENT (lexical-core.ebnf §2), which admits a
		// single-capital head as well as multi-word UpperCamel.
		if !is_upper_ident(tok.class) {
			return .Wrong_Case
		}
	case .Dot, .L_Paren:
		// A member-access receiver or a callee — any sanctioned class.
	case:
		if tok.class != .Snake_Case && tok.class != .Upper_Snake {
			return .Wrong_Case
		}
	}
	return .None
}

// terminate_statement consumes the newline statement terminator
// (spec §02); end of input and a closing brace also end the last
// statement of their scope.
terminate_statement :: proc(p: ^Parser) -> Parse_Error {
	if peek_kind(p) == .Newline {
		p.pos += 1
		return .None
	}
	if at_end(p) || peek_kind(p) == .R_Brace {
		return .None
	}
	return .Unexpected_Token
}

at_end :: proc(p: ^Parser) -> bool {
	return p.pos >= len(p.tokens)
}

// peek_kind reports Invalid at end of input so callers' kind checks
// fail closed without a separate end test.
peek_kind :: proc(p: ^Parser) -> Token_Kind {
	if at_end(p) {
		return .Invalid
	}
	return p.tokens[p.pos].kind
}

advance :: proc(p: ^Parser) -> (tok: Token, err: Parse_Error) {
	if at_end(p) {
		return Token{}, .Unexpected_End
	}
	tok = p.tokens[p.pos]
	p.pos += 1
	return tok, .None
}

expect :: proc(p: ^Parser, kind: Token_Kind) -> (tok: Token, err: Parse_Error) {
	tok = advance(p) or_return
	if tok.kind != kind {
		return Token{}, .Unexpected_Token
	}
	return tok, .None
}

skip_newlines :: proc(p: ^Parser) {
	for peek_kind(p) == .Newline {
		p.pos += 1
	}
}
