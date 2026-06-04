// Parser for the trivial-assert grammar: the single statement-layer
// production `test "name" { assert <operand> == <operand> }` where an
// operand is an Int literal, a Fixed literal, or a to_fixed(Int) call.
// LL(1) per spec §02 — every production opens with a unique keyword, so
// one token of lookahead selects it. The full Pratt expression parser
// (spec §02) replaces the operand layer behind the same stage seam.
package funpack

Operand_Kind :: enum {
	Int_Literal,
	Fixed_Literal,
	To_Fixed_Call,
}

Operand :: struct {
	kind:       Operand_Kind,
	int_value:  i64,   // Int_Literal value; To_Fixed_Call argument
	fixed_bits: Fixed, // Fixed_Literal value
}

Assert_Node :: struct {
	lhs: Operand,
	rhs: Operand,
}

Test_Node :: struct {
	name:    string,
	asserts: []Assert_Node,
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
	tests := make([dynamic]Test_Node, 0, 4, context.temp_allocator)
	skip_newlines(&p)
	for !at_end(&p) {
		test := parse_test(&p) or_return
		append(&tests, test)
		skip_newlines(&p)
	}
	return Ast{tests = tests[:]}, .None
}

parse_test :: proc(p: ^Parser) -> (test: Test_Node, err: Parse_Error) {
	expect(p, .Test) or_return
	name_tok := expect(p, .String_Lit) or_return
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	asserts := make([dynamic]Assert_Node, 0, 4, context.temp_allocator)
	for peek_kind(p) == .Assert {
		node := parse_assert(p) or_return
		append(&asserts, node)
		skip_newlines(p)
	}
	expect(p, .R_Brace) or_return
	return Test_Node{name = name_tok.text, asserts = asserts[:]}, .None
}

parse_assert :: proc(p: ^Parser) -> (node: Assert_Node, err: Parse_Error) {
	expect(p, .Assert) or_return
	lhs := parse_operand(p) or_return
	expect(p, .Eq_Eq) or_return
	rhs := parse_operand(p) or_return
	// Statement terminator is the newline (spec §02); a closing brace
	// also ends the single-line form.
	if peek_kind(p) == .Newline {
		p.pos += 1
	} else if peek_kind(p) != .R_Brace {
		return Assert_Node{}, .Unexpected_Token
	}
	return Assert_Node{lhs = lhs, rhs = rhs}, .None
}

parse_operand :: proc(p: ^Parser) -> (op: Operand, err: Parse_Error) {
	tok := advance(p) or_return
	#partial switch tok.kind {
	case .Int_Lit:
		return Operand{kind = .Int_Literal, int_value = tok.int_value}, .None
	case .Fixed_Lit:
		return Operand{kind = .Fixed_Literal, fixed_bits = tok.fixed_bits}, .None
	case .Ident:
		check_ident_case(tok, peek_kind(p)) or_return
		if tok.text == "to_fixed" {
			return parse_to_fixed_call(p)
		}
	}
	return Operand{}, .Unexpected_Token
}

// check_ident_case enforces the casing-is-structural rule (spec §02): a
// name followed by `{` (record-literal constructor) or `::` (variant
// selector) stands in type position and must be UpperCamel; any other
// value/function name must be snake_case, or UPPER_SNAKE for a bare
// constant. The casing verdict fires before the construct is parsed, so
// a wrong-case name in a not-yet-supported production still reports
// Wrong_Case rather than a generic Unexpected_Token.
check_ident_case :: proc(tok: Token, following: Token_Kind) -> Parse_Error {
	type_position := following == .L_Brace || following == .Colon_Colon
	if type_position {
		if tok.class != .Upper_Camel {
			return .Wrong_Case
		}
		return .None
	}
	if tok.class != .Snake_Case && tok.class != .Upper_Snake {
		return .Wrong_Case
	}
	return .None
}

parse_to_fixed_call :: proc(p: ^Parser) -> (op: Operand, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	arg := expect(p, .Int_Lit) or_return
	expect(p, .R_Paren) or_return
	return Operand{kind = .To_Fixed_Call, int_value = arg.int_value}, .None
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
