package funpack

Setup_Fold :: struct {
	ast:   Ast,
	binds: map[string]Expr,
}

fold_expr :: proc(fold: ^Setup_Fold, expr: Expr) -> (folded: Expr, ok: bool) {
	#partial switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr:
		return expr, true
	case ^Name_Expr:
		if e.name == "true" || e.name == "false" {
			return expr, true
		}
		if bound, found := fold.binds[e.name]; found {
			return bound, true
		}
		if constant, found := fold_module_const(fold, e.name); found {
			return constant, true
		}
		return nil, false
	case ^Record_Expr:
		return fold_record(fold, e)
	case ^Variant_Expr:
		return fold_variant(fold, e)
	case ^List_Expr:
		return fold_list(fold, e)
	case ^Call_Expr:
		return fold_call(fold, e)
	}
	return nil, false
}

fold_record :: proc(fold: ^Setup_Fold, e: ^Record_Expr) -> (folded: Expr, ok: bool) {
	fields := make([]Record_Field, len(e.fields), context.temp_allocator)
	for field, i in e.fields {
		value, resolved := fold_expr(fold, field.value)
		if !resolved {
			return nil, false
		}
		fields[i] = Record_Field{name = field.name, value = value}
	}
	node := new(Record_Expr, context.temp_allocator)
	node^ = Record_Expr{type_name = e.type_name, fields = fields}
	return node, true
}

fold_variant :: proc(fold: ^Setup_Fold, e: ^Variant_Expr) -> (folded: Expr, ok: bool) {
	if e.has_payload {
		return nil, false
	}
	if !e.has_fields {
		return e, true
	}
	fields := make([]Record_Field, len(e.fields), context.temp_allocator)
	for field, i in e.fields {
		value, resolved := fold_expr(fold, field.value)
		if !resolved {
			return nil, false
		}
		fields[i] = Record_Field{name = field.name, value = value}
	}
	node := new(Variant_Expr, context.temp_allocator)
	node^ = Variant_Expr{
		type_name  = e.type_name,
		variant    = e.variant,
		fields     = fields,
		has_fields = true,
	}
	return node, true
}

fold_list :: proc(fold: ^Setup_Fold, e: ^List_Expr) -> (folded: Expr, ok: bool) {
	elements := make([]Expr, len(e.elements), context.temp_allocator)
	for element, i in e.elements {
		value, resolved := fold_expr(fold, element)
		if !resolved {
			return nil, false
		}
		elements[i] = value
	}
	node := new(List_Expr, context.temp_allocator)
	node^ = List_Expr{elements = elements}
	return node, true
}

fold_call :: proc(fold: ^Setup_Fold, e: ^Call_Expr) -> (folded: Expr, ok: bool) {
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return nil, false
	}
	fn, found := find_user_fn(fold.ast, name.name)
	if !found || len(e.args) != len(fn.params) {
		return nil, false
	}
	ret, has_return := single_return_expr(fn.body)
	if !has_return {
		return nil, false
	}
	frame := Setup_Fold{ast = fold.ast, binds = make(map[string]Expr, context.temp_allocator)}
	for param, i in fn.params {
		arg, resolved := fold_expr(fold, e.args[i])
		if !resolved {
			return nil, false
		}
		frame.binds[param.name] = arg
	}
	return fold_expr(&frame, ret)
}

fold_module_const :: proc(fold: ^Setup_Fold, name: string) -> (value: Expr, found: bool) {
	for decl in fold.ast.lets {
		if decl.name == name {
			empty := Setup_Fold{ast = fold.ast, binds = make(map[string]Expr, context.temp_allocator)}
			return fold_expr(&empty, decl.value)
		}
	}
	return nil, false
}

fold_field_default :: proc(expr: Expr, ast: Ast) -> Expr {
	fold := Setup_Fold{ast = ast, binds = make(map[string]Expr, context.temp_allocator)}
	if folded, ok := fold_expr(&fold, expr); ok {
		return folded
	}
	return expr
}

fold_field_decls :: proc(fields: []Field_Decl, ast: Ast) -> []Field_Decl {
	out := make([]Field_Decl, len(fields), context.temp_allocator)
	for field, i in fields {
		out[i] = field
		if field.has_default {
			out[i].default = fold_field_default(field.default, ast)
		}
	}
	return out
}

single_return_expr :: proc(body: []Statement) -> (expr: Expr, ok: bool) {
	if len(body) != 1 {
		return nil, false
	}
	ret, is_return := body[0].(Return_Node)
	if !is_return {
		return nil, false
	}
	return ret.value, true
}
