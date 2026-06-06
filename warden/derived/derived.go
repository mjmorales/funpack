// Package derived is warden's derived-view projection over the decoded Index
// Contract (spec §29 §3): the ephemeral, gitignored, rebuilt projection of the
// index into the three views warden's query surface reports — TAGS, HOLES, and
// TODOS. It is the "derived" half of the §29 §3 storage split (derived =
// holes/todos/tags, a projection of the index; authored = goals/leases/criteria,
// warden's own committed state); this package owns the projection only, never the
// authored task-DB fold, leases, or dispatch.
//
// The projection is a DETERMINISTIC FOLD matching warden's §29 §3 determinism
// tier (event-log → bit-identical state): two folds over the same set of decoded
// records produce a byte-identical View. The discipline is concrete — nothing
// nondeterministic reaches folded state or output: no Go map iteration order, no
// goroutine scheduling, no wall-clock read. Where input order is NOT
// producer-given (the per-declaration HOLES/TODOS entries, which arrive in
// whatever order the stream carried decls), the fold sorts inputs by a total key
// before folding, so the output order is a pure function of the records, not of
// their arrival order. Where order IS producer-given (the TAGS view rides the
// project record's authored tag_registry), it is preserved verbatim — the
// authored order is the contract, and re-sorting it would discard meaning.
//
// warden NEVER writes source (spec §29 §3): this projection reports what the
// index says; the agent edits source; recompilation regenerates the index;
// warden re-projects. So this package consumes already-decoded records and emits
// a view — it does no IO, no decode, and no source mutation.
package derived

import (
	"fmt"
	"sort"

	"github.com/mjmorales/funpack/warden/index"
)

// TagsView is the projected registry-tag view: the live project record's
// tag_registry (spec §29 §2/§3) in the producer's AUTHORED order, verbatim. The
// order is producer-given — the registry is the @gtag declaration order lifted
// from tags.fcfg — so the projection preserves it rather than sorting, since the
// authored order is itself the contract a reader queries against. It is a value
// copy of the project record's slice (never an alias), so a later mutation of the
// source record cannot reach a projected view.
type TagsView []string

// Entry is one per-declaration derived-view row — the projected shape both the
// HOLES and TODOS views carry. It names the declaration the directive sits on
// (qualified name + kind) and where it lives in source (file + span), the
// provenance chain warden's query surface reports ("T-0042's hole is still open"
// resolves to a qualified name at a file/span). It is the projection of a `decl`
// record's identity fields, never the whole record — the derived view carries
// only what a holes/todos query needs to point an operator at the debt.
type Entry struct {
	// QualifiedName is the module-qualified declaration name (§15) the directive
	// is attached to — the stable identity a holes/todos query reports.
	QualifiedName string
	// Kind is the source declaration form (the closed DeclKind from the decoder).
	Kind index.DeclKind
	// File is the source file path; "" in the single-source frontend (the
	// producer does not yet thread the path).
	File string
	// Span is the 1-based source line of the declaration keyword (§9 line-span).
	Span int
}

// HolesView is the projected @stub view: every declaration whose decl record
// carries stub=true (spec §29 §2 enumeration), in the fold's deterministic order
// (sorted by entryKey, since decl arrival order is not producer-meaningful). A
// hole is an incomplete declaration the agent left behind — the §29 §4 backstop
// bans them under --release — so warden surfaces them as the work still open.
type HolesView []Entry

// TodosView is the projected @todo view: every declaration whose decl record
// carries todo=true (spec §29 §2 enumeration), in the same deterministic
// sorted order as HolesView. A todo is debt with a deadline (§29 §4: @todo
// expiry → build error); warden surfaces the open todos so the debt has a
// visible owner.
type TodosView []Entry

// View is the whole derived-view projection of one index stream — the three §29
// §3 derived views (TAGS, HOLES, TODOS) folded from the decoded records. It is
// the ephemeral, rebuilt artifact warden's query surface reads; it holds no
// authored state and no clock, so two folds over the same records produce a
// byte-identical View.
type View struct {
	// Tags is the live tag_registry in authored order (from the project record).
	Tags TagsView
	// Holes is the stub=true declarations in deterministic sorted order.
	Holes HolesView
	// Todos is the todo=true declarations in deterministic sorted order.
	Todos TodosView
}

// Project folds a slice of spine-decoded Records into the derived View (spec §29
// §3). It is the deterministic fold: it decodes each record to its typed form
// (the project record feeds TAGS; each decl record feeds HOLES/TODOS when its
// stub/todo flag is set), then sorts the per-declaration entries by their total
// entryKey so the output order is a pure function of the records, independent of
// their arrival order. Exactly one project record is expected per stream (spec
// §29 §2: the project record is the one-per-stream summary) — zero or more than
// one is a contract violation, refused rather than guessed. No map iteration,
// goroutine, or clock touches the fold, so two runs over the same records are
// byte-identical.
func Project(records []index.Record) (View, error) {
	var tags TagsView
	tagsSeen := false
	holes := make(HolesView, 0)
	todos := make(TodosView, 0)

	for i, rec := range records {
		switch rec.Kind {
		case index.RecordKindProject:
			if tagsSeen {
				return View{}, fmt.Errorf("derived: stream carries more than one project record (record %d) — the project record is one-per-stream (spec §29 §2)", i)
			}
			project, err := index.DecodeProjectRecord(rec)
			if err != nil {
				return View{}, fmt.Errorf("derived: decoding project record %d: %w", i, err)
			}
			tags = projectTags(project)
			tagsSeen = true
		case index.RecordKindDecl:
			decl, err := index.DecodeDecl(rec.Raw)
			if err != nil {
				return View{}, fmt.Errorf("derived: decoding decl record %d: %w", i, err)
			}
			if decl.Stub {
				holes = append(holes, declEntry(decl))
			}
			if decl.Todo {
				todos = append(todos, declEntry(decl))
			}
		default:
			return View{}, fmt.Errorf("derived: record %d has unclassified kind %s — the spine never produces it on success", i, rec.Kind)
		}
	}

	if !tagsSeen {
		return View{}, fmt.Errorf("derived: stream carries no project record — the tag_registry projection has no source (spec §29 §2)")
	}

	sortEntries(holes)
	sortEntries(todos)

	return View{Tags: tags, Holes: holes, Todos: todos}, nil
}

// projectTags lifts the live tag_registry from a decoded project record into the
// TagsView, copying the slice so the view never aliases the record's storage (a
// later mutation of the record cannot reach the projected view). The authored
// order is preserved verbatim — it is producer-given and is itself the contract,
// so the projection never re-sorts it.
func projectTags(project index.ProjectRecord) TagsView {
	tags := make(TagsView, len(project.TagRegistry))
	copy(tags, project.TagRegistry)
	return tags
}

// declEntry projects a decoded decl record into the per-declaration Entry both
// the HOLES and TODOS views carry — the identity-and-location subset a query
// needs to point an operator at the debt, never the whole decl record.
func declEntry(decl index.DeclRecord) Entry {
	return Entry{
		QualifiedName: decl.QualifiedName,
		Kind:          decl.Kind,
		File:          decl.File,
		Span:          decl.Span,
	}
}

// sortEntries sorts a per-declaration view in place by entryKey's total order, so
// the projected order is a pure function of the records and never their arrival
// order (the fold's determinism obligation). sort.SliceStable is used so two
// entries with an identical key keep a deterministic relative order rather than
// an implementation-defined swap, keeping the output byte-stable even when the
// key is not unique.
func sortEntries[E ~[]Entry](entries E) {
	sort.SliceStable(entries, func(a, b int) bool {
		return entryLess(entries[a], entries[b])
	})
}

// entryLess is the total ordering the per-declaration views fold to: qualified
// name first (the stable declaration identity), then file, then span. The key is
// total over every field that distinguishes two entries, so the sort is a
// deterministic function of the records alone — no field is left to an
// implementation-defined tiebreak that arrival order could leak into.
func entryLess(a, b Entry) bool {
	if a.QualifiedName != b.QualifiedName {
		return a.QualifiedName < b.QualifiedName
	}
	if a.File != b.File {
		return a.File < b.File
	}
	return a.Span < b.Span
}
