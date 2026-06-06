// The §07 pipeline-flattening pass and the §04/§07 effect-closure EDGE check.
// It runs after the §06 §6 behavior-contract NODE check (contracts.odin): the
// node check is per-behavior slot well-formedness; this is the cross-behavior
// edge check, and it needs the depth-first flattened pipeline as its total
// order. A pipeline is funpack's schedule — an ordered plan whose stage order
// IS its meaning (spec §07 §1) — and a pipeline tree flattens depth-first into
// one total order (spec §07 §3): a stage member that names a sub-pipeline
// expands in place at its position; a member that names a behavior is a leaf
// step. The gameplay surface's Pong pipeline is single-level (no sub-pipeline
// member), but the walk is the general depth-first one, so a nested pipeline
// would expand correctly.
//
// Over that total order the pass builds the signal routing graph from the
// typed signatures (typecheck.odin): a behavior whose return emits a signal
// list [S] is a producer at its flattened ordinal, and a behavior whose params
// take an inbound signal list [S] is a consumer at its ordinal (spec §06 §3:
// params are reads, return is writes). Effect closure (spec §04 §4 / §07 §2)
// holds iff every emitted user signal has a consuming stage downstream — a
// consumer at an ordinal strictly greater than at least one producer's ordinal
// in the flattened order. Same-stage members count as downstream because the
// flatten assigns each a distinct strictly-increasing ordinal in listed order
// (so score at its ordinal is upstream of tally/serve at theirs, both in the
// scoring stage). Engine commands (Spawn/Draw) are engine-consumed and never
// enter the routing graph, so they are always satisfied.
//
// Boundary: this produces the flattened order and the routing map in memory —
// the checked, contract-validated AST + flattened pipeline. It does NOT
// serialize (artifact emission owns that; the in-memory shapes here match the
// artifact-format §11 [pipeline_flattened] and §12 [signal_routing] sections so
// the emitter is a straight projection) and does NOT execute (the runtime
// interpreter owns execution).
package funpack

// Flat_Step is one step of the depth-first flattened total order (spec §07 §3,
// artifact-format §11): the 0-based ordinal a tick's fold visits it at, the
// owning stage name (documentary — its position is the contract, spec §07 §1),
// and the occupant run at this step. Ordinals are contiguous and gap-free.
//
// An occupant is either a user behavior or an engine-closed BATTERY (the §11 §3
// `physics:` stage's `solve`). is_battery marks the latter: a battery step holds
// no user Behavior_Decl (the runtime dispatches it to the native solver by the
// (stage, behavior) pair, not a behavior lookup), and its `behavior` field is
// the battery name (`solve`). The artifact §11 line is the same shape either way
// — `step ORDINAL stage:STAGE behavior:NAME` — so the marker stays in-memory;
// the runtime re-derives "this is the battery" from `stage:physics behavior:solve`.
Flat_Step :: struct {
	ordinal:    int,
	stage:      string,
	behavior:   string,
	is_battery: bool,
}

// Signal_Endpoint is a producer or consumer of a signal at a flattened
// ordinal: the behavior and the position it occupies in the total order. The
// ordinal is the closure key — a consumer endpoint is downstream of a producer
// endpoint iff its ordinal is strictly greater.
Signal_Endpoint :: struct {
	ordinal:  int,
	behavior: string,
}

// Signal_Route is one signal type's routing entry (artifact-format §12): every
// producer endpoint (a behavior emitting [signal]) and every consumer endpoint
// (a behavior taking inbound [signal]), each keyed by flattened ordinal so
// closure is a forward-flow check over ordinals alone. signal is the user
// signal type's declared name.
Signal_Route :: struct {
	signal:    string,
	producers: []Signal_Endpoint,
	consumers: []Signal_Endpoint,
}

// Flattened_Pipeline is the flatten pass's in-memory result: the depth-first
// total order (order) and the signal routing map (routes), in the shapes the
// artifact-format §11/§12 sections serialize. routes carries one entry per
// signal that is emitted or consumed anywhere, in signal-declaration order.
Flattened_Pipeline :: struct {
	order:  []Flat_Step,
	routes: []Signal_Route,
}

// Flatten_Error is closed with one arm per way flattening or the edge check can
// reject. Unclosed_Signal is the §04 §4 / §07 §2 effect-closure failure — an
// emitted signal with no downstream consumer. Unknown_Member and
// Recursive_Pipeline are structural flatten failures: a stage names something
// that is neither a behavior nor a sub-pipeline, or a sub-pipeline reference
// cycles (a pipeline tree is acyclic, spec §07 §3).
Flatten_Error :: enum {
	None,
	Unknown_Member,     // a stage member names neither a behavior nor a sub-pipeline
	Recursive_Pipeline, // a sub-pipeline reference cycles — a pipeline tree is acyclic
	Unclosed_Signal,    // an emitted signal with no downstream consumer (effect closure)
}

// Flatten_Verdict pairs a flatten/closure failure with the offending signal so
// an Unclosed_Signal reject names which signal went unclosed (spec §07 §2),
// and carries the flattened pipeline when the walk succeeded. flat is the empty
// Flattened_Pipeline when flattening itself failed (Unknown_Member /
// Recursive_Pipeline); signal is "" unless err is Unclosed_Signal.
Flatten_Verdict :: struct {
	err:    Flatten_Error,
	signal: string,
	flat:   Flattened_Pipeline,
}

// stage_flatten is the flattening + effect-closure seam. It flattens the named
// root pipeline depth-first into the total order, builds the signal routing
// graph from the typed signatures, and runs the effect-closure edge check over
// that order. The root is the first declared pipeline (the gameplay surface
// declares exactly one — Pong); a source with no pipeline flattens to the
// empty order and passes closure vacuously. A flatten failure
// (Unknown_Member / Recursive_Pipeline) returns before the closure check, since
// closure has no order to run over.
stage_flatten :: proc(typed: Typed_Ast) -> Flatten_Verdict {
	if len(typed.ast.pipelines) == 0 {
		return Flatten_Verdict{err = .None}
	}
	root := typed.ast.pipelines[0]
	order, flatten_err := flatten_pipeline(typed, root)
	if flatten_err != .None {
		return Flatten_Verdict{err = flatten_err}
	}
	routes := build_routes(typed, order)
	if unclosed, ok := first_unclosed(routes); ok {
		return Flatten_Verdict{err = .Unclosed_Signal, signal = unclosed}
	}
	return Flatten_Verdict {
		err = .None,
		flat = Flattened_Pipeline{order = order, routes = routes},
	}
}

// flatten_pipeline walks a pipeline's ordered stages and expands each into the
// growing total order. The walk is the general depth-first one (spec §07 §3):
// a stage member that names a leaf occupant (a behavior, or the startup fn) is
// a step appended at the next ordinal; a member that names a sub-pipeline
// expands in place, recursing into its stages before the next member. A
// visited-set guards the recursion so a sub-pipeline cycle is a
// Recursive_Pipeline reject rather than a stack overflow.
flatten_pipeline :: proc(typed: Typed_Ast, root: Pipeline_Node) -> (order: []Flat_Step, err: Flatten_Error) {
	steps := make([dynamic]Flat_Step, 0, 16, context.temp_allocator)
	visiting := make(map[string]bool, context.temp_allocator)
	flatten_err := expand_pipeline(typed, root, &steps, &visiting)
	return steps[:], flatten_err
}

// expand_pipeline appends one pipeline's flattened steps to the order in
// depth-first stage-then-member sequence, recursing into a member that names a
// sub-pipeline. visiting holds the pipelines on the current recursion path: a
// member naming one already on the path is a cycle (Recursive_Pipeline). The
// step's stage is the stage that LISTED the member, so a sub-pipeline's
// expanded leaves keep their own inner stage names (the sub-pipeline's stage),
// matching the depth-first flatten's "expand in place" rule. A leaf occupant is
// any term-resolvable member (a behavior or the startup fn) — the same
// term-table window the contract node check reads slot occupants through
// (contracts.odin), so the startup stage's setup() fn is a leaf step like any
// behavior.
expand_pipeline :: proc(
	typed: Typed_Ast,
	pipeline: Pipeline_Node,
	steps: ^[dynamic]Flat_Step,
	visiting: ^map[string]bool,
) -> Flatten_Error {
	if visiting[pipeline.name] {
		return .Recursive_Pipeline
	}
	visiting[pipeline.name] = true
	defer delete_key(visiting, pipeline.name)
	for stage in pipeline.stages {
		// A bare-battery stage (`physics: solve`, spec §11 §3) is an engine-closed
		// stage occupying a real pipeline POSITION with no user behaviors — stage
		// position is the ordering (intent written before it, reactions consumed
		// after). It flattens to one battery step at the next ordinal, so the §11
		// total order records the engine boundary between the upstream intent
		// stages and the downstream reaction stages. The battery name was validated
		// against the engine battery set in the contract node check (contracts.odin).
		if stage.is_battery {
			append(steps, Flat_Step{
				ordinal    = len(steps),
				stage      = stage.name,
				behavior   = stage.battery,
				is_battery = true,
			})
			continue
		}
		for member in stage.behaviors {
			if sub, is_pipeline := find_pipeline_decl(typed.ast, member); is_pipeline {
				expand_pipeline(typed, sub, steps, visiting) or_return
				continue
			}
			if _, is_term := env_term_name(typed.env, member); !is_term {
				return .Unknown_Member
			}
			append(steps, Flat_Step{ordinal = len(steps), stage = stage.name, behavior = member})
		}
	}
	return .None
}

// build_routes builds the signal routing graph over the flattened order: it
// reads each step's behavior signature (resolve.odin records it on the term)
// and registers an emitted signal list [S] in the return as a producer endpoint
// and an inbound signal list [S] param as a consumer endpoint, both at the
// step's ordinal. Routes are kept in signal-declaration order (artifact-format
// §12) and only signals that appear as a producer or consumer get an entry. A
// step whose member has no recorded signature contributes nothing — the
// contract node check already rejected an unresolved slot occupant.
//
// The return is unwrapped through write_of_return (contracts.odin) BEFORE the
// signal lookup, so the producer scan sees the same write position the node
// check validated: a bare [signal] return routes directly, and a signal
// emitted inside an RNG-threaded tuple `(Rng, [signal])` routes from its tuple
// tail rather than being silently dropped (a tuple return whose signal went
// unscanned would evade effect closure entirely). snake's detect_eat/
// detect_death return bare [signal] lists and its replenish returns a
// (Rng, [Spawn]) command tuple (engine-consumed, no route), so the surface
// itself emits no tuple-wrapped signal — but the unwrap keeps the edge check
// honest if one ever does, matching the node check's write extraction. The
// param (consumer) side stays bare: an inbound signal is a [signal] param, and
// a tuple param has no surface form.
build_routes :: proc(typed: Typed_Ast, order: []Flat_Step) -> []Signal_Route {
	table := make(map[string]Route_Builder, context.temp_allocator)
	for step in order {
		term, found := env_term_name(typed.env, step.behavior)
		if !found || term.signature == nil {
			continue
		}
		for param in term.signature.params {
			if name, is_signal := signal_list_name(param); is_signal {
				route_record_consumer(&table, name, step)
			}
		}
		if name, is_signal := signal_list_name(write_of_return(term.signature.result)); is_signal {
			route_record_producer(&table, name, step)
		}
	}
	return routes_in_decl_order(typed.ast, table)
}

// Route_Builder accumulates a signal's producer and consumer endpoints as the
// flattened order is walked; routes_in_decl_order freezes each into a
// Signal_Route in signal-declaration order.
Route_Builder :: struct {
	producers: [dynamic]Signal_Endpoint,
	consumers: [dynamic]Signal_Endpoint,
}

route_record_producer :: proc(table: ^map[string]Route_Builder, signal: string, step: Flat_Step) {
	builder := route_builder_for(table, signal)
	append(&builder.producers, Signal_Endpoint{ordinal = step.ordinal, behavior = step.behavior})
	table[signal] = builder
}

route_record_consumer :: proc(table: ^map[string]Route_Builder, signal: string, step: Flat_Step) {
	builder := route_builder_for(table, signal)
	append(&builder.consumers, Signal_Endpoint{ordinal = step.ordinal, behavior = step.behavior})
	table[signal] = builder
}

// route_builder_for returns the signal's accumulator, seeding empty endpoint
// lists on first touch so a producer-only or consumer-only signal still gets an
// entry.
route_builder_for :: proc(table: ^map[string]Route_Builder, signal: string) -> Route_Builder {
	if builder, seen := table[signal]; seen {
		return builder
	}
	return Route_Builder {
		producers = make([dynamic]Signal_Endpoint, 0, 2, context.temp_allocator),
		consumers = make([dynamic]Signal_Endpoint, 0, 2, context.temp_allocator),
	}
}

// routes_in_decl_order freezes the accumulated routing table into a slice in
// signal-declaration order (artifact-format §12) — the table is keyed by name
// and never iterated for order; the source's signal declarations drive the
// sequence, so the output is deterministic and never hash-ordered. Only signals
// the table touched (emitted or consumed) get a route entry.
routes_in_decl_order :: proc(ast: Ast, table: map[string]Route_Builder) -> []Signal_Route {
	routes := make([dynamic]Signal_Route, 0, len(ast.signals), context.temp_allocator)
	for decl in ast.signals {
		builder, touched := table[decl.name]
		if !touched {
			continue
		}
		append(&routes, Signal_Route{
			signal    = decl.name,
			producers = builder.producers[:],
			consumers = builder.consumers[:],
		})
	}
	return routes[:]
}

// first_unclosed returns the first signal that fails effect closure (spec §04
// §4 / §07 §2) in signal-declaration order: a signal is closed iff it has at
// least one consumer downstream of at least one producer — a consumer ordinal
// strictly greater than a producer ordinal. A signal with no producer is
// vacuously closed (nothing was emitted to leave unconsumed); a produced signal
// with no downstream consumer is unclosed.
first_unclosed :: proc(routes: []Signal_Route) -> (signal: string, unclosed: bool) {
	for route in routes {
		if len(route.producers) == 0 {
			continue
		}
		if !has_downstream_consumer(route) {
			return route.signal, true
		}
	}
	return "", false
}

// has_downstream_consumer reports whether any consumer endpoint sits strictly
// after some producer endpoint in the flattened order — the §07 §2 forward-flow
// condition. A consumer at or before every producer (or no consumer at all) is
// not downstream, so the signal is unclosed.
has_downstream_consumer :: proc(route: Signal_Route) -> bool {
	for consumer in route.consumers {
		for producer in route.producers {
			if consumer.ordinal > producer.ordinal {
				return true
			}
		}
	}
	return false
}

// signal_list_name reads the declared signal type name off a signal list [S] —
// a ^List_Type whose element is a user ^Signal declaration (spec §06 §5). It is
// the routing-graph analogue of contracts.odin's is_signal_list, returning the
// element's name so the route is keyed by the signal type. A non-signal-list
// type (a thing write, a [Draw]/[Spawn] command list, a scalar) returns
// is_signal = false and contributes no routing edge.
signal_list_name :: proc(t: Type) -> (name: string, is_signal: bool) {
	list, is_list := t.(^List_Type)
	if !is_list {
		return "", false
	}
	user, is_user := list.elem.(^User_Type)
	if !is_user || user.kind != .Signal {
		return "", false
	}
	return user.name, true
}

// find_pipeline_decl looks up a declared pipeline by name — a stage member that
// names one expands in place during the depth-first flatten (spec §07 §3). A
// linear scan over the declared pipelines; pipeline names are UpperCamel and
// behavior names are snake_case (spec §02), so a member resolves to at most one.
find_pipeline_decl :: proc(ast: Ast, name: string) -> (pipeline: Pipeline_Node, found: bool) {
	for decl in ast.pipelines {
		if decl.name == name {
			return decl, true
		}
	}
	return Pipeline_Node{}, false
}
