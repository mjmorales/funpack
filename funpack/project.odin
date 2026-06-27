package funpack

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

RESERVED_ROOT :: "engine"

Source :: struct {
	path:         string,
	module:       string,
	package_root: string,
}

Project :: struct {
	name:         string,
	version:      string,
	sources:      []Source,
	builds:       Builds,
	capabilities: Capabilities,
	deps:         []Dep,
	package_sources: []Source,
}

Build_Platform :: enum {
	Desktop,
	Wasm,
}

Build_Target :: struct {
	name:     string,
	platform: Build_Platform,
}

Builds :: struct {
	targets: []Build_Target,
}

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
	Reserved_Engine_Root,
	Duplicate_Module,
	Malformed_Builds_Fcfg,
	Malformed_Seam,
	Seam_Imports_Behavior,
	Malformed_Deps_Fcfg,
	Malformed_Package_Tree,
	Dep_Name_Mismatch,
	Package_Imports_Package,
	Package_Shadows_Engine_Root,
	Module_Shadows_Package_Root,
	Missing_Vendored_Package,
	Package_Hash_Mismatch,
}

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
	identity, parse_err, parse_detail := parse_project_fcfg(string(fcfg_bytes))
	if parse_err != .None {
		return Project{}, parse_err, parse_detail
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
	seam_sources, seam_collect_err := collect_seam_sources(root, capabilities)
	if seam_collect_err != .None {
		return Project{}, seam_collect_err, ""
	}
	sources, merge_err, merge_detail := merge_sources(src_sources, seam_sources)
	if merge_err != .None {
		return Project{}, merge_err, merge_detail
	}
	if layer_err := check_seam_layering(seam_sources, sources); layer_err != .None {
		return Project{}, layer_err, ""
	}
	deps, deps_err := read_deps_fcfg(configs_dir)
	if deps_err != .None {
		return Project{}, deps_err, ""
	}
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

project_refusal_message :: proc(err: Project_Error, detail: string, allocator := context.allocator) -> string {
	if detail == "" {
		return fmt.aprintf("%v", err, allocator = allocator)
	}
	return fmt.aprintf("%v: %s", err, detail, allocator = allocator)
}

read_builds_fcfg :: proc(configs_dir: string) -> (builds: Builds, err: Project_Error) {
	path, _ := filepath.join({configs_dir, "builds.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return Builds{}, .None
	}
	return parse_builds_fcfg(string(bytes))
}

Project_Identity :: struct {
	name:    string,
	version: string,
}

parse_project_fcfg :: proc(content: string) -> (identity: Project_Identity, err: Project_Error, detail: string) {
	p := Cfg_Parser{tokens = lex_fcfg(content)}
	saw_block := false
	for !cfg_at_end(&p) {
		#partial switch cfg_peek(&p).kind {
		case .At:
			if doc_err := cfg_skip_doc(&p); doc_err != .None {
				return Project_Identity{}, doc_err, ""
			}
		case .Ident:
			if cfg_peek(&p).text != "project" || saw_block {
				return Project_Identity{}, .Malformed_Project_Fcfg, project_shape_detail(
					&p,
					content,
					"a project.fcfg is one `project <name> { ... }` block — the block label IS the package name (there is no `name =` key, and identity is not a TOML/INI section)",
				)
			}
			block_identity, block_err, block_detail := cfg_parse_block(&p, content)
			if block_err != .None {
				return Project_Identity{}, block_err, block_detail
			}
			identity = block_identity
			saw_block = true
		case:
			return Project_Identity{}, .Malformed_Project_Fcfg, project_shape_detail(
				&p,
				content,
				"a project.fcfg is one `project <name> { ... }` brace block, not a `[section]` header",
			)
		}
	}
	if !saw_block {
		return Project_Identity{}, .Malformed_Project_Fcfg, project_shape_detail(
			&p,
			content,
			"a project.fcfg must declare exactly one `project <name> { ... }` block",
		)
	}
	return identity, .None, ""
}

cfg_parse_block :: proc(p: ^Cfg_Parser, content: string) -> (identity: Project_Identity, err: Project_Error, detail: string) {
	if _, kw_err := cfg_expect(p, .Ident); kw_err != .None {
		return Project_Identity{}, kw_err, ""
	}
	label, label_err := cfg_expect(p, .Ident)
	if label_err != .None {
		return Project_Identity{}, label_err, project_shape_detail(
			p,
			content,
			"the block label is the package name — write `project <name> { ... }`, not a labelless `project { ... }`",
		)
	}
	if !is_lower_ident(label.text) {
		return Project_Identity{}, .Malformed_Project_Fcfg, project_name_detail(label)
	}
	if next := cfg_peek(p); next.kind != .L_Brace {
		abut := label.offset + len(label.text)
		if abut < len(content) && cfg_is_name_truncating_byte(content[abut]) {
			return Project_Identity{}, .Malformed_Project_Fcfg, project_name_truncated_detail(label, content[abut])
		}
	}
	if _, brace_err := cfg_expect(p, .L_Brace); brace_err != .None {
		return Project_Identity{}, brace_err, project_shape_detail(
			p,
			content,
			"the package name is followed by a `{ ... }` body block",
		)
	}
	name := label.text
	version := ""
	saw_version := false
	for cfg_peek(p).kind != .R_Brace {
		#partial switch cfg_peek(p).kind {
		case .At:
			if doc_err := cfg_skip_doc(p); doc_err != .None {
				return Project_Identity{}, doc_err, ""
			}
		case .Ident:
			key, value, assign_detail, assign_err := cfg_parse_assignment(p, content)
			if assign_err != .None {
				return Project_Identity{}, assign_err, assign_detail
			}
			if key == "version" {
				version = value
				saw_version = true
			}
		case:
			return Project_Identity{}, .Malformed_Project_Fcfg, project_shape_detail(
				p,
				content,
				"a block body holds `key = \"value\"` assignments and `@doc(...)` directives only",
			)
		}
	}
	if _, rbrace_err := cfg_expect(p, .R_Brace); rbrace_err != .None {
		return Project_Identity{}, rbrace_err, project_shape_detail(
			p,
			content,
			"the block body is closed by `}`",
		)
	}
	if !saw_version {
		return Project_Identity{}, .Missing_Project_Version, project_missing_version_detail(label)
	}
	return Project_Identity{name = name, version = version}, .None, ""
}

project_missing_version_detail :: proc(label: Cfg_Token, allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"project.fcfg:%d: project '%s' is missing the required `version = \"...\"` key (spec §14 §1)",
		label.line,
		label.text,
		allocator = allocator,
	)
}

project_name_detail :: proc(label: Cfg_Token, allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"project.fcfg:%d: project name must be a bare identifier (a lower-case or '_' start, then letters, digits, or '_') — '%s' is not (spec §14 §4, §15)",
		label.line,
		label.text,
		allocator = allocator,
	)
}

project_name_truncated_detail :: proc(label: Cfg_Token, glyph: u8, allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"project.fcfg:%d: project name must be a bare identifier (a lower-case or '_' start, then letters, digits, or '_'); the '%c' after '%s' is not allowed (spec §14 §4, §15)",
		label.line,
		rune(glyph),
		label.text,
		allocator = allocator,
	)
}

cfg_is_name_truncating_byte :: proc(ch: u8) -> bool {
	if ch == '{' || ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' {
		return false
	}
	return !is_ident_char(ch)
}

PROJECT_FCFG_SHAPE :: "project <name> { version = \"...\" }"

cfg_token_col :: proc(content: string, offset: int) -> int {
	pos := offset
	if pos > len(content) {
		pos = len(content)
	}
	line_start := 0
	for i in 0 ..< pos {
		if content[i] == '\n' {
			line_start = i + 1
		}
	}
	return pos - line_start + 1
}

cfg_found_token :: proc(tok: Cfg_Token, content: string) -> string {
	if tok.offset >= len(content) {
		return "found end of input"
	}
	if tok.text != "" {
		return fmt.tprintf("found '%s'", tok.text)
	}
	return fmt.tprintf("found '%c'", rune(content[tok.offset]))
}

cfg_offender_token :: proc(p: ^Cfg_Parser, content: string) -> Cfg_Token {
	tok := cfg_peek(p)
	if cfg_at_end(p) {
		line := 1
		for i in 0 ..< len(content) {
			if content[i] == '\n' {
				line += 1
			}
		}
		return Cfg_Token{kind = .Invalid, offset = len(content), line = line}
	}
	return tok
}

project_shape_detail :: proc(p: ^Cfg_Parser, content: string, hint: string, allocator := context.temp_allocator) -> string {
	tok := cfg_offender_token(p, content)
	return fmt.aprintf(
		"project.fcfg:%d:%d: expected %s, %s — %s (spec §14 §1, §14 §2)",
		tok.line,
		cfg_token_col(content, tok.offset),
		PROJECT_FCFG_SHAPE,
		cfg_found_token(tok, content),
		hint,
		allocator = allocator,
	)
}

cfg_parse_assignment :: proc(p: ^Cfg_Parser, content: string) -> (key: string, value: string, detail: string, err: Project_Error) {
	key_tok, key_err := cfg_expect(p, .Ident)
	if key_err != .None {
		return "", "", project_shape_detail(p, content, "a block body assignment is `key = \"value\"`"), key_err
	}
	if _, eq_err := cfg_expect(p, .Eq); eq_err != .None {
		return "", "", project_shape_detail(
			p,
			content,
			"an assignment binds with `=`, not `:` — write `version = \"...\"`",
		), eq_err
	}
	value_tok, value_err := cfg_expect(p, .String)
	if value_err != .None {
		return "", "", project_shape_detail(
			p,
			content,
			"an assignment value is a double-quoted string literal (`version = \"0.1.0\"`)",
		), value_err
	}
	return key_tok.text, value_tok.text, "", .None
}

parse_builds_fcfg :: proc(content: string) -> (builds: Builds, err: Project_Error) {
	p := Cfg_Parser{tokens = lex_fcfg(content)}
	targets := make([dynamic]Build_Target, 0, 2, context.temp_allocator)
	for !cfg_at_end(&p) {
		#partial switch cfg_peek(&p).kind {
		case .At:
			cfg_skip_doc_builds(&p) or_return
		case .Ident:
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

cfg_parse_build_block :: proc(p: ^Cfg_Parser) -> (target: Build_Target, err: Project_Error) {
	cfg_expect_builds_text(p, "build") or_return
	label := cfg_expect_builds(p, .Ident) or_return
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
			value := cfg_expect_builds(p, .Ident) or_return
			platform, ok := parse_build_platform(value.text)
			if !ok {
				return Build_Target{}, .Malformed_Builds_Fcfg
			}
			target.platform = platform
			saw_platform = true
		case:
			return Build_Target{}, .Malformed_Builds_Fcfg
		}
	}
	cfg_expect_builds(p, .R_Brace) or_return
	if !saw_platform {
		return Build_Target{}, .Malformed_Builds_Fcfg
	}
	return target, .None
}

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

cfg_expect_builds :: proc(p: ^Cfg_Parser, kind: Cfg_Token_Kind) -> (tok: Cfg_Token, err: Project_Error) {
	tok = cfg_peek(p)
	if tok.kind != kind {
		return Cfg_Token{}, .Malformed_Builds_Fcfg
	}
	p.pos += 1
	return tok, .None
}

cfg_expect_builds_text :: proc(p: ^Cfg_Parser, text: string) -> Project_Error {
	tok := cfg_peek(p)
	if tok.kind != .Ident || tok.text != text {
		return .Malformed_Builds_Fcfg
	}
	p.pos += 1
	return .None
}

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

Entrypoints :: struct {
	use_module:  string,
	use_members: []string,
	entrypoints: []Entrypoint,
}

Entrypoint :: struct {
	name:     string,
	pipeline: string,
	tick:     string,
	logical:  string,
	bindings: string,
	seed:     string,
}

Entrypoints_Error :: enum {
	None,
	Malformed_Entrypoints_Fcfg,
	Dangling_Reference,
	Multiple_Entrypoints,
}

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

cfg_parse_use :: proc(p: ^Cfg_Parser) -> (module: string, members: []string, err: Entrypoints_Error) {
	cfg_take(p, .Ident, "use") or_return
	module_tok := cfg_take(p, .Ident) or_return
	cfg_take(p, .Dot) or_return
	cfg_take(p, .L_Brace) or_return
	list := make([dynamic]string, 0, 4, context.temp_allocator)
	for cfg_peek(p).kind == .Ident {
		member := cfg_take(p, .Ident) or_return
		append(&list, member.text)
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
			value := cfg_take(p, .Tick) or_return
			block.logical = value.text
			saw_logical = true
		case "seed":
			value := cfg_take(p, .Tick) or_return
			block.seed = value.text
		case:
			return Entrypoint{}, .Malformed_Entrypoints_Fcfg
		}
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

cfg_take :: proc(p: ^Cfg_Parser, kind: Cfg_Token_Kind, text: string = "") -> (tok: Cfg_Token, err: Entrypoints_Error) {
	tok = cfg_peek(p)
	if tok.kind != kind || (text != "" && tok.text != text) {
		return Cfg_Token{}, .Malformed_Entrypoints_Fcfg
	}
	p.pos += 1
	return tok, .None
}

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

module_declares_pipeline :: proc(ast: Ast, name: string) -> bool {
	for decl in ast.pipelines {
		if decl.name == name {
			return true
		}
	}
	return false
}

module_declares_fn :: proc(ast: Ast, name: string) -> bool {
	for decl in ast.fns {
		if decl.name == name {
			return true
		}
	}
	return false
}

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

Cfg_Token_Kind :: enum {
	Invalid,
	Ident,
	String,
	Eq,
	At,
	L_Brace,
	R_Brace,
	L_Paren,
	R_Paren,
	Dot,
	Tick,
	Comma,
}

Cfg_Token :: struct {
	kind:   Cfg_Token_Kind,
	text:   string,
	line:   int,
	offset: int,
}

Cfg_Parser :: struct {
	tokens: []Cfg_Token,
	pos:    int,
}

cfg_at_end :: proc(p: ^Cfg_Parser) -> bool {
	return p.pos >= len(p.tokens)
}

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

lex_fcfg :: proc(content: string) -> []Cfg_Token {
	tokens := make([dynamic]Cfg_Token, 0, 16, context.temp_allocator)
	i := 0
	line := 1
	for i < len(content) {
		ch := content[i]
		start := i
		start_line := line
		switch {
		case ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n':
			if ch == '\n' {
				line += 1
			}
			i += 1
			continue
		case ch == '"':
			tok, next := cfg_scan_string(content, i)
			append(&tokens, cfg_stamp(tok, start_line, start))
			i = next
		case is_ident_start(ch):
			tok, next := cfg_scan_ident(content, i)
			append(&tokens, cfg_stamp(tok, start_line, start))
			i = next
		case is_digit(ch):
			tok, next := cfg_scan_tick(content, i)
			append(&tokens, cfg_stamp(tok, start_line, start))
			i = next
		case:
			append(&tokens, cfg_stamp(cfg_scan_punct(ch), start_line, start))
			i += 1
		}
	}
	return tokens[:]
}

cfg_stamp :: proc(tok: Cfg_Token, line: int, offset: int) -> Cfg_Token {
	stamped := tok
	stamped.line = line
	stamped.offset = offset
	return stamped
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

cfg_scan_tick :: proc(content: string, start: int) -> (tok: Cfg_Token, next: int) {
	i := start
	for i < len(content) && (is_digit(content[i]) || is_ident_char(content[i])) {
		i += 1
	}
	return Cfg_Token{kind = .Tick, text = content[start:i]}, i
}

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

derive_module_name :: proc(src_root: string, source_path: string) -> string {
	rel, rel_err := filepath.rel(src_root, source_path, context.temp_allocator)
	if rel_err != .None {
		rel = source_path
	}
	stem := strings.trim_suffix(rel, ".fun")
	segments := strings.split(stem, filepath.SEPARATOR_STRING, context.temp_allocator)
	return strings.join(segments, ".", context.temp_allocator)
}

module_under_reserved_root :: proc(module: string) -> bool {
	return module == RESERVED_ROOT || strings.has_prefix(module, RESERVED_ROOT + ".")
}

Subsystem_Dir :: struct {
	dir: string,
	ext: string,
}

derive_tree_capabilities :: proc(root: string) -> Capabilities {
	caps: Capabilities
	expected := make([dynamic]string, 0, 4, context.temp_allocator)
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

GEN_ROOT :: "gen"
GEN_SUFFIX :: ".gen.fun"

collect_seam_sources :: proc(root: string, caps: Capabilities) -> ([]Source, Project_Error) {
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

derive_seam_module_name :: proc(gen_root: string, source_path: string) -> string {
	rel, rel_err := filepath.rel(gen_root, source_path, context.temp_allocator)
	if rel_err != .None {
		rel = source_path
	}
	stem := strings.trim_suffix(rel, GEN_SUFFIX)
	segments := strings.split(stem, filepath.SEPARATOR_STRING, context.temp_allocator)
	return strings.join(segments, ".", context.temp_allocator)
}

capabilities_any_on :: proc(caps: Capabilities) -> bool {
	return caps.levels || caps.models || caps.ui || caps.assets
}

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

parse_source :: proc(path: string) -> (ast: Ast, ok: bool) {
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return
	}
	parsed, parse_err := stage_parse(stage_lex(string(bytes)))
	if parse_err != .None {
		return
	}
	return parsed, true
}

check_seam_layering :: proc(seam_sources: []Source, all_sources: []Source) -> Project_Error {
	for seam in seam_sources {
		seam_ast, ok := parse_source(seam.path)
		if !ok {
			return .Malformed_Seam
		}
		for imp in seam_ast.imports {
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

source_is_behavior_module :: proc(all_sources: []Source, module: string) -> bool {
	for source in all_sources {
		if source.module != module {
			continue
		}
		ast, ok := parse_source(source.path)
		if !ok {
			return false
		}
		return len(ast.behaviors) > 0 || len(ast.pipelines) > 0
	}
	return false
}
