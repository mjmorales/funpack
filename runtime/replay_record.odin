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
// a replay. The on-disk durable layer and the production reader that parses this
// log back live in replay_log.odin; the replay re-feed driver that re-folds the
// parsed log against a freshly-loaded artifact, and the bit-identity acceptance
// harness, are further layers above that. The framing here mirrors the artifact
// format's line-oriented style (docs/artifact-format.md §2.1) — length-prefixed
// strings, raw Fixed bits, `[section N]` headers — so the production reader and
// the re-feed driver read this log with the same parse discipline. runtime/**
// never imports funpack/**; the artifact bytes are the only sanctioned coupling
// (spec §29, §09).
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
