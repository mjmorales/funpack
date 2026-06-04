// Lexer for the golden-file lexis (spec §02): keywords, identifiers,
// Int and Fixed literals, string literals, the operator/separator/
// bracket glyph set, and the newline statement terminator. The lexer
// is total — an unrecognized character becomes an Invalid token for the
// parser to reject — and has no comment production (P6): `//` lexes as
// two division glyphs, never a swallowed span. Unary minus is a
// separate token, not part of a numeric literal. A Newline token is a
// statement terminator, so newlines that are mere layout — inside
// ( ) [ ] nesting, inside record-literal braces, or before a
// leading-dot chain continuation — are dropped here and never reach
// the parser. Every identifier carries its casing class: casing is a
// structural signal (spec §02), and a wrong case is a compile error,
// never a silent rename.
package funpack

Token_Kind :: enum {
	Invalid,
	// declaration/statement keywords (one unique opener per production)
	Test,
	Assert,
	Import,
	Let,
	Return,
	Fn,
	// names and literals
	Ident,
	Int_Lit,
	Fixed_Lit,
	String_Lit,
	// brackets
	L_Paren,
	R_Paren,
	L_Brace,
	R_Brace,
	L_Bracket,
	R_Bracket,
	// operators and separators — one concept per glyph (spec §02)
	At,          // directive prefix
	Dot,         // member access / import path
	Colon_Colon, // enum-variant selector, only
	Colon,       // type ascription / record-field separator
	Comma,
	Arrow, // function return type
	Eq,    // binding, never equality
	Eq_Eq,
	Not_Eq,
	Lt,
	Lt_Eq,
	Gt,
	Gt_Eq,
	Plus,
	Minus,
	Star,
	Slash,
	Percent,
	Newline,
}

// Ident_Class is the closed casing taxonomy of spec §02. The class is
// decided by spelling alone; which class a grammar position demands is
// the parser's call. pi/tau — the sanctioned lowercase constants —
// classify as Snake_Case by construction.
Ident_Class :: enum {
	None,        // non-identifier tokens
	Upper_Camel, // type names and enum variants
	Snake_Case,  // values, functions, behaviors, fields, parameters, modules
	Upper_Snake, // module-level let constants
	Mixed,       // matches no sanctioned class — always a compile error
}

Token :: struct {
	kind:       Token_Kind,
	text:       string,
	class:      Ident_Class, // Ident casing class
	int_value:  i64,         // Int_Lit value
	fixed_bits: Fixed,       // Fixed_Lit value
}

stage_lex :: proc(source: string) -> []Token {
	tokens := make([dynamic]Token, 0, 16, context.temp_allocator)
	nesting := Nesting {
		brace_is_record = make([dynamic]bool, 0, 8, context.temp_allocator),
	}
	prev_kind := Token_Kind.Invalid
	i := 0
	for i < len(source) {
		ch := source[i]
		tok: Token
		next: int
		switch {
		case ch == ' ' || ch == '\t' || ch == '\r':
			i += 1
			continue
		case ch == '"':
			tok, next = scan_string(source, i)
		case is_digit(ch):
			tok, next = scan_number(source, i)
		case is_ident_start(ch):
			tok, next = scan_ident(source, i)
		case:
			tok, next = scan_punct(source, i)
		}
		if tok.kind == .Newline && newline_suppressed(&nesting, source, next) {
			i = next
			continue
		}
		update_nesting(&nesting, tok.kind, prev_kind)
		append(&tokens, tok)
		prev_kind = tok.kind
		i = next
	}
	return tokens[:]
}

// Nesting tracks the bracket context that decides whether a newline is
// a statement terminator (spec §02). Newlines inside ( ) [ ] and inside
// record-literal { } are layout; block { } interiors are statement
// sequences, so theirs are kept. The two brace roles are told apart by
// the predecessor token: a `{` directly after an identifier is a
// record-literal constructor (Vec2{…}); any other `{` (after a test
// name string, a lambda's `)`) opens a block.
Nesting :: struct {
	paren_bracket_depth: int,
	record_brace_depth:  int,
	brace_is_record:     [dynamic]bool,
}

newline_suppressed :: proc(n: ^Nesting, source: string, after: int) -> bool {
	if n.paren_bracket_depth > 0 || n.record_brace_depth > 0 {
		return true
	}
	// Leading-dot chain continuation (spec §02): a newline whose next
	// line opens with `.` joins the statement instead of ending it.
	j := after
	for j < len(source) && (source[j] == ' ' || source[j] == '\t' || source[j] == '\r') {
		j += 1
	}
	return j < len(source) && source[j] == '.'
}

update_nesting :: proc(n: ^Nesting, kind: Token_Kind, prev: Token_Kind) {
	#partial switch kind {
	case .L_Paren, .L_Bracket:
		n.paren_bracket_depth += 1
	case .R_Paren, .R_Bracket:
		n.paren_bracket_depth = max(0, n.paren_bracket_depth - 1)
	case .L_Brace:
		is_record := prev == .Ident
		append(&n.brace_is_record, is_record)
		if is_record {
			n.record_brace_depth += 1
		}
	case .R_Brace:
		if len(n.brace_is_record) > 0 && pop(&n.brace_is_record) {
			n.record_brace_depth = max(0, n.record_brace_depth - 1)
		}
	}
}

// scan_punct applies maximal munch: the two-glyph operators are matched
// before their one-glyph prefixes (== before =, :: before :, -> before -).
scan_punct :: proc(source: string, start: int) -> (tok: Token, next: int) {
	two := source[start:min(start + 2, len(source))]
	switch two {
	case "==":
		return Token{kind = .Eq_Eq, text = two}, start + 2
	case "!=":
		return Token{kind = .Not_Eq, text = two}, start + 2
	case "<=":
		return Token{kind = .Lt_Eq, text = two}, start + 2
	case ">=":
		return Token{kind = .Gt_Eq, text = two}, start + 2
	case "::":
		return Token{kind = .Colon_Colon, text = two}, start + 2
	case "->":
		return Token{kind = .Arrow, text = two}, start + 2
	}
	one := source[start : start+1]
	one_kind: Token_Kind
	switch source[start] {
	case '\n':
		one_kind = .Newline
	case '(':
		one_kind = .L_Paren
	case ')':
		one_kind = .R_Paren
	case '{':
		one_kind = .L_Brace
	case '}':
		one_kind = .R_Brace
	case '[':
		one_kind = .L_Bracket
	case ']':
		one_kind = .R_Bracket
	case '@':
		one_kind = .At
	case '.':
		one_kind = .Dot
	case ':':
		one_kind = .Colon
	case ',':
		one_kind = .Comma
	case '=':
		one_kind = .Eq
	case '<':
		one_kind = .Lt
	case '>':
		one_kind = .Gt
	case '+':
		one_kind = .Plus
	case '-':
		one_kind = .Minus
	case '*':
		one_kind = .Star
	case '/':
		one_kind = .Slash
	case '%':
		one_kind = .Percent
	case:
		one_kind = .Invalid
	}
	return Token{kind = one_kind, text = one}, start + 1
}

// scan_string returns the contents between the quotes; an unterminated
// string (end of input or a newline before the closing quote) is Invalid.
scan_string :: proc(source: string, start: int) -> (tok: Token, next: int) {
	i := start + 1
	for i < len(source) && source[i] != '"' && source[i] != '\n' {
		i += 1
	}
	if i >= len(source) || source[i] != '"' {
		return Token{kind = .Invalid, text = source[start:i]}, i
	}
	return Token{kind = .String_Lit, text = source[start+1 : i]}, i + 1
}

// scan_number is type-directed per spec §10: a bare digit run is Int,
// digits with a `.` and a fractional digit run is Fixed.
scan_number :: proc(source: string, start: int) -> (tok: Token, next: int) {
	i := start
	for i < len(source) && is_digit(source[i]) {
		i += 1
	}
	if i+1 < len(source) && source[i] == '.' && is_digit(source[i+1]) {
		frac_start := i + 1
		j := frac_start
		for j < len(source) && is_digit(source[j]) {
			j += 1
		}
		bits := fixed_from_decimal(parse_digits(source[start:i]), source[frac_start:j])
		return Token{kind = .Fixed_Lit, text = source[start:j], fixed_bits = bits}, j
	}
	text := source[start:i]
	return Token{kind = .Int_Lit, text = text, int_value = parse_digits(text)}, i
}

scan_ident :: proc(source: string, start: int) -> (tok: Token, next: int) {
	i := start
	for i < len(source) && is_ident_char(source[i]) {
		i += 1
	}
	text := source[start:i]
	switch text {
	case "test":
		return Token{kind = .Test, text = text}, i
	case "assert":
		return Token{kind = .Assert, text = text}, i
	case "import":
		return Token{kind = .Import, text = text}, i
	case "let":
		return Token{kind = .Let, text = text}, i
	case "return":
		return Token{kind = .Return, text = text}, i
	case "fn":
		return Token{kind = .Fn, text = text}, i
	}
	return Token{kind = .Ident, text = text, class = classify_ident(text)}, i
}

classify_ident :: proc(text: string) -> Ident_Class {
	has_lower, has_upper, has_underscore: bool
	for ch in text {
		switch {
		case ch >= 'a' && ch <= 'z':
			has_lower = true
		case ch >= 'A' && ch <= 'Z':
			has_upper = true
		case ch == '_':
			has_underscore = true
		}
	}
	first := text[0]
	switch {
	case first >= 'A' && first <= 'Z' && !has_lower:
		return .Upper_Snake
	case first >= 'A' && first <= 'Z' && !has_underscore:
		return .Upper_Camel
	case !has_upper:
		return .Snake_Case
	}
	return .Mixed
}

parse_digits :: proc(text: string) -> i64 {
	value: i64 = 0
	for ch in text {
		value = value*10 + i64(ch - '0')
	}
	return value
}

is_digit :: proc(ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

is_ident_start :: proc(ch: u8) -> bool {
	return ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

is_ident_char :: proc(ch: u8) -> bool {
	return is_ident_start(ch) || is_digit(ch)
}
