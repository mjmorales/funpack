// The project-wide module index and the user-module import arm that rides on
// it. The frontend was single-source: resolve_imports validated every import
// against STDLIB_SURFACE alone (surface.odin), so an `import arena_world.{Player}`
// referencing a SIBLING user module returned .Unknown_Module. A multi-module
// project (the arena example: arena_game.fun imports both arena_world and the
// generated arena seam) needs a project-wide name index built over EVERY source
// before per-module resolution, so a member-group or dotted import whose leading
// segments name a user module resolves its members against that module's
// exported names.
//
// The index is a closed two-position view of each module's surface (spec §15:
// a module's name is its §15 path-derived location, and its exports are its
// top-level declarations): the type-position names (data/enum/thing/singleton/
// signal) and the term-position names (top-level fn). It is built once from
// []Source and threaded through the resolver alongside STDLIB_SURFACE; an
// unknown user module, an unknown member of a known user module, and a name
// colliding with an in-scope import all stay compile errors (spec §02
// one-name-one-meaning), exactly as the stdlib arm enforces them.
//
// Determinism: every module entry stores its exports as ORDERED slices, walked
// by index — no map is ever iterated (the determinism tripwire), mirroring
// STDLIB_SURFACE and Bindings. The module list is keyed by name and looked up
// by a linear walk, the same shape surface_module uses over the partition table.
package funpack

import "core:os"

// Module_Export_Kind is the closed three-position view the index records for
// each exported name: a type-position name (a data/enum/thing/singleton/signal
// declaration), a term-position fn name (a top-level fn), or a term-position
// const name (a module-level `let`). It maps 1:1 onto the Decl_Kind a resolved
// Binding carries — a type export binds as .Type_Name, a fn export as .Func, a
// const export as .Value — so a user-module import (a member group, a dotted
// member, or a whole-module handle's `module.NAME` access) populates Bindings
// identically to a stdlib import.
Module_Export_Kind :: enum {
	Type,  // a data/enum/thing/singleton/signal declaration — a type-position name
	Term,  // a top-level fn declaration — a term-position name
	Const, // a module-level `let NAME: T = expr` — a term-position value name
}

// Module_Export pairs one exported name with its position. The position is read
// when the resolver binds the name, so a cross-module type reference (a field's
// Ref[T] naming a sibling-module type) resolves to a type-position binding while
// a fn reference resolves to a term-position binding. user_kind carries the §06
// declaration form of a .Type export (Thing/Data/Enum/Signal) so a cross-module
// type reference resolves to a nominal User_Type with the right kind; it is
// meaningless (.Thing as a placeholder) for a .Term/.Const export. signature
// carries the resolved fn signature of a .Term fn export so a CONSUMER can type a
// cross-module CALL (`arena_spawns() -> [Spawn]` in arena_game's setup). let_type
// carries the resolved DECLARED type of a .Const let export so a CONSUMER can type
// a module-qualified const reference (`assets.coin_sfx` types as SoundHandle).
// Both the signature and let_type are filled only by build_module_index_typed,
// which resolves each module's own env; the name-only index
// (build_module_index_from_asts) leaves them nil. exposed carries the §05 §4
// `@expose` marker off the declaration — the package-edge visibility fact:
// within a project it is recorded but never consulted (public-by-default,
// spec §15 §4); across a package edge an export is importable iff it is true
// (spec §30 §6).
Module_Export :: struct {
	name:      string,
	kind:      Module_Export_Kind,
	user_kind: User_Kind,   // the §06 form of a .Type export; unused for a .Term/.Const
	signature: ^Func_Type,  // the resolved signature of a .Term fn export; nil otherwise
	let_type:  Type,        // the resolved declared type of a .Const let export; nil otherwise
	exposed:   bool,        // the declaration carries §05 §4 @expose — importable across a package edge (spec §30 §6)
}

// Module_Record_Schema pairs one exported RECORD type's name with its resolved
// field schema (field name → type). It is the cross-module field surface a
// CONSUMER needs to type a record-member read (`s.on` on an imported Switch), a
// record literal (`Switch{pos:…, on:…}`), or a `with` update on a sibling-module
// record. The name-only index leaves record_schemas empty — only
// build_module_index_typed, which resolves each module's own env, fills it.
Module_Record_Schema :: struct {
	name:   string,
	schema: Record_Schema,
}

// Module_Enum_Schema pairs one exported ENUM type's name with its resolved
// Enum_Schema (variant set + per-variant tuple-payload types). It is the
// cross-module VARIANT-VALUE surface a CONSUMER needs to type an imported enum's
// variant used as a value — `Screen::Pause` in a `with`-update RHS, the §21 §3
// variant-as-function value `AppMsg::Hud` a `.map(AppMsg::Hud)` re-tags through,
// and a `match`-arm binder over an imported tagged union (`AppMsg::Hud(m)`). The
// enum analogue of Module_Record_Schema: an enum carries no fields, so it
// contributes a variant schema, not a record one. The name-only index leaves
// enum_schemas empty — only build_module_index_typed, which resolves each
// module's own env, fills it.
Module_Enum_Schema :: struct {
	name:   string,
	schema: Enum_Schema,
}

// Module_Entry is one user module's exported surface: its §15 path-derived
// module name, the ORDERED export list (source order within each kind, type
// exports before term exports), and the resolved record schemas of its exported
// record types (the cross-module field surface). The lists are walked by index —
// never a map — so the resolver's verdict is reproducible from the source set
// alone.
//
// package_root distinguishes the two §15 §4 visibility boundaries: "" is a
// WITHIN-PROJECT module (public-by-default — the exposed flag is never
// consulted); a non-empty root names the §30 dependency whose project name is
// the entry's root namespace (spec §30 §7: `hexgrid.layout` roots at
// `hexgrid`), and every import resolving through such an entry crosses the
// package edge — importable iff the export is @expose'd, Package_Private
// otherwise. Any import that resolves through a prefixed package entry is a
// cross-edge import by construction: within the package itself modules root
// UNPREFIXED at the package's own source root (spec §15 §5), so a
// package-internal import never names the prefixed entry.
Module_Entry :: struct {
	module:         string,
	package_root:   string,
	exports:        []Module_Export,
	record_schemas: []Module_Record_Schema,
	enum_schemas:   []Module_Enum_Schema,
}

// Module_Index is the project-wide name index: one Module_Entry per user module,
// keyed by module name and looked up by a linear walk (module_index_lookup). It
// is the user-module analogue of STDLIB_SURFACE — the closed table the
// user-module import arm resolves members against. An empty index (the
// single-source case) makes every user-module import a .Unknown_Module reject,
// which is the prior single-source behavior.
Module_Index :: struct {
	modules: []Module_Entry,
}

// Module_Index_Error is closed with one arm per way building the index can fail
// before any module resolves. Read_Failed is a source file the index cannot read
// off disk; Parse_Failed is a source whose bytes the §06/§07 grammar rejects.
// Both fail the whole index build — a project with an unreadable or unparseable
// source has no well-defined name surface, so resolution never proceeds against
// a partial index.
Module_Index_Error :: enum {
	None,
	Read_Failed,
	Parse_Failed,
}

// build_module_index reads every source in the set, lexes and parses each, and
// records its top-level declaration names into the per-module export list. It is
// name-and-position only: no body is typed and no import is resolved — the index
// is the input the resolver consults, built before any per-module resolution.
// The entries preserve the source order of []Source (project.odin sorts paths
// for determinism), so the index is reproducible from the tree alone. A source
// that cannot be read or parsed fails the whole build (Module_Index_Error).
build_module_index :: proc(sources: []Source) -> (index: Module_Index, err: Module_Index_Error) {
	entries := make([dynamic]Module_Entry, 0, len(sources), context.temp_allocator)
	for source in sources {
		source_bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
		if read_err != nil {
			return Module_Index{}, .Read_Failed
		}
		ast, parse_err := stage_parse(stage_lex(string(source_bytes)))
		if parse_err != .None {
			return Module_Index{}, .Parse_Failed
		}
		append(&entries, Module_Entry{module = source.module, exports = collect_module_exports(ast)})
	}
	return Module_Index{modules = entries[:]}, .None
}

// build_module_index_from_asts builds the index directly from already-parsed
// (module, Ast) pairs, the unit-test seam that needs no on-disk reads — a
// hand-built stand-in for a not-yet-generated seam module (the arena seam) joins
// the index alongside the real, file-backed sources. It shares collect_module_exports
// with build_module_index, so a stand-in entry carries the identical export shape
// a file-backed entry would. package_roots, when given, runs in lockstep with
// modules and stamps each entry's §30 package_root ("" = within-project) — the
// seam the deps.fcfg resolution story constructs package entries through; nil
// (the default) leaves every entry within-project, the prior behavior.
build_module_index_from_asts :: proc(modules: []string, asts: []Ast, package_roots: []string = nil) -> Module_Index {
	entries := make([dynamic]Module_Entry, 0, len(asts), context.temp_allocator)
	for ast, i in asts {
		append(&entries, Module_Entry {
			module       = modules[i],
			package_root = package_roots[i] if package_roots != nil else "",
			exports      = collect_module_exports(ast),
		})
	}
	return Module_Index{modules = entries[:]}
}

// build_module_index_typed builds the project-wide index over already-parsed
// (module, Ast) pairs AND records each exported fn's resolved signature, the form
// a CONSUMER's typecheck needs to type a cross-module CALL (`arena_spawns() ->
// [Spawn]`). It is the two-pass index the multi-module project pipeline builds:
// pass 1 collects the name-only entries (build_module_index_from_asts) so every
// module's exports are visible; pass 2 resolves each module's own imports + env
// against that name index and copies the resolved fn signature onto each .Term
// export. The name pass runs first because a module's signature may reference a
// sibling module's exported type (a fn returning a cross-module record), so the
// whole name surface must be visible before any signature resolves. A module that
// fails to resolve its own imports/env is left with nil-signature exports — the
// per-module typecheck surfaces the error precisely, so the index never aborts the
// whole build over one module's resolution failure. package_roots, when given,
// runs in lockstep with modules and stamps each entry's §30 package_root
// (build_module_index_from_asts's seam); nil leaves every entry within-project.
build_module_index_typed :: proc(modules: []string, asts: []Ast, package_roots: []string = nil) -> Module_Index {
	name_index := build_module_index_from_asts(modules, asts, package_roots)
	entries := make([dynamic]Module_Entry, 0, len(asts), context.temp_allocator)
	for ast, i in asts {
		exports := collect_module_exports(ast)
		record_schemas, enum_schemas := fill_export_types(&exports, ast, name_index)
		append(&entries, Module_Entry {
			module         = modules[i],
			package_root   = package_roots[i] if package_roots != nil else "",
			exports        = exports,
			record_schemas = record_schemas,
			enum_schemas   = enum_schemas,
		})
	}
	return Module_Index{modules = entries[:]}
}

// fill_export_types resolves one module's own imports + env against the
// project-wide NAME index and lifts the resolved types a CONSUMER needs into the
// index: each .Term fn export's signature is copied onto its export (the
// cross-module CALL surface), each .Const let export's declared type is copied
// onto its export (the cross-module CONST surface — `assets.coin_sfx` types as
// SoundHandle), each exported RECORD type's resolved field schema is collected
// (the cross-module FIELD surface — a member read, a literal, a `with` on a
// sibling-module record), and each exported ENUM type's resolved variant schema
// is collected (the cross-module VARIANT-VALUE surface — `Screen::Pause` as a
// value, `AppMsg::Hud` as a variant-as-function value, an imported tagged-union
// match binder). It is the typed half of build_module_index_typed; the name pass
// already ran, so a cross-module type a signature/const/field/payload references
// is visible. A module whose imports or env do not resolve leaves its export
// signatures and let types nil and its record/enum schema sets empty — that
// module's own typecheck reports the real error.
fill_export_types :: proc(
	exports: ^[]Module_Export,
	ast: Ast,
	name_index: Module_Index,
) -> (
	record_schemas: []Module_Record_Schema,
	enum_schemas: []Module_Enum_Schema,
) {
	bindings, bind_err := resolve_imports_indexed(ast, name_index)
	if bind_err != .None {
		return nil, nil
	}
	env, env_err := resolve_env(ast, bindings, name_index)
	if env_err != .None {
		return nil, nil
	}
	for &export in exports {
		#partial switch export.kind {
		case .Term:
			if term, found := env_term_name(env, export.name); found {
				export.signature = term.signature
			}
		case .Const:
			// A let's resolve_env Term_Schema carries its declared type — the
			// cross-module reference grounds to the same Type the owning module's
			// own name_check returns for the bare name.
			if term, found := env_term_name(env, export.name); found {
				export.let_type = term.type
			}
		}
	}
	records := make([dynamic]Module_Record_Schema, 0, 8, context.temp_allocator)
	enums := make([dynamic]Module_Enum_Schema, 0, 8, context.temp_allocator)
	for &export in exports {
		if export.kind != .Type {
			continue
		}
		// A record-shaped type (thing/data/signal) carries a field schema; an enum
		// carries a variant schema instead — the two cross-module surfaces are
		// disjoint, so each type contributes to exactly one set.
		if record, declared := env.records[export.name]; declared {
			append(&records, Module_Record_Schema{name = export.name, schema = record})
		}
		if enum_schema, declared := env.enums[export.name]; declared {
			append(&enums, Module_Enum_Schema{name = export.name, schema = enum_schema})
		}
	}
	return records[:], enums[:]
}

// module_call_signature resolves the signature of a name an import bound to a
// sibling user module's fn — the cross-module CALL surface (`arena_spawns()` in
// arena_game's setup resolves to the `arena` seam's `extern fn arena_spawns() ->
// [Spawn]`). It mirrors index_user_type for the term position: the name must bind
// to a sibling module as a .Func, that module must be in the index, and the export
// must be a .Term carrying a resolved signature. found = false leaves the call-site
// check to fall through to the stdlib/combinator arms, so a name that is not a
// cross-module fn is untouched.
module_call_signature :: proc(index: Module_Index, bindings: Bindings, name: string) -> (signature: ^Func_Type, found: bool) {
	binding, bound := bindings.names[name]
	if !bound || binding.kind != .Func {
		return nil, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return nil, false
	}
	export, exported := module_export_lookup(entry, name)
	if !exported || export.kind != .Term || export.signature == nil {
		return nil, false
	}
	return export.signature, true
}

// module_const_type resolves the declared type of a module-qualified const
// reference — the cross-module CONST surface a consumer reads to type
// `assets.coin_sfx` (a whole-module `import assets` handle, then a `.coin_sfx`
// member). It is the term-position analogue of module_record_schema for the
// whole-module access route: the receiver name (`assets`) must bind to a sibling
// module as a .Module handle, that module must be in the index, and the named
// member must be a .Const export carrying a resolved let type. found = false
// leaves the member check to its other arms (a non-module receiver, a member that
// is not a const), so a record/enum/fn member of a module handle is untouched. The
// CONSUMER passes its own bindings so the handle's OWNING module is recovered from
// the .Module binding (spec §02 — the binding carries the source of the name's
// meaning), exactly as module_call_signature/module_record_schema do.
module_const_type :: proc(index: Module_Index, bindings: Bindings, handle: string, member: string) -> (type: Type, found: bool) {
	binding, bound := bindings.names[handle]
	if !bound || binding.kind != .Module {
		return nil, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return nil, false
	}
	export, exported := module_export_lookup(entry, member)
	if !exported || export.kind != .Const {
		return nil, false
	}
	return export.let_type, true
}

// module_member_kind reports the export kind of a member reached through a
// whole-module `.Module` handle (`assets.NAME`), distinguishing an UNKNOWN member
// of a known user module (found = false, exported = false) from a known member
// that simply is not a const (found = true, exported = true, kind set). The
// member_check uses it to raise the precise .Unknown_Member diagnostic for a
// mistyped member of a user-module handle rather than the generic .Unsupported_Expr
// — the same closed-surface rejection module_export_lookup enforces for a member
// group. handle_known reports whether the receiver bound to a user module at all.
// importable carries the §15 §4 visibility verdict (module_export_importable —
// the same predicate the import resolver gates through), meaningful only when
// exported: a handle-member access is the one route that reaches an export
// without an importing declaration, so the package edge gates here too (spec
// §30 §6) — module_member_check raises .Package_Private off it.
module_member_kind :: proc(index: Module_Index, bindings: Bindings, handle: string, member: string) -> (kind: Module_Export_Kind, exported: bool, handle_known: bool, importable: bool) {
	binding, bound := bindings.names[handle]
	if !bound || binding.kind != .Module {
		return {}, false, false, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return {}, false, false, false
	}
	export, found := module_export_lookup(entry, member)
	if !found {
		return {}, false, true, false
	}
	return export.kind, true, true, module_export_importable(entry, export)
}

// module_record_schema resolves the field schema of a RECORD type an import bound
// to a sibling user module — the cross-module FIELD surface a consumer reads to
// type `s.on` on an imported Switch, a `Switch{…}` literal, or a `self with {…}`
// over an imported record. It mirrors module_call_signature for the type position:
// the name must bind to a sibling module as a .Type_Name, that module must be in
// the index, and the module must carry a record schema for the name. found = false
// leaves the field/literal/with check to its local-env arm, so a local record (or
// a non-record type) is untouched. The CONSUMER passes its own bindings so the
// name's OWNING module is recovered from the binding (spec §02 one-name-one-
// meaning — the binding carries the source of the name's meaning).
module_record_schema :: proc(index: Module_Index, bindings: Bindings, name: string) -> (schema: Record_Schema, found: bool) {
	binding, bound := bindings.names[name]
	if !bound || binding.kind != .Type_Name {
		return Record_Schema{}, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return Record_Schema{}, false
	}
	for candidate in entry.record_schemas {
		if candidate.name == name {
			return candidate.schema, true
		}
	}
	return Record_Schema{}, false
}

// module_enum_schema resolves the variant schema of a name an import bound to a
// sibling user module's ENUM — the cross-module VARIANT-VALUE surface a CONSUMER
// needs to type an imported enum's variant used as a value: `Screen::Pause` in a
// `with`-update RHS, the §21 §3 variant-as-function value `AppMsg::Hud` a
// `.map(AppMsg::Hud)` re-tags through, and an imported tagged-union match binder
// (`AppMsg::Hud(m)`). It mirrors module_record_schema for the enum position: the
// name must bind to a sibling module as a .Type_Name, that module must be in the
// index, and the module must carry an enum schema for the name. found = false
// leaves the variant check to its local-env arm, so a local enum (or a non-enum
// type) is untouched. The CONSUMER passes its own bindings so the name's OWNING
// module is recovered from the binding (spec §02 one-name-one-meaning).
module_enum_schema :: proc(index: Module_Index, bindings: Bindings, name: string) -> (schema: Enum_Schema, found: bool) {
	binding, bound := bindings.names[name]
	if !bound || binding.kind != .Type_Name {
		return Enum_Schema{}, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return Enum_Schema{}, false
	}
	for candidate in entry.enum_schemas {
		if candidate.name == name {
			return candidate.schema, true
		}
	}
	return Enum_Schema{}, false
}

// collect_module_exports lifts a parsed module's top-level declarations into its
// ordered export list: every type-position declaration (data/enum/thing/
// singleton/signal) as a .Type export, then every top-level fn as a .Term export,
// then every module-level `let` as a .Const export. A module's whole top-level
// surface is exported (spec §15: a module has no visibility modifier — a
// declaration's presence at module scope IS its export), so the index mirrors
// resolve_env's own type/term partition. A module-level let IS exported because a
// let-emitting seam (the §19 assets seam's typed handle constants) must be
// referenced cross-module (`import assets` then `assets.coin_sfx`); behaviors stay
// unexported — a behavior is reached through its own module's pipeline, not an
// importable name. The order is source order within each kind, type exports first
// then fn terms then const terms, so the list walks deterministically. Each
// export carries its declaration's §05 §4 @expose flag — recorded for every
// module, consulted only across a package edge (spec §30 §6).
collect_module_exports :: proc(ast: Ast) -> []Module_Export {
	exports := make([dynamic]Module_Export, 0, 8, context.temp_allocator)
	for decl in ast.things {
		// `thing` and `singleton` both occupy the .Thing user kind (parser
		// folds them into ast.things, distinguished only by is_singleton).
		append(&exports, Module_Export{name = decl.name, kind = .Type, user_kind = .Thing, exposed = decl.exposed})
	}
	for decl in ast.datas {
		append(&exports, Module_Export{name = decl.name, kind = .Type, user_kind = .Data, exposed = decl.exposed})
	}
	for decl in ast.signals {
		append(&exports, Module_Export{name = decl.name, kind = .Type, user_kind = .Signal, exposed = decl.exposed})
	}
	for decl in ast.enums {
		append(&exports, Module_Export{name = decl.name, kind = .Type, user_kind = .Enum, exposed = decl.exposed})
	}
	for decl in ast.fns {
		append(&exports, Module_Export{name = decl.name, kind = .Term, exposed = decl.exposed})
	}
	for decl in ast.lets {
		append(&exports, Module_Export{name = decl.name, kind = .Const, exposed = decl.exposed})
	}
	return exports[:]
}

// module_index_lookup finds a module entry by name, walked by index like every
// table here — never a map. The user-module import arm calls it after the stdlib
// arm misses, so a path naming neither a stdlib partition nor a user module is
// the .Unknown_Module reject.
module_index_lookup :: proc(index: Module_Index, module: string) -> (entry: Module_Entry, found: bool) {
	for candidate in index.modules {
		if candidate.module == module {
			return candidate, true
		}
	}
	return Module_Entry{}, false
}

// module_export_lookup finds one exported name within a module entry, walked by
// index. A name the module does not export is the .Unknown_Member reject — the
// user-module analogue of surface_lookup over a stdlib partition.
module_export_lookup :: proc(entry: Module_Entry, name: string) -> (export: Module_Export, found: bool) {
	for candidate in entry.exports {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Module_Export{}, false
}

// module_export_importable is THE §15 §4 two-boundary visibility rule: a
// within-project export (package_root == "") is public-by-default — always
// importable, the exposed flag never consulted — while a package-edge export
// is importable iff its declaration carries §05 §4 @expose (spec §30 §6;
// everything else is package-private). Both the import resolver
// (resolve_user_import) and the whole-module-handle member access
// (module_member_kind) gate through this one predicate, so the two access
// routes cannot drift.
module_export_importable :: proc(entry: Module_Entry, export: Module_Export) -> bool {
	return entry.package_root == "" || export.exposed
}

// module_export_binding maps an export's position to the Binding the resolver
// records: the binding's module is the OWNING user module, so a cross-module
// reference carries the source of its meaning (spec §02 one-name-one-meaning),
// and the Decl_Kind mirrors the export's position — a type export binds as
// .Type_Name, a fn term as .Func, a const term as .Value — so a user-module
// import populates Bindings identically to a stdlib import.
module_export_binding :: proc(module: string, export: Module_Export) -> Binding {
	kind: Decl_Kind
	switch export.kind {
	case .Type:
		kind = .Type_Name
	case .Term:
		kind = .Func
	case .Const:
		kind = .Value
	}
	return Binding{module = module, kind = kind}
}

// index_user_type resolves a name that an import bound to a sibling user module
// into the checker's nominal User_Type, recovering the export's §06 kind from
// the owning module's entry. The resolver calls it for a field/param Type_Ref
// whose name is in scope as a user-module type binding (a `gate: Ref[Switch]`
// where Switch was imported from arena_world, or a `data Arena` field typed by
// the seam) — the cross-module type reference resolves to the same nominal handle
// the owning module's own resolve_env would build for it. found = false when the
// name is not an in-scope user-module type binding (a stdlib import, a prelude
// name, or an unbound name), leaving the caller's other arms to resolve it.
index_user_type :: proc(index: Module_Index, bindings: Bindings, name: string) -> (type: Type, found: bool) {
	binding, bound := bindings.names[name]
	if !bound || binding.kind != .Type_Name {
		return nil, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return nil, false
	}
	export, exported := module_export_lookup(entry, name)
	if !exported || export.kind != .Type {
		return nil, false
	}
	return user_type_of(name, export.user_kind), true
}

// resolve_user_import resolves one import's members against a known user module's
// export list, binding each into the consuming module's environment. It is the
// user-module sibling of the stdlib arm (surface_resolve + bind_name): a member
// the module exports binds to the owning module; a member it does not export is
// .Unknown_Member; a member the module exports but does NOT @expose across a
// package edge is .Package_Private (spec §30 §6 — importable iff @expose'd; a
// within-project entry never gates, spec §15 §4); a member whose name already
// binds to a DIFFERENT in-scope import is .Name_Collision (bind_name enforces
// the §02 rule). The privacy gate runs AFTER the export lookup so an unknown
// member of a package module stays the precise .Unknown_Member — privacy is a
// fact about a declaration that exists. The caller has already confirmed the
// module is in the index, so this arm never re-checks module existence.
resolve_user_import :: proc(bindings: ^Bindings, entry: Module_Entry, members: []string) -> Type_Error {
	for member in members {
		export, exported := module_export_lookup(entry, member)
		if !exported {
			return .Unknown_Member
		}
		if !module_export_importable(entry, export) {
			return .Package_Private
		}
		bind_name(bindings, member, module_export_binding(entry.module, export)) or_return
	}
	return .None
}
