// The §28 §4 debug-probe placement gate — pure AST, a structural gate like its
// gates.odin siblings (spec §01 P5: no per-site waiver): the §28 §4 On-table
// fixes which debug directive sits legally on which declaration kind, and this
// gate refuses any probe placed where the table does not admit it.
//
// THE ON-TABLE (§28 §4 / §05 §5), by probe position:
//
//   | Directive | Legal On                          |
//   |-----------|-----------------------------------|
//   | @break    | a behavior                        |
//   | @log      | a behavior                        |
//   | @watch    | a behavior OR a `data` field      |
//   | @trace    | a behavior OR a pipeline stage    |
//
// A probe rides one of THREE AST positions: a declaration prefix (carried on
// the declaration node's `probes`), a `data`-field prefix (Field_Decl.probes),
// or a pipeline-stage prefix (Pipeline_Stage.probes). The field and stage
// positions are already adjudicated AT PARSE — parse_field_list admits only
// @watch on a `data` field (every other probe there is Parse_Error
// .Probe_Wrong_Target) and parse_pipeline admits only @trace on a stage — so a
// field/stage probe that reaches this gate is legal by construction. What the
// parser cannot decide is the DECLARATION-PREFIX position: parse_directive
// accumulates @break/@log/@watch/@trace into the pending directive set and ANY
// declaration consumes the whole set, so a `@break`-on-a-`fn`, a `@log`-on-a-
// `let`, a `@watch`-on-a-`thing`, a `@trace`-on-a-`query` all parse. Per the
// table, a declaration-prefix probe is admitted only on a BEHAVIOR — the one
// declaration kind every probe lists — so this gate's whole job is: a
// declaration-prefix probe on any non-behavior declaration is the named
// Probe_Wrong_Placement verdict.
//
// This is deliberately a GATE-stage check, not a parse-time one (the
// Index_Wrong_Target mold the §05 §3 @index/@spatial placement uses at parse):
// the full On-table is only adjudicable once the AST represents all three
// probe positions (the field/stage grammar the prerequisite task added), and a
// single gate walk over the whole declaration sequence keeps one placement
// seam total over the declaration kinds rather than a parse special-case per
// arm. It runs in BOTH dev and release — a mis-placed probe is a structural
// error independent of mode, distinct from the release-only debug-directive ban
// (release_debug_decl, gates.odin), which is placement-BLIND because debug
// residue cannot ship even when mis-placed.
package funpack

// check_probe_placement_gate walks every declaration in the Ast's source-ordered
// declaration sequence (the same order the index derivation and the release
// walkers read) and returns the first §28 §4 On-table violation, naming the
// offending declaration — so a multi-violation source always reports the same
// first offender, matching index order. The switch is total over
// Ast_Decl_Kind, so a new declaration kind is a visible compile gap here, never
// a silently-unchecked probe position.
//
// Only the DECLARATION-PREFIX probe set is checked per kind: a behavior admits
// every probe (the one kind the whole table lists), and every other
// declaration admits NONE at the declaration-prefix position. A `data`
// declaration's FIELD probes and a pipeline's STAGE probes are NOT re-checked —
// the parser already admitted only the On-table's legal sub-declaration probe
// there (@watch on a `data` field, @trace on a stage), so they are legal by
// construction; re-walking them would duplicate a verdict the grammar owns.
check_probe_placement_gate :: proc(ast: Ast) -> Gate_Verdict {
	for ref in ast.decls {
		switch ref.kind {
		case .Behavior:
			// A behavior is the one declaration every probe in the On-table
			// admits, so its declaration-prefix probes are always legal.
		case .Data:
			decl := ast.datas[ref.index]
			if len(decl.probes) > 0 {
				return Gate_Verdict{err = .Probe_Wrong_Placement, declaration = decl.name, line = decl.line}
			}
		case .Enum:
			decl := ast.enums[ref.index]
			if len(decl.probes) > 0 {
				return Gate_Verdict{err = .Probe_Wrong_Placement, declaration = decl.name, line = decl.line}
			}
		case .Thing:
			decl := ast.things[ref.index]
			if len(decl.probes) > 0 {
				return Gate_Verdict{err = .Probe_Wrong_Placement, declaration = decl.name, line = decl.line}
			}
		case .Signal:
			decl := ast.signals[ref.index]
			if len(decl.probes) > 0 {
				return Gate_Verdict{err = .Probe_Wrong_Placement, declaration = decl.name, line = decl.line}
			}
		case .Fn:
			decl := ast.fns[ref.index]
			if len(decl.probes) > 0 {
				return Gate_Verdict{err = .Probe_Wrong_Placement, declaration = decl.name, line = decl.line}
			}
		case .Query:
			decl := ast.queries[ref.index]
			if len(decl.probes) > 0 {
				return Gate_Verdict{err = .Probe_Wrong_Placement, declaration = decl.name, line = decl.line}
			}
		case .Pipeline:
			// A pipeline declaration's own prefix admits no probe (the @trace
			// the On-table places "on a stage" rides Pipeline_Stage.probes, not
			// the Pipeline_Node prefix), so a declaration-prefix probe here is
			// mis-placed.
			decl := ast.pipelines[ref.index]
			if len(decl.probes) > 0 {
				return Gate_Verdict{err = .Probe_Wrong_Placement, declaration = decl.name, line = decl.line}
			}
		case .Let:
			decl := ast.lets[ref.index]
			if len(decl.probes) > 0 {
				return Gate_Verdict{err = .Probe_Wrong_Placement, declaration = decl.name, line = decl.line}
			}
		case .Test:
			// A test block is not in the On-table, so a probe before a test is
			// mis-placed. The parser carries the pending probes onto the test
			// node (parser.odin) precisely so this gate SEES them and names the
			// test — a probe before a test is a named diagnostic here, never the
			// silent drop the .Test arm would otherwise be.
			decl := ast.tests[ref.index]
			if len(decl.probes) > 0 {
				return Gate_Verdict{err = .Probe_Wrong_Placement, declaration = decl.name, line = decl.line}
			}
		case .Extern_Type:
			decl := ast.extern_types[ref.index]
			if len(decl.probes) > 0 {
				return Gate_Verdict{err = .Probe_Wrong_Placement, declaration = decl.name, line = decl.line}
			}
		}
	}
	return Gate_Verdict{err = .None}
}
