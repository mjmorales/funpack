@doc("Captured by capture_test: paddle_bounce on Ball#0 at tick 3 of a recorded session.")
test "captured paddle_bounce tick 3 instance 0" {
  assert paddle_bounce.step(Ball{pos: Vec2{x: 84.666666649281978607177734375, y: 62.6666666567325592041015625}, vel: Vec2{x: 70.0, y: 40.0}}, View.of([Paddle{player: PlayerId::P1, side: Side::Left, x: 8.0, y: 60.0, speed: 90.0}, Paddle{player: PlayerId::P2, side: Side::Right, x: 152.0, y: 65.999999977648258209228515625, speed: 90.0}])) == Ball{pos: Vec2{x: 84.666666649281978607177734375, y: 62.6666666567325592041015625}, vel: Vec2{x: 70.0, y: 40.0}}
}
