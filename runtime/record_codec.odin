package funpack_runtime

import "core:strconv"
import "core:strings"

@(private)
write_string_field :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, 'L')
	strings.write_int(b, len(s))
	strings.write_byte(b, ':')
	strings.write_string(b, s)
}

@(private)
write_u64 :: proc(b: ^strings.Builder, v: u64) {
	buf: [20]byte
	strings.write_string(b, strconv.write_uint(buf[:], v, 10))
}

@(private)
next_line :: proc(lines: []string, cursor: ^int) -> (line: string, ok: bool) {
	if cursor^ >= len(lines) {
		return "", false
	}
	line = lines[cursor^]
	cursor^ += 1
	return line, true
}

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
