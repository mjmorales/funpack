package funpack

Fpm_Parse_Error :: Sub_Parse_Error

Fpm_Expr :: union {
	^Fpm_Int_Lit,
	^Fpm_Float_Lit,
	^Fpm_String_Lit,
	^Fpm_Name,
	^Fpm_Member,
	^Fpm_Call,
	^Fpm_Unary,
	^Fpm_Binary,
	^Fpm_Range,
}

Fpm_Int_Lit :: struct {
	value: i64,
}

Fpm_Float_Lit :: struct {
	value: f64,
}

Fpm_String_Lit :: struct {
	text: string,
}

Fpm_Name :: struct {
	name:       string,
	ident_case: Fpm_Ident_Case,
}

Fpm_Member :: struct {
	receiver: Fpm_Expr,
	member:   string,
}

Fpm_Call :: struct {
	callee: Fpm_Expr,
	args:   []Fpm_Arg,
}

Fpm_Arg :: struct {
	label:   string,
	labeled: bool,
	value:   Fpm_Expr,
}

Fpm_Unary :: struct {
	op:      Fpm_Token_Kind,
	operand: Fpm_Expr,
}

Fpm_Binary :: struct {
	op:  Fpm_Token_Kind,
	lhs: Fpm_Expr,
	rhs: Fpm_Expr,
}

Fpm_Range :: struct {
	lo: Fpm_Expr,
	hi: Fpm_Expr,
}

Fpm_Solid :: union {
	^Fpm_Primitive,
	^Fpm_Transform,
	^Fpm_Boolean,
}

Fpm_Prim_Kind :: enum {
	Capsule,
	Sphere,
	Box,
	Cyl,
}

Fpm_Primitive :: struct {
	kind: Fpm_Prim_Kind,
	dims: []f64,
}

Fpm_Transform_Kind :: enum {
	Up,
	Down,
	At,
	Rotate,
	Scale,
}

Fpm_Transform :: struct {
	kind:  Fpm_Transform_Kind,
	inner: Fpm_Solid,
	scale: f64,
}

Fpm_Bool_Kind :: enum {
	Union,
	Difference,
	Intersect,
}

Fpm_Boolean :: struct {
	kind:     Fpm_Bool_Kind,
	operands: []Fpm_Solid,
}

Fpm_Param :: struct {
	name:        string,
	type:        string,
	default:     Fpm_Expr,
	has_default: bool,
}

Fpm_Fn :: struct {
	name:   string,
	params: []Fpm_Param,
	ret:    string,
	body:   []Fpm_Stmt,
	solid:  Fpm_Solid,
}

Fpm_Stmt :: union {
	Fpm_Let,
	Fpm_Return,
	Fpm_For,
	Fpm_Assign,
	Fpm_Expr_Stmt,
}

Fpm_Let :: struct {
	name:  string,
	type:  string,
	value: Fpm_Expr,
}

Fpm_Return :: struct {
	value: Fpm_Expr,
}

Fpm_For :: struct {
	binder:   string,
	iterable: Fpm_Expr,
	body:     []Fpm_Stmt,
}

Fpm_Assign :: struct {
	path:  []string,
	value: Fpm_Expr,
}

Fpm_Expr_Stmt :: struct {
	value: Fpm_Expr,
}

Fpm_Bind_Kind :: enum {
	Emit,
	Anchor,
	Socket,
	Material,
	Collide,
	Part,
}

Fpm_Bind :: struct {
	kind:  Fpm_Bind_Kind,
	name:  string,
	bone:  string,
	value: Fpm_Expr,
	solid: Fpm_Solid,
}

Fpm_Mirror :: struct {
	from: string,
	to:   string,
}

Fpm_Unit :: struct {
	name:          string,
	is_rig:        bool,
	skeleton:      string,
	params:        []Fpm_Param,
	fns:           []Fpm_Fn,
	binds:         []Fpm_Bind,
	mirrors:       []Fpm_Mirror,
	has_clearance: bool,
	clearance:     f64,
}

Fpm_Parser :: Cursor(Fpm_Token, Fpm_Token_Kind)

fpm_parse :: proc(tokens: []Fpm_Token) -> (unit: Fpm_Unit, err: Fpm_Parse_Error) {
	p := Fpm_Parser{tokens = tokens}
	fpm_skip_newlines(&p)
	#partial switch cursor_peek_kind(&p) {
	case .Model:
		return fpm_parse_block(&p, is_rig = false)
	case .Rig:
		return fpm_parse_block(&p, is_rig = true)
	}
	return unit, .Unexpected_Token
}

fpm_parse_block :: proc(p: ^Fpm_Parser, is_rig: bool) -> (unit: Fpm_Unit, err: Fpm_Parse_Error) {
	cursor_advance(p) or_return
	name := fpm_expect_upper(p) or_return
	fpm_expect(p, .L_Brace) or_return
	unit.name = name
	unit.is_rig = is_rig
	params := make([dynamic]Fpm_Param, 0, 8, context.temp_allocator)
	fns := make([dynamic]Fpm_Fn, 0, 8, context.temp_allocator)
	binds := make([dynamic]Fpm_Bind, 0, 8, context.temp_allocator)
	mirrors := make([dynamic]Fpm_Mirror, 0, 2, context.temp_allocator)
	fpm_skip_seps(p)
	for cursor_peek_kind(p) != .R_Brace && !cursor_at_end(p) {
		#partial switch cursor_peek_kind(p) {
		case .Param:
			node := fpm_parse_param(p) or_return
			append(&params, node)
		case .Fn:
			node := fpm_parse_fn(p) or_return
			append(&fns, node)
		case .Emit:
			node := fpm_parse_emit(p) or_return
			append(&binds, node)
		case .Anchor, .Socket, .Material, .Collide:
			node := fpm_parse_named_bind(p) or_return
			append(&binds, node)
		case .Skeleton:
			topology := fpm_parse_skeleton(p) or_return
			unit.skeleton = topology
		case .Part:
			node := fpm_parse_part(p) or_return
			append(&binds, node)
		case .Mirror:
			node := fpm_parse_mirror(p) or_return
			append(&mirrors, node)
		case .Clearance:
			value := fpm_parse_clearance(p) or_return
			unit.has_clearance = true
			unit.clearance = value
		case:
			return unit, .Unexpected_Token
		}
		fpm_skip_seps(p)
	}
	fpm_expect(p, .R_Brace) or_return
	unit.params = params[:]
	unit.fns = fns[:]
	unit.binds = binds[:]
	unit.mirrors = mirrors[:]
	return unit, .None
}

fpm_parse_param :: proc(p: ^Fpm_Parser) -> (node: Fpm_Param, err: Fpm_Parse_Error) {
	fpm_expect(p, .Param) or_return
	name := fpm_expect_lower(p) or_return
	fpm_expect(p, .Colon) or_return
	type := fpm_parse_type(p) or_return
	node = Fpm_Param{name = name, type = type}
	if cursor_peek_kind(p) == .Eq {
		cursor_advance(p) or_return
		node.default = fpm_parse_expression(p) or_return
		node.has_default = true
	}
	fpm_terminate(p) or_return
	return node, .None
}

fpm_parse_fn :: proc(p: ^Fpm_Parser) -> (node: Fpm_Fn, err: Fpm_Parse_Error) {
	fpm_expect(p, .Fn) or_return
	name := fpm_expect_lower(p) or_return
	fpm_expect(p, .L_Paren) or_return
	params := make([dynamic]Fpm_Param, 0, 4, context.temp_allocator)
	for cursor_peek_kind(p) != .R_Paren && !cursor_at_end(p) {
		pname := fpm_expect_lower(p) or_return
		fpm_expect(p, .Colon) or_return
		ptype := fpm_parse_type(p) or_return
		append(&params, Fpm_Param{name = pname, type = ptype})
		if cursor_peek_kind(p) == .Comma {
			cursor_advance(p) or_return
		}
	}
	fpm_expect(p, .R_Paren) or_return
	fpm_expect(p, .Arrow) or_return
	ret := fpm_parse_type(p) or_return
	body := fpm_parse_block_body(p) or_return
	node = Fpm_Fn{name = name, params = params[:], ret = ret, body = body}
	node.solid = fpm_return_solid(body)
	return node, .None
}

fpm_return_solid :: proc(body: []Fpm_Stmt) -> Fpm_Solid {
	for stmt in body {
		if ret, is_ret := stmt.(Fpm_Return); is_ret {
			return fpm_solid_of_expr(ret.value)
		}
	}
	return nil
}

fpm_parse_block_body :: proc(p: ^Fpm_Parser) -> (body: []Fpm_Stmt, err: Fpm_Parse_Error) {
	fpm_expect(p, .L_Brace) or_return
	stmts := make([dynamic]Fpm_Stmt, 0, 8, context.temp_allocator)
	fpm_skip_seps(p)
	for cursor_peek_kind(p) != .R_Brace && !cursor_at_end(p) {
		stmt := fpm_parse_stmt(p) or_return
		append(&stmts, stmt)
		fpm_skip_seps(p)
	}
	fpm_expect(p, .R_Brace) or_return
	return stmts[:], .None
}

fpm_parse_stmt :: proc(p: ^Fpm_Parser) -> (stmt: Fpm_Stmt, err: Fpm_Parse_Error) {
	#partial switch cursor_peek_kind(p) {
	case .Let:
		return fpm_parse_let(p)
	case .Return:
		cursor_advance(p) or_return
		value := fpm_parse_expression(p) or_return
		fpm_terminate(p) or_return
		return Fpm_Return{value = value}, .None
	case .For:
		return fpm_parse_for(p)
	}
	expr := fpm_parse_expression(p) or_return
	if cursor_peek_kind(p) == .Eq {
		path, ok := fpm_lvalue_path(expr)
		if !ok {
			return stmt, .Unexpected_Token
		}
		cursor_advance(p) or_return
		value := fpm_parse_expression(p) or_return
		fpm_terminate(p) or_return
		return Fpm_Assign{path = path, value = value}, .None
	}
	fpm_terminate(p) or_return
	return Fpm_Expr_Stmt{value = expr}, .None
}

fpm_lvalue_path :: proc(expr: Fpm_Expr) -> (path: []string, ok: bool) {
	segs := make([dynamic]string, 0, 4, context.temp_allocator)
	cursor := expr
	for {
		switch e in cursor {
		case ^Fpm_Name:
			append(&segs, e.name)
			reversed := make([]string, len(segs), context.temp_allocator)
			for i in 0 ..< len(segs) {
				reversed[i] = segs[len(segs) - 1 - i]
			}
			return reversed, true
		case ^Fpm_Member:
			append(&segs, e.member)
			cursor = e.receiver
		case ^Fpm_Int_Lit, ^Fpm_Float_Lit, ^Fpm_String_Lit, ^Fpm_Call, ^Fpm_Unary, ^Fpm_Binary, ^Fpm_Range:
			return nil, false
		case nil:
			return nil, false
		}
	}
}

fpm_parse_let :: proc(p: ^Fpm_Parser) -> (stmt: Fpm_Stmt, err: Fpm_Parse_Error) {
	fpm_expect(p, .Let) or_return
	name := fpm_expect_lower(p) or_return
	type := ""
	if cursor_peek_kind(p) == .Colon {
		cursor_advance(p) or_return
		type = fpm_parse_type(p) or_return
	}
	fpm_expect(p, .Eq) or_return
	value := fpm_parse_expression(p) or_return
	fpm_terminate(p) or_return
	return Fpm_Let{name = name, type = type, value = value}, .None
}

fpm_parse_for :: proc(p: ^Fpm_Parser) -> (stmt: Fpm_Stmt, err: Fpm_Parse_Error) {
	fpm_expect(p, .For) or_return
	binder := fpm_expect_lower(p) or_return
	fpm_expect(p, .In) or_return
	iterable := fpm_parse_expression(p) or_return
	body := fpm_parse_block_body(p) or_return
	return Fpm_For{binder = binder, iterable = iterable, body = body}, .None
}

fpm_parse_emit :: proc(p: ^Fpm_Parser) -> (node: Fpm_Bind, err: Fpm_Parse_Error) {
	fpm_expect(p, .Emit) or_return
	value := fpm_parse_expression(p) or_return
	fpm_terminate(p) or_return
	return Fpm_Bind{kind = .Emit, value = value, solid = fpm_solid_of_expr(value)}, .None
}

fpm_parse_named_bind :: proc(p: ^Fpm_Parser) -> (node: Fpm_Bind, err: Fpm_Parse_Error) {
	kw := cursor_advance(p) or_return
	kind: Fpm_Bind_Kind
	#partial switch kw.kind {
	case .Anchor:
		kind = .Anchor
	case .Socket:
		kind = .Socket
	case .Material:
		kind = .Material
	case .Collide:
		kind = .Collide
	case:
		return node, .Unexpected_Token
	}
	name := fpm_expect_lower(p) or_return
	fpm_expect(p, .Eq) or_return
	value := fpm_parse_expression(p) or_return
	fpm_terminate(p) or_return
	return Fpm_Bind{kind = kind, name = name, value = value, solid = fpm_solid_of_expr(value)}, .None
}

fpm_parse_part :: proc(p: ^Fpm_Parser) -> (node: Fpm_Bind, err: Fpm_Parse_Error) {
	fpm_expect(p, .Part) or_return
	name := fpm_expect_lower(p) or_return
	fpm_expect(p, .At) or_return
	bone := fpm_expect_upper(p) or_return
	fpm_expect(p, .Eq) or_return
	value := fpm_parse_expression(p) or_return
	fpm_terminate(p) or_return
	return Fpm_Bind{kind = .Part, name = name, bone = bone, value = value, solid = fpm_solid_of_expr(value)}, .None
}

fpm_parse_skeleton :: proc(p: ^Fpm_Parser) -> (topology: string, err: Fpm_Parse_Error) {
	fpm_expect(p, .Skeleton) or_return
	fpm_expect(p, .Colon) or_return
	name := fpm_expect_lower(p) or_return
	fpm_terminate(p) or_return
	return name, .None
}

fpm_parse_mirror :: proc(p: ^Fpm_Parser) -> (node: Fpm_Mirror, err: Fpm_Parse_Error) {
	fpm_expect(p, .Mirror) or_return
	from := fpm_expect_upper(p) or_return
	fpm_expect(p, .Arrow) or_return
	to := fpm_expect_upper(p) or_return
	fpm_terminate(p) or_return
	return Fpm_Mirror{from = from, to = to}, .None
}

fpm_parse_clearance :: proc(p: ^Fpm_Parser) -> (value: f64, err: Fpm_Parse_Error) {
	fpm_expect(p, .Clearance) or_return
	num := fpm_parse_unary(p) or_return
	v, ok := fpm_eval_number(num)
	if !ok {
		return 0, .Unexpected_Token
	}
	fpm_terminate(p) or_return
	return v, .None
}

fpm_parse_type :: proc(p: ^Fpm_Parser) -> (name: string, err: Fpm_Parse_Error) {
	if cursor_peek_kind(p) == .L_Bracket {
		cursor_advance(p) or_return
		fpm_parse_type(p) or_return
		fpm_expect(p, .R_Bracket) or_return
		return "[]", .None
	}
	head := fpm_expect_upper(p) or_return
	if cursor_peek_kind(p) == .L_Bracket {
		cursor_advance(p) or_return
		fpm_parse_type(p) or_return
		for cursor_peek_kind(p) == .Comma {
			cursor_advance(p) or_return
			fpm_parse_type(p) or_return
		}
		fpm_expect(p, .R_Bracket) or_return
	}
	return head, .None
}

fpm_parse_expression :: proc(p: ^Fpm_Parser) -> (expr: Fpm_Expr, err: Fpm_Parse_Error) {
	lhs := fpm_parse_add(p) or_return
	if cursor_peek_kind(p) == .Dot_Dot {
		cursor_advance(p) or_return
		hi := fpm_parse_add(p) or_return
		node := new(Fpm_Range, context.temp_allocator)
		node^ = Fpm_Range{lo = lhs, hi = hi}
		return node, .None
	}
	return lhs, .None
}

fpm_parse_add :: proc(p: ^Fpm_Parser) -> (expr: Fpm_Expr, err: Fpm_Parse_Error) {
	lhs := fpm_parse_mul(p) or_return
	for cursor_peek_kind(p) == .Plus || cursor_peek_kind(p) == .Minus {
		op := cursor_advance(p) or_return
		rhs := fpm_parse_mul(p) or_return
		node := new(Fpm_Binary, context.temp_allocator)
		node^ = Fpm_Binary{op = op.kind, lhs = lhs, rhs = rhs}
		lhs = node
	}
	return lhs, .None
}

fpm_parse_mul :: proc(p: ^Fpm_Parser) -> (expr: Fpm_Expr, err: Fpm_Parse_Error) {
	lhs := fpm_parse_unary(p) or_return
	for cursor_peek_kind(p) == .Star || cursor_peek_kind(p) == .Slash || cursor_peek_kind(p) == .Percent {
		op := cursor_advance(p) or_return
		rhs := fpm_parse_unary(p) or_return
		node := new(Fpm_Binary, context.temp_allocator)
		node^ = Fpm_Binary{op = op.kind, lhs = lhs, rhs = rhs}
		lhs = node
	}
	return lhs, .None
}

fpm_parse_unary :: proc(p: ^Fpm_Parser) -> (expr: Fpm_Expr, err: Fpm_Parse_Error) {
	if cursor_peek_kind(p) == .Minus {
		cursor_advance(p) or_return
		operand := fpm_parse_unary(p) or_return
		node := new(Fpm_Unary, context.temp_allocator)
		node^ = Fpm_Unary{op = .Minus, operand = operand}
		return node, .None
	}
	return fpm_parse_postfix(p)
}

fpm_parse_postfix :: proc(p: ^Fpm_Parser) -> (expr: Fpm_Expr, err: Fpm_Parse_Error) {
	atom := fpm_parse_atom(p) or_return
	for {
		#partial switch cursor_peek_kind(p) {
		case .Dot:
			cursor_advance(p) or_return
			member := fpm_expect_lower(p) or_return
			mnode := new(Fpm_Member, context.temp_allocator)
			mnode^ = Fpm_Member{receiver = atom, member = member}
			if cursor_peek_kind(p) == .L_Paren {
				args := fpm_parse_call_args(p) or_return
				cnode := new(Fpm_Call, context.temp_allocator)
				cnode^ = Fpm_Call{callee = mnode, args = args}
				atom = cnode
			} else {
				atom = mnode
			}
		case .L_Paren:
			args := fpm_parse_call_args(p) or_return
			cnode := new(Fpm_Call, context.temp_allocator)
			cnode^ = Fpm_Call{callee = atom, args = args}
			atom = cnode
		case:
			return atom, .None
		}
	}
}

fpm_parse_call_args :: proc(p: ^Fpm_Parser) -> (args: []Fpm_Arg, err: Fpm_Parse_Error) {
	fpm_expect(p, .L_Paren) or_return
	list := make([dynamic]Fpm_Arg, 0, 4, context.temp_allocator)
	for cursor_peek_kind(p) != .R_Paren && !cursor_at_end(p) {
		arg: Fpm_Arg
		if cursor_peek_kind(p) == .Lower_Ident && cursor_peek_kind_at(p, 1) == .Colon {
			label := cursor_advance(p) or_return
			cursor_advance(p) or_return
			arg.label = label.text
			arg.labeled = true
		}
		arg.value = fpm_parse_expression(p) or_return
		append(&list, arg)
		if cursor_peek_kind(p) == .Comma {
			cursor_advance(p) or_return
		}
	}
	fpm_expect(p, .R_Paren) or_return
	return list[:], .None
}

fpm_parse_atom :: proc(p: ^Fpm_Parser) -> (expr: Fpm_Expr, err: Fpm_Parse_Error) {
	tok := cursor_peek(p)
	#partial switch tok.kind {
	case .Int_Lit:
		cursor_advance(p) or_return
		node := new(Fpm_Int_Lit, context.temp_allocator)
		node^ = Fpm_Int_Lit{value = tok.int_value}
		return node, .None
	case .Float_Lit:
		cursor_advance(p) or_return
		node := new(Fpm_Float_Lit, context.temp_allocator)
		node^ = Fpm_Float_Lit{value = tok.float_value}
		return node, .None
	case .String_Lit:
		cursor_advance(p) or_return
		node := new(Fpm_String_Lit, context.temp_allocator)
		node^ = Fpm_String_Lit{text = tok.text}
		return node, .None
	case .Lower_Ident, .Upper_Ident:
		cursor_advance(p) or_return
		node := new(Fpm_Name, context.temp_allocator)
		node^ = Fpm_Name{name = tok.text, ident_case = tok.ident_case}
		return node, .None
	case .L_Paren:
		cursor_advance(p) or_return
		inner := fpm_parse_expression(p) or_return
		fpm_expect(p, .R_Paren) or_return
		return inner, .None
	}
	if cursor_at_end(p) {
		return expr, .Unexpected_End
	}
	return expr, .Unexpected_Token
}

@(rodata)
FPM_PRIM_NAMES := [Fpm_Prim_Kind]string {
	.Capsule = "capsule",
	.Sphere  = "sphere",
	.Box     = "box",
	.Cyl     = "cyl",
}

@(rodata)
FPM_TRANSFORM_NAMES := [Fpm_Transform_Kind]string {
	.Up     = "up",
	.Down   = "down",
	.At     = "at",
	.Rotate = "rotate",
	.Scale  = "scale",
}

@(rodata)
FPM_BOOL_NAMES := [Fpm_Bool_Kind]string {
	.Union      = "union",
	.Difference = "difference",
	.Intersect  = "intersect",
}

fpm_solid_of_expr :: proc(expr: Fpm_Expr) -> Fpm_Solid {
	call, is_call := expr.(^Fpm_Call)
	if !is_call {
		return nil
	}
	if member, is_member := call.callee.(^Fpm_Member); is_member {
		if kind, ok := fpm_transform_kind(member.member); ok {
			inner := fpm_solid_of_expr(member.receiver)
			if inner == nil {
				return nil
			}
			node := new(Fpm_Transform, context.temp_allocator)
			node^ = Fpm_Transform{kind = kind, inner = inner, scale = fpm_transform_scale(kind, call.args)}
			return node
		}
		return nil
	}
	name, is_name := call.callee.(^Fpm_Name)
	if !is_name {
		return nil
	}
	if kind, ok := fpm_prim_kind(name.name); ok {
		return fpm_lift_primitive(kind, call.args)
	}
	if kind, ok := fpm_bool_kind(name.name); ok {
		return fpm_lift_boolean(kind, call.args)
	}
	return nil
}

fpm_lift_primitive :: proc(kind: Fpm_Prim_Kind, args: []Fpm_Arg) -> Fpm_Solid {
	dims := make([]f64, len(args), context.temp_allocator)
	for arg, i in args {
		if v, ok := fpm_eval_number(arg.value); ok {
			dims[i] = v
		} else {
			dims[i] = -1
		}
	}
	node := new(Fpm_Primitive, context.temp_allocator)
	node^ = Fpm_Primitive{kind = kind, dims = dims}
	return node
}

fpm_lift_boolean :: proc(kind: Fpm_Bool_Kind, args: []Fpm_Arg) -> Fpm_Solid {
	operands := make([dynamic]Fpm_Solid, 0, len(args), context.temp_allocator)
	for arg in args {
		if solid := fpm_solid_of_expr(arg.value); solid != nil {
			append(&operands, solid)
		}
	}
	node := new(Fpm_Boolean, context.temp_allocator)
	node^ = Fpm_Boolean{kind = kind, operands = operands[:]}
	return node
}

fpm_transform_scale :: proc(kind: Fpm_Transform_Kind, args: []Fpm_Arg) -> f64 {
	if kind != .Scale || len(args) == 0 {
		return 1
	}
	if v, ok := fpm_eval_number(args[0].value); ok {
		return v
	}
	return 1
}

fpm_eval_number :: proc(expr: Fpm_Expr) -> (value: f64, ok: bool) {
	switch e in expr {
	case ^Fpm_Int_Lit:
		return f64(e.value), true
	case ^Fpm_Float_Lit:
		return e.value, true
	case ^Fpm_Unary:
		inner := fpm_eval_number(e.operand) or_return
		return -inner, true
	case ^Fpm_Binary:
		lhs := fpm_eval_number(e.lhs) or_return
		rhs := fpm_eval_number(e.rhs) or_return
		#partial switch e.op {
		case .Plus:
			return lhs + rhs, true
		case .Minus:
			return lhs - rhs, true
		case .Star:
			return lhs * rhs, true
		case .Slash:
			if rhs == 0 {
				return 0, false
			}
			return lhs / rhs, true
		case .Percent:
			if rhs == 0 {
				return 0, false
			}
			return lhs - rhs*f64(i64(lhs/rhs)), true
		}
		return 0, false
	case ^Fpm_String_Lit, ^Fpm_Name, ^Fpm_Member, ^Fpm_Call, ^Fpm_Range:
		return 0, false
	case nil:
		return 0, false
	}
	return 0, false
}

fpm_prim_kind :: proc(name: string) -> (kind: Fpm_Prim_Kind, ok: bool) {
	for candidate in Fpm_Prim_Kind {
		if FPM_PRIM_NAMES[candidate] == name {
			return candidate, true
		}
	}
	return {}, false
}

fpm_transform_kind :: proc(name: string) -> (kind: Fpm_Transform_Kind, ok: bool) {
	for candidate in Fpm_Transform_Kind {
		if FPM_TRANSFORM_NAMES[candidate] == name {
			return candidate, true
		}
	}
	return {}, false
}

fpm_bool_kind :: proc(name: string) -> (kind: Fpm_Bool_Kind, ok: bool) {
	for candidate in Fpm_Bool_Kind {
		if FPM_BOOL_NAMES[candidate] == name {
			return candidate, true
		}
	}
	return {}, false
}

fpm_expect_lower :: proc(p: ^Fpm_Parser) -> (name: string, err: Fpm_Parse_Error) {
	tok := cursor_advance(p) or_return
	if tok.kind != .Lower_Ident {
		if tok.kind == .Upper_Ident {
			return "", .Wrong_Case
		}
		return "", .Unexpected_Token
	}
	return tok.text, .None
}

fpm_expect_upper :: proc(p: ^Fpm_Parser) -> (name: string, err: Fpm_Parse_Error) {
	tok := cursor_advance(p) or_return
	if tok.kind != .Upper_Ident {
		if tok.kind == .Lower_Ident {
			return "", .Wrong_Case
		}
		return "", .Unexpected_Token
	}
	return tok.text, .None
}

fpm_expect :: proc(p: ^Fpm_Parser, kind: Fpm_Token_Kind) -> (tok: Fpm_Token, err: Fpm_Parse_Error) {
	return cursor_expect(p, kind)
}

fpm_terminate :: proc(p: ^Fpm_Parser) -> Fpm_Parse_Error {
	if cursor_peek_kind(p) == .Newline || cursor_peek_kind(p) == .Comma {
		fpm_skip_seps(p)
		return .None
	}
	if cursor_at_end(p) || cursor_peek_kind(p) == .R_Brace {
		return .None
	}
	return .Unexpected_Token
}

fpm_skip_seps :: proc(p: ^Fpm_Parser) {
	cursor_skip_kinds(p, Fpm_Token_Kind.Newline, Fpm_Token_Kind.Comma)
}

fpm_skip_newlines :: proc(p: ^Fpm_Parser) {
	cursor_skip_kinds(p, Fpm_Token_Kind.Newline)
}
