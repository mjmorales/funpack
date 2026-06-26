// The shared line-codec primitives for the runtime's text record formats
// (artifact-format §2 style): the replay record stream, the replay log, and the
// introspection session log all serialize as space-delimited records of
// length-prefixed fields, and all three read and write them through these exact
// procs. Holding the codec in one place is what makes "the session log's on-disk
// encoding mirrors the replay log's" a STRUCTURAL fact rather than a comment the two
// sites must be kept in sync by hand — a divergence is structurally impossible, not
// merely discouraged.
//
// The field grammar (spec §2.4/§2.5): a record line is space-delimited fields; a
// string field is `Lbyte_count:raw_bytes` (length-prefixed so a value may contain a
// space, a newline, or a `:` without confusing the scan); a bool is the bare token
// `true`/`false`; integers are decimal. Every reader fails CLOSED — a malformed or
// truncated field returns ok=false rather than a partial parse.
package funpack_runtime

import "core:strconv"
import "core:strings"

// write_string_field writes a length-prefixed string `Lbyte_count:raw_bytes` (§2.4):
// the byte count, a `:`, then the bytes verbatim. A reader consumes exactly that many
// bytes, so a value containing a space, a newline, or a `:` never confuses the parser
// — the load-bearing reason a whole NDJSON envelope can be stored as one field.
@(private)
write_string_field :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, 'L')
	strings.write_int(b, len(s))
	strings.write_byte(b, ':')
	strings.write_string(b, s)
}

// write_u64 writes an unsigned 64-bit value in decimal. ActionId and the content hash
// are unsigned, so they go through here rather than a signed writer (which would
// mis-render a high-bit-set value as negative).
@(private)
write_u64 :: proc(b: ^strings.Builder, v: u64) {
	buf: [20]byte
	strings.write_string(b, strconv.write_uint(buf[:], v, 10))
}

// next_line returns the line at the cursor and advances it, or ok=false past the end
// — the bound check every record parser relies on to fail closed on a truncated log.
@(private)
next_line :: proc(lines: []string, cursor: ^int) -> (line: string, ok: bool) {
	if cursor^ >= len(lines) {
		return "", false
	}
	line = lines[cursor^]
	cursor^ += 1
	return line, true
}

// parse_bool reads a `true`/`false` bare token (§2.5).
@(private)
parse_bool :: proc(tok: string) -> (v: bool, ok: bool) {
	switch tok {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	return false, false
}

// take_field splits the first space-delimited field off a record line, returning the
// field, the remainder past the space, and ok=false for an empty line. It is the scan
// step a record uses around its length-prefixed string fields.
@(private)
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

// take_string_field reads a length-prefixed `Lbyte_count:raw_bytes` field (§2.4) and
// returns the decoded bytes plus the remainder past the trailing space. Reading the
// byte count explicitly is what lets a value carry a space or a newline without the
// scan mistaking it for a field delimiter.
@(private)
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
