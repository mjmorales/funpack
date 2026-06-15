@doc("The runtime clock. Logical time only — there is no wall clock in sim code, so a replay re-folds identically.")

import engine.prelude.Fixed

@doc("The per-tick time resource: dt is the fixed step, t is accumulated logical time since startup. A read-only resource a behavior takes to observe time.")
data Time { dt: Fixed, t: Fixed }

@doc("A fixed simulation rate, written as a literal like 60hz in a pipeline's data block.")
extern type TickRate

@doc("A Time double for tests: the step dt, with elapsed t at zero.")
fn at(dt: Fixed) -> Time {
  return Time{ dt: dt, t: 0.0 }
}

@doc("A Time double for tests: an explicit step and elapsed time.")
fn tick(dt: Fixed, t: Fixed) -> Time {
  return Time{ dt: dt, t: t }
}
