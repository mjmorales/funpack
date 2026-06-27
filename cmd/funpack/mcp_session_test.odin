package main

import funpack_runtime "../../runtime"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

SESSION_FIXTURE :: "funpack-artifact 19\n" +
	"[meta 2]\n" +
	"project introspect\n" +
	"version L5:0.1.0\n" +
	"[data 2]\n" +
	"data Stats 2 false\n" +
	"field hp Int -\n" +
	"field mana Int -\n" +
	"data Coord 1 false\n" +
	"field v Int -\n" +
	"[things 1]\n" +
	"thing Hero false 0 4\n" +
	"field pos Fixed =0\n" +
	"field stats Stats =Stats(hp=10,mana=4)\n" +
	"field home Coord =Coord(v=5)\n" +
	"field score Int =0\n" +
	"[behaviors 1]\n" +
	"behavior advance on:Hero stage:control contract:Update 0 1 1 1\n" +
	"param self Hero\n" +
	"emit Hero\n" +
	"node return 1\n" +
	"node with 1 2\n" +
	"node name self 0\n" +
	"node recfield pos 1\n" +
	"node binary add 2\n" +
	"node field pos 1\n" +
	"node name self 0\n" +
	"node fixed 4294967296 0\n" +
	"[pipeline_flattened 1]\n" +
	"step 0 stage:control behavior:advance\n" +
	"[setup 1]\n" +
	"spawn Hero 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Intro tick_hz:60 logical:160x120 bindings:bindings\n"

@(private = "file")
stage_fixture_artifact :: proc(t: ^testing.T, name: string) -> (path: string, ok: bool) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	path, _ = filepath.join({base, name}, context.temp_allocator)
	if write_err := os.write_entire_file(path, SESSION_FIXTURE); write_err != nil {
		return "", false
	}
	return path, true
}

@(test)
test_mcp_session_f13_outlives_request_scratch :: proc(t: ^testing.T) {
	path, staged := stage_fixture_artifact(t, "funpack-mcp-f13-session.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)
	testing.expect(t, id != "", "an opened session mints a non-empty id")

	forked, found_fork := mcp_session_registry_request(&registry, id, `{"id":1,"cmd":"branch"}`)
	testing.expect(t, found_fork, "the just-opened session is found")
	testing.expect(t, strings.contains(forked, `"ok":true`), "the branch fork succeeds")
	set, _ := mcp_session_registry_request(
		&registry,
		id,
		`{"id":2,"cmd":"set","args":{"thing":"Hero","instance":0,"field":"pos","value":"4"}}`,
	)
	testing.expect(t, strings.contains(set, `"ok":true`), "the branch set succeeds")

	scratch: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&scratch), virtual.Allocator_Error.None)
	scratch_allocator := virtual.arena_allocator(&scratch)
	junk := make([]u8, 4096, scratch_allocator)
	_ = junk
	virtual.arena_free_all(&scratch)
	defer virtual.arena_destroy(&scratch)

	entry, found_later := mcp_session_registry_lookup(&registry, id)
	testing.expect(t, found_later, "the session is still in the registry after the scratch reset")
	testing.expect_value(t, entry.id, id)

	checked, _ := mcp_session_registry_request(&registry, id, `{"id":3,"cmd":"checkout"}`)
	testing.expect(t, strings.contains(checked, `"active":"branch"`), "checkout activates the retained branch")
	diff, _ := mcp_session_registry_request(&registry, id, `{"id":4,"cmd":"diff","args":{"from":63,"to":64}}`)
	testing.expect(t, strings.contains(diff, `"ok":true`), "the branch tip is addressable after the scratch reset")
	testing.expect(t, strings.contains(diff, `"thing":"Hero"`), "the diff reads the retained branch's Hero")
	testing.expect(t, strings.contains(diff, `"field":"pos"`), "the forced pos column is the retained branch divergence")
}

@(test)
test_mcp_session_open_lookup_end :: proc(t: ^testing.T) {
	path, staged := stage_fixture_artifact(t, "funpack-mcp-roundtrip-session.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	id, open_result := mcp_session_registry_open(&registry, path, "", false, "pong-debug", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	entry, found := mcp_session_registry_lookup(&registry, id)
	testing.expect(t, found, "an open session is found by its id")
	testing.expect_value(t, entry.label, "pong-debug")
	testing.expect(t, entry.program != nil, "the session borrows a live program")

	ended := mcp_session_registry_end(&registry, id, context.temp_allocator)
	testing.expect(t, ended, "ending a live session reports found=true")
	_, found_after := mcp_session_registry_lookup(&registry, id)
	testing.expect(t, !found_after, "an ended session is gone from the registry")
}

@(test)
test_mcp_session_unknown_id :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	_, found := mcp_session_registry_lookup(&registry, "sess-999")
	testing.expect(t, !found, "an unknown id is not found")
	_, req_found := mcp_session_registry_request(&registry, "sess-999", `{"id":1,"cmd":"pipeline"}`)
	testing.expect(t, !req_found, "a request against an unknown id misses, never fabricating a session")
	ended := mcp_session_registry_end(&registry, "sess-999", context.temp_allocator)
	testing.expect(t, !ended, "ending an unknown id is a clean no-op, not a fault")
}

@(test)
test_mcp_session_open_failure_no_orphan :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	id, open_result := mcp_session_registry_open(
		&registry,
		"/nonexistent/funpack-mcp-no-such-artifact.fpk",
		"",
		false,
		"",
		context.temp_allocator,
	)
	testing.expect(t, open_result != .Ok, "opening a missing artifact fails")
	testing.expect_value(t, id, "")
	testing.expect_value(t, len(registry.entries), 0)
}

@(test)
test_mcp_session_distinct_ids :: proc(t: ^testing.T) {
	path, staged := stage_fixture_artifact(t, "funpack-mcp-distinct-session.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	id_a, result_a := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	id_b, result_b := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, result_a, funpack_runtime.Open_Session_Result.Ok)
	testing.expect_value(t, result_b, funpack_runtime.Open_Session_Result.Ok)
	testing.expect(t, id_a != id_b, "two concurrent sessions mint distinct ids")
	testing.expect_value(t, len(registry.entries), 2)

	entry_a, _ := mcp_session_registry_lookup(&registry, id_a)
	entry_b, _ := mcp_session_registry_lookup(&registry, id_b)
	testing.expect(t, entry_a != entry_b, "distinct ids resolve to distinct entries")
}
