package funpack

Token_Kind :: enum {
	Invalid,
	Malformed_Escape,
	Test,
	Assert,
	Import,
	Let,
	Return,
	Fn,
	Extern,
	Type,
	Match,
	Behavior,
	Signal,
	Pipeline,
	With,
	If,
	Else,
	Ident,
	Int_Lit,
	Fixed_Lit,
	String_Lit,
	L_Paren,
	R_Paren,
	L_Brace,
	R_Brace,
	L_Bracket,
	R_Bracket,
	At,
	Dot,
	Colon_Colon,
	Colon,
	Comma,
	Arrow,
	Eq_Arrow,
	Eq,
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

Ident_Class :: enum {
	None,
	Upper_Camel,
	Snake_Case,
	Upper_Snake,
	Mixed,
}

Token :: struct {
	kind:       Token_Kind,
	text:       string,
	class:      Ident_Class,
	int_value:  i64,
	fixed_bits: Fixed,
	line:       int,
	col:        int,
	offset:     int,
}

stage_lex :: proc(source: string) -> []Token {
	tokens := make([dynamic]Token, 0, 16, context.temp_allocator)
	nesting := Nesting {
		frames = make([dynamic]Bracket_Frame, 0, 8, context.temp_allocator),
	}
	prev_kind := Token_Kind.Invalid
	line := 1
	scanned := 0
	line_start := 0
	i := 0
	for i < len(source) {
		for scanned < i {
			if source[scanned] == '\n' {
				line += 1
				line_start = scanned + 1
			}
			scanned += 1
		}
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
		tok.line = line
		tok.col = i - line_start + 1
		tok.offset = i
		if tok.kind == .Newline && newline_suppressed(&nesting, source, next) {
			i = next
			continue
		}
		at_stmt_start := prev_kind == .Newline || prev_kind == .Invalid
		update_nesting(&nesting, tok, prev_kind, at_stmt_start)
		append(&tokens, tok)
		prev_kind = tok.kind
		i = next
	}
	return tokens[:]
}

Nesting :: struct {
	frames:        [dynamic]Bracket_Frame,
	block_pending: bool,
}

Bracket_Frame :: struct {
	suppress: bool,
}

newline_suppressed :: proc(n: ^Nesting, source: string, after: int) -> bool {
	if len(n.frames) > 0 && n.frames[len(n.frames) - 1].suppress {
		return true
	}
	j := after
	for j < len(source) && (source[j] == ' ' || source[j] == '\t' || source[j] == '\r') {
		j += 1
	}
	return j < len(source) && source[j] == '.'
}

update_nesting :: proc(n: ^Nesting, tok: Token, prev: Token_Kind, at_stmt_start: bool) {
	if tok.kind == .Ident && len(n.frames) == 0 && at_stmt_start && is_decl_opener_keyword(tok.text) {
		n.block_pending = true
		return
	}
	#partial switch tok.kind {
	case .Match, .If, .Else, .Behavior, .Signal, .Pipeline, .Arrow:
		n.block_pending = true
	case .L_Paren:
		append(&n.frames, Bracket_Frame{suppress = true})
	case .R_Paren:
		pop_frame(n)
	case .L_Bracket:
		append(&n.frames, Bracket_Frame{suppress = false})
	case .R_Bracket:
		pop_frame(n)
	case .L_Brace:
		is_record := (prev == .Ident || prev == .With) && !n.block_pending
		n.block_pending = false
		append(&n.frames, Bracket_Frame{suppress = is_record})
	case .R_Brace:
		pop_frame(n)
	}
}

pop_frame :: proc(n: ^Nesting) {
	if len(n.frames) > 0 {
		pop(&n.frames)
	}
}

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
	case "=>":
		return Token{kind = .Eq_Arrow, text = two}, start + 2
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

scan_string :: proc(source: string, start: int) -> (tok: Token, next: int) {
	i := start + 1
	for i < len(source) && source[i] != '"' && source[i] != '\n' {
		if source[i] == '\\' {
			if i+1 >= len(source) || !is_string_escape(source[i+1]) {
				return malformed_escape_token(source, start, i)
			}
			i += 2
			continue
		}
		i += 1
	}
	if i >= len(source) || source[i] != '"' {
		return Token{kind = .Invalid, text = source[start:i]}, i
	}
	return Token{kind = .String_Lit, text = source[start+1 : i]}, i + 1
}

is_string_escape :: proc(ch: u8) -> bool {
	return ch == '"' || ch == '{' || ch == '}'
}

malformed_escape_token :: proc(source: string, start: int, bad: int) -> (tok: Token, next: int) {
	i := bad
	for i < len(source) && source[i] != '\n' {
		if source[i] == '"' {
			return Token{kind = .Malformed_Escape, text = source[start : i+1]}, i + 1
		}
		i += 1
	}
	return Token{kind = .Malformed_Escape, text = source[start:i]}, i
}

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
	case "extern":
		return Token{kind = .Extern, text = text}, i
	case "type":
		return Token{kind = .Type, text = text}, i
	case "match":
		return Token{kind = .Match, text = text}, i
	case "behavior":
		return Token{kind = .Behavior, text = text}, i
	case "signal":
		return Token{kind = .Signal, text = text}, i
	case "pipeline":
		return Token{kind = .Pipeline, text = text}, i
	case "with":
		return Token{kind = .With, text = text}, i
	case "if":
		return Token{kind = .If, text = text}, i
	case "else":
		return Token{kind = .Else, text = text}, i
	}
	return Token{kind = .Ident, text = text, class = classify_ident(text)}, i
}

is_decl_opener_keyword :: proc(text: string) -> bool {
	switch text {
	case "data", "enum", "thing", "singleton", "query":
		return true
	}
	return false
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

is_upper_ident :: proc(class: Ident_Class) -> bool {
	return class == .Upper_Camel || class == .Upper_Snake
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

is_lower_ident :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	if !(s[0] == '_' || (s[0] >= 'a' && s[0] <= 'z')) {
		return false
	}
	for i in 1 ..< len(s) {
		if !is_ident_char(s[i]) {
			return false
		}
	}
	return true
}

scan_quoted_inner :: proc(content: string, start: int) -> (inner: string, terminated: bool, next: int) {
	i := start + 1
	for i < len(content) && content[i] != '"' && content[i] != '\n' {
		i += 1
	}
	if i >= len(content) || content[i] != '"' {
		return content[start:i], false, i
	}
	return content[start+1 : i], true, i + 1
}
