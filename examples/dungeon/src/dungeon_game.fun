@doc("The dungeon's behaviors and pipeline: grid movement gated by the baked tile layer, a dig that rewrites rubble with SetTile, slimes that crawl the open neighbors toward the hero, and a chest looted by standing on its cell. Every terrain query goes through the level seam's TilemapHandle; the decisions are decomposed into pure functions and tested exactly.")
import engine.prelude.{Option, Fixed, String, or_else}
import engine.core.Time
import engine.input.{Input, Key, PlayerId, Bindings}
import engine.math.Vec2
import engine.grid.{Cell, neighbors, in_bounds}
import engine.tilemap.{TilemapHandle, SetTile, tile_at, solid_at, cell_of, center_of}
import engine.render.{Draw, Color, Flip}
import engine.world.{Spawn, View}
import engine.list.{fold, filter, is_empty}
import dungeon_world.{Player, Slime, Chest, Dir, Looted}
import dungeon.{dungeon_spawns, terrain}
import assets

@doc("The terrain grid's extent in cells — the 16x9 picture in dungeon.flvl.")
let MAP_SIZE: Cell = Cell{x: 16, y: 9}

@doc("Seconds a slime rests between one-cell steps.")
let SLIME_REST: Fixed = 0.4

@doc("Sprite extent: one tile, 16 logical units square.")
let TILE: Vec2 = Vec2{x: 16.0, y: 16.0}

@doc("The semantic input actions: four steps and a dig. Device-agnostic; keys bind in `bindings`.")
enum Act: Button { Up, Down, Left, Right, Dig }

@doc("The cell one step from a cell in a heading.")
fn step_cell(c: Cell, d: Dir) -> Cell {
  return match d {
    Dir::Up => Cell{x: c.x, y: c.y - 1}
    Dir::Down => Cell{x: c.x, y: c.y + 1}
    Dir::Left => Cell{x: c.x - 1, y: c.y}
    Dir::Right => Cell{x: c.x + 1, y: c.y}
  }
}

@doc("The heading this tick's input asks for, if any. Edge-triggered, so the hero steps one cell per press.")
fn dir_from_input(input: Input) -> Option[Dir] {
  if input.pressed(PlayerId::P1, Act::Up) { return Option::Some(Dir::Up) }
  if input.pressed(PlayerId::P1, Act::Down) { return Option::Some(Dir::Down) }
  if input.pressed(PlayerId::P1, Act::Left) { return Option::Some(Dir::Left) }
  if input.pressed(PlayerId::P1, Act::Right) { return Option::Some(Dir::Right) }
  return Option::None
}

@doc("Whether a queried cell can be entered: it must hold a tile (the void is not floor) and the tile must not be solid. The movement gate, as a pure decision over query results.")
fn enterable(tile: Option[String], solid: Bool) -> Bool {
  return match tile {
    Option::Some(_) => not solid
    Option::None => false
  }
}

@doc("The center of a target cell when the movement gate passes, or the stay position when it refuses. Thin glue over the contracted layer queries; the decision is `enterable`.")
fn enter(map: TilemapHandle, target: Cell, stay: Vec2) -> Vec2 {
  if enterable(map.tile_at(target), map.solid_at(target)) { return map.center_of(target) }
  return stay
}

@doc("One attempted step in a heading: the hero enters the target cell when the gate passes and turns to face the heading either way, so the next dig aims where the player faces.")
fn walk(self: Player, d: Dir) -> Player {
  let target = step_cell(terrain.cell_of(self.pos), d)
  return self with { pos: enter(terrain, target, self.pos), dir: d }
}

@doc("Steps the hero one cell per press, gated by the baked layer through the seam's `terrain` TilemapHandle constant.")
@gtag("actor")
behavior step_hero on Player {
  fn step(self: Player, input: Input) -> Player {
    return match dir_from_input(input) {
      Option::Some(d) => walk(self, d)
      Option::None => self
    }
  }
}

@doc("Whether a queried tile yields to the shovel — only rubble does.")
fn diggable(tile: Option[String]) -> Bool {
  return tile == Option::Some("rubble")
}

@doc("Digs the cell the hero faces: rubble becomes floor via a SetTile command, applied deterministically at tick end — render, collision, and the nav graph update from the same data.")
@gtag("actor", "terrain")
behavior dig on Player {
  fn step(self: Player, input: Input) -> [SetTile] {
    if not input.pressed(PlayerId::P1, Act::Dig) { return [] }
    let target = step_cell(terrain.cell_of(self.pos), self.dir)
    if diggable(terrain.tile_at(target)) { return [SetTile{map: terrain, cell: target, tile: "floor"}] }
    return []
  }
}

@doc("Distance between two scalars on the integer grid.")
fn dist1(a: Int, b: Int) -> Int {
  if a < b { return b - a }
  return a - b
}

@doc("Manhattan distance between two cells.")
fn manhattan(a: Cell, b: Cell) -> Int {
  return dist1(a.x, b.x) + dist1(a.y, b.y)
}

@doc("The open cell that strictly closes distance to the goal, or `from` when none does. Pure greedy pursuit over plain cells.")
fn toward(from: Cell, goal: Cell, open: [Cell]) -> Cell {
  return fold(open, from, fn(best, c) { return if manhattan(c, goal) < manhattan(best, goal) { c } else { best } })
}

@doc("The position of some player, or the fallback when none exist (a slime with no target rests in place).")
fn hero_pos(players: View[Player], fallback: Vec2) -> Vec2 {
  return or_else(fold(players, Option::None, fn(acc, p) { return Option::Some(p.pos) }), fallback)
}

@doc("Crawls the slime one open cell toward the hero, then rests. The open set is the in-bounds neighbors that pass the same `enterable` gate the hero obeys, so slimes never cross walls, rubble, or the chasm — but a dug passage opens to them too.")
@gtag("ai")
behavior ooze on Slime {
  fn step(self: Slime, time: Time, players: View[Player]) -> Slime {
    if self.rest > 0.0 { return self with { rest: self.rest - time.dt } }
    let here = terrain.cell_of(self.pos)
    let open = filter(neighbors(here), fn(c) { return in_bounds(c, MAP_SIZE) and enterable(terrain.tile_at(c), terrain.solid_at(c)) })
    let goal = terrain.cell_of(hero_pos(players, self.pos))
    return self with { pos: terrain.center_of(toward(here, goal, open)), rest: SLIME_REST }
  }
}

@doc("Opens the chest the tick a player stands on its cell, emitting the bounty exactly once.")
@gtag("loot")
behavior open_chest on Chest {
  fn step(self: Chest, players: View[Player]) -> (Chest, [Looted]) {
    if self.opened { return (self, []) }
    let here = terrain.cell_of(self.pos)
    let visitors = filter(players, fn(p) { return terrain.cell_of(p.pos) == here })
    if is_empty(visitors) { return (self, []) }
    return (self with { opened: true }, [Looted{gems: self.gems}])
  }
}

@doc("Folds this tick's loot into the hero's gem count.")
@gtag("actor", "loot")
behavior collect on Player {
  fn step(self: Player, looted: [Looted]) -> Player {
    return fold(looted, self, fn(p, l) { return p with { gems: p.gems + l.gems } })
  }
}

@doc("The atlas cell a chest shows for its state.")
fn chest_cell(opened: Bool) -> String {
  if opened { return "chest_open" }
  return "chest_closed"
}

@doc("Draws the hero above the terrain. The tile layer itself is engine-rendered, batched — no behavior emits per-tile sprites.")
@gtag("render")
behavior draw_hero on Player {
  fn step(self: Player) -> [Draw] {
    return [Draw::Sprite{atlas: assets.dungeon_atlas, cell: "hero", at: self.pos, size: TILE, tint: Color::White, flip: Flip::None, layer: 5}]
  }
}

@doc("Draws a slime.")
@gtag("render")
behavior draw_slime on Slime {
  fn step(self: Slime) -> [Draw] {
    return [Draw::Sprite{atlas: assets.dungeon_atlas, cell: "slime", at: self.pos, size: TILE, tint: Color::White, flip: Flip::None, layer: 4}]
  }
}

@doc("Draws the chest, closed or sprung.")
@gtag("render")
behavior draw_chest on Chest {
  fn step(self: Chest) -> [Draw] {
    return [Draw::Sprite{atlas: assets.dungeon_atlas, cell: chest_cell(self.opened), at: self.pos, size: TILE, tint: Color::White, flip: Flip::None, layer: 3}]
  }
}

@doc("Binds the four steps and the dig. The only device-aware code.")
@gtag("input")
fn bindings() -> Bindings {
  return Bindings.empty().button(PlayerId::P1, Act::Up, [Key::W, Key::Up]).button(PlayerId::P1, Act::Down, [Key::S, Key::Down]).button(PlayerId::P1, Act::Left, [Key::A, Key::Left]).button(PlayerId::P1, Act::Right, [Key::D, Key::Right]).button(PlayerId::P1, Act::Dig, [Key::Space])
}

@doc("Loads the Dungeon level at startup — the grid's markers and the placed chest arrive as one deterministic spawn list.")
@gtag("startup")
fn setup() -> [Spawn] {
  return dungeon_spawns()
}

@doc("A dungeon crawl driven by one ASCII tilemap: the grid paints the terrain and scatters the slimes, the legend's named marker is the hero, and the rubble wall falls to a SetTile.")
@gtag("game")
pipeline DungeonCrawl {
  startup: [setup]
  control: [step_hero, dig]
  ai:      [ooze]
  loot:    [open_chest, collect]
  render:  [draw_hero, draw_slime, draw_chest]
}

@doc("Cell arithmetic steps one cell in the heading.")
test "step_cell steps one cell" {
  assert step_cell(Cell{x: 5, y: 3}, Dir::Down) == Cell{x: 5, y: 4}
  assert step_cell(Cell{x: 5, y: 3}, Dir::Left) == Cell{x: 4, y: 3}
}

@doc("The movement gate: floor passes, a solid tile refuses, and the void (no tile) is never enterable.")
test "enterable demands a tile and no solid" {
  assert enterable(Option::Some("floor"), false) == true
  assert enterable(Option::Some("wall"), true) == false
  assert enterable(Option::None, false) == false
}

@doc("The whole movement decision over a seeded fixture layer (18 §4): floor enters at its center, the wall refuses, and the void refuses — one handle-level test where the gate once had to decompose into pure functions.")
test "enter walks a fixture layer" {
  let map = TilemapHandle.of(16, [(Cell{x: 0, y: 0}, "wall", true), (Cell{x: 1, y: 0}, "floor", false)])
  let stay = Vec2{x: 100.0, y: 100.0}
  assert enter(map, Cell{x: 1, y: 0}, stay) == map.center_of(Cell{x: 1, y: 0})
  assert enter(map, Cell{x: 0, y: 0}, stay) == stay
  assert enter(map, Cell{x: 5, y: 5}, stay) == stay
}

@doc("Only rubble yields to the shovel — not walls, not the void.")
test "diggable accepts rubble alone" {
  assert diggable(Option::Some("rubble")) == true
  assert diggable(Option::Some("wall")) == false
  assert diggable(Option::None) == false
}

@doc("The dig decision read through the handle (18 §4): the fixture seeds a rubble segment beside floor, and the gate answers over the layer queries directly — the composition the dig behavior folds every tick.")
test "the dig gate reads the layer through the handle" {
  let map = TilemapHandle.of(16, [(Cell{x: 2, y: 1}, "rubble", true), (Cell{x: 1, y: 1}, "floor", false)])
  assert diggable(map.tile_at(Cell{x: 2, y: 1})) == true
  assert diggable(map.tile_at(Cell{x: 1, y: 1})) == false
  assert diggable(map.tile_at(Cell{x: 9, y: 9})) == false
}

@doc("A pressed step action reads as a heading; idle input reads as none.")
test "dir_from_input maps presses to headings" {
  assert dir_from_input(Input.empty().with_pressed(PlayerId::P1, Act::Left)) == Option::Some(Dir::Left)
  assert dir_from_input(Input.empty()) == Option::None
}

@doc("Greedy pursuit picks the open neighbor that closes distance, and stays put when nothing is open.")
test "toward closes distance over open cells only" {
  let open = [Cell{x: 4, y: 3}, Cell{x: 6, y: 3}]
  assert toward(Cell{x: 5, y: 3}, Cell{x: 8, y: 3}, open) == Cell{x: 6, y: 3}
  assert toward(Cell{x: 5, y: 3}, Cell{x: 8, y: 3}, []) == Cell{x: 5, y: 3}
}

@doc("A view with a player yields that player's position; an empty view yields the fallback.")
test "hero_pos reads the view, falls back when empty" {
  let players = View.of([Player{pos: Vec2{x: 40.0, y: 40.0}, dir: Dir::Down, gems: 0}])
  assert hero_pos(players, Vec2{x: 0.0, y: 0.0}) == Vec2{x: 40.0, y: 40.0}
  assert hero_pos(View.of([]), Vec2{x: 8.0, y: 24.0}) == Vec2{x: 8.0, y: 24.0}
}

@doc("Loot folds into the gem count; an empty tick leaves it unchanged.")
test "collect folds loot into gems" {
  let hero = Player{pos: Vec2{x: 24.0, y: 40.0}, dir: Dir::Down, gems: 1}
  assert collect.step(hero, [Looted{gems: 5}]).gems == 6
  assert collect.step(hero, []).gems == 1
}

@doc("The chest sprite follows its state.")
test "chest_cell names the state's sprite" {
  assert chest_cell(false) == "chest_closed"
  assert chest_cell(true) == "chest_open"
}
