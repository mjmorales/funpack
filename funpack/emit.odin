// The production artifact emitter: the pure source → artifact serializer.
// It walks the checked AST (parse → resolve → typecheck → contracts) and the
// depth-first flattened pipeline (pipeline_flatten.odin) and writes every
// section of the v1 byte format in the spec's fixed order
// (docs/artifact-format.md §3). The output reproduces the committed golden
// fixture (testdata/pong.artifact) byte-for-byte from the pong source, and the
// runtime parses those bytes with zero funpack imports.
//
// PURITY (spec §09, §29; docs/artifact-format.md §2): emission is a pure
// function of source — no clock, no machine paths, no float, no host bytes.
// Every Fixed is its raw Q32.32 i64 bits in decimal (the same kernel
// representation as fixed.odin), every list is in a defined total order
// (declaration order or the flattened pipeline order, never map order), and the
// only path-derived datum is the §15 module name carried in a span. Two
// emissions from the same source are therefore byte-identical: no field's value
// depends on when, where, or on which machine it was emitted.
//
// Boundary: bytes only. This file does not wire a CLI verb (the build verb is
// out of scope), does not emit the Index Contract NDJSON (§29, out of scope),
// and does not execute the artifact (the runtime owns execution).
package funpack

import "core:strings"

// Emit_Input bundles the four pure inputs the emitter projects into bytes: the
// checked AST (source declarations), the flattened pipeline (the §11 total
// order and §12 routing map), the §14 project identity (the [meta] name/version
// and the span module name), and the §14 entrypoint wiring ([entrypoint]). Each
// is itself a pure function of source, so the whole emission is.
Emit_Input :: struct {
	ast:          Ast,
	flat:         Flattened_Pipeline,
	module:       string, // the §15 path-derived module name carried in [functions] spans
	project:      Project_Identity,
	entrypoint:   Entrypoint_Config,
	// imported_fns are the §17 cross-module SEAM fn/const records the entrypoint
	// module references — the fns and module-level consts it imports from sibling
	// USER modules (krognid's `stroll` imports `krognid_skeleton`/`krognid_parts`
	// from the rig seam; dungeon imports the level seam's `terrain` TilemapHandle
	// const, schema v15). Each carries its OWN seam module in its span, so
	// emit_functions appends them after the entrypoint module's own records and a
	// behavior body's references resolve to a self-contained record the runtime
	// finds by bare name. Empty for a single-module game (every byte of pong/
	// snake/hunt/yard is unchanged).
	imported_fns: []Function_Record,
	// imported_decls is the v15 cross-module DECLARATION carry
	// (emit_seam_decls.odin): the enum/data/signal/thing declarations the
	// entrypoint module imports from sibling USER modules, appended after each
	// section's own declarations so the artifact carries the whole referenced
	// schema (dungeon_world's Player/Slime/Chest things, Dir enum, Looted
	// signal). Empty for a single-module game.
	imported_decls: Imported_Decls,
	// level_spawns are the baked levels' deterministic spawn lists keyed by
	// their seam extern names (emit_level_setup.odin, schema v15) — the data
	// the [setup] emitter folds when setup() is a lone call to a level's
	// `<level>_spawns` extern. The build verb threads them in from the tree's
	// levels/*.flvl bake; empty for a level-less game.
	level_spawns: []Level_Spawn_Batch,
	// tilemaps are the §18 §3 baked tile layers (flvl_bake.odin) the [tilemaps]
	// section carries (docs/artifact-format.md §17, schema v12) — the static
	// environment the runtime renders batched and collides against, each layer
	// carrying its v12 grid→world anchor. The build verb threads them in from
	// the tree's levels/*.flvl bake (emit_tree_artifact); empty for a level-less
	// game, which moves by the version stamp plus the constant `[tilemaps 0]`
	// tail alone.
	tilemaps:     []Baked_Tile_Layer,
	// nav_graphs are the §12 §1 nav graphs the [nav] section carries
	// (docs/artifact-format.md §18, schema v13) — one flat walkable-cell graph
	// per baked tile layer (bake_tree_nav_graphs), in the SAME slice order as
	// tilemaps, so the [nav] section mirrors [tilemaps]. The build verb derives
	// them from the same baked layers; empty for a level-less game (the constant
	// `[nav 0]` tail).
	nav_graphs:   []Baked_Nav_Graph,
	// assets are the §19 baked sprite assets the [assets] section carries
	// (docs/artifact-format.md §19, schema v16) — the decoded, content-addressed
	// image pixels and the atlas slice rects a textured `Draw_Sprite{atlas, cell}`
	// resolves against. The build verb threads them in from the §19-literal
	// manifest bake (bake_tree_assets) only when the tree carries an
	// assets.manifest; empty for an asset-less game, which writes the constant
	// `[assets 0]` tail and moves by the version stamp alone.
	assets:       Baked_Assets,
}

// Emit_Error distinguishes the ways emission can refuse before it writes bytes:
// the source failed to compile (Parse/Gate/Typecheck/Contract/Flatten — the same
// checked-pipeline floors the test verb runs), or the entrypoint config failed —
// malformed, more than one block, or a pipeline/bindings reference the checked
// source does not declare (§07's dangling-reference obligation, enforced at
// emission so a [entrypoint] section can never name wiring the runtime cannot
// resolve). The emitter only serializes a fully-checked program (spec §09: the
// artifact is the checked AST), so a source that does not compile yields no
// artifact.
Emit_Error :: enum {
	None,
	Parse_Failed,
	Gate_Failed,
	Typecheck_Failed,
	Contract_Failed,
	Flatten_Failed,
	Entrypoint_Failed,
	// Whole_Module_Collision is the v17 textured-render lowering's refusal: a
	// whole-module-imported handle const's bare name collides with an own-module
	// declaration (the v6 disambiguation), so lowering it to a bare name would put
	// two [functions] records under one name. The build refuses before writing any
	// product — the same exit-2 compile class as the other emission floors (the
	// build verb maps it to Compile_Failed), never a silently ambiguous artifact.
	Whole_Module_Collision,
}

// stage_emit is the single-source → artifact seam: it runs the full checked
// pipeline (lex → parse → gates → typecheck → contracts → flatten) over one
// project source against an EMPTY module index, parses the §14 entrypoint config
// through the one entrypoints production and validates its references against the
// checked AST, then bundles the checked AST, flattened pipeline, §14 project
// identity, and selected entrypoint into an Emit_Input and serializes it.
// Emission is a pure function of the three inputs — the source bytes, the project
// identity, and the entrypoint config text — so two calls on the same inputs are
// byte-identical. A source that fails any checked-pipeline floor returns the
// matching Emit_Error and no bytes. It is stage_emit_indexed with the empty index
// and no sibling-module ASTs (every user-module import is .Unknown_Module), so a
// single-module game emits exactly as before; a multi-module game's entrypoint
// emits through stage_emit_indexed with the project-wide index.
stage_emit :: proc(
	source: string,
	module: string,
	project: Project_Identity,
	entrypoint_fcfg: string,
	allocator := context.allocator,
) -> (artifact: string, err: Emit_Error) {
	return stage_emit_indexed(source, module, project, entrypoint_fcfg, Module_Index{}, nil, nil, nil, nil, Baked_Assets{}, allocator)
}

// stage_emit_indexed is the source → artifact seam typed against a project-wide
// module index, so a multi-module game's ENTRYPOINT module (the arena example's
// arena_game, importing arena_world + the arena seam) types cross-module before
// it emits. The stage order is identical to the single-source stage_emit — only
// the typecheck stage becomes index-aware (stage_typecheck_indexed) — and an
// empty index reduces it to the single-source path (every user-module import is
// .Unknown_Module), so a one-module game's bytes are unchanged. The entrypoint
// config's pipeline/bindings references still validate against THIS module's AST
// (the entrypoint module declares the pipeline and bindings fn), so a dangling
// reference is still caught at emission.
//
// module_asts maps each sibling §15 module name to its parsed AST — the bodies the
// §17 cross-module SEAM-FN CARRY reads. After the entrypoint AST checks, the
// emitter walks its imports, and for each fn imported from a sibling USER module
// present in this map, carries that fn's full record (signature + body) into
// [functions] (collect_imported_fn_records). A nil/absent map (the single-source
// stage_emit) carries nothing, so a one-module game's bytes are unchanged.
//
// tilemaps are the tree's §18 §3 baked tile layers (the levels/*.flvl bake the
// build verb runs — bake_tree_levels) threaded through to the artifact's
// [tilemaps] section. nav_graphs are the §12 §1 nav graphs derived from those
// same layers (bake_tree_nav_graphs) threaded through to the [nav] section.
// level_spawns are the same bake's deterministic spawn lists, keyed by their
// seam extern names, the v15 [setup] fold consumes (emit_level_setup.odin). Like
// every other input they are a pure function of the tree, so emission stays pure;
// nil is the level-less default (the constant `[tilemaps 0]` / `[nav 0]` tails
// and the resolve_setup_spawns [setup] path).
//
// assets are the tree's §19 baked sprite assets (bake_tree_assets) the [assets]
// section carries — the decoded content-addressed image pixels and the atlas slice
// rects (schema v16). Like every other input it is a pure function of the tree
// (import_image decodes deterministically), so emission stays pure; the empty
// Baked_Assets is the asset-less default (the constant `[assets 0]` tail).
stage_emit_indexed :: proc(
	source: string,
	module: string,
	project: Project_Identity,
	entrypoint_fcfg: string,
	index: Module_Index,
	module_asts: map[string]Ast,
	tilemaps: []Baked_Tile_Layer = nil,
	nav_graphs: []Baked_Nav_Graph = nil,
	level_spawns: []Level_Spawn_Batch = nil,
	assets: Baked_Assets = {},
	allocator := context.allocator,
) -> (artifact: string, err: Emit_Error) {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return "", .Parse_Failed
	}
	if stage_gates(ast) != .None {
		return "", .Gate_Failed
	}
	typed, type_err := stage_typecheck_indexed(ast, index)
	if type_err != .None {
		return "", .Typecheck_Failed
	}
	if stage_contracts(typed).err != .None {
		return "", .Contract_Failed
	}
	verdict := stage_flatten(typed)
	if verdict.err != .None {
		return "", .Flatten_Failed
	}
	entrypoints, ep_err := parse_entrypoints_fcfg(entrypoint_fcfg)
	if ep_err != .None {
		return "", .Entrypoint_Failed
	}
	if validate_entrypoints(entrypoints, ast) != .None {
		return "", .Entrypoint_Failed
	}
	entrypoint, sel_err := select_entrypoint(entrypoints)
	if sel_err != .None {
		return "", .Entrypoint_Failed
	}
	// The §19 textured-render whole-module const carry + bare-name lowering (v17):
	// carry the handle consts the entrypoint reaches through a WHOLE-MODULE import
	// (`import assets`, `assets.dungeon_atlas`) into [functions] BEFORE lowering the
	// AST (the carry reads the qualified `module.NAME` refs the lowering then strips
	// to bare names). The two together make `assets.dungeon_atlas` resolve by bare
	// name at runtime, no runtime special-case. A bare-name collision (the v6
	// disambiguation) refuses the build, surfaced as Typecheck_Failed (the
	// pre-emission compile class), naming nothing further here — the offending name
	// is in the verdict, kept for the build verb's refusal line.
	whole_module_consts := collect_whole_module_const_records(ast, module_asts)
	if lower_verdict := lower_whole_module_refs(&ast, module_asts); lower_verdict.err != .None {
		return "", .Whole_Module_Collision
	}
	imported_fns := collect_imported_fn_records(ast, module_asts)
	imported_fns = concat_function_records(imported_fns, whole_module_consts)
	input := Emit_Input {
		ast            = ast,
		flat           = verdict.flat,
		module         = module,
		project        = project,
		entrypoint     = entrypoint,
		imported_fns   = imported_fns,
		imported_decls = collect_imported_decls(ast, module_asts),
		tilemaps       = tilemaps,
		nav_graphs     = nav_graphs,
		level_spawns   = level_spawns,
		assets         = assets,
	}
	return emit_artifact(input, allocator), .None
}

// emit_artifact serializes the checked program to the versioned artifact bytes
// (docs/artifact-format.md). It writes the version stamp — the magic then the
// current ARTIFACT_SCHEMA_VERSION, the single compatibility gate — then every
// section in the fixed order, each as a `[name N]` header followed by its
// records. The returned string is the whole artifact, terminated by a single
// trailing '\n' like every other line — byte-identical across emissions by
// construction.
emit_artifact :: proc(input: Emit_Input, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	emit_line(&b, ARTIFACT_MAGIC, " ", encode_int(ARTIFACT_SCHEMA_VERSION, context.temp_allocator))

	emit_meta(&b, input.project)
	emit_enums(&b, input.ast, input.imported_decls.enums)
	emit_data(&b, input.ast, input.imported_decls)
	emit_signals(&b, input.ast, input.imported_decls.signals)
	emit_things(&b, input.ast, input.imported_decls.things)
	emit_functions(&b, input.ast, input.module, input.imported_fns)
	emit_behaviors(&b, input.ast, input.flat)
	emit_pipeline_flattened(&b, input.flat)
	emit_signal_routing(&b, input.flat)
	emit_setup(&b, input.ast, input.level_spawns, input.imported_decls.things)
	emit_bindings(&b, input.ast)
	emit_entrypoint(&b, input.entrypoint)
	emit_queries(&b, input.ast, input.module)
	emit_tilemaps(&b, input.tilemaps)
	emit_navs(&b, input.nav_graphs)
	emit_assets(&b, input.assets)
	emit_probes(&b, input.ast)

	return strings.to_string(b)
}

// emit_line writes the concatenation of parts then the single LF terminator the
// format mandates (docs/artifact-format.md §2.1). It is the one place a line
// ends, so every record is exactly one '\n'-terminated line.
emit_line :: proc(b: ^strings.Builder, parts: ..string) {
	for part in parts {
		strings.write_string(b, part)
	}
	strings.write_byte(b, '\n')
}

// emit_header writes a `[name N]` section header (docs/artifact-format.md §2.1):
// the section name and its exact top-level record count. A reader re-derives N
// by counting lead lines and refuses a mismatch, so N must equal the records
// that follow.
emit_header :: proc(b: ^strings.Builder, name: string, count: int) {
	strings.write_byte(b, '[')
	strings.write_string(b, name)
	strings.write_byte(b, ' ')
	strings.write_int(b, count)
	emit_line(b, "]")
}
