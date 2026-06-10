// The single warden projection renderer (spec §29 §1/§4): the ONE place a
// Warden_Command maps to its pure projection of a decoded index. Every
// consumer rides this seam — warden_verb_exit prints exactly these bytes
// before exiting 0, and the golden determinism sweeps assert over the same
// function — so the dispatch can never drift from what the tests prove
// (a test-side mirror of this switch was the false-green risk this file
// retires). Rendering stays pure (bytes out, no print, no host state); the
// exit mapping and the eprint side of the refusal tier remain
// warden_verb_exit's (main.odin).
package funpack

// warden_command_output renders one warden subcommand's pure projection of a
// decoded index — exactly the byte stream `funpack warden <cmd>` prints
// before exiting 0. The switch is deliberately exhaustive over the closed
// Warden_Command enum (no #partial): a new member fails this file's compile
// until it is mapped here, so neither the CLI dispatch nor the enum-derived
// golden sweeps can silently under-cover a command. arg is the command's
// parsed positional ("" when absent) — today only graph admits one (its
// incident-edge filter); find carries its parsed filter set instead (the
// zero query on every other command).
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
