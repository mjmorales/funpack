package funpack_runtime

Audio_Bus :: enum {
	Master,
	Music,
	Sfx,
	Ui,
	Voice,
}

Audio_Track :: struct {
	key:   string,
	clip:  string,
	gain:  Fixed,
	pitch: Fixed,
	bus:   Audio_Bus,
}

Audio_Scene :: struct {
	tracks: []Audio_Track,
}

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
	project_stage(&interp, program, "audio", &tracks, audio_track_from_record)
	return Audio_Scene{tracks = tracks[:]}
}

append_audio_tracks :: proc(tracks: ^[dynamic]Audio_Track, result: Value) {
	fold_emitted_list(tracks, result, audio_track_from_record)
}

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

audio_record_string :: proc(record: Record_Value, name: string) -> (text: string, ok: bool) {
	return record_name_field(record, name)
}

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

audio_bus_variant :: proc(variant: string) -> Value {
	return Variant_Value{enum_type = "Bus", case_name = variant}
}

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
