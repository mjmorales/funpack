package funpack

Fui_Token_Kind :: enum {
	Invalid,
	Screen,
	If,
	For,
	In,
	Key,
	Panel,
	Row,
	Col,
	Grid,
	Stack,
	Scroll,
	Spacer,
	Text,
	Image,
	Icon,
	Button,
	Field,
	Slider,
	Toggle,
	Select,
	Ident,
	String_Lit,
	Int_Lit,
	Bool_Lit,
	L_Brace,
	R_Brace,
	L_Paren,
	R_Paren,
	L_Bracket,
	R_Bracket,
	Equals,
	Dot,
	Comma,
	Colon,
	At_Sign,
	Bind_Colon,
}

Fui_Ident_Case :: enum {
	None,
	Upper,
	Lower,
}

Fui_Token :: struct {
	kind:       Fui_Token_Kind,
	text:       string,
	case_class: Fui_Ident_Case,
	int_value:  i64,
	bool_value: bool,
	line:       int,
}

lex_fui :: proc(content: string) -> []Fui_Token {
	tokens := make([dynamic]Fui_Token, 0, 64, context.temp_allocator)
	line := 1
	i := 0
	for i < len(content) {
		ch := content[i]
		switch {
		case ch == '\n':
			line += 1
			i += 1
		case ch == ' ' || ch == '\t' || ch == '\r':
			i += 1
		case ch == '/' && i+1 < len(content) && content[i+1] == '/':
			for i < len(content) && content[i] != '\n' {
				i += 1
			}
		case ch == '"':
			tok, next := fui_scan_string(content, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		case is_digit(ch):
			tok, next := fui_scan_number(content, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		case is_ident_start(ch):
			tok, next := fui_scan_ident(content, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		case:
			tok, next := fui_scan_punct(content, i)
			tok.line = line
			append(&tokens, tok)
			i = next
		}
	}
	return tokens[:]
}

fui_scan_string :: proc(content: string, start: int) -> (tok: Fui_Token, next: int) {
	inner, terminated, next2 := scan_quoted_inner(content, start)
	return Fui_Token{kind = .String_Lit if terminated else .Invalid, text = inner}, next2
}

fui_scan_number :: proc(content: string, start: int) -> (tok: Fui_Token, next: int) {
	i := start
	for i < len(content) && is_digit(content[i]) {
		i += 1
	}
	text := content[start:i]
	return Fui_Token{kind = .Int_Lit, text = text, int_value = parse_digits(text)}, i
}

fui_scan_ident :: proc(content: string, start: int) -> (tok: Fui_Token, next: int) {
	i := start
	for i < len(content) && is_ident_char(content[i]) {
		i += 1
	}
	text := content[start:i]
	if text == "bind" && i < len(content) && content[i] == ':' {
		return Fui_Token{kind = .Bind_Colon, text = "bind:"}, i + 1
	}
	switch text {
	case "screen":
		return Fui_Token{kind = .Screen, text = text}, i
	case "if":
		return Fui_Token{kind = .If, text = text}, i
	case "for":
		return Fui_Token{kind = .For, text = text}, i
	case "in":
		return Fui_Token{kind = .In, text = text}, i
	case "key":
		return Fui_Token{kind = .Key, text = text}, i
	case "panel":
		return Fui_Token{kind = .Panel, text = text}, i
	case "row":
		return Fui_Token{kind = .Row, text = text}, i
	case "col":
		return Fui_Token{kind = .Col, text = text}, i
	case "grid":
		return Fui_Token{kind = .Grid, text = text}, i
	case "stack":
		return Fui_Token{kind = .Stack, text = text}, i
	case "scroll":
		return Fui_Token{kind = .Scroll, text = text}, i
	case "spacer":
		return Fui_Token{kind = .Spacer, text = text}, i
	case "text":
		return Fui_Token{kind = .Text, text = text}, i
	case "image":
		return Fui_Token{kind = .Image, text = text}, i
	case "icon":
		return Fui_Token{kind = .Icon, text = text}, i
	case "button":
		return Fui_Token{kind = .Button, text = text}, i
	case "field":
		return Fui_Token{kind = .Field, text = text}, i
	case "slider":
		return Fui_Token{kind = .Slider, text = text}, i
	case "toggle":
		return Fui_Token{kind = .Toggle, text = text}, i
	case "select":
		return Fui_Token{kind = .Select, text = text}, i
	case "true":
		return Fui_Token{kind = .Bool_Lit, text = text, bool_value = true}, i
	case "false":
		return Fui_Token{kind = .Bool_Lit, text = text, bool_value = false}, i
	}
	return Fui_Token{kind = .Ident, text = text, case_class = fui_classify_case(text)}, i
}

fui_classify_case :: proc(text: string) -> Fui_Ident_Case {
	first := text[0]
	if first >= 'A' && first <= 'Z' {
		return .Upper
	}
	return .Lower
}

fui_scan_punct :: proc(content: string, start: int) -> (tok: Fui_Token, next: int) {
	one := content[start : start+1]
	kind: Fui_Token_Kind
	switch content[start] {
	case '{':
		kind = .L_Brace
	case '}':
		kind = .R_Brace
	case '(':
		kind = .L_Paren
	case ')':
		kind = .R_Paren
	case '[':
		kind = .L_Bracket
	case ']':
		kind = .R_Bracket
	case '=':
		kind = .Equals
	case '.':
		kind = .Dot
	case ',':
		kind = .Comma
	case ':':
		kind = .Colon
	case '@':
		kind = .At_Sign
	case:
		kind = .Invalid
	}
	return Fui_Token{kind = kind, text = one}, start + 1
}
