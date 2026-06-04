// Command warden is the impure governance binary: it owns the task DB,
// leases, swarm dispatch, and the clock, and consumes the Index Contract
// over a process boundary — never linking the compiler or the grammar
// (spec §29). warden's event-log fold must stay deterministic: no map
// iteration order or goroutine scheduling may ever reach state or output.
package main

func main() {}
