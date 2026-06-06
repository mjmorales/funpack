// The §19 §3 asset-seam-emitter golden: a hand-built (manifest, docs) pair
// corresponding to the committed exemplar funpack-spec/examples/assets/gen/
// assets.gen.fun, emitted through emit_assets_gen_fun, must reproduce that
// exemplar byte-for-byte, and emitting the same inputs twice must be byte-
// identical (spec §09/§29 purity). Like the .flvl/arena seam golden
// (gen_emit_test.odin), the inputs are built BY HAND here — never parsed from the
// file — so the test pins the emitter's byte contract, not a round-trip; it
// resolves the live exemplar (or FUNPACK_ASSETS_GEN) and SKIPs loudly when the
// funpack-spec sibling is absent (a skipped golden is a warning, never a pass).
//
// WHY THE DOCS ARE HAND-BUILT: the manifest carries the registry (names, kinds,
// order) but not the per-asset prose @doc strings — those are authored content no
// upstream artifact produces (asset_seam_emit.odin documents the sourcing). So the
// test supplies the docs that match the exemplar, exactly as arena_seam carries
// its declaration docs in the Seam model.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// ASSETS_GEN_DEFAULT_REL is the committed exemplar's path relative to the main
// checkout root, resolved through resolve_spec_dir so it survives an orchestrator
// task-worktree #directory (the same resolution the other goldens use).
ASSETS_GEN_DEFAULT_REL :: "../funpack-spec/examples/assets/gen/assets.gen.fun"

// resolve_assets_gen_path resolves the committed assets.gen.fun exemplar: the
// FUNPACK_ASSETS_GEN env override when set, else the sibling-checkout default
// anchored at the main checkout root. The path points at the file, not a dir.
resolve_assets_gen_path :: proc() -> string {
	return resolve_spec_dir("FUNPACK_ASSETS_GEN", ASSETS_GEN_DEFAULT_REL)
}

// example_assets_manifest builds, by hand, the Asset_Manifest the committed
// examples/assets/assets.manifest reads to — three entries in committed order
// (coin/model, pickups/atlas, coin_sfx/audio). Only the fields the emitter reads
// (name, kind) are filled with their golden values; the rest carry placeholder
// content the seam does not render, so the model pins the emitter's input shape,
// not the manifest reader (which asset_manifest_test.odin covers).
example_assets_manifest :: proc(allocator := context.allocator) -> Asset_Manifest {
	entries := make([]Asset_Entry, 3, allocator)
	entries[0] = Asset_Entry{name = "coin", kind = .Model}
	entries[1] = Asset_Entry{name = "pickups", kind = .Atlas}
	entries[2] = Asset_Entry{name = "coin_sfx", kind = .Audio}
	return Asset_Manifest{entries = entries}
}

// example_assets_docs is the per-asset @doc prose parallel to
// example_assets_manifest, one entry per asset in the same order — the authored
// layer the baker carries over the registry. Verbatim from the committed
// exemplar's per-handle @doc lines (the em-dash and apostrophes kept so the byte
// comparison exercises multibyte and quote-adjacent content).
example_assets_docs :: proc(allocator := context.allocator) -> []string {
	docs := make([]string, 3, allocator)
	docs[0] = "The coin model's mesh. Generated from the manifest — edit the source, not this file; a rename propagates as a compile error in every reader."
	docs[1] = "The pickups sprite atlas (cells coin/gem/key, clip spin)."
	docs[2] = "The coin pickup chime."
	return docs
}

// test_emit_assets_gen_fun_byte_matches_golden is the load-bearing acceptance: the
// hand-built (manifest, docs) pair, emitted through emit_assets_gen_fun,
// reproduces the committed assets.gen.fun exemplar byte-for-byte. A diff in any
// byte — a doc character, an import member, the @gtag line, a handle's name, the
// trailing newline — fails here. SKIPs loudly when the sibling checkout is absent.
@(test)
test_emit_assets_gen_fun_byte_matches_golden :: proc(t: ^testing.T) {
	path := resolve_assets_gen_path()
	golden_bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		log.warnf(
			"SKIP assets gen-emit: %s not found — set FUNPACK_ASSETS_GEN or check out funpack-spec as a sibling of the repo",
			path,
		)
		return
	}
	golden := string(golden_bytes)

	manifest := example_assets_manifest(context.temp_allocator)
	docs := example_assets_docs(context.temp_allocator)
	emitted := emit_assets_gen_fun(manifest, docs, context.temp_allocator)

	testing.expect_value(t, len(emitted), len(golden))
	testing.expect(t, emitted == golden)
	if emitted != golden {
		report_first_byte_diff(emitted, golden)
		return
	}
	// odin test echoes a name only on failure, so announce the byte match so a
	// passing run leaves a trace the acceptance gate can read.
	log.infof("assets gen-emit golden: assets.gen.fun reproduces the exemplar byte-for-byte (%d bytes)", len(emitted))
}

// test_assets_gen_fun_double_emit_identical proves emission is deterministic (spec
// §09, §29): two emissions of the same hand-built (manifest, docs) pair are
// byte-identical, so the seam bytes carry no field whose value depends on when,
// where, or on which machine they were emitted. Self-contained — no golden
// checkout needed.
@(test)
test_assets_gen_fun_double_emit_identical :: proc(t: ^testing.T) {
	manifest := example_assets_manifest(context.temp_allocator)
	docs := example_assets_docs(context.temp_allocator)
	first := emit_assets_gen_fun(manifest, docs, context.temp_allocator)
	second := emit_assets_gen_fun(manifest, docs, context.temp_allocator)
	testing.expect(t, first == second)
	testing.expect_value(t, len(first), len(second))
	if first == second {
		log.infof("assets gen-emit double emit: two emissions are byte-identical (deterministic emit, %d bytes)", len(first))
	}
}

// test_assets_import_line_is_first_use_order pins the import-member ordering in
// isolation: the `import engine.assets.{…}` line carries the handle types in
// first-use order across the manifest entries, deduplicated — so an assets file
// using only one kind imports only that handle. A manifest registering two models
// then one atlas imports {MeshHandle, AtlasHandle}, not the enum order or a
// duplicate MeshHandle. Self-contained.
@(test)
test_assets_import_line_is_first_use_order :: proc(t: ^testing.T) {
	entries := make([]Asset_Entry, 3, context.temp_allocator)
	entries[0] = Asset_Entry{name = "a", kind = .Model}
	entries[1] = Asset_Entry{name = "b", kind = .Model}
	entries[2] = Asset_Entry{name = "c", kind = .Atlas}
	manifest := Asset_Manifest{entries = entries}
	docs := []string{"a doc", "b doc", "c doc"}

	emitted := emit_assets_gen_fun(manifest, docs, context.temp_allocator)
	// Two models then one atlas → MeshHandle once (first use), then AtlasHandle.
	expected_import := "import engine.assets.{MeshHandle, AtlasHandle}\n"
	testing.expect(t, contains_substring(emitted, expected_import))
	// SoundHandle is never used here, so it must not appear in the import line.
	testing.expect(t, !contains_substring(emitted, "SoundHandle"))
}

// test_resolve_assets_gen_path_is_absolute keeps the exemplar resolver honest: the
// resolved path is absolute (so a bare `odin test .` from any cwd, and a worktree
// validation run, resolve the same sibling file).
@(test)
test_resolve_assets_gen_path_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_assets_gen_path()))
}

// contains_substring is a small test-local substring probe: it reports whether
// `haystack` contains `needle` anywhere. Used to assert the import line appears in
// the emitted seam without pinning its surrounding bytes (the byte-match test pins
// the whole file; this isolates the import-ordering invariant).
contains_substring :: proc(haystack: string, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle {
			return true
		}
	}
	return false
}
