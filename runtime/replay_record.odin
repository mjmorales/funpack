package funpack_runtime

import "core:hash/xxhash"
import "core:slice"
import "core:strings"

REPLAY_SCHEMA_VERSION :: 2

REPLAY_MAGIC :: "funpack-replay"

Replay_Identity :: struct {
	artifact_schema_version: int,
	project_name:            string,
	project_version:         string,
	tick_hz:                 int,
	content_hash:            u64,
	has_seed:                bool,
	seed:                    i64,
}

identity_from_program :: proc(program: Program, artifact_bytes: string) -> Replay_Identity {
	return Replay_Identity {
		artifact_schema_version = program.schema_version,
		project_name = program.meta.name,
		project_version = program.meta.version,
		tick_hz = program.entrypoint.tick_hz,
		content_hash = u64(xxhash.XXH64(transmute([]u8)artifact_bytes)),
		has_seed = false,
		seed = 0,
	}
}

identity_from_program_seeded :: proc(
	program: Program,
	artifact_bytes: string,
	seed: i64,
) -> Replay_Identity {
	identity := identity_from_program(program, artifact_bytes)
	identity.has_seed = true
	identity.seed = seed
	return identity
}

Replay_Writer :: struct {
	identity:    Replay_Identity,
	header:      strings.Builder,
	records:     strings.Builder,
	tick_count:  int,
}

open_replay_writer :: proc(
	identity: Replay_Identity,
	allocator := context.allocator,
) -> Replay_Writer {
	writer := Replay_Writer {
		identity = identity,
		header   = strings.builder_make(allocator),
		records  = strings.builder_make(allocator),
	}
	write_header(&writer.header, identity)
	return writer
}

delete_replay_writer :: proc(writer: ^Replay_Writer) {
	strings.builder_destroy(&writer.header)
	strings.builder_destroy(&writer.records)
}

record_tick :: proc(writer: ^Replay_Writer, snapshot: Input, allocator := context.allocator) {
	button_keys := sorted_keys(snapshot.buttons, allocator)
	defer delete(button_keys)
	axis_keys := sorted_keys(snapshot.axes, allocator)
	defer delete(axis_keys)

	b := &writer.records
	strings.write_string(b, "tick ")
	strings.write_int(b, len(button_keys))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(axis_keys))
	strings.write_byte(b, '\n')

	for key in button_keys {
		state := snapshot.buttons[key]
		write_button_record(b, key, state)
	}
	for key in axis_keys {
		vec := snapshot.axes[key]
		write_axis_record(b, key, vec)
	}

	writer.tick_count += 1
}

finish_replay :: proc(writer: ^Replay_Writer, allocator := context.allocator) -> string {
	out := strings.builder_make(allocator)
	strings.write_string(&out, strings.to_string(writer.header))
	strings.write_string(&out, "[ticks ")
	strings.write_int(&out, writer.tick_count)
	strings.write_string(&out, "]\n")
	strings.write_string(&out, strings.to_string(writer.records))
	return strings.to_string(out)
}

@(private = "file")
write_header :: proc(b: ^strings.Builder, identity: Replay_Identity) {
	strings.write_string(b, REPLAY_MAGIC)
	strings.write_byte(b, ' ')
	strings.write_int(b, REPLAY_SCHEMA_VERSION)
	strings.write_byte(b, '\n')

	strings.write_string(b, "artifact ")
	strings.write_int(b, identity.artifact_schema_version)
	strings.write_byte(b, ' ')
	write_string_field(b, identity.project_name)
	strings.write_byte(b, ' ')
	write_string_field(b, identity.project_version)
	strings.write_byte(b, ' ')
	strings.write_int(b, identity.tick_hz)
	strings.write_byte(b, ' ')
	write_u64(b, identity.content_hash)
	strings.write_byte(b, ' ')
	write_bool(b, identity.has_seed)
	strings.write_byte(b, ' ')
	strings.write_i64(b, identity.seed)
	strings.write_byte(b, '\n')
}

@(private = "file")
write_button_record :: proc(b: ^strings.Builder, key: Player_Action, state: Button_State) {
	strings.write_string(b, "button ")
	write_key(b, key)
	strings.write_byte(b, ' ')
	write_bool(b, state.pressed)
	strings.write_byte(b, ' ')
	write_bool(b, state.released)
	strings.write_byte(b, ' ')
	write_bool(b, state.held)
	strings.write_byte(b, '\n')
}

@(private = "file")
write_axis_record :: proc(b: ^strings.Builder, key: Player_Action, vec: Vec2) {
	strings.write_string(b, "axis ")
	write_key(b, key)
	strings.write_byte(b, ' ')
	strings.write_i64(b, i64(vec.x))
	strings.write_byte(b, ' ')
	strings.write_i64(b, i64(vec.y))
	strings.write_byte(b, '\n')
}

@(private = "file")
write_key :: proc(b: ^strings.Builder, key: Player_Action) {
	strings.write_int(b, int(key.player))
	strings.write_byte(b, ' ')
	write_u64(b, u64(key.action))
}

@(private = "file")
write_bool :: proc(b: ^strings.Builder, v: bool) {
	strings.write_string(b, v ? "true" : "false")
}

@(private = "file")
sorted_keys :: proc(
	m: $M/map[Player_Action]$V,
	allocator := context.allocator,
) -> [dynamic]Player_Action {
	keys := make([dynamic]Player_Action, 0, len(m), allocator)
	for key in m {
		append(&keys, key)
	}
	slice.sort_by(keys[:], player_action_less)
	return keys
}

@(private = "file")
player_action_less :: proc(a, b: Player_Action) -> bool {
	if a.player != b.player {
		return a.player < b.player
	}
	return a.action < b.action
}
