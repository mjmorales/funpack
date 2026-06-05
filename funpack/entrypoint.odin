// The §14 entrypoints.fcfg reader: the runtime wiring a pipeline carries no
// configuration for (spec §07 §1 — wiring lives in the entrypoint, never the
// pipeline). It parses the one selected entrypoint block into the
// pipeline ↔ tick ↔ bindings triple the artifact's [entrypoint] section carries
// (docs/artifact-format.md §15). The grammar is the §14 smaller config grammar:
// a leading `use module.{…}` reference and an `entrypoint <label> { key = value
// }` block whose values are bare tokens (`Pong`, `60hz`, `bindings`) — distinct
// from project.fcfg's string-valued assignments, so it carries its own reader.
//
// The reader is pure over the config text: it derives no value from a clock, a
// path, or a host byte. The `tick` value `60hz` yields the integer Hz `60`;
// there are no multi-rate ticks (§07 §1), so the entrypoint carries one Hz.
package funpack

import "core:strconv"
import "core:strings"

// Entrypoint_Config is the resolved [entrypoint] record (docs/artifact-format.md
// §15): the entrypoint block label, the root pipeline whose flattened order the
// artifact carries, the fixed tick rate in integer Hz, and the bindings fn whose
// resolved table the artifact's [bindings] section carries.
Entrypoint_Config :: struct {
	name:     string,
	pipeline: string,
	tick_hz:  int,
	bindings: string,
}

Entrypoint_Error :: enum {
	None,
	Malformed,    // a token outside the §14 entrypoints grammar
	Missing_Keys, // a well-formed block missing pipeline/tick/bindings
}

// read_entrypoint parses entrypoints.fcfg into the selected entrypoint's wiring.
// It scans top-level `use` references (skipped — they name source, not identity)
// and the one `entrypoint <label> { … }` block, lifting its `pipeline`/`tick`/
// `bindings` assignments. A token outside the grammar is Malformed; a block
// missing any of the three required keys is Missing_Keys.
read_entrypoint :: proc(content: string) -> (config: Entrypoint_Config, err: Entrypoint_Error) {
	tokens := lex_entrypoint(content)
	p := Ep_Parser{tokens = tokens}
	saw_block := false
	for !ep_at_end(&p) {
		tok := ep_peek(&p)
		if tok.kind != .Ident {
			return Entrypoint_Config{}, .Malformed
		}
		switch tok.text {
		case "use":
			ep_skip_use(&p) or_return
		case "entrypoint":
			if saw_block {
				return Entrypoint_Config{}, .Malformed
			}
			config = ep_parse_block(&p) or_return
			saw_block = true
		case:
			return Entrypoint_Config{}, .Malformed
		}
	}
	if !saw_block {
		return Entrypoint_Config{}, .Malformed
	}
	return config, .None
}

// ep_parse_block parses `entrypoint <label> { pipeline = P, tick = Nhz,
// bindings = B }`. The label is the entrypoint name; the body is `key = value`
// assignments with bare-token values. All three keys are required — a missing
// one is Missing_Keys.
ep_parse_block :: proc(p: ^Ep_Parser) -> (config: Entrypoint_Config, err: Entrypoint_Error) {
	ep_expect(p, .Ident) or_return // `entrypoint`
	label := ep_expect(p, .Ident) or_return
	ep_expect(p, .L_Brace) or_return
	config.name = label.text
	saw_pipeline, saw_tick, saw_bindings := false, false, false
	for ep_peek(p).kind != .R_Brace {
		if ep_peek(p).kind != .Ident {
			return Entrypoint_Config{}, .Malformed
		}
		key := ep_expect(p, .Ident) or_return
		ep_expect(p, .Eq) or_return
		value := ep_expect(p, .Ident) or_return
		switch key.text {
		case "pipeline":
			config.pipeline = value.text
			saw_pipeline = true
		case "tick":
			hz, ok := parse_tick_hz(value.text)
			if !ok {
				return Entrypoint_Config{}, .Malformed
			}
			config.tick_hz = hz
			saw_tick = true
		case "bindings":
			config.bindings = value.text
			saw_bindings = true
		}
	}
	ep_expect(p, .R_Brace) or_return
	if !saw_pipeline || !saw_tick || !saw_bindings {
		return Entrypoint_Config{}, .Missing_Keys
	}
	return config, .None
}

// parse_tick_hz extracts the integer Hz from a `Nhz` tick token (`60hz` → 60).
// The tick rate is a fixed integer Hz (docs/artifact-format.md §15); a token
// without the `hz` suffix or with a non-integer rate is rejected.
parse_tick_hz :: proc(text: string) -> (hz: int, ok: bool) {
	digits := strings.trim_suffix(text, "hz")
	if digits == text {
		return 0, false
	}
	return strconv.parse_int(digits)
}

// ep_skip_use consumes a `use module.{ a, b }` reference: it names source and
// carries no entrypoint identity (§14 §2), so it is accepted and dropped. The
// reference runs to its closing brace; a `use` with no brace group (a bare
// `use module.Name`) ends at the next top-level keyword, so the skip stops at
// the first `entrypoint`/`use` ident after the path.
ep_skip_use :: proc(p: ^Ep_Parser) -> Entrypoint_Error {
	ep_expect(p, .Ident) or_return // `use`
	for !ep_at_end(p) {
		kind := ep_peek(p).kind
		if kind == .R_Brace {
			p.pos += 1
			return .None
		}
		// A bare `use module.Name` (no brace group) ends at the top-level
		// keyword that opens the next construct.
		if kind == .Ident && ep_is_top_keyword(ep_peek(p).text) && ep_seen_path(p) {
			return .None
		}
		p.pos += 1
	}
	return .None
}

// ep_is_top_keyword reports whether an ident opens a top-level construct — the
// stop tokens a brace-less `use` reference ends before.
ep_is_top_keyword :: proc(text: string) -> bool {
	return text == "entrypoint" || text == "use"
}

// ep_seen_path reports whether the `use` skip has advanced past its opening
// `use` keyword — so the first ident after `use` (the module path) is not
// mistaken for the next top-level keyword.
ep_seen_path :: proc(p: ^Ep_Parser) -> bool {
	return p.pos > 0 && p.tokens[p.pos - 1].kind != .Ident
}

// ───────────────────────────────────────────────────────────────────────────
// Entrypoint config lexer/parser — a focused tokenizer for the §14 entrypoints
// grammar. project.fcfg's lexer is not reused: its values are string literals,
// while an entrypoint's values are bare tokens including the digit-leading
// `60hz` tick rate that the project lexer would split.
// ───────────────────────────────────────────────────────────────────────────

Ep_Token_Kind :: enum {
	Invalid,
	Ident, // a module/pipeline/bindings name, a key, or a `Nhz` tick rate
	Eq,
	Dot,
	Comma,
	L_Brace,
	R_Brace,
}

Ep_Token :: struct {
	kind: Ep_Token_Kind,
	text: string,
}

Ep_Parser :: struct {
	tokens: []Ep_Token,
	pos:    int,
}

ep_at_end :: proc(p: ^Ep_Parser) -> bool {
	return p.pos >= len(p.tokens)
}

ep_peek :: proc(p: ^Ep_Parser) -> Ep_Token {
	if ep_at_end(p) {
		return Ep_Token{kind = .Invalid}
	}
	return p.tokens[p.pos]
}

ep_expect :: proc(p: ^Ep_Parser, kind: Ep_Token_Kind) -> (tok: Ep_Token, err: Entrypoint_Error) {
	tok = ep_peek(p)
	if tok.kind != kind {
		return Ep_Token{}, .Malformed
	}
	p.pos += 1
	return tok, .None
}

// lex_entrypoint tokenizes the entrypoints.fcfg surface. It is total: an
// unrecognized glyph is an Invalid token the parser rejects. A token run that
// starts with a letter, digit, or underscore is one Ident (so `60hz`, `Pong`,
// and `bindings` each lex as a single token); whitespace and `::`-free dotted
// paths split on `.`/`,`/braces/`=`.
lex_entrypoint :: proc(content: string) -> []Ep_Token {
	tokens := make([dynamic]Ep_Token, 0, 16, context.temp_allocator)
	i := 0
	for i < len(content) {
		ch := content[i]
		switch {
		case ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n':
			i += 1
		case is_ep_token_char(ch):
			start := i
			for i < len(content) && is_ep_token_char(content[i]) {
				i += 1
			}
			append(&tokens, Ep_Token{kind = .Ident, text = content[start:i]})
		case:
			append(&tokens, ep_scan_punct(ch))
			i += 1
		}
	}
	return tokens[:]
}

// is_ep_token_char reports whether a byte continues a bare token — a letter,
// digit, or underscore. The digit case is what lets `60hz` lex as one token
// rather than a number split from an `hz` ident.
is_ep_token_char :: proc(ch: u8) -> bool {
	return is_ident_char(ch)
}

// ep_scan_punct maps the entrypoints grammar's structural glyphs; every other
// single character is Invalid, the parser's reject signal.
ep_scan_punct :: proc(ch: u8) -> Ep_Token {
	switch ch {
	case '=':
		return Ep_Token{kind = .Eq, text = "="}
	case '.':
		return Ep_Token{kind = .Dot, text = "."}
	case ',':
		return Ep_Token{kind = .Comma, text = ","}
	case '{':
		return Ep_Token{kind = .L_Brace, text = "{"}
	case '}':
		return Ep_Token{kind = .R_Brace, text = "}"}
	}
	return Ep_Token{kind = .Invalid}
}
