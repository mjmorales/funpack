package funpack

Fpm_Token_Kind :: enum {
	Invalid,
	Model,
	Rig,
	Param,
	Emit,
	Anchor,
	Socket,
	Material,
	Collide,
	Skeleton,
	Part,
	Mirror,
	Clearance,
	Fn,
	Let,
	Return,
	For,
	In,
	At,
	Lower_Ident,
	Upper_Ident,
	Int_Lit,
	Float_Lit,
	String_Lit,
	L_Paren,
	R_Paren,
	L_Brace,
	R_Brace,
	L_Bracket,
	R_Bracket,
	Dot,
	Dot_Dot,
	Colon,
	Comma,
	Arrow,
	Eq,
	Plus,
	Minus,
	Star,
	Slash,
	Percent,
	Newline,
}

Fpm_Ident_Case :: enum {
	None,
	Lower,
	Upper,
}

Fpm_Token :: struct {
	kind:        Fpm_Token_Kind,
	text:        string,
	ident_case:  Fpm_Ident_Case,
	int_value:   i64,
	float_value: f64,
	line:        int,
}

fpm_lex :: proc(source: string) -> []Fpm_Token {
	tokens := make([dynamic]Fpm_Token, 0, 16, context.temp_allocator)
	line := 1
	i := 0
	for i < len(source) {
		ch := source[i]
		switch {
		case ch == '\n':
			tokens = fpm_emit_newline(tokens, line)
			j := i
			for j < len(source) && fpm_is_layout(source[j]) {
				if source[j] == '\n' {
					line += 1
				}
				j += 1
			}
			i = j
		case ch == ' ' || ch == '\t' || ch == '\r':
			i += 1
		case ch == '/' && i+1 < len(source) && source[i+1] == '/':
			j := i + 2
			for j < len(source) && source[j] != '\n' {
				j += 1
			}
			i = j
		case ch == '"':
			tok, next := fpm_scan_string(source, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		case is_digit(ch):
			tok, next := fpm_scan_number(source, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		case is_ident_start(ch):
			tok, next := fpm_scan_ident(source, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		case:
			tok, next := fpm_scan_punct(source, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		}
	}
	return tokens[:]
}

fpm_emit_newline :: proc(tokens: [dynamic]Fpm_Token, line: int) -> [dynamic]Fpm_Token {
	out := tokens
	if len(out) > 0 && out[len(out) - 1].kind != .Newline {
		append(&out, Fpm_Token{kind = .Newline, text = "\n", line = line})
	}
	return out
}

fpm_is_layout :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
}

fpm_scan_string :: proc(source: string, start: int) -> (tok: Fpm_Token, next: int) {
	inner, terminated, next2 := scan_quoted_inner(source, start)
	return Fpm_Token{kind = .String_Lit if terminated else .Invalid, text = inner}, next2
}

fpm_scan_number :: proc(source: string, start: int) -> (tok: Fpm_Token, next: int) {
	i := start
	for i < len(source) && is_digit(source[i]) {
		i += 1
	}
	int_part := source[start:i]
	is_decimal := i+1 < len(source) && source[i] == '.' && source[i+1] != '.' && is_digit(source[i+1])
	if is_decimal {
		frac_start := i + 1
		j := frac_start
		for j < len(source) && is_digit(source[j]) {
			j += 1
		}
		end := j
		if end < len(source) && source[end] == 'f' {
			end += 1
		}
		value := fpm_parse_float(source[start:j])
		return Fpm_Token{kind = .Float_Lit, text = source[start:end], float_value = value}, end
	}
	value := parse_digits(int_part)
	return Fpm_Token{kind = .Int_Lit, text = int_part, int_value = value, float_value = f64(value)}, i
}

fpm_scan_ident :: proc(source: string, start: int) -> (tok: Fpm_Token, next: int) {
	i := start
	for i < len(source) && is_ident_char(source[i]) {
		i += 1
	}
	text := source[start:i]
	switch text {
	case "model":
		return Fpm_Token{kind = .Model, text = text}, i
	case "rig":
		return Fpm_Token{kind = .Rig, text = text}, i
	case "param":
		return Fpm_Token{kind = .Param, text = text}, i
	case "emit":
		return Fpm_Token{kind = .Emit, text = text}, i
	case "anchor":
		return Fpm_Token{kind = .Anchor, text = text}, i
	case "socket":
		return Fpm_Token{kind = .Socket, text = text}, i
	case "material":
		return Fpm_Token{kind = .Material, text = text}, i
	case "collide":
		return Fpm_Token{kind = .Collide, text = text}, i
	case "skeleton":
		return Fpm_Token{kind = .Skeleton, text = text}, i
	case "part":
		return Fpm_Token{kind = .Part, text = text}, i
	case "mirror":
		return Fpm_Token{kind = .Mirror, text = text}, i
	case "clearance":
		return Fpm_Token{kind = .Clearance, text = text}, i
	case "fn":
		return Fpm_Token{kind = .Fn, text = text}, i
	case "let":
		return Fpm_Token{kind = .Let, text = text}, i
	case "return":
		return Fpm_Token{kind = .Return, text = text}, i
	case "for":
		return Fpm_Token{kind = .For, text = text}, i
	case "in":
		return Fpm_Token{kind = .In, text = text}, i
	case "at":
		return Fpm_Token{kind = .At, text = text}, i
	}
	return Fpm_Token{kind = .Lower_Ident if fpm_initial_lower(text[0]) else .Upper_Ident, text = text, ident_case = fpm_classify_case(text[0])}, i
}

fpm_scan_punct :: proc(source: string, start: int) -> (tok: Fpm_Token, next: int) {
	two := source[start:min(start + 2, len(source))]
	switch two {
	case "..":
		return Fpm_Token{kind = .Dot_Dot, text = two}, start + 2
	case "->":
		return Fpm_Token{kind = .Arrow, text = two}, start + 2
	}
	one := source[start : start+1]
	kind: Fpm_Token_Kind
	switch source[start] {
	case '(':
		kind = .L_Paren
	case ')':
		kind = .R_Paren
	case '{':
		kind = .L_Brace
	case '}':
		kind = .R_Brace
	case '[':
		kind = .L_Bracket
	case ']':
		kind = .R_Bracket
	case '.':
		kind = .Dot
	case ':':
		kind = .Colon
	case ',':
		kind = .Comma
	case '=':
		kind = .Eq
	case '+':
		kind = .Plus
	case '-':
		kind = .Minus
	case '*':
		kind = .Star
	case '/':
		kind = .Slash
	case '%':
		kind = .Percent
	case:
		kind = .Invalid
	}
	return Fpm_Token{kind = kind, text = one}, start + 1
}

fpm_classify_case :: proc(first: u8) -> Fpm_Ident_Case {
	return .Lower if fpm_initial_lower(first) else .Upper
}

fpm_initial_lower :: proc(first: u8) -> bool {
	return first == '_' || (first >= 'a' && first <= 'z')
}

fpm_parse_float :: proc(text: string) -> f64 {
	whole: f64 = 0
	frac: f64 = 0
	scale: f64 = 1
	seen_dot := false
	for ch in text {
		if ch == '.' {
			seen_dot = true
			continue
		}
		digit := f64(ch - '0')
		if seen_dot {
			scale *= 10
			frac = frac*10 + digit
		} else {
			whole = whole*10 + digit
		}
	}
	return whole + frac/scale
}
