// The §16 §7 pose/anim EVALUATION surface in the runtime interp: the Pose/Skeleton/
// PartSet builders draw_krognid's body folds end-to-end, so the body evaluates to a
// Draw3::Rigged record carrying skeleton/parts/pose/at. This is a DELIBERATE MIRROR
// of funpack/evaluate.odin's pose-evaluation arms (the same per-bone blend/layer
// math, the same rot_x/up transform builders, the same insert-ordered sparse-pose
// representation) under the kernel-copy-not-link invariant — the runtime carries no
// funpack import, so the math is copied and pinned bit-for-bit (the determinism bet:
// pose-driven replay folds the SAME Q32.32 transforms the funpack evaluator does).
//
// REPRESENTATION (the shape decision):
//   - A Pose is a Pose_Value: a sparse Bone→Transform map held as an INSERT-ORDERED
//     slice (Pose_Bone_Transform[]), never an Odin map — the order IS the result
//     under fixed-point arithmetic, so a deterministic insertion order is the
//     determinism tripwire (spec §10). An absent bone reads the rest transform.
//   - A Transform is a Transform_Value: {pos: Vec3, rot: Quat, scale: Vec3} — the
//     §16 §7 local transform rot_x/up build and blend/layer compose.
//   - A Skeleton and a PartSet are OPAQUE Handle_Value handles. A behavior reads
//     none of their fields by name; they compose only through their builders
//     (Skeleton.humanoid()/empty(), PartSet.empty().bind(...).mirror(...)) and land
//     verbatim in the Draw3::Rigged record. The handle carries its kind + an
//     ordered op log so two handles built the same way compare equal (the §03 Eq
//     the Rigged record's structural equality rests on) without modeling the
//     engine's internal rig geometry (which the frontend does not own anyway).
package funpack_runtime

import "core:strings"

// Transform_Value is a §16 §7 local bone transform: translation, orientation, and
// scale. rot_x/up build one, Pose.blend interpolates two (lerp pos/scale, slerp
// rot), Pose.get returns one (the rest/identity transform for an undriven bone).
Transform_Value :: struct {
	pos:   Vec3,
	rot:   Quat,
	scale: Vec3,
}

// Pose_Bone_Transform is one driven bone of a Pose_Value: the Bone variant name
// (the case_name a Bone::LUpperLeg Variant_Value lowers to) and the local
// transform the pose drives it with.
Pose_Bone_Transform :: struct {
	bone:      string,
	transform: Transform_Value,
}

// Pose_Value is a §16 §7 sparse Bone→Transform map: only the driven bones, in a
// deterministic insert order (a slice, never a map — the order is the result under
// fixed-point + saturation). A bone the pose never drives reads the rest transform.
Pose_Value :: struct {
	bones: []Pose_Bone_Transform,
}

// Handle_Op is one builder step recorded on an opaque anim handle: the method name
// and its serialized arguments (a Slot/Side variant case, a mesh handle name). Two
// handles compare equal iff their kind and op log match, so a Skeleton/PartSet
// built the same way through its builder chain is equal — the §03 Eq the Rigged
// record's structural equality folds through, with no rig geometry modeled.
Handle_Op :: struct {
	method: string,
	args:   []string,
}

// Handle_Value is an opaque engine.anim handle (a Skeleton or a PartSet). `kind` is
// the handle's engine type ("Skeleton"/"PartSet"); `factory` is the static
// constructor it was seeded from ("humanoid"/"empty"); `ops` is the ordered builder
// log (bind/mirror) layered on after. A behavior reads none of these by field — the
// handle composes through builders and lands verbatim in Draw3::Rigged.
Handle_Value :: struct {
	kind:    string,
	factory: string,
	ops:     []Handle_Op,
}

// transform_identity is the §16 §7 rest transform: no translation, the identity
// rotation, unit scale — the transform a Pose assigns a bone it does not drive
// (Pose.get of an undriven bone), and the base every rot_x/up builds off.
transform_identity :: proc() -> Transform_Value {
	return Transform_Value{
		pos   = Vec3{},
		rot   = QUAT_IDENTITY,
		scale = Vec3{x = FIXED_ONE, y = FIXED_ONE, z = FIXED_ONE},
	}
}

// transform_rot_x builds the §16 §7 rot_x(angle) Transform: the identity
// translation, a quaternion rotating `angle` radians about the local X axis, and
// unit scale. At angle 0 the quaternion is the identity (sin(0)=0, cos(0)=1), so
// rot_x(0.0) equals the rest transform — the zero-crossing the pose_walk golden
// asserts.
transform_rot_x :: proc(angle: Fixed) -> Transform_Value {
	t := transform_identity()
	t.rot = quat_axis_angle(Vec3{x = FIXED_ONE}, angle)
	return t
}

// transform_up builds the §16 §7 up(d) Transform: a translation of `d` along the
// local +Y axis, the identity rotation, and unit scale — the torso bob a pose
// generator drives the torso with.
transform_up :: proc(d: Fixed) -> Transform_Value {
	t := transform_identity()
	t.pos = Vec3{y = d}
	return t
}

// pose_bone_transform reads the transform a pose drives on a bone by name — a
// linear scan over the insert-ordered driven-bone slice, returning found=false
// when the bone is undriven (the rest-transform default lives at the call site).
pose_bone_transform :: proc(bones: []Pose_Bone_Transform, bone: string) -> (transform: Transform_Value, found: bool) {
	for driven in bones {
		if driven.bone == bone {
			return driven.transform, true
		}
	}
	return Transform_Value{}, false
}

// eval_anim_constructor resolves an engine.anim static constructor `Type.method()`:
// Pose.empty()/blend()/layer(), Skeleton.humanoid()/empty(), PartSet.empty(). It is
// the engine-provided builder surface §16 §7 names, reached from
// eval_engine_constructor (a type name is never an env binding). is_ctor is false
// for any (type, method) outside this set so the caller falls through.
eval_anim_constructor :: proc(interp: ^Interp, node: ^Node, env: ^Env, type_name, method: string) -> (value: Value, is_ctor: bool) {
	switch type_name {
	case "Pose":
		return eval_pose_static(interp, node, env, method)
	case "Skeleton":
		return eval_skeleton_static(interp, method)
	case "PartSet":
		return eval_partset_static(interp, method)
	}
	return nil, false
}

// eval_pose_static lowers the §16 §7 Pose Type-name static builders/combinators:
// empty() seeds the sparse pose a generator .set()s bones on; blend(a, b, weight)
// per-bone interpolates two poses; layer(base, overlay) lets the overlay win per
// bone. is_ctor is false for any other (member, arity) — a typecheck-rejected form
// that never reaches a passing program (fail-closed, never a panic).
eval_pose_static :: proc(interp: ^Interp, node: ^Node, env: ^Env, member: string) -> (value: Value, is_ctor: bool) {
	args := node.children[1:]
	switch member {
	case "empty":
		if len(args) != 0 {
			return nil, false
		}
		return Pose_Value{bones = make([]Pose_Bone_Transform, 0, interp.allocator)}, true
	case "blend":
		if len(args) != 3 {
			return nil, false
		}
		a, a_ok := eval_pose_arg(interp, &args[0], env)
		b, b_ok := eval_pose_arg(interp, &args[1], env)
		if !a_ok || !b_ok {
			return nil, false
		}
		weight_val, w_ok := eval(interp, &args[2], env)
		if !w_ok {
			return nil, false
		}
		w, is_fixed := as_fixed(weight_val)
		if !is_fixed {
			return nil, false
		}
		return eval_pose_blend(interp, a, b, w), true
	case "layer":
		if len(args) != 2 {
			return nil, false
		}
		base, base_ok := eval_pose_arg(interp, &args[0], env)
		overlay, over_ok := eval_pose_arg(interp, &args[1], env)
		if !base_ok || !over_ok {
			return nil, false
		}
		return eval_pose_layer(interp, base, overlay), true
	}
	return nil, false
}

// eval_skeleton_static lowers the §16 §7 Skeleton constructors humanoid()/empty()
// to an opaque Skeleton handle seeded from the named factory — krognid_skeleton()'s
// `Skeleton.humanoid()`. is_ctor is false for any other member (fail-closed).
eval_skeleton_static :: proc(interp: ^Interp, method: string) -> (value: Value, is_ctor: bool) {
	switch method {
	case "humanoid", "empty":
		return Handle_Value{kind = "Skeleton", factory = method, ops = make([]Handle_Op, 0, interp.allocator)}, true
	}
	return nil, false
}

// eval_partset_static lowers the §16 §7 PartSet constructor empty() to an opaque
// PartSet handle the .bind/.mirror adders chain onto — krognid_parts()'s seed.
// is_ctor is false for any other member (fail-closed).
eval_partset_static :: proc(interp: ^Interp, method: string) -> (value: Value, is_ctor: bool) {
	switch method {
	case "empty":
		return Handle_Value{kind = "PartSet", factory = method, ops = make([]Handle_Op, 0, interp.allocator)}, true
	}
	return nil, false
}

// eval_pose_method lowers the §16 §7 Pose value methods: set(Bone, Transform)
// returns a new pose driving the named bone (so a generator chains .set across
// bones), get(Bone) reads a bone's Transform (the rest transform when undriven). A
// non-Bone arg or a non-Transform value is ok=false (fail-closed).
eval_pose_method :: proc(interp: ^Interp, node: ^Node, env: ^Env, pose: Pose_Value, member: string) -> (value: Value, ok: bool) {
	args := node.children[1:]
	switch member {
	case "set":
		if len(args) != 2 {
			return nil, false
		}
		bone, bone_ok := eval_bone_arg(interp, &args[0], env)
		if !bone_ok {
			return nil, false
		}
		transform_value, tv_ok := eval(interp, &args[1], env)
		if !tv_ok {
			return nil, false
		}
		transform, is_transform := transform_value.(Transform_Value)
		if !is_transform {
			return nil, false
		}
		return eval_pose_set(interp, pose, bone, transform), true
	case "get":
		if len(args) != 1 {
			return nil, false
		}
		bone, bone_ok := eval_bone_arg(interp, &args[0], env)
		if !bone_ok {
			return nil, false
		}
		return eval_pose_get(pose, bone), true
	}
	return nil, false
}

// eval_pose_set returns a new pose driving `bone` with `transform`: a re-`.set` of
// an existing driven bone overwrites in place (replace, never duplicate), a new
// bone appends — keeping the driven-bone slice in a deterministic insert order,
// never a map (the determinism tripwire). The input pose is never mutated (a fresh
// slice copy).
eval_pose_set :: proc(interp: ^Interp, pose: Pose_Value, bone: string, transform: Transform_Value) -> Value {
	for driven, i in pose.bones {
		if driven.bone == bone {
			next := make([]Pose_Bone_Transform, len(pose.bones), interp.allocator)
			copy(next, pose.bones)
			next[i].transform = transform
			return Pose_Value{bones = next}
		}
	}
	next := make([]Pose_Bone_Transform, len(pose.bones) + 1, interp.allocator)
	copy(next, pose.bones)
	next[len(pose.bones)] = Pose_Bone_Transform{bone = bone, transform = transform}
	return Pose_Value{bones = next}
}

// eval_pose_get reads the transform a pose drives on `bone`, or the rest (identity)
// transform when the pose leaves it undriven — the §16 §7 "absent bones default to
// rest" rule a sparse-pose comparison rests on (Pose.get of an undriven bone ==
// identity == rot_x(0.0)).
eval_pose_get :: proc(pose: Pose_Value, bone: string) -> Value {
	if transform, found := pose_bone_transform(pose.bones, bone); found {
		return transform
	}
	return transform_identity()
}

// eval_pose_blend per-bone interpolates two poses by `weight` (§16 §7): for every
// bone EITHER pose drives, the result drives the lerp from a's transform (a's
// driven value, or rest when a omits it) to b's (b's driven value, or rest when b
// omits it) — so a blend of disjoint bone sets keeps every bone, each interpolating
// against the other pose's rest. The driven-bone union is built in a deterministic
// order: a's bones in their order, then b's bones new to the result in theirs. At
// weight 0 every bone reads a's transform, at weight 1 b's (the slerp/lerp endpoint
// identity).
eval_pose_blend :: proc(interp: ^Interp, a, b: Pose_Value, weight: Fixed) -> Value {
	bones := make([dynamic]Pose_Bone_Transform, 0, len(a.bones) + len(b.bones), interp.allocator)
	for driven in a.bones {
		// b's side falls back to rest (identity) when b omits the bone — the §16 §7
		// absent-bone rule, matching the b-only loop below (which rests a's side) and
		// eval_pose_get. Without this, a bone a drives but b omits would blend toward
		// the zero-value transform (a degenerate {0,0,0,0} quat), not rest.
		other, found := pose_bone_transform(b.bones, driven.bone)
		if !found {
			other = transform_identity()
		}
		append(&bones, Pose_Bone_Transform{
			bone      = driven.bone,
			transform = transform_blend(driven.transform, other, weight),
		})
	}
	for driven in b.bones {
		if _, already := pose_bone_transform(a.bones, driven.bone); already {
			continue
		}
		append(&bones, Pose_Bone_Transform{
			bone      = driven.bone,
			transform = transform_blend(transform_identity(), driven.transform, weight),
		})
	}
	return Pose_Value{bones = bones[:]}
}

// transform_blend interpolates two transforms: position and scale lerp
// component-wise, orientation slerps — the §16 §7 "lerp position, slerp rotation"
// rule. quat_slerp returns its endpoints bit-exactly, so a weight of 0 yields a and
// 1 yields b without recomputation.
transform_blend :: proc(a, b: Transform_Value, weight: Fixed) -> Transform_Value {
	return Transform_Value{
		pos   = vec3_lerp(a.pos, b.pos, weight),
		rot   = quat_slerp(a.rot, b.rot, weight),
		scale = vec3_lerp(a.scale, b.scale, weight),
	}
}

// eval_pose_layer composes two poses by override (§16 §7): the overlay's bones
// replace the base's, the base shows through elsewhere — overlay wins per bone. The
// result is the base's driven bones (each overwritten by the overlay where it
// drives the same bone) followed by the overlay's bones new to the base, in a
// deterministic order.
eval_pose_layer :: proc(interp: ^Interp, base, overlay: Pose_Value) -> Value {
	bones := make([dynamic]Pose_Bone_Transform, 0, len(base.bones) + len(overlay.bones), interp.allocator)
	for driven in base.bones {
		if over, wins := pose_bone_transform(overlay.bones, driven.bone); wins {
			append(&bones, Pose_Bone_Transform{bone = driven.bone, transform = over})
		} else {
			append(&bones, driven)
		}
	}
	for driven in overlay.bones {
		if _, already := pose_bone_transform(base.bones, driven.bone); already {
			continue
		}
		append(&bones, driven)
	}
	return Pose_Value{bones = bones[:]}
}

// eval_handle_method lowers the §16 §7 PartSet value-method adders bind(Slot, mesh)
// and mirror(Side, Side): each returns a NEW handle with one op appended, so they
// chain (krognid_parts()'s .bind(...).bind(...).mirror(...)). The args serialize to
// strings (a Slot/Side variant case, the mesh handle's name) so two handles built
// the same way compare equal. is_handle_method is false for any other member.
eval_handle_method :: proc(interp: ^Interp, node: ^Node, env: ^Env, handle: Handle_Value, member: string) -> (value: Value, is_handle_method: bool) {
	args := node.children[1:]
	switch member {
	case "bind":
		if len(args) != 2 {
			return nil, false
		}
		slot, slot_ok := eval_variant_case_arg(interp, &args[0], env)
		mesh, mesh_ok := eval_mesh_name_arg(interp, &args[1], env)
		if !slot_ok || !mesh_ok {
			return nil, false
		}
		return handle_append_op(interp, handle, "bind", slot, mesh), true
	case "mirror":
		if len(args) != 2 {
			return nil, false
		}
		from, from_ok := eval_variant_case_arg(interp, &args[0], env)
		to, to_ok := eval_variant_case_arg(interp, &args[1], env)
		if !from_ok || !to_ok {
			return nil, false
		}
		return handle_append_op(interp, handle, "mirror", from, to), true
	}
	return nil, false
}

// handle_append_op returns a new handle with one builder op (method + serialized
// args) appended to the op log, leaving the input handle's op slice untouched (a
// fresh copy) so the builder chain is a functional accumulation, never a mutation.
handle_append_op :: proc(interp: ^Interp, handle: Handle_Value, method: string, args: ..string) -> Value {
	op_args := make([]string, len(args), interp.allocator)
	for arg, i in args {
		op_args[i] = strings.clone(arg, interp.allocator)
	}
	next := make([]Handle_Op, len(handle.ops) + 1, interp.allocator)
	copy(next, handle.ops)
	next[len(handle.ops)] = Handle_Op{method = strings.clone(method, interp.allocator), args = op_args}
	return Handle_Value{kind = handle.kind, factory = handle.factory, ops = next}
}

// eval_pose_arg evaluates an expression expected to be a Pose value — the shape
// blend/layer read their pose arguments through. ok=false on a non-Pose value (a
// typecheck-rejected shape that never reaches a passing test).
eval_pose_arg :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (pose: Pose_Value, ok: bool) {
	value, value_ok := eval(interp, node, env)
	if !value_ok {
		return Pose_Value{}, false
	}
	pose, ok = value.(Pose_Value)
	return
}

// eval_bone_arg evaluates an argument expected to be a Bone variant and returns its
// case name — the key a Pose drives a transform on. ok=false on a non-variant arg
// (fail-closed).
eval_bone_arg :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (bone: string, ok: bool) {
	return eval_variant_case_arg(interp, node, env)
}

// eval_variant_case_arg evaluates an argument expected to be a bare enum variant
// (Bone::LUpperLeg, Slot::Torso, Side::L) and returns its case name — the
// serialized key the pose/handle builders drive an op on. ok=false on a non-variant
// value (fail-closed).
eval_variant_case_arg :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (case_name: string, ok: bool) {
	value, value_ok := eval(interp, node, env)
	if !value_ok {
		return "", false
	}
	variant, is_variant := value.(Variant_Value)
	if !is_variant {
		return "", false
	}
	return variant.case_name, true
}

// eval_mesh_name_arg evaluates a mesh-handle argument (mesh("krognid_torso") or a
// typed MeshHandle record) and returns the asset name it carries — the value
// serialized into a PartSet bind op. ok=false when the value is neither a mesh
// handle record nor a bare String (fail-closed).
eval_mesh_name_arg :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (name: string, ok: bool) {
	value, value_ok := eval(interp, node, env)
	if !value_ok {
		return "", false
	}
	#partial switch v in value {
	case Record_Value:
		field, present := v.fields["name"]
		if !present {
			return "", false
		}
		text, is_string := field.(String_Value)
		if !is_string {
			return "", false
		}
		return text.text, true
	case String_Value:
		return v.text, true
	}
	return "", false
}

// transforms_equal compares two §16 §7 transforms by their kernel-stable Q32.32
// bits, component by component — the structural equality the pose asserts
// (Pose.get(...) == rot_x(0.0)) fold through.
transforms_equal :: proc(a, b: Transform_Value) -> bool {
	return(
		a.pos == b.pos &&
		a.rot == b.rot &&
		a.scale == b.scale \
	)
}

// poses_equal compares two poses per bone (§16 §7): every bone either drives must
// drive the same transform in the other (an undriven bone reading rest is NOT equal
// to a driven-to-rest bone — the §03 Eq is over the explicit driven set), and the
// driven sets must have the same size. The comparison is order-independent (the
// driven set is the canonical content), matching funpack's pose_bones_equal.
poses_equal :: proc(a, b: Pose_Value) -> bool {
	if len(a.bones) != len(b.bones) {
		return false
	}
	for driven in a.bones {
		other, found := pose_bone_transform(b.bones, driven.bone)
		if !found || !transforms_equal(driven.transform, other) {
			return false
		}
	}
	return true
}

// handles_equal compares two opaque anim handles by kind, factory, and the ordered
// builder op log — two handles built through the same constructor + builder chain
// are equal (the §03 Eq the Rigged record's structural equality folds through),
// with no rig geometry modeled.
handles_equal :: proc(a, b: Handle_Value) -> bool {
	if a.kind != b.kind || a.factory != b.factory || len(a.ops) != len(b.ops) {
		return false
	}
	for op, i in a.ops {
		other := b.ops[i]
		if op.method != other.method || len(op.args) != len(other.args) {
			return false
		}
		for arg, j in op.args {
			if arg != other.args[j] {
				return false
			}
		}
	}
	return true
}
