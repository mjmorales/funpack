package funpack

import "core:fmt"
import "core:os"
import "core:strings"

Fmt_Mode :: enum {
	Write,
	Check,
}

run_fmt_verb :: proc(mode: Fmt_Mode) -> int {
	return fmt_verb_exit(".", mode)
}

Fmt_Error :: enum {
	None,
	Malformed_Tree,
	Read_Failed,
	Parse_Failed,
}

Fmt_Verdict :: struct {
	err:      Fmt_Error,
	offender: string,
}

Drifted_Source :: struct {
	path:         string,
	on_disk:      string,
	canonical:    string,
	unified_diff: string,
}

fmt_drift :: proc(root: string, allocator := context.allocator) -> (drifted: []Drifted_Source, verdict: Fmt_Verdict) {
	project, project_err, project_detail := read_project(root)
	if project_err != .None {
		return nil, Fmt_Verdict{err = .Malformed_Tree, offender = project_refusal_message(project_err, project_detail, allocator)}
	}
	out := make([dynamic]Drifted_Source, 0, len(project.sources), allocator)
	for source in project.sources {
		if strings.has_suffix(source.path, GEN_SUFFIX) {
			continue
		}
		bytes, read_err := os.read_entire_file_from_path(source.path, allocator)
		if read_err != nil {
			return nil, Fmt_Verdict{err = .Read_Failed, offender = fmt.aprintf("%s: %v", source.path, read_err, allocator = allocator)}
		}
		ast, parse_err := stage_parse(stage_lex(string(bytes)))
		if parse_err != .None {
			return nil, Fmt_Verdict{err = .Parse_Failed, offender = fmt.aprintf("%s: %v", source.path, parse_err, allocator = allocator)}
		}
		canonical := render_canonical(ast, allocator)
		if canonical == string(bytes) {
			continue
		}
		append(
			&out,
			Drifted_Source {
				path = source.path,
				on_disk = string(bytes),
				canonical = canonical,
				unified_diff = unified_diff(source.path, string(bytes), canonical, allocator),
			},
		)
	}
	return out[:], Fmt_Verdict{}
}

fmt_verb_exit :: proc(root: string, mode: Fmt_Mode) -> int {
	drifted, verdict := fmt_drift(root, context.temp_allocator)
	if verdict.err != .None {
		fmt.eprintfln("funpack fmt: %s", verdict.offender)
		return 2
	}
	switch mode {
	case .Write:
		for d in drifted {
			if os.write_entire_file(d.path, transmute([]u8)d.canonical) != nil {
				fmt.eprintfln("funpack fmt: %s: write failed", d.path)
				return 2
			}
			fmt.printfln("funpack fmt: wrote %s", d.path)
		}
		return 0
	case .Check:
		for d in drifted {
			fmt.printfln("funpack fmt: %s drifts from canonical form", d.path)
			fmt.print(d.unified_diff)
		}
		if len(drifted) != 0 {
			return 1
		}
		fmt.println("funpack fmt: clean")
		return 0
	}
	return 0
}

DIFF_CONTEXT :: 3

Diff_Op :: enum {
	Equal,
	Delete,
	Insert,
}

Diff_Edit :: struct {
	op:        Diff_Op,
	text:      string,
	old_index: int,
	new_index: int,
}

unified_diff :: proc(path: string, old: string, new: string, allocator := context.allocator) -> string {
	if old == new {
		return ""
	}
	old_lines := strings.split_after(old, "\n", allocator)
	new_lines := strings.split_after(new, "\n", allocator)
	old_lines = trim_trailing_empty(old_lines)
	new_lines = trim_trailing_empty(new_lines)
	edits := diff_lines(old_lines, new_lines, allocator)
	b := strings.builder_make(allocator)
	fmt.sbprintfln(&b, "--- %s", path)
	fmt.sbprintfln(&b, "+++ %s", path)
	write_diff_hunks(&b, edits)
	return strings.to_string(b)
}

trim_trailing_empty :: proc(lines: []string) -> []string {
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		return lines[:len(lines) - 1]
	}
	return lines
}

diff_lines :: proc(old: []string, new: []string, allocator := context.allocator) -> []Diff_Edit {
	n := len(old)
	m := len(new)
	lcs := make([][]int, n + 1, allocator)
	for i in 0 ..= n {
		lcs[i] = make([]int, m + 1, allocator)
	}
	for i := n - 1; i >= 0; i -= 1 {
		for j := m - 1; j >= 0; j -= 1 {
			if old[i] == new[j] {
				lcs[i][j] = lcs[i + 1][j + 1] + 1
			} else {
				lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
			}
		}
	}
	edits := make([dynamic]Diff_Edit, 0, n + m, allocator)
	i, j := 0, 0
	for i < n && j < m {
		if old[i] == new[j] {
			append(&edits, Diff_Edit{op = .Equal, text = old[i], old_index = i, new_index = j})
			i += 1
			j += 1
		} else if lcs[i + 1][j] >= lcs[i][j + 1] {
			append(&edits, Diff_Edit{op = .Delete, text = old[i], old_index = i, new_index = j})
			i += 1
		} else {
			append(&edits, Diff_Edit{op = .Insert, text = new[j], old_index = i, new_index = j})
			j += 1
		}
	}
	for ; i < n; i += 1 {
		append(&edits, Diff_Edit{op = .Delete, text = old[i], old_index = i, new_index = j})
	}
	for ; j < m; j += 1 {
		append(&edits, Diff_Edit{op = .Insert, text = new[j], old_index = i, new_index = j})
	}
	return edits[:]
}

write_diff_hunks :: proc(b: ^strings.Builder, edits: []Diff_Edit) {
	start := 0
	for start < len(edits) {
		if edits[start].op == .Equal {
			start += 1
			continue
		}
		hunk_lo := max(0, start - DIFF_CONTEXT)
		end := start
		for {
			for end < len(edits) && edits[end].op != .Equal {
				end += 1
			}
			gap := end
			for gap < len(edits) && edits[gap].op == .Equal {
				gap += 1
			}
			if gap < len(edits) && gap - end <= 2 * DIFF_CONTEXT {
				end = gap
				continue
			}
			break
		}
		hunk_hi := min(len(edits), end + DIFF_CONTEXT)
		write_one_hunk(b, edits[hunk_lo:hunk_hi])
		start = hunk_hi
	}
}

write_one_hunk :: proc(b: ^strings.Builder, hunk: []Diff_Edit) {
	old_start, old_len, new_start, new_len := hunk_bounds(hunk)
	fmt.sbprintfln(b, "@@ -%d,%d +%d,%d @@", old_start, old_len, new_start, new_len)
	for edit in hunk {
		switch edit.op {
		case .Equal:
			strings.write_byte(b, ' ')
		case .Delete:
			strings.write_byte(b, '-')
		case .Insert:
			strings.write_byte(b, '+')
		}
		strings.write_string(b, edit.text)
		if !strings.has_suffix(edit.text, "\n") {
			strings.write_string(b, "\n\\ No newline at end of file\n")
		}
	}
}

hunk_bounds :: proc(hunk: []Diff_Edit) -> (old_start: int, old_len: int, new_start: int, new_len: int) {
	for edit in hunk {
		switch edit.op {
		case .Equal:
			old_len += 1
			new_len += 1
		case .Delete:
			old_len += 1
		case .Insert:
			new_len += 1
		}
	}
	old_start = hunk[0].old_index + 1 if old_len > 0 else 0
	new_start = hunk[0].new_index + 1 if new_len > 0 else 0
	return old_start, old_len, new_start, new_len
}
