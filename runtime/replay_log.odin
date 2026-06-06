// The DURABLE replay-log layer: the on-disk format and the production reader the
// replay re-fold driver consumes. The recorder (replay_record.odin) assembles a
// byte-stable in-memory log from the per-tick resolved action snapshots; this file
// persists that log to a file and parses it back into the artifact identity + the
// ordered snapshot sequence a re-fold re-feeds (spec §23 §4, §09 §5).
//
// §23 §4 vs §24 DETERMINATION (the load-bearing scope boundary): the replay log is
// ACTION-SNAPSHOT serialization riding §23 §4's determinism record — it persists
// the resolved Input snapshots that are the sole recorded source of nondeterminism,
// so a faithful re-run is the same artifact re-fed the same snapshots. It is NOT
// the §24 save/settings persistence layer: §24 owns sim-snapshot saves (committed
// fixed-point world state) and per-machine settings (the rebinding overlay, volume,
// resolution), which are an entirely different concern. The replay log is neither a
// world-state save nor a settings store, so this layer DOES NOT DEPEND ON the §24
// persistence subsystem — it reads and writes only the replay format the recorder
// owns, through core:os, with no save-game or settings type in its path.
//
// ON-DISK ENCODING: the file bytes ARE the in-memory log bytes the recorder
// produced, written verbatim. The byte-stability that holds in memory (§23 §4 —
// fixed field order, raw Q32.32 bits, sorted-key enumeration, no float/wall-clock/
// map-iteration order) therefore holds on disk unchanged: writing is a passthrough,
// not a re-encode, so two runs that record identical snapshot sequences write
// byte-identical files. File IO goes through core:os.write_entire_file /
// read_entire_file_from_path per the Odin-first policy (the runtime owns no custom
// IO); runtime/** never imports funpack/**.
//
// PRODUCTION READER: read_replay is THE parse path the re-fold driver uses — there
// is one parser, not a separate test reader. It validates the magic + schema
// version + header before reading a payload, yields the snapshots back in tick
// order, and FAILS CLOSED (`ok = false`) on a truncated or malformed log rather
// than re-folding a partial stream (the artifact format's exact-match discipline,
// §1, applied to the replay log). The recording-side tests exercise this same
// reader; they do not carry a second parse path.
package funpack_runtime

import "core:os"
import "core:strconv"
import "core:strings"

// write_replay_file persists a finished replay log to a file, byte-exact. The log
// bytes are written verbatim (core:os, Odin-first IO), so the on-disk file equals
// the in-memory log finish_replay produced and read_replay_file round-trips it
// without change. `ok` is false when the file cannot be written; the determinism
// invariant lives in the bytes, so persisting is a passthrough, never a re-encode.
write_replay_file :: proc(path: string, log_bytes: string) -> (ok: bool) {
	return os.write_entire_file_from_string(path, log_bytes) == nil
}

// read_replay_file reads a replay log off disk and parses it into the artifact
// identity + ordered snapshots — the on-disk entry point the re-fold driver opens a
// committed golden log with. `io_ok` is false when the file cannot be read; a file
// that reads but is truncated or malformed surfaces through `ok` from read_replay
// (the same fail-closed refusal, never a best-effort partial log). The file bytes
// are parsed by the one production reader, so an on-disk log and an in-memory log
// take exactly the same path.
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

// --- The production reader (one parse path for disk + in-memory) ------------

// Replay_Log is a parsed replay log: the artifact identity from the header plus
// the ordered per-tick snapshots the re-fold re-feeds. The snapshots own their
// tables — delete_replay_log frees each snapshot and the slice.
Replay_Log :: struct {
	identity:  Replay_Identity,
	snapshots: []Input,
}

// delete_replay_log frees every parsed snapshot's tables and the snapshot slice.
delete_replay_log :: proc(log: Replay_Log) {
	for snapshot in log.snapshots {
		delete_input(snapshot)
	}
	delete(log.snapshots)
}

// read_replay is THE production parser the re-fold driver uses: it parses a log
// the recorder produced back into its header identity and ordered snapshots. `ok`
// is false on any malformed log — a wrong magic, a schema version this build was
// not built for, a record that does not parse, or a truncation that runs the
// parser past the last line — so the driver fails closed rather than re-folding a
// partial stream. Each snapshot is rebuilt by writing the recorded bits straight
// into the snapshot tables (NOT through the lossy producer surface, which would
// re-derive held from pressed and drop the recorded released edge), so the query
// API reads the re-fed snapshot identically to the recorded one.
read_replay :: proc(
	log_bytes: string,
	allocator := context.allocator,
) -> (
	log: Replay_Log,
	ok: bool,
) {
	lines := strings.split_lines(log_bytes, allocator)
	defer delete(lines, allocator)
	// split_lines yields a trailing empty element for the final `\n`; the cursor
	// walks the real lines and the parsers below bound-check their reads, so a log
	// that ends early fails closed instead of reading off the end.
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

	return Replay_Log{identity = identity, snapshots = snapshots[:]}, true
}

// parse_header reads the magic line and the artifact-identity record, advancing
// the cursor past both. It refuses a wrong magic or a schema version this build was
// not built for — the reader loads only the exact format the recorder writes.
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

// parse_identity_record parses the `artifact …` line back into a Replay_Identity.
// The two project strings are length-prefixed (§2.4), so the record is scanned
// field-by-field with a small cursor rather than split on spaces — a name could
// contain a space inside its length-prefixed bytes. The trailing `HAS_SEED
// SEED_BITS` (§25 §60) is parsed in fixed order after the content hash: the seed
// flag as a bare bool, the seed as its raw integer (§10). A v1 log lacking these
// fields fails closed here — but parse_header refuses the v1 magic before reaching
// this parser, so a version-mismatched log never gets this far.
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

// parse_ticks_header reads the `[ticks N]` section header and returns N.
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

// parse_tick reads one tick record — the `tick BUTTON_COUNT AXIS_COUNT` lead line
// then exactly that many button and axis records — into an Input. Each button's
// three bits and each axis's two raw Fixed components are written straight into the
// snapshot tables, so the query API reads them back identically (no producer-side
// re-derivation). A record line missing past the end fails closed.
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

// parse_button_record parses `button PLAYER ACTION PRESSED RELEASED HELD`.
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

// parse_axis_record parses `axis PLAYER ACTION X_BITS Y_BITS` — the two components
// are raw Q32.32 bits, lifted back into Fixed with no float in the path.
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

// parse_key lifts a `PLAYER ACTION` pair back into a Player_Action: the PlayerId
// ordinal (bounded to the four slots) and the ActionId u32.
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

// --- Read-back primitives --------------------------------------------------

// next_line returns the line at the cursor and advances it, or ok=false past the
// end — the bound check every record parser relies on to fail closed on a
// truncated log.
@(private = "file")
next_line :: proc(lines: []string, cursor: ^int) -> (line: string, ok: bool) {
	if cursor^ >= len(lines) {
		return "", false
	}
	line = lines[cursor^]
	cursor^ += 1
	return line, true
}

// parse_bool reads a `true`/`false` bare token (§2.5).
@(private = "file")
parse_bool :: proc(tok: string) -> (v: bool, ok: bool) {
	switch tok {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	return false, false
}

// take_field splits the first space-delimited field off a record line, returning
// the field, the remainder past the space, and ok=false for an empty line. It is
// the scan step the identity record uses around its length-prefixed string fields.
@(private = "file")
take_field :: proc(s: string) -> (field: string, rest: string, ok: bool) {
	if len(s) == 0 {
		return "", "", false
	}
	space := strings.index_byte(s, ' ')
	if space < 0 {
		return s, "", true
	}
	return s[:space], s[space + 1:], true
}

// take_string_field reads a length-prefixed `Lbyte_count:raw_bytes` field (§2.4)
// and returns the decoded bytes plus the remainder past the trailing space. Reading
// the byte count explicitly is what lets a project name carry a space without the
// scan mistaking it for a field delimiter.
@(private = "file")
take_string_field :: proc(s: string) -> (value: string, rest: string, ok: bool) {
	if len(s) == 0 || s[0] != 'L' {
		return "", "", false
	}
	colon := strings.index_byte(s, ':')
	if colon < 0 {
		return "", "", false
	}
	count, count_ok := strconv.parse_int(s[1:colon])
	if !count_ok || count < 0 {
		return "", "", false
	}
	start := colon + 1
	if start + count > len(s) {
		return "", "", false
	}
	value = s[start:start + count]
	rest = s[start + count:]
	if len(rest) > 0 {
		if rest[0] != ' ' {
			return "", "", false
		}
		rest = rest[1:]
	}
	return value, rest, true
}
