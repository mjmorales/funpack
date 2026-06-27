package funpack

import "core:strconv"
import "core:strings"

ARTIFACT_SCHEMA_VERSION :: 19

ARTIFACT_MAGIC :: "funpack-artifact"

encode_int :: proc(value: i64, allocator := context.allocator) -> string {
	buf: [32]byte
	return strings.clone(strconv.write_int(buf[:], value, 10), allocator)
}

encode_fixed :: proc(value: Fixed, allocator := context.allocator) -> string {
	return encode_int(i64(value), allocator)
}

encode_string :: proc(value: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, 'L')
	strings.write_int(&b, len(value))
	strings.write_byte(&b, ':')
	strings.write_string(&b, value)
	return strings.to_string(b)
}

encode_bool :: proc(value: bool) -> string {
	return "true" if value else "false"
}

@(rodata)
SUB_RECORD_KEYWORDS := []string{
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

Artifact_Section :: struct {
	name:  string,
	count: int,
	body:  []string,
}

Artifact_Doc :: struct {
	schema_version: int,
	sections:       []Artifact_Section,
}

Artifact_Parse_Error :: enum {
	None,
	Bad_Magic,
	Bad_Version,
	Bad_Section_Header,
	Count_Mismatch,
}

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

is_section_header_line :: proc(line: string) -> bool {
	return len(line) > 0 && line[0] == '['
}

section_lead_count :: proc(section: Artifact_Section) -> int {
	lead := 0
	for line in section.body {
		if !is_sub_record_line(line) {
			lead += 1
		}
	}
	return lead
}

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

split_artifact_lines :: proc(content: string) -> []string {
	trimmed := strings.trim_suffix(content, "\n")
	if trimmed == "" {
		return nil
	}
	return strings.split(trimmed, "\n", context.temp_allocator)
}

parse_version_stamp :: proc(line: string) -> (magic: string, version: int, ok: bool) {
	space := strings.index_byte(line, ' ')
	if space < 0 {
		return "", -1, false
	}
	version, ok = strconv.parse_int(line[space + 1:])
	return line[:space], version, ok
}

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

artifact_find_section :: proc(doc: Artifact_Doc, name: string) -> (section: Artifact_Section, found: bool) {
	for candidate in doc.sections {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Artifact_Section{}, false
}

NODE_LINE_KEYWORD :: "node"

ARM_NODE_KIND :: "arm"

ARM_TUPLE_PATTERN :: "tuple"

node_line_kind :: proc(line: string) -> (kind: string, ok: bool) {
	prefix := NODE_LINE_KEYWORD + " "
	if !strings.has_prefix(line, prefix) {
		return "", false
	}
	tail := line[len(prefix):]
	if end := strings.index_byte(tail, ' '); end >= 0 {
		return tail[:end], true
	}
	return tail, true
}

node_child_count :: proc(line: string) -> (count: int, ok: bool) {
	kind, kind_ok := node_line_kind(line)
	if !kind_ok {
		return 0, false
	}
	if kind == ARM_NODE_KIND {
		if arm_pattern_kind(line) == ARM_TUPLE_PATTERN {
			return parse_trailing_int(line)
		}
		return 0, true
	}
	return parse_trailing_int(line)
}

parse_trailing_int :: proc(line: string) -> (int, bool) {
	space := strings.last_index_byte(line, ' ')
	if space < 0 {
		return 0, false
	}
	return strconv.parse_int(line[space + 1:])
}

arm_pattern_kind :: proc(line: string) -> string {
	prefix := NODE_LINE_KEYWORD + " " + ARM_NODE_KIND + " "
	if !strings.has_prefix(line, prefix) {
		return ""
	}
	tail := line[len(prefix):]
	if end := strings.index_byte(tail, ' '); end >= 0 {
		return tail[:end]
	}
	return tail
}

consume_node_subtree :: proc(nodes: []string, start: int) -> (next: int, ok: bool) {
	if start >= len(nodes) {
		return start, false
	}
	child_count, count_ok := node_child_count(nodes[start])
	if !count_ok {
		return start, false
	}
	i := start + 1
	for _ in 0 ..< child_count {
		i, ok = consume_node_subtree(nodes, i)
		if !ok {
			return i, false
		}
	}
	return i, true
}

body_forest_is_well_formed :: proc(nodes: []string, statement_count: int) -> bool {
	i := 0
	for _ in 0 ..< statement_count {
		next, ok := consume_node_subtree(nodes, i)
		if !ok {
			return false
		}
		i = next
	}
	return i == len(nodes)
}
