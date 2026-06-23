@doc("Grid snake: a seeded-RNG game with food spawn/despawn, a game-over state machine, and signal-driven consumers. The golden reference for the things/behaviors model on a discrete grid.")
import engine.math.{Vec2, to_fixed}
import engine.world.{View, Spawn, Despawn}
import engine.input.{Input, Key, PlayerId, Bindings}
import engine.render.{Draw, Color}
import engine.rand.{Rng, pick}
import engine.grid.grid_cells
import engine.list.{prepend, init, contains, map, filter, concat, is_empty}

enum Dir { Up, Down, Left, Right }
enum GameState { Playing, Dead }
enum Move: Button { Up, Down, Left, Right }

@doc("An integer grid cell. A plain value, no identity.")
data Cell { x: Int, y: Int }

@doc("Playfield extent in cells.")
data Grid { size: Cell }

@doc("The fixed grid. The renderer scales a cell to 8 logical units.")
let GRID: Grid = Grid{ size: Cell{x: 20, y: 20} }

@doc("The snake: head, trailing body, heading, pending-growth flag, and round state. Singleton.")
@gtag("snake")
thing Snake {
  head:  Cell      = Cell{x: 10, y: 10}
  body:  [Cell]    = []
  dir:   Dir       = Dir::Right
  grow:  Bool      = false
  state: GameState = GameState::Playing
}

@doc("A food pellet occupying one grid cell.")
@gtag("food")
thing Food {
  cell: Cell
}

@doc("Emitted the tick the snake head lands on a food cell.")
@gtag("food", "event")
signal Eaten { cell: Cell }

@doc("Emitted the tick the snake hits a wall or itself.")
@gtag("state", "event")
signal Died {}

@doc("The cell one step from a cell in a direction.")
fn step_cell(c: Cell, d: Dir) -> Cell {
  return match d {
    Dir::Up => Cell{x: c.x, y: c.y - 1}
    Dir::Down => Cell{x: c.x, y: c.y + 1}
    Dir::Left => Cell{x: c.x - 1, y: c.y}
    Dir::Right => Cell{x: c.x + 1, y: c.y}
  }
}

@doc("Every cell the snake currently occupies, head first.")
fn cells(snake: Snake) -> [Cell] {
  return prepend(snake.head, snake.body)
}

@doc("The body after one step: old head joins the front, tail drops unless growing.")
fn body_after(snake: Snake) -> [Cell] {
  let extended = prepend(snake.head, snake.body)
  if snake.grow { return extended }
  return init(extended)
}

@doc("True when a cell lies outside the grid.")
fn off_grid(c: Cell) -> Bool {
  return c.x < 0 or c.y < 0 or c.x >= GRID.size.x or c.y >= GRID.size.y
}

@doc("The heading after applying this tick's input, refusing a 180-degree reversal.")
fn dir_from_input(input: Input, current: Dir) -> Dir {
  if input.pressed(PlayerId::P1, Move::Up) and current != Dir::Down { return Dir::Up }
  if input.pressed(PlayerId::P1, Move::Down) and current != Dir::Up { return Dir::Down }
  if input.pressed(PlayerId::P1, Move::Left) and current != Dir::Right { return Dir::Left }
  if input.pressed(PlayerId::P1, Move::Right) and current != Dir::Left { return Dir::Right }
  return current
}

@doc("The world-space rect for a grid cell.")
fn cell_rect(c: Cell, color: Color) -> Draw {
  return Draw::Rect{at: Vec2{x: to_fixed(c.x) * 8.0, y: to_fixed(c.y) * 8.0}, size: Vec2{x: 8.0, y: 8.0}, color: color}
}

@doc("Cells that are occupied and must not receive new food.")
fn occupied(snake: Snake, foods: View[Food]) -> [Cell] {
  return concat(cells(snake), map(foods, fn(f) { return f.cell }))
}

@doc("Every cell of the grid.")
fn all_cells() -> [Cell] {
  return grid_cells(GRID.size.x, GRID.size.y, fn(x, y) { return Cell{x: x, y: y} })
}

@doc("Turns the snake toward this tick's input.")
@gtag("input", "snake")
behavior turn on Snake {
  fn step(self: Snake, input: Input) -> Snake {
    return self with { dir: dir_from_input(input, self.dir) }
  }
}

@doc("Steps the snake forward one cell while the round is live.")
@gtag("snake")
behavior advance on Snake {
  fn step(self: Snake) -> Snake {
    if self.state == GameState::Dead { return self }
    return self with { head: step_cell(self.head, self.dir), body: body_after(self), grow: false }
  }
}

@doc("Emits an Eaten for each food the snake's head now shares a cell with.")
@gtag("food", "event")
behavior detect_eat on Snake {
  fn step(self: Snake, foods: View[Food]) -> [Eaten] {
    return map(filter(foods, fn(f) { return f.cell == self.head }), fn(f) { return Eaten{cell: f.cell} })
  }
}

@doc("Marks the snake to grow next step if anything was eaten this tick.")
@gtag("snake")
behavior grow on Snake {
  fn step(self: Snake, eaten: [Eaten]) -> Snake {
    if is_empty(eaten) { return self }
    return self with { grow: true }
  }
}

@doc("Spawns a replacement food on a random free cell after one is eaten.")
@gtag("food", "rng")
behavior replenish on Snake {
  fn step(self: Snake, eaten: [Eaten], foods: View[Food], rng: Rng) -> (Rng, [Spawn]) {
    if is_empty(eaten) { return (rng, []) }
    let occ = occupied(self, foods)
    let free = filter(all_cells(), fn(c) { return not contains(occ, c) })
    return match rng.pick(free) {
      (Option::Some(cell), next) => (next, [Spawn( Food{cell: cell} )])
      (Option::None, next) => (next, [])
    }
  }
}

@doc("Emits Died when the head leaves the grid or overlaps the body.")
@gtag("state", "event")
behavior detect_death on Snake {
  fn step(self: Snake) -> [Died] {
    if off_grid(self.head) or contains(self.body, self.head) { return [Died{}] }
    return []
  }
}

@doc("Ends the round on the first death signal.")
@gtag("state")
behavior apply_death on Snake {
  fn step(self: Snake, died: [Died]) -> Snake {
    if is_empty(died) { return self }
    return self with { state: GameState::Dead }
  }
}

@doc("Despawns this food if it was eaten this tick.")
@gtag("food")
behavior despawn_eaten on Food {
  fn step(self: Food, eaten: [Eaten]) -> [Despawn] {
    if contains(map(eaten, fn(e) { return e.cell }), self.cell) { return [Despawn()] }
    return []
  }
}

@doc("Draws the snake body green.")
@gtag("render")
behavior draw_snake on Snake {
  fn step(self: Snake) -> [Draw] {
    return map(cells(self), fn(c) { return cell_rect(c, Color::Green) })
  }
}

@doc("Shows GAME OVER once the round has ended.")
@gtag("render")
behavior draw_state on Snake {
  fn step(self: Snake) -> [Draw] {
    if self.state == GameState::Dead { return [Draw::Text{at: Vec2{x: 80.0, y: 80.0}, text: "GAME OVER", color: Color::White}] }
    return []
  }
}

@doc("Draws a food cell red.")
@gtag("render")
behavior draw_food on Food {
  fn step(self: Food) -> [Draw] {
    return [cell_rect(self.cell, Color::Red)]
  }
}

@doc("Binds the four move actions to keys and arrows. The only device-aware code.")
@gtag("input")
fn bindings() -> Bindings {
  return Bindings.empty()
    .button(PlayerId::P1, Move::Up,    [Key::W, Key::Up])
    .button(PlayerId::P1, Move::Down,  [Key::S, Key::Down])
    .button(PlayerId::P1, Move::Left,  [Key::A, Key::Left])
    .button(PlayerId::P1, Move::Right, [Key::D, Key::Right])
}

@doc("Spawns the snake and the first food on a random free cell.")
@gtag("startup")
fn setup(rng: Rng) -> (Rng, [Spawn]) {
  let snake = Snake{}
  let free = filter(all_cells(), fn(c) { return not contains(cells(snake), c) })
  return match rng.pick(free) {
    (Option::Some(cell), next) => (next, [Spawn( snake ), Spawn( Food{cell: cell} )])
    (Option::None, next) => (next, [Spawn( snake )])
  }
}

@doc("Snake at a fixed 8hz. Food placement is seeded, so every replay is bit-identical.")
@gtag("game")
pipeline Snake {
  startup: [setup]
  control: [turn, advance]
  eat:     [detect_eat, grow, despawn_eaten, replenish]
  death:   [detect_death, apply_death]
  render:  [draw_snake, draw_food, draw_state]
}

@doc("Stepping right increments x by one cell.")
test "step_cell moves right" {
  assert step_cell(Cell{x: 3, y: 3}, Dir::Right) == Cell{x: 4, y: 3}
}

@doc("Input opposite to the current heading is ignored (no self-reversal).")
test "dir_from_input refuses a 180" {
  assert dir_from_input(Input.empty().with_pressed(PlayerId::P1, Move::Down), Dir::Up) == Dir::Up
}

@doc("A head off the grid is a death.")
test "detect_death fires off the grid" {
  assert detect_death.step(Snake{head: Cell{x: -1, y: 5}, body: [], dir: Dir::Left, grow: false, state: GameState::Playing}) == [Died{}]
}

@doc("Eating sets the growth flag without yet changing the body.")
test "grow flags growth on an Eaten signal" {
  let s = grow.step(Snake{head: Cell{x: 5, y: 5}, body: [], dir: Dir::Right, grow: false, state: GameState::Playing}, [Eaten{cell: Cell{x: 5, y: 5}}])
  assert s.grow == true
}
