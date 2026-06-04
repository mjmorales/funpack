// Evaluator over tagged Values and the saturating scalar kernel.
// Every operation is total and all-integer (spec §10) — no epsilon, no
// float, bit-identical on every machine. eval_expr fails closed: a form
// outside the evaluable domain returns ok = false, and the typecheck
// gate keeps such forms from reaching a counted assert. Each test block
// owns an environment frame; let statements bind into it in statement
// order, and lambda applications chain child frames off the captured
// env so iterations never leak bindings.
package funpack

// Env is a chained binding frame. Lookups walk toward the root; only
// the owning scope ever inserts, and nothing iterates the map — map
// order can never reach evaluation results (the determinism tripwire).
Env :: struct {
	bindings: map[string]Value,
	parent:   ^Env,
}

new_env :: proc(parent: ^Env) -> ^Env {
	env := new(Env, context.temp_allocator)
	env.bindings = make(map[string]Value, context.temp_allocator)
	env.parent = parent
	return env
}

env_lookup :: proc(env: ^Env, name: string) -> (value: Value, ok: bool) {
	for frame := env; frame != nil; frame = frame.parent {
		if v, found := frame.bindings[name]; found {
			return v, true
		}
	}
	return nil, false
}

stage_evaluate :: proc(typed: Typed_Ast) -> Eval_Result {
	result := Eval_Result{}
	for test in typed.ast.tests {
		env := new_env(nil)
		for stmt in test.body {
			switch node in stmt {
			case Let_Node:
				// A failed RHS leaves the name unbound; the asserts
				// reading it then fail rather than trapping.
				if value, ok := eval_expr(env, node.value); ok {
					env.bindings[node.name] = value
				}
			case Assert_Node:
				if eval_assert(env, node) {
					result.passed += 1
				} else {
					result.failed += 1
				}
			}
		}
	}
	return result
}

// eval_assert passes only when the expression evaluates to Bool true.
eval_assert :: proc(env: ^Env, node: Assert_Node) -> bool {
	value, ok := eval_expr(env, node.expr)
	if !ok {
		return false
	}
	passed, is_bool := value.(bool)
	return is_bool && passed
}

eval_expr :: proc(env: ^Env, expr: Expr) -> (value: Value, ok: bool) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return e.value, true
	case ^Fixed_Lit_Expr:
		return e.bits, true
	case ^Name_Expr:
		if bound, found := env_lookup(env, e.name); found {
			return bound, true
		}
		// The sanctioned lowercase constants are the builtin fallback.
		if e.name == "pi" {
			return PI_FIXED, true
		}
		return nil, false
	case ^Unary_Expr:
		return eval_unary(env, e)
	case ^Binary_Expr:
		return eval_binary(env, e)
	case ^Member_Expr:
		return eval_member(e)
	case ^Call_Expr:
		return eval_call(env, e)
	case ^Variant_Expr:
		return eval_variant(env, e)
	case ^Record_Expr:
		return eval_record(env, e)
	case ^List_Expr:
		return eval_list(env, e)
	case ^Lambda_Expr:
		return Lambda_Value{node = e, env = env}, true
	}
	return nil, false
}

eval_list :: proc(env: ^Env, e: ^List_Expr) -> (value: Value, ok: bool) {
	elements := make([]Value, len(e.elements), context.temp_allocator)
	for element, i in e.elements {
		elements[i] = eval_expr(env, element) or_return
	}
	return List_Value{elements = elements}, true
}

// apply_lambda binds the parameters in a fresh child frame off the
// captured environment, so applications are isolated from one another.
apply_lambda :: proc(lambda: Lambda_Value, args: []Value) -> (value: Value, ok: bool) {
	if len(args) != len(lambda.node.params) {
		return nil, false
	}
	frame := new_env(lambda.env)
	for param, i in lambda.node.params {
		frame.bindings[param] = args[i]
	}
	return eval_expr(frame, lambda.node.body)
}

// eval_variant lowers Option::Some/None — the one variant family in
// the evaluable domain.
eval_variant :: proc(env: ^Env, e: ^Variant_Expr) -> (value: Value, ok: bool) {
	if e.type_name != "Option" {
		return nil, false
	}
	switch e.variant {
	case "Some":
		if !e.has_payload || len(e.payload) != 1 {
			return nil, false
		}
		inner := eval_expr(env, e.payload[0]) or_return
		boxed := new(Value, context.temp_allocator)
		boxed^ = inner
		return Option_Value{is_some = true, payload = boxed}, true
	case "None":
		if e.has_payload {
			return nil, false
		}
		return Option_Value{is_some = false, payload = nil}, true
	}
	return nil, false
}

// eval_record lowers Vec2/Vec3 record literals: named Fixed fields onto
// the component slots, unnamed components defaulting to zero.
eval_record :: proc(env: ^Env, e: ^Record_Expr) -> (value: Value, ok: bool) {
	switch e.type_name {
	case "Vec2":
		v := Vec2_Value{}
		for field in e.fields {
			component := eval_expr(env, field.value) or_return
			f := component.(Fixed) or_return
			switch field.name {
			case "x":
				v.x = f
			case "y":
				v.y = f
			case:
				return nil, false
			}
		}
		return v, true
	case "Vec3":
		v := Vec3_Value{}
		for field in e.fields {
			component := eval_expr(env, field.value) or_return
			f := component.(Fixed) or_return
			switch field.name {
			case "x":
				v.x = f
			case "y":
				v.y = f
			case "z":
				v.z = f
			case:
				return nil, false
			}
		}
		return v, true
	}
	return nil, false
}

eval_unary :: proc(env: ^Env, e: ^Unary_Expr) -> (value: Value, ok: bool) {
	if e.op.kind != .Minus {
		return nil, false
	}
	operand := eval_expr(env, e.operand) or_return
	#partial switch v in operand {
	case Fixed:
		return fixed_neg(v), true
	case i64:
		return int_neg(v), true
	}
	return nil, false
}

eval_binary :: proc(env: ^Env, e: ^Binary_Expr) -> (value: Value, ok: bool) {
	lhs := eval_expr(env, e.lhs) or_return
	rhs := eval_expr(env, e.rhs) or_return
	if e.op.kind == .Eq_Eq {
		return value_equal(lhs, rhs), true
	}
	#partial switch l in lhs {
	case Fixed:
		r, is_fixed := rhs.(Fixed)
		if !is_fixed {
			return nil, false
		}
		#partial switch e.op.kind {
		case .Plus:
			return fixed_add(l, r), true
		case .Minus:
			return fixed_sub(l, r), true
		case .Star:
			return fixed_mul(l, r), true
		case .Slash:
			return fixed_div(l, r), true
		case .Percent:
			return fixed_mod(l, r), true
		}
	case i64:
		r, is_int := rhs.(i64)
		if !is_int {
			return nil, false
		}
		#partial switch e.op.kind {
		case .Plus:
			return int_add(l, r), true
		case .Minus:
			return int_sub(l, r), true
		case .Star:
			return int_mul(l, r), true
		case .Slash:
			return int_div(l, r), true
		case .Percent:
			return int_mod(l, r), true
		}
	}
	return nil, false
}

// eval_member resolves a type's associated constants: Fixed.MAX,
// Fixed.MIN, Quat.identity.
eval_member :: proc(e: ^Member_Expr) -> (value: Value, ok: bool) {
	recv, is_name := e.receiver.(^Name_Expr)
	if !is_name {
		return nil, false
	}
	switch recv.name {
	case "Fixed":
		switch e.member {
		case "MAX":
			return FIXED_MAX, true
		case "MIN":
			return FIXED_MIN, true
		}
	case "Quat":
		if e.member == "identity" {
			return QUAT_IDENTITY, true
		}
	}
	return nil, false
}

eval_call :: proc(env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if member, is_method := e.callee.(^Member_Expr); is_method {
		return eval_method_call(env, member, e.args)
	}
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return nil, false
	}
	switch name.name {
	case "to_fixed":
		if len(e.args) != 1 {
			return nil, false
		}
		arg := eval_expr(env, e.args[0]) or_return
		n, is_int := arg.(i64)
		if !is_int {
			return nil, false
		}
		return to_fixed(n), true
	case "trunc":
		f := eval_fixed_arg(env, e, 0, 1) or_return
		return fixed_trunc(f), true
	case "floor":
		f := eval_fixed_arg(env, e, 0, 1) or_return
		return fixed_floor(f), true
	case "round":
		f := eval_fixed_arg(env, e, 0, 1) or_return
		return fixed_round(f), true
	case "clamp":
		x := eval_fixed_arg(env, e, 0, 3) or_return
		lo := eval_fixed_arg(env, e, 1, 3) or_return
		hi := eval_fixed_arg(env, e, 2, 3) or_return
		return fixed_clamp(x, lo, hi), true
	case "lerp":
		a := eval_fixed_arg(env, e, 0, 3) or_return
		b := eval_fixed_arg(env, e, 1, 3) or_return
		t := eval_fixed_arg(env, e, 2, 3) or_return
		return fixed_lerp(a, b, t), true
	case "checked_div":
		a := eval_fixed_arg(env, e, 0, 2) or_return
		b := eval_fixed_arg(env, e, 1, 2) or_return
		quotient, has_quotient := fixed_checked_div(a, b)
		if !has_quotient {
			return Option_Value{is_some = false, payload = nil}, true
		}
		boxed := new(Value, context.temp_allocator)
		boxed^ = quotient
		return Option_Value{is_some = true, payload = boxed}, true
	case "dot":
		if len(e.args) != 2 {
			return nil, false
		}
		lhs := eval_expr(env, e.args[0]) or_return
		rhs := eval_expr(env, e.args[1]) or_return
		if a2, is_vec2 := lhs.(Vec2_Value); is_vec2 {
			b2 := rhs.(Vec2_Value) or_return
			return vec2_dot(a2, b2), true
		}
		a3 := lhs.(Vec3_Value) or_return
		b3 := rhs.(Vec3_Value) or_return
		return vec3_dot(a3, b3), true
	case "cross":
		if len(e.args) != 2 {
			return nil, false
		}
		lhs := eval_expr(env, e.args[0]) or_return
		rhs := eval_expr(env, e.args[1]) or_return
		a3 := lhs.(Vec3_Value) or_return
		b3 := rhs.(Vec3_Value) or_return
		return vec3_cross(a3, b3), true
	case "length":
		if len(e.args) != 1 {
			return nil, false
		}
		arg := eval_expr(env, e.args[0]) or_return
		if v2, is_vec2 := arg.(Vec2_Value); is_vec2 {
			return vec2_length(v2), true
		}
		v3 := arg.(Vec3_Value) or_return
		return vec3_length(v3), true
	case "sin":
		angle := eval_fixed_arg(env, e, 0, 1) or_return
		return fixed_sin(angle), true
	case "cos":
		angle := eval_fixed_arg(env, e, 0, 1) or_return
		return fixed_cos(angle), true
	case "fold":
		return eval_fold(env, e)
	}
	return nil, false
}

// eval_fold reduces strictly left-to-right: acc = lambda(acc, element)
// in element order, never tree-reduced or reordered — fixed-point + is
// not reorder-invariant under saturation, so the order IS the result
// (spec §10).
eval_fold :: proc(env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 3 {
		return nil, false
	}
	list_value := eval_expr(env, e.args[0]) or_return
	list := list_value.(List_Value) or_return
	acc := eval_expr(env, e.args[1]) or_return
	lambda_value := eval_expr(env, e.args[2]) or_return
	lambda := lambda_value.(Lambda_Value) or_return
	for element in list.elements {
		acc = apply_lambda(lambda, {acc, element}) or_return
	}
	return acc, true
}

// eval_method_call dispatches receiver.method(args) — the quaternion
// surface the golden asserts exercise. A type-name receiver that is not
// a bound value selects an associated constructor (Quat.axis_angle); a
// value receiver selects a method on the evaluated quaternion.
eval_method_call :: proc(env: ^Env, callee: ^Member_Expr, args: []Expr) -> (value: Value, ok: bool) {
	if recv, is_type := callee.receiver.(^Name_Expr); is_type && recv.name == "Quat" {
		if callee.member != "axis_angle" || len(args) != 2 {
			return nil, false
		}
		axis_value := eval_expr(env, args[0]) or_return
		axis := axis_value.(Vec3_Value) or_return
		angle_value := eval_expr(env, args[1]) or_return
		angle := angle_value.(Fixed) or_return
		return quat_axis_angle(axis, angle), true
	}
	receiver := eval_expr(env, callee.receiver) or_return
	q := receiver.(Quat_Value) or_return
	switch callee.member {
	case "rotate":
		if len(args) != 1 {
			return nil, false
		}
		arg := eval_expr(env, args[0]) or_return
		v := arg.(Vec3_Value) or_return
		return quat_rotate(q, v), true
	case "mul":
		if len(args) != 1 {
			return nil, false
		}
		arg := eval_expr(env, args[0]) or_return
		other := arg.(Quat_Value) or_return
		return quat_mul(q, other), true
	case "slerp":
		if len(args) != 2 {
			return nil, false
		}
		other_value := eval_expr(env, args[0]) or_return
		other := other_value.(Quat_Value) or_return
		t_value := eval_expr(env, args[1]) or_return
		t := t_value.(Fixed) or_return
		return quat_slerp(q, other, t), true
	}
	return nil, false
}

// eval_fixed_arg evaluates argument i of an expected-arity call and
// demands a Fixed — the shared shape of the scalar-surface builtins.
eval_fixed_arg :: proc(env: ^Env, e: ^Call_Expr, i: int, arity: int) -> (f: Fixed, ok: bool) {
	if len(e.args) != arity {
		return Fixed(0), false
	}
	value := eval_expr(env, e.args[i]) or_return
	return value.(Fixed)
}
