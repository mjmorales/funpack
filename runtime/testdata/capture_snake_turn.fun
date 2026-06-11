@doc("Captured by capture_test: turn on Snake#0 at tick 6 of a recorded session.")
test "captured turn tick 6 instance 0" {
  assert turn.step(Snake{head: Cell{x: 16, y: 10}, body: [], dir: Dir::Right, grow: false, state: GameState::Playing}, Input.empty().with_pressed(PlayerId::P1, Move::Down)) == Snake{head: Cell{x: 16, y: 10}, body: [], dir: Dir::Down, grow: false, state: GameState::Playing}
}
