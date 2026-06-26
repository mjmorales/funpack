// A generic, hand-rolled `.fcfg` mini-reader: the line-oriented lexer/parser
// primitives — blocks, `key = value` assignments, bare-identifier tag lists —
// that serve §14 config files with no validated production of their own,
// factored apart from their Index-Contract consumers to stay self-contained.
package funpack

import "core:strings"

// Fcfg_Assignment is one `key = value` line inside an fcfg block. The value is
// the bare token after `=` (an identifier, a platform name, a `60hz` rate) —
// the smaller config grammar carries bare values, not the string literals the
// project.fcfg reader expects, so the project-record readers take the value
// verbatim and interpret it per field.
Fcfg_Assignment :: struct {
	key:   string,
	value: string,
}

// Fcfg_Block is one `<keyword> <label> { … }` block of the smaller config
// grammar (§14 §2): the block label and its `key = value` assignments. A `use`
// reference line, an `@doc` directive, and blank lines are not blocks and are
// skipped, so the reader sees only the authored declaration blocks.
Fcfg_Block :: struct {
	label:       string,
	assignments: []Fcfg_Assignment,
}

// fcfg_blocks reads every `<keyword> <label> { … }` block of a given keyword
// from an fcfg source into its label and `key = value` assignments. The reader
// is line-oriented over the §14 smaller config grammar: a block opens on a line
// whose first token is the keyword (the label is the second token), each body
// line is one `key = value` assignment until the closing `}`, and a leading
// `use mod.{…}` reference and `@doc` directives are skipped. It serves the
// configs with no validated production of their own (builds.fcfg) —
// entrypoints.fcfg rides parse_entrypoints_fcfg, the one entrypoints grammar.
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

// fcfg_block_body reads a block's `key = value` assignment lines from `start`
// up to and including the closing `}`, returning the assignments and the index
// one past the `}`. A line that is neither an assignment nor the closer (an
// `@doc`, a blank line) is skipped, so only the authored wiring is collected.
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

// fcfg_assignment parses one `key = value` line into its key and bare value.
// ok is false for a line without `=` (an `@doc`, a `use` reference, the `{`/`}`
// braces), which the block reader skips. The value is the trimmed token after
// `=`, taken verbatim (a bare identifier or `60hz` rate, never a quoted
// literal in the smaller config grammar's block bodies).
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

// fcfg_tag_list reads the bare identifiers inside the single `tags { … }` block
// (§14 §4): each non-brace body line is one registered tag, in authored order.
// A line outside the block, the `tags {` opener, and the `}` closer are not
// tags. It returns the tags in listed order, never re-sorted, so the registry
// field is deterministic.
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

// fcfg_line_fields splits an fcfg line on whitespace into its tokens, dropping
// a trailing `{` so a block-opener line (`entrypoint main {`) yields just the
// keyword and label. It is the line tokenizer the block reader keys off — the
// smaller config grammar has no statement terminator, so a token split on
// whitespace is sufficient for the opener lines the reader inspects.
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
