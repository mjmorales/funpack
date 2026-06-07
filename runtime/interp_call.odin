// The call and match halves of the interpreter (interp.odin): user-function and
// engine-builtin application, and pattern matching over a scrutinee. Kept beside
// the expression core so the value model and the dispatch that consumes it read
// as one engine; the split is by surface (expression forms vs application/match),
// not by layer.
//
// A `call` is one of three things, decided by its callee node: a method-style
// `recv.method(args)` (a `field` callee — the §23 Input resource queries
// `value`/`axis`/`pressed`/`released`/`held`, the record-intent `body.apply_impulse`
// over a Body column, and the engine static constructor `Settings.defaults()`), an
// engine builtin (the §08/§26 leaf combinators —
// `abs`, `clamp`, the §10 `length`, `first`, `fold`, the §08 list set `prepend`/
// `init`/`contains`/`map`/`filter`/`concat`/`is_empty`/`len`, the §26
// `engine.grid.grid_cells`, `Spawn`,
// a record constructor), or a user §9 helper (`advance`, `overlaps`, `add_goal`,
// …) evaluated by binding its args to its params and folding its body. No float
// (spec §10); every numeric path is the fixed.odin kernel.
//
// Match patterns span the closed §2.5 arm set: bare/binding variant arms, the
// struct-field-pun `Enum::Case{f}` (yard's `Shape2::Box{size}`), tuple
// destructure, and the wildcard.
package funpack_runtime

import "core:strings"

// --- match ----------------------------------------------------------------

// eval_match evaluates `match SCRUTINEE { arm => body, … }`: child[0] is the
// scrutinee, the remaining children alternate arm/body. The FIRST arm whose
// pattern matches the scrutinee wins; its body evaluates with the arm's binders
// bound, in a fresh child scope. A match with no matching arm is ok=false (the
// checked AST makes pong's matches exhaustive — Option has Some+None, Side has
// Left+Right — so an unmatched scrutinee is a malformed body).
eval_match :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	scrutinee, scrut_ok := eval(interp, &node.children[0], env)
	if !scrut_ok {
		return nil, false
	}
	// Children after the scrutinee pair up arm/body in source order.
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

// arm_matches tests one arm's pattern against the scrutinee, binding the arm's
// payload/positional binders into `scope` on a match. The closed pattern kinds
// (§2.7 arm `pat` field): `bare_variant Enum Case` matches a variant by case name
// with no binder; `variant_binds Enum Case BINDER_COUNT binders…` matches the case
// and binds its payload (Option::Some(side) binds `side`, a `_` binder discards);
// `wildcard - -` matches anything; `bare_binder - - 1 name` binds the WHOLE
// scrutinee to `name` (snake's `next` tuple position); `tuple - - 0` destructures a
// tuple scrutinee position-by-position, recursing into each positional sub-pattern
// (a nested arm child). The recursion makes the nested `(Option::Some(cell), next)`
// shape — a variant pattern inside a tuple pattern — match by the same per-position
// arm test (§04 §1, snake's `match pick(free, rng)`).
arm_matches :: proc(scrutinee: Value, arm: ^Node, scope: ^Env) -> bool {
	pat := arm.fields[0]
	switch pat {
	case "wildcard":
		return true
	case "bare_binder":
		// A bare binder binds the whole position to its single binder name (a `_` is
		// the wildcard, handled above). fields: pat, type, case, binder_count, name.
		if len(arm.fields) >= 5 && arm.fields[4] != "_" {
			scope.names[arm.fields[4]] = scrutinee
		}
		return true
	case "bare_variant":
		v, is_variant := scrutinee.(Variant_Value)
		if !is_variant {
			return false
		}
		// fields: pat, enum, case — match by case name (the enum is the same type).
		return v.case_name == arm.fields[2]
	case "variant_binds":
		v, is_variant := scrutinee.(Variant_Value)
		if !is_variant {
			return false
		}
		if v.case_name != arm.fields[2] {
			return false
		}
		// fields: pat, enum, case, binder_count, binders… — bind the first binder
		// to the variant's payload (pong's Some(x) binds one; `_` discards).
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

// struct_arm_matches tests the §2.5 struct-field-pun pattern `Enum::Case{f, …}`
// (yard's `Shape2::Box{size} => size`): it matches a struct-payload variant value
// of the named case, then binds EACH named field of the pattern to the same-named
// payload column (the pun — `{size}` binds `size` to `payload.size`, not the whole
// payload). fields: pat, enum, case, field_count, field_names…  A `_` field name
// discards; a payload missing a punned field is a non-match (the case carries no
// such column). Distinct from variant_binds, which binds the WHOLE payload to one
// binder rather than punning its struct fields.
//
// The scrutinee arrives in EITHER of the two shapes a struct-payload variant value
// takes on this runtime: a Variant_Value whose payload is the struct Record_Value
// (a hand-built or combinator-produced enum value), OR — the EMITTED form (seam #1)
// — a `::`-named Record_Value the funpack emitter serializes a `Shape2::Box{size}`
// expression into (a `record Type::Case` node, eval_record). struct_variant_payload
// normalizes both to (case_name, payload columns), so a struct-pun arm matches a
// struct-variant VALUE whether it was hand-built or emitted-and-loaded.
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

// struct_variant_payload normalizes a struct-payload variant value to its case name
// and its payload columns, accepting both runtime shapes (seam #1): a Variant_Value
// whose boxed payload is the struct Record_Value, and the EMITTED `::`-named
// Record_Value (`Shape2::Box`) the funpack emitter produces for a struct-payload
// variant expression. ok is false for any other value (a bare variant, a plain
// record, a scalar) — a non-struct-variant scrutinee never matches a struct-pun arm.
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
		// The emitted form: a `::`-named record IS the struct-variant value, its
		// case the segment after `::` and its columns the record's own fields.
		sep := strings.index(v.type_name, "::")
		if sep < 0 {
			return "", nil, false
		}
		return v.type_name[sep + 2:], v.fields, true
	}
	return "", nil, false
}

// tuple_arm_matches destructures a tuple scrutinee against a tuple pattern arm: the
// arm's CHILDREN are its positional sub-pattern arms (one per tuple position), and
// each child is tested against the scrutinee's element at the same position by a
// recursive arm_matches. An arm matches only when its arity equals the scrutinee's
// and EVERY position matches; binders from every position accumulate into the one
// shared scope, so `(Option::Some(cell), next)` binds both `cell` (from the nested
// variant arm) and `next` (from the bare-binder arm) for the body. A non-tuple
// scrutinee, an arity mismatch, or any position miss is a non-match — the tick's
// (Rng, [Spawn]) split and snake's pick-result match both route through here.
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

// --- call -----------------------------------------------------------------

// eval_call applies a call node. The callee (child[0]) decides the form: a
// `field` callee is a method-style `recv.method(args)` (a resource query, a record
// intent, or an engine static constructor — see eval_method_call); a `name` callee
// is an engine builtin or a user §9 helper. Args are children[1:], evaluated
// left-to-right so evaluation order is deterministic.
eval_call :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	callee := &node.children[0]
	switch callee.kind {
	case .Field:
		return eval_method_call(interp, node, env)
	case .Name:
		return eval_named_call(interp, callee.fields[0], node, env)
	case .Int, .Fixed, .String, .Variant, .Record, .Recfield, .With, .List, .Tuple, .Call, .Lambda, .Unary, .Binary, .Match, .Arm, .Let, .If_Return, .Return:
		return nil, false
	}
	return nil, false
}

// eval_method_call evaluates `recv.method(args)` — the resource-query, the
// record-intent, and the engine static-constructor forms. The receiver is the
// `field` callee's child; the method name is its field token. Two receiver
// classes reach here: the Input snapshot (the §23 1D `value` / 2D `axis` analog
// reads and the digital `pressed`/`released`/`held` Button reads) and a record
// column carrying an intent method (yard's `body.apply_impulse(j)`, a Body record
// receiver). A THIRD form has no value receiver at all — an engine static
// constructor `Type.method()` (yard's `Settings.defaults()`) whose receiver is a
// type name, resolved before the receiver is evaluated. An unknown receiver/
// method is ok=false.
eval_method_call :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	field_node := &node.children[0]
	method := field_node.fields[0]
	// An engine static constructor `Type.method()` has a TYPE-NAME receiver, not a
	// value — intercept it before evaluating the receiver (a type name is not a
	// local, so eval would fail-closed on it). The receiver child is the bare type
	// name node.
	recv_node := &field_node.children[0]
	if recv_node.kind == .Name {
		if ctor, is_ctor := eval_engine_constructor(interp, node, env, recv_node.fields[0], method); is_ctor {
			return ctor, true
		}
		// The §22 §2 sustained-audio builder seed `Audio.track(key, clip)` is a
		// TYPE-NAME static constructor that takes args — intercepted here (before the
		// `Audio` name is evaluated as a local, which would fail-closed) the same way
		// the no-arg engine constructors are. The .pitch/.gain/.bus/.at adders chain
		// off the built record value (the value-receiver arm below).
		if ctor, is_ctor := eval_audio_constructor(interp, recv_node.fields[0], method, node, env);
		   is_ctor {
			return ctor, true
		}
	}
	recv, recv_ok := eval(interp, recv_node, env)
	if !recv_ok {
		return nil, false
	}
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
	// A §16 §7 value-method on a built anim value: Pose.set/get drive/read a bone
	// (the receiver is a Pose chained from Pose.empty().set(...)), PartSet
	// .bind/.mirror chain ops on the opaque handle. Tried after the resource/intent
	// methods so an Input/Body receiver still resolves first.
	if pose, is_pose := recv.(Pose_Value); is_pose {
		return eval_pose_method(interp, node, env, pose, method)
	}
	if handle, is_handle := recv.(Handle_Value); is_handle {
		return eval_handle_method(interp, node, env, handle, method)
	}
	// The §22 self-first adders chain off a built Audio record value
	// (Audio.track(k, c).pitch(p).gain(g).bus(b)); a non-Audio receiver or a
	// non-adder member falls through to ok=false.
	if record, is_record := recv.(Record_Value); is_record {
		if bent, is_audio := eval_audio_adder(interp, record, method, node, env); is_audio {
			return bent, true
		}
	}
	return nil, false
}

// eval_audio_constructor lowers the §22 §2 sustained-audio seed
// `Audio.track(key, clip)` reached as a type-name static method — it evaluates the
// key (a String) and clip (a SoundHandle from sound(name)) args and builds the
// keyed Audio record at the spec defaults (unity gain/pitch, Music bus, no
// position) the adders chain onto. is_ctor is false for any (type, member) that is
// not Audio.track, so a non-constructor `Type.method()` falls through to the
// value-receiver dispatch. The builder/record shape lives in audio.odin.
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

// eval_apply_impulse evaluates `body.apply_impulse(j)` — yard's drive intent: a
// new Body with the impulse Vec2 ACCUMULATED (the prior impulse plus j), every
// other column carried unchanged. The receiver is the Body Record_Value column
// (NOT the Input snapshot), and the write is a functional update — the base body
// is read, never mutated, and a fresh record carries the summed impulse, so two
// pushes sum (the §11 solver consumes and zeroes it next stage). A prior impulse
// absent from the body reads VEC2_ZERO (the no-intent default), so the first push
// of a tick accumulates onto zero. A non-Body receiver or a non-Vec2 argument is
// ok=false (the intent is defined only over a Body and a vector).
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

// eval_engine_constructor resolves an engine static constructor `Type.method()`
// to its canonical seed value: yard's `Settings.defaults()` → the factory-default
// Settings, the §16 §7 anim builders Pose.empty()/blend()/layer() /
// Skeleton.humanoid()/empty() / PartSet.empty() → the pose/handle seed values
// (eval_anim_constructor, which needs the call node + env to evaluate blend/layer's
// pose args). It is the engine-provided constructor surface the spec names: a
// behavior reads these seeds, never authoring the engine internals. is_ctor is
// false for any (type, method) pair that is not a recognized engine constructor, so
// a non-constructor `recv.method()` falls through to the value-receiver dispatch.
eval_engine_constructor :: proc(interp: ^Interp, node: ^Node, env: ^Env, type_name, method: string) -> (value: Value, is_ctor: bool) {
	switch type_name {
	case "Settings":
		if method == "defaults" {
			return settings_defaults(interp), true
		}
	}
	return eval_anim_constructor(interp, node, env, type_name, method)
}

// settings_defaults is the §24 factory-default Settings record `Settings.defaults()`
// seeds a Menu with: the canonical preference layout the engine ships, with the
// `access` sub-record carrying `reduce_motion: false` (the accessibility default
// yard's toggle_motion flips). The record is the engine's, not the sim's — gameplay
// never reads it back (the settings split, §24) — so the runtime owns this seed
// shape rather than the artifact. Built in the evaluation arena so it outlives the
// constructor call.
settings_defaults :: proc(interp: ^Interp) -> Value {
	access_fields := make(map[string]Value, interp.allocator)
	access_fields["reduce_motion"] = false
	access := Record_Value{type_name = "Access", fields = access_fields}

	settings_fields := make(map[string]Value, interp.allocator)
	settings_fields["access"] = access
	return Record_Value{type_name = "Settings", fields = settings_fields}
}

// eval_input_button evaluates a digital Button query `input.pressed/released/held(
// player, action)` — the §23 §2 edge/level read snake's control stage turns on. It
// resolves the PlayerId and action-variant args, maps the action to its stable
// ActionId through the program's action registry, and reads the snapshot through
// the supplied reader (one of pressed/released/held), returning a Bool. An
// unresolved player or action reads false (the snapshot default), mirroring
// eval_input_value's zero default so a behavior never faults on input.
eval_input_button :: proc(
	interp: ^Interp,
	node: ^Node,
	env: ^Env,
	reader: proc(input: Input, player: PlayerId, action: ActionId) -> bool,
) -> (
	result: Value,
	ok: bool,
) {
	if len(node.children) < 3 {
		return nil, false
	}
	player_val, player_ok := eval(interp, &node.children[1], env)
	action_val, action_ok := eval(interp, &node.children[2], env)
	if !player_ok || !action_ok {
		return nil, false
	}
	player_variant, is_player := player_val.(Variant_Value)
	action_variant, is_action := action_val.(Variant_Value)
	if !is_player || !is_action {
		return nil, false
	}
	player, player_resolved := player_from_string(player_variant.case_name)
	if !player_resolved {
		return false, true
	}
	action_name := variant_to_token(action_variant, interp.allocator)
	def, action_found := interp.registry.by_name[action_name]
	if !action_found {
		return false, true
	}
	return reader(interp.input, player, def.id), true
}

// eval_input_value evaluates `input.value(self.player, Steer::Move)`: resolve the
// PlayerId arg and the action variant arg, map the action to its stable ActionId
// through the program's action registry, and read the snapshot's 1D analog value
// (§23 §2). An unresolved player or action reads zero (the snapshot default), so
// a behavior never faults on input.
eval_input_value :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (result: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	player_val, player_ok := eval(interp, &node.children[1], env)
	action_val, action_ok := eval(interp, &node.children[2], env)
	if !player_ok || !action_ok {
		return nil, false
	}
	player_variant, is_player := player_val.(Variant_Value)
	action_variant, is_action := action_val.(Variant_Value)
	if !is_player || !is_action {
		return nil, false
	}
	player, player_resolved := player_from_string(player_variant.case_name)
	if !player_resolved {
		return Fixed(0), true
	}
	// The registry is minted once per program (new_interp), so this read is an
	// index lookup, not a per-instance rebuild.
	action_name := variant_to_token(action_variant, interp.allocator)
	def, action_found := interp.registry.by_name[action_name]
	if !action_found {
		return Fixed(0), true
	}
	return value(interp.input, player, def.id), true
}

// eval_input_axis evaluates `input.axis(self.player, Drive::Move)`: resolve the
// PlayerId arg and the action variant arg, map the action to its stable ActionId
// through the program's action registry, and read the snapshot's 2D analog axis
// (§23 §2), a Vec2 whose components are each in [-1, 1]. An unresolved player or
// action reads VEC2_ZERO (the snapshot default), mirroring eval_input_value's
// zero default — a behavior never faults on input. hunt's drive body multiplies
// this Vec2 by P_SPEED*time.dt, so the 2D read is the player-move path.
eval_input_axis :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (result: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	player_val, player_ok := eval(interp, &node.children[1], env)
	action_val, action_ok := eval(interp, &node.children[2], env)
	if !player_ok || !action_ok {
		return nil, false
	}
	player_variant, is_player := player_val.(Variant_Value)
	action_variant, is_action := action_val.(Variant_Value)
	if !is_player || !is_action {
		return nil, false
	}
	player, player_resolved := player_from_string(player_variant.case_name)
	if !player_resolved {
		return VEC2_ZERO, true
	}
	// The registry is minted once per program (new_interp), so this read is an
	// index lookup, not a per-instance rebuild.
	action_name := variant_to_token(action_variant, interp.allocator)
	def, action_found := interp.registry.by_name[action_name]
	if !action_found {
		return VEC2_ZERO, true
	}
	return axis(interp.input, player, def.id), true
}

// eval_named_call dispatches a `name(args)` call: an engine builtin first (the
// closed set §07/§08 expose to a body), then a user §9 helper. An unresolved
// name is ok=false.
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
	case "fold":
		return builtin_fold(interp, node, env)
	case "length":
		return builtin_length(interp, node, env)
	case "sin":
		return builtin_sin(interp, node, env)
	case "mesh":
		return builtin_mesh(interp, node, env)
	case "rot_x":
		return builtin_rot_x(interp, node, env)
	case "up":
		return builtin_up(interp, node, env)
	case "prepend":
		return builtin_prepend(interp, node, env)
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
	case "grid_cells":
		return builtin_grid_cells(interp, node, env)
	case "sound":
		return builtin_sound(interp, node, env)
	case "pick":
		return builtin_pick(interp, node, env)
	case "Spawn":
		return builtin_spawn(interp, node, env)
	case "Despawn":
		return builtin_despawn(interp, node, env)
	}
	// A user §9 helper: bind its args to its params and fold its body.
	if fn := program_function(interp.program, name); fn != nil {
		return eval_user_call(interp, fn, node, env)
	}
	return nil, false
}

// eval_user_call applies a user §9 helper: evaluate each arg, bind it to the
// matching param name in a fresh scope (the helper closes over no caller locals
// — it sees only its params plus module consts), then fold the helper's body.
// The arg count must match the param count (the checked AST guarantees it).
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

// --- engine builtins ------------------------------------------------------

// builtin_abs is the §10 absolute value over the kernel: |Fixed| / |Int|,
// computed by saturating-negating a negative operand so it stays total at the
// rails. Pong's overlaps() calls abs on a Fixed difference.
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
	case bool, Vec2, Ref, Record_Value, List_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value, Rng, Vec3, Transform_Value, Pose_Value, Handle_Value:
		return nil, false
	}
	return nil, false
}

// builtin_clamp is the §10 clamp over the kernel: clamp(x, lo, hi) on Fixed.
// Pong's paddle_move clamps the paddle's y into the board, so x/lo/hi are all
// Fixed; the kernel's fixed_clamp keeps the rule in one place.
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

// builtin_length is the §10 vector magnitude `length(v: Vec2) -> Fixed`:
// sqrt(dot(v, v)) over the Q32.32 kernel through vec2_length, which routes
// vec2_dot into fixed_sqrt (digit-by-digit binary restoring — bit-exact on a
// perfect square, floor-rounded otherwise, no libm/float on the path, §10.5).
// hunt's step_to reads `speed / length(delta)` and visible's perception
// predicate reads `length(p.pos - from) <= SIGHT`, so the single arg is always a
// Vec2; a non-Vec2 arg is ok=false (fail-closed — the magnitude of a scalar/list
// is undefined, never coerced).
builtin_length :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	v, is_vec2 := arg.(Vec2)
	if !is_vec2 {
		return nil, false
	}
	return vec2_length(v), true
}

// builtin_sin is the §10 transcendental `sin(angle: Fixed) -> Fixed`: the
// fixed_sin polynomial (x − x³/6 + x⁵/120) over the saturating kernel, copied
// verbatim from the funpack trig kernel so the bits are identical (the
// determinism bet — pose-driven replay folds the SAME Q32.32 sin the funpack
// evaluator does). The single arg is coerced through as_fixed (an Int angle
// lifts to Fixed, matching funpack's eval_fixed_arg), so a Vec2/list/bool arg is
// ok=false (fail-closed — the sine of a non-scalar is undefined). pose_idle/
// pose_walk's sin terms and advance_gait's wrapped phase feed this builtin.
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

// builtin_rot_x is the §16 §7 per-bone X-axis rotation builder `rot_x(angle: Fixed)
// -> Transform`: a fixed-point angle (radians) into a Transform with the identity
// translation, a quaternion rotating `angle` about the local X axis, and unit scale
// — the leg/arm swing a pose generator drives a bone with. At angle 0 the quaternion
// is the identity (sin(0)=0, cos(0)=1), so rot_x(0.0) is the rest transform, the
// pose_walk zero-crossing the golden asserts. A non-scalar arg is ok=false
// (fail-closed). transform_rot_x carries the kernel-copied quat math (pose.odin /
// vector3.odin), so the bits match the funpack evaluator's rot_x bit-for-bit.
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

// builtin_up is the §16 §7 per-bone vertical-offset builder `up(d: Fixed) ->
// Transform`: a fixed-point displacement into a Transform translating by `d` along
// the local +Y axis, with the identity rotation and unit scale — pose_idle's torso
// breathing bob. A non-scalar arg is ok=false (fail-closed).
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

// builtin_mesh is the §19/§26 asset-handle constructor `mesh(name: String) ->
// MeshHandle`: a single String asset name lowered into the typed handle value a
// Model seam constant's literal builds — a Record_Value tagged "MeshHandle" with
// the one `name` field set to the supplied String. So mesh("krognid_torso")
// evaluates to the identical handle MeshHandle{name: "krognid_torso"} does, and the
// PartSet bind reads its name through eval_mesh_name_arg (pose.odin). This MIRRORS
// funpack/evaluate.odin's eval_asset_constructor (the closed-registry kind/name
// validity is the build gate's, not this evaluator's — the runtime builds the value
// the typecheck-passed reference names). Without it the artifact-path Rigged fold
// fail-closes when draw_krognid's krognid_parts() body calls mesh(...). A non-String
// arg, or the wrong arity, is ok=false (fail-closed). The sibling sound() asset
// constructor (audio.odin builtin_sound) follows the identical shape.
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

// builtin_first is the §08 list combinator `first(list) -> Option[T]`: the head
// of a list as Option::Some, or Option::None for the empty list. Pong's
// paddle_bounce/serve match on first(...). When a lambda predicate is supplied
// (`first(list, pred)`), the first element satisfying the predicate is returned
// — paddle_bounce's `first(paddles, pad => overlaps(...))`.
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
	// With a predicate lambda, return the first element it accepts; without one,
	// return the head.
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

// builtin_fold is the §08 list aggregate `fold(list, seed, f)`: fold f over the
// list left-to-right from the seed, threading the accumulator. The combiner takes
// two forms: a §9 helper NAME (pong's tally folds add_goal), or an INLINE binary
// lambda `fn(acc, elem) { … }` (yard's on_persist_result folds a match over each
// signal's result). A named callee resolves to the program function directly; any
// other combiner node is evaluated and must yield a two-param Lambda_Value. Either
// way the combiner is applied per element as f(acc, element); a combiner that is
// neither a binary helper nor a binary lambda is ok=false.
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
	// A bare-name combiner is a §9 helper resolved directly (pong's add_goal); any
	// other combiner node evaluates to a binary lambda closure (yard's inline
	// fn(m, r) over a signal's Result).
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

// fold_with_helper folds a two-param §9 helper over the elements left-to-right
// from the seed, threading the accumulator as f(acc, element) — the named-combiner
// branch of builtin_fold (pong's add_goal).
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

// builtin_prepend is the §08 list combinator `prepend(elem, list) -> [T]`: a new
// list with `elem` at the front, then every element of `list` in order. Snake's
// cells() prepends the head onto the body; the list is rebuilt fresh in the
// evaluation arena (immutable data — the input list is never mutated, §08).
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

// builtin_init is the §08 list combinator `init(list) -> [T]`: a new list with
// every element except the last. Snake's body_after drops the tail this way when
// the snake is not growing. The empty list yields the empty list (total — never
// a fault on a missing last element, §26 totality).
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

// builtin_contains is the §08 list combinator `contains(list, elem) -> Bool`:
// true when any element of `list` structurally equals `elem` (§03 universal Eq).
// Snake tests `contains(occ, c)` over Cell records and `contains(self.body,
// self.head)`, so the membership is the deep record equality values_equal folds.
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

// builtin_map is the §08 list combinator `map(list, fn) -> [U]`: a new list
// applying the unary lambda `fn` to each element in order. Snake projects food
// rows to their cells and cells to draw rects this way. The lambda is applied
// per element through apply_lambda; the result keeps the input's deterministic
// order (§08 stable order — order is the source order, never an iteration order).
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

// builtin_filter is the §08 list combinator `filter(list, pred) -> [T]`: a new
// list of the elements the unary predicate lambda accepts, in order. Snake's
// free-cell selection filters all_cells() by un-occupied, and detect_eat filters
// foods by the head cell. The kept elements preserve the input's deterministic
// order (§08 stable order).
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

// builtin_concat is the §08 list combinator `concat(a, b) -> [T]`: a new list of
// every element of `a` followed by every element of `b`, both in order. Snake's
// occupied() concatenates the snake's cells with the food cells. The two inputs
// are read, never mutated; the join is fresh in the evaluation arena (§08).
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

// builtin_is_empty is the §08 list combinator `is_empty(list) -> Bool`: true
// when the list has no elements. Snake gates grow/replenish/apply_death on an
// empty signal list this way.
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

// builtin_len is the §08 list aggregate `len(list) -> Int`: the element count as
// an Int (the i64 arm). Yard's tally folds this tick's deliveries into the running
// count — `self.delivered + len(done)` — so the result lands on the Int rail the
// `+` adds to a delivered count. A non-list arg is ok=false (the count of a
// scalar is undefined, never coerced).
builtin_len :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
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
	return i64(len(elements)), true
}

// builtin_grid_cells is the §26 `engine.grid.grid_cells(w, h, fn(x, y) -> Cell)
// -> [Cell]`: every cell of a w×h grid in STABLE ROW-MAJOR order, built by the
// supplied two-arg lambda. The order is driven by the loop indices — the outer
// loop walks rows (y from 0), the inner loop walks columns within a row (x from
// 0) — so the enumeration is machine-identical, never dependent on any map/hash
// iteration (§08 stable order, §26 "stable row-major order"). Snake's all_cells()
// folds free-cell selection through this; a non-positive extent yields the empty
// list (total — no fault on a degenerate grid). No float: w/h are Ints (§10).
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
	// Row-major: y is the outer (row) index, x the inner (column) index, so the
	// list reads row 0 left-to-right, then row 1, …  The two indices fully order
	// the output, independent of any map iteration.
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

// builtin_pick is the §26 seeded draw `pick(list, rng) -> (Option[T], Rng)`
// (snake's `pick(free, rng)`): it selects a uniform element of `list` and returns
// the THREADED pair — the drawn element boxed as `Option::Some(elem)` (or
// `Option::None` for an empty list) and the ADVANCED Rng. The draw is never a
// silent advance (§04 §1): the Rng is consumed and its successor returned even on
// the empty (None) arm, so the caller threads `next` forward exactly as the kernel
// contract requires. The result is a `Tuple_Value{Option, Rng}` a tuple-pattern
// match destructures into `(Option::Some(cell), next)` / `(Option::None, next)`.
//
// None-arm boxing: None is a unit `Option::None` (nil payload) via none_value;
// Some boxes the picked element via some_value (an arena-allocated payload). The
// reduction is rand_bounded (Lemire multiply-shift) over the interpreter's element
// slice, so the picked position is bit-identical to the kernel's parametric
// rand_pick — the interpreter binds T to Value here rather than calling the
// parametric kernel proc, keeping the boxing decision on the interpreter side.
builtin_pick :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	rng_val, rng_ok := eval(interp, &node.children[2], env)
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
	if len(elements) == 0 {
		// Empty draw: the None arm, yet the Rng still advances (no silent no-op).
		_, advanced := rand_next(rng)
		return pick_tuple(interp, none_value(), advanced), true
	}
	index, advanced := rand_bounded(rng, len(elements))
	return pick_tuple(interp, some_value(interp, elements[index]), advanced), true
}

// pick_tuple builds pick's `(Option, Rng)` return: the boxed Option in position 0,
// the advanced Rng in position 1 — the exact positional shape snake's tuple-pattern
// match `(Option::Some(cell), next)` destructures (§04 §1). The two-element slice
// is arena-allocated so the tuple outlives this call.
pick_tuple :: proc(interp: ^Interp, option: Value, advanced: Rng) -> Value {
	elements := make([]Value, 2, interp.allocator)
	elements[0] = option
	elements[1] = advanced
	return Tuple_Value{elements = elements}
}

// builtin_spawn is the §02 §2 command-wrap `Spawn(thing_record)` — the tuple-payload
// constructor a startup/behavior `[Spawn]` list carries (snake's `Spawn(Food{cell:
// cell})`, `Spawn(snake)`). It evaluates its single argument (a thing record) and
// returns that record VALUE directly: a Spawn command IS its wrapped blackboard, so
// queue_commands reads the record's type_name as the thing to mint and its fields as
// the new row. The wrap is a transparent carrier — it adds no value of its own, it
// just marks the record as a spawn payload at the source level.
builtin_spawn :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	return eval(interp, &node.children[1], env)
}

// builtin_despawn is the §02 §2 command-wrap `Despawn()` — the self-despawn
// command a behavior's `[Despawn]` list carries (snake's despawn_eaten emits
// `[Despawn()]` to remove the eaten Food). The no-arg form despawns the behavior's
// SELF row; it returns a marker Record_Value of type "Despawn" so the `[Despawn]`
// list is non-empty and fold_behavior_result detects the despawn intent, then
// queues a despawn of self_row at the tick boundary (§07 §4). The marker carries
// no fields — the target is the self row the tick fold already knows, not a field
// of this value (a future `Despawn(ref)` form would carry the Ref here).
builtin_despawn :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	return Record_Value{type_name = "Despawn", fields = make(map[string]Value, interp.allocator)}, true
}

// --- builtin support ------------------------------------------------------

// as_elements reads a value as a list's elements: a List_Value yields its slice;
// a View-of-thing value the interpreter never materializes as a list here, so a
// non-list is ok=false. A behavior reads a View through its param binding (the
// tick passes View rows as a List_Value), so first/fold over `paddles` see the
// rows as elements.
as_elements :: proc(interp: ^Interp, v: Value) -> (elements: []Value, ok: bool) {
	list, is_list := v.(List_Value)
	if !is_list {
		return nil, false
	}
	return list.elements, true
}

// apply_lambda applies a unary lambda closure to one argument: bind the arg to
// the lambda's single param in a child of its captured scope, then evaluate the
// body. A lambda whose arity is not one is a malformed application (ok=false) —
// the unary combinators (first/map/filter) only ever hold a one-param closure.
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

// apply_two_arg_lambda applies a binary lambda closure to (a, b): bind both args
// to the lambda's two params in order in a child of its captured scope, then
// evaluate the body. grid_cells applies this with (x, y) per grid cell — the
// only binary-lambda combinator. A lambda whose arity is not two is malformed.
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

// apply_two_arg applies a two-param §9 helper to (a, b) — the fold combiner shape
// (add_goal(score, goal)). The args bind to the helper's two params in order in a
// fresh scope, then the body folds.
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

// some_value boxes a value as Option::Some(v) — the head/predicate-hit result of
// first(). The payload is arena-allocated so the variant outlives the call.
some_value :: proc(interp: ^Interp, v: Value) -> Value {
	boxed := new(Value, interp.allocator)
	boxed^ = v
	return Variant_Value{enum_type = "Option", case_name = "Some", payload = boxed}
}

// none_value is the Option::None result of first() over an empty list / no
// predicate hit. The None arm a behavior's match falls through to.
none_value :: proc() -> Value {
	return Variant_Value{enum_type = "Option", case_name = "None"}
}
