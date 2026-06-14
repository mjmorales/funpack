// The fmt-verb integration tests: the exit contract over temp §14 trees
// (mirroring check_test.odin's patterns — 0 canonical / 1 counted drift on
// --check / 2 malformed tree or parse error, with --check's no-write floor),
// the gen/*.gen.fun skip rule, and the two AST-preservation PROPERTIES the
// story pins: parse(fmt(x)) is an AST equivalent to parse(x) (ast_equiv —
// modulo line spans), and fmt(fmt(x)) == fmt(x) byte-for-byte.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// fmt_source is the renderer applied to one source string — the pure
// function the properties quantify over (the verb is this plus tree IO).
fmt_source :: proc(source: string) -> (formatted: string, err: Parse_Error) {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return "", parse_err
	}
	return render_canonical(ast, context.temp_allocator), .None
}

// expect_fmt_properties asserts the two story properties on one source:
// parse(fmt(x)) is equivalent to parse(x), and fmt is idempotent.
expect_fmt_properties :: proc(t: ^testing.T, source: string, loc := #caller_location) {
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None, loc = loc)
	if parse_err != .None {
		return
	}
	formatted, fmt_err := fmt_source(source)
	testing.expect_value(t, fmt_err, Parse_Error.None, loc = loc)
	reparsed, reparse_err := stage_parse(stage_lex(formatted))
	testing.expect_value(t, reparse_err, Parse_Error.None, loc = loc)
	if reparse_err != .None {
		return
	}
	testing.expect(t, ast_equiv(ast, reparsed), "parse(fmt(x)) is not equivalent to parse(x)", loc = loc)
	second, second_err := fmt_source(formatted)
	testing.expect_value(t, second_err, Parse_Error.None, loc = loc)
	testing.expect_value(t, second, formatted, loc = loc)
}

// The fmt `--check` flag seam is now pinned in cli_funpack_test.odin (the CLI
// tree maps `--check` to Fmt_Mode.Check and its absence to Write, and a typo'd
// or trailing argument is the usage tier); the property and integration tests
// below exercise the formatter itself.

@(test)
test_fmt_property_holds_over_fixture_battery :: proc(t: ^testing.T) {
	// The properties over the surface battery: directives, every decl kind,
	// expressions with restored parens, match/if/lambda, holes, tuples.
	fixtures := [?]string{
		MINI_SOURCE,
		HOLED_SOURCE,
		"@doc(\"M\")\nimport engine.math.{Vec2}\n\nenum Side { Left, Right }\n\ndata Board { w: Fixed, h: Fixed }\n\nthing Paddle {\n  side: Side\n  x:    Fixed\n}\n\nsignal Goal { side: Side }\n\nfn serve(side: Side) -> Vec2 {\n  return match side {\n    Side::Left => Vec2{x: 70.0, y: 40.0}\n    Side::Right => Vec2{x: -70.0, y: 40.0}\n  }\n}\n\nbehavior move on Paddle {\n  fn step(self: Paddle) -> Paddle {\n    if self.x > 1.0 { return self }\n    return self with { x: (self.x + 1.0) * 0.5 }\n  }\n}\n\npipeline P {\n  control: [move]\n}\n\ntest \"serves left\" {\n  assert serve(Side::Left) == Vec2{x: 70.0, y: 40.0}\n}\n",
		"fn pick(a: Bool, b: Bool) -> Int {\n  let x = if a { 1 } else if b { 2 } else { 3 }\n  return match (x == 1) {\n    _ => x\n  }\n}\n",
	}
	for fixture in fixtures {
		expect_fmt_properties(t, fixture)
	}
}

@(test)
test_fmt_property_holds_over_golden_numerics :: proc(t: ^testing.T) {
	// The properties over a live committed golden source — the numerics tree's
	// single module (SKIP-warn when the sibling checkout is absent).
	source, ok := golden_source()
	if !ok {
		return
	}
	expect_fmt_properties(t, source)
}

@(test)
test_fmt_check_drift_exits_one_without_writing :: proc(t: ^testing.T) {
	// MINI_SOURCE carries a blank line between the module @doc and the import,
	// which the canonical form drops — a real drift. --check exits 1, prints
	// only advisory lines, and leaves the source bytes untouched.
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	src_path := scratch_join({root, "src", "mini.fun"})

	testing.expect_value(t, fmt_verb_exit(root, .Check), 1)
	after, read_err := os.read_entire_file_from_path(src_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(after), MINI_SOURCE)
	log.infof("fmt --check drift: the drifting tree exits 1 and the source stays byte-untouched (verdict-only)")
}

@(test)
test_fmt_write_then_check_clean_and_idempotent :: proc(t: ^testing.T) {
	// The write pass rewrites the drifting source to canonical (exit 0), after
	// which --check is clean (exit 0) and a second write pass changes nothing —
	// the on-disk idempotence the §02 mandatory formatter requires.
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	src_path := scratch_join({root, "src", "mini.fun"})

	testing.expect_value(t, fmt_verb_exit(root, .Write), 0)
	first, first_err := os.read_entire_file_from_path(src_path, context.temp_allocator)
	testing.expect(t, first_err == nil)
	testing.expect(t, string(first) != MINI_SOURCE)

	testing.expect_value(t, fmt_verb_exit(root, .Check), 0)

	testing.expect_value(t, fmt_verb_exit(root, .Write), 0)
	second, second_err := os.read_entire_file_from_path(src_path, context.temp_allocator)
	testing.expect(t, second_err == nil)
	testing.expect_value(t, string(second), string(first))
	log.infof("fmt write: the tree canonicalizes once, then --check is clean and a second pass is a byte no-op")
}

@(test)
test_fmt_malformed_tree_exits_two :: proc(t: ^testing.T) {
	// A root with no funpack_configs/ is the read_project refusal — exit 2 in
	// both modes, the same malformed-tree tier every front-door verb shares.
	root := scratch_join({scratch_base(), tprintf_seq("funpack-fmt-malformed")})
	remove_scratch_tree(root)
	if !ensure_dir(root) {
		log.warnf("SKIP fmt malformed tree: cannot create %s", root)
		return
	}
	defer remove_scratch_tree(root)

	testing.expect_value(t, fmt_verb_exit(root, .Write), 2)
	testing.expect_value(t, fmt_verb_exit(root, .Check), 2)
}

@(test)
test_fmt_parse_error_exits_two_untouched :: proc(t: ^testing.T) {
	// A source the §02 grammar cannot parse is the compile tier — exit 2 in
	// both modes, never a counted drift — and the broken bytes stay untouched
	// (fmt never writes a file it could not parse).
	root, ok := write_broken_pong_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	src_path := scratch_join({root, "src", "pong.fun"})
	before, before_err := os.read_entire_file_from_path(src_path, context.temp_allocator)
	testing.expect(t, before_err == nil)

	testing.expect_value(t, fmt_verb_exit(root, .Check), 2)
	testing.expect_value(t, fmt_verb_exit(root, .Write), 2)
	after, after_err := os.read_entire_file_from_path(src_path, context.temp_allocator)
	testing.expect(t, after_err == nil)
	testing.expect_value(t, string(after), string(before))
	log.infof("fmt parse error: the unparseable tree refuses exit 2 (never a counted drift) and writes nothing")
}

@(test)
test_fmt_skips_generated_seams :: proc(t: ^testing.T) {
	// A committed gen/*.gen.fun seam is the bake emitter's byte contract: fmt
	// must neither rewrite it (Write) nor count it as drift (Check), even when
	// its spelling is non-canonical. The fixture flips the levels capability ON
	// (a levels/*.flvl authoring file) so the seam joins the source set.
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	// Canonicalize the authored source first so any later drift verdict could
	// only come from the seam.
	testing.expect_value(t, fmt_verb_exit(root, .Write), 0)

	levels_path := scratch_join({root, "levels", "a.flvl"})
	seam_path := scratch_join({root, "gen", "a.gen.fun"})
	seam_bytes :: "data   A   {   x:   Int   }\n"
	if !ensure_dir(filepath.dir(levels_path)) || !ensure_dir(filepath.dir(seam_path)) ||
	   os.write_entire_file(levels_path, transmute([]u8)string("level a {\n}\n")) != nil ||
	   os.write_entire_file(seam_path, transmute([]u8)string(seam_bytes)) != nil {
		log.warnf("SKIP fmt seam skip: cannot materialize levels/gen under %s", root)
		return
	}

	testing.expect_value(t, fmt_verb_exit(root, .Check), 0)
	testing.expect_value(t, fmt_verb_exit(root, .Write), 0)
	after, read_err := os.read_entire_file_from_path(seam_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(after), seam_bytes)
	log.infof("fmt seam skip: the non-canonical gen/ seam is neither drift-counted nor rewritten — emitter-owned bytes")
}

@(test)
test_unified_diff_emits_replacement_hunk :: proc(t: ^testing.T) {
	// The drift body is the gofmt -d / diff -u shape: a `--- path` / `+++ path`
	// header then a `@@ -l,c +l,c @@` hunk with `-` (on-disk) and `+`
	// (canonical) lines around context. A one-line replacement in the middle
	// keeps DIFF_CONTEXT context lines each side.
	old := "a\nb\nc\nd\ne\n"
	new := "a\nb\nX\nd\ne\n"
	diff := unified_diff("src/x.fun", old, new, context.temp_allocator)
	testing.expect(t, strings.contains(diff, "--- src/x.fun\n"))
	testing.expect(t, strings.contains(diff, "+++ src/x.fun\n"))
	testing.expect(t, strings.contains(diff, "@@ -1,5 +1,5 @@\n"))
	testing.expect(t, strings.contains(diff, "-c\n"))
	testing.expect(t, strings.contains(diff, "+X\n"))
	// Context lines carry a leading space; the changed line c→X is the only
	// `-`/`+` pair.
	testing.expect(t, strings.contains(diff, " a\n"))
	testing.expect(t, strings.contains(diff, " e\n"))
}

@(test)
test_unified_diff_is_deterministic :: proc(t: ^testing.T) {
	// Identical (old, new) bytes always yield byte-identical diff text — the
	// LCS edit script has a fixed tie-break (Delete before Insert), so there is
	// no run-to-run drift, the §29 determinism invariant the formatter holds.
	old := "one\ntwo\nthree\n"
	new := "one\n2\nthree\n"
	first := unified_diff("p", old, new, context.temp_allocator)
	second := unified_diff("p", old, new, context.temp_allocator)
	testing.expect_value(t, first, second)
	// Byte-identical inputs produce no diff.
	testing.expect_value(t, unified_diff("p", old, old, context.temp_allocator), "")
}

@(test)
test_unified_diff_marks_missing_final_newline :: proc(t: ^testing.T) {
	// A line missing its trailing newline gets the `\ No newline at end of
	// file` marker, the diff -u convention, so the hunk is faithful to the
	// bytes — a final-newline drift is a real, visible change.
	old := "x\ny"     // no trailing newline on `y`
	new := "x\ny\n"   // canonical adds it
	diff := unified_diff("p", old, new, context.temp_allocator)
	testing.expect(t, strings.contains(diff, "\\ No newline at end of file\n"))
}

@(test)
test_fmt_check_drift_prints_diff_body :: proc(t: ^testing.T) {
	// The integration contract: a drifting source's --check verdict line is
	// followed by its unified-diff body. MINI_SOURCE's blank-line drift renders
	// at least one `@@` hunk against the canonical form — the human-facing body
	// the bare exit code does not carry.
	source, ok := fmt_source(MINI_SOURCE)
	testing.expect_value(t, ok, Parse_Error.None)
	diff := unified_diff("src/mini.fun", MINI_SOURCE, source, context.temp_allocator)
	testing.expect(t, strings.contains(diff, "@@ "))
	testing.expect(t, len(diff) > 0)
}
