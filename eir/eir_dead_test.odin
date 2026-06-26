// Dead-lint tests: the floor is (1) a file-private declaration nothing references is
// reported, with its kind, while a file-private one that IS referenced is not, (2) the
// lint is scoped to FILE-private — a package-visible or `@(private)` unused declaration is
// NOT reported (it could be used from another file, so single-file analysis cannot condemn
// it), (3) the empty case renders the "no dead" forms, and (4) the --json render is
// byte-stable and round-trips. Each fixture is a real source parsed through the loader
// (load_source_fixture, shared from eir_discover_test.odin), so the tests exercise the lint
// over genuine core:odin/ast trees.
package eir

import "core:encoding/json"
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

// test_dead_all_referenced: every file-private decl is used, so the lint finds nothing and
// renders the empty forms.
@(test)
test_dead_all_referenced :: proc(t: ^testing.T) {
	result := load_source_fixture("dead_allused", ALL_USED_SRC)
	dead := find_dead_decls(result, context.temp_allocator)
	testing.expect_value(t, len(dead), 0)

	human := render_dead_human(dead, context.temp_allocator)
	testing.expect(t, strings.contains(human, "no dead file-private declarations found"), "an empty scan must say so")

	body := render_dead_json(dead, context.temp_allocator)
	testing.expect(t, strings.contains(body, "\"dead_decls\":[]"), "an empty scan's JSON must carry an empty array")
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

// test_dead_json_byte_stable_and_valid: two renders of the same dead set are byte-identical,
// the output parses as valid JSON, and it round-trips into Dead_Report with the recorded
// shape (schema version and the per-decl fields).
@(test)
test_dead_json_byte_stable_and_valid :: proc(t: ^testing.T) {
	result := load_source_fixture("dead_json", DEAD_SRC)
	dead := find_dead_decls(result, context.temp_allocator)

	first := render_dead_json(dead, context.temp_allocator)
	second := render_dead_json(dead, context.temp_allocator)
	testing.expect(t, first == second, "the dead JSON must be byte-stable across renders")

	report: Dead_Report
	err := json.unmarshal_string(first, &report, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "the JSON must parse into Dead_Report")
	testing.expect_value(t, report.schema_version, DEAD_REPORT_SCHEMA_VERSION)
	testing.expect_value(t, len(report.dead_decls), 3)
	if len(report.dead_decls) == 3 {
		testing.expect_value(t, report.dead_decls[0].name, "DEAD_LIMIT")
		testing.expect_value(t, report.dead_decls[2].kind, "type")
	}
}
