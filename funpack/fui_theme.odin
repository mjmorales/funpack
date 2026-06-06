// The §21 §1 THEME-TOKEN gate: every `class="…"` style token is validated against
// a closed, project theme vocabulary, and an unknown token is a COMPILE ERROR
// with a fix-it — "checked like a @gtag" (§21 §1). Style is space-separated tokens
// from the project theme, a closed semantic-role vocabulary (`bg-panel`,
// `text-2xl`, `gap-4`, `rounded-md`; never raw values); a token outside that set
// resolves to nothing and is rejected, exactly the way a @gtag name not in its
// registry is rejected.
//
// WHAT IS CHECKED: only the LITERAL token lists on `class="…"` plain attributes.
// A `:class=tone` bind-in is a typed String read feeding the attribute at runtime
// (§21 §1 directive table) — its value is not a compile-time token list, so it is
// not theme-checked here (the contract inference owns it). Every space-separated
// word of every `class="…"` literal, on every widget at every depth, is a token
// the closed vocabulary must contain.
//
// THE VOCABULARY: the project theme is `data`, swappable behind unchanged
// templates (§21 §1) — so the closed token set is a parameter, not a hard-coded
// constant. The gate takes the vocabulary as `theme: []string`; the committed §21
// example theme (FUI_HUD_THEME_TOKENS) is the set the committed templates check
// against. A different project ships a different theme `data`; the gate is the
// same closed-membership check over whichever vocabulary it is handed.
//
// PURITY (spec §09, §29): the check is a pure function of (screen, theme). It
// walks the parsed AST and the token slice — no clock, no path, no host bytes — so
// the same screen and theme always yield the same verdict.
package funpack

import "core:strings"

// Theme_Error is closed with one arm per outcome of validating a screen's style
// tokens against the project theme. None is the only passing arm (every
// `class="…"` token is in the vocabulary); Unknown_Token is the §21 §1 compile
// error — a token outside the closed theme set, checked like a @gtag. A new
// outcome is a deliberate addition here.
Theme_Error :: enum {
	// None: every style token on every `class="…"` attribute is in the theme
	// vocabulary — the screen's styling is well-formed.
	None,
	// Unknown_Token: a `class="…"` carries a token the closed theme vocabulary
	// does not contain — a compile error (§21 §1). The offending token is reported
	// alongside (validate_theme_tokens_detail) so the fix-it can name it.
	Unknown_Token,
}

// FUI_HUD_THEME_TOKENS is the closed §21 example theme vocabulary — the semantic
// style roles the committed examples/hud templates use, plus the spec-named role
// `rounded-md` (§21 §1). Every `class="…"` token in the three committed .fui
// files appears here, so the committed set validates clean; a token outside this
// set (an author's typo or a raw value) is an Unknown_Token. The order is
// lexicographic for legibility — membership, not order, is the contract — and the
// set is the swappable theme `data` the §21 spec describes, frozen here as the
// committed project theme.
FUI_HUD_THEME_TOKENS :: []string {
	"bg-panel",
	"bg-scrim",
	"btn",
	"btn-primary",
	"center",
	"font-bold",
	"gap-2",
	"gap-3",
	"gap-4",
	"ml-auto",
	"overlay",
	"p-3",
	"p-4",
	"panel",
	"rounded-md",
	"text-2xl",
	"top-bar",
}

// validate_theme_tokens walks a parsed screen and validates every `class="…"`
// style token against the closed project theme vocabulary (§21 §1). It returns
// None when every token is in `theme`, and Unknown_Token on the FIRST token
// outside it — the closed-membership gate the style layer rests on, mirroring the
// @gtag closed-registry check. The signature the set-level bake calls; the
// offending-token detail (for the fix-it diagnostic) is the sibling
// validate_theme_tokens_detail.
validate_theme_tokens :: proc(screen: Fui_Screen, theme: []string) -> Theme_Error {
	err, _ := validate_theme_tokens_detail(screen, theme)
	return err
}

// validate_theme_tokens_detail is validate_theme_tokens with the offending token
// surfaced: on Unknown_Token it returns the exact unknown token so the caller can
// emit a precise compile error with a fix-it naming the bad token (§21 §1 "a
// compile error with a fix-it"). On None the token is empty. The detail is split
// out so the closed-enum signature the bake consumes stays clean while the
// diagnostic still has the offending token.
validate_theme_tokens_detail :: proc(screen: Fui_Screen, theme: []string) -> (err: Theme_Error, unknown: string) {
	return fui_theme_check_nodes(screen.body, theme)
}

// fui_theme_check_nodes walks a node sequence, checking each node's class tokens
// (for an Element) and recursing into its children (Element/If/For blocks). The
// FIRST unknown token short-circuits the whole walk with Unknown_Token — one bad
// token fails the screen, the same all-or-nothing the @gtag gate uses. Text nodes
// carry no class attribute, so they are skipped.
fui_theme_check_nodes :: proc(nodes: []Fui_Node, theme: []string) -> (err: Theme_Error, unknown: string) {
	for node in nodes {
		switch n in node {
		case ^Fui_Element:
			err, unknown = fui_theme_check_element(n, theme)
			if err != .None {
				return err, unknown
			}
		case ^Fui_Text:
			// A text node has no style tokens.
		case ^Fui_If:
			err, unknown = fui_theme_check_nodes(n.children, theme)
			if err != .None {
				return err, unknown
			}
		case ^Fui_For:
			err, unknown = fui_theme_check_nodes(n.children, theme)
			if err != .None {
				return err, unknown
			}
		}
	}
	return .None, ""
}

// fui_theme_check_element validates one element's `class="…"` plain attributes
// then recurses into its child block. Only a Plain attr named `class` whose value
// is a String literal is a token list; a `:class=tone` bind-in (a path read) is
// not checked here. Each space-separated word of the class string must be in the
// theme vocabulary.
fui_theme_check_element :: proc(el: ^Fui_Element, theme: []string) -> (err: Theme_Error, unknown: string) {
	for attr in el.attrs {
		if attr.kind != .Plain || attr.name != "class" {
			continue
		}
		lit, is_lit := attr.value.(Fui_Literal)
		if !is_lit || lit.kind != .String {
			continue
		}
		err, unknown = fui_theme_check_class_string(lit.text, theme)
		if err != .None {
			return err, unknown
		}
	}
	return fui_theme_check_nodes(el.children, theme)
}

// fui_theme_check_class_string validates one `class="…"` literal: it splits the
// string on whitespace and checks each non-empty token against the theme
// vocabulary, returning Unknown_Token on the first token not in `theme`. The split
// matches §21 §1's "space-separated tokens"; an empty class string (no tokens) is
// trivially valid.
fui_theme_check_class_string :: proc(class: string, theme: []string) -> (err: Theme_Error, unknown: string) {
	tokens := strings.fields(class, context.temp_allocator)
	for token in tokens {
		if !fui_theme_known(token, theme) {
			return .Unknown_Token, token
		}
	}
	return .None, ""
}

// fui_theme_known reports whether a token is in the closed theme vocabulary — the
// closed-membership probe the gate rests on. A linear scan: the theme is a small
// closed set and a sorted-then-bsearch would not change the byte-for-byte verdict,
// only the constant factor.
fui_theme_known :: proc(token: string, theme: []string) -> bool {
	for known in theme {
		if known == token {
			return true
		}
	}
	return false
}
