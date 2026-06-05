// Typecheck for the evaluable domain: every free name binds to exactly
// one declaration — a test block's let binding or an imported surface
// member (spec §02: one name, one meaning) — and an unresolved name is
// a compile error, never a fallback. There is no implicit promotion
// (spec §10) — equality and arithmetic demand same-typed sides, and
// the Int → Fixed lift is the explicit to_fixed call. Types are the
// parameterized model in type.odin: Option and List carry element
// types, lambdas carry a function type. The stage opens by resolving
// imports against the stdlib surface (surface.odin) into the Bindings
// carrier; name, callee, and receiver checking all route through it.
// Lambda parameter types are inferred only at evaluation: the
// placeholder Func signature is the seam where combinator inference
// plugs in.
package funpack

Type_Error :: enum {
	None,
	Assert_Not_Bool,  // an assert whose expression is not Bool-typed
	Type_Mismatch,    // differently-typed sides — no implicit promotion
	Unsupported_Expr, // a parsed form outside the evaluable domain
	Unknown_Module,   // an import naming a module outside the surface
	Unknown_Member,   // an import naming a member its module lacks
	Unresolved_Name,  // a free name with no let binding and no import
}

// Scope maps a test block's let-bound names to their checked types.
// Lookups only — nothing iterates the map.
Scope :: map[string]Type

// Check_Ctx threads the file-level import resolutions and the test
// block's let scope through expression checking; both maps are
// lookup-only below stage_typecheck.
Check_Ctx :: struct {
	bindings: Bindings,
	scope:    Scope,
}

stage_typecheck :: proc(ast: Ast) -> (typed: Typed_Ast, err: Type_Error) {
	bindings := resolve_imports(ast) or_return
	for test in ast.tests {
		ctx := Check_Ctx{bindings = bindings, scope = make(Scope, context.temp_allocator)}
		for stmt in test.body {
			switch node in stmt {
			case Let_Node:
				type := expr_check(ctx, node.value) or_return
				ctx.scope[node.name] = type
			case Assert_Node:
				check_assert(ctx, node) or_return
			}
		}
	}
	return Typed_Ast{ast = ast, bindings = bindings}, .None
}

check_assert :: proc(ctx: Check_Ctx, node: Assert_Node) -> Type_Error {
	type := expr_check(ctx, node.expr) or_return
	if !is_ground(type, .Bool) {
		return .Assert_Not_Bool
	}
	return .None
}

expr_check :: proc(ctx: Check_Ctx, expr: Expr) -> (type: Type, err: Type_Error) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return Ground_Type.Int, .None
	case ^Fixed_Lit_Expr:
		return Ground_Type.Fixed, .None
	case ^Name_Expr:
		if bound, found := ctx.scope[e.name]; found {
			return bound, .None
		}
		if binding, found := ctx.bindings.names[e.name]; found {
			if binding.kind == .Value {
				if value_type, typed := surface_value_type(e.name); typed {
					return value_type, .None
				}
			}
			// A type, module, or bare function name is not a value in
			// the evaluable domain.
			return nil, .Unsupported_Expr
		}
		return nil, .Unresolved_Name
	case ^Unary_Expr:
		if e.op.kind != .Minus {
			return nil, .Unsupported_Expr
		}
		operand := expr_check(ctx, e.operand) or_return
		if !is_numeric_ground(operand) {
			return nil, .Type_Mismatch
		}
		return operand, .None
	case ^Binary_Expr:
		lhs := expr_check(ctx, e.lhs) or_return
		rhs := expr_check(ctx, e.rhs) or_return
		if e.op.kind == .Eq_Eq {
			if !types_compatible(lhs, rhs) {
				return nil, .Type_Mismatch
			}
			return Ground_Type.Bool, .None
		}
		#partial switch e.op.kind {
		case .Plus, .Minus, .Star, .Slash, .Percent:
			// Arithmetic sides must be the same numeric ground type.
			if !is_numeric_ground(lhs) || !types_compatible(lhs, rhs) {
				return nil, .Type_Mismatch
			}
			return lhs, .None
		}
		return nil, .Unsupported_Expr
	case ^Member_Expr:
		recv, is_name := e.receiver.(^Name_Expr)
		if !is_name {
			return nil, .Unsupported_Expr
		}
		if _, let_bound := ctx.scope[recv.name]; let_bound {
			// Value receivers expose no members outside a method call.
			return nil, .Unsupported_Expr
		}
		binding, imported := ctx.bindings.names[recv.name]
		if !imported {
			return nil, .Unresolved_Name
		}
		if binding.kind != .Type_Name {
			return nil, .Unsupported_Expr
		}
		associated, declared := surface_associated(recv.name, e.member)
		if !declared {
			return nil, .Unsupported_Expr
		}
		if _, is_constructor := associated.(^Func_Type); is_constructor {
			// A constructor is only meaningful applied.
			return nil, .Unsupported_Expr
		}
		return associated, .None
	case ^Record_Expr:
		binding, imported := ctx.bindings.names[e.type_name]
		if !imported {
			return nil, .Unresolved_Name
		}
		if binding.kind != .Type_Name {
			return nil, .Unsupported_Expr
		}
		switch e.type_name {
		case "Vec2":
			record_fields_check(ctx, e, {"x", "y"}) or_return
			return Ground_Type.Vec2, .None
		case "Vec3":
			record_fields_check(ctx, e, {"x", "y", "z"}) or_return
			return Ground_Type.Vec3, .None
		}
		return nil, .Unsupported_Expr
	case ^List_Expr:
		// Elements must agree with each other; the element type is the
		// first concrete one (nil for the empty list).
		element_type: Type
		for element in e.elements {
			got := expr_check(ctx, element) or_return
			if !types_compatible(element_type, got) {
				return nil, .Type_Mismatch
			}
			if element_type == nil {
				element_type = got
			}
		}
		return list_of(element_type), .None
	case ^Lambda_Expr:
		// The opaque placeholder signature — the combinator-inference
		// seam.
		return func_of(nil, nil), .None
	case ^Call_Expr:
		return call_check(ctx, e)
	case ^Variant_Expr:
		binding, imported := ctx.bindings.names[e.type_name]
		if !imported {
			return nil, .Unresolved_Name
		}
		if binding.kind != .Type_Name || e.type_name != "Option" {
			return nil, .Unsupported_Expr
		}
		switch e.variant {
		case "Some":
			if !e.has_payload || len(e.payload) != 1 {
				return nil, .Unsupported_Expr
			}
			payload := expr_check(ctx, e.payload[0]) or_return
			return option_of(payload), .None
		case "None":
			if e.has_payload {
				return nil, .Unsupported_Expr
			}
			return option_of(nil), .None
		}
		return nil, .Unsupported_Expr
	}
	return nil, .Unsupported_Expr
}

// call_check types a free-function call by resolving the callee name —
// let scope first, then the imported surface — and checking the
// arguments against the resolved overload set. The generic list
// combinators carry no table signature: fold keeps its dedicated
// call-site rule; the rest wait on combinator inference.
call_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if member, is_method := e.callee.(^Member_Expr); is_method {
		return method_check(ctx, member, e)
	}
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return nil, .Unsupported_Expr
	}
	if _, let_bound := ctx.scope[name.name]; let_bound {
		// Calling a let-bound lambda waits on combinator inference —
		// the placeholder Func carries no signature to check against.
		return nil, .Unsupported_Expr
	}
	binding, found := ctx.bindings.names[name.name]
	if !found {
		return nil, .Unresolved_Name
	}
	if binding.kind != .Func {
		return nil, .Type_Mismatch
	}
	if name.name == "fold" {
		return fold_check(ctx, e)
	}
	overloads, has_signature := surface_signatures(name.name)
	if !has_signature {
		return nil, .Unsupported_Expr
	}
	return overloads_check(ctx, e, overloads)
}

// fold is (List[T], A, Func) -> A: the accumulator type is the init's.
// The lambda's parameters stay unchecked until combinator inference.
fold_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 3 {
		return nil, .Type_Mismatch
	}
	list := expr_check(ctx, e.args[0]) or_return
	init := expr_check(ctx, e.args[1]) or_return
	lambda := expr_check(ctx, e.args[2]) or_return
	_, is_list := list.(^List_Type)
	_, is_func := lambda.(^Func_Type)
	if !is_list || !is_func {
		return nil, .Type_Mismatch
	}
	return init, .None
}

// overloads_check types the arguments once and admits the call when the
// argument row matches one overload's parameters exactly.
overloads_check :: proc(ctx: Check_Ctx, e: ^Call_Expr, overloads: []Type) -> (type: Type, err: Type_Error) {
	args := make([]Type, len(e.args), context.temp_allocator)
	for arg, i in e.args {
		args[i] = expr_check(ctx, arg) or_return
	}
	for overload in overloads {
		signature, is_func := overload.(^Func_Type)
		if !is_func || len(signature.params) != len(args) {
			continue
		}
		matches := true
		for want, i in signature.params {
			if !types_compatible(args[i], want) {
				matches = false
				break
			}
		}
		if matches {
			return signature.result, .None
		}
	}
	return nil, .Type_Mismatch
}

check_args :: proc(ctx: Check_Ctx, e: ^Call_Expr, signature: []Type) -> Type_Error {
	if len(e.args) != len(signature) {
		return .Type_Mismatch
	}
	for want, i in signature {
		got, err := expr_check(ctx, e.args[i])
		if err != .None {
			return err
		}
		if !types_compatible(got, want) {
			return .Type_Mismatch
		}
	}
	return .None
}

// method_check types receiver.member(args): a Type-name receiver
// resolved through the surface selects an associated constructor; any
// other receiver checks as a value whose methods the surface keys by
// the receiver's type.
method_check :: proc(ctx: Check_Ctx, callee: ^Member_Expr, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if recv, is_name := callee.receiver.(^Name_Expr); is_name {
		if _, let_bound := ctx.scope[recv.name]; !let_bound {
			binding, imported := ctx.bindings.names[recv.name]
			if !imported {
				return nil, .Unresolved_Name
			}
			if binding.kind == .Type_Name {
				associated, declared := surface_associated(recv.name, callee.member)
				if !declared {
					return nil, .Unsupported_Expr
				}
				signature, is_constructor := associated.(^Func_Type)
				if !is_constructor {
					return nil, .Unsupported_Expr
				}
				check_args(ctx, e, signature.params) or_return
				return signature.result, .None
			}
		}
	}
	receiver := expr_check(ctx, callee.receiver) or_return
	method, declared := surface_method(receiver, callee.member)
	if !declared {
		return nil, .Unsupported_Expr
	}
	signature, is_func := method.(^Func_Type)
	if !is_func {
		return nil, .Unsupported_Expr
	}
	check_args(ctx, e, signature.params) or_return
	return signature.result, .None
}

// record_fields_check demands every field name belong to the record's
// component set and every component expression be Fixed.
record_fields_check :: proc(ctx: Check_Ctx, e: ^Record_Expr, allowed: []string) -> Type_Error {
	for field in e.fields {
		known := false
		for name in allowed {
			if field.name == name {
				known = true
				break
			}
		}
		if !known {
			return .Type_Mismatch
		}
		got, err := expr_check(ctx, field.value)
		if err != .None {
			return err
		}
		if !is_ground(got, .Fixed) {
			return .Type_Mismatch
		}
	}
	return .None
}
