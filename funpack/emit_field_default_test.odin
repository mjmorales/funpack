package funpack

import "core:strings"
import "core:testing"

default_field :: proc(default: Expr) -> Field_Decl {
	return Field_Decl{name = "f", default = default, has_default = true}
}

variant_lit :: proc(type_name: string, variant: string) -> ^Variant_Expr {
	node := new(Variant_Expr, context.temp_allocator)
	node^ = Variant_Expr{type_name = type_name, variant = variant}
	return node
}

fixed_lit :: proc(n: i64) -> ^Fixed_Lit_Expr {
	node := new(Fixed_Lit_Expr, context.temp_allocator)
	node^ = Fixed_Lit_Expr{bits = to_fixed(n)}
	return node
}

int_lit :: proc(n: i64) -> ^Int_Lit_Expr {
	node := new(Int_Lit_Expr, context.temp_allocator)
	node^ = Int_Lit_Expr{value = n}
	return node
}

record_lit :: proc(type_name: string, fields: []Record_Field) -> ^Record_Expr {
	node := new(Record_Expr, context.temp_allocator)
	node^ = Record_Expr{type_name = type_name, fields = fields}
	return node
}

empty_list_lit :: proc() -> ^List_Expr {
	node := new(List_Expr, context.temp_allocator)
	node^ = List_Expr{elements = {}}
	return node
}

name_expr :: proc(name: string) -> ^Name_Expr {
	node := new(Name_Expr, context.temp_allocator)
	node^ = Name_Expr{name = name}
	return node
}

@(test)
test_field_default_scalar_forms_unchanged :: proc(t: ^testing.T) {
	testing.expect_value(t, field_default_token(default_field(int_lit(0))), "=0")
	testing.expect_value(t, field_default_token(default_field(int_lit(-7))), "=-7")
	testing.expect_value(t, field_default_token(default_field(fixed_lit(0))), "=0")
	testing.expect_value(t, field_default_token(default_field(fixed_lit(4))), "=17179869184")
	false_node := new(Name_Expr, context.temp_allocator)
	false_node^ = Name_Expr{name = "false"}
	testing.expect_value(t, field_default_token(default_field(false_node)), "=false")
	testing.expect_value(t, field_default_token(Field_Decl{name = "f", has_default = false}), "-")
}

@(test)
test_field_default_enum_variant_token :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		field_default_token(default_field(variant_lit("Hunt", "Patrol"))),
		"=Hunt::Patrol",
	)
	testing.expect_value(
		t,
		field_default_token(default_field(variant_lit("Dir", "Right"))),
		"=Dir::Right",
	)
	testing.expect_value(
		t,
		field_default_token(default_field(variant_lit("GameState", "Playing"))),
		"=GameState::Playing",
	)
}

@(test)
test_field_default_record_constructor_token :: proc(t: ^testing.T) {
	vec2 := record_lit("Vec2", {{name = "x", value = fixed_lit(0)}, {name = "y", value = fixed_lit(0)}})
	testing.expect_value(t, field_default_token(default_field(vec2)), "=Vec2(x=0,y=0)")
	cell := record_lit("Cell", {{name = "x", value = int_lit(10)}, {name = "y", value = int_lit(10)}})
	testing.expect_value(t, field_default_token(default_field(cell)), "=Cell(x=10,y=10)")
}

@(test)
test_field_default_empty_list_token :: proc(t: ^testing.T) {
	testing.expect_value(t, field_default_token(default_field(empty_list_lit())), "=[]")
}

@(test)
test_field_default_hunt_composite_pair :: proc(t: ^testing.T) {
	ai := variant_lit("Hunt", "Patrol")
	last_seen := record_lit(
		"Vec2",
		{{name = "x", value = fixed_lit(0)}, {name = "y", value = fixed_lit(0)}},
	)
	testing.expect_value(t, field_default_token(default_field(ai)), "=Hunt::Patrol")
	testing.expect_value(t, field_default_token(default_field(last_seen)), "=Vec2(x=0,y=0)")
}

@(test)
test_field_default_named_const_folds :: proc(t: ^testing.T) {
	ast := Ast{lets = []Let_Decl_Node{{name = "GROUND_Y", value = fixed_lit(110)}}}
	folded := fold_field_default(name_expr("GROUND_Y"), ast)
	want := strings.concatenate({"=", encode_fixed(to_fixed(110), context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, field_default_token(default_field(folded)), want)
	testing.expect_value(t, field_default_token(default_field(name_expr("GROUND_Y"))), "=")
}

@(test)
test_emit_things_folds_named_const_default :: proc(t: ^testing.T) {
	ast := Ast{
		lets   = []Let_Decl_Node{{name = "GROUND_Y", value = fixed_lit(110)}},
		things = []Thing_Node{
			{
				name         = "Stage",
				is_singleton = true,
				fields       = []Field_Decl{
					{
						name        = "ground_y",
						type        = Type_Ref{name = "Fixed"},
						default     = name_expr("GROUND_Y"),
						has_default = true,
					},
				},
			},
		},
	}
	b := strings.builder_make(context.temp_allocator)
	emit_things(&b, ast, nil)
	out := strings.to_string(b)

	bits := encode_fixed(to_fixed(110), context.temp_allocator)
	want := strings.concatenate({"field ground_y Fixed =", bits, "\n"}, context.temp_allocator)
	testing.expect(t, strings.contains(out, want))
	testing.expect(t, !strings.contains(out, "field ground_y Fixed =\n"))
}
