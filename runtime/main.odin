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
when #config(FUNPACK_LIVE, false) {
	main :: proc() {
		os.exit(run_live_session(os.args))
	}
} else {
	main :: proc() {
	}
}
