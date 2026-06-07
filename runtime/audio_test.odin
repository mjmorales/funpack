// Audio projection acceptance (spec §07 §4, §22 §2): the terminal self→[Audio]
// pass folds a COMMITTED krognid tick into the deterministic keyed track scene the
// engine reconciles its live voices against. These tests run a HAND-BUILT krognid
// program (no artifact — the krognid.artifact is the funpack emission side's leaf,
// team Lore #14 build order) whose `locomotion` behavior body mirrors stroll.fun
// verbatim in §2.7 node form, so the interpreter folds krognid's REAL audio
// decomposition: the speed gate (`if self.speed == 0.0 { return [] }`) and the
// keyed stride loop `Audio.track("stride", sound("krognid_step")).pitch(0.6 +
// self.speed * 0.2).gain(clamp(self.speed, 0, 1)).bus(Bus::Sfx)`.
//
// They are the runtime twin of stroll's two locomotion asserts (stroll.fun §179,
// §184):
//   - "locomotion is silent at rest"  → a standing creature folds to []  (empty
//     scene, so the engine stops its voice);
//   - "locomotion loops while moving" → speed 1.0 folds to one Sfx-bus track at
//     pitch 0.8 / gain 1.0, pinned by EXACT Q32.32 equality (0.6 + 1.0*0.2 through
//     the kernel's fixed_add/fixed_mul, not float).
// A third test fixes the projection as PURE: two folds of the same committed tick
// produce a bit-identical scene, the determinism surface (and the headless build
// links no SDL — audio.odin imports none).
package funpack_runtime

import "core:fmt"
import "core:strconv"
import "core:testing"

// --- the hand-built krognid audio program ---------------------------------

// audio_program builds the minimal krognid artifact the audio fold runs over: the
// Bus mixer enum, the Krognid thing (only the `speed` column the body reads plus a
// pos the spawn carries), the `locomotion` audio behavior, the one-stage `audio`
// pipeline, and a setup spawning one Krognid at the supplied speed. Allocated in
// the test temp arena so the leak checker stays clean. This is the substrate the
// projection tests fold.
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

// bus_variants is the §22 §4 Bus mixer enum's five cases (Master..Voice) — the
// closed bus palette a track routes to, present so Bus::Sfx resolves as a variant.
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

// krognid_fields is the Krognid blackboard the audio body reads: pos (the spawn
// anchor, unread by locomotion) and speed (the gait magnitude the stride loop's
// pitch/gain track), defaulting to 0 (at rest) so an unset speed is silent.
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

// krognid_spawn builds the one Krognid the setup mints: a pos at the origin and
// the supplied speed (0 for the rest case, 1.0 for the moving case).
@(private = "file")
krognid_spawn :: proc(speed: Fixed, a := context.allocator) -> []Spawn_Field {
	fields := make([]Spawn_Field, 2, a)
	fields[0] = Spawn_Field{name = "pos", kind = .Vec2, vec2_x = to_fixed(0), vec2_y = to_fixed(0)}
	fields[1] = Spawn_Field{name = "speed", kind = .Fixed, fixed = speed}
	return fields
}

// locomotion_behavior builds krognid's `locomotion on Krognid` audio behavior
// verbatim (stroll.fun §123): `if self.speed == 0.0 { return [] }; return
// [Audio.track("stride", sound("krognid_step")).pitch(0.6 + self.speed * 0.2)
// .gain(clamp(self.speed, 0.0, 1.0)).bus(Bus::Sfx)]`. The body is the §2.7 node
// forest the interpreter folds — the speed gate then the keyed builder chain.
@(private = "file")
locomotion_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	params := make([]Param_Decl, 1, a)
	params[0] = Param_Decl{name = "self", type = "Krognid"}
	emits := make([]string, 1, a)
	emits[0] = "Audio"

	self_speed := af_field(af_name("self", a), "speed", a)

	body := make([]Node, 2, a)
	// if self.speed == 0.0 { return [] }
	body[0] = af_if_return(
		af_binary("eq", self_speed, af_fixed_node(to_fixed(0), a), a),
		af_list(a),
		a,
	)
	// Audio.track("stride", sound("krognid_step"))
	track := af_method_call(
		af_name("Audio", a),
		"track",
		a,
		af_string("stride", a),
		af_call("sound", a, af_string("krognid_step", a)),
	)
	// .pitch(0.6 + self.speed * 0.2)
	pitch_expr := af_binary(
		"add",
		af_fixed_node(frac_fixed(0, "6"), a),
		af_binary("mul", self_speed, af_fixed_node(frac_fixed(0, "2"), a), a),
		a,
	)
	pitched := af_method_call(track, "pitch", a, pitch_expr)
	// .gain(clamp(self.speed, 0.0, 1.0))
	gain_expr := af_call(
		"clamp",
		a,
		self_speed,
		af_fixed_node(to_fixed(0), a),
		af_fixed_node(to_fixed(1), a),
	)
	gained := af_method_call(pitched, "gain", a, gain_expr)
	// .bus(Bus::Sfx)
	bussed := af_method_call(gained, "bus", a, af_variant_unit("Bus", "Sfx", a))
	// return [ <the built track> ]
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

// --- the tests ------------------------------------------------------------

// audio_committed_scene runs the hand-built krognid program at the supplied speed:
// commit the setup spawn (the Krognid at that speed), then fold the terminal audio
// projection over the committed version. The returned scene is the keyed track set
// of the committed tick — what audio_version produces for the level-triggered
// `audio` stage.
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

// audio_time is the Time resource the projection binds (observable-but-unread by
// an audio behavior, which reads only self) — the fixed 60hz dt, no float.
@(private = "file")
audio_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

// A standing krognid (speed 0) folds locomotion to the EMPTY keyed scene — the
// runtime twin of stroll's "locomotion is silent at rest" assert (stroll.fun
// §179: locomotion.step(...) == []). The empty scene is the engine's signal to
// stop the stride voice (§22 §1 absent ⇒ stopped).
@(test)
test_locomotion_silent_at_rest :: proc(t: ^testing.T) {
	scene := audio_committed_scene(t, to_fixed(0))
	testing.expect_value(t, len(scene.tracks), 0)
}

// A moving krognid (speed 1.0) folds locomotion to ONE Sfx-bus stride track at
// pitch 0.8 / gain 1.0 — the runtime twin of stroll's "locomotion loops while
// moving" assert (stroll.fun §184: == [Audio.track("stride", sound(
// "krognid_step")).pitch(0.8).gain(1.0).bus(Bus::Sfx)]). The pitch is pinned by
// EXACT Q32.32 equality computed through the kernel (0.6 + 1.0*0.2 via fixed_add/
// fixed_mul, never float), the gain through fixed_clamp — so the assert is the
// determinism path, not a decimal round-trip.
@(test)
test_locomotion_track_while_moving :: proc(t: ^testing.T) {
	scene := audio_committed_scene(t, to_fixed(1))
	testing.expect_value(t, len(scene.tracks), 1)
	if len(scene.tracks) != 1 {
		return
	}
	track := scene.tracks[0]

	// pitch = 0.6 + 1.0 * 0.2, through the SAME kernel ops the body folds.
	want_pitch := fixed_add(frac_fixed(0, "6"), fixed_mul(to_fixed(1), frac_fixed(0, "2")))
	// gain = clamp(1.0, 0.0, 1.0) = 1.0.
	want_gain := fixed_clamp(to_fixed(1), to_fixed(0), to_fixed(1))

	testing.expect_value(t, track.key, "stride")
	testing.expect_value(t, track.clip, "krognid_step")
	testing.expect_value(t, track.bus, Audio_Bus.Sfx)
	testing.expect_value(t, track.pitch, want_pitch)
	testing.expect_value(t, track.gain, want_gain)
	// 0.6 + 0.2 lands at 0.8 to the ULP — the moving track is audibly pitched up.
	testing.expect_value(t, track.pitch, frac_fixed(0, "8"))
	testing.expect_value(t, track.gain, FIXED_ONE)
}

// The audio projection is PURE: two folds of the same committed tick produce a
// bit-identical keyed scene (the §10.5 determinism thesis over the audio surface).
// This is the headless contract the live SDL backend never enters — audio.odin
// imports no SDL, so this test compiles and asserts with no device on the path,
// and a re-fold of a committed log plays the identical voices the live run did.
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
	// And a malformed audio body (a non-Audio record in the [Audio] list) adds no
	// track rather than faulting the projection — the fail-closed lowering path.
	bad := Record_Value{type_name = "Sound", fields = make(map[string]Value, context.temp_allocator)}
	tracks := make([dynamic]Audio_Track, context.temp_allocator)
	append_audio_tracks(&tracks, List_Value{elements = {bad}})
	testing.expect_value(t, len(tracks), 0)
}

// --- §2.7 node constructors (file-private to the audio test) ---------------

// frac_fixed converts a literal's integer part and fractional digits to Q32.32
// bits with the SAME all-integer round-to-nearest the funpack lexer's
// fixed_from_decimal uses (no float on the path), so a `0.6`/`0.2`/`0.8` literal
// node carries the canonical bits the krognid artifact would. Kept beside the test
// (not linked from funpack) per the kernel-copy-not-link invariant.
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

// af_fixed_bits renders a Fixed to its raw Q32.32 decimal-bits token (the artifact
// form a Fixed default carries) — the Krognid speed default.
@(private = "file")
af_fixed_bits :: proc(f: Fixed, a := context.allocator) -> string {
	buf := make([]u8, 24, a)
	return strconv.write_int(buf, i64(f), 10)
}

// af_fixed_node builds a `.Fixed` literal node carrying the raw Q32.32 bits token
// decode_fixed parses back.
@(private = "file")
af_fixed_node :: proc(f: Fixed, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = af_fixed_bits(f, a)
	return Node{kind = .Fixed, fields = fields}
}

// af_name builds a `.Name` reference node — a param/local/type-name identifier.
@(private = "file")
af_name :: proc(name: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

// af_string builds a `.String` literal node carrying the length-prefixed
// `L<len>:<bytes>` token decode_string parses back (the artifact §2.4 string form)
// — the track's "stride" key and the "krognid_step" clip name.
@(private = "file")
af_string :: proc(text: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = fmt.aprintf("L%d:%s", len(text), text, allocator = a)
	return Node{kind = .String, fields = fields}
}

// af_field builds a `.Field` access node `recv.FIELD` over a single receiver child
// — self.speed.
@(private = "file")
af_field :: proc(recv: Node, field: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = field
	children := make([]Node, 1, a)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

// af_binary builds a `.Binary` op node `lhs OP rhs` over the kernel — the eq gate,
// the pitch add/mul.
@(private = "file")
af_binary :: proc(op: string, lhs, rhs: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = op
	children := make([]Node, 2, a)
	children[0] = lhs
	children[1] = rhs
	return Node{kind = .Binary, fields = fields, children = children}
}

// af_call builds a `.Call` node with a `.Name` callee — sound(name)/clamp(x,lo,hi).
@(private = "file")
af_call :: proc(callee: string, a: Runtime_Allocator, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, a)
	children[0] = af_name(callee, a)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

// af_method_call builds a `.Call` node whose callee is a `.Field` (a method-style
// recv.method(args)) — the Audio.track static seed and the .pitch/.gain/.bus
// adders. child[0] is the field callee (its child is the receiver), children[1:]
// the args.
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

// af_variant_unit builds a unit `.Variant` value node `variant ENUM CASE false` —
// Bus::Sfx.
@(private = "file")
af_variant_unit :: proc(enum_type, case_name: string, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "false"
	return Node{kind = .Variant, fields = fields}
}

// af_list builds a `.List` literal node over its element subtrees — the `[]` rest
// return and the one-track moving return.
@(private = "file")
af_list :: proc(a: Runtime_Allocator, elements: ..Node) -> Node {
	children := make([]Node, len(elements), a)
	for elem, i in elements {
		children[i] = elem
	}
	return Node{kind = .List, children = children}
}

// af_if_return builds an `.If_Return` statement node `if GUARD { return VALUE }` —
// the speed gate.
@(private = "file")
af_if_return :: proc(guard, value: Node, a := context.allocator) -> Node {
	children := make([]Node, 2, a)
	children[0] = guard
	children[1] = value
	return Node{kind = .If_Return, children = children}
}

// af_return builds a `.Return` statement node wrapping its value subtree.
@(private = "file")
af_return :: proc(value: Node, a := context.allocator) -> Node {
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Return, children = children}
}
