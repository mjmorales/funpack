package funpack_runtime

import "core:strings"

eval_match :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	scrutinee, scrut_ok := eval(interp, &node.children[0], env)
	if !scrut_ok {
		return nil, false
	}
	i := 1
	for i + 1 < len(node.children) {
		arm := &node.children[i]
		body := &node.children[i + 1]
		if arm.kind != .Arm {
			return nil, false
		}
		bound := Env {
			names  = make(map[string]Value, interp.allocator),
			parent = env,
		}
		if arm_matches(scrutinee, arm, &bound) {
			return eval(interp, body, &bound)
		}
		i += 2
	}
	return nil, false
}

arm_matches :: proc(scrutinee: Value, arm: ^Node, scope: ^Env) -> bool {
	pat := arm.fields[0]
	switch pat {
	case "wildcard":
		return true
	case "bare_binder":
		if len(arm.fields) >= 5 && arm.fields[4] != "_" {
			scope.names[arm.fields[4]] = scrutinee
		}
		return true
	case "bare_variant":
		v, is_variant := scrutinee.(Variant_Value)
		if !is_variant {
			return false
		}
		return v.case_name == arm.fields[2]
	case "variant_binds":
		v, is_variant := scrutinee.(Variant_Value)
		if !is_variant {
			return false
		}
		if v.case_name != arm.fields[2] {
			return false
		}
		binder_count := 0
		if n, n_ok := decode_int(arm.fields[3]); n_ok {
			binder_count = int(n)
		}
		if binder_count >= 1 && len(arm.fields) >= 5 {
			binder := arm.fields[4]
			if binder != "_" && v.payload != nil {
				scope.names[binder] = v.payload^
			}
		}
		return true
	case "struct_binds":
		return struct_arm_matches(scrutinee, arm, scope)
	case "tuple":
		return tuple_arm_matches(scrutinee, arm, scope)
	}
	return false
}

struct_arm_matches :: proc(scrutinee: Value, arm: ^Node, scope: ^Env) -> bool {
	case_name, payload, ok := struct_variant_payload(scrutinee)
	if !ok {
		return false
	}
	if case_name != arm.fields[2] {
		return false
	}
	field_count := 0
	if n, n_ok := decode_int(arm.fields[3]); n_ok {
		field_count = int(n)
	}
	for i in 0 ..< field_count {
		if 4 + i >= len(arm.fields) {
			return false
		}
		field_name := arm.fields[4 + i]
		if field_name == "_" {
			continue
		}
		column, present := payload[field_name]
		if !present {
			return false
		}
		scope.names[field_name] = column
	}
	return true
}

struct_variant_payload :: proc(scrutinee: Value) -> (case_name: string, columns: map[string]Value, ok: bool) {
	#partial switch v in scrutinee {
	case Variant_Value:
		if v.payload == nil {
			return "", nil, false
		}
		record, is_record := v.payload^.(Record_Value)
		if !is_record {
			return "", nil, false
		}
		return v.case_name, record.fields, true
	case Record_Value:
		sep := strings.index(v.type_name, "::")
		if sep < 0 {
			return "", nil, false
		}
		return v.type_name[sep + 2:], v.fields, true
	}
	return "", nil, false
}

tuple_arm_matches :: proc(scrutinee: Value, arm: ^Node, scope: ^Env) -> bool {
	tuple, is_tuple := scrutinee.(Tuple_Value)
	if !is_tuple {
		return false
	}
	if len(tuple.elements) != len(arm.children) {
		return false
	}
	for &sub_arm, i in arm.children {
		if sub_arm.kind != .Arm {
			return false
		}
		if !arm_matches(tuple.elements[i], &sub_arm, scope) {
			return false
		}
	}
	return true
}

eval_call :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	callee := &node.children[0]
	switch callee.kind {
	case .Field:
		return eval_method_call(interp, node, env)
	case .Name:
		return eval_named_call(interp, callee.fields[0], node, env)
	case .Int, .Fixed, .String, .Variant, .Record, .Recfield, .With, .List, .Tuple, .Call, .Lambda, .Unary, .Binary, .Match, .If_Expr, .Arm, .Let, .Let_Tuple, .If_Return, .Return, .Stub, .Block, .All:
		return nil, false
	}
	return nil, false
}

eval_method_call :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	field_node := &node.children[0]
	method := field_node.fields[0]
	recv_node := &field_node.children[0]
	if recv_node.kind == .Name {
		if ctor, is_ctor := eval_engine_constructor(interp, node, env, recv_node.fields[0], method); is_ctor {
			return ctor, true
		}
		if ctor, is_ctor := eval_audio_constructor(interp, recv_node.fields[0], method, node, env);
		   is_ctor {
			return ctor, true
		}
		if ctor, is_ctor := eval_nav_constructor(interp, recv_node.fields[0], method, node, env);
		   is_ctor {
			return ctor, true
		}
	}
	recv, recv_ok := eval(interp, recv_node, env)
	if !recv_ok {
		return nil, false
	}
	return eval_value_receiver_method(interp, recv, method, node, env)
}

eval_value_receiver_method :: proc(
	interp: ^Interp,
	recv: Value,
	method: string,
	node: ^Node,
	env: ^Env,
) -> (
	value: Value,
	ok: bool,
) {
	switch method {
	case "value":
		return eval_input_value(interp, node, env)
	case "axis":
		return eval_input_axis(interp, node, env)
	case "pressed":
		return eval_input_button(interp, node, env, pressed)
	case "released":
		return eval_input_button(interp, node, env, released)
	case "held":
		return eval_input_button(interp, node, env, held)
	case "apply_impulse":
		return eval_apply_impulse(interp, recv, node, env)
	}
	if pose, is_pose := recv.(Pose_Value); is_pose {
		return eval_pose_method(interp, node, env, pose, method)
	}
	if handle, is_handle := recv.(Handle_Value); is_handle {
		return eval_handle_method(interp, node, env, handle, method)
	}
	if record, is_record := recv.(Record_Value); is_record {
		if record.type_name == "TilemapHandle" {
			if result, tm_ok, is_tilemap := eval_tilemap_method(interp, node, env, record, method);
			   is_tilemap {
				return result, tm_ok
			}
		}
		if record.type_name == "NavHandle" {
			if result, nav_ok, is_nav := eval_nav_method(interp, node, env, record, method);
			   is_nav {
				return result, nav_ok
			}
		}
		if record.type_name == "Path" && method == "advance" {
			return eval_path_advance(interp, node, env, record)
		}
		if bent, is_audio := eval_audio_adder(interp, record, method, node, env); is_audio {
			return bent, true
		}
	}
	if nav, is_nav := recv.(Nav_Value); is_nav {
		return eval_nav_fixture_method(interp, nav, method, node, env)
	}
	if rng, is_rng := recv.(Rng); is_rng {
		switch method {
		case "next":
			return eval_rng_next(interp, rng, node)
		case "range":
			return eval_rng_range(interp, rng, node, env)
		case "chance":
			return eval_rng_chance(interp, rng, node, env)
		case "split":
			return eval_rng_split(interp, rng, node)
		case "pick":
			return eval_rng_pick(interp, rng, node, env)
		}
	}
	if list, is_list := recv.(List_Value); is_list {
		switch method {
		case "count":
			return eval_view_count(interp, list, node, env)
		case "at":
			return eval_view_at(interp, list, node, env)
		case "ref":
			return eval_view_ref(interp, list, node, env)
		case "resolve":
			return eval_view_resolve(interp, list, node, env)
		}
	}
	if m, is_map := recv.(Map_Value); is_map {
		return eval_map_method(interp, m, method, node, env)
	}
	return nil, false
}

eval_view_count :: proc(interp: ^Interp, view: List_Value, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 1 {
		return nil, false
	}
	return i64(len(view.elements)), true
}

eval_view_at :: proc(interp: ^Interp, view: List_Value, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	index_value, idx_ok := eval(interp, &node.children[1], env)
	if !idx_ok {
		return nil, false
	}
	index, is_int := index_value.(i64)
	if !is_int {
		return nil, false
	}
	if index < 0 || index >= i64(len(view.elements)) {
		return nil, false
	}
	return view.elements[index], true
}

eval_view_ref :: proc(interp: ^Interp, view: List_Value, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	index_value, idx_ok := eval(interp, &node.children[1], env)
	if !idx_ok {
		return nil, false
	}
	index, is_int := index_value.(i64)
	if !is_int {
		return nil, false
	}
	fields := make(map[string]Value, interp.allocator)
	fields["index"] = index
	return Record_Value{type_name = "Ref", fields = fields}, true
}

eval_view_resolve :: proc(interp: ^Interp, view: List_Value, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	ref_value, ref_ok := eval(interp, &node.children[1], env)
	if !ref_ok {
		return nil, false
	}
	ref, is_record := ref_value.(Record_Value)
	if !is_record || ref.type_name != "Ref" {
		return nil, false
	}
	index_value, has_index := ref.fields["index"]
	if !has_index {
		return nil, false
	}
	index, is_int := index_value.(i64)
	if !is_int {
		return nil, false
	}
	if index < 0 || index >= i64(len(view.elements)) {
		return none_value(), true
	}
	return some_value(interp, view.elements[index]), true
}

eval_audio_constructor :: proc(
	interp: ^Interp,
	type_name, member: string,
	node: ^Node,
	env: ^Env,
) -> (
	value: Value,
	is_ctor: bool,
) {
	if type_name != "Audio" || member != "track" {
		return nil, false
	}
	if len(node.children) != 3 {
		return nil, false
	}
	key, key_ok := eval(interp, &node.children[1], env)
	clip, clip_ok := eval(interp, &node.children[2], env)
	if !key_ok || !clip_ok {
		return nil, false
	}
	return audio_track_value(interp, key, clip), true
}

eval_apply_impulse :: proc(interp: ^Interp, recv: Value, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	body, is_record := recv.(Record_Value)
	if !is_record {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	push, is_vec2 := arg.(Vec2)
	if !is_vec2 {
		return nil, false
	}
	prior := VEC2_ZERO
	if existing, present := body.fields["impulse"]; present {
		if v, was_vec2 := existing.(Vec2); was_vec2 {
			prior = v
		}
	}
	merged := make(map[string]Value, interp.allocator)
	for k, v in body.fields {
		merged[k] = v
	}
	merged["impulse"] = vec2_add(prior, push)
	return Record_Value{type_name = body.type_name, fields = merged}, true
}

eval_engine_constructor :: proc(interp: ^Interp, node: ^Node, env: ^Env, type_name, method: string) -> (value: Value, is_ctor: bool) {
	switch type_name {
	case "Settings":
		if method == "defaults" {
			return settings_defaults(interp), true
		}
	case "Map":
		if method == "empty" {
			return Map_Value{}, true
		}
	}
	return eval_anim_constructor(interp, node, env, type_name, method)
}

settings_defaults :: proc(interp: ^Interp) -> Value {
	access_fields := make(map[string]Value, interp.allocator)
	access_fields["reduce_motion"] = false
	access := Record_Value{type_name = "Access", fields = access_fields}

	settings_fields := make(map[string]Value, interp.allocator)
	settings_fields["access"] = access
	return Record_Value{type_name = "Settings", fields = settings_fields}
}

resolve_input_action :: proc(
	interp: ^Interp,
	node: ^Node,
	env: ^Env,
) -> (
	player: PlayerId,
	action: ActionId,
	resolved: bool,
	ok: bool,
) {
	if len(node.children) < 3 {
		return {}, {}, false, false
	}
	player_val, player_ok := eval(interp, &node.children[1], env)
	action_val, action_ok := eval(interp, &node.children[2], env)
	if !player_ok || !action_ok {
		return {}, {}, false, false
	}
	player_variant, is_player := player_val.(Variant_Value)
	action_variant, is_action := action_val.(Variant_Value)
	if !is_player || !is_action {
		return {}, {}, false, false
	}
	resolved_player, player_resolved := player_from_string(player_variant.case_name)
	if !player_resolved {
		return {}, {}, false, true
	}
	def, action_found := registry_find(interp.registry, action_variant.enum_type, action_variant.case_name)
	if !action_found {
		return {}, {}, false, true
	}
	return resolved_player, def.id, true, true
}

eval_input_button :: proc(
	interp: ^Interp,
	node: ^Node,
	env: ^Env,
	reader: proc(input: Input, player: PlayerId, action: ActionId) -> bool,
) -> (
	result: Value,
	ok: bool,
) {
	player, action, resolved, args_ok := resolve_input_action(interp, node, env)
	if !args_ok {
		return nil, false
	}
	if !resolved {
		return false, true
	}
	return reader(interp.input, player, action), true
}

eval_input_value :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (result: Value, ok: bool) {
	player, action, resolved, args_ok := resolve_input_action(interp, node, env)
	if !args_ok {
		return nil, false
	}
	if !resolved {
		return Fixed(0), true
	}
	return value(interp.input, player, action), true
}

eval_input_axis :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (result: Value, ok: bool) {
	player, action, resolved, args_ok := resolve_input_action(interp, node, env)
	if !args_ok {
		return nil, false
	}
	if !resolved {
		return VEC2_ZERO, true
	}
	return axis(interp.input, player, action), true
}

eval_named_call :: proc(
	interp: ^Interp,
	name: string,
	node: ^Node,
	env: ^Env,
) -> (
	value: Value,
	ok: bool,
) {
	switch name {
	case "abs":
		return builtin_abs(interp, node, env)
	case "clamp":
		return builtin_clamp(interp, node, env)
	case "first":
		return builtin_first(interp, node, env)
	case "find":
		return builtin_first(interp, node, env)
	case "fold":
		return builtin_fold(interp, node, env)
	case "within":
		return builtin_within(interp, node, env)
	case "nearest_first":
		return builtin_nearest_first(interp, node, env)
	case "length":
		return builtin_length(interp, node, env)
	case "sin":
		return builtin_sin(interp, node, env)
	case "cos":
		return builtin_cos(interp, node, env)
	case "sqrt":
		return builtin_sqrt(interp, node, env)
	case "max":
		return builtin_max(interp, node, env)
	case "compare":
		return builtin_compare(interp, node, env)
	case "lerp":
		return builtin_lerp(interp, node, env)
	case "floor":
		return builtin_floor(interp, node, env)
	case "round":
		return builtin_round(interp, node, env)
	case "trunc":
		return builtin_trunc(interp, node, env)
	case "checked_div":
		return builtin_checked_div(interp, node, env)
	case "to_fixed":
		return builtin_to_fixed(interp, node, env)
	case "to_int":
		return builtin_trunc(interp, node, env)
	case "dot":
		return builtin_dot(interp, node, env)
	case "cross":
		return builtin_cross(interp, node, env)
	case "normalize":
		return builtin_normalize(interp, node, env)
	case "mesh":
		return builtin_mesh(interp, node, env)
	case "rot_x":
		return builtin_rot_x(interp, node, env)
	case "up":
		return builtin_up(interp, node, env)
	case "prepend":
		return builtin_prepend(interp, node, env)
	case "append":
		return builtin_append(interp, node, env)
	case "reverse":
		return builtin_reverse(interp, node, env)
	case "init":
		return builtin_init(interp, node, env)
	case "contains":
		return builtin_contains(interp, node, env)
	case "map":
		return builtin_map(interp, node, env)
	case "filter":
		return builtin_filter(interp, node, env)
	case "concat":
		return builtin_concat(interp, node, env)
	case "is_empty":
		return builtin_is_empty(interp, node, env)
	case "len":
		return builtin_len(interp, node, env)
	case "get":
		return builtin_get(interp, node, env)
	case "empty":
		return builtin_map_empty(interp, node, env)
	case "has":
		return builtin_map_has(interp, node, env)
	case "set":
		return builtin_map_set(interp, node, env)
	case "remove":
		return builtin_map_remove(interp, node, env)
	case "keys":
		return builtin_map_keys(interp, node, env)
	case "values":
		return builtin_map_values(interp, node, env)
	case "grid_cells":
		return builtin_grid_cells(interp, node, env)
	case "neighbors":
		return builtin_neighbors(interp, node, env)
	case "in_bounds":
		return builtin_in_bounds(interp, node, env)
	case "or_else":
		return builtin_or_else(interp, node, env)
	case "is_some":
		return builtin_is_some(interp, node, env)
	case "sound":
		return builtin_sound(interp, node, env)
	case "pick":
		return builtin_pick(interp, node, env)
	case "seed":
		return builtin_seed(interp, node, env)
	case "Spawn":
		return builtin_spawn(interp, node, env)
	case "Despawn":
		return builtin_despawn(interp, node, env)
	}
	if query := program_query(interp.program, name); query != nil {
		return eval_query_call(interp, query, node, env)
	}
	if fn := program_function(interp.program, name); fn != nil {
		return eval_user_call(interp, fn, node, env)
	}
	return nil, false
}

eval_user_call :: proc(
	interp: ^Interp,
	fn: ^Function_Decl,
	node: ^Node,
	env: ^Env,
) -> (
	value: Value,
	ok: bool,
) {
	arg_count := len(node.children) - 1
	if arg_count != len(fn.params) {
		return nil, false
	}
	scope := Env{names = make(map[string]Value, interp.allocator)}
	for param, i in fn.params {
		arg, arg_ok := eval(interp, &node.children[i + 1], env)
		if !arg_ok {
			return nil, false
		}
		scope.names[param.name] = arg
	}
	return eval_body(interp, fn.body, &scope)
}

builtin_abs :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	switch v in arg {
	case Fixed:
		return (v < 0 ? fixed_neg(v) : v), true
	case i64:
		return (v < 0 ? int_neg(v) : v), true
	case bool, Vec2, Ref, Record_Value, List_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value, Rng, Vec3, Transform_Value, Pose_Value, Handle_Value, Nav_Value, Map_Value:
		return nil, false
	}
	return nil, false
}

builtin_clamp :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 4 {
		return nil, false
	}
	x_val, x_ok := eval(interp, &node.children[1], env)
	lo_val, lo_ok := eval(interp, &node.children[2], env)
	hi_val, hi_ok := eval(interp, &node.children[3], env)
	if !x_ok || !lo_ok || !hi_ok {
		return nil, false
	}
	x, xf := as_fixed(x_val)
	lo, lof := as_fixed(lo_val)
	hi, hif := as_fixed(hi_val)
	if !xf || !lof || !hif {
		return nil, false
	}
	return fixed_clamp(x, lo, hi), true
}

builtin_length :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	if v2, is_vec2 := arg.(Vec2); is_vec2 {
		return vec2_length(v2), true
	}
	if v3, is_vec3 := arg.(Vec3); is_vec3 {
		return vec3_length(v3), true
	}
	return nil, false
}

builtin_sin :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	angle, is_fixed := as_fixed(arg)
	if !is_fixed {
		return nil, false
	}
	return fixed_sin(angle), true
}

builtin_cos :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	angle, is_fixed := as_fixed(arg)
	if !is_fixed {
		return nil, false
	}
	return fixed_cos(angle), true
}

builtin_sqrt :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	x, is_fixed := as_fixed(arg)
	if !is_fixed {
		return nil, false
	}
	return fixed_sqrt(x), true
}

builtin_max :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	a, a_ok := eval(interp, &node.children[1], env)
	b, b_ok := eval(interp, &node.children[2], env)
	if !a_ok || !b_ok {
		return nil, false
	}
	if af, a_fixed := a.(Fixed); a_fixed {
		bf, b_fixed := b.(Fixed)
		if !b_fixed {
			return nil, false
		}
		return (i64(af) >= i64(bf)) ? af : bf, true
	}
	if ai, a_int := a.(i64); a_int {
		bi, b_int := b.(i64)
		if !b_int {
			return nil, false
		}
		return (ai >= bi) ? ai : bi, true
	}
	return nil, false
}

builtin_compare :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	a, a_ok := eval(interp, &node.children[1], env)
	b, b_ok := eval(interp, &node.children[2], env)
	if !a_ok || !b_ok {
		return nil, false
	}
	if af, a_fixed := a.(Fixed); a_fixed {
		bf, b_fixed := b.(Fixed)
		if !b_fixed {
			return nil, false
		}
		return ordering_value(i64(af), i64(bf)), true
	}
	if ai, a_int := a.(i64); a_int {
		bi, b_int := b.(i64)
		if !b_int {
			return nil, false
		}
		return ordering_value(ai, bi), true
	}
	return nil, false
}

ordering_value :: proc(l, r: i64) -> Value {
	case_name := "Equal"
	if l < r {
		case_name = "Less"
	} else if l > r {
		case_name = "Greater"
	}
	return Variant_Value{enum_type = "Ordering", case_name = case_name}
}

builtin_lerp :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 4 {
		return nil, false
	}
	a_val, a_ok := eval(interp, &node.children[1], env)
	b_val, b_ok := eval(interp, &node.children[2], env)
	t_val, t_ok := eval(interp, &node.children[3], env)
	if !a_ok || !b_ok || !t_ok {
		return nil, false
	}
	a, af := as_fixed(a_val)
	b, bf := as_fixed(b_val)
	t, tf := as_fixed(t_val)
	if !af || !bf || !tf {
		return nil, false
	}
	return fixed_lerp(a, b, t), true
}

builtin_floor :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	x, ok2 := eval_single_fixed_arg(interp, node, env)
	if !ok2 {
		return nil, false
	}
	return fixed_floor(x), true
}

builtin_round :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	x, ok2 := eval_single_fixed_arg(interp, node, env)
	if !ok2 {
		return nil, false
	}
	return fixed_round(x), true
}

builtin_trunc :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	x, ok2 := eval_single_fixed_arg(interp, node, env)
	if !ok2 {
		return nil, false
	}
	return fixed_trunc(x), true
}

builtin_checked_div :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	a_val, a_ok := eval(interp, &node.children[1], env)
	b_val, b_ok := eval(interp, &node.children[2], env)
	if !a_ok || !b_ok {
		return nil, false
	}
	a, af := as_fixed(a_val)
	b, bf := as_fixed(b_val)
	if !af || !bf {
		return nil, false
	}
	quotient, has_quotient := fixed_checked_div(a, b)
	if !has_quotient {
		return none_value(), true
	}
	return some_value(interp, quotient), true
}

builtin_to_fixed :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	n, is_int := arg.(i64)
	if !is_int {
		return nil, false
	}
	return to_fixed(n), true
}

builtin_dot :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	a, a_ok := eval(interp, &node.children[1], env)
	b, b_ok := eval(interp, &node.children[2], env)
	if !a_ok || !b_ok {
		return nil, false
	}
	if a2, is_vec2 := a.(Vec2); is_vec2 {
		b2, b_vec2 := b.(Vec2)
		if !b_vec2 {
			return nil, false
		}
		return vec2_dot(a2, b2), true
	}
	if a3, is_vec3 := a.(Vec3); is_vec3 {
		b3, b_vec3 := b.(Vec3)
		if !b_vec3 {
			return nil, false
		}
		return vec3_dot(a3, b3), true
	}
	return nil, false
}

builtin_cross :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	a, a_ok := eval(interp, &node.children[1], env)
	b, b_ok := eval(interp, &node.children[2], env)
	if !a_ok || !b_ok {
		return nil, false
	}
	a3, a_vec3 := a.(Vec3)
	b3, b_vec3 := b.(Vec3)
	if !a_vec3 || !b_vec3 {
		return nil, false
	}
	return vec3_cross(a3, b3), true
}

builtin_normalize :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	if v2, is_vec2 := arg.(Vec2); is_vec2 {
		unit, _ := vec2_normalize(v2)
		return unit, true
	}
	if v3, is_vec3 := arg.(Vec3); is_vec3 {
		unit, _ := vec3_normalize(v3)
		return unit, true
	}
	return nil, false
}

eval_single_fixed_arg :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (x: Fixed, ok: bool) {
	if len(node.children) != 2 {
		return Fixed(0), false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return Fixed(0), false
	}
	return as_fixed(arg)
}

builtin_rot_x :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	angle, is_fixed := as_fixed(arg)
	if !is_fixed {
		return nil, false
	}
	return transform_rot_x(angle), true
}

builtin_up :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	d, is_fixed := as_fixed(arg)
	if !is_fixed {
		return nil, false
	}
	return transform_up(d), true
}

builtin_mesh :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	name, is_string := arg.(String_Value)
	if !is_string {
		return nil, false
	}
	fields := make(map[string]Value, interp.allocator)
	fields["name"] = String_Value{text = strings.clone(name.text, interp.allocator)}
	return Record_Value{type_name = "MeshHandle", fields = fields}, true
}

builtin_first :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	if !list_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	if len(node.children) >= 3 {
		pred_val, pred_ok := eval(interp, &node.children[2], env)
		if !pred_ok {
			return nil, false
		}
		pred, is_lambda := pred_val.(Lambda_Value)
		if !is_lambda {
			return nil, false
		}
		for elem in elements {
			result, result_ok := apply_lambda(interp, pred, elem)
			if !result_ok {
				return nil, false
			}
			if as_bool(result) {
				return some_value(interp, elem), true
			}
		}
		return none_value(), true
	}
	if len(elements) == 0 {
		return none_value(), true
	}
	return some_value(interp, elements[0]), true
}

builtin_fold :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 4 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	seed_val, seed_ok := eval(interp, &node.children[2], env)
	if !list_ok || !seed_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	combiner := &node.children[3]
	if combiner.kind == .Name {
		fn := program_function(interp.program, combiner.fields[0])
		if fn != nil && len(fn.params) == 2 {
			return fold_with_helper(interp, fn, elements, seed_val)
		}
	}
	combiner_val, combiner_ok := eval(interp, combiner, env)
	if !combiner_ok {
		return nil, false
	}
	lambda, is_lambda := combiner_val.(Lambda_Value)
	if !is_lambda || len(lambda.params) != 2 {
		return nil, false
	}
	acc := seed_val
	for elem in elements {
		next, next_ok := apply_two_arg_lambda(interp, lambda, acc, elem)
		if !next_ok {
			return nil, false
		}
		acc = next
	}
	return acc, true
}

fold_with_helper :: proc(
	interp: ^Interp,
	fn: ^Function_Decl,
	elements: []Value,
	seed: Value,
) -> (
	value: Value,
	ok: bool,
) {
	acc := seed
	for elem in elements {
		next, next_ok := apply_two_arg(interp, fn, acc, elem)
		if !next_ok {
			return nil, false
		}
		acc = next
	}
	return acc, true
}

builtin_prepend :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	elem_val, elem_ok := eval(interp, &node.children[1], env)
	list_val, list_ok := eval(interp, &node.children[2], env)
	if !elem_ok || !list_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	out := make([]Value, len(elements) + 1, interp.allocator)
	out[0] = elem_val
	for elem, i in elements {
		out[i + 1] = elem
	}
	return List_Value{elements = out}, true
}

builtin_append :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	elem_val, elem_ok := eval(interp, &node.children[2], env)
	if !list_ok || !elem_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	out := make([]Value, len(elements) + 1, interp.allocator)
	for elem, i in elements {
		out[i] = elem
	}
	out[len(elements)] = elem_val
	return List_Value{elements = out}, true
}

builtin_reverse :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	if !list_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	out := make([]Value, len(elements), interp.allocator)
	for elem, i in elements {
		out[len(elements) - 1 - i] = elem
	}
	return List_Value{elements = out}, true
}

builtin_init :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	if !list_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	if len(elements) == 0 {
		return List_Value{elements = make([]Value, 0, interp.allocator)}, true
	}
	out := make([]Value, len(elements) - 1, interp.allocator)
	for i in 0 ..< len(elements) - 1 {
		out[i] = elements[i]
	}
	return List_Value{elements = out}, true
}

builtin_contains :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	elem_val, elem_ok := eval(interp, &node.children[2], env)
	if !list_ok || !elem_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	for elem in elements {
		if values_equal(elem, elem_val) {
			return true, true
		}
	}
	return false, true
}

builtin_map :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	fn_val, fn_ok := eval(interp, &node.children[2], env)
	if !list_ok || !fn_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	lambda, is_lambda := fn_val.(Lambda_Value)
	if !is_lambda {
		return nil, false
	}
	out := make([]Value, len(elements), interp.allocator)
	for elem, i in elements {
		projected, projected_ok := apply_lambda(interp, lambda, elem)
		if !projected_ok {
			return nil, false
		}
		out[i] = projected
	}
	return List_Value{elements = out}, true
}

builtin_filter :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	pred_val, pred_ok := eval(interp, &node.children[2], env)
	if !list_ok || !pred_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	pred, is_lambda := pred_val.(Lambda_Value)
	if !is_lambda {
		return nil, false
	}
	kept := make([dynamic]Value, 0, len(elements), interp.allocator)
	for elem in elements {
		verdict, verdict_ok := apply_lambda(interp, pred, elem)
		if !verdict_ok {
			return nil, false
		}
		if as_bool(verdict) {
			append(&kept, elem)
		}
	}
	return List_Value{elements = kept[:]}, true
}

builtin_concat :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	a_val, a_ok := eval(interp, &node.children[1], env)
	b_val, b_ok := eval(interp, &node.children[2], env)
	if !a_ok || !b_ok {
		return nil, false
	}
	a_elements, a_elems_ok := as_elements(interp, a_val)
	b_elements, b_elems_ok := as_elements(interp, b_val)
	if !a_elems_ok || !b_elems_ok {
		return nil, false
	}
	out := make([]Value, len(a_elements) + len(b_elements), interp.allocator)
	for elem, i in a_elements {
		out[i] = elem
	}
	for elem, i in b_elements {
		out[len(a_elements) + i] = elem
	}
	return List_Value{elements = out}, true
}

builtin_is_empty :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	if !list_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	return len(elements) == 0, true
}

builtin_len :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	if !list_ok {
		return nil, false
	}
	if m, is_map := list_val.(Map_Value); is_map {
		return i64(len(m.entries)), true
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	return i64(len(elements)), true
}

map_find :: proc(m: Map_Value, key: Value) -> (index: int, found: bool) {
	for entry, i in m.entries {
		if values_equal(entry.key, key) {
			return i, true
		}
	}
	return -1, false
}

map_get_value :: proc(interp: ^Interp, m: Map_Value, key: Value) -> Value {
	if i, found := map_find(m, key); found {
		return some_value(interp, m.entries[i].value)
	}
	return none_value()
}

map_set_value :: proc(interp: ^Interp, m: Map_Value, key, val: Value) -> Map_Value {
	if i, found := map_find(m, key); found {
		out := make([]Map_Entry, len(m.entries), interp.allocator)
		copy(out, m.entries)
		out[i] = Map_Entry{key = m.entries[i].key, value = val}
		return Map_Value{entries = out}
	}
	out := make([]Map_Entry, len(m.entries) + 1, interp.allocator)
	copy(out, m.entries)
	out[len(m.entries)] = Map_Entry{key = key, value = val}
	return Map_Value{entries = out}
}

map_remove_value :: proc(interp: ^Interp, m: Map_Value, key: Value) -> Map_Value {
	i, found := map_find(m, key)
	if !found {
		return m
	}
	out := make([]Map_Entry, len(m.entries) - 1, interp.allocator)
	copy(out[:i], m.entries[:i])
	copy(out[i:], m.entries[i + 1:])
	return Map_Value{entries = out}
}

map_keys_value :: proc(interp: ^Interp, m: Map_Value) -> List_Value {
	out := make([]Value, len(m.entries), interp.allocator)
	for entry, i in m.entries {
		out[i] = entry.key
	}
	return List_Value{elements = out}
}

map_values_value :: proc(interp: ^Interp, m: Map_Value) -> List_Value {
	out := make([]Value, len(m.entries), interp.allocator)
	for entry, i in m.entries {
		out[i] = entry.value
	}
	return List_Value{elements = out}
}

builtin_map_empty :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 1 {
		return nil, false
	}
	return Map_Value{}, true
}

builtin_get :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	source, source_ok := eval(interp, &node.children[1], env)
	arg, arg_ok := eval(interp, &node.children[2], env)
	if !source_ok || !arg_ok {
		return nil, false
	}
	if m, is_map := source.(Map_Value); is_map {
		return map_get_value(interp, m, arg), true
	}
	elements, elems_ok := as_elements(interp, source)
	if !elems_ok {
		return nil, false
	}
	i, is_int := arg.(i64)
	if !is_int {
		return nil, false
	}
	if i < 0 || int(i) >= len(elements) {
		return none_value(), true
	}
	return some_value(interp, elements[i]), true
}

builtin_map_has :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	source, source_ok := eval(interp, &node.children[1], env)
	key, key_ok := eval(interp, &node.children[2], env)
	if !source_ok || !key_ok {
		return nil, false
	}
	m, is_map := source.(Map_Value)
	if !is_map {
		return nil, false
	}
	_, found := map_find(m, key)
	return found, true
}

builtin_map_set :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 4 {
		return nil, false
	}
	source, source_ok := eval(interp, &node.children[1], env)
	key, key_ok := eval(interp, &node.children[2], env)
	val, val_ok := eval(interp, &node.children[3], env)
	if !source_ok || !key_ok || !val_ok {
		return nil, false
	}
	m, is_map := source.(Map_Value)
	if !is_map {
		return nil, false
	}
	return map_set_value(interp, m, key, val), true
}

builtin_map_remove :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	source, source_ok := eval(interp, &node.children[1], env)
	key, key_ok := eval(interp, &node.children[2], env)
	if !source_ok || !key_ok {
		return nil, false
	}
	m, is_map := source.(Map_Value)
	if !is_map {
		return nil, false
	}
	return map_remove_value(interp, m, key), true
}

builtin_map_keys :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	source, source_ok := eval(interp, &node.children[1], env)
	if !source_ok {
		return nil, false
	}
	m, is_map := source.(Map_Value)
	if !is_map {
		return nil, false
	}
	return map_keys_value(interp, m), true
}

builtin_map_values :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	source, source_ok := eval(interp, &node.children[1], env)
	if !source_ok {
		return nil, false
	}
	m, is_map := source.(Map_Value)
	if !is_map {
		return nil, false
	}
	return map_values_value(interp, m), true
}

eval_map_method :: proc(interp: ^Interp, m: Map_Value, method: string, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	switch method {
	case "len":
		if len(node.children) != 1 {
			return nil, false
		}
		return i64(len(m.entries)), true
	case "keys":
		if len(node.children) != 1 {
			return nil, false
		}
		return map_keys_value(interp, m), true
	case "values":
		if len(node.children) != 1 {
			return nil, false
		}
		return map_values_value(interp, m), true
	case "get":
		if len(node.children) != 2 {
			return nil, false
		}
		key := eval(interp, &node.children[1], env) or_return
		return map_get_value(interp, m, key), true
	case "has":
		if len(node.children) != 2 {
			return nil, false
		}
		key := eval(interp, &node.children[1], env) or_return
		_, found := map_find(m, key)
		return found, true
	case "remove":
		if len(node.children) != 2 {
			return nil, false
		}
		key := eval(interp, &node.children[1], env) or_return
		return map_remove_value(interp, m, key), true
	case "set":
		if len(node.children) != 3 {
			return nil, false
		}
		key := eval(interp, &node.children[1], env) or_return
		val := eval(interp, &node.children[2], env) or_return
		return map_set_value(interp, m, key, val), true
	}
	return nil, false
}

builtin_grid_cells :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 4 {
		return nil, false
	}
	w_val, w_ok := eval(interp, &node.children[1], env)
	h_val, h_ok := eval(interp, &node.children[2], env)
	fn_val, fn_ok := eval(interp, &node.children[3], env)
	if !w_ok || !h_ok || !fn_ok {
		return nil, false
	}
	w, w_is_int := w_val.(i64)
	h, h_is_int := h_val.(i64)
	if !w_is_int || !h_is_int {
		return nil, false
	}
	lambda, is_lambda := fn_val.(Lambda_Value)
	if !is_lambda {
		return nil, false
	}
	count := (w > 0 && h > 0) ? int(w) * int(h) : 0
	out := make([]Value, count, interp.allocator)
	idx := 0
	for y in 0 ..< h {
		for x in 0 ..< w {
			cell, cell_ok := apply_two_arg_lambda(interp, lambda, x, y)
			if !cell_ok {
				return nil, false
			}
			out[idx] = cell
			idx += 1
		}
	}
	return List_Value{elements = out}, true
}

builtin_neighbors :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	x, y, type_name, is_cell := grid_cell_coords(arg)
	if !is_cell {
		return nil, false
	}
	offsets := [4][2]i64{{0, -1}, {-1, 0}, {1, 0}, {0, 1}}
	elements := make([]Value, 4, interp.allocator)
	for offset, i in offsets {
		fields := make(map[string]Value, interp.allocator)
		fields["x"] = x + offset[0]
		fields["y"] = y + offset[1]
		elements[i] = Record_Value{type_name = type_name, fields = fields}
	}
	return List_Value{elements = elements}, true
}

builtin_in_bounds :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	cell_val, cell_ok := eval(interp, &node.children[1], env)
	size_val, size_ok := eval(interp, &node.children[2], env)
	if !cell_ok || !size_ok {
		return nil, false
	}
	x, y, _, x_is_cell := grid_cell_coords(cell_val)
	sx, sy, _, size_is_cell := grid_cell_coords(size_val)
	if !x_is_cell || !size_is_cell {
		return nil, false
	}
	return x >= 0 && x < sx && y >= 0 && y < sy, true
}

grid_cell_coords :: proc(arg: Value) -> (x, y: i64, type_name: string, ok: bool) {
	record, is_record := arg.(Record_Value)
	if !is_record {
		return 0, 0, "", false
	}
	x_field, x_present := record.fields["x"]
	y_field, y_present := record.fields["y"]
	if !x_present || !y_present {
		return 0, 0, "", false
	}
	xi, x_is_int := x_field.(i64)
	yi, y_is_int := y_field.(i64)
	if !x_is_int || !y_is_int {
		return 0, 0, "", false
	}
	return xi, yi, record.type_name, true
}

builtin_or_else :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	option, option_ok := runtime_option_arg(interp, &node.children[1], env)
	if !option_ok {
		return nil, false
	}
	if option.case_name == "Some" && option.payload != nil {
		return option.payload^, true
	}
	return eval(interp, &node.children[2], env)
}

builtin_is_some :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	option, option_ok := runtime_option_arg(interp, &node.children[1], env)
	if !option_ok {
		return nil, false
	}
	return option.case_name == "Some", true
}

runtime_option_arg :: proc(interp: ^Interp, arg: ^Node, env: ^Env) -> (option: Variant_Value, ok: bool) {
	value, value_ok := eval(interp, arg, env)
	if !value_ok {
		return {}, false
	}
	variant, is_variant := value.(Variant_Value)
	if !is_variant || variant.enum_type != "Option" {
		return {}, false
	}
	return variant, true
}

builtin_pick :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	rng_val, rng_ok := eval(interp, &node.children[1], env)
	list_val, list_ok := eval(interp, &node.children[2], env)
	if !list_ok || !rng_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	rng, is_rng := rng_val.(Rng)
	if !is_rng {
		return nil, false
	}
	return rng_pick_reduce(interp, rng, elements), true
}

rng_pick_reduce :: proc(interp: ^Interp, rng: Rng, elements: []Value) -> Value {
	if len(elements) == 0 {
		_, advanced := rand_next(rng)
		return pick_tuple(interp, none_value(), advanced)
	}
	index, advanced := rand_bounded(rng, len(elements))
	return pick_tuple(interp, some_value(interp, elements[index]), advanced)
}

pick_tuple :: proc(interp: ^Interp, option: Value, advanced: Rng) -> Value {
	return rng_draw_tuple(interp, option, advanced)
}

rng_draw_tuple :: proc(interp: ^Interp, value: Value, advanced: Value) -> Value {
	elements := make([]Value, 2, interp.allocator)
	elements[0] = value
	elements[1] = advanced
	return Tuple_Value{elements = elements}
}

builtin_seed :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	n, is_int := arg.(i64)
	if !is_int {
		return nil, false
	}
	return rand_seed(n), true
}

eval_rng_next :: proc(interp: ^Interp, rng: Rng, node: ^Node) -> (value: Value, ok: bool) {
	if len(node.children) != 1 {
		return nil, false
	}
	drawn, advanced := rand_next_fixed(rng)
	return rng_draw_tuple(interp, drawn, advanced), true
}

eval_rng_range :: proc(interp: ^Interp, rng: Rng, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	lo_val, lo_ok := eval(interp, &node.children[1], env)
	hi_val, hi_ok := eval(interp, &node.children[2], env)
	if !lo_ok || !hi_ok {
		return nil, false
	}
	lo, lo_is_int := lo_val.(i64)
	hi, hi_is_int := hi_val.(i64)
	if !lo_is_int || !hi_is_int {
		return nil, false
	}
	drawn, advanced := rand_range(rng, lo, hi)
	return rng_draw_tuple(interp, drawn, advanced), true
}

eval_rng_chance :: proc(interp: ^Interp, rng: Rng, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	p_val, p_ok := eval(interp, &node.children[1], env)
	if !p_ok {
		return nil, false
	}
	p, p_is_fixed := as_fixed(p_val)
	if !p_is_fixed {
		return nil, false
	}
	drawn, advanced := rand_chance(rng, p)
	return rng_draw_tuple(interp, drawn, advanced), true
}

eval_rng_split :: proc(interp: ^Interp, rng: Rng, node: ^Node) -> (value: Value, ok: bool) {
	if len(node.children) != 1 {
		return nil, false
	}
	a, b := rand_split(rng)
	return rng_draw_tuple(interp, a, b), true
}

eval_rng_pick :: proc(interp: ^Interp, rng: Rng, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 2 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	if !list_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	return rng_pick_reduce(interp, rng, elements), true
}

builtin_spawn :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	return eval(interp, &node.children[1], env)
}

builtin_despawn :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	return Record_Value{type_name = "Despawn", fields = make(map[string]Value, interp.allocator)}, true
}

as_elements :: proc(interp: ^Interp, v: Value) -> (elements: []Value, ok: bool) {
	list, is_list := v.(List_Value)
	if !is_list {
		return nil, false
	}
	return list.elements, true
}

apply_lambda :: proc(interp: ^Interp, lambda: Lambda_Value, arg: Value) -> (value: Value, ok: bool) {
	if len(lambda.params) != 1 {
		return nil, false
	}
	scope := Env {
		names  = make(map[string]Value, interp.allocator),
		parent = lambda.captured,
	}
	scope.names[lambda.params[0]] = arg
	return eval(interp, lambda.body, &scope)
}

apply_two_arg_lambda :: proc(
	interp: ^Interp,
	lambda: Lambda_Value,
	a, b: Value,
) -> (
	value: Value,
	ok: bool,
) {
	if len(lambda.params) != 2 {
		return nil, false
	}
	scope := Env {
		names  = make(map[string]Value, interp.allocator),
		parent = lambda.captured,
	}
	scope.names[lambda.params[0]] = a
	scope.names[lambda.params[1]] = b
	return eval(interp, lambda.body, &scope)
}

apply_two_arg :: proc(
	interp: ^Interp,
	fn: ^Function_Decl,
	a, b: Value,
) -> (
	value: Value,
	ok: bool,
) {
	scope := Env{names = make(map[string]Value, interp.allocator)}
	scope.names[fn.params[0].name] = a
	scope.names[fn.params[1].name] = b
	return eval_body(interp, fn.body, &scope)
}

some_value :: proc(interp: ^Interp, v: Value) -> Value {
	boxed := new(Value, interp.allocator)
	boxed^ = v
	return Variant_Value{enum_type = "Option", case_name = "Some", payload = boxed}
}

none_value :: proc() -> Value {
	return Variant_Value{enum_type = "Option", case_name = "None"}
}
