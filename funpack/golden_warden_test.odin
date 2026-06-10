// The warden consumer golden: the drift example tree (funpack-spec/examples/
// drift) proves the producer→consumer contract end-to-end — funpack builds the
// tree and writes `.funpack/index.ndjson`, and `funpack warden`'s acquisition
// seam (read_warden_index) decodes the SAME bytes back onto the producer's own
// record structs, with the §29 §1 refusal contract holding around it (missing
// product, doctored schema_version, over-shaped record — each a closed refusal
// the warden exit mapping turns into 2, never a recompile). Every assertion
// goes through the public consumer seams — read_warden_index plus
// warden_verb_exit — and the round-trip assertions are TYPED struct reads
// (Decl_Record / Project_Record field access), not string-contains greps: the
// decoder exists, so the golden asserts decoded values, the contract proof the
// pre-consumer contains-idiom in golden_drift_test could not make. Like the
// other goldens it resolves the sibling checkout (or FUNPACK_DRIFT_DIR) and
// SKIPs loudly when it is absent — a skipped golden is a warning, never a
// pass.
//
// The surface-done sweep (the projection epic's leaf): every Warden_Command's
// projection is asserted byte-deterministic across two full acquisitions of
// the same written index — the command list derived from the closed enum, so
// a new member joins the sweep automatically and the exhaustive PRODUCTION
// renderer (warden_command_output, warden_output.odin — the same switch
// warden_verb_exit prints through, so the sweep covers the real dispatch,
// never a test-side mirror) refuses to compile until it is mapped. Drift's
// project record is faithfully empty on the pipeline axis
// (pipeline_flattened: [] — its schedule is the empty hole-first pipeline),
// so a drift-only double-run identity for `warden pipeline` would compare two
// empty byte streams; the pong example (eleven recorded flat steps, the
// ten-tag registry) is the non-empty counterpart that makes the
// project-record-side determinism non-vacuous.
package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// build_warden_index_root copies a live spec example tree into a fresh temp
// root, dev-builds it, writes the products, and reads the written index bytes
// back — the built fixture every golden warden case starts from, so each case
// exercises the index funpack REALLY wrote, never a hand-built stand-in. ok is
// false on the golden SKIP (absent checkout) or, test-failing, on any
// build/write/read failure; a false return owns the scratch-tree cleanup.
build_warden_index_root :: proc(t: ^testing.T, src: string, label: string, env_name: string) -> (root: string, stream: string, ok: bool) {
	copied: bool
	root, copied = copy_spec_tree_to_temp(src, label, env_name)
	if !copied {
		return "", "", false
	}
	product, build_err := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, build_err, Build_Error.None)
	if build_err != .None {
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

// build_drift_index_root is the drift instantiation of build_warden_index_root
// — the typed-holes governance tree whose two @stub decls are the live data
// for holes/find/graph/debt and the refusal cases.
build_drift_index_root :: proc(t: ^testing.T) -> (root: string, stream: string, ok: bool) {
	return build_warden_index_root(t, resolve_drift_dir(), "drift-warden", "FUNPACK_DRIFT_DIR")
}

// build_pong_index_root is the pong instantiation of build_warden_index_root —
// the gameplay tree whose NON-EMPTY project record (eleven flattened steps,
// ten registered tags) makes the pipeline/tags determinism sweep non-vacuous.
build_pong_index_root :: proc(t: ^testing.T) -> (root: string, stream: string, ok: bool) {
	return build_warden_index_root(t, resolve_pong_dir(), "pong-warden", "FUNPACK_PONG_DIR")
}

// expect_six_command_byte_determinism acquires the same written index TWICE —
// two full read_warden_index decodes of the same bytes, the in-process analog
// of two CLI invocations — and asserts every Warden_Command's projection is
// byte-identical across the runs AND that the integrated dispatch exits 0 for
// each (the whole-stream success tier; an empty projection included). The
// command list is derived from the closed enum, never written out by hand, so
// a future seventh command automatically joins the sweep. find_query keeps the
// find arm a real lookup per fixture (the zero query is find's defensive
// early-out, which would make its identity vacuous).
expect_six_command_byte_determinism :: proc(t: ^testing.T, root: string, find_query: Warden_Find_Query) {
	index_a, refusal_a := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal_a.err, Warden_Read_Error.None)
	index_b, refusal_b := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal_b.err, Warden_Read_Error.None)
	if refusal_a.err != .None || refusal_b.err != .None {
		return
	}
	for cmd in Warden_Command {
		first := warden_command_output(index_a, cmd, "", find_query, context.temp_allocator)
		second := warden_command_output(index_b, cmd, "", find_query, context.temp_allocator)
		testing.expect_value(t, second, first)
		testing.expect_value(t, warden_verb_exit(root, cmd, "", find_query), 0)
	}
}

// find_warden_decl finds a decoded decl record by qualified name — the typed
// counterpart of golden_drift_test's line grep. The drift project is
// single-module, so decls qualify to their bare names (read_index_project's
// lore-#11 rule); found = false keeps a renamed fixture loud, never a vacuous
// assert.
find_warden_decl :: proc(index: Warden_Index, qualified_name: string) -> (decl: Decl_Record, found: bool) {
	for candidate in index.decls {
		if candidate.qualified_name == qualified_name {
			return candidate, true
		}
	}
	return Decl_Record{}, false
}

@(test)
test_golden_warden_round_trip_typed_decode :: proc(t: ^testing.T) {
	// ROUND-TRIP: the consumer decodes the exact bytes funpack wrote. Typed
	// struct reads pin the contract — the project record carries this funpack's
	// schema stamp, the decl count equals the stream's decl lines (every line
	// after the leading project record), the bare drag hole decodes stub=true
	// and the intact damped caller stub=false — and the warden exit mapping is
	// 0 for EVERY command over the same root, the whole-stream success tier.
	root, stream, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	testing.expect_value(t, index.project.schema_version, INDEX_SCHEMA_VERSION)
	testing.expect_value(t, len(index.decls), len(ndjson_lines(stream)) - 1)

	drag, drag_found := find_warden_decl(index, "drag")
	testing.expect(t, drag_found)
	if drag_found {
		testing.expect(t, drag.stub)
	}
	damped, damped_found := find_warden_decl(index, "damped")
	testing.expect(t, damped_found)
	if damped_found {
		testing.expect(t, !damped.stub)
	}

	for cmd in Warden_Command {
		testing.expect_value(t, warden_verb_exit(root, cmd), 0)
	}
	log.infof("golden warden round-trip: the written drift index decodes whole through the consumer and every command exits 0")
}

@(test)
test_golden_warden_drift_six_command_byte_determinism :: proc(t: ^testing.T) {
	// BYTE-DETERMINISM (live drift): two acquisitions of the same written
	// index project byte-identically on EVERY command — the input stream is
	// byte-stable, so every projection must be (§29 §1). Non-vacuity pins for
	// the decl-side commands ride the live data: holes projects exactly the
	// two stub lines, find `damped` answers one record, graph carries the
	// damped→drag call edge set, tags carries the one-entry registry. Drift's
	// pipeline_flattened is faithfully [] (the empty hole-first schedule), so
	// the pipeline (and tags-at-scale) identity is made non-vacuous by the
	// pong sweep below — here it pins that the empty projection is stably
	// empty.
	root, _, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	expect_six_command_byte_determinism(t, root, Warden_Find_Query{name = "damped"})

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	testing.expect_value(t, len(ndjson_lines(warden_command_output(index, .Holes, allocator = context.temp_allocator))), 2)
	testing.expect_value(t, len(ndjson_lines(warden_command_output(index, .Find, find = Warden_Find_Query{name = "damped"}, allocator = context.temp_allocator))), 1)
	testing.expect(t, warden_command_output(index, .Graph, allocator = context.temp_allocator) != "")
	testing.expect_value(t, len(ndjson_lines(warden_command_output(index, .Tags, allocator = context.temp_allocator))), 1)
	testing.expect_value(t, warden_command_output(index, .Pipeline, allocator = context.temp_allocator), "")
	log.infof("golden warden drift determinism: all six projections are byte-identical across two acquisitions of the written index")
}

@(test)
test_golden_warden_pong_six_command_byte_determinism :: proc(t: ^testing.T) {
	// BYTE-DETERMINISM (live pong — the non-empty project record): pong's
	// index records the eleven-step §07 §3 depth-first total order and the
	// ten-tag authored registry, so here `warden pipeline` and `warden tags`
	// compare REAL bytes across the double run — the identity a drift-only
	// sweep cannot give (drift's pipeline projection is empty, and an
	// empty-vs-empty compare proves nothing). The counts are pinned exactly
	// against the live golden (the index_contract pong project-record counts);
	// when the spec evolves they change in lockstep — never loosen them.
	root, _, ok := build_pong_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	expect_six_command_byte_determinism(t, root, Warden_Find_Query{name = "paddle"})

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	testing.expect_value(t, len(index.project.pipeline_flattened), 11)
	testing.expect_value(t, len(index.project.tag_registry), 10)
	testing.expect_value(t, len(ndjson_lines(warden_command_output(index, .Pipeline, allocator = context.temp_allocator))), 11)
	testing.expect_value(t, len(ndjson_lines(warden_command_output(index, .Tags, allocator = context.temp_allocator))), 10)
	testing.expect(t, warden_command_output(index, .Graph, allocator = context.temp_allocator) != "")
	log.infof("golden warden pong determinism: pipeline (11 steps) and tags (10 tags) project real bytes identically across two acquisitions")
}

@(test)
test_golden_warden_holes_projects_producer_lines_byte_identical :: proc(t: ^testing.T) {
	// LIVE HOLES: `warden holes` over drift is EXACTLY the producer's own
	// bytes for the two §05 typed holes — drag (the bare @stub(Fixed)) and
	// launch_speed (the fallback form), in stream order, nothing else. The
	// expectation is rebuilt positionally from the WRITTEN stream (decls[i] ↔
	// line i+1, the decode's positional rule), so the assert is byte-identity
	// against the file funpack wrote — never a re-emission the test computed
	// for itself.
	root, stream, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	lines := ndjson_lines(stream)
	testing.expect_value(t, len(lines), len(index.decls) + 1)
	if len(lines) != len(index.decls) + 1 {
		return
	}
	expected := make([dynamic]string, 0, len(index.decls), context.temp_allocator)
	stub_names := make([dynamic]string, 0, len(index.decls), context.temp_allocator)
	for decl, i in index.decls {
		if decl.stub {
			append(&expected, strings.concatenate({lines[i + 1], "\n"}, context.temp_allocator))
			append(&stub_names, decl.qualified_name)
		}
	}
	testing.expect_value(t, len(stub_names), 2)
	if len(stub_names) == 2 {
		testing.expect_value(t, stub_names[0], "drag")
		testing.expect_value(t, stub_names[1], "launch_speed")
	}
	holes := warden_command_output(index, .Holes, allocator = context.temp_allocator)
	testing.expect_value(t, holes, strings.concatenate(expected[:], context.temp_allocator))
	log.infof("golden warden holes: the projection is byte-identical to the stream's two stub=true producer lines (drag, launch_speed)")
}

@(test)
test_golden_warden_debt_empty_projection_is_success :: proc(t: ^testing.T) {
	// EMPTY-IS-SUCCESS: drift carries no debt — no drift decl authors a §05
	// §2 @todo note (so every record's AST-derived todo flag is false) and no
	// drift decl attaches the registered `debt` gtag — so `warden debt`
	// projects ZERO bytes and the integrated dispatch exits 0: an empty answer
	// is an answer (§29 §1), and the warden has no exit-1 tier to mistake it
	// for. The live-todo counterpart below pins the non-empty projection.
	root, _, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	testing.expect_value(t, warden_command_output(index, .Debt, allocator = context.temp_allocator), "")
	testing.expect_value(t, warden_verb_exit(root, .Debt), 0)
	log.infof("golden warden debt: the empty drift projection exits 0 — emptiness is success, never a failure tier")
}

// overwrite_scratch_tree_file rewrites one file of a copied scratch tree —
// the pre-build fixture-amendment seam the live-debt golden uses to register
// data no committed spec example authors yet. The write happens BEFORE the
// build, so the index under test is still exactly what funpack wrote (over
// the amended tree), never doctored product bytes.
overwrite_scratch_tree_file :: proc(t: ^testing.T, root: string, rel: string, content: string) -> bool {
	path := scratch_join({root, rel})
	err := os.write_entire_file(path, transmute([]byte)content)
	testing.expect(t, err == nil)
	return err == nil
}

// append_scratch_tree_file appends source text to one file of a copied
// scratch tree — overwrite_scratch_tree_file's append form, used to add
// declarations to a copied .fun source without restating the committed bytes.
append_scratch_tree_file :: proc(t: ^testing.T, root: string, rel: string, addition: string) -> bool {
	path := scratch_join({root, rel})
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return false
	}
	joined := strings.concatenate({string(bytes), addition}, context.temp_allocator)
	return overwrite_scratch_tree_file(t, root, rel, joined)
}

@(test)
test_golden_warden_debt_projects_live_todo_alongside_gtag :: proc(t: ^testing.T) {
	// LIVE DEBT (@todo alongside @gtag): no committed spec example authors
	// @todo yet, so the scratch drift copy is amended BEFORE the build — one
	// fn carrying a §05 §2 @todo note and one carrying the `debt` gtag
	// (registered by amending the copied tags.fcfg) — and funpack builds the
	// amended tree for real. `warden debt` then projects EXACTLY the
	// producer's own bytes for those two decls in stream order: the predicate's
	// todo half reads the live v3 AST-derived flag alongside the gtag half,
	// never the v2 constant-false. When a spec example authors @todo, this pin
	// moves to the pristine tree.
	root, copied := copy_spec_tree_to_temp(resolve_drift_dir(), "drift-warden-todo", "FUNPACK_DRIFT_DIR")
	if !copied {
		return
	}
	defer remove_scratch_tree(root)
	if !overwrite_scratch_tree_file(t, root, "funpack_configs/tags.fcfg", "tags {\n  game\n  debt\n}\n") {
		return
	}
	addition := "\n@todo(\"retire the placeholder drag target\", T-0042)\nfn drag_target() -> Fixed {\n  return 0.5\n}\n\n@gtag(\"debt\")\nfn coast_speed(base: Fixed) -> Fixed {\n  return base * 2.0\n}\n"
	if !append_scratch_tree_file(t, root, "src/drift.fun", addition) {
		return
	}
	product, build_err := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, build_err, Build_Error.None)
	if build_err != .None {
		return
	}
	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)
	if write_err != .None {
		return
	}
	index_bytes, read_err := os.read_entire_file_from_path(product.index_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	stream := string(index_bytes)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	// The decoded records carry the two live halves separately: drag_target is
	// todo-only (the AST-derived flag, no gtag needed), coast_speed gtag-only.
	target, target_found := find_warden_decl(index, "drag_target")
	testing.expect(t, target_found)
	if target_found {
		testing.expect(t, target.todo)
		testing.expect_value(t, len(target.gtags), 0)
	}
	coast, coast_found := find_warden_decl(index, "coast_speed")
	testing.expect(t, coast_found)
	if coast_found {
		testing.expect(t, !coast.todo)
		testing.expect(t, contains_str(coast.gtags, WARDEN_DEBT_GTAG))
	}
	// Positional rebuild from the WRITTEN stream (decls[i] ↔ line i+1, the
	// decode's positional rule): the debt projection is byte-identical to the
	// producer's own two debt lines in stream order — the holes golden's
	// byte-identity, applied to debt.
	lines := ndjson_lines(stream)
	testing.expect_value(t, len(lines), len(index.decls) + 1)
	if len(lines) != len(index.decls) + 1 {
		return
	}
	expected := make([dynamic]string, 0, len(index.decls), context.temp_allocator)
	debt_names := make([dynamic]string, 0, len(index.decls), context.temp_allocator)
	for decl, i in index.decls {
		if warden_debt_predicate(decl, "") {
			append(&expected, strings.concatenate({lines[i + 1], "\n"}, context.temp_allocator))
			append(&debt_names, decl.qualified_name)
		}
	}
	testing.expect_value(t, len(debt_names), 2)
	if len(debt_names) == 2 {
		testing.expect_value(t, debt_names[0], "drag_target")
		testing.expect_value(t, debt_names[1], "coast_speed")
	}
	debt := warden_command_output(index, .Debt, allocator = context.temp_allocator)
	testing.expect_value(t, debt, strings.concatenate(expected[:], context.temp_allocator))
	testing.expect_value(t, warden_verb_exit(root, .Debt), 0)
	log.infof("golden warden debt: the live @todo and @gtag(debt) decls project byte-identical producer lines (drag_target, coast_speed)")
}

@(test)
test_golden_warden_missing_index_refuses_naming_build :: proc(t: ^testing.T) {
	// MISSING-INDEX REFUSAL: the same copied tree WITHOUT a build has no
	// `.funpack/index.ndjson`, so the acquisition is the Missing_Index refusal
	// — line 0, no decls — whose fix-it names `funpack build` (the warden never
	// recompiles in the product's place, §29 §1) and whose exit mapping is 2.
	root, ok := copy_spec_tree_to_temp(resolve_drift_dir(), "drift-warden", "FUNPACK_DRIFT_DIR")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.Missing_Index)
	testing.expect_value(t, refusal.line, 0)
	testing.expect_value(t, len(index.decls), 0)
	message := warden_refusal_message(refusal, context.temp_allocator)
	testing.expect(t, strings.contains(message, "`funpack build`"))
	testing.expect(t, strings.contains(message, INDEX_PRODUCT_NAME))
	// The refusal holds on EVERY command (enum-derived, so a new command joins
	// the sweep automatically): acquisition refuses before any projection arm.
	for cmd in Warden_Command {
		testing.expect_value(t, warden_verb_exit(root, cmd), 2)
	}
	log.infof("golden warden missing index: an unbuilt drift tree refuses exit 2 on every command with the `funpack build` fix-it")
}

@(test)
test_golden_warden_doctored_schema_version_refused :: proc(t: ^testing.T) {
	// DOCTORED-STREAM REFUSAL (schema): the written index bytes with every
	// line's schema_version stamp bumped to 999 refuse the whole stream as
	// Schema_Mismatch on line 1 — the version gate fires before any shape
	// reading — with the mismatch's OWN fix-it (rebuild with THIS funpack) and
	// exit 2. The surgery is asserted to have hit, so an emitter drift turns
	// the test loud, never vacuous.
	root, stream, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	anchor := fmt.tprintf("\"schema_version\":%d", INDEX_SCHEMA_VERSION)
	doctored, _ := strings.replace_all(stream, anchor, "\"schema_version\":999", context.temp_allocator)
	testing.expect(t, doctored != stream)
	if !write_warden_index_product(t, root, doctored) {
		return
	}

	_, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.Schema_Mismatch)
	testing.expect_value(t, refusal.line, 1)
	testing.expect_value(t, refusal.decode, Index_Read_Error.Schema_Mismatch)
	testing.expect(t, strings.contains(warden_refusal_message(refusal, context.temp_allocator), "rebuild the index with this funpack"))
	// The schema refusal holds on EVERY command (enum-derived): the version
	// gate fires in the shared acquisition, never per projection arm.
	for cmd in Warden_Command {
		testing.expect_value(t, warden_verb_exit(root, cmd), 2)
	}
	log.infof("golden warden doctored schema: a bumped schema_version refuses the written index exit 2 on every command")
}

@(test)
test_golden_warden_injected_extra_key_refused :: proc(t: ^testing.T) {
	// DOCTORED-STREAM REFUSAL (exact-match): one decl line of the written index
	// with an extra top-level key injected is the over-shaped Record_Refused
	// refusal — the per-line decoder's Unknown_Field cause at the offending
	// line — never a best-effort read past it, and the exit mapping is 2 with
	// the generic rebuild fix-it.
	root, stream, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	lines := ndjson_lines(stream)
	testing.expect(t, len(lines) >= 2)
	if len(lines) < 2 {
		return
	}
	doctored := make([dynamic]string, 0, len(lines), context.temp_allocator)
	for line, i in lines {
		full := strings.concatenate({line, "\n"}, context.temp_allocator)
		if i == 1 {
			full = inject_top_level_key(t, full)
		}
		append(&doctored, full)
	}
	joined := strings.concatenate(doctored[:], context.temp_allocator)
	if !write_warden_index_product(t, root, joined) {
		return
	}

	_, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.Record_Refused)
	testing.expect_value(t, refusal.line, 2)
	testing.expect_value(t, refusal.decode, Index_Read_Error.Unknown_Field)
	testing.expect(t, strings.contains(warden_refusal_message(refusal, context.temp_allocator), "`funpack build`"))
	testing.expect_value(t, warden_verb_exit(root, .Graph), 2)
	log.infof("golden warden injected key: an over-shaped decl line refuses the written index exit 2")
}
