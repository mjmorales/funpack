// The deterministic per-tick frame digest (spec §20, §28, §10.5): the
// comparison surface a determinism assertion compares two runs against. For each
// COMMITTED tick this layer serializes the committed fixed-point world state
// and/or the §20 draw-list into a CANONICAL, machine-invariant byte stream and
// folds it to a content hash — a per-tick digest plus a session digest over the
// whole run. It is an OBSERVE-class projection (§28, screenshot{include_drawlist}
// style): it reads a committed version and never perturbs the fold, so digesting
// a session cannot change its outcome.
//
// CANONICAL ENCODING (the byte-stability this rests on): every number is its raw
// fixed-width LITTLE-ENDIAN bits — a Fixed or an Int as its 8-byte Q32.32 / i64
// bits, never a float or a decimal point — so the bytes are identical on every
// machine (§10: no float anywhere in the determinism path). Things serialize in
// stable Id ORDER (the version already keeps each table's rows ascending by Id,
// §08 §2); a row's blackboard is a `map[string]Field_Value` whose Odin iteration
// order is unspecified, so this layer SORTS the field names before writing — the
// same sorted-key discipline the replay recorder applies to its action keys. Draw
// commands serialize in the flattened render order the §20 draw-list already
// carries (the render stage emits them in flattened-pipeline + stable-Id order).
// No map-iteration order and no pointer value ever reaches the bytes.
//
// INDEPENDENT OF THE REPLAY PATH: this digests whatever drove the tick loop — a
// live run or a re-fold of a recorded session — because it reads only the
// committed version (and optionally the projected draw-list), not the input
// source. Two runs that commit bit-identical versions therefore produce
// bit-identical digests regardless of how each was driven. Odin-first: the
// content hash is core:hash/xxhash (the same hasher the replay header pins) and
// the little-endian field packing is core:encoding/endian — no custom hasher,
// no custom byte order.
package funpack_runtime

import "core:encoding/endian"
import "core:hash/xxhash"
import "core:slice"

// FRAME_DIGEST_SCHEMA_VERSION stamps the canonical frame encoding. Any change to
// a tag byte, a field's encoding, or the serialization order changes the bytes
// and so bumps this — a digest is only comparable to one produced at the same
// version (the closed-enum / exact-match discipline §04). The session digest
// seeds from this stamp so two runs at different encodings never collide.
FRAME_DIGEST_SCHEMA_VERSION :: 1

// Field_Tag is the closed set of leading tag bytes that disambiguate a
// Field_Value arm in the canonical stream, so two distinct columns never encode
// to the same bytes (an Int 0 and a Fixed 0 differ by their tag). A new arm is a
// schema bump (§04). The ordinals are fixed — reordering would change the bytes.
Field_Tag :: enum u8 {
	Int     = 0, // an i64 Int column
	Fixed   = 1, // a Fixed (Q32.32 bits) column
	Variant = 2, // an enum variant token (a length-prefixed string)
	Vec2    = 3, // a two-Fixed vector column
	Ref     = 4, // a weak typed handle (target thing name + raw Id)
}

// Cmd_Tag is the closed set of leading tag bytes for a §20 draw command, so a
// Rect and a Text never alias in the stream. Fixed ordinals — a draw-command
// kind added to the §20 union is a schema bump here too (§04).
Cmd_Tag :: enum u8 {
	Rect = 0, // a Draw_Rect: at, size, color
	Text = 1, // a Draw_Text: at, length-prefixed text, color
}

// Frame_Digest is one committed tick's digest: the tick ordinal it was taken at
// and the xxh64 content hash over that tick's canonical byte stream. Two runs
// that commit bit-identical state/draw-lists at the same tick produce the same
// digest; a single differing Fixed bit changes it. The ordinal travels with the
// hash so a per-tick comparison names which tick diverged.
Frame_Digest :: struct {
	tick:   int, // the committed tick ordinal this digest covers
	digest: u64, // xxh64 over the tick's canonical byte stream
}

// Frame_Capture is the headless entrypoint's result over a driven session: the
// per-tick digests in tick order plus the single session digest folded over them.
// The acceptance harness compares two captures — equal per-tick digests prove
// every committed tick matched; an equal session digest is the one-value summary
// of the whole run. The slice lives in the supplied allocator.
Frame_Capture :: struct {
	per_tick: []Frame_Digest, // one digest per captured committed tick, in tick order
	session:  u64, // xxh64 fold over the per-tick digests — the whole-run summary
}

// --- The canonical byte stream (the byte-stability load-bearing encoding) ---

// frame_bytes serializes one committed tick into its CANONICAL byte stream: the
// world state (every table in declaration order, rows ascending by Id, fields in
// SORTED name order) followed by the §20 draw-list (commands in flattened render
// order). The caller passes whichever surfaces it wants in the digest — passing
// `nil` for the draw-list digests world state alone, passing a draw-list folds it
// in. The bytes are raw little-endian fixed-point throughout: no float, no
// decimal point, no map-iteration order, no pointer value. The returned slice
// lives in the supplied allocator.
frame_bytes :: proc(
	version: World_Version,
	draw: Maybe(Draw_List),
	allocator := context.allocator,
) -> []u8 {
	buf := make([dynamic]u8, allocator)
	write_world_state(&buf, version)
	if list, has_draw := draw.?; has_draw {
		write_draw_list(&buf, list)
	}
	return buf[:]
}

// frame_digest hashes one committed tick's canonical byte stream into its per-tick
// digest. It builds the SAME canonical bytes frame_bytes defines (world state then
// the optional §20 draw-list) and hashes them with xxh64 (core:hash/xxhash, the
// Odin-first hasher the replay header already pins), so the digest is a pure
// content hash — byte-identical bytes hash identically on every machine. The bytes
// are built and freed in the supplied allocator; only the digest escapes.
frame_digest :: proc(
	version: World_Version,
	draw: Maybe(Draw_List),
	allocator := context.allocator,
) -> Frame_Digest {
	buf := make([dynamic]u8, allocator)
	defer delete(buf)
	write_world_state(&buf, version)
	if list, has_draw := draw.?; has_draw {
		write_draw_list(&buf, list)
	}
	return Frame_Digest{tick = version.tick, digest = u64(xxhash.XXH64(buf[:]))}
}

// fold_session folds an ordered per-tick digest sequence into the single session
// digest. It seeds a running hash from the schema version (so two runs at
// different frame encodings never collide) then chains each per-tick digest in
// tick order — the session digest is therefore order-sensitive: the same digests
// in a different order produce a different session hash, exactly as a run whose
// ticks committed in a different order is a different run. xxh64 over the packed
// (tick, digest) pairs keeps the fold on the one Odin-first hasher.
fold_session :: proc(per_tick: []Frame_Digest, allocator := context.allocator) -> u64 {
	buf := make([dynamic]u8, allocator)
	defer delete(buf)
	put_u64_le(&buf, u64(FRAME_DIGEST_SCHEMA_VERSION))
	for frame in per_tick {
		put_u64_le(&buf, u64(frame.tick))
		put_u64_le(&buf, frame.digest)
	}
	return u64(xxhash.XXH64(buf[:]))
}

// --- World-state serialization (declaration order / Id order / sorted fields) ---

// write_world_state writes every committed table in the version's declaration
// order, each table's rows in their stable ascending-Id order (the version keeps
// rows sorted by Id, §08 §2). A table leads with its thing name and row count so
// two versions with a different table population never alias; the per-row writer
// handles the field ordering. The tick ordinal leads the whole world block so a
// digest of tick N never equals a digest of tick M with the same state.
@(private = "file")
write_world_state :: proc(buf: ^[dynamic]u8, version: World_Version) {
	put_u64_le(buf, u64(version.tick))
	put_u64_le(buf, u64(len(version.tables)))
	for table in version.tables {
		write_length_prefixed(buf, table.thing)
		put_u64_le(buf, u64(len(table.rows)))
		for row in table.rows {
			write_row(buf, row)
		}
	}
}

// write_row writes one thing instance: its raw stable Id, then its blackboard
// columns in SORTED field-name order. Odin leaves map iteration order
// unspecified, so a row writer that walked `row.fields` directly would emit
// different bytes on different runs of the same state; sorting the field names
// here is what makes the encoding depend on the row's CONTENT, not on how the
// blackboard map happened to be built (the same discipline the replay recorder
// applies to its action keys). The field count leads so a row that gained a
// column never aliases one that did not.
@(private = "file")
write_row :: proc(buf: ^[dynamic]u8, row: Row) {
	put_u64_le(buf, u64(row.id.raw))
	names := sorted_field_names(row.fields)
	defer delete(names)
	put_u64_le(buf, u64(len(names)))
	for name in names {
		write_length_prefixed(buf, name)
		write_field_value(buf, row.fields[name])
	}
}

// sorted_field_names returns a row blackboard's field names in ascending byte
// order — a DEFINED total order over the column names. Odin specifies no map
// iteration order, so this sort is the step that makes the per-row encoding
// machine-invariant. The dynamic array is allocated on the context allocator and
// freed by the caller; field names are short and few, so the sort is cheap.
@(private = "file")
sorted_field_names :: proc(fields: map[string]Field_Value) -> [dynamic]string {
	names := make([dynamic]string, 0, len(fields))
	for name in fields {
		append(&names, name)
	}
	slice.sort(names[:])
	return names
}

// write_field_value writes one blackboard column tagged by its arm so two arms
// never alias (an Int 0 and a Fixed 0 differ only by the leading tag). Every
// numeric arm is raw fixed-width little-endian bits — a Fixed/Int as its 8-byte
// i64 bits, a Vec2 as two such — never a float or a decimal point (§10). A Ref
// serializes as its target thing name plus the raw target Id (a flat id-graph,
// never a pointer value, §08 §1). The Field_Value union has no other arm, so the
// switch is total.
@(private = "file")
write_field_value :: proc(buf: ^[dynamic]u8, value: Field_Value) {
	switch v in value {
	case i64:
		append(buf, u8(Field_Tag.Int))
		put_u64_le(buf, u64(v))
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		put_u64_le(buf, u64(i64(v)))
	case string:
		append(buf, u8(Field_Tag.Variant))
		write_length_prefixed(buf, v)
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		write_vec2(buf, v)
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		write_length_prefixed(buf, v.thing)
		put_u64_le(buf, u64(v.id.raw))
	}
}

// --- Draw-list serialization (flattened render order) -----------------------

// write_draw_list writes the §20 draw commands in the order the draw-list already
// carries them — flattened-pipeline order across render behaviors, stable-Id
// order within each (render.odin emits them so). This layer preserves that order
// verbatim; it never sorts or reorders, because the emit order IS the canonical
// order (re-sorting would discard the render stage's deterministic sequencing).
// The command count leads so two draw-lists of different length never alias.
@(private = "file")
write_draw_list :: proc(buf: ^[dynamic]u8, draw: Draw_List) {
	put_u64_le(buf, u64(len(draw.cmds)))
	for cmd in draw.cmds {
		write_draw_cmd(buf, cmd)
	}
}

// write_draw_cmd writes one §20 draw command tagged by its kind. A Rect carries
// its at/size as fixed-point Vec2s and a color ordinal; a Text carries its at, a
// length-prefixed interpolated string, and a color ordinal. The color is the
// closed Draw_Color enum's ordinal — a single byte, not a float. The Draw_Cmd
// union has only these two arms, so the switch is total.
@(private = "file")
write_draw_cmd :: proc(buf: ^[dynamic]u8, cmd: Draw_Cmd) {
	switch c in cmd {
	case Draw_Rect:
		append(buf, u8(Cmd_Tag.Rect))
		write_vec2(buf, c.at)
		write_vec2(buf, c.size)
		append(buf, u8(c.color))
	case Draw_Text:
		append(buf, u8(Cmd_Tag.Text))
		write_vec2(buf, c.at)
		write_length_prefixed(buf, c.text)
		append(buf, u8(c.color))
	}
}

// --- Byte primitives (fixed-width little-endian, length-prefixed strings) ----

// write_vec2 writes a Vec2 as its two Fixed components' raw Q32.32 bits in
// little-endian order, x then y — 16 fixed-width bytes, no float, no decimal
// point. The component order is fixed so a vector never aliases its transpose.
@(private = "file")
write_vec2 :: proc(buf: ^[dynamic]u8, v: Vec2) {
	put_u64_le(buf, u64(i64(v.x)))
	put_u64_le(buf, u64(i64(v.y)))
}

// write_length_prefixed writes a string as its byte length (u64 little-endian)
// followed by the raw bytes — so a name containing any byte (a space, a NUL)
// never collides with the framing, and an empty string is distinguishable from
// an absent one. Length-prefixing rather than a delimiter keeps the encoding
// total: there is no byte a value cannot carry.
@(private = "file")
write_length_prefixed :: proc(buf: ^[dynamic]u8, s: string) {
	put_u64_le(buf, u64(len(s)))
	append(buf, ..transmute([]u8)s)
}

// put_u64_le appends a value's 8 raw bytes in little-endian order via
// core:encoding/endian (the Odin-first byte-order primitive — no hand-rolled
// shift loop). Every number in the canonical stream flows through here, so the
// fixed-width little-endian invariant lives in exactly one place. A signed value
// is cast to u64 by the caller (same endianness, same two's-complement bits), so
// the raw bit pattern is what gets written.
@(private = "file")
put_u64_le :: proc(buf: ^[dynamic]u8, v: u64) {
	scratch: [8]u8
	_ = endian.put_u64(scratch[:], .Little, v)
	append(buf, ..scratch[:])
}

// --- The headless capture entrypoint ----------------------------------------

// capture_frame is the single-tick capture the acceptance harness folds over a
// driven session: it digests one committed version (and its optional §20
// draw-list) into a Frame_Digest. A driver steps the tick loop and calls this per
// committed tick, accumulating the per-tick digests, then folds them with
// fold_session — the surface a live run and a re-fold both drive identically,
// since both produce committed versions this digests independently of how they
// were driven.
capture_frame :: proc(
	version: World_Version,
	draw: Maybe(Draw_List),
	allocator := context.allocator,
) -> Frame_Digest {
	return frame_digest(version, draw, allocator)
}

// finish_capture assembles a session's captured per-tick digests into a
// Frame_Capture: it takes ownership of the per-tick slice and folds the session
// digest over it. The caller drives the tick loop, appends a capture_frame result
// per committed tick into a [dynamic]Frame_Digest, then calls this once with the
// finished slice — the two-step shape (per-tick accumulate, then fold) the
// acceptance harness compares two runs through.
finish_capture :: proc(per_tick: []Frame_Digest, allocator := context.allocator) -> Frame_Capture {
	return Frame_Capture{per_tick = per_tick, session = fold_session(per_tick, allocator)}
}
