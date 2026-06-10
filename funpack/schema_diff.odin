// The name-keyed schema-diff kernel (spec §09 §4, §24): given two data
// schemas — the OLD one a save or the pre-reload world was written under,
// the NEW one this build declares — classify every field change and produce
// the per-field migration plan the loader executes. `data` is name-keyed
// (map-backed, spec §03), so the classification is total: a field REORDER is
// a non-event (lookups are by name, never position), an ADDITIVE field takes
// its declared default, a REMOVED field drops, and RENAME/RETYPE — the two
// structural breaks the automatic rules cannot resolve — apply the field's
// §05 §6 @migrate metadata; everything else REFUSES with a precise verdict,
// never a best-effort guess (the §09 §4 "rejected with a diagnostic" arm).
//
// The kernel is a PLAN compiler, not an executor: it reads names, type
// spellings, and opaque default tokens, and emits Carry/Rename/Convert/
// Default actions keyed to the new schema's declaration order. Running a
// Convert's `fn(Old) -> New` needs an interpreter, which the loader owns —
// so the kernel performs no arithmetic at all (trivially fixed-point-only)
// and two calls over the same schemas are bit-identical by construction: no
// map iteration, no clock, no allocation-order dependence in the output.
//
// PROVENANCE — this kernel is funpack-side library code the runtime takes a
// DELIBERATE COPY of, NOT a shared import (the fixed.odin discipline).
// runtime/** and funpack/** are separate products (spec §29, §09); the
// artifact file is the only sanctioned coupling, so the runtime must never
// link compiler internals. The file is therefore self-contained — no imports,
// no compiler AST types; its schema model mirrors the artifact's §6 [data]
// field record (name, TYPE spelling, DEFAULT token, migrate FROM/WITH) — and
// any change here must be mirrored byte-for-byte in the runtime's copy when
// the runtime epic lands restore + hot-reload, with the per-class unit
// vectors (schema_diff_test.odin) re-asserted on both sides.
package funpack

// Schema_Field is one field of a name-keyed data schema — the §6 [data]
// `field` record's projection plus its v8 `migrate` carry. type_spelling is
// the canonical TYPE token (the Type_Ref rendering the artifact carries, e.g.
// `Fixed`, `Option[Side]`, `[Goal]`), compared verbatim: the surface has no
// type aliases, so spelling equality IS type equality here. default_token is
// the declared default in whatever encoding the caller's domain uses (the §6
// `=ENCODED` token on the artifact side) — opaque to the kernel, which only
// routes it. migrate_from / migrate_with mirror the §05 §6 directive halves;
// the has_* flags discriminate absence, mirroring Field_Decl.has_default.
Schema_Field :: struct {
	name:          string,
	type_spelling: string,
	default_token: string, // meaningful iff has_default
	has_default:   bool,
	migrate_from:  string, // the prior key (§05 §6 `from:`); meaningful iff has_from
	has_from:      bool,
	migrate_with:  string, // the conversion fn's name (§05 §6 `with:`); meaningful iff has_with
	has_with:      bool,
}

// Migration_Op is the closed action vocabulary the plan speaks — one op per
// way a new-schema field obtains its value from an old row. Removed old
// fields produce NO action (the §09 §4 "remove field: safe, automatic" drop);
// a reorder is invisible by construction (every op sources by name).
Migration_Op :: enum {
	Carry,   // same name, same type: copy the old value (covers the reorder no-op)
	Rename,  // @migrate(from:) — copy the old value from the prior key (same type)
	Convert, // @migrate(with:) — run the old value (at `source`) through the named pure fn
	Default, // additive field: seed the declared default
}

// Migration_Action fills one NEW-schema field. Actions come in the new
// schema's declaration order, one per field, so a plan's shape is a pure
// function of its inputs. source is the OLD row key read (Carry/Rename/
// Convert; "" for Default); convert is the §05 §6 fn name (Convert only);
// default_token is the declared default routed through (Default only).
Migration_Action :: struct {
	field:         string,
	op:            Migration_Op,
	source:        string,
	convert:       string,
	default_token: string,
}

// Schema_Diff_Error is the closed refusal vocabulary — the §09 §4 "rejected
// with a diagnostic" arm, one named verdict per unresolvable class so the
// diagnostic names the exact repair.
Schema_Diff_Error :: enum {
	None,
	Duplicate_Field, // a schema declares one name twice — the name-keyed premise is broken, the diff is ill-defined (an input-contract violation, refused before any classification)
	Unknown_Source, // a @migrate names a prior key the old schema lacks — the directive's claim about the old world is false, refused rather than silently defaulted (a wrong rename must not masquerade as an additive field)
	Retype_Without_Migrate, // a same-named field changed type with no directive — the §09 §4 "change field type: breaking" verdict; the repair is @migrate(with: convert)
	Rename_Type_Changed, // a rename-only @migrate(from:) whose source field's type differs — rename is the SAME-type form (§05 §6); the repair is the combined from+with form
	Missing_Default, // an additive field with no declared default — the §09 §4 "add non-optional field, no default: breaking" verdict; the repair is "make it Option or give a default"
}

// diff_schemas compiles the migration plan from the OLD schema to the NEW
// one. On refusal it returns the verdict plus the offending NEW-schema field
// name (for Duplicate_Field, the duplicated name in whichever schema carries
// it) and an empty plan. The walk is the new schema in declaration order with
// linear by-name lookups into the old — deterministic by construction. Every
// action sources from the old SNAPSHOT, never from a sequentially-mutated
// row, so cross-field moves (old.a → new.b while old.b → new.c) read the
// values their directives name regardless of order.
diff_schemas :: proc(
	old_schema: []Schema_Field,
	new_schema: []Schema_Field,
	allocator := context.allocator,
) -> (
	plan: []Migration_Action,
	offender: string,
	err: Schema_Diff_Error,
) {
	if dup, found := first_duplicate_name(old_schema); found {
		return nil, dup, .Duplicate_Field
	}
	if dup, found := first_duplicate_name(new_schema); found {
		return nil, dup, .Duplicate_Field
	}
	actions := make([dynamic]Migration_Action, 0, len(new_schema), allocator)
	for field in new_schema {
		action, field_err := classify_field(old_schema, field)
		if field_err != .None {
			delete(actions)
			return nil, field.name, field_err
		}
		append(&actions, action)
	}
	return actions[:], "", .None
}

// classify_field resolves one new-schema field to its action — the §09 §4
// verdict table as code. A @migrate directive is the explicit channel and
// takes precedence over the automatic by-name rules: a directive-carrying
// field sources from exactly the key its directive names (its own name for a
// pure retype), and that source must exist — the directive states a fact
// about the old schema, so a missing source is the Unknown_Source refusal,
// never a silent fall-through to the additive default (a mistyped rename
// must surface, not seed a default). Only a directive-free field is eligible
// for the automatic arms: same-name same-type carries, an absent name is
// additive (declared default or the Missing_Default refusal).
classify_field :: proc(old_schema: []Schema_Field, field: Schema_Field) -> (action: Migration_Action, err: Schema_Diff_Error) {
	if field.has_from || field.has_with {
		source_key := field.migrate_from if field.has_from else field.name
		source, found := find_field(old_schema, source_key)
		if !found {
			return action, .Unknown_Source
		}
		if field.has_with {
			return Migration_Action{field = field.name, op = .Convert, source = source_key, convert = field.migrate_with}, .None
		}
		// Rename-only is the SAME-type form (§05 §6 "rename (same type)"):
		// a type change rides the conversion, never a bare rename.
		if source.type_spelling != field.type_spelling {
			return action, .Rename_Type_Changed
		}
		return Migration_Action{field = field.name, op = .Rename, source = source_key}, .None
	}
	if source, found := find_field(old_schema, field.name); found {
		if source.type_spelling != field.type_spelling {
			return action, .Retype_Without_Migrate
		}
		return Migration_Action{field = field.name, op = .Carry, source = field.name}, .None
	}
	if !field.has_default {
		return action, .Missing_Default
	}
	return Migration_Action{field = field.name, op = .Default, default_token = field.default_token}, .None
}

// find_field is the name-keyed lookup — a linear scan over the declared
// order, so the kernel never iterates a map (the determinism tripwire).
find_field :: proc(schema: []Schema_Field, name: string) -> (field: Schema_Field, found: bool) {
	for candidate in schema {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Schema_Field{}, false
}

// first_duplicate_name returns the first name a schema declares twice, in
// declaration order — the precondition probe behind Duplicate_Field. The
// quadratic scan is deliberate: schemas are small, and ordered scans keep
// the verdict reproducible without a map.
first_duplicate_name :: proc(schema: []Schema_Field) -> (name: string, found: bool) {
	for field, i in schema {
		for earlier in schema[:i] {
			if earlier.name == field.name {
				return field.name, true
			}
		}
	}
	return "", false
}
