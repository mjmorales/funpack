// The `build` verb's emission seam: the integration point that wires both of
// funpack's emission surfaces — the runtime binary artifact (emit.odin) and the
// Index Contract `project` record NDJSON (index_contract.odin) — onto one §14
// project tree. It reads the tree at the working directory (read_project,
// project.odin), runs the source through the full checked pipeline (parse →
// gates → resolve → typecheck → contracts → flatten/closure) once per emission
// surface, and on success writes BOTH products under the derived, gitignored
// `.funpack/` directory (§14 §1).
//
// EXIT CONTRACT (spec §29 §3; the same contract the test verb honors): a
// malformed §14 tree or ANY compile/gate failure is exit 2 and writes NEITHER
// product — the build either emits both products or none, never a partial tree.
// A compile/gate error is never a counted failure; the build verb has no
// assertion-failure tier (that is the test verb's), so its only outcomes are
// success (0, both products written) and compile/gate/tree error (2, no
// product).
//
// PURITY (spec §09, §29 §1): the products are a pure function of source and the
// authored config. The output paths are derived from the project root per §14
// (`.funpack/` under the root, fixed leaf names), so no absolute machine path is
// baked into either product's bytes — the artifact carries only the §15
// path-derived module name in its spans, and the NDJSON carries no path at all.
// Two builds of the same tree therefore write byte-identical artifact AND
// byte-identical NDJSON.
//
// BOUNDARY: this wires emission into the CLI. It does NOT execute the artifact
// (the runtime owns execution) and does NOT add a new pipeline stage — it
// composes the existing stage_emit and read_index_project seams.
package funpack

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// FUNPACK_BUILD_DIR is the §14 derived-products directory (`.funpack/`): the
// gitignored sibling of `funpack_configs/` and `src/` where a build writes its
// products. It is rebuilt on demand and never committed (§14 §1), so the build
// verb creates it if absent and overwrites its contents on every build.
FUNPACK_BUILD_DIR :: ".funpack"

// ARTIFACT_PRODUCT_NAME is the runtime binary artifact's fixed leaf name under
// `.funpack/`. The name is project-independent so the derived path is a pure
// function of the project root alone (no project-name interpolation), keeping
// the output path deterministic and free of any machine-specific component.
ARTIFACT_PRODUCT_NAME :: "artifact"

// INDEX_PRODUCT_NAME is the Index Contract `project` record's fixed leaf name
// under `.funpack/`. The `.ndjson` extension names the one-object-per-line
// transport (spec §29 §2); like the artifact name it carries no project-specific
// or machine-specific component.
INDEX_PRODUCT_NAME :: "index.ndjson"

// Build_Product is the pair of byte products a successful build emits, with the
// derived output path each is written to. artifact is the runtime binary
// artifact (emit.odin); index is the Index Contract `project` record NDJSON
// (index_contract.odin). Each path is the §14 `.funpack/` derived location under
// the project root, so the struct carries both the bytes and where they land.
Build_Product :: struct {
	artifact:      string,
	index:         string,
	artifact_path: string,
	index_path:    string,
}

// Build_Mode is the closed build-mode set the §29 §4 hole-ban keys on,
// mirroring the asset pipeline's Bake_Mode (asset_strip.odin). Dev (the CLI
// default — `funpack build` with no flag) compiles §05 typed holes so the game
// stays playable mid-edit; Release (`funpack build --release`) refuses to ship
// a hole — ANY holed declaration is a compile error (exit 2, never a counted
// failure). The mode is a pure flag threaded through stage_build, so the
// hole-ban verdict is a pure function of (AST, mode) — no clock, no host
// nondeterminism (§29 §1). A third mode is a deliberate addition here in
// lockstep with the spec, never a silently-tolerated fall-through.
Build_Mode :: enum {
	Dev,
	Release,
}

// Build_Error is closed with one arm per way a build refuses before it writes
// any product. Malformed_Tree is a §14 project-tree violation (read_project
// rejected the tree); Compile_Failed is any checked-pipeline floor (parse, gate,
// typecheck, contract, or flatten — the source does not compile); Index_Failed
// is an authored-config read failure projecting the `project` record;
// Holed_Declaration is the §29 §4 release hole-ban — a --release build over a
// tree carrying a §05 typed hole (you cannot ship a hole); Debug_Directive is
// its §05 §5 sibling — a --release build over a tree carrying a debug probe
// (@break/@log/@watch/@trace are dev-only, release-forbidden like @stub, §28
// §4: debug residue cannot ship). Every arm maps to the exit-2 outcome — a
// build that cannot emit both products emits neither.
Build_Error :: enum {
	None,
	Malformed_Tree,
	Compile_Failed,
	Index_Failed,
	Holed_Declaration,
	Debug_Directive,
	// Asset_Bake_Failed is the §19-literal manifest-bake refusal arm: the asset
	// bake could not produce a manifest that matches the committed one — a
	// missing/unreadable source, a missing or corrupt image file, an importer
	// reject, or (the §19 §5 seam-staleness model) a committed assets.manifest
	// that does not byte-match the freshly-baked one. Like every other arm it
	// maps to exit 2, no product — a stale or unbuildable asset graph refuses the
	// whole build before either emission surface runs. The offender line names
	// the offending asset/file and the specific bake error (asset_bake_refusal_message).
	Asset_Bake_Failed,
}

// Build_Verdict is the build seam's refusal verdict: the closed Build_Error arm
// plus the diagnostic payload the arm carries. offender is the §15
// module-qualified name of the offending declaration on the two release-refusal
// arms (Holed_Declaration — the holed decl; Debug_Directive — the probed decl),
// "" on every other arm. The struct exists so the CLI refusal line can NAME the
// declaration an agent must repair without stringly-typing the error kind: the
// arm stays the closed enum, the name rides beside it. The zero value is the
// clean verdict (err = .None, no offender).
//
// diagnostic is the inner fix-criteria Diagnostic the Compile_Failed arm carries
// (path/line/col/rule/message) — the §15 stage rejection a checked-pipeline floor
// surfaces, so the CLI renders a `file:line:col: rule: message` block instead of
// a bare `Compile_Failed`. It is zero (rule = "") on every other arm: those arms
// name their offender on the `offender` line (build_refusal_message), and only
// the compile floor has an inner per-stage diagnostic to thread. The arm stays
// the machine contract (exit 2); the diagnostic is the added human body.
Build_Verdict :: struct {
	err:        Build_Error,
	offender:   string,
	diagnostic: Diagnostic,
}

// build_refusal_message renders one Build_Verdict as the operator-facing
// refusal line body: the closed arm's name, with the module-qualified offender
// appended (`Holed_Declaration: drag`) when the arm carries one. Stdout/stderr
// wording is ADVISORY — the machine contract is exclusively the exit code
// (spec §29 §3) — but the line is deterministic (a pure function of the
// verdict) so goldens may pin it byte-for-byte.
build_refusal_message :: proc(verdict: Build_Verdict, allocator := context.allocator) -> string {
	if verdict.offender == "" {
		return fmt.aprintf("%v", verdict.err, allocator = allocator)
	}
	return fmt.aprintf("%v: %s", verdict.err, verdict.offender, allocator = allocator)
}

// stage_asset_bake is the §19-literal manifest-bake GATE the build runs over a
// tree carrying an assets/assets.manifest: it bakes the manifest from real source
// bytes (bake_asset_manifest — every hash recomputed, each atlas's image read off
// disk), emits the canonical manifest text (emit_asset_manifest), and
// STALENESS-CHECKS it against the committed bytes (bake_manifest_staleness, §19
// §5). It is the pure check side — it WRITES nothing — so a stale committed
// manifest is a Build_Error here (exit 2, no product), and regeneration is the
// impure CLI side's job (regen_asset_manifest under FUNPACK_REGEN_GOLDEN). The
// returned verdict's offender carries the bake error kind + the offending
// asset/file path so the refusal line names exactly what to repair (a missing
// image, a stale manifest awaiting regen).
stage_asset_bake :: proc(root: string, allocator := context.allocator) -> Build_Verdict {
	baked, bake_err, bake_detail := bake_asset_manifest(root, context.temp_allocator)
	if bake_err != .None {
		return Build_Verdict{err = .Asset_Bake_Failed, offender = asset_bake_refusal_message(bake_err, bake_detail, allocator)}
	}
	emitted := emit_asset_manifest(baked, context.temp_allocator)
	if stale_err, stale_detail := bake_manifest_staleness(root, emitted); stale_err != .None {
		return Build_Verdict{err = .Asset_Bake_Failed, offender = asset_bake_refusal_message(stale_err, stale_detail, allocator)}
	}
	return Build_Verdict{}
}

// asset_bake_refusal_message renders an Asset_Bake_Error + its offending
// asset/file path as the build refusal's offender line — the advisory fix-it that
// rides beside the closed Asset_Bake_Failed arm (the named-offender discipline:
// the arm is the machine contract, this names what to repair). A Stale_Manifest
// directs the agent to regenerate; the read/source/image errors name the file
// that could not be resolved. The line is deterministic (a pure function of the
// error + detail) so goldens may pin it.
asset_bake_refusal_message :: proc(err: Asset_Bake_Error, detail: string, allocator := context.allocator) -> string {
	switch err {
	case .None:
		return ""
	case .Stale_Manifest:
		return fmt.aprintf("Stale_Manifest: %s does not match the freshly-baked manifest — regenerate it (FUNPACK_REGEN_GOLDEN=1 funpack build) and commit the diff", detail, allocator = allocator)
	case .Missing_Manifest:
		return fmt.aprintf("Missing_Manifest: %s — a tree that bakes assets must carry the generated manifest", detail, allocator = allocator)
	case .Malformed_Manifest:
		return fmt.aprintf("Malformed_Manifest: %s — the committed manifest does not parse", detail, allocator = allocator)
	case .Missing_Source:
		return fmt.aprintf("Missing_Source: %s — a registered asset source is not on disk", detail, allocator = allocator)
	case .Malformed_Source:
		return fmt.aprintf("Malformed_Source: %s — an asset source rejected its importer", detail, allocator = allocator)
	case .Missing_Image:
		return fmt.aprintf("Missing_Image: %s — an atlas names an image file that is not on disk", detail, allocator = allocator)
	case .Malformed_Image:
		return fmt.aprintf("Malformed_Image: %s — an image file could not be decoded", detail, allocator = allocator)
	}
	return fmt.aprintf("%v: %s", err, detail, allocator = allocator)
}

// regen_asset_manifest is the §19-literal manifest bake's IMPURE regenerate side:
// it bakes the manifest from real source bytes and WRITES the freshly-emitted text
// back to the committed assets/assets.manifest, so the next build's staleness gate
// passes. It is the dev-regenerate path the CLI runs under FUNPACK_REGEN_GOLDEN — a
// committed-but-generated artifact the operator regenerates and commits as a diff
// (§19 §3). A tree with no manifest is a no-op (ok = true — nothing to regen); a
// bake or write failure is ok = false with the error named, so a regen that cannot
// produce a manifest fails loudly rather than silently leaving the committed copy
// stale.
regen_asset_manifest :: proc(root: string) -> (err: Asset_Bake_Error, detail: string) {
	if !asset_tree_has_manifest(root) {
		return .None, ""
	}
	baked, bake_err, bake_detail := bake_asset_manifest(root, context.temp_allocator)
	if bake_err != .None {
		return bake_err, bake_detail
	}
	emitted := emit_asset_manifest(baked, context.temp_allocator)
	if !write_asset_manifest(root, emitted) {
		return .Missing_Manifest, asset_manifest_path(root, context.temp_allocator)
	}
	return .None, ""
}

// stage_build is the build verb's pure seam: it reads the §14 project tree at
// `root` and projects its emission surfaces — per project kind. A GAME (an
// entrypoints.fcfg names a pipeline) emits BOTH products: the runtime binary
// artifact (stage_emit_indexed over the entrypoint module) and the Index Contract
// NDJSON (read_index_project over every module). A PACKAGE (no entrypoints.fcfg,
// §30 §7) has no entrypoint to select, so it emits the Index Contract NDJSON ONLY
// — there is no runtime artifact, and artifact_path stays empty so the write side
// writes no artifact. The write contract is all-or-nothing PER KIND: a game
// writes both products or none; a package writes its index or nothing. It writes
// nothing here — the impure write is write_build_products' job — so it is a pure
// function of the tree contents: two calls on the same tree return byte-identical
// products. ANY checked-pipeline floor (a compile/gate failure on any module) or
// a malformed tree returns the matching Build_Verdict (its closed Build_Error
// arm, plus the module-qualified offender name on the release-refusal arms) and
// no product. The exit contract is unchanged: success (0, the kind's products
// written) and compile/gate/tree error (2, no product); a build never has an
// assertion tier (exit 1 is the test verb's).
//
// MODE (§29 §4): mode is the pure Dev/Release flag the release bans key on.
// Dev compiles §05 typed holes and §05 §5 debug probes; Release refuses the
// whole build when ANY module carries a holed declaration (Holed_Declaration)
// or a debug directive (Debug_Directive — @break/@log/@watch/@trace are
// release-forbidden like @stub, §28 §4) — the same exit-2 compile-error
// outcome, never a counted failure, with the verdict naming the offending
// declaration so the refusal line tells the agent exactly what to repair. The
// verdict is a pure function of (AST, mode): the same tree builds identically
// in dev, and in release either emits the same bytes (hole- and probe-free) or
// refuses before any emission.
stage_build :: proc(root: string, mode: Build_Mode, allocator := context.allocator) -> (product: Build_Product, verdict: Build_Verdict) {
	project, project_err, project_detail := read_project(root)
	if project_err != .None {
		// The closed Build_Error arm stays the machine contract; the project
		// arm + its detail ride the offender line so the refusal names what
		// to repair instead of a bare Malformed_Tree.
		return Build_Product{}, Build_Verdict{err = .Malformed_Tree, offender = project_refusal_message(project_err, project_detail, allocator)}
	}
	if len(project.sources) == 0 {
		return Build_Product{}, Build_Verdict{err = .Malformed_Tree}
	}
	// §19-literal manifest-bake gate: a tree carrying an assets/assets.manifest
	// has its manifest REGENERATED from real source bytes (every hash recomputed,
	// each atlas's image read off disk and hashed) and STALENESS-CHECKED against
	// the committed bytes (§19 §5: a committed generated manifest that does not
	// match the freshly-baked one is a build error). This runs before either
	// emission surface so a stale or unbuildable asset graph refuses the whole
	// build — exit 2, no product — naming the offending asset/file. A tree with no
	// manifest has no assets to bake, so the gate is skipped (an asset-free game
	// is not refused).
	if asset_tree_has_manifest(root) {
		if bake_verdict := stage_asset_bake(root, allocator); bake_verdict.err != .None {
			return Build_Product{}, bake_verdict
		}
	}
	// §30 §7: a path dependency is compiled through the consumer's pipeline
	// with the same gates as its own code, so every build/check walk below
	// consumes the COMBINED source set (own + package_sources, the test
	// verb's project_pipeline_sources discipline) — a dep-importing game
	// checks and builds, and the dep's decls reach the emitted index under
	// their package-prefixed module names.
	sources := project_pipeline_sources(project)
	if mode == .Release {
		// Both refusal walkers scan the sources in the Index Contract's module
		// order (entrypoint module first, then sorted-by-path remainder) so the
		// named offender is the first offender in the order the emitted index
		// lists its decl blocks — never a plain sorted-by-path artifact.
		scan_sources := order_release_sources(root, sources)
		// The §29 §4 release hole-ban: a hole cannot ship, so a holed declaration
		// in ANY module refuses the whole build before either emission surface
		// runs — exit 2, no product, never a counted failure — naming the first
		// holed declaration so the refusal is actionable.
		if name, holed := project_holed_decl(scan_sources); holed {
			return Build_Product{}, Build_Verdict{err = .Holed_Declaration, offender = name}
		}
		// The §05 §5 release debug-directive ban, the hole-ban's sibling tier
		// (§28 §4: a @break/@log in a --release build is a compile error): a
		// debug probe on ANY declaration refuses the whole build the same way —
		// exit 2, no product, never a counted failure — naming the first probed
		// declaration.
		if name, probed := project_debug_decl(scan_sources); probed {
			return Build_Product{}, Build_Verdict{err = .Debug_Directive, offender = name}
		}
	}
	// The §01 P5 structural gates over EVERY module — the per-module pass the test
	// pipeline runs (run_project_pipeline -> gate_verdict per module) that the
	// emit/index path below otherwise skips: emit gates only the entrypoint's
	// flattened AST, and a package emits no artifact at all, so a gate an imported
	// module overshoots (Nesting_Exceeded, Duplicate_Declaration) never surfaces
	// under check/build. Running it here keeps check, build, and test in agreement
	// on the structural gates instead of leaving check a false green.
	if gate := project_gate_verdict(sources); gate.err != .None {
		return Build_Product{}, gate
	}
	// A package has no entrypoints.fcfg, so there is no entrypoint module and no
	// runtime artifact to emit (§30 §7). The Index Contract is the package's
	// single product — its index path is set, the artifact path stays empty.
	is_game := has_entrypoints_fcfg(root)
	artifact := ""
	artifact_path := ""
	if is_game {
		emit_err: Emit_Error
		artifact, emit_err = emit_tree_artifact(root, project, sources, allocator)
		if emit_err != .None {
			return Build_Product{}, compile_failed_verdict(sources)
		}
		artifact_path = build_product_path(root, ARTIFACT_PRODUCT_NAME, allocator)
	}
	// project_err carries the real read_project cause when index_err is
	// Project_Read_Failed; the build verdict is coarse (Index_Failed) and does not
	// need the detail, but the seam no longer collapses it (a fix-it consumer can read it).
	index, index_err, _, compiled := read_index_project(root, allocator)
	if index_err != .None {
		return Build_Product{}, Build_Verdict{err = .Index_Failed}
	}
	if !compiled {
		return Build_Product{}, compile_failed_verdict(sources)
	}
	return Build_Product {
			artifact      = artifact,
			index         = index,
			artifact_path = artifact_path,
			index_path    = build_product_path(root, INDEX_PRODUCT_NAME, allocator),
		},
		Build_Verdict{}
}

// compile_failed_verdict builds the Compile_Failed verdict carrying the inner
// fix-criteria Diagnostic — the per-stage rejection (parse/gate/typecheck/
// contract/closure) of the first failing module. The emit/index paths above
// know ONLY that a checked-pipeline floor tripped (a coarse Emit_Error or
// `compiled = false`); the diagnostic-bearing project pipeline re-derives WHICH
// stage rejected WHERE, so the CLI renders `file:line:col: rule: message`
// instead of a bare `Compile_Failed`. It runs over the SAME combined source set
// the floor tripped on (own + §30 package_sources), so its first-failing-module
// diagnostic is the same fault the floor surfaced. A defensive .None (the floor
// said fail but the project pipeline finds none — an emit-only floor with no
// checked-pipeline cause) still returns the closed Compile_Failed arm with an
// empty diagnostic, so the exit-2 contract holds and the CLI falls back to the
// bare arm name (build_refusal_message). The Diagnostic's path is the failing
// module's source path so the CLI re-reads the right file.
compile_failed_verdict :: proc(sources: []Source) -> Build_Verdict {
	report := run_project_pipeline(sources)
	return Build_Verdict{err = .Compile_Failed, diagnostic = report.diagnostic}
}

// project_gate_verdict runs the §01 P5 structural gates over EVERY module of the
// source set — the same per-module gate pass the test pipeline applies
// (run_module_pipeline_diag's gate_verdict, run before typecheck) — and returns
// the FIRST module's overshoot as a Compile_Failed verdict carrying its
// path-stamped fix-criteria Diagnostic, or .None when every module clears. It is
// the gate stage_build was missing: the emit path runs the gates only over the
// entrypoint's flattened AST (so an imported module's body went unscored), and a
// package emits no artifact, so neither check nor build saw a per-module gate
// failure that `funpack test` rejects. A source that fails to PARSE contributes no
// verdict here — that parse error is surfaced precisely by the emit/index floor
// below (Compile_Failed), so the gate pass never masks a parse failure. Sources
// walk in their given order, so the named offender is deterministic and matches
// the test verb's first-failing module.
project_gate_verdict :: proc(sources: []Source) -> Build_Verdict {
	for source in sources {
		ast, ok := parse_source(source.path)
		if !ok {
			continue
		}
		if verdict := gate_verdict(ast); verdict.err != .None {
			diag := gate_diagnostic(verdict.err, verdict.line, verdict.declaration, verdict.nesting_cause)
			diag.path = source.path
			return Build_Verdict{err = .Compile_Failed, diagnostic = diag}
		}
	}
	return Build_Verdict{}
}

// project_first_decl walks every §14 source for the first declaration the
// pure-AST `predicate` flags (gates.odin's release_holed_decl / release_debug_decl,
// the two --release ban probes), returning it §15 module-qualified. Sources walk
// in the order the caller supplies — stage_build passes the Index Contract's
// module order (order_release_sources: entrypoint first, then sorted-by-path
// remainder) — and each AST in its source-ordered declaration sequence, so a
// multi-offender project always names the same first offender deterministically,
// and that offender is the first in index order. The name is §15 module-qualified
// (qualify_offender — bare on a single-module project, lore #11), matching the
// Index Contract's qualified_name so the refusal line and the index name the decl
// identically. A source that fails to read or parse contributes no verdict — the
// checked pipeline downstream surfaces that compile error precisely
// (Compile_Failed), so the ban never masks a parse failure with a hole/probe
// verdict.
project_first_decl :: proc(sources: []Source, predicate: proc(ast: Ast) -> (string, bool)) -> (declaration: string, found: bool) {
	for source in sources {
		ast, ok := parse_source(source.path)
		if !ok {
			continue
		}
		if name, hit := predicate(ast); hit {
			return qualify_offender(sources, source, name), true
		}
	}
	return "", false
}

// project_holed_decl is the --release typed-hole ban's project walk: the first §05
// hole-bearing declaration across the sources (release_holed_decl per AST).
project_holed_decl :: proc(sources: []Source) -> (declaration: string, holed: bool) {
	return project_first_decl(sources, release_holed_decl)
}

// project_debug_decl is the --release debug-directive ban's project walk: the
// first §05 §5 probe-bearing declaration across the sources (release_debug_decl
// per AST).
project_debug_decl :: proc(sources: []Source) -> (declaration: string, probed: bool) {
	return project_first_decl(sources, release_debug_decl)
}

// qualify_offender builds a release refusal's §15 module-qualified offender
// name from the source the offending declaration lives in, applying the index's
// single-module bare rule (lore #11, read_index_project): a one-source project
// qualifies decls to their bare names, a multi-module project prefixes the §15
// path-derived module — so the refusal names the decl exactly as the Index
// Contract's qualified_name would.
qualify_offender :: proc(sources: []Source, source: Source, name: string) -> string {
	module := source.module
	if len(sources) == 1 {
		module = ""
	}
	return qualify_decl(module, name)
}

// order_release_sources projects the §14 sources into the Index Contract's
// module order — the entrypoint module's source first, then the remainder in
// Project.sources order — by applying entrypoint_first_order, the SAME pure
// index permutation order_index_modules applies to the emitted decl blocks
// (never a duplicated ordering rule). The release-refusal walkers scan this
// order so the named offender is the first offender in the order the emitted
// index lists its declarations. A package (no entrypoints.fcfg ⇒ "" entrypoint,
// §30 §7) keeps the plain sources order, exactly like its index stream. The
// permutation is temp-allocated and never mutates Project.sources.
order_release_sources :: proc(root: string, sources: []Source) -> []Source {
	names := make([]string, len(sources), context.temp_allocator)
	for source, i in sources {
		names[i] = source.module
	}
	ordered := make([]Source, len(sources), context.temp_allocator)
	for src, dst in entrypoint_first_order(names, entrypoint_module_name(root)) {
		ordered[dst] = sources[src]
	}
	return ordered
}

// has_entrypoints_fcfg reports whether the §14 tree carries a funpack_configs/
// entrypoints.fcfg — the §30 §7 game-vs-package discriminant. A game declares an
// entrypoint (the pipeline the runtime artifact wires); a package omits it, so it
// has no runtime artifact. The file's presence alone is the discriminant — a
// present-but-malformed entrypoints.fcfg is a game whose compile fails downstream,
// never silently reclassified as a package.
has_entrypoints_fcfg :: proc(root: string) -> bool {
	path, _ := filepath.join({root, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	return os.exists(path)
}

// emit_tree_artifact emits the GAME's runtime artifact from its ENTRYPOINT
// module: it builds one project-wide module index over every source (so a
// multi-module game's entrypoint types cross-module — the arena example's
// arena_game imports arena_world + the arena seam), selects the source whose §15
// module is the entrypoints.fcfg `use <module>` clause, and drives it through
// stage_emit_indexed against that index. It reads the per-source inputs the
// emitter needs from the §14 tree: the entrypoint source bytes, its module name,
// the §14 project identity, and the entrypoints.fcfg text. The entrypoint module
// is the one whose pipeline the artifact wires, so emission's reference
// validation (§07) resolves the pipeline/bindings names against that module. It
// also builds the sibling module→AST map the §17 cross-module SEAM-FN CARRY and
// the v15 declaration carry read, so the entrypoint's imported seam fns/consts
// (krognid's `krognid_skeleton`/`krognid_parts`, dungeon's `terrain`) land in
// [functions] and its imported schema types land in their sections as
// self-contained records, and bakes the tree's levels/*.flvl (bake_tree_levels)
// so the artifact's [tilemaps] section carries the §18 §3 static environment —
// the dungeon's terrain reaches the runtime in the same build that emits its
// behaviors — the v15 [setup] fold carries each level's deterministic spawn
// batch, and the §12 §1 nav graphs derive from those same layers
// (bake_tree_nav_graphs) so the artifact's [nav] section carries the
// walkable-cell topology the runtime path-finds over, and bakes the tree's §19
// sprite assets (bake_tree_assets, only when an assets.manifest is present) so
// the artifact's [assets] section carries the decoded content-addressed image
// pixels + atlas slice rects a textured Draw_Sprite resolves against (schema
// v16). A read failure or any checked-pipeline floor surfaces as the
// stage_emit_indexed
// error, which stage_build maps to Compile_Failed (no artifact); a level that
// trips a §17.4/§18 §5 bake gate is the same exit-2 compile-error class,
// surfaced as Gate_Failed.
emit_tree_artifact :: proc(root: string, project: Project, sources: []Source, allocator := context.allocator) -> (artifact: string, err: Emit_Error) {
	entrypoint_path, _ := filepath.join({root, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	entrypoint_bytes, ep_err := os.read_entire_file_from_path(entrypoint_path, context.temp_allocator)
	if ep_err != nil {
		return "", .Entrypoint_Failed
	}
	entry_module := entrypoint_module_name(root)
	source, found := select_entrypoint_source(sources, entry_module)
	if !found {
		// No source provides the entrypoint module: either entrypoints.fcfg does
		// not parse (entry_module is "") or its `use <module>` clause names a
		// module the tree does not provide (a dangling `use`). Either way there is
		// no entrypoint module to emit, so emission refuses at the entrypoint stage
		// (mapped to Compile_Failed, no artifact).
		return "", .Entrypoint_Failed
	}
	source_bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
	if read_err != nil {
		return "", .Parse_Failed
	}
	index := build_project_module_index(sources)
	tilemaps, level_spawns, baked_ok := bake_tree_levels(root, sources, index, allocator)
	if !baked_ok {
		// A level that does not parse, a tileset/manifest the table cannot
		// build from, or any §17.4/§18 §5 bake gate: the build refuses before
		// emission — a malformed level is a compile error, never a silently
		// layer-less artifact.
		return "", .Gate_Failed
	}
	// The §12 §1 nav graphs are a SIBLING bake over the SAME baked tile layers
	// (bake_tree_nav_graphs, not folded into the tilemap bake): one flat graph
	// per layer in the same slice order, so the [nav] section mirrors [tilemaps].
	// A level-less tree has no layers, so the slice is empty (the `[nav 0]` tail).
	nav_graphs := bake_tree_nav_graphs(tilemaps, allocator)
	// The §19 [assets] sprite art (schema v16): the decoded content-addressed
	// image pixels + atlas slice rects a textured Draw_Sprite resolves against.
	// Baked only when the tree carries an assets.manifest (stage_build already
	// staleness-gated it); an asset-less tree threads the empty Baked_Assets (the
	// constant `[assets 0]` tail). A bake floor here is the same exit-2 compile
	// class as a level-bake floor — a malformed/missing asset refuses the build
	// rather than emitting a sprite-less artifact.
	assets := Baked_Assets{}
	if asset_tree_has_manifest(root) {
		baked_assets, assets_err, _ := bake_tree_assets(root, allocator)
		if assets_err != .None {
			return "", .Gate_Failed
		}
		assets = baked_assets
	}
	sibling_asts := build_sibling_module_asts(sources, source.module)
	identity := Project_Identity{name = project.name, version = project.version}
	return stage_emit_indexed(string(source_bytes), source.module, identity, string(entrypoint_bytes), index, sibling_asts, tilemaps, nav_graphs, level_spawns, assets, allocator)
}

// bake_tree_levels bakes every levels/*.flvl under the §14 tree and
// concatenates two artifact inputs: the §18 §3 tile layers (the [tilemaps]
// slice) and the per-level deterministic spawn batches (the v15 [setup] fold's
// input, one Level_Spawn_Batch per level keyed by its `<level>_spawns` seam
// extern name — the same name the committed .gen.fun seam declares, so the
// setup() call site and the batch key derive from one rule). Levels walk in
// sorted-filename order (the §14.4 deterministic subsystem walk) and each
// level's layers/spawns ride in declaration order, so both slices are a pure
// function of the tree. Each level bakes against its own `things <module>`
// schema source and the ONE project-global tile table (flvl_project_tile_table over
// every manifest-registered tileset — the tilemap-legend ADR's flat namespace).
// ok = false on ANY floor — an unreadable/unparsable level, a missing schema
// source, a manifest or tileset that cannot build the table, or a §17.4/§18 §5
// bake gate — so the caller refuses the build rather than emitting a partial
// environment. A tree with no levels/ directory returns empty slices (the
// level-less `[tilemaps 0]` tail and the resolve_setup_spawns [setup] path).
bake_tree_levels :: proc(root: string, sources: []Source, index: Module_Index, allocator := context.allocator) -> (layers: []Baked_Tile_Layer, level_spawns: []Level_Spawn_Batch, ok: bool) {
	level_paths := collect_level_paths(root)
	if len(level_paths) == 0 {
		return nil, nil, true
	}
	tilesets, tilesets_ok := read_tree_tilesets(root)
	if !tilesets_ok {
		return nil, nil, false
	}
	table, table_err := flvl_project_tile_table(tilesets, context.temp_allocator)
	if table_err != .None {
		return nil, nil, false
	}
	out := make([dynamic]Baked_Tile_Layer, 0, 2, allocator)
	batches := make([dynamic]Level_Spawn_Batch, 0, 2, allocator)
	for path in level_paths {
		level_bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
		if read_err != nil {
			return nil, nil, false
		}
		level, parse_err := parse_flvl(string(level_bytes))
		if parse_err != .None {
			return nil, nil, false
		}
		schema_source, has_schema := select_entrypoint_source(sources, level.things_module)
		if !has_schema {
			return nil, nil, false
		}
		schema_bytes, schema_read := os.read_entire_file_from_path(schema_source.path, context.temp_allocator)
		if schema_read != nil {
			return nil, nil, false
		}
		schema_ast, schema_parse := stage_parse(stage_lex(string(schema_bytes)))
		if schema_parse != .None {
			return nil, nil, false
		}
		baked, bake_err := bake_flvl(level, schema_ast, level.things_module, index, table)
		if bake_err != .None {
			return nil, nil, false
		}
		for layer in baked.tile_layers {
			append(&out, clone_tile_layer(layer, allocator))
		}
		append(&batches, Level_Spawn_Batch {
			fn_name = level_spawns_fn_name(baked, allocator),
			spawns  = clone_spawns(baked.spawns, allocator),
		})
	}
	return out[:], batches[:], true
}

// clone_spawns deep-copies one baked level's spawn list into the caller's
// allocator — the bake works in temp memory (bake_flvl's context.temp_allocator
// slices), and the emitted artifact must outlive the bake's scratch (the
// clone_tile_layer discipline applied to spawns).
clone_spawns :: proc(spawns: []Baked_Spawn, allocator := context.allocator) -> []Baked_Spawn {
	out := make([]Baked_Spawn, len(spawns), allocator)
	for spawn, i in spawns {
		cloned := spawn
		cloned.thing_type = strings.clone(spawn.thing_type, allocator)
		params := make([]Baked_Param, len(spawn.params), allocator)
		for param, j in spawn.params {
			params[j] = param
			params[j].field = strings.clone(param.field, allocator)
		}
		cloned.params = params
		out[i] = cloned
	}
	return out
}

// Baked_Nav_Graph is one §12 §1 navigation graph derived from a single baked
// tile layer (docs/artifact-format.md §18, schema v13) — the walkable-cell
// topology the runtime path-finds over. It is a FLAT graph: the §12 §1
// hierarchical decomposition stays invisible in the wire format, so the artifact
// carries one tier of nodes and one tier of edges, never a tree. `name` is the
// source layer's name (the same TilemapHandle constant name), so a nav record
// keys 1:1 to its tilemap record. nodes are the walkable cells' world-space
// CENTERS in ROW-MAJOR order — node index = row-major rank among walkable cells —
// because §12 §5 forbids exposing the raw Cell index, so the artifact leaks no
// col/row, only the cell-center Vec2. edges are the 4-neighbor orthogonal
// adjacencies between walkable cells, deduped and canonical (A < B).
Baked_Nav_Graph :: struct {
	name:  string,
	nodes: []Nav_Node,
	edges: []Nav_Edge,
}

// Nav_Node is one walkable cell's world-space CENTER as a Vec2 of raw Q32.32
// Fixed (docs/artifact-format.md §18) — the v12 anchor encoding (encode_fixed),
// reconstructed from the layer alone (anchor_x/anchor_y + col/row + half-cell).
// The col/row are NOT carried: §12 §5 exposes only the center, never the Cell
// index, so the runtime path-finds over centers and the artifact leaks no grid
// coordinate.
Nav_Node :: struct {
	x: Fixed,
	y: Fixed,
}

// Nav_Edge is one undirected 4-neighbor adjacency between two walkable cells,
// stored as two node indices into the row-major node list with `a < b`
// canonical (docs/artifact-format.md §18). The bake emits only the right
// (c+1) and down (r+1) neighbors so each undirected edge appears once, and the
// `a < b` ordering makes the pair canonical regardless of walk direction.
Nav_Edge :: struct {
	a: int,
	b: int,
}

// bake_tree_nav_graphs derives one §12 §1 nav graph per baked tile layer — a
// SIBLING to bake_tree_tile_layers (the tilemap/nav split §12/§18 keep, never
// folded into one bake), consuming the SAME []Baked_Tile_Layer in the SAME slice
// order so the [nav] section's record order mirrors [tilemaps] exactly. It is a
// pure function of the layers (no level re-read, no host nondeterminism §29): the
// walkable set, the centers, and the edges all derive from each layer's cells +
// palette + anchor alone. A walkable cell is an empty/marker cell
// (TILE_LAYER_EMPTY_CELL — markers sit on the floor) OR a non-solid tile
// (!palette[cells[i]].solid; palette[].solid is the single source of truth, §12
// §1). A level-less tree (no layers) returns the empty slice — the constant
// `[nav 0]` tail.
bake_tree_nav_graphs :: proc(layers: []Baked_Tile_Layer, allocator := context.allocator) -> []Baked_Nav_Graph {
	graphs := make([]Baked_Nav_Graph, len(layers), allocator)
	for layer, i in layers {
		graphs[i] = bake_layer_nav_graph(layer, allocator)
	}
	return graphs
}

// bake_layer_nav_graph derives one layer's flat nav graph: the walkable cells'
// row-major centers as nodes and their 4-neighbor orthogonal adjacencies as
// edges. The cell→node map is built first (row-major rank among walkable cells,
// TILE_LAYER_EMPTY_CELL or a non-solid tile), so an edge can name node indices
// rather than cell indices. Edges emit only the right (c+1) and down (r+1)
// neighbors, so each undirected adjacency appears once with `a < b` canonical and
// the edge list is in ascending (a, b) order (the row-major scan visits cells —
// and thus the smaller endpoint of every edge — in ascending node-index order).
bake_layer_nav_graph :: proc(layer: Baked_Tile_Layer, allocator := context.allocator) -> Baked_Nav_Graph {
	cell_to_node := make([]int, len(layer.cells), context.temp_allocator)
	node_count := 0
	for r in 0 ..< layer.rows {
		for c in 0 ..< layer.cols {
			cell := r * layer.cols + c
			if nav_cell_walkable(layer, layer.cells[cell]) {
				cell_to_node[cell] = node_count
				node_count += 1
			} else {
				cell_to_node[cell] = -1
			}
		}
	}
	nodes := make([]Nav_Node, node_count, allocator)
	edges := make([dynamic]Nav_Edge, 0, node_count * 2, allocator)
	half := fixed_div(to_fixed(layer.cell_size), to_fixed(2))
	for r in 0 ..< layer.rows {
		for c in 0 ..< layer.cols {
			cell := r * layer.cols + c
			node := cell_to_node[cell]
			if node < 0 {
				continue
			}
			// The center from the layer alone (flvl_cell_center math, flvl_bake.odin):
			// the grid's top-left corner is (anchor_x, anchor_y), col grows +x and
			// row grows -y, so the cell center is half a cell in from its corner.
			off := fixed_add(to_fixed(int_mul(i64(c), layer.cell_size)), half)
			nodes[node].x = fixed_add(layer.anchor_x, off)
			nodes[node].y = fixed_sub(layer.anchor_y, fixed_add(to_fixed(int_mul(i64(r), layer.cell_size)), half))
			// Undirected dedupe: emit only the right and down neighbors so each
			// adjacency appears once. The scan visits cells in row-major order, so
			// `node` is the smaller endpoint of every edge it opens — `a < b`.
			if c + 1 < layer.cols {
				if right := cell_to_node[cell + 1]; right >= 0 {
					append(&edges, Nav_Edge{a = node, b = right})
				}
			}
			if r + 1 < layer.rows {
				if down := cell_to_node[cell + layer.cols]; down >= 0 {
					append(&edges, Nav_Edge{a = node, b = down})
				}
			}
		}
	}
	return Baked_Nav_Graph{name = strings.clone(layer.name, allocator), nodes = nodes, edges = edges[:]}
}

// nav_cell_walkable reports whether a baked cell admits a nav node (§12 §1): an
// empty or marker cell (TILE_LAYER_EMPTY_CELL — a marker places an entity on the
// floor, never a solid) is walkable, and a tile cell is walkable iff its palette
// entry is NOT solid (palette[].solid is the single source of truth, §12 §1 —
// the same baked collision verdict the tilemap section carries). A solid tile
// (a wall, baked rubble) is the only non-walkable cell.
nav_cell_walkable :: proc(layer: Baked_Tile_Layer, cell: int) -> bool {
	if cell == TILE_LAYER_EMPTY_CELL {
		return true
	}
	return !layer.palette[cell].solid
}

// clone_tile_layer deep-copies one baked layer into the caller's allocator —
// the bake works in temp memory (bake_flvl's context.temp_allocator slices),
// and the emitted artifact must outlive the bake's scratch.
clone_tile_layer :: proc(layer: Baked_Tile_Layer, allocator := context.allocator) -> Baked_Tile_Layer {
	cloned := layer
	cloned.name = strings.clone(layer.name, allocator)
	// The §19 textured-render link (v17): the layer atlas and each palette tile's
	// atlas-cell coordinate ride the clone so they outlive the bake's temp scratch.
	cloned.atlas = strings.clone(layer.atlas, allocator)
	palette := make([]Baked_Tile, len(layer.palette), allocator)
	for tile, i in layer.palette {
		palette[i] = Baked_Tile{name = strings.clone(tile.name, allocator), solid = tile.solid, cell_x = tile.cell_x, cell_y = tile.cell_y}
	}
	cells := make([]int, len(layer.cells), allocator)
	copy(cells, layer.cells)
	cloned.palette = palette
	cloned.cells = cells
	return cloned
}

// collect_level_paths walks levels/ for the tree's *.flvl authoring files in
// sorted-filename order — the same deterministic order the §14.4 capability
// reader derives its expected gen/ outputs in, so the [tilemaps] section order
// never depends on the directory walk. An absent levels/ (or one holding no
// .flvl) returns the empty slice — the level-less tree.
collect_level_paths :: proc(root: string) -> []string {
	dir, _ := filepath.join({root, "levels"}, context.temp_allocator)
	if !os.is_dir(dir) {
		return nil
	}
	paths := make([dynamic]string, 0, 4, context.temp_allocator)
	walker := os.walker_create(dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular || !strings.has_suffix(info.name, ".flvl") {
			continue
		}
		append(&paths, strings.clone(info.fullpath, context.temp_allocator))
	}
	slice.sort(paths[:])
	return paths[:]
}

// read_tree_tilesets imports every manifest-registered tileset under assets/ —
// the inputs flvl_project_tile_table aggregates into the §18 §3 project-global tile
// namespace. The committed assets.manifest is the source of truth (§19 §3): a
// tileset entry's source file imports with the entry's declared dependency
// hashes (a tileset deps-on its atlas, §19 §5). A tree with no manifest has no
// registered tilesets (the empty table — a legend tile name then trips the
// Unknown_Tile_Name gate honestly); a PRESENT manifest that does not parse, or
// a registered tileset whose source is unreadable or rejects its importer, is
// ok = false — fail-closed, never a silently empty namespace.
read_tree_tilesets :: proc(root: string) -> (tilesets: []Tileset_Asset, ok: bool) {
	manifest_path, _ := filepath.join({root, "assets", "assets.manifest"}, context.temp_allocator)
	manifest_bytes, read_err := os.read_entire_file_from_path(manifest_path, context.temp_allocator)
	if read_err != nil {
		return nil, true
	}
	manifest, manifest_err := read_asset_manifest(string(manifest_bytes))
	if manifest_err != .None {
		return nil, false
	}
	out := make([dynamic]Tileset_Asset, 0, 2, context.temp_allocator)
	for entry in manifest.entries {
		if entry.kind != .Tileset {
			continue
		}
		source_path, _ := filepath.join({root, "assets", entry.source}, context.temp_allocator)
		source_bytes, source_err := os.read_entire_file_from_path(source_path, context.temp_allocator)
		if source_err != nil {
			return nil, false
		}
		tileset, import_err := import_tileset(string(source_bytes), entry.deps, context.temp_allocator)
		if import_err != .None {
			return nil, false
		}
		append(&out, tileset)
	}
	return out[:], true
}

// build_sibling_module_asts parses every source EXCEPT the entrypoint module and
// returns a §15 module-name → AST map — the sibling-module bodies the §17 seam-fn
// carry reads (collect_imported_fn_records). The entrypoint module is excluded so
// the carry never re-emits the entrypoint's own fns (it already walks that AST in
// emit_functions); only sibling modules (the rig seam) contribute carried records.
// A source that fails to read or parse contributes no entry — the entrypoint's own
// typecheck surfaces a real cross-module error precisely, so the map never aborts
// the build over one sibling's read failure. A single-module game yields an empty
// map, so the carry adds nothing.
build_sibling_module_asts :: proc(sources: []Source, entry_module: string) -> map[string]Ast {
	asts := make(map[string]Ast, len(sources), context.temp_allocator)
	for s in sources {
		if s.module == entry_module {
			continue
		}
		ast, ok := parse_source(s.path)
		if !ok {
			continue
		}
		asts[s.module] = ast
	}
	return asts
}

// select_entrypoint_source finds the source whose §15 module is the entrypoints.fcfg
// `use <module>` clause — the entrypoint module the artifact emits. An empty
// `module` (a malformed entrypoints.fcfg that did not parse to a `use` clause) or
// a name no source provides returns found = false, so emission refuses rather
// than picking an arbitrary module. It is a linear scan over the small source
// set, so no map reaches the deterministic selection.
select_entrypoint_source :: proc(sources: []Source, module: string) -> (source: Source, found: bool) {
	if module == "" {
		return Source{}, false
	}
	for s in sources {
		if s.module == module {
			return s, true
		}
	}
	return Source{}, false
}

// build_project_module_index builds the project-wide module index over every §14
// source — the cross-module CALL/type surface the entrypoint module's typecheck
// resolves through. It mirrors run_project_pipeline's index build: read + parse
// each source, then build_module_index_typed over the (module, ast) pairs. A
// source that fails to read or parse is skipped from the index (its empty AST
// contributes no exports); the entrypoint module's own typecheck surfaces the
// real error precisely, so the index never aborts the build over one module's
// read failure. An empty source set yields the empty index (the single-source
// path).
build_project_module_index :: proc(sources: []Source) -> Module_Index {
	modules := make([]string, len(sources), context.temp_allocator)
	asts := make([]Ast, len(sources), context.temp_allocator)
	package_roots := make([]string, len(sources), context.temp_allocator)
	for source, i in sources {
		modules[i] = source.module
		// The §30 package_roots ride in lockstep with the modules (the
		// run_project_pipeline discipline) so a dep module's exports gate
		// through the §30 §6 expose edge and its own imports resolve from
		// its own vantage.
		package_roots[i] = source.package_root
		ast, ok := parse_source(source.path)
		if !ok {
			continue
		}
		asts[i] = ast
	}
	return build_module_index_typed(modules, asts, package_roots)
}

// build_product_path joins the project root, the `.funpack/` derived directory,
// and a product's leaf name into the product's output path. The path is derived
// from the root alone (§14 §1) — no machine-specific or project-name component —
// so two builds of the same tree at the same root resolve the same paths.
build_product_path :: proc(root: string, leaf: string, allocator := context.allocator) -> string {
	path, _ := filepath.join({root, FUNPACK_BUILD_DIR, leaf}, allocator)
	return path
}

// Build_Write_Error is closed with one arm per filesystem failure writing the
// products. Mkdir_Failed is a failure creating the `.funpack/` directory;
// Write_Artifact_Failed / Write_Index_Failed are failures writing the respective
// product. The write is all-or-nothing: a failure writing the second product
// removes the first before returning, so an exit-2 build never leaves a
// partial product set from THIS invocation on disk (§29 §3 — a failed build
// writes neither product).
Build_Write_Error :: enum {
	None,
	Mkdir_Failed,
	Write_Artifact_Failed,
	Write_Index_Failed,
}

// write_build_products writes the build's products under `.funpack/` (creating
// the directory if absent), overwriting any prior build's products. It is the
// impure write side stage_build deliberately omits: stage_build computes the
// bytes and paths purely, this commits them to disk. A GAME writes both the
// artifact and the index; a PACKAGE (§30 §7) has an empty artifact_path — there
// is no runtime artifact — so the artifact write is skipped and only the index
// lands. The directory is created idempotently — an existing `.funpack/` is
// reused, not an error — so a rebuild overwrites in place.
write_build_products :: proc(product: Build_Product, root: string) -> Build_Write_Error {
	build_dir, _ := filepath.join({root, FUNPACK_BUILD_DIR}, context.temp_allocator)
	if mk_err := os.make_directory(build_dir); mk_err != nil && mk_err != os.General_Error.Exist {
		return .Mkdir_Failed
	}
	wrote_artifact := false
	if product.artifact_path != "" {
		if write_err := os.write_entire_file(product.artifact_path, transmute([]u8)product.artifact); write_err != nil {
			return .Write_Artifact_Failed
		}
		wrote_artifact = true
	}
	if write_err := os.write_entire_file(product.index_path, transmute([]u8)product.index); write_err != nil {
		// All-or-nothing per kind: a game's artifact is already on disk, so a
		// failed index write removes it before reporting — an exit-2 build leaves
		// no partial product set behind. A package wrote no artifact, so there is
		// nothing to roll back.
		if wrote_artifact {
			os.remove(product.artifact_path)
		}
		return .Write_Index_Failed
	}
	return .None
}
