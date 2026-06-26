// Lexer for the modeling DSL (.fpm) — the SECOND funpack language (spec §16,
// grammar/fpm.ebnf). It is wholly separate from the `.fun` lexer (lexer.odin):
// the file-type token `.fpm` IS the regime disambiguator (§16 §1, R1), so this
// lexer admits the bake-time-only spellings the `.fun` lexer forbids — `//`
// line comments (§16 §1, the LineComment_Slash production), a FLOAT literal
// (`1.5f`, render/visual-only, lexical-core.ebnf §3), and the `..` range
// operator of an accumulating `for x in a..b` loop (§16 §1). It reuses the core
// lexer's character-class predicates (digit/ident) and single-line quoted-string
// scanner directly, and carries only its own UPPER/lower identifier split
// (lexical-core.ebnf §2); it does NOT carry the `.fun`
// casing lint bands, the Fixed-point literal interpretation, or the
// bracket-aware newline suppression — `.fpm` numbers live in the float domain
// and the parser reads explicit Sep runs, not layout-suppressed newlines.
//
// The lexer is total: an unrecognized character becomes an Invalid token for the
// parser to reject, so a stray glyph never silently vanishes. A `//` comment
// runs to end of line and is dropped (it is whitespace to the parser, never a
// token). Whitespace and newlines are emitted as a single Newline token per run
// so the grammar's Sep (`(NEWLINE | ',')+`) is a flat token check.
package funpack

// Fpm_Token_Kind is the closed lexis of the .fpm grammar (fpm.ebnf). It is a
// distinct enum from the `.fun` Token_Kind: the two languages share no token
// stream, and folding them would force `.fpm`-only spellings (`..`, the FLOAT
// `f` suffix) into the core lexer that must reject them. Keywords are the
// model/rig vocabulary (§16 §2) plus the imperative-body openers (`for`/`in`,
// §16 §1); every declaration member opens with a unique leading keyword.
Fpm_Token_Kind :: enum {
	Invalid,
	// block + member keywords (§16 §2)
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
	// fn + imperative-body keywords (§16 §1)
	Fn,
	Let,
	Return,
	For,
	In,
	At, // the `at` of `part <name> at BONE` — a keyword, not the `.fun` `@` directive prefix
	// identifiers, split only on initial-case (lexical-core.ebnf §2)
	Lower_Ident, // values, fns, fields, params, modules, skeleton topologies
	Upper_Ident, // types, bone names, mirror sides
	// literals — all numbers live in the float domain (§16 §1)
	Int_Lit,
	Float_Lit,
	String_Lit,
	// brackets
	L_Paren,
	R_Paren,
	L_Brace,
	R_Brace,
	L_Bracket,
	R_Bracket,
	// operators & separators
	Dot,        // member access / l-value path segment
	Dot_Dot,    // the `..` range of `for x in a..b`
	Colon,      // type ascription / named-arg label / record-field separator
	Comma,      // element separator (collapses into Sep with Newline)
	Arrow,      // `->` fn return type / `mirror L -> R`
	Eq,         // binding / assignment / named-arg `=`-vs-`:`… (`=` is assign here)
	Plus,
	Minus,
	Star,
	Slash,
	Percent,
	Newline, // statement / element separator (one token per whitespace-newline run)
}

// Fpm_Ident_Case is the two-class split lexical-core.ebnf §2 fixes for every
// funpack file: a name's grammar role (a LOWER_IDENT value vs an UPPER_IDENT
// type/bone) is decided by its initial character alone. The `.fpm` grammar does
// NOT impose the `.fun` three-band casing lint (UpperCamel / UPPER_SNAKE /
// snake_case), so the lexer carries only this binary class, not Ident_Class.
Fpm_Ident_Case :: enum {
	None,  // non-identifier tokens
	Lower, // lower_start ident_char* — values, fns, fields, modules, topologies
	Upper, // upper ident_char* — types, bone names, mirror sides
}

Fpm_Token :: struct {
	kind:        Fpm_Token_Kind,
	text:        string,
	ident_case:  Fpm_Ident_Case, // initial-case class of an identifier token
	int_value:   i64,            // Int_Lit value
	float_value: f64,            // Float_Lit / Int_Lit-promoted value (float domain, §16 §1)
	line:        int,            // 1-based source line of the token's first byte (§15 diagnostic provenance)
}

// fpm_lex tokenizes a .fpm source. It is total — an unrecognized character is an
// Invalid token, never a silent skip. A `//` comment is dropped to end of line
// (it never reaches the parser, §16 §1). A run of spaces, tabs, carriage
// returns, and newlines that contains at least one '\n' collapses to a single
// Newline token, so the grammar's Sep run is a flat token check; pure-space gaps
// between tokens on one line emit nothing.
fpm_lex :: proc(source: string) -> []Fpm_Token {
	tokens := make([dynamic]Fpm_Token, 0, 16, context.temp_allocator)
	line := 1
	i := 0
	for i < len(source) {
		ch := source[i]
		switch {
		case ch == '\n':
			// Coalesce a whitespace-plus-newline run into ONE Newline token at
			// the line of the first '\n', advancing the line counter across every
			// '\n' the run spans.
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
			// A `//` line comment runs to end of line and is whitespace to the
			// parser — never a token (§16 §1, LineComment_Slash).
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

// fpm_emit_newline appends a single Newline token unless the previous token is
// already a Newline, so a multi-line gap is one Sep token, never a run the
// parser must skip element-by-element. A leading run (no prior token) emits
// nothing — a file cannot open with a separator.
fpm_emit_newline :: proc(tokens: [dynamic]Fpm_Token, line: int) -> [dynamic]Fpm_Token {
	out := tokens
	if len(out) > 0 && out[len(out) - 1].kind != .Newline {
		append(&out, Fpm_Token{kind = .Newline, text = "\n", line = line})
	}
	return out
}

// fpm_is_layout reports whether a byte is whitespace the Newline-coalescing run
// absorbs: a space, tab, carriage return, or the line break itself.
fpm_is_layout :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
}

// fpm_scan_string returns the contents between the quotes. An unterminated
// string (end of input or a newline before the closing quote) is Invalid — a
// `.fpm` string is single-line, matching the core lexer's discipline, which is
// why the scan defers to the shared scan_quoted_inner and only stamps the kind.
fpm_scan_string :: proc(source: string, start: int) -> (tok: Fpm_Token, next: int) {
	inner, terminated, next2 := scan_quoted_inner(source, start)
	return Fpm_Token{kind = .String_Lit if terminated else .Invalid, text = inner}, next2
}

// fpm_scan_number scans a numeric literal in the float domain (§16 §1,
// lexical-core.ebnf §3). A bare digit run is an Int_Lit (whose float_value is the
// promoted value, since `.fpm` arithmetic is float); a digit run with a `.` and a
// fractional digit run is a Float_Lit; a trailing `f` (`1.5f`) is the
// render/visual FLOAT spelling and is also a Float_Lit. A `..` after the integer
// part is the range operator, NOT a decimal point — `0..3` scans the Int_Lit `0`,
// leaving `..3` to the punct scanner — so an accumulating-loop bound is never
// mis-lexed as a float.
fpm_scan_number :: proc(source: string, start: int) -> (tok: Fpm_Token, next: int) {
	i := start
	for i < len(source) && is_digit(source[i]) {
		i += 1
	}
	int_part := source[start:i]
	// A single `.` followed by a digit opens a fractional part. A `..` (range)
	// or a `.` followed by a non-digit is NOT a decimal point — leave it for the
	// punct/postfix scanner so `0..3` and `5.up(0)` lex correctly.
	is_decimal := i+1 < len(source) && source[i] == '.' && source[i+1] != '.' && is_digit(source[i+1])
	if is_decimal {
		frac_start := i + 1
		j := frac_start
		for j < len(source) && is_digit(source[j]) {
			j += 1
		}
		end := j
		// An optional trailing `f` is the FLOAT (render/visual) spelling; it is a
		// Float_Lit just like a suffix-less decimal.
		if end < len(source) && source[end] == 'f' {
			end += 1
		}
		value := fpm_parse_float(source[start:j])
		return Fpm_Token{kind = .Float_Lit, text = source[start:end], float_value = value}, end
	}
	value := parse_digits(int_part)
	return Fpm_Token{kind = .Int_Lit, text = int_part, int_value = value, float_value = f64(value)}, i
}

// fpm_scan_ident scans an identifier or keyword. Every block/member keyword of
// §16 §2 and every imperative-body opener of §16 §1 maps to its dedicated kind;
// any other identifier is split LOWER vs UPPER on its initial character alone
// (lexical-core.ebnf §2), the only casing signal the .fpm grammar reads.
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

// fpm_scan_punct applies maximal munch: the two-glyph operators (`..`, `->`)
// match before their one-glyph prefixes (`.`, `-`). Every other single
// character is Invalid — the parser's reject signal.
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

// fpm_classify_case returns the two-class split lexical-core.ebnf §2 fixes for
// an identifier, decided by its initial character alone.
fpm_classify_case :: proc(first: u8) -> Fpm_Ident_Case {
	return .Lower if fpm_initial_lower(first) else .Upper
}

// fpm_initial_lower reports whether an identifier's first character opens a
// LOWER_IDENT (a lowercase letter or `_`); an uppercase letter opens an
// UPPER_IDENT (lexical-core.ebnf §2 lower_start).
fpm_initial_lower :: proc(first: u8) -> bool {
	return first == '_' || (first >= 'a' && first <= 'z')
}

// fpm_parse_float parses a `digits '.' digits` decimal into an f64 by hand —
// the float domain is bake-time only (§16 §1), so a small accumulate-then-divide
// is exact enough for the geometry digest and avoids a strconv dependency for a
// closed numeric form. The text never carries the `f` suffix (the scanner slices
// it off before calling).
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
