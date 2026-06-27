package eir

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

DEFAULT_MAX_COMMENTS_PER_FILE :: 5

File_Comment_Count :: struct {
	path:          string,
	is_test:       bool,
	comment_lines: int,
}

count_comment_lines_per_file :: proc(
	result: Load_Result,
	allocator := context.allocator,
) -> []File_Comment_Count {
	counts := make([dynamic]File_Comment_Count, 0, len(result.files), allocator)
	for loaded in result.files {
		if loaded.file == nil {
			continue
		}
		append(
			&counts,
			File_Comment_Count {
				path = loaded.path,
				is_test = loaded.is_test,
				comment_lines = comment_line_count(loaded.file),
			},
		)
	}
	slice.sort_by(counts[:], file_comment_count_heaviest_first)
	return counts[:]
}

comment_line_count :: proc(file: ^ast.File) -> int {
	occupied := make(map[int]bool, 64, context.temp_allocator)
	for group in file.comments {
		for token in group.list {
			if comment_is_build_directive(token.text) {
				continue
			}
			first := token.pos.line
			last := first + strings.count(token.text, "\n")
			for line in first ..= last {
				occupied[line] = true
			}
		}
	}
	return len(occupied)
}

comment_is_build_directive :: proc(text: string) -> bool {
	body := strings.trim_space(strings.trim_left(text, "/"))
	return strings.has_prefix(body, "+")
}

over_budget_diagnostics :: proc(
	counts: []File_Comment_Count,
	budget: int,
	severity: Severity,
	allocator := context.allocator,
) -> []Diagnostic {
	out := make([dynamic]Diagnostic, 0, 16, allocator)
	for count in counts {
		if count.comment_lines <= budget {
			continue
		}
		append(
			&out,
			Diagnostic {
				file = count.path,
				line = 1,
				col = 1,
				severity = severity,
				rule = "comments",
				message = fmt.aprintf(
					"%d comment lines exceed the budget of %d — encode intent in names, types, and tests instead",
					count.comment_lines,
					budget,
					allocator = allocator,
				),
				related = nil,
			},
		)
	}
	return out[:]
}

@(private = "file")
file_comment_count_heaviest_first :: proc(a, b: File_Comment_Count) -> bool {
	if a.comment_lines != b.comment_lines {
		return a.comment_lines > b.comment_lines
	}
	return a.path < b.path
}
