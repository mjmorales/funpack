// §17 level-bake fixtures (spec §17.1–§17.4). The bake lowers a parsed `.flvl`
// against its `things` schema module into the typed Ref table, the deterministic
// spawn list, and every §17.4 gate. These are HAND-BUILT schema+level fixtures
// (no spec golden checkout, no byte-match — that is the leaf story): a small
// schema module that bakes a clean level, plus ONE rejecting fixture per gate
// arm asserting the specific Bake_Error.
//
// The schema module is a real parsed .fun source (stage_parse over a hand-built
// thing schema), so a Ref[T] field, a `pos: Vec2`, and a `rate: Fixed` carry the
// genuine Field_Decl/Type_Ref shapes the bake reads; the level is a real
// parse_flvl over flat text. build_module_index_from_asts wires the schema module
// into the index the bake resolves `things <module>` against — the same seam the
// multi-module fixtures use.
package funpack

import "core:testing"

// SCHEMA_SOURCE is the hand-built `arena_world` schema module: the placeable
// thing types the fixtures place, with a Ref[Switch]-gated Door (the
// reference-by-name target) and a Fixed-rate Cannon (the prefab override
// target). Schema only — no behaviors — so it is a valid §17.2 schema module.
SCHEMA_SOURCE :: `
import engine.math.{Fixed, Vec2}
import engine.world.Ref
thing Player { pos: Vec2 }
thing Switch { pos: Vec2, on: Bool = false }
thing Door { pos: Vec2, gate: Ref[Switch], open: Bool = false }
thing Pillar { pos: Vec2 }
thing Base { pos: Vec2 }
thing Cannon { pos: Vec2, rate: Fixed }
`

// bake_fixture parses a schema source and a level source, builds the project
// index over the schema module, and bakes the level — the shared fixture wiring
// every test below funnels through. The schema module name is `arena_world`,
// matching the `things arena_world` line the level sources carry.
bake_fixture :: proc(t: ^testing.T, schema_src, level_src: string) -> (baked: Baked_Level, err: Bake_Error) {
	schema_ast, schema_parse := stage_parse(stage_lex(schema_src))
	testing.expect_value(t, schema_parse, Parse_Error.None)
	level, level_parse := parse_flvl(level_src)
	testing.expect_value(t, level_parse, Flvl_Parse_Error.None)
	index := build_module_index_from_asts({"arena_world"}, {schema_ast})
	return bake_flvl(level, schema_ast, "arena_world", index)
}

// CLEAN_LEVEL is the canonical clean fixture: a 2d arena with a player, a
// switch, a switch-gated door (reference-by-name `gate: plate`), a five-iteration
// pillar loop, and a Turret prefab placement with a nested-field override
// (`cannon.rate: 4.0`). It exercises every clean-path mechanism — anchors,
// offset arithmetic, the loop var, a prefab + override, a typed Ref — at once.
CLEAN_LEVEL :: `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world

  prefab Turret {
    place Base   base   at origin
    place Cannon cannon { rate: 2.0 } at base.offset(y: 6)
  }

  place Player hero at center
  place Switch plate at center.offset(y: 40)
  place Door   exit  { gate: plate } at center.offset(y: -40)
  for i in 0..5 {
    place Pillar at center.offset(x: -48 + i * 24, y: 0)
  }
  place Turret right_gun { cannon.rate: 4.0 } at right_edge.center.offset(x: -12)
}
`

@(test)
test_flvl_bake_clean_fixture :: proc(t: ^testing.T) {
	// AC: the clean fixture bakes to the expected Ref table and spawn list. The
	// Ref table is the five NAMED instances (hero, plate, exit, and the prefab's
	// two members); the prefab instance itself is a Baked_Prefab_Instance, not a
	// Ref. The spawn list is declaration order with the loop and prefab expanded
	// in place: hero, plate, exit, 5 pillars, base, cannon = 10 spawns.
	baked, err := bake_fixture(t, SCHEMA_SOURCE, CLEAN_LEVEL)
	testing.expect_value(t, err, Bake_Error.None)
	testing.expect_value(t, baked.level_name, "Arena")

	// Five named Refs: hero, plate, exit, right_gun.base, right_gun.cannon.
	testing.expect_value(t, len(baked.refs), 5)
	hero, has_hero := find_baked_ref(baked.refs, "Arena.hero")
	testing.expect(t, has_hero)
	testing.expect_value(t, hero.thing_type, "Player")
	exit, has_exit := find_baked_ref(baked.refs, "Arena.exit")
	testing.expect(t, has_exit)
	testing.expect_value(t, exit.thing_type, "Door")
	cannon, has_cannon := find_baked_ref(baked.refs, "Arena.right_gun.cannon")
	testing.expect(t, has_cannon)
	testing.expect_value(t, cannon.thing_type, "Cannon")

	// The deterministic spawn list: 10 entries (1 player + 1 switch + 1 door +
	// 5 pillars + base + cannon), declaration order with the loop/prefab expanded
	// in place.
	testing.expect_value(t, len(baked.spawns), 10)
	testing.expect_value(t, baked.spawns[0].thing_type, "Player")
	testing.expect_value(t, baked.spawns[1].thing_type, "Switch")
	testing.expect_value(t, baked.spawns[2].thing_type, "Door")
	testing.expect_value(t, baked.spawns[3].thing_type, "Pillar")
	testing.expect_value(t, baked.spawns[7].thing_type, "Pillar")
	testing.expect_value(t, baked.spawns[8].thing_type, "Base")
	testing.expect_value(t, baked.spawns[9].thing_type, "Cannon")

	// The one prefab instance (right_gun) expands to its two member Refs.
	testing.expect_value(t, len(baked.prefabs), 1)
	testing.expect_value(t, baked.prefabs[0].name, "Arena.right_gun")
	testing.expect_value(t, baked.prefabs[0].type, "Turret")
	testing.expect_value(t, len(baked.prefabs[0].members), 2)

	// The reference-by-name `gate: plate` on the Door resolves to a Ref param
	// pointing at the `plate` instance's stable Id.
	plate, has_plate := find_baked_ref(baked.refs, "Arena.plate")
	testing.expect(t, has_plate)
	door_spawn := baked.spawns[2]
	testing.expect_value(t, len(door_spawn.params), 1)
	testing.expect(t, door_spawn.params[0].is_ref)
	testing.expect_value(t, door_spawn.params[0].field, "gate")
	testing.expect_value(t, door_spawn.params[0].ref_id, plate.id)

	// The nested-field override `cannon.rate: 4.0` reaches the prefab's Cannon
	// member: its `rate` param is the overridden 4.0, not the prefab default 2.0.
	cannon_spawn := baked.spawns[9]
	rate, has_rate := find_baked_param(cannon_spawn.params, "rate")
	testing.expect(t, has_rate)
	testing.expect_value(t, rate.value, to_fixed(4))
}

@(test)
test_flvl_bake_stable_name_ids :: proc(t: ^testing.T) {
	// AC: a named instance's Id is derived from its level-qualified name and is
	// stable — the same name bakes to the same Id, a different name to a different
	// Id (spec §17.2 "stable ids by name"). The qualified name `Arena.hero` keys
	// the Id, so the Id is reproducible and rename-sensitive.
	baked, err := bake_fixture(t, SCHEMA_SOURCE, CLEAN_LEVEL)
	testing.expect_value(t, err, Bake_Error.None)

	hero, _ := find_baked_ref(baked.refs, "Arena.hero")
	plate, _ := find_baked_ref(baked.refs, "Arena.plate")
	// The Id is the deterministic hash of the qualified name — recomputable.
	testing.expect_value(t, hero.id, stable_id("Arena.hero"))
	testing.expect_value(t, plate.id, stable_id("Arena.plate"))
	// Distinct names → distinct Ids (no collision among the fixture's names).
	testing.expect(t, hero.id != plate.id)
	// A prefab member's Id keys off its deep qualified name.
	cannon, _ := find_baked_ref(baked.refs, "Arena.right_gun.cannon")
	testing.expect_value(t, cannon.id, stable_id("Arena.right_gun.cannon"))
}

@(test)
test_flvl_bake_fixed_point_coords :: proc(t: ^testing.T) {
	// AC: an `at` resolves to a fixed-point coordinate by anchoring + folding the
	// offset arithmetic (spec §17.4 — coordinates are fixed-point so a level loads
	// bit-identically). center = (80, 60); `center.offset(y: 40)` = (80, 100);
	// the loop's `center.offset(x: -48 + i*24)` walks 32, 56, 80, 104, 128 in x.
	baked, err := bake_fixture(t, SCHEMA_SOURCE, CLEAN_LEVEL)
	testing.expect_value(t, err, Bake_Error.None)

	// hero at center: bounds (0,0)-(160,120) → center (80, 60), exact Fixed bits.
	hero_spawn := baked.spawns[0]
	testing.expect_value(t, hero_spawn.pos.x, to_fixed(80))
	testing.expect_value(t, hero_spawn.pos.y, to_fixed(60))

	// plate at center.offset(y: 40): (80, 100).
	plate_spawn := baked.spawns[1]
	testing.expect_value(t, plate_spawn.pos.x, to_fixed(80))
	testing.expect_value(t, plate_spawn.pos.y, to_fixed(100))

	// The pillar loop folds `-48 + i * 24` over the kernel: i=0 → x=32, i=4 → 128.
	first_pillar := baked.spawns[3]
	testing.expect_value(t, first_pillar.pos.x, to_fixed(32))
	testing.expect_value(t, first_pillar.pos.y, to_fixed(60))
	last_pillar := baked.spawns[7]
	testing.expect_value(t, last_pillar.pos.x, to_fixed(128))

	// The prefab member `cannon at base.offset(y: 6)` against the placement
	// origin (right_edge.center.offset(x: -12) = (148, 60)): base at (148, 60),
	// cannon at (148, 66).
	base_spawn := baked.spawns[8]
	testing.expect_value(t, base_spawn.pos.x, to_fixed(148))
	testing.expect_value(t, base_spawn.pos.y, to_fixed(60))
	cannon_spawn := baked.spawns[9]
	testing.expect_value(t, cannon_spawn.pos.y, to_fixed(66))
}

// ── §17.4 gate rejections (one fixture per arm) ─────────────────────────────

@(test)
test_flvl_gate_unresolved_name :: proc(t: ^testing.T) {
	// A reference-by-name (`gate: ghost`) naming no placed instance is the
	// unresolved-name compile error — dangling references are unrepresentable.
	level := `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world
  place Door exit { gate: ghost } at center
}
`
	_, err := bake_fixture(t, SCHEMA_SOURCE, level)
	testing.expect_value(t, err, Bake_Error.Unresolved_Name)
}

@(test)
test_flvl_gate_duplicate_name :: proc(t: ^testing.T) {
	// Two named instances sharing a level-qualified name is the duplicate-name
	// compile error.
	level := `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world
  place Player hero at center
  place Player hero at center.offset(x: 10)
}
`
	_, err := bake_fixture(t, SCHEMA_SOURCE, level)
	testing.expect_value(t, err, Bake_Error.Duplicate_Name)
}

@(test)
test_flvl_gate_type_mismatched_ref :: proc(t: ^testing.T) {
	// A Ref[Switch] field (`gate`) bound to an instance whose thing type is NOT
	// Switch (here a Player) is the type-mismatched-ref compile error.
	level := `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world
  place Player hero at center
  place Door exit { gate: hero } at center.offset(y: -40)
}
`
	_, err := bake_fixture(t, SCHEMA_SOURCE, level)
	testing.expect_value(t, err, Bake_Error.Type_Mismatched_Ref)
}

@(test)
test_flvl_gate_param_not_on_schema :: proc(t: ^testing.T) {
	// A param key (`speed`) that is not a field of the placed thing's schema is
	// the param-not-on-schema compile error.
	level := `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world
  place Player hero { speed: 5 } at center
}
`
	_, err := bake_fixture(t, SCHEMA_SOURCE, level)
	testing.expect_value(t, err, Bake_Error.Param_Not_On_Schema)
}

@(test)
test_flvl_gate_at_without_pos :: proc(t: ^testing.T) {
	// A thing placed with `at` must declare a `pos` of the level's arity. A 3d
	// level placing a thing whose `pos` is Vec2 (the wrong arity) is the
	// at-without-pos (dimensionality) compile error.
	schema := `
import engine.math.{Vec2}
thing Player { pos: Vec2 }
`
	level := `
level Arena 3d {
  bounds (0, 0, 0) (160, 120, 80)
  things arena_world
  place Player hero at center
}
`
	_, err := bake_fixture(t, schema, level)
	testing.expect_value(t, err, Bake_Error.At_Without_Pos)
}

@(test)
test_flvl_gate_outside_bounds :: proc(t: ^testing.T) {
	// A resolved coordinate outside the level's bounds is the out-of-bounds
	// compile error. `center.offset(x: 200)` on a 160-wide level lands at x=280,
	// past the right bound.
	level := `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world
  place Player hero at center.offset(x: 200)
}
`
	_, err := bake_fixture(t, SCHEMA_SOURCE, level)
	testing.expect_value(t, err, Bake_Error.Outside_Bounds)
}

@(test)
test_flvl_gate_seam_imports_behavior :: proc(t: ^testing.T) {
	// §17.2 layering: a generated `.gen.fun` seam imports schema modules only — a
	// seam importing a behavior module (one declaring a `behavior`/`pipeline`) is
	// the seam-imports-behavior compile error. The seam's import of `arena_game`,
	// a behavior module, rejects; an import of the schema module `arena_world`
	// does not.
	behavior_src := `
thing Player { pos: Int }
behavior chase on Player { fn step(p: Player) -> Player { return p } }
`
	schema_only_src := `thing Switch { pos: Int }`
	behavior_ast, b_parse := stage_parse(stage_lex(behavior_src))
	testing.expect_value(t, b_parse, Parse_Error.None)
	schema_ast, s_parse := stage_parse(stage_lex(schema_only_src))
	testing.expect_value(t, s_parse, Parse_Error.None)

	module_asts := make(map[string]Ast, 4, context.temp_allocator)
	module_asts["arena_game"] = behavior_ast
	module_asts["arena_world"] = schema_ast

	// A seam importing the behavior module rejects.
	seam_bad_src := `import arena_game.{Player}`
	seam_bad, sb_parse := stage_parse(stage_lex(seam_bad_src))
	testing.expect_value(t, sb_parse, Parse_Error.None)
	testing.expect_value(t, check_flvl_seam_layering(seam_bad, module_asts), Bake_Error.Seam_Imports_Behavior)

	// A seam importing the schema module only is clean.
	seam_ok_src := `import arena_world.{Switch}`
	seam_ok, so_parse := stage_parse(stage_lex(seam_ok_src))
	testing.expect_value(t, so_parse, Parse_Error.None)
	testing.expect_value(t, check_flvl_seam_layering(seam_ok, module_asts), Bake_Error.None)
}

@(test)
test_flvl_gate_prefab_member_not_placed :: proc(t: ^testing.T) {
	// A prefab override naming a member the prefab never places is the
	// prefab-member-not-placed compile error. The Turret prefab places `base` and
	// `cannon`; an override `turret.rate` names `turret`, which it never places.
	level := `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world
  prefab Turret {
    place Base   base   at origin
    place Cannon cannon { rate: 2.0 } at base.offset(y: 6)
  }
  place Turret right_gun { turret.rate: 4.0 } at center
}
`
	_, err := bake_fixture(t, SCHEMA_SOURCE, level)
	testing.expect_value(t, err, Bake_Error.Prefab_Member_Not_Placed)
}

// ── Test-local lookup helpers ───────────────────────────────────────────────

// find_baked_ref finds a Ref table entry by its level-qualified name, walked by
// index. Test-local: the bake's own find_ref keys on the BARE local name (the
// reference-by-name resolution key), while the assertions want the qualified
// name.
find_baked_ref :: proc(refs: []Baked_Ref, qualified: string) -> (ref: Baked_Ref, found: bool) {
	for candidate in refs {
		if candidate.name == qualified {
			return candidate, true
		}
	}
	return Baked_Ref{}, false
}

// find_baked_param finds a resolved spawn param by field name, walked by index.
find_baked_param :: proc(params: []Baked_Param, field: string) -> (param: Baked_Param, found: bool) {
	for candidate in params {
		if candidate.field == field {
			return candidate, true
		}
	}
	return Baked_Param{}, false
}
