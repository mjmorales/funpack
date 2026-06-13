// runtime — executes the compiled artifact; the execution-side impure
// consumer of the pure compiler's output (spec §29, §09). Package is
// named funpack_runtime because Odin reserves `runtime` (base:runtime);
// the directory and binary keep the product name.
package funpack_runtime

import "core:os"

// MAIN_OS_ALIVE keeps the core:os import referenced OUTSIDE the when-gated dispatch
// so a headless build's -vet does not flag it as unused — os.args/os.exit are only
// reached under FUNPACK_LIVE, and an import cannot itself sit inside a `when`. The
// alias emits no code (it is a type alias, dead-stripped), so the default binary
// pulls nothing extra; this mirrors session_live.odin's SDL/fmt/os alias discipline.
MAIN_OS_ALIVE :: os.Error

// main dispatches by build: under -define:FUNPACK_LIVE=true it runs the live SDL
// session (run_live_session, gated in session_live.odin) over the process args and
// exits with its return code; the default (headless/test/CI) build keeps the no-op
// stub so the deterministic suite links no SDL symbol. The when-clause is the
// single dispatch — the live entry exists only when the define compiles its block.
//
// The one localized verb arm: `funpack-live attach <artifact> …` opens a §28
// introspection session and serves it on the auth-gated loopback port
// (run_attach_session, gated in introspect_attach.odin) instead of the SDL window —
// the §28.2 remote-attach CLI entry. Every other argv runs the live SDL session
// unchanged, so the verb is a single localized branch, never a CLI restructure.
when #config(FUNPACK_LIVE, false) {
	main :: proc() {
		if len(os.args) >= 2 && os.args[1] == "attach" {
			os.exit(run_attach_session(os.args))
		}
		os.exit(run_live_session(os.args))
	}
} else {
	main :: proc() {
	}
}
