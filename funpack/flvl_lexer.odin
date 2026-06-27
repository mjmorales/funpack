package funpack

Flvl_Token_Kind :: enum {
	Invalid,
	Level,
	Bounds,
	Things,
	Place,
	At,
	Facing,
	Prefab,
	For,
	In,
	Tilemap,
	Legend,
	Grid,
	Spawn,
	Empty,
	Ident,
	Dim,
	Int_Lit,
	Fixed_Lit,
	String_Lit,
	Char_Lit,
	Triple_String,
	L_Paren,
	R_Paren,
	L_Brace,
	R_Brace,
	Dot,
	Dot_Dot,
	Colon,
	Comma,
	Plus,
	Minus,
	Star,
	Slash,
	Newline,
}

Flvl_Ident_Case :: enum {
	None,
	Upper,
	Lower,
}

Flvl_Token :: struct {
	kind:       Flvl_Token_Kind,
	text:       string,
	case_class: Flvl_Ident_Case,
	int_value:  i64,
	fixed_bits: Fixed,
	char_value: u8,
	line:       int,
}

lex_flvl :: proc(content: string) -> []Flvl_Token {
	tokens := make([dynamic]Flvl_Token, 0, 32, context.temp_allocator)
	line := 1
	i := 0
	for i < len(content) {
		ch := content[i]
		switch {
		case ch == '\n':
			append(&tokens, Flvl_Token{kind = .Newline, text = "\n", line = line})
			line += 1
			i += 1
		case ch == ' ' || ch == '\t' || ch == '\r':
			i += 1
		case ch == '/' && i+1 < len(content) && content[i+1] == '/':
			for i < len(content) && content[i] != '\n' {
				i += 1
			}
		case ch == '"':
			if i+2 < len(content) && content[i+1] == '"' && content[i+2] == '"' {
				tok, next := flvl_scan_triple_string(content, i)
				tok.line = line
				for j := i; j < next; j += 1 {
					if content[j] == '\n' {
						line += 1
					}
				}
				append(&tokens, tok)
				i = next
				continue
			}
			tok, next := flvl_scan_string(content, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		case ch == '\'':
			tok, next := flvl_scan_char(content, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		case is_digit(ch):
			tok, next := flvl_scan_number(content, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		case is_ident_start(ch):
			tok, next := flvl_scan_ident(content, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		case:
			tok, next := flvl_scan_punct(content, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		}
	}
	return tokens[:]
}

flvl_scan_string :: proc(content: string, start: int) -> (tok: Flvl_Token, next: int) {
	inner, terminated, next2 := scan_quoted_inner(content, start)
	return Flvl_Token{kind = .String_Lit if terminated else .Invalid, text = inner}, next2
}

flvl_scan_triple_string :: proc(content: string, start: int) -> (tok: Flvl_Token, next: int) {
	i := start + 3
	for i+2 < len(content) {
		if content[i] == '"' && content[i+1] == '"' && content[i+2] == '"' {
			return Flvl_Token{kind = .Triple_String, text = content[start+3 : i]}, i + 3
		}
		i += 1
	}
	return Flvl_Token{kind = .Invalid, text = content[start:]}, len(content)
}

flvl_scan_char :: proc(content: string, start: int) -> (tok: Flvl_Token, next: int) {
	if start+2 < len(content) && content[start+1] != '\n' && content[start+2] == '\'' {
		body := content[start+1]
		return Flvl_Token{kind = .Char_Lit, text = content[start+1 : start+2], char_value = body}, start + 3
	}
	end := start + 1
	for end < len(content) && content[end] != '\n' && end < start+3 {
		end += 1
	}
	return Flvl_Token{kind = .Invalid, text = content[start:end]}, end
}

flvl_scan_number :: proc(content: string, start: int) -> (tok: Flvl_Token, next: int) {
	i := start
	for i < len(content) && is_digit(content[i]) {
		i += 1
	}
	if i < len(content) && content[i] == 'd' && (i+1 >= len(content) || !is_ident_char(content[i+1])) {
		end := i + 1
		return Flvl_Token{kind = .Dim, text = content[start:end]}, end
	}
	if i+1 < len(content) && content[i] == '.' && is_digit(content[i+1]) {
		frac_start := i + 1
		j := frac_start
		for j < len(content) && is_digit(content[j]) {
			j += 1
		}
		bits := fixed_from_decimal(parse_digits(content[start:i]), content[frac_start:j])
		return Flvl_Token{kind = .Fixed_Lit, text = content[start:j], fixed_bits = bits}, j
	}
	text := content[start:i]
	return Flvl_Token{kind = .Int_Lit, text = text, int_value = parse_digits(text)}, i
}

flvl_scan_ident :: proc(content: string, start: int) -> (tok: Flvl_Token, next: int) {
	i := start
	for i < len(content) && is_ident_char(content[i]) {
		i += 1
	}
	text := content[start:i]
	switch text {
	case "level":
		return Flvl_Token{kind = .Level, text = text}, i
	case "bounds":
		return Flvl_Token{kind = .Bounds, text = text}, i
	case "things":
		return Flvl_Token{kind = .Things, text = text}, i
	case "place":
		return Flvl_Token{kind = .Place, text = text}, i
	case "at":
		return Flvl_Token{kind = .At, text = text}, i
	case "facing":
		return Flvl_Token{kind = .Facing, text = text}, i
	case "prefab":
		return Flvl_Token{kind = .Prefab, text = text}, i
	case "for":
		return Flvl_Token{kind = .For, text = text}, i
	case "in":
		return Flvl_Token{kind = .In, text = text}, i
	case "tilemap":
		return Flvl_Token{kind = .Tilemap, text = text}, i
	case "legend":
		return Flvl_Token{kind = .Legend, text = text}, i
	case "grid":
		return Flvl_Token{kind = .Grid, text = text}, i
	case "spawn":
		return Flvl_Token{kind = .Spawn, text = text}, i
	case "empty":
		return Flvl_Token{kind = .Empty, text = text}, i
	}
	return Flvl_Token{kind = .Ident, text = text, case_class = flvl_classify_case(text)}, i
}

flvl_classify_case :: proc(text: string) -> Flvl_Ident_Case {
	first := text[0]
	if first >= 'A' && first <= 'Z' {
		return .Upper
	}
	return .Lower
}

flvl_scan_punct :: proc(content: string, start: int) -> (tok: Flvl_Token, next: int) {
	if start+1 < len(content) && content[start] == '.' && content[start+1] == '.' {
		return Flvl_Token{kind = .Dot_Dot, text = ".."}, start + 2
	}
	one := content[start : start+1]
	kind: Flvl_Token_Kind
	switch content[start] {
	case '(':
		kind = .L_Paren
	case ')':
		kind = .R_Paren
	case '{':
		kind = .L_Brace
	case '}':
		kind = .R_Brace
	case '.':
		kind = .Dot
	case ':':
		kind = .Colon
	case ',':
		kind = .Comma
	case '+':
		kind = .Plus
	case '-':
		kind = .Minus
	case '*':
		kind = .Star
	case '/':
		kind = .Slash
	case:
		kind = .Invalid
	}
	return Flvl_Token{kind = kind, text = one}, start + 1
}
