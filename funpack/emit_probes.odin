// The [probes]-section serializer of the artifact emitter
// (docs/artifact-format.md §21): the §28 §4 in-code debug directives lifted onto
// their §28 §2 addressing sites. The probe-collection walk over the
// source-ordered declaration sequence is a self-contained, dev-only concern — the
// upstream release ban keeps this section empty in a release artifact.
package funpack

import "core:strings"

// ───────────────────────────────────────────────────────────────────────────
// [probes] — the §28 §4 in-code debug directives (docs/artifact-format.md §21,
// schema v18)
// ───────────────────────────────────────────────────────────────────────────

// Probe_Record is one §05 §5 / §28 §4 debug directive lifted to the
// artifact-emit shape: its closed kind (the lowercased directive family token the
// [probes] record leads with — `probe_directive_name`, the SAME token the §29 §2
// index `debug` field carries, so the two probe surfaces name a probe identically),
// the TARGET — the §28 §2 "addressing reuses index identity" site the runtime
// resolves the probe against — and the probe's predicate/expression body (a single
// Expr subtree for @break/@log/@watch, nil for @trace, which carries no argument).
//
// TARGET takes two shapes, both the §28 §2 addressing namespace (`Snake`,
// `Snake.eat`). A DECLARATION-PREFIX probe (a behavior @break/@log/@watch/@trace)
// targets the bare declaration NAME. A SUB-DECLARATION probe targets the qualified
// `Owner.member` site: a `data` field @watch targets `<data>.<field>`, a pipeline
// stage @trace targets `<pipeline>.<stage>` (qualify_probe_site). The qualifier is
// a single space-free token, so it rides the free-string TARGET slot of the
// `probe KIND TARGET body_count` record with no parse-contract change — the v18
// format already documents TARGET as "the behavior, stage, `data` field, or other
// declaration the directive is attached to" (a §2.6 name field). It is the pure
// projection of a parser Debug_Probe onto its site.
Probe_Record :: struct {
	kind:   string,
	target: string,
	body:   Expr,
}

// collect_probe_records walks the checked AST's source-ordered declaration
// sequence (`ast.decls`) and lifts every §05 §5 / §28 §4 debug probe onto its
// §28 §2 addressing site, in (declaration order, then — within one declaration —
// declaration-prefix probes first, then field/stage probes in field/stage order)
// — the SAME declaration-then-field/stage walk release_debug_decl (gates.odin)
// and derive_decl_records (index_decl.odin) use, so the [probes] section order is
// the deterministic index order. A declaration with no probe contributes nothing.
//
// TWO probe positions ride into [probes] (the §28 §4 On-table). (1) the
// DECLARATION-PREFIX probe (a behavior @break/@log/@watch/@trace) → TARGET is the
// bare declaration NAME. (2) the SUB-DECLARATION probe — a @watch on a `data`
// field (Field_Decl.probes) and a @trace on a pipeline stage
// (Pipeline_Stage.probes) → TARGET is the qualified `Owner.member` site
// (qualify_probe_site): `<data/thing/signal>.<field>` for a field, `<pipeline>.<stage>`
// for a stage. The owner prefix disambiguates a field from a stage of the same
// bare name (top-level decl names share one namespace, so `<owner>.<suffix>` is
// unique); the runtime resolves the prefix to a declaration, then the suffix
// within it. The field walk is total over data/thing/signal fields for the
// closed-walk discipline, but in a parseable tree only a `data` body field carries
// a probe (the parser admits a field @watch only there); the stage walk covers
// every pipeline stage. A test block reaching here is probe-free (the §28 §4
// placement gate refuses a probe-before-a-test before emit), so the .Test arm
// lifts nothing.
//
// The result is a pure function of the AST: no map iteration, no host bytes, so
// two emissions are byte-identical (§29).
collect_probe_records :: proc(ast: Ast, allocator := context.allocator) -> []Probe_Record {
	out := make([dynamic]Probe_Record, 0, 4, allocator)
	for ref in ast.decls {
		probes: []Debug_Probe
		name: string
		switch ref.kind {
		case .Let:
			probes = ast.lets[ref.index].probes
			name = ast.lets[ref.index].name
		case .Data:
			probes = ast.datas[ref.index].probes
			name = ast.datas[ref.index].name
		case .Enum:
			probes = ast.enums[ref.index].probes
			name = ast.enums[ref.index].name
		case .Thing:
			probes = ast.things[ref.index].probes
			name = ast.things[ref.index].name
		case .Signal:
			probes = ast.signals[ref.index].probes
			name = ast.signals[ref.index].name
		case .Fn:
			probes = ast.fns[ref.index].probes
			name = ast.fns[ref.index].name
		case .Query:
			probes = ast.queries[ref.index].probes
			name = ast.queries[ref.index].name
		case .Behavior:
			probes = ast.behaviors[ref.index].probes
			name = ast.behaviors[ref.index].name
		case .Pipeline:
			probes = ast.pipelines[ref.index].probes
			name = ast.pipelines[ref.index].name
		case .Extern_Type:
			probes = ast.extern_types[ref.index].probes
			name = ast.extern_types[ref.index].name
		case .Test:
		// A test reaching emit is probe-free (the §28 §4 placement gate refuses
		// a probe before a test before emit runs) — nothing to lift.
		}
		// Declaration-prefix probes FIRST (the bare-name TARGET), mirroring the
		// index/ban order within one declaration.
		for probe in probes {
			append(&out, Probe_Record{kind = probe_directive_name(probe.kind), target = name, body = probe.arg})
		}
		// Then the §28 §4 sub-declaration probes for this same declaration — a
		// `data`/thing/signal field @watch and a pipeline stage @trace — each with
		// its qualified `Owner.member` TARGET, in field/stage source order.
		#partial switch ref.kind {
		case .Data:
			append_field_probes(&out, name, ast.datas[ref.index].fields)
		case .Thing:
			append_field_probes(&out, name, ast.things[ref.index].fields)
		case .Signal:
			append_field_probes(&out, name, ast.signals[ref.index].fields)
		case .Pipeline:
			append_stage_probes(&out, name, ast.pipelines[ref.index].stages)
		}
	}
	return out[:]
}

// append_field_probes lifts every §28 §4 field @watch (Field_Decl.probes) onto its
// qualified `<owner>.<field>` TARGET, in field-declaration order — the
// sub-declaration half of collect_probe_records for a data/thing/signal record.
// The field walk is total over the kind for the closed-walk discipline; in a
// parseable tree only a `data` body field carries a probe (the parser admits a
// field @watch nowhere else), so a thing/signal contributes none.
append_field_probes :: proc(out: ^[dynamic]Probe_Record, owner: string, fields: []Field_Decl) {
	for field in fields {
		for probe in field.probes {
			append(out, Probe_Record{
				kind   = probe_directive_name(probe.kind),
				target = qualify_probe_site(owner, field.name),
				body   = probe.arg,
			})
		}
	}
}

// append_stage_probes lifts every §28 §4 stage @trace (Pipeline_Stage.probes) onto
// its qualified `<pipeline>.<stage>` TARGET, in stage-declaration order — the
// sub-declaration half of collect_probe_records for a pipeline record. The
// On-table admits only @trace on a stage and @trace carries no argument, so a
// stage probe's body is always nil (body_count 0); the walk routes the arg through
// regardless so a future argument-bearing stage probe rides without re-editing.
append_stage_probes :: proc(out: ^[dynamic]Probe_Record, pipeline: string, stages: []Pipeline_Stage) {
	for stage in stages {
		for probe in stage.probes {
			append(out, Probe_Record{
				kind   = probe_directive_name(probe.kind),
				target = qualify_probe_site(pipeline, stage.name),
				body   = probe.arg,
			})
		}
	}
}

// qualify_probe_site builds the §28 §2 qualified `Owner.member` addressing TARGET a
// sub-declaration probe carries — `<data>.<field>` for a field @watch,
// `<pipeline>.<stage>` for a stage @trace — the same `Snake.eat` form the spec's
// addressing uses (static structure and live state share one namespace). The
// owner prefix disambiguates the site (top-level decl names share one namespace),
// and the joined name is one space-free token, so it fits the free-string TARGET
// slot of the `probe KIND TARGET body_count` record with no parse-contract change.
qualify_probe_site :: proc(owner: string, member: string) -> string {
	return strings.concatenate({owner, ".", member}, context.temp_allocator)
}

// emit_probes writes the [probes] section (docs/artifact-format.md §21, schema
// v18): one `probe KIND TARGET body_count` top-level record per in-code §28 §4
// debug directive, each followed by its predicate/expression body as a §2.7 node
// forest (the `node` sub-record run emit_expr produces) — never funpack source
// (§28 §2: the body is compiled funpack-side to a node forest the runtime folds).
// TARGET is the §28 §2 addressing site: a bare declaration name for a behavior
// probe, or the qualified `Owner.member` site for a §28 §4 sub-declaration probe —
// a `data` field @watch (`<data>.<field>`) or a pipeline stage @trace
// (`<pipeline>.<stage>`). body_count is 1 for @break/@log/@watch (the single
// predicate/expression subtree rides next) and 0 for @trace (no argument, nil
// body). The walk is source order (collect_probe_records), so two emissions are
// byte-identical (§29).
//
// The section is DEV-ONLY by construction: the §29 §3 release debug-directive ban
// refuses the whole build (Build_Error.Debug_Directive) before emission whenever a
// declaration carries a probe under --release, so a release artifact's AST is
// probe-free and this writes the constant `[probes 0]` tail — the v7 stub-node
// precedent (a release artifact never carries a stub because the hole-ban refuses
// the holed tree first). The emitter stays mode-blind: it emits exactly the probes
// the AST carries, which the upstream ban guarantees is none in release. A
// probe-free dev build likewise writes `[probes 0]`.
emit_probes :: proc(b: ^strings.Builder, ast: Ast) {
	records := collect_probe_records(ast, context.temp_allocator)
	emit_header(b, "probes", len(records))
	for record in records {
		has_body := record.body != nil
		strings.write_string(b, "probe ")
		strings.write_string(b, record.kind)
		strings.write_byte(b, ' ')
		strings.write_string(b, record.target)
		strings.write_byte(b, ' ')
		strings.write_int(b, 1 if has_body else 0)
		emit_line(b, "")
		if has_body {
			emit_expr(b, record.body)
		}
	}
}
