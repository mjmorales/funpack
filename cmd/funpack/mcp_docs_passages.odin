// The BM25 passage half of the funpack docs index — the Odin re-home of the
// deleted Go mcp/internal/docs/passages package. It answers conceptual queries
// ("determinism", "pipeline schedule") by ranking Corpus_Section prose on Okapi
// BM25 relevance and returning anchored hits with a short matching snippet.
//
// WHY a custom BM25 and not a core: facility: Odin core ships no full-text /
// BM25 ranker, and the corpus is small (low thousands of short passages), so a
// compact in-memory inverted index built on core:strings/unicode/math is the
// Odin-first answer — lighter than introducing a search-engine dependency, and
// the ranker is the textbook Okapi BM25 with the conventional k1=1.2, b=0.75.
//
// The index keys on Corpus_Section.anchor (stable across corpus regen, see
// mcp_corpus.odin), so a Passage_Hit is a durable reference a docs-search tool
// can hand back to an agent and re-resolve later.
//
// WHY cmd/funpack: this is part of the FUNPACK_LIVE-only `funpack mcp` server
// graph the ADR homes in the single SDL-linking binary. The ranker itself needs
// only core: text/math, so it compiles in both arms of the package and its tests
// run on the default `odin test .` floor.
package main

import "core:math"
import "core:slice"
import "core:strings"
import "core:unicode"

// BM25 free parameters. PASSAGE_BM25_K1 controls term-frequency saturation;
// PASSAGE_BM25_B controls document-length normalization. 1.2 / 0.75 are the
// standard Okapi values and behave well on the short, uniform docs passages.
PASSAGE_BM25_K1 :: 1.2
PASSAGE_BM25_B :: 0.75

// PASSAGE_TITLE_BOOST multiplies the term-frequency contribution of a token that
// also appears in the section title. A heading match is a strong topicality
// signal, so a title token counts as PASSAGE_TITLE_BOOST occurrences when scoring.
PASSAGE_TITLE_BOOST :: 3.0

// PASSAGE_SNIPPET_RADIUS is the number of bytes of context shown on each side of
// the matched term in a snippet.
PASSAGE_SNIPPET_RADIUS :: 80

// passage_kind_weight scales a section's score by its source kind. Prose
// (spec, plugin) is the primary conceptual-query target; engine signatures are
// the symbol table's job and are indexed only as a lower-weight fallback so a
// query that genuinely matches a signature's @doc line can still surface it.
passage_kind_weight :: proc(kind: string) -> f64 {
	switch kind {
	case CORPUS_KIND_ENGINE:
		return 0.4
	case:
		// spec + plugin are full-weight prose.
		return 1.0
	}
}

// Passage_Hit is one ranked search result: the section's stable anchor and
// title, its BM25 relevance score (higher is more relevant), and a short snippet
// of body text centered on the best-matching query term.
Passage_Hit :: struct {
	// anchor is the matched section's stable corpus anchor (re-resolvable).
	anchor:  string,
	// title is the section's human-readable heading.
	title:   string,
	// kind is the matched section's source category (one of CORPUS_KIND_*).
	kind:    string,
	// score is the BM25 relevance after kind weighting; larger is better.
	score:   f64,
	// snippet is a short window of body text around the strongest query-term
	// match, for display alongside the anchor.
	snippet: string,
}

// Passage_Document is one indexed section: its identity plus the precomputed
// term-frequency table (title tokens already boosted) and total length the BM25
// scorer reads.
Passage_Document :: struct {
	anchor:    string,
	title:     string,
	kind:      string,
	text:      string,
	// term_freq is token -> boosted occurrence count within this document.
	term_freq: map[string]f64,
	// length is the sum of term_freq values — the BM25 document length, with title
	// boosting folded in so a heading match lengthens the doc consistently.
	length:    f64,
}

// Passage_Index is an in-memory inverted index over a set of sections. Build it
// once with passage_index_build and query it with passage_index_query, which
// never mutates the index. All index storage is owned by `allocator`.
Passage_Index :: struct {
	docs:      []Passage_Document,
	// postings maps a token to the indices (into docs) of documents containing it,
	// so a query only scores documents that share at least one term.
	postings:  map[string][dynamic]int,
	// doc_freq maps a token to the number of documents containing it (for IDF).
	doc_freq:  map[string]int,
	// avg_len is the mean document length across the index (BM25 normalization).
	avg_len:   f64,
}

// passage_index_build builds a BM25 index over the given sections. Sections with
// empty text are skipped. Kind weighting and title boosting are baked into the
// precomputed per-document frequency tables, so query is a pure scoring pass.
// Everything is allocated in `allocator`.
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
		// Fold title tokens in at PASSAGE_TITLE_BOOST weight: a heading match is a
		// strong topicality signal and should dominate a passing body mention.
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

// passage_index_query scores q against every document sharing a query term and
// returns up to limit hits ranked by descending BM25 score. An empty or
// stop-only query, a limit <= 0, or an empty index yields a nil slice. Ties
// break on anchor for a deterministic order. Hits are allocated in `allocator`.
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
	// Accumulate per-document scores over only the documents that match a term.
	scores := make(map[int]f64, 0, allocator)
	defer delete(scores)
	for term in terms {
		posting, ok := ix.postings[term]
		if !ok {
			continue
		}
		df := f64(ix.doc_freq[term])
		// Okapi BM25 IDF with the +1 floor so a term in every document still scores
		// non-negatively.
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

// passage_is_stop_word reports whether a lowercased token is a high-frequency
// English word that carries no topical signal. Dropping these keeps short
// conceptual queries ("the pipeline schedule") focused on their content terms.
passage_is_stop_word :: proc(tok: string) -> bool {
	switch tok {
	case "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in",
	     "is", "it", "of", "on", "or", "that", "the", "to", "with":
		return true
	}
	return false
}

// passage_tokenize lowercases s and splits it into content tokens on any
// non-alphanumeric rune, dropping stop words and single-character tokens. The
// same tokenizer runs over documents at index time and queries at search time,
// so the vocabularies always agree. Tokens are allocated in `allocator`.
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

// passage_dedupe returns toks with duplicates removed, preserving first-seen
// order. A query term scores a document once regardless of how often the user
// repeated it. Allocated in `allocator`.
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

// passage_snippet returns a short window of text centered on the first
// occurrence of any query term, with whitespace collapsed and ellipses on
// truncated ends. When no term is found in the raw text (it matched only via the
// title), it falls back to the text's head. Allocated in `allocator`.
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

// passage_head returns the leading window of flat for sections whose match came
// only from the title. Allocated in `allocator`.
passage_head :: proc(flat: string, allocator := context.allocator) -> string {
	if len(flat) <= 2 * PASSAGE_SNIPPET_RADIUS {
		return flat
	}
	return strings.concatenate({flat[:2 * PASSAGE_SNIPPET_RADIUS], "…"}, allocator)
}
