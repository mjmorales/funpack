// §28 §3 SESSION RECORD/REPLAY — the session command-log format, recorder, and
// production reader. "Sessions are themselves replayable — the command stream is
// NDJSON and logged, so a debug session (recording + command log) re-runs
// bit-identically and is shareable." This layer owns the COMMAND-LOG half of that
// pair: the recorder logs the full request/async-event stream a live session
// produced; the recording half (the per-tick action snapshots the session opens
// over) is the existing replay log (replay_record.odin / replay_log.odin), so a
// shared session is a replay log + a session command log.
//
// THE STREAM IS THE TRANSCRIPT (§28 §2/§3): every line the duplex transport
// carries is one of the three closed message kinds — a `request` (agent → runtime),
// a `response` (runtime → agent, the request's correlated answer), or an
// `async-event` (an unsolicited runtime → agent push). The recorder logs each as it
// crosses the seam, in order. The request lines ARE the command log a replay
// re-feeds; the response and event lines ARE the recorded transcript a replay must
// reproduce bit-for-bit — the shareable-repro property (a recorded session re-runs
// to a byte-identical transcript).
//
// WHY THIS IS REPLAYABLE BY CONSTRUCTION: session_request (introspect.odin) is a
// PURE fold over (session_state, request) → (session_state, response). Observe
// commands leave the session untouched; control/time commands write only the
// session's own cursor/branch through the SAME deterministic step_tick seam the
// canonical fold ran. So the session state after N requests is a deterministic
// function of (the recording, the request stream) — re-feeding the identical
// request stream through a fresh session over the identical recording reproduces
// every response and event byte-for-byte. The envelopes are already byte-stable by
// design (introspect.odin/introspect_time.odin: fixed field order, raw Q32.32 bits,
// sorted-key enumeration, no float/wall-clock/map-iteration order), so the recorded
// transcript bytes are stable across machines and runs.
//
// ON-DISK ENCODING mirrors the replay log (docs/artifact-format.md §2.1,
// replay_record.odin): a magic + schema-version line, the pinned recording identity
// + snapshot extent, a `[stream N]` section header, then N length-prefixed entry
// lines. The session-log bytes ARE the in-memory log bytes written verbatim through
// core:os (Odin-first IO; the runtime owns no custom IO), so persisting is a
// passthrough — two recordings of the same request stream over the same recording
// write byte-identical files. runtime/** never imports funpack/**; the artifact
// bytes (and the envelope wire) are the only sanctioned coupling (§29, §09).
package funpack_runtime

import "core:os"
import "core:strconv"
import "core:strings"

// SESSION_LOG_SCHEMA_VERSION stamps the session command-log format. Any change to
// the header, the entry framing, or an entry kind bumps this — there is no
// compatible tier, mirroring the replay log's and artifact format's exact-match
// versioning (§29 §2). The replayer refuses a log whose stamp it was not built for.
SESSION_LOG_SCHEMA_VERSION :: 1

// SESSION_LOG_MAGIC is line 1 of every session command log: the format name, so a
// consumer rejects a non-session file before reading any payload (the artifact
// format §1 discipline applied to the session log).
SESSION_LOG_MAGIC :: "funpack-session"

// Session_Entry_Kind is the §28 §2 closed set of wire message kinds the stream
// carries, exactly as the contract names them: a request (agent → runtime), a
// response (runtime → agent, the request's correlated answer), or an async-event
// (an unsolicited runtime → agent push, correlated by event name not id). The kind
// is the entry's leading token, so the reader dispatches on it without parsing the
// JSON payload.
Session_Entry_Kind :: enum {
	Request,
	Response,
	Event,
}

// session_entry_kind_token maps an entry kind to its on-disk token. The token is a
// bare lowercase word leading the entry line; the JSON envelope follows it
// length-prefixed.
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

// Session_Entry is one logged line of the session stream: its message kind plus the
// raw NDJSON envelope as it crossed the seam (a request line, a response line, or
// an async-event line). The envelope is stored VERBATIM — the recorder logs exactly
// the bytes session_request consumed/produced, so the transcript a replay reproduces
// is the literal wire bytes, never a re-rendered approximation.
//
// NDJSON SINGLE-LINE INVARIANT: an envelope is one NDJSON line and carries NO literal
// newline — NDJSON is newline-delimited by definition (one JSON value per line), and
// every response this fold renders escapes control bytes including `\n` (write_json_string,
// introspect.odin), so a payload newline is `\\n`, never a raw `0x0A`. The reader is
// line-based (split on `\n`), so this invariant is what lets a whole envelope ride in
// one length-prefixed entry line; the length prefix guards spaces and `:` inside it.
Session_Entry :: struct {
	kind:     Session_Entry_Kind,
	envelope: string,
}

// Session_Log is a parsed session command log: the pinned recording identity (the
// build the session ran against and its tick-0 seed — the SAME Replay_Identity the
// replay log pins, so the recording and the command log agree on the build), the
// recorded snapshot count (the recording's extent, a cross-check that the paired
// recording is the one this command log was made against), and the ordered stream
// of logged entries. The entries own their envelope strings — delete_session_log
// frees them and the slice.
Session_Log :: struct {
	identity:   Replay_Identity,
	tick_count: int, // the paired recording's snapshot count, pinned for the cross-check
	entries:    []Session_Entry,
}

// delete_session_log frees every parsed entry's envelope and the entry slice.
delete_session_log :: proc(log: Session_Log, allocator := context.allocator) {
	for entry in log.entries {
		delete(entry.envelope, allocator)
	}
	delete(log.entries, allocator)
}

// Session_Log_Writer accumulates the byte-stable command log: the pinned recording
// identity and its snapshot count (written into the header at open), a builder for
// the appended entry lines, and the count of entries appended so far. The framing is
// self-describing — finish_session_log backfills the `[stream N]` count once the
// session is done, so the entry lines live in their own builder without a second
// pass (the same shape the replay writer's `[ticks N]` uses).
Session_Log_Writer :: struct {
	identity:    Replay_Identity,
	tick_count:  int,
	header:      strings.Builder, // magic + recording identity + extent, written at open
	entries:     strings.Builder, // the appended stream entry lines, in stream order
	entry_count: int, // entries appended so far — the `[stream N]` count
}

// open_session_log_writer starts a session-log recording against the recording's
// identity and snapshot count, writing the header up front so the paired recording
// is pinned before any entry is logged. The builders are allocated on the passed
// allocator; finish_session_log returns the assembled bytes and the caller frees the
// writer with delete_session_log_writer.
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

// delete_session_log_writer releases the writer's two builders. A writer is finished
// once; the caller owns the returned log string and frees the writer afterward.
delete_session_log_writer :: proc(writer: ^Session_Log_Writer) {
	strings.builder_destroy(&writer.header)
	strings.builder_destroy(&writer.entries)
}

// log_session_entry appends one stream entry — a kind token then the envelope as a
// length-prefixed string (§2.4), so an envelope carrying any byte (a newline inside
// a JSON string, a space) round-trips without the line framing mistaking it for a
// delimiter. The entries are appended in the exact order they crossed the seam, so
// the recorded stream IS the session transcript.
log_session_entry :: proc(writer: ^Session_Log_Writer, kind: Session_Entry_Kind, envelope: string) {
	b := &writer.entries
	strings.write_string(b, session_entry_kind_token(kind))
	strings.write_byte(b, ' ')
	write_string_field(b, envelope)
	strings.write_byte(b, '\n')
	writer.entry_count += 1
}

// finish_session_log assembles the complete command log: the header, then the
// `[stream N]` section header carrying the final entry count, then the accumulated
// entry lines. Writing the count last is why the entries live in their own builder.
// The returned string is allocated on the passed allocator and owned by the caller;
// the writer is then freed with delete_session_log_writer.
finish_session_log :: proc(writer: ^Session_Log_Writer, allocator := context.allocator) -> string {
	out := strings.builder_make(allocator)
	strings.write_string(&out, strings.to_string(writer.header))
	strings.write_string(&out, "[stream ")
	strings.write_int(&out, writer.entry_count)
	strings.write_string(&out, "]\n")
	strings.write_string(&out, strings.to_string(writer.entries))
	return strings.to_string(out)
}

// --- Header encoding (the recording identity the command log pins) ----------

// write_session_header writes the magic line, then the recording identity record,
// then the recording-extent line. The identity record reuses the replay log's exact
// field order (schema version, length-prefixed project name + version, tick rate,
// content hash, `HAS_SEED SEED_BITS`), so a session log and the replay log it pairs
// with pin the build identically — the replayer cross-checks both speak the same
// recording. The extent line pins the recording's snapshot count, so a command log
// re-driven against a recording of a different length is caught before replay.
@(private = "file")
write_session_header :: proc(b: ^strings.Builder, identity: Replay_Identity, tick_count: int) {
	strings.write_string(b, SESSION_LOG_MAGIC)
	strings.write_byte(b, ' ')
	strings.write_int(b, SESSION_LOG_SCHEMA_VERSION)
	strings.write_byte(b, '\n')

	// The recording-identity record — the SAME line shape write_replay_file's header
	// writes (write_header in replay_record.odin), so the recording and the command
	// log carry an identical build fingerprint and the replayer can pair them.
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

// The §2 field primitives (write_string_field, write_u64, next_line, parse_bool,
// take_field, take_string_field) live in record_codec.odin, shared with the replay
// log and record stream — the on-disk encoding the session log "mirrors the replay
// log" is the SAME codec, not a hand-kept copy.

// --- The on-disk durable layer (one parse path for disk + in-memory) --------

// write_session_log_file persists a finished command log to a file, byte-exact. The
// log bytes are written verbatim (core:os, Odin-first IO), so the on-disk file equals
// the in-memory log finish_session_log produced and read_session_log_file round-trips
// it without change. `ok` is false when the file cannot be written; the byte-stability
// invariant lives in the bytes, so persisting is a passthrough, never a re-encode.
write_session_log_file :: proc(path: string, log_bytes: string) -> (ok: bool) {
	return os.write_entire_file_from_string(path, log_bytes) == nil
}

// read_session_log_file reads a session command log off disk and parses it through
// the one production reader — the entry point a replay opens a committed shared
// session with. `io_ok` is false when the file cannot be read; a file that reads but
// is truncated or malformed surfaces through `ok` from read_session_log (the same
// fail-closed refusal). The file bytes take exactly the same path as an in-memory log.
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

// --- The production reader --------------------------------------------------

// read_session_log is THE production parser the replayer uses: it parses a command
// log the recorder produced back into its recording identity, snapshot extent, and
// ordered stream entries. `ok` is false on any malformed log — a wrong magic, a
// schema version this build was not built for, a record that does not parse, or a
// truncation that runs the parser past the last line — so the replayer fails closed
// rather than re-driving a partial stream (the exact-match discipline, §1). Each
// entry's envelope is copied onto `allocator` so the parsed log outlives the input
// bytes; delete_session_log frees them.
read_session_log :: proc(
	log_bytes: string,
	allocator := context.allocator,
) -> (
	log: Session_Log,
	ok: bool,
) {
	lines := strings.split_lines(log_bytes, allocator)
	defer delete(lines, allocator)
	// split_lines yields a trailing empty element for the final `\n`; the cursor walks
	// the real lines and the parsers bound-check their reads, so a log that ends early
	// fails closed instead of reading off the end.
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

// parse_session_header reads the magic line, the recording-identity record, and the
// snapshot-extent line, advancing the cursor past all three. It refuses a wrong magic
// or a schema version this build was not built for — the reader loads only the exact
// format the recorder writes.
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

// parse_recording_record parses the `recording …` line back into a Replay_Identity.
// The two project strings are length-prefixed (§2.4), so the record is scanned
// field-by-field with a small cursor rather than split on spaces — a name could carry
// a space inside its length-prefixed bytes. The field order mirrors the replay log's
// identity record exactly (parse_identity_record in replay_log.odin): schema, name,
// version, tick rate, content hash, then `HAS_SEED SEED_BITS`.
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

// parse_stream_header reads the `[stream N]` section header and returns N.
@(private = "file")
parse_stream_header :: proc(lines: []string, cursor: ^int) -> (count: int, ok: bool) {
	line, line_ok := next_line(lines, cursor)
	if !line_ok {
		return 0, false
	}
	return parse_section_count(line, "[stream ")
}

// parse_section_count reads a `[<prefix>N]` section header against the expected
// prefix and returns N. Shared by the snapshot-extent and stream headers.
@(private = "file")
parse_section_count :: proc(line: string, prefix: string) -> (count: int, ok: bool) {
	if !strings.has_prefix(line, prefix) || !strings.has_suffix(line, "]") {
		return 0, false
	}
	inner := line[len(prefix):len(line) - 1]
	return strconv.parse_int(inner)
}

// parse_session_entry reads one stream entry — a kind token then the length-prefixed
// envelope — copying the envelope onto `allocator` so the parsed log owns it. An
// unknown kind token or a malformed length-prefixed field fails closed.
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

// parse_session_entry_kind maps an on-disk kind token back to its enum. An unknown
// token is the fail-closed arm — the reader refuses a kind this build does not know.
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

