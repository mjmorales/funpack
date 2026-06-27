package funpack

import "core:strings"

Theme_Error :: enum {
	None,
	Unknown_Token,
}

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

validate_theme_tokens :: proc(screen: Fui_Screen, theme: []string) -> Theme_Error {
	err, _ := validate_theme_tokens_detail(screen, theme)
	return err
}

validate_theme_tokens_detail :: proc(screen: Fui_Screen, theme: []string) -> (err: Theme_Error, unknown: string) {
	return fui_theme_check_nodes(screen.body, theme)
}

fui_theme_check_nodes :: proc(nodes: []Fui_Node, theme: []string) -> (err: Theme_Error, unknown: string) {
	for node in nodes {
		switch n in node {
		case ^Fui_Element:
			err, unknown = fui_theme_check_element(n, theme)
			if err != .None {
				return err, unknown
			}
		case ^Fui_Text:
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

fui_theme_check_class_string :: proc(class: string, theme: []string) -> (err: Theme_Error, unknown: string) {
	tokens := strings.fields(class, context.temp_allocator)
	for token in tokens {
		if !fui_theme_known(token, theme) {
			return .Unknown_Token, token
		}
	}
	return .None, ""
}

fui_theme_known :: proc(token: string, theme: []string) -> bool {
	for known in theme {
		if known == token {
			return true
		}
	}
	return false
}
