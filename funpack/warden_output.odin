package funpack

warden_command_output :: proc(
	index: Warden_Index,
	cmd: Warden_Command,
	arg := "",
	find := Warden_Find_Query{},
	allocator := context.allocator,
) -> string {
	switch cmd {
	case .Find:
		return warden_find_output(index, find, allocator)
	case .Holes:
		return warden_project_decls(index.decls, warden_holes_predicate, "", allocator)
	case .Probes:
		return warden_project_decls(index.decls, warden_probes_predicate, "", allocator)
	case .Debt:
		return warden_project_decls(index.decls, warden_debt_predicate, "", allocator)
	case .Graph:
		return warden_graph_output(index, arg, allocator)
	case .Tags:
		return warden_tags_ndjson(index, allocator)
	case .Pipeline:
		return warden_pipeline_ndjson(index, allocator)
	}
	return ""
}
