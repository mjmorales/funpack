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
Source :: struct {
	path:   string,
	module: string,
}

Project :: struct {
	name:    string,
	version: string,
	sources: []Source,
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
}

read_project :: proc(root: string) -> (project: Project, err: Project_Error) {
	configs_dir, _ := filepath.join({root, "funpack_configs"}, context.temp_allocator)
	if !os.is_dir(configs_dir) {
		return Project{}, .Missing_Configs_Dir
	}
	fcfg_path, _ := filepath.join({configs_dir, "project.fcfg"}, context.temp_allocator)
	fcfg_bytes, read_err := os.read_entire_file_from_path(fcfg_path, context.temp_allocator)
	if read_err != nil {
		return Project{}, .Missing_Project_Fcfg
	}
	identity, parse_err := parse_project_fcfg(string(fcfg_bytes))
	if parse_err != .None {
		return Project{}, parse_err
	}
	sources, src_err := collect_sources(root)
	if src_err != .None {
		return Project{}, src_err
	}
	return Project{name = identity.name, version = identity.version, sources = sources}, .None
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
collect_sources :: proc(root: string) -> ([]Source, Project_Error) {
	src_dir, _ := filepath.join({root, "src"}, context.temp_allocator)
	if !os.is_dir(src_dir) {
		return nil, .Missing_Src_Dir
	}
	paths := collect_fun_paths(src_dir)
	if len(paths) == 0 {
		return nil, .No_Sources
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
			return nil, .Reserved_Engine_Root
		}
		if module in seen {
			return nil, .Duplicate_Module
		}
		seen[module] = true
		sources[i] = Source{path = path, module = module}
	}
	return sources, .None
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
