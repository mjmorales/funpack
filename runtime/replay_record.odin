// Replay recording: append each tick's RESOLVED action snapshot to a byte-stable
// replay log — the SOLE recorded source of nondeterminism in the runtime (spec
// §23 §4, §09 §5). pong has no RNG, the interpreter is the determinism ground
// truth, and raw device state is never recorded, so the resolved snapshot is the
// only thing a faithful re-run must be fed. This layer owns the RECORDING side:
// a versioned header pinning the artifact identity (so a replay refuses a
// mismatched build, §09 §5) plus one deterministic record per tick carrying the
// full resolved snapshot in the action vocabulary input.odin owns.
//
// BYTE-STABILITY (the runtime determinism invariant, §23 §4): identical snapshot
// sequences encode byte-identical across machines and runs. That holds only with
// (1) a fixed field order, (2) fixed-width fixed-point — every Fixed written as
// its raw Q32.32 i64 bits in decimal, never a float or a decimal point, and (3)
// a SORTED key enumeration: Odin map iteration order is unspecified, so this
// recorder sorts the (player, action) keys itself before writing — never leaking
// map-iteration order or wall-clock into the bytes.
//
// BOUNDARY: this layer records the resolved snapshot bindings resolution produced
// (bindings_resolve.odin); it does NOT resolve bindings, read devices, or re-fold
// a replay — the on-disk reader and the replay re-feed driver that re-folds this
// log against a freshly-loaded artifact are a separate layer, as is the
// bit-identity acceptance harness. The framing here mirrors the artifact format's
// line-oriented style (docs/artifact-format.md §2.1) — length-prefixed strings,
// raw Fixed bits, `[section N]` headers — so that re-feed driver reads this log
// with the same parse discipline. runtime/** never imports funpack/**; the
// artifact bytes are the only sanctioned coupling (spec §29, §09).
package funpack_runtime

import "core:hash/xxhash"
import "core:slice"
import "core:strconv"
import "core:strings"

// REPLAY_SCHEMA_VERSION stamps the replay-log format. Any change to the header,
// a record's field order, or an encoding bumps this — there is no compatible
// tier, mirroring the artifact format's exact-match versioning (§29 §2). The
// replay re-feed driver refuses a log whose stamp it was not built for.
REPLAY_SCHEMA_VERSION :: 1

// REPLAY_MAGIC is line 1 of every replay log: the format name and its schema
// version, so the consumer rejects a wrong-version or non-replay file before
// reading any payload (artifact format §1 discipline applied to the replay log).
REPLAY_MAGIC :: "funpack-replay"

// Replay_Identity is the artifact identity the header pins so a replay refuses a
// mismatched build (§09 §5). It is the build-independent fingerprint of the
// artifact a recording was made against: the artifact schema version, the §4
// project name + version, the single fixed tick rate, and a content hash over the
// artifact bytes. A re-fold whose loaded artifact does not reproduce this exact
// identity is NOT the same build, so the recorded snapshots would re-fold against
// the wrong program — the header is the gate that catches that.
Replay_Identity :: struct {
	artifact_schema_version: int, // the artifact's own schema stamp (Program.schema_version)
	project_name:            string, // §4 project name (Project_Meta.name)
	project_version:         string, // §4 project version (Project_Meta.version)
	tick_hz:                 int, // the single fixed tick rate (Entrypoint.tick_hz)
	content_hash:            u64, // xxh64 over the artifact bytes — the build fingerprint
}

// identity_from_program derives the artifact identity from the loaded Program and
// the raw artifact bytes it was loaded from. The content hash is xxh64 (core:hash,
// per the Odin-first policy — no custom hasher) over the artifact bytes verbatim:
// xxh64 is byte-defined and endian-neutral, so the same bytes hash identically on
// every machine, which the determinism contract requires. The bytes are the same
// `content` string load_program parsed, so the recording pins the exact build it
// ran against.
identity_from_program :: proc(program: Program, artifact_bytes: string) -> Replay_Identity {
	return Replay_Identity {
		artifact_schema_version = program.schema_version,
		project_name = program.meta.name,
		project_version = program.meta.version,
		tick_hz = program.entrypoint.tick_hz,
		content_hash = u64(xxhash.XXH64(transmute([]u8)artifact_bytes)),
	}
}

// Replay_Writer accumulates the byte-stable log: an underlying byte builder plus
// the count of tick records appended so far. A writer is opened against an
// artifact identity (which writes the header immediately), each tick's resolved
// snapshot is appended in order, then finished — the finish step backfills the
// declared tick count so the framing is self-describing (§2.1 `[section N]`).
//
// The tick records are appended into a SEPARATE builder from the header so the
// `[ticks N]` section header can be written with the final count once the run is
// known, without a second pass over the records or a placeholder rewrite.
Replay_Writer :: struct {
	identity:    Replay_Identity,
	header:      strings.Builder, // magic + artifact-identity record, written at open
	records:     strings.Builder, // the appended per-tick records, in tick order
	tick_count:  int, // records appended so far — the `[ticks N]` count
}

// open_replay_writer starts a recording against an artifact identity, writing the
// header (magic line + artifact-identity record) up front so the build is pinned
// before any tick is recorded. The two builders are allocated on the passed
// allocator; finish_replay returns the assembled bytes and the caller frees the
// writer with delete_replay_writer.
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

// delete_replay_writer releases the writer's two builders. A writer is finished
// once; the caller owns the returned log string and frees the writer afterward.
delete_replay_writer :: proc(writer: ^Replay_Writer) {
	strings.builder_destroy(&writer.header)
	strings.builder_destroy(&writer.records)
}

// record_tick appends one tick's RESOLVED snapshot as a single deterministic
// record (spec §23 §4). The record is: a `tick BUTTON_COUNT AXIS_COUNT` lead line,
// then the buttons in SORTED (player, action) order, then the axes in SORTED
// (player, action) order. Sorting here — not relying on map iteration — is what
// makes the bytes identical across machines (Odin leaves map order unspecified).
// Every Fixed is its raw Q32.32 bits; every bool is `true`/`false`; no float, no
// wall-clock, no map-iteration order reaches the bytes.
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

// finish_replay assembles the complete log: the header, then the `[ticks N]`
// section header carrying the final tick count, then the accumulated tick records.
// Writing the count last is why the records live in their own builder — the
// framing is self-describing (§2.1) without a placeholder rewrite. The returned
// string is allocated on the passed allocator and owned by the caller; the writer
// is then freed with delete_replay_writer.
finish_replay :: proc(writer: ^Replay_Writer, allocator := context.allocator) -> string {
	out := strings.builder_make(allocator)
	strings.write_string(&out, strings.to_string(writer.header))
	strings.write_string(&out, "[ticks ")
	strings.write_int(&out, writer.tick_count)
	strings.write_string(&out, "]\n")
	strings.write_string(&out, strings.to_string(writer.records))
	return strings.to_string(out)
}

// --- Header encoding -------------------------------------------------------

// write_header writes the magic line and the artifact-identity record. The
// identity record's field order is fixed: schema version, project name (length-
// prefixed §2.4), project version (length-prefixed), tick rate, then the content
// hash. A replay reader checks this record against its freshly-loaded artifact and
// refuses a mismatch (§09 §5) before reading a single tick.
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
	strings.write_byte(b, '\n')
}

// --- Per-record encoding ---------------------------------------------------

// write_button_record writes one button entry: `button PLAYER ACTION PRESSED
// RELEASED HELD`. PLAYER is the PlayerId ordinal, ACTION the ActionId as a plain
// decimal u32, and the three edge/level bits as bools in fixed order (§23 §2).
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

// write_axis_record writes one axis entry: `axis PLAYER ACTION X_BITS Y_BITS`.
// Each component is its raw Q32.32 i64 bits in decimal (the fixed-width fixed-point
// encoding, §2.3) — never a decimal point, so the bytes are machine-independent.
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

// write_key writes a (player, action) key as `PLAYER ACTION`: the PlayerId ordinal
// then the ActionId as a decimal u32. Both are stable per-artifact identities, so a
// record line names the snapshot slot unambiguously without the enum vocabulary.
@(private = "file")
write_key :: proc(b: ^strings.Builder, key: Player_Action) {
	strings.write_int(b, int(key.player))
	strings.write_byte(b, ' ')
	write_u64(b, u64(key.action))
}

// --- Field primitives (artifact-format §2 style) ---------------------------

// write_string_field writes a length-prefixed string `Lbyte_count:raw_bytes`
// (§2.4): the byte count, a `:`, then the bytes verbatim. A reader consumes exactly
// that many bytes, so a name containing a space or `:` never confuses the parser.
@(private = "file")
write_string_field :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, 'L')
	strings.write_int(b, len(s))
	strings.write_byte(b, ':')
	strings.write_string(b, s)
}

// write_bool writes `true`/`false` as a bare lowercase token (§2.5).
@(private = "file")
write_bool :: proc(b: ^strings.Builder, v: bool) {
	strings.write_string(b, v ? "true" : "false")
}

// write_u64 writes an unsigned 64-bit value in decimal. ActionId and the content
// hash are unsigned, so they go through here rather than write_i64 (which would
// mis-render a high-bit-set value as negative).
@(private = "file")
write_u64 :: proc(b: ^strings.Builder, v: u64) {
	buf: [20]byte
	strings.write_string(b, strconv.write_uint(buf[:], v, 10))
}

// --- Sorted key enumeration (the byte-stability load-bearing step) ---------

// sorted_keys returns the map's keys in a DEFINED total order — (player ordinal,
// then action id) ascending. Odin specifies no map iteration order, so a recorder
// that wrote keys in map-iteration order would produce different bytes on different
// runs; sorting here is what makes the encoding byte-identical across machines
// (§23 §4). The dynamic array is allocated on the passed allocator and freed by the
// caller with delete (returned as a [dynamic] so delete matches the allocation).
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

// player_action_less is the total order sorted_keys imposes: primary key the
// PlayerId ordinal, tie-broken by the ActionId. A total order over the composite
// key is what makes the enumeration deterministic regardless of insertion order.
@(private = "file")
player_action_less :: proc(a, b: Player_Action) -> bool {
	if a.player != b.player {
		return a.player < b.player
	}
	return a.action < b.action
}

// --- In-memory read-back (test-sufficient, NOT the re-feed driver) ---------
// The on-disk reader and the replay re-feed driver that re-folds a log are a
// separate layer. What this layer provides is the matching read-back needed to
// PROVE the recording side: parse a log produced by the writer above back into its
// header identity and its per-tick snapshots, so a test can assert (1) a recorded
// snapshot round-trips to an Input the query API reads identically to the original,
// and (2) the header pins the artifact identity. It reads only the format this file
// writes; it does not re-fold a tick, drive a sim, or read from disk.

// Replay_Log is a parsed replay log: the artifact identity from the header plus
// the ordered per-tick snapshots. The snapshots own their tables — free each with
// delete_input and the slice with delete(snapshots) (delete_replay_log does both).
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

// read_replay parses a log the writer above produced back into its header identity
// and ordered snapshots. `ok` is false on a malformed log — a wrong magic, a
// version the read-back was not built for, or a record that does not parse — so a
// test fails closed rather than reading a partial log. Each snapshot is rebuilt by
// writing the recorded bits straight into the snapshot tables (NOT through the
// lossy producer surface, which would re-derive held from pressed and drop the
// recorded released edge), so the query API reads the round-tripped snapshot
// identically to the original.
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
	// walks the real lines and the parsers below bound-check their reads.
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
// the cursor past both. It refuses a wrong magic or a version it was not built for
// — the read-back loads only the exact format this file writes.
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
// contain a space inside its length-prefixed bytes.
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

	hash_tok, _, hash_field_ok := take_field(rest)
	if !hash_field_ok {
		return {}, false
	}
	content_hash, hash_ok := strconv.parse_u64(hash_tok)
	if !hash_ok {
		return {}, false
	}

	return Replay_Identity {
			artifact_schema_version = schema,
			project_name = name,
			project_version = version,
			tick_hz = tick_hz,
			content_hash = content_hash,
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
// re-derivation).
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
// end — the bound check every record parser relies on.
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
