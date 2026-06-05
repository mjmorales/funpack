package funpack

import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// ── Snippet-shaped accept paths ────────────────────────────────────────
// parse_project_fcfg owns the §14 smaller config grammar; these exercise
// its surface directly, independent of the on-disk tree.

@(test)
test_parse_project_fcfg_happy :: proc(t: ^testing.T) {
	identity, err := parse_project_fcfg("project numerics {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, identity.name, "numerics")
	testing.expect_value(t, identity.version, "0.1.0")
}

@(test)
test_parse_project_fcfg_leading_doc :: proc(t: ^testing.T) {
	// A grammar-legal top-level @doc preceding the block is accepted and
	// dropped; identity is unchanged.
	content := "@doc(\"the numeric kernel\")\nproject numerics {\n  version = \"0.1.0\"\n}\n"
	identity, err := parse_project_fcfg(content)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, identity.name, "numerics")
	testing.expect_value(t, identity.version, "0.1.0")
}

@(test)
test_parse_project_fcfg_extra_doc_and_key_same_identity :: proc(t: ^testing.T) {
	// Adding benign grammar-legal constructs — an in-block @doc and an
	// extra key = value — still parses to the same identity. This proves
	// the parser handles the grammar's surface, not just the two golden
	// lines.
	content := "project numerics {\n  @doc(\"version pin\")\n  version = \"0.1.0\"\n  edition = \"2026\"\n}\n"
	identity, err := parse_project_fcfg(content)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, identity.name, "numerics")
	testing.expect_value(t, identity.version, "0.1.0")
}

// ── Snippet-shaped reject paths ────────────────────────────────────────

@(test)
test_parse_project_fcfg_missing_label_rejected :: proc(t: ^testing.T) {
	// A labelless block has no package name — the label IS the name
	// (§14.4), so `project { … }` is malformed.
	_, err := parse_project_fcfg("project {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_missing_version_rejected :: proc(t: ^testing.T) {
	// A well-formed block missing the required version is the dedicated
	// Missing_Project_Version diagnostic — version is the one required
	// key, so its absence is never silently accepted.
	_, err := parse_project_fcfg("project numerics {\n}\n")
	testing.expect_value(t, err, Project_Error.Missing_Project_Version)
}

@(test)
test_parse_project_fcfg_key_without_eq_rejected :: proc(t: ^testing.T) {
	// `=` is the lexical tell that separates config from logic (§14.2); a
	// key without it is not an assignment.
	_, err := parse_project_fcfg("project numerics {\n  version \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_control_flow_rejected :: proc(t: ^testing.T) {
	// The config grammar has no control flow (§14.2); an `if` inside the
	// block is a construct outside key=value/block/@doc and rejects. (`if`
	// lexes as a bare Ident, then the following `{` is not `=`.)
	_, err := parse_project_fcfg("project numerics {\n  version = \"0.1.0\"\n  if active { }\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_expression_value_rejected :: proc(t: ^testing.T) {
	// The config grammar has no expressions (§14.2); a value that is an
	// arithmetic expression rather than a string literal rejects — the
	// `+` glyph lexes Invalid.
	_, err := parse_project_fcfg("project numerics {\n  version = 1 + 1\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_use_reference_rejected :: proc(t: ^testing.T) {
	// `use` references name source and are out of scope for project
	// identity (§14.2); a top-level `use` is not the project block opener.
	_, err := parse_project_fcfg("use numerics.{X}\nproject numerics {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_empty_rejected :: proc(t: ^testing.T) {
	// No block at all — there is no identity to read.
	_, err := parse_project_fcfg("")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

// ── Tree-shaped paths through read_project ─────────────────────────────

@(test)
test_read_project_valid_tree :: proc(t: ^testing.T) {
	// The full read_project path over a scratch §14 tree: a valid
	// project.fcfg plus a src/*.fun resolves to the parsed identity.
	root, ok := write_scratch_tree(t, "project numerics {\n  version = \"0.1.0\"\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	project, err := read_project(root)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, project.name, "numerics")
	testing.expect_value(t, project.version, "0.1.0")
	testing.expect(t, len(project.sources) > 0)
}

@(test)
test_read_project_malformed_tree_rejected :: proc(t: ^testing.T) {
	// A tree whose project.fcfg violates the grammar (a stray control-flow
	// construct) is rejected through read_project — a grammar violation is
	// never silently ignored.
	root, ok := write_scratch_tree(t, "project numerics {\n  version = \"0.1.0\"\n  while go { }\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err := read_project(root)
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_read_project_missing_version_tree_rejected :: proc(t: ^testing.T) {
	// A tree whose project.fcfg omits the required version surfaces the
	// dedicated Missing_Project_Version arm through read_project.
	root, ok := write_scratch_tree(t, "project numerics {\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err := read_project(root)
	testing.expect_value(t, err, Project_Error.Missing_Project_Version)
}

@(test)
test_read_project_missing_tree :: proc(t: ^testing.T) {
	_, err := read_project("/nonexistent-funpack-project-root")
	testing.expect_value(t, err, Project_Error.Missing_Configs_Dir)
}

// ── §15 path-derived module identity ───────────────────────────────────

@(test)
test_derive_module_name_flat :: proc(t: ^testing.T) {
	// The flat golden case: src/numerics.fun → module `numerics`. The src/
	// prefix and .fun suffix drop; there is no interior directory to dot.
	module := derive_module_name("/proj/src", "/proj/src/numerics.fun")
	testing.expect_value(t, module, "numerics")
}

@(test)
test_derive_module_name_nested :: proc(t: ^testing.T) {
	// The rule generalizes beyond the flat golden case:
	// src/combat/melee.fun → `combat.melee` — the interior directory is
	// dotted, the filename is the leaf — proving derivation is a pure
	// function of the path, not a single-case hardcode.
	module := derive_module_name("/proj/src", "/proj/src/combat/melee.fun")
	testing.expect_value(t, module, "combat.melee")
}

@(test)
test_read_project_nested_source_module :: proc(t: ^testing.T) {
	// End-to-end: a scratch tree whose only source is src/combat/melee.fun
	// reads back a single Source whose path-derived module is the dotted
	// `combat.melee`. read_project feeds the on-disk path through the same
	// derivation, so the rule holds on real trees, not just the unit.
	root, ok := write_scratch_tree_at(t, "project numerics {\n  version = \"0.1.0\"\n}\n", "combat/melee.fun")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	project, err := read_project(root)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(project.sources), 1)
	testing.expect_value(t, project.sources[0].module, "combat.melee")
}

@(test)
test_read_project_reserved_engine_root_rejected :: proc(t: ^testing.T) {
	// A user source under src/engine/ derives a module beneath the reserved
	// `engine` stdlib root, which §15.7 makes unshadowable — read_project
	// rejects the whole tree through the dedicated Reserved_Engine_Root arm,
	// never a catch-all.
	root, ok := write_scratch_tree_at(t, "project numerics {\n  version = \"0.1.0\"\n}\n", "engine/math.fun")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err := read_project(root)
	testing.expect_value(t, err, Project_Error.Reserved_Engine_Root)
}

@(test)
test_read_project_reserved_engine_bare_root_rejected :: proc(t: ^testing.T) {
	// The bare reserved root collides too: src/engine.fun derives module
	// `engine`, shadowing the stdlib package root — also Reserved_Engine_Root.
	root, ok := write_scratch_tree_at(t, "project numerics {\n  version = \"0.1.0\"\n}\n", "engine.fun")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err := read_project(root)
	testing.expect_value(t, err, Project_Error.Reserved_Engine_Root)
}

// write_scratch_tree materializes a minimal §14 project tree under a
// unique temp root: funpack_configs/project.fcfg carrying the given config
// plus a single src/x.fun so collect_sources succeeds. ok = false (with a
// logged skip) when the scratch I/O fails, so a sandboxed runner without
// write access degrades to a skip rather than a spurious failure.
write_scratch_tree :: proc(t: ^testing.T, fcfg: string) -> (root: string, ok: bool) {
	return write_scratch_tree_at(t, fcfg, "x.fun")
}

// write_scratch_tree_at is write_scratch_tree with the single source
// placed at src/<src_rel> (creating any interior directories), so a test
// can pin the module name a given path derives — a flat `x.fun`, a nested
// `combat/melee.fun`, or a reserved-root `engine/math.fun`.
write_scratch_tree_at :: proc(t: ^testing.T, fcfg: string, src_rel: string) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), fmt.tprintf("funpack-scratch-%d", scratch_seq())})
	// The seq counter resets each process but leftover trees from a
	// crashed prior run persist on disk; clear any stale tree first so a
	// reused root name can never poison the fixture or skip on .Exist.
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	src_path := scratch_join({root, "src", src_rel})
	src_parent := filepath.dir(src_path)
	if os.make_directory_all(configs) != nil || os.make_directory_all(src_parent) != nil {
		log.warnf("SKIP scratch tree: cannot create dirs under %s", root)
		return "", false
	}
	fcfg_path := scratch_join({configs, "project.fcfg"})
	if os.write_entire_file(fcfg_path, fcfg) != nil ||
	   os.write_entire_file(src_path, "@doc(\"scratch\")\n") != nil {
		remove_scratch_tree(root)
		log.warnf("SKIP scratch tree: cannot write files under %s", root)
		return "", false
	}
	return root, true
}

// remove_scratch_tree tears down a write_scratch_tree root.
remove_scratch_tree :: proc(root: string) {
	os.remove_all(root)
}

// scratch_join is filepath.join with the allocator error dropped, matching
// the construction style in project.odin.
scratch_join :: proc(elems: []string) -> string {
	joined, _ := filepath.join(elems, context.temp_allocator)
	return joined
}

scratch_base :: proc() -> string {
	dir, has := os.lookup_env("TMPDIR", context.temp_allocator)
	if has && dir != "" {
		return dir
	}
	return "/tmp"
}

// scratch_seq yields a per-process monotonically increasing counter so
// concurrently-defined scratch roots never collide within one test run.
// The increment is atomic: the test runner schedules tests across worker
// threads, and a plain `+= 1` races — two tests reading the same value
// share a scratch root, where one's deferred teardown then deletes the
// other's tree mid-construction (the transient dir-creation skip).
@(private = "file")
scratch_counter: int

scratch_seq :: proc() -> int {
	return intrinsics.atomic_add(&scratch_counter, 1) + 1
}
