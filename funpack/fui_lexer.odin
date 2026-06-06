// Lexer for the §21 UI-template grammar (`.fui`), the FOURTH config-class
// grammar in the family (after `.fun`, the §14 `.fcfg` smaller-config grammar,
// the §17 `.flvl` level grammar, and the §16 `.fpm` model grammar). It gets its
// own lexer/parser pair like every sibling: the directive triad introduces three
// glyph forms (`@event`, `:attr`, `bind:value`) and one fused `bind:` head that
// no other grammar carries, and string literals here carry INTERPOLATION holes
// (`"Score: {score}"`) the parser reads as embedded paths — so reusing the `.fun`
// lexer would conflate `:` (a `.fui` bind-in directive head) with the `.fun`
// type-ascription colon and would not surface the `{path}` holes (fui.ebnf §0).
//
// The grammar is LL(1) (fui.ebnf §0): every node and attribute is selected by one
// token, so the lexer never needs to fuse multi-glyph operators beyond the one
// `bind:` head. Two `.fui`-local lexer facts the family lexers do not need land
// here (fui.ebnf §0): `bind:` is ONE token (the two-way directive head — a `bind`
// ident immediately followed by `:`), kept distinct from a bare `bind` ident and
// from a lone `:`; and the `@` event sigil is the `.fui` event token, NOT the
// `.fun` `@directive` token. A `//` line comment runs to end-of-line.
//
// The lexer is total: an unrecognized glyph becomes an Invalid token for the
// parser to reject, so a stray operator cannot slip through as layout.
package funpack

// Fui_Token_Kind is the closed token set the §21 UI grammar reads (fui.ebnf).
// Keyword tokens (Screen/If/For/In/Key) open the screen's productions; the
// fourteen Widget keywords open an element (layout/content/input, §21 §1); Ident
// carries names, paths, and Msg variants (upper/lower split by case_class);
// String/Int/Bool are the attribute-value and text-node literals; the bracket
// and operator glyphs drive blocks, attributes, paths, and the directive triad.
// At_Sign is the `@event` head, Bind_Colon the fused `bind:` two-way head, and a
// lone Colon is both the `:attr` bind-in head and the row-type/row-field
// separator — disambiguated by the parser's grammar position, never the lexer.
Fui_Token_Kind :: enum {
	Invalid, // end of input or an unrecognized glyph
	// production-opening keywords
	Screen,
	If,
	For,
	In,
	Key,
	// the fourteen closed widgets (§21 §1): layout, content, input
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
	// names, paths, Msg variants, and literals
	Ident,
	String_Lit, // a (possibly interpolated) text/attr-value string, contents only
	Int_Lit,    // a numeric attribute value (min=0, max=100)
	Bool_Lit,   // a true/false attribute value
	// brackets
	L_Brace,
	R_Brace,
	L_Paren,
	R_Paren,
	L_Bracket,
	R_Bracket,
	// operators, separators, and the directive triad
	Equals,    // attribute / directive value separator (class="…", @click=Coin)
	Dot,       // path segment separator (p.value, item.id)
	Comma,     // row-field separator inside an inline row type
	Colon,     // `:attr` bind-in head AND row-type/row-field separator
	At_Sign,   // `@event` head (@click=, the §21 event sigil)
	Bind_Colon, // the fused `bind:` two-way directive head (one token)
}

// Fui_Ident_Case is the upper/lower split the UI grammar reads (UPPER_IDENT for a
// screen name, Msg variant, or row-payload type; LOWER_IDENT for a widget, attr
// name, path segment, or loop var). The decision is by the first letter alone —
// the UI grammar does not carry the §02 UpperCamel-vs-UPPER_SNAKE band — so the
// parser only ever asks "upper or lower" of a name's grammar position.
Fui_Ident_Case :: enum {
	None,  // non-identifier tokens
	Upper, // a screen name, Msg variant, or row-payload type (UPPER_IDENT)
	Lower, // a widget, attribute, path segment, or loop var (LOWER_IDENT)
}

Fui_Token :: struct {
	kind:       Fui_Token_Kind,
	text:       string,           // Ident/String_Lit/Bool_Lit lexeme; for String_Lit, the contents between the quotes
	case_class: Fui_Ident_Case,   // Ident first-letter case
	int_value:  i64,              // Int_Lit value
	bool_value: bool,             // Bool_Lit value
	line:       int,              // 1-based source line of the token's first byte (§21 diagnostic provenance)
}

// lex_fui tokenizes the §21 UI surface. It tracks the 1-based source line of each
// token's first byte for diagnostic provenance, mirroring stage_lex. Whitespace
// (space/tab/CR/newline) is insignificant layout and dropped — the UI grammar is
// LL(1) and brace-delimited, so it needs no newline item separator. A `//` line
// comment is skipped to end-of-line.
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
			// A `//` line comment runs to end-of-line; the trailing newline is
			// scanned on the next iteration so the line counter advances.
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

// fui_scan_string returns the contents between the quotes — a text node or a
// string attribute value, possibly carrying `{path}` interpolation holes the
// parser reads (fui.ebnf Interpolation). The holes are NOT lexed here: the
// String_Lit text retains the raw `{…}` so the parser scans the paths out, which
// keeps the interpolation grammar in one place. An unterminated string (end of
// input or a newline before the closing quote) is Invalid, the parser's reject
// signal.
fui_scan_string :: proc(content: string, start: int) -> (tok: Fui_Token, next: int) {
	i := start + 1
	for i < len(content) && content[i] != '"' && content[i] != '\n' {
		i += 1
	}
	if i >= len(content) || content[i] != '"' {
		return Fui_Token{kind = .Invalid, text = content[start:i]}, i
	}
	return Fui_Token{kind = .String_Lit, text = content[start+1 : i]}, i + 1
}

// fui_scan_number scans a numeric attribute value (`min=0`, `max=100`). The UI
// expression sublanguage is paths and literals only (§21 §5) — no arithmetic — so
// a number is a bare digit run with no fractional or range forms to disambiguate.
fui_scan_number :: proc(content: string, start: int) -> (tok: Fui_Token, next: int) {
	i := start
	for i < len(content) && is_digit(content[i]) {
		i += 1
	}
	text := content[start:i]
	return Fui_Token{kind = .Int_Lit, text = text, int_value = parse_digits(text)}, i
}

// fui_scan_ident scans an identifier run and maps the UI keywords and the
// fourteen closed widgets. The fused `bind:` head is scanned here: a `bind` run
// immediately followed by `:` is the Bind_Colon two-way directive head (one
// token, fui.ebnf §0), consuming the `:`. The `true`/`false` words are Bool
// literal attribute values. A non-keyword run is an Ident carrying its
// first-letter case class — the UI grammar's upper/lower split.
fui_scan_ident :: proc(content: string, start: int) -> (tok: Fui_Token, next: int) {
	i := start
	for i < len(content) && is_ident_char(content[i]) {
		i += 1
	}
	text := content[start:i]
	// The fused two-way directive head `bind:` — a `bind` ident glued to `:`. The
	// `:` is consumed into this one token so a bind-in `:attr` head and the
	// two-way `bind:` head never share a lexeme.
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

// fui_classify_case decides a name's UI-grammar case from its first letter only
// (the upper/lower split of grammar/lexical-core.ebnf §2 the UI grammar reads).
// An underscore-led or digit-led leading char is Lower by default — the parser
// rejects a malformed name positionally, not the lexer.
fui_classify_case :: proc(text: string) -> Fui_Ident_Case {
	first := text[0]
	if first >= 'A' && first <= 'Z' {
		return .Upper
	}
	return .Lower
}

// fui_scan_punct maps the bracket, operator, and directive-sigil glyphs the UI
// grammar uses (fui.ebnf). Every glyph is a single token (the grammar is LL(1)
// and fuses no multi-glyph operators beyond the `bind:` head scanned in the ident
// path); an unrecognized glyph is Invalid, the parser's reject signal.
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
