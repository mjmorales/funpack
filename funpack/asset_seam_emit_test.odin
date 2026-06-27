package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

ASSETS_GEN_DEFAULT_REL :: "examples/assets/gen/assets.gen.fun"

resolve_assets_gen_path :: proc() -> string {
	return resolve_spec_dir("FUNPACK_ASSETS_GEN", ASSETS_GEN_DEFAULT_REL)
}

example_assets_manifest :: proc(allocator := context.allocator) -> Asset_Manifest {
	entries := make([]Asset_Entry, 3, allocator)
	entries[0] = Asset_Entry{name = "coin", kind = .Model}
	entries[1] = Asset_Entry{name = "pickups", kind = .Atlas}
	entries[2] = Asset_Entry{name = "coin_sfx", kind = .Audio}
	return Asset_Manifest{entries = entries}
}

example_assets_docs :: proc(allocator := context.allocator) -> []string {
	docs := make([]string, 3, allocator)
	docs[0] = "The coin model's mesh. Generated from the manifest — edit the source, not this file; a rename propagates as a compile error in every reader."
	docs[1] = "The pickups sprite atlas (cells coin/gem/key, clip spin)."
	docs[2] = "The coin pickup chime."
	return docs
}

@(test)
test_emit_assets_gen_fun_byte_matches_golden :: proc(t: ^testing.T) {
	path := resolve_assets_gen_path()
	golden_bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		log.warnf(
			"SKIP assets gen-emit: %s not found — set FUNPACK_ASSETS_GEN or ensure the in-repo fixture exists",
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
	log.infof("assets gen-emit golden: assets.gen.fun reproduces the exemplar byte-for-byte (%d bytes)", len(emitted))
}

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

@(test)
test_assets_import_line_is_first_use_order :: proc(t: ^testing.T) {
	entries := make([]Asset_Entry, 3, context.temp_allocator)
	entries[0] = Asset_Entry{name = "a", kind = .Model}
	entries[1] = Asset_Entry{name = "b", kind = .Model}
	entries[2] = Asset_Entry{name = "c", kind = .Atlas}
	manifest := Asset_Manifest{entries = entries}
	docs := []string{"a doc", "b doc", "c doc"}

	emitted := emit_assets_gen_fun(manifest, docs, context.temp_allocator)
	expected_import := "import engine.assets.{MeshHandle, AtlasHandle}\n"
	testing.expect(t, contains_substring(emitted, expected_import))
	testing.expect(t, !contains_substring(emitted, "SoundHandle"))
}

@(test)
test_resolve_assets_gen_path_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_assets_gen_path()))
}

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
