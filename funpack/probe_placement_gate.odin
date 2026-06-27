package funpack

check_probe_placement_gate :: proc(ast: Ast) -> Gate_Verdict {
	for ref in ast.decls {
		switch ref.kind {
		case .Behavior:
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
