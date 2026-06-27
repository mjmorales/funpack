package funpack_runtime

import "core:strings"

Transform_Value :: struct {
	pos:   Vec3,
	rot:   Quat,
	scale: Vec3,
}

Pose_Bone_Transform :: struct {
	bone:      string,
	transform: Transform_Value,
}

Pose_Value :: struct {
	bones: []Pose_Bone_Transform,
}

Handle_Op :: struct {
	method: string,
	args:   []string,
}

Handle_Value :: struct {
	kind:    string,
	factory: string,
	ops:     []Handle_Op,
}

transform_identity :: proc() -> Transform_Value {
	return Transform_Value{
		pos   = Vec3{},
		rot   = QUAT_IDENTITY,
		scale = Vec3{x = FIXED_ONE, y = FIXED_ONE, z = FIXED_ONE},
	}
}

transform_rot_x :: proc(angle: Fixed) -> Transform_Value {
	t := transform_identity()
	t.rot = quat_axis_angle(Vec3{x = FIXED_ONE}, angle)
	return t
}

transform_up :: proc(d: Fixed) -> Transform_Value {
	t := transform_identity()
	t.pos = Vec3{y = d}
	return t
}

pose_bone_transform :: proc(bones: []Pose_Bone_Transform, bone: string) -> (transform: Transform_Value, found: bool) {
	for driven in bones {
		if driven.bone == bone {
			return driven.transform, true
		}
	}
	return Transform_Value{}, false
}

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

eval_skeleton_static :: proc(interp: ^Interp, method: string) -> (value: Value, is_ctor: bool) {
	switch method {
	case "humanoid", "empty":
		return Handle_Value{kind = "Skeleton", factory = method, ops = make([]Handle_Op, 0, interp.allocator)}, true
	}
	return nil, false
}

eval_partset_static :: proc(interp: ^Interp, method: string) -> (value: Value, is_ctor: bool) {
	switch method {
	case "empty":
		return Handle_Value{kind = "PartSet", factory = method, ops = make([]Handle_Op, 0, interp.allocator)}, true
	}
	return nil, false
}

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

eval_pose_get :: proc(pose: Pose_Value, bone: string) -> Value {
	if transform, found := pose_bone_transform(pose.bones, bone); found {
		return transform
	}
	return transform_identity()
}

eval_pose_blend :: proc(interp: ^Interp, a, b: Pose_Value, weight: Fixed) -> Value {
	bones := make([dynamic]Pose_Bone_Transform, 0, len(a.bones) + len(b.bones), interp.allocator)
	for driven in a.bones {
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

transform_blend :: proc(a, b: Transform_Value, weight: Fixed) -> Transform_Value {
	return Transform_Value{
		pos   = vec3_lerp(a.pos, b.pos, weight),
		rot   = quat_slerp(a.rot, b.rot, weight),
		scale = vec3_lerp(a.scale, b.scale, weight),
	}
}

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

eval_pose_arg :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (pose: Pose_Value, ok: bool) {
	value, value_ok := eval(interp, node, env)
	if !value_ok {
		return Pose_Value{}, false
	}
	pose, ok = value.(Pose_Value)
	return
}

eval_bone_arg :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (bone: string, ok: bool) {
	return eval_variant_case_arg(interp, node, env)
}

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

eval_mesh_name_arg :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (name: string, ok: bool) {
	value, value_ok := eval(interp, node, env)
	if !value_ok {
		return "", false
	}
	return handle_value_name(value)
}

transforms_equal :: proc(a, b: Transform_Value) -> bool {
	return(
		a.pos == b.pos &&
		a.rot == b.rot &&
		a.scale == b.scale \
	)
}

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
