package funpack

Type :: union {
	Ground_Type,
	^Option_Type,
	^List_Type,
	^Map_Type,
	^Tuple_Type,
	^Func_Type,
	^User_Type,
	^Engine_Type,
}

Engine_Type :: struct {
	kind: Engine_Kind,
	elem: Type,
}

Engine_Kind :: enum {
	View,
	Spawn,
	Despawn,
	Draw,
	Input,
	Bindings,
	Time,
	Rng,
	String,
	PlayerId,
	Key,
	PadButton,
	MouseButton,
	Stick,
	Color,
	Flip,
	Align,
	Body,
	BodyKind,
	Shape2,
	Trigger,
	Save,
	Restore,
	ApplySettings,
	Saved,
	Restored,
	SettingsApplied,
	Settings,
	AccessOpts,
	Result,
	Ordering,
	Ref,
	Nav,
	Path,
	NavError,
	MeshHandle,
	TextureHandle,
	SoundHandle,
	AtlasHandle,
	TilesetHandle,
	TilemapHandle,
	SetTile,
	BuildLayer,
	Skeleton,
	PartSet,
	Slot,
	Side,
	Pose,
	Bone,
	Transform,
	Draw3,
	Material,
	Audio,
	Bus,
	Sound,
	UiAction,
	Theme,
}

User_Type :: struct {
	name: string,
	kind: User_Kind,
}

User_Kind :: enum {
	Thing,
	Data,
	Enum,
	Signal,
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
	elem: Type,
}

List_Type :: struct {
	elem: Type,
}

Map_Type :: struct {
	key:   Type,
	value: Type,
}

Tuple_Type :: struct {
	elements: []Type,
}

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

map_of :: proc(key, value: Type) -> Type {
	node := new(Map_Type, context.temp_allocator)
	node.key = key
	node.value = value
	return node
}

tuple_of :: proc(elements: []Type) -> Type {
	node := new(Tuple_Type, context.temp_allocator)
	node.elements = clone_types(elements)
	return node
}

func_of :: proc(params: []Type, result: Type) -> Type {
	node := new(Func_Type, context.temp_allocator)
	if params != nil {
		node.params = clone_types(params)
	}
	node.result = result
	return node
}

// Clone so a call-site []Type{...} stack literal can't dangle past the constructor (func_of/tuple_of pass theirs through here).
clone_types :: proc(set: []Type) -> []Type {
	cloned := make([]Type, len(set), context.temp_allocator)
	copy(cloned, set)
	return cloned
}

user_type_of :: proc(name: string, kind: User_Kind) -> Type {
	node := new(User_Type, context.temp_allocator)
	node.name = name
	node.kind = kind
	return node
}

engine_type_of :: proc(kind: Engine_Kind, elem: Type = nil) -> Type {
	node := new(Engine_Type, context.temp_allocator)
	node.kind = kind
	node.elem = elem
	return node
}

is_engine :: proc(t: Type, kind: Engine_Kind) -> bool {
	v, ok := t.(^Engine_Type)
	return ok && v.kind == kind
}

is_ground :: proc(t: Type, g: Ground_Type) -> bool {
	v, ok := t.(Ground_Type)
	return ok && v == g
}

is_numeric_ground :: proc(t: Type) -> bool {
	return is_ground(t, .Int) || is_ground(t, .Fixed)
}

is_vector_ground :: proc(t: Type) -> bool {
	return is_ground(t, .Vec2) || is_ground(t, .Vec3)
}

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
	case ^Map_Type:
		bv, ok := b.(^Map_Type)
		return ok && types_compatible(av.key, bv.key) && types_compatible(av.value, bv.value)
	case ^Tuple_Type:
		bv, ok := b.(^Tuple_Type)
		if !ok || len(av.elements) != len(bv.elements) {
			return false
		}
		for elem, i in av.elements {
			if !types_compatible(elem, bv.elements[i]) {
				return false
			}
		}
		return true
	case ^Func_Type:
		bv, ok := b.(^Func_Type)
		if !ok {
			return false
		}
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
		bv, ok := b.(^User_Type)
		return ok && av.name == bv.name
	case ^Engine_Type:
		bv, ok := b.(^Engine_Type)
		return ok && av.kind == bv.kind && types_compatible(av.elem, bv.elem)
	}
	return false
}
