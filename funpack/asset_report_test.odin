package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

ASSETS_REPORT_DEFAULT_REL :: "examples/assets/assets/assets.report.txt"

resolve_assets_report_path :: proc() -> string {
	return resolve_spec_dir("FUNPACK_ASSETS_REPORT", ASSETS_REPORT_DEFAULT_REL)
}

report_example_inputs :: proc(
	allocator := context.allocator,
) -> (
	reach: Asset_Reach,
	kept: []Asset_Entry,
	stripped: []Asset_Entry,
	sizes: []Asset_Size,
) {
	manifest := strip_example_manifest(allocator)
	handles_used := []string{"pickups", "coin_sfx"}
	reach = asset_references(handles_used, manifest, allocator)
	references := []Asset_Reference {
		{by = "pickups.draw_coin", asset = "pickups"},
		{by = "pickups.on_pickup", asset = "coin_sfx"},
	}
	attribute_referencers(reach, references)

	kept, stripped = strip_unreferenced(manifest, reach, allocator)

	sizes = make([]Asset_Size, 3, allocator)
	sizes[0] = Asset_Size{name = "pickups", kb = 6}
	sizes[1] = Asset_Size{name = "coin_sfx", kb = 3}
	sizes[2] = Asset_Size{name = "coin", kb = 12}
	return
}

@(test)
test_emit_asset_report_byte_matches_golden :: proc(t: ^testing.T) {
	path := resolve_assets_report_path()
	golden_bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		log.warnf(
			"SKIP assets report: %s not found — set FUNPACK_ASSETS_REPORT or ensure the in-repo fixture exists",
			path,
		)
		return
	}
	golden := string(golden_bytes)

	reach, kept, stripped, sizes := report_example_inputs(context.temp_allocator)
	emitted := emit_asset_report(reach, kept, stripped, sizes, context.temp_allocator)

	testing.expect_value(t, len(emitted), len(golden))
	testing.expect(t, emitted == golden)
	if emitted != golden {
		report_first_byte_diff(emitted, golden)
		return
	}
	log.infof("assets report golden: assets.report.txt reproduces the exemplar byte-for-byte (%d bytes)", len(emitted))
}

@(test)
test_asset_report_double_emit_identical :: proc(t: ^testing.T) {
	reach, kept, stripped, sizes := report_example_inputs(context.temp_allocator)
	first := emit_asset_report(reach, kept, stripped, sizes, context.temp_allocator)
	second := emit_asset_report(reach, kept, stripped, sizes, context.temp_allocator)
	testing.expect(t, first == second)
	testing.expect_value(t, len(first), len(second))
	if first == second {
		log.infof("assets report double emit: two emissions are byte-identical (deterministic emit, %d bytes)", len(first))
	}
}

@(test)
test_asset_report_header_counts :: proc(t: ^testing.T) {
	reach, kept, stripped, sizes := report_example_inputs(context.temp_allocator)
	emitted := emit_asset_report(reach, kept, stripped, sizes, context.temp_allocator)
	testing.expect(t, contains_substring(emitted, "baked 3, stripped 1 (unreferenced)"))
	testing.expect(t, contains_substring(emitted, "shipped 9 KB across 2 assets; 12 KB stripped."))
	testing.expect(t, contains_substring(emitted, "cache: 3 hits, 0 misses (incremental)."))
}

@(test)
test_resolve_assets_report_path_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_assets_report_path()))
}
