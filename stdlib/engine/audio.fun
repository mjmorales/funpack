@doc("Audio as data, in two regimes. A one-shot Sound is a fire-and-forget command an Update behavior returns (like Spawn/Draw) — edge-triggered. A sustained Audio is a keyed entry an `audio:` stage returns each tick; the engine diffs the set by key and starts/stops/crossfades to match — level-triggered, the same reconciliation as a UI View. Both are plain data: there is no playback function and no `extern` here — the effect happens because the engine consumes the returned lists. Triggers are deterministic data computed from sim state; the actual mixing/output is engine-side and never flows back into the sim (like Draw).")

import engine.prelude.{Fixed, String, Option}
import engine.math.Vec3
import engine.assets.SoundHandle

@doc("A mixer group, for grouped volume control (a settings slider drives a bus). Positional sounds attenuate relative to the listener, which defaults to the active Draw3 camera.")
enum Bus { Master, Music, Sfx, Ui, Voice }

@doc("A one-shot sound: played once when returned as a command, then forgotten. No key, no lifetime — fire and forget.")
data Sound { clip: SoundHandle, gain: Fixed, pitch: Fixed, bus: Bus, at: Option[Vec3] }

@doc("A sustained, keyed sound the engine keeps alive while it is present in the audio scene; absent next tick ⇒ stopped. Same key across ticks ⇒ the same voice (change gain/pitch to fade or bend); same key, new clip ⇒ crossfade.")
data Audio { key: String, clip: SoundHandle, gain: Fixed, pitch: Fixed, bus: Bus, at: Option[Vec3] }

@doc("A one-shot non-positional sound at unity gain/pitch on the Sfx bus. Invoked Sound.sfx(clip).")
fn sfx(clip: SoundHandle) -> Sound {
  return Sound{ clip: clip, gain: 1.0, pitch: 1.0, bus: Bus::Sfx, at: Option::None }
}

@doc("A one-shot sound placed in the world, attenuated relative to the listener. Invoked Sound.sfx_at(clip, pos).")
fn sfx_at(clip: SoundHandle, pos: Vec3) -> Sound {
  return Sound{ clip: clip, gain: 1.0, pitch: 1.0, bus: Bus::Sfx, at: Option::Some(pos) }
}

@doc("A keyed sustained sound at unity gain/pitch on the Music bus. Invoked Audio.track(key, clip).")
fn track(key: String, clip: SoundHandle) -> Audio {
  return Audio{ key: key, clip: clip, gain: 1.0, pitch: 1.0, bus: Bus::Music, at: Option::None }
}

@doc("Sets a one-shot's gain.")
fn gain(self: Sound, g: Fixed) -> Sound { return self with { gain: g } }
@doc("Sets a one-shot's pitch (1.0 is unmodified).")
fn pitch(self: Sound, p: Fixed) -> Sound { return self with { pitch: p } }
@doc("Routes a one-shot to a mixer bus.")
fn bus(self: Sound, b: Bus) -> Sound { return self with { bus: b } }
@doc("Places a one-shot in the world.")
fn at(self: Sound, pos: Vec3) -> Sound { return self with { at: Option::Some(pos) } }

@doc("Sets a sustained sound's gain (changing it across ticks fades the live voice).")
fn gain(self: Audio, g: Fixed) -> Audio { return self with { gain: g } }
@doc("Sets a sustained sound's pitch/playback rate.")
fn pitch(self: Audio, p: Fixed) -> Audio { return self with { pitch: p } }
@doc("Routes a sustained sound to a mixer bus.")
fn bus(self: Audio, b: Bus) -> Audio { return self with { bus: b } }
@doc("Places a sustained sound in the world.")
fn at(self: Audio, pos: Vec3) -> Audio { return self with { at: Option::Some(pos) } }
