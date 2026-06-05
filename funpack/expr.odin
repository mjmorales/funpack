// The Pratt expression cascade over the golden-file surface (spec §02).
// One binding-power table orders the whole ladder, low → high:
// or → and → == != → < <= > >= → + - → * / % → unary (not, -), with the
// call/member postfix loop binding above unary and atoms at the bottom.
// `and`/`or`/`not` are word operators carried as Ident tokens, so the
// table keys them by text. Out of the golden surface — `with`, `match`,
// `if`, indexing `xs[i]`, and ranges — have no production here and
// parse as errors.
package funpack

Expr :: union {
	^Int_Lit_Expr,
	^Fixed_Lit_Expr,
	^Name_Expr,
	^Call_Expr,
	^Member_Expr,
	^Variant_Expr,
	^Record_Expr,
	^List_Expr,
	^Lambda_Expr,
	^Unary_Expr,
	^Binary_Expr,
	^Match_Expr,
}

Int_Lit_Expr :: struct {
	value: i64,
}

Fixed_Lit_Expr :: struct {
	bits: Fixed,
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

Variant_Expr :: struct {
	type_name:   string,
	variant:     string,
	payload:     []Expr,
	has_payload: bool, // distinguishes Option::Some() from Option::None
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
// over Option/enum variants needs only these three. Struct-field-pun and
// tuple patterns are deliberately out of this minimal scope.
Pattern_Kind :: enum {
	Wildcard,      // `_`
	Bare_Variant,  // `Dir::Up`
	Variant_Binds, // `Option::Some(v)` — payload positions bind value names
}

// Pattern is a match-arm pattern. type_name/variant are set for the two
// variant forms; binders holds the payload binder names for the
// Variant_Binds form (empty otherwise).
Pattern :: struct {
	kind:      Pattern_Kind,
	type_name: string,   // variant forms: the enum type (`Option`, `Dir`)
	variant:   string,   // variant forms: the variant (`Some`, `Up`)
	binders:   []string, // Variant_Binds: payload binder names
}

// Match_Arm is one `pattern => body` arm; the body is a single
// expression, mirroring the lambda single-return shape (block-bodied
// arms are out of this minimal scope).
Match_Arm :: struct {
	pattern: Pattern,
	body:    Expr,
}

// Match_Expr is the structural match node (spec §02 §5): a scrutinee and
// its newline-separated arms. It parses to AST only — stage_typecheck
// contains it as Unsupported_Expr, with no evaluation path.
Match_Expr :: struct {
	scrutinee: Expr,
	arms:      []Match_Arm,
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
	return parse_postfix(p)
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
	case .L_Paren:
		// A parenthesized sub-expression re-enters normal parsing: a
		// record literal inside it is valid even within a match scrutinee.
		saved := p.no_record_brace
		p.no_record_brace = false
		inner := parse_expression(p) or_return
		expect(p, .R_Paren) or_return
		p.no_record_brace = saved
		return inner, .None
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
// §13): wildcard `_`, a variant `Type::Variant`, or a variant with
// payload binders `Type::Variant(a, b)`. A `_` lexes as a snake_case
// Ident, so the wildcard is recognized by text.
parse_pattern :: proc(p: ^Parser) -> (pattern: Pattern, err: Parse_Error) {
	tok := expect(p, .Ident) or_return
	if tok.text == "_" {
		return Pattern{kind = .Wildcard}, .None
	}
	// The two remaining forms are variant patterns: an UpperCamel enum
	// type, `::`, then an UpperCamel variant.
	if tok.class != .Upper_Camel {
		return pattern, .Wrong_Case
	}
	expect(p, .Colon_Colon) or_return
	variant := expect(p, .Ident) or_return
	if variant.class != .Upper_Camel {
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
		// Enum variants are UpperCamel (spec §02).
		if variant.class != .Upper_Camel {
			return nil, .Wrong_Case
		}
		payload: []Expr
		has_payload := false
		if peek_kind(p) == .L_Paren {
			payload = parse_call_args(p) or_return
			has_payload = true
		}
		node := new(Variant_Expr, context.temp_allocator)
		node^ = Variant_Expr{type_name = tok.text, variant = variant.text, payload = payload, has_payload = has_payload}
		return node, .None
	case .L_Brace:
		return parse_record_tail(p, tok.text)
	}
	node := new(Name_Expr, context.temp_allocator)
	node^ = Name_Expr{name = tok.text, class = tok.class}
	return node, .None
}

// parse_record_tail parses `{ field: expr, … }` after the constructor
// name. The lexer already dropped interior newlines (record braces are
// layout context), so `,` is the only separator seen here.
parse_record_tail :: proc(p: ^Parser, type_name: string) -> (expr: Expr, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	fields := make([dynamic]Record_Field, 0, 4, context.temp_allocator)
	for peek_kind(p) == .Ident {
		fname := advance(p) or_return
		// Record fields are value names — snake_case (spec §02).
		if fname.class != .Snake_Case {
			return nil, .Wrong_Case
		}
		expect(p, .Colon) or_return
		value := parse_expression(p) or_return
		append(&fields, Record_Field{name = fname.text, value = value})
		if peek_kind(p) == .Comma {
			p.pos += 1
		}
	}
	expect(p, .R_Brace) or_return
	node := new(Record_Expr, context.temp_allocator)
	node^ = Record_Expr{type_name = type_name, fields = fields[:]}
	return node, .None
}

parse_list_tail :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	saved := p.no_record_brace
	p.no_record_brace = false
	defer p.no_record_brace = saved
	elements := make([dynamic]Expr, 0, 4, context.temp_allocator)
	for peek_kind(p) != .R_Bracket {
		element := parse_expression(p) or_return
		append(&elements, element)
		if peek_kind(p) == .Comma {
			p.pos += 1
		} else {
			break
		}
	}
	expect(p, .R_Bracket) or_return
	node := new(List_Expr, context.temp_allocator)
	node^ = List_Expr{elements = elements[:]}
	return node, .None
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
