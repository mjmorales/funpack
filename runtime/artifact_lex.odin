package funpack_runtime

import "core:strconv"
import "core:strings"

ARTIFACT_SCHEMA_VERSION :: 19

ARTIFACT_STAMP :: "funpack-artifact"

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
	"migrate",
	"index",
	"tile",
	"row",
	"navnode",
	"navedge",
	"region",
}

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

Artifact_Record :: struct {
	lead: string,
	subs: []string,
}

Artifact_Section :: struct {
	name:    string,
	count:   int,
	records: []Artifact_Record,
}

Artifact_Doc :: struct {
	schema_version: int,
	sections:       []Artifact_Section,
}

is_sub_record_keyword :: proc(keyword: string) -> bool {
	for kw in SUB_RECORD_KEYWORDS {
		if keyword == kw {
			return true
		}
	}
	return false
}

line_keyword :: proc(line: string) -> string {
	space := strings.index_byte(line, ' ')
	if space < 0 {
		return line
	}
	return line[:space]
}

is_lead_line :: proc(line: string) -> bool {
	if len(line) == 0 || line[0] == '[' {
		return false
	}
	return !is_sub_record_keyword(line_keyword(line))
}

split_artifact_lines :: proc(content: string, allocator := context.allocator) -> []string {
	lines := strings.split(content, "\n", allocator)
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		return lines[:len(lines) - 1]
	}
	return lines
}

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
	i := 1
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

	body_start := start + 1
	body_end := body_start
	for body_end < len(lines) && (len(lines[body_end]) == 0 || lines[body_end][0] != '[') {
		body_end += 1
	}

	records, rec_err := split_records(lines[body_start:body_end], allocator)
	if rec_err != .None {
		return {}, body_end, rec_err
	}
	if len(records) != count {
		return {}, body_end, .Section_Count_Mismatch
	}

	return Artifact_Section{name = name, count = count, records = records}, body_end, .None
}

parse_section_header :: proc(line: string) -> (name: string, count: int, err: Artifact_Error) {
	if len(line) < 2 || line[0] != '[' || line[len(line) - 1] != ']' {
		return "", 0, .Missing_Section_Header
	}
	inner := line[1:len(line) - 1]
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

decode_int :: proc(token: string) -> (value: i64, ok: bool) {
	return strconv.parse_i64(token)
}

decode_fixed :: proc(token: string, human := false) -> (value: Fixed, ok: bool) {
	if human && strings.index_byte(token, '.') >= 0 {
		return decode_fixed_source(token)
	}
	bits, parsed := strconv.parse_i64(token)
	if !parsed {
		return Fixed(0), false
	}
	return Fixed(bits), true
}

decode_fixed_source :: proc(token: string) -> (value: Fixed, ok: bool) {
	body := token
	negative := false
	if len(body) > 0 && body[0] == '-' {
		negative = true
		body = body[1:]
	}
	dot := strings.index_byte(body, '.')
	if dot < 0 {
		return Fixed(0), false
	}
	int_str := body[:dot]
	frac := body[dot + 1:]
	if len(int_str) == 0 && len(frac) == 0 {
		return Fixed(0), false
	}
	if !is_ascii_digits(int_str) || !is_ascii_digits(frac) {
		return Fixed(0), false
	}
	int_part: i64 = 0
	if len(int_str) > 0 {
		parsed: bool
		int_part, parsed = strconv.parse_i64(int_str)
		if !parsed {
			return Fixed(0), false
		}
	}
	magnitude := fixed_from_decimal(int_part, frac)
	if negative {
		return fixed_neg(magnitude), true
	}
	return magnitude, true
}

is_ascii_digits :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

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

decode_bool :: proc(token: string) -> (value: bool, ok: bool) {
	switch token {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	return false, false
}
