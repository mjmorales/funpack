// Project-tree reader for the §14-enforced layout: funpack errors on a
// malformed tree as it errors on a malformed function — there is no
// alternative arrangement and no override flag. The project.fcfg parse
// here is the §14 *smaller* config grammar: a single
// `project <name> { … }` block whose label IS the package name, carrying
// the required `version = "…"`, plus `key = value` assignments and `@doc`
// directives. The grammar has no expressions, no control flow, and no
// `use` references — those name source and are out of scope for project
// identity (§14.2). A tree that violates the grammar is rejected, never
// silently ignored.
package funpack

import "core:os"
import "core:path/filepath"

Project :: struct {
	name:    string,
	version: string,
	sources: []string,
}

Project_Error :: enum {
	None,
	Missing_Configs_Dir,
	Missing_Project_Fcfg,
	Malformed_Project_Fcfg,
	Missing_Project_Version,
	Missing_Src_Dir,
	No_Sources,
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

// Cfg_Token is the minimal token set the project.fcfg grammar needs. The
// `.fun` lexer is deliberately not reused: it carries casing classes,
// Fixed literals, and `.fun`-specific newline semantics that the smaller
// config grammar has no use for.
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

// cfg_scan_punct maps the six bracket/operator glyphs the grammar uses;
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
	case:
		return Cfg_Token{kind = .Invalid}
	}
}

collect_sources :: proc(root: string) -> ([]string, Project_Error) {
	src_dir, _ := filepath.join({root, "src"}, context.temp_allocator)
	if !os.is_dir(src_dir) {
		return nil, .Missing_Src_Dir
	}
	pattern, _ := filepath.join({src_dir, "*.fun"}, context.temp_allocator)
	sources, glob_err := filepath.glob(pattern, context.temp_allocator)
	if glob_err != nil || len(sources) == 0 {
		return nil, .No_Sources
	}
	return sources, .None
}
