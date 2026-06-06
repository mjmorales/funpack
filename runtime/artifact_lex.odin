// Artifact lexical layer — the line frame, the primitive decoders, and the
// single lead-line section reader (docs/artifact-format.md §2, §16). This is
// the runtime's OWN zero-import parser: nothing in funpack/** is on the
// include path, so the recipe here is derived from the format doc alone, not
// linked from the compiler's emitter. The artifact file is the only coupling
// between the two products (spec §29, §09).
//
// Decoding discipline (§16 step 3): every field is decoded by its POSITION in
// the record's documented signature — a Fixed is lexically identical to an Int,
// so the caller, not the lexer, knows which a token is. The lexer hands back
// the raw token shaping; the loader (artifact_load.odin) reads positionally.
package funpack_runtime

import "core:strconv"
import "core:strings"

// ARTIFACT_SCHEMA_VERSION is the exact version this runtime is built for.
// The version gate is exact-match, no best-effort: a mismatch is refused with
// a diagnostic, never parsed leniently (§1, §29 §2).
//
// v2 ratifies two §2.7 arm-pattern tokens within the Arm node kind that the
// snake/hunt goldens introduce: `bare_binder` (a tuple position binding the whole
// element) and `tuple` (a positional tuple pattern). The `tuple` arm pattern is
// the one that carries children — its positional sub-pattern arms — so its line
// ends in a trailing `child_count`, unlike every other arm pattern whose count is
// fixed at 0 by token. A new arm-pattern token and an arm-with-children are both
// layout changes, so the version bumped 1 → 2 (funpack/docs/artifact-format.md
// §1, §2.7).
//
// v3 ratifies the closed §14 binding SOURCE-form set the emitter lowers the
// §23 §3 builder helpers into: key-list button sources arrive spread as one
// `key(…)` bind per key, `wasd()` arrives lowered to the 2D
// `keys_quad(neg_x,pos_x,neg_y,pos_y)` form, and `stick(Stick)` is a
// first-class 2D source (both components fold into the action's Vec2). The
// source vocabulary is a closed taxonomy, so growing it bumped 2 → 3
// (funpack/docs/artifact-format.md §1, §14).
//
// v4 adds the required `logical:WxH` field to the §15 entrypoint record — the
// fixed logical draw space (§20 §3) in integer world units the present pass
// letterboxes to. A required field on an existing record is a layout change:
// 3 → 4 (funpack/docs/artifact-format.md §1, §15).
//
// v5 is the yard cross-epic format the §11 physics / §20 camera / §24 persistence
// surfaces first reach. Four layout changes ride it: the §06 §2 SINGLETON tick-0
// spawn marker (a `singleton`'s [things] row carries SINGLETON true plus its
// complete defaulted field schema, so this runtime spawns the singleton population
// from the artifact alone); the §11 §3 PHYSICS-STAGE step (`stage:physics
// behavior:solve` in [pipeline_flattened], a battery step the tick fold dispatches
// to the native solver, not a behavior lookup); the §03 §4 CollisionLayer enum
// KIND tag; and the §6 ENGINE-TYPE field defaults (Option[String] = Option::None,
// and a Settings composite default `Settings(volume=128,fullscreen=false)` decoded
// against the §8 Settings data projection). A marker row, a new flattened-step
// occupant kind, an enum KIND value, and widened §6/§8 default forms are layout
// changes: 4 → 5 (funpack/docs/artifact-format.md §1, §6, §8, §11).
ARTIFACT_SCHEMA_VERSION :: 5

// ARTIFACT_STAMP is the literal keyword on line 1 before the version integer.
ARTIFACT_STAMP :: "funpack-artifact"

// SUB_RECORD_KEYWORDS is the closed set of sub-record line keywords (§2.1).
// A lead line is any line whose leading keyword is NOT in this set; a section's
// record count N is always the lead-line count, never a sum of sub-counts. This
// is the SINGLE parse discipline for top-level record boundaries (§2.1, §16).
SUB_RECORD_KEYWORDS :: [?]string {
	"variant",
	"field",
	"gtag",
	"param",
	"emit",
	"producer",
	"consumer",
	"set",
	"node",
}

// Artifact_Error is the closed parse-failure enum. Every failure is a refusal
// with provenance, never a best-effort partial parse (§1).
Artifact_Error :: enum {
	None,
	Empty_Input,
	Bad_Stamp,
	Version_Mismatch,
	Missing_Section_Header,
	Section_Count_Mismatch,
	Malformed_Header,
	Bad_Body_Node,
	Body_Count_Mismatch,
	Bad_Field,
}

// Artifact_Section is one `[name N]` header plus its N top-level records, each
// already split into its lead line and the sub-record lines that follow it up
// to the next lead line (§2.1). Sub-records stay as raw lines — the loader
// shapes them by the lead line's declared scalar counts (§16 step 3).
Artifact_Record :: struct {
	lead: string, // the lead line (KIND field…)
	subs: []string, // the sub-record lines belonging to this record
}

Artifact_Section :: struct {
	name:    string,
	count:   int, // the declared N (== len(records), asserted)
	records: []Artifact_Record,
}

// Artifact_Doc is the section-level view of an artifact: the version stamp and
// the sections in their fixed §3 order. The loader walks this to build the
// in-memory Program (artifact_load.odin).
Artifact_Doc :: struct {
	schema_version: int,
	sections:       []Artifact_Section,
}

// is_sub_record_keyword reports whether `keyword` opens a sub-record line — the
// negation is the lead-line test (§2.1).
is_sub_record_keyword :: proc(keyword: string) -> bool {
	for kw in SUB_RECORD_KEYWORDS {
		if keyword == kw {
			return true
		}
	}
	return false
}

// line_keyword returns the leading space-delimited token of a line (its KIND
// tag), or "" for an empty line. It never allocates.
line_keyword :: proc(line: string) -> string {
	space := strings.index_byte(line, ' ')
	if space < 0 {
		return line
	}
	return line[:space]
}

// is_lead_line reports whether a body line opens a top-level record: its
// keyword is not a sub-record keyword and it is not a `[` section header (§2.1).
is_lead_line :: proc(line: string) -> bool {
	if len(line) == 0 || line[0] == '[' {
		return false
	}
	return !is_sub_record_keyword(line_keyword(line))
}

// split_artifact_lines splits the artifact into LF-delimited lines, dropping the
// single trailing empty produced by the mandatory final `\n` (§2.1). The format
// is LF-only by contract, so there is no `\r` to strip.
split_artifact_lines :: proc(content: string, allocator := context.allocator) -> []string {
	lines := strings.split(content, "\n", allocator)
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		return lines[:len(lines) - 1]
	}
	return lines
}

// parse_artifact reads the version stamp and every section in the §3 fixed
// order using the single lead-line discipline (§16). It refuses on any shape
// mismatch — a wrong stamp, a wrong version, a header that is not `[name N]`,
// or a declared N that disagrees with the lead-line count.
parse_artifact :: proc(
	content: string,
	allocator := context.allocator,
) -> (
	doc: Artifact_Doc,
	err: Artifact_Error,
) {
	lines := split_artifact_lines(content, allocator)
	if len(lines) == 0 {
		return {}, .Empty_Input
	}

	version, stamp_err := parse_version_stamp(lines[0])
	if stamp_err != .None {
		return {}, stamp_err
	}
	if version != ARTIFACT_SCHEMA_VERSION {
		return {}, .Version_Mismatch
	}

	sections := make([dynamic]Artifact_Section, 0, 12, allocator)
	i := 1 // line 0 was the stamp
	for i < len(lines) {
		section, next, sec_err := parse_section(lines, i, allocator)
		if sec_err != .None {
			return {}, sec_err
		}
		append(&sections, section)
		i = next
	}

	return Artifact_Doc{schema_version = version, sections = sections[:]}, .None
}

// parse_version_stamp asserts line 1 is `funpack-artifact <int>` and returns the
// declared version (§1). The stamp is line 1 so a parser rejects a wrong version
// before reading any payload.
parse_version_stamp :: proc(line: string) -> (version: int, err: Artifact_Error) {
	space := strings.index_byte(line, ' ')
	if space < 0 {
		return 0, .Bad_Stamp
	}
	if line[:space] != ARTIFACT_STAMP {
		return 0, .Bad_Stamp
	}
	v, ok := strconv.parse_int(line[space + 1:])
	if !ok {
		return 0, .Bad_Stamp
	}
	return v, .None
}

// parse_section reads one `[name N]` header at `lines[start]` plus its N
// records, splitting the body up to the next `[` header by the lead-line
// discipline and asserting the lead-line count equals N (§2.1, §16). Returns the
// section and the index of the next header line.
parse_section :: proc(
	lines: []string,
	start: int,
	allocator := context.allocator,
) -> (
	section: Artifact_Section,
	next: int,
	err: Artifact_Error,
) {
	header := lines[start]
	name, count, header_err := parse_section_header(header)
	if header_err != .None {
		return {}, start, header_err
	}

	// The section body runs from the line after the header up to the next `[`
	// header (the only line class that opens with `[`) — never seeking past it.
	body_start := start + 1
	body_end := body_start
	for body_end < len(lines) && (len(lines[body_end]) == 0 || lines[body_end][0] != '[') {
		body_end += 1
	}

	records, rec_err := split_records(lines[body_start:body_end], allocator)
	if rec_err != .None {
		return {}, body_end, rec_err
	}
	// A declared N that disagrees with the lead-line count is an under- or
	// over-shaped section — an exact-match refusal (§2.1, §29-style).
	if len(records) != count {
		return {}, body_end, .Section_Count_Mismatch
	}

	return Artifact_Section{name = name, count = count, records = records}, body_end, .None
}

// parse_section_header decodes a `[name N]` header into its name and declared
// count. Anything not of that exact shape is a refusal (§3).
parse_section_header :: proc(line: string) -> (name: string, count: int, err: Artifact_Error) {
	if len(line) < 2 || line[0] != '[' || line[len(line) - 1] != ']' {
		return "", 0, .Missing_Section_Header
	}
	inner := line[1:len(line) - 1] // strip the brackets
	space := strings.index_byte(inner, ' ')
	if space < 0 {
		return "", 0, .Malformed_Header
	}
	n, ok := strconv.parse_int(inner[space + 1:])
	if !ok {
		return "", 0, .Malformed_Header
	}
	return inner[:space], n, .None
}

// split_records groups a section body into top-level records by the lead-line
// discipline: a record spans its lead line up to the next lead line (§2.1). The
// first line of a non-empty body must be a lead line.
split_records :: proc(
	body: []string,
	allocator := context.allocator,
) -> (
	records: []Artifact_Record,
	err: Artifact_Error,
) {
	out := make([dynamic]Artifact_Record, 0, len(body), allocator)
	i := 0
	for i < len(body) {
		if !is_lead_line(body[i]) {
			// A body that does not open on a lead line is malformed — a stray
			// sub-record with no owning record.
			return nil, .Bad_Field
		}
		lead := body[i]
		sub_start := i + 1
		j := sub_start
		for j < len(body) && !is_lead_line(body[j]) {
			j += 1
		}
		append(&out, Artifact_Record{lead = lead, subs = body[sub_start:j]})
		i = j
	}
	return out[:], .None
}

// --- Primitive field decoders (§2.2–§2.6) --------------------------------
// Each decodes one token by the kind the caller already knows from the
// record's documented field position (§16 step 3).

// decode_int reads a decimal Int field (§2.2): signed, no leading zeros, no `+`.
decode_int :: proc(token: string) -> (value: i64, ok: bool) {
	return strconv.parse_i64(token)
}

// decode_fixed reads a Fixed field as its raw Q32.32 i64 bits in decimal (§2.3)
// and lifts the bits straight into the runtime kernel's Fixed — bit-exact, no
// decimal point, NO FLOAT in the load path. The raw integer IS the value
// (`literal * 2^32`, truncated), so this is the only sound decode: any float
// round-trip would break the determinism thesis (spec §10.5).
decode_fixed :: proc(token: string) -> (value: Fixed, ok: bool) {
	bits, parsed := strconv.parse_i64(token)
	if !parsed {
		return Fixed(0), false
	}
	return Fixed(bits), true
}

// decode_string reads a length-prefixed `Lk:bytes` String field (§2.4): the
// byte count, then exactly that many raw bytes — never a delimiter scan. The
// empty string is `L0:`.
decode_string :: proc(token: string) -> (value: string, ok: bool) {
	if len(token) < 2 || token[0] != 'L' {
		return "", false
	}
	colon := strings.index_byte(token, ':')
	if colon < 0 {
		return "", false
	}
	n, parsed := strconv.parse_int(token[1:colon])
	if !parsed {
		return "", false
	}
	body := token[colon + 1:]
	if len(body) != n {
		return "", false
	}
	return body, true
}

// decode_bool reads a bare lowercase `true`/`false` Bool field (§2.5).
decode_bool :: proc(token: string) -> (value: bool, ok: bool) {
	switch token {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	return false, false
}
