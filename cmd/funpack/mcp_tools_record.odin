package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:os"
import "core:strings"

mcp_record_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	if !rec_owns_command(dispatch.spec) {
		return "", false
	}

	switch dispatch.name {
	case "record":
		return rec_record(dispatch, allocator), true
	}

	return mcp_tool_error(
		dispatch.id,
		Mcp_Error{category = .Internal, message = "record-family tool has no dispatch arm", detail = dispatch.name},
		allocator,
	), true
}

rec_owns_command :: proc(spec: funpack.Tool_Spec) -> bool {
	return spec.group == "record"
}

rec_record :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	artifact, has_artifact := funpack_runtime.json_string_field(dispatch.arguments, "artifact")
	if !has_artifact {
		return mcp_tool_error(dispatch.id, mcp_missing_string_field("artifact", dispatch.name, allocator), allocator)
	}

	artifact_bytes, read_err := os.read_entire_file_from_path(artifact, allocator)
	if read_err != nil {
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Resolver, message = "the artifact could not be read", detail = artifact},
			allocator,
		)
	}
	program, load_err := funpack_runtime.load_program(string(artifact_bytes), allocator)
	if load_err != .None {
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "the artifact bytes did not parse as a funpack build", detail = artifact},
			allocator,
		)
	}

	segments, script_err := rec_parse_script(&program, dispatch.arguments, allocator)
	if script_err.message != "" {
		return mcp_tool_error(dispatch.id, script_err, allocator)
	}

	seed_override: Maybe(i64)
	if seed, has_seed := rec_int_arg(dispatch.arguments, "seed"); has_seed {
		seed_override = seed
	}

	out_override, _ := funpack_runtime.json_string_field(dispatch.arguments, "out")
	out_path := funpack_runtime.replay_out_path(artifact, out_override, allocator)

	log_bytes, summary := funpack_runtime.record_scripted(&program, string(artifact_bytes), seed_override, segments, allocator)
	if !funpack_runtime.write_replay_file(out_path, log_bytes) {
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Resolver, message = "the replay log could not be written", detail = out_path},
			allocator,
		)
	}

	body := rec_render_result(out_path, summary, allocator)
	return mcp_text_result(dispatch.id, body, allocator)
}

rec_parse_script :: proc(
	program: ^funpack_runtime.Program,
	arguments: json.Object,
	allocator := context.allocator,
) -> (
	segments: []funpack_runtime.Scripted_Segment,
	err: Mcp_Error,
) {
	field, present := arguments["script"]
	if !present {
		return nil, Mcp_Error{category = .Invalid_Input, message = "missing required array argument: script"}
	}
	array, is_array := field.(json.Array)
	if !is_array {
		return nil, Mcp_Error{category = .Invalid_Input, message = "script must be an array of input segments"}
	}
	if len(array) == 0 {
		return nil, Mcp_Error{category = .Invalid_Input, message = "script must carry at least one input segment"}
	}

	built := make([dynamic]funpack_runtime.Scripted_Segment, 0, len(array), allocator)
	for element, i in array {
		object, is_object := element.(json.Object)
		if !is_object {
			return nil, Mcp_Error{category = .Invalid_Input, message = "each script segment must be an object", detail = rec_segment_label(i, allocator)}
		}
		ticks := i64(1)
		if requested, has_ticks := rec_int_field(object, "ticks"); has_ticks {
			ticks = requested
		}
		if ticks < 1 {
			return nil, Mcp_Error{category = .Invalid_Input, message = "each script segment needs ticks >= 1", detail = rec_segment_label(i, allocator)}
		}
		snapshot, build_err := funpack_runtime.build_input_snapshot(program, object, allocator)
		if build_err != "" {
			return nil, Mcp_Error{category = .Invalid_Input, message = build_err, detail = rec_segment_label(i, allocator)}
		}
		append(&built, funpack_runtime.Scripted_Segment{snapshot = snapshot, ticks = int(ticks)})
	}
	return built[:], Mcp_Error{}
}

rec_segment_label :: proc(index: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "segment ")
	strings.write_int(&b, index)
	return strings.to_string(b)
}

rec_render_result :: proc(path: string, summary: funpack_runtime.Scripted_Record_Summary, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"path\":")
	funpack_runtime.write_json_string(&b, path)
	strings.write_string(&b, ",\"ticks\":")
	strings.write_int(&b, summary.tick_count)
	strings.write_string(&b, ",\"has_seed\":")
	strings.write_string(&b, summary.has_seed ? "true" : "false")
	strings.write_string(&b, ",\"seed\":")
	strings.write_i64(&b, summary.seed)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

rec_int_arg :: proc(arguments: json.Object, name: string) -> (value: i64, has: bool) {
	return rec_int_field(arguments, name)
}

rec_int_field :: proc(object: json.Object, name: string) -> (value: i64, has: bool) {
	return funpack_runtime.json_int_field(object, name)
}
