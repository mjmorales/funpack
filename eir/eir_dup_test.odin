package eir

import "core:testing"

@(private = "file")
opts :: proc(min_nodes: int, fold_literals: bool) -> Dup_Options {
	return Dup_Options{min_nodes = min_nodes, fold_literals = fold_literals}
}

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

@(test)
test_dup_type1_exact_clone :: proc(t: ^testing.T) {
	result := load_source_fixture("type1", TYPE1_SRC)
	classes := find_clones(result, opts(4, false), context.temp_allocator)

	testing.expect_value(t, len(classes), 1)
	if len(classes) == 1 {
		testing.expect_value(t, len(classes[0].instances), 2)
		testing.expect_value(t, classes[0].kind, "proc_lit")
	}
}

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

@(test)
test_dup_type2_alpha_renamed :: proc(t: ^testing.T) {
	result := load_source_fixture("type2", TYPE2_SRC)
	classes := find_clones(result, opts(4, false), context.temp_allocator)

	testing.expect_value(t, len(classes), 1)
	if len(classes) == 1 {
		testing.expect_value(t, len(classes[0].instances), 2)
		testing.expect_value(t, classes[0].kind, "proc_lit")
	}
}

@(private = "file")
FREE_NAME_SRC :: `package p

eps :: proc(a: int) -> int {
	return foo(a) - a
}

zet :: proc(a: int) -> int {
	return bar(a) - a
}
`

@(test)
test_dup_free_name_difference_no_collide :: proc(t: ^testing.T) {
	result := load_source_fixture("freename", FREE_NAME_SRC)
	classes := find_clones(result, opts(2, false), context.temp_allocator)

	testing.expect_value(t, len(classes), 0)
}

@(private = "file")
FLOOR_SRC :: `package p

m1 :: proc(a: int) -> int {
	return a + a
}

m2 :: proc(a: int) -> int {
	return a + a
}
`

@(test)
test_dup_min_nodes_floor :: proc(t: ^testing.T) {
	result := load_source_fixture("floor", FLOOR_SRC)

	above := find_clones(result, opts(20, false), context.temp_allocator)
	testing.expect_value(t, len(above), 0)

	below := find_clones(result, opts(3, false), context.temp_allocator)
	testing.expect_value(t, len(below), 1)
	if len(below) == 1 {
		testing.expect_value(t, len(below[0].instances), 2)
	}
}

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

@(test)
test_dup_maximal_only_suppression :: proc(t: ^testing.T) {
	result := load_source_fixture("maximal", MULTI_CLASS_SRC)
	classes := find_clones(result, opts(3, false), context.temp_allocator)

	testing.expect_value(t, len(classes), 2)
	for c in classes {
		testing.expect_value(t, len(c.instances), 2)
		testing.expect_value(t, c.kind, "proc_lit")
	}
}

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

@(test)
test_dup_fold_literals :: proc(t: ^testing.T) {
	result := load_source_fixture("fold", FOLD_SRC)

	distinct_classes := find_clones(result, opts(3, false), context.temp_allocator)
	testing.expect_value(t, len(distinct_classes), 0)

	folded := find_clones(result, opts(3, true), context.temp_allocator)
	testing.expect_value(t, len(folded), 1)
	if len(folded) == 1 {
		testing.expect_value(t, len(folded[0].instances), 2)
	}
}

@(test)
test_dup_collision_does_not_merge :: proc(t: ^testing.T) {
	H :: u64(0xDEAD_BEEF_CAFE_F00D)
	records := []Subtree_Record {
		{hash = H, canon = "shape-A", node_count = 40, kind = "block", path = "a.odin", line_start = 1, line_end = 10},
		{hash = H, canon = "shape-B", node_count = 40, kind = "block", path = "b.odin", line_start = 1, line_end = 10},
		{hash = H, canon = "shape-A", node_count = 40, kind = "block", path = "c.odin", line_start = 1, line_end = 10},
	}
	classes := cluster_and_suppress(records, context.temp_allocator)

	testing.expect_value(t, len(classes), 1)
	if len(classes) == 1 {
		testing.expect_value(t, len(classes[0].instances), 2)
		testing.expect_value(t, classes[0].instances[0].path, "a.odin")
		testing.expect_value(t, classes[0].instances[1].path, "c.odin")
	}
}

@(test)
test_dup_deterministic :: proc(t: ^testing.T) {
	result := load_source_fixture("determinism", MULTI_CLASS_SRC)
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
