package funpack

import "core:strings"

FUI_SCREENS_FILE_DOC :: "Generated navigation seam: the set of screens and the app message union over them. Generated from the .fui files — adding a screen extends these enums."

FUI_SCREENS_SCREEN_DOC :: "Every screen in the app. Generated from the set of .fui files; navigation is just setting this value in state, so the route table cannot drift from the screens that exist."

FUI_SCREENS_APPMSG_DOC :: "The app message union: each screen's messages, tagged by screen. The mount lifts a child screen's Msg into this with View.map; the update unwraps and delegates. Adding a screen extends this enum, so the update's match stops compiling until the new screen is handled."

emit_screens_seam :: proc(screens: []Fui_Screen, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	emit_seam_doc(&b, FUI_SCREENS_FILE_DOC)
	strings.write_string(&b, "\n")

	for screen in screens {
		fui_screens_emit_import(&b, screen)
	}

	strings.write_string(&b, "\n")
	emit_seam_doc(&b, FUI_SCREENS_SCREEN_DOC)
	fui_screens_emit_screen_enum(&b, screens)

	strings.write_string(&b, "\n")
	emit_seam_doc(&b, FUI_SCREENS_APPMSG_DOC)
	fui_screens_emit_appmsg_enum(&b, screens)

	return strings.to_string(b)
}

fui_screens_emit_import :: proc(b: ^strings.Builder, screen: Fui_Screen) {
	strings.write_string(b, "import ")
	strings.write_string(b, fui_screens_module_name(screen))
	strings.write_string(b, ".")
	strings.write_string(b, fui_screens_msg_type(screen))
	strings.write_string(b, "\n")
}

fui_screens_emit_screen_enum :: proc(b: ^strings.Builder, screens: []Fui_Screen) {
	strings.write_string(b, "enum Screen { ")
	for screen, i in screens {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, screen.name)
	}
	strings.write_string(b, " }\n")
}

fui_screens_emit_appmsg_enum :: proc(b: ^strings.Builder, screens: []Fui_Screen) {
	strings.write_string(b, "enum AppMsg { ")
	for screen, i in screens {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, screen.name)
		strings.write_string(b, "(")
		strings.write_string(b, fui_screens_msg_type(screen))
		strings.write_string(b, ")")
	}
	strings.write_string(b, " }\n")
}

fui_screens_module_name :: proc(screen: Fui_Screen) -> string {
	return strings.to_lower(screen.name, context.temp_allocator)
}

fui_screens_msg_type :: proc(screen: Fui_Screen) -> string {
	return strings.concatenate({screen.name, "Msg"}, context.temp_allocator)
}
