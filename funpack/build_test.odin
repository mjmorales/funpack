// The build-verb integration golden: the `funpack build` seam (build.odin) read
// against a real §14 project tree must write BOTH the runtime artifact and the
// Index Contract NDJSON on success, write NEITHER on a compile/gate failure, and
// be byte-identical on a re-build (spec §09/§29 end-to-end determinism). These
// tests exercise the integration path on disk — they copy the live pong tree
// into a temp root, build it, and assert the products land — so the CLI exit
// contract (§29 §3) is proven against a real tree, not a hand-shaped stub. The
// compile-error and malformed-tree cases use a deliberately-broken temp tree so
// the exit-2-writes-no-product path is covered. Like the emit/index goldens they
// resolve the sibling pong checkout (or FUNPACK_PONG_DIR) and SKIP loudly when
// it is absent, so a missing checkout never silently passes.
package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// test_build_pong_tree_exits_zero_and_writes_both_products is the load-bearing
// acceptance: building the live pong tree (copied to a temp root) succeeds and
// writes both products under `.funpack/`. It drives the exact stage_build →
// write_build_products path the CLI verb runs, then asserts both files exist on
// disk — the §29 §3 success outcome (exit 0, both products).
@(test)
test_build_pong_tree_exits_zero_and_writes_both_products :: proc(t: ^testing.T) {
	root, ok := copy_pong_tree_to_temp()
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	product, build_err := stage_build(root, context.temp_allocator)
	testing.expect_value(t, build_err, Build_Error.None)
	if build_err != .None {
		return
	}
	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)

	testing.expect(t, os.exists(product.artifact_path))
	testing.expect(t, os.exists(product.index_path))
	// Both products are non-empty: the artifact carries the v1 magic line and
	// the NDJSON carries the schema_version object.
	testing.expect(t, strings.has_prefix(product.artifact, ARTIFACT_MAGIC))
	testing.expect(t, strings.has_prefix(product.index, "{\"schema_version\":"))
	log.infof("build verb: pong tree build exits 0 and writes both products (artifact + index NDJSON)")
}

// test_build_pong_double_build_identical proves the build is deterministic end
// to end (spec §09/§29): building the same pong tree twice writes byte-identical
// artifact AND byte-identical Index Contract NDJSON. The output paths are derived
// from the project root with no machine-specific component, so the bytes carry no
// datum that varies between builds.
@(test)
test_build_pong_double_build_identical :: proc(t: ^testing.T) {
	root, ok := copy_pong_tree_to_temp()
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	first, first_err := stage_build(root, context.temp_allocator)
	testing.expect_value(t, first_err, Build_Error.None)
	second, second_err := stage_build(root, context.temp_allocator)
	testing.expect_value(t, second_err, Build_Error.None)
	if first_err != .None || second_err != .None {
		return
	}
	testing.expect(t, first.artifact == second.artifact)
	testing.expect(t, first.index == second.index)
	if first.artifact == second.artifact && first.index == second.index {
		// A passing-run confirmation the acceptance gate reads: the double build
		// is byte-identical for both products (end-to-end determinism).
		log.infof(
			"build identical: double build of pong is byte-identical artifact (%d bytes) and index NDJSON (%d bytes)",
			len(first.artifact),
			len(first.index),
		)
	}
}

// test_build_double_build_identical_no_checkout proves the build is
// deterministic without the sibling pong checkout: it materializes a minimal
// valid §14 tree in temp, builds it twice, and asserts byte-identical artifact
// AND byte-identical Index Contract NDJSON. The output paths derive from the
// project root with no machine-specific component, so the bytes carry no datum
// that varies between builds — the end-to-end bit-identity obligation (spec
// §09/§29), provable on every host regardless of the checkout.
@(test)
test_build_double_build_identical_no_checkout :: proc(t: ^testing.T) {
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	first, first_err := stage_build(root, context.temp_allocator)
	testing.expect_value(t, first_err, Build_Error.None)
	second, second_err := stage_build(root, context.temp_allocator)
	testing.expect_value(t, second_err, Build_Error.None)
	if first_err != .None || second_err != .None {
		return
	}
	testing.expect(t, first.artifact == second.artifact)
	testing.expect(t, first.index == second.index)
	if first.artifact == second.artifact && first.index == second.index {
		// A passing-run confirmation the acceptance gate reads: a double build of
		// the same tree is byte-identical for both products (end-to-end
		// determinism), without depending on the sibling checkout.
		log.infof(
			"double build identical: building the same tree twice is byte-identical artifact (%d bytes) and index NDJSON (%d bytes)",
			len(first.artifact),
			len(first.index),
		)
	}
}

// test_build_compile_error_exits_two_writes_no_artifact covers the §29 §3
// failure outcome: a deliberately-broken source on an otherwise-valid §14 tree
// fails the checked pipeline, so stage_build returns Compile_Failed and writes no
// product. A compile error is NEVER a counted failure (the build verb has no
// assertion tier) — it is the exit-2 path, and no artifact lands on disk.
@(test)
test_build_compile_error_exits_two_writes_no_artifact :: proc(t: ^testing.T) {
	root, ok := write_broken_pong_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, build_err := stage_build(root, context.temp_allocator)
	// The broken source parses to a malformed program the checked pipeline
	// rejects, so the build refuses with Compile_Failed and emits nothing.
	testing.expect_value(t, build_err, Build_Error.Compile_Failed)

	// No artifact and no index were written: stage_build returns before the
	// write side, so the derived `.funpack/` products are absent.
	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	index_path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, !os.exists(artifact_path))
	testing.expect(t, !os.exists(index_path))
	log.infof("build exit 2: compile error on the project tree writes no artifact (the build is exit 2, never a counted failure)")
}

// test_build_malformed_tree_exits_two covers the malformed-§14-tree failure: a
// tree missing funpack_configs/ is rejected by read_project, so stage_build
// returns Malformed_Tree (the exit-2 path) and writes no product. A malformed
// tree and a compile error share the exit-2 outcome — the build emits both
// products or none.
@(test)
test_build_malformed_tree_exits_two :: proc(t: ^testing.T) {
	root := scratch_join({scratch_base(), tprintf_seq("funpack-build-malformed")})
	remove_scratch_tree(root)
	if !ensure_dir(root) {
		log.warnf("SKIP build malformed tree: cannot create %s", root)
		return
	}
	defer remove_scratch_tree(root)
	// The root has no funpack_configs/ — read_project rejects it, so the build
	// is a malformed-tree exit-2.
	_, build_err := stage_build(root, context.temp_allocator)
	testing.expect_value(t, build_err, Build_Error.Malformed_Tree)
}

// ── Helpers ────────────────────────────────────────────────────────────

// copy_pong_tree_to_temp copies the live pong project tree into a fresh temp
// root so a build test can write derived products without touching the committed
// checkout. ok = false (with the golden SKIP semantics) when the sibling pong
// checkout is absent or the copy fails. The copy is recursive over the tree's
// regular files, recreating the directory structure under the temp root.
copy_pong_tree_to_temp :: proc() -> (root: string, ok: bool) {
	src := resolve_pong_dir()
	if !os.is_dir(src) {
		log.warnf("SKIP build pong: %s not found — set FUNPACK_PONG_DIR or check out funpack-spec as a sibling", src)
		return "", false
	}
	root = scratch_join({scratch_base(), tprintf_seq("funpack-build-pong")})
	remove_scratch_tree(root)
	if !copy_tree(src, root) {
		remove_scratch_tree(root)
		log.warnf("SKIP build pong: cannot copy pong tree into %s", root)
		return "", false
	}
	return root, true
}

// copy_tree recursively copies every regular file under `src` into `dst`,
// recreating the interior directory structure. It is scoped to the build test's
// fixture need (materialize a real §14 tree in temp) — it copies file bytes
// verbatim and skips non-regular entries, so the copied tree is a faithful build
// input. false on any directory-create or file-write failure.
copy_tree :: proc(src: string, dst: string) -> bool {
	if !ensure_dir(dst) {
		return false
	}
	walker := os.walker_create(src)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular {
			continue
		}
		rel, rel_err := filepath.rel(src, info.fullpath, context.temp_allocator)
		if rel_err != .None {
			return false
		}
		dst_path := scratch_join({dst, rel})
		if !ensure_dir(filepath.dir(dst_path)) {
			return false
		}
		bytes, read_err := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
		if read_err != nil {
			return false
		}
		if os.write_entire_file(dst_path, bytes) != nil {
			return false
		}
	}
	return true
}

// ensure_dir creates a directory and its parents idempotently: an
// already-present directory is success, not an error. os.make_directory_all
// reports General_Error.Exist when the path already exists, so a recursive copy
// that touches a shared parent more than once treats that as a no-op rather than
// a failure.
ensure_dir :: proc(path: string) -> bool {
	err := os.make_directory_all(path)
	return err == nil || err == os.General_Error.Exist
}

// write_broken_pong_tree materializes a §14 tree whose configs are valid but
// whose single source is a deliberately-malformed program the checked pipeline
// rejects, so stage_build reaches the compile floor and refuses with
// Compile_Failed. The configs mirror the pong tree (so read_project and the
// index's authored read succeed) — only the source is broken, isolating the
// failure to the compile floor rather than a tree-shape error.
write_broken_pong_tree :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), tprintf_seq("funpack-build-broken")})
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	src_path := scratch_join({root, "src", "pong.fun"})
	if !ensure_dir(configs) || !ensure_dir(filepath.dir(src_path)) {
		log.warnf("SKIP build broken tree: cannot create dirs under %s", root)
		return "", false
	}
	ok_writes :=
		os.write_entire_file(scratch_join({configs, "project.fcfg"}), "project pong {\n  version = \"0.1.0\"\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "entrypoints.fcfg"}), "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  bindings = bindings\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "builds.fcfg"}), "build native {\n  platform = desktop\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "tags.fcfg"}), "tags {\n  game\n}\n") == nil &&
		// A source that fails to parse — a `fn` head with no body and a dangling
		// brace — so the checked pipeline rejects it at the parse floor.
		os.write_entire_file(src_path, "fn broken( {\n") == nil
	if !ok_writes {
		remove_scratch_tree(root)
		log.warnf("SKIP build broken tree: cannot write files under %s", root)
		return "", false
	}
	return root, true
}

// write_minimal_valid_tree materializes a minimal valid §14 project tree whose
// configs and single source all compile, so stage_build emits both products. The
// source is a lone `@doc` declaration with no pipeline — it parses, types, and
// flattens to the empty schedule, exercising the full build path without
// reproducing the pong source. It is the pong-independent fixture the
// determinism test builds twice, so the byte-identity check holds on any host.
write_minimal_valid_tree :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), tprintf_seq("funpack-build-mini")})
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	src_path := scratch_join({root, "src", "mini.fun"})
	if !ensure_dir(configs) || !ensure_dir(filepath.dir(src_path)) {
		log.warnf("SKIP build minimal tree: cannot create dirs under %s", root)
		return "", false
	}
	ok_writes :=
		os.write_entire_file(scratch_join({configs, "project.fcfg"}), "project mini {\n  version = \"0.1.0\"\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "entrypoints.fcfg"}), "use mini.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  bindings = bindings\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "builds.fcfg"}), "build native {\n  platform = desktop\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "tags.fcfg"}), "tags {\n  game\n}\n") == nil &&
		os.write_entire_file(src_path, "@doc(\"scratch\")\n") == nil
	if !ok_writes {
		remove_scratch_tree(root)
		log.warnf("SKIP build minimal tree: cannot write files under %s", root)
		return "", false
	}
	return root, true
}

// tprintf_seq builds a per-process-unique scratch dir name from a prefix and the
// shared scratch sequence counter, so concurrently-scheduled build tests never
// collide on a temp root.
tprintf_seq :: proc(prefix: string) -> string {
	return fmt.tprintf("%s-%d", prefix, scratch_seq())
}
