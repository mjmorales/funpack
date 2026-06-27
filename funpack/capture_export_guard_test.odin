package funpack

import "core:os"
import "core:strings"
import "core:testing"

CAPTURE_EXPORT_PATHS :: [?]string {
	"../runtime/testdata/capture_snake_eat.fun",
	"../runtime/testdata/capture_snake_turn.fun",
	"../runtime/testdata/capture_pong_paddle_bounce.fun",
}

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
	testing.expect_value(t, report.passed, 6)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_capture_export_goldens_run_against_pong :: proc(t: ^testing.T) {
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
	testing.expect_value(t, report.passed, 9)
	testing.expect_value(t, report.failed, 0)
}
