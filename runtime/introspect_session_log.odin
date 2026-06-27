package funpack_runtime

import "core:os"
import "core:strconv"
import "core:strings"

SESSION_LOG_SCHEMA_VERSION :: 1

SESSION_LOG_MAGIC :: "funpack-session"

Session_Entry_Kind :: enum {
	Request,
	Response,
	Event,
}

session_entry_kind_token :: proc(kind: Session_Entry_Kind) -> string {
	switch kind {
	case .Request:
		return "request"
	case .Response:
		return "response"
	case .Event:
		return "event"
	}
	return ""
}

Session_Entry :: struct {
	kind:     Session_Entry_Kind,
	envelope: string,
}

Session_Log :: struct {
	identity:   Replay_Identity,
	tick_count: int,
	entries:    []Session_Entry,
}

delete_session_log :: proc(log: Session_Log, allocator := context.allocator) {
	for entry in log.entries {
		delete(entry.envelope, allocator)
	}
	delete(log.entries, allocator)
}

Session_Log_Writer :: struct {
	identity:    Replay_Identity,
	tick_count:  int,
	header:      strings.Builder,
	entries:     strings.Builder,
	entry_count: int,
}

open_session_log_writer :: proc(
	identity: Replay_Identity,
	tick_count: int,
	allocator := context.allocator,
) -> Session_Log_Writer {
	writer := Session_Log_Writer {
		identity   = identity,
		tick_count = tick_count,
		header     = strings.builder_make(allocator),
		entries    = strings.builder_make(allocator),
	}
	write_session_header(&writer.header, identity, tick_count)
	return writer
}

delete_session_log_writer :: proc(writer: ^Session_Log_Writer) {
	strings.builder_destroy(&writer.header)
	strings.builder_destroy(&writer.entries)
}

log_session_entry :: proc(writer: ^Session_Log_Writer, kind: Session_Entry_Kind, envelope: string) {
	b := &writer.entries
	strings.write_string(b, session_entry_kind_token(kind))
	strings.write_byte(b, ' ')
	write_string_field(b, envelope)
	strings.write_byte(b, '\n')
	writer.entry_count += 1
}

finish_session_log :: proc(writer: ^Session_Log_Writer, allocator := context.allocator) -> string {
	out := strings.builder_make(allocator)
	strings.write_string(&out, strings.to_string(writer.header))
	strings.write_string(&out, "[stream ")
	strings.write_int(&out, writer.entry_count)
	strings.write_string(&out, "]\n")
	strings.write_string(&out, strings.to_string(writer.entries))
	return strings.to_string(out)
}

@(private = "file")
write_session_header :: proc(b: ^strings.Builder, identity: Replay_Identity, tick_count: int) {
	strings.write_string(b, SESSION_LOG_MAGIC)
	strings.write_byte(b, ' ')
	strings.write_int(b, SESSION_LOG_SCHEMA_VERSION)
	strings.write_byte(b, '\n')

	strings.write_string(b, "recording ")
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
	strings.write_string(b, identity.has_seed ? "true" : "false")
	strings.write_byte(b, ' ')
	strings.write_i64(b, identity.seed)
	strings.write_byte(b, '\n')

	strings.write_string(b, "[snapshots ")
	strings.write_int(b, tick_count)
	strings.write_string(b, "]\n")
}

write_session_log_file :: proc(path: string, log_bytes: string) -> (ok: bool) {
	return os.write_entire_file_from_string(path, log_bytes) == nil
}

read_session_log_file :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	log: Session_Log,
	ok: bool,
	io_ok: bool,
) {
	bytes, read_err := os.read_entire_file_from_path(path, allocator)
	if read_err != nil {
		return {}, false, false
	}
	defer delete(bytes, allocator)
	parsed, parse_ok := read_session_log(string(bytes), allocator)
	return parsed, parse_ok, true
}

read_session_log :: proc(
	log_bytes: string,
	allocator := context.allocator,
) -> (
	log: Session_Log,
	ok: bool,
) {
	lines := strings.split_lines(log_bytes, allocator)
	defer delete(lines, allocator)
	cursor := 0

	identity, tick_count, header_ok := parse_session_header(lines, &cursor)
	if !header_ok {
		return {}, false
	}

	entry_count, stream_ok := parse_stream_header(lines, &cursor)
	if !stream_ok {
		return {}, false
	}

	entries := make([dynamic]Session_Entry, 0, entry_count, allocator)
	for _ in 0 ..< entry_count {
		entry, entry_ok := parse_session_entry(lines, &cursor, allocator)
		if !entry_ok {
			for built in entries {
				delete(built.envelope, allocator)
			}
			delete(entries)
			return {}, false
		}
		append(&entries, entry)
	}

	return Session_Log{identity = identity, tick_count = tick_count, entries = entries[:]}, true
}

@(private = "file")
parse_session_header :: proc(
	lines: []string,
	cursor: ^int,
) -> (
	identity: Replay_Identity,
	tick_count: int,
	ok: bool,
) {
	magic_line, magic_ok := next_line(lines, cursor)
	if !magic_ok {
		return {}, 0, false
	}
	magic_fields := strings.fields(magic_line, context.temp_allocator)
	if len(magic_fields) != 2 || magic_fields[0] != SESSION_LOG_MAGIC {
		return {}, 0, false
	}
	version, version_ok := strconv.parse_int(magic_fields[1])
	if !version_ok || version != SESSION_LOG_SCHEMA_VERSION {
		return {}, 0, false
	}

	identity_line, line_ok := next_line(lines, cursor)
	if !line_ok {
		return {}, 0, false
	}
	parsed_identity, identity_ok := parse_recording_record(identity_line)
	if !identity_ok {
		return {}, 0, false
	}

	extent_line, extent_line_ok := next_line(lines, cursor)
	if !extent_line_ok {
		return {}, 0, false
	}
	count, count_ok := parse_section_count(extent_line, "[snapshots ")
	if !count_ok {
		return {}, 0, false
	}
	return parsed_identity, count, true
}

@(private = "file")
parse_recording_record :: proc(line: string) -> (identity: Replay_Identity, ok: bool) {
	rest := line
	keyword, after_keyword, kw_ok := take_field(rest)
	if !kw_ok || keyword != "recording" {
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
parse_stream_header :: proc(lines: []string, cursor: ^int) -> (count: int, ok: bool) {
	line, line_ok := next_line(lines, cursor)
	if !line_ok {
		return 0, false
	}
	return parse_section_count(line, "[stream ")
}

@(private = "file")
parse_section_count :: proc(line: string, prefix: string) -> (count: int, ok: bool) {
	if !strings.has_prefix(line, prefix) || !strings.has_suffix(line, "]") {
		return 0, false
	}
	inner := line[len(prefix):len(line) - 1]
	return strconv.parse_int(inner)
}

@(private = "file")
parse_session_entry :: proc(
	lines: []string,
	cursor: ^int,
	allocator := context.allocator,
) -> (
	entry: Session_Entry,
	ok: bool,
) {
	line, line_ok := next_line(lines, cursor)
	if !line_ok {
		return {}, false
	}
	kind_tok, after_kind, kind_field_ok := take_field(line)
	if !kind_field_ok {
		return {}, false
	}
	kind, kind_ok := parse_session_entry_kind(kind_tok)
	if !kind_ok {
		return {}, false
	}
	envelope, _, env_ok := take_string_field(after_kind)
	if !env_ok {
		return {}, false
	}
	return Session_Entry{kind = kind, envelope = strings.clone(envelope, allocator)}, true
}

@(private = "file")
parse_session_entry_kind :: proc(tok: string) -> (kind: Session_Entry_Kind, ok: bool) {
	switch tok {
	case "request":
		return .Request, true
	case "response":
		return .Response, true
	case "event":
		return .Event, true
	}
	return .Request, false
}
