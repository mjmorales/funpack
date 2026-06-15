@doc("Two-player Pong: defines the paddles, ball, scoreboard, and goal signal, the pure fixed-point helpers and behaviors that move, bounce, and score them, the input bindings and setup, and the pipeline that schedules them.")
import engine.math.{Fixed, Vec2, abs, clamp}
import engine.world.{View, Spawn}
import engine.input.{Input, Key, PlayerId, Bindings, keys_axis, stick_y, Stick}
import engine.render.{Draw, Color}
import engine.core.Time
import engine.list.{fold, first}

@doc("Which end of the table a paddle defends.")
enum Side { Left, Right }

@doc("A paddle's vertical steer axis: negative is up, positive is down.")
enum Steer: Axis { Move }

@doc("Playfield extent in fixed logical units.")
data Board { w: Fixed, h: Fixed }

@doc("The fixed playfield. The renderer scales it to the window.")
let BOARD: Board = Board{ w: 160.0, h: 120.0 }

@doc("A player's paddle: its fixed column, its vertical position, and its speed.")
@gtag("paddle")
thing Paddle {
  player: PlayerId
  side:   Side
  x:      Fixed
  y:      Fixed
  speed:  Fixed
}

@doc("The ball: position and per-tick velocity, in fixed logical units.")
@gtag("ball")
thing Ball {
  pos: Vec2
  vel: Vec2
}

@doc("The running score. A singleton thing, spawned once.")
@gtag("score")
thing Scoreboard {
  left:  Int = 0
  right: Int = 0
}

@doc("Emitted the tick the ball crosses an end. Consumed by the score and the serve.")
@gtag("score")
signal Goal { side: Side }

@doc("Advances a point by a velocity over one fixed step.")
fn advance(at: Vec2, vel: Vec2, dt: Fixed) -> Vec2 {
  return at + vel * dt
}

@doc("Reflects a vector across the horizontal axis.")
fn reflect_y(v: Vec2) -> Vec2 {
  return Vec2{x: v.x, y: -v.y}
}

@doc("Reflects a vector across the vertical axis.")
fn reflect_x(v: Vec2) -> Vec2 {
  return Vec2{x: -v.x, y: v.y}
}

@doc("True when the drawn ball and paddle rects touch: per axis the center distance is within the summed half-extents of the 3x3 ball and 4x16 paddle, so the collision box is exactly the visuals.")
fn overlaps(ball: Vec2, paddle: Vec2) -> Bool {
  return abs(ball.x - paddle.x) <= 3.5 and abs(ball.y - paddle.y) <= 9.5
}

@doc("Which player scored when the ball is at a given x, if any.")
fn goal_side(at: Vec2) -> Option[Side] {
  if at.x < 0.0 { return Option::Some(Side::Right) }
  if at.x > BOARD.w { return Option::Some(Side::Left) }
  return Option::None
}

@doc("The serve velocity awarded after a side scores.")
fn serve_velocity(side: Side) -> Vec2 {
  return match side {
    Side::Left => Vec2{x: 70.0, y: 40.0}
    Side::Right => Vec2{x: -70.0, y: 40.0}
  }
}

@doc("Adds one goal to a score. A pure fold step.")
fn add_goal(score: Scoreboard, goal: Goal) -> Scoreboard {
  return match goal.side {
    Side::Left => score with { left: score.left + 1 }
    Side::Right => score with { right: score.right + 1 }
  }
}

@doc("Moves a paddle by its bound vertical Move axis, clamped inside the board.")
@gtag("paddle")
behavior paddle_move on Paddle {
  fn step(self: Paddle, input: Input, time: Time) -> Paddle {
    let dir = input.value(self.player, Steer::Move)
    return self with { y: clamp(self.y + dir * self.speed * time.dt, 0.0, BOARD.h) }
  }
}

@doc("Advances the ball along its velocity.")
@gtag("ball")
behavior ball_move on Ball {
  fn step(self: Ball, time: Time) -> Ball {
    return self with { pos: advance(self.pos, self.vel, time.dt) }
  }
}

@doc("Bounces the ball off the top and bottom walls.")
@gtag("ball")
behavior wall_bounce on Ball {
  fn step(self: Ball) -> Ball {
    if self.pos.y <= 0.0 or self.pos.y >= BOARD.h {
      return self with { vel: reflect_y(self.vel) }
    }
    return self
  }
}

@doc("Reverses the ball's horizontal velocity when it overlaps any paddle.")
@gtag("ball", "paddle")
behavior paddle_bounce on Ball {
  fn step(self: Ball, paddles: View[Paddle]) -> Ball {
    return match first(paddles, fn(pad) { return overlaps(self.pos, Vec2{x: pad.x, y: pad.y}) }) {
      Option::Some(_) => self with { vel: reflect_x(self.vel) }
      Option::None => self
    }
  }
}

@doc("Emits a Goal the tick the ball crosses an end.")
@gtag("ball", "score")
behavior score on Ball {
  fn step(self: Ball) -> [Goal] {
    return match goal_side(self.pos) {
      Option::Some(side) => [Goal{side: side}]
      Option::None => []
    }
  }
}

@doc("Folds this tick's goals into the running score.")
@gtag("score")
behavior tally on Scoreboard {
  fn step(self: Scoreboard, goals: [Goal]) -> Scoreboard {
    return fold(goals, self, add_goal)
  }
}

@doc("Resets the ball to center after a goal, serving toward the conceding side.")
@gtag("ball", "score")
behavior serve on Ball {
  fn step(self: Ball, goals: [Goal]) -> Ball {
    return match first(goals) {
      Option::Some(goal) => Ball{ pos: Vec2{x: BOARD.w * 0.5, y: BOARD.h * 0.5}, vel: serve_velocity(goal.side) }
      Option::None => self
    }
  }
}

@doc("Draws a paddle as a tall white rect.")
@gtag("render")
behavior draw_paddle on Paddle {
  fn step(self: Paddle) -> [Draw] {
    return [Draw::Rect{at: Vec2{x: self.x, y: self.y}, size: Vec2{x: 4.0, y: 16.0}, color: Color::White}]
  }
}

@doc("Draws the ball as a small white rect.")
@gtag("render")
behavior draw_ball on Ball {
  fn step(self: Ball) -> [Draw] {
    return [Draw::Rect{at: self.pos, size: Vec2{x: 3.0, y: 3.0}, color: Color::White}]
  }
}

@doc("Draws the score readout.")
@gtag("render")
behavior draw_score on Scoreboard {
  fn step(self: Scoreboard) -> [Draw] {
    return [Draw::Text{at: Vec2{x: 80.0, y: 8.0}, text: "{self.left}   {self.right}", color: Color::White}]
  }
}

@doc("Maps each player's vertical paddle axis to keys and a stick. The only device-aware code.")
@gtag("input")
fn bindings() -> Bindings {
  return Bindings.empty()
    .axis(PlayerId::P1, Steer::Move, keys_axis(Key::W, Key::S))
    .axis(PlayerId::P1, Steer::Move, stick_y(Stick::Left))
    .axis(PlayerId::P2, Steer::Move, keys_axis(Key::Up, Key::Down))
    .axis(PlayerId::P2, Steer::Move, stick_y(Stick::Left))
}

@doc("Spawns both paddles, the ball, and the scoreboard in fixed logical units.")
@gtag("startup")
fn setup() -> [Spawn] {
  return [
    Spawn( Paddle{player: PlayerId::P1, side: Side::Left,  x: 8.0,   y: 60.0, speed: 90.0} )
    Spawn( Paddle{player: PlayerId::P2, side: Side::Right, x: 152.0, y: 60.0, speed: 90.0} )
    Spawn( Ball{pos: Vec2{x: 80.0, y: 60.0}, vel: Vec2{x: 70.0, y: 40.0}} )
    Spawn( Scoreboard{left: 0, right: 0} )
  ]
}

@doc("Two-player Pong at a fixed 60hz. Pure behaviors, so every replay is bit-identical.")
@gtag("game")
pipeline Pong {
  startup:   [setup]
  control:   [paddle_move, ball_move]
  collision: [wall_bounce, paddle_bounce]
  scoring:   [score, tally, serve]
  render:    [draw_paddle, draw_ball, draw_score]
}

@doc("A point advances by velocity*dt each tick, exactly, in fixed-point.")
test "advance moves a point by velocity over dt" {
  assert advance(Vec2{x: 0.0, y: 0.0}, Vec2{x: 2.0, y: 4.0}, 0.5) == Vec2{x: 1.0, y: 2.0}
}

@doc("A ball past the right edge is a goal for the left player.")
test "score emits a left goal past the right edge" {
  assert score.step(Ball{pos: Vec2{x: 161.0, y: 60.0}, vel: Vec2{x: 70.0, y: 40.0}}) == [Goal{side: Side::Left}]
}

@doc("The score behavior folds goals into the scoreboard deterministically.")
test "tally folds goals into the score" {
  assert tally.step(Scoreboard{left: 0, right: 0}, [Goal{side: Side::Left}, Goal{side: Side::Left}]) == Scoreboard{left: 2, right: 0}
}

@doc("Rendering is a pure function of a thing's blackboard, so the draw list is assertable.")
test "draw_ball emits one white rect at the ball position" {
  assert draw_ball.step(Ball{pos: Vec2{x: 10.0, y: 20.0}, vel: Vec2{x: 0.0, y: 0.0}}) == [Draw::Rect{at: Vec2{x: 10.0, y: 20.0}, size: Vec2{x: 3.0, y: 3.0}, color: Color::White}]
}

@doc("The collision box equals the drawn geometry: per axis the contact rail is the summed half-extents (3.5, 9.5), and one half world unit past the rail is a miss.")
test "overlaps fires exactly at the drawn-rect contact rail" {
  assert overlaps(Vec2{x: 11.5, y: 60.0}, Vec2{x: 8.0, y: 60.0}) == true
  assert overlaps(Vec2{x: 12.0, y: 60.0}, Vec2{x: 8.0, y: 60.0}) == false
  assert overlaps(Vec2{x: 8.0, y: 69.5}, Vec2{x: 8.0, y: 60.0}) == true
  assert overlaps(Vec2{x: 8.0, y: 70.0}, Vec2{x: 8.0, y: 60.0}) == false
}
