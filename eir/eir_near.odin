// The NEAR tier: Type-3 near-miss clone detection, reported on its own surface so the
// precision-first exact tier (eir dup) stays untainted. Where the exact tier reports
// subtrees whose canonical bytes are IDENTICAL, the near tier reports top-level
// declarations whose canonical SUBTREE SETS overlap above a tunable cutoff — the
// gapped/parameterized copy that shares most of its structure but diverges in a few
// statements, which exact hashing can never collapse.
//
// A declaration's fingerprint is the weighted multiset of its PROPER-PART subtree
// canon-hashes (canon_fingerprint, the SAME canonicalization the exact tier clusters on —
// the near tier never re-walks the AST, so the two tiers cannot drift). "Proper part"
// matters: a subtree larger than half the unit is an ancestor (the body block, the unit
// root) that ALWAYS differs the moment any one statement does, so including it would let a
// single-statement divergence crush an otherwise-near pair; capping shingles at unit/2
// keeps the shared statement/expression blocks driving the score. Two declarations'
// similarity is the weighted Jaccard of their fingerprints: overlap / union, each hash
// weighted by its subtree's node_count so a larger shared block counts more than a tiny
// one. Ubiquitous subtrees (the `if err != nil` idiom, a common literal) are stopword-
// filtered by document frequency — they distinguish nothing, inflate every score, and
// would explode the comparison, so dropping them sharpens precision AND bounds the work
// to declarations that share DISTINCTIVE structure.
//
// Determinism: similarity is integer per-mille (overlap*1000/union — no float), each
// pair is oriented a-before-b by span, and the final order is a total order over
// (similarity desc, a-span, b-span). So the report is a pure function of the source set,
// independent of map-iteration order, and byte-stable.
package eir

import "core:encoding/json"
import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

// NEAR_REPORT_SCHEMA_VERSION leads the JSON object so a consumer reads the shape version
// before the pairs — the self-describing lead the dup report and baseline both use.
NEAR_REPORT_SCHEMA_VERSION :: 1

// NEAR_SHINGLE_FLOOR is the subtree-size floor for a fingerprint: finer than the clone
// floor (a near-miss is built from sub-proc blocks, not whole clones), but above bare
// leaves whose recurrence is noise. Four nodes is roughly a small expression — the
// smallest shingle that carries structure.
NEAR_SHINGLE_FLOOR :: 4

// NEAR_STOPWORD_DF is the document-frequency cap: a subtree hash present in more than this
// many candidate declarations is an idiom, not a distinguishing feature, so it is excluded
// from every fingerprint. The cap both lifts precision (two procs sharing only boilerplate
// no longer score as near) and bounds pair generation (a stopword can seat at most this
// many declarations in its inverted-index bucket).
NEAR_STOPWORD_DF :: 24

// NEAR_DEFAULT_MIN_NODES is the whole-declaration floor: a declaration smaller than this
// is too small for a meaningful near-miss and is not a candidate. It mirrors the clone
// tier's default so the two tiers scope to comparable units.
NEAR_DEFAULT_MIN_NODES :: 30

// NEAR_DEFAULT_SIMILARITY is the default cutoff in percent: a pair at or above it is
// reported. Eighty percent admits a copy that diverges in roughly a fifth of its weighted
// structure — gapped enough to be a near-miss, close enough to be a real dedup candidate.
NEAR_DEFAULT_SIMILARITY :: 80

// Near_Options configures one near-miss scan: the candidate declaration floor, the
// similarity cutoff (percent, [1,100]), and whether literals fold (passed through to the
// shared canonicalization so constant-only differences can collide).
Near_Options :: struct {
	min_nodes:      int,
	similarity_pct: int,
	fold_literals:  bool,
}

// NEAR_INDENT and NEAR_GAP are the human table's fixed two-space lead-in and inter-column
// separators (eir_report.odin's equivalents are file-private to it, so the near table
// carries its own); the per-column widths are computed from the data.
@(private = "file")
NEAR_INDENT :: "  "
@(private = "file")
NEAR_GAP :: "  "

// near_default_options returns the engine defaults the verb runs with absent overriding
// flags.
near_default_options :: proc() -> Near_Options {
	return Near_Options {
		min_nodes      = NEAR_DEFAULT_MIN_NODES,
		similarity_pct = NEAR_DEFAULT_SIMILARITY,
		fold_literals  = false,
	}
}

// Hash_Weight is one fingerprint entry: a subtree canon-hash and its weight in a
// declaration (occurrence count times the subtree's node_count). A fingerprint is a slice
// of these sorted by hash, so two fingerprints intersect by a linear merge-join.
@(private = "file")
Hash_Weight :: struct {
	hash:   u64,
	weight: int,
}

// Near_Candidate is one top-level declaration eligible for comparison: its location and
// test tag, its whole-declaration canon hash (so an exact-clone pair is excluded — that
// belongs to the dup tier), its node_count (the unit size), and its post-stopword
// fingerprint (weights sorted by hash) with the total weight (the self term of the
// Jaccard union).
@(private = "file")
Near_Candidate :: struct {
	path:         string,
	is_test:      bool,
	line_start:   int,
	line_end:     int,
	decl_hash:    u64,
	node_count:   int,
	weights:      []Hash_Weight,
	total_weight: int,
}

// Near_Site is one declaration's location in a reported pair: where it sits, its test tag,
// and its node_count, so a consumer can scope and size the near-miss.
Near_Site :: struct {
	path:       string,
	is_test:    bool,
	line_start: int,
	line_end:   int,
	node_count: int,
}

// Near_Pair is one reported near-miss: two declarations (oriented a-before-b by span) and
// their similarity as integer per-mille (overlap*1000/union), so the report carries no
// float and renders byte-stably.
Near_Pair :: struct {
	a:                   Near_Site,
	b:                   Near_Site,
	similarity_permille: int,
}

// find_near_clones runs the near tier over a Load_Result and returns the near-miss pairs
// at or above the similarity cutoff, in a deterministic order. It fingerprints every
// top-level declaration that meets the floor, stopword-filters by document frequency,
// pairs only declarations that share a distinctive subtree (an inverted-index walk, not
// an O(n^2) sweep), scores each pair by weighted Jaccard, drops exact clones and
// below-cutoff pairs, and sorts the survivors. The result borrows the loader's path
// strings; keep the loader alive while reading it.
find_near_clones :: proc(
	result: Load_Result,
	opts: Near_Options,
	allocator := context.allocator,
) -> []Near_Pair {
	candidates := collect_near_candidates(result, opts, context.temp_allocator)

	// Document frequency over distinct candidate subtree hashes: a hash counted in N
	// candidates' raw fingerprints has DF N. The stopword cap reads this.
	df := make(map[u64]int, 256, context.temp_allocator)
	for cand in candidates {
		for hw in cand.weights {
			df[hw.hash] += 1
		}
	}

	// Re-derive each candidate's fingerprint without stopwords, then index the survivors.
	// A candidate whose every shingle is a stopword keeps an empty fingerprint and simply
	// never pairs (overlap 0) — correct, not special-cased.
	index := make(map[u64][dynamic]int, 256, context.temp_allocator)
	filtered := make([]Near_Candidate, len(candidates), context.temp_allocator)
	for cand, ci in candidates {
		kept := make([dynamic]Hash_Weight, 0, len(cand.weights), context.temp_allocator)
		total := 0
		for hw in cand.weights {
			if df[hw.hash] > NEAR_STOPWORD_DF {
				continue
			}
			append(&kept, hw)
			total += hw.weight
			if _, seen := index[hw.hash]; !seen {
				index[hw.hash] = make([dynamic]int, 0, 2, context.temp_allocator)
			}
			bucket := &index[hw.hash]
			append(bucket, ci)
		}
		c := cand
		c.weights = kept[:]
		c.total_weight = total
		filtered[ci] = c
	}

	// Candidate pairs: every (i<j) co-occurring in a non-stopword bucket, deduped. Only
	// declarations sharing a distinctive subtree can clear the cutoff, so this is the
	// whole comparison set — no full sweep.
	seen := make(map[u64]bool, 1024, context.temp_allocator)
	pairs := make([dynamic]Near_Pair, 0, 64, allocator)
	for _, idxs in index {
		for a in 0 ..< len(idxs) {
			for b in (a + 1) ..< len(idxs) {
				i, j := idxs[a], idxs[b]
				if i == j {
					continue
				}
				if i > j {
					i, j = j, i
				}
				key := (u64(i) << 32) | u64(j)
				if seen[key] {
					continue
				}
				seen[key] = true
				if pair, ok := score_near_pair(filtered[i], filtered[j], opts); ok {
					append(&pairs, pair)
				}
			}
		}
	}

	slice.sort_by(pairs[:], near_pair_less)
	return pairs[:]
}

// near_unit_node returns the subtree a top-level declaration is compared BY: a
// `name :: <value>` declaration is compared by its VALUE (the proc literal, the
// struct/enum type, the const expression) with the binding name excluded — exactly the
// unit the exact tier identifies a clone by. So two renamed-identical procs have the
// IDENTICAL unit (identical decl_hash) and are dropped as an exact clone the dup tier
// already owns, never re-surfaced here as a 99%-near pair; only a genuine divergence in
// the value yields a distinct unit and a sub-100% score. A multi-value or non-value
// declaration (an import group, a foreign block) has no single name-excluded value, so it
// is compared whole.
@(private = "file")
near_unit_node :: proc(decl: ^ast.Node) -> ^ast.Node {
	if vd, ok := decl.derived.(^ast.Value_Decl); ok && len(vd.values) == 1 {
		return vd.values[0]
	}
	return decl
}

// collect_near_candidates fingerprints every top-level declaration that meets the floor.
// canon_fingerprint reuses the exact tier's canonicalization, so the near tier measures
// similarity over the identical canonical form. The raw fingerprint aggregates duplicate
// subtree hashes into one weighted entry (count * node_count) sorted by hash; document
// frequency and the stopword cut happen in the caller, where the whole candidate set is
// visible.
@(private = "file")
collect_near_candidates :: proc(
	result: Load_Result,
	opts: Near_Options,
	allocator := context.allocator,
) -> []Near_Candidate {
	out := make([dynamic]Near_Candidate, 0, 128, allocator)
	for loaded in result.files {
		if loaded.file == nil {
			continue
		}
		for decl in loaded.file.decls {
			decl_hash, n, subs := canon_fingerprint(
				near_unit_node(decl),
				NEAR_SHINGLE_FLOOR,
				opts.fold_literals,
				context.temp_allocator,
			)
			if n < opts.min_nodes {
				continue
			}
			// A shingle is a PROPER PART, not the near-whole: cap it at half the unit so the
			// unit root and its body block — which always differ the moment any one
			// statement does — never enter the fingerprint and drown a single-statement
			// divergence. The shared statement/expression blocks below the cap drive the
			// score instead, which is what makes two near-identical procs read as near.
			shingle_cap := max(NEAR_SHINGLE_FLOOR, n / 2)
			append(
				&out,
				Near_Candidate {
					path = loaded.path,
					is_test = loaded.is_test,
					line_start = decl.pos.line,
					line_end = decl.end.line,
					decl_hash = decl_hash,
					node_count = n,
					weights = aggregate_weights(subs, shingle_cap, allocator),
				},
			)
		}
	}
	return out[:]
}

// aggregate_weights folds a declaration's subtree list into one weighted entry per
// distinct hash (weight = occurrences * node_count, the same for every occurrence since a
// shared canon has a shared size), sorted by hash so two fingerprints merge-join. A
// subtree larger than max_nodes is skipped — it is an ancestor, not a shingle (see the
// shingle-cap rationale at the call site). The sort is what lets score_near_pair run in
// linear time over the two sorted slices.
@(private = "file")
aggregate_weights :: proc(
	subs: []Subtree_Fingerprint,
	max_nodes: int,
	allocator := context.allocator,
) -> []Hash_Weight {
	acc := make(map[u64]int, len(subs), context.temp_allocator)
	for s in subs {
		if s.node_count > max_nodes {
			continue
		}
		acc[s.hash] += s.node_count
	}
	out := make([]Hash_Weight, len(acc), allocator)
	i := 0
	for h, w in acc {
		out[i] = Hash_Weight{hash = h, weight = w}
		i += 1
	}
	slice.sort_by(out, proc(a, b: Hash_Weight) -> bool {return a.hash < b.hash})
	return out
}

// score_near_pair computes the weighted Jaccard of two fingerprints and decides the pair.
// An exact-clone pair (identical whole-declaration canon) is rejected — it is the dup
// tier's, and keeping the surfaces disjoint is the whole point of a separate tier. The
// merge-join over the hash-sorted weights sums the per-hash minimum as the overlap; the
// union is total_a + total_b - overlap. The pair clears the cutoff when
// overlap*100 >= similarity_pct*union (integer, no division), and the similarity is then
// per-mille for the report. ok is false on an empty union (a stopword-emptied fingerprint)
// or a below-cutoff score.
@(private = "file")
score_near_pair :: proc(
	a, b: Near_Candidate,
	opts: Near_Options,
) -> (
	pair: Near_Pair,
	ok: bool,
) {
	if a.decl_hash == b.decl_hash {
		return {}, false
	}

	overlap := 0
	i, j := 0, 0
	for i < len(a.weights) && j < len(b.weights) {
		ha, hb := a.weights[i].hash, b.weights[j].hash
		switch {
		case ha == hb:
			overlap += min(a.weights[i].weight, b.weights[j].weight)
			i += 1
			j += 1
		case ha < hb:
			i += 1
		case:
			j += 1
		}
	}

	total_union := a.total_weight + b.total_weight - overlap
	if total_union <= 0 {
		return {}, false
	}
	if overlap * 100 < opts.similarity_pct * total_union {
		return {}, false
	}

	lo, hi := orient_sites(a, b)
	return Near_Pair {
			a = lo,
			b = hi,
			similarity_permille = overlap * 1000 / total_union,
		},
		true
}

// orient_sites canonicalizes a pair's orientation: the site with the smaller (path, line)
// is `a`. A stable orientation makes the pair representation canonical, so the final sort
// is a total order and the output is byte-stable regardless of which declaration the walk
// reached first.
@(private = "file")
orient_sites :: proc(x, y: Near_Candidate) -> (lo, hi: Near_Site) {
	sx := candidate_site(x)
	sy := candidate_site(y)
	if site_less(sx, sy) {
		return sx, sy
	}
	return sy, sx
}

// candidate_site projects a candidate onto the report's site record.
@(private = "file")
candidate_site :: proc(c: Near_Candidate) -> Near_Site {
	return Near_Site {
		path = c.path,
		is_test = c.is_test,
		line_start = c.line_start,
		line_end = c.line_end,
		node_count = c.node_count,
	}
}

// site_less is the total order on sites by span, delegating to the shared span comparator
// so the near surface orders identically to the clone surface.
@(private = "file")
site_less :: proc(a, b: Near_Site) -> bool {
	return span_less(a.path, a.line_start, a.line_end, b.path, b.line_start, b.line_end)
}

// near_pair_less is the report order: highest similarity first, then the a-site span, then
// the b-site span. Two distinct pairs cannot tie on all three (the two spans identify the
// declarations), so this is a total order — the determinism the byte-stable JSON needs.
@(private = "file")
near_pair_less :: proc(a, b: Near_Pair) -> bool {
	if a.similarity_permille != b.similarity_permille {
		return a.similarity_permille > b.similarity_permille
	}
	if !sites_equal(a.a, b.a) {
		return site_less(a.a, b.a)
	}
	return site_less(a.b, b.b)
}

// sites_equal reports whether two sites name the same declaration (path + span).
@(private = "file")
sites_equal :: proc(a, b: Near_Site) -> bool {
	return a.path == b.path && a.line_start == b.line_start && a.line_end == b.line_end
}

// Near_Report is the whole --json payload as one marshal-able struct: field-declaration
// order is the key order and every field is a scalar or an index-ordered slice (no map),
// so json.marshal over the same pair set is byte-identical. similarity_threshold records
// the cutoff the scan used so a consumer reads the scan's parameter alongside its results.
Near_Report :: struct {
	schema_version:       int,
	similarity_threshold: int,
	pairs:                []Near_Pair_Record,
}

// Near_Pair_Record is one ranked near-miss in the JSON: 1-based rank, the similarity as
// integer per-mille (853 = 85.3% — exact, no float-precision loss across a consumer's
// parser), and the two sites.
Near_Pair_Record :: struct {
	rank:                int,
	similarity_permille: int,
	a:                   Near_Site,
	b:                   Near_Site,
}

// render_near_json renders the near-miss pairs as one byte-stable JSON object: a compact
// marshal of the ordered Near_Report (no map anywhere), so a double render over the same
// pairs is byte-identical. An empty pair set renders an empty `pairs` array (never null).
// No trailing newline — the caller adds one — matching the dup --json convention.
render_near_json :: proc(
	pairs: []Near_Pair,
	threshold_pct: int,
	allocator := context.allocator,
) -> string {
	records := make([]Near_Pair_Record, len(pairs), context.temp_allocator)
	for p, i in pairs {
		records[i] = Near_Pair_Record {
			rank                = i + 1,
			similarity_permille = p.similarity_permille,
			a                   = p.a,
			b                   = p.b,
		}
	}
	report := Near_Report {
		schema_version       = NEAR_REPORT_SCHEMA_VERSION,
		similarity_threshold = threshold_pct,
		pairs                = records,
	}
	bytes, _ := json.marshal(report, {}, context.temp_allocator)
	return strings.clone(string(bytes), allocator)
}

// render_near_human renders the near-miss pairs as an aligned text table — rank, the
// similarity percent (per-mille rendered as `NN.N%`), and the two file:line-line spans. An
// empty pair set renders the single "no near-miss clones found" line. Allocated in
// `allocator`.
render_near_human :: proc(pairs: []Near_Pair, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	if len(pairs) == 0 {
		strings.write_string(&b, "no near-miss clones found\n")
		return strings.to_string(b)
	}

	rank_w := len("rank")
	sim_w := len("sim")
	for p, i in pairs {
		rank_w = max(rank_w, len(fmt.tprintf("%d", i + 1)))
		sim_w = max(sim_w, len(format_permille(p.similarity_permille)))
	}

	write_near_prefix(&b, "rank", "sim", rank_w, sim_w)
	strings.write_string(&b, "sites")
	strings.write_byte(&b, '\n')

	cont_prefix := len(NEAR_INDENT) + rank_w + len(NEAR_GAP) + sim_w + len(NEAR_GAP)
	for p, i in pairs {
		write_near_prefix(&b, fmt.tprintf("%d", i + 1), format_permille(p.similarity_permille), rank_w, sim_w)
		fmt.sbprintf(&b, "%s:%d-%d", p.a.path, p.a.line_start, p.a.line_end)
		strings.write_byte(&b, '\n')
		write_near_spaces(&b, cont_prefix)
		fmt.sbprintf(&b, "%s:%d-%d", p.b.path, p.b.line_start, p.b.line_end)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// format_permille renders an integer per-mille as a one-decimal percent: 853 -> "85.3%".
@(private = "file")
format_permille :: proc(permille: int) -> string {
	return fmt.tprintf("%d.%d%%", permille / 10, permille % 10)
}

// write_near_prefix writes the two left-aligned scalar columns (rank, sim) of a row, each
// padded to its width and followed by the inter-column gap, leaving the builder at the
// sites column. Header and data rows share this layout, so a header sits over its cells.
@(private = "file")
write_near_prefix :: proc(b: ^strings.Builder, rank, sim: string, rank_w, sim_w: int) {
	strings.write_string(b, NEAR_INDENT)
	write_near_cell(b, rank, rank_w)
	strings.write_string(b, NEAR_GAP)
	write_near_cell(b, sim, sim_w)
	strings.write_string(b, NEAR_GAP)
}

// write_near_cell writes a left-aligned cell: the value, then padding to width.
@(private = "file")
write_near_cell :: proc(b: ^strings.Builder, value: string, width: int) {
	strings.write_string(b, value)
	write_near_spaces(b, width - len(value))
}

// write_near_spaces writes n spaces (a no-op for n <= 0).
@(private = "file")
write_near_spaces :: proc(b: ^strings.Builder, n: int) {
	for _ in 0 ..< n {
		strings.write_byte(b, ' ')
	}
}
