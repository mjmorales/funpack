// The Pratt expression cascade over the golden-file surface (spec §02).
// One binding-power table orders the whole ladder, low → high:
// or → and → == != → < <= > >= → + - → * / % → unary (not, -) → with →
// call/member → atom. `and`/`or`/`not` are word operators carried as Ident
// tokens, so the table keys them by text; `with` (the record-update
// operator, spec §02 §5) binds just above unary and just below the
// call/member postfix loop. `if` parses as the early-return statement form
// in fn bodies (parser.odin), not as an expression atom here. Indexing
// `xs[i]` and ranges have no production and parse as errors; `match` parses
// structurally (spec §02 §5), is typed by typecheck.odin's match_check, and
// is proven exhaustive by the gate stage (gates.odin).
package funpack

Expr :: union {
	^Int_Lit_Expr,
	^Fixed_Lit_Expr,
	^String_Lit_Expr,
	^Name_Expr,
	^Call_Expr,
	^Member_Expr,
	^Variant_Expr,
	^Record_Expr,
	^List_Expr,
	^Lambda_Expr,
	^Unary_Expr,
	^Binary_Expr,
	^With_Expr,
	^Match_Expr,
	^Tuple_Expr,
}

Int_Lit_Expr :: struct {
	value: i64,
}

Fixed_Lit_Expr :: struct {
	bits: Fixed,
}

// String_Lit_Expr carries a string literal's raw inner text, including any
// `{expr}` interpolation holes (spec §02 §2). Interpolation is parse-only
// here — the holes are retained verbatim in `text`, not split into
// sub-expressions; that split is a typing/lowering concern, not grammar.
String_Lit_Expr :: struct {
	text: string,
}

Name_Expr :: struct {
	name:  string,
	class: Ident_Class,
}

Call_Expr :: struct {
	callee: Expr,
	args:   []Expr,
}

// Member_Expr covers field access, UFCS receivers, and a type's
// associated members alike (a.b, body.apply_impulse, Fixed.MAX) —
// which one it is resolves semantically, not structurally.
Member_Expr :: struct {
	receiver: Expr,
	member:   string,
	class:    Ident_Class,
}

// Variant_Expr is an enum-variant value selected with `::` (spec §02 §3).
// A bare variant has no payload (Option::None); a tuple-payload variant
// carries positional argument expressions (Option::Some(v)); a
// struct-payload variant carries named fields (Draw::Rect{ at: …, size: …
// }). The closed payload tag distinguishes the three; `payload` holds the
// tuple args and `fields` the struct fields, mutually exclusive.
Variant_Expr :: struct {
	type_name:   string,
	variant:     string,
	payload:     []Expr,         // tuple-payload positional args
	fields:      []Record_Field, // struct-payload named fields
	has_payload: bool,           // true for a tuple-payload variant
	has_fields:  bool,           // true for a struct-payload variant
}

Record_Field :: struct {
	name:  string,
	value: Expr,
}

Record_Expr :: struct {
	type_name: string,
	fields:    []Record_Field,
}

List_Expr :: struct {
	elements: []Expr,
}

// Tuple_Expr is a fixed-arity positional aggregate `(a, b, …)` (spec §02;
// §04 §1 — every draw returns the pair `(value, next_rng)`, written as a
// tuple expression). It is distinguished from a parenthesized grouping `(e)`
// by the presence of a comma: a single parenthesized expression stays a
// grouping (it unwraps to its inner expr at parse_atom), so a Tuple_Expr
// always holds two or more elements. The artifact-format `tuple` node KIND
// that serializes it (§2.7) lands with the golden-integration seam; this
// grammar seam ships the parse node and its structural-gate scoring only.
Tuple_Expr :: struct {
	elements: []Expr,
}

// Lambda_Expr carries the single-return body form the golden surface
// uses: fn(params) { return expr }.
Lambda_Expr :: struct {
	params: []string,
	body:   Expr,
}

Unary_Expr :: struct {
	op:      Token, // Minus, or the word operator `not`
	operand: Expr,
}

Binary_Expr :: struct {
	op:  Token, // glyph operators by kind; `and`/`or` as Ident tokens
	lhs: Expr,
	rhs: Expr,
}

// Pattern_Kind is the closed, minimal pattern taxonomy this parser
// admits (spec §02 §5; grammar/fun.ebnf §13): the exhaustiveness gate
// over Option/enum variants needs these four. Struct-field-pun patterns
// are deliberately out of this minimal scope; the tuple pattern is the
// snake/hunt `match pick(free, rng) { (Option::Some(cell), next) => … }`
// shape — a parenthesized sequence of sub-patterns, each a child Pattern.
Pattern_Kind :: enum {
	Wildcard,      // `_`
	Bare_Variant,  // `Dir::Up`
	Variant_Binds, // `Option::Some(v)` — payload positions bind value names
	Tuple,         // `(Option::Some(cell), next)` — positional sub-patterns
	Bare_Binder,   // `next` — a snake_case name binding the whole position
}

// Pattern is a match-arm pattern. type_name/variant are set for the two
// variant forms; binders holds the payload binder names for the
// Variant_Binds form (empty otherwise); elements holds the positional
// sub-patterns for the Tuple form (empty otherwise). A tuple sub-pattern is
// itself a Pattern — snake's only depth is one variant-with-binder plus one
// bare binder per position, but the shape recurses by construction.
Pattern :: struct {
	kind:      Pattern_Kind,
	type_name: string,    // variant forms: the enum type (`Option`, `Dir`)
	variant:   string,    // variant forms: the variant (`Some`, `Up`)
	binders:   []string,  // Variant_Binds: payload binder names
	elements:  []Pattern, // Tuple: positional sub-patterns
}

// Match_Arm is one `pattern => body` arm; the body is a single
// expression, mirroring the lambda single-return shape (block-bodied
// arms are out of this minimal scope).
Match_Arm :: struct {
	pattern: Pattern,
	body:    Expr,
}

// Match_Expr is the structural match node (spec §02 §5): a scrutinee and
// its newline-separated arms. stage_typecheck types it through match_check
// (typecheck.odin) — the scrutinee is typed, each arm's binders bind against
// its variant payloads, and the arm bodies unify to the match's type — and
// the gate stage proves it exhaustive against its closed variant set
// (gates.odin).
Match_Expr :: struct {
	scrutinee: Expr,
	arms:      []Match_Arm,
}

// With_Expr is the record-update operator `value with { field: v, … }`
// (spec §02 §5): a new value with the named fields replaced (COW). `base`
// is the value being updated — a full postfix expression, since `with`
// binds just below the call/member loop — and `fields` are the
// replacements. The form nests (`a with { … } with { … }`), so a With_Expr
// can itself be the base of another.
With_Expr :: struct {
	base:   Expr,
	fields: []Record_Field,
}

// Binding_Power is the one table ordering the ladder; the enum's
// numeric order IS the precedence (spec §02).
Binding_Power :: enum {
	None,
	Or,
	And,
	Equality,
	Comparison,
	Additive,
	Multiplicative,
	Unary,
}

infix_power :: proc(tok: Token) -> Binding_Power {
	#partial switch tok.kind {
	case .Eq_Eq, .Not_Eq:
		return .Equality
	case .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return .Comparison
	case .Plus, .Minus:
		return .Additive
	case .Star, .Slash, .Percent:
		return .Multiplicative
	case .Ident:
		switch tok.text {
		case "or":
			return .Or
		case "and":
			return .And
		}
	}
	return .None
}

// parse_expression is the single expression seam every statement RHS
// enters.
parse_expression :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	return parse_binary(p, .Or)
}

parse_binary :: proc(p: ^Parser, min_power: Binding_Power) -> (expr: Expr, err: Parse_Error) {
	lhs := parse_unary(p) or_return
	for !at_end(p) {
		tok := p.tokens[p.pos]
		power := infix_power(tok)
		if power == .None || power < min_power {
			break
		}
		p.pos += 1
		// The right side starts one power higher, making every binary
		// operator left-associative — the fold direction §10 depends on.
		rhs := parse_binary(p, Binding_Power(int(power) + 1)) or_return
		node := new(Binary_Expr, context.temp_allocator)
		node^ = Binary_Expr{op = tok, lhs = lhs, rhs = rhs}
		lhs = node
	}
	return lhs, .None
}

parse_unary :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	is_minus := peek_kind(p) == .Minus
	is_not := peek_kind(p) == .Ident && !at_end(p) && p.tokens[p.pos].text == "not"
	if is_minus || is_not {
		tok := advance(p) or_return
		operand := parse_unary(p) or_return
		node := new(Unary_Expr, context.temp_allocator)
		node^ = Unary_Expr{op = tok, operand = operand}
		return node, .None
	}
	return parse_with(p)
}

// parse_with sits one tier below unary and above the call/member postfix
// loop (spec §02 §3 precedence table): it parses a postfix expression then
// folds any trailing `with { … }` updates onto it. `with` is left-binding
// and nests, so each update wraps the prior result; a fresh `{ field: v }`
// field list (no type name) is the replacement set.
parse_with :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	expr = parse_postfix(p) or_return
	for peek_kind(p) == .With {
		p.pos += 1
		// The update brace is a fresh record-style field list, valid even
		// inside a match scrutinee's no-struct-literal context.
		saved := p.no_record_brace
		p.no_record_brace = false
		fields := parse_with_fields(p) or_return
		p.no_record_brace = saved
		node := new(With_Expr, context.temp_allocator)
		node^ = With_Expr{base = expr, fields = fields}
		expr = node
	}
	return expr, .None
}

// parse_with_fields parses the `{ field: v, … }` replacement set of a
// `with` update — the same field-list shape as a record literal, sharing
// parse_record_fields.
parse_with_fields :: proc(p: ^Parser) -> (fields: []Record_Field, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	return parse_record_fields(p)
}

parse_postfix :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	expr = parse_atom(p) or_return
	for {
		#partial switch peek_kind(p) {
		case .Dot:
			p.pos += 1
			member := expect(p, .Ident) or_return
			if member.class == .Mixed {
				return nil, .Wrong_Case
			}
			node := new(Member_Expr, context.temp_allocator)
			node^ = Member_Expr{receiver = expr, member = member.text, class = member.class}
			expr = node
		case .L_Paren:
			args := parse_call_args(p) or_return
			node := new(Call_Expr, context.temp_allocator)
			node^ = Call_Expr{callee = expr, args = args}
			expr = node
		case:
			return expr, .None
		}
	}
}

parse_atom :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	tok := advance(p) or_return
	#partial switch tok.kind {
	case .Int_Lit:
		node := new(Int_Lit_Expr, context.temp_allocator)
		node^ = Int_Lit_Expr{value = tok.int_value}
		return node, .None
	case .Fixed_Lit:
		node := new(Fixed_Lit_Expr, context.temp_allocator)
		node^ = Fixed_Lit_Expr{bits = tok.fixed_bits}
		return node, .None
	case .String_Lit:
		// A string literal atom retains its raw inner text, interpolation
		// holes and all (spec §02 §2).
		node := new(String_Lit_Expr, context.temp_allocator)
		node^ = String_Lit_Expr{text = tok.text}
		return node, .None
	case .L_Paren:
		// A parenthesized form is either a grouping `(e)` or a tuple
		// `(a, b, …)` — the comma after the first element discriminates the
		// two (spec §02; §04 §1). A record literal inside is valid even within
		// a match scrutinee, so the no-record-brace context is lifted here.
		return parse_paren_atom(p)
	case .L_Bracket:
		return parse_list_tail(p)
	case .Fn:
		return parse_lambda(p)
	case .Match:
		return parse_match(p)
	case .Ident:
		return parse_name_atom(p, tok)
	}
	return nil, .Unexpected_Token
}

// parse_paren_atom parses a parenthesized atom after the `(` is consumed: a
// grouping `(e)` that unwraps to its inner expression, or a tuple `(a, b, …)`
// (spec §02; §04 §1 — `(value, next_rng)`). The first element parses, then a
// comma decides: a comma opens the comma-list and the result is a Tuple_Expr;
// no comma means a plain grouping and the inner expression passes through. A
// trailing comma after the last element is accepted, mirroring lists. The
// no-record-brace context is lifted inside the parentheses (a record literal
// is valid there even within a match scrutinee).
parse_paren_atom :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	saved := p.no_record_brace
	p.no_record_brace = false
	defer p.no_record_brace = saved
	first := parse_expression(p) or_return
	if peek_kind(p) != .Comma {
		// A single parenthesized expression is a grouping, not a tuple.
		expect(p, .R_Paren) or_return
		return first, .None
	}
	elements := make([dynamic]Expr, 0, 4, context.temp_allocator)
	append(&elements, first)
	for peek_kind(p) == .Comma {
		p.pos += 1
		if peek_kind(p) == .R_Paren {
			break // a trailing comma after the last element
		}
		element := parse_expression(p) or_return
		append(&elements, element)
	}
	expect(p, .R_Paren) or_return
	node := new(Tuple_Expr, context.temp_allocator)
	node^ = Tuple_Expr{elements = elements[:]}
	return node, .None
}

// parse_match parses `match scrutinee { pattern => expr … }` (spec §02
// §5). The match brace is a block context, so its arms are
// newline-separated (the lexer kept those newlines); a `,` is also a
// legal separator (Sep). Each arm body is a single expression.
parse_match :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	// The scrutinee parses in the no-struct-literal context: a trailing
	// `{` opens the match block, not a record literal off the scrutinee.
	p.no_record_brace = true
	scrutinee := parse_expression(p) or_return
	p.no_record_brace = false
	expect(p, .L_Brace) or_return
	skip_arm_separators(p)
	arms := make([dynamic]Match_Arm, 0, 4, context.temp_allocator)
	for peek_kind(p) != .R_Brace {
		pattern := parse_pattern(p) or_return
		expect(p, .Eq_Arrow) or_return
		body := parse_expression(p) or_return
		append(&arms, Match_Arm{pattern = pattern, body = body})
		if peek_kind(p) != .R_Brace {
			// Arms separate by newline or `,` (Sep); at least one is
			// required between two arms.
			if peek_kind(p) != .Newline && peek_kind(p) != .Comma {
				return nil, .Unexpected_Token
			}
			skip_arm_separators(p)
		}
	}
	expect(p, .R_Brace) or_return
	node := new(Match_Expr, context.temp_allocator)
	node^ = Match_Expr{scrutinee = scrutinee, arms = arms[:]}
	return node, .None
}

// parse_pattern parses the minimal pattern set (spec §02 §5; grammar
// §13): wildcard `_`, a variant `Type::Variant`, a variant with payload
// binders `Type::Variant(a, b)`, or a tuple `(p, q, …)` of positional
// sub-patterns. A `(` head opens the tuple form; otherwise a `_` (lexed as a
// snake_case Ident) is the wildcard and an UPPER_IDENT head a variant.
parse_pattern :: proc(p: ^Parser) -> (pattern: Pattern, err: Parse_Error) {
	if peek_kind(p) == .L_Paren {
		return parse_tuple_pattern(p)
	}
	tok := expect(p, .Ident) or_return
	if tok.text == "_" {
		return Pattern{kind = .Wildcard}, .None
	}
	// The two remaining forms are variant patterns: an UPPER_IDENT enum
	// type, `::`, then an UPPER_IDENT variant (lexical-core.ebnf §2).
	if !is_upper_ident(tok.class) {
		return pattern, .Wrong_Case
	}
	expect(p, .Colon_Colon) or_return
	variant := expect(p, .Ident) or_return
	if !is_upper_ident(variant.class) {
		return pattern, .Wrong_Case
	}
	if peek_kind(p) != .L_Paren {
		return Pattern{kind = .Bare_Variant, type_name = tok.text, variant = variant.text}, .None
	}
	binders := parse_pattern_binders(p) or_return
	return Pattern{
		kind = .Variant_Binds,
		type_name = tok.text,
		variant = variant.text,
		binders = binders,
	}, .None
}

// parse_pattern_binders parses `(a, b)` — the payload binder names of a
// variant pattern. Binders are value names, so snake_case; nested
// patterns are out of this minimal scope.
parse_pattern_binders :: proc(p: ^Parser) -> (binders: []string, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	list := make([dynamic]string, 0, 4, context.temp_allocator)
	for peek_kind(p) != .R_Paren {
		name := expect(p, .Ident) or_return
		if name.class != .Snake_Case {
			return nil, .Wrong_Case
		}
		append(&list, name.text)
		if peek_kind(p) == .Comma {
			p.pos += 1
		} else {
			break
		}
	}
	expect(p, .R_Paren) or_return
	return list[:], .None
}

// parse_tuple_pattern parses a tuple pattern `(p, q, …)` — a parenthesized
// sequence of positional sub-patterns (spec §02 §5). Each position is either
// a bare snake_case binder (`next` — binds the whole position) or a full
// sub-pattern (a variant `Option::Some(cell)`, a wildcard `_`, or a nested
// tuple). A bare binder is distinguished from a variant by its leading
// snake_case Ident: a variant head is UPPER_IDENT and a `_` is the wildcard,
// so any other snake_case name at a position head is a bare binder.
parse_tuple_pattern :: proc(p: ^Parser) -> (pattern: Pattern, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	elements := make([dynamic]Pattern, 0, 4, context.temp_allocator)
	for peek_kind(p) != .R_Paren {
		sub := parse_tuple_sub_pattern(p) or_return
		append(&elements, sub)
		if peek_kind(p) == .Comma {
			p.pos += 1
		} else {
			break
		}
	}
	expect(p, .R_Paren) or_return
	return Pattern{kind = .Tuple, elements = elements[:]}, .None
}

// parse_tuple_sub_pattern parses one position of a tuple pattern: a bare
// snake_case binder, or a full sub-pattern. A leading snake_case Ident that
// is not the wildcard `_` is a bare binder (it binds the whole position); the
// binder name is carried in the single-element `binders` slice. Everything
// else (`_`, a variant, a nested tuple) defers to parse_pattern.
parse_tuple_sub_pattern :: proc(p: ^Parser) -> (pattern: Pattern, err: Parse_Error) {
	if peek_kind(p) == .Ident && is_snake_binder(p.tokens[p.pos]) {
		name := advance(p) or_return
		binders := make([]string, 1, context.temp_allocator)
		binders[0] = name.text
		return Pattern{kind = .Bare_Binder, binders = binders}, .None
	}
	return parse_pattern(p)
}

// is_snake_binder reports whether a token is a bare binder name — a
// snake_case Ident other than the wildcard `_`. The wildcard lexes as a
// snake_case Ident too, so it is excluded by text here and handled as the
// Wildcard pattern by parse_pattern.
is_snake_binder :: proc(tok: Token) -> bool {
	return tok.kind == .Ident && tok.class == .Snake_Case && tok.text != "_"
}

// skip_arm_separators consumes the Sep run (newlines and commas) between
// match arms (spec §02 §5: arms are newline-separated; `,` is also a
// legal Sep).
skip_arm_separators :: proc(p: ^Parser) {
	for peek_kind(p) == .Newline || peek_kind(p) == .Comma {
		p.pos += 1
	}
}

parse_name_atom :: proc(p: ^Parser, tok: Token) -> (expr: Expr, err: Parse_Error) {
	following := peek_kind(p)
	// In a match scrutinee's no-struct-literal context, a trailing `{`
	// belongs to the match block — treat the name as a bare value, not a
	// record-literal head, so neither the casing check nor the record
	// branch claims the brace.
	if p.no_record_brace && following == .L_Brace {
		check_ident_case(tok, .Invalid) or_return
		node := new(Name_Expr, context.temp_allocator)
		node^ = Name_Expr{name = tok.text, class = tok.class}
		return node, .None
	}
	check_ident_case(tok, following) or_return
	#partial switch following {
	case .Colon_Colon:
		p.pos += 1
		variant := expect(p, .Ident) or_return
		// Enum variants are UPPER_IDENT (spec §02; lexical-core.ebnf §2),
		// so a single-capital variant (Key::W, PlayerId::P1) is valid.
		if !is_upper_ident(variant.class) {
			return nil, .Wrong_Case
		}
		node := new(Variant_Expr, context.temp_allocator)
		node^ = Variant_Expr{type_name = tok.text, variant = variant.text}
		#partial switch peek_kind(p) {
		case .L_Paren:
			// Tuple-payload variant: Option::Some(v), MoveTo(Vec2)-style args.
			node.payload = parse_call_args(p) or_return
			node.has_payload = true
		case .L_Brace:
			// Struct-payload variant: Draw::Rect{ at: …, size: … } (spec §03 §2).
			// In a no-struct-literal context (a match scrutinee or an `if`-guard
			// condition, spec §02 §5), a trailing `{` opens the enclosing block,
			// not a struct payload — so a bare variant compared in a condition
			// (`current != Dir::Down { return … }`) leaves the brace for the
			// guard, mirroring the bare-name rule above.
			if !p.no_record_brace {
				p.pos += 1
				node.fields = parse_record_fields(p) or_return
				node.has_fields = true
			}
		}
		return node, .None
	case .L_Brace:
		return parse_record_tail(p, tok.text)
	}
	node := new(Name_Expr, context.temp_allocator)
	node^ = Name_Expr{name = tok.text, class = tok.class}
	return node, .None
}

// parse_record_tail parses `{ field: expr, … }` after the constructor
// name and wraps it as a Record_Expr.
parse_record_tail :: proc(p: ^Parser, type_name: string) -> (expr: Expr, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	fields := parse_record_fields(p) or_return
	node := new(Record_Expr, context.temp_allocator)
	node^ = Record_Expr{type_name = type_name, fields = fields[:]}
	return node, .None
}

// parse_record_fields parses the `field: expr, …` body of a record literal,
// a struct-payload variant, or a `with` update, with the opening `{`
// already consumed and the closing `}` consumed here. The lexer dropped
// interior newlines (record braces are layout context), so `,` is the only
// separator seen here. Field names are value names — snake_case (spec §02).
parse_record_fields :: proc(p: ^Parser) -> (fields: []Record_Field, err: Parse_Error) {
	list := make([dynamic]Record_Field, 0, 4, context.temp_allocator)
	for peek_kind(p) == .Ident {
		fname := advance(p) or_return
		if fname.class != .Snake_Case {
			return nil, .Wrong_Case
		}
		expect(p, .Colon) or_return
		value := parse_expression(p) or_return
		append(&list, Record_Field{name = fname.text, value = value})
		if peek_kind(p) == .Comma {
			p.pos += 1
		}
	}
	expect(p, .R_Brace) or_return
	return list[:], .None
}

parse_list_tail :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	saved := p.no_record_brace
	p.no_record_brace = false
	defer p.no_record_brace = saved
	elements := make([dynamic]Expr, 0, 4, context.temp_allocator)
	// List elements separate by newline or `,` — both legal (spec §02 §1).
	// Inside `[ ]` the lexer keeps newlines (they are separators, not layout),
	// so a multi-line list like the pong `setup` program parses element-per-line.
	skip_list_separators(p)
	for peek_kind(p) != .R_Bracket {
		element := parse_expression(p) or_return
		append(&elements, element)
		if peek_kind(p) == .Comma || peek_kind(p) == .Newline {
			skip_list_separators(p)
		} else {
			break
		}
	}
	expect(p, .R_Bracket) or_return
	node := new(List_Expr, context.temp_allocator)
	node^ = List_Expr{elements = elements[:]}
	return node, .None
}

// skip_list_separators consumes the Sep run (newlines and commas) between
// list elements (spec §02 §1: both are legal separators; a trailing one is
// allowed).
skip_list_separators :: proc(p: ^Parser) {
	for peek_kind(p) == .Newline || peek_kind(p) == .Comma {
		p.pos += 1
	}
}

parse_lambda :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	params := make([dynamic]string, 0, 4, context.temp_allocator)
	for peek_kind(p) == .Ident {
		param := advance(p) or_return
		// Parameters are value names — snake_case (spec §02).
		if param.class != .Snake_Case {
			return nil, .Wrong_Case
		}
		append(&params, param.text)
		if peek_kind(p) == .Comma {
			p.pos += 1
		}
	}
	expect(p, .R_Paren) or_return
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	expect(p, .Return) or_return
	body := parse_expression(p) or_return
	skip_newlines(p)
	expect(p, .R_Brace) or_return
	node := new(Lambda_Expr, context.temp_allocator)
	node^ = Lambda_Expr{params = params[:], body = body}
	return node, .None
}

parse_call_args :: proc(p: ^Parser) -> (args: []Expr, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	saved := p.no_record_brace
	p.no_record_brace = false
	defer p.no_record_brace = saved
	list := make([dynamic]Expr, 0, 4, context.temp_allocator)
	for peek_kind(p) != .R_Paren {
		arg := parse_expression(p) or_return
		append(&list, arg)
		if peek_kind(p) == .Comma {
			p.pos += 1
		} else {
			break
		}
	}
	expect(p, .R_Paren) or_return
	return list[:], .None
}
