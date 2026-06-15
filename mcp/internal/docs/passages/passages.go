// Package passages is a pure-Go BM25 full-text index over the funpack docs
// corpus prose. It answers conceptual queries — "determinism", "pipeline
// schedule" — by ranking documentation Sections on Okapi BM25 relevance and
// returning anchored hits with a short matching snippet.
//
// Why BM25 and no dependency: the corpus is small (low thousands of sections,
// each a short passage), so a compact in-memory inverted index built from the
// standard library is faster to load, easier to audit, and lighter than pulling
// a search engine (bleve/blevesearch) into the MCP binary. The ranker is the
// textbook Okapi BM25 with the conventional k1=1.2, b=0.75 parameters.
//
// The index keys on Section.Anchor (stable across corpus regen, see the docs
// package), so a PassageHit is a durable reference a docs-search MCP tool can
// hand back to an agent and re-resolve later.
package passages

import (
	"math"
	"sort"
	"strings"
	"unicode"

	"github.com/mjmorales/funpack/mcp/internal/docs"
)

// BM25 free parameters. k1 controls term-frequency saturation; b controls
// document-length normalization. 1.2 / 0.75 are the standard Okapi values and
// behave well on short, uniform passages like the docs corpus.
const (
	bm25K1 = 1.2
	bm25B  = 0.75
)

// kindWeight scales a section's score by its source kind. Prose (spec, plugin)
// is the primary conceptual-query target; engine signatures are the
// symbol-table's job and are indexed only as a lower-weight fallback so a query
// that genuinely matches a signature's @doc line can still surface it.
var kindWeight = map[docs.Kind]float64{
	docs.KindSpec:   1.0,
	docs.KindPlugin: 1.0,
	docs.KindEngine: 0.4,
}

// titleBoost multiplies the term frequency contribution of a token that also
// appears in the section Title. A heading match is a strong topicality signal
// ("Determinism" as a heading beats a passing mention in body prose), so a
// title token counts as titleBoost occurrences when scoring.
const titleBoost = 3.0

// PassageHit is one ranked search result: the section's stable Anchor and
// Title, its BM25 relevance Score (higher is more relevant), and a short
// Snippet of body text centered on the best-matching query term.
type PassageHit struct {
	// Anchor is the matched section's stable corpus anchor (file#slug or
	// engine/module#decl), re-resolvable against the docs corpus.
	Anchor string
	// Title is the section's human-readable heading.
	Title string
	// Kind is the matched section's source category.
	Kind docs.Kind
	// Score is the BM25 relevance score after kind weighting; larger is better.
	Score float64
	// Snippet is a short window of body text around the strongest query-term
	// match, for display alongside the anchor.
	Snippet string
}

// document is one indexed section: its identity plus the precomputed
// term-frequency table (title tokens already boosted) and total length the
// BM25 scorer reads.
type document struct {
	anchor string
	title  string
	kind   docs.Kind
	text   string
	// termFreq is token -> boosted occurrence count within this document.
	termFreq map[string]float64
	// length is the sum of termFreq values — the BM25 document length, with
	// title boosting folded in so a heading match lengthens the doc consistently.
	length float64
}

// Index is an immutable in-memory inverted index over a set of sections. Build
// it once with New and query it concurrently — Query never mutates the index.
type Index struct {
	docs []document
	// postings maps a token to the indices (into docs) of documents containing
	// it, so a query only scores documents that share at least one term.
	postings map[string][]int
	// docFreq maps a token to the number of documents containing it (for IDF).
	docFreq map[string]int
	// avgLen is the mean document length across the index (BM25 normalization).
	avgLen float64
}

// New builds a BM25 index over the given sections. Sections with empty Text are
// skipped. Kind weighting and title boosting are baked into the precomputed
// per-document frequency tables, so Query is a pure scoring pass.
func New(sections []docs.Section) *Index {
	idx := &Index{
		docs:     make([]document, 0, len(sections)),
		postings: make(map[string][]int),
		docFreq:  make(map[string]int),
	}
	var totalLen float64
	for _, s := range sections {
		if s.Text == "" {
			continue
		}
		tf := make(map[string]float64)
		for _, tok := range tokenize(s.Text) {
			tf[tok]++
		}
		// Fold title tokens in at titleBoost weight: a heading match is a strong
		// topicality signal and should dominate a passing body mention.
		for _, tok := range tokenize(s.Title) {
			tf[tok] += titleBoost
		}
		if len(tf) == 0 {
			continue
		}
		var length float64
		for _, c := range tf {
			length += c
		}
		docIdx := len(idx.docs)
		idx.docs = append(idx.docs, document{
			anchor:   s.Anchor,
			title:    s.Title,
			kind:     s.Kind,
			text:     s.Text,
			termFreq: tf,
			length:   length,
		})
		for tok := range tf {
			idx.postings[tok] = append(idx.postings[tok], docIdx)
			idx.docFreq[tok]++
		}
		totalLen += length
	}
	if len(idx.docs) > 0 {
		idx.avgLen = totalLen / float64(len(idx.docs))
	}
	return idx
}

// NewFromCorpus builds an index over a corpus's prose sections (KindSpec +
// KindPlugin) plus engine sections at lower kind weight. It is the standard
// constructor for the docs-search surface; pass docs.Load()'s corpus.
func NewFromCorpus(c *docs.Corpus) *Index {
	if c == nil {
		return New(nil)
	}
	return New(c.Sections)
}

// Query scores q against every document sharing a query term and returns up to
// limit hits ranked by descending BM25 score. An empty or stop-only query, a
// limit <= 0, or an empty index yields a nil slice. Ties break on anchor for a
// deterministic order.
func (ix *Index) Query(q string, limit int) []PassageHit {
	if ix == nil || len(ix.docs) == 0 || limit <= 0 {
		return nil
	}
	terms := dedupe(tokenize(q))
	if len(terms) == 0 {
		return nil
	}

	n := float64(len(ix.docs))
	// Accumulate per-document scores over only the documents that match a term.
	scores := make(map[int]float64)
	for _, term := range terms {
		posting, ok := ix.postings[term]
		if !ok {
			continue
		}
		df := float64(ix.docFreq[term])
		// Okapi BM25 IDF with the +1 floor so a term in every document still
		// scores non-negatively.
		idf := math.Log(1 + (n-df+0.5)/(df+0.5))
		for _, di := range posting {
			d := &ix.docs[di]
			tf := d.termFreq[term]
			denom := tf + bm25K1*(1-bm25B+bm25B*d.length/ix.avgLen)
			scores[di] += idf * (tf * (bm25K1 + 1)) / denom
		}
	}
	if len(scores) == 0 {
		return nil
	}

	hits := make([]PassageHit, 0, len(scores))
	for di, sc := range scores {
		d := &ix.docs[di]
		weighted := sc * kindWeight[d.kind]
		hits = append(hits, PassageHit{
			Anchor:  d.anchor,
			Title:   d.title,
			Kind:    d.kind,
			Score:   weighted,
			Snippet: snippet(d.text, terms),
		})
	}
	sort.Slice(hits, func(i, j int) bool {
		if hits[i].Score != hits[j].Score {
			return hits[i].Score > hits[j].Score
		}
		return hits[i].Anchor < hits[j].Anchor
	})
	if len(hits) > limit {
		hits = hits[:limit]
	}
	return hits
}

// stopWords are high-frequency English tokens that carry no topical signal;
// dropping them keeps short conceptual queries ("the pipeline schedule")
// focused on their content terms.
var stopWords = map[string]struct{}{
	"a": {}, "an": {}, "and": {}, "are": {}, "as": {}, "at": {}, "be": {},
	"by": {}, "for": {}, "from": {}, "in": {}, "is": {}, "it": {}, "of": {},
	"on": {}, "or": {}, "that": {}, "the": {}, "to": {}, "with": {},
}

// tokenize lowercases s and splits it into content tokens on any
// non-alphanumeric rune, dropping stop words and single-character tokens. The
// same tokenizer runs over documents at index time and queries at search time,
// so the vocabularies always agree.
func tokenize(s string) []string {
	fields := strings.FieldsFunc(s, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsNumber(r)
	})
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		tok := strings.ToLower(f)
		if len(tok) < 2 {
			continue
		}
		if _, stop := stopWords[tok]; stop {
			continue
		}
		out = append(out, tok)
	}
	return out
}

// dedupe returns toks with duplicates removed, preserving first-seen order. A
// query term scores a document once regardless of how often the user repeated
// it.
func dedupe(toks []string) []string {
	seen := make(map[string]struct{}, len(toks))
	out := make([]string, 0, len(toks))
	for _, t := range toks {
		if _, ok := seen[t]; ok {
			continue
		}
		seen[t] = struct{}{}
		out = append(out, t)
	}
	return out
}

// snippetRadius is the number of characters of context shown on each side of
// the matched term in a snippet.
const snippetRadius = 80

// snippet returns a short window of text centered on the first occurrence of
// any query term, with leading/trailing whitespace collapsed and ellipses on
// truncated ends. When no term is found in the raw text (it matched only via
// the title), it falls back to the text's head.
func snippet(text string, terms []string) string {
	flat := strings.Join(strings.Fields(text), " ")
	lower := strings.ToLower(flat)

	best := -1
	for _, term := range terms {
		if i := strings.Index(lower, term); i >= 0 && (best < 0 || i < best) {
			best = i
		}
	}
	if best < 0 {
		return head(flat)
	}

	start := best - snippetRadius
	if start < 0 {
		start = 0
	}
	end := best + snippetRadius
	if end > len(flat) {
		end = len(flat)
	}
	out := flat[start:end]
	if start > 0 {
		out = "…" + out
	}
	if end < len(flat) {
		out = out + "…"
	}
	return out
}

// head returns the leading window of flat for sections whose match came only
// from the title.
func head(flat string) string {
	if len(flat) <= 2*snippetRadius {
		return flat
	}
	return flat[:2*snippetRadius] + "…"
}
