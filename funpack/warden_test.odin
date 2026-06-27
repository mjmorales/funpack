package funpack

import "core:log"
import "core:testing"

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

@(test)
test_warden_verb_exit_schema_mismatch_two :: proc(t: ^testing.T) {
	root, stream, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	doctored := mutate_line(t, stream, "\"schema_version\":6", "\"schema_version\":1")
	if !write_warden_index_product(t, root, doctored) {
		return
	}
	testing.expect_value(t, warden_verb_exit(root, .Holes), 2)
	log.infof("warden exit: a schema-mismatched index refuses exit 2 — the verb decodes, it does not probe")
}
