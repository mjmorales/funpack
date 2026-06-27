package funpack

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Dep_Source :: enum {
	Registry,
	Path,
	Url,
}

Dep :: struct {
	name:   string,
	source: Dep_Source,
	value:  string,
	hash:   string,
}

read_deps_fcfg :: proc(configs_dir: string) -> (deps: []Dep, err: Project_Error) {
	path, _ := filepath.join({configs_dir, "deps.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return nil, .None
	}
	return parse_deps_fcfg(string(bytes))
}

parse_deps_fcfg :: proc(content: string) -> (deps: []Dep, err: Project_Error) {
	p := Cfg_Parser{tokens = lex_fcfg(content)}
	list := make([dynamic]Dep, 0, 2, context.temp_allocator)
	for !cfg_at_end(&p) {
		#partial switch cfg_peek(&p).kind {
		case .At:
			cfg_skip_doc_deps(&p) or_return
		case .Ident:
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

cfg_expect_deps :: proc(p: ^Cfg_Parser, kind: Cfg_Token_Kind) -> (tok: Cfg_Token, err: Project_Error) {
	tok = cfg_peek(p)
	if tok.kind != kind {
		return Cfg_Token{}, .Malformed_Deps_Fcfg
	}
	p.pos += 1
	return tok, .None
}

cfg_expect_deps_text :: proc(p: ^Cfg_Parser, text: string) -> Project_Error {
	tok := cfg_peek(p)
	if tok.kind != .Ident || tok.text != text {
		return .Malformed_Deps_Fcfg
	}
	p.pos += 1
	return .None
}

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
	parsed, parse_err, _ := parse_project_fcfg(string(fcfg_bytes))
	if parse_err != .None {
		return Project_Identity{}, .Malformed_Package_Tree
	}
	return parsed, .None
}

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

VENDOR_DIR :: "packages"

vendored_package_dir :: proc(root: string, dep_name: string) -> string {
	dir, _ := filepath.join({root, VENDOR_DIR, dep_name}, context.temp_allocator)
	return dir
}

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

Vendored_File :: struct {
	rel:  string,
	path: string,
}

hash_vendored_tree :: proc(dep_dir: string) -> (hash: string, ok: bool) {
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
