package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

fmt_source :: proc(source: string) -> (formatted: string, err: Parse_Error) {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return "", parse_err
	}
	return render_canonical(ast, context.temp_allocator), .None
}

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

@(test)
test_fmt_property_holds_over_fixture_battery :: proc(t: ^testing.T) {
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
	source, ok := golden_source()
	if !ok {
		return
	}
	expect_fmt_properties(t, source)
}

@(test)
test_fmt_drift_reports_drift_without_writing :: proc(t: ^testing.T) {
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	drifted, verdict := fmt_drift(root, context.temp_allocator)
	testing.expect_value(t, verdict.err, Fmt_Error.None)
	testing.expect_value(t, len(drifted), 1)
	if len(drifted) != 1 {
		return
	}
	src_path := drifted[0].path
	testing.expect(t, strings.has_suffix(src_path, "mini.fun"), "drift path ends in the offending source")
	testing.expect_value(t, drifted[0].on_disk, MINI_SOURCE)
	testing.expect(t, drifted[0].canonical != MINI_SOURCE, "canonical must differ from the drifting on-disk bytes")

	after, read_err := os.read_entire_file_from_path(src_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(after), MINI_SOURCE)
	log.infof("fmt_drift: the drift is reported and the source stays byte-untouched (pure compute, no side effect)")
}

@(test)
test_fmt_drift_clean_tree_empty :: proc(t: ^testing.T) {
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	testing.expect_value(t, fmt_verb_exit(root, .Write), 0)
	drifted, verdict := fmt_drift(root, context.temp_allocator)
	testing.expect_value(t, verdict.err, Fmt_Error.None)
	testing.expect_value(t, len(drifted), 0)
	log.infof("fmt_drift: a canonical tree yields an empty drift list and a clean verdict")
}

@(test)
test_fmt_drift_unified_diff_matches_verb :: proc(t: ^testing.T) {
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	drifted, verdict := fmt_drift(root, context.temp_allocator)
	testing.expect_value(t, verdict.err, Fmt_Error.None)
	testing.expect_value(t, len(drifted), 1)
	if len(drifted) != 1 {
		return
	}
	d := drifted[0]
	fresh := unified_diff(d.path, d.on_disk, d.canonical, context.temp_allocator)
	testing.expect_value(t, d.unified_diff, fresh)
	log.infof("fmt_drift: Drifted_Source.unified_diff is byte-equal to a fresh unified_diff() call (seam↔print coherence)")
}

@(test)
test_fmt_drift_malformed_tree_refuses :: proc(t: ^testing.T) {
	root := scratch_join({scratch_base(), tprintf_seq("funpack-fmt-drift-malformed")})
	remove_scratch_tree(root)
	if !ensure_dir(root) {
		log.warnf("SKIP fmt_drift malformed tree: cannot create %s", root)
		return
	}
	defer remove_scratch_tree(root)

	drifted, verdict := fmt_drift(root, context.temp_allocator)
	testing.expect_value(t, verdict.err, Fmt_Error.Malformed_Tree)
	testing.expect_value(t, len(drifted), 0)
	testing.expect(t, verdict.offender != "", "Malformed_Tree carries the project_refusal_message offender")
}

@(test)
test_fmt_drift_parse_error_refuses :: proc(t: ^testing.T) {
	root, ok := write_broken_pong_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	drifted, verdict := fmt_drift(root, context.temp_allocator)
	testing.expect_value(t, verdict.err, Fmt_Error.Parse_Failed)
	testing.expect_value(t, len(drifted), 0)
	testing.expect(t, strings.contains(verdict.offender, "pong.fun"), "Parse_Failed offender names the offending source path")
}

@(test)
test_fmt_check_drift_exits_one_without_writing :: proc(t: ^testing.T) {
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
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

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
	old := "a\nb\nc\nd\ne\n"
	new := "a\nb\nX\nd\ne\n"
	diff := unified_diff("src/x.fun", old, new, context.temp_allocator)
	testing.expect(t, strings.contains(diff, "--- src/x.fun\n"))
	testing.expect(t, strings.contains(diff, "+++ src/x.fun\n"))
	testing.expect(t, strings.contains(diff, "@@ -1,5 +1,5 @@\n"))
	testing.expect(t, strings.contains(diff, "-c\n"))
	testing.expect(t, strings.contains(diff, "+X\n"))
	testing.expect(t, strings.contains(diff, " a\n"))
	testing.expect(t, strings.contains(diff, " e\n"))
}

@(test)
test_unified_diff_is_deterministic :: proc(t: ^testing.T) {
	old := "one\ntwo\nthree\n"
	new := "one\n2\nthree\n"
	first := unified_diff("p", old, new, context.temp_allocator)
	second := unified_diff("p", old, new, context.temp_allocator)
	testing.expect_value(t, first, second)
	testing.expect_value(t, unified_diff("p", old, old, context.temp_allocator), "")
}

@(test)
test_unified_diff_marks_missing_final_newline :: proc(t: ^testing.T) {
	old := "x\ny"
	new := "x\ny\n"
	diff := unified_diff("p", old, new, context.temp_allocator)
	testing.expect(t, strings.contains(diff, "\\ No newline at end of file\n"))
}

@(test)
test_fmt_check_drift_prints_diff_body :: proc(t: ^testing.T) {
	source, ok := fmt_source(MINI_SOURCE)
	testing.expect_value(t, ok, Parse_Error.None)
	diff := unified_diff("src/mini.fun", MINI_SOURCE, source, context.temp_allocator)
	testing.expect(t, strings.contains(diff, "@@ "))
	testing.expect(t, len(diff) > 0)
}
