@doc("Typed holes under governance (P8, spec/05-directives.md §2): a hole-first module built top-down. Callers typecheck against a hole's declared type, a fallback approximation evaluates in dev so the loop stays playable, and a release build refuses to ship either hole (spec/29-architecture-governance.md §4).")
import engine.input.{Bindings}

@doc("The drag coefficient, a typecheck-only hole: callers compose against Fixed by construction, a dev execution that reaches it fails closed, and release refuses to ship it.")
fn drag() -> Fixed @stub(Fixed)

@doc("Velocity after one tick of drag — a caller whose body typechecks against the drag hole's declared type, with no implementation behind that signature.")
fn damped(v: Fixed) -> Fixed {
  return v * drag()
}

@doc("Launch speed with a live approximation: the fallback evaluates in dev with the declaration's own parameters in scope, so the loop stays playable under the hole.")
fn launch_speed(boost: Fixed) -> Fixed @stub(Fixed, boost + 6.0)

@doc("No device map — the minimal deviceless bindings.")
fn bindings() -> Bindings {
  return Bindings.empty()
}

@doc("The empty schedule the entrypoint wires over a hole-first module.")
pipeline Drift {
}

@doc("The fallback approximation is live in dev: the holed launch_speed returns boost + 6.0, evaluated with the call's argument bound to boost.")
test "a fallback hole runs its approximation" {
  assert launch_speed(1.5) == 7.5
}
