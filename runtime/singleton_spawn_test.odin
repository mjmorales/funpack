// Singleton tick-0 engine-spawn acceptance (spec §06 §2, §08 §3): a singleton is
// a guaranteed-single-row thing the ENGINE spawns from its defaulted-field schema
// BEFORE tick 0 — never by setup, accessed by type, never iterated. These tests
// prove the engine singleton-spawn pass on a HAND-BUILT Program (runtime Lore #8:
// the yard.artifact carrying real singletons is emitted by the sibling funpack
// epic, so the runtime arm is proven on a hand-written node-forest before that
// artifact lands), asserting:
//
//   - exactly ONE row per `Thing_Decl.singleton == true` thing exists at tick 0,
//     each column equal to its decoded Field_Decl default (the yard surface's
//     Scoreboard.delivered==0, Camera.at==Vec2{80,60} & zoom==1.0, Menu.dirty==
//     false & status==Option::None, plus the composite Settings default);
//   - the spawn is DETERMINISTIC — two runs of the pass over the same Program
//     produce byte-identical singleton rows (same Ids, same columns): the pass is
//     a pure function of the schema defaults, no RNG, no input.
//
// The pass runs through run_startup (the pre-tick-0 population step), so these
// also prove a singleton is queryable at tick 0 via the by-type read (singleton_row
// / view_of_type), exactly as a behavior keyed on a singleton sees it.
package funpack_runtime

import "core:fmt"
import "core:testing"

// yard_singleton_program builds a minimal Program carrying the three yard
// singletons (Scoreboard, Camera, Menu) plus the Settings data decl Menu's
// composite default resolves against — the schema substrate the engine
// singleton-spawn pass reads. Every slice is allocated on the supplied allocator
// (NOT a stack-local literal) so the decls outlive this proc's return; a freed
// Field_Decl would make the spawn pass read garbage default tokens. The defaults
// mirror yard.fun: Scoreboard's bare-scalar `delivered: Int = 0`, Camera's Vec2/
// Fixed defaults, and Menu's composite `Settings.defaults()` + Bool + Option::None.
@(private = "file")
yard_singleton_program :: proc(allocator := context.allocator) -> Program {
	// The Settings data decl Menu's `settings: Settings = Settings(…)` default
	// resolves its nested field types against (volume: Int, fullscreen: Bool).
	settings_fields := make([]Field_Decl, 2, allocator)
	settings_fields[0] = Field_Decl{name = "volume", type = "Int"}
	settings_fields[1] = Field_Decl{name = "fullscreen", type = "Bool"}
	data := make([]Data_Decl, 1, allocator)
	data[0] = Data_Decl{name = "Settings", fields = settings_fields}

	// Scoreboard { delivered: Int = 0 } — the bare-scalar singleton.
	scoreboard_fields := make([]Field_Decl, 1, allocator)
	scoreboard_fields[0] = Field_Decl {
		name            = "delivered",
		type            = "Int",
		has_default     = true,
		default_encoded = "0",
	}

	// Camera { at = Vec2{80,60}, zoom = 1.0, shake = Vec2{0,0} } — the Vec2/Fixed
	// singleton. The Vec2/Fixed defaults are encoded as the kernel's raw Q32.32
	// bits (i64(to_fixed(v))), so the spawn decodes the exact bytes the emitter
	// would write — bit-exact, no float.
	camera_fields := make([]Field_Decl, 3, allocator)
	camera_fields[0] = Field_Decl {
		name            = "at",
		type            = "Vec2",
		has_default     = true,
		default_encoded = fmt.aprintf(
			"Vec2(x=%d,y=%d)",
			i64(to_fixed(80)),
			i64(to_fixed(60)),
			allocator = allocator,
		),
	}
	camera_fields[1] = Field_Decl {
		name            = "zoom",
		type            = "Fixed",
		has_default     = true,
		default_encoded = fmt.aprintf("%d", i64(to_fixed(1)), allocator = allocator),
	}
	camera_fields[2] = Field_Decl {
		name            = "shake",
		type            = "Vec2",
		has_default     = true,
		default_encoded = fmt.aprintf(
			"Vec2(x=%d,y=%d)",
			i64(to_fixed(0)),
			i64(to_fixed(0)),
			allocator = allocator,
		),
	}

	// Menu { settings = Settings.defaults(), dirty = false, status = Option::None }
	// — the composite singleton. `settings` is a Settings record default (the v5
	// composite decode), `dirty` a Bool, `status` an Option::None enum token.
	menu_fields := make([]Field_Decl, 3, allocator)
	menu_fields[0] = Field_Decl {
		name            = "settings",
		type            = "Settings",
		has_default     = true,
		default_encoded = "Settings(volume=128,fullscreen=false)",
	}
	menu_fields[1] = Field_Decl {
		name            = "dirty",
		type            = "Bool",
		has_default     = true,
		default_encoded = "false",
	}
	menu_fields[2] = Field_Decl {
		name            = "status",
		type            = "Option",
		has_default     = true,
		default_encoded = "Option::None",
	}

	things := make([]Thing_Decl, 3, allocator)
	things[0] = Thing_Decl{name = "Scoreboard", singleton = true, fields = scoreboard_fields}
	things[1] = Thing_Decl{name = "Camera", singleton = true, fields = camera_fields}
	things[2] = Thing_Decl{name = "Menu", singleton = true, fields = menu_fields}

	program := Program{}
	program.data = data
	program.things = things
	return program
}

// startup_singletons runs the engine singleton-spawn pass via run_startup against
// the empty initial version — the pre-tick-0 population the singleton rows land in,
// so the result is the version a behavior keyed on a singleton reads at tick 0.
@(private = "file")
startup_singletons :: proc(program: ^Program, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	return run_startup(program, base, allocator)
}

// Each singleton spawns EXACTLY ONE row before tick 0, every column equal to its
// decoded Field_Decl default. This is the §06 §2 contract: a behavior keyed on a
// singleton sees one row at tick 0 accessed by type, filled from the schema
// defaults (no setup Spawn supplies a singleton).
@(test)
test_singletons_spawn_one_row_per_decl :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := yard_singleton_program()
	base := startup_singletons(&program)

	// Exactly one row per singleton — the row-count-1 constraint (§08 §3).
	testing.expect_value(t, view_count(view_of_type(&base, "Scoreboard")), 1)
	testing.expect_value(t, view_count(view_of_type(&base, "Camera")), 1)
	testing.expect_value(t, view_count(view_of_type(&base, "Menu")), 1)

	// Scoreboard.delivered == 0 — the bare-scalar Int default.
	scoreboard, sb_ok := singleton_row(&base, "Scoreboard")
	testing.expect(t, sb_ok)
	delivered, d_present := row_field(scoreboard, "delivered")
	testing.expect(t, d_present)
	testing.expect_value(t, delivered.(i64), i64(0))

	// Camera.at == Vec2{80,60}, zoom == 1.0, shake == Vec2{0,0} — the Vec2/Fixed
	// defaults, decoded bit-exact through the kernel.
	camera, cam_ok := singleton_row(&base, "Camera")
	testing.expect(t, cam_ok)
	at, at_present := row_field(camera, "at")
	zoom, zoom_present := row_field(camera, "zoom")
	shake, shake_present := row_field(camera, "shake")
	testing.expect(t, at_present && zoom_present && shake_present)
	testing.expect_value(t, at.(Vec2), Vec2{to_fixed(80), to_fixed(60)})
	testing.expect_value(t, zoom.(Fixed), to_fixed(1))
	testing.expect_value(t, shake.(Vec2), Vec2{to_fixed(0), to_fixed(0)})

	// Menu.dirty == false, status == Option::None — the Bool and Option-token
	// defaults; settings is the composite Settings record (asserted below).
	menu, menu_ok := singleton_row(&base, "Menu")
	testing.expect(t, menu_ok)
	dirty, dirty_present := row_field(menu, "dirty")
	testing.expect(t, dirty_present)
	testing.expect_value(t, dirty.(bool), false)

	// status is the verbatim Option::None enum token, lifting to a unit
	// Option::None Variant_Value (the SAME shape none_value boxes).
	status, status_present := row_field(menu, "status")
	testing.expect(t, status_present)
	status_token, is_token := status.(string)
	testing.expect(t, is_token)
	testing.expect_value(t, status_token, "Option::None")
	lifted := field_value_to_value(status)
	variant, is_variant := lifted.(Variant_Value)
	testing.expect(t, is_variant)
	testing.expect_value(t, variant.enum_type, "Option")
	testing.expect_value(t, variant.case_name, "None")
	testing.expect(t, variant.payload == nil)
}

// Menu's `settings = Settings.defaults()` composite default decodes to a
// Record_Value column whose nested fields resolve by Settings' declared types —
// the v5 composite-decode arm a singleton row carries (volume: Int → i64,
// fullscreen: Bool → bool), so a singleton's composite column is the SAME shape a
// runtime `Settings{…}` literal evaluates to.
@(test)
test_singleton_composite_default_decodes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := yard_singleton_program()
	base := startup_singletons(&program)

	menu, menu_ok := singleton_row(&base, "Menu")
	testing.expect(t, menu_ok)
	settings, settings_present := row_field(menu, "settings")
	testing.expect(t, settings_present)
	rec, is_rec := settings.(Record_Value)
	if !testing.expect(t, is_rec) {
		return
	}
	testing.expect_value(t, rec.type_name, "Settings")

	volume, volume_ok := rec.fields["volume"].(i64)
	testing.expect(t, volume_ok)
	testing.expect_value(t, volume, i64(128))

	fullscreen, fs_ok := rec.fields["fullscreen"].(bool)
	testing.expect(t, fs_ok)
	testing.expect_value(t, fullscreen, false)
}

// The singleton spawn is DETERMINISTIC: two independent runs of the pass over the
// same Program produce BYTE-IDENTICAL singleton rows — same minted Ids, same
// columns down to the fixed-point bits. The pass is a pure function of the schema
// defaults (no RNG, no input), so it is replay-stable and identical every run —
// the determinism warranty the §06 §2 engine spawn rests on.
@(test)
test_singleton_spawn_is_deterministic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := yard_singleton_program()

	first := startup_singletons(&program)
	second := startup_singletons(&program)

	// The two runs commit identical versions — same tick, same singleton tables,
	// same rows in the same stable Id order, same fixed-point bits.
	testing.expect(t, world_versions_equal(first, second))

	// Each singleton's minted Id is 0 in its own table (the singleton lands as the
	// sole row), identical across both runs — the Id assignment is schema-driven,
	// not run-dependent.
	for thing in ([]string{"Scoreboard", "Camera", "Menu"}) {
		row_first, ok_first := singleton_row(&first, thing)
		row_second, ok_second := singleton_row(&second, thing)
		testing.expect(t, ok_first && ok_second)
		testing.expect_value(t, row_first.id, Id{raw = Thing_Id(0)})
		testing.expect_value(t, row_second.id, row_first.id)
	}
}

// A non-singleton thing is NOT engine-spawned: the pass mints rows only for
// `singleton == true` decls, so an ordinary thing's table stays empty until setup
// spawns it. This guards the disjointness the run_startup ordering relies on —
// pong's ordinary Scoreboard (singleton == false, spawned via setup) is untouched
// by the engine singleton pass, so the existing pong fold is unaffected.
@(test)
test_non_singleton_not_engine_spawned :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// A program with one ordinary thing carrying a defaulted field — the engine
	// singleton pass must NOT mint a row for it.
	fields := make([]Field_Decl, 1, context.temp_allocator)
	fields[0] = Field_Decl{name = "score", type = "Int", has_default = true, default_encoded = "0"}
	things := make([]Thing_Decl, 1, context.temp_allocator)
	things[0] = Thing_Decl{name = "Scoreboard", singleton = false, fields = fields}
	program := Program{}
	program.things = things

	base := startup_singletons(&program)

	// No setup batch and not a singleton — the table stays empty (setup, not the
	// engine, would spawn this ordinary thing).
	testing.expect_value(t, view_count(view_of_type(&base, "Scoreboard")), 0)
}
