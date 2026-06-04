// LL(1) statement-layer parser over the golden-file surface (spec §02):
// a file-leading @doc as the module doc, per-test @doc directives,
// import in its three forms (whole module, dotted single member, member
// group), and test blocks whose body is an ordered sequence of let and
// assert statements. Every production opens with a unique keyword, so
// one token of lookahead selects it. Expressions route through the
// single parse_expression seam owned by the Pratt cascade (expr.odin).
package funpack

Assert_Node :: struct {
	expr: Expr,
}

Let_Node :: struct {
	name:  string,
	value: Expr,
}

Statement :: union {
	Assert_Node,
	Let_Node,
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

Parse_Error :: enum {
	None,
	Unexpected_Token,
	Unexpected_End,
	Wrong_Case, // an identifier whose casing class is wrong for its grammar position (spec §02)
}

Parser :: struct {
	tokens: []Token,
	pos:    int,
}

stage_parse :: proc(tokens: []Token) -> (ast: Ast, err: Parse_Error) {
	p := Parser{tokens = tokens}
	imports := make([dynamic]Import_Node, 0, 4, context.temp_allocator)
	tests := make([dynamic]Test_Node, 0, 4, context.temp_allocator)
	module_doc := ""
	pending_doc := ""
	seen_decl := false
	skip_newlines(&p)
	for !at_end(&p) {
		#partial switch peek_kind(&p) {
		case .At:
			text := parse_doc_directive(&p) or_return
			// The file-leading @doc documents the module (spec §15);
			// any later @doc attaches to the test that follows it.
			if !seen_decl && module_doc == "" {
				module_doc = text
			} else {
				pending_doc = text
			}
		case .Import:
			node := parse_import(&p) or_return
			append(&imports, node)
			seen_decl = true
		case .Test:
			node := parse_test(&p) or_return
			node.doc = pending_doc
			pending_doc = ""
			append(&tests, node)
			seen_decl = true
		case:
			return Ast{}, .Unexpected_Token
		}
		skip_newlines(&p)
	}
	return Ast{module_doc = module_doc, imports = imports[:], tests = tests[:]}, .None
}

parse_doc_directive :: proc(p: ^Parser) -> (text: string, err: Parse_Error) {
	expect(p, .At) or_return
	name := expect(p, .Ident) or_return
	if name.text != "doc" {
		return "", .Unexpected_Token
	}
	expect(p, .L_Paren) or_return
	str := expect(p, .String_Lit) or_return
	expect(p, .R_Paren) or_return
	terminate_statement(p) or_return
	return str.text, .None
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

// check_ident_case enforces the casing-is-structural rule (spec §02): a
// name followed by `{` (record-literal constructor) or `::` (variant
// selector) stands in type position and must be UpperCamel; a name
// followed by `.` is a member-access receiver — a value name or a
// type's associated module (Fixed.MAX, Quat.identity) — so any
// sanctioned class passes; any other value/function name must be
// snake_case, or UPPER_SNAKE for a bare constant. The casing verdict
// fires before the construct is parsed, so a wrong-case name always
// reports Wrong_Case rather than a generic Unexpected_Token.
check_ident_case :: proc(tok: Token, following: Token_Kind) -> Parse_Error {
	if tok.class == .Mixed {
		return .Wrong_Case
	}
	#partial switch following {
	case .L_Brace, .Colon_Colon:
		if tok.class != .Upper_Camel {
			return .Wrong_Case
		}
	case .Dot:
		// any sanctioned class
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
