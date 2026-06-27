package funpack_runtime

import "core:fmt"
import "core:strconv"
import "core:testing"

@(private = "file")
audio_program :: proc(speed: Fixed, a := context.temp_allocator) -> Program {
	enums := make([]Enum_Decl, 1, a)
	enums[0] = Enum_Decl{name = "Bus", kind = .None, variants = bus_variants(a)}

	things := make([]Thing_Decl, 1, a)
	things[0] = Thing_Decl{name = "Krognid", singleton = false, fields = krognid_fields(a)}

	behaviors := make([]Behavior_Decl, 1, a)
	behaviors[0] = locomotion_behavior(a)

	pipeline := make([]Pipeline_Step, 1, a)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "audio", behavior = "locomotion"}

	setup := make([]Spawn_Command, 1, a)
	setup[0] = Spawn_Command{thing = "Krognid", fields = krognid_spawn(speed, a)}

	return Program {
		enums = enums,
		things = things,
		behaviors = behaviors,
		pipeline = pipeline,
		setup = setup,
	}
}

@(private = "file")
bus_variants :: proc(a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 5, a)
	v[0] = Enum_Variant{name = "Master", payload = "unit"}
	v[1] = Enum_Variant{name = "Music", payload = "unit"}
	v[2] = Enum_Variant{name = "Sfx", payload = "unit"}
	v[3] = Enum_Variant{name = "Ui", payload = "unit"}
	v[4] = Enum_Variant{name = "Voice", payload = "unit"}
	return v
}

@(private = "file")
krognid_fields :: proc(a := context.allocator) -> []Field_Decl {
	f := make([]Field_Decl, 2, a)
	f[0] = Field_Decl{name = "pos", type = "Vec2"}
	f[1] = Field_Decl {
		name            = "speed",
		type            = "Fixed",
		has_default     = true,
		default_encoded = af_fixed_bits(to_fixed(0), a),
	}
	return f
}

@(private = "file")
krognid_spawn :: proc(speed: Fixed, a := context.allocator) -> []Spawn_Field {
	fields := make([]Spawn_Field, 2, a)
	fields[0] = Spawn_Field{name = "pos", kind = .Vec2, vec2_x = to_fixed(0), vec2_y = to_fixed(0)}
	fields[1] = Spawn_Field{name = "speed", kind = .Fixed, fixed = speed}
	return fields
}

@(private = "file")
locomotion_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	params := make([]Param_Decl, 1, a)
	params[0] = Param_Decl{name = "self", type = "Krognid"}
	emits := make([]string, 1, a)
	emits[0] = "Audio"

	self_speed := af_field(af_name("self", a), "speed", a)

	body := make([]Node, 2, a)
	body[0] = af_if_return(
		af_binary("eq", self_speed, af_fixed_node(to_fixed(0), a), a),
		af_list(a),
		a,
	)
	track := af_method_call(
		af_name("Audio", a),
		"track",
		a,
		af_string("stride", a),
		af_call("sound", a, af_string("krognid_step", a)),
	)
	pitch_expr := af_binary(
		"add",
		af_fixed_node(frac_fixed(0, "6"), a),
		af_binary("mul", self_speed, af_fixed_node(frac_fixed(0, "2"), a), a),
		a,
	)
	pitched := af_method_call(track, "pitch", a, pitch_expr)
	gain_expr := af_call(
		"clamp",
		a,
		self_speed,
		af_fixed_node(to_fixed(0), a),
		af_fixed_node(to_fixed(1), a),
	)
	gained := af_method_call(pitched, "gain", a, gain_expr)
	bussed := af_method_call(gained, "bus", a, af_variant_unit("Bus", "Sfx", a))
	body[1] = af_return(af_list(a, bussed), a)

	return Behavior_Decl {
		name = "locomotion",
		on_thing = "Krognid",
		stage = "audio",
		contract = "Audio",
		params = params,
		emits = emits,
		body = body,
	}
}

@(private = "file")
audio_committed_scene :: proc(t: ^testing.T, speed: Fixed) -> Audio_Scene {
	program := audio_program(speed, context.temp_allocator)
	world := new_world(program, context.temp_allocator)
	base := initial_version(world, context.temp_allocator)
	committed := run_startup(&program, base, context.temp_allocator)
	return audio_version(
		&program,
		committed,
		empty(),
		audio_time(context.temp_allocator),
		context.temp_allocator,
	)
}

@(private = "file")
audio_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

@(test)
test_locomotion_silent_at_rest :: proc(t: ^testing.T) {
	scene := audio_committed_scene(t, to_fixed(0))
	testing.expect_value(t, len(scene.tracks), 0)
}

@(test)
test_locomotion_track_while_moving :: proc(t: ^testing.T) {
	scene := audio_committed_scene(t, to_fixed(1))
	testing.expect_value(t, len(scene.tracks), 1)
	if len(scene.tracks) != 1 {
		return
	}
	track := scene.tracks[0]

	want_pitch := fixed_add(frac_fixed(0, "6"), fixed_mul(to_fixed(1), frac_fixed(0, "2")))
	want_gain := fixed_clamp(to_fixed(1), to_fixed(0), to_fixed(1))

	testing.expect_value(t, track.key, "stride")
	testing.expect_value(t, track.clip, "krognid_step")
	testing.expect_value(t, track.bus, Audio_Bus.Sfx)
	testing.expect_value(t, track.pitch, want_pitch)
	testing.expect_value(t, track.gain, want_gain)
	testing.expect_value(t, track.pitch, frac_fixed(0, "8"))
	testing.expect_value(t, track.gain, FIXED_ONE)
}

@(test)
test_audio_projection_pure :: proc(t: ^testing.T) {
	first := audio_committed_scene(t, to_fixed(1))
	second := audio_committed_scene(t, to_fixed(1))
	testing.expect_value(t, len(first.tracks), len(second.tracks))
	if len(first.tracks) != len(second.tracks) {
		return
	}
	for track, i in first.tracks {
		other := second.tracks[i]
		testing.expect_value(t, track.key, other.key)
		testing.expect_value(t, track.clip, other.clip)
		testing.expect_value(t, track.bus, other.bus)
		testing.expect_value(t, track.pitch, other.pitch)
		testing.expect_value(t, track.gain, other.gain)
	}
	bad := Record_Value{type_name = "Sound", fields = make(map[string]Value, context.temp_allocator)}
	tracks := make([dynamic]Audio_Track, context.temp_allocator)
	append_audio_tracks(&tracks, List_Value{elements = {bad}})
	testing.expect_value(t, len(tracks), 0)
}

@(private = "file")
frac_fixed :: proc(int_part: i64, frac_digits: string) -> Fixed {
	numer: u128 = 0
	denom: u128 = 1
	for ch in frac_digits {
		numer = numer * 10 + u128(ch - '0')
		denom *= 10
	}
	frac_bits := u64((numer << FIXED_FRACTION_BITS + denom / 2) / denom)
	return Fixed((int_part << FIXED_FRACTION_BITS) + i64(frac_bits))
}

@(private = "file")
af_fixed_bits :: proc(f: Fixed, a := context.allocator) -> string {
	buf := make([]u8, 24, a)
	return strconv.write_int(buf, i64(f), 10)
}

@(private = "file")
af_fixed_node :: proc(f: Fixed, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = af_fixed_bits(f, a)
	return Node{kind = .Fixed, fields = fields}
}

@(private = "file")
af_name :: proc(name: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

@(private = "file")
af_string :: proc(text: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = fmt.aprintf("L%d:%s", len(text), text, allocator = a)
	return Node{kind = .String, fields = fields}
}

@(private = "file")
af_field :: proc(recv: Node, field: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = field
	children := make([]Node, 1, a)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

@(private = "file")
af_binary :: proc(op: string, lhs, rhs: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = op
	children := make([]Node, 2, a)
	children[0] = lhs
	children[1] = rhs
	return Node{kind = .Binary, fields = fields, children = children}
}

@(private = "file")
af_call :: proc(callee: string, a: Runtime_Allocator, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, a)
	children[0] = af_name(callee, a)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
af_method_call :: proc(recv: Node, method: string, a: Runtime_Allocator, args: ..Node) -> Node {
	callee := af_field(recv, method, a)
	children := make([]Node, len(args) + 1, a)
	children[0] = callee
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
af_variant_unit :: proc(enum_type, case_name: string, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "false"
	return Node{kind = .Variant, fields = fields}
}

@(private = "file")
af_list :: proc(a: Runtime_Allocator, elements: ..Node) -> Node {
	children := make([]Node, len(elements), a)
	for elem, i in elements {
		children[i] = elem
	}
	return Node{kind = .List, children = children}
}

@(private = "file")
af_if_return :: proc(guard, value: Node, a := context.allocator) -> Node {
	children := make([]Node, 2, a)
	children[0] = guard
	children[1] = value
	return Node{kind = .If_Return, children = children}
}

@(private = "file")
af_return :: proc(value: Node, a := context.allocator) -> Node {
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Return, children = children}
}
