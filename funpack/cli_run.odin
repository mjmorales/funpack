// The `funpack run` verb: build the §14 project tree, then exec the separate
// funpack-live runtime over the freshly-built artifact — the one-command,
// discoverable "build it and play it" path (cargo/go-run semantics) the spec
// §14 §6 envisions ("the invocation selects among committed declarations …
// `funpack run [name]`").
//
// THE PURITY BOUNDARY (spec §29 §1): funpack stays the PURE compiler. The build
// half here is the SAME stage_build the build verb compiles — no clock, no
// network, no SDL linked into this binary. `run` is a CLI-LAYER ORCHESTRATION
// verb: after the pure build, it SPAWNS the separate funpack-live process (which
// links vendor:sdl2 and opens the window). That spawn is exactly the "downstream
// build-driver / CLI concern" §14 §6 carves out from the pure compiler core — so
// this file holds the process spawn while the compile path stays untouched and
// SDL-free. The two-binary split (funpack + funpack-live) the release dist ships
// (release.yml) is the seam this verb bridges.
//
// THE EXEC MECHANISM: core:os process_start + process_wait (NOT a POSIX exec that
// replaces the image). Spawn-and-wait keeps funpack run's own frame alive so it
// RELAYS the child's exit code as its own — process_wait's Process_State.exit_code
// is the child's exit status, and on a signal death it is the signal number, so
// the child's exit code AND signals pass through cleanly (the §29 §3 exit-contract
// requirement). The release targets macOS + Linux only (both POSIX); core:os
// abstracts the spawn over both, so no per-OS branch is needed here.
package funpack

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// FUNPACK_LIVE_BIN is the runtime binary's fixed leaf name — the executable the
// release dist ships beside funpack (release.yml: `cp funpack/funpack
// runtime/funpack-live "$dist"/`). The name is the resolution key for both the
// sibling-of-argv0 lookup and the PATH fallback.
FUNPACK_LIVE_BIN :: "funpack-live"

// Funpack_Live_Probe is the injectable "is this path a runnable file?" predicate
// the pure resolver tests each candidate with. Production passes
// funpack_live_is_runnable (os.is_file); a unit test passes a fake over a known
// candidate set, so resolve_funpack_live is provable without a filesystem. A nil
// probe is treated as "nothing is runnable" (every candidate misses).
Funpack_Live_Probe :: #type proc(path: string) -> bool

// Funpack_Live_Location is the pure resolver's result: the resolved funpack-live
// path and whether resolution succeeded. found = false means neither the sibling
// of the running funpack binary nor any PATH entry holds a runnable funpack-live;
// the caller then prints the not-found fix-it and exits 1.
Funpack_Live_Location :: struct {
	path:  string,
	found: bool,
}

// resolve_funpack_live is the PURE funpack-live location strategy — a function of
// (argv0, PATH, probe) alone, no host state of its own, so it is unit-tested over
// a fake probe. The order matters and mirrors how the release dist lays the two
// binaries out:
//
//  1. SIBLING of the running funpack binary — `dirname(argv0)/funpack-live`. The
//     release tarball puts funpack and funpack-live in the same directory, so a
//     user running the dist's funpack finds the dist's funpack-live next to it
//     first (and a Homebrew install resolves the same way — both live in the
//     formula's bin). argv0 with no directory part (a bare `funpack` resolved off
//     PATH) yields no sibling candidate and falls through.
//  2. PATH fallback — the first `<entry>/funpack-live` that the probe accepts,
//     scanning path_list_sep-split PATH in order. This covers a funpack invoked by
//     an absolute path whose sibling is absent but whose funpack-live is on PATH.
//
// The first candidate the probe accepts wins; an empty argv0 and an empty PATH
// resolve to found = false. Candidates are allocated in `allocator`.
resolve_funpack_live :: proc(
	argv0: string,
	path_env: string,
	probe: Funpack_Live_Probe,
	allocator := context.allocator,
) -> Funpack_Live_Location {
	if probe == nil {
		return Funpack_Live_Location{}
	}
	// 1. Sibling of the running funpack binary. filepath.dir of an argv0 with no
	//    separator is "", so the candidate is the bare "funpack-live" (a relative
	//    path resolved against cwd) — correct when funpack was launched from its
	//    own directory, and harmlessly missing otherwise (the PATH scan then decides).
	if argv0 != "" {
		dir := filepath.dir(argv0)
		sibling, _ := filepath.join({dir, FUNPACK_LIVE_BIN}, allocator)
		if probe(sibling) {
			return Funpack_Live_Location{path = sibling, found = true}
		}
	}
	// 2. PATH fallback: the first entry holding a runnable funpack-live.
	sep := path_list_sep(context.temp_allocator)
	for entry in strings.split(path_env, sep, context.temp_allocator) {
		if entry == "" {
			continue
		}
		candidate, _ := filepath.join({entry, FUNPACK_LIVE_BIN}, allocator)
		if probe(candidate) {
			return Funpack_Live_Location{path = candidate, found = true}
		}
	}
	return Funpack_Live_Location{}
}

// path_list_sep renders os.Path_List_Separator (the OS PATH delimiter rune — ':'
// on the POSIX release targets) as a one-byte string, so strings.split can slice
// PATH on it without hardcoding the byte. The separator is ASCII, so a single u8
// is exact.
path_list_sep :: proc(allocator := context.allocator) -> string {
	return strings.clone_from_bytes([]u8{u8(os.Path_List_Separator)}, allocator)
}

// funpack_live_is_runnable is the production Funpack_Live_Probe: a candidate is
// runnable iff it is an existing regular file. The OS adjudicates the executable
// bit at spawn time (a present-but-non-executable funpack-live surfaces as a spawn
// error the verb reports), so this probe is the cheap "the binary is there" test
// the resolver needs — not a full permission check, which would duplicate the
// kernel's spawn-time decision.
funpack_live_is_runnable :: proc(path: string) -> bool {
	return os.is_file(path)
}

// run_run_verb is the `funpack run [name]` core: BUILD the project tree (the same
// pure stage_build the build verb runs), then EXEC funpack-live over the built
// artifact. It mirrors run_build_verb's structure — the build path is identical,
// so a build that refuses under `funpack build` refuses identically under
// `funpack run`.
//
// THE EXIT CONTRACT (spec §29 §3):
//   - A build/gate/tree refusal is exit 2 with the SAME eprint_build_refusal block
//     build prints (a compile error is never a counted failure).
//   - A host IO failure writing the products is exit 2.
//   - A PACKAGE (no entrypoint ⇒ artifact_path == "") has nothing to run: exit 2
//     with the no-entrypoint fix-it (you cannot run an Index-Contract-only build).
//   - funpack-live unresolvable (no sibling, not on PATH) is exit 1 with the
//     direct-invocation fix-it — distinct from the build-refusal tier because the
//     build SUCCEEDED; the toolchain is merely incomplete.
//   - Otherwise the verb RELAYS funpack-live's own exit code (process_wait's
//     exit_code), so `funpack run`'s exit status IS the game's.
//
// extra_args are the trailing positionals after the optional [name] — forwarded
// verbatim to funpack-live (e.g. a replay-out path: funpack-live's args[2]). mode
// is the Dev/Release flag (`--release`, parity with build); the build half threads
// it through stage_build exactly as build does.
//
// [name] ENTRYPOINT SELECTION (spec §14 §6): the optional positional is accepted
// and forwarded honestly, but multi-entrypoint selection is NOT yet wired in the
// build path (stage_build emits the single entrypoints.fcfg artifact). Rather than
// fake a pick, run_select_entrypoint validates the name against what the build can
// honor and refuses a name the single-artifact path cannot satisfy — keeping the
// signature forward-compatible without lying about selection (the multi-entrypoint
// pick is a tracked follow-up).
run_run_verb :: proc(name: string, extra_args: []string, mode: Build_Mode) -> int {
	// BUILD — the same pure seam the build verb compiles, identical refusal block.
	product, verdict := stage_build(".", mode, context.temp_allocator)
	if verdict.err != .None {
		eprint_build_refusal("funpack run", verdict)
		return 2
	}
	if write_err := write_build_products(product, "."); write_err != .None {
		fmt.eprintfln("funpack run: %v", write_err)
		return 2
	}
	// NO ENTRYPOINT — a package (Index Contract only, §30 §7) has no runtime
	// artifact, so there is nothing to run. Refuse before locating the runtime.
	if product.artifact_path == "" {
		fmt.eprintln("funpack run: nothing to run — this project declares no entrypoint")
		return 2
	}
	// [name] — validate the optional entrypoint pick against what the single-
	// artifact build path can honor (the multi-entrypoint selection is deferred).
	if sel_err := run_select_entrypoint(name); sel_err != "" {
		fmt.eprintfln("funpack run: %s", sel_err)
		return 2
	}
	// LOCATE funpack-live — sibling of the running funpack binary first, PATH
	// fallback second (resolve_funpack_live), over the real filesystem probe.
	argv0 := os.args[0] if len(os.args) > 0 else ""
	location := resolve_funpack_live(
		argv0,
		os.get_env("PATH", context.temp_allocator),
		funpack_live_is_runnable,
		context.temp_allocator,
	)
	if !location.found {
		fmt.eprintfln(
			"funpack run: cannot find the %s runtime; run it directly with: %s %s",
			FUNPACK_LIVE_BIN,
			FUNPACK_LIVE_BIN,
			product.artifact_path,
		)
		return 1
	}
	// EXEC — spawn funpack-live <artifact> [extra_args…], inheriting this
	// process's std streams so the game's window/log lands on the operator's
	// terminal, and RELAY its exit code as our own.
	return exec_funpack_live(location.path, product.artifact_path, extra_args)
}

// run_select_entrypoint adjudicates the optional `funpack run [name]` positional
// against what the build path can honor. The current build emits the single
// entrypoints.fcfg artifact (no multi-entrypoint selection wired), so:
//   - no name ("") is always honored — the implicit single-entrypoint default.
//   - a NAMED pick is refused with a clear "selection not yet supported" message
//     rather than silently ignored, so a user never thinks a name took effect when
//     it did not. (Wiring the named pick is the tracked follow-up.)
// Returns "" when the selection is honorable, else the refusal detail. Pure — a
// function of the name alone — so it is unit-tested without a build.
run_select_entrypoint :: proc(name: string) -> (refusal: string) {
	if name == "" {
		return ""
	}
	return fmt.aprintf(
		"entrypoint selection (run %s) is not yet supported — this build runs its single declared entrypoint; omit the name",
		name,
		allocator = context.temp_allocator,
	)
}

// exec_funpack_live spawns the funpack-live runtime over the artifact and returns
// ITS exit code as funpack run's. It is the IMPURE half this verb owns — the
// process spawn the pure compile path never touches. The child inherits this
// process's stdin/stdout/stderr (os.stdin/stdout/stderr), so funpack-live's
// window and diagnostics render on the operator's terminal exactly as a direct
// invocation would. A spawn failure (funpack-live present but unspawnable — e.g.
// the executable bit unset) is exit 1, the same tier as an unresolved runtime:
// the build succeeded, only the launch did not. process_wait returns the child's
// Process_State.exit_code — the exit status on a clean exit, the signal number on
// a signal death — which becomes funpack run's exit code, so a headless SDL
// device-open failure (the expected no-display outcome) propagates as the child's
// own non-zero code.
exec_funpack_live :: proc(live_path: string, artifact_path: string, extra_args: []string) -> int {
	command := make([dynamic]string, 0, 2 + len(extra_args), context.temp_allocator)
	append(&command, live_path)
	append(&command, artifact_path)
	append(&command, ..extra_args)
	process, start_err := os.process_start(
		os.Process_Desc {
			command = command[:],
			stdin   = os.stdin,
			stdout  = os.stdout,
			stderr  = os.stderr,
		},
	)
	if start_err != nil {
		fmt.eprintfln("funpack run: cannot launch %s: %v", live_path, start_err)
		return 1
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		fmt.eprintfln("funpack run: %s exited abnormally: %v", FUNPACK_LIVE_BIN, wait_err)
		return 1
	}
	return state.exit_code
}
