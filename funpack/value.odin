// Value is the evaluator's tagged runtime value. The scalar arms land
// with the kernel; composite arms (vectors, quaternions, Option, lists,
// lambdas) widen the union behind the same dispatch shape. There is no
// implicit promotion anywhere: equality and arithmetic demand matching
// tags, mirroring the type discipline of spec §10.
package funpack

Value :: union {
	Fixed,
	i64,    // Int — counts and indices
	bool,   // Bool — the result of ==
	string, // String — a string literal's text; a §19 asset handle's `name` field
	Option_Value,
	Vec2_Value,
	Vec3_Value,
	Quat_Value,
	List_Value,
	Tuple_Value,
	Lambda_Value,
	Enum_Value,
	Record_Value,
	Input_Value,
	Time_Value,
	Transform_Value,
	Pose_Value,
	Tilemap_Value,
	Nav_Value,
}

// Nav_Value is the §12 test-position navigation handle Nav.of(route) seeds —
// the fixture stand-in a behavior test passes where a baked nav graph would be
// (the View.of/TilemapHandle.of mold). It carries the supplied route as the
// Path record value (type_name "Path", fields steps/cost) the five nav queries
// answer over: path() replays the route, los()/reachable() read true, nearest()
// snaps to identity — exactly the @doc-pinned fixture semantics, all pure. The
// failed/err fields carry the Nav.fail twin's failure (a path() on a failed Nav
// yields Result::Err(err)); Nav.of always builds a non-failed handle, so they
// sit at the zero value here until the §12 Nav.fail builder (a later story)
// seeds them — the shape is final so the twin lands without a value reshape.
Nav_Value :: struct {
	route:  Record_Value, // the Path route Nav.of was built from (steps/cost)
	failed: bool,         // the Nav.fail twin: path() yields Result::Err
	err:    string,       // the NavError variant Nav.fail's path() wraps
}

// Transform_Value is a §16 §7 local bone transform: translation, orientation,
// and scale relative to the parent bone (the engine.anim Transform record). The
// free builders rot_x/up construct it — rot_x(angle) is the identity translation
// with a quaternion rotation about the local X axis and unit scale; up(d) is a
// +Y translation with the identity rotation and unit scale. Its three component
// values are plain comparable structs, so equality is the bit-exact field match
// `pose_walk(…).get(Bone::LUpperLeg) == rot_x(0.0)` rests on (spec §10).
Transform_Value :: struct {
	pos:   Vec3_Value,
	rot:   Quat_Value,
	scale: Vec3_Value,
}

// Pose_Value is a §16 §7 sparse map of bone → local transform (the engine.anim
// Pose extern type). The bones it omits sit at rest, so a `.get` of an undriven
// bone reads the identity transform. The driven bones live in a DETERMINISTIC
// insert-ordered slice — never an iterated map — so the value an evaluation
// produces is machine-identical: `.set` appends (or overwrites in place), and
// blend/layer build the union of driven bones in a fixed order (the base/a
// bones in their order, then the overlay/b bones new to the result in theirs).
// Equality is by driven-bone set: two poses are equal iff they drive the same
// bones each with an equal transform, so insertion order never reaches the
// verdict (the same name-keyed shape Record_Value equality takes, spec §10).
Pose_Value :: struct {
	bones: []Pose_Bone_Transform,
}

// Pose_Bone_Transform is one driven bone of a Pose_Value: the Bone variant name
// (matching the Enum_Value identity Bone::LUpperLeg lowers to) and the local
// Transform it drives.
Pose_Bone_Transform :: struct {
	bone:      string, // the Bone variant name (e.g. "LUpperLeg")
	transform: Transform_Value,
}

List_Value :: struct {
	elements: []Value,
}

// Tuple_Value is a fixed-arity positional aggregate — the §04 §1 `(value,
// next_rng)` pair a draw/startup returns, and the `(Option, Rng)` shape a
// pick result carries. Equality is positional: two tuples are equal iff they
// have the same arity and every position compares equal (spec §10). A View.of
// list materializes as a List_Value, so a tuple never holds a View.
Tuple_Value :: struct {
	elements: []Value,
}

// Tilemap_Value is the §18 §4 test-position tile layer: the (cell, tile, solid)
// rows TilemapHandle.of(cell_size, cells) seeds, in the layer's own grid-local
// coordinate space anchored at the origin (the bake's world bounds and y-up
// flip belong to the runtime's baked handle, never to this fixture). The four
// queries read it: tile_at/solid_at scan the seeded rows — an unseeded cell
// reads None/not-solid, total, never a fault — cell_of floor-divides a world
// position by the cell size, and center_of reads a cell's center (origin +
// half cell). cell_type_name carries the seeded cells' record type so cell_of
// constructs cells of the user's own Cell type (the grid_cells discipline);
// it is "" when no cell was seeded, so an empty fixture's cell_of yields an
// untagged record that equals no user Cell — defined, just never equal.
Tilemap_Value :: struct {
	cell_size:      i64,
	cell_type_name: string,
	cells:          []Tilemap_Seed_Cell,
}

// Tilemap_Seed_Cell is one seeded row of a Tilemap_Value: the cell's integer
// grid coordinates and the (tile, solid) verdicts the queries answer with.
Tilemap_Seed_Cell :: struct {
	x:     i64,
	y:     i64,
	tile:  string,
	solid: bool,
}

// Input_Value is the test-position Input snapshot: the set of (player, action)
// button presses an inline test seeds via Input.empty().with_pressed(…). It is
// a §23 §2 read surface — pressed/released/held query whether a button is in
// the set; an absent (player, action) reads false. The set is identified by the
// player and action VARIANT names (PlayerId::P1, Move::Down), matching the
// evaluator's Enum_Value (type_name, variant) identity. value/axis read the
// analog channels, which a with_pressed snapshot never seeds, so they read the
// zero/zero-vector default — a behavior never faults on input.
Input_Value :: struct {
	pressed: []Input_Press,
}

// Input_Press is one held button in an Input snapshot: the player and action
// variant pair Input.with_pressed marked down-this-tick.
Input_Press :: struct {
	player: string, // the PlayerId variant (e.g. "P1")
	action: string, // the action variant (e.g. "Down")
}

// Time_Value is the test-position Time resource: the fixed frame delta and the
// accumulated logical time the Time.at(dt) double seeds (§04; engine.core.Time is
// `data Time { dt: Fixed, t: Fixed }`). `dt` is the per-tick delta in fixed
// seconds the hunt search countdown folds; `t` is logical time since startup,
// zero for a Time.at(dt) double (Time.at seeds t at zero, per the stdlib). Both
// member reads (`time.dt`, `time.t`) resolve to these fields.
Time_Value :: struct {
	dt: Fixed,
	t:  Fixed,
}

// Enum_Value is an enum variant value — a user enum (Side::Left, AppMsg::Hud(m))
// or an engine enum (Color::White, PlayerId::P1, Bus::Ui). A bare variant
// carries no payload (payload nil); a §21 §3 tagged-union variant carries its
// single payload value (AppMsg::Hud(HudMsg::Coin) → payload is the HudMsg::Coin
// Enum_Value). Equality is by (type_name, variant) AND payload: two variants are
// equal iff they name the same variant of the same enum and their payloads are
// equal (spec §10 demands matching tags; §03 §2 closes the variant set). The
// payload is a pointer because a union cannot contain itself by value.
Enum_Value :: struct {
	type_name: string,
	variant:   string,
	payload:   ^Value, // nil for a nullary variant; the single tuple payload otherwise
}

// Record_Value is a constructed record value: a user thing/data/signal
// (Goal{side: …}, Scoreboard{left: …}) or an engine struct-payload command
// variant (Draw::Rect{at: …}). type_name is the declared/engine type;
// variant is the struct-variant tag ("" for a plain record). fields carry
// the field name→value pairs in construction order; equality matches by
// field name, so construction order never reaches the result (§10).
Record_Value :: struct {
	type_name: string,
	variant:   string, // the engine struct-variant tag; "" for a plain record
	fields:    []Record_Field_Value,
}

// Record_Field_Value is one named field slot of a Record_Value.
Record_Field_Value :: struct {
	name:  string,
	value: Value,
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
	case string:
		// String equality is byte-exact (spec §10 demands matching tags). The §19
		// asset handle's `name` field compares this way, so a typed handle constant
		// equals the string-constructor handle iff they name the same asset.
		bv, ok := b.(string)
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
	case Tuple_Value:
		bv, ok := b.(Tuple_Value)
		if !ok || len(av.elements) != len(bv.elements) {
			return false
		}
		for element, i in av.elements {
			if !value_equal(element, bv.elements[i]) {
				return false
			}
		}
		return true
	case Input_Value:
		// Input snapshots have no value-equality in the surface (no test compares
		// two Inputs); comparing them is always false rather than promising a set
		// equality the language never defines.
		return false
	case Tilemap_Value:
		// A fixture tile layer has no value-equality in the surface either (no
		// test compares two layers); always false, the Input_Value discipline.
		return false
	case Nav_Value:
		// A fixture nav handle has no value-equality in the surface (no test
		// compares two Navs); always false, the Input_Value/Tilemap_Value
		// discipline — the route it carries is read through path(), never by
		// comparing handles.
		return false
	case Time_Value:
		bv, ok := b.(Time_Value)
		return ok && av.dt == bv.dt
	case Lambda_Value:
		// Functions have no extensional equality; comparing them is
		// always false rather than an identity check the language never
		// promises.
		return false
	case Enum_Value:
		bv, ok := b.(Enum_Value)
		if !ok || av.type_name != bv.type_name || av.variant != bv.variant {
			return false
		}
		// A nullary variant has no payload on either side; a §21 §3 tagged variant
		// compares its single payload (AppMsg::Hud(HudMsg::Coin) equals another iff
		// the inner HudMsg::Coin does). A payload present on one side only is a
		// mismatch — different variant arities never compare equal.
		if (av.payload == nil) != (bv.payload == nil) {
			return false
		}
		if av.payload == nil {
			return true
		}
		return value_equal(av.payload^, bv.payload^)
	case Record_Value:
		bv, ok := b.(Record_Value)
		if !ok || av.type_name != bv.type_name || av.variant != bv.variant {
			return false
		}
		return record_fields_equal(av.fields, bv.fields)
	case Transform_Value:
		// A Transform's three components (pos, rot, scale) are plain comparable
		// structs over the Fixed kernel, so equality is the bit-exact field match
		// — `rot_x(0.0)` from two sites builds the identical Transform (§10).
		bv, ok := b.(Transform_Value)
		return ok && av == bv
	case Pose_Value:
		bv, ok := b.(Pose_Value)
		return ok && pose_bones_equal(av.bones, bv.bones)
	}
	return false
}

// pose_bones_equal compares two driven-bone sets by bone name: every bone one
// pose drives must be driven by the other with an equal transform, and the two
// must drive the same number of bones. Matching by name (not slice position)
// makes insertion order irrelevant — two poses that drive the same bones in a
// different `.set` order compare equal (spec §10, the determinism tripwire).
pose_bones_equal :: proc(a, b: []Pose_Bone_Transform) -> bool {
	if len(a) != len(b) {
		return false
	}
	for driven in a {
		other, found := pose_bone_transform(b, driven.bone)
		if !found || driven.transform != other {
			return false
		}
	}
	return true
}

// pose_bone_transform reads the transform a pose drives on a bone by name — a
// linear lookup over the insert-ordered slice, so bone order never reaches the
// result. found = false when the pose leaves the bone at rest.
pose_bone_transform :: proc(bones: []Pose_Bone_Transform, bone: string) -> (transform: Transform_Value, found: bool) {
	for driven in bones {
		if driven.bone == bone {
			return driven.transform, true
		}
	}
	return Transform_Value{}, false
}

// record_fields_equal compares two record field sets by name: every field on
// one side must match a same-named field on the other with an equal value, and
// the two sides must carry the same field count. Matching by name (not
// position) makes construction order irrelevant — a `with`-update or a
// reordered literal compares equal to the canonical value (spec §10).
record_fields_equal :: proc(a, b: []Record_Field_Value) -> bool {
	if len(a) != len(b) {
		return false
	}
	for field in a {
		other, found := record_field_value(b, field.name)
		if !found || !value_equal(field.value, other) {
			return false
		}
	}
	return true
}

// record_field_value reads a field's value off a record value by name — a
// linear lookup, so field order never reaches the verdict.
record_field_value :: proc(fields: []Record_Field_Value, name: string) -> (value: Value, found: bool) {
	for field in fields {
		if field.name == name {
			return field.value, true
		}
	}
	return nil, false
}
