// Project-tree reader for the §14-enforced layout: funpack errors on a
// malformed tree as it errors on a malformed function — there is no
// alternative arrangement and no override flag. This file owns the §14
// *smaller* config grammar in two productions over one shared lexer
// (lex_fcfg):
//   - project.fcfg: a single `project <name> { … }` block whose label IS the
//     package name, carrying the required `version = "…"`, plus `key = value`
//     string assignments and `@doc` directives. It has no expressions, no
//     control flow, and no `use` references — project identity names no source
//     (§14.2).
//   - entrypoints.fcfg (§23/§07): a `use module.{members}` source reference
//     and `entrypoint <name> { pipeline = …, tick = …hz, logical = WxH, bindings = … }`
//     blocks, whose pipeline/bindings references are validated against the
//     source module — a dangling reference rejects.
// Both grammars share the closed config token set; a tree that violates either
// is rejected, never silently ignored.
package funpack

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// RESERVED_ROOT is the single §15 reserved namespace root: the built-in
// stdlib package occupies `engine`, and the set is closed and
// compiler-fixed. A user source path whose derived module would fall
// under `engine` (or be `engine` itself) shadows that root, which §15.7
// makes a compile error — reserved roots are unshadowable.
RESERVED_ROOT :: "engine"

// Source pairs a collected `.fun` file's on-disk path with its
// path-derived module name (§15): a file's module IS its location under
// the source root, directory segments dotted and filename as the leaf,
// with no `module` keyword to declare or drift. The two travel together
// so identity comes from config and the filesystem, never a hardcode.
// package_root is "" for the project's own sources (src/ and gen/); a §30
// path dependency's sources carry their package's project name — the root
// namespace their module is prefixed under (`hexgrid.layout`) and the edge
// the §30 §6 expose gate reads.
Source :: struct {
	path:         string,
	module:       string,
	package_root: string,
}

Project :: struct {
	name:         string,
	version:      string,
	sources:      []Source,
	// builds is the parsed builds.fcfg (§14.4/§6): the presentation platform
	// targets the build driver emits. It is read off the tree alongside
	// identity and sources, so a Project carries its declared emit targets.
	builds:       Builds,
	// capabilities is the §14.4 derived-capability set: which subsystem
	// directories (levels/models/ui/assets) are present-and-non-empty, and the
	// committed gen/ seam each ON subsystem is expected to have baked. It is
	// derived from the filesystem, never declared — there is no features config
	// (§14 §4) — so it travels with the Project as a fact of the tree.
	capabilities: Capabilities,
	// deps is the parsed funpack_configs/deps.fcfg (§30 §3): the declared
	// dependencies across all four provenance sources. Absent file = zero
	// deps (deps.fcfg is optional; a stdlib-only game has none).
	deps:         []Dep,
	// package_sources is the §30 path-dependency source set: every path dep's
	// .fun sources, modules prefixed under the dependency's project name
	// (`hexgrid.layout`) with package_root stamped. Kept distinct from
	// `sources` so the project's own walks (fmt, emit ordering, the index
	// contract) are untouched; the test pipeline compiles BOTH sets against
	// one index (project_pipeline_sources). Registry/url deps are pin-verified
	// over their vendored trees at read time (verify_vendored_deps, §30 §4)
	// but their sources are not resolved into this set yet — that lands
	// later behind the same pin gate.
	package_sources: []Source,
}

// Build_Platform is the closed §14.4/§6 presentation-platform set a build
// target selects. builds.fcfg declares the presentation platform and nothing
// else (no realm field — the server/client split is derived from source, §14
// §6), so the value set is exactly `desktop` and `wasm`. The set is closed and
// compiler-fixed: a new platform is a deliberate addition here, never a
// silently-accepted string — an unknown platform value rejects the tree.
Build_Platform :: enum {
	Desktop,
	Wasm,
}

// Build_Target is one `build <name> { platform = … }` block of builds.fcfg:
// the build's label (a name distinct from the platform — the arena exemplar
// labels its single target `native`) and its closed presentation platform.
Build_Target :: struct {
	name:     string,
	platform: Build_Platform,
}

// Builds is the parsed builds.fcfg: the declared build targets in authored
// order. An empty-but-present (or absent) builds.fcfg yields zero targets — a
// tree may declare no emit targets — but a present file with a non-grammar
// construct or an unknown platform value rejects (§14.4).
Builds :: struct {
	targets: []Build_Target,
}

// Capabilities is the §14.4 derived-capability set over the four
// directory-backed subsystems: each flag is ON when its authoring directory is
// present-and-non-empty (holds the subsystem's authoring files), OFF when the
// directory is absent or present-but-empty (the same arm — both mean the
// feature is off). For each ON subsystem, the matching gen/ seam(s) are
// expected: one gen/<stem>.gen.fun per authoring file (levels/arena.flvl ⇒
// gen/arena.gen.fun). The expected-output paths are derived from the authoring
// filenames, never declared. This struct does NOT read or compare seam
// contents (the harness story) and does NOT join gen/ into the source set (the
// seam-import story) — it only records what the tree declares and what gen/
// outputs that declaration expects.
Capabilities :: struct {
	levels:           bool,
	models:           bool,
	ui:               bool,
	assets:           bool,
	expected_gen_out: []string,
}

Project_Error :: enum {
	None,
	Missing_Configs_Dir,
	Missing_Project_Fcfg,
	Malformed_Project_Fcfg,
	Missing_Project_Version,
	Missing_Src_Dir,
	No_Sources,
	// Reserved_Engine_Root is the §15.7 reserved-root collision: a user
	// source path under `src/engine/…` (or a bare `src/engine.fun`)
	// derives a module under the reserved `engine` stdlib namespace,
	// which is unshadowable. A dedicated arm, never folded into
	// No_Sources or Malformed — the error names a specific §15 rule.
	Reserved_Engine_Root,
	// Duplicate_Module is the §15.6 module-identity collision: two distinct
	// source paths deriving the same module name — e.g. a dotted filename
	// `src/a.b.fun` against a nested `src/a/b.fun`, both deriving `a.b`.
	// §15.6 makes two sources producing the same module name a compile
	// error (an import site could resolve to either), and the collision
	// fails the whole tree. A dedicated arm, never a catch-all.
	Duplicate_Module,
	// Malformed_Builds_Fcfg is the §14.4 builds.fcfg grammar reject: a
	// present builds.fcfg that violates the `build <name> { platform =
	// desktop|wasm }` production — a missing label, a missing platform key,
	// an unknown platform value (the platform set is closed), or any
	// non-grammar construct. A dedicated arm, never folded into the
	// project.fcfg's Malformed_Project_Fcfg: the error names a specific §14.4
	// rule (the builds production), not the identity production.
	Malformed_Builds_Fcfg,
	// Malformed_Seam is a gen/*.gen.fun seam the §06/§07 grammar cannot read:
	// a file the lexer/parser rejects, or one the reader cannot read off disk.
	// A committed seam is canonical funpack the bake pipeline emitted, so a seam
	// that does not lex+parse is a stale/corrupt baked output — a tree-level
	// compile error, distinct from a hand-written src/ source's pipeline error
	// (the test verb reports those per-source). A dedicated arm so a broken seam
	// is never confused with a malformed authoring config.
	Malformed_Seam,
	// Seam_Imports_Behavior is the §17 module-layering reject: a generated seam
	// (gen/*.gen.fun) imports a BEHAVIOR module — a user module that declares
	// `behavior`s or a `pipeline`. §17 keeps the schema → seam → behavior import
	// graph acyclic BY CONSTRUCTION: a seam imports schema modules + engine.*
	// only; a behavior module imports schema + seam. A seam importing a behavior
	// module closes the cycle (behavior → seam → behavior), so it is a compile
	// error. A dedicated arm, never a catch-all — the error names the specific
	// §17 layering invariant the bake pipeline rests on.
	Seam_Imports_Behavior,
	// Malformed_Deps_Fcfg is the §30 §3 deps.fcfg grammar reject: a present
	// deps.fcfg that violates the `use <name> <source> "…" [hash "…"]`
	// production — an unknown source kind (the set is closed: version/path/
	// url), a registry/url dep missing its required hash, a hash on a path
	// dep (the table grants path deps none), a duplicate dependency name
	// (one name, one dependency), or any non-grammar construct. A dedicated
	// arm naming the deps production, never folded into another config's.
	Malformed_Deps_Fcfg,
	// Malformed_Package_Tree is a §30 §7 path dependency whose tree is not a
	// well-formed PACKAGE: a missing/malformed funpack_configs/project.fcfg,
	// a missing or empty src/, or a present entrypoints.fcfg — a package is
	// structurally a project WITHOUT an entrypoint (a game runs, a package is
	// imported), so a tree that runs cannot be depended on as a package.
	Malformed_Package_Tree,
	// Dep_Name_Mismatch is a deps.fcfg `use <name>` whose path dependency's
	// own project.fcfg declares a DIFFERENT project name. The package name is
	// its root namespace (§30 §7) and project.fcfg's label is the package
	// identity (§14 §4), so a declaration naming one identity while the tree
	// carries another is the same label/identity drift class §30 §4 makes a
	// compile error for hashes — refused, never silently reconciled.
	Dep_Name_Mismatch,
	// Package_Imports_Package is the §30 §2 star-graph violation surfaced
	// STRUCTURALLY: a path dependency's own tree declares dependencies (a
	// non-empty funpack_configs/deps.fcfg). A package depends only on engine —
	// it may not depend on another package — so the dependency graph stays a
	// star with the consuming game as its hub. The import-level twin lives in
	// Type_Error (a package module's import reaching beyond engine + itself).
	Package_Imports_Package,
	// Package_Shadows_Engine_Root is a path dependency whose project name is
	// (or falls under) the reserved `engine` root: the package name joins
	// `engine` as a root namespace (§30 §7), and reserved roots are
	// unshadowable (§15 §7), so a package named like the engine root is
	// refused before any of its sources are read.
	Package_Shadows_Engine_Root,
	// Module_Shadows_Package_Root is the consumer-side half of §30 §7's
	// reserved-root sentence: the package name joins `engine` as a reserved
	// root, so a local module named like a declared dependency's root
	// namespace (a `src/hexgrid.fun` — or anything under `src/hexgrid/` —
	// beside a `use hexgrid` dep) shadows the dependency and is a compile
	// error.
	Module_Shadows_Package_Root,
	// Missing_Vendored_Package is a declared registry/url dependency whose
	// pinned vendored tree is absent (no packages/<name>/, §30 §4) or
	// unreadable. Builds never touch the network — hermetic, §30 §4 — so a
	// pin with nothing on disk to verify refuses naming the missing vendored
	// tree, never fetches; vendoring is a separate authored act the author
	// commits and reviews.
	Missing_Vendored_Package,
	// Package_Hash_Mismatch is the §30 §4 pin gate's refusal: re-hashing a
	// registry/url dep's vendored packages/<name>/ tree at project-read time
	// produced a hash that is not byte-equal to the declared pin — local
	// tampering or an unreviewed source change. Exact match or refusal, no
	// partial acceptance (the Index Contract discipline, §29 §2); the
	// verify_vendored_deps fix-it carries the actual hash so the author can
	// review the vendored diff and re-pin deliberately (§30 §5).
	Package_Hash_Mismatch,
}

// read_project's detail return is the uniform one-line advisory channel every
// Project_Error arm rides — the named-offender refusal-line discipline build
// refusals follow (Build_Verdict.offender), applied at project-read time. The
// closed enum stays the machine contract; detail is advisory text naming the
// offender or carrying the fix-it ("" when an arm has no payload yet), so a
// CLI refusal line tells the agent exactly what to repair without any verb
// growing arm-by-arm prose.
read_project :: proc(root: string) -> (project: Project, err: Project_Error, detail: string) {
	configs_dir, _ := filepath.join({root, "funpack_configs"}, context.temp_allocator)
	if !os.is_dir(configs_dir) {
		return Project{}, .Missing_Configs_Dir, ""
	}
	fcfg_path, _ := filepath.join({configs_dir, "project.fcfg"}, context.temp_allocator)
	fcfg_bytes, read_err := os.read_entire_file_from_path(fcfg_path, context.temp_allocator)
	if read_err != nil {
		return Project{}, .Missing_Project_Fcfg, ""
	}
	identity, parse_err := parse_project_fcfg(string(fcfg_bytes))
	if parse_err != .None {
		return Project{}, parse_err, ""
	}
	src_sources, src_err, src_detail := collect_sources(root)
	if src_err != .None {
		return Project{}, src_err, src_detail
	}
	builds, builds_err := read_builds_fcfg(configs_dir)
	if builds_err != .None {
		return Project{}, builds_err, ""
	}
	capabilities := derive_tree_capabilities(root)
	// A baked gen/*.gen.fun seam joins the source set so it rides the same
	// lex → parse → … pipeline any .fun module does (§17 seam #4). The gen/ root
	// is a derived source root peer to src/: its module derives by stripping the
	// gen/ prefix exactly as src/ is stripped (gen/arena.gen.fun ⇒ `arena`, NOT
	// `gen.arena`). The src/ and gen/ sets merge into one source set, re-running
	// the §15.6 duplicate-module and §15.7 reserved-root checks across the
	// COMBINED set so a seam colliding with a hand-written module fails the tree.
	seam_sources, seam_collect_err := collect_seam_sources(root, capabilities)
	if seam_collect_err != .None {
		return Project{}, seam_collect_err, ""
	}
	sources, merge_err, merge_detail := merge_sources(src_sources, seam_sources)
	if merge_err != .None {
		return Project{}, merge_err, merge_detail
	}
	// §17 acyclic layering: a generated seam imports schema modules + engine.*
	// only. A seam importing a behavior module closes the import cycle, so it is
	// a compile error (Seam_Imports_Behavior). The check runs over the combined
	// set so it can classify every imported user module by its declarations.
	if layer_err := check_seam_layering(seam_sources, sources); layer_err != .None {
		return Project{}, layer_err, ""
	}
	// §30: the optional deps.fcfg declares the dependency set; each PATH dep
	// resolves to a package tree whose sources join the build under the
	// dependency's project name as root namespace (deps.odin). The shadow
	// check runs over the COMBINED consumer set (src/ + gen/) so a seam-
	// derived module shadowing a package root is caught too.
	deps, deps_err := read_deps_fcfg(configs_dir)
	if deps_err != .None {
		return Project{}, deps_err, ""
	}
	// §30 §4: every registry/url pin verifies over its committed vendored
	// tree BEFORE any package source joins the build, so check/build/test
	// all gate alike at project-read time. The closed arm is the machine
	// contract; the fix-it riding beside it is the detail line (path deps
	// are skipped inside — §30 §3 grants them no hash).
	if verify_err, fix_it := verify_vendored_deps(root, deps); verify_err != .None {
		return Project{}, verify_err, fix_it
	}
	package_sources, pkg_err, pkg_detail := collect_package_sources(root, deps)
	if pkg_err != .None {
		return Project{}, pkg_err, pkg_detail
	}
	if shadow_err, shadow_detail := check_package_root_shadowing(sources, deps); shadow_err != .None {
		return Project{}, shadow_err, shadow_detail
	}
	return Project {
			name = identity.name,
			version = identity.version,
			sources = sources,
			builds = builds,
			capabilities = capabilities,
			deps = deps,
			package_sources = package_sources,
		},
		.None,
		""
}

// project_refusal_message renders one project-read refusal line: the closed
// arm name, with the advisory detail appended when the arm carries one — the
// build_refusal_message mold, so every CLI verb prints refusals through one
// channel instead of growing arm-by-arm prose.
project_refusal_message :: proc(err: Project_Error, detail: string, allocator := context.allocator) -> string {
	if detail == "" {
		return fmt.aprintf("%v", err, allocator = allocator)
	}
	return fmt.aprintf("%v: %s", err, detail, allocator = allocator)
}

// read_builds_fcfg reads the optional builds.fcfg out of the configs dir and
// parses it through the §14.4 builds grammar. An absent file is zero declared
// targets (a tree may declare no emit targets), never an error — mirroring the
// authored-config readers (read_builds, read_tag_registry) that treat absence
// as an empty-but-present field. A present file that violates the grammar
// surfaces Malformed_Builds_Fcfg.
read_builds_fcfg :: proc(configs_dir: string) -> (builds: Builds, err: Project_Error) {
	path, _ := filepath.join({configs_dir, "builds.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return Builds{}, .None
	}
	return parse_builds_fcfg(string(bytes))
}

// Project_Identity is the §14 project.fcfg payload: the block label as the
// package name plus the required version value.
Project_Identity :: struct {
	name:    string,
	version: string,
}

// parse_project_fcfg parses the §14 smaller config grammar for
// project.fcfg into the project identity, or rejects a tree that violates
// it. The grammar is: a sequence of top-level `@doc(…)` directives and
// exactly one `project <name> { … }` block, whose body is `key = value`
// assignments and `@doc(…)` directives. `version` is the one required key.
// Any token outside that grammar — a key without `=`, a `use` reference,
// an expression, a control-flow keyword — is a Malformed_Project_Fcfg
// rejection. A well-formed block missing `version` is the dedicated
// Missing_Project_Version diagnostic.
parse_project_fcfg :: proc(content: string) -> (identity: Project_Identity, err: Project_Error) {
	p := Cfg_Parser{tokens = lex_fcfg(content)}
	saw_block := false
	for !cfg_at_end(&p) {
		#partial switch cfg_peek(&p).kind {
		case .At:
			cfg_skip_doc(&p) or_return
		case .Ident:
			// The only legal top-level identifier is the `project` block
			// opener; a stray top-level `key = value` or any other
			// keyword (a `use` reference, a control-flow word) is not part
			// of the project-identity grammar.
			if cfg_peek(&p).text != "project" || saw_block {
				return Project_Identity{}, .Malformed_Project_Fcfg
			}
			identity, err = cfg_parse_block(&p)
			if err != .None {
				return Project_Identity{}, err
			}
			saw_block = true
		case:
			return Project_Identity{}, .Malformed_Project_Fcfg
		}
	}
	if !saw_block {
		return Project_Identity{}, .Malformed_Project_Fcfg
	}
	return identity, .None
}

// cfg_parse_block parses `project <name> { … }`. The label is mandatory
// (a labelless `project { … }` is rejected) and becomes the package name;
// the body carries `key = value` assignments and `@doc` directives, with
// `version` required.
cfg_parse_block :: proc(p: ^Cfg_Parser) -> (identity: Project_Identity, err: Project_Error) {
	cfg_expect(p, .Ident) or_return // `project`
	label := cfg_expect(p, .Ident) or_return // the package-name label
	cfg_expect(p, .L_Brace) or_return
	name := label.text
	version := ""
	saw_version := false
	for cfg_peek(p).kind != .R_Brace {
		#partial switch cfg_peek(p).kind {
		case .At:
			cfg_skip_doc(p) or_return
		case .Ident:
			key, value := cfg_parse_assignment(p) or_return
			if key == "version" {
				version = value
				saw_version = true
			}
		case:
			// End of input before `}` (Invalid), or any non-assignment,
			// non-doc construct inside the block.
			return Project_Identity{}, .Malformed_Project_Fcfg
		}
	}
	cfg_expect(p, .R_Brace) or_return
	if !saw_version {
		return Project_Identity{}, .Missing_Project_Version
	}
	return Project_Identity{name = name, version = version}, .None
}

// cfg_parse_assignment parses a single `key = "value"` pair. A key without
// `=` (the lexical tell that separates config from logic, §14.2) and a
// value that is not a string literal both reject as malformed.
cfg_parse_assignment :: proc(p: ^Cfg_Parser) -> (key: string, value: string, err: Project_Error) {
	key_tok := cfg_expect(p, .Ident) or_return
	cfg_expect(p, .Eq) or_return
	value_tok := cfg_expect(p, .String) or_return
	return key_tok.text, value_tok.text, .None
}

// ── §14.4 builds.fcfg ──────────────────────────────────────────────────
// The builds production of the §14 smaller config grammar: a sequence of
// `build <name> { platform = desktop|wasm }` blocks (exemplar:
// funpack-spec/examples/arena/funpack_configs/builds.fcfg, `build native {
// platform = desktop }`). Each block's label is the build name and its sole
// required key is `platform`, whose value is the closed §14.6 presentation set.
// It rides the same lex_fcfg/Cfg_Parser machinery the project.fcfg production
// uses (the value here is a bare platform identifier, never a string literal),
// distinct from index_contract.odin's line-oriented read_builds: that one
// projects lenient Build_Records for the NDJSON, this one is the strict grammar
// production with a closed platform set that feeds Project.builds and rejects an
// unknown platform.

// parse_builds_fcfg parses the §14.4 builds grammar into the declared targets,
// or rejects a present file that violates it. The grammar is a sequence of
// top-level `@doc(…)` directives and `build <name> { platform = P }` blocks; P
// is a closed identifier (`desktop` or `wasm`). A missing label, a missing or
// repeated platform, an unknown platform value, or any non-grammar construct is
// a Malformed_Builds_Fcfg rejection. Zero blocks is legal (no declared emit
// targets) — only a malformed construct rejects.
parse_builds_fcfg :: proc(content: string) -> (builds: Builds, err: Project_Error) {
	p := Cfg_Parser{tokens = lex_fcfg(content)}
	targets := make([dynamic]Build_Target, 0, 2, context.temp_allocator)
	for !cfg_at_end(&p) {
		#partial switch cfg_peek(&p).kind {
		case .At:
			cfg_skip_doc_builds(&p) or_return
		case .Ident:
			// The only legal top-level identifier is the `build` block opener;
			// any other top-level token is outside the builds grammar.
			if cfg_peek(&p).text != "build" {
				return Builds{}, .Malformed_Builds_Fcfg
			}
			target := cfg_parse_build_block(&p) or_return
			append(&targets, target)
		case:
			return Builds{}, .Malformed_Builds_Fcfg
		}
	}
	return Builds{targets = targets[:]}, .None
}

// cfg_parse_build_block parses one `build <name> { platform = P }` block. The
// label is mandatory (a labelless `build { … }` rejects) and becomes the build
// name; `platform` is the one required key and its value is the closed §14.6
// platform set. A missing or repeated platform, an unknown platform value, or a
// non-platform key rejects.
cfg_parse_build_block :: proc(p: ^Cfg_Parser) -> (target: Build_Target, err: Project_Error) {
	cfg_expect_builds_text(p, "build") or_return
	label := cfg_expect_builds(p, .Ident) or_return // the build-name label
	cfg_expect_builds(p, .L_Brace) or_return
	target.name = label.text
	saw_platform := false
	for cfg_peek(p).kind != .R_Brace {
		#partial switch cfg_peek(p).kind {
		case .At:
			cfg_skip_doc_builds(p) or_return
		case .Ident:
			key := cfg_expect_builds(p, .Ident) or_return
			if key.text != "platform" || saw_platform {
				return Build_Target{}, .Malformed_Builds_Fcfg
			}
			cfg_expect_builds(p, .Eq) or_return
			// The platform value is a bare identifier in the closed §14.6 set,
			// never a string literal — the smaller config grammar's block bodies
			// carry bare values.
			value := cfg_expect_builds(p, .Ident) or_return
			platform, ok := parse_build_platform(value.text)
			if !ok {
				return Build_Target{}, .Malformed_Builds_Fcfg
			}
			target.platform = platform
			saw_platform = true
		case:
			// End of input before `}` (Invalid), or any non-assignment,
			// non-doc construct inside the block.
			return Build_Target{}, .Malformed_Builds_Fcfg
		}
	}
	cfg_expect_builds(p, .R_Brace) or_return
	if !saw_platform {
		return Build_Target{}, .Malformed_Builds_Fcfg
	}
	return target, .None
}

// parse_build_platform maps a platform identifier to the closed Build_Platform
// set, reporting ok = false for any value outside it. The set is the §14.6
// presentation platforms (`desktop`, `wasm`); an unknown value is the reject
// signal cfg_parse_build_block turns into Malformed_Builds_Fcfg.
parse_build_platform :: proc(text: string) -> (platform: Build_Platform, ok: bool) {
	switch text {
	case "desktop":
		return .Desktop, true
	case "wasm":
		return .Wasm, true
	case:
		return .Desktop, false
	}
}

// cfg_expect_builds is cfg_expect threading the builds error type: it consumes
// the next token, demanding the given kind, and surfaces Malformed_Builds_Fcfg
// on a mismatch so the builds production threads its own closed arm rather than
// project.fcfg's.
cfg_expect_builds :: proc(p: ^Cfg_Parser, kind: Cfg_Token_Kind) -> (tok: Cfg_Token, err: Project_Error) {
	tok = cfg_peek(p)
	if tok.kind != kind {
		return Cfg_Token{}, .Malformed_Builds_Fcfg
	}
	p.pos += 1
	return tok, .None
}

// cfg_expect_builds_text is cfg_expect_builds demanding a specific identifier
// text too — the `build` block-opener keyword. A kind or text mismatch is
// Malformed_Builds_Fcfg.
cfg_expect_builds_text :: proc(p: ^Cfg_Parser, text: string) -> Project_Error {
	tok := cfg_peek(p)
	if tok.kind != .Ident || tok.text != text {
		return .Malformed_Builds_Fcfg
	}
	p.pos += 1
	return .None
}

// cfg_skip_doc_builds consumes a `@doc("…")` directive inside the builds
// grammar, mirroring cfg_skip_doc but threading the builds error arm so a
// malformed `@` directive in builds.fcfg surfaces Malformed_Builds_Fcfg.
cfg_skip_doc_builds :: proc(p: ^Cfg_Parser) -> Project_Error {
	cfg_expect_builds(p, .At) or_return
	name := cfg_expect_builds(p, .Ident) or_return
	if name.text != "doc" {
		return .Malformed_Builds_Fcfg
	}
	cfg_expect_builds(p, .L_Paren) or_return
	cfg_expect_builds(p, .String) or_return
	cfg_expect_builds(p, .R_Paren) or_return
	return .None
}

// ── §23/§07 entrypoints.fcfg ───────────────────────────────────────────
// The entrypoints config is the §14 smaller-config grammar's second
// production: a `use module.{members}` source reference and one or more
// `entrypoint <name> { pipeline = …, tick = …hz, logical = WxH, bindings = … }` blocks. It
// names source (a pipeline and a bindings fn the module declares) and a tick
// rate, so its values are names and a tick literal — distinct from
// project.fcfg's string-literal-only assignments. The referenced pipeline and
// bindings names are validated against the parsed source module; a dangling
// reference (a name the module does not declare) rejects.

// Entrypoints is the parsed entrypoints.fcfg: the `use` reference's module
// path and member group, plus the declared entrypoint blocks. The members are
// the names brought into scope (the pipeline and the bindings fn), kept in
// source order.
Entrypoints :: struct {
	use_module:  string,
	use_members: []string,
	entrypoints: []Entrypoint,
}

// Entrypoint is one `entrypoint <name> { … }` block: the engine wires the
// named pipeline at the given tick rate, logical draw space, and named bindings
// fn (§23/§07, §20 §3). pipeline and bindings are source names validated
// against the module; tick is the `<digits>hz` rate value as written; logical
// is the `WxH` extent value as written (the fixed logical space §20 §3
// letterboxes to, in integer world units).
Entrypoint :: struct {
	name:     string,
	pipeline: string,
	tick:     string,
	logical:  string,
	bindings: string,
}

// Entrypoints_Error is closed with one arm per way entrypoints.fcfg can
// reject. Malformed_Entrypoints_Fcfg is any grammar violation (a missing key,
// a value of the wrong shape, a stray construct); Dangling_Reference is the
// §07 obligation — the `pipeline`/`bindings` reference names something the
// source module does not declare; Multiple_Entrypoints is the emit-selection
// reject — the v1 artifact carries exactly one [entrypoint] record and there
// is no selection mechanism, so read_entrypoint refuses a config declaring
// more than one block rather than silently picking the first.
Entrypoints_Error :: enum {
	None,
	Malformed_Entrypoints_Fcfg,
	Dangling_Reference,
	Multiple_Entrypoints,
}

// parse_entrypoints_fcfg parses the entrypoints.fcfg grammar: a single
// top-level `use module.{members}` reference followed by one or more
// `entrypoint <name> { pipeline = N, tick = Rhz, logical = WxH, bindings = N }` blocks.
// pipeline/tick/logical/bindings are the four required keys; a missing or extra key,
// a value of the wrong shape, or any non-grammar construct is a
// Malformed_Entrypoints_Fcfg rejection. Reference validation against the
// source module is validate_entrypoints' job, not the parse's.
parse_entrypoints_fcfg :: proc(content: string) -> (entrypoints: Entrypoints, err: Entrypoints_Error) {
	p := Cfg_Parser{tokens = lex_fcfg(content)}
	module, members := cfg_parse_use(&p) or_return
	blocks := make([dynamic]Entrypoint, 0, 2, context.temp_allocator)
	for !cfg_at_end(&p) {
		if cfg_peek(&p).kind != .Ident || cfg_peek(&p).text != "entrypoint" {
			return Entrypoints{}, .Malformed_Entrypoints_Fcfg
		}
		block := cfg_parse_entrypoint(&p) or_return
		append(&blocks, block)
	}
	if len(blocks) == 0 {
		return Entrypoints{}, .Malformed_Entrypoints_Fcfg
	}
	return Entrypoints{use_module = module, use_members = members, entrypoints = blocks[:]}, .None
}

// cfg_parse_use parses `use module.{member, …}` — the source reference that
// names the pipeline and bindings brought into the entrypoint's scope. The
// module path is a single segment on the gameplay surface (`pong`); the member
// group is brace-delimited and comma-separated.
cfg_parse_use :: proc(p: ^Cfg_Parser) -> (module: string, members: []string, err: Entrypoints_Error) {
	cfg_take(p, .Ident, "use") or_return
	module_tok := cfg_take(p, .Ident) or_return
	cfg_take(p, .Dot) or_return
	cfg_take(p, .L_Brace) or_return
	list := make([dynamic]string, 0, 4, context.temp_allocator)
	for cfg_peek(p).kind == .Ident {
		member := cfg_take(p, .Ident) or_return
		append(&list, member.text)
		// Members separate by `,` (the `use pong.{Pong, bindings}` group); a
		// trailing comma before the closing brace is tolerated.
		for cfg_peek(p).kind == .Comma {
			p.pos += 1
		}
	}
	cfg_take(p, .R_Brace) or_return
	if len(list) == 0 {
		return "", nil, .Malformed_Entrypoints_Fcfg
	}
	return module_tok.text, list[:], .None
}

// cfg_parse_entrypoint parses one `entrypoint <name> { pipeline = N, tick =
// Rhz, logical = WxH, bindings = N }` block. The four keys are required and
// each is read by name, so key order does not matter; a missing key or an
// unknown key is malformed. tick demands a `<digits>hz` value; logical demands
// a `WxH` extent (a digit-led token whose W/H integers select_entrypoint
// validates); pipeline and bindings demand a bare name.
cfg_parse_entrypoint :: proc(p: ^Cfg_Parser) -> (block: Entrypoint, err: Entrypoints_Error) {
	cfg_take(p, .Ident, "entrypoint") or_return
	name := cfg_take(p, .Ident) or_return
	cfg_take(p, .L_Brace) or_return
	block.name = name.text
	saw_pipeline := false
	saw_tick := false
	saw_logical := false
	saw_bindings := false
	for cfg_peek(p).kind == .Ident {
		key := cfg_take(p, .Ident) or_return
		cfg_take(p, .Eq) or_return
		switch key.text {
		case "pipeline":
			value := cfg_take(p, .Ident) or_return
			block.pipeline = value.text
			saw_pipeline = true
		case "bindings":
			value := cfg_take(p, .Ident) or_return
			block.bindings = value.text
			saw_bindings = true
		case "tick":
			value := cfg_take(p, .Tick) or_return
			if !strings.has_suffix(value.text, "hz") {
				return Entrypoint{}, .Malformed_Entrypoints_Fcfg
			}
			block.tick = value.text
			saw_tick = true
		case "logical":
			// A `WxH` extent lexes as one digit-led token (the same scan a tick
			// rides); the W/H integer split is select_entrypoint's job.
			value := cfg_take(p, .Tick) or_return
			block.logical = value.text
			saw_logical = true
		case:
			return Entrypoint{}, .Malformed_Entrypoints_Fcfg
		}
		// Keys separate by newline (whitespace) in the golden block; a `,`
		// separator between keys is tolerated too.
		for cfg_peek(p).kind == .Comma {
			p.pos += 1
		}
	}
	cfg_take(p, .R_Brace) or_return
	if !saw_pipeline || !saw_tick || !saw_logical || !saw_bindings {
		return Entrypoint{}, .Malformed_Entrypoints_Fcfg
	}
	return block, .None
}

// cfg_take consumes the next token, demanding the given kind (and optional
// text). It is the entrypoints-grammar analogue of cfg_expect, returning the
// entrypoints error type so the `use`/`entrypoint` productions thread one
// closed error. A kind or text mismatch is Malformed_Entrypoints_Fcfg.
cfg_take :: proc(p: ^Cfg_Parser, kind: Cfg_Token_Kind, text: string = "") -> (tok: Cfg_Token, err: Entrypoints_Error) {
	tok = cfg_peek(p)
	if tok.kind != kind || (text != "" && tok.text != text) {
		return Cfg_Token{}, .Malformed_Entrypoints_Fcfg
	}
	p.pos += 1
	return tok, .None
}

// validate_entrypoints checks every entrypoint's pipeline and bindings
// reference against the parsed source module (§07): the pipeline must be a
// declared pipeline and the bindings must be a declared top-level fn. A
// reference naming something the module does not declare is a
// Dangling_Reference reject. The `use` member group must also name only
// declared members, so an imported member that the module lacks rejects too.
validate_entrypoints :: proc(entrypoints: Entrypoints, ast: Ast) -> Entrypoints_Error {
	for member in entrypoints.use_members {
		if !module_declares_pipeline(ast, member) && !module_declares_fn(ast, member) {
			return .Dangling_Reference
		}
	}
	for block in entrypoints.entrypoints {
		if !module_declares_pipeline(ast, block.pipeline) {
			return .Dangling_Reference
		}
		if !module_declares_fn(ast, block.bindings) {
			return .Dangling_Reference
		}
	}
	return .None
}

// module_declares_pipeline reports whether the source module declares a
// pipeline of the given name — the §07 target a `pipeline = N` reference must
// resolve to.
module_declares_pipeline :: proc(ast: Ast, name: string) -> bool {
	for decl in ast.pipelines {
		if decl.name == name {
			return true
		}
	}
	return false
}

// module_declares_fn reports whether the source module declares a top-level fn
// of the given name — the bindings fn a `bindings = N` reference resolves to.
module_declares_fn :: proc(ast: Ast, name: string) -> bool {
	for decl in ast.fns {
		if decl.name == name {
			return true
		}
	}
	return false
}

// cfg_skip_doc consumes a `@doc("…")` directive. The directive describes a
// declaration (§14.2) and carries no identity, so it is accepted and
// dropped; a malformed `@` directive is rejected.
cfg_skip_doc :: proc(p: ^Cfg_Parser) -> Project_Error {
	cfg_expect(p, .At) or_return
	name := cfg_expect(p, .Ident) or_return
	if name.text != "doc" {
		return .Malformed_Project_Fcfg
	}
	cfg_expect(p, .L_Paren) or_return
	cfg_expect(p, .String) or_return
	cfg_expect(p, .R_Paren) or_return
	return .None
}

// Cfg_Token is the minimal token set the §14 smaller-config grammar needs,
// shared by project.fcfg and entrypoints.fcfg. The `.fun` lexer is
// deliberately not reused: it carries casing classes, Fixed literals, and
// `.fun`-specific newline semantics the smaller config grammars have no use
// for. Dot and Tick extend the set for entrypoints.fcfg: a `use`
// reference's dotted module path (`use pong.{…}`) and a tick rate value
// (`tick = 60hz`), which project.fcfg never uses.
Cfg_Token_Kind :: enum {
	Invalid, // end of input or an unrecognized glyph
	Ident,
	String,
	Eq,
	At,
	L_Brace,
	R_Brace,
	L_Paren,
	R_Paren,
	Dot,   // the `.` of a `use module.{members}` reference (entrypoints.fcfg)
	Tick,  // a `<digits>hz` tick-rate value (entrypoints.fcfg `tick = 60hz`)
	Comma, // the `,` member separator of a `use module.{a, b}` group (entrypoints.fcfg)
}

Cfg_Token :: struct {
	kind: Cfg_Token_Kind,
	text: string,
}

Cfg_Parser :: struct {
	tokens: []Cfg_Token,
	pos:    int,
}

cfg_at_end :: proc(p: ^Cfg_Parser) -> bool {
	return p.pos >= len(p.tokens)
}

// cfg_peek reports an Invalid token at end of input so a kind check fails
// closed without a separate end test.
cfg_peek :: proc(p: ^Cfg_Parser) -> Cfg_Token {
	if cfg_at_end(p) {
		return Cfg_Token{kind = .Invalid}
	}
	return p.tokens[p.pos]
}

cfg_expect :: proc(p: ^Cfg_Parser, kind: Cfg_Token_Kind) -> (tok: Cfg_Token, err: Project_Error) {
	tok = cfg_peek(p)
	if tok.kind != kind {
		return Cfg_Token{}, .Malformed_Project_Fcfg
	}
	p.pos += 1
	return tok, .None
}

// lex_fcfg tokenizes the project.fcfg surface. It is total: an
// unrecognized glyph becomes an Invalid token for the parser to reject,
// so an expression operator or control-flow punctuation cannot slip
// through as layout. Whitespace and newlines are insignificant (the
// config grammar has no statement terminator); `//` is two division
// glyphs that lex as Invalid, matching the `.fun` no-free-comment
// discipline (§14.2, P6).
lex_fcfg :: proc(content: string) -> []Cfg_Token {
	tokens := make([dynamic]Cfg_Token, 0, 16, context.temp_allocator)
	i := 0
	for i < len(content) {
		ch := content[i]
		switch {
		case ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n':
			i += 1
		case ch == '"':
			tok, next := cfg_scan_string(content, i)
			append(&tokens, tok)
			i = next
		case is_ident_start(ch):
			tok, next := cfg_scan_ident(content, i)
			append(&tokens, tok)
			i = next
		case is_digit(ch):
			// A leading digit opens a tick-rate value (`60hz`) — a closed
			// numeric form the entrypoints grammar reads. project.fcfg never
			// admits one, so a bare digit there scans Tick and the parser
			// rejects it as a non-grammar value.
			tok, next := cfg_scan_tick(content, i)
			append(&tokens, tok)
			i = next
		case:
			append(&tokens, cfg_scan_punct(ch))
			i += 1
		}
	}
	return tokens[:]
}

cfg_scan_string :: proc(content: string, start: int) -> (tok: Cfg_Token, next: int) {
	i := start + 1
	for i < len(content) && content[i] != '"' && content[i] != '\n' {
		i += 1
	}
	if i >= len(content) || content[i] != '"' {
		return Cfg_Token{kind = .Invalid, text = content[start:i]}, i
	}
	return Cfg_Token{kind = .String, text = content[start+1 : i]}, i + 1
}

cfg_scan_ident :: proc(content: string, start: int) -> (tok: Cfg_Token, next: int) {
	i := start
	for i < len(content) && is_ident_char(content[i]) {
		i += 1
	}
	return Cfg_Token{kind = .Ident, text = content[start:i]}, i
}

// cfg_scan_tick scans a tick-rate value: a digit run followed by the unit
// suffix `hz` (`60hz`). The whole `<digits><suffix>` run is one Tick token;
// a digit run with no suffix or a foreign suffix scans Tick too, leaving the
// units check to the parser, which validates the `hz` unit against the
// entrypoints grammar.
cfg_scan_tick :: proc(content: string, start: int) -> (tok: Cfg_Token, next: int) {
	i := start
	for i < len(content) && (is_digit(content[i]) || is_ident_char(content[i])) {
		i += 1
	}
	return Cfg_Token{kind = .Tick, text = content[start:i]}, i
}

// cfg_scan_punct maps the bracket/operator/dot glyphs the grammar uses;
// every other single character is Invalid, the parser's reject signal.
cfg_scan_punct :: proc(ch: u8) -> Cfg_Token {
	switch ch {
	case '=':
		return Cfg_Token{kind = .Eq, text = "="}
	case '@':
		return Cfg_Token{kind = .At, text = "@"}
	case '{':
		return Cfg_Token{kind = .L_Brace, text = "{"}
	case '}':
		return Cfg_Token{kind = .R_Brace, text = "}"}
	case '(':
		return Cfg_Token{kind = .L_Paren, text = "("}
	case ')':
		return Cfg_Token{kind = .R_Paren, text = ")"}
	case '.':
		return Cfg_Token{kind = .Dot, text = "."}
	case ',':
		return Cfg_Token{kind = .Comma, text = ","}
	case:
		return Cfg_Token{kind = .Invalid}
	}
}

// collect_sources walks every `.fun` under `src/` (recursively — a
// module's directory IS its namespace, §15, so nested files are
// first-class) and pairs each path with its §15 path-derived module name.
// Paths are sorted for a deterministic source order regardless of the
// filesystem's walk order. A path whose module falls under the reserved
// `engine` root rejects with the dedicated Reserved_Engine_Root arm
// before any source is returned — a reserved collision fails the whole
// tree, not just the offending file. Two paths deriving the same module
// name reject with Duplicate_Module (§15.6) — module identity is
// single-owner, so the second deriver in sorted-path order trips the
// check deterministically.
collect_sources :: proc(root: string) -> ([]Source, Project_Error, string) {
	src_dir, _ := filepath.join({root, "src"}, context.temp_allocator)
	if !os.is_dir(src_dir) {
		return nil, .Missing_Src_Dir, ""
	}
	paths := collect_fun_paths(src_dir)
	if len(paths) == 0 {
		return nil, .No_Sources, ""
	}
	slice.sort(paths)
	// The walker resolves the source root through realpath, so the
	// collected fullpaths are realpath-rooted; relativize against the
	// same realpath form (filepath.abs uses realpath) so the prefix
	// matches and the derived module is not corrupted by a symlinked
	// temp root (the macOS /var → /private/var case).
	abs_src_dir, abs_err := filepath.abs(src_dir, context.temp_allocator)
	if abs_err != nil {
		abs_src_dir = src_dir
	}
	seen := make(map[string]bool, context.temp_allocator)
	sources := make([]Source, len(paths), context.temp_allocator)
	for path, i in paths {
		module := derive_module_name(abs_src_dir, path)
		if module_under_reserved_root(module) {
			return nil, .Reserved_Engine_Root, fmt.tprintf("%s derives module '%s' under the reserved engine root (§15 §7)", path, module)
		}
		if module in seen {
			return nil, .Duplicate_Module, fmt.tprintf("%s derives module '%s', which another source already derives (§15 §6)", path, module)
		}
		seen[module] = true
		sources[i] = Source{path = path, module = module}
	}
	return sources, .None, ""
}

// collect_fun_paths walks `src_dir` breadth-first and returns every
// regular `.fun` file's path (cloned into the temp allocator so they
// outlive the walker, whose own path strings are freed on destroy).
collect_fun_paths :: proc(src_dir: string) -> []string {
	paths := make([dynamic]string, 0, 8, context.temp_allocator)
	walker := os.walker_create(src_dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular || !strings.has_suffix(info.name, ".fun") {
			continue
		}
		append(&paths, strings.clone(info.fullpath, context.temp_allocator))
	}
	return paths[:]
}

// derive_module_name computes a source's §15 module name as a pure
// function of its path: relativize against the source root (dropping the
// `src/` prefix), strip the `.fun` extension, and dot the interior
// directory segments — `src/numerics.fun` → `numerics`,
// `src/combat/melee.fun` → `combat.melee`. No `module` keyword, no
// hardcode: the filesystem location IS the name.
derive_module_name :: proc(src_root: string, source_path: string) -> string {
	rel, rel_err := filepath.rel(src_root, source_path, context.temp_allocator)
	if rel_err != .None {
		rel = source_path
	}
	stem := strings.trim_suffix(rel, ".fun")
	segments := strings.split(stem, filepath.SEPARATOR_STRING, context.temp_allocator)
	return strings.join(segments, ".", context.temp_allocator)
}

// module_under_reserved_root reports whether a derived module name
// shadows the closed reserved `engine` root (§15.7): the bare root itself
// (`src/engine.fun`) or any module beneath it (`src/engine/foo.fun` →
// `engine.foo`). The leading segment is compared exactly, so a benign
// `engineering` module does not collide.
module_under_reserved_root :: proc(module: string) -> bool {
	return module == RESERVED_ROOT || strings.has_prefix(module, RESERVED_ROOT + ".")
}

// ── §14.4 derived-capability tree-walk ─────────────────────────────────
// The capability set is derived, never declared (§14 §4): there is no
// features config. Each of the four directory-backed subsystems switches on
// from its backing authoring directory — a present-and-non-empty levels/ ⇒
// levels ON, and so on for models/ ui/ assets/ — and for each ON subsystem the
// matching gen/ seam is expected. An absent or present-but-empty directory is
// the same arm: the feature is OFF (the spec collapses absence and empty —
// present-but-empty ⇒ off; an absent dir has no authoring files, so it is off
// too). This walk reads directory presence and the authoring filenames only; it
// does NOT read or compare gen/ seam contents (the harness story) and does NOT
// join gen/ into the source set (the seam-import story).

// Subsystem_Dir pairs one directory-backed subsystem's authoring directory
// with the authoring-file extension that makes it non-empty (§14 §1):
// levels/*.flvl, models/*.fpm, ui/*.fui, assets/*.manifest.
Subsystem_Dir :: struct {
	dir: string,
	ext: string,
}

// derive_tree_capabilities walks the four §14.4 directory-backed subsystem
// directories and reports which are ON (present-and-non-empty with the
// subsystem's authoring files) plus, for each ON subsystem, the gen/ seam(s) its
// authoring files expect. The result is deterministic: the expected gen outputs
// are collected in sorted authoring-path order. The name is distinct from
// index_contract.odin's derive_capabilities — that one projects the closed
// Capability battery vector (which folds in net/expose/audio source signals) for
// the NDJSON; this one is the §14.4 directory-backed tree-walk that records the
// expected gen/ seams, the fact the bake pipeline consumes.
derive_tree_capabilities :: proc(root: string) -> Capabilities {
	caps: Capabilities
	expected := make([dynamic]string, 0, 4, context.temp_allocator)
	// The closed §14.4 directory-backed subsystem list — a new subsystem is a
	// deliberate addition here.
	subsystems := [4]Subsystem_Dir {
		{dir = "levels", ext = ".flvl"},
		{dir = "models", ext = ".fpm"},
		{dir = "ui", ext = ".fui"},
		{dir = "assets", ext = ".manifest"},
	}
	flags := [4]^bool{&caps.levels, &caps.models, &caps.ui, &caps.assets}
	for sub, i in subsystems {
		gen_outs := subsystem_expected_gen(root, sub.dir, sub.ext)
		if len(gen_outs) > 0 {
			flags[i]^ = true
			append(&expected, ..gen_outs)
		}
	}
	caps.expected_gen_out = expected[:]
	return caps
}

// subsystem_expected_gen walks one subsystem directory for its authoring files
// (regular files with the given extension) and returns the gen/ seam path each
// expects — gen/<stem>.gen.fun, the authoring filename with its extension
// swapped for `.gen.fun` (levels/arena.flvl ⇒ gen/arena.gen.fun). Returns an
// empty slice when the directory is absent or holds no authoring file (the OFF
// arm). The paths are sorted by authoring filename so the expected set is
// deterministic regardless of the walk order.
subsystem_expected_gen :: proc(root: string, sub: string, ext: string) -> []string {
	dir, _ := filepath.join({root, sub}, context.temp_allocator)
	if !os.is_dir(dir) {
		return nil
	}
	stems := make([dynamic]string, 0, 4, context.temp_allocator)
	walker := os.walker_create(dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular || !strings.has_suffix(info.name, ext) {
			continue
		}
		stem := strings.trim_suffix(info.name, ext)
		append(&stems, strings.clone(stem, context.temp_allocator))
	}
	if len(stems) == 0 {
		return nil
	}
	slice.sort(stems[:])
	outs := make([]string, len(stems), context.temp_allocator)
	for stem, i in stems {
		out, _ := filepath.join({"gen", strings.concatenate({stem, ".gen.fun"}, context.temp_allocator)}, context.temp_allocator)
		outs[i] = out
	}
	return outs
}

// ── §17 seam-import path ────────────────────────────────────────────────
// A baked gen/*.gen.fun seam joins the source set and rides the same
// lex → parse → gates → typecheck → contracts → flatten → evaluate pipeline any
// .fun module does (lore #10 seam #4). gen/ is a DERIVED source root peer to
// src/: a seam's §15 module derives by stripping the gen/ prefix exactly as src/
// is stripped, so gen/arena.gen.fun ⇒ module `arena` (NOT `gen.arena`). The seam
// sources merge into Project.sources alongside src/, re-running the §15.6
// duplicate-module and §15.7 reserved-root checks across the COMBINED set, and
// the §17 schema/seam/behavior acyclic layering is enforced: a seam imports
// schema modules + engine.* only — importing a behavior module is a compile
// error (Seam_Imports_Behavior).

GEN_ROOT :: "gen"
GEN_SUFFIX :: ".gen.fun"

// collect_seam_sources walks the gen/ directory for *.gen.fun seams when a
// subsystem capability is ON, pairing each with its §15 path-derived module
// name. gen/ is a derived source root, so a seam's module is its location under
// gen/ with the gen/ prefix and the `.gen.fun` suffix stripped and interior
// directories dotted — the same derivation src/ uses, against the gen/ root.
// When no capability is ON there is no expected gen/ output (§14.4), so the walk
// is skipped and the seam set is empty — the pong/numerics/yard no-gen-tree case.
// A seam whose derived module shadows the reserved `engine` root rejects with
// Reserved_Engine_Root, the same §15.7 rule src/ enforces. The returned sources
// are sorted by path for a deterministic order.
collect_seam_sources :: proc(root: string, caps: Capabilities) -> ([]Source, Project_Error) {
	// No ON subsystem ⇒ no expected gen/ seam (§14.4), so the gen/ root is not a
	// source root for this tree — the no-gen-tree case (pong/numerics/yard).
	if !capabilities_any_on(caps) {
		return nil, .None
	}
	gen_dir, _ := filepath.join({root, GEN_ROOT}, context.temp_allocator)
	if !os.is_dir(gen_dir) {
		return nil, .None
	}
	paths := collect_seam_paths(gen_dir)
	if len(paths) == 0 {
		return nil, .None
	}
	slice.sort(paths)
	abs_gen_dir, abs_err := filepath.abs(gen_dir, context.temp_allocator)
	if abs_err != nil {
		abs_gen_dir = gen_dir
	}
	sources := make([]Source, len(paths), context.temp_allocator)
	for path, i in paths {
		module := derive_seam_module_name(abs_gen_dir, path)
		if module_under_reserved_root(module) {
			return nil, .Reserved_Engine_Root
		}
		sources[i] = Source{path = path, module = module}
	}
	return sources, .None
}

// collect_seam_paths walks gen_dir for every regular `*.gen.fun` seam file,
// cloning each fullpath into the temp allocator (the walker frees its own path
// strings on destroy), mirroring collect_fun_paths over src/. The suffix is the
// full `.gen.fun`, not bare `.fun`, so a stray hand-written `gen/notes.fun`
// (which is not a generated seam) is not collected as one.
collect_seam_paths :: proc(gen_dir: string) -> []string {
	paths := make([dynamic]string, 0, 4, context.temp_allocator)
	walker := os.walker_create(gen_dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular || !strings.has_suffix(info.name, GEN_SUFFIX) {
			continue
		}
		append(&paths, strings.clone(info.fullpath, context.temp_allocator))
	}
	return paths[:]
}

// derive_seam_module_name computes a seam's §15 module name as a pure function
// of its path: relativize against the gen/ root, strip the `.gen.fun` suffix,
// and dot the interior directory segments — gen/arena.gen.fun ⇒ `arena`,
// gen/town/market.gen.fun ⇒ `town.market`. It is derive_module_name against the
// gen/ root with the seam suffix: gen/ is a peer source root to src/, so a seam
// carries the SAME module the schema it mirrors would, never a `gen.`-prefixed
// one (a seam IS the `arena` module the behavior code imports).
derive_seam_module_name :: proc(gen_root: string, source_path: string) -> string {
	rel, rel_err := filepath.rel(gen_root, source_path, context.temp_allocator)
	if rel_err != .None {
		rel = source_path
	}
	stem := strings.trim_suffix(rel, GEN_SUFFIX)
	segments := strings.split(stem, filepath.SEPARATOR_STRING, context.temp_allocator)
	return strings.join(segments, ".", context.temp_allocator)
}

// capabilities_any_on reports whether any of the four §14.4 directory-backed
// subsystems is ON — the precondition for an expected gen/ seam set. An all-OFF
// tree (pong/numerics/yard) has no gen/ source root, so its source set is exactly
// src/, unchanged by the seam-import path.
capabilities_any_on :: proc(caps: Capabilities) -> bool {
	return caps.levels || caps.models || caps.ui || caps.assets
}

// merge_sources combines the src/ and gen/ source sets into one source set,
// preserving a deterministic sorted-by-path order and re-running the §15.6
// duplicate-module and §15.7 reserved-root checks across the COMBINED set. The
// per-set checks (collect_sources, collect_seam_sources) already cleared each
// set in isolation; this re-check catches a CROSS-set collision — a seam whose
// derived module equals a hand-written src/ module — which neither per-set pass
// could see. A reserved-root module in either set fails the tree (the seam set
// is pre-checked, so a reserved collision here can only come from src/, but the
// arm is total over the combined set). The deterministic order matters because
// downstream stages walk Project.sources by index.
merge_sources :: proc(src_sources: []Source, seam_sources: []Source) -> ([]Source, Project_Error, string) {
	combined := make([]Source, len(src_sources) + len(seam_sources), context.temp_allocator)
	copy(combined[:len(src_sources)], src_sources)
	copy(combined[len(src_sources):], seam_sources)
	slice.sort_by(combined, proc(a, b: Source) -> bool {
		return a.path < b.path
	})
	seen := make(map[string]bool, context.temp_allocator)
	for source in combined {
		if module_under_reserved_root(source.module) {
			return nil, .Reserved_Engine_Root, fmt.tprintf("%s derives module '%s' under the reserved engine root (§15 §7)", source.path, source.module)
		}
		if source.module in seen {
			return nil, .Duplicate_Module, fmt.tprintf("%s derives module '%s', which another source already derives (§15 §6)", source.path, source.module)
		}
		seen[source.module] = true
	}
	return combined, .None, ""
}

// check_seam_layering enforces the §17 schema/seam/behavior acyclic-import
// invariant: each generated seam imports schema modules + engine.* only — a seam
// importing a BEHAVIOR module is a compile error (Seam_Imports_Behavior). It
// parses each seam, walks its USER-module imports (the engine.* imports are
// stdlib, never a layering concern), looks each imported module up in the
// combined source set, and classifies it by its declarations: a module declaring
// `behavior`s or a `pipeline` is a behavior module. A seam importing such a
// module closes the behavior → seam → behavior cycle the layering forbids. A
// seam the parser rejects is Malformed_Seam (a committed seam is canonical
// funpack; a non-parsing one is a stale baked output). An imported user module
// not in the source set is not classified here — that is a resolution concern
// the per-source pipeline surfaces — so the layering check is conservative: it
// rejects only a seam importing a module the tree proves is a behavior module.
check_seam_layering :: proc(seam_sources: []Source, all_sources: []Source) -> Project_Error {
	for seam in seam_sources {
		seam_bytes, read_err := os.read_entire_file_from_path(seam.path, context.temp_allocator)
		if read_err != nil {
			return .Malformed_Seam
		}
		seam_ast, parse_err := stage_parse(stage_lex(string(seam_bytes)))
		if parse_err != .None {
			return .Malformed_Seam
		}
		for imp in seam_ast.imports {
			// engine.* imports are stdlib — they never name a user module, so they
			// are not a §17 layering concern (a seam imports engine types freely).
			if module_under_reserved_root(imp.segments[0]) {
				continue
			}
			imported := join_path(imp.segments)
			if source_is_behavior_module(all_sources, imported) {
				return .Seam_Imports_Behavior
			}
		}
	}
	return .None
}

// source_is_behavior_module reports whether the user module of the given name is
// a §17 BEHAVIOR module — one whose source declares `behavior`s or a `pipeline`
// (§17: a behavior module declares the behaviors and the pipeline; a schema
// module declares only thing/data/enum/signal). It finds the module's source in
// the combined set, parses it, and inspects the declaration kinds. A module not
// in the set (or one the parser rejects) is NOT classified as a behavior module —
// the layering check rejects only a module the tree positively proves is one,
// leaving an unknown/unparseable import to the per-source resolution pipeline.
source_is_behavior_module :: proc(all_sources: []Source, module: string) -> bool {
	for source in all_sources {
		if source.module != module {
			continue
		}
		source_bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
		if read_err != nil {
			return false
		}
		ast, parse_err := stage_parse(stage_lex(string(source_bytes)))
		if parse_err != .None {
			return false
		}
		return len(ast.behaviors) > 0 || len(ast.pipelines) > 0
	}
	return false
}
