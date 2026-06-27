package funpack_runtime

import "core:os"
import "core:strconv"
import "core:strings"

write_replay_file :: proc(path: string, log_bytes: string) -> (ok: bool) {
	return os.write_entire_file_from_string(path, log_bytes) == nil
}

read_replay_file :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	log: Replay_Log,
	ok: bool,
	io_ok: bool,
) {
	bytes, read_err := os.read_entire_file_from_path(path, allocator)
	if read_err != nil {
		return {}, false, false
	}
	defer delete(bytes, allocator)
	parsed, parse_ok := read_replay(string(bytes), allocator)
	return parsed, parse_ok, true
}

Replay_Log :: struct {
	identity:  Replay_Identity,
	snapshots: []Input,
}

delete_replay_log :: proc(log: Replay_Log) {
	delete(log.identity.project_name)
	delete(log.identity.project_version)
	for snapshot in log.snapshots {
		delete_input(snapshot)
	}
	delete(log.snapshots)
}

read_replay :: proc(
	log_bytes: string,
	allocator := context.allocator,
) -> (
	log: Replay_Log,
	ok: bool,
) {
	lines := strings.split_lines(log_bytes, allocator)
	defer delete(lines, allocator)
	cursor := 0

	identity, identity_ok := parse_header(lines, &cursor)
	if !identity_ok {
		return {}, false
	}

	tick_count, ticks_ok := parse_ticks_header(lines, &cursor)
	if !ticks_ok {
		return {}, false
	}

	snapshots := make([dynamic]Input, 0, tick_count, allocator)
	for _ in 0 ..< tick_count {
		snapshot, snap_ok := parse_tick(lines, &cursor, allocator)
		if !snap_ok {
			for built in snapshots {
				delete_input(built)
			}
			delete(snapshots)
			return {}, false
		}
		append(&snapshots, snapshot)
	}

	identity.project_name = strings.clone(identity.project_name, allocator)
	identity.project_version = strings.clone(identity.project_version, allocator)
	return Replay_Log{identity = identity, snapshots = snapshots[:]}, true
}

@(private = "file")
parse_header :: proc(
	lines: []string,
	cursor: ^int,
) -> (
	identity: Replay_Identity,
	ok: bool,
) {
	magic_line, magic_ok := next_line(lines, cursor)
	if !magic_ok {
		return {}, false
	}
	magic_fields := strings.fields(magic_line, context.temp_allocator)
	if len(magic_fields) != 2 || magic_fields[0] != REPLAY_MAGIC {
		return {}, false
	}
	version, version_ok := strconv.parse_int(magic_fields[1])
	if !version_ok || version != REPLAY_SCHEMA_VERSION {
		return {}, false
	}

	identity_line, line_ok := next_line(lines, cursor)
	if !line_ok {
		return {}, false
	}
	return parse_identity_record(identity_line)
}

@(private = "file")
parse_identity_record :: proc(line: string) -> (identity: Replay_Identity, ok: bool) {
	rest := line
	keyword, after_keyword, kw_ok := take_field(rest)
	if !kw_ok || keyword != "artifact" {
		return {}, false
	}
	rest = after_keyword

	schema_tok, after_schema, schema_field_ok := take_field(rest)
	if !schema_field_ok {
		return {}, false
	}
	schema, schema_ok := strconv.parse_int(schema_tok)
	if !schema_ok {
		return {}, false
	}
	rest = after_schema

	name, after_name, name_ok := take_string_field(rest)
	if !name_ok {
		return {}, false
	}
	rest = after_name

	version, after_version, version_ok := take_string_field(rest)
	if !version_ok {
		return {}, false
	}
	rest = after_version

	hz_tok, after_hz, hz_field_ok := take_field(rest)
	if !hz_field_ok {
		return {}, false
	}
	tick_hz, hz_ok := strconv.parse_int(hz_tok)
	if !hz_ok {
		return {}, false
	}
	rest = after_hz

	hash_tok, after_hash, hash_field_ok := take_field(rest)
	if !hash_field_ok {
		return {}, false
	}
	content_hash, hash_ok := strconv.parse_u64(hash_tok)
	if !hash_ok {
		return {}, false
	}
	rest = after_hash

	has_seed_tok, after_has_seed, has_seed_field_ok := take_field(rest)
	if !has_seed_field_ok {
		return {}, false
	}
	has_seed, has_seed_ok := parse_bool(has_seed_tok)
	if !has_seed_ok {
		return {}, false
	}
	rest = after_has_seed

	seed_tok, _, seed_field_ok := take_field(rest)
	if !seed_field_ok {
		return {}, false
	}
	seed, seed_ok := strconv.parse_i64(seed_tok)
	if !seed_ok {
		return {}, false
	}

	return Replay_Identity {
			artifact_schema_version = schema,
			project_name = name,
			project_version = version,
			tick_hz = tick_hz,
			content_hash = content_hash,
			has_seed = has_seed,
			seed = seed,
		},
		true
}

@(private = "file")
parse_ticks_header :: proc(lines: []string, cursor: ^int) -> (count: int, ok: bool) {
	line, line_ok := next_line(lines, cursor)
	if !line_ok {
		return 0, false
	}
	if !strings.has_prefix(line, "[ticks ") || !strings.has_suffix(line, "]") {
		return 0, false
	}
	inner := line[len("[ticks "):len(line) - 1]
	return strconv.parse_int(inner)
}

@(private = "file")
parse_tick :: proc(
	lines: []string,
	cursor: ^int,
	allocator := context.allocator,
) -> (
	snapshot: Input,
	ok: bool,
) {
	lead, lead_ok := next_line(lines, cursor)
	if !lead_ok {
		return {}, false
	}
	lead_fields := strings.fields(lead, context.temp_allocator)
	if len(lead_fields) != 3 || lead_fields[0] != "tick" {
		return {}, false
	}
	button_count, bc_ok := strconv.parse_int(lead_fields[1])
	axis_count, ac_ok := strconv.parse_int(lead_fields[2])
	if !bc_ok || !ac_ok {
		return {}, false
	}

	snapshot = Input {
		buttons = make(map[Player_Action]Button_State, allocator),
		axes    = make(map[Player_Action]Vec2, allocator),
	}

	for _ in 0 ..< button_count {
		line, line_ok := next_line(lines, cursor)
		if !line_ok {
			delete_input(snapshot)
			return {}, false
		}
		key, state, rec_ok := parse_button_record(line)
		if !rec_ok {
			delete_input(snapshot)
			return {}, false
		}
		snapshot.buttons[key] = state
	}
	for _ in 0 ..< axis_count {
		line, line_ok := next_line(lines, cursor)
		if !line_ok {
			delete_input(snapshot)
			return {}, false
		}
		key, vec, rec_ok := parse_axis_record(line)
		if !rec_ok {
			delete_input(snapshot)
			return {}, false
		}
		snapshot.axes[key] = vec
	}

	return snapshot, true
}

@(private = "file")
parse_button_record :: proc(
	line: string,
) -> (
	key: Player_Action,
	state: Button_State,
	ok: bool,
) {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) != 6 || fields[0] != "button" {
		return {}, {}, false
	}
	parsed_key, key_ok := parse_key(fields[1], fields[2])
	if !key_ok {
		return {}, {}, false
	}
	pressed, p_ok := parse_bool(fields[3])
	released, r_ok := parse_bool(fields[4])
	held, h_ok := parse_bool(fields[5])
	if !p_ok || !r_ok || !h_ok {
		return {}, {}, false
	}
	return parsed_key, Button_State{pressed = pressed, released = released, held = held}, true
}

@(private = "file")
parse_axis_record :: proc(line: string) -> (key: Player_Action, vec: Vec2, ok: bool) {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) != 5 || fields[0] != "axis" {
		return {}, {}, false
	}
	parsed_key, key_ok := parse_key(fields[1], fields[2])
	if !key_ok {
		return {}, {}, false
	}
	x_bits, x_ok := strconv.parse_i64(fields[3])
	y_bits, y_ok := strconv.parse_i64(fields[4])
	if !x_ok || !y_ok {
		return {}, {}, false
	}
	return parsed_key, Vec2{x = Fixed(x_bits), y = Fixed(y_bits)}, true
}

@(private = "file")
parse_key :: proc(player_tok, action_tok: string) -> (key: Player_Action, ok: bool) {
	player_ord, player_ok := strconv.parse_int(player_tok)
	if !player_ok || player_ord < int(PlayerId.P1) || player_ord > int(PlayerId.P4) {
		return {}, false
	}
	action_raw, action_ok := strconv.parse_u64(action_tok)
	if !action_ok || action_raw > u64(max(u32)) {
		return {}, false
	}
	return Player_Action{player = PlayerId(player_ord), action = ActionId(u32(action_raw))}, true
}
