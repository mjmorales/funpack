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
	identity, err, _ := parse_project_fcfg("project numerics {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, identity.name, "numerics")
	testing.expect_value(t, identity.version, "0.1.0")
}

@(test)
test_parse_project_fcfg_leading_doc :: proc(t: ^testing.T) {
	// A grammar-legal top-level @doc preceding the block is accepted and
	// dropped; identity is unchanged.
	content := "@doc(\"the numeric kernel\")\nproject numerics {\n  version = \"0.1.0\"\n}\n"
	identity, err, _ := parse_project_fcfg(content)
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
	identity, err, _ := parse_project_fcfg(content)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, identity.name, "numerics")
	testing.expect_value(t, identity.version, "0.1.0")
}

// ── Snippet-shaped reject paths ────────────────────────────────────────

@(test)
test_parse_project_fcfg_missing_label_rejected :: proc(t: ^testing.T) {
	// A labelless block has no package name — the label IS the name
	// (§14.4), so `project { … }` is malformed.
	_, err, _ := parse_project_fcfg("project {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_missing_version_rejected :: proc(t: ^testing.T) {
	// A well-formed block missing the required version is the dedicated
	// Missing_Project_Version diagnostic — version is the one required
	// key, so its absence is never silently accepted.
	_, err, _ := parse_project_fcfg("project numerics {\n}\n")
	testing.expect_value(t, err, Project_Error.Missing_Project_Version)
}

@(test)
test_parse_project_fcfg_key_without_eq_rejected :: proc(t: ^testing.T) {
	// `=` is the lexical tell that separates config from logic (§14.2); a
	// key without it is not an assignment.
	_, err, _ := parse_project_fcfg("project numerics {\n  version \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_control_flow_rejected :: proc(t: ^testing.T) {
	// The config grammar has no control flow (§14.2); an `if` inside the
	// block is a construct outside key=value/block/@doc and rejects. (`if`
	// lexes as a bare Ident, then the following `{` is not `=`.)
	_, err, _ := parse_project_fcfg("project numerics {\n  version = \"0.1.0\"\n  if active { }\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_expression_value_rejected :: proc(t: ^testing.T) {
	// The config grammar has no expressions (§14.2); a value that is an
	// arithmetic expression rather than a string literal rejects — the
	// `+` glyph lexes Invalid.
	_, err, _ := parse_project_fcfg("project numerics {\n  version = 1 + 1\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_use_reference_rejected :: proc(t: ^testing.T) {
	// `use` references name source and are out of scope for project
	// identity (§14.2); a top-level `use` is not the project block opener.
	_, err, _ := parse_project_fcfg("use numerics.{X}\nproject numerics {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_empty_rejected :: proc(t: ^testing.T) {
	// No block at all — there is no identity to read.
	_, err, _ := parse_project_fcfg("")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

// ── Malformed-label fix-criteria detail ────────────────────────────────
// A project name is a bare LOWER_IDENT (§14 §4, §15). A label that violates
// the rule must reject with the dedicated detail line naming the file, the
// label line, and the exact charset rule — never the bare arm name that
// sent the first author guessing. These pin the SCANNED-LABEL byte detail
// so a wording or rule-cite regression fails loudly.

@(test)
test_parse_project_fcfg_hyphen_label_detail :: proc(t: ^testing.T) {
	// The canonical hyphen case: `project colony-sim { … }` scans the label
	// as `colony`, then the `-` truncates the name and breaks the `{` expect.
	// The detail names the offending glyph and the rule on line 1 — the
	// hyphen, not `colony`, is the cause.
	_, err, detail := parse_project_fcfg("project colony-sim {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1: project name must be a bare identifier (a lower-case or '_' start, then letters, digits, or '_'); the '-' after 'colony' is not allowed (spec §14 §4, §15)",
	)
}

@(test)
test_parse_project_fcfg_uppercase_label_detail :: proc(t: ^testing.T) {
	// An UpperCamel label scans clean as one ident but is not a LOWER_IDENT
	// (the name class roots a module, §15). The detail names the rule and the
	// offending label directly.
	_, err, detail := parse_project_fcfg("project Colony {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1: project name must be a bare identifier (a lower-case or '_' start, then letters, digits, or '_') — 'Colony' is not (spec §14 §4, §15)",
	)
}

@(test)
test_parse_project_fcfg_dotted_label_detail :: proc(t: ^testing.T) {
	// A `.` in the label (the dotted-name instinct) is the truncating-glyph
	// case like the hyphen: `project my.game { … }` scans `my`, then `.` breaks
	// the name. The detail names the `.` glyph after `my`.
	_, err, detail := parse_project_fcfg("project my.game {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1: project name must be a bare identifier (a lower-case or '_' start, then letters, digits, or '_'); the '.' after 'my' is not allowed (spec §14 §4, §15)",
	)
}

@(test)
test_parse_project_fcfg_underscore_label_accepted :: proc(t: ^testing.T) {
	// A '_'-rooted label IS a LOWER_IDENT (lower_start = [a-z] | '_'), so it is
	// accepted — the rule admits the underscore start the charset names, never
	// over-rejecting a valid bare identifier.
	identity, err, detail := parse_project_fcfg("project _scratch {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, identity.name, "_scratch")
	testing.expect_value(t, detail, "")
}

@(test)
test_is_lower_ident_charset :: proc(t: ^testing.T) {
	// is_lower_ident enforces the LOWER_IDENT charset (lower_start ident_char*),
	// the §14 §4 / §15 name class: lower/'_' start, then letters/digits/'_'.
	testing.expect(t, is_lower_ident("colony"))
	testing.expect(t, is_lower_ident("_scratch"))
	testing.expect(t, is_lower_ident("combat_melee2"))
	testing.expect(t, !is_lower_ident("Colony")) // UpperCamel head
	testing.expect(t, !is_lower_ident("2d")) // digit head
	testing.expect(t, !is_lower_ident("")) // empty is no identifier
}

// ── Shape-violation fix-criteria detail ────────────────────────────────
// The §14 §1 project.fcfg shape is `project <name> { version = "..." }` — the
// block LABEL is the package name (no `name =` key), the brace-block form, `=`
// not `:`, never a TOML/INI section. An author who reaches for the wrong shape
// must get a `project.fcfg:LINE:COL:` line naming the expected production, what
// was found, and the resolving hint — NOT the bare `Malformed_Project_Fcfg` arm
// that sent the first dogfooder guessing the grammar against a yes/no oracle.
// These pin the byte-exact detail for the FOUR canonical wrong-shape instincts
// (TOML section, bare `name =` key, `key: value` colon, labelless block) plus the
// EOF and missing-version siblings, so a wording, col-anchor, or rule-cite
// regression fails loudly. The arm stays the closed machine contract; the detail
// is the added human body riding project_refusal_message.

@(test)
test_parse_project_fcfg_toml_section_detail :: proc(t: ^testing.T) {
	// The TOML `[project]` section instinct: `[` lexes Invalid at top level, so
	// the brace-block-not-section hint fires anchored on the `[` at 1:1.
	_, err, detail := parse_project_fcfg("[project]\nname = \"deepseed\"\nversion = \"0.1.0\"\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1:1: expected project <name> { version = \"...\" }, found '[' — a project.fcfg is one `project <name> { ... }` brace block, not a `[section]` header (spec §14 §1, §14 §2)",
	)
}

@(test)
test_parse_project_fcfg_bare_name_key_detail :: proc(t: ^testing.T) {
	// The bare `name = "..."` key instinct (the TOML/INI form with no block): a
	// top-level identifier that is not the `project` opener names the
	// label-is-the-name hint, anchored on `name` at 1:1.
	_, err, detail := parse_project_fcfg("name = \"deepseed\"\nversion = \"0.1.0\"\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1:1: expected project <name> { version = \"...\" }, found 'name' — a project.fcfg is one `project <name> { ... }` block — the block label IS the package name (there is no `name =` key, and identity is not a TOML/INI section) (spec §14 §1, §14 §2)",
	)
}

@(test)
test_parse_project_fcfg_colon_assignment_detail :: proc(t: ^testing.T) {
	// The `key: value` colon instinct (YAML/JSON): inside a well-formed block, the
	// `:` after the key breaks the `=` expect and names the `=`-not-`:` hint,
	// anchored on the `:` at its line:col (line 2, col 10).
	_, err, detail := parse_project_fcfg("project deepseed {\n  version: \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:2:10: expected project <name> { version = \"...\" }, found ':' — an assignment binds with `=`, not `:` — write `version = \"...\"` (spec §14 §1, §14 §2)",
	)
}

@(test)
test_parse_project_fcfg_labelless_block_detail :: proc(t: ^testing.T) {
	// The labelless `project { ... }` form: the label slot holds the `{`, so the
	// package name is missing — the label-is-the-name hint fires anchored on the
	// `{` at 1:9.
	_, err, detail := parse_project_fcfg("project { name = \"deepseed\" }\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1:9: expected project <name> { version = \"...\" }, found '{' — the block label is the package name — write `project <name> { ... }`, not a labelless `project { ... }` (spec §14 §1, §14 §2)",
	)
}

@(test)
test_parse_project_fcfg_empty_file_detail :: proc(t: ^testing.T) {
	// An empty (or doc-only) file reaches end-of-input with no block: the detail
	// anchors on the trailing byte and reports `found end of input`, naming the
	// required shape rather than a phantom line-0 sentinel.
	_, err, detail := parse_project_fcfg("")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1:1: expected project <name> { version = \"...\" }, found end of input — a project.fcfg must declare exactly one `project <name> { ... }` block (spec §14 §1, §14 §2)",
	)
}

@(test)
test_parse_project_fcfg_missing_version_detail :: proc(t: ^testing.T) {
	// The dedicated Missing_Project_Version sibling: a well-formed block omitting
	// the one required key surfaces its own detail naming the block and the exact
	// `version = "..."` assignment to add, anchored on the block label's line.
	_, err, detail := parse_project_fcfg("project deepseed {\n}\n")
	testing.expect_value(t, err, Project_Error.Missing_Project_Version)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1: project 'deepseed' is missing the required `version = \"...\"` key (spec §14 §1)",
	)
}

@(test)
test_parse_project_fcfg_non_string_value_detail :: proc(t: ^testing.T) {
	// A non-string assignment value (the `version = 1` instinct): the value is not
	// a string literal, so the string-literal-rule hint fires anchored on the
	// offending value token (a bare digit lexes Tick at line 2, col 13).
	_, err, detail := parse_project_fcfg("project deepseed {\n  version = 1\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:2:13: expected project <name> { version = \"...\" }, found '1' — an assignment value is a double-quoted string literal (`version = \"0.1.0\"`) (spec §14 §1, §14 §2)",
	)
}

@(test)
test_cfg_token_col_recovers_column :: proc(t: ^testing.T) {
	// cfg_token_col recovers a 1-based column from a 0-based offset by counting to
	// the prior newline: the first byte of line 1 is col 1, a mid-line byte counts
	// from its line start, and an offset past end clamps to the trailing column.
	content := "ab\ncde"
	testing.expect_value(t, cfg_token_col(content, 0), 1) // 'a' on line 1
	testing.expect_value(t, cfg_token_col(content, 1), 2) // 'b' on line 1
	testing.expect_value(t, cfg_token_col(content, 3), 1) // 'c' first byte of line 2
	testing.expect_value(t, cfg_token_col(content, 5), 3) // 'e' on line 2
	testing.expect_value(t, cfg_token_col(content, 99), len(content) - 3 + 1) // clamp past end
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

	project, err, _ := read_project(root)
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

	_, err, _ := read_project(root)
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

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Missing_Project_Version)
}

@(test)
test_read_project_missing_tree :: proc(t: ^testing.T) {
	_, err, _ := read_project("/nonexistent-funpack-project-root")
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

	project, err, _ := read_project(root)
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

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Reserved_Engine_Root)
}

@(test)
test_read_project_duplicate_module_rejected :: proc(t: ^testing.T) {
	// A dotted filename and a nested path that derive the same §15 module —
	// src/a.b.fun and src/a/b.fun both derive `a.b` — collide. §15.6 makes
	// two sources producing the same module name a compile error, surfaced
	// through the dedicated Duplicate_Module arm, never a catch-all.
	root, ok := write_scratch_tree_multi(t, "project numerics {\n  version = \"0.1.0\"\n}\n", {"a.b.fun", "a/b.fun"})
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Duplicate_Module)
}

@(test)
test_read_project_distinct_modules_accepted :: proc(t: ^testing.T) {
	// Two sources whose derived modules differ (`a` and `b.a` — same leaf
	// filename, different namespace) pass the §15.6 collision check: the
	// check keys on the full dotted module name, not the filename leaf.
	root, ok := write_scratch_tree_multi(t, "project numerics {\n  version = \"0.1.0\"\n}\n", {"a.fun", "b/a.fun"})
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	project, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(project.sources), 2)
	if len(project.sources) == 2 {
		testing.expect_value(t, project.sources[0].module, "a")
		testing.expect_value(t, project.sources[1].module, "b.a")
	}
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

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Reserved_Engine_Root)
}

// ── §23/§07 entrypoints.fcfg ───────────────────────────────────────────
// parse_entrypoints_fcfg owns the entrypoints production of the §14 smaller
// config grammar; validate_entrypoints checks its references against a parsed
// source module. These exercise both, snippet-shaped and against the live
// pong golden tree.

// PONG_ENTRYPOINTS is the golden entrypoints.fcfg shape: the `use
// pong.{Pong, bindings}` reference and the `entrypoint main { pipeline = Pong,
// tick = 60hz, logical = 160x120, bindings = bindings }` block — the literal
// surface the pong tree carries.
PONG_ENTRYPOINTS :: "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick     = 60hz\n  logical  = 160x120\n  bindings = bindings\n}\n"

@(test)
test_parse_entrypoints_fcfg_happy :: proc(t: ^testing.T) {
	// The golden shape parses to its use reference and its single entrypoint:
	// module `pong`, members {Pong, bindings}, and a `main` entrypoint wiring
	// the Pong pipeline at 60hz with the bindings fn.
	entrypoints, err := parse_entrypoints_fcfg(PONG_ENTRYPOINTS)
	testing.expect_value(t, err, Entrypoints_Error.None)
	testing.expect_value(t, entrypoints.use_module, "pong")
	testing.expect_value(t, len(entrypoints.use_members), 2)
	testing.expect_value(t, entrypoints.use_members[0], "Pong")
	testing.expect_value(t, entrypoints.use_members[1], "bindings")
	testing.expect_value(t, len(entrypoints.entrypoints), 1)
	if len(entrypoints.entrypoints) == 1 {
		block := entrypoints.entrypoints[0]
		testing.expect_value(t, block.name, "main")
		testing.expect_value(t, block.pipeline, "Pong")
		testing.expect_value(t, block.tick, "60hz")
		testing.expect_value(t, block.logical, "160x120")
		testing.expect_value(t, block.bindings, "bindings")
	}
}

@(test)
test_parse_entrypoints_fcfg_missing_key_rejected :: proc(t: ^testing.T) {
	// An entrypoint block missing a required key (tick) is malformed — all
	// four of pipeline/tick/logical/bindings are required.
	content := "use pong.{Pong, bindings}\nentrypoint main {\n  pipeline = Pong\n  logical = 160x120\n  bindings = bindings\n}\n"
	_, err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_parse_entrypoints_fcfg_missing_logical_rejected :: proc(t: ^testing.T) {
	// The logical draw-space extent is a required key (§20 §3 — the present
	// pass letterboxes from the artifact, so an entrypoint cannot omit it).
	content := "use pong.{Pong, bindings}\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  bindings = bindings\n}\n"
	_, err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_parse_entrypoints_fcfg_no_use_rejected :: proc(t: ^testing.T) {
	// The `use` reference is mandatory — an entrypoints.fcfg that opens with an
	// entrypoint block but names no source is malformed.
	content := "entrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  bindings = bindings\n}\n"
	_, err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_parse_entrypoints_fcfg_bad_tick_rejected :: proc(t: ^testing.T) {
	// The tick value must carry the `hz` unit; a bare number rejects.
	content := "use pong.{Pong, bindings}\nentrypoint main {\n  pipeline = Pong\n  tick = 60\n  bindings = bindings\n}\n"
	_, err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_validate_entrypoints_pong_resolves :: proc(t: ^testing.T) {
	// End-to-end: the live pong entrypoints.fcfg parses, and its Pong/bindings
	// references resolve against the parsed pong source module — the Pong
	// pipeline and the bindings fn are both declared. The fixture reads the
	// live golden source (or FUNPACK_PONG_DIR) and SKIPs loudly when absent.
	source, ok := pong_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)

	entrypoints, cfg_err := parse_entrypoints_fcfg(pong_entrypoints_source())
	testing.expect_value(t, cfg_err, Entrypoints_Error.None)
	testing.expect_value(t, validate_entrypoints(entrypoints, ast), Entrypoints_Error.None)
}

@(test)
test_validate_entrypoints_dangling_pipeline_rejected :: proc(t: ^testing.T) {
	// A `pipeline` reference naming a pipeline the module does not declare is a
	// dangling reference and rejects — validation against the source module is
	// the §07 obligation the config reader enforces. The bindings fn still
	// resolves, isolating the pipeline miss.
	source, ok := pong_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)

	content := "use pong.{Missing, bindings}\nentrypoint main {\n  pipeline = Missing\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n"
	entrypoints, cfg_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, cfg_err, Entrypoints_Error.None)
	testing.expect_value(t, validate_entrypoints(entrypoints, ast), Entrypoints_Error.Dangling_Reference)
}

@(test)
test_validate_entrypoints_dangling_bindings_rejected :: proc(t: ^testing.T) {
	// A `bindings` reference naming a fn the module does not declare is also a
	// dangling reference — the pipeline resolves, isolating the bindings miss.
	source, ok := pong_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)

	content := "use pong.{Pong, missing_bindings}\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  logical = 160x120\n  bindings = missing_bindings\n}\n"
	entrypoints, cfg_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, cfg_err, Entrypoints_Error.None)
	testing.expect_value(t, validate_entrypoints(entrypoints, ast), Entrypoints_Error.Dangling_Reference)
}

// pong_entrypoints_source reads the pong project's entrypoints.fcfg via the
// §14 project-tree layout, resolving the same dir pong_source uses; it falls
// back to the embedded golden shape only if the on-disk file is unreadable,
// so the validation tests run against the literal golden surface.
pong_entrypoints_source :: proc() -> string {
	dir := resolve_pong_dir()
	fcfg_path, _ := filepath.join({dir, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(fcfg_path, context.temp_allocator)
	if read_err != nil {
		return PONG_ENTRYPOINTS
	}
	return string(bytes)
}

// ── §14.4 builds.fcfg ──────────────────────────────────────────────────
// parse_builds_fcfg owns the §14.4 builds production of the smaller config
// grammar over the lex_fcfg/Cfg_Parser machinery. These exercise its surface
// directly: the closed platform set, a labelless block, an unknown platform,
// and non-grammar constructs.

@(test)
test_parse_builds_fcfg_happy :: proc(t: ^testing.T) {
	// The arena exemplar shape parses to one `native` target on `desktop` —
	// the build name (the label) is distinct from the platform value.
	builds, err := parse_builds_fcfg("build native {\n  platform = desktop\n}\n")
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(builds.targets), 1)
	if len(builds.targets) == 1 {
		testing.expect_value(t, builds.targets[0].name, "native")
		testing.expect_value(t, builds.targets[0].platform, Build_Platform.Desktop)
	}
}

@(test)
test_parse_builds_fcfg_wasm_and_multiple :: proc(t: ^testing.T) {
	// The grammar generalizes beyond the single golden block: two blocks, one
	// per closed platform, parse in authored order — proving the production
	// reads the grammar, not a single hardcoded block.
	content := "build native {\n  platform = desktop\n}\nbuild web {\n  platform = wasm\n}\n"
	builds, err := parse_builds_fcfg(content)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(builds.targets), 2)
	if len(builds.targets) == 2 {
		testing.expect_value(t, builds.targets[0].platform, Build_Platform.Desktop)
		testing.expect_value(t, builds.targets[1].name, "web")
		testing.expect_value(t, builds.targets[1].platform, Build_Platform.Wasm)
	}
}

@(test)
test_parse_builds_fcfg_empty_is_no_targets :: proc(t: ^testing.T) {
	// An empty (or absent) builds.fcfg is zero declared emit targets, never an
	// error — a tree may declare no targets.
	builds, err := parse_builds_fcfg("")
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(builds.targets), 0)
}

@(test)
test_parse_builds_fcfg_unknown_platform_rejected :: proc(t: ^testing.T) {
	// The platform value is a closed set (§14.6 — desktop|wasm); an unknown
	// platform rejects through the dedicated Malformed_Builds_Fcfg arm, never
	// silently accepted.
	_, err := parse_builds_fcfg("build native {\n  platform = console\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Builds_Fcfg)
}

@(test)
test_parse_builds_fcfg_missing_label_rejected :: proc(t: ^testing.T) {
	// A labelless `build { … }` has no build name — the label is mandatory.
	_, err := parse_builds_fcfg("build {\n  platform = desktop\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Builds_Fcfg)
}

@(test)
test_parse_builds_fcfg_missing_platform_rejected :: proc(t: ^testing.T) {
	// `platform` is the one required key; a block missing it rejects.
	_, err := parse_builds_fcfg("build native {\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Builds_Fcfg)
}

@(test)
test_parse_builds_fcfg_non_grammar_construct_rejected :: proc(t: ^testing.T) {
	// A top-level token that is not a `build` block opener (a stray `use`
	// reference) is outside the builds grammar and rejects.
	_, err := parse_builds_fcfg("use pong.{X}\nbuild native {\n  platform = desktop\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Builds_Fcfg)
}

@(test)
test_parse_builds_fcfg_string_value_rejected :: proc(t: ^testing.T) {
	// The platform value is a bare identifier, never a string literal — a
	// quoted value is not in the block-body grammar.
	_, err := parse_builds_fcfg("build native {\n  platform = \"desktop\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Builds_Fcfg)
}

// ── §14.4 derived-capability tree-walk ─────────────────────────────────
// derive_tree_capabilities walks the four directory-backed subsystem dirs;
// these exercise the OFF/ON arms against scratch trees, independent of the
// arena exemplar.

@(test)
test_derive_tree_capabilities_all_off_no_subsystem_dirs :: proc(t: ^testing.T) {
	// A tree with no subsystem dirs (the pong/numerics shape) derives all four
	// capabilities OFF — absent ⇒ off, the same arm as present-empty — and
	// expects no gen/ seams.
	root, ok := write_scratch_tree(t, "project numerics {\n  version = \"0.1.0\"\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	caps := derive_tree_capabilities(root)
	testing.expect(t, !caps.levels)
	testing.expect(t, !caps.models)
	testing.expect(t, !caps.ui)
	testing.expect(t, !caps.assets)
	testing.expect_value(t, len(caps.expected_gen_out), 0)
}

@(test)
test_derive_tree_capabilities_present_empty_is_off :: proc(t: ^testing.T) {
	// A present-but-empty levels/ derives the levels capability OFF (§14.4 —
	// present-empty ⇒ off, the same arm as absent) and expects no gen/ seam.
	root, ok := write_scratch_tree(t, "project numerics {\n  version = \"0.1.0\"\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	levels_dir := scratch_join({root, "levels"})
	if os.make_directory_all(levels_dir) != nil {
		log.warnf("SKIP present-empty levels: cannot create %s", levels_dir)
		return
	}

	caps := derive_tree_capabilities(root)
	testing.expect(t, !caps.levels)
	testing.expect_value(t, len(caps.expected_gen_out), 0)
}

@(test)
test_derive_tree_capabilities_non_empty_levels_on :: proc(t: ^testing.T) {
	// A levels/ holding an authoring file derives the levels capability ON and
	// expects the matching gen/<stem>.gen.fun seam, derived from the authoring
	// filename. The other three subsystems are absent ⇒ off.
	root, ok := write_scratch_tree(t, "project numerics {\n  version = \"0.1.0\"\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	levels_dir := scratch_join({root, "levels"})
	if os.make_directory_all(levels_dir) != nil ||
	   os.write_entire_file(scratch_join({levels_dir, "arena.flvl"}), "level Arena 2d {\n}\n") != nil {
		log.warnf("SKIP non-empty levels: cannot write under %s", levels_dir)
		return
	}

	caps := derive_tree_capabilities(root)
	testing.expect(t, caps.levels)
	testing.expect(t, !caps.models)
	testing.expect(t, !caps.ui)
	testing.expect(t, !caps.assets)
	testing.expect_value(t, len(caps.expected_gen_out), 1)
	if len(caps.expected_gen_out) == 1 {
		testing.expect_value(t, caps.expected_gen_out[0], "gen/arena.gen.fun")
	}
}

// ── arena exemplar tree (acceptance) ───────────────────────────────────

// test_arena_builds_and_capabilities is the load-bearing acceptance: reading
// the live arena exemplar tree parses builds.fcfg to one `desktop` target and
// derives the §14.4 capability set — a non-empty levels/ ⇒ levels ON with the
// expected gen/arena.gen.fun output, while the other three subsystem dirs
// (absent) derive OFF. It resolves the in-repo examples tree (or
// FUNPACK_ARENA_DIR) and SKIPs loudly when absent, so a missing checkout never
// silently passes.
@(test)
test_arena_builds_and_capabilities :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP arena builds+capabilities: %s not found — set FUNPACK_ARENA_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return
	}

	project, err, _ := read_project(dir)
	testing.expect_value(t, err, Project_Error.None)
	if err != .None {
		return
	}

	// builds.fcfg parses to one `desktop` target.
	testing.expect_value(t, len(project.builds.targets), 1)
	if len(project.builds.targets) == 1 {
		testing.expect_value(t, project.builds.targets[0].platform, Build_Platform.Desktop)
	}

	// levels ON with the expected gen/arena.gen.fun; models/ui/assets OFF.
	caps := project.capabilities
	testing.expect(t, caps.levels)
	testing.expect(t, !caps.models)
	testing.expect(t, !caps.ui)
	testing.expect(t, !caps.assets)
	testing.expect_value(t, len(caps.expected_gen_out), 1)
	if len(caps.expected_gen_out) == 1 {
		testing.expect_value(t, caps.expected_gen_out[0], "gen/arena.gen.fun")
	}
	log.infof(
		"arena §14.4: builds.fcfg → 1 desktop target; levels ON ⇒ gen/arena.gen.fun; models/ui/assets OFF",
	)
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
	return write_scratch_tree_multi(t, fcfg, {src_rel})
}

// write_scratch_tree_multi is write_scratch_tree_at generalized to one
// source per src_rels entry, so a test can materialize multi-module trees —
// including two paths that derive the same module name (the §15.6
// duplicate-module fixture).
write_scratch_tree_multi :: proc(t: ^testing.T, fcfg: string, src_rels: []string) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), fmt.tprintf("funpack-scratch-%d", scratch_seq())})
	// The seq counter resets each process but leftover trees from a
	// crashed prior run persist on disk; clear any stale tree first so a
	// reused root name can never poison the fixture or skip on .Exist.
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	if os.make_directory_all(configs) != nil {
		log.warnf("SKIP scratch tree: cannot create dirs under %s", root)
		return "", false
	}
	fcfg_path := scratch_join({configs, "project.fcfg"})
	if os.write_entire_file(fcfg_path, fcfg) != nil {
		remove_scratch_tree(root)
		log.warnf("SKIP scratch tree: cannot write files under %s", root)
		return "", false
	}
	for src_rel in src_rels {
		src_path := scratch_join({root, "src", src_rel})
		if os.make_directory_all(filepath.dir(src_path)) != nil ||
		   os.write_entire_file(src_path, "@doc(\"scratch\")\n") != nil {
			remove_scratch_tree(root)
			log.warnf("SKIP scratch tree: cannot write files under %s", root)
			return "", false
		}
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
