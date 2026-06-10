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
	// `extern` is the §02/§26 native-boundary opener: `extern fn name(…) -> R`
	// declares a body-less function whose definition lives outside funpack — the
	// generated §17 seam's symbol-table/spawn-list accessors (`extern fn arena()
	// -> Arena`). It is a reserved keyword (grammar/fun.ll1.md §2) and a distinct
	// FIRST(Declaration) opener, so it tokenizes here like every other unique
	// declaration keyword rather than riding as a contextual Ident.
	Extern,
	Match,
	// §06/§07 declaration and expression keywords. `behavior`/`signal` are
	// reserved declaration openers (they never name a value on the golden
	// surface). `with` is the record-update operator, `if` the conditional
	// opener (both the early-return statement and the value expression, spec §02
	// §5), `else` the required value-expression alternate arm (`if cond { … }
	// else { … }`); `else` is a reserved keyword, preserving §02
	// one-name-one-meaning.
	//
	// `thing`/`singleton`/`data`/`enum`/`query` (and `on`) are CONTEXTUAL keywords
	// (fun.ll1.md §2): a keyword only where it opens a module-level declaration,
	// an ordinary value name everywhere else (`let thing = …`, a field `data:`,
	// a member `s.enum`). They are NOT token kinds — they lex as Ident, and
	// parse_declaration dispatches on the leading Ident's TEXT at the
	// declaration-opening position (the start of a module-level statement), the
	// one position where one token of lookahead still selects the production.
	Behavior,
	Signal,
	Pipeline,
	With,
	If,
	Else,
	// `on`, `thing`, `singleton`, `data`, and `enum` are contextual keywords
	// (see above): they lex as Ident, and the parser recognizes the keyword by
	// text only in declaration-opening position.
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
	Arrow,    // function return type
	Eq_Arrow, // match arm separator `=>`
	Eq,       // binding, never equality
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
	line:       int,         // 1-based source line of the token's first byte (§15 diagnostic provenance)
}

stage_lex :: proc(source: string) -> []Token {
	tokens := make([dynamic]Token, 0, 16, context.temp_allocator)
	nesting := Nesting {
		frames = make([dynamic]Bracket_Frame, 0, 8, context.temp_allocator),
	}
	prev_kind := Token_Kind.Invalid
	// line tracks the 1-based source line of the byte at `i`: it advances by
	// the count of '\n' bytes the cursor has stepped over, so every token is
	// stamped with the line of its first byte (§15 diagnostic provenance,
	// artifact-format §9 span). scanned is the cursor position `line` is
	// current for, so newlines crossed between tokens are counted exactly once.
	line := 1
	scanned := 0
	i := 0
	for i < len(source) {
		for scanned < i {
			if source[scanned] == '\n' {
				line += 1
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
		if tok.kind == .Newline && newline_suppressed(&nesting, source, next) {
			i = next
			continue
		}
		// A declaration-opening contextual keyword (`thing`/`singleton`/`data`/
		// `enum`/`query`) sits at the start of a module-level statement: the previous
		// emitted token was a statement terminator (or none) and no bracket frame
		// is open. Only there does it arm the body brace as a block; in value
		// position (`let thing = …`) it is an ordinary Ident the rule ignores.
		at_stmt_start := prev_kind == .Newline || prev_kind == .Invalid
		update_nesting(&nesting, tok, prev_kind, at_stmt_start)
		append(&tokens, tok)
		prev_kind = tok.kind
		i = next
	}
	return tokens[:]
}

// Nesting tracks the bracket context that decides whether a newline is
// a statement terminator (spec §02). The decision is the INNERMOST open
// bracket's role, tracked as a stack of frames: newlines inside a ( ) frame
// and inside a record-literal { } frame are layout (suppressed); newlines
// inside a list literal [ ] frame and inside a block { } frame are SEPARATORS,
// kept. A stack (not depth counters) is required because the roles interleave:
// a block brace opened INSIDE parens (a lambda body's `match { … }` passed as a
// combinator argument — `fold(xs, init, fn(a, b) { return match … })`) must keep
// its arm-separator newlines even though a `(` is open further out. Counting
// "any paren open" would suppress those arm separators and break the match. The
// pong `setup` list (newline-separated `Spawn(…)` elements, 01 §5) keeps its
// separators because the innermost frame is the list bracket.
//
// The two brace roles are told apart by the predecessor token: a `{` directly
// after an identifier — or after the `with` operator — is a record-style field
// list (Vec2{…}, self with {…}); any other `{` (after a test name string, a
// lambda's `)`) opens a block. block_pending arms the next `{` to open a block,
// not a record literal, for the constructs whose body brace is preceded by an
// Ident that the prev==Ident rule would otherwise misread as a record head: a
// `match` scrutinee (ends in an Ident/`)`), an `if` condition (ends in any
// value), a declaration body (`thing Paddle {`, `data Board {`, `enum Steer:
// Axis {`, `pipeline Pong {`), a `behavior … on Thing {`, and a function's
// return type (`-> Vec2 {`). Each of these arms the flag (on the keyword, `on`,
// or the `->` arrow); the first `{` thereafter clears it, so nested record
// literals inside the body still classify as record braces.
Nesting :: struct {
	frames:        [dynamic]Bracket_Frame,
	block_pending: bool,
}

// Bracket_Frame is one open bracket's role on the nesting stack. suppress is
// whether a newline inside this frame is layout (dropped) rather than a
// statement/arm/element separator (kept). is_record is carried so a `}` knows
// it is closing a record-brace frame for the diagnostic-free pop; it is not read
// for the suppression decision (suppress already encodes it).
Bracket_Frame :: struct {
	suppress:  bool,
	is_record: bool,
}

newline_suppressed :: proc(n: ^Nesting, source: string, after: int) -> bool {
	// The innermost open bracket decides: a ( ) or record { } frame suppresses
	// newlines; a list [ ] or block { } frame, and the top level, keep them.
	if len(n.frames) > 0 && n.frames[len(n.frames) - 1].suppress {
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

update_nesting :: proc(n: ^Nesting, tok: Token, prev: Token_Kind, at_stmt_start: bool) {
	// A declaration-opening contextual keyword (`thing`/`singleton`/`data`/
	// `enum`/`query`) arms its body brace as a block exactly like the reserved decl
	// keywords below — but only in declaration-opening position (top of a
	// module-level statement, no open bracket frame). In value position it lexes
	// as a plain Ident the prev==Ident record-brace rule treats normally.
	if tok.kind == .Ident && len(n.frames) == 0 && at_stmt_start && is_decl_opener_keyword(tok.text) {
		n.block_pending = true
		return
	}
	#partial switch tok.kind {
	case .Match, .If, .Else, .Behavior, .Signal, .Pipeline, .Arrow:
		// `behavior … on Ball {` keeps its body brace a block via the .Behavior
		// arming above — `on` lexes as an Ident and need not re-arm here, as
		// nothing consumes block_pending before the body `{`. `.Else` arms the
		// alternate arm's `{` as a block the same way `.If` arms the consequent's.
		n.block_pending = true
	case .L_Paren:
		// A paren frame suppresses newlines (call args / grouping / tuple are
		// comma-separated layout).
		append(&n.frames, Bracket_Frame{suppress = true})
	case .R_Paren:
		pop_frame(n)
	case .L_Bracket:
		// A list frame keeps newlines — list elements separate by newline or
		// comma (spec §02 §1, the pong setup program).
		append(&n.frames, Bracket_Frame{suppress = false})
	case .R_Bracket:
		pop_frame(n)
	case .L_Brace:
		// A `{` after an Ident or the `with` operator is a record-style field
		// list (suppress newlines) — unless block_pending armed it as a
		// declaration body or control-flow block (keep newlines: a block's
		// interior is a statement / arm / member sequence).
		is_record := (prev == .Ident || prev == .With) && !n.block_pending
		n.block_pending = false
		append(&n.frames, Bracket_Frame{suppress = is_record, is_record = is_record})
	case .R_Brace:
		pop_frame(n)
	}
}

// pop_frame closes the innermost bracket frame, guarding an unbalanced closer
// (a stray `)`/`]`/`}`) so the lexer never underflows — an unbalanced source is
// the parser's reject, not a lexer crash.
pop_frame :: proc(n: ^Nesting) {
	if len(n.frames) > 0 {
		pop(&n.frames)
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
	case "extern":
		return Token{kind = .Extern, text = text}, i
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
	// `on`/`thing`/`singleton`/`data`/`enum`/`query` are CONTEXTUAL keywords, not
	// reserved ones (fun.ll1.md §2): each selects a production only where it
	// opens a module-level declaration, yet is a perfectly valid §02 value name
	// elsewhere — a binding (`let thing = …`), a field (`data Cfg { data: Bytes
	// }`), a member read (`s.on`), an argument. Lexing them as Ident keeps the
	// value-name namespace whole; the parser recognizes each keyword by text only
	// in declaration-opening position, the same by-text recognition `step` and
	// the behavior-header `on` separator use.
	return Token{kind = .Ident, text = text, class = classify_ident(text)}, i
}

// is_decl_opener_keyword reports whether a word is one of the contextual
// declaration-opening keywords (fun.ll1.md §2: `data enum thing singleton
// query`). These lex as Ident; the word is the keyword only when it opens a
// module-level declaration. Both the lexer (to arm the body brace as a block,
// not a record literal) and the parser (parse_declaration's by-text dispatch)
// consult this one set, so the contextual classification lives in a single
// place. `on` is a contextual keyword too but is a behavior-header separator,
// never a declaration opener, so it is recognized by parse_behavior alone.
//
// `mut` is a §2 contextual keyword too and IS a declaration opener in the
// grammar (`mut data`, §03 §7) — but its production does not exist (emit_data
// hardcodes mut=false), so it is deliberately ABSENT from this set: a word arms
// a block here only if its declaration parses. `mut` stays an ordinary Ident in
// every position; when the production lands it joins this set
// (test_query_mut_contextual_value_only pins both directions). `query` joined
// when its §08 §3 declaration production landed (parse_query).
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

// is_upper_ident reports whether a casing class is an UPPER_IDENT — a name
// that starts uppercase (lexical-core.ebnf §2: the parser-level split is
// upper vs lower only; UpperCamel-vs-UPPER_SNAKE is a lint band on top).
// Type names and enum variants are UPPER_IDENT, so a single-capital or
// capital-plus-digit variant (Key::W, PlayerId::P1) — which classify as
// Upper_Snake for lack of a lowercase letter — is still a valid variant.
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
