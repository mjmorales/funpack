// The §30 dependency surface: the deps.fcfg production of the §14 smaller
// config grammar, and the path-source package resolution that joins a
// dependency's sources to the consumer's build under the dependency's project
// name as root namespace (§30 §7, §15 §5).
//
// deps.fcfg names the declared dependency set across the four provenance
// sources (§30 §3): the stdlib needs no declaration; a `path` dep is vouched
// by you and carries no hash; `version` (registry) and `url` deps are pinned
// to a required content hash. The grammar is one production:
//
//   use <name> version "<label>" hash "<sha…>"   // registry
//   use <name> path "<relative-dir>"             // local path
//   use <name> url "<https…>" hash "<sha…>"      // url
//
// This file RESOLVES path deps only: a path dependency is a §30 §7 package —
// a full funpack project tree WITHOUT an entrypoint — whose src/ modules
// enter the consumer's module index keyed `<project-name>.<module>` with
// package_root stamped, so the §30 §6 expose gate and the §30 §2 star-graph
// refusal both see the edge. Registry/url deps are parsed but not resolved:
// vendoring into packages/<name>/ and the content-hash verification gate are
// §30 §4, a downstream story — the Dep record carries the pin for it.
package funpack

import "core:os"
import "core:path/filepath"
import "core:strings"

// Dep_Source is the closed §30 §3 provenance-source set a `use` declaration
// selects (the fourth source, stdlib, needs no declaration). The set is
// closed and compiler-fixed: a new source kind is a deliberate addition
// here, never a silently-accepted identifier.
Dep_Source :: enum {
	Registry, // `use <name> version "…" hash "…"` — the curated registry
	Path,     // `use <name> path "…"` — your own local/shared tree
	Url,      // `use <name> url "…" hash "…"` — the decentralization valve
}

// Dep is one declared dependency: the name (the root namespace the package's
// modules import under, §30 §7), its provenance source, the source's value
// (a version label, a relative path, or a url), and the content-hash pin —
// required for registry/url deps, absent ("") for a path dep, which is
// vouched by the author directly (§30 §3).
Dep :: struct {
	name:   string,
	source: Dep_Source,
	value:  string,
	hash:   string,
}

// read_deps_fcfg reads the optional deps.fcfg out of the configs dir and
// parses it through the §30 §3 deps grammar. An absent file is zero declared
// dependencies (deps.fcfg is optional — a stdlib-only game has none), never
// an error, mirroring read_builds_fcfg. A present file that violates the
// grammar surfaces Malformed_Deps_Fcfg.
read_deps_fcfg :: proc(configs_dir: string) -> (deps: []Dep, err: Project_Error) {
	path, _ := filepath.join({configs_dir, "deps.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return nil, .None
	}
	return parse_deps_fcfg(string(bytes))
}

// parse_deps_fcfg parses the §30 §3 deps grammar into the declared dependency
// list, or rejects a present file that violates it. The grammar is a sequence
// of top-level `@doc(…)` directives and `use <name> <source> "<value>"
// [hash "<hash>"]` declarations; the source kind is the closed identifier set
// version/path/url. A registry/url dep missing its hash, a hash on a path dep
// (path deps carry none — you vouch for the tree directly), a duplicate
// dependency name (one name, one dependency — a second declaration could
// silently shadow the first), or any non-grammar construct is a
// Malformed_Deps_Fcfg rejection. Zero declarations is legal (an
// empty-but-present file declares no deps) — only a malformed construct
// rejects.
parse_deps_fcfg :: proc(content: string) -> (deps: []Dep, err: Project_Error) {
	p := Cfg_Parser{tokens = lex_fcfg(content)}
	list := make([dynamic]Dep, 0, 2, context.temp_allocator)
	for !cfg_at_end(&p) {
		#partial switch cfg_peek(&p).kind {
		case .At:
			cfg_skip_doc_deps(&p) or_return
		case .Ident:
			// The only legal top-level identifier is the `use` declaration
			// opener; any other top-level token is outside the deps grammar.
			if cfg_peek(&p).text != "use" {
				return nil, .Malformed_Deps_Fcfg
			}
			dep := cfg_parse_use_dep(&p) or_return
			for prior in list {
				if prior.name == dep.name {
					return nil, .Malformed_Deps_Fcfg
				}
			}
			append(&list, dep)
		case:
			return nil, .Malformed_Deps_Fcfg
		}
	}
	return list[:], .None
}

// cfg_parse_use_dep parses one `use <name> <source> "<value>" [hash "<hash>"]`
// declaration. The source kind selects the closed Dep_Source set and decides
// the hash obligation: version/url demand it (§30 §4 — the pin IS the
// lockfile), path forbids it (§30 §3 — a path dep is vouched by you, the
// table grants it no hash column).
cfg_parse_use_dep :: proc(p: ^Cfg_Parser) -> (dep: Dep, err: Project_Error) {
	cfg_expect_deps_text(p, "use") or_return
	name := cfg_expect_deps(p, .Ident) or_return
	source_tok := cfg_expect_deps(p, .Ident) or_return
	source, source_ok := parse_dep_source(source_tok.text)
	if !source_ok {
		return Dep{}, .Malformed_Deps_Fcfg
	}
	value := cfg_expect_deps(p, .String) or_return
	dep = Dep{name = name.text, source = source, value = value.text}
	if cfg_peek(p).kind == .Ident && cfg_peek(p).text == "hash" {
		cfg_expect_deps(p, .Ident) or_return
		hash := cfg_expect_deps(p, .String) or_return
		dep.hash = hash.text
	}
	hash_required := source != .Path
	if hash_required && dep.hash == "" {
		return Dep{}, .Malformed_Deps_Fcfg
	}
	if !hash_required && dep.hash != "" {
		return Dep{}, .Malformed_Deps_Fcfg
	}
	return dep, .None
}

// parse_dep_source maps a source-kind identifier to the closed Dep_Source
// set, reporting ok = false for any value outside it — the reject signal
// cfg_parse_use_dep turns into Malformed_Deps_Fcfg.
parse_dep_source :: proc(text: string) -> (source: Dep_Source, ok: bool) {
	switch text {
	case "version":
		return .Registry, true
	case "path":
		return .Path, true
	case "url":
		return .Url, true
	case:
		return .Registry, false
	}
}

// cfg_expect_deps is cfg_expect threading the deps error arm: it consumes the
// next token, demanding the given kind, and surfaces Malformed_Deps_Fcfg on a
// mismatch so the deps production threads its own closed arm rather than
// another config's.
cfg_expect_deps :: proc(p: ^Cfg_Parser, kind: Cfg_Token_Kind) -> (tok: Cfg_Token, err: Project_Error) {
	tok = cfg_peek(p)
	if tok.kind != kind {
		return Cfg_Token{}, .Malformed_Deps_Fcfg
	}
	p.pos += 1
	return tok, .None
}

// cfg_expect_deps_text is cfg_expect_deps demanding a specific identifier
// text too — the `use` declaration-opener keyword.
cfg_expect_deps_text :: proc(p: ^Cfg_Parser, text: string) -> Project_Error {
	tok := cfg_peek(p)
	if tok.kind != .Ident || tok.text != text {
		return .Malformed_Deps_Fcfg
	}
	p.pos += 1
	return .None
}

// cfg_skip_doc_deps consumes a `@doc("…")` directive inside the deps grammar,
// mirroring cfg_skip_doc but threading the deps error arm.
cfg_skip_doc_deps :: proc(p: ^Cfg_Parser) -> Project_Error {
	cfg_expect_deps(p, .At) or_return
	name := cfg_expect_deps(p, .Ident) or_return
	if name.text != "doc" {
		return .Malformed_Deps_Fcfg
	}
	cfg_expect_deps(p, .L_Paren) or_return
	cfg_expect_deps(p, .String) or_return
	cfg_expect_deps(p, .R_Paren) or_return
	return .None
}

// ── §30 §7 path-source package resolution ───────────────────────────────

// collect_package_sources resolves every PATH dependency to its package tree
// and returns the combined dependency source set: each dep's src/ modules,
// prefixed `<project-name>.<module>` (§30 §7 — the package name is its root
// namespace; §15 §5 — the project name becomes a namespace prefix only
// across the package boundary) with package_root stamped, in declared-dep
// order with each dep's sources path-sorted (collect_sources), so the set is
// deterministic. Before any source joins, the tree is adjudicated as a
// PACKAGE:
//   - its funpack_configs/project.fcfg must parse (Malformed_Package_Tree)
//     and its project name must equal the `use` name (Dep_Name_Mismatch);
//   - a project name on the reserved `engine` root is refused
//     (Package_Shadows_Engine_Root) — reserved roots are unshadowable;
//   - a present entrypoints.fcfg is refused (Malformed_Package_Tree): a
//     package is structurally a project WITHOUT an entrypoint (§30 §7);
//   - a deps.fcfg declaring any dependency is the §30 §2 star-graph
//     violation (Package_Imports_Package): a package depends only on engine.
// Registry/url deps are skipped — vendoring + the hash gate are §30 §4
// (downstream); their declarations ride Project.deps untouched.
collect_package_sources :: proc(root: string, deps: []Dep) -> (sources: []Source, err: Project_Error) {
	collected := make([dynamic]Source, 0, 4, context.temp_allocator)
	for dep in deps {
		if dep.source != .Path {
			continue
		}
		dep_root, _ := filepath.join({root, dep.value}, context.temp_allocator)
		identity := read_package_identity(dep_root) or_return
		if module_under_reserved_root(identity.name) {
			return nil, .Package_Shadows_Engine_Root
		}
		if identity.name != dep.name {
			return nil, .Dep_Name_Mismatch
		}
		check_package_is_leaf(dep_root) or_return
		dep_sources := collect_package_tree_sources(dep_root) or_return
		for source in dep_sources {
			prefixed := strings.concatenate({identity.name, ".", source.module}, context.temp_allocator)
			append(&collected, Source{path = source.path, module = prefixed, package_root = identity.name})
		}
	}
	return collected[:], .None
}

// read_package_identity reads and parses a path dependency's
// funpack_configs/project.fcfg — the package identity whose name is the root
// namespace (§14 §4, §30 §7). Any missing piece of that chain (no configs
// dir, no project.fcfg, a file the identity grammar rejects) is
// Malformed_Package_Tree: the precise project.fcfg arms describe the
// CONSUMER's own tree, so the dependency's malformation gets the arm that
// names the §30 rule — the declared path does not hold a well-formed package.
read_package_identity :: proc(dep_root: string) -> (identity: Project_Identity, err: Project_Error) {
	configs_dir, _ := filepath.join({dep_root, "funpack_configs"}, context.temp_allocator)
	if !os.is_dir(configs_dir) {
		return Project_Identity{}, .Malformed_Package_Tree
	}
	fcfg_path, _ := filepath.join({configs_dir, "project.fcfg"}, context.temp_allocator)
	fcfg_bytes, read_err := os.read_entire_file_from_path(fcfg_path, context.temp_allocator)
	if read_err != nil {
		return Project_Identity{}, .Malformed_Package_Tree
	}
	parsed, parse_err := parse_project_fcfg(string(fcfg_bytes))
	if parse_err != .None {
		return Project_Identity{}, .Malformed_Package_Tree
	}
	return parsed, .None
}

// check_package_is_leaf enforces the two §30 structural facts a package tree
// must satisfy before its sources join a consumer's build: it has NO
// entrypoint (§30 §7 — a game runs, a package is imported; a tree with
// entrypoints.fcfg is a game, and depending on a game is a malformed-package
// refusal) and it declares NO dependencies of its own (§30 §2 — the star
// graph is depth-1, always: a package depends only on engine, so a dep tree
// whose deps.fcfg declares anything is the named Package_Imports_Package
// star-graph violation). A present-but-empty deps.fcfg declares nothing and
// passes; a deps.fcfg the grammar rejects is a malformed package tree.
check_package_is_leaf :: proc(dep_root: string) -> Project_Error {
	configs_dir, _ := filepath.join({dep_root, "funpack_configs"}, context.temp_allocator)
	entrypoints_path, _ := filepath.join({configs_dir, "entrypoints.fcfg"}, context.temp_allocator)
	if os.is_file(entrypoints_path) {
		return .Malformed_Package_Tree
	}
	deps_path, _ := filepath.join({configs_dir, "deps.fcfg"}, context.temp_allocator)
	deps_bytes, read_err := os.read_entire_file_from_path(deps_path, context.temp_allocator)
	if read_err != nil {
		return .None
	}
	dep_deps, parse_err := parse_deps_fcfg(string(deps_bytes))
	if parse_err != .None {
		return .Malformed_Package_Tree
	}
	if len(dep_deps) > 0 {
		return .Package_Imports_Package
	}
	return .None
}

// collect_package_tree_sources walks a package's src/ through the same §15
// collection the consumer's own tree rides (collect_sources): paths sorted,
// modules path-derived, the reserved-root and duplicate-module checks applied
// to the package's OWN (unprefixed) module set — §30 §7: the dependency is
// compiled through your pipeline with the same gates as your own code. A
// missing or empty src/ maps to Malformed_Package_Tree (a package with no
// sources exports nothing — the declared path does not hold a package); the
// precise §15 arms (Reserved_Engine_Root, Duplicate_Module) pass through
// untouched, naming the same rule they name on a consumer tree.
collect_package_tree_sources :: proc(dep_root: string) -> (sources: []Source, err: Project_Error) {
	collected, collect_err := collect_sources(dep_root)
	#partial switch collect_err {
	case .None:
		return collected, .None
	case .Missing_Src_Dir, .No_Sources:
		return nil, .Malformed_Package_Tree
	case:
		return nil, collect_err
	}
}

// check_package_root_shadowing enforces the consumer-side half of §30 §7's
// reserved-root rule over the COMBINED consumer source set (src/ + gen/): a
// declared dependency's name joins `engine` as a reserved root, so a local
// module named like a dep's root namespace — the bare root (`src/hexgrid.fun`
// beside `use hexgrid`) or anything beneath it (`src/hexgrid/axial.fun`, or a
// dotted filename deriving `hexgrid.layout`) — shadows the dependency and is
// the named Module_Shadows_Package_Root compile error. Every DECLARED dep
// reserves its root, path or not: a registry/url dep's namespace is claimed
// by the declaration even before its vendored tree resolves (§30 §4,
// downstream), so the collision cannot appear later as a silent rebind.
check_package_root_shadowing :: proc(sources: []Source, deps: []Dep) -> Project_Error {
	for dep in deps {
		dep_prefix := strings.concatenate({dep.name, "."}, context.temp_allocator)
		for source in sources {
			if source.module == dep.name || strings.has_prefix(source.module, dep_prefix) {
				return .Module_Shadows_Package_Root
			}
		}
	}
	return .None
}
