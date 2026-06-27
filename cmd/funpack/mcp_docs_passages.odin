package main

import "core:math"
import "core:slice"
import "core:strings"
import "core:unicode"

PASSAGE_BM25_K1 :: 1.2
PASSAGE_BM25_B :: 0.75

PASSAGE_TITLE_BOOST :: 3.0

PASSAGE_SNIPPET_RADIUS :: 80

passage_kind_weight :: proc(kind: string) -> f64 {
	switch kind {
	case CORPUS_KIND_ENGINE:
		return 0.4
	case:
		return 1.0
	}
}

Passage_Hit :: struct {
	anchor:  string,
	title:   string,
	kind:    string,
	score:   f64,
	snippet: string,
}

Passage_Document :: struct {
	anchor:    string,
	title:     string,
	kind:      string,
	text:      string,
	term_freq: map[string]f64,
	length:    f64,
}

Passage_Index :: struct {
	docs:      []Passage_Document,
	postings:  map[string][dynamic]int,
	doc_freq:  map[string]int,
	avg_len:   f64,
}

passage_index_build :: proc(sections: []Corpus_Section, allocator := context.allocator) -> Passage_Index {
	ix := Passage_Index {
		postings = make(map[string][dynamic]int, 0, allocator),
		doc_freq = make(map[string]int, 0, allocator),
	}
	docs := make([dynamic]Passage_Document, 0, len(sections), allocator)
	total_len: f64

	for s in sections {
		if s.text == "" {
			continue
		}
		tf := make(map[string]f64, 0, allocator)
		for tok in passage_tokenize(s.text, allocator) {
			tf[tok] += 1
		}
		for tok in passage_tokenize(s.title, allocator) {
			tf[tok] += PASSAGE_TITLE_BOOST
		}
		if len(tf) == 0 {
			continue
		}
		length: f64
		for _, c in tf {
			length += c
		}
		doc_idx := len(docs)
		append(
			&docs,
			Passage_Document {
				anchor = s.anchor,
				title = s.title,
				kind = s.kind,
				text = s.text,
				term_freq = tf,
				length = length,
			},
		)
		for tok in tf {
			posting := &ix.postings[tok]
			if posting == nil {
				ix.postings[tok] = make([dynamic]int, 0, allocator)
				posting = &ix.postings[tok]
			}
			append(posting, doc_idx)
			ix.doc_freq[tok] += 1
		}
		total_len += length
	}

	ix.docs = docs[:]
	if len(ix.docs) > 0 {
		ix.avg_len = total_len / f64(len(ix.docs))
	}
	return ix
}

passage_index_query :: proc(
	ix: ^Passage_Index,
	q: string,
	limit: int,
	allocator := context.allocator,
) -> []Passage_Hit {
	if ix == nil || len(ix.docs) == 0 || limit <= 0 {
		return nil
	}
	terms := passage_dedupe(passage_tokenize(q, allocator), allocator)
	if len(terms) == 0 {
		return nil
	}

	n := f64(len(ix.docs))
	scores := make(map[int]f64, 0, allocator)
	defer delete(scores)
	for term in terms {
		posting, ok := ix.postings[term]
		if !ok {
			continue
		}
		df := f64(ix.doc_freq[term])
		idf := math.ln(1 + (n - df + 0.5) / (df + 0.5))
		for di in posting {
			d := &ix.docs[di]
			tf := d.term_freq[term]
			denom := tf + PASSAGE_BM25_K1 * (1 - PASSAGE_BM25_B + PASSAGE_BM25_B * d.length / ix.avg_len)
			scores[di] += idf * (tf * (PASSAGE_BM25_K1 + 1)) / denom
		}
	}
	if len(scores) == 0 {
		return nil
	}

	hits := make([dynamic]Passage_Hit, 0, len(scores), allocator)
	for di, sc in scores {
		d := &ix.docs[di]
		weighted := sc * passage_kind_weight(d.kind)
		append(
			&hits,
			Passage_Hit {
				anchor = d.anchor,
				title = d.title,
				kind = d.kind,
				score = weighted,
				snippet = passage_snippet(d.text, terms[:], allocator),
			},
		)
	}
	slice.sort_by(hits[:], proc(a, b: Passage_Hit) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		return a.anchor < b.anchor
	})
	out := hits[:]
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

passage_is_stop_word :: proc(tok: string) -> bool {
	switch tok {
	case "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in",
	     "is", "it", "of", "on", "or", "that", "the", "to", "with":
		return true
	}
	return false
}

passage_tokenize :: proc(s: string, allocator := context.allocator) -> []string {
	fields := strings.fields_proc(s, proc(r: rune) -> bool {
		return !unicode.is_letter(r) && !unicode.is_number(r)
	}, allocator)
	out := make([dynamic]string, 0, len(fields), allocator)
	for f in fields {
		tok := strings.to_lower(f, allocator)
		if len(tok) < 2 {
			continue
		}
		if passage_is_stop_word(tok) {
			continue
		}
		append(&out, tok)
	}
	return out[:]
}

passage_dedupe :: proc(toks: []string, allocator := context.allocator) -> []string {
	seen := make(map[string]bool, 0, allocator)
	defer delete(seen)
	out := make([dynamic]string, 0, len(toks), allocator)
	for tok in toks {
		if seen[tok] {
			continue
		}
		seen[tok] = true
		append(&out, tok)
	}
	return out[:]
}

passage_snippet :: proc(text: string, terms: []string, allocator := context.allocator) -> string {
	collapsed := strings.fields(text, allocator)
	flat := strings.join(collapsed, " ", allocator)
	lower := strings.to_lower(flat, allocator)

	best := -1
	for term in terms {
		if i := strings.index(lower, term); i >= 0 && (best < 0 || i < best) {
			best = i
		}
	}
	if best < 0 {
		return passage_head(flat, allocator)
	}

	start := best - PASSAGE_SNIPPET_RADIUS
	if start < 0 {
		start = 0
	}
	end := best + PASSAGE_SNIPPET_RADIUS
	if end > len(flat) {
		end = len(flat)
	}
	window := flat[start:end]
	b := strings.builder_make(allocator)
	if start > 0 {
		strings.write_string(&b, "…")
	}
	strings.write_string(&b, window)
	if end < len(flat) {
		strings.write_string(&b, "…")
	}
	return strings.to_string(b)
}

passage_head :: proc(flat: string, allocator := context.allocator) -> string {
	if len(flat) <= 2 * PASSAGE_SNIPPET_RADIUS {
		return flat
	}
	return strings.concatenate({flat[:2 * PASSAGE_SNIPPET_RADIUS], "…"}, allocator)
}
