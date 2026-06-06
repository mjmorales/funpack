// Lexer for the §17 flat-text level grammar (`.flvl`). This is the THIRD
// config-class grammar in the family, distinct from `.fun` and from the §14
// smaller-config grammar (lex_fcfg): unlike `.fcfg` it carries EXPRESSIONS —
// offset arithmetic (`-48 + i * 24`) and for-range bounds (`0..5`) — so it
// gets its own lexer/parser pair rather than reusing either, mirroring why
// `.fcfg` did not reuse the `.fun` lexer (grammar/flvl.ebnf §0).
//
// The lexer is total: an unrecognized glyph becomes an Invalid token for the
// parser to reject, so an expression operator or control-flow punctuation
// cannot slip through as layout. Two scans the family lexers do not need land
// here: the `..` range glyph (the only place in the family ranges appear,
// grammar/flvl.ebnf §0) is matched before the member-access `.`, and the
// dimension words `2d`/`3d` are digit-led keywords scanned by the number
// scanner (a digit run followed by a `d` suffix), kept distinct from a bare
// numeric literal. Whitespace and newlines are insignificant layout: the level
// grammar separates items by newline OR comma but, like the smaller-config
// grammar, the parser tolerates either, so the lexer drops both classes of
// separator down to a single Comma/Newline-agnostic stream by emitting only
// the glyphs the grammar reads. A `//` line comment (the level surface admits
// comments, grammar/flvl.ebnf §0) is skipped to end-of-line.
package funpack

// Flvl_Token_Kind is the closed token set the §17 level grammar reads. Keyword
// tokens (Level/Bounds/Things/Place/At/Facing/Prefab/For/In) open the level's
// productions; Dim carries a `2d`/`3d` header word; Int/Fixed/String are the
// anchor-expression atoms; the operator/bracket glyphs drive the offset
// arithmetic, range, dotted-path, and block structure. Dot_Dot is the range
// operator `..`, scanned ahead of the member-access Dot so `0..5` never lexes
// as two member accesses.
Flvl_Token_Kind :: enum {
	Invalid, // end of input or an unrecognized glyph
	// production-opening keywords
	Level,
	Bounds,
	Things,
	Place,
	At,
	Facing,
	Prefab,
	For,
	In,
	// names, the dimension header word, and literals
	Ident,
	Dim,        // the `2d` / `3d` header word
	Int_Lit,
	Fixed_Lit,
	String_Lit,
	// brackets
	L_Paren,
	R_Paren,
	L_Brace,
	R_Brace,
	// operators and separators — one concept per glyph
	Dot,     // member access / dotted name-path segment
	Dot_Dot, // the `..` for-range operator (`0..5`)
	Colon,   // param-entry / named-arg key separator
	Comma,   // coordinate / argument separator
	Plus,
	Minus,
	Star,
	Slash,
	Newline, // item separator (the grammar also accepts `,`; the parser tolerates either)
}

// Flvl_Ident_Case is the upper/lower split the level grammar reads (UPPER_IDENT
// for a placed type or prefab name, LOWER_IDENT for an instance name, field,
// schema module, or loop var). The decision is by the first letter alone — the
// level grammar does not carry the §02 UpperCamel-vs-UPPER_SNAKE band — so the
// parser only ever asks "upper or lower" of a name's grammar position.
Flvl_Ident_Case :: enum {
	None,  // non-identifier tokens
	Upper, // a type or prefab name (UPPER_IDENT)
	Lower, // an instance name, field, module, or loop var (LOWER_IDENT)
}

Flvl_Token :: struct {
	kind:       Flvl_Token_Kind,
	text:       string,
	case_class: Flvl_Ident_Case, // Ident first-letter case
	int_value:  i64,             // Int_Lit value
	fixed_bits: Fixed,           // Fixed_Lit value
	line:       int,             // 1-based source line of the token's first byte (§17 diagnostic provenance)
}

// lex_flvl tokenizes the §17 level surface. It tracks the 1-based source line
// of each token's first byte for diagnostic provenance, mirroring stage_lex.
// Whitespace (space/tab/CR) is dropped; a newline emits a Newline token (the
// item separator); a `//` line comment is skipped to the line's end.
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
			// A `//` line comment runs to end-of-line; the trailing newline is
			// scanned on the next iteration so it still terminates the item.
			for i < len(content) && content[i] != '\n' {
				i += 1
			}
		case ch == '"':
			tok, next := flvl_scan_string(content, i)
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

// flvl_scan_string returns the contents between the quotes (the socket-name
// argument of `table.socket("cup")`, grammar/flvl.ebnf §AnchorAtom). An
// unterminated string (end of input or a newline before the closing quote) is
// Invalid, the parser's reject signal.
flvl_scan_string :: proc(content: string, start: int) -> (tok: Flvl_Token, next: int) {
	i := start + 1
	for i < len(content) && content[i] != '"' && content[i] != '\n' {
		i += 1
	}
	if i >= len(content) || content[i] != '"' {
		return Flvl_Token{kind = .Invalid, text = content[start:i]}, i
	}
	return Flvl_Token{kind = .String_Lit, text = content[start+1 : i]}, i + 1
}

// flvl_scan_number scans a number atom, the dimension header word, or stops
// short of a range operator. A digit run followed by a lone `d` (and no further
// ident char) is the dimension word `2d`/`3d` (Dim). A digit run with a
// fractional part (`.` then a digit) is a Fixed, matching §10's type-directed
// rule. A bare digit run is an Int. The range operator `..` must NOT be eaten as
// a fractional point: a `.` is only consumed into a Fixed when a digit follows
// it, so `0..5` scans the `0` as an Int and leaves `..5` for the punct scanner.
flvl_scan_number :: proc(content: string, start: int) -> (tok: Flvl_Token, next: int) {
	i := start
	for i < len(content) && is_digit(content[i]) {
		i += 1
	}
	// Dimension header word: a digit run followed by exactly `d` (`2d`, `3d`).
	if i < len(content) && content[i] == 'd' && (i+1 >= len(content) || !is_ident_char(content[i+1])) {
		end := i + 1
		return Flvl_Token{kind = .Dim, text = content[start:end]}, end
	}
	// Fixed literal: a `.` followed by a fractional digit run. A `.` with no
	// trailing digit (the `..` range, or a member access) is left for the punct
	// scanner.
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

// flvl_scan_ident scans an identifier run and maps the level keywords. A
// non-keyword run is an Ident carrying its first-letter case class — the level
// grammar's upper/lower split for type-vs-name positions.
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
	}
	return Flvl_Token{kind = .Ident, text = text, case_class = flvl_classify_case(text)}, i
}

// flvl_classify_case decides a name's level-grammar case from its first letter
// only (the upper/lower split of grammar/lexical-core.ebnf §2 the level grammar
// reads). An underscore-led or digit-led leading char is Lower by default — the
// parser rejects a malformed name positionally, not the lexer.
flvl_classify_case :: proc(text: string) -> Flvl_Ident_Case {
	first := text[0]
	if first >= 'A' && first <= 'Z' {
		return .Upper
	}
	return .Lower
}

// flvl_scan_punct maps the operator/bracket glyphs the level grammar uses. The
// two-glyph `..` range operator is matched before the one-glyph member-access
// `.` (maximal munch), so a for-range bound never lexes as two member accesses.
// Every other single character is Invalid, the parser's reject signal.
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
