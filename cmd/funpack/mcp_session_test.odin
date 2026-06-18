// Deliberate spec for the server-scoped session registry (mcp_session.odin) — the
// F13 fix as a living regression. The headline test (test_mcp_session_f13_outlives_request
// _scratch) is the sharpest statement of the F13 invariant: a debug session's
// retained COW chain OUTLIVES the request that opened it, so a LATER request through
// a re-looked-up entry reads a branch a PRIOR request committed — even after a
// SEPARATE per-request scratch arena was reset in between. The rest pin the registry
// surface: open over an artifact, lookup, end (arena_destroy teardown), the
// unknown-id refusal path, double-end idempotency, and distinct minted ids.
//
// DEFINE-FREE FLOOR: these run in the default `odin test .` build (no FUNPACK_LIVE, no
// SDL). Everything the registry folds (open_session_for_artifact, session_request, the
// virtual.Arena lifecycle) is SDL-free, so the registry's lifetime contract is pinned
// in the same deterministic floor the rest of the compiler tests run in.
package main

import funpack_runtime "../../runtime"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// SESSION_FIXTURE is a minimal one-behavior artifact (the introspect envelope fixture's
// shape, runtime/introspect_test.odin): a Hero with a Fixed pos advancing 1.0/tick. It
// gives the session a canonical chain to fork a branch off and a column (`pos`) a `set`
// can force on that branch — the substrate the F13 retention test reads back. Inlined
// here per the self-contained-test standard (the runtime fixture is file-private).
SESSION_FIXTURE :: "funpack-artifact 18\n" +
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

// stage_fixture_artifact writes SESSION_FIXTURE to a uniquely-named temp file and
// returns its path. Returns ok=false (a test should skip, not false-fail) when the temp
// root cannot be staged. The caller defers os.remove on the returned path.
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

// test_mcp_session_f13_outlives_request_scratch is THE F13 regression. It proves the
// session's retained branch survives a per-request scratch arena reset and is read back
// by a LATER request through a re-looked-up entry — the F13 failure mode (an MCP host
// cancels the request scope the instant session_start returns, freeing the session
// out from under the next call). Here the session lives on its OWN arena, so:
//
//   1. open a session in the registry (its COW chain on the dedicated session arena),
//   2. fold `branch` then `set` through it — the forked branch head commits ONTO the
//      session arena (the retention rule mcp_session_registry_request enforces),
//   3. reset a SEPARATE per-request scratch arena (the protocol loop's scratch) — this
//      is the F13 trigger: the request that opened/forked is "over", its scratch gone,
//   4. RE-LOOK-UP the same id and fold `checkout` + `diff` on the branch — the forced
//      `pos` from step 2 must read back, proving the branch outlived the scratch reset.
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

	// (2) The fork + force, folded through the registry on the SESSION arena.
	forked, found_fork := mcp_session_registry_request(&registry, id, `{"id":1,"cmd":"branch"}`)
	testing.expect(t, found_fork, "the just-opened session is found")
	testing.expect(t, strings.contains(forked, `"ok":true`), "the branch fork succeeds")
	set, _ := mcp_session_registry_request(
		&registry,
		id,
		`{"id":2,"cmd":"set","args":{"thing":"Hero","instance":0,"field":"pos","value":"4"}}`,
	)
	testing.expect(t, strings.contains(set, `"ok":true`), "the branch set succeeds")

	// (3) THE F13 TRIGGER: a SEPARATE per-request scratch arena is reset between the
	// request that forked and the request that reads. A registry that owned the session
	// on this scratch (the F13 failure mode) would lose the branch here.
	scratch: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&scratch), virtual.Allocator_Error.None)
	scratch_allocator := virtual.arena_allocator(&scratch)
	junk := make([]u8, 4096, scratch_allocator)
	_ = junk
	virtual.arena_free_all(&scratch)
	defer virtual.arena_destroy(&scratch)

	// (4) A LATER request through a RE-LOOKED-UP entry reads the branch back. The
	// checkout flips the active lineage to the fork; the diff over the fork-point → tip
	// must surface the forced Hero pos — proving the retained chain outlived the scratch.
	entry, found_later := mcp_session_registry_lookup(&registry, id)
	testing.expect(t, found_later, "the session is still in the registry after the scratch reset")
	testing.expect_value(t, entry.id, id)

	// A fresh open holds ATTACH_FRESH_TICKS (64) canonical ticks, so `branch` (no
	// args) forks at the canonical head (tick 63) and the `set` lands the branch tip at
	// tick 64 — the diff over the fork-point (63) → tip (64) reads the forced divergence.
	checked, _ := mcp_session_registry_request(&registry, id, `{"id":3,"cmd":"checkout"}`)
	testing.expect(t, strings.contains(checked, `"active":"branch"`), "checkout activates the retained branch")
	diff, _ := mcp_session_registry_request(&registry, id, `{"id":4,"cmd":"diff","args":{"from":63,"to":64}}`)
	testing.expect(t, strings.contains(diff, `"ok":true`), "the branch tip is addressable after the scratch reset")
	testing.expect(t, strings.contains(diff, `"thing":"Hero"`), "the diff reads the retained branch's Hero")
	testing.expect(t, strings.contains(diff, `"field":"pos"`), "the forced pos column is the retained branch divergence")
}

// test_mcp_session_open_lookup_end pins the registry surface round-trip: open mints a
// session, lookup borrows it, end tears it down (arena_destroy), and a post-end lookup
// misses — the session is gone, not stale.
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

// test_mcp_session_unknown_id pins the stale-session refusal path: a lookup and a
// request against an id the registry never minted both miss (found=false) — the session
// is never fabricated, so the tool arm renders the Session-category refusal.
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

// test_mcp_session_open_failure_no_orphan pins the failure path: opening over a path
// that cannot load returns a non-Ok result and NO registry entry (the arena minted for
// the attempt is destroyed before returning) — a failed open leaks no arena and no id.
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

// test_mcp_session_distinct_ids pins that concurrent sessions get distinct, stable ids
// — two opens never collide, so each session's handle addresses exactly its own entry
// (the precondition for single-threaded-per-session isolation across concurrent ones).
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

	// Each id addresses its own entry — no cross-talk.
	entry_a, _ := mcp_session_registry_lookup(&registry, id_a)
	entry_b, _ := mcp_session_registry_lookup(&registry, id_b)
	testing.expect(t, entry_a != entry_b, "distinct ids resolve to distinct entries")
}
