// Typecheck for the evaluable domain: a recursive expr_check mirrors
// what the evaluator computes and gates everything else out as
// Unsupported_Expr, so a counted assert never reaches a form the
// kernel cannot produce bits for. There is no implicit promotion
// (spec §10) — equality and arithmetic demand same-typed sides, and
// the Int → Fixed lift is the explicit to_fixed call. Each test block
// carries a Scope built by checking let RHS types in statement order.
// The stage opens by resolving imports against the stdlib surface
// (surface.odin) into the Bindings carrier; expression checking does
// not consume it yet — name resolution will route through it when it
// replaces the builtin-name fallback below. Lambda bodies are
// deliberately delegated to evaluation: typing them statically needs
// parameter types the opaque List/Lambda surface does not carry — that
// is the full checker's seam. Full static name resolution widens this
// behind the same stage seam.
package funpack

Value_Type :: enum {
	Int,
	Fixed,
	Bool,
	Option, // opaque here — payload types are the full checker's seam
	Vec2,
	Vec3,
	Quat,
	List,   // opaque element type
	Lambda, // body delegated to evaluation
}

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
Scope :: map[string]Value_Type

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
	if type != .Bool {
		return .Assert_Not_Bool
	}
	return .None
}

expr_check :: proc(scope: Scope, expr: Expr) -> (type: Value_Type, err: Type_Error) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return .Int, .None
	case ^Fixed_Lit_Expr:
		return .Fixed, .None
	case ^Name_Expr:
		if bound, found := scope[e.name]; found {
			return bound, .None
		}
		// The sanctioned lowercase constants are the builtin fallback.
		if e.name == "pi" {
			return .Fixed, .None
		}
		return .Int, .Unsupported_Expr
	case ^Unary_Expr:
		if e.op.kind != .Minus {
			return .Int, .Unsupported_Expr
		}
		operand := expr_check(scope, e.operand) or_return
		if operand != .Fixed && operand != .Int {
			return .Int, .Type_Mismatch
		}
		return operand, .None
	case ^Binary_Expr:
		lhs := expr_check(scope, e.lhs) or_return
		rhs := expr_check(scope, e.rhs) or_return
		if e.op.kind == .Eq_Eq {
			if lhs != rhs {
				return .Int, .Type_Mismatch
			}
			return .Bool, .None
		}
		#partial switch e.op.kind {
		case .Plus, .Minus, .Star, .Slash, .Percent:
			if lhs != rhs || (lhs != .Fixed && lhs != .Int) {
				return .Int, .Type_Mismatch
			}
			return lhs, .None
		}
		return .Int, .Unsupported_Expr
	case ^Member_Expr:
		recv, is_name := e.receiver.(^Name_Expr)
		if is_name && recv.name == "Fixed" && (e.member == "MAX" || e.member == "MIN") {
			return .Fixed, .None
		}
		if is_name && recv.name == "Quat" && e.member == "identity" {
			return .Quat, .None
		}
		return .Int, .Unsupported_Expr
	case ^Record_Expr:
		switch e.type_name {
		case "Vec2":
			record_fields_check(scope, e, {"x", "y"}) or_return
			return .Vec2, .None
		case "Vec3":
			record_fields_check(scope, e, {"x", "y", "z"}) or_return
			return .Vec3, .None
		}
		return .Int, .Unsupported_Expr
	case ^List_Expr:
		// Elements must agree with each other; the list type itself
		// stays opaque.
		element_type := Value_Type.Int
		for element, i in e.elements {
			got := expr_check(scope, element) or_return
			if i == 0 {
				element_type = got
			} else if got != element_type {
				return .Int, .Type_Mismatch
			}
		}
		return .List, .None
	case ^Lambda_Expr:
		return .Lambda, .None
	case ^Call_Expr:
		return call_check(scope, e)
	case ^Variant_Expr:
		if e.type_name != "Option" {
			return .Int, .Unsupported_Expr
		}
		switch e.variant {
		case "Some":
			if !e.has_payload || len(e.payload) != 1 {
				return .Int, .Unsupported_Expr
			}
			expr_check(scope, e.payload[0]) or_return
			return .Option, .None
		case "None":
			if e.has_payload {
				return .Int, .Unsupported_Expr
			}
			return .Option, .None
		}
		return .Int, .Unsupported_Expr
	}
	return .Int, .Unsupported_Expr
}

// call_check types the builtin surface: each name has one signature,
// checked argument by argument with no promotion. dot/length accept
// either vector width, so they dispatch on the first argument's type;
// fold types as (List, T, Lambda) -> T.
call_check :: proc(scope: Scope, e: ^Call_Expr) -> (type: Value_Type, err: Type_Error) {
	if member, is_method := e.callee.(^Member_Expr); is_method {
		return method_check(scope, member, e)
	}
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return .Int, .Unsupported_Expr
	}
	switch name.name {
	case "dot":
		if len(e.args) != 2 {
			return .Int, .Type_Mismatch
		}
		lhs := expr_check(scope, e.args[0]) or_return
		rhs := expr_check(scope, e.args[1]) or_return
		if lhs != rhs || (lhs != .Vec2 && lhs != .Vec3) {
			return .Int, .Type_Mismatch
		}
		return .Fixed, .None
	case "cross":
		check_args(scope, e, {.Vec3, .Vec3}) or_return
		return .Vec3, .None
	case "length":
		if len(e.args) != 1 {
			return .Int, .Type_Mismatch
		}
		arg := expr_check(scope, e.args[0]) or_return
		if arg != .Vec2 && arg != .Vec3 {
			return .Int, .Type_Mismatch
		}
		return .Fixed, .None
	case "to_fixed":
		check_args(scope, e, {.Int}) or_return
		return .Fixed, .None
	case "trunc", "floor", "round":
		check_args(scope, e, {.Fixed}) or_return
		return .Int, .None
	case "clamp", "lerp":
		check_args(scope, e, {.Fixed, .Fixed, .Fixed}) or_return
		return .Fixed, .None
	case "checked_div":
		check_args(scope, e, {.Fixed, .Fixed}) or_return
		return .Option, .None
	case "sin", "cos":
		check_args(scope, e, {.Fixed}) or_return
		return .Fixed, .None
	case "fold":
		if len(e.args) != 3 {
			return .Int, .Type_Mismatch
		}
		list := expr_check(scope, e.args[0]) or_return
		init := expr_check(scope, e.args[1]) or_return
		lambda := expr_check(scope, e.args[2]) or_return
		if list != .List || lambda != .Lambda {
			return .Int, .Type_Mismatch
		}
		// fold is (List, T, Lambda) -> T: the accumulator type is the
		// init's.
		return init, .None
	}
	return .Int, .Unsupported_Expr
}

check_args :: proc(scope: Scope, e: ^Call_Expr, signature: []Value_Type) -> Type_Error {
	if len(e.args) != len(signature) {
		return .Type_Mismatch
	}
	for want, i in signature {
		got, err := expr_check(scope, e.args[i])
		if err != .None {
			return err
		}
		if got != want {
			return .Type_Mismatch
		}
	}
	return .None
}

// method_check types receiver.method(args) — the quaternion surface.
// A type-name receiver selects the associated constructor.
method_check :: proc(scope: Scope, callee: ^Member_Expr, e: ^Call_Expr) -> (type: Value_Type, err: Type_Error) {
	if recv, is_type := callee.receiver.(^Name_Expr); is_type && recv.name == "Quat" {
		if callee.member != "axis_angle" {
			return .Int, .Unsupported_Expr
		}
		check_args(scope, e, {.Vec3, .Fixed}) or_return
		return .Quat, .None
	}
	receiver := expr_check(scope, callee.receiver) or_return
	if receiver != .Quat {
		return .Int, .Unsupported_Expr
	}
	switch callee.member {
	case "rotate":
		check_args(scope, e, {.Vec3}) or_return
		return .Vec3, .None
	case "mul":
		check_args(scope, e, {.Quat}) or_return
		return .Quat, .None
	case "slerp":
		check_args(scope, e, {.Quat, .Fixed}) or_return
		return .Quat, .None
	}
	return .Int, .Unsupported_Expr
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
		if got != .Fixed {
			return .Type_Mismatch
		}
	}
	return .None
}
