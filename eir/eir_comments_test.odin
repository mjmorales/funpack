package eir

import "core:strings"
import "core:testing"

@(private = "file")
budget_count :: proc(label, src: string) -> int {
	result := load_source_fixture(label, src)
	counts := count_comment_lines_per_file(result, context.temp_allocator)
	if len(counts) == 0 {
		return -1
	}
	return counts[0].comment_lines
}

@(private = "file")
HEAVY_SRC :: `package p

// one
// two
foo :: proc() -> int {
	x := 1 // trailing three
	// four
	return x
}
`

@(test)
test_counts_every_comment_line_including_trailing :: proc(t: ^testing.T) {
	testing.expect_value(t, budget_count("comments_heavy", HEAVY_SRC), 4)
}

@(private = "file")
BLOCK_SRC :: `package p

/* one
   two
   three */
foo :: proc() -> int {
	return 0
}
`

@(test)
test_block_comment_counts_every_spanned_line :: proc(t: ^testing.T) {
	testing.expect_value(t, budget_count("comments_block", BLOCK_SRC), 3)
}

@(private = "file")
CLEAN_SRC :: `package p

clamp_to_unit_interval :: proc(value: f32) -> f32 {
	if value < 0 { return 0 }
	if value > 1 { return 1 }
	return value
}
`

@(test)
test_comment_free_file_counts_zero :: proc(t: ^testing.T) {
	testing.expect_value(t, budget_count("comments_clean", CLEAN_SRC), 0)
}

@(private = "file")
BUILD_TAG_SRC :: `package p

//+build linux
//+private
real_comment_below :: proc() -> int {
	// counted
	return 0
}
`

@(test)
test_build_directives_are_exempt :: proc(t: ^testing.T) {
	testing.expect_value(t, budget_count("comments_buildtag", BUILD_TAG_SRC), 1)
}

@(test)
test_over_budget_diagnostics_flag_only_files_above_budget :: proc(t: ^testing.T) {
	result := load_source_fixture("comments_budget", HEAVY_SRC)
	counts := count_comment_lines_per_file(result, context.temp_allocator)

	under := over_budget_diagnostics(counts, 4, .Error, context.temp_allocator)
	testing.expect_value(t, len(under), 0)

	over := over_budget_diagnostics(counts, 3, .Error, context.temp_allocator)
	testing.expect_value(t, len(over), 1)
	if len(over) == 1 {
		testing.expect_value(t, over[0].rule, "comments")
		testing.expect_value(t, over[0].severity, Severity.Error)
		testing.expect(t, strings.contains(over[0].message, "budget"), "the message names the budget")
	}
}
