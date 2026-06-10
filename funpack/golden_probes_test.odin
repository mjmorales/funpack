// The §05 §5 / §28 §4 debug-directive governance golden, the drift typed-holes
// golden's sibling: one fixture tree carries ALL FOUR debug probes
// (@break/@log/@watch/@trace) across four representative declaration kinds
// (fn, let, thing, behavior) plus the §05 §2 @todo that retires the fixture,
// and the three compile modes adjudicate it exactly as the spec promises —
// dev builds green and indexes every probe by name, release (build AND check)
// refuses with Debug_Directive writing nothing, and the probes surface through
// the §29 warden projection surface as the producer's own record bytes.
//
// FIXTURE TECHNIQUE: no committed spec example authors a debug directive yet,
// so the fixture follows the live-debt golden's amended-scratch mold
// (golden_warden_test.odin): the live PONG tree is copied to temp and the
// probe addendum appended BEFORE the build, so every asserted byte is what
// funpack really wrote over the amended tree — never a doctored product. Pong,
// not drift, is the base deliberately: stage_build adjudicates the §29 §4
// hole-ban BEFORE the debug ban, so drift's @stub holes would mask the
// Debug_Directive refusal this golden pins; pong is hole-free, isolating the
// release verdict to the probes alone. When a spec example authors the
// directives, these pins move to the pristine tree.
//
// WARDEN SURFACE: the §29 enumeration has NO probes-specific projection —
// `holes` projects @stub debt and `debt` projects @todo/@gtag(debt) — so a
// probe is visible exactly as its decl record's `debug` field bytes through
// `find` (and any record-projecting command). This golden pins that REAL
// surface: find answers each probed decl byte-identical to its producer line,
// debt projects the @todo-carrying traced behavior, holes stays empty, and
// all six commands are byte-deterministic over the probed tree. Like the
// other goldens it resolves the sibling checkout (or FUNPACK_PONG_DIR) and
// SKIPs loudly when absent — a skipped golden is a warning, never a pass.
package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// PROBED_GOVERNANCE_ADDITION is the four-probe governance addendum appended to
// the copied pong source: each §05 §5 directive once, each on a different
// declaration kind — @break(pred) on a fn, @log(expr) on a let, @watch(expr)
// on a thing, @trace on a behavior — and one §05 §2 @todo (the recommended
// Task_Ref window form) stacked on the traced behavior, so the v3 contract's
// two live derivations (debug + todo) are pinned together on one decl. The
// names share no substring with any pristine pong decl, so a per-name find
// answers exactly one record.
PROBED_GOVERNANCE_ADDITION ::
	"\n@doc(\"Debug fixture: a breakpoint probe pausing when the serve threshold is crossed.\")\n" +
	"@break(base > 70.0)\n" +
	"fn debug_serve_threshold(base: Fixed) -> Fixed {\n" +
	"  return base + 1.0\n" +
	"}\n" +
	"\n" +
	"@doc(\"Debug fixture: the drift bias under live observation, logged each step.\")\n" +
	"@log(BOARD.w)\n" +
	"let DEBUG_DRIFT_BIAS: Fixed = 0.25\n" +
	"\n" +
	"@doc(\"Debug fixture: a marker thing whose position is watched for changes.\")\n" +
	"@watch(self.pos)\n" +
	"thing DebugMarker {\n" +
	"  pos: Vec2\n" +
	"}\n" +
	"\n" +
	"@doc(\"Debug fixture: a traced ball observer, with the @todo that retires the whole fixture.\")\n" +
	"@trace\n" +
	"@todo(\"retire the debug governance fixture\", T-0042)\n" +
	"behavior debug_trace_ball on Ball {\n" +
	"  fn step(self: Ball) -> Ball {\n" +
	"    return self\n" +
	"  }\n" +
	"}\n"

// PROBED_DECL_NAMES is the fixture's four probed declarations in their
// directive order (@break, @log, @watch, @trace) — the per-name find sweep's
// query list. Single-module pong qualifies decls to their bare names.
PROBED_DECL_NAMES :: [4]string{"debug_serve_threshold", "DEBUG_DRIFT_BIAS", "DebugMarker", "debug_trace_ball"}

// amend_probed_pong_root copies the live pong tree into a fresh temp root and
// appends the four-probe addendum to its source BEFORE any build — the
// live-debt golden's pre-build amendment seam, so the products under test are
// exactly what funpack wrote over the amended tree. ok = false on the golden
// SKIP (absent checkout) or a write failure; a false return owns the cleanup.
amend_probed_pong_root :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	copied: bool
	root, copied = copy_spec_tree_to_temp(resolve_pong_dir(), "pong-probes", "FUNPACK_PONG_DIR")
	if !copied {
		return "", false
	}
	if !append_scratch_tree_file(t, root, "src/pong.fun", PROBED_GOVERNANCE_ADDITION) {
		remove_scratch_tree(root)
		return "", false
	}
	return root, true
}

// build_probed_pong_root amends, dev-builds, writes the products, and reads
// the written index bytes back — build_warden_index_root's shape over the
// amended fixture, so every warden assertion reads the index funpack REALLY
// wrote. ok is false on the SKIP or, test-failing, on any build/write/read
// failure; a false return owns the scratch-tree cleanup.
build_probed_pong_root :: proc(t: ^testing.T) -> (root: string, stream: string, ok: bool) {
	amended: bool
	root, amended = amend_probed_pong_root(t)
	if !amended {
		return "", "", false
	}
	product, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		remove_scratch_tree(root)
		return "", "", false
	}
	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)
	if write_err != .None {
		remove_scratch_tree(root)
		return "", "", false
	}
	index_bytes, read_err := os.read_entire_file_from_path(product.index_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		remove_scratch_tree(root)
		return "", "", false
	}
	return root, string(index_bytes), true
}

@(test)
test_golden_probed_pong_dev_build_indexes_all_four_probes :: proc(t: ^testing.T) {
	// AC (dev build): the probed tree built in Dev mode (the no-flag default) is
	// exit 0 and writes BOTH products — a probe is a first-class dev citizen —
	// and the written index derives each directive onto ITS declaration's debug
	// field, byte-pinned on the producer's own lines: break on the fn, log on
	// the let, watch on the thing, trace on the behavior (which also carries the
	// live todo flag), while a pristine pong decl keeps the mandatory-present
	// empty debug and todo=false — the index discriminates the probed decls,
	// not merely the file.
	root, stream, ok := build_probed_pong_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	testing.expect(t, os.exists(build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)))
	testing.expect(t, os.exists(build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)))

	break_line, break_found := index_decl_line(stream, "debug_serve_threshold")
	testing.expect(t, break_found)
	testing.expect(t, strings.contains(break_line, "\"kind\":\"Fn\""))
	testing.expect(t, strings.contains(break_line, "\"debug\":[\"break\"]"))
	testing.expect(t, strings.contains(break_line, "\"todo\":false"))

	log_line, log_found := index_decl_line(stream, "DEBUG_DRIFT_BIAS")
	testing.expect(t, log_found)
	testing.expect(t, strings.contains(log_line, "\"kind\":\"Let\""))
	testing.expect(t, strings.contains(log_line, "\"debug\":[\"log\"]"))

	watch_line, watch_found := index_decl_line(stream, "DebugMarker")
	testing.expect(t, watch_found)
	testing.expect(t, strings.contains(watch_line, "\"kind\":\"Thing\""))
	testing.expect(t, strings.contains(watch_line, "\"debug\":[\"watch\"]"))

	trace_line, trace_found := index_decl_line(stream, "debug_trace_ball")
	testing.expect(t, trace_found)
	testing.expect(t, strings.contains(trace_line, "\"kind\":\"Behavior\""))
	testing.expect(t, strings.contains(trace_line, "\"debug\":[\"trace\"]"))
	testing.expect(t, strings.contains(trace_line, "\"todo\":true"))

	pristine_line, pristine_found := index_decl_line(stream, "advance")
	testing.expect(t, pristine_found)
	testing.expect(t, strings.contains(pristine_line, "\"debug\":[]"))
	testing.expect(t, strings.contains(pristine_line, "\"todo\":false"))
	log.infof("golden probes dev build: exit 0, both products, and the index pins break/log/watch/trace each on its own decl with the live todo flag")
}

@(test)
test_golden_probed_pong_release_build_and_check_refuse :: proc(t: ^testing.T) {
	// AC (release ban): the SAME probed tree under --release is the exit-2
	// compile-error outcome on BOTH adjudicating verbs — stage_build refuses
	// with a Debug_Directive verdict NAMING the first probed declaration and
	// writing NEITHER product, and the check verb adjudicates dev 0 / release 2
	// with no `.funpack/` after either verdict. The offender is
	// debug_serve_threshold: release_debug_decl walks the Ast's source-ordered
	// declaration sequence (the same order the index emits), the addendum
	// appends after every pristine (probe-free) pong decl, and the @break-probed
	// fn is the addendum's FIRST declaration — so it precedes the probed
	// let/thing/behavior, and single-module pong qualifies it bare (lore #11).
	// The refusal line is pinned byte-for-byte for determinism — stdout/stderr
	// stay advisory (§29 §3, the machine contract is the exit code), but the
	// NAME in the message is the deliverable. Never a counted failure: neither
	// verb has an exit-1 tier. Pong is hole-free, so the refusal is the debug
	// ban's own — not the hole-ban firing first.
	root, ok := amend_probed_pong_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Debug_Directive)
	testing.expect_value(t, verdict.offender, "debug_serve_threshold")
	testing.expect_value(t, build_refusal_message(verdict, context.temp_allocator), "Debug_Directive: debug_serve_threshold")
	testing.expect(t, !os.exists(build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)))
	testing.expect(t, !os.exists(build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)))

	testing.expect_value(t, run_check_verb(root, .Dev), 0)
	testing.expect_value(t, run_check_verb(root, .Release), 2)
	testing.expect(t, !os.exists(scratch_join({root, FUNPACK_BUILD_DIR})))
	log.infof("golden probes release: build refuses naming the offender (Debug_Directive: debug_serve_threshold) with no product and check adjudicates dev 0 / release 2 — debug residue cannot ship")
}

@(test)
test_golden_probed_pong_warden_projects_probes :: proc(t: ^testing.T) {
	// AC (warden projection): the probes are visible through the §29 projection
	// surface exactly as producer bytes — there is no probes-specific command,
	// so the pins ride what the six commands REALLY show over a probed tree.
	// The decoded records carry each directive name typed (debug=["break"|"log"|
	// "watch"|"trace"], todo=true on the traced behavior); a per-name `find`
	// answers each probed decl byte-identical to its producer line (the
	// positional rebuild: decls[i] ↔ line i+1, never a re-emission the test
	// computed); `debt` projects exactly the @todo-carrying behavior; `holes`
	// stays empty (probes are not stub debt); and all six commands are
	// byte-deterministic across two acquisitions, each exiting 0.
	root, stream, ok := build_probed_pong_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}

	directives := [4]string{"break", "log", "watch", "trace"}
	names := PROBED_DECL_NAMES
	for name, i in names {
		decl, found := find_warden_decl(index, name)
		testing.expect(t, found)
		if !found {
			continue
		}
		testing.expect_value(t, len(decl.debug), 1)
		if len(decl.debug) == 1 {
			testing.expect_value(t, decl.debug[0], directives[i])
		}
		testing.expect_value(t, decl.todo, name == "debug_trace_ball")
	}

	lines := ndjson_lines(stream)
	testing.expect_value(t, len(lines), len(index.decls) + 1)
	if len(lines) != len(index.decls) + 1 {
		return
	}
	for name in names {
		expected, found := probed_producer_line(index, lines, name)
		testing.expect(t, found)
		if !found {
			continue
		}
		query := Warden_Find_Query{name = name}
		testing.expect_value(t, warden_command_output(index, .Find, find = query, allocator = context.temp_allocator), expected)
		testing.expect_value(t, warden_verb_exit(root, .Find, "", query), 0)
	}

	// The traced behavior's @todo makes it the tree's ONLY debt record (pong
	// registers no `debt` gtag and authors no @todo), and the probes are not
	// holes — @stub debt and debug residue are distinct governance surfaces.
	expected_debt, debt_found := probed_producer_line(index, lines, "debug_trace_ball")
	testing.expect(t, debt_found)
	if debt_found {
		testing.expect_value(t, warden_command_output(index, .Debt, allocator = context.temp_allocator), expected_debt)
	}
	testing.expect_value(t, warden_verb_exit(root, .Debt), 0)
	testing.expect_value(t, warden_command_output(index, .Holes, allocator = context.temp_allocator), "")
	testing.expect_value(t, warden_verb_exit(root, .Holes), 0)

	expect_six_command_byte_determinism(t, root, Warden_Find_Query{name = "debug_trace_ball"})
	log.infof("golden probes warden: each probed decl answers find byte-identical to its producer line, debt projects the @todo behavior, holes stays empty")
}

// probed_producer_line rebuilds one decl's producer line (with its trailing
// LF) positionally from the WRITTEN stream — decls[i] ↔ line i+1, the
// decode's positional rule — so a projection assert is byte-identity against
// the file funpack wrote, never a re-emission the test computed for itself.
// found = false keeps a renamed fixture loud, never a vacuous assert.
probed_producer_line :: proc(index: Warden_Index, lines: []string, name: string) -> (line: string, found: bool) {
	for decl, i in index.decls {
		if decl.qualified_name == name {
			return strings.concatenate({lines[i + 1], "\n"}, context.temp_allocator), true
		}
	}
	return "", false
}
