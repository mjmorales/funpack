// Lexer for the trivial-assert lexis (spec §02): the test/assert
// keywords, identifiers, Int and Fixed literals, string literals,
// parens, braces, ==, and the newline statement terminator. The lexer
// is total — an unrecognized character becomes an Invalid token for the
// parser to reject. The full lexis widens this behind the same stage
// seam.
package funpack

Token_Kind :: enum {
	Invalid,
	Test,
	Assert,
	Ident,
	Int_Lit,
	Fixed_Lit,
	String_Lit,
	L_Paren,
	R_Paren,
	L_Brace,
	R_Brace,
	Eq_Eq,
	Newline,
}

Token :: struct {
	kind:       Token_Kind,
	text:       string,
	int_value:  i64,   // Int_Lit value
	fixed_bits: Fixed, // Fixed_Lit value
}

stage_lex :: proc(source: string) -> []Token {
	tokens := make([dynamic]Token, 0, 16, context.temp_allocator)
	i := 0
	for i < len(source) {
		ch := source[i]
		switch {
		case ch == ' ' || ch == '\t' || ch == '\r':
			i += 1
		case ch == '"':
			tok, next := scan_string(source, i)
			append(&tokens, tok)
			i = next
		case is_digit(ch):
			tok, next := scan_number(source, i)
			append(&tokens, tok)
			i = next
		case is_ident_start(ch):
			tok, next := scan_ident(source, i)
			append(&tokens, tok)
			i = next
		case:
			tok, next := scan_punct(source, i)
			append(&tokens, tok)
			i = next
		}
	}
	return tokens[:]
}

scan_punct :: proc(source: string, start: int) -> (tok: Token, next: int) {
	text := source[start : start+1]
	switch source[start] {
	case '\n':
		return Token{kind = .Newline, text = text}, start + 1
	case '(':
		return Token{kind = .L_Paren, text = text}, start + 1
	case ')':
		return Token{kind = .R_Paren, text = text}, start + 1
	case '{':
		return Token{kind = .L_Brace, text = text}, start + 1
	case '}':
		return Token{kind = .R_Brace, text = text}, start + 1
	case '=':
		if start+1 < len(source) && source[start+1] == '=' {
			return Token{kind = .Eq_Eq, text = source[start : start+2]}, start + 2
		}
	}
	return Token{kind = .Invalid, text = text}, start + 1
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
	}
	return Token{kind = .Ident, text = text}, i
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
