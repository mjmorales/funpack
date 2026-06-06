// The §19 §5 asset-report golden: the hand-built reach/partition/sizes for the
// committed examples/assets reference set, emitted through emit_asset_report, must
// reproduce the committed exemplar examples/assets/assets/assets.report.txt byte-
// for-byte, and emitting the same inputs twice must be byte-identical (spec §09/§29
// purity). Like the seam-emit golden (asset_seam_emit_test.odin), the inputs are
// built BY HAND here — never re-derived from the source — so the test pins the
// report's byte contract, not a round-trip; it resolves the live exemplar (or
// FUNPACK_ASSETS_REPORT) and SKIPs loudly when the funpack-spec sibling is absent.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// ASSETS_REPORT_DEFAULT_REL is the committed exemplar's path relative to the main
// checkout root, resolved through resolve_spec_dir so it survives an orchestrator
// task-worktree #directory (the same resolution the seam-emit golden uses).
ASSETS_REPORT_DEFAULT_REL :: "../funpack-spec/examples/assets/assets/assets.report.txt"

// resolve_assets_report_path resolves the committed assets.report.txt exemplar: the
// FUNPACK_ASSETS_REPORT env override when set, else the sibling-checkout default
// anchored at the main checkout root. The path points at the file, not a dir.
resolve_assets_report_path :: proc() -> string {
	return resolve_spec_dir("FUNPACK_ASSETS_REPORT", ASSETS_REPORT_DEFAULT_REL)
}

// report_example_inputs builds, by hand, the (reach, kept, stripped, sizes) the
// committed exemplar reports over: the example manifest stripped in release with
// {pickups, coin_sfx} used, the referencer edges (draw_coin → pickups, on_pickup →
// coin_sfx), and the per-asset sizes (atlas 6, audio 3, model 12 KB). Returns the
// four emit_asset_report arguments. Allocated in `allocator`.
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

// test_emit_asset_report_byte_matches_golden is the load-bearing acceptance: the
// hand-built (reach, kept, stripped, sizes), emitted through emit_asset_report,
// reproduces the committed assets.report.txt exemplar byte-for-byte. A diff in any
// byte — a column width, the em-dash header, a refs count, a referencer, the strip
// rationale, the footer sums, the cache line, the trailing newline — fails here.
// SKIPs loudly when the sibling checkout is absent (a skipped golden is a warning).
@(test)
test_emit_asset_report_byte_matches_golden :: proc(t: ^testing.T) {
	path := resolve_assets_report_path()
	golden_bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		log.warnf(
			"SKIP assets report: %s not found — set FUNPACK_ASSETS_REPORT or check out funpack-spec as a sibling of the repo",
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
	// odin test echoes a name only on failure, so announce the byte match so a
	// passing run leaves a trace the acceptance gate can read.
	log.infof("assets report golden: assets.report.txt reproduces the exemplar byte-for-byte (%d bytes)", len(emitted))
}

// test_asset_report_double_emit_identical proves emission is deterministic (spec
// §09, §29): two emissions of the same hand-built inputs are byte-identical, so the
// report carries no field whose value depends on when, where, or on which machine
// it was emitted. Self-contained — no golden checkout needed.
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

// test_asset_report_header_counts pins the header counts in isolation: "baked N,
// stripped M" reads N as kept+stripped and M as len(stripped), so the example's two
// kept + one stripped renders "baked 3, stripped 1". Self-contained.
@(test)
test_asset_report_header_counts :: proc(t: ^testing.T) {
	reach, kept, stripped, sizes := report_example_inputs(context.temp_allocator)
	emitted := emit_asset_report(reach, kept, stripped, sizes, context.temp_allocator)
	testing.expect(t, contains_substring(emitted, "baked 3, stripped 1 (unreferenced)"))
	// The footer sums the kept sizes (6 + 3 = 9) across len(kept) assets, and the
	// stripped sizes (12) separately.
	testing.expect(t, contains_substring(emitted, "shipped 9 KB across 2 assets; 12 KB stripped."))
	// The cache line is the incremental all-hit derivation: baked (3) hits, 0 misses.
	testing.expect(t, contains_substring(emitted, "cache: 3 hits, 0 misses (incremental)."))
}

// test_resolve_assets_report_path_is_absolute keeps the exemplar resolver honest:
// the resolved path is absolute, so a bare `odin test .` from any cwd and a
// worktree validation run resolve the same sibling file.
@(test)
test_resolve_assets_report_path_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_assets_report_path()))
}
