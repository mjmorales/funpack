// The artifact-emission golden: emitting the pong artifact from the checked
// source must reproduce the committed fixture (testdata/pong.artifact)
// byte-for-byte, and emitting twice must be byte-identical. The fixture is the
// cross-team seam with the runtime's loader (runtime/artifact_load.odin parses
// these exact bytes), so the byte equality is load-bearing — when the spec
// evolves the fixture and this test change in lockstep; never loosen the
// comparison to a substring or a length check. Like the parse/typecheck goldens,
// it resolves the live pong source (or FUNPACK_PONG_DIR) and SKIPs loudly when
// the sibling checkout is absent.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// test_emit_pong_artifact_matches_golden is the load-bearing acceptance: the
// production emitter, run over the live pong source, reproduces the committed
// golden artifact byte-for-byte (docs/artifact-format.md). A diff in any section
// — a count, a node child_count, a span line, a Fixed's raw bits — fails here.
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
	// Announce the byte-for-byte match so a passing run leaves a trace the
	// acceptance gate can read — odin test echoes a test name only on failure,
	// so success is logged explicitly.
	log.infof("emit golden: pong artifact reproduces the golden fixture byte-for-byte (%d bytes)", len(emitted))
}

// test_emit_pong_artifact_double_emit_identical proves emission is deterministic
// (spec §09, §29): two emissions from the same source are byte-identical, so the
// artifact carries no field whose value depends on when, where, or on which
// machine it was emitted.
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
		// Log the deterministic result so a passing run leaves a trace the
		// acceptance gate can read (odin test echoes a name only on failure).
		log.infof("double emit: two pong emissions are byte-identical (deterministic emit, %d bytes)", len(first))
	}
}

// Pong_Emit_Inputs bundles the pure inputs the emitter consumes for the pong
// project: the single source's bytes, its §15 module name, the §14 project
// identity, and the §14 entrypoints.fcfg text.
Pong_Emit_Inputs :: struct {
	source:          string,
	module:          string,
	project:         Project_Identity,
	entrypoint_fcfg: string,
}

// pong_emit_inputs resolves the pong project tree and reads the emitter's
// inputs. ok = false (with the golden's SKIP semantics through pong_source) when
// the sibling checkout is absent.
pong_emit_inputs :: proc(t: ^testing.T) -> (inputs: Pong_Emit_Inputs, ok: bool) {
	dir := resolve_pong_dir()
	if !os.is_dir(dir) {
		// pong_source emits the SKIP warning; call it for the side effect and
		// the shared absence check.
		_, present := pong_source()
		_ = present
		return Pong_Emit_Inputs{}, false
	}
	project, read_err := read_project(dir)
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

// emit_pong_and_load_golden emits the pong artifact and reads the committed
// golden fixture for comparison. The fixture is located relative to this test
// file's directory (#directory = funpack/), so it is the in-repo committed
// bytes, never a regenerated copy. ok = false on a SKIP or any read failure.
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

// report_first_byte_diff logs the first byte index where the emitted artifact
// diverges from the golden, with the surrounding line context, so a byte
// mismatch points straight at the offending section rather than just failing
// the equality. It runs only on a failing comparison.
report_first_byte_diff :: proc(emitted: string, golden: string) {
	limit := min(len(emitted), len(golden))
	for i in 0 ..< limit {
		if emitted[i] != golden[i] {
			log.errorf(
				"first byte diff at %d: emitted line %q vs golden line %q",
				i,
				line_around(emitted, i),
				line_around(golden, i),
			)
			return
		}
	}
	log.errorf("artifacts agree on first %d bytes but differ in length (emitted %d, golden %d)", limit, len(emitted), len(golden))
}

// line_around returns the whole line containing byte index i, so a diff report
// shows the offending record rather than a bare byte.
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
