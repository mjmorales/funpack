# 22 — Audio

Sound is an **effect**, and funpack effects are **data returned to the engine** (commands-as-data).
There is no `play_sound()` — a behavior returns audio *values* and the engine produces the sound, so
audio is pure, testable, and replay-deterministic like everything else. It splits into the two
regimes the rest of the engine uses:

| Regime | Surface | Trigger | Returned from |
|---|---|---|---|
| **One-shot SFX** | `[Sound]` command | edge (an event happened) | an Update behavior, alongside other commands |
| **Sustained audio** | `[Audio]` scene | level (this *should* be playing now) | the `audio:` stage, diffed by the engine |

## 1. One-shot — `[Sound]`

A fire-and-forget command emitted from the behavior that handles an event, exactly like a `Spawn`:

```funpack
fn click_sfx(msg: AppMsg) -> [Sound] {
  return match msg {
    AppMsg::Hud(HudMsg::Coin) => [Sound.sfx(sound("coin")).bus(Bus::Ui)]
    _                         => [Sound.sfx(sound("click")).bus(Bus::Ui)]
  }
}
```

`Sound` is `data { clip: SoundHandle, gain: Fixed, pitch: Fixed, bus: Bus, at: Option[Vec3] }`, built
with `Sound.sfx(clip)` / `Sound.sfx_at(clip, pos)` and the `.gain` / `.pitch` / `.bus` / `.at`
builders. No key, no lifetime — the engine plays it once and forgets it.

## 2. Sustained — the `audio:` stage

Music, ambience, a speed-modulated loop — sounds with a *lifetime* — are a **projection of state**,
like a UI screen. An `audio:` behavior returns the set that **should be playing now**, each under a
stable **key**; the engine diffs that set against what is currently playing and reconciles:

- a key that **appears** → start it;
- a key that **disappears** → stop it (with the bus fade);
- the **same key**, new gain/pitch → **bend** the live voice;
- the **same key**, new clip → **crossfade**.

```funpack
behavior music on App {
  fn step(self: App) -> [Audio] {
    let clip = match self.screen { Screen::Hud => "bgm_play", _ => "bgm_menu" }
    return [Audio.track("music", sound(clip)).gain(to_fixed(self.volume) / 100.0).bus(Bus::Music)]
  }
}
```

One stable key (`"music"`) with a clip that follows the active screen ⇒ the engine crossfades on
navigation, with no start/stop bookkeeping. The settings volume drives the gain because the desired
gain **is part of the projection** — there is no global mixer to mutate. `Audio` is `data { key:
String, clip, gain, pitch, bus, at }`, built with `Audio.track(key, clip)` + the same builders. (A
loop present while moving and absent at rest stops automatically — `examples/krognid` `locomotion`.)

The keyed-diff is the audio twin of a UI list `key=` ([`21`](21-ui.md)): stable identity is what lets
the engine tell "bend this voice" from "replace it."

## 3. The `audio:` stage contract

`audio:` is an engine-closed stage kind alongside Render/Ui: a pure projection `fn(self) -> [Audio]`
with Render's input rules (blackboard / resources / `View`; no signal lists, no `Rng`, no writes). It
is **output-only** — unlike Ui it has no inbound edge, because sound emits nothing back. Stage order
among `render:` / `ui:` / `audio:` is irrelevant; they are independent projections.

## 4. Buses & determinism

A `Bus` (`Master / Music / Sfx / Ui / Voice`) groups sounds for volume control; a settings slider
drives a bus by feeding its value into the gain of the sounds on it — no mutable global mixer.
**Triggers are deterministic data** (a replay re-emits the identical sequence), and **output never
feeds back**: mixing, latency, and device output are engine-side and not sim-observable (like `Draw`).
`gain`/`pitch` are `Fixed` (they often derive from sim, e.g. pitch from speed), but the sim never
reads anything *back* from audio. Positional audio attenuates relative to the listener, which defaults
to the active `Draw3::Camera`; a `Sound`/`Audio` carries an optional world `at`.

Per-bus gain is folded into the projection — there is no global mixer to mutate. The listener
defaults to the active `Draw3::Camera`.

**There is no DSP-effect-chain authoring graph.** The entire authored audio surface is the one-shot
`[Sound]` command (§1) plus the keyed, diffed `audio:` scene (§2), each with **per-bus gain** the
projection supplies. Effects such as reverb and filtering are **engine bus-level settings**, not an
authored node graph — there is no `effect`/`chain`/`send` vocabulary, no per-voice DSP wiring, and no
sim-observable effect state. Like mixing and device output, the effect stage is engine-side and never
feeds back into the sim, so the authored projection stays a pure description of *what should sound*,
not *how it is processed*.
