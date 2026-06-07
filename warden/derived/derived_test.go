package derived

import (
	"fmt"
	"reflect"
	"sync"
	"testing"

	"github.com/mjmorales/funpack/warden/index"
)

// projectLineWithTags is a hand-built `project` record carrying a known
// tag_registry in a deliberate AUTHORED order — not alphabetical — so the TAGS
// projection is proven to preserve the producer's order rather than re-sort it.
// It is the minimal well-shaped project record (every §29 §2 mandatory key
// present, marker keys pipeline_flattened/gate_results present so the spine
// classifies it as project); only the tag_registry value matters to the
// projection. This is hand-authored, NOT machine-emitted — the in-repo tests
// never build funpack.
const projectLineWithTags = `{"schema_version":2,` +
	`"entrypoints":[{"name":"main","pipeline":"Yard","tick_hz":60,"bindings":"bindings"}],` +
	`"builds":[{"name":"native","platform":"desktop"}],` +
	`"tag_registry":["zebra","game","alpha","mid","beta"],` +
	`"capabilities":["Render","Input","State"],` +
	`"pipeline_flattened":[{"ordinal":0,"stage":"startup","behavior":"setup"}],` +
	`"gate_results":[{"gate":"Cyclomatic","passed":true}]}`

// authoredTagOrder is the tag_registry of projectLineWithTags in its exact
// authored order — the order the TAGS projection must reproduce verbatim. It is
// intentionally not alphabetical, so a projection that sorted the tags would
// produce a different slice and fail the order assertion.
var authoredTagOrder = []string{"zebra", "game", "alpha", "mid", "beta"}

// declLine builds a well-shaped `decl` record line with the given identity and
// the stub/todo directive flags set, every other §29 §2 mandatory field carrying
// a benign empty/zero value. It is the fixture factory the HOLES/TODOS tests fold
// over — the live corpus carries zero @stub/@todo, so a hand-built decl fixture
// is the only surface that exercises the holes/todos projection (the producer's
// live decl emission binds it in a sibling epic; this projection does not depend
// on it). The marker keys qualified_name/dup_class/mut_data are present so the
// spine classifies the line as a decl record.
func declLine(qualifiedName, kind string, span int, stub, todo bool) string {
	return fmt.Sprintf(
		`{"schema_version":2,"qualified_name":%q,"kind":%q,"file":"","span":%d,`+
			`"doc":"","gtags":[],"stub":%t,"todo":%t,"debug":[],"emits":[],`+
			`"consumes":[],"calls":[],"dup_class":0,"mut_data":[]}`,
		qualifiedName, kind, span, stub, todo,
	)
}

// recordsFrom decodes a set of NDJSON lines per-line through the spine
// (index.DecodeLine — the same gate-and-dispatch seam DecodeStream applies to
// each live-stream line) into the []Record the projection folds over, so the
// test exercises the integrated decode→project path, not a bypass.
func recordsFrom(t *testing.T, lines ...string) []index.Record {
	t.Helper()
	var recs []index.Record
	for _, line := range lines {
		rec, err := index.DecodeLine([]byte(line))
		if err != nil {
			t.Fatalf("fixture line failed the spine: %v\nline: %s", err, line)
		}
		recs = append(recs, rec)
	}
	return recs
}

func TestProjectionTagsPreserveAuthoredOrder(t *testing.T) {
	// The TAGS projection reproduces the project record's tag_registry in its
	// authored order verbatim — the order is producer-given and is itself the
	// contract, so the projection preserves it rather than sorting. The fixture's
	// order is deliberately non-alphabetical, so a sorting projection would fail.
	view, err := Project(recordsFrom(t, projectLineWithTags))
	if err != nil {
		t.Fatalf("expected the project line to project, got %v", err)
	}
	if !reflect.DeepEqual([]string(view.Tags), authoredTagOrder) {
		t.Fatalf("tags view = %v, want authored order %v", view.Tags, authoredTagOrder)
	}
}

func TestProjectionTagsAreaCopyNotAlias(t *testing.T) {
	// The TAGS view is a copy of the project record's slice, never an alias —
	// mutating the projected view cannot reach back to the source record's
	// storage. (The fold copies on projection; this guards that copy stays in
	// place so two views over the same record never share backing.)
	recs := recordsFrom(t, projectLineWithTags)
	first, err := Project(recs)
	if err != nil {
		t.Fatalf("first projection failed: %v", err)
	}
	second, err := Project(recs)
	if err != nil {
		t.Fatalf("second projection failed: %v", err)
	}
	first.Tags[0] = "MUTATED"
	if second.Tags[0] == "MUTATED" {
		t.Fatal("mutating one tags view reached another — the projection must copy, not alias")
	}
}

func TestProjectionHolesSurfaceStubDecls(t *testing.T) {
	// The HOLES projection surfaces exactly the stub=true declarations and no
	// others — a clean (stub=false) decl is excluded, a stub=true decl is
	// included with its identity/location projected. A project record is present
	// so the fold has its required tag source.
	recs := recordsFrom(t,
		projectLineWithTags,
		declLine("yard.spawn", "Behavior", 10, true, false),
		declLine("yard.tick", "Behavior", 20, false, false),
		declLine("yard.render", "Behavior", 30, true, false),
	)
	view, err := Project(recs)
	if err != nil {
		t.Fatalf("expected the stub fixtures to project, got %v", err)
	}
	got := qualifiedNames(view.Holes)
	want := []string{"yard.render", "yard.spawn"} // sorted by qualified name
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("holes view = %v, want %v", got, want)
	}
	if view.Holes[0].Kind != index.DeclKindBehavior || view.Holes[0].Span != 30 {
		t.Fatalf("holes[0] identity mismatch: %+v", view.Holes[0])
	}
}

func TestProjectionTodosSurfaceTodoDecls(t *testing.T) {
	// The TODOS projection surfaces exactly the todo=true declarations, sorted by
	// qualified name. A decl can be both a hole and a todo (stub and todo both
	// set) — it then appears in both views, since the two flags are independent
	// §29 §2 directives.
	recs := recordsFrom(t,
		projectLineWithTags,
		declLine("yard.cleanup", "Fn", 5, false, true),
		declLine("yard.spawn", "Behavior", 10, true, true),
		declLine("yard.tick", "Behavior", 20, false, false),
	)
	view, err := Project(recs)
	if err != nil {
		t.Fatalf("expected the todo fixtures to project, got %v", err)
	}
	gotTodos := qualifiedNames(view.Todos)
	wantTodos := []string{"yard.cleanup", "yard.spawn"}
	if !reflect.DeepEqual(gotTodos, wantTodos) {
		t.Fatalf("todos view = %v, want %v", gotTodos, wantTodos)
	}
	// yard.spawn carries both flags, so it lands in HOLES as well.
	if got := qualifiedNames(view.Holes); !reflect.DeepEqual(got, []string{"yard.spawn"}) {
		t.Fatalf("holes view = %v, want [yard.spawn] (the stub+todo decl)", got)
	}
}

func TestProjectionRejectsNoProjectRecord(t *testing.T) {
	// A stream with decl records but no project record is refused — the TAGS
	// projection has no source, and the fold reports the missing project record
	// rather than emitting an empty tags view (an absent source is a contract
	// violation, not an empty result).
	recs := recordsFrom(t, declLine("yard.spawn", "Behavior", 10, true, false))
	_, err := Project(recs)
	if err == nil {
		t.Fatal("expected a stream with no project record to fail")
	}
}

func TestProjectionRejectsTwoProjectRecords(t *testing.T) {
	// Two project records in one stream is a contract violation — the project
	// record is one-per-stream (spec §29 §2), so the fold refuses rather than
	// silently picking one.
	recs := recordsFrom(t, projectLineWithTags, projectLineWithTags)
	_, err := Project(recs)
	if err == nil {
		t.Fatal("expected two project records to fail")
	}
}

func TestDeterministicFoldRepeatsByteStable(t *testing.T) {
	// The fold is deterministic: two projections over the SAME records produce a
	// byte-identical View. reflect.DeepEqual over the whole view (tags + holes +
	// todos) is the byte-stability assertion at the value level — any clock,
	// map-order, or scheduling leak into folded state would diverge the two runs.
	recs := recordsFrom(t,
		projectLineWithTags,
		declLine("yard.spawn", "Behavior", 10, true, false),
		declLine("yard.cleanup", "Fn", 5, false, true),
		declLine("yard.render", "Behavior", 30, true, true),
	)
	first, err := Project(recs)
	if err != nil {
		t.Fatalf("first projection failed: %v", err)
	}
	second, err := Project(recs)
	if err != nil {
		t.Fatalf("second projection failed: %v", err)
	}
	if !reflect.DeepEqual(first, second) {
		t.Fatalf("two folds over the same records diverged:\n first=%+v\nsecond=%+v", first, second)
	}
}

func TestDeterministicFoldOrderIndependent(t *testing.T) {
	// The fold's output is a pure function of the record SET, not the arrival
	// order: folding the same decls in a different stream order yields an
	// identical HOLES/TODOS view, because the per-declaration entries are sorted
	// by their total key before reaching the view. (The TAGS view rides the single
	// project record, so its order is unaffected by decl permutation.)
	forward := recordsFrom(t,
		projectLineWithTags,
		declLine("yard.alpha", "Fn", 1, true, false),
		declLine("yard.beta", "Behavior", 2, true, false),
		declLine("yard.gamma", "Pipeline", 3, true, false),
	)
	reverse := recordsFrom(t,
		projectLineWithTags,
		declLine("yard.gamma", "Pipeline", 3, true, false),
		declLine("yard.beta", "Behavior", 2, true, false),
		declLine("yard.alpha", "Fn", 1, true, false),
	)
	fwd, err := Project(forward)
	if err != nil {
		t.Fatalf("forward projection failed: %v", err)
	}
	rev, err := Project(reverse)
	if err != nil {
		t.Fatalf("reverse projection failed: %v", err)
	}
	if !reflect.DeepEqual(fwd.Holes, rev.Holes) {
		t.Fatalf("decl arrival order leaked into the holes view:\n forward=%+v\n reverse=%+v", fwd.Holes, rev.Holes)
	}
}

func TestStableFoldUnderConcurrentProjection(t *testing.T) {
	// Many goroutines projecting the SAME records concurrently all produce a
	// View byte-identical to a serial baseline — proving no shared mutable state,
	// no goroutine-scheduling leak, and (under `go test -race`) no data race in
	// the fold. Each goroutine decodes its own records so the spine's per-line
	// buffer is never shared across goroutines.
	baseline, err := Project(recordsFrom(t,
		projectLineWithTags,
		declLine("yard.spawn", "Behavior", 10, true, false),
		declLine("yard.cleanup", "Fn", 5, false, true),
		declLine("yard.render", "Behavior", 30, true, true),
	))
	if err != nil {
		t.Fatalf("baseline projection failed: %v", err)
	}

	// Each worker folds its OWN independent record slice (decoded up front on the
	// test goroutine, so the spine's per-line buffer is never shared and t.Fatalf
	// stays on the test goroutine) — the fold must hold no shared mutable state.
	const workers = 32
	perWorker := make([][]index.Record, workers)
	for i := range perWorker {
		perWorker[i] = recordsFrom(t,
			projectLineWithTags,
			declLine("yard.spawn", "Behavior", 10, true, false),
			declLine("yard.cleanup", "Fn", 5, false, true),
			declLine("yard.render", "Behavior", 30, true, true),
		)
	}

	var wg sync.WaitGroup
	results := make([]View, workers)
	errs := make([]error, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(slot int) {
			defer wg.Done()
			results[slot], errs[slot] = Project(perWorker[slot])
		}(i)
	}
	wg.Wait()

	for i := 0; i < workers; i++ {
		if errs[i] != nil {
			t.Fatalf("worker %d failed: %v", i, errs[i])
		}
		if !reflect.DeepEqual(results[i], baseline) {
			t.Fatalf("worker %d diverged from the serial baseline:\n got=%+v\nwant=%+v", i, results[i], baseline)
		}
	}
}

// qualifiedNames extracts the projected entries' qualified names in view order —
// the assertion handle the HOLES/TODOS tests compare against an expected ordered
// slice without spelling out every Entry field.
func qualifiedNames(entries []Entry) []string {
	out := make([]string, len(entries))
	for i, e := range entries {
		out[i] = e.QualifiedName
	}
	return out
}
