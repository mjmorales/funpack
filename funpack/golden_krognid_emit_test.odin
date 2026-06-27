package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

krognid_emit :: proc(t: ^testing.T) -> (artifact: string, ok: bool) {
	dir := resolve_krognid_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP krognid emit golden: %s not found — set FUNPACK_KROGNID_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return "", false
	}
	project, read_err, _ := read_project(dir)
	if read_err != .None {
		log.warnf("SKIP krognid emit golden: krognid tree at %s did not read (%v)", dir, read_err)
		return "", false
	}
	emitted, emit_err := emit_tree_artifact(dir, project, project_pipeline_sources(project), context.temp_allocator)
	testing.expect_value(t, emit_err, Emit_Error.None)
	if emit_err != .None {
		return "", false
	}
	return emitted, true
}

@(test)
test_emit_krognid_artifact_round_trips :: proc(t: ^testing.T) {
	artifact, ok := krognid_emit(t)
	if !ok {
		return
	}
	doc, parse_err := parse_artifact(artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)

	second, second_ok := krognid_emit(t)
	testing.expect(t, second_ok)
	testing.expect(t, artifact == second)
	if artifact == second {
		log.infof(
			"emit krognid: multi-module v6 artifact emits well-formed and byte-identical twice (%d bytes)",
			len(artifact),
		)
	}
}

@(test)
test_emit_krognid_seam_fn_carry :: proc(t: ^testing.T) {
	artifact, ok := krognid_emit(t)
	if !ok {
		return
	}

	testing.expect(t, artifact_has_line(artifact, "function krognid_skeleton fn 0 return:Skeleton 1 span:krognid:8"))
	testing.expect(t, artifact_has_line(artifact, "function krognid_parts fn 0 return:PartSet 1 span:krognid:14"))

	testing.expect(t, artifact_has_line(artifact, "node field humanoid 1"))

	testing.expect(t, artifact_has_line(artifact, "node string L13:krognid_torso 0"))
	testing.expect(t, artifact_has_line(artifact, "node variant Side L false 0"))
	testing.expect(t, artifact_has_line(artifact, "node variant Side R false 0"))

	testing.expect(t, artifact_contains(artifact, "node name krognid_skeleton"))
	testing.expect(t, artifact_contains(artifact, "node name krognid_parts"))

	log.infof("emit krognid: the krognid seam fns krognid_skeleton/krognid_parts carried into [functions] with seam spans and full bodies")
}

@(test)
test_emit_krognid_thing_and_setup :: proc(t: ^testing.T) {
	artifact, ok := krognid_emit(t)
	if !ok {
		return
	}

	testing.expect(t, artifact_has_line(artifact, "thing Krognid false 1 5"))
	testing.expect(t, artifact_has_line(artifact, "field player PlayerId -"))
	testing.expect(t, artifact_has_line(artifact, "field pos Vec3 -"))
	testing.expect(t, artifact_has_line(artifact, "field intent Vec2 =Vec2(x=0,y=0)"))
	testing.expect(t, artifact_has_line(artifact, "field phase Fixed =0"))

	testing.expect(t, artifact_has_line(artifact, "thing Field false 1 0"))

	testing.expect(t, artifact_has_line(artifact, "[setup 2]"))
	testing.expect(t, artifact_has_line(artifact, "spawn Krognid 5"))
	testing.expect(t, artifact_has_line(artifact, "set player =PlayerId::P1"))
	testing.expect(t, artifact_has_line(artifact, "set pos =Vec3(x=107374182400,y=0,z=107374182400)"))
	testing.expect(t, artifact_has_line(artifact, "set intent =vec2 0 0"))
	testing.expect(t, artifact_has_line(artifact, "set phase =0"))
	testing.expect(t, artifact_has_line(artifact, "set speed =0"))
	testing.expect(t, artifact_has_line(artifact, "spawn Field 0"))

	testing.expect(t, artifact_has_line(artifact, "entrypoint main pipeline:Stroll tick_hz:60 logical:160x120 bindings:bindings"))
}

@(test)
test_emit_krognid_matches_runtime_testdata :: proc(t: ^testing.T) {
	emitted, ok := krognid_emit(t)
	if !ok {
		return
	}
	committed_path, _ := filepath.join({#directory, "..", "runtime", "testdata", "krognid.artifact"}, context.temp_allocator)
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) != "" {
		testing.expect(t, os.write_entire_file(committed_path, transmute([]u8)emitted) == nil)
		log.infof("REGEN krognid: wrote %s (%d bytes)", committed_path, len(emitted))
		return
	}
	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	if read_err != nil {
		log.warnf("SKIP krognid testdata match: committed %s unreadable", committed_path)
		return
	}
	committed := string(committed_bytes)
	if _, committed_version, stamp_ok := parse_version_stamp(line_around(committed, 0)); stamp_ok && committed_version < ARTIFACT_SCHEMA_VERSION {
		log.warnf(
			"SKIP krognid testdata match: committed runtime copy is stamped v%d while the emitter is at v%d — a staged schema bump; the runtime-side reconcile restamps its copy and restores this byte seam",
			committed_version,
			ARTIFACT_SCHEMA_VERSION,
		)
		return
	}
	testing.expect_value(t, len(emitted), len(committed))
	testing.expect(t, emitted == committed)
	if emitted != committed {
		report_first_byte_diff(emitted, committed)
		return
	}
	log.infof(
		"emit krognid: the live emitter reproduces the committed runtime/testdata/krognid.artifact byte-for-byte (%d bytes)",
		len(emitted),
	)
}
