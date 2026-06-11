@doc("Captured by capture_test: detect_eat on Snake#0 at tick 9 of a recorded session.")
test "captured detect_eat tick 9 instance 0" {
  assert detect_eat.step(Snake{head: Cell{x: 16, y: 14}, body: [], dir: Dir::Down, grow: false, state: GameState::Playing}, View.of([Food{cell: Cell{x: 16, y: 14}}])) == [Eaten{cell: Cell{x: 16, y: 14}}]
}
