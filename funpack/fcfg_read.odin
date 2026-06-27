package funpack

import "core:strings"

Fcfg_Assignment :: struct {
	key:   string,
	value: string,
}

Fcfg_Block :: struct {
	label:       string,
	assignments: []Fcfg_Assignment,
}

fcfg_blocks :: proc(content: string, keyword: string) -> []Fcfg_Block {
	blocks := make([dynamic]Fcfg_Block, 0, 2, context.temp_allocator)
	lines := strings.split_lines(content, context.temp_allocator)
	i := 0
	for i < len(lines) {
		fields := fcfg_line_fields(lines[i])
		if len(fields) >= 2 && fields[0] == keyword {
			block := Fcfg_Block{label = fields[1]}
			block.assignments, i = fcfg_block_body(lines, i + 1)
			append(&blocks, block)
			continue
		}
		i += 1
	}
	return blocks[:]
}

fcfg_block_body :: proc(lines: []string, start: int) -> (assignments: []Fcfg_Assignment, next: int) {
	pairs := make([dynamic]Fcfg_Assignment, 0, 4, context.temp_allocator)
	i := start
	for i < len(lines) {
		trimmed := strings.trim_space(lines[i])
		i += 1
		if trimmed == "}" {
			break
		}
		if key, value, ok := fcfg_assignment(trimmed); ok {
			append(&pairs, Fcfg_Assignment{key = key, value = value})
		}
	}
	return pairs[:], i
}

fcfg_assignment :: proc(line: string) -> (key: string, value: string, ok: bool) {
	eq := strings.index_byte(line, '=')
	if eq < 0 {
		return "", "", false
	}
	key = strings.trim_space(line[:eq])
	value = strings.trim_space(line[eq + 1:])
	if key == "" || value == "" {
		return "", "", false
	}
	return key, value, true
}

fcfg_tag_list :: proc(content: string) -> []string {
	lines := strings.split_lines(content, context.temp_allocator)
	tags := make([dynamic]string, 0, 8, context.temp_allocator)
	in_block := false
	for line in lines {
		trimmed := strings.trim_space(line)
		if !in_block {
			fields := fcfg_line_fields(trimmed)
			if len(fields) >= 1 && fields[0] == "tags" {
				in_block = true
			}
			continue
		}
		if trimmed == "}" {
			break
		}
		if trimmed != "" && trimmed != "{" {
			append(&tags, trimmed)
		}
	}
	return tags[:]
}

fcfg_line_fields :: proc(line: string) -> []string {
	trimmed := strings.trim_space(line)
	raw := strings.fields(trimmed, context.temp_allocator)
	fields := make([dynamic]string, 0, len(raw), context.temp_allocator)
	for token in raw {
		if token == "{" {
			continue
		}
		append(&fields, token)
	}
	return fields[:]
}
