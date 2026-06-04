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
	}
	return false
}
