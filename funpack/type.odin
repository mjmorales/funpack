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
	^Tuple_Type,
	^Func_Type,
	^User_Type,
	^Engine_Type,
}

// Engine_Type is the nominal handle for an engine/stdlib type the value
// kernel does not ground (spec §08/§20/§23/§04): the §08 read table View[T],
// the §04 command constructors Spawn/Despawn/Draw, the §23 Input/Bindings
// resources, the §04 Time resource, the engine.rand Rng handle, the engine
// String, and the engine enums (PlayerId/Key/Stick/Color). Engine_Kind is the
// closed set of those names;
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
	Despawn,  // §04 despawn command
	Draw,     // §20 draw command
	Input,    // §23 input resource
	Bindings, // §23 input-binding builder
	Time,     // §04 frame-time resource
	Rng,      // threaded-resource RNG handle (engine.rand)
	String,   // engine String (string literals, Draw::Text)
	PlayerId, // §23 player-id enum
	Key,      // §23 keyboard-key enum
	Stick,    // §23 gamepad-stick enum
	Color,    // §20 palette enum
	Flip,     // §20 sprite-mirroring enum (None | X | Y | XY), Draw::Sprite.flip
	// §11 physics surface: the Body record, its kind/shape enums, and the
	// engine-routed Trigger signal.
	Body,            // §11 §2 physics body record (engine.physics)
	BodyKind,        // §11 §2 Static | Dynamic | Kinematic enum
	Shape2,          // §11 §2 collision-shape enum (struct-payload Box/Circle)
	Trigger,         // §11 §4 zero-field sensor-overlap signal (engine-emitted)
	// §24 persistence surface: the save/settings command constructors, the
	// engine-routed result signals, and the settings records.
	Save,            // §24 §1 Save{slot} command constructor (engine.save)
	Restore,         // §24 §1 Restore{slot} command constructor
	ApplySettings,   // §24 §2 ApplySettings{settings} command constructor
	Saved,           // §24 §1 save-outcome signal (carries result: Result[…])
	Restored,        // §24 §1 restore-outcome signal (carries result: Result[…])
	SettingsApplied, // §24 §2 settings-apply-outcome signal (carries result)
	Settings,        // §24 §2 per-machine preferences record
	AccessOpts,      // §24 §2 accessibility sub-record (reduce_motion)
	Result,          // prelude Result[_, _] — matched Ok/Err with wildcard payloads
	// §08 reference + navigation surface: the typed reference the §17 level
	// bake resolves names to, the nav read/query handle, the route value a
	// Path-field default carries, and the query-failure variant.
	Ref,             // §08 typed reference Ref[T] (engine.world; Door.gate, Ref[Player])
	Nav,             // §08 nav read/query handle (Nav.path queries a route)
	Path,            // §08 route value (a thing-field default; Path.advance walks it)
	NavError,        // §08 nav query-failure variant
	// §19/§26 the shared typed asset handles (engine.assets): the typed constant a
	// generated seam binds (`let coin: MeshHandle = MeshHandle{name: "coin"}`) and
	// the result of the manifest-checked string constructor (mesh/texture/sound/
	// atlas). Each is a single-field record over a String `name` — its schema is
	// surface_engine_record.
	MeshHandle,      // §26 a baked-mesh handle (mesh("…"); a model bakes to a mesh)
	TextureHandle,   // §26 a baked-texture handle (texture("…"))
	SoundHandle,     // §26 a baked-sound handle (sound("…"))
	AtlasHandle,     // §26 a sprite-atlas handle (atlas("…"); cell/frame accessors)
	// §18 §2 / §26 the tilemap partition's handle (engine.tilemap): the typed
	// constant a .tiles bake's seam binds (`let dungeon: TilesetHandle =
	// TilesetHandle{name: "dungeon"}`). Same single-String-`name` record schema
	// as the engine.assets handles (surface_engine_record); §26 declares no
	// string constructor for it. TilemapHandle/SetTile and the tile queries
	// ride the tilemap-layer story, not this kind.
	TilesetHandle,   // §18 §2 a baked-tileset handle (the .tiles seam constant)
	// §16 §7 the rig/animation surface (engine.anim): the engine-provided
	// skeleton, the part→slot mesh bindings, the sparse bone→Transform pose, and
	// the bone/slot/side enums a pose generator and the generated rig seam name.
	// A behavior reads none of these by field — they are opaque engine values
	// composed through their builders (Pose.blend, PartSet.bind) and consumed by
	// Draw3::Rigged. The pose generators are pure fixed-point, so every replay is
	// bit-identical.
	Skeleton,        // §16 §7 the bone topology (Skeleton.humanoid()/empty())
	PartSet,         // §16 §7 the part→slot mesh bindings (PartSet.empty().bind(…))
	Slot,            // §16 §7 a part-attach slot enum (Slot::Torso, Slot::Head, …)
	Side,            // §16 §7 the mirror-side enum (Side::L | Side::R)
	Pose,            // §16 §7 the sparse bone→Transform pose (Pose.empty().set(…))
	Bone,            // §16 §7 a skeleton bone enum (Bone::LUpperLeg, Bone::Torso, …)
	Transform,       // §16 §7 a per-bone transform value (rot_x(s), up(d))
	// §20 §1 the 3D render command (engine.render3): the Draw3 draw-list a render3
	// behavior emits, distinct from the §20 2D Draw command — render3 owns Draw3,
	// it never reuses the .Draw kind. Material is the PBR surface a Draw3::Mesh
	// names (Color is owned by engine.render and re-exported to render3, §26 §3).
	Draw3,           // §20 §1 the 3D draw command (Camera/Light/Plane/Rigged/Mesh)
	Material,        // §20 §1 the PBR material a Draw3::Mesh carries
	// §22 §2 the sustained-audio scene value (engine.audio): the keyed Audio track
	// an `audio:` behavior projects, built with Audio.track(key, clip) and the
	// .pitch/.gain/.bus builders, plus the Bus group enum the one-shot Sound
	// regime (5.2) shares. Audio is the level-triggered twin of the edge-triggered
	// one-shot Sound command.
	Audio,           // §22 §2 the keyed sustained-audio track (Audio.track(…).bus(…))
	Bus,             // §22 §4 the audio bus group enum (Bus::Sfx, shared with Sound)
	// §22 §1 the ONE-SHOT sound command record (engine.audio): Sound.sfx(clip)
	// + .gain/.pitch/.bus/.at — the edge-triggered twin of the sustained Audio
	// regime above; both regimes share the Bus mixer-group enum.
	Sound,           // §22 §1 one-shot sound command record (engine.audio)
	// §21 ui surface (engine.ui): the UI navigation-action enum and the project
	// style-token vocabulary handle. View[Msg] already exists above (the §08 read
	// table doubles as the §21 retained-mode view tree, re-exported by engine.ui
	// per §26). UiAction is the closed focus/gamepad action set
	// (NavUp/NavDown/NavLeft/NavRight/Confirm/Cancel); Theme is the opaque
	// style-token vocabulary a class= token is checked against.
	UiAction,        // §21 §5 closed UI navigation-action enum (engine.ui)
	Theme,           // §21 §1 opaque project style-token vocabulary handle
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

// Tuple_Type is a fixed-arity positional aggregate type (spec §04 §1: every
// draw returns the pair `(value, next_rng)`). It carries its positional element
// types in order; compatibility is structural over the positions, like List and
// Option, with a nil position unifying against anything. The snake/hunt return
// pairs are tuples of two — the RNG-threaded `(Rng, [Spawn])` and the
// pick-result `(Option[Cell], Rng)` — but the node carries any arity.
Tuple_Type :: struct {
	elements: []Type, // positional element types, in source order
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

// tuple_of builds a tuple type over positional element types, cloning the set so
// a call-site compound literal never escapes its stack frame (mirroring
// func_of's param clone).
tuple_of :: proc(elements: []Type) -> Type {
	node := new(Tuple_Type, context.temp_allocator)
	node.elements = clone_types(elements)
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
	case ^Tuple_Type:
		// A tuple is structural over its positions: same arity, and each
		// position unifies — a nil position unifies with anything, mirroring
		// List/Option. So (Option[Cell], Rng) matches (Option[Cell], Rng) and a
		// declared (Rng, [Spawn]) return matches a body tuple of the same shape.
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
