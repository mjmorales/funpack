// Dead-lint tests: the floor is (1) a file-private declaration nothing references is
// reported, with its kind, while a file-private one that IS referenced is not, (2) the
// lint is scoped to FILE-private — a package-visible or `@(private)` unused declaration is
// NOT reported (it could be used from another file, so single-file analysis cannot condemn
// it), (3) every file-private decl being referenced yields an empty projection, and (4) each
// dead decl projects to one `dead` Warning point-finding whose message names the kind and the
// declaration. Each fixture is a real source parsed through the loader (load_source_fixture,
// shared from eir_discover_test.odin), so the tests exercise the lint over genuine
// core:odin/ast trees.
package eir

import "core:strings"
import "core:testing"

// DEAD_SRC: four file-private declarations of distinct kinds — a const, a proc, and a type
// that nothing references (dead), plus a proc that the package-visible entry calls (live).
// public_entry itself is NOT file-private, so it is never a candidate even though the file
// does not call it.
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

// ALL_USED_SRC: every file-private declaration is referenced within the file, so the lint
// reports nothing.
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

// SCOPED_SRC: two unused declarations that are NOT file-private — a package-visible proc
// and a package-private (`@(private)`) one. Neither is single-file-condemnable (another
// file in the package could reference them), so the lint must report nothing.
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

// test_dead_reports_unreferenced_file_private: the three unreferenced file-private decls are
// reported in (line) order with their kinds; the referenced one and the public entry are
// not.
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

// test_dead_all_referenced: every file-private decl is used, so the lint finds nothing and the
// projection is empty (the shared renderer turns that into the "no findings" line).
@(test)
test_dead_all_referenced :: proc(t: ^testing.T) {
	result := load_source_fixture("dead_allused", ALL_USED_SRC)
	dead := find_dead_decls(result, context.temp_allocator)
	testing.expect_value(t, len(dead), 0)
	testing.expect_value(t, len(dead_diagnostics(dead, context.temp_allocator)), 0)
}

// test_dead_scoped_to_file_private: an unused package-visible decl and an unused
// `@(private)` (package-private) decl are NOT reported — single-file analysis cannot condemn
// a declaration another file might reference.
@(test)
test_dead_scoped_to_file_private :: proc(t: ^testing.T) {
	result := load_source_fixture("dead_scoped", SCOPED_SRC)
	dead := find_dead_decls(result, context.temp_allocator)
	testing.expect_value(t, len(dead), 0)
}

// test_dead_diagnostics_projection: each dead declaration projects to one `dead` Warning — a
// point finding with no related sites — whose message names the kind and the declaration to
// delete, in the lint's (path, line) order.
@(test)
test_dead_diagnostics_projection :: proc(t: ^testing.T) {
	result := load_source_fixture("dead_diag", DEAD_SRC)
	dead := find_dead_decls(result, context.temp_allocator)

	diags := dead_diagnostics(dead, context.temp_allocator)
	testing.expect_value(t, len(diags), 3)
	if len(diags) == 3 {
		testing.expect_value(t, diags[0].severity, Severity.Warning)
		testing.expect_value(t, diags[0].rule, "dead")
		testing.expect_value(t, len(diags[0].related), 0) // a point finding carries no related sites
		testing.expect(t, strings.contains(diags[0].message, "DEAD_LIMIT"), "the message names the declaration")
		testing.expect(t, strings.contains(diags[0].message, "const"), "the message names the kind")
		testing.expect(t, strings.contains(diags[2].message, "Dead_Type"), "projection preserves the lint's order")
	}
}
