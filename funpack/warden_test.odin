// The warden verb dispatch tests: parse_warden_command's totality over the
// closed subcommand set (every name maps, a missing/unknown/trailing argument
// is the usage path — the parse_build_mode contract mirrored), and
// warden_verb_exit's {0, 2} exit contract over real planted roots — a
// really-emitted index decodes to 0 on EVERY command, an absent product and a
// doctored schema_version each refuse 2 (the acquisition + exact-match decode
// substrate, never a file-exists probe). There is deliberately no exit-1
// case to pin: the warden has no assertion tier (§29 §3), so the contract's
// whole image is {0, 2}. Roots ride the warden_stream_fixture /
// write_warden_index_product scratch idiom from index_read_test.odin.
package funpack

import "core:log"
import "core:testing"

// test_parse_warden_command_totality pins the closed set both ways: the five
// argumentless subcommand names map to their enum member with an empty
// positional and the zero query, bare `find` is the FILTERLESS usage error
// (find answers a lookup, never dumps the index — §29 §4; its full filter
// shape is pinned in test_parse_warden_command_find_query), and every
// non-command shape — an empty argument list, an unknown name, a trailing
// argument on a zero-positional command — is ok = false, the path main maps
// to usage + exit 2. A typo never silently runs a different query.
@(test)
test_parse_warden_command_totality :: proc(t: ^testing.T) {
	names := [Warden_Command]string {
		.Find     = "find",
		.Holes    = "holes",
		.Debt     = "debt",
		.Graph    = "graph",
		.Tags     = "tags",
		.Pipeline = "pipeline",
	}
	for name, want in names {
		cmd, arg, find, ok := parse_warden_command({name})
		if want == .Find {
			testing.expect(t, !ok)
			continue
		}
		testing.expect(t, ok)
		testing.expect_value(t, cmd, want)
		testing.expect_value(t, arg, "")
		testing.expect_value(t, find, Warden_Find_Query{})
	}

	_, _, _, ok := parse_warden_command({})
	testing.expect(t, !ok)

	_, _, _, ok = parse_warden_command({"fnid"})
	testing.expect(t, !ok)

	_, _, _, ok = parse_warden_command({"tags", "extra"})
	testing.expect(t, !ok)
}

// test_parse_warden_command_graph_positional pins graph's per-command arity:
// graph admits ONE optional positional (the incident-edge filter, carried
// verbatim), a second positional is the usage error, and the optional arity
// is graph's alone — a positional on any other command stays ok = false, so
// extending the seam did not loosen the strict commands.
@(test)
test_parse_warden_command_graph_positional :: proc(t: ^testing.T) {
	cmd, arg, _, ok := parse_warden_command({"graph", "drift.damped"})
	testing.expect(t, ok)
	testing.expect_value(t, cmd, Warden_Command.Graph)
	testing.expect_value(t, arg, "drift.damped")

	_, _, _, ok = parse_warden_command({"graph", "drift.damped", "extra"})
	testing.expect(t, !ok)

	_, _, _, ok = parse_warden_command({"holes", "drift.damped"})
	testing.expect(t, !ok)

	_, _, _, ok = parse_warden_command({"pipeline", "drift.damped"})
	testing.expect(t, !ok)
}

// test_parse_warden_command_find_query pins find's per-command flag
// extension of the parse seam: a positional name-query, --kind, and --gtag
// each parse alone and all together; the filterless bare `find` and every
// malformed shape — an unknown kind name (exact against the closed
// Index_Decl_Kind member names, never fuzzy or case-folded), a flag with a
// missing or empty value, a duplicate flag, a second positional, an unknown
// flag — are ok = false, adjudicated at parse BEFORE any index read so the
// usage exit 2 holds in any directory. The other commands never admit find's
// flags through this extension (the strict-arity cases above are untouched).
@(test)
test_parse_warden_command_find_query :: proc(t: ^testing.T) {
	cmd, arg, find, ok := parse_warden_command({"find", "damped"})
	testing.expect(t, ok)
	testing.expect_value(t, cmd, Warden_Command.Find)
	testing.expect_value(t, arg, "")
	testing.expect_value(t, find, Warden_Find_Query{name = "damped"})

	_, _, find, ok = parse_warden_command({"find", "--kind", "Extern_Fn"})
	testing.expect(t, ok)
	testing.expect_value(t, find, Warden_Find_Query{kind = "Extern_Fn"})

	_, _, find, ok = parse_warden_command({"find", "--gtag", "debt"})
	testing.expect(t, ok)
	testing.expect_value(t, find, Warden_Find_Query{gtag = "debt"})

	_, _, find, ok = parse_warden_command({"find", "damped", "--kind", "Fn", "--gtag", "physics"})
	testing.expect(t, ok)
	testing.expect_value(t, find, Warden_Find_Query{name = "damped", kind = "Fn", gtag = "physics"})

	// The usage tier: each malformed shape refuses at parse.
	rejected := [][]string {
		{"find"},                               // filterless — find is not the index dump
		{"find", "--kind", "fn"},               // kind names are exact, never case-folded
		{"find", "--kind", "Widget"},           // unknown kind name, never a fuzzy match
		{"find", "--kind"},                     // missing flag value
		{"find", "--gtag"},                     // missing flag value
		{"find", "--gtag", ""},                 // empty flag value
		{"find", ""},                           // empty name-query (a disguised dump)
		{"find", "a", "b"},                     // second positional
		{"find", "--kind", "Fn", "--kind", "Fn"}, // duplicate flag
		{"find", "--glob", "x"},                // unknown flag
	}
	for shape in rejected {
		_, _, _, shape_ok := parse_warden_command(shape)
		testing.expect(t, !shape_ok)
	}
}

// test_warden_verb_exit_planted_index_zero is the success tier: a
// really-emitted Index Contract stream planted under a scratch root's
// .funpack/ decodes whole, so warden_verb_exit is 0 — for EVERY command,
// because each rides the same acquisition + decode substrate (the projection
// seam differs per command; the exit contract does not).
@(test)
test_warden_verb_exit_planted_index_zero :: proc(t: ^testing.T) {
	root, stream, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	if !write_warden_index_product(t, root, stream) {
		return
	}
	for cmd in Warden_Command {
		testing.expect_value(t, warden_verb_exit(root, cmd), 0)
	}
	log.infof("warden exit: a planted emitted index decodes whole and every command exits 0")
}

// test_warden_verb_exit_missing_index_two is the absent-product refusal: a
// root with no .funpack/ at all is the Missing_Index refusal mapped to exit 2
// — the warden never recompiles in the missing product's place (§29 §1), it
// refuses and names `funpack build`.
@(test)
test_warden_verb_exit_missing_index_two :: proc(t: ^testing.T) {
	root := scratch_join({scratch_base(), tprintf_seq("funpack-warden-verb")})
	remove_scratch_tree(root)
	if !ensure_dir(root) {
		log.warnf("SKIP warden missing index: cannot create %s", root)
		return
	}
	defer remove_scratch_tree(root)

	testing.expect_value(t, warden_verb_exit(root, .Find), 2)
}

// test_warden_verb_exit_schema_mismatch_two is the doctored-index refusal: a
// planted stream whose schema_version stamp was rewritten refuses the whole
// decode as Schema_Mismatch, so the verb exits 2 — the exact-match decode
// fires on every query, proving the substrate is the full acquisition and
// never a file-exists probe (a probe would have exited 0 here).
@(test)
test_warden_verb_exit_schema_mismatch_two :: proc(t: ^testing.T) {
	root, stream, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	doctored := mutate_line(t, stream, "\"schema_version\":2", "\"schema_version\":1")
	if !write_warden_index_product(t, root, doctored) {
		return
	}
	testing.expect_value(t, warden_verb_exit(root, .Holes), 2)
	log.infof("warden exit: a schema-mismatched index refuses exit 2 — the verb decodes, it does not probe")
}
