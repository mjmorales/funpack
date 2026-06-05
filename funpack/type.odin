// The checker's parameterized type model. Ground types are the
// parameterless heads; Option, List, and function types carry their
// parameters as allocated nodes, so Option[Fixed] and Option[Int] are
// distinct and a lambda has a real signature. A nil Type is the one
// unknown: the element of Option::None and of the empty list, standing
// for a type the expression alone cannot determine. Compatibility is
// structural with nil unifying against anything — the equality
// judgment the golden checked_div(1.0, 0.0) == Option::None depends
// on. There is still no implicit promotion anywhere (spec §10): a nil
// never arises between Int and Fixed, so ground types only ever match
// themselves.
package funpack

Type :: union {
	Ground_Type,
	^Option_Type,
	^List_Type,
	^Func_Type,
}

Ground_Type :: enum {
	Int,
	Fixed,
	Bool,
	Vec2,
	Vec3,
	Quat,
}

Option_Type :: struct {
	elem: Type, // nil for Option::None until unified
}

List_Type :: struct {
	elem: Type, // nil for the empty list until unified
}

// Func_Type with nil params is the opaque lambda placeholder — the
// seam where combinator inference plugs in real parameter types.
Func_Type :: struct {
	params: []Type,
	result: Type,
}

option_of :: proc(elem: Type) -> Type {
	node := new(Option_Type, context.temp_allocator)
	node.elem = elem
	return node
}

list_of :: proc(elem: Type) -> Type {
	node := new(List_Type, context.temp_allocator)
	node.elem = elem
	return node
}

// func_of clones the params so call-site compound literals never
// escape their stack frame; a nil params stays nil — the opaque
// placeholder signature.
func_of :: proc(params: []Type, result: Type) -> Type {
	node := new(Func_Type, context.temp_allocator)
	if params != nil {
		node.params = clone_types(params)
	}
	node.result = result
	return node
}

clone_types :: proc(set: []Type) -> []Type {
	cloned := make([]Type, len(set), context.temp_allocator)
	copy(cloned, set)
	return cloned
}

is_ground :: proc(t: Type, g: Ground_Type) -> bool {
	v, ok := t.(Ground_Type)
	return ok && v == g
}

// is_numeric_ground reports an arithmetic-capable scalar side: Int or
// Fixed, never anything parameterized.
is_numeric_ground :: proc(t: Type) -> bool {
	return is_ground(t, .Int) || is_ground(t, .Fixed)
}

// types_compatible is the structural equality judgment with one
// loosening: a nil side (the unknown) unifies with anything. Heads
// must otherwise match exactly — there is no promotion and no
// subtyping.
types_compatible :: proc(a, b: Type) -> bool {
	if a == nil || b == nil {
		return true
	}
	switch av in a {
	case Ground_Type:
		bv, ok := b.(Ground_Type)
		return ok && av == bv
	case ^Option_Type:
		bv, ok := b.(^Option_Type)
		return ok && types_compatible(av.elem, bv.elem)
	case ^List_Type:
		bv, ok := b.(^List_Type)
		return ok && types_compatible(av.elem, bv.elem)
	case ^Func_Type:
		bv, ok := b.(^Func_Type)
		if !ok {
			return false
		}
		// nil params is the opaque placeholder signature.
		if av.params == nil || bv.params == nil {
			return true
		}
		if len(av.params) != len(bv.params) {
			return false
		}
		for param, i in av.params {
			if !types_compatible(param, bv.params[i]) {
				return false
			}
		}
		return types_compatible(av.result, bv.result)
	}
	return false
}
