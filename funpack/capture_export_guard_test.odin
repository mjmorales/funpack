// The cross-product guard for the §28 §5 capture → test loop: the runtime
// exporter's capture goldens are byte-pinned runtime-side as committed copies
// under runtime/testdata/capture_*.fun (its lockstep pin keeps the live
// exporter byte-equal to those files), and THIS side proves the compiler
// agrees — every committed export parses as funpack source, and against the
// live example projects it evaluates as a passing test block. Without it the
// byte-pin and the parser can drift apart silently: an exporter rendering a
// form the grammar later drops (or never admitted) keeps its runtime pin
// green while the exported "runnable regression test" stops being runnable.
package funpack

import "core:os"
import "core:strings"
import "core:testing"

// CAPTURE_EXPORT_PATHS lists every committed capture-export copy, relative
// to the funpack package (the test cwd) — in-repo, so unlike the example
// goldens these never SKIP.
CAPTURE_EXPORT_PATHS :: [?]string {
	"../runtime/testdata/capture_snake_eat.fun",
	"../runtime/testdata/capture_snake_turn.fun",
	"../runtime/testdata/capture_pong_paddle_bounce.fun",
}

// read_capture_export reads one committed copy; a missing file is a hard
// failure (the seam file is committed beside this test, not an optional
// sibling checkout).
@(private = "file")
read_capture_export :: proc(t: ^testing.T, path: string) -> (source: string, ok: bool) {
	bytes, err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expectf(t, err == nil, "committed capture export must read: %s", path)
	if err != nil {
		return "", false
	}
	return string(bytes), true
}

@(test)
test_capture_export_goldens_parse :: proc(t: ^testing.T) {
	// Every committed export is one @doc'd test block of funpack SOURCE —
	// the §28 §5 contract ("indistinguishable from a hand-written test")
	// holds at the grammar level with no example checkout in the loop.
	for path in CAPTURE_EXPORT_PATHS {
		source, ok := read_capture_export(t, path)
		if !ok {
			continue
		}
		ast, parse_err := stage_parse(stage_lex(source))
		testing.expect_value(t, parse_err, Parse_Error.None)
		testing.expect_value(t, len(ast.tests), 1)
	}
}

@(test)
test_capture_export_goldens_run_against_snake :: proc(t: ^testing.T) {
	// The two snake captures appended to the live snake example must pass
	// under the full pipeline — the exported expectation re-evaluates to
	// itself, so the exporter's fixtures (record literals, View.of, the
	// Input producer chain) and the evaluator agree. SKIPs with the example
	// goldens' sibling-checkout semantics.
	source, ok := snake_source()
	if !ok {
		return
	}
	eat, eat_ok := read_capture_export(t, "../runtime/testdata/capture_snake_eat.fun")
	turn, turn_ok := read_capture_export(t, "../runtime/testdata/capture_snake_turn.fun")
	if !eat_ok || !turn_ok {
		return
	}
	combined := strings.concatenate({source, "\n", eat, "\n", turn}, context.temp_allocator)
	report, err := run_test_pipeline(combined)
	testing.expect_value(t, err, Pipeline_Error.None)
	// The snake example's four inline asserts plus the two captured ones.
	testing.expect_value(t, report.passed, 6)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_capture_export_goldens_run_against_pong :: proc(t: ^testing.T) {
	// The pong capture exercises the exporter's exact-dyadic Fixed render
	// (Q32.32 fractions, 25+ decimal digits) and a multi-row View.of — the
	// literals must round-trip through fixed_from_decimal to the captured
	// bits for the assert to pass.
	source, ok := pong_source()
	if !ok {
		return
	}
	bounce, bounce_ok := read_capture_export(t, "../runtime/testdata/capture_pong_paddle_bounce.fun")
	if !bounce_ok {
		return
	}
	combined := strings.concatenate({source, "\n", bounce}, context.temp_allocator)
	report, err := run_test_pipeline(combined)
	testing.expect_value(t, err, Pipeline_Error.None)
	// The pong example's eight inline asserts plus the captured one.
	testing.expect_value(t, report.passed, 9)
	testing.expect_value(t, report.failed, 0)
}
