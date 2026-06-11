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
// refusal both see the edge. Registry/url deps carry the §30 §4 pin contract
// this file VERIFIES (the bottom section): the declared content hash is
// re-computed over the committed packages/<name>/ vendored tree every
// project read, an inexact match or an absent tree is a named refusal, and
// nothing here can fetch — the resolver reads the filesystem only (core:os),
// no network primitive is linked, so builds are hermetic by construction.
// Joining a verified registry/url tree's sources to the build (the way path
// deps join) lands later behind this same pin gate.
package funpack

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
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
// Registry/url deps are skipped HERE — their vendored trees are verified
// against the declared pin by verify_vendored_deps (the §30 §4 gate
// read_project runs before this resolution); joining their sources to the
// build lands later behind that same gate.
collect_package_sources :: proc(root: string, deps: []Dep) -> (sources: []Source, err: Project_Error, detail: string) {
	collected := make([dynamic]Source, 0, 4, context.temp_allocator)
	for dep in deps {
		if dep.source != .Path {
			continue
		}
		dep_root, _ := filepath.join({root, dep.value}, context.temp_allocator)
		identity, identity_err := read_package_identity(dep_root)
		if identity_err != .None {
			return nil, identity_err, fmt.tprintf("use %s: the tree at %s is not a well-formed package", dep.name, dep.value)
		}
		if module_under_reserved_root(identity.name) {
			return nil, .Package_Shadows_Engine_Root, fmt.tprintf("use %s: the tree's project name '%s' falls under the reserved engine root (§15 §7)", dep.name, identity.name)
		}
		if identity.name != dep.name {
			return nil, .Dep_Name_Mismatch, fmt.tprintf("use %s: the tree's project.fcfg declares '%s' — one name, one identity (§30 §7)", dep.name, identity.name)
		}
		if leaf_err := check_package_is_leaf(dep_root); leaf_err != .None {
			if leaf_err == .Package_Imports_Package {
				return nil, leaf_err, fmt.tprintf("use %s: the tree declares its own dependencies — a package depends only on engine (§30 §2)", dep.name)
			}
			return nil, leaf_err, fmt.tprintf("use %s: the tree at %s is not a well-formed package", dep.name, dep.value)
		}
		dep_sources, tree_err, tree_detail := collect_package_tree_sources(dep_root)
		if tree_err != .None {
			if tree_detail == "" {
				tree_detail = fmt.tprintf("use %s: the tree at %s is not a well-formed package", dep.name, dep.value)
			}
			return nil, tree_err, tree_detail
		}
		for source in dep_sources {
			prefixed := strings.concatenate({identity.name, ".", source.module}, context.temp_allocator)
			append(&collected, Source{path = source.path, module = prefixed, package_root = identity.name})
		}
	}
	return collected[:], .None, ""
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
collect_package_tree_sources :: proc(dep_root: string) -> (sources: []Source, err: Project_Error, detail: string) {
	collected, collect_err, collect_detail := collect_sources(dep_root)
	#partial switch collect_err {
	case .None:
		return collected, .None, ""
	case .Missing_Src_Dir, .No_Sources:
		return nil, .Malformed_Package_Tree, ""
	case:
		return nil, collect_err, collect_detail
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
check_package_root_shadowing :: proc(sources: []Source, deps: []Dep) -> (err: Project_Error, detail: string) {
	for dep in deps {
		dep_prefix := strings.concatenate({dep.name, "."}, context.temp_allocator)
		for source in sources {
			if source.module == dep.name || strings.has_prefix(source.module, dep_prefix) {
				return .Module_Shadows_Package_Root, fmt.tprintf("%s derives module '%s', which shadows the declared dependency root '%s' (§30 §7)", source.path, source.module, dep.name)
			}
		}
	}
	return .None, ""
}

// ── §30 §4 content-hash pins + vendored verification ─────────────────────

// VENDOR_DIR is the §30 §4 vendored-tree root: a registry/url dependency's
// source is fetched once into packages/<name>/, committed, and reviewed in
// PRs — no opaque node_modules. The pin gate below re-hashes that committed
// tree every project read, so local tampering is caught at the same gate a
// compromised fetch would be.
VENDOR_DIR :: "packages"

// vendored_package_dir is where §30 §4 puts a declared dependency's vendored
// tree: packages/<name>/ under the consumer root, the same directory a path
// dep conventionally lives in — one place to review either provenance.
vendored_package_dir :: proc(root: string, dep_name: string) -> string {
	dir, _ := filepath.join({root, VENDOR_DIR, dep_name}, context.temp_allocator)
	return dir
}

// verify_vendored_deps is the §30 §4 pin gate read_project runs over every
// declared dependency before any package source joins the build: each
// registry/url dep's vendored tree at packages/<name>/ is re-hashed
// (hash_vendored_tree) and compared against the declared pin under the
// exact-match discipline — byte-equal or refused, no partial acceptance,
// the same all-or-nothing the Index Contract reader applies (§29 §2). A
// path dep is never verified: §30 §3 grants it no hash column — you vouch
// for the tree directly — so the loop skips it without touching the disk.
//
// The two refusal arms, each with its fix-it riding beside the closed enum
// (the named-offender discipline — the arm is the machine contract, the
// fix-it is the advisory line an agent repairs from):
//   - Missing_Vendored_Package: the pinned dep has no vendored tree (or one
//     that cannot be read back for hashing). Builds never touch the network
//     (§30 §4 hermetic) — fetching is `funpack add`'s job, never the
//     build's — so the refusal names the missing packages/<name>/ tree
//     instead of reaching out.
//   - Package_Hash_Mismatch: the re-hashed tree differs from the pin. The
//     fix-it carries the ACTUAL hash so the author can review the vendored
//     diff and re-pin deliberately (§30 §5 — every change to dependency
//     code is a human-reviewed diff, never a silent upgrade or downgrade).
verify_vendored_deps :: proc(root: string, deps: []Dep) -> (err: Project_Error, fix_it: string) {
	for dep in deps {
		if dep.source == .Path {
			continue
		}
		dep_dir := vendored_package_dir(root, dep.name)
		if !os.is_dir(dep_dir) {
			return .Missing_Vendored_Package, fmt.tprintf(
				"%s: pinned dependency has no vendored tree at %s/%s/ — builds never fetch (§30 §4); vendor the source and commit it",
				dep.name,
				VENDOR_DIR,
				dep.name,
			)
		}
		actual, hash_ok := hash_vendored_tree(dep_dir)
		if !hash_ok {
			return .Missing_Vendored_Package, fmt.tprintf(
				"%s: vendored tree at %s/%s/ cannot be read back for hash verification",
				dep.name,
				VENDOR_DIR,
				dep.name,
			)
		}
		if actual != dep.hash {
			return .Package_Hash_Mismatch, fmt.tprintf(
				"%s: vendored tree at %s/%s/ hashes %s but the declared pin is %s — review the vendored diff, then re-pin the declared hash deliberately",
				dep.name,
				VENDOR_DIR,
				dep.name,
				actual,
				dep.hash,
			)
		}
	}
	return .None, ""
}

// Vendored_File pairs one vendored regular file's slash-normalized
// root-relative path (the name the hash covers — identical on every
// platform) with the on-disk path its bytes are read from.
Vendored_File :: struct {
	rel:  string,
	path: string,
}

// hash_vendored_tree computes the §30 §4 content hash of a vendored tree as
// the canonical `sha256:<hex>` string the deps.fcfg pin declares. §30 is
// silent on the exact recipe, so it is pinned HERE as the normative one:
//
//   SHA-256 over [ file count, then per file in rel-path-sorted order:
//                  slash-normalized relative path, file bytes ]
//
// with every field length-prefixed (asset_hash.odin's hash_field framing, so
// the stream is injective — a path/content boundary can never be forged by
// rearranging bytes) and the count folded first (zero files and one empty
// file differ). Determinism: the walk order is discarded and the files are
// sorted by their slash-normalized relative path — not the platform path —
// so the same tree bytes hash identically on every filesystem and OS; no
// clock, no metadata (permissions/mtimes are host noise, content is the
// contract). EVERY regular file under the root is covered with no exclusion
// list — what is in the tree is what is pinned, the exact-match discipline
// with nothing to special-case. ok = false when a file cannot be read back
// (the tree is unverifiable, the caller's missing-tree class), never a
// partial hash.
hash_vendored_tree :: proc(dep_dir: string) -> (hash: string, ok: bool) {
	// The walker resolves the root through realpath, so relativize against
	// the same realpath form (filepath.abs) — the collect_sources idiom for
	// the symlinked temp-root case.
	abs_dir, abs_err := filepath.abs(dep_dir, context.temp_allocator)
	if abs_err != nil {
		abs_dir = dep_dir
	}
	files := make([dynamic]Vendored_File, 0, 8, context.temp_allocator)
	walker := os.walker_create(dep_dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular {
			continue
		}
		rel, rel_err := filepath.rel(abs_dir, info.fullpath, context.temp_allocator)
		if rel_err != .None {
			return "", false
		}
		segments := strings.split(rel, filepath.SEPARATOR_STRING, context.temp_allocator)
		append(
			&files,
			Vendored_File {
				rel = strings.join(segments, "/", context.temp_allocator),
				path = strings.clone(info.fullpath, context.temp_allocator),
			},
		)
	}
	// Sort by the slash-normalized relative path, not the native one: '/'
	// and '\' order differently against the bytes between them, so only the
	// normalized name gives one cross-platform total order.
	slice.sort_by(files[:], proc(a, b: Vendored_File) -> bool {
		return a.rel < b.rel
	})
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	hash_u64(&ctx, u64(len(files)))
	for file in files {
		bytes, read_err := os.read_entire_file_from_path(file.path, context.temp_allocator)
		if read_err != nil {
			return "", false
		}
		hash_field(&ctx, transmute([]byte)file.rel)
		hash_field(&ctx, bytes)
	}
	digest: [32]byte
	sha2.final(&ctx, digest[:])
	hex_digest := hex.encode(digest[:], context.temp_allocator)
	return strings.concatenate({HASH_PREFIX, string(hex_digest)}, context.temp_allocator), true
}
