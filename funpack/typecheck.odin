// Typecheck for the evaluable domain: a recursive expr_check mirrors
// what the evaluator computes and gates everything else out as
// Unsupported_Expr, so a counted assert never reaches a form the
// kernel cannot produce bits for. There is no implicit promotion
// (spec §10) — equality and arithmetic demand same-typed sides, and
// the Int → Fixed lift is the explicit to_fixed call. Types are the
// parameterized model in type.odin: Option and List carry element
// types, lambdas carry a function type. Each test block carries a
// Scope built by checking let RHS types in statement order. The stage
// opens by resolving imports against the stdlib surface (surface.odin)
// into the Bindings carrier; expression checking does not consume it
// yet — name resolution will route through it when it replaces the
// builtin-name fallback below. Lambda parameter types are inferred
// only at evaluation: the placeholder Func signature is the seam
// where combinator inference plugs in.
package funpack

Type_Error :: enum {
	None,
	Assert_Not_Bool,  // an assert whose expression is not Bool-typed
	Type_Mismatch,    // differently-typed sides — no implicit promotion
	Unsupported_Expr, // a parsed form outside the evaluable domain
	Unknown_Module,   // an import naming a module outside the surface
	Unknown_Member,   // an import naming a member its module lacks
}

// Scope maps a test block's let-bound names to their checked types.
// Lookups only — nothing iterates the map.
Scope :: map[string]Type

stage_typecheck :: proc(ast: Ast) -> (typed: Typed_Ast, err: Type_Error) {
	bindings := resolve_imports(ast) or_return
	for test in ast.tests {
		scope := make(Scope, context.temp_allocator)
		for stmt in test.body {
			switch node in stmt {
			case Let_Node:
				type := expr_check(scope, node.value) or_return
				scope[node.name] = type
			case Assert_Node:
				check_assert(scope, node) or_return
			}
		}
	}
	return Typed_Ast{ast = ast, bindings = bindings}, .None
}

check_assert :: proc(scope: Scope, node: Assert_Node) -> Type_Error {
	type := expr_check(scope, node.expr) or_return
	if !is_ground(type, .Bool) {
		return .Assert_Not_Bool
	}
	return .None
}

expr_check :: proc(scope: Scope, expr: Expr) -> (type: Type, err: Type_Error) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return Ground_Type.Int, .None
	case ^Fixed_Lit_Expr:
		return Ground_Type.Fixed, .None
	case ^Name_Expr:
		if bound, found := scope[e.name]; found {
			return bound, .None
		}
		// The sanctioned lowercase constants are the builtin fallback.
		if e.name == "pi" {
			return Ground_Type.Fixed, .None
		}
		return nil, .Unsupported_Expr
	case ^Unary_Expr:
		if e.op.kind != .Minus {
			return nil, .Unsupported_Expr
		}
		operand := expr_check(scope, e.operand) or_return
		if !is_numeric_ground(operand) {
			return nil, .Type_Mismatch
		}
		return operand, .None
	case ^Binary_Expr:
		lhs := expr_check(scope, e.lhs) or_return
		rhs := expr_check(scope, e.rhs) or_return
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
		if is_name && recv.name == "Fixed" && (e.member == "MAX" || e.member == "MIN") {
			return Ground_Type.Fixed, .None
		}
		if is_name && recv.name == "Quat" && e.member == "identity" {
			return Ground_Type.Quat, .None
		}
		return nil, .Unsupported_Expr
	case ^Record_Expr:
		switch e.type_name {
		case "Vec2":
			record_fields_check(scope, e, {"x", "y"}) or_return
			return Ground_Type.Vec2, .None
		case "Vec3":
			record_fields_check(scope, e, {"x", "y", "z"}) or_return
			return Ground_Type.Vec3, .None
		}
		return nil, .Unsupported_Expr
	case ^List_Expr:
		// Elements must agree with each other; the element type is the
		// first concrete one (nil for the empty list).
		element_type: Type
		for element in e.elements {
			got := expr_check(scope, element) or_return
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
		return call_check(scope, e)
	case ^Variant_Expr:
		if e.type_name != "Option" {
			return nil, .Unsupported_Expr
		}
		switch e.variant {
		case "Some":
			if !e.has_payload || len(e.payload) != 1 {
				return nil, .Unsupported_Expr
			}
			payload := expr_check(scope, e.payload[0]) or_return
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

// call_check types the builtin surface: each name has one signature,
// checked argument by argument with no promotion. dot/length accept
// either vector width, so they dispatch on the first argument's type;
// fold types as (List[T], A, Func) -> A.
call_check :: proc(scope: Scope, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if member, is_method := e.callee.(^Member_Expr); is_method {
		return method_check(scope, member, e)
	}
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return nil, .Unsupported_Expr
	}
	switch name.name {
	case "dot":
		if len(e.args) != 2 {
			return nil, .Type_Mismatch
		}
		lhs := expr_check(scope, e.args[0]) or_return
		rhs := expr_check(scope, e.args[1]) or_return
		if !types_compatible(lhs, rhs) || (!is_ground(lhs, .Vec2) && !is_ground(lhs, .Vec3)) {
			return nil, .Type_Mismatch
		}
		return Ground_Type.Fixed, .None
	case "cross":
		check_args(scope, e, {Ground_Type.Vec3, Ground_Type.Vec3}) or_return
		return Ground_Type.Vec3, .None
	case "length":
		if len(e.args) != 1 {
			return nil, .Type_Mismatch
		}
		arg := expr_check(scope, e.args[0]) or_return
		if !is_ground(arg, .Vec2) && !is_ground(arg, .Vec3) {
			return nil, .Type_Mismatch
		}
		return Ground_Type.Fixed, .None
	case "to_fixed":
		check_args(scope, e, {Ground_Type.Int}) or_return
		return Ground_Type.Fixed, .None
	case "trunc", "floor", "round":
		check_args(scope, e, {Ground_Type.Fixed}) or_return
		return Ground_Type.Int, .None
	case "clamp", "lerp":
		check_args(scope, e, {Ground_Type.Fixed, Ground_Type.Fixed, Ground_Type.Fixed}) or_return
		return Ground_Type.Fixed, .None
	case "checked_div":
		check_args(scope, e, {Ground_Type.Fixed, Ground_Type.Fixed}) or_return
		return option_of(Ground_Type.Fixed), .None
	case "sin", "cos":
		check_args(scope, e, {Ground_Type.Fixed}) or_return
		return Ground_Type.Fixed, .None
	case "fold":
		if len(e.args) != 3 {
			return nil, .Type_Mismatch
		}
		list := expr_check(scope, e.args[0]) or_return
		init := expr_check(scope, e.args[1]) or_return
		lambda := expr_check(scope, e.args[2]) or_return
		_, is_list := list.(^List_Type)
		_, is_func := lambda.(^Func_Type)
		if !is_list || !is_func {
			return nil, .Type_Mismatch
		}
		// fold is (List[T], A, Func) -> A: the accumulator type is the
		// init's.
		return init, .None
	}
	return nil, .Unsupported_Expr
}

check_args :: proc(scope: Scope, e: ^Call_Expr, signature: []Type) -> Type_Error {
	if len(e.args) != len(signature) {
		return .Type_Mismatch
	}
	for want, i in signature {
		got, err := expr_check(scope, e.args[i])
		if err != .None {
			return err
		}
		if !types_compatible(got, want) {
			return .Type_Mismatch
		}
	}
	return .None
}

// method_check types receiver.method(args) — the quaternion surface.
// A type-name receiver selects the associated constructor.
method_check :: proc(scope: Scope, callee: ^Member_Expr, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if recv, is_type := callee.receiver.(^Name_Expr); is_type && recv.name == "Quat" {
		if callee.member != "axis_angle" {
			return nil, .Unsupported_Expr
		}
		check_args(scope, e, {Ground_Type.Vec3, Ground_Type.Fixed}) or_return
		return Ground_Type.Quat, .None
	}
	receiver := expr_check(scope, callee.receiver) or_return
	if !is_ground(receiver, .Quat) {
		return nil, .Unsupported_Expr
	}
	switch callee.member {
	case "rotate":
		check_args(scope, e, {Ground_Type.Vec3}) or_return
		return Ground_Type.Vec3, .None
	case "mul":
		check_args(scope, e, {Ground_Type.Quat}) or_return
		return Ground_Type.Quat, .None
	case "slerp":
		check_args(scope, e, {Ground_Type.Quat, Ground_Type.Fixed}) or_return
		return Ground_Type.Quat, .None
	}
	return nil, .Unsupported_Expr
}

// record_fields_check demands every field name belong to the record's
// component set and every component expression be Fixed.
record_fields_check :: proc(scope: Scope, e: ^Record_Expr, allowed: []string) -> Type_Error {
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
		got, err := expr_check(scope, field.value)
		if err != .None {
			return err
		}
		if !is_ground(got, .Fixed) {
			return .Type_Mismatch
		}
	}
	return .None
}
