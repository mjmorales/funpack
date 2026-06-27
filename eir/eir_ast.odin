// Parsing and per-run caching for the source lints: turn the paths discovery
// found into core:odin/ast trees, cache each by canonical absolute path so one run
// never parses a file twice, and surface — never swallow — the files that fail to
// parse. This is the load layer's back half; discover_odin_sources finds the
// files, load_dir turns them into the Load_Result the dup engine consumes.
package eir

import "base:runtime"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"

NO_POS :: tokenizer.Pos{}

// warm_tokenizer_keyword_lut builds core:odin/tokenizer's process-global keyword
// LUT once, serially, at program init — before the parallel test runner (or any
// future concurrent parse) spawns a worker thread. The upstream lazy init guards
// the LUT with a double-checked lock that never re-checks inside the lock, so two
// threads racing the first parse both run keyword_lut_init and the second asserts
// on an already-filled slot. Pre-warming on the single init thread closes that race
// window for every parser-using lint.
@(init)
warm_tokenizer_keyword_lut :: proc "contextless" () {
	context = runtime.default_context()
	t: tokenizer.Tokenizer
	tokenizer.init(&t, "package p", "")
}

// Loaded is one successfully parsed source: the absolute path, the test/non-test
// tag carried from discovery, and the parsed tree. file points into the loader's
// allocator and is valid for that allocator's lifetime.
Loaded :: struct {
	path:    string,
	is_test: bool,
	file:    ^ast.File,
}

// Load_Result is the deterministic outcome of loading a directory: every source
// that parsed (in discovery order), the count that did not, and the paths that did
// not. parse_failures is a first-class output, not an error swallowed mid-walk — a
// lint reading `files` knows its view is partial exactly when parse_failures > 0,
// and `failures` names which files to inspect.
Load_Result :: struct {
	files:          []Loaded,
	parse_failures: int,
	failures:       []string,
}

// Loader owns the per-run parse cache. The cache keys on the canonical absolute
// path, so loading the same file twice in one run returns the first parse's tree
// (pointer-identical) instead of re-parsing. The cache is RUN-SCOPED: a lint loads
// its tree, reports, and exits, so no file changes under a live loader and
// mtime/size invalidation would guard a state that cannot occur (decision
// eir-ast-cache-run-scoped). allocator backs the cache map, the parsed trees, and
// the source buffers — one shared lifetime.
Loader :: struct {
	cache:     map[string]^ast.File,
	allocator: runtime.Allocator,
}

// loader_init binds a loader to `allocator`: the cache map, every parsed tree, and
// every source buffer are allocated there, so freeing the allocator (or resetting
// its arena) frees the whole load at once.
loader_init :: proc(l: ^Loader, allocator := context.allocator) {
	l.allocator = allocator
	l.cache = make(map[string]^ast.File, 16, allocator)
}

// loader_destroy frees the cache index only. It deliberately does NOT free the
// parsed trees: those live in the loader's allocator and are reclaimed with it,
// which is how a lint disposes of a whole load in one stroke.
loader_destroy :: proc(l: ^Loader) {
	delete(l.cache)
}

// load_file parses one source through the cache. The first load of a path reads,
// parses, and caches the tree; a later load of the same path returns that exact
// tree without re-parsing. ok is false when the file could not be read or carried
// a syntax error (a non-zero syntax_error_count) — the returned tree is still the
// partial parse, never nil-dropped, so the caller decides whether it is usable.
// The cache key is the canonical absolute path, so the same file reached by two
// spellings shares one parse.
load_file :: proc(l: ^Loader, path: string) -> (file: ^ast.File, ok: bool) {
	key := path
	if abs, abs_err := filepath.abs(path, l.allocator); abs_err == nil {
		key = abs
	}

	if cached, hit := l.cache[key]; hit {
		return cached, cached.syntax_error_count == 0
	}

	src, read_err := os.read_entire_file(path, l.allocator)
	if read_err != nil {
		return nil, false
	}

	context.allocator = l.allocator

	parsed := ast.new(ast.File, NO_POS, NO_POS)
	parsed.fullpath = key
	parsed.src = string(src)

	p := parser.default_parser()
	// Silence the default stderr handlers: parse failures are reported through
	// Load_Result, so the loader stays a pure data function and a lint owns how it
	// surfaces a syntax error. The count survives nil handlers because the parser
	// increments syntax_error_count unconditionally.
	p.err = nil
	p.warn = nil

	parser.parse_file(&p, parsed)

	l.cache[key] = parsed
	return parsed, parsed.syntax_error_count == 0
}

// load_dir discovers every .odin file under `root` (honoring `excludes`), parses
// each through the cache, and returns the parsed set in discovery order plus a
// surfaced count of the files that failed. ok is false only when discovery itself
// fails (an unresolvable root); a parse failure is a counted Load_Result field, not
// an ok=false abort, so one broken file never hides the rest.
load_dir :: proc(
	l: ^Loader,
	root: string,
	excludes: []string,
) -> (
	result: Load_Result,
	ok: bool,
) {
	sources, disco_ok := discover_odin_sources(root, excludes, l.allocator)
	if !disco_ok {
		return Load_Result{}, false
	}

	loaded := make([dynamic]Loaded, 0, len(sources), l.allocator)
	failures := make([dynamic]string, 0, l.allocator)

	for src in sources {
		file, parsed_ok := load_file(l, src.path)
		if parsed_ok {
			append(&loaded, Loaded{path = src.path, is_test = src.is_test, file = file})
		} else {
			append(&failures, src.path)
		}
	}

	return Load_Result {
			files = loaded[:],
			parse_failures = len(failures),
			failures = failures[:],
		},
		true
}
