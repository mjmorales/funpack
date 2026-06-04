// Value is the evaluator's tagged runtime value. The scalar arms land
// with the kernel; composite arms (vectors, quaternions, Option, lists,
// lambdas) widen the union behind the same dispatch shape. There is no
// implicit promotion anywhere: equality and arithmetic demand matching
// tags, mirroring the type discipline of spec §10.
package funpack

Value :: union {
	Fixed,
	i64,  // Int — counts and indices
	bool, // Bool — the result of ==
	Option_Value,
	Vec2_Value,
	Vec3_Value,
	Quat_Value,
	List_Value,
	Lambda_Value,
}

List_Value :: struct {
	elements: []Value,
}

// Lambda_Value captures its defining environment; application binds
// parameters in a child frame off it.
Lambda_Value :: struct {
	node: ^Lambda_Expr,
	env:  ^Env,
}

// Option_Value is the runtime Option: a present payload or none. The
// payload is a pointer because a union cannot contain itself by value.
Option_Value :: struct {
	is_some: bool,
	payload: ^Value, // nil when none
}

// value_equal is structural: tags must match, then the payloads compare
// bit-exactly (Fixed is transparent integer data, spec §10).
value_equal :: proc(a, b: Value) -> bool {
	switch av in a {
	case Fixed:
		bv, ok := b.(Fixed)
		return ok && av == bv
	case i64:
		bv, ok := b.(i64)
		return ok && av == bv
	case bool:
		bv, ok := b.(bool)
		return ok && av == bv
	case Option_Value:
		bv, ok := b.(Option_Value)
		if !ok || av.is_some != bv.is_some {
			return false
		}
		if !av.is_some {
			return true
		}
		return value_equal(av.payload^, bv.payload^)
	case Vec2_Value:
		bv, ok := b.(Vec2_Value)
		return ok && av == bv
	case Vec3_Value:
		bv, ok := b.(Vec3_Value)
		return ok && av == bv
	case Quat_Value:
		bv, ok := b.(Quat_Value)
		return ok && av == bv
	case List_Value:
		bv, ok := b.(List_Value)
		if !ok || len(av.elements) != len(bv.elements) {
			return false
		}
		for element, i in av.elements {
			if !value_equal(element, bv.elements[i]) {
				return false
			}
		}
		return true
	case Lambda_Value:
		// Functions have no extensional equality; comparing them is
		// always false rather than an identity check the language never
		// promises.
		return false
	}
	return false
}
