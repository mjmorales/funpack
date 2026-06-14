// Junction tests for the PURE parts of the `funpack run` verb: the funpack-live
// location strategy (resolve_funpack_live — sibling-of-argv0, PATH fallback,
// not-found) and the entrypoint-selection adjudication (run_select_entrypoint).
// The impure half (the actual process spawn that opens a window) is verified
// manually, not unit-tested — these cover everything that decides WHAT to spawn
// and WHETHER it can run, without touching a real filesystem (the probe is faked).
package funpack

import "core:testing"

// run_test_probe is the test Funpack_Live_Probe: it reports whether `path` is in
// the runnable set threaded through context.user_ptr — the fake stand-in for
// funpack_live_is_runnable's os.is_file. The set rides the context (NOT a shared
// package global) so the parallel test runner never races: each test owns its own
// set and points context.user_ptr at it for the duration of the resolver call,
// making resolve_funpack_live's candidate order provable deterministically and in
// isolation.
@(private = "file")
run_test_probe :: proc(path: string) -> bool {
	set := (^map[string]bool)(context.user_ptr)
	if set == nil {
		return false
	}
	return set^[path]
}

// test_resolve_funpack_live_sibling pins the FIRST resolution rule: a funpack-live
// sitting beside the running funpack binary (dirname(argv0)/funpack-live) wins,
// even when PATH also holds one — the release-dist layout where both binaries ship
// in the same directory.
@(test)
test_resolve_funpack_live_sibling :: proc(t: ^testing.T) {
	runnable := make(map[string]bool, context.temp_allocator)
	runnable["/opt/funpack/funpack-live"] = true
	runnable["/usr/local/bin/funpack-live"] = true // also on PATH
	context.user_ptr = &runnable

	loc := resolve_funpack_live(
		"/opt/funpack/funpack",
		"/usr/local/bin:/usr/bin",
		run_test_probe,
		context.temp_allocator,
	)
	testing.expect(t, loc.found, "the sibling funpack-live must resolve")
	testing.expect_value(t, loc.path, "/opt/funpack/funpack-live")
}

// test_resolve_funpack_live_path_fallback pins the SECOND rule: when no sibling
// exists (the sibling candidate is not runnable), the resolver scans PATH in order
// and returns the first entry holding a runnable funpack-live.
@(test)
test_resolve_funpack_live_path_fallback :: proc(t: ^testing.T) {
	runnable := make(map[string]bool, context.temp_allocator)
	// No sibling: /opt/funpack/funpack-live is absent. Two PATH entries hold one;
	// the FIRST in scan order must win.
	runnable["/usr/local/bin/funpack-live"] = true
	runnable["/usr/bin/funpack-live"] = true
	context.user_ptr = &runnable

	loc := resolve_funpack_live(
		"/opt/funpack/funpack",
		"/usr/local/bin:/usr/bin",
		run_test_probe,
		context.temp_allocator,
	)
	testing.expect(t, loc.found, "a PATH funpack-live must resolve when no sibling exists")
	testing.expect_value(t, loc.path, "/usr/local/bin/funpack-live")
}

// test_resolve_funpack_live_not_found pins the not-found tier: neither the sibling
// nor any PATH entry holds a runnable funpack-live, so the resolver reports
// found = false (the caller then prints the direct-invocation fix-it and exits 1).
@(test)
test_resolve_funpack_live_not_found :: proc(t: ^testing.T) {
	runnable := make(map[string]bool, context.temp_allocator) // empty: nothing runnable
	context.user_ptr = &runnable
	loc := resolve_funpack_live(
		"/opt/funpack/funpack",
		"/usr/local/bin:/usr/bin",
		run_test_probe,
		context.temp_allocator,
	)
	testing.expect(t, !loc.found, "no runnable funpack-live ⇒ not found")
	testing.expect_value(t, loc.path, "")

	// An empty argv0 and empty PATH also resolve to not-found, never a crash.
	loc = resolve_funpack_live("", "", run_test_probe, context.temp_allocator)
	testing.expect(t, !loc.found, "empty argv0 + empty PATH ⇒ not found")

	// A nil probe (defensive) treats every candidate as a miss.
	loc = resolve_funpack_live("/opt/funpack/funpack", "/usr/bin", nil, context.temp_allocator)
	testing.expect(t, !loc.found, "a nil probe ⇒ not found")
}

// test_resolve_funpack_live_bare_argv0 pins the no-directory argv0 case: a funpack
// launched as a bare `funpack` (resolved off PATH, no separator in argv0) has its
// sibling candidate fall to the bare "funpack-live" (a cwd-relative path, since
// filepath.dir of a separator-less name is ""); when that is runnable it resolves
// (launched from its own directory), and otherwise the PATH scan decides.
@(test)
test_resolve_funpack_live_bare_argv0 :: proc(t: ^testing.T) {
	runnable := make(map[string]bool, context.temp_allocator)
	runnable["funpack-live"] = true
	context.user_ptr = &runnable

	loc := resolve_funpack_live("funpack", "/usr/bin", run_test_probe, context.temp_allocator)
	testing.expect(t, loc.found, "a bare-argv0 sibling resolves to the cwd funpack-live when present")
	testing.expect_value(t, loc.path, "funpack-live")
}

// test_run_select_entrypoint pins the [name] adjudication: no name ("") is the
// honored implicit single-entrypoint default; a NAMED pick is refused (the
// multi-entrypoint selection is not yet wired — refused, never silently ignored),
// with the refusal naming the requested entrypoint.
@(test)
test_run_select_entrypoint :: proc(t: ^testing.T) {
	testing.expect_value(t, run_select_entrypoint(""), "")

	refusal := run_select_entrypoint("benchmark")
	testing.expect(t, refusal != "", "a named entrypoint pick is refused (selection unwired)")
	testing.expect(
		t,
		// The refusal must name the requested entrypoint so the user sees what was
		// rejected, not a bare "unsupported".
		contains_substring(refusal, "benchmark"),
		"the refusal names the requested entrypoint",
	)
}

// contains_substring is a tiny test helper: does haystack contain needle? Inlined
// here (not pulled from core:strings) to keep the test self-contained and avoid an
// import this file otherwise does not need.
@(private = "file")
contains_substring :: proc(haystack: string, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle {
			return true
		}
	}
	return false
}
