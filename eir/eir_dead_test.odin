package eir

import "core:strings"
import "core:testing"

@(private = "file")
DEAD_SRC :: `package p

@(private="file")
DEAD_LIMIT :: 100

@(private="file")
dead_helper :: proc() -> int {
	return 7
}

@(private="file")
Dead_Type :: struct {
	x: int,
}

@(private="file")
used_helper :: proc() -> int {
	return 42
}

public_entry :: proc() -> int {
	return used_helper()
}
`

@(private = "file")
ALL_USED_SRC :: `package p

@(private="file")
LIMIT :: 10

@(private="file")
scale :: proc(n: int) -> int {
	return n * LIMIT
}

run :: proc() -> int {
	return scale(3)
}
`

@(private = "file")
SCOPED_SRC :: `package p

unused_public :: proc() -> int {
	return 1
}

@(private)
unused_package :: proc() -> int {
	return 2
}
`

@(test)
test_dead_reports_unreferenced_file_private :: proc(t: ^testing.T) {
	result := load_source_fixture("dead_basic", DEAD_SRC)
	dead := find_dead_decls(result, context.temp_allocator)

	testing.expect_value(t, len(dead), 3)
	if len(dead) == 3 {
		testing.expect_value(t, dead[0].name, "DEAD_LIMIT")
		testing.expect_value(t, dead[0].kind, "const")
		testing.expect_value(t, dead[1].name, "dead_helper")
		testing.expect_value(t, dead[1].kind, "proc")
		testing.expect_value(t, dead[2].name, "Dead_Type")
		testing.expect_value(t, dead[2].kind, "type")
	}

	for d in dead {
		testing.expect(t, d.name != "used_helper", "a referenced file-private decl is not dead")
		testing.expect(t, d.name != "public_entry", "a package-visible decl is never a candidate")
	}
}

@(test)
test_dead_all_referenced :: proc(t: ^testing.T) {
	result := load_source_fixture("dead_allused", ALL_USED_SRC)
	dead := find_dead_decls(result, context.temp_allocator)
	testing.expect_value(t, len(dead), 0)
	testing.expect_value(t, len(dead_diagnostics(dead, context.temp_allocator)), 0)
}

@(test)
test_dead_scoped_to_file_private :: proc(t: ^testing.T) {
	result := load_source_fixture("dead_scoped", SCOPED_SRC)
	dead := find_dead_decls(result, context.temp_allocator)
	testing.expect_value(t, len(dead), 0)
}

@(test)
test_dead_diagnostics_projection :: proc(t: ^testing.T) {
	result := load_source_fixture("dead_diag", DEAD_SRC)
	dead := find_dead_decls(result, context.temp_allocator)

	diags := dead_diagnostics(dead, context.temp_allocator)
	testing.expect_value(t, len(diags), 3)
	if len(diags) == 3 {
		testing.expect_value(t, diags[0].severity, Severity.Warning)
		testing.expect_value(t, diags[0].rule, "dead")
		testing.expect_value(t, len(diags[0].related), 0)
		testing.expect(t, strings.contains(diags[0].message, "DEAD_LIMIT"), "the message names the declaration")
		testing.expect(t, strings.contains(diags[0].message, "const"), "the message names the kind")
		testing.expect(t, strings.contains(diags[2].message, "Dead_Type"), "projection preserves the lint's order")
	}
}
