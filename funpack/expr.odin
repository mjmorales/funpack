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

Member_Expr :: struct {
	receiver:    Expr,
	member:      string,
	class:       Ident_Class,
	line:        int,
	col:         int,
	member_line: int,
	member_col:  int,
}

Variant_Expr :: struct {
	type_name:   string,
	variant:     string,
	payload:     []Expr,
	fields:      []Record_Field,
	has_payload: bool,
	has_fields:  bool,
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

Tuple_Expr :: struct {
	elements: []Expr,
	line:     int,
	col:      int,
}

Lambda_Expr :: struct {
	params: []string,
	body:   Expr,
	line:   int,
	col:    int,
}

Unary_Expr :: struct {
	op:      Token,
	operand: Expr,
	line:    int,
	col:     int,
}

Binary_Expr :: struct {
	op:   Token,
	lhs:  Expr,
	rhs:  Expr,
	line: int,
	col:  int,
}

Pattern_Kind :: enum {
	Wildcard,
	Bare_Variant,
	Variant_Binds,
	Struct_Binds,
	Tuple,
	Bare_Binder,
}

Pattern :: struct {
	kind:      Pattern_Kind,
	type_name: string,
	variant:   string,
	binders:   []string,
	elements:  []Pattern,
}

Match_Arm :: struct {
	pattern: Pattern,
	body:    Expr,
}

Match_Expr :: struct {
	scrutinee: Expr,
	arms:      []Match_Arm,
	line:      int,
	col:       int,
}

If_Expr :: struct {
	cond:        Expr,
	then_branch: Expr,
	else_branch: Expr,
	line:        int,
	col:         int,
}

Stub_Expr :: struct {
	hole_type:    Type_Ref,
	fallback:     Expr,
	has_fallback: bool,
	line:         int,
	col:          int,
}

All_Expr :: struct {
	thing: string,
	line:  int,
	col:   int,
}

With_Expr :: struct {
	base:   Expr,
	fields: []Record_Field,
	line:   int,
	col:    int,
}

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

leading_binary_op :: proc(tok: Token) -> bool {
	if tok.kind == .Minus {
		return false
	}
	if tok.kind == .Ident && tok.text == "not" {
		return false
	}
	return infix_power(tok) != .None
}

parse_expression :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	return parse_binary(p, .Or)
}

parse_binary :: proc(p: ^Parser, min_power: Binding_Power) -> (expr: Expr, err: Parse_Error) {
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
		rhs := parse_binary(p, Binding_Power(int(power) + 1)) or_return
		node := new(Binary_Expr, context.temp_allocator)
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
		node^ = Unary_Expr{op = tok, operand = operand, line = tok.line, col = tok.col}
		return node, .None
	}
	return parse_with(p)
}

parse_with :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	expr = parse_postfix(p) or_return
	for peek_kind(p) == .With {
		p.pos += 1
		saved := p.no_record_brace
		p.no_record_brace = false
		fields := parse_with_fields(p) or_return
		p.no_record_brace = saved
		node := new(With_Expr, context.temp_allocator)
		base_line, base_col := expr_span(expr)
		node^ = With_Expr{base = expr, fields = fields, line = base_line, col = base_col}
		expr = node
	}
	return expr, .None
}

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
		node := new(String_Lit_Expr, context.temp_allocator)
		node^ = String_Lit_Expr{text = tok.text, line = tok.line, col = tok.col}
		return node, .None
	case .L_Paren:
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
	return nil, reject(p, tok, .Unexpected_Token)
}

parse_stub_atom :: proc(p: ^Parser, at_tok: Token) -> (expr: Expr, err: Parse_Error) {
	hole_type, fallback, has_fallback := parse_stub_parts(p) or_return
	node := new(Stub_Expr, context.temp_allocator)
	node^ = Stub_Expr{hole_type = hole_type, fallback = fallback, has_fallback = has_fallback, line = at_tok.line, col = at_tok.col}
	return node, .None
}

parse_paren_atom :: proc(p: ^Parser, lparen: Token) -> (expr: Expr, err: Parse_Error) {
	saved := p.no_record_brace
	p.no_record_brace = false
	defer p.no_record_brace = saved
	first := parse_expression(p) or_return
	if peek_kind(p) != .Comma {
		expect(p, .R_Paren) or_return
		return first, .None
	}
	elements := make([dynamic]Expr, 0, 4, context.temp_allocator)
	append(&elements, first)
	for peek_kind(p) == .Comma {
		p.pos += 1
		if peek_kind(p) == .R_Paren {
			break
		}
		element := parse_expression(p) or_return
		append(&elements, element)
	}
	expect(p, .R_Paren) or_return
	node := new(Tuple_Expr, context.temp_allocator)
	node^ = Tuple_Expr{elements = elements[:], line = lparen.line, col = lparen.col}
	return node, .None
}

parse_match :: proc(p: ^Parser, match_tok: Token) -> (expr: Expr, err: Parse_Error) {
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
			if peek_kind(p) != .Newline && peek_kind(p) != .Comma {
				return nil, .Unexpected_Token
			}
			skip_arm_separators(p)
		}
	}
	expect(p, .R_Brace) or_return
	node := new(Match_Expr, context.temp_allocator)
	node^ = Match_Expr{scrutinee = scrutinee, arms = arms[:], line = match_tok.line, col = match_tok.col}
	return node, .None
}

parse_if_expr :: proc(p: ^Parser, if_tok: Token) -> (expr: Expr, err: Parse_Error) {
	saved := p.no_record_brace
	p.no_record_brace = true
	cond := parse_expression(p) or_return
	p.no_record_brace = saved
	then_branch := parse_if_branch(p) or_return
	if peek_kind(p) != .Else {
		return nil, reject(p, peek_tok(p), .Missing_Else)
	}
	p.pos += 1
	else_branch: Expr
	if peek_kind(p) == .If {
		else_branch = parse_expression(p) or_return
	} else {
		else_branch = parse_if_branch(p) or_return
	}
	node := new(If_Expr, context.temp_allocator)
	node^ = If_Expr{cond = cond, then_branch = then_branch, else_branch = else_branch, line = if_tok.line, col = if_tok.col}
	return node, .None
}

parse_if_branch :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	if peek_kind(p) == .Return || peek_kind(p) == .Let {
		return nil, reject(p, peek_tok(p), .Statement_In_Value_Block)
	}
	value := parse_expression(p) or_return
	skip_newlines(p)
	expect(p, .R_Brace) or_return
	return value, .None
}

parse_pattern :: proc(p: ^Parser) -> (pattern: Pattern, err: Parse_Error) {
	if peek_kind(p) == .L_Paren {
		return parse_tuple_pattern(p)
	}
	tok := expect(p, .Ident) or_return
	if tok.text == "_" {
		return Pattern{kind = .Wildcard}, .None
	}
	if tok.text == "true" || tok.text == "false" {
		return pattern, reject(p, tok, .Bool_Pattern_Unsupported)
	}
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

parse_struct_pattern_binders :: proc(p: ^Parser) -> (binders: []string, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	list := make([dynamic]string, 0, 4, context.temp_allocator)
	skip_arm_separators(p)
	for peek_kind(p) == .Ident {
		name := expect(p, .Ident) or_return
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

parse_tuple_sub_pattern :: proc(p: ^Parser) -> (pattern: Pattern, err: Parse_Error) {
	if peek_kind(p) == .Ident && is_snake_binder(p.tokens[p.pos]) {
		name := advance(p) or_return
		binders := make([]string, 1, context.temp_allocator)
		binders[0] = name.text
		return Pattern{kind = .Bare_Binder, binders = binders}, .None
	}
	return parse_pattern(p)
}

is_snake_binder :: proc(tok: Token) -> bool {
	return tok.kind == .Ident && tok.class == .Snake_Case && tok.text != "_"
}

skip_arm_separators :: proc(p: ^Parser) {
	for peek_kind(p) == .Newline || peek_kind(p) == .Comma {
		p.pos += 1
	}
}

parse_name_atom :: proc(p: ^Parser, tok: Token) -> (expr: Expr, err: Parse_Error) {
	following := peek_kind(p)
	if p.no_record_brace && following == .L_Brace {
		check_ident_case(p, tok, .Invalid) or_return
		node := new(Name_Expr, context.temp_allocator)
		node^ = Name_Expr{name = tok.text, class = tok.class, line = tok.line, col = tok.col}
		return node, .None
	}
	if tok.text == "all" && following == .L_Bracket {
		return parse_all_tail(p, tok)
	}
	check_ident_case(p, tok, following) or_return
	#partial switch following {
	case .Colon_Colon:
		p.pos += 1
		variant := expect(p, .Ident) or_return
		if !is_upper_ident(variant.class) {
			return nil, reject(p, variant, .Wrong_Case)
		}
		node := new(Variant_Expr, context.temp_allocator)
		node^ = Variant_Expr{type_name = tok.text, variant = variant.text, line = tok.line, col = tok.col}
		#partial switch peek_kind(p) {
		case .L_Paren:
			node.payload = parse_call_args(p) or_return
			node.has_payload = true
		case .L_Brace:
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

parse_all_tail :: proc(p: ^Parser, all_tok: Token) -> (expr: Expr, err: Parse_Error) {
	expect(p, .L_Bracket) or_return
	thing := expect(p, .Ident) or_return
	if !is_upper_ident(thing.class) {
		return nil, reject(p, thing, .Wrong_Case)
	}
	expect(p, .R_Bracket) or_return
	node := new(All_Expr, context.temp_allocator)
	node^ = All_Expr{thing = thing.text, line = all_tok.line, col = all_tok.col}
	return node, .None
}

parse_record_tail :: proc(p: ^Parser, name_tok: Token) -> (expr: Expr, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	fields := parse_record_fields(p) or_return
	node := new(Record_Expr, context.temp_allocator)
	node^ = Record_Expr{type_name = name_tok.text, fields = fields[:], line = name_tok.line, col = name_tok.col}
	return node, .None
}

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
	node^ = List_Expr{elements = elements[:], line = lbracket.line, col = lbracket.col}
	return node, .None
}

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
	if peek_kind(p) == .Let {
		return nil, reject(p, peek_tok(p), .Lambda_Body_Multi_Statement)
	}
	if peek_kind(p) == .Return {
		expect(p, .Return) or_return
	}
	body := parse_expression(p) or_return
	skip_newlines(p)
	if peek_kind(p) != .R_Brace {
		return nil, reject(p, peek_tok(p), .Lambda_Body_Multi_Statement)
	}
	expect(p, .R_Brace) or_return
	node := new(Lambda_Expr, context.temp_allocator)
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
