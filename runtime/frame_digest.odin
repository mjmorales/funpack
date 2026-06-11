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
// v2 adds the Bool / Record / List column tags the snake blackboard introduces
// (`grow: Bool`, `head: Cell`, `body: [Cell]`) — a composite column is part of the
// committed state the digest covers, so a new column arm is a digest-encoding
// change and bumps this stamp.
// v3 adds the Camera draw-command tag yard's `view` introduces (Cmd_Tag.Camera):
// the digest folds the §20 draw-list, so a new Draw_Cmd union arm is a digest
// encoding change and bumps this stamp deliberately (§04 closed-enum). pong / snake
// / hunt emit no Draw::Camera, so their CONTENT byte streams (per-tick AND session)
// are byte-unchanged — the new tag never appears in them, and the session fold is
// seeded from the fixed FRAME_SESSION_SEED rather than this version (see
// fold_session), so the committed pong/snake/hunt golden digests do NOT move under
// the v3 bump even though the stamp advances. The version is the comparability
// stamp; the goldens are unmoved because their bytes are identical.
// v4 folds variant PAYLOADS and String columns: a payload-carrying variant (a
// body's Shape2::Box{size}, a status's Option::Some("saved")) digests its boxed
// payload under Variant_Payload instead of its bare token, and a String column
// digests under the String tag instead of vanishing tag-less — closing the
// blindness where two worlds differing only in a payload or a String digested
// identically. Unit variants keep the token-only Variant encoding, so pong /
// snake / hunt streams (no payload variants, no Strings) are byte-unchanged;
// yard's golden digests move (its Body shapes carry payloads every tick) and
// regenerate under the FUNPACK_REGEN_GOLDEN gate. The session fold stays seeded
// from FRAME_SESSION_SEED (frozen, see the seed-decoupling rationale at
// fold_session).
// v5 extends the §20 Draw_Color closed palette from five named members to nine
// (+ Yellow/Cyan/Magenta/Gray, render.odin) — a closed-enum extension, so the
// comparability stamp bumps deliberately (§04). The new members are APPENDED, so
// the original five keep their ordinals (White=0..Blue=4); write_draw_cmd folds the
// color as that raw ordinal, so a golden whose draw-list paints only the original
// five emits byte-identical color bytes and its CONTENT digests (per-tick AND
// session, the latter seeded from the frozen FRAME_SESSION_SEED, not this version)
// are UNMOVED under the v5 bump. pong/snake/hunt paint only White; yard paints only
// White (camera-only secondary commands carry no color) — none emits a new member,
// so every committed golden digest is byte-unchanged. Only a draw-list that paints
// one of the four new members produces a different (correct) byte, and no current
// golden does.
// v6 adds the four §20 §1 3D draw-command tags krognid's [Draw3] render bodies
// introduce (Cmd_Tag.Draw3_Camera/Draw3_Light/Draw3_Plane/Draw3_Rigged): the digest
// folds the §20 draw-list, so a new Draw_Cmd union arm is a digest-encoding change
// and bumps this stamp deliberately (§04 closed-enum). The new ordinals are APPENDED
// after the 2D ordinals (Rect=0/Text=1/Camera=2 keep theirs; the 3D arms take 3..6),
// so an existing 2D draw-list emits the SAME tag bytes it always did and the new tags
// never appear in it. pong/snake/hunt emit Rect/Text only; yard adds the 2D Camera —
// NONE emits a Draw3 command, so their CONTENT byte streams (per-tick AND session,
// the session seeded from the frozen FRAME_SESSION_SEED, not this version) are
// byte-unchanged, and the committed pong/snake/hunt/yard golden digests do NOT move
// under the v6 bump even though the comparability stamp advances. Only a draw-list
// carrying a 3D command (krognid) produces the new (correct) bytes; the §16 §7 rig
// fold (the handle op-logs, the per-bone pose transforms, the Vec3 positions) is
// raw fixed-point throughout — no float (§10).
// v6 ALSO adds the Field_Tag.Vec3 COLUMN tag (ordinal 10, APPENDED after String=9):
// krognid's `pos: Vec3` is the first committed Vec3 blackboard COLUMN (move_krognid
// mutates it each tick), distinct from the v6 Cmd_Tag DRAW arms above (a draw-list
// command). A committed Vec3 column is part of the world state the digest folds, so
// the new column arm is part of the v6 encoding. It is byte-stable for every existing
// golden: pong/snake/hunt/yard carry no Vec3 field, so the tag never appears in their
// streams and their CONTENT digests (per-tick AND session, the latter seeded from the
// frozen FRAME_SESSION_SEED) are unmoved. Only krognid's stream carries the Vec3
// column bytes.
// v7 adds the §18 §3 BATCHED tile-layer tag (Cmd_Tag.Tilemap): render_version
// engine-emits one Draw_Tilemap per decoded [tilemaps] layer (never per-tile
// commands), and the digest folds the LAYER'S FULL CONTENT — name, cell size,
// dimensions, the grid→world anchor, the palette's (name, solid) pairs, and
// every row-major cell index — so the rendered terrain is inside the
// comparison surface bit-exactly (a single flipped cell changes the digest —
// the §18 §4 SetTile command moves exactly this surface, no further digest
// change: the application rewrites committed cells the fold already covers,
// so the v7 encoding carries dynamic tiles as-is). The ordinal is APPENDED
// (Tilemap=7 after Draw3_Rigged=6), and every committed golden artifact
// carries `[tilemaps 0]` — no golden draw-list emits the new tag, so all
// committed pong/snake/hunt/yard/krognid CONTENT digests (per-tick AND
// session, the session seeded from the frozen FRAME_SESSION_SEED, not this
// version) are byte-unchanged under the v7 bump. Only a tile-layer-carrying
// artifact produces the new (correct) bytes.
FRAME_DIGEST_SCHEMA_VERSION :: 7

// Field_Tag is the closed set of leading tag bytes that disambiguate a
// Field_Value arm in the canonical stream, so two distinct columns never encode
// to the same bytes (an Int 0 and a Fixed 0 differ by their tag). A new arm is a
// schema bump (§04) of whichever stamp's stream emits it. The ordinals are fixed
// — reordering would change the bytes.
Field_Tag :: enum u8 {
	Int     = 0, // an i64 Int column
	Fixed   = 1, // a Fixed (Q32.32 bits) column
	Variant = 2, // an enum variant token (a length-prefixed string)
	Vec2    = 3, // a two-Fixed vector column
	Ref     = 4, // a weak typed handle (target thing name + raw Id)
	Bool    = 5, // a Bool column (one tag byte + one 0/1 byte)
	Record  = 6, // a composite record column (type name + sorted-name fields)
	List    = 7, // a `[T]` list column (element count + each element in order)
	// Variant_Payload is a payload-carrying variant — token + the boxed payload
	// value — so a Restore swaps back the exact committed shape (a wall's
	// Shape2::Box{size}) and two worlds differing only in a payload digest
	// differently. A unit variant stays on the token-only Variant tag, keeping
	// payload-free streams byte-identical across the digest v4 / snapshot v3
	// encoding bumps.
	Variant_Payload = 8,
	// String is a String column's text (§03 primitive) — length-prefixed bytes,
	// digest v4 / snapshot v3.
	String = 9,
	// Vec3 is a three-Fixed vector column (krognid's `pos: Vec3`) — three raw
	// Q32.32 lanes, the 3D twin of the Vec2 tag. APPENDED at ordinal 10 so every
	// existing tag keeps its byte (Int=0..String=9), so a stream with no Vec3 column
	// (pong/snake/hunt/yard — none has a Vec3 field) is byte-unchanged. It rides the
	// existing digest v6 / snapshot v3 encodings: v6 already appended the Cmd_Tag 3D
	// DRAW arms for krognid's draw-list, and the Vec3 COLUMN arm is the committed-state
	// twin krognid's `pos` field first reaches — both land under the v6 stamp, and no
	// other golden carries the tag, so no committed golden moves (the append-ordinal
	// discipline, §04).
	Vec3 = 10,
}

// Cmd_Tag is the closed set of leading tag bytes for a §20 draw command, so a
// Rect, a Text, a Camera, and the four 3D commands never alias in the stream. Fixed
// ordinals — a draw-command kind added to the §20 union is a schema bump here too
// (§04). The ordinals are append-only: each new tag takes the next free ordinal so
// an existing byte stream is unchanged (pong/snake/hunt/yard emit none of the 3D
// commands, so their digests are unmoved under the v6 append).
Cmd_Tag :: enum u8 {
	Rect         = 0, // a Draw_Rect: at, size, color
	Text         = 1, // a Draw_Text: at, length-prefixed text, color
	Camera       = 2, // a Draw_Camera: at, zoom (Fixed), rotation (Fixed)
	Draw3_Camera = 3, // a Draw3_Camera: eye (Vec3), at (Vec3), fov (Fixed)
	Draw3_Light  = 4, // a Draw3_Light: dir (Vec3), color ordinal
	Draw3_Plane  = 5, // a Draw3_Plane: at (Vec3), size (Vec2), color ordinal
	Draw3_Rigged = 6, // a Draw3_Rigged: skeleton/parts handles, pose, at (Vec3)
	Tilemap      = 7, // a Draw_Tilemap: the full §18 §3 batched layer (name, geometry, anchor, palette, cells)
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

// FRAME_SESSION_SEED is the FIXED seed the session fold opens with. It is
// deliberately a STABLE constant, NOT FRAME_DIGEST_SCHEMA_VERSION: the
// cross-encoding distinction lives entirely in the per-tick stream (every
// Field_Tag / Cmd_Tag byte is folded into each per-tick digest), so two runs at
// different frame encodings already produce different per-tick digests and hence a
// different session fold — the session seed need not re-encode the version to keep
// that guarantee. Decoupling the seed from the version is what lets a closed-enum
// bump that adds a tag NO existing golden emits (the Camera arm: pong/snake/hunt
// emit no Draw::Camera) leave those content-identical goldens' session digests
// unmoved, while the schema version still bumps as the comparability stamp (§04).
// The value is pinned at 2 — the FRAME_DIGEST_SCHEMA_VERSION the committed
// pong/snake/hunt golden digests were folded under — so decoupling the seed leaves
// those goldens bit-identical to their committed fixtures (the "must not move"
// invariant the camera bump must hold).
FRAME_SESSION_SEED :: 2

// fold_session folds an ordered per-tick digest sequence into the single session
// digest. It seeds a running hash from FRAME_SESSION_SEED then chains each per-tick
// digest in tick order — the session digest is therefore order-sensitive: the same
// digests in a different order produce a different session hash, exactly as a run
// whose ticks committed in a different order is a different run. The encoding
// distinction is carried by the per-tick digests themselves (their tag bytes), so
// the seed stays a fixed constant. xxh64 over the packed (tick, digest) pairs keeps
// the fold on the one Odin-first hasher.
fold_session :: proc(per_tick: []Frame_Digest, allocator := context.allocator) -> u64 {
	buf := make([dynamic]u8, allocator)
	defer delete(buf)
	put_u64_le(&buf, u64(FRAME_SESSION_SEED))
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
// never a pointer value, §08 §1). A Bool is one 0/1 byte; a Record digests its
// type name then its fields in SORTED name order (the same map-invariance the row
// blackboard uses); a List digests its element count then each element in list
// order (order IS canonical for a list). The Field_Value union has no other arm,
// so the switch is total.
@(private = "file")
write_field_value :: proc(buf: ^[dynamic]u8, value: Field_Value) {
	switch v in value {
	case i64:
		append(buf, u8(Field_Tag.Int))
		put_u64_le(buf, u64(v))
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		put_u64_le(buf, u64(i64(v)))
	case bool:
		append(buf, u8(Field_Tag.Bool))
		append(buf, v ? u8(1) : u8(0))
	case string:
		append(buf, u8(Field_Tag.Variant))
		write_length_prefixed(buf, v)
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		write_vec2(buf, v)
	case Vec3:
		append(buf, u8(Field_Tag.Vec3))
		write_vec3(buf, v)
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		write_length_prefixed(buf, v.thing)
		put_u64_le(buf, u64(v.id.raw))
	case Record_Value:
		write_record_column(buf, v)
	case List_Value:
		write_list_column(buf, v)
	case Variant_Value:
		write_variant_column(buf, v)
	case String_Value:
		append(buf, u8(Field_Tag.String))
		write_length_prefixed(buf, v.text)
	}
}

// write_variant_column digests one variant: a unit variant as the token-only
// Variant tag (the encoding every payload-free stream has always carried), a
// payload-carrying variant as Variant_Payload + token + the boxed payload —
// so a payload difference changes the digest instead of hiding behind an
// identical token. Shared by the top-level column arm and the nested fold so
// the two encodings never diverge.
@(private = "file")
write_variant_column :: proc(buf: ^[dynamic]u8, v: Variant_Value) {
	if v.payload == nil {
		append(buf, u8(Field_Tag.Variant))
		write_length_prefixed(buf, variant_to_token(v))
		return
	}
	append(buf, u8(Field_Tag.Variant_Payload))
	write_length_prefixed(buf, variant_to_token(v))
	write_column_value(buf, v.payload^)
}

// write_record_column digests a composite record column (snake's `head: Cell`):
// the Record tag, the type name, the field count, then each field's name and
// value in SORTED name order — the same sorted-key discipline write_world_state
// applies to a row blackboard, so a Record column is machine-invariant regardless
// of Odin's unspecified map iteration order.
@(private = "file")
write_record_column :: proc(buf: ^[dynamic]u8, rec: Record_Value) {
	append(buf, u8(Field_Tag.Record))
	write_length_prefixed(buf, rec.type_name)
	put_u64_le(buf, u64(len(rec.fields)))
	names := sorted_value_field_names(rec.fields)
	defer delete(names)
	for name in names {
		write_length_prefixed(buf, name)
		write_column_value(buf, rec.fields[name])
	}
}

// write_list_column digests a `[T]` list column (snake's `body: [Cell]`): the
// List tag, the element count, then each element in LIST order — order is the
// list's canonical sequence (the deterministic fold order it was built in), so it
// is written verbatim, never sorted.
@(private = "file")
write_list_column :: proc(buf: ^[dynamic]u8, list: List_Value) {
	append(buf, u8(Field_Tag.List))
	put_u64_le(buf, u64(len(list.elements)))
	for elem in list.elements {
		write_column_value(buf, elem)
	}
}

// write_column_value digests one Value nested inside a structural column (a Cell
// in `body: [Cell]`, an x/y in a Cell). It tags by the SAME Field_Tag set the
// top-level columns use, so a Cell column and a Cell nested in a list digest
// identically. A nested variant digests through write_variant_column — token-only
// when unit, token + payload when payload-carrying — and a nested String digests
// its text, exactly as the top-level arms do, so the two encodings never diverge.
// A non-column transient (lambda / tuple / Rng) cannot appear in a committed
// structural column; it is written tag-less as a defensive no-op rather than
// aborting the digest.
@(private = "file")
write_column_value :: proc(buf: ^[dynamic]u8, v: Value) {
	switch x in v {
	case i64:
		append(buf, u8(Field_Tag.Int))
		put_u64_le(buf, u64(x))
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		put_u64_le(buf, u64(i64(x)))
	case bool:
		append(buf, u8(Field_Tag.Bool))
		append(buf, x ? u8(1) : u8(0))
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		write_vec2(buf, x)
	case Vec3:
		append(buf, u8(Field_Tag.Vec3))
		write_vec3(buf, x)
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		write_length_prefixed(buf, x.thing)
		put_u64_le(buf, u64(x.id.raw))
	case Variant_Value:
		write_variant_column(buf, x)
	case String_Value:
		append(buf, u8(Field_Tag.String))
		write_length_prefixed(buf, x.text)
	case Record_Value:
		write_record_column(buf, x)
	case List_Value:
		write_list_column(buf, x)
	case Lambda_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value:
	// A transient value never lands in a committed structural column — the §16 §7
	// anim VALUES (Transform/Pose/handle) compose inside a render body into a [Draw3]
	// draw-list, never a blackboard column the digest folds here. A Vec3 is NOT here:
	// a committed Vec3 column (krognid's `pos`, or a Vec3 nested in a record column)
	// digests through the Vec3 arm above, the same as a Vec2.
	}
}

// sorted_value_field_names returns a Record_Value's field names in ascending byte
// order — the same defined total order sorted_field_names gives a row blackboard,
// applied to the `map[string]Value` a structural column carries so a nested record
// is digested map-invariantly. The dynamic array is freed by the caller.
@(private = "file")
sorted_value_field_names :: proc(fields: map[string]Value) -> [dynamic]string {
	names := make([dynamic]string, 0, len(fields))
	for name in fields {
		append(&names, name)
	}
	slice.sort(names[:])
	return names
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
// length-prefixed interpolated string, and a color ordinal; a Camera carries its
// at, zoom, and rotation as raw fixed-point bits (the §3 world↔screen transform —
// no color, it is not a painted primitive). The four §20 §1 3D commands carry their
// full fixed-point state: a Draw3_Camera its eye/at Vec3s + fov; a Draw3_Light its
// dir Vec3 + color ordinal; a Draw3_Plane its at Vec3 + size Vec2 + color ordinal; a
// Draw3_Rigged its two opaque handles' op-logs + the per-bone pose transforms + the
// world position. Every number is raw Q32.32 little-endian bits, never a float (§10).
// The 3D arms fold the COMPLETE 3D state (the determinism bet is on the lowering, not
// the present), so two folds of the same committed rig digest identically and any
// single Fixed bit divergence changes the digest. The Draw_Cmd union has exactly
// these seven arms, so the switch is total.
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
	case Draw_Camera:
		append(buf, u8(Cmd_Tag.Camera))
		write_vec2(buf, c.at)
		put_u64_le(buf, u64(i64(c.zoom)))
		put_u64_le(buf, u64(i64(c.rotation)))
	case Draw3_Camera:
		append(buf, u8(Cmd_Tag.Draw3_Camera))
		write_vec3(buf, c.eye)
		write_vec3(buf, c.at)
		put_u64_le(buf, u64(i64(c.fov)))
	case Draw3_Light:
		append(buf, u8(Cmd_Tag.Draw3_Light))
		write_vec3(buf, c.dir)
		append(buf, u8(c.color))
	case Draw3_Plane:
		append(buf, u8(Cmd_Tag.Draw3_Plane))
		write_vec3(buf, c.at)
		write_vec2(buf, c.size)
		append(buf, u8(c.color))
	case Draw3_Rigged:
		append(buf, u8(Cmd_Tag.Draw3_Rigged))
		write_handle(buf, c.skeleton)
		write_handle(buf, c.parts)
		write_pose(buf, c.pose)
		write_vec3(buf, c.at)
	case Draw_Tilemap:
		// The batched §18 §3 layer folds COMPLETE: name, cell size, dims, the
		// grid→world anchor, the legend-order palette (each name + solid
		// byte), and every row-major cell index — counts lead each run so two
		// layers never alias across a boundary. A cell index is its i64 value
		// (TILE_CELL_EMPTY folds as the all-ones byte run), so one flipped
		// tile changes the digest — the exact surface a committed §18 §4
		// SetTile moves (the §28 determinism warranty over dynamic terrain).
		append(buf, u8(Cmd_Tag.Tilemap))
		write_length_prefixed(buf, c.layer.name)
		put_u64_le(buf, u64(c.layer.cell_size))
		put_u64_le(buf, u64(i64(c.layer.cols)))
		put_u64_le(buf, u64(i64(c.layer.rows)))
		write_vec2(buf, c.layer.top_left)
		put_u64_le(buf, u64(len(c.layer.palette)))
		for tile in c.layer.palette {
			write_length_prefixed(buf, tile.name)
			append(buf, u8(1) if tile.solid else u8(0))
		}
		put_u64_le(buf, u64(len(c.layer.cells)))
		for cell in c.layer.cells {
			put_u64_le(buf, u64(i64(cell)))
		}
	}
}

// write_vec3 writes a Vec3 as its three Fixed components' raw Q32.32 bits in
// little-endian order, x then y then z — 24 fixed-width bytes, no float, no decimal
// point. The component order is fixed (the same x,y,z order the lowering reads), so
// a vector never aliases a permutation of itself.
@(private = "file")
write_vec3 :: proc(buf: ^[dynamic]u8, v: Vec3) {
	put_u64_le(buf, u64(i64(v.x)))
	put_u64_le(buf, u64(i64(v.y)))
	put_u64_le(buf, u64(i64(v.z)))
}

// write_quat writes a Quat as its four Fixed components' raw Q32.32 bits in
// little-endian order, x,y,z,w — a §16 §7 bone orientation, fully fixed-point.
@(private = "file")
write_quat :: proc(buf: ^[dynamic]u8, q: Quat) {
	put_u64_le(buf, u64(i64(q.x)))
	put_u64_le(buf, u64(i64(q.y)))
	put_u64_le(buf, u64(i64(q.z)))
	put_u64_le(buf, u64(i64(q.w)))
}

// write_transform writes one §16 §7 bone transform: its pos Vec3, its rot Quat, its
// scale Vec3 — the full local transform a pose drives a bone with, all raw
// fixed-point bits. A single differing Q32.32 bit (a leg-swing angle off by one)
// changes the digest, so the rig pose is inside the comparison surface bit-exactly.
@(private = "file")
write_transform :: proc(buf: ^[dynamic]u8, t: Transform_Value) {
	write_vec3(buf, t.pos)
	write_quat(buf, t.rot)
	write_vec3(buf, t.scale)
}

// write_pose writes a §16 §7 sparse pose: the driven-bone count, then each driven
// bone's name (length-prefixed) and transform in the pose's INSERT order — the order
// IS canonical for a pose (the deterministic fold order set/blend/layer built it in,
// pose.odin), so it is written verbatim, never sorted. Two poses built the same way
// digest identically; a different driven set, a reordered insertion, or one differing
// transform bit changes the digest.
@(private = "file")
write_pose :: proc(buf: ^[dynamic]u8, pose: Pose_Value) {
	put_u64_le(buf, u64(len(pose.bones)))
	for driven in pose.bones {
		write_length_prefixed(buf, driven.bone)
		write_transform(buf, driven.transform)
	}
}

// write_handle writes an opaque §16 §7 anim handle (a Skeleton or PartSet): its kind
// and factory (length-prefixed), then its ordered builder op-log — each op's method
// and its serialized args in order. The op-log order IS canonical (the builder chain
// applied bind/mirror in that order, pose.odin), so it is written verbatim. Two
// handles built through the same constructor + builder chain digest identically (the
// §03 Eq handles_equal folds through); a different op, arg, or order changes the
// digest. No rig geometry is modeled — the handle is opaque, its identity is its
// build recipe.
@(private = "file")
write_handle :: proc(buf: ^[dynamic]u8, handle: Handle_Value) {
	write_length_prefixed(buf, handle.kind)
	write_length_prefixed(buf, handle.factory)
	put_u64_le(buf, u64(len(handle.ops)))
	for op in handle.ops {
		write_length_prefixed(buf, op.method)
		put_u64_le(buf, u64(len(op.args)))
		for arg in op.args {
			write_length_prefixed(buf, arg)
		}
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
