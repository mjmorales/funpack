package eir

import "core:fmt"
import "core:odin/ast"
import "core:slice"

NEAR_SHINGLE_FLOOR :: 4

NEAR_STOPWORD_DF :: 24

NEAR_DEFAULT_MIN_NODES :: 30

NEAR_DEFAULT_SIMILARITY :: 80

Near_Options :: struct {
	min_nodes:      int,
	similarity_pct: int,
	fold_literals:  bool,
}

near_default_options :: proc() -> Near_Options {
	return Near_Options {
		min_nodes      = NEAR_DEFAULT_MIN_NODES,
		similarity_pct = NEAR_DEFAULT_SIMILARITY,
		fold_literals  = false,
	}
}

@(private = "file")
Hash_Weight :: struct {
	hash:   u64,
	weight: int,
}

@(private = "file")
Near_Candidate :: struct {
	path:         string,
	is_test:      bool,
	line_start:   int,
	line_end:     int,
	col:          int,
	decl_hash:    u64,
	node_count:   int,
	weights:      []Hash_Weight,
	total_weight: int,
}

Near_Site :: struct {
	path:       string,
	is_test:    bool,
	line_start: int,
	line_end:   int,
	col:        int,
	node_count: int,
}

Near_Pair :: struct {
	a:                   Near_Site,
	b:                   Near_Site,
	similarity_permille: int,
}

find_near_clones :: proc(
	result: Load_Result,
	opts: Near_Options,
	allocator := context.allocator,
) -> []Near_Pair {
	candidates := collect_near_candidates(result, opts, context.temp_allocator)

	df := make(map[u64]int, 256, context.temp_allocator)
	for cand in candidates {
		for hw in cand.weights {
			df[hw.hash] += 1
		}
	}

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

@(private = "file")
near_unit_node :: proc(decl: ^ast.Node) -> ^ast.Node {
	if vd, ok := decl.derived.(^ast.Value_Decl); ok && len(vd.values) == 1 {
		return vd.values[0]
	}
	return decl
}

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
			shingle_cap := max(NEAR_SHINGLE_FLOOR, n / 2)
			append(
				&out,
				Near_Candidate {
					path = loaded.path,
					is_test = loaded.is_test,
					line_start = decl.pos.line,
					line_end = decl.end.line,
					col = decl.pos.column,
					decl_hash = decl_hash,
					node_count = n,
					weights = aggregate_weights(subs, shingle_cap, allocator),
				},
			)
		}
	}
	return out[:]
}

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

@(private = "file")
orient_sites :: proc(x, y: Near_Candidate) -> (lo, hi: Near_Site) {
	sx := candidate_site(x)
	sy := candidate_site(y)
	if site_less(sx, sy) {
		return sx, sy
	}
	return sy, sx
}

@(private = "file")
candidate_site :: proc(c: Near_Candidate) -> Near_Site {
	return Near_Site {
		path = c.path,
		is_test = c.is_test,
		line_start = c.line_start,
		line_end = c.line_end,
		col = c.col,
		node_count = c.node_count,
	}
}

@(private = "file")
site_less :: proc(a, b: Near_Site) -> bool {
	return span_less(a.path, a.line_start, a.line_end, b.path, b.line_start, b.line_end)
}

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

@(private = "file")
sites_equal :: proc(a, b: Near_Site) -> bool {
	return a.path == b.path && a.line_start == b.line_start && a.line_end == b.line_end
}

near_diagnostics :: proc(pairs: []Near_Pair, allocator := context.allocator) -> []Diagnostic {
	out := make([]Diagnostic, len(pairs), allocator)
	for p, i in pairs {
		sim := format_permille(p.similarity_permille)
		related := make([]Related_Location, 1, allocator)
		related[0] = Related_Location {
			file = p.b.path,
			line = p.b.line_start,
			col  = p.b.col,
			note = fmt.aprintf("near-miss counterpart (%s)", sim, allocator = allocator),
		}
		out[i] = Diagnostic {
			file     = p.a.path,
			line     = p.a.line_start,
			col      = p.a.col,
			severity = .Warning,
			rule     = "near",
			message  = fmt.aprintf(
				"%s near-miss with %s:%d",
				sim,
				p.b.path,
				p.b.line_start,
				allocator = allocator,
			),
			related  = related,
		}
	}
	return out
}

@(private = "file")
format_permille :: proc(permille: int) -> string {
	return fmt.tprintf("%d.%d%%", permille / 10, permille % 10)
}
