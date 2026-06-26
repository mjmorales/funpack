// The terminal AUDIO projection (spec §07 §4, §22 §2): a pure, read-only
// self→[Audio] pass that folds a COMMITTED tick into the deterministic keyed
// track scene the engine reconciles its live voices against. Audio is the
// SUSTAINED (level-triggered) twin of the one-shot Sound: an `audio:` stage
// behavior returns the FULL set of tracks that should be sounding THIS tick,
// keyed by a stable String; the engine diffs the set by key and starts / stops /
// bends voices to match (§22 §1: "absent next tick ⇒ stopped; same key ⇒ same
// voice"). Like render, it is NOT part of the per-tick write fold — it writes no
// blackboard, takes no signals and no Rng, reads only `self` — so it runs as a
// POST-COMMIT pass over the sealed World_Version (tick.odin's fold skips the
// `audio` stage for exactly this reason, the same as `render`).
//
// PURITY: this whole file is headless and float-free. Every track's gain/pitch
// is a Fixed off the kernel — the locomotion loop's pitch (0.6 + speed*0.2) and
// gain (clamp(speed,0,1)) are the SAME Q32.32 bits the funpack evaluator folds,
// so a re-fold of a committed log is bit-identical (the determinism bet). The
// live SDL backend (audio_live.odin) consumes this scene behind FUNPACK_LIVE; no
// SDL symbol appears here, so the deterministic suite compiles and asserts the
// projection with no device on the path.
package funpack_runtime

// --- The §22 §4 mixer-bus palette -----------------------------------------

// Audio_Bus is the §22 §4 closed mixer-group enum a track routes to — the five
// named members of the spec's audio.fun `Bus` enum (Master..Voice), the same
// closed taxonomy a `Bus::X` variant lowers to. A grouped volume slider drives a
// bus, so the bus is carried into the scene rather than collapsed at the source.
// Appended in spec order, so a new member is a deliberate schema-version bump
// (§04 closed-enum) — the same discipline Draw_Color follows.
Audio_Bus :: enum {
	Master,
	Music,
	Sfx,
	Ui,
	Voice,
}

// --- The §22 §2 keyed track scene (the audio projection's first-class result) ---

// Audio_Track is one §22 §2 sustained voice the scene asks the engine to keep
// alive this tick: its stable diff `key` (the engine matches voices across ticks
// by this — same key ⇒ same voice), the `clip` sound-asset name it plays, its
// `gain`/`pitch` as Fixed off the kernel (gain is the linear volume, pitch the
// playback rate — 1.0 is unmodified), and the `bus` it routes to. No `at` field:
// krognid's stride loop is non-positional; a positional sustained voice is a
// later regime (the §22 `at` adder is admitted on the builder but unused here).
Audio_Track :: struct {
	key:   string,
	clip:  string,
	gain:  Fixed,
	pitch: Fixed,
	bus:   Audio_Bus,
}

// Audio_Scene is the §22 §2 keyed track scene of one committed tick: the ordered
// tracks that should be sounding, in flattened-pipeline order across `audio`
// behaviors and stable Id order within each. It is the reconciliation surface —
// the engine diffs THIS set by key against the prior tick's to start/stop/bend
// voices. At rest it is empty (locomotion returns []), so the engine stops the
// stride loop; two folds of the same committed tick produce a bit-identical scene
// (the determinism thesis, §10.5). The tracks live in the supplied allocator.
Audio_Scene :: struct {
	tracks: []Audio_Track,
}

// --- The audio projection pass --------------------------------------------

// audio_version projects a COMMITTED world version into its §22 §2 keyed track
// scene. It mirrors render_version: walk the flattened pipeline (§11), and for
// each `audio`-stage step run that behavior once per instance of its on-Thing in
// stable Id order (§08 §2), concatenating every instance's emitted [Audio] tracks
// in that order. The interpreter reads the committed version with NO tick in
// flight (interp.tick is nil), so each `self` is the committed blackboard — the
// scene is the tick as committed (a creature's committed `speed` drives its
// track's pitch/gain). Input/Time bind to the supplied resources but an audio
// behavior reads only `self`, so they are observable-only, never consulted.
audio_version :: proc(
	program: ^Program,
	version: World_Version,
	input: Input,
	time: Record_Value,
	allocator := context.allocator,
) -> Audio_Scene {
	committed := version
	interp := new_interp(program, &committed, nil, input, time, allocator)

	tracks := make([dynamic]Audio_Track, allocator)
	// Shares render's projection walk (project_stage in render.odin) — the audio stage
	// folds each behavior's [Audio] list through audio_track_from_record. obs is never
	// armed for audio (the §28 trace re-projection is render-only).
	project_stage(&interp, program, "audio", &tracks, audio_track_from_record)
	return Audio_Scene{tracks = tracks[:]}
}

// append_audio_tracks lowers an audio behavior's returned [Audio] list into the
// scene (fold_emitted_list over audio_track_from_record) — a non-list return or a
// malformed Audio record is skipped, the same fail-closed discipline render's
// append_draw_commands follows. Kept as a named entry point for the standalone
// audio-lowering test (a standing creature's locomotion returns [], so the scene stays
// empty and the engine stops its voice).
append_audio_tracks :: proc(tracks: ^[dynamic]Audio_Track, result: Value) {
	fold_emitted_list(tracks, result, audio_track_from_record)
}

// audio_track_from_record lowers one evaluated Audio record into an Audio_Track.
// The record is the §22 §2 `Audio` value the builder chain folds to (type_name
// "Audio"): key/clip are required (the track's identity), gain/pitch read the
// Fixed fields (a built track always carries them — the constructor seeds unity),
// and bus reads the §22 §4 mixer enum. A record that is not an Audio value, or one
// missing the key/clip/bus, yields ok=false — only a well-formed sustained track
// enters the scene. The one-shot Sound (no `key`) is NOT a sustained track and is
// rejected here: it is the deferred audio: slot's twin, never an interior emit.
audio_track_from_record :: proc(record: Record_Value) -> (track: Audio_Track, ok: bool) {
	if record.type_name != "Audio" {
		return Audio_Track{}, false
	}
	key, key_ok := audio_record_string(record, "key")
	clip, clip_ok := audio_record_clip(record, "clip")
	bus, bus_ok := audio_record_bus(record, "bus")
	if !key_ok || !clip_ok || !bus_ok {
		return Audio_Track{}, false
	}
	gain := audio_record_fixed(record, "gain")
	pitch := audio_record_fixed(record, "pitch")
	return Audio_Track{key = key, clip = clip, gain = gain, pitch = pitch, bus = bus}, true
}

// --- audio-record field readers -------------------------------------------

// audio_record_string reads a String_Value field off an Audio record — the track's
// stable diff `key` (the shared record_name_field mold). ok is false when the field is
// absent or not a String.
audio_record_string :: proc(record: Record_Value, name: string) -> (text: string, ok: bool) {
	return record_name_field(record, name)
}

// audio_record_clip reads the played sound's asset name off an Audio record's
// `clip` field. The clip is a SoundHandle value — a Record_Value tagged
// "SoundHandle" carrying one `name` String column (the form `sound("krognid_step")`
// folds to, identical to the funpack evaluator's handle). ok is false when the
// field is absent, not a SoundHandle, or carries no name.
audio_record_clip :: proc(record: Record_Value, name: string) -> (clip: string, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return "", false
	}
	handle, is_record := field.(Record_Value)
	if !is_record || handle.type_name != "SoundHandle" {
		return "", false
	}
	return record_name_field(handle, "name")
}

// audio_record_fixed reads a Fixed gain/pitch field off an Audio record. A built
// track always carries unity gain/pitch (the constructor seed) replaced by any
// adder, so a present field is the Fixed arm; an absent-or-non-Fixed field reads
// unity (FIXED_ONE), the absent-safe default a partially-built track folds in
// rather than faulting (mirrors record_fixed's absent-safe read for Draw::Camera).
audio_record_fixed :: proc(record: Record_Value, name: string) -> Fixed {
	field, present := record.fields[name]
	if !present {
		return FIXED_ONE
	}
	value, is_fixed := field.(Fixed)
	if !is_fixed {
		return FIXED_ONE
	}
	return value
}

// audio_record_bus reads an Audio record's `bus` into the §22 §4 mixer palette. A
// present field must name one of the five closed-palette members (the spec
// audio.fun `Bus` enum, Master..Voice): a recognized variant lowers to its member
// with ok=true; an unrecognized case_name (a typo or a future bus member) REFUSES
// with ok=false — never guessed, the same fail-closed discipline record_color
// applies to an out-of-palette draw color. A present-but-not-a-variant field also
// refuses. The constructor always seeds a bus, so an absent field is a malformed
// track and refuses too.
audio_record_bus :: proc(record: Record_Value, name: string) -> (bus: Audio_Bus, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return .Master, false
	}
	variant, is_variant := field.(Variant_Value)
	if !is_variant {
		return .Master, false
	}
	switch variant.case_name {
	case "Master":
		return .Master, true
	case "Music":
		return .Music, true
	case "Sfx":
		return .Sfx, true
	case "Ui":
		return .Ui, true
	case "Voice":
		return .Voice, true
	}
	return .Master, false
}

// --- the §22 §2 Audio builder chain (interpreter values) ------------------

// audio_track_value builds the §22 §2 `Audio.track(key, clip)` record value at the
// spec defaults — unity gain/pitch on the Music bus, no position — the seed the
// .pitch/.gain/.bus/.at adders then chain onto. It carries exactly the six §22
// `Audio` fields (key, clip, gain, pitch, bus, at) in the same shape the funpack
// evaluator's audio_record builds, so a runtime-built track and an artifact-loaded
// one fold to the same scene. `clip` is the SoundHandle the `sound(name)` builtin
// returned; `key` is the diff-key String. Allocated in the evaluation arena.
audio_track_value :: proc(interp: ^Interp, key, clip: Value) -> Value {
	fields := make(map[string]Value, interp.allocator)
	fields["key"] = key
	fields["clip"] = clip
	fields["gain"] = FIXED_ONE
	fields["pitch"] = FIXED_ONE
	fields["bus"] = audio_bus_variant("Music")
	fields["at"] = none_value()
	return Record_Value{type_name = "Audio", fields = fields}
}

// audio_bus_variant is a §22 §4 Bus enum value (Bus::Sfx, Bus::Music) — the same
// Variant_Value a `Bus::X` literal lowers to (eval_variant), so a default bus
// compares equal to a literal-set one and audio_record_bus reads either by its
// case name.
audio_bus_variant :: proc(variant: string) -> Value {
	return Variant_Value{enum_type = "Bus", case_name = variant}
}

// eval_audio_adder lowers a §22 self-first adder on a built Audio record value —
// `.gain(g)` / `.pitch(p)` replace the Fixed field, `.bus(b)` the Bus field,
// `.at(pos)` the Option position — each returning a NEW Audio record with the one
// field replaced (the base untouched), so they chain
// (Audio.track(k,c).pitch(p).gain(g).bus(b)). is_audio is false when the receiver
// is not an Audio record or the member is not an adder, so the caller falls
// through. The fields the chain does not touch carry the constructor seed forward,
// so locomotion's chain lands pitch (0.6+speed*0.2), gain (clamp(speed,0,1)), bus
// Sfx, leaving key/clip/at at their track() seed.
eval_audio_adder :: proc(
	interp: ^Interp,
	record: Record_Value,
	member: string,
	node: ^Node,
	env: ^Env,
) -> (
	value: Value,
	is_audio: bool,
) {
	if record.type_name != "Audio" {
		return nil, false
	}
	field: string
	wrap_some := false
	switch member {
	case "gain", "pitch", "bus":
		field = member
	case "at":
		field = "at"
		wrap_some = true
	case:
		return nil, false
	}
	if len(node.children) != 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	if wrap_some {
		arg = some_value(interp, arg)
	}
	updated := make(map[string]Value, interp.allocator)
	for k, v in record.fields {
		updated[k] = v
	}
	updated[field] = arg
	return Record_Value{type_name = "Audio", fields = updated}, true
}

// --- asset-handle constructors --------------------------------------------

// builtin_sound is the §19/§26 `sound(name) -> SoundHandle` asset constructor: a
// single String asset name into the typed handle value the seam constant's literal
// builds — a Record_Value tagged "SoundHandle" carrying the one `name` String
// column. So `sound("krognid_step")` folds to the IDENTICAL handle the funpack
// evaluator's eval_asset_constructor builds (the §19 golden's parity), and the two
// compare equal under values_equal. A non-String arg is ok=false (fail-closed —
// an asset name is a String). The locomotion loop's clip reads this; the
// closed-registry name validity was the build gate's, not the runtime's.
builtin_sound :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
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
	fields["name"] = name
	return Record_Value{type_name = "SoundHandle", fields = fields}, true
}
