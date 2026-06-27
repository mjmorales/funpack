package eir

import "base:runtime"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"

NO_POS :: tokenizer.Pos{}

@(init)
warm_tokenizer_keyword_lut :: proc "contextless" () {
	context = runtime.default_context()
	t: tokenizer.Tokenizer
	tokenizer.init(&t, "package p", "")
}

Loaded :: struct {
	path:    string,
	is_test: bool,
	file:    ^ast.File,
}

Load_Result :: struct {
	files:          []Loaded,
	parse_failures: int,
	failures:       []string,
}

Loader :: struct {
	cache:     map[string]^ast.File,
	allocator: runtime.Allocator,
}

loader_init :: proc(l: ^Loader, allocator := context.allocator) {
	l.allocator = allocator
	l.cache = make(map[string]^ast.File, 16, allocator)
}

loader_destroy :: proc(l: ^Loader) {
	delete(l.cache)
}

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
	p.err = nil
	p.warn = nil

	parser.parse_file(&p, parsed)

	l.cache[key] = parsed
	return parsed, parsed.syntax_error_count == 0
}

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
