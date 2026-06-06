// The §06 §6 behavior-contract node check: the per-behavior "is this
// behavior well-formed for its pipeline-stage slot?" stage. It runs after
// typecheck (it reads the resolved/typed signatures the typing pass records)
// and before artifact emission. A behavior takes on a contract ONLY by
// occupying a pipeline stage slot (spec §06 §6: slot-conferred, no
// `@behavior` annotation); the slot's stage name selects the closed,
// engine-defined contract, and the behavior's typed signature — its params
// are its reads, its return its writes (spec §06 §3) — is validated against
// that contract's allowed inputs and returns. A signature that violates its
// slot (a renderer emitting a signal, a render behavior taking an inbound
// signal, a startup reading an unspawned thing) is a compile error whose
// diagnostic names the BEHAVIOR.
//
// This is the NODE check only (spec §06 §6 separates the two layers). The
// cross-behavior effect-closure EDGE check ("does every emitted signal have a
// downstream consuming stage?", spec §04 §4 / §07 §2), which needs the
// depth-first flattened pipeline as its total order, is a distinct stage and
// is not implemented here.
package funpack

// Pipeline_Slot is the closed, engine-defined set of contract slots a
// pipeline stage confers (spec §06 §6). The stage name selects the slot:
// `startup:` ⇒ Startup, the terminal `render:`/`ui:`/`audio:` projection
// stages ⇒ Render/Ui/Audio, and every interior stage ⇒ Update. Ui and Audio
// are slots the surface declares no behavior for yet; this stage classifies
// them but defers their signature validation (no behavior occupies them on
// the gameplay surface).
Pipeline_Slot :: enum {
	Update,  // any interior stage between startup and the terminal projections
	Render,  // terminal `render:` — output-only, no signals in, only [Draw] out
	Startup, // `startup:` — engine resources only, returns [Spawn]
	Ui,      // terminal `ui:` — deferred (no surface behavior occupies it)
	Audio,   // terminal `audio:` — deferred (no surface behavior occupies it)
}

// Contract_Error is closed with one arm per way a behavior's signature can
// violate its slot's contract (spec §06 §6), plus the dead-code arm. Every
// arm is a behavior-level diagnostic: the reject names which behavior broke
// which contract clause, never the stage.
Contract_Error :: enum {
	None,
	Render_Emits,        // a render behavior returns a signal/command list (only [Draw] is allowed)
	Render_Takes_Signal, // a render behavior takes an inbound [Signal] param (render has no inbound edge)
	Render_Takes_Rng,    // a render behavior takes an Rng resource param (render is a deterministic projection, §06 render-slot)
	Render_No_Draw,      // a render behavior returns something other than a [Draw] list
	Startup_Reads_Thing, // a startup occupant reads an unspawned thing (blackboard or View) — only engine resources are in scope
	Startup_No_Spawn,    // a startup occupant returns something other than a [Spawn] list
	Update_Dead,         // an update behavior neither writes its blackboard nor emits a list — dead code
	Unknown_Battery,     // a bare-battery stage names a battery outside the engine set (spec §11 §3: the only battery is `solve`)
}

// Contract_Verdict pairs a contract failure with the behavior it indicts, so
// the diagnostic points at the behavior (spec §06 §6), not the slot. behavior
// is "" only when err is None.
Contract_Verdict :: struct {
	err:      Contract_Error,
	behavior: string,
}

// stage_contracts is the behavior-contract node check's seam. It walks the
// pipeline stages in order: every member a stage lists (a behavior, or the
// startup-program fn) takes on its stage's slot contract, and its typed
// signature is validated against it. A behavior in no pipeline stage takes on
// no contract (a behavior is constrained only by occupying a slot, spec §06
// §6), so it is never reached here. The first violation found is returned,
// naming the offending member. The member's typed `step`/fn signature comes
// from the resolved term table (resolve.odin), so a behavior and a top-level
// fn in a slot are validated through the one signature window — the §06 §3
// "params are reads, return is writes" handle.
stage_contracts :: proc(typed: Typed_Ast) -> Contract_Verdict {
	for pipeline in typed.ast.pipelines {
		seen := make(map[string]bool, context.temp_allocator)
		for stage in pipeline.stages {
			// A bare-battery stage (`physics: solve`) is an engine-closed stage,
			// not a behavior list: its battery name must resolve to a known engine
			// battery (spec §11 §3: the only one is `solve`), so an unknown battery
			// is a compile error. The parser left this unvalidated (Pipeline_Stage.
			// battery is a free string); validate it here, where the pipeline stages
			// are already walked.
			if stage.is_battery {
				if !is_engine_battery(stage.battery) {
					return Contract_Verdict{err = .Unknown_Battery, behavior = stage.battery}
				}
				continue
			}
			slot := slot_of_stage(stage.name)
			for member in stage.behaviors {
				// A member listed in two stages keeps its first slot; the golden
				// surface lists each once, and a cross-stage member is the
				// edge-check's concern, not this node check's.
				if seen[member] {
					continue
				}
				seen[member] = true
				if verdict := check_member(typed.env, slot, member); verdict.err != .None {
					return verdict
				}
			}
		}
	}
	return Contract_Verdict{err = .None}
}

// is_engine_battery reports whether a name is a known engine battery — the
// closed set of engine-closed stage members (spec §11 §3). `solve` is the only
// one: the §11 physics resolution battery, the single member of the `physics:`
// stage. Growing this set is a deliberate edit, mirroring the closed surface
// tables.
is_engine_battery :: proc(name: string) -> bool {
	switch name {
	case "solve":
		return true
	}
	return false
}

// check_member validates one pipeline-slot occupant against its slot
// contract. The member's typed signature is its recorded term signature (a
// behavior's `step` or a top-level fn); its blackboard target is the
// behavior's `on Thing` ("" for a fn, which owns no blackboard). A member
// with no recorded signature — a name not declared as a behavior or fn — is
// left for the edge-check/flattening stage to reject; this node check
// validates the members it can read a signature for.
check_member :: proc(env: Type_Env, slot: Pipeline_Slot, member: string) -> Contract_Verdict {
	term, found := env_term_name(env, member)
	if !found || term.signature == nil {
		return Contract_Verdict{err = .None}
	}
	if err := check_contract(slot, term.target, term.signature); err != .None {
		return Contract_Verdict{err = err, behavior = member}
	}
	return Contract_Verdict{err = .None}
}

// slot_of_stage maps a pipeline stage name to its conferred slot (spec §07
// §1): `startup:` is Startup, the terminal `render:`/`ui:`/`audio:` stages
// are their named projection slots, and every other (interior) stage name is
// Update. Stage names are documentary, but these reserved terminal/startup
// names select the contract.
slot_of_stage :: proc(name: string) -> Pipeline_Slot {
	switch name {
	case "startup":
		return .Startup
	case "render":
		return .Render
	case "ui":
		return .Ui
	case "audio":
		return .Audio
	}
	return .Update
}

// check_contract validates one behavior's typed signature against its slot's
// contract (spec §06 §6). The signature's params are the behavior's reads and
// its result is its writes; each slot fixes the allowed read kinds and the
// allowed return form. The gameplay surface exercises only Update/Render/
// Startup; Ui and Audio confer slots no surface behavior occupies, so their
// contract is deferred (None).
check_contract :: proc(slot: Pipeline_Slot, target: string, signature: ^Func_Type) -> Contract_Error {
	switch slot {
	case .Render:
		return check_render(signature)
	case .Startup:
		return check_startup(signature)
	case .Update:
		return check_update(target, signature)
	case .Ui, .Audio:
		return .None
	}
	return .None
}

// check_render enforces the Render contract (spec §06 §6): a render behavior
// reads blackboard/resources/View but takes NO inbound signal and NO Rng
// resource, and returns ONLY a [Draw] list — it cannot emit a signal, command,
// or write a blackboard. Render is the deterministic projection stage (§06
// render-slot): a frame's pixels are a pure function of the world, so threading
// the RNG into it would make rendering nondeterministic, which the slot
// forbids. An inbound signal param, an Rng param, a return that is not a [Draw]
// list, and a return that is an emit (a signal or non-Draw command list) are
// each a distinct behavior-level reject.
check_render :: proc(signature: ^Func_Type) -> Contract_Error {
	for param in signature.params {
		if is_signal_list(param) {
			return .Render_Takes_Signal
		}
		if is_engine(param, .Rng) {
			return .Render_Takes_Rng
		}
	}
	if is_command_list(signature.result, .Draw) {
		return .None
	}
	if is_signal_list(signature.result) || is_any_command_list(signature.result) {
		return .Render_Emits
	}
	return .Render_No_Draw
}

// check_startup enforces the Startup contract (spec §06 §6): a startup
// occupant reads engine resources only — no unspawned-thing read, neither a
// blackboard `self` nor a cross-thing View — and returns a [Spawn] list. A
// thing/View read is Startup_Reads_Thing; a return that is not a [Spawn] list
// is Startup_No_Spawn. An RNG-threaded startup returns the §04 §1 pair
// `(Rng, [Spawn])` — a tuple whose command position is the [Spawn] write and
// whose other position is the threaded Rng resource — so the return is unwrapped
// to its command-list position before the [Spawn] check (snake's `setup`).
check_startup :: proc(signature: ^Func_Type) -> Contract_Error {
	for param in signature.params {
		if is_thing(param) || is_view(param) {
			return .Startup_Reads_Thing
		}
	}
	if !is_command_list(write_of_return(signature.result), .Spawn) {
		return .Startup_No_Spawn
	}
	return .None
}

// check_update enforces the Update contract (spec §06 §6): an interior-stage
// behavior must write SOMETHING — its own blackboard, an emitted signal list,
// or an emitted command list — else it is dead code. The read side (any of
// blackboard/resources/signals/View) is unconstrained for Update, so only the
// write obligation is checked here. A return that writes the behavior's own
// thing blackboard, or any signal/command list, satisfies the contract. An
// RNG-threaded update returns the §04 §1 pair `(Rng, [command])` — a tuple whose
// command position is the write and whose other position is the threaded Rng —
// so the return is unwrapped to its write position before the obligation check
// (snake's `replenish`, an eat-stage behavior returning `(Rng, [Spawn])`).
check_update :: proc(target: string, signature: ^Func_Type) -> Contract_Error {
	result := write_of_return(signature.result)
	if writes_own_blackboard(result, target) {
		return .None
	}
	if is_signal_list(result) || is_any_command_list(result) {
		return .None
	}
	return .Update_Dead
}

// write_of_return unwraps a behavior's return type to its WRITE position (spec
// §04 §1): a plain return is its own write; an RNG-threaded return is the pair
// `(Rng, [command])`, whose write is the command/signal-list element while the
// other position threads the Rng resource back. It scans a tuple for the single
// command/signal-list position and returns it; a tuple with no such position (or
// a non-tuple return) passes the return through unchanged, so the contract check
// rejects a tuple that carries no write. Only the canonical two-element
// `(Rng, [command])` shape arises on the surface, but the scan generalizes.
write_of_return :: proc(result: Type) -> Type {
	tuple, is_tuple := result.(^Tuple_Type)
	if !is_tuple {
		return result
	}
	for element in tuple.elements {
		if is_signal_list(element) || is_any_command_list(element) {
			return element
		}
	}
	return result
}

// writes_own_blackboard reports whether a return type writes the behavior's
// own thing blackboard (spec §06 §4: a behavior writes only its own thing).
// The §06 §3 writes-as-return is the behavior's target thing handle; a nil
// (unresolved) target conservatively accepts any thing write, since the
// resolver could not ground the slot.
writes_own_blackboard :: proc(result: Type, target: string) -> bool {
	user, is_user := result.(^User_Type)
	if !is_user || user.kind != .Thing {
		return false
	}
	return target == "" || user.name == target
}

// is_thing reports a thing/singleton blackboard read — a ^User_Type of the
// Thing kind. A behavior's `self` parameter is this; a startup occupant reads
// none (spec §06 §6).
is_thing :: proc(t: Type) -> bool {
	user, is_user := t.(^User_Type)
	return is_user && user.kind == .Thing
}

// is_view reports a cross-thing read table View[T] (spec §08) — an engine
// type of the View kind. A startup occupant may not read one (spec §06 §6).
is_view :: proc(t: Type) -> bool {
	return is_engine(t, .View)
}

// is_signal_list reports an inbound/emitted signal list [S] — a ^List_Type
// whose element is a user ^Signal declaration (spec §06 §5). Render forbids
// it inbound and as a return; Update admits it as an emit.
is_signal_list :: proc(t: Type) -> bool {
	list, is_list := t.(^List_Type)
	if !is_list {
		return false
	}
	user, is_user := list.elem.(^User_Type)
	return is_user && user.kind == .Signal
}

// is_command_list reports an engine-command list of one kind — [Spawn] or
// [Draw] (spec §04 §1): a ^List_Type whose element is an ^Engine_Type of that
// kind. Render returns [Draw]; Startup returns [Spawn].
is_command_list :: proc(t: Type, kind: Engine_Kind) -> bool {
	list, is_list := t.(^List_Type)
	if !is_list {
		return false
	}
	return is_engine(list.elem, kind)
}

// is_any_command_list reports an engine-command list of any closed §04
// command kind ([Spawn], [Despawn], or [Draw]) — the "is this an emit?" test the
// Render and Update contracts share. The closed set mirrors surface_command and
// surface_struct_variant's emitting kinds; [Despawn] is the self-scoped despawn
// an Update behavior emits (snake's `despawn_eaten` returns [Despawn]).
is_any_command_list :: proc(t: Type) -> bool {
	return is_command_list(t, .Spawn) || is_command_list(t, .Despawn) || is_command_list(t, .Draw)
}
