package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_emit_pong_artifact_matches_golden :: proc(t: ^testing.T) {
	emitted, golden, ok := emit_pong_and_load_golden(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(emitted), len(golden))
	testing.expect(t, emitted == golden)
	if emitted != golden {
		report_first_byte_diff(emitted, golden)
		return
	}
	log.infof("emit golden: pong artifact reproduces the golden fixture byte-for-byte (%d bytes)", len(emitted))
}

@(test)
test_emit_pong_artifact_double_emit_identical :: proc(t: ^testing.T) {
	inputs, ok := pong_emit_inputs(t)
	if !ok {
		return
	}
	first, first_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, first_err, Emit_Error.None)
	second, second_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, second_err, Emit_Error.None)
	testing.expect(t, first == second)
	if first == second {
		log.infof("double emit: two pong emissions are byte-identical (deterministic emit, %d bytes)", len(first))
	}
}

@(test)
test_emit_snake_artifact_schema_v2_round_trips :: proc(t: ^testing.T) {
	inputs, ok := snake_emit_inputs(t)
	if !ok {
		return
	}
	artifact, emit_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, emit_err, Emit_Error.None)
	if emit_err != .None {
		return
	}
	doc, parse_err := parse_artifact(artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)
	second, second_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, second_err, Emit_Error.None)
	testing.expect(t, artifact == second)
	if artifact == second {
		log.infof("emit snake: schema-v2 artifact emits well-formed and byte-identical twice (%d bytes)", len(artifact))
	}
}

@(test)
test_emit_schema_v2_tuple_arm_body_forest_round_trips :: proc(t: ^testing.T) {
	source := strings.concatenate({SCHEMA_V2_TUPLE_HEADER,
		"behavior replenish on Snake {\n" +
		"  fn step(self: Snake, rng: Rng) -> (Rng, [Spawn]) {\n" +
		"    return match rng.pick(self.free) {\n" +
		"      (Option::Some(cell), next) => (next, [Spawn( Food{cell: cell} )])\n" +
		"      (Option::None, next) => (next, [])\n" +
		"    }\n" +
		"  }\n" +
		"}\n"}, context.temp_allocator)
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	behavior, found := find_behavior(ast, "replenish")
	testing.expect(t, found)
	if !found {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	emit_body(&b, behavior.step.body)
	nodes := split_artifact_lines(strings.to_string(b))
	testing.expect(t, body_forest_is_well_formed(nodes, len(behavior.step.body)))
}

SCHEMA_V2_TUPLE_HEADER :: "import engine.world.{Spawn}\n" +
	"import engine.rand.{Rng, pick}\n" +
	"data Cell { x: Int, y: Int }\n" +
	"thing Food { cell: Cell }\n" +
	"thing Snake { free: [Cell] = [] }\n"

Pong_Emit_Inputs :: struct {
	source:          string,
	module:          string,
	project:         Project_Identity,
	entrypoint_fcfg: string,
}

snake_emit_inputs :: proc(t: ^testing.T) -> (inputs: Pong_Emit_Inputs, ok: bool) {
	dir := resolve_snake_dir()
	if !os.is_dir(dir) {
		_, present := snake_source()
		_ = present
		return Pong_Emit_Inputs{}, false
	}
	project, read_err, _ := read_project(dir)
	if read_err != .None || len(project.sources) == 0 {
		return Pong_Emit_Inputs{}, false
	}
	source_bytes, src_err := os.read_entire_file_from_path(project.sources[0].path, context.temp_allocator)
	if src_err != nil {
		return Pong_Emit_Inputs{}, false
	}
	entrypoint_path, _ := filepath.join({dir, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	entrypoint_bytes, ep_err := os.read_entire_file_from_path(entrypoint_path, context.temp_allocator)
	if ep_err != nil {
		return Pong_Emit_Inputs{}, false
	}
	return Pong_Emit_Inputs {
			source          = string(source_bytes),
			module          = project.sources[0].module,
			project         = Project_Identity{name = project.name, version = project.version},
			entrypoint_fcfg = string(entrypoint_bytes),
		},
		true
}

pong_emit_inputs :: proc(t: ^testing.T) -> (inputs: Pong_Emit_Inputs, ok: bool) {
	dir := resolve_pong_dir()
	if !os.is_dir(dir) {
		_, present := pong_source()
		_ = present
		return Pong_Emit_Inputs{}, false
	}
	project, read_err, _ := read_project(dir)
	if read_err != .None || len(project.sources) == 0 {
		return Pong_Emit_Inputs{}, false
	}
	source_bytes, src_err := os.read_entire_file_from_path(project.sources[0].path, context.temp_allocator)
	if src_err != nil {
		return Pong_Emit_Inputs{}, false
	}
	entrypoint_path, _ := filepath.join({dir, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	entrypoint_bytes, ep_err := os.read_entire_file_from_path(entrypoint_path, context.temp_allocator)
	if ep_err != nil {
		return Pong_Emit_Inputs{}, false
	}
	return Pong_Emit_Inputs {
			source          = string(source_bytes),
			module          = project.sources[0].module,
			project         = Project_Identity{name = project.name, version = project.version},
			entrypoint_fcfg = string(entrypoint_bytes),
		},
		true
}

emit_pong_and_load_golden :: proc(t: ^testing.T) -> (emitted: string, golden: string, ok: bool) {
	inputs, have_inputs := pong_emit_inputs(t)
	if !have_inputs {
		return "", "", false
	}
	artifact, emit_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, emit_err, Emit_Error.None)
	if emit_err != .None {
		return "", "", false
	}
	golden_path, _ := filepath.join({#directory, "testdata", "pong.artifact"}, context.temp_allocator)
	golden_bytes, golden_err := os.read_entire_file_from_path(golden_path, context.temp_allocator)
	if golden_err != nil {
		return "", "", false
	}
	return artifact, string(golden_bytes), true
}

report_first_byte_diff :: proc(emitted: string, golden: string) {
	idx := first_byte_diff_index(emitted, golden)
	if idx >= 0 {
		log.errorf(
			"first byte diff at %d: emitted line %q vs golden line %q",
			idx,
			line_around(emitted, idx),
			line_around(golden, idx),
		)
		return
	}
	log.errorf(
		"artifacts agree on first %d bytes but differ in length (emitted %d, golden %d)",
		min(len(emitted), len(golden)),
		len(emitted),
		len(golden),
	)
}

first_byte_diff_index :: proc(a: string, b: string) -> int {
	limit := min(len(a), len(b))
	for i in 0 ..< limit {
		if a[i] != b[i] {
			return i
		}
	}
	return -1
}

line_around :: proc(s: string, i: int) -> string {
	start := i
	for start > 0 && s[start - 1] != '\n' {
		start -= 1
	}
	end := i
	for end < len(s) && s[end] != '\n' {
		end += 1
	}
	return s[start:end]
}
