// Shared cursor helpers for the asset importers — the .atlas, .manifest, and
// .tiles surfaces. The three importers each drive a token cursor over the shared
// Cursor data structure (parser_cursor.odin) and reuse its error-free primitives
// (cursor_at_end / cursor_peek), so only the two helpers below — which the
// sub-language cursor cannot supply — live here.
//
// Why the importer expect is its own proc, not cursor_expect:
//   - It is PEEK-based: a wrong token is reported WITHOUT consuming it, where the
//     sub-language cursor_expect advances first. The importers abort on the first
//     verdict, so the position after a reject is unobservable, but preserving the
//     peek discipline keeps every importer's behavior byte-identical.
//   - It is parametric over the verdict enum ($E): .atlas/.tiles reject with
//     Importer_Error.Malformed_Source while .manifest rejects with
//     Asset_Manifest_Error.Malformed_Manifest, so one body serves both error
//     domains. A thin per-importer facade binds K and the concrete verdict.
package funpack

// import_expect consumes the next token only when its kind matches, returning the
// caller's `mismatch` verdict otherwise (success returns E{}, the zero value —
// .None for every importer verdict enum). See the file header for why this is
// peek-based and parametric over $E rather than reusing cursor_expect.
import_expect :: proc(c: ^Cursor($T, $K), kind: K, mismatch: $E) -> (tok: T, err: E) {
	tok = cursor_peek(c)
	if tok.kind != kind {
		return T{}, mismatch
	}
	c.pos += 1
	return tok, E{}
}

// import_skip_balanced_parens consumes a balanced `( … )` group whose interior is
// metadata the importer does not lift (a material constructor's argument list, a
// .tiles directive's arguments). A missing opener, an unbalanced group, or a
// lexer Invalid token inside is Malformed_Source. The mid-stream Invalid token is
// the kind enum's zero value (every importer Token_Kind opens on Invalid), so it
// is compared against the zero `invalid` rather than a passed-in kind.
import_skip_balanced_parens :: proc(c: ^Cursor($T, $K), lparen, rparen: K) -> Importer_Error {
	if cursor_peek_kind(c) != lparen {
		return .Malformed_Source
	}
	c.pos += 1
	depth := 1
	for depth > 0 {
		if cursor_at_end(c) {
			return .Malformed_Source
		}
		invalid: K
		#partial switch cursor_peek_kind(c) {
		case lparen:
			depth += 1
		case rparen:
			depth -= 1
		case invalid:
			return .Malformed_Source
		}
		c.pos += 1
	}
	return .None
}
