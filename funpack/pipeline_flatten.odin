package funpack

Flat_Step :: struct {
	ordinal:    int,
	stage:      string,
	behavior:   string,
	is_battery: bool,
}

Signal_Endpoint :: struct {
	ordinal:  int,
	behavior: string,
}

Signal_Route :: struct {
	signal:    string,
	producers: []Signal_Endpoint,
	consumers: []Signal_Endpoint,
}

Flattened_Pipeline :: struct {
	order:  []Flat_Step,
	routes: []Signal_Route,
}

Flatten_Error :: enum {
	None,
	Unknown_Member,
	Recursive_Pipeline,
	Unclosed_Signal,
}

Flatten_Verdict :: struct {
	err:    Flatten_Error,
	signal: string,
	flat:   Flattened_Pipeline,
}

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

flatten_pipeline :: proc(typed: Typed_Ast, root: Pipeline_Node) -> (order: []Flat_Step, err: Flatten_Error) {
	steps := make([dynamic]Flat_Step, 0, 16, context.temp_allocator)
	visiting := make(map[string]bool, context.temp_allocator)
	flatten_err := expand_pipeline(typed, root, &steps, &visiting)
	return steps[:], flatten_err
}

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

route_builder_for :: proc(table: ^map[string]Route_Builder, signal: string) -> Route_Builder {
	if builder, seen := table[signal]; seen {
		return builder
	}
	return Route_Builder {
		producers = make([dynamic]Signal_Endpoint, 0, 2, context.temp_allocator),
		consumers = make([dynamic]Signal_Endpoint, 0, 2, context.temp_allocator),
	}
}

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

find_pipeline_decl :: proc(ast: Ast, name: string) -> (pipeline: Pipeline_Node, found: bool) {
	for decl in ast.pipelines {
		if decl.name == name {
			return decl, true
		}
	}
	return Pipeline_Node{}, false
}
