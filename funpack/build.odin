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
}

// Build_Verdict is the build seam's refusal verdict: the closed Build_Error arm
// plus the diagnostic payload the arm carries. offender is the §15
// module-qualified name of the offending declaration on the two release-refusal
// arms (Holed_Declaration — the holed decl; Debug_Directive — the probed decl),
// "" on every other arm. The struct exists so the CLI refusal line can NAME the
// declaration an agent must repair without stringly-typing the error kind: the
// arm stays the closed enum, the name rides beside it. The zero value is the
// clean verdict (err = .None, no offender).
Build_Verdict :: struct {
	err:      Build_Error,
	offender: string,
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
	project, project_err := read_project(root)
	if project_err != .None {
		return Build_Product{}, Build_Verdict{err = .Malformed_Tree}
	}
	if len(project.sources) == 0 {
		return Build_Product{}, Build_Verdict{err = .Malformed_Tree}
	}
	if mode == .Release {
		// Both refusal walkers scan the sources in the Index Contract's module
		// order (entrypoint module first, then sorted-by-path remainder) so the
		// named offender is the first offender in the order the emitted index
		// lists its decl blocks — never a plain sorted-by-path artifact.
		scan_sources := order_release_sources(root, project.sources)
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
	// A package has no entrypoints.fcfg, so there is no entrypoint module and no
	// runtime artifact to emit (§30 §7). The Index Contract is the package's
	// single product — its index path is set, the artifact path stays empty.
	is_game := has_entrypoints_fcfg(root)
	artifact := ""
	artifact_path := ""
	if is_game {
		emit_err: Emit_Error
		artifact, emit_err = emit_tree_artifact(root, project, allocator)
		if emit_err != .None {
			return Build_Product{}, Build_Verdict{err = .Compile_Failed}
		}
		artifact_path = build_product_path(root, ARTIFACT_PRODUCT_NAME, allocator)
	}
	index, index_err, compiled := read_index_project(root, allocator)
	if index_err != .None {
		return Build_Product{}, Build_Verdict{err = .Index_Failed}
	}
	if !compiled {
		return Build_Product{}, Build_Verdict{err = .Compile_Failed}
	}
	return Build_Product {
			artifact      = artifact,
			index         = index,
			artifact_path = artifact_path,
			index_path    = build_product_path(root, INDEX_PRODUCT_NAME, allocator),
		},
		Build_Verdict{}
}

// project_holed_decl walks every §14 source for the first §05 typed-hole
// declaration — the project-wide form of the pure-AST release_holed_decl
// (gates.odin) the --release hole-ban consults. Sources walk in the order the
// caller supplies — stage_build passes the Index Contract's module order
// (order_release_sources: entrypoint first, then sorted-by-path remainder) —
// and each AST in declaration order, so a multi-hole project always names the
// same first offender deterministically, and that offender is the first in
// index order. The returned declaration is §15 module-qualified
// (qualify_offender — bare on a single-module project, lore #11), matching the
// Index Contract's qualified_name so the refusal line and the index name the
// decl identically.
// A source that fails to read or parse contributes no verdict here — the
// checked pipeline downstream surfaces that compile error precisely
// (Compile_Failed), so the ban never masks a parse failure with a hole verdict.
project_holed_decl :: proc(sources: []Source) -> (declaration: string, holed: bool) {
	for source in sources {
		bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
		if read_err != nil {
			continue
		}
		ast, parse_err := stage_parse(stage_lex(string(bytes)))
		if parse_err != .None {
			continue
		}
		if name, found := release_holed_decl(ast); found {
			return qualify_offender(sources, source, name), true
		}
	}
	return "", false
}

// project_debug_decl walks every §14 source for the first declaration carrying
// a §05 §5 debug probe — the project-wide form of the pure-AST
// release_debug_decl (gates.odin) the --release debug-directive ban consults,
// mirroring project_holed_decl exactly. Sources walk in the order the caller
// supplies — stage_build passes the Index Contract's module order
// (order_release_sources: entrypoint first, then sorted-by-path remainder) —
// and each AST in the fixed per-kind declaration order, so a multi-probe
// project always names the same first offender deterministically, and that
// offender is the first in index order. The returned declaration is §15 module-qualified
// (qualify_offender — bare on a single-module project, lore #11), matching the
// Index Contract's qualified_name so the refusal line and the index name the
// decl identically. A source that fails to read or parse contributes
// no verdict here — the checked pipeline downstream surfaces that compile
// error precisely (Compile_Failed), so the ban never masks a parse failure
// with a probe verdict.
project_debug_decl :: proc(sources: []Source) -> (declaration: string, probed: bool) {
	for source in sources {
		bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
		if read_err != nil {
			continue
		}
		ast, parse_err := stage_parse(stage_lex(string(bytes)))
		if parse_err != .None {
			continue
		}
		if name, found := release_debug_decl(ast); found {
			return qualify_offender(sources, source, name), true
		}
	}
	return "", false
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
// also builds the sibling module→AST map the §17 cross-module SEAM-FN CARRY reads,
// so the entrypoint's imported seam fns (krognid's `krognid_skeleton`/
// `krognid_parts`) land in [functions] as self-contained records. A read failure or
// any checked-pipeline floor surfaces as the stage_emit_indexed error, which
// stage_build maps to Compile_Failed (no artifact).
emit_tree_artifact :: proc(root: string, project: Project, allocator := context.allocator) -> (artifact: string, err: Emit_Error) {
	entrypoint_path, _ := filepath.join({root, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	entrypoint_bytes, ep_err := os.read_entire_file_from_path(entrypoint_path, context.temp_allocator)
	if ep_err != nil {
		return "", .Entrypoint_Failed
	}
	entry_module := entrypoint_module_name(root)
	source, found := select_entrypoint_source(project.sources, entry_module)
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
	index := build_project_module_index(project.sources)
	sibling_asts := build_sibling_module_asts(project.sources, source.module)
	identity := Project_Identity{name = project.name, version = project.version}
	return stage_emit_indexed(string(source_bytes), source.module, identity, string(entrypoint_bytes), index, sibling_asts, allocator)
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
		bytes, read_err := os.read_entire_file_from_path(s.path, context.temp_allocator)
		if read_err != nil {
			continue
		}
		ast, parse_err := stage_parse(stage_lex(string(bytes)))
		if parse_err != .None {
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
	for source, i in sources {
		modules[i] = source.module
		bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
		if read_err != nil {
			continue
		}
		ast, parse_err := stage_parse(stage_lex(string(bytes)))
		if parse_err != .None {
			continue
		}
		asts[i] = ast
	}
	return build_module_index_typed(modules, asts)
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
