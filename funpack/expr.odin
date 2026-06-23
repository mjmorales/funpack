// The Pratt expression cascade over the golden-file surface (spec §02).
// One binding-power table orders the whole ladder, low → high:
// or → and → == != → < <= > >= → + - → * / % → unary (not, -) → with →
// call/member → atom. `and`/`or`/`not` are word operators carried as Ident
// tokens, so the table keys them by text; `with` (the record-update
// operator, spec §02 §5) binds just above unary and just below the
// call/member postfix loop. `if` is BOTH the early-return statement form in
// fn bodies (parser.odin parse_if_stmt) AND a value expression atom here
// (parse_if_expr): the value form `if cond { expr } else { expr }` requires
// both arms — a missing `else` is the precise parse error .Missing_Else, never
// a fallback — and the typechecker unifies the two arm types (the "if/match
// pullout" of grammar/fun.ll1.md: `if` at statement head dispatches to the
// statement construct, as an Atom elsewhere it is the expression). Indexing
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
	^If_Expr,
	^Stub_Expr,
	^All_Expr,
}

// expr_span is the one pure accessor returning any Expr arm's stamped span —
// the §15 line/col of the construct's first byte (the leftmost-byte convention
// every arm follows; see the Int_Lit_Expr note). It is the frontend's
// provenance interface: the typecheck stage calls it to point a diagnostic at
// the offending expression without reaching into each arm's struct. A nil Expr
// (a hole the parser left empty) reports (0, 0) — no position — never a crash.
expr_span :: proc(e: Expr) -> (line: int, col: int) {
	switch n in e {
	case ^Int_Lit_Expr:
		return n.line, n.col
	case ^Fixed_Lit_Expr:
		return n.line, n.col
	case ^String_Lit_Expr:
		return n.line, n.col
	case ^Name_Expr:
		return n.line, n.col
	case ^Call_Expr:
		return n.line, n.col
	case ^Member_Expr:
		return n.line, n.col
	case ^Variant_Expr:
		return n.line, n.col
	case ^Record_Expr:
		return n.line, n.col
	case ^List_Expr:
		return n.line, n.col
	case ^Lambda_Expr:
		return n.line, n.col
	case ^Unary_Expr:
		return n.line, n.col
	case ^Binary_Expr:
		return n.line, n.col
	case ^With_Expr:
		return n.line, n.col
	case ^Match_Expr:
		return n.line, n.col
	case ^Tuple_Expr:
		return n.line, n.col
	case ^If_Expr:
		return n.line, n.col
	case ^Stub_Expr:
		return n.line, n.col
	case ^All_Expr:
		return n.line, n.col
	}
	return 0, 0
}

// Every Expr arm carries `line`/`col` — the §15 diagnostic provenance of the
// construct's FIRST byte (the token that opened the production). The span
// anchors on the start of the whole expression, never the operator: a
// `Binary_Expr a + b` reports `a`'s position, a `Unary_Expr -x` reports the
// `-`'s position (the `-` IS the construct's first byte), so a single
// convention — leftmost byte — locates every node. expr_span reads this pair
// uniformly across the union; the typecheck stage uses it to point a
// diagnostic at the offending expression.
Int_Lit_Expr :: struct {
	value: i64,
	line:  int,
	col:   int,
}

Fixed_Lit_Expr :: struct {
	bits: Fixed,
	line: int,
	col:  int,
}

// String_Lit_Expr carries a string literal's raw inner text, including any
// `{expr}` interpolation holes (spec §02 §2) and the closed lexical-core §4
// escape spellings (`\"` `\{` `\}`) backslash-and-all. Interpolation is
// parse-only here — the holes are retained verbatim in `text`, not split into
// sub-expressions; that split is a typing/lowering concern, not grammar — and
// unescaping is the same kind of lowering concern, so `text` is always the
// source bytes between the quotes.
String_Lit_Expr :: struct {
	text: string,
	line: int,
	col:  int,
}

Name_Expr :: struct {
	name:  string,
	class: Ident_Class,
	line:  int,
	col:   int,
}

Call_Expr :: struct {
	callee: Expr,
	args:   []Expr,
	line:   int,
	col:    int,
}

// Member_Expr covers field access, UFCS receivers, and a type's
// associated members alike (a.b, body.apply_impulse, Fixed.MAX) —
// which one it is resolves semantically, not structurally.
// line/col anchor the WHOLE access on the receiver's leftmost byte (the
// expr_span convention `a.b.c` reports `a` at every level); member_line/member_col
// anchor the MEMBER NAME's own token, the span a member-precise diagnostic
// ("no such method on this type", typecheck.odin) puts its caret under — distinct
// from the construct anchor so an unknown-member fault lands on `b`, not `a`.
Member_Expr :: struct {
	receiver:    Expr,
	member:      string,
	class:       Ident_Class,
	line:        int,
	col:         int,
	member_line: int,
	member_col:  int,
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
	line:        int,
	col:         int,
}

Record_Field :: struct {
	name:  string,
	value: Expr,
}

Record_Expr :: struct {
	type_name: string,
	fields:    []Record_Field,
	line:      int,
	col:       int,
}

List_Expr :: struct {
	elements: []Expr,
	line:     int,
	col:      int,
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
	line:     int,
	col:      int,
}

// Lambda_Expr carries the lambda's single-statement body as ONE Expr (spec
// §02 §5): the bare expression of an implicit-return body `fn(x){ x + 1 }`, the
// `if`-expression of `fn(x){ if c { a } else { b } }`, or the inner expression of
// a `return` body `fn(x){ return x + 1 }`. parse_lambda strips the optional
// leading `return`, so `body` is always the expression the evaluators run — there
// is no Return node.
Lambda_Expr :: struct {
	params: []string,
	body:   Expr,
	line:   int,
	col:    int,
}

// Unary_Expr/Binary_Expr already carry `op: Token`, but the explicit line/col
// pair is added for a UNIFORM expr_span accessor across the whole union (no arm
// is special-cased on `op`). For the unary form `op` is the construct's first
// byte, so line/col equal op's; for the binary form the span anchors on the
// LEAD OPERAND (`a` in `a + b`), the leftmost byte of the whole expression —
// not the operator — matching the every-arm "first byte of the construct" rule.
Unary_Expr :: struct {
	op:      Token, // Minus, or the word operator `not`
	operand: Expr,
	line:    int,
	col:     int,
}

Binary_Expr :: struct {
	op:   Token, // glyph operators by kind; `and`/`or` as Ident tokens
	lhs:  Expr,
	rhs:  Expr,
	line: int,
	col:  int,
}

// Pattern_Kind is the closed pattern taxonomy this parser admits (spec §02
// §5; grammar/fun.ebnf §13): the exhaustiveness gate over Option/enum
// variants needs these. Struct_Binds is the struct-payload field-pun form
// `Shape2::Box{size}` (yard `box_size`), parallel to the value-side
// struct-payload Variant_Expr (expr.odin Variant_Expr.fields): each named
// field binds a value of the same name. The tuple pattern is the snake/hunt
// `match pick(free, rng) { (Option::Some(cell), next) => … }` shape — a
// parenthesized sequence of sub-patterns, each a child Pattern.
Pattern_Kind :: enum {
	Wildcard,      // `_`
	Bare_Variant,  // `Dir::Up`
	Variant_Binds, // `Option::Some(v)` — payload positions bind value names
	Struct_Binds,  // `Shape2::Box{size}` — struct-payload fields field-pun bind
	Tuple,         // `(Option::Some(cell), next)` — positional sub-patterns
	Bare_Binder,   // `next` — a snake_case name binding the whole position
}

// Pattern is a match-arm pattern. type_name/variant are set for the three
// variant forms (Bare_Variant, Variant_Binds, Struct_Binds); binders holds
// the field-pun binder names for Struct_Binds (a binder name equals the bound
// field name), empty otherwise; elements holds the positional sub-patterns for
// both the Tuple form AND the Variant_Binds payload (grammar/fun.ebnf §13:
// `VariantPat ::= '(' Pattern (',' Pattern)* ')'` — each payload position is a
// full nested Pattern, so AppMsg::Hud(HudMsg::Coin) is a Variant_Binds whose one
// element is a Bare_Variant, and Option::Some(v) a Variant_Binds whose one
// element is a Bare_Binder). A sub-pattern is itself a Pattern — the §21 §3
// router nests one variant inside another, but the shape recurses by construction.
Pattern :: struct {
	kind:      Pattern_Kind,
	type_name: string,    // variant forms: the enum type (`Option`, `Dir`)
	variant:   string,    // variant forms: the variant (`Some`, `Box`)
	binders:   []string,  // Struct_Binds: field-pun binder names
	elements:  []Pattern, // Tuple / Variant_Binds: positional sub-patterns
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
	line:      int,
	col:       int,
}

// If_Expr is the value-producing conditional `if cond { then } else { else }`
// (spec §02 §5; grammar/fun.ebnf §15 IfExpr). Distinct from the parser.odin
// If_Node early-return STATEMENT — this is an EXPRESSION atom usable anywhere a
// value is (a `let` RHS, a `return` value, a match-arm body, a call argument).
// Both arms are REQUIRED in expression position: the parser rejects a missing
// `else` with .Missing_Else, and the typechecker unifies the two arm types
// (a disagreement is .Type_Mismatch). Each arm is a single value expression —
// the minimal value-block `{ expr }` shape, mirroring the lambda body and the
// match-arm body — and the else arm may itself be another If_Expr, so an
// else-if chain `if a { … } else if b { … } else { … }` nests by construction.
If_Expr :: struct {
	cond:        Expr,
	then_branch: Expr,
	else_branch: Expr,
	line:        int,
	col:         int,
}

// Stub_Expr is a §05 §2 typed hole standing in EXPRESSION position
// (grammar/fun.ebnf §15: StubExpr is an Atom), the expression-side twin of the
// body-position hole parse_stub_body records on Fn_Node: `1.0 + @stub(Fixed)`,
// `Vec2{x: @stub(Fixed, 0.5), y: 0.0}`. The hole ASCRIBES its declared T — the
// enclosing expression typechecks against T (stub_expr_check) — and the
// optional fallback is the dev approximation that evaluates in the scope at
// the hole's position (eval_stub_hole, the same funnel the body hole runs
// through). has_fallback distinguishes the two-argument form; fallback is
// meaningless when it is false, mirroring Fn_Node.has_fallback. The index
// registers the containing declaration as stub debt and --release refuses it
// exactly like a body hole (release_holed_decl descends expression trees).
Stub_Expr :: struct {
	hole_type:    Type_Ref,
	fallback:     Expr,
	has_fallback: bool,
	line:         int,
	col:          int,
}

// All_Expr is the §08 §3 world read `all[T]` — the whole table of a declared
// thing's instances as a View[T], in stable Id order. It is the ONLY way a
// query body reads the world (spec §08 §3: "reads the world via `all[T]` and
// `Ref` resolution"), so the typechecker admits it inside query bodies alone.
// Grammar: the fun.ebnf §14 index PostfixOp `'[' Expr ']'` applied to the
// contextual LOWER_IDENT `all` is this form's only ratified spelling — general
// value indexing still has no production (the header note above holds) — so
// the parser claims `all` + `[` as one atom on a single token of lookahead
// (LL(1) preserved: no other production begins `LOWER_IDENT '['`).
All_Expr :: struct {
	thing: string, // the read table's element thing — an UPPER_IDENT type name
	line:  int,
	col:   int,
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
	line:   int,
	col:    int,
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

// leading_binary_op reports whether `tok` is a binary-ONLY operator standing in
// a fresh statement/expression-start position — `and`/`or` (word operators
// carried as Ident), a comparison (`== != < <= > >=`), or an arithmetic
// (`+ * / %`) glyph — i.e. an infix operator with NO unary form. funpack is
// newline-terminated (spec §02 §1), so such a token at expression start means
// the prior line already ended a complete expression and this operator dangles
// across the newline with no left operand. `-` and `not` are EXCLUDED: they
// legally open a fresh expression (unary negation), so parse_unary owns them;
// only the binary-only operators reach this predicate's `true`. The infix_power
// table is the single source of which glyphs are infix; this predicate subtracts
// the two that also open a unary form.
leading_binary_op :: proc(tok: Token) -> bool {
	if tok.kind == .Minus {
		return false // `-` also opens a unary expression (parse_unary)
	}
	if tok.kind == .Ident && tok.text == "not" {
		return false // `not` is the word unary operator (parse_unary)
	}
	return infix_power(tok) != .None
}

// parse_expression is the single expression seam every statement RHS
// enters.
parse_expression :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	return parse_binary(p, .Or)
}

parse_binary :: proc(p: ^Parser, min_power: Binding_Power) -> (expr: Expr, err: Parse_Error) {
	// A fresh expression cannot open on a binary operator — funpack is
	// newline-terminated, so a leading `and`/`or`/comparison/arithmetic glyph is
	// a continuation dangling off the prior (already complete) line. Name the
	// verdict here at the single expression-entry seam, ahead of parse_unary,
	// rather than letting parse_atom's bare Unexpected_Token (or, for the word
	// operators, a stray name parse) swallow it (spec §02 §1).
	if !at_end(p) && leading_binary_op(p.tokens[p.pos]) {
		return nil, reject(p, p.tokens[p.pos], .Newline_Before_Binary_Op)
	}
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
		// The span anchors on the lead operand — the leftmost byte of `a + b`
		// is `a`, not the operator (the every-arm first-byte rule).
		lhs_line, lhs_col := expr_span(lhs)
		node^ = Binary_Expr{op = tok, lhs = lhs, rhs = rhs, line = lhs_line, col = lhs_col}
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
		// The `-`/`not` operator token IS the construct's first byte.
		node^ = Unary_Expr{op = tok, operand = operand, line = tok.line, col = tok.col}
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
		// `value with { … }` anchors on `value`, its leftmost byte.
		base_line, base_col := expr_span(expr)
		node^ = With_Expr{base = expr, fields = fields, line = base_line, col = base_col}
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
				return nil, reject(p, member, .Wrong_Case)
			}
			node := new(Member_Expr, context.temp_allocator)
			// `a.b` anchors on the receiver `a`, the leftmost byte; a postfix
			// chain `a.b.c` thus reports `a` at every level. member_line/member_col
			// keep the member token's OWN span (the `b`), so a member-precise
			// diagnostic anchors its caret under the offending member name.
			recv_line, recv_col := expr_span(expr)
			node^ = Member_Expr {
				receiver    = expr,
				member      = member.text,
				class       = member.class,
				line        = recv_line,
				col         = recv_col,
				member_line = member.line,
				member_col  = member.col,
			}
			expr = node
		case .L_Paren:
			args := parse_call_args(p) or_return
			node := new(Call_Expr, context.temp_allocator)
			// `f(x)` anchors on the callee `f`, the leftmost byte.
			callee_line, callee_col := expr_span(expr)
			node^ = Call_Expr{callee = expr, args = args, line = callee_line, col = callee_col}
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
		node^ = Int_Lit_Expr{value = tok.int_value, line = tok.line, col = tok.col}
		return node, .None
	case .Fixed_Lit:
		node := new(Fixed_Lit_Expr, context.temp_allocator)
		node^ = Fixed_Lit_Expr{bits = tok.fixed_bits, line = tok.line, col = tok.col}
		return node, .None
	case .String_Lit:
		// A string literal atom retains its raw inner text, interpolation
		// holes and all (spec §02 §2).
		node := new(String_Lit_Expr, context.temp_allocator)
		node^ = String_Lit_Expr{text = tok.text, line = tok.line, col = tok.col}
		return node, .None
	case .L_Paren:
		// A parenthesized form is either a grouping `(e)` or a tuple
		// `(a, b, …)` — the comma after the first element discriminates the
		// two (spec §02; §04 §1). A record literal inside is valid even within
		// a match scrutinee, so the no-record-brace context is lifted here. The
		// lead `(` is the construct's first byte (a grouping passes its inner
		// expr's own span through; a tuple anchors on the `(`).
		return parse_paren_atom(p, tok)
	case .L_Bracket:
		return parse_list_tail(p, tok)
	case .Fn:
		return parse_lambda(p, tok)
	case .Match:
		return parse_match(p, tok)
	case .If:
		return parse_if_expr(p, tok)
	case .At:
		return parse_stub_atom(p, tok)
	case .Ident:
		return parse_name_atom(p, tok)
	}
	// `tok` was consumed above; it is the unexpected atom token, so anchor the
	// diagnostic on it (post-advance — p.pos has moved past it).
	return nil, reject(p, tok, .Unexpected_Token)
}

// parse_stub_atom parses a `@stub(T)` / `@stub(T, fallback)` typed hole in
// EXPRESSION position (spec §05 §2; grammar/fun.ebnf §15: StubExpr is an
// Atom), with the leading `@` already consumed by parse_atom. The directive
// core is the same parse_stub_parts production the body-position hole uses
// (parser.odin parse_stub_body), so the two positions can never drift — only
// the carrier differs: an Expr node here, the holed Fn_Node there. A non-stub
// directive in expression position is an Unexpected_Token (parse_stub_parts'
// name check): @doc/@gtag/@todo prefix declarations, and no other directive
// names a value.
parse_stub_atom :: proc(p: ^Parser, at_tok: Token) -> (expr: Expr, err: Parse_Error) {
	hole_type, fallback, has_fallback := parse_stub_parts(p) or_return
	node := new(Stub_Expr, context.temp_allocator)
	// The leading `@` is the hole's first byte.
	node^ = Stub_Expr{hole_type = hole_type, fallback = fallback, has_fallback = has_fallback, line = at_tok.line, col = at_tok.col}
	return node, .None
}

// parse_paren_atom parses a parenthesized atom after the `(` is consumed: a
// grouping `(e)` that unwraps to its inner expression, or a tuple `(a, b, …)`
// (spec §02; §04 §1 — `(value, next_rng)`). The first element parses, then a
// comma decides: a comma opens the comma-list and the result is a Tuple_Expr;
// no comma means a plain grouping and the inner expression passes through. A
// trailing comma after the last element is accepted, mirroring lists. The
// no-record-brace context is lifted inside the parentheses (a record literal
// is valid there even within a match scrutinee).
parse_paren_atom :: proc(p: ^Parser, lparen: Token) -> (expr: Expr, err: Parse_Error) {
	saved := p.no_record_brace
	p.no_record_brace = false
	defer p.no_record_brace = saved
	first := parse_expression(p) or_return
	if peek_kind(p) != .Comma {
		// A single parenthesized expression is a grouping, not a tuple — it
		// passes through carrying its own inner-expr span, not the `(`.
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
	// A tuple anchors on the leading `(`, its first byte.
	node^ = Tuple_Expr{elements = elements[:], line = lparen.line, col = lparen.col}
	return node, .None
}

// parse_match parses `match scrutinee { pattern => expr … }` (spec §02
// §5). The match brace is a block context, so its arms are
// newline-separated (the lexer kept those newlines); a `,` is also a
// legal separator (Sep). Each arm body is a single expression.
parse_match :: proc(p: ^Parser, match_tok: Token) -> (expr: Expr, err: Parse_Error) {
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
	// The `match` keyword is the construct's first byte.
	node^ = Match_Expr{scrutinee = scrutinee, arms = arms[:], line = match_tok.line, col = match_tok.col}
	return node, .None
}

// parse_if_expr parses the value-producing conditional `if cond { then } else
// { else }` (spec §02 §5; grammar/fun.ebnf §15 IfExpr), with the leading `if`
// already consumed by parse_atom. The condition parses in the no-struct-literal
// context — a trailing `{` opens the consequent block, not a record literal off
// the condition — mirroring the match-scrutinee and if-statement rules. Each
// arm is a single value expression wrapped in a `{ … }` value-block; the `else`
// arm is REQUIRED in expression position (a missing `else` is .Missing_Else,
// never a silent fallback). The else arm is either a block or a chained `if`
// (`else if …`), so an else-if ladder nests through parse_atom by construction.
parse_if_expr :: proc(p: ^Parser, if_tok: Token) -> (expr: Expr, err: Parse_Error) {
	saved := p.no_record_brace
	p.no_record_brace = true
	cond := parse_expression(p) or_return
	p.no_record_brace = saved
	then_branch := parse_if_branch(p) or_return
	// The `else` arm is mandatory for the value form — the consequent's type
	// has no counterpart to unify against without it (spec §02 §5). A peek-reject:
	// p.pos points at the token standing where `else` should be, so anchor the
	// diagnostic on it (the missing-arm site); at end of input the zero token
	// leaves the span unstamped and parser_stop_span clamps to the last token.
	if peek_kind(p) != .Else {
		return nil, reject(p, peek_tok(p), .Missing_Else)
	}
	p.pos += 1
	// `else if …` chains as a nested If_Expr; a plain `else { … }` is a value
	// block. Both reach parse_atom (the if-expr arm), so the chain nests with
	// no special case here.
	else_branch: Expr
	if peek_kind(p) == .If {
		else_branch = parse_expression(p) or_return
	} else {
		else_branch = parse_if_branch(p) or_return
	}
	node := new(If_Expr, context.temp_allocator)
	// The `if` keyword is the construct's first byte; a chained `else if` nests
	// its OWN If_Expr through parse_expression, each anchored on its own `if`.
	node^ = If_Expr{cond = cond, then_branch = then_branch, else_branch = else_branch, line = if_tok.line, col = if_tok.col}
	return node, .None
}

// parse_if_branch parses one `{ expr }` value-block arm of an if-expression —
// a single value expression between braces, the same minimal value-block shape
// the lambda body and match-arm body use (spec §02 §5). Interior newlines are
// skipped so a multi-line arm `{\n expr \n}` parses, mirroring the lambda body.
parse_if_branch :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	// A value-block holds a single expression (spec §02 §5). A `return`/`let`
	// leading the branch is the statement-form-`if`-in-expression-position trip:
	// a lambda body `fn(acc, x){ if c { return v } return w }` parses its body as
	// this if-EXPRESSION, whose `{ return v }` branch then leads with `return`.
	// Name the verdict here (steering the author to the if-EXPRESSION rewrite)
	// rather than recursing into parse_expression and tripping a bare
	// Unexpected_Token on the statement keyword.
	if peek_kind(p) == .Return || peek_kind(p) == .Let {
		return nil, reject(p, peek_tok(p), .Statement_In_Value_Block)
	}
	value := parse_expression(p) or_return
	skip_newlines(p)
	expect(p, .R_Brace) or_return
	return value, .None
}

// parse_pattern parses the pattern set (spec §02 §5; grammar §13): wildcard
// `_`, a variant `Type::Variant`, a variant with payload binders
// `Type::Variant(a, b)`, a struct-payload field-pun `Type::Variant{f, …}`, or
// a tuple `(p, q, …)` of positional sub-patterns. A `(` head opens the tuple
// form; otherwise a `_` (lexed as a snake_case Ident) is the wildcard and an
// UPPER_IDENT head a variant. After the variant, a `(` opens positional
// binders and a `{` opens struct-payload field-pun binders.
parse_pattern :: proc(p: ^Parser) -> (pattern: Pattern, err: Parse_Error) {
	if peek_kind(p) == .L_Paren {
		return parse_tuple_pattern(p)
	}
	tok := expect(p, .Ident) or_return
	if tok.text == "_" {
		return Pattern{kind = .Wildcard}, .None
	}
	// A `true`/`false` head is a bool literal in pattern position, not a
	// mis-cased variant: Bool's two values are not a §02 §5 match domain (a
	// match dispatches over a closed enum/tuple), so steer the author to
	// `if`/`else` with the named verdict — branched AHEAD of the casing check,
	// since `true`/`false` lex as a snake_case Ident that the Wrong_Case rule
	// below would otherwise flag as casing rather than the real "Bool is not
	// matchable" fault.
	if tok.text == "true" || tok.text == "false" {
		return pattern, reject(p, tok, .Bool_Pattern_Unsupported)
	}
	// The remaining forms are variant patterns: an UPPER_IDENT enum type,
	// `::`, then an UPPER_IDENT variant (lexical-core.ebnf §2).
	if !is_upper_ident(tok.class) {
		return pattern, reject(p, tok, .Wrong_Case)
	}
	expect(p, .Colon_Colon) or_return
	variant := expect(p, .Ident) or_return
	if !is_upper_ident(variant.class) {
		return pattern, reject(p, variant, .Wrong_Case)
	}
	#partial switch peek_kind(p) {
	case .L_Paren:
		elements := parse_pattern_payload(p) or_return
		return Pattern{
			kind = .Variant_Binds,
			type_name = tok.text,
			variant = variant.text,
			elements = elements,
		}, .None
	case .L_Brace:
		binders := parse_struct_pattern_binders(p) or_return
		return Pattern{
			kind = .Struct_Binds,
			type_name = tok.text,
			variant = variant.text,
			binders = binders,
		}, .None
	}
	return Pattern{kind = .Bare_Variant, type_name = tok.text, variant = variant.text}, .None
}

// parse_struct_pattern_binders parses `{f, g}` — the struct-payload field-pun
// binders of a struct-payload variant pattern `Shape2::Box{size}` (spec §02
// §5; yard `box_size`). Each entry is a bare snake_case field name that binds
// a value of the same name (field-pun: the binder name equals the field it
// reads). Field names separate by `,` or newline, both legal (spec §02 §1).
parse_struct_pattern_binders :: proc(p: ^Parser) -> (binders: []string, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	list := make([dynamic]string, 0, 4, context.temp_allocator)
	skip_arm_separators(p)
	for peek_kind(p) == .Ident {
		name := expect(p, .Ident) or_return
		// A field-pun binder is a value name — snake_case (spec §02).
		if name.class != .Snake_Case {
			return nil, reject(p, name, .Wrong_Case)
		}
		append(&list, name.text)
		if peek_kind(p) == .Comma || peek_kind(p) == .Newline {
			skip_arm_separators(p)
		} else {
			break
		}
	}
	expect(p, .R_Brace) or_return
	return list[:], .None
}

// parse_pattern_payload parses a variant pattern's `( … )` payload (grammar/
// fun.ebnf §13: `VariantPat ::= '(' Pattern (',' Pattern)* ')'`): each position
// is a full sub-pattern, so a bare snake_case binder (`v` in Option::Some(v),
// `m` in AppMsg::Hud(m)) is a Bare_Binder and a nested variant (`HudMsg::Coin`
// in AppMsg::Hud(HudMsg::Coin)) is a Bare_Variant — the §21 §3 router's
// tagged-union destructure. Each position reuses parse_tuple_sub_pattern, the
// same position-parser the tuple form uses (a leading snake_case Ident is a
// binder, anything else a full pattern), so a nested pattern recurses by
// construction.
parse_pattern_payload :: proc(p: ^Parser) -> (elements: []Pattern, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	list := make([dynamic]Pattern, 0, 4, context.temp_allocator)
	for peek_kind(p) != .R_Paren {
		sub := parse_tuple_sub_pattern(p) or_return
		append(&list, sub)
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
		check_ident_case(p, tok, .Invalid) or_return
		node := new(Name_Expr, context.temp_allocator)
		node^ = Name_Expr{name = tok.text, class = tok.class, line = tok.line, col = tok.col}
		return node, .None
	}
	// The §08 §3 world read `all[T]`: the contextual name `all` followed by a
	// bracket is the one-token-lookahead atom (see All_Expr). `all` stays a
	// legal value name everywhere else — only the immediate `[` selects.
	if tok.text == "all" && following == .L_Bracket {
		return parse_all_tail(p, tok)
	}
	check_ident_case(p, tok, following) or_return
	#partial switch following {
	case .Colon_Colon:
		p.pos += 1
		variant := expect(p, .Ident) or_return
		// Enum variants are UPPER_IDENT (spec §02; lexical-core.ebnf §2),
		// so a single-capital variant (Key::W, PlayerId::P1) is valid.
		if !is_upper_ident(variant.class) {
			return nil, reject(p, variant, .Wrong_Case)
		}
		node := new(Variant_Expr, context.temp_allocator)
		// The enum type name is the variant expression's first byte.
		node^ = Variant_Expr{type_name = tok.text, variant = variant.text, line = tok.line, col = tok.col}
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
		return parse_record_tail(p, tok)
	}
	node := new(Name_Expr, context.temp_allocator)
	node^ = Name_Expr{name = tok.text, class = tok.class, line = tok.line, col = tok.col}
	return node, .None
}

// parse_all_tail parses the `[T]` tail of the §08 §3 world read `all[T]`,
// with the `all` Ident already consumed by parse_name_atom. T is a thing TYPE
// name — an UPPER_IDENT (lexical-core.ebnf §2), so a lowercase or mixed-case
// head is the parser-wide Wrong_Case verdict; whether T names a declared
// thing is the typechecker's membership rule (all_check), not grammar.
parse_all_tail :: proc(p: ^Parser, all_tok: Token) -> (expr: Expr, err: Parse_Error) {
	expect(p, .L_Bracket) or_return
	thing := expect(p, .Ident) or_return
	if !is_upper_ident(thing.class) {
		return nil, reject(p, thing, .Wrong_Case)
	}
	expect(p, .R_Bracket) or_return
	node := new(All_Expr, context.temp_allocator)
	// The `all` name is the read's first byte.
	node^ = All_Expr{thing = thing.text, line = all_tok.line, col = all_tok.col}
	return node, .None
}

// parse_record_tail parses `{ field: expr, … }` after the constructor
// name and wraps it as a Record_Expr. The constructor-name token anchors the
// span — `Vec2{…}` reports `Vec2`, its first byte.
parse_record_tail :: proc(p: ^Parser, name_tok: Token) -> (expr: Expr, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	fields := parse_record_fields(p) or_return
	node := new(Record_Expr, context.temp_allocator)
	node^ = Record_Expr{type_name = name_tok.text, fields = fields[:], line = name_tok.line, col = name_tok.col}
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
			return nil, reject(p, fname, .Wrong_Case)
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

parse_list_tail :: proc(p: ^Parser, lbracket: Token) -> (expr: Expr, err: Parse_Error) {
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
	// The leading `[` is the list's first byte.
	node^ = List_Expr{elements = elements[:], line = lbracket.line, col = lbracket.col}
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

parse_lambda :: proc(p: ^Parser, fn_tok: Token) -> (expr: Expr, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	params := make([dynamic]string, 0, 4, context.temp_allocator)
	for peek_kind(p) == .Ident {
		param := advance(p) or_return
		// Parameters are value names — snake_case (spec §02).
		if param.class != .Snake_Case {
			return nil, reject(p, param, .Wrong_Case)
		}
		append(&params, param.text)
		if peek_kind(p) == .Comma {
			p.pos += 1
		}
	}
	expect(p, .R_Paren) or_return
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	// The lambda body is a SINGLE STATEMENT (spec §02 §5): one expression (implicit
	// return), an if-expression, or a `return` — never a multi-statement block.
	// A leading `let` is the multi-statement case by construction: a `let` binds a
	// name the body must then USE, so it can never be the one statement. Name the
	// verdict here at the body seam so the author lifts the locals into a named
	// helper `fn` rather than tripping a bare Unexpected_Token. The offender is the
	// `let` keyword in hand.
	if peek_kind(p) == .Let {
		return nil, reject(p, peek_tok(p), .Lambda_Body_Multi_Statement)
	}
	// `return` is optional sugar: forms 1 (bare expression, implicit return) and 3
	// (`return <expr>`) collapse — consume an optional leading `return`, then parse
	// the one body expression. The expression parser already handles the
	// if-expression atom (form 2) and the bare-expression and `return`-stripped
	// forms, so all three single-statement body shapes set `body` to the same
	// single Expr the evaluators run as an expression (no Return-specific node).
	if peek_kind(p) == .Return {
		expect(p, .Return) or_return
	}
	body := parse_expression(p) or_return
	skip_newlines(p)
	// One statement is consumed. Any token before the closing `}` other than the
	// brace is a SECOND statement — the multi-statement / `let`-then-`return` body
	// the spec forbids. Name the verdict on that second statement's lead token; the
	// helper-fn remedy (which CAN hold a `let` sequence) is the fix.
	if peek_kind(p) != .R_Brace {
		return nil, reject(p, peek_tok(p), .Lambda_Body_Multi_Statement)
	}
	expect(p, .R_Brace) or_return
	node := new(Lambda_Expr, context.temp_allocator)
	// The `fn` keyword is the lambda's first byte.
	node^ = Lambda_Expr{params = params[:], body = body, line = fn_tok.line, col = fn_tok.col}
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
