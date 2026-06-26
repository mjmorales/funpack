// Clone-engine tests: the dup engine is the algorithmic heart of the DRY checker, so
// its floor is the dup_class doctrine itself — (1) a Type-1 exact duplicate is one
// clone class, (2) a Type-2 alpha-renamed duplicate collides as the SAME class
// (positional-slot canonicalization), (3) a free-name difference does NOT collide
// (free spellings are structural), (4) the min-nodes floor excludes sub-floor and
// admits at-floor clones, (5) maximal-only suppression drops a fragment wholly
// contained in a larger same-instance-set clone, (6) --fold-literals collapses a
// constant-only difference into a collision, and (7) the output is deterministic.
// Each fixture is a real source string parsed through the loader (load_clone_fixture),
// so the tests exercise the engine over genuine core:odin/ast trees.
package eir

import "core:testing"

// load_clone_fixture writes one source to a fresh temp tree, parses the tree through
// the loader, removes the temp files (the parsed tree lives in the temp allocator,
// independent of disk), and returns the Load_Result the engine consumes. The shared
// fixture helpers (fixture_root / write_fixture / remove_tree) come from
// eir_discover_test.odin.
@(private = "file")
load_clone_fixture :: proc(label, src: string) -> Load_Result {
	root := fixture_root(label)
	write_fixture(root, "fix.odin", src)

	l: Loader
	loader_init(&l, context.temp_allocator)
	result, _ := load_dir(&l, root, nil)

	remove_tree(root)
	return result
}

// opts is a terse Dup_Options constructor for the tests.
@(private = "file")
opts :: proc(min_nodes: int, fold_literals: bool) -> Dup_Options {
	return Dup_Options{min_nodes = min_nodes, fold_literals = fold_literals}
}

// TYPE1_SRC: two procs with byte-identical bodies AND identical param names. The proc
// names differ (alpha/beta), but a proc literal excludes its declaration name, so the
// two literals collide.
@(private = "file")
TYPE1_SRC :: `package p

alpha :: proc(a: int) -> int {
	x := a + a
	y := x * a
	return y - a
}

beta :: proc(a: int) -> int {
	x := a + a
	y := x * a
	return y - a
}
`

// test_dup_type1_exact_clone: an exact duplicate is one clone class with two
// instances. Maximal-only collapses the nested body/statement clones into the single
// proc-literal clone.
@(test)
test_dup_type1_exact_clone :: proc(t: ^testing.T) {
	result := load_clone_fixture("type1", TYPE1_SRC)
	classes := find_clones(result, opts(4, false), context.temp_allocator)

	testing.expect_value(t, len(classes), 1)
	if len(classes) == 1 {
		testing.expect_value(t, len(classes[0].instances), 2)
		testing.expect_value(t, classes[0].kind, "proc_lit")
	}
}

// TYPE2_SRC: two procs identical in structure but with every bound name renamed
// (param p↔q, locals m↔r, n↔s). Only bound-name spellings differ, so positional-slot
// canonicalization must make them collide.
@(private = "file")
TYPE2_SRC :: `package p

gamma :: proc(p: int) -> int {
	m := p + p
	n := m * p
	return n - p
}

delta :: proc(q: int) -> int {
	r := q + q
	s := r * q
	return s - q
}
`

// test_dup_type2_alpha_renamed: an alpha-renamed duplicate collides as the SAME clone
// class — proving a bound name canonicalizes to its binding slot, not its spelling.
@(test)
test_dup_type2_alpha_renamed :: proc(t: ^testing.T) {
	result := load_clone_fixture("type2", TYPE2_SRC)
	classes := find_clones(result, opts(4, false), context.temp_allocator)

	testing.expect_value(t, len(classes), 1)
	if len(classes) == 1 {
		testing.expect_value(t, len(classes[0].instances), 2)
		testing.expect_value(t, classes[0].kind, "proc_lit")
	}
}

// FREE_NAME_SRC: two procs identical except the called function (foo vs bar), a FREE
// name. The free spelling is structural, so the procs must NOT collide — and with no
// other shared subtree at the floor, the scan finds zero clones.
@(private = "file")
FREE_NAME_SRC :: `package p

eps :: proc(a: int) -> int {
	return foo(a) - a
}

zet :: proc(a: int) -> int {
	return bar(a) - a
}
`

// test_dup_free_name_difference_no_collide: a single differing free name defeats the
// clone — the complement of the Type-2 case, proving free names keep their spelling.
@(test)
test_dup_free_name_difference_no_collide :: proc(t: ^testing.T) {
	result := load_clone_fixture("freename", FREE_NAME_SRC)
	classes := find_clones(result, opts(2, false), context.temp_allocator)

	testing.expect_value(t, len(classes), 0)
}

// FLOOR_SRC: two identical one-statement procs. The proc-literal clone is small (~9
// nodes), so it sits below a high floor and at or above a low one.
@(private = "file")
FLOOR_SRC :: `package p

m1 :: proc(a: int) -> int {
	return a + a
}

m2 :: proc(a: int) -> int {
	return a + a
}
`

// test_dup_min_nodes_floor: a high floor excludes the small duplicate, a low floor
// admits it — the noise gate that keeps trivial shared shapes out of the report.
@(test)
test_dup_min_nodes_floor :: proc(t: ^testing.T) {
	result := load_clone_fixture("floor", FLOOR_SRC)

	above := find_clones(result, opts(20, false), context.temp_allocator)
	testing.expect_value(t, len(above), 0)

	below := find_clones(result, opts(3, false), context.temp_allocator)
	testing.expect_value(t, len(below), 1)
	if len(below) == 1 {
		testing.expect_value(t, len(below[0].instances), 2)
	}
}

// MULTI_CLASS_SRC: two INDEPENDENT clone families — f1/f2 (one shape) and g1/g2
// (another). Each family's procs are multi-statement, so without suppression each
// would yield a proc clone PLUS nested block/statement clones; maximal-only must
// leave exactly one class per family. The two families share no subtree at the floor,
// so suppression is selective — it drops the contained fragments but keeps both
// independent maximal clones.
@(private = "file")
MULTI_CLASS_SRC :: `package p

f1 :: proc(a: int) -> int {
	x := a + a
	y := x * x
	return y - a
}

f2 :: proc(a: int) -> int {
	x := a + a
	y := x * x
	return y - a
}

g1 :: proc(a: int) -> int {
	p := a - a
	q := p + p
	return q * a
}

g2 :: proc(a: int) -> int {
	p := a - a
	q := p + p
	return q * a
}
`

// test_dup_maximal_only_suppression: two independent clone families collapse to two
// classes — one maximal proc clone each, the nested block/statement fragments
// suppressed. A broken suppressor would surface the fragments as extra classes.
@(test)
test_dup_maximal_only_suppression :: proc(t: ^testing.T) {
	result := load_clone_fixture("maximal", MULTI_CLASS_SRC)
	classes := find_clones(result, opts(3, false), context.temp_allocator)

	testing.expect_value(t, len(classes), 2)
	for c in classes {
		testing.expect_value(t, len(c.instances), 2)
		testing.expect_value(t, c.kind, "proc_lit")
	}
}

// FOLD_SRC: two procs identical except their literal constants (1/2/3 vs 9/8/7).
// With distinct-literal hashing they are unrelated; under --fold-literals the
// constants collapse and the procs collide.
@(private = "file")
FOLD_SRC :: `package p

c1 :: proc(a: int) -> int {
	x := a + 1
	y := x * 2
	return y - 3
}

c2 :: proc(a: int) -> int {
	x := a + 9
	y := x * 8
	return y - 7
}
`

// test_dup_fold_literals: a constant-only difference is no clone by default and a
// clone under --fold-literals.
@(test)
test_dup_fold_literals :: proc(t: ^testing.T) {
	result := load_clone_fixture("fold", FOLD_SRC)

	distinct_classes := find_clones(result, opts(3, false), context.temp_allocator)
	testing.expect_value(t, len(distinct_classes), 0)

	folded := find_clones(result, opts(3, true), context.temp_allocator)
	testing.expect_value(t, len(folded), 1)
	if len(folded) == 1 {
		testing.expect_value(t, len(folded[0].instances), 2)
	}
}

// test_dup_deterministic: the same input yields byte-identical class ordering and
// content across two runs — no map iteration order reaches the result. The two-family
// fixture gives multiple classes so the ordering is meaningful.
@(test)
test_dup_deterministic :: proc(t: ^testing.T) {
	result := load_clone_fixture("determinism", MULTI_CLASS_SRC)
	o := opts(3, false)

	a := find_clones(result, o, context.temp_allocator)
	b := find_clones(result, o, context.temp_allocator)

	testing.expect_value(t, len(a), len(b))
	if len(a) != len(b) {
		return
	}
	for i in 0 ..< len(a) {
		testing.expect_value(t, a[i].hash, b[i].hash)
		testing.expect_value(t, a[i].node_count, b[i].node_count)
		testing.expect_value(t, a[i].kind, b[i].kind)
		testing.expect_value(t, len(a[i].instances), len(b[i].instances))
		if len(a[i].instances) != len(b[i].instances) {
			continue
		}
		for j in 0 ..< len(a[i].instances) {
			testing.expect_value(t, a[i].instances[j].path, b[i].instances[j].path)
			testing.expect_value(t, a[i].instances[j].line_start, b[i].instances[j].line_start)
			testing.expect_value(t, a[i].instances[j].line_end, b[i].instances[j].line_end)
		}
	}
}
