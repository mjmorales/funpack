// The artifact-format primitive encoders and the golden-fixture seam.
// This is the funpack side of the spec-§29 process-boundary data contract
// with the runtime: a versioned byte format whose layout is written in
// docs/artifact-format.md and whose pong instance is committed at
// testdata/pong.artifact. The runtime (Odin, runtime/**) parses those
// bytes from the doc alone with ZERO funpack imports; this file owns only
// the funpack-side encoders the (later) production emitter reuses, so the
// encoding rules are executable and the byte-identical-twice obligation is
// provable here under `odin test`.
//
// The format is deterministic by construction (spec §09, §29): no clock,
// no machine paths, no float. Every Fixed is its raw Q32.32 i64 bits in
// decimal — the same kernel representation as fixed.odin — so emission and
// load are exact and identical on every machine.
package funpack

import "core:strconv"
import "core:strings"

// ARTIFACT_SCHEMA_VERSION is the leading stamp every artifact carries
// (docs/artifact-format.md §1). Any field/layout/encoding change bumps it;
// a runtime exact-matches it and refuses a mismatch rather than
// best-effort parsing. It is the single compatibility gate.
ARTIFACT_SCHEMA_VERSION :: 1

// ARTIFACT_MAGIC is the first token of line 1, before the version integer:
// `funpack-artifact 1`. A parser asserts the magic and the version before
// reading any payload.
ARTIFACT_MAGIC :: "funpack-artifact"

// encode_int writes a funpack Int (64-bit signed saturating, §10) as plain
// decimal: a leading `-` for negatives, no leading zeros, no `+`, no
// separators (docs/artifact-format.md §2.2). The encoding is a pure
// function of the value, so it is byte-identical across emissions.
encode_int :: proc(value: i64, allocator := context.allocator) -> string {
	buf: [32]byte
	return strings.clone(strconv.write_int(buf[:], value, 10), allocator)
}

// encode_fixed writes a Fixed as its raw Q32.32 i64 bits in decimal
// (docs/artifact-format.md §2.3) — value*2^32, the exact integer the
// fixed-point lowering produced. There is no decimal-point round-trip, so
// the bits are bit-identical on every machine; the runtime divides by 2^32
// in its own fixed representation to recover the logical value.
encode_fixed :: proc(value: Fixed, allocator := context.allocator) -> string {
	return encode_int(i64(value), allocator)
}

// encode_string writes a length-prefixed string field `Lbyte_count:raw`
// (docs/artifact-format.md §2.4). The byte count is the UTF-8 length; the
// raw bytes follow the colon verbatim, so a value containing a space or
// newline never breaks the line-oriented frame and a parser consumes
// exactly byte_count bytes without scanning for a delimiter.
encode_string :: proc(value: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, 'L')
	strings.write_int(&b, len(value))
	strings.write_byte(&b, ':')
	strings.write_string(&b, value)
	return strings.to_string(b)
}

// encode_bool writes the lowercase token `true`/`false`
// (docs/artifact-format.md §2.5).
encode_bool :: proc(value: bool) -> string {
	return "true" if value else "false"
}

// SUB_RECORD_KEYWORDS is the closed set of keywords that begin a
// SUB-record — a line that belongs to the preceding top-level record rather
// than starting a new one (docs/artifact-format.md §2.1). A top-level
// record (`enum`, `thing`, `behavior`, …) may be followed by a
// variable-length run of these; the section's declared count is the number
// of top-level records, so a reader separates the two by this set. Closed
// and format-fixed: a new sub-record kind is a schema-version bump.
@(rodata)
SUB_RECORD_KEYWORDS := []string{
	"variant", // an enum's variant (§5)
	"field", // a data/signal/thing field (§6-§8)
	"gtag", // a thing's/behavior's registered tag (§8, §10)
	"param", // a function's/behavior-step's parameter (§9, §10)
	"emit", // a behavior-step's return-side emission (§10)
	"value", // a const's evaluated field (§9)
	"producer", // a signal route's producer (§12)
	"consumer", // a signal route's consumer (§12)
	"set", // a setup spawn's supplied field (§13)
}

// Artifact_Section is one parsed `[name N]` block from an artifact: the
// section name, its declared TOP-LEVEL record count, and every body line up
// to the next section header. A section's records are variable-length — a
// top-level record (e.g. `enum Side - 2`) is followed by its own count of
// sub-records (its `variant` lines) — so the body holds both; `count` is the
// top-level total, and section_lead_count separates lead lines from sub
// lines via SUB_RECORD_KEYWORDS (docs/artifact-format.md §2.1).
Artifact_Section :: struct {
	name:  string,
	count: int,
	body:  []string,
}

// Artifact_Doc is a parsed artifact: the schema version from line 1 and the
// ordered sections (docs/artifact-format.md §3). It is the funpack-side
// reader used to verify the committed golden fixture is well-formed against
// the written layout; the runtime carries its own zero-import parser.
Artifact_Doc :: struct {
	schema_version: int,
	sections:       []Artifact_Section,
}

Artifact_Parse_Error :: enum {
	None,
	Bad_Magic,
	Bad_Version,
	Bad_Section_Header,
	Count_Mismatch, // a section's declared count != its top-level record count
}

// parse_artifact reads an artifact's bytes into the ordered section model,
// validating the §1 stamp and every section's declared top-level count
// against the lead records that follow. It mirrors the runtime's §16
// parsing recipe (read line 1, then each `[name N]` header and its records)
// so the golden fixture is checked against the same count-driven discipline
// the runtime relies on. A section body runs to the next `[` header — the
// only line class that opens with `[` — so variable-length records inside a
// section are unambiguous. It is pure over the input bytes.
parse_artifact :: proc(content: string) -> (doc: Artifact_Doc, err: Artifact_Parse_Error) {
	lines := split_artifact_lines(content)
	if len(lines) == 0 {
		return Artifact_Doc{}, .Bad_Magic
	}
	magic, version, header_ok := parse_version_stamp(lines[0])
	if !header_ok || magic != ARTIFACT_MAGIC {
		return Artifact_Doc{}, .Bad_Magic
	}
	if version < 0 {
		return Artifact_Doc{}, .Bad_Version
	}
	sections := make([dynamic]Artifact_Section, 0, 12, context.temp_allocator)
	i := 1
	for i < len(lines) {
		name, count, ok := parse_section_header(lines[i])
		if !ok {
			return Artifact_Doc{}, .Bad_Section_Header
		}
		i += 1
		body_start := i
		for i < len(lines) && !is_section_header_line(lines[i]) {
			i += 1
		}
		section := Artifact_Section{name = name, count = count, body = lines[body_start:i]}
		if section_lead_count(section) != count {
			return Artifact_Doc{}, .Count_Mismatch
		}
		append(&sections, section)
	}
	return Artifact_Doc{schema_version = version, sections = sections[:]}, .None
}

// is_section_header_line reports whether a line opens a `[name N]` section
// header. Only headers begin with `[`, so this is the section delimiter.
is_section_header_line :: proc(line: string) -> bool {
	return len(line) > 0 && line[0] == '['
}

// section_lead_count counts a section's top-level records: body lines whose
// leading keyword is NOT in SUB_RECORD_KEYWORDS. A top-level record opens a
// new entry (an `enum`, `thing`, `behavior`, …); a sub-record continues the
// previous one (its `variant`/`field`/`param`/… lines). This is how the
// declared count and the body reconcile for variable-length records.
section_lead_count :: proc(section: Artifact_Section) -> int {
	lead := 0
	for line in section.body {
		if !is_sub_record_line(line) {
			lead += 1
		}
	}
	return lead
}

// is_sub_record_line reports whether a body line's leading keyword is a
// sub-record kind (SUB_RECORD_KEYWORDS). The keyword is the token up to the
// first space (or the whole line when there is none).
is_sub_record_line :: proc(line: string) -> bool {
	keyword := line
	if space := strings.index_byte(line, ' '); space >= 0 {
		keyword = line[:space]
	}
	for sub in SUB_RECORD_KEYWORDS {
		if keyword == sub {
			return true
		}
	}
	return false
}

// split_artifact_lines splits on the single LF the format mandates and
// drops the trailing empty element from the final terminator, so a file
// ending in exactly one `\n` yields one element per record line (no phantom
// empty line). It does not strip interior content — a length-prefixed
// string's bytes are inside a single line by construction.
split_artifact_lines :: proc(content: string) -> []string {
	trimmed := strings.trim_suffix(content, "\n")
	if trimmed == "" {
		return nil
	}
	return strings.split(trimmed, "\n", context.temp_allocator)
}

// parse_version_stamp splits line 1 into its magic token and integer
// version: `funpack-artifact 1`. ok is false on a missing space or a
// non-integer version, which the caller maps to Bad_Magic/Bad_Version.
parse_version_stamp :: proc(line: string) -> (magic: string, version: int, ok: bool) {
	space := strings.index_byte(line, ' ')
	if space < 0 {
		return "", -1, false
	}
	version, ok = strconv.parse_int(line[space + 1:])
	return line[:space], version, ok
}

// parse_section_header parses `[name N]` into the section name and its
// record count. ok is false on a malformed bracket or a non-integer count.
parse_section_header :: proc(line: string) -> (name: string, count: int, ok: bool) {
	if len(line) < 3 || line[0] != '[' || line[len(line) - 1] != ']' {
		return "", 0, false
	}
	inner := line[1:len(line) - 1]
	space := strings.index_byte(inner, ' ')
	if space < 0 {
		return "", 0, false
	}
	count, ok = strconv.parse_int(inner[space + 1:])
	return inner[:space], count, ok
}

// artifact_find_section returns the first section with the given name, or
// found = false. The format fixes section order (docs/artifact-format.md
// §3), so a lookup by name is a convenience for verification, not the
// runtime's path — the runtime reads sections positionally.
artifact_find_section :: proc(doc: Artifact_Doc, name: string) -> (section: Artifact_Section, found: bool) {
	for candidate in doc.sections {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Artifact_Section{}, false
}
