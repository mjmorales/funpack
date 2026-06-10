// The Index Contract `project` record — funpack's ONE structured interface
// (spec §29 §2): the data contract the `funpack warden` sub-toolchain consumes
// as an in-process pure projection. It is
// a closed, schema-versioned, exact-match structure with ALL fields
// mandatory and a leading `schema_version` stamp; an under- or over-shaped
// record is an error, there are no optional fields. The transport is NDJSON —
// one JSON object per line — emitted whole-stream per build (a complete
// index, never an incremental delta). The emission is a pure projection of
// the §14 authored config (`funpack_configs/*.fcfg`) and the compiled source,
// so it is byte-identical on every machine: there is no clock, no map
// iteration, no float (spec §29 §1). Any change to which fields are emitted
// is a contract RESHAPE — bump INDEX_SCHEMA_VERSION, never silently drift.
//
// This file owns BOTH §29 §2 record kinds — the per-declaration `decl` record
// and the whole-project `project` record (the `funpack warden` query/projection
// side is out of scope here). It is a DISTINCT surface from the runtime binary
// artifact (artifact_format.odin): different consumer (the `funpack warden`
// surface, not the runtime) and different transport (NDJSON, not the
// length-prefixed byte format).
//
// AUTHORED fields project from the config tree: `entrypoints` (the
// entrypoints.fcfg pipeline/tick/bindings wiring, §14 §4), `builds` (the
// builds.fcfg presentation platform targets, §14 §4/§6), `tag_registry` (the
// tags.fcfg @gtag registry, §14 §4). DERIVED fields project from source:
// `capabilities` (the §14 §4 derivation — core render/input/state always on,
// the optional batteries switched on by their backing source), the
// `pipeline_flattened` depth-first total order (stage_flatten, §07 §3), and
// the structural `gate_results` (the §29 §1 gate verdicts).
package funpack

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// INDEX_SCHEMA_VERSION is the leading stamp every Index Contract record
// carries (spec §29 §2). The `funpack warden` consumer exact-matches it and refuses a mismatch
// with a fix-it rather than best-effort parsing, so it is the single
// compatibility gate. Any change to the emitted field set is a contract
// reshape that bumps this; it is independent of the runtime artifact's
// ARTIFACT_SCHEMA_VERSION (a separate surface with its own version line).
//
// Version 2 adds the §29 §2 per-declaration `decl` record kind alongside the
// `project` record — a deliberate schema reshape under closed-enum discipline
// (a new record kind in the closed contract bumps the version, never silent
// drift). The stamp leads BOTH record kinds, so a v2 stream carries v2 in
// every line.
//
// Version 3 makes the decl record's §05 directive fields AUTHORITATIVE — BOTH
// `debug` (probe_names over the parsed §05 §5 probes) and `todo` (todo_flag
// over the parsed §05 §2 notes) derive from the AST (index_decl.odin) instead
// of the v2 constant-empty stamps. The field SHAPES are unchanged, but the
// content contract is not — a v2 stream may report `debug: []` / `todo: false`
// over a source that carries probes or @todo notes (the parser admitted both
// before the derivations landed), so the §28 §4 task-registration consumer and
// the §29 §4 `warden debt` surface must refuse a pre-derivation stream rather
// than read its empties as "no probes" / "no debt". A derivation-contract
// change the consumer can misread is a reshape, so it bumps — once: the two
// derivations land inside the same v3, so the shipped contract changes a
// single time carrying the pair.
INDEX_SCHEMA_VERSION :: 3

// Index_Decl_Kind is the closed §29 §2 set of source DECLARATION FORMS the
// per-declaration `decl` record reports — the kind taxonomy of what a
// declaration IS in the source. It is a DISTINCT taxonomy from surface.odin's
// Decl_Kind, which is the IMPORT-RESOLUTION binding kind (Module/Type_Name/
// Func/Value — how a resolved name binds against the stdlib surface). The two
// must not be conflated: one enumerates source declaration forms, the other
// enumerates import-binding positions. The form set maps 1:1 onto the parser's
// declaration collections — Data/Enum/Thing/Signal/Fn/Behavior/Pipeline/Let/
// Test are the Ast.* collections, and Extern_Fn is the `is_extern` Fn (a
// body-less §02/§26 native-boundary fn, a distinct kind from a bodied Fn). The
// set is closed: a new declaration form is a schema-version bump, never a
// silently-added string.
Index_Decl_Kind :: enum {
	Data,      // a `data` record declaration (§03)
	Enum,      // an `enum` declaration (§03)
	Thing,     // a `thing` declaration (§06)
	Signal,    // a `signal` declaration (§04)
	Fn,        // a bodied free function (§02)
	Extern_Fn, // a body-less `extern fn` native-boundary fn (§02/§26)
	Behavior,  // a `behavior` declaration (§06)
	Pipeline,  // a `pipeline` declaration (§07)
	Let,       // a module-level `let` value binding (§02)
	Test,      // a `test` declaration (§29 §1)
}

// Decl_Record is the closed, exact-match per-declaration `decl` record of the
// Index Contract (spec §29 §2). Like the `project` record the field set is
// fixed and ALL fields are mandatory — there are no optional fields, an absent
// value is the empty list / false / "" never an omitted key. Field declaration
// order IS the emitted JSON key order (a pure struct marshal), so the
// schema_version stamp leads. The §29 §2 inline field list, in order:
//   - qualified_name — the module-qualified declaration name (§15)
//   - kind           — the source declaration form (closed Index_Decl_Kind)
//   - file           — the source file path; "" in the single-source frontend
//                      (the frontend compiles one source, so the path is not
//                      yet threaded — lore #11)
//   - span           — the 1-based source line of the declaration keyword, the
//                      artifact-format §9 line-span convention the lexer and
//                      Fn_Node/Let_Decl_Node already stamp
//   - doc            — the attached `@doc` text (§05); "" when undocumented
//   - gtags          — the attached `@gtag` registry tags (§05), authored order
//   - stub           — the §05 §2 typed-hole flag, AST-derived: true when the
//                      declaration holds a `@stub(T)` / `@stub(T, fallback)`
//                      hole in body position (the parser's Fn_Node.holed) OR in
//                      expression position anywhere the shared hole walkers
//                      descend (fn_holds_stub and friends: bodies, initializers,
//                      defaults), false only for a hole-free declaration —
//                      mandatory-present, never omitted
//   - todo           — the §05 §2 @todo presence flag, AST-derived (v3): true
//                      exactly when the declaration carries at least one
//                      `@todo("msg", window)` note (todo_flag); the parsed
//                      message/window stay AST-side — the record carries the
//                      flag only — mandatory-present, never omitted
//   - debug          — the §05 §5 debug-probe directive names, AST-derived
//                      (v3): one lowercase name per parsed probe
//                      ("break"/"log"/"watch"/"trace") in authored order,
//                      never deduped (§28 §4: every outstanding probe
//                      registers); [] on a probe-free decl —
//                      mandatory-present, never omitted
//   - emits          — the signal names this declaration emits (§04)
//   - consumes       — the signal names this declaration consumes (§04)
//   - calls          — the function names this declaration calls
//   - dup_class      — the normalized-AST duplication-class hash (§29 §1, the
//                      gates.odin dup_class hash domain)
//   - mut_data       — the data-type names this declaration mutates (§08)
// The shape is closed and derivation-filled: derive_decl_records
// (index_decl.odin) projects every field from the compiled AST, and
// read_index_project emits the whole stream. Any change to this field set is a
// contract reshape — bump INDEX_SCHEMA_VERSION — and the shape is what the
// `funpack warden` projection decodes against.
Decl_Record :: struct {
	schema_version: int,
	qualified_name: string,
	kind:           Index_Decl_Kind,
	file:           string,
	span:           int,
	doc:            string,
	gtags:          []string,
	stub:           bool,
	todo:           bool,
	debug:          []string,
	emits:          []string,
	consumes:       []string,
	calls:          []string,
	dup_class:      u64,
	mut_data:       []string,
}

// emit_decl_record encodes a `decl` record as one NDJSON line: the compact
// JSON object followed by a single LF, mirroring emit_project_record's
// one-object-per-line transport (spec §29 §2). The struct marshals in
// field-declaration order with enum values as their names (use_enum_names), so
// the schema_version key leads and the kind enum emits as a readable string. No
// map is marshaled — every field is a scalar or a slice — so the bytes are
// deterministic and a double emission of the same record is byte-identical.
emit_decl_record :: proc(record: Decl_Record, allocator := context.allocator) -> string {
	bytes, _ := json.marshal(record, {use_enum_names = true}, context.temp_allocator)
	line := strings.concatenate({string(bytes), "\n"}, allocator)
	return line
}

// Entrypoint_Record is one authored entrypoint's lifted wiring (§14 §4): the
// entrypoint name and the root pipeline ↔ tick ↔ bindings it binds. tick_hz
// is the tick rate in hertz (the `60hz` value carried as its integer rate);
// bindings is the named bindings fn — always present, the §14 grammar
// requires all three keys.
Entrypoint_Record :: struct {
	name:     string,
	pipeline: string,
	tick_hz:  int,
	bindings: string,
}

// Build_Record is one authored emit target (§14 §4/§6): the build name and
// its presentation platform (`desktop`, `wasm`). builds.fcfg carries the
// presentation platform only — no realm field — so a build projects to
// exactly its name and platform.
Build_Record :: struct {
	name:     string,
	platform: string,
}

// Capability is the closed §14 §4 battery set the `project` record reports as
// active. Core render/input/state are always on; the optional batteries
// switch on from their backing source (a non-empty ui/ ⇒ Ui, a non-empty
// models/ ⇒ Modeling, a `net:` entrypoint ⇒ Netcode, an `@expose` ⇒ Modding,
// an `audio:` stage ⇒ Audio). The set is closed and compiler-fixed: a new
// battery is a schema-version bump, never a silently-added string.
Capability :: enum {
	Render,   // core — always on
	Input,    // core — always on
	State,    // core — always on
	Ui,       // non-empty ui/ (§21)
	Modeling, // non-empty models/ (§16)
	Netcode,  // a `net:` in an entrypoint (§25)
	Modding,  // an `@expose` declaration (§27)
	Audio,    // an `audio:` stage (§22)
}

// Gate_Family is the closed set of structural quality gates whose verdicts
// the `project` record reports (spec §29 §1: cyclomatic/nesting/fn-size/arity,
// exhaustiveness, effect-closure, duplication). The set bisects exactly the
// pure-AST structural gates that live in `funpack` — the node-level budget
// gates (gates.odin) and the cross-behavior effect-closure edge check
// (pipeline_flatten.odin). It is closed: a new gate is a schema-version bump.
Gate_Family :: enum {
	Cyclomatic,
	Nesting,
	Fn_Size,
	Arity,
	Exhaustiveness,
	Duplication,
	Effect_Closure,
}

// Gate_Result is one structural gate's verdict line in the `project` record:
// the gate family and whether the source cleared it. The whole vector is
// emitted (every family, passing or not) so the record is exact-match — a
// `funpack warden` reader keys off the family, never a positional index.
Gate_Result :: struct {
	gate:   Gate_Family,
	passed: bool,
}

// Flat_Step_Record is one step of the emitted depth-first flattened total
// order (spec §07 §3): the 0-based ordinal, the owning stage name, and the
// behavior run at this step. It mirrors Flat_Step (pipeline_flatten.odin) as
// the contract's own field-named shape, so the in-memory flatten projects
// straight onto the NDJSON without leaking the internal struct's layout.
Flat_Step_Record :: struct {
	ordinal:  int,
	stage:    string,
	behavior: string,
}

// Project_Record is the closed, exact-match `project` record of the Index
// Contract (spec §29 §2). The field set is fixed and ALL fields are
// mandatory: schema_version (the leading stamp), the AUTHORED entrypoints /
// builds / tag_registry, and the DERIVED capabilities / pipeline_flattened /
// gate_results. Field declaration order IS the emitted JSON key order (a pure
// struct marshal), so schema_version leads. An empty-but-present field (no
// builds, no tags) is a zero-length list, never an omitted key — absence is
// an empty list, never a missing field.
Project_Record :: struct {
	schema_version:     int,
	entrypoints:        []Entrypoint_Record,
	builds:             []Build_Record,
	tag_registry:       []string,
	capabilities:       []Capability,
	pipeline_flattened: []Flat_Step_Record,
	gate_results:       []Gate_Result,
}

// Index_Contract_Error is closed with one arm per way the `project` record's
// authored config can fail to read. The derived fields cannot fail here —
// they project from an already-compiled Typed_Ast and an already-flattened
// pipeline — so every arm names a config-read failure, never a compile error.
Index_Contract_Error :: enum {
	None,
	Missing_Configs_Dir,     // funpack_configs/ is absent — a malformed §14 tree
	Malformed_Entrypoints,   // entrypoints.fcfg is present but does not parse
	Malformed_Builds,        // builds.fcfg is present but does not parse
}

// build_project_record assembles the exact `project` record from the project
// tree and the compiled program. The authored fields read the §14 config
// tree (read-only); the derived fields project from the typed AST and the
// flattened pipeline the prior stages already produced. It never opens a
// clock, a map iteration, or a float, so the record is a pure function of its
// inputs (spec §29 §1) and emits byte-identical on every machine. A
// config-read failure returns before any record is built; the derived inputs
// are trusted (the caller compiled them).
build_project_record :: proc(
	root: string,
	typed: Typed_Ast,
	flat: Flattened_Pipeline,
) -> (record: Project_Record, err: Index_Contract_Error) {
	configs_dir, _ := filepath.join({root, "funpack_configs"}, context.temp_allocator)
	if !os.is_dir(configs_dir) {
		return Project_Record{}, .Missing_Configs_Dir
	}
	entrypoints, entry_err := read_entrypoints(configs_dir)
	if entry_err != .None {
		return Project_Record{}, entry_err
	}
	builds, build_err := read_builds(configs_dir)
	if build_err != .None {
		return Project_Record{}, build_err
	}
	return Project_Record {
			schema_version     = INDEX_SCHEMA_VERSION,
			entrypoints        = entrypoints,
			builds             = builds,
			tag_registry       = read_tag_registry(configs_dir),
			capabilities       = derive_capabilities(root, typed, entrypoints),
			pipeline_flattened = flatten_to_records(flat),
			gate_results       = derive_gate_results(typed, flat),
		},
		.None
}

// emit_project_record encodes a `project` record as one NDJSON line: the
// compact JSON object followed by a single LF (the one-object-per-line
// transport, spec §29 §2). The struct marshals in field-declaration order
// with enum values as their names (use_enum_names), so the schema_version key
// leads and the gate/capability enums emit as readable strings. No map is
// marshaled — every field is a scalar or a slice — so the bytes are
// deterministic and a double emission of the same record is byte-identical.
emit_project_record :: proc(record: Project_Record, allocator := context.allocator) -> string {
	bytes, _ := json.marshal(record, {use_enum_names = true}, context.temp_allocator)
	line := strings.concatenate({string(bytes), "\n"}, allocator)
	return line
}

// flatten_to_records projects the in-memory flattened pipeline onto the
// contract's field-named step shape (spec §07 §3 total order). It is a
// straight per-step copy in flatten order, so the emitted order is the
// depth-first total order with no re-sort.
flatten_to_records :: proc(flat: Flattened_Pipeline) -> []Flat_Step_Record {
	steps := make([]Flat_Step_Record, len(flat.order), context.temp_allocator)
	for step, i in flat.order {
		steps[i] = Flat_Step_Record{ordinal = step.ordinal, stage = step.stage, behavior = step.behavior}
	}
	return steps
}

// derive_gate_results reports every structural gate's verdict (spec §29 §1) in
// the fixed Gate_Family order. The node-level budget gates (cyclomatic,
// nesting, fn-size, arity, exhaustiveness, duplication) read the same
// per-declaration unit set stage_gates folds over; effect-closure reads the
// flattened pipeline's routing graph. Each family's verdict is `did the
// source clear THIS gate`, computed independently so the whole vector is
// reported, not just the first overshoot. The source reaching this stage has
// already passed the gates (the pipeline rejects on the first failure before
// emitting), so on a compiled program every family passes; the per-family
// computation is faithful so a future emit-on-failure path reports the real
// vector.
derive_gate_results :: proc(typed: Typed_Ast, flat: Flattened_Pipeline) -> []Gate_Result {
	units := gate_units(typed.ast)
	sets := closed_variant_sets(typed.ast)
	results := make([]Gate_Result, len(Gate_Family), context.temp_allocator)
	results[Gate_Family.Cyclomatic]     = Gate_Result{gate = .Cyclomatic, passed = !any_unit_fails(units, check_cyclomatic)}
	results[Gate_Family.Nesting]        = Gate_Result{gate = .Nesting, passed = !any_unit_fails(units, check_nesting)}
	results[Gate_Family.Fn_Size]        = Gate_Result{gate = .Fn_Size, passed = !any_unit_fails(units, check_fn_size)}
	results[Gate_Family.Arity]          = Gate_Result{gate = .Arity, passed = !any_unit_fails(units, gate_arity_unit)}
	results[Gate_Family.Exhaustiveness] = Gate_Result{gate = .Exhaustiveness, passed = !any_match_fails(units, sets)}
	results[Gate_Family.Duplication]    = Gate_Result{gate = .Duplication, passed = gate_duplication(units) == .None}
	results[Gate_Family.Effect_Closure] = Gate_Result{gate = .Effect_Closure, passed = !first_unclosed_holds(flat.routes)}
	return results
}

// check_fn_size is the fn-size budget as a per-unit predicate, mirroring the
// in-line check stage_gates runs (a body's flattened statement count must not
// exceed MAX_FN_STATEMENTS). It is factored here so derive_gate_results scores
// the fn-size family through the same any_unit_fails fold as the other
// per-unit gates.
check_fn_size :: proc(unit: Gate_Unit) -> Gate_Error {
	if len(statements_count(unit.body)) > MAX_FN_STATEMENTS {
		return .Fn_Size_Exceeded
	}
	return .None
}

// any_unit_fails reports whether any declaration unit overshoots a per-unit
// gate — the gate family's verdict is the negation. The check is the same
// per-unit predicate stage_gates runs (cyclomatic, nesting, fn-size, arity),
// so a family's project-record verdict and the pipeline's first-error reject
// agree on the same source.
any_unit_fails :: proc(units: []Gate_Unit, check: proc(Gate_Unit) -> Gate_Error) -> bool {
	for unit in units {
		if check(unit) != .None {
			return true
		}
	}
	return false
}

// any_match_fails reports whether any declaration unit holds a non-total match
// (the exhaustiveness gate), proven against the per-file closed variant sets.
// It is the exhaustiveness analogue of any_unit_fails, carrying the closed-set
// table the per-unit match check needs.
any_match_fails :: proc(units: []Gate_Unit, sets: []Closed_Variant_Set) -> bool {
	for unit in units {
		if check_match_exhaustiveness_unit(unit, sets) != .None {
			return true
		}
	}
	return false
}

// first_unclosed_holds reports whether the routing graph has any unclosed
// signal — an emitted signal with no downstream consumer (spec §04 §4 / §07
// §2). It is the effect-closure family's failure predicate; its negation is
// the family's passed verdict.
first_unclosed_holds :: proc(routes: []Signal_Route) -> bool {
	_, unclosed := first_unclosed(routes)
	return unclosed
}

// derive_capabilities computes the active §14 §4 battery set as the contract's
// closed Capability vector. Core render/input/state are always on; the
// optional batteries switch on from their backing source: a non-empty ui/ ⇒
// Ui, a non-empty models/ ⇒ Modeling, a `net:` in any entrypoint ⇒ Netcode, an
// `@expose` declaration ⇒ Modding, an `audio:` pipeline stage ⇒ Audio. The
// derivation is structural — it reads directory presence and the source, never
// a features config (there is none, §14 §4) — and emits in the fixed
// Capability enum order so the vector is deterministic.
derive_capabilities :: proc(root: string, typed: Typed_Ast, entrypoints: []Entrypoint_Record) -> []Capability {
	caps := make([dynamic]Capability, 0, len(Capability), context.temp_allocator)
	// Core batteries are unconditional (§14 §4: render/input/state always on).
	append(&caps, Capability.Render, Capability.Input, Capability.State)
	if dir_is_non_empty(root, "ui") {
		append(&caps, Capability.Ui)
	}
	if dir_is_non_empty(root, "models") {
		append(&caps, Capability.Modeling)
	}
	if any_entrypoint_has_net(entrypoints) {
		append(&caps, Capability.Netcode)
	}
	if source_has_expose(typed.ast) {
		append(&caps, Capability.Modding)
	}
	if source_has_audio_stage(typed.ast) {
		append(&caps, Capability.Audio)
	}
	return caps[:]
}

// dir_is_non_empty reports whether a capability-backing subsystem directory is
// present and holds at least one regular file (§14 §4: present-but-empty ⇒ the
// feature is off; present-and-non-empty ⇒ on). An absent directory is off, so
// the read is closed: a missing ui/ or models/ never errors, it just leaves
// the battery off.
dir_is_non_empty :: proc(root: string, sub: string) -> bool {
	dir, _ := filepath.join({root, sub}, context.temp_allocator)
	if !os.is_dir(dir) {
		return false
	}
	walker := os.walker_create(dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type == .Regular {
			return true
		}
	}
	return false
}

// any_entrypoint_has_net reports whether any entrypoint declares a `net:`
// wiring (§14 §4 / §25: a `net:` switches on netcode). The entrypoint reader
// records the tick/bindings wiring but no net field on the gameplay surface;
// when a future entrypoint carries one, the reader fills it and this predicate
// fires. The gameplay surface declares none, so netcode is off for pong.
any_entrypoint_has_net :: proc(entrypoints: []Entrypoint_Record) -> bool {
	// The entrypoint record carries no net wiring yet (the gameplay surface
	// declares none); a net field on Entrypoint_Record is the seam that turns
	// this on, so it reads false until that field is authored and read.
	return false
}

// source_has_expose reports whether the source declares an `@expose` directive
// (§14 §4 / §27: an `@expose` switches on modding). The gameplay surface
// admits only `@doc`/`@gtag` directives, so no declaration carries an
// `@expose` and modding is off for pong; the predicate is the §27 seam for
// when the directive grammar admits it.
source_has_expose :: proc(ast: Ast) -> bool {
	// `@expose` is not part of the directive grammar the gameplay surface
	// parses (only `@doc`/`@gtag` attach to a declaration), so no AST node
	// records an expose flag and this reads false. It is the modding seam.
	return false
}

// source_has_audio_stage reports whether any pipeline declares an `audio:`
// stage (§14 §4 / §22: an `audio:` stage switches on audio). It reads the
// declared pipeline stages by name, so an authored `audio:` stage turns audio
// on by composition (§14 §5) with no features config. The gameplay surface
// declares no audio stage, so audio is off for pong.
source_has_audio_stage :: proc(ast: Ast) -> bool {
	for pipeline in ast.pipelines {
		for stage in pipeline.stages {
			if stage.name == "audio" {
				return true
			}
		}
	}
	return false
}

// read_entrypoints reads entrypoints.fcfg into the authored entrypoint records
// (§14 §4) through the ONE §14 entrypoints production (parse_entrypoints_fcfg)
// — there is no second grammar here, so a config the compiler would reject is
// never lifted into the contract. An absent file is an empty-but-present field
// (no entrypoints), never an error — the §14 tree may omit it; a present file
// that violates the grammar is Malformed_Entrypoints, never line-skipped. The
// reader is read-only: it parses the authored config and never writes a seam,
// matching §14 §3's import-terminal config rule.
read_entrypoints :: proc(configs_dir: string) -> (entrypoints: []Entrypoint_Record, err: Index_Contract_Error) {
	path, _ := filepath.join({configs_dir, "entrypoints.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return nil, .None
	}
	parsed, parse_err := parse_entrypoints_fcfg(string(bytes))
	if parse_err != .None {
		return nil, .Malformed_Entrypoints
	}
	records, ok := lift_entrypoint_records(parsed)
	if !ok {
		return nil, .Malformed_Entrypoints
	}
	return records, .None
}

// lift_entrypoint_records converts the parsed §14 entrypoints onto the
// contract's record shape, converting each block's `Nhz` tick token to its
// integer rate. Every block lifts — the contract reports all authored
// entrypoints, unlike the emit path's single selection. ok is false when a
// tick passes the grammar's `hz`-suffix check but is not an integer rate
// (`60khz`), the one value error the grammar cannot catch.
lift_entrypoint_records :: proc(parsed: Entrypoints) -> (records: []Entrypoint_Record, ok: bool) {
	lifted := make([]Entrypoint_Record, len(parsed.entrypoints), context.temp_allocator)
	for block, i in parsed.entrypoints {
		hz, parsed_hz := parse_tick_hz(block.tick)
		if !parsed_hz {
			return nil, false
		}
		lifted[i] = Entrypoint_Record {
			name     = block.name,
			pipeline = block.pipeline,
			tick_hz  = hz,
			bindings = block.bindings,
		}
	}
	return lifted, true
}

// read_builds reads builds.fcfg into the authored build records (§14 §4/§6):
// each `build <name> { platform = … }` block's presentation platform. An
// absent file is an empty-but-present field (no builds), never an error. Like
// read_entrypoints it is scoped to the platform field the `project` record
// carries and is read-only.
read_builds :: proc(configs_dir: string) -> (builds: []Build_Record, err: Index_Contract_Error) {
	path, _ := filepath.join({configs_dir, "builds.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return nil, .None
	}
	records := make([dynamic]Build_Record, 0, 2, context.temp_allocator)
	blocks := fcfg_blocks(string(bytes), "build")
	for block in blocks {
		record := Build_Record{name = block.label}
		for assignment in block.assignments {
			if assignment.key == "platform" {
				record.platform = assignment.value
			}
		}
		if record.platform == "" {
			return nil, .Malformed_Builds
		}
		append(&records, record)
	}
	return records[:], .None
}

// read_tag_registry reads tags.fcfg into the authored @gtag registry (§14 §4):
// the bare identifiers inside the single `tags { … }` block. The registry is
// emitted in authored order — the order the tags are listed — so the field is
// deterministic and never re-sorted. An absent file is an empty-but-present
// registry (no tags), never an error.
read_tag_registry :: proc(configs_dir: string) -> []string {
	path, _ := filepath.join({configs_dir, "tags.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return nil
	}
	return fcfg_tag_list(string(bytes))
}

// Fcfg_Assignment is one `key = value` line inside an fcfg block. The value is
// the bare token after `=` (an identifier, a platform name, a `60hz` rate) —
// the smaller config grammar carries bare values, not the string literals the
// project.fcfg reader expects, so the project-record readers take the value
// verbatim and interpret it per field.
Fcfg_Assignment :: struct {
	key:   string,
	value: string,
}

// Fcfg_Block is one `<keyword> <label> { … }` block of the smaller config
// grammar (§14 §2): the block label and its `key = value` assignments. A `use`
// reference line, an `@doc` directive, and blank lines are not blocks and are
// skipped, so the reader sees only the authored declaration blocks.
Fcfg_Block :: struct {
	label:       string,
	assignments: []Fcfg_Assignment,
}

// fcfg_blocks reads every `<keyword> <label> { … }` block of a given keyword
// from an fcfg source into its label and `key = value` assignments. The reader
// is line-oriented over the §14 smaller config grammar: a block opens on a line
// whose first token is the keyword (the label is the second token), each body
// line is one `key = value` assignment until the closing `}`, and a leading
// `use mod.{…}` reference and `@doc` directives are skipped. It serves the
// configs with no validated production of their own (builds.fcfg) —
// entrypoints.fcfg rides parse_entrypoints_fcfg, the one entrypoints grammar.
fcfg_blocks :: proc(content: string, keyword: string) -> []Fcfg_Block {
	blocks := make([dynamic]Fcfg_Block, 0, 2, context.temp_allocator)
	lines := strings.split_lines(content, context.temp_allocator)
	i := 0
	for i < len(lines) {
		fields := fcfg_line_fields(lines[i])
		if len(fields) >= 2 && fields[0] == keyword {
			block := Fcfg_Block{label = fields[1]}
			block.assignments, i = fcfg_block_body(lines, i + 1)
			append(&blocks, block)
			continue
		}
		i += 1
	}
	return blocks[:]
}

// fcfg_block_body reads a block's `key = value` assignment lines from `start`
// up to and including the closing `}`, returning the assignments and the index
// one past the `}`. A line that is neither an assignment nor the closer (an
// `@doc`, a blank line) is skipped, so only the authored wiring is collected.
fcfg_block_body :: proc(lines: []string, start: int) -> (assignments: []Fcfg_Assignment, next: int) {
	pairs := make([dynamic]Fcfg_Assignment, 0, 4, context.temp_allocator)
	i := start
	for i < len(lines) {
		trimmed := strings.trim_space(lines[i])
		i += 1
		if trimmed == "}" {
			break
		}
		if key, value, ok := fcfg_assignment(trimmed); ok {
			append(&pairs, Fcfg_Assignment{key = key, value = value})
		}
	}
	return pairs[:], i
}

// fcfg_assignment parses one `key = value` line into its key and bare value.
// ok is false for a line without `=` (an `@doc`, a `use` reference, the `{`/`}`
// braces), which the block reader skips. The value is the trimmed token after
// `=`, taken verbatim (a bare identifier or `60hz` rate, never a quoted
// literal in the smaller config grammar's block bodies).
fcfg_assignment :: proc(line: string) -> (key: string, value: string, ok: bool) {
	eq := strings.index_byte(line, '=')
	if eq < 0 {
		return "", "", false
	}
	key = strings.trim_space(line[:eq])
	value = strings.trim_space(line[eq + 1:])
	if key == "" || value == "" {
		return "", "", false
	}
	return key, value, true
}

// fcfg_tag_list reads the bare identifiers inside the single `tags { … }` block
// (§14 §4): each non-brace body line is one registered tag, in authored order.
// A line outside the block, the `tags {` opener, and the `}` closer are not
// tags. It returns the tags in listed order, never re-sorted, so the registry
// field is deterministic.
fcfg_tag_list :: proc(content: string) -> []string {
	lines := strings.split_lines(content, context.temp_allocator)
	tags := make([dynamic]string, 0, 8, context.temp_allocator)
	in_block := false
	for line in lines {
		trimmed := strings.trim_space(line)
		if !in_block {
			fields := fcfg_line_fields(trimmed)
			if len(fields) >= 1 && fields[0] == "tags" {
				in_block = true
			}
			continue
		}
		if trimmed == "}" {
			break
		}
		if trimmed != "" && trimmed != "{" {
			append(&tags, trimmed)
		}
	}
	return tags[:]
}

// fcfg_line_fields splits an fcfg line on whitespace into its tokens, dropping
// a trailing `{` so a block-opener line (`entrypoint main {`) yields just the
// keyword and label. It is the line tokenizer the block reader keys off — the
// smaller config grammar has no statement terminator, so a token split on
// whitespace is sufficient for the opener lines the reader inspects.
fcfg_line_fields :: proc(line: string) -> []string {
	trimmed := strings.trim_space(line)
	raw := strings.fields(trimmed, context.temp_allocator)
	fields := make([dynamic]string, 0, len(raw), context.temp_allocator)
	for token in raw {
		if token == "{" {
			continue
		}
		append(&fields, token)
	}
	return fields[:]
}

// Index_Module is one §14 source module compiled for the Index Contract: its
// §15 path-derived module name and the typed AST + flattened pipeline BOTH
// record kinds' derived fields read. The whole-project index builds one of these
// per source — the `project` record reads the entrypoint module's pair, every
// module's pair feeds its own `decl` block — so the multi-module stream is a fan
// of per-module derivations off ONE project-wide module index.
Index_Module :: struct {
	module: string,
	typed:  Typed_Ast,
	flat:   Flattened_Pipeline,
}

// read_index_project reads the §14 project tree and emits the WHOLE Index
// Contract NDJSON stream (spec §29 §2): the `project` record on line 1, then per
// module a block of `decl` records in the fixed gate_units-style declaration
// order (derive_decl_records). It is the end-to-end seam over EVERY project
// source: it builds ONE project-wide module index (build_module_index_typed, the
// run_project_pipeline precedent) so a multi-module tree (the arena example:
// arena_world + the arena seam + arena_game) types cross-module, then derives
// each module's typed AST + flattened pipeline against that one index — the same
// build feeding both products' source-derived fields. The `project` record reads
// the ENTRYPOINT module's pair (the `use <module>` clause of entrypoints.fcfg);
// a package (no entrypoints.fcfg, §30 §7) has no entrypoint, so its `project`
// record reads the first module's pair (sorted-by-path, the §15 module the
// `project` record's source-derived fields project from). A malformed tree or
// ANY module's compile error returns before emission — the records are facts
// about a tree that compiles, so a tree that does not is not indexed here. The
// stream is byte-stable (project line, then per-module decl blocks in fixed
// module order, no map/clock/float), so two reads of the same tree are
// byte-identical.
//
// MODULE-QUALIFICATION (lore #11): a SINGLE-module project's decls stay BARE —
// the bare module name "" qualifies each decl to its bare name (`Board`), so a
// single-module game's index bytes are unchanged from the pre-multi-module seam
// (the green-four byte-identity floor). A MULTI-module project qualifies each
// decl by its §15 module name (`arena_game.chase`), the §29 §2 module-qualified
// name, so a cross-module index disambiguates a name two modules both declare.
read_index_project :: proc(root: string, allocator := context.allocator) -> (ndjson: string, err: Index_Contract_Error, compiled: bool) {
	identity, project_err := read_project(root)
	if project_err != .None {
		return "", .Missing_Configs_Dir, false
	}
	if len(identity.sources) == 0 {
		return "", .None, false
	}
	index_modules, ok := compile_index_modules(identity.sources)
	if !ok {
		return "", .None, false
	}
	// A single-module project's one decl block stays bare (lore #11): blank the
	// module so each decl qualifies to its bare name, keeping the single-module
	// index bytes byte-identical to the pre-multi-module seam. A multi-module
	// project keeps each module's §15 name, so its decls qualify cross-module.
	if len(index_modules) == 1 {
		index_modules[0].module = ""
	}
	// MODULE ORDER: the entrypoint module's decl block leads, then the remaining
	// modules in Project.sources order (merge_sources' sorted-by-path order). A
	// package has no entrypoint, so its blocks emit in plain sources order. The
	// entrypoint module's typed+flat back the `project` record's source-derived
	// fields (pipeline_flattened, capabilities, gate_results); for a package the
	// first module's pair backs them (no pipeline ⇒ empty pipeline_flattened).
	entrypoint := entrypoint_module_name(root)
	ordered := order_index_modules(index_modules, entrypoint)
	record_src := ordered[0]
	record, record_err := build_project_record(root, record_src.typed, record_src.flat)
	if record_err != .None {
		return "", record_err, false
	}
	return emit_index_stream(record, ordered, allocator), .None, true
}

// compile_index_modules builds one project-wide module index over EVERY §14
// source (build_module_index_typed) and derives each module's typed AST +
// flattened pipeline against it — the single index build the whole-project Index
// Contract fans both products off. It mirrors run_project_pipeline's two-phase
// shape: phase 1 reads + parses every source so the index sees the whole export
// surface; phase 2 types each module index-aware (a cross-module import resolves)
// and flattens it. ok is false on the first read/parse/typecheck/flatten failure
// — a tree with any uncompilable module has no derived shape to index, the same
// all-or-nothing floor the test verb honors (§29 §3). An empty index reduces the
// per-module typecheck to the single-source path, so a one-module tree types
// exactly as before.
compile_index_modules :: proc(sources: []Source) -> (modules: []Index_Module, ok: bool) {
	module_names := make([]string, len(sources), context.temp_allocator)
	asts := make([]Ast, len(sources), context.temp_allocator)
	for source, i in sources {
		bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
		if read_err != nil {
			return nil, false
		}
		ast, parse_err := stage_parse(stage_lex(string(bytes)))
		if parse_err != .None {
			return nil, false
		}
		module_names[i] = source.module
		asts[i] = ast
	}
	index := build_module_index_typed(module_names, asts)
	derived := make([]Index_Module, len(sources), context.temp_allocator)
	for ast, i in asts {
		typed, type_err := stage_typecheck_indexed(ast, index)
		if type_err != .None {
			return nil, false
		}
		verdict := stage_flatten(typed)
		if verdict.err != .None {
			return nil, false
		}
		derived[i] = Index_Module{module = module_names[i], typed = typed, flat = verdict.flat}
	}
	return derived, true
}

// order_index_modules orders the compiled modules for emission: the entrypoint
// module first (when `entrypoint` names a module in the set), then the remaining
// modules in their original Project.sources order (sorted-by-path). This is the
// pinned module-order rule the multi-module `decl` stream emits in and the
// `project` record's source-derived fields read off ordered[0]. An empty or
// unmatched `entrypoint` (a package, §30 §7) leaves the plain sources order, so
// the package stream's blocks follow the source set verbatim. The reorder is a
// pure index permutation (entrypoint_first_order) — no re-sort of the source
// list, no map — so the order is deterministic for a given tree.
order_index_modules :: proc(modules: []Index_Module, entrypoint: string) -> []Index_Module {
	names := make([]string, len(modules), context.temp_allocator)
	for m, i in modules {
		names[i] = m.module
	}
	ordered := make([]Index_Module, len(modules), context.temp_allocator)
	for src, dst in entrypoint_first_order(names, entrypoint) {
		ordered[dst] = modules[src]
	}
	return ordered
}

// entrypoint_first_order is THE single entrypoint-first ordering rule, expressed
// as a pure index permutation over the §15 module names: the index of the module
// `entrypoint` names comes first (when it is in the set), then the remaining
// indices in their original order. An empty or unmatched entrypoint (a package,
// §30 §7) yields the identity permutation. Both consumers apply this one rule —
// order_index_modules permutes the compiled modules the `decl` stream emits, and
// order_release_sources (build.odin) permutes the sources the release-refusal
// walkers scan — so the refusal's named offender is always the first offender in
// the emitted index's module order, never a sorted-by-path artifact.
entrypoint_first_order :: proc(module_names: []string, entrypoint: string) -> []int {
	order := make([dynamic]int, 0, len(module_names), context.temp_allocator)
	if entrypoint != "" {
		for name, i in module_names {
			if name == entrypoint {
				append(&order, i)
				break
			}
		}
	}
	for name, i in module_names {
		if entrypoint != "" && name == entrypoint {
			continue
		}
		append(&order, i)
	}
	return order[:]
}

// entrypoint_module_name reads the §15 module the entrypoints.fcfg `use <module>`
// clause names (§14 §4) — the module whose pipeline the runtime artifact emits
// and whose source-derived fields the `project` record reads. An absent
// entrypoints.fcfg (a package, §30 §7) or one that does not parse returns "" —
// there is no entrypoint module to privilege, so the multi-module stream emits in
// plain sources order. It reads only the `use` clause, never the entrypoint
// blocks, so a malformed block (a value error the grammar catches downstream)
// does not change the module the stream privileges.
entrypoint_module_name :: proc(root: string) -> string {
	path, _ := filepath.join({root, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return ""
	}
	parsed, parse_err := parse_entrypoints_fcfg(string(bytes))
	if parse_err != .None {
		return ""
	}
	return parsed.use_module
}

// emit_index_stream concatenates the whole Index Contract NDJSON stream from the
// compiled modules: the `project` record line first, then per module a block of
// `decl` record lines in the fixed gate_units-style order (derive_decl_records).
// The modules emit in the order order_index_modules pinned — entrypoint module
// first, then the remaining in sources order — and each decl is qualified by its
// §15 module name (qualify_decl), so a multi-module stream's qualified_names are
// `<module>.<name>` while a bare module name "" stays the bare decl name. Each
// record marshals to its own one-object-per-line NDJSON via the shared emitters
// and the lines join in emission order, so the stream is a byte-stable
// concatenation — no re-sort, no map, no clock — and a double emission of the
// same tree is byte-identical. The per-line strings are temp-allocated and the
// joined result lands in `allocator`, matching emit_project_record's allocation
// contract.
emit_index_stream :: proc(
	record: Project_Record,
	modules: []Index_Module,
	allocator := context.allocator,
) -> string {
	lines := make([dynamic]string, 0, 1 + total_decl_count(modules), context.temp_allocator)
	append(&lines, emit_project_record(record, context.temp_allocator))
	for m in modules {
		decls := derive_decl_records(m.module, m.typed, m.flat)
		for decl in decls {
			append(&lines, emit_decl_record(decl, context.temp_allocator))
		}
	}
	return strings.concatenate(lines[:], allocator)
}

// total_decl_count sums the declaration count across every compiled module — the
// exact capacity for the stream's line vector (one project line plus this many
// decl lines), so the concatenation makes no extra allocation.
total_decl_count :: proc(modules: []Index_Module) -> int {
	total := 0
	for m in modules {
		total += decl_count(m.typed.ast)
	}
	return total
}

// compile_for_index drives a SINGLE source through the lex → parse → typecheck →
// flatten stages the `project` record's derived fields read, returning the typed
// AST and the flattened pipeline. It is the single-source projection (empty
// module index, bare module name "") the decl-derivation tests drive directly;
// the whole-project seam uses compile_index_modules so a cross-module import
// resolves. compiled is false on any parse, typecheck, or flatten failure — the
// gate stage is intentionally not a hard stop here (the gate VERDICTS are a
// derived field, so a gated source still has a `project` record to emit), but a
// source that fails to parse, type, or flatten has no derived shape to project.
compile_for_index :: proc(source: string) -> (typed: Typed_Ast, flat: Flattened_Pipeline, compiled: bool) {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return Typed_Ast{}, Flattened_Pipeline{}, false
	}
	typed_ast, type_err := stage_typecheck(ast)
	if type_err != .None {
		return Typed_Ast{}, Flattened_Pipeline{}, false
	}
	verdict := stage_flatten(typed_ast)
	if verdict.err != .None {
		return Typed_Ast{}, Flattened_Pipeline{}, false
	}
	return typed_ast, verdict.flat, true
}

// index_capabilities_contains reports whether a capability vector holds a
// given battery — a verification helper for the exact derived-capability set,
// not a runtime path. The vector is small and order-fixed, so a linear scan is
// the whole lookup.
index_capabilities_contains :: proc(caps: []Capability, cap: Capability) -> bool {
	return slice.contains(caps, cap)
}
