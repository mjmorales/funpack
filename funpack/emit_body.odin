package funpack

import "core:strings"

emit_body :: proc(b: ^strings.Builder, body: []Statement) {
	for stmt in body {
		emit_statement(b, stmt)
	}
}

executable_body_count :: proc(holed: bool, body: []Statement) -> int {
	if holed {
		return 1
	}
	return len(body)
}

emit_executable_body :: proc(b: ^strings.Builder, holed: bool, has_fallback: bool, fallback: Expr, body: []Statement) {
	if !holed {
		emit_body(b, body)
		return
	}
	if has_fallback {
		emit_line(b, "node stub fallback 1")
		emit_expr(b, fallback)
		return
	}
	emit_line(b, "node stub bare 0")
}

emit_statement :: proc(b: ^strings.Builder, stmt: Statement) {
	switch node in stmt {
	case Let_Node:
		emit_let(b, node)
	case Return_Node:
		emit_line(b, "node return 1")
		emit_expr(b, node.value)
	case If_Node:
		emit_line(b, "node if_return 2")
		emit_expr(b, node.cond)
		if ret, bare := single_bare_return(node); bare {
			emit_expr(b, ret)
			return
		}
		emit_line(b, "node block ", encode_int(i64(len(node.body)), context.temp_allocator))
		for inner in node.body {
			emit_statement(b, inner)
		}
	case Assert_Node:
	}
}

emit_let :: proc(b: ^strings.Builder, node: Let_Node) {
	if !node.is_tuple {
		emit_line(b, "node let ", node.name, " 1")
		emit_expr(b, node.value)
		return
	}
	strings.write_string(b, "node let_tuple ")
	strings.write_int(b, len(node.names))
	for name in node.names {
		strings.write_byte(b, ' ')
		strings.write_string(b, name)
	}
	emit_line(b, " 1")
	emit_expr(b, node.value)
}

single_bare_return :: proc(node: If_Node) -> (value: Expr, bare: bool) {
	if len(node.body) == 1 {
		if ret, ok := node.body[0].(Return_Node); ok {
			return ret.value, true
		}
	}
	return nil, false
}

emit_expr :: proc(b: ^strings.Builder, expr: Expr) {
	switch e in expr {
	case ^Int_Lit_Expr:
		emit_line(b, "node int ", encode_int(e.value, context.temp_allocator), " 0")
	case ^Fixed_Lit_Expr:
		emit_line(b, "node fixed ", encode_fixed(e.bits, context.temp_allocator), " 0")
	case ^String_Lit_Expr:
		emit_line(b, "node string ", encode_string(e.text, context.temp_allocator), " 0")
	case ^Name_Expr:
		emit_line(b, "node name ", e.name, " 0")
	case ^Member_Expr:
		emit_line(b, "node field ", e.member, " 1")
		emit_expr(b, e.receiver)
	case ^Call_Expr:
		emit_call(b, e)
	case ^Variant_Expr:
		emit_variant(b, e)
	case ^Record_Expr:
		emit_record(b, e)
	case ^List_Expr:
		emit_list(b, e)
	case ^Lambda_Expr:
		emit_lambda(b, e)
	case ^Unary_Expr:
		emit_line(b, "node unary ", unary_op_name(e.op), " 1")
		emit_expr(b, e.operand)
	case ^Binary_Expr:
		emit_line(b, "node binary ", binary_op_name(e.op), " 2")
		emit_expr(b, e.lhs)
		emit_expr(b, e.rhs)
	case ^With_Expr:
		emit_with(b, e)
	case ^Match_Expr:
		emit_match(b, e)
	case ^Tuple_Expr:
		emit_tuple(b, e)
	case ^If_Expr:
		emit_if(b, e)
	case ^Stub_Expr:
		emit_stub(b, e)
	case ^All_Expr:
		emit_line(b, "node all ", e.thing, " 0")
	}
}

emit_stub :: proc(b: ^strings.Builder, e: ^Stub_Expr) {
	strings.write_string(b, "node stub ")
	strings.write_string(b, type_ref_string(e.hole_type))
	strings.write_string(b, e.has_fallback ? " true " : " false ")
	strings.write_int(b, e.has_fallback ? 1 : 0)
	emit_line(b, "")
	if e.has_fallback {
		emit_expr(b, e.fallback)
	}
}

emit_if :: proc(b: ^strings.Builder, e: ^If_Expr) {
	emit_line(b, "node if_expr 3")
	emit_expr(b, e.cond)
	emit_expr(b, e.then_branch)
	emit_expr(b, e.else_branch)
}

emit_tuple :: proc(b: ^strings.Builder, e: ^Tuple_Expr) {
	strings.write_string(b, "node tuple ")
	strings.write_int(b, len(e.elements))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.elements))
	emit_line(b, "")
	for element in e.elements {
		emit_expr(b, element)
	}
}

emit_call :: proc(b: ^strings.Builder, e: ^Call_Expr) {
	emit_node_head(b, "call", 1 + len(e.args))
	emit_expr(b, e.callee)
	for arg in e.args {
		emit_expr(b, arg)
	}
}

emit_variant :: proc(b: ^strings.Builder, e: ^Variant_Expr) {
	if e.has_fields {
		emit_struct_variant(b, e)
		return
	}
	strings.write_string(b, "node variant ")
	strings.write_string(b, e.type_name)
	strings.write_byte(b, ' ')
	strings.write_string(b, e.variant)
	strings.write_byte(b, ' ')
	strings.write_string(b, encode_bool(e.has_payload))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.payload))
	emit_line(b, "")
	for arg in e.payload {
		emit_expr(b, arg)
	}
}

emit_struct_variant :: proc(b: ^strings.Builder, e: ^Variant_Expr) {
	strings.write_string(b, "node record ")
	strings.write_string(b, e.type_name)
	strings.write_string(b, "::")
	strings.write_string(b, e.variant)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.fields))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.fields))
	emit_line(b, "")
	for field in e.fields {
		emit_recfield(b, field)
	}
}

emit_record :: proc(b: ^strings.Builder, e: ^Record_Expr) {
	strings.write_string(b, "node record ")
	strings.write_string(b, e.type_name)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.fields))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.fields))
	emit_line(b, "")
	for field in e.fields {
		emit_recfield(b, field)
	}
}

emit_recfield :: proc(b: ^strings.Builder, field: Record_Field) {
	emit_line(b, "node recfield ", field.name, " 1")
	emit_expr(b, field.value)
}

emit_with :: proc(b: ^strings.Builder, e: ^With_Expr) {
	strings.write_string(b, "node with ")
	strings.write_int(b, len(e.fields))
	strings.write_byte(b, ' ')
	strings.write_int(b, 1 + len(e.fields))
	emit_line(b, "")
	emit_expr(b, e.base)
	for field in e.fields {
		emit_recfield(b, field)
	}
}

emit_list :: proc(b: ^strings.Builder, e: ^List_Expr) {
	strings.write_string(b, "node list ")
	strings.write_int(b, len(e.elements))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.elements))
	emit_line(b, "")
	for element in e.elements {
		emit_expr(b, element)
	}
}

emit_lambda :: proc(b: ^strings.Builder, e: ^Lambda_Expr) {
	strings.write_string(b, "node lambda ")
	strings.write_int(b, len(e.params))
	for param in e.params {
		strings.write_byte(b, ' ')
		strings.write_string(b, param)
	}
	emit_line(b, " 1")
	emit_expr(b, e.body)
}

emit_match :: proc(b: ^strings.Builder, e: ^Match_Expr) {
	strings.write_string(b, "node match ")
	strings.write_int(b, len(e.arms))
	strings.write_byte(b, ' ')
	strings.write_int(b, 1 + 2 * len(e.arms))
	emit_line(b, "")
	emit_expr(b, e.scrutinee)
	for arm in e.arms {
		emit_arm(b, arm.pattern)
		emit_expr(b, arm.body)
	}
}

emit_arm :: proc(b: ^strings.Builder, pattern: Pattern) {
	strings.write_string(b, "node arm ")
	switch pattern.kind {
	case .Wildcard:
		emit_line(b, "wildcard - - 0")
	case .Bare_Variant:
		strings.write_string(b, "bare_variant ")
		strings.write_string(b, pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, pattern.variant)
		emit_line(b, " 0")
	case .Variant_Binds:
		binders := variant_payload_binders(pattern)
		strings.write_string(b, "variant_binds ")
		strings.write_string(b, pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, pattern.variant)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(binders))
		for binder in binders {
			strings.write_byte(b, ' ')
			strings.write_string(b, binder)
		}
		emit_line(b, "")
	case .Struct_Binds:
		strings.write_string(b, "struct_binds ")
		strings.write_string(b, pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, pattern.variant)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(pattern.binders))
		for binder in pattern.binders {
			strings.write_byte(b, ' ')
			strings.write_string(b, binder)
		}
		emit_line(b, "")
	case .Bare_Binder:
		strings.write_string(b, "bare_binder - - 1 ")
		emit_line(b, tuple_binder_name(pattern))
	case .Tuple:
		strings.write_string(b, "tuple ")
		strings.write_int(b, len(pattern.elements))
		emit_line(b, "")
		for sub in pattern.elements {
			emit_arm(b, sub)
		}
	}
}

tuple_binder_name :: proc(pattern: Pattern) -> string {
	if len(pattern.binders) == 1 {
		return pattern.binders[0]
	}
	return "-"
}

variant_payload_binders :: proc(pattern: Pattern) -> []string {
	out := make([]string, len(pattern.elements), context.temp_allocator)
	for sub, i in pattern.elements {
		#partial switch sub.kind {
		case .Bare_Binder:
			out[i] = tuple_binder_name(sub)
		case .Wildcard:
			out[i] = "_"
		case:
			out[i] = "-"
		}
	}
	return out
}

emit_node_head :: proc(b: ^strings.Builder, kind: string, child_count: int) {
	strings.write_string(b, "node ")
	strings.write_string(b, kind)
	strings.write_byte(b, ' ')
	strings.write_int(b, child_count)
	emit_line(b, "")
}

unary_op_name :: proc(op: Token) -> string {
	if op.kind == .Minus {
		return "neg"
	}
	return "not"
}

binary_op_name :: proc(op: Token) -> string {
	#partial switch op.kind {
	case .Plus:
		return "add"
	case .Minus:
		return "sub"
	case .Star:
		return "mul"
	case .Slash:
		return "div"
	case .Percent:
		return "mod"
	case .Eq_Eq:
		return "eq"
	case .Not_Eq:
		return "ne"
	case .Lt:
		return "lt"
	case .Lt_Eq:
		return "le"
	case .Gt:
		return "gt"
	case .Gt_Eq:
		return "ge"
	case .Ident:
		switch op.text {
		case "and":
			return "and"
		case "or":
			return "or"
		}
	}
	return ""
}

type_ref_string :: proc(ref: Type_Ref) -> string {
	if ref.name == TYPE_REF_LIST_HEAD {
		if len(ref.args) == 1 {
			return strings.concatenate({"[", type_ref_string(ref.args[0]), "]"}, context.temp_allocator)
		}
		return TYPE_REF_LIST_HEAD
	}
	if ref.name == TYPE_REF_FN_HEAD && len(ref.args) > 0 {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "fn(")
		for arg, i in ref.args[:len(ref.args)-1] {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			strings.write_string(&b, type_ref_string(arg))
		}
		strings.write_string(&b, ")->")
		strings.write_string(&b, type_ref_string(ref.args[len(ref.args)-1]))
		return strings.to_string(b)
	}
	if ref.name == TYPE_REF_TUPLE_HEAD {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '(')
		for arg, i in ref.args {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			strings.write_string(&b, type_ref_string(arg))
		}
		strings.write_byte(&b, ')')
		return strings.to_string(b)
	}
	if len(ref.args) == 0 {
		return ref.name
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, ref.name)
	strings.write_byte(&b, '[')
	for arg, i in ref.args {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, type_ref_string(arg))
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

encode_literal :: proc(expr: Expr) -> string {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return encode_int(e.value, context.temp_allocator)
	case ^Fixed_Lit_Expr:
		return encode_fixed(e.bits, context.temp_allocator)
	case ^String_Lit_Expr:
		return encode_string(e.text, context.temp_allocator)
	case ^Name_Expr:
		if e.name == "true" || e.name == "false" {
			return e.name
		}
	}
	return ""
}
