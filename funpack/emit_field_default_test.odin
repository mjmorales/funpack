// Unit fixtures pinning the §6 field-default token encoding (emit.odin
// field_default_token / encode_field_default). The defect this guards: a thing
// field with a COMPOSITE default (an enum variant `ai: Hunt = Hunt::Patrol`, a
// record `last_seen: Vec2 = Vec2{x: 0.0, y: 0.0}`) used to emit a bare `=` —
// encode_literal returned "" for a Variant_Expr/Record_Expr — so a Hunter
// spawned with `ai` empty and `think`'s exhaustive match over Hunt matched no
// arm and froze. These tests pin the exact one-token default for every form,
// hold the scalar (Int/Fixed/Bool/String) forms byte-identical to the original
// scalar-only encoding, and pin hunt's two composite defaults directly so the
// freeze-causing forms can never silently regress to a bare `=`.
package funpack

import "core:strings"
import "core:testing"

// default_field builds a defaulted Field_Decl over a default expression — the one
// input field_default_token reads (it never touches the field's type), so the
// fixtures supply only the default and the has_default flag.
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

// name_expr builds a bare Name reference — a field default written as a module
// const (`ground_y: Fixed = GROUND_Y`) parses to one of these. Only `.name` is read
// by the §6 default fold and encode, so the fixtures leave class/span zero.
name_expr :: proc(name: string) -> ^Name_Expr {
	node := new(Name_Expr, context.temp_allocator)
	node^ = Name_Expr{name = name}
	return node
}

// The scalar (Int/Fixed/Bool/String) field-default forms stay byte-identical to
// the original scalar-only encoding (docs/artifact-format.md §6, §2): pong's
// Scoreboard `Int = 0` pair and any Fixed/Bool/String scalar default must encode
// exactly as before, so the gameplay surface is untouched by the composite
// addition.
@(test)
test_field_default_scalar_forms_unchanged :: proc(t: ^testing.T) {
	// pong's Scoreboard.left/right: `Int = 0` → `=0`.
	testing.expect_value(t, field_default_token(default_field(int_lit(0))), "=0")
	testing.expect_value(t, field_default_token(default_field(int_lit(-7))), "=-7")
	// A Fixed default carries its raw Q32.32 bits (§2.3): 0.0 → 0, 4.0 → 4<<32.
	testing.expect_value(t, field_default_token(default_field(fixed_lit(0))), "=0")
	testing.expect_value(t, field_default_token(default_field(fixed_lit(4))), "=17179869184")
	// A bare-name `true`/`false` is a Bool default (§2.5) — snake's `grow = false`.
	false_node := new(Name_Expr, context.temp_allocator)
	false_node^ = Name_Expr{name = "false"}
	testing.expect_value(t, field_default_token(default_field(false_node)), "=false")
	// An undefaulted field is `-`.
	testing.expect_value(t, field_default_token(Field_Decl{name = "f", has_default = false}), "-")
}

// An enum-variant default emits its `Type::Case` token (docs/artifact-format.md
// §6, §2.6) — a single space-free token the runtime carries verbatim as the enum
// column value. This is the load-bearing fix for the Hunter freeze: `ai: Hunt =
// Hunt::Patrol` must emit `=Hunt::Patrol`, never a bare `=`, so the spawned
// Hunter's `ai` is `Hunt::Patrol` and `think`'s match selects the Patrol arm.
@(test)
test_field_default_enum_variant_token :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		field_default_token(default_field(variant_lit("Hunt", "Patrol"))),
		"=Hunt::Patrol",
	)
	// snake's `dir: Dir = Dir::Right` and `state: GameState = GameState::Playing`.
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

// A composite record default emits its single-token inline constructor
// `Type(field=enc,…)` (docs/artifact-format.md §6): parenthesized, comma-joined
// `field=ENCODED`, no interior spaces, each value a space-free nested token. This
// is the §6 single-token realization of "its constructor record inline" — hunt's
// `last_seen: Vec2 = Vec2{x: 0.0, y: 0.0}` and snake's `head: Cell = Cell{x: 10,
// y: 10}`.
@(test)
test_field_default_record_constructor_token :: proc(t: ^testing.T) {
	// Vec2{x: 0.0, y: 0.0} → Vec2(x=0,y=0) — both Fixed components are 0.0 → raw 0.
	vec2 := record_lit("Vec2", {{name = "x", value = fixed_lit(0)}, {name = "y", value = fixed_lit(0)}})
	testing.expect_value(t, field_default_token(default_field(vec2)), "=Vec2(x=0,y=0)")
	// Cell{x: 10, y: 10} → Cell(x=10,y=10) — Int components stay decimal.
	cell := record_lit("Cell", {{name = "x", value = int_lit(10)}, {name = "y", value = int_lit(10)}})
	testing.expect_value(t, field_default_token(default_field(cell)), "=Cell(x=10,y=10)")
}

// An empty-list default emits `=[]` (docs/artifact-format.md §6) — the only list
// literal a default admits (a defaulted list seeds empty, e.g. snake's `body:
// [Cell] = []`).
@(test)
test_field_default_empty_list_token :: proc(t: ^testing.T) {
	testing.expect_value(t, field_default_token(default_field(empty_list_lit())), "=[]")
}

// hunt's two composite Hunter defaults pinned together — the exact tokens the
// regression produced as bare `=`. `ai: Hunt = Hunt::Patrol` → `=Hunt::Patrol`
// (the freeze fix) and `last_seen: Vec2 = Vec2{x: 0.0, y: 0.0}` → `=Vec2(x=0,y=0)`
// (the composite blackboard seed). These are the precise tokens hunt's emitted
// artifact must carry for the AI to leave its initial Patrol state.
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

// A field default written as a module const (`ground_y: Fixed = GROUND_Y`) must fold
// to the constant's value before the §6 DEFAULT token is encoded. encode_literal has
// no const table and returns "" for a Name_Expr, so the unfolded default emits a bare
// `=` the runtime's decode_default drops — the column then never reaches the spawned
// row (a render-only singleton whose only consumer is its render reads the absent
// field and emits nothing). fold_field_default resolves the const against the
// module's `let` table so the value survives.
@(test)
test_field_default_named_const_folds :: proc(t: ^testing.T) {
	ast := Ast{lets = []Let_Decl_Node{{name = "GROUND_Y", value = fixed_lit(110)}}}
	folded := fold_field_default(name_expr("GROUND_Y"), ast)
	want := strings.concatenate({"=", encode_fixed(to_fixed(110), context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, field_default_token(default_field(folded)), want)
	// Unresolved (no const table), the Name still degrades to the bare `=` the bug
	// produced — proving the fold, not encode_literal, is what carries the value.
	testing.expect_value(t, field_default_token(default_field(name_expr("GROUND_Y"))), "=")
}

// The fold must be WIRED into the production emit path, not just available: emit_things
// folds each thing's §6 defaults against the module's lets, so a singleton with a
// const default lands a populated `field` line instead of the empty `=` the unfolded
// default dropped. This pins the wiring the unit fold above cannot — removing the fold
// from emit_fields re-opens the bug here.
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
	// The bug form — an empty default token — must never appear.
	testing.expect(t, !strings.contains(out, "field ground_y Fixed =\n"))
}
