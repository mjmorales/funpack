// The docs disk-projection junction. Every proc exercises the materializer
// (mcp_docs_export.odin) over the REAL embedded corpus (load_corpus) into a temp root,
// asserting the four invariants the ADR pins: faithful reconstruction (one file per
// source, greppable anchor markers), byte-determinism (a re-render is identical),
// idempotence (a second export with a matching sentinel is a no-op), and graceful
// degradation (no managed home → no path, never a fault).
//
// Define-free, so these run on the default `odin test .` floor.
package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// export_test_sections loads the real committed corpus, failing if empty — the
// production-data discipline the other docs tests hold.
@(private = "file")
export_test_sections :: proc(t: ^testing.T) -> []Corpus_Section {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus must parse")
	testing.expect(t, len(sections) > 0, "corpus is empty — run `funpack mcp gen-corpus`")
	return sections
}

// export_test_tmp_base resolves a writable temp base ($TMPDIR or /tmp), mirroring the
// TMPDIR pattern the session/observe tests use.
@(private = "file")
export_test_tmp_base :: proc(allocator := context.allocator) -> string {
	base := os.get_env("TMPDIR", allocator)
	if strings.trim_space(base) == "" {
		return "/tmp"
	}
	return base
}

// export_test_root mints a per-test projection root under the OS temp dir, keyed by the
// test name so parallel tests never collide. It best-effort removes any stale completion
// sentinel from a prior run so the test starts from a known "not yet materialized" state
// (the temp dir persists across runs; clearing the sentinel forces a deterministic
// rewrite). The dir need not pre-exist — docs_export_write mkdirs it.
@(private = "file")
export_test_root :: proc(name: string, allocator := context.allocator) -> string {
	root := corpus_join({export_test_tmp_base(allocator), strings.concatenate({"funpack-docs-export-", name}, allocator)}, allocator)
	os.remove(corpus_join({root, DOCS_EXPORT_SENTINEL}, allocator))
	return root
}

// test_export_writes_one_file_per_source asserts the reconstruction contract: every
// distinct corpus source becomes exactly one on-disk file under the root, and each file
// carries the greppable anchor marker for every section it holds.
@(test)
test_export_writes_one_file_per_source :: proc(t: ^testing.T) {
	sections := export_test_sections(t)
	root := export_test_root("one-file-per-source", context.temp_allocator)

	wrote, ok := docs_export_write(root, "test-v", sections, context.temp_allocator)
	testing.expect(t, ok, "export must succeed into a fresh temp root")
	testing.expect(t, wrote, "a fresh root with no sentinel must actually write")

	// Pick a representative section and assert its file exists, sits at <root>/<source>,
	// and contains its anchor marker.
	sample := sections[0]
	path := corpus_join({root, sample.source}, context.temp_allocator)
	data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, read_err == nil, "the sample section's source file must be materialized")

	body := string(data)
	marker := strings.concatenate({"<!-- anchor: ", sample.anchor}, context.temp_allocator)
	testing.expect(t, strings.contains(body, marker), "materialized file must carry the section's anchor marker")
	testing.expect(t, strings.contains(body, sample.title), "materialized file must carry the section title")
}

// test_export_is_byte_deterministic asserts a re-render of the same group produces
// identical bytes — the content-stability the projection relies on.
@(test)
test_export_is_byte_deterministic :: proc(t: ^testing.T) {
	sections := export_test_sections(t)
	groups := docs_export_group(sections, context.temp_allocator)
	testing.expect(t, len(groups) > 0, "grouping must yield at least one source")

	first := docs_export_render_file(sections, groups[0], context.temp_allocator)
	again := docs_export_render_file(sections, groups[0], context.temp_allocator)
	testing.expect(t, first == again, "two renders of one group must be byte-identical")
}

// test_export_groups_cover_every_section asserts the grouping is total and disjoint:
// the indices across all groups are exactly the corpus index set, so no section is
// dropped or duplicated when reconstructing files.
@(test)
test_export_groups_cover_every_section :: proc(t: ^testing.T) {
	sections := export_test_sections(t)
	groups := docs_export_group(sections, context.temp_allocator)

	seen := make(map[int]bool, len(sections), context.temp_allocator)
	count := 0
	for g in groups {
		for idx in g.indices {
			testing.expect(t, !seen[idx], "no section index may appear in two groups")
			seen[idx] = true
			count += 1
		}
	}
	testing.expectf(t, count == len(sections), "grouping must cover all %d sections, covered %d", len(sections), count)
}

// test_export_is_idempotent asserts a second export against a root whose sentinel
// matches the version short-circuits to a no-op (wrote=false, ok=true) — the
// startup-once contract.
@(test)
test_export_is_idempotent :: proc(t: ^testing.T) {
	sections := export_test_sections(t)
	root := export_test_root("idempotent", context.temp_allocator)

	wrote1, ok1 := docs_export_write(root, "v1", sections, context.temp_allocator)
	testing.expect(t, ok1 && wrote1, "first export writes")

	wrote2, ok2 := docs_export_write(root, "v1", sections, context.temp_allocator)
	testing.expect(t, ok2, "second export succeeds")
	testing.expect(t, !wrote2, "second export with a matching sentinel is a no-op")

	// A version change invalidates the sentinel and forces a re-materialize.
	wrote3, ok3 := docs_export_write(root, "v2", sections, context.temp_allocator)
	testing.expect(t, ok3 && wrote3, "a version bump re-materializes the tree")
}

// test_export_root_and_startup_hook pins the resolver AND the server-startup hook in ONE
// test so all HOME mutation is serial within a single proc — HOME is process-global, and
// the parallel test runner would otherwise race a set against an unset across two tests.
// With HOME set: the root is absolute and version-keyed under .funpack/docs, and the
// startup hook (mcp_materialize_docs_projection) writes a sentinel-bearing tree there. With
// HOME unset: the resolver reports ok=false and the startup hook degrades to ok=false
// without aborting — the graceful path the renderer reads to omit `path`.
@(test)
test_export_root_and_startup_hook :: proc(t: ^testing.T) {
	saved := os.get_env("HOME", context.temp_allocator)
	defer if saved != "" {
		os.set_env("HOME", saved)
	} else {
		os.unset_env("HOME")
	}

	manifest, _ := load_manifest(context.temp_allocator)
	version := docs_normalize_version(manifest.funpack_version)
	testing.expect(t, version != "", "the committed manifest carries a funpack version")

	// With HOME set under a temp base, the root is absolute and version-keyed, and the
	// startup hook materializes a sentinel-bearing tree at exactly that root.
	home := corpus_join({export_test_tmp_base(context.temp_allocator), "funpack-docs-startup-home"}, context.temp_allocator)
	os.remove(corpus_join({home, DOCS_EXPORT_HOME_SUBDIR, DOCS_EXPORT_DOCS_SEGMENT, version, DOCS_EXPORT_SENTINEL}, context.temp_allocator))
	os.set_env("HOME", home)

	root, ok := docs_export_root(manifest, context.temp_allocator)
	testing.expect(t, ok, "with HOME set the root resolves")
	testing.expect(t, filepath.is_abs(root), "the resolved root is absolute")
	expected_parent := corpus_join({DOCS_EXPORT_HOME_SUBDIR, DOCS_EXPORT_DOCS_SEGMENT, version}, context.temp_allocator)
	testing.expect(t, strings.has_suffix(root, expected_parent), "root must sit under .funpack/docs/<version>")

	hook_root, hook_ok := mcp_materialize_docs_projection(context.temp_allocator)
	testing.expect(t, hook_ok, "the startup hook materializes with a writable HOME")
	testing.expect(t, hook_root == root, "the hook writes to the resolved root")
	_, sentinel_err := os.read_entire_file_from_path(corpus_join({root, DOCS_EXPORT_SENTINEL}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, sentinel_err == nil, "the startup hook leaves a completion sentinel")

	// With HOME unset, both the resolver and the hook degrade rather than aborting.
	os.unset_env("HOME")
	_, ok_missing := docs_export_root(manifest, context.temp_allocator)
	testing.expect(t, !ok_missing, "a missing HOME must yield ok=false, not a fabricated path")
	_, hook_missing := mcp_materialize_docs_projection(context.temp_allocator)
	testing.expect(t, !hook_missing, "the startup hook degrades (ok=false) without a writable HOME")
}
