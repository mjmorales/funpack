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
	^User_Type,
	^Engine_Type,
}

// Engine_Type is the nominal handle for an engine/stdlib type the value
// kernel does not ground (spec §08/§20/§23/§04): the §08 read table View[T],
// the §04 command constructors Spawn/Draw, the §23 Input/Bindings resources,
// the §04 Time resource, the engine String, and the engine enums
// (PlayerId/Key/Stick/Color). Engine_Kind is the closed set of those names;
// View carries its element type in elem (nil for the non-parameterized
// kinds). Two engine types are compatible only when their kind matches and,
// for View, their element types unify — nominal like User_Type, never
// structural across kinds.
Engine_Type :: struct {
	kind: Engine_Kind,
	elem: Type, // View[T]'s element; nil for every non-parameterized kind
}

// Engine_Kind is the closed set of engine/stdlib type names the typing pass
// grounds. Growing it is a deliberate edit, mirroring STDLIB_SURFACE.
Engine_Kind :: enum {
	View,     // §08 read table View[T]
	Spawn,    // §04 spawn command
	Draw,     // §20 draw command
	Input,    // §23 input resource
	Bindings, // §23 input-binding builder
	Time,     // §04 frame-time resource
	String,   // engine String (string literals, Draw::Text)
	PlayerId, // §23 player-id enum
	Key,      // §23 keyboard-key enum
	Stick,    // §23 gamepad-stick enum
	Color,    // §20 palette enum
}

// User_Type is the nominal handle for a name the source declares
// (spec §06): a thing/singleton/data record, an enum, or a signal. The
// resolver records each user declaration's field/variant schema in the
// Type_Env (resolve.odin); a User_Type carries only the declared name and
// which §06 kind it names, so a field typed `side: Side` resolves to a
// concrete handle without the resolver yet typing any value of it. Two
// user types are compatible only when their names match — nominal, never
// structural (spec §02: one name, one meaning).
User_Type :: struct {
	name: string,
	kind: User_Kind,
}

// User_Kind is the closed set of §06/§03 declaration forms a User_Type can
// name. The resolver keys each declared name to exactly one kind, so a
// later stage reads the right schema table off the handle.
User_Kind :: enum {
	Thing,  // `thing`/`singleton Name { … }`
	Data,   // `data Name { … }`
	Enum,   // `enum Name { … }`, incl. the `Name: Kind` role form
	Signal, // `signal Name { … }`
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

// user_type_of builds a nominal handle for a declared name (resolve.odin).
user_type_of :: proc(name: string, kind: User_Kind) -> Type {
	node := new(User_Type, context.temp_allocator)
	node.name = name
	node.kind = kind
	return node
}

// engine_type_of builds an engine-type handle; elem is the View[T] element
// (nil for every non-parameterized kind).
engine_type_of :: proc(kind: Engine_Kind, elem: Type = nil) -> Type {
	node := new(Engine_Type, context.temp_allocator)
	node.kind = kind
	node.elem = elem
	return node
}

// is_engine reports an engine type of a specific kind — the engine analogue
// of is_ground over Ground_Type.
is_engine :: proc(t: Type, kind: Engine_Kind) -> bool {
	v, ok := t.(^Engine_Type)
	return ok && v.kind == kind
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

// is_vector_ground reports a vector ground type — Vec2 or Vec3 — the
// component-wise arithmetic and vector-scalar scaling sides.
is_vector_ground :: proc(t: Type) -> bool {
	return is_ground(t, .Vec2) || is_ground(t, .Vec3)
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
	case ^User_Type:
		// A user type is nominal: the same declared name is the same type;
		// the §06 kind always agrees once the name does (one name, one
		// meaning — the resolver rejects a name reused across kinds).
		bv, ok := b.(^User_Type)
		return ok && av.name == bv.name
	case ^Engine_Type:
		// An engine type is nominal by kind; View[T] additionally unifies its
		// element so View[Paddle] and View[Ball] never cross (nil elem is the
		// unknown that unifies, mirroring Option/List).
		bv, ok := b.(^Engine_Type)
		return ok && av.kind == bv.kind && types_compatible(av.elem, bv.elem)
	}
	return false
}
