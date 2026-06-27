package funpack

import "core:testing"

@(test)
test_fui_parses_screen_and_nested_block :: proc(t: ^testing.T) {
	src := "screen Hud {\n  row class=\"top-bar\" {\n    text { \"Score\" }\n  }\n}\n"
	screen, err := parse_fui(src)
	testing.expect_value(t, err, Fui_Parse_Error.None)
	testing.expect_value(t, screen.name, "Hud")
	testing.expect_value(t, len(screen.body), 1)
	row, is_el := screen.body[0].(^Fui_Element)
	testing.expect(t, is_el, "top node is a row element")
	testing.expect_value(t, row.widget, Fui_Widget_Kind.Row)
	testing.expect_value(t, row.has_block, true)
	testing.expect_value(t, len(row.attrs), 1)
	testing.expect_value(t, row.attrs[0].kind, Fui_Attr_Kind.Plain)
	testing.expect_value(t, row.attrs[0].name, "class")
	lit, is_lit := row.attrs[0].value.(Fui_Literal)
	testing.expect(t, is_lit, "class value is a literal")
	testing.expect_value(t, lit.kind, Fui_Literal_Kind.String)
	testing.expect_value(t, lit.text, "top-bar")
	testing.expect_value(t, len(row.children), 1)
	text, is_text := row.children[0].(^Fui_Element)
	testing.expect(t, is_text, "child is a text element")
	testing.expect_value(t, text.widget, Fui_Widget_Kind.Text)
}

@(test)
test_fui_parses_directive_triad :: proc(t: ^testing.T) {
	src := "screen S {\n" +
		"  button @click=SetVolume(p.value) { \"go\" }\n" +
		"  text :class=tone { \"x\" }\n" +
		"  slider bind:value=volume\n" +
		"}\n"
	screen, err := parse_fui(src)
	testing.expect_value(t, err, Fui_Parse_Error.None)
	testing.expect_value(t, len(screen.body), 3)

	btn := screen.body[0].(^Fui_Element)
	testing.expect_value(t, len(btn.attrs), 1)
	testing.expect_value(t, btn.attrs[0].kind, Fui_Attr_Kind.Event)
	testing.expect_value(t, btn.attrs[0].name, "click")
	ref, is_ref := btn.attrs[0].value.(Fui_Msg_Ref)
	testing.expect(t, is_ref, "event value is a Msg ref")
	testing.expect_value(t, ref.variant, "SetVolume")
	testing.expect_value(t, ref.has_payload, true)
	testing.expect_value(t, len(ref.payload.segments), 2)
	testing.expect_value(t, ref.payload.segments[0], "p")
	testing.expect_value(t, ref.payload.segments[1], "value")

	txt := screen.body[1].(^Fui_Element)
	testing.expect_value(t, txt.attrs[0].kind, Fui_Attr_Kind.Bind_In)
	testing.expect_value(t, txt.attrs[0].name, "class")
	bind_path := txt.attrs[0].value.(Fui_Path)
	testing.expect_value(t, bind_path.segments[0], "tone")

	sld := screen.body[2].(^Fui_Element)
	testing.expect_value(t, sld.widget, Fui_Widget_Kind.Slider)
	testing.expect_value(t, sld.has_block, false)
	testing.expect_value(t, sld.attrs[0].kind, Fui_Attr_Kind.Two_Way)
	testing.expect_value(t, sld.attrs[0].name, "value")
	two_path := sld.attrs[0].value.(Fui_Path)
	testing.expect_value(t, two_path.segments[0], "volume")
}

@(test)
test_fui_parses_text_interpolation_holes :: proc(t: ^testing.T) {
	src := "screen S {\n  text { \"Score: {score}\" }\n  text { \"Settings\" }\n}\n"
	screen, err := parse_fui(src)
	testing.expect_value(t, err, Fui_Parse_Error.None)
	first := screen.body[0].(^Fui_Element)
	tn, is_tn := first.children[0].(^Fui_Text)
	testing.expect(t, is_tn, "child is a text node")
	testing.expect_value(t, tn.text, "Score: {score}")
	testing.expect_value(t, len(tn.holes), 1)
	testing.expect_value(t, tn.holes[0].segments[0], "score")
	second := screen.body[1].(^Fui_Element)
	tn2 := second.children[0].(^Fui_Text)
	testing.expect_value(t, len(tn2.holes), 0)
	testing.expect_value(t, tn2.text, "Settings")
}

@(test)
test_fui_parses_if_block :: proc(t: ^testing.T) {
	src := "screen S {\n  if game_over {\n    text { \"Game Over\" }\n  }\n}\n"
	screen, err := parse_fui(src)
	testing.expect_value(t, err, Fui_Parse_Error.None)
	testing.expect_value(t, len(screen.body), 1)
	n, is_if := screen.body[0].(^Fui_If)
	testing.expect(t, is_if, "top node is an if node")
	testing.expect_value(t, len(n.cond.segments), 1)
	testing.expect_value(t, n.cond.segments[0], "game_over")
	testing.expect_value(t, len(n.children), 1)
}

@(test)
test_fui_parses_for_with_row_type_and_key :: proc(t: ^testing.T) {
	src := "screen S {\n" +
		"  for opt in difficulties : { id: Ref[Difficulty], label: String } key=opt.id {\n" +
		"    button @click=Pick(opt.id) { \"{opt.label}\" }\n" +
		"  }\n" +
		"}\n"
	screen, err := parse_fui(src)
	testing.expect_value(t, err, Fui_Parse_Error.None)
	testing.expect_value(t, len(screen.body), 1)
	n, is_for := screen.body[0].(^Fui_For)
	testing.expect(t, is_for, "top node is a for node")
	testing.expect_value(t, n.var, "opt")
	testing.expect_value(t, n.list.segments[0], "difficulties")
	testing.expect_value(t, n.has_row_type, true)
	testing.expect_value(t, len(n.row_type), 2)
	testing.expect_value(t, n.row_type[0].name, "id")
	testing.expect_value(t, n.row_type[0].type, "Ref[Difficulty]")
	testing.expect_value(t, n.row_type[1].name, "label")
	testing.expect_value(t, n.row_type[1].type, "String")
	testing.expect_value(t, n.has_key, true)
	testing.expect_value(t, n.key.segments[0], "opt")
	testing.expect_value(t, n.key.segments[1], "id")
	testing.expect_value(t, len(n.children), 1)
}

@(test)
test_fui_parses_nullary_and_int_attr :: proc(t: ^testing.T) {
	src := "screen S {\n  slider min=0 max=100 bind:value=v\n  button @click=Back { \"Back\" }\n}\n"
	screen, err := parse_fui(src)
	testing.expect_value(t, err, Fui_Parse_Error.None)
	sld := screen.body[0].(^Fui_Element)
	testing.expect_value(t, len(sld.attrs), 3)
	min_lit := sld.attrs[0].value.(Fui_Literal)
	testing.expect_value(t, min_lit.kind, Fui_Literal_Kind.Int)
	testing.expect_value(t, min_lit.int_value, 0)
	max_lit := sld.attrs[1].value.(Fui_Literal)
	testing.expect_value(t, max_lit.int_value, 100)
	btn := screen.body[1].(^Fui_Element)
	ref := btn.attrs[0].value.(Fui_Msg_Ref)
	testing.expect_value(t, ref.variant, "Back")
	testing.expect_value(t, ref.has_payload, false)
}

@(test)
test_fui_rejects_malformed :: proc(t: ^testing.T) {
	lower_name := "screen hud {\n  text { \"x\" }\n}\n"
	_, err_name := parse_fui(lower_name)
	testing.expect_value(t, err_name, Fui_Parse_Error.Wrong_Case)

	unterminated := "screen Hud {\n  text { \"x\" }\n"
	_, err_block := parse_fui(unterminated)
	testing.expect_value(t, err_block, Fui_Parse_Error.Unexpected_End)

	bad_hole := "screen Hud {\n  text { \"Score: {score\" }\n}\n"
	_, err_hole := parse_fui(bad_hole)
	testing.expect_value(t, err_hole, Fui_Parse_Error.Unexpected_End)
}
