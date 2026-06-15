// The §21 §3 SET-LEVEL routing-seam emitter: the pure set-of-screens →
// screens.gen.fun source-TEXT serializer. Distinct from the PER-SCREEN seam
// (each screen's HudView/HudMsg/builder, owned by the sibling per-screen
// emitter), this file emits the ONE whole-project seam over the SET of .fui
// files — the `Screen` enum (one variant per screen) and the `AppMsg` tagged
// union (one `Screen(ScreenMsg)` arm per screen), plus the import header pulling
// each screen module's Msg type. The byte target is the committed exemplar
// examples/hud/gen/screens.gen.fun.
//
// "The screens ARE the route table" (§21 §3): there is no route config — the SET
// of templates generates both enums, so adding a .fui extends `Screen` AND
// `AppMsg`, and the mount/update `match` stop compiling until the new screen is
// handled. The emitter is therefore a pure function of the screen SET in file-set
// order: feed it the screens read_project collected (sorted authoring-path order)
// and it renders the committed bytes.
//
// DISTINCT FROM gen_emit.odin's emit_gen_fun and asset_seam_emit.odin's
// emit_assets_gen_fun: those render the `data`/`extern fn` Seam shape and the
// `let` handle-constant shape respectively. The routing seam is a THIRD canonical
// byte shape — bare single-member `import <module>.<Member>` lines (no `{…}`
// brace list) and `enum` declarations (which the Seam_Decl data/extern union does
// not carry) — so it is its own emitter, reusing only the shared canonical-text
// discipline (the `@doc("…")` line form via emit_seam_doc, deterministic
// slice-order walks, a single trailing newline), not the Seam_Decl union.
//
// NAMESPACE: every proc here is `fui_screens_`-prefixed and the per-screen
// emission helpers (a single screen's view/msg/builder decls) live in the sibling
// per-screen emitter — this file declares NONE of those, to keep the two
// set-level vs per-screen seam concerns in distinct files without symbol
// collision.
//
// PURITY (spec §09, §29): emission is a pure function of the screen slice. Every
// layout decision is mechanical — the import block, the enum bodies, and the
// blank-line separators are fixed, and every list walks in slice order — so the
// emitter reads no clock, no path, no host bytes, and two emissions of the same
// screen set are byte-identical.
package funpack

import "core:strings"

// FUI_SCREENS_FILE_DOC is the file-leading @doc of screens.gen.fun: fixed
// boilerplate naming the seam (the set of screens and the app message union) and
// the add-a-screen-extends-the-enums invariant. Verbatim from the committed
// exemplar's line 1, em-dash included.
FUI_SCREENS_FILE_DOC :: "Generated navigation seam: the set of screens and the app message union over them. Generated from the .fui files — adding a screen extends these enums."

// FUI_SCREENS_SCREEN_DOC is the @doc heading the `Screen` enum: the route-table
// invariant — navigation is just setting this value, so the routes cannot drift
// from the screens that exist (§21 §3). Verbatim from the committed exemplar.
FUI_SCREENS_SCREEN_DOC :: "Every screen in the app. Generated from the set of .fui files; navigation is just setting this value in state, so the route table cannot drift from the screens that exist."

// FUI_SCREENS_APPMSG_DOC is the @doc heading the `AppMsg` tagged union: the mount
// lifts a child Msg in with View.map and the update unwraps and delegates, so
// adding a screen makes the update's match non-exhaustive until handled (§21 §3).
// Verbatim from the committed exemplar.
FUI_SCREENS_APPMSG_DOC :: "The app message union: each screen's messages, tagged by screen. The mount lifts a child screen's Msg into this with View.map; the update unwraps and delegates. Adding a screen extends this enum, so the update's match stops compiling until the new screen is handled."

// emit_screens_seam renders the SET of screens to canonical screens.gen.fun
// source bytes, byte-matching the committed exemplar. `screens` is the screen set
// in FILE-SET ORDER (the sorted authoring-path order read_project collects) — the
// order is the byte contract, so `Screen`/`AppMsg` variants come out in the same
// order the templates were collected. Layout mirrors the exemplar exactly: the
// file-leading @doc, a blank line, the per-screen `import <module>.<Screen>Msg`
// block, a blank line, the @doc-headed `enum Screen { … }`, a blank line, and the
// @doc-headed `enum AppMsg { … }` — so the file ends in exactly one newline. The
// returned string is allocated in `allocator`.
emit_screens_seam :: proc(screens: []Fui_Screen, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	// File-leading @doc, then a blank line before the import block (the routing
	// seam offsets its file doc from the imports, like the assets seam).
	emit_seam_doc(&b, FUI_SCREENS_FILE_DOC)
	strings.write_string(&b, "\n")

	// The import block: one `import <module>.<Screen>Msg` line per screen, in
	// file-set order. Each line is a bare single-member import (no `{…}` brace
	// list) — the seam pulls exactly the screen module's Msg type.
	for screen in screens {
		fui_screens_emit_import(&b, screen)
	}

	// A blank line, then the @doc-headed `enum Screen { … }`.
	strings.write_string(&b, "\n")
	emit_seam_doc(&b, FUI_SCREENS_SCREEN_DOC)
	fui_screens_emit_screen_enum(&b, screens)

	// A blank line, then the @doc-headed `enum AppMsg { … }`.
	strings.write_string(&b, "\n")
	emit_seam_doc(&b, FUI_SCREENS_APPMSG_DOC)
	fui_screens_emit_appmsg_enum(&b, screens)

	return strings.to_string(b)
}

// fui_screens_emit_import writes one `import <module>.<Screen>Msg` line: the
// screen's lowercase module name (the .fui file stem, §15) dot the screen's Msg
// type. `Hud` -> `import hud.HudMsg`. A bare single-member import — no brace list
// — matching the committed exemplar's import block.
fui_screens_emit_import :: proc(b: ^strings.Builder, screen: Fui_Screen) {
	strings.write_string(b, "import ")
	strings.write_string(b, fui_screens_module_name(screen))
	strings.write_string(b, ".")
	strings.write_string(b, fui_screens_msg_type(screen))
	strings.write_string(b, "\n")
}

// fui_screens_emit_screen_enum writes `enum Screen { V0, V1, … }` on one line —
// one variant per screen (the screen's own name) in file-set order, the variants
// comma-and-space separated, a single space inside each brace. Adding a screen
// adds a variant, so the route table cannot drift from the templates (§21 §3).
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

// fui_screens_emit_appmsg_enum writes `enum AppMsg { Hud(HudMsg), … }` on one
// line — one `Screen(ScreenMsg)` tagged arm per screen in file-set order, each
// tagging that screen's Msg type. Adding a screen adds an arm, so the update's
// match goes non-exhaustive until the new screen is handled (§21 §3).
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

// fui_screens_module_name derives a screen's seam module name — the lowercase of
// the screen name, which is the .fui file stem the §15 module rule names the
// module after (`Hud` -> `hud`, `Settings` -> `settings`). The committed §21
// screen names are single words, so a plain lowercase is the file stem; a
// multi-word screen name would be pinned by its file stem at the source, not
// synthesized here.
fui_screens_module_name :: proc(screen: Fui_Screen) -> string {
	return strings.to_lower(screen.name, context.temp_allocator)
}

// fui_screens_msg_type derives a screen's Msg type name — the screen name with a
// `Msg` suffix (`Hud` -> `HudMsg`), matching the per-screen seam's generated
// message enum so the import resolves the type the per-screen seam declares.
fui_screens_msg_type :: proc(screen: Fui_Screen) -> string {
	return strings.concatenate({screen.name, "Msg"}, context.temp_allocator)
}
