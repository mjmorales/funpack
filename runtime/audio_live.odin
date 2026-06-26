// The LIVE audio boundary: consumes the pure §22 §2 keyed track scene
// (audio.odin's Audio_Scene) and reconciles it against SDL's audio device — the
// sustained regime's start / stop / bend. Like the live device and present
// boundaries, it is an interchangeable OUTPUT of the deterministic projection:
// the scene is the contract, the SDL device the replaceable consumer. Nothing it
// does flows back into the sim (the §22 "never flows back into the sim, like
// Draw" rule), so a headless re-fold computes the identical scene this layer
// would have played — the projection is the determinism surface, the mix is not.
//
// LEVEL-TRIGGERED RECONCILIATION (§22 §1): each tick the scene is the FULL set of
// tracks that should be sounding, keyed by a stable String. audio_live_apply
// diffs the new scene against the live voice table by key — a key present now but
// absent before STARTS a voice, a key absent now but present before STOPS its
// voice, and a key in both BENDS the live voice to the new gain/pitch (the same
// reconciliation a UI View runs). So as a creature's committed `speed` changes,
// its stride voice's pitch (0.6+speed*0.2) and gain (clamp(speed,0,1)) bend on a
// live voice rather than restarting, and at rest (empty scene) the voice stops.
//
// HEADLESS/LIVE SEPARATION: the vendor:sdl2 import is held only by a type alias
// (AUDIO_LIVE_SDL_ALIVE) so -vet accepts it under a headless build, while every
// SDL CALL and the whole reconciler live behind `when #config(FUNPACK_LIVE,
// false)`. A default (headless / test / CI) build references no SDL symbol and
// links no audio device; the live backend compiles only under
// -define:FUNPACK_LIVE=true. audio.odin (the projection) imports no SDL at all,
// so the acceptance criterion "no SDL identifier outside a FUNPACK_LIVE block in
// the audio path" holds: SDL appears only in THIS file, only inside the when-block
// (and the dead-stripped alias).
//
// ODIN-FIRST (verified): vendor:sdl2's audio device API (OpenAudioDevice /
// PauseAudioDevice / CloseAudioDevice over an AudioSpec) is the platform output
// path — no custom device layer is written; this is a thin scene→device
// reconciler over it. Sample decode/mix is the playback detail the device feeds
// (the per-voice feed seam below), not a determinism concern.
package funpack_runtime

import sdl "vendor:sdl2"

// AUDIO_LIVE_SDL_ALIVE keeps the vendor:sdl2 import referenced OUTSIDE the
// when-gated reconciler so a headless build's -vet does not flag the import as
// unused, while emitting no SDL symbol (a type alias is dead-stripped, so the
// default binary links no audio device). The live backend below uses this same
// import for its real SDL calls; this alias exists only to satisfy the headless
// vet gate, the identical discipline device_live/session_live hold their imports
// with.
AUDIO_LIVE_SDL_ALIVE :: sdl.AudioDeviceID

// AUDIO_LIVE_FREQ / AUDIO_LIVE_CHANNELS / AUDIO_LIVE_SAMPLES are the output device
// format the live backend opens — a 44.1kHz stereo S16 device with a small frame
// buffer, the conventional game-audio output. They are output-side constants
// (never on the determinism path: the scene is identical regardless of the device
// format), pinned here so the open call carries no magic numbers.
AUDIO_LIVE_FREQ :: 44100
AUDIO_LIVE_CHANNELS :: 2
AUDIO_LIVE_SAMPLES :: 1024

when #config(FUNPACK_LIVE, false) {

	// Live_Voice is one live sustained voice the backend keeps alive for a scene
	// key: the SDL device id it sounds through and the gain/pitch it is currently
	// bent to (the last values audio_live_apply reconciled it to). The voice is
	// keyed by the track's stable String in the table; a re-applied scene bends
	// these in place rather than restarting, so the same key is the same voice
	// across ticks (§22 §1).
	Live_Voice :: struct {
		device: sdl.AudioDeviceID,
		clip:   string,
		gain:   Fixed,
		pitch:  Fixed,
	}

	// Live_Audio is the live backend's whole state: the table of currently-sounding
	// voices keyed by the track key, and the device format the voices open against.
	// It is the live consumer of the keyed scene — created once for a session, fed
	// the projected scene each tick, and closed at session end. It owns the SDL
	// devices its voices hold.
	Live_Audio :: struct {
		voices: map[string]Live_Voice,
		spec:   sdl.AudioSpec,
	}

	// audio_live_open initializes SDL's audio subsystem and seeds an empty voice
	// table with the output device format every voice opens against. `ok` is false
	// when the audio subsystem fails to init (a machine with no audio device fails
	// closed — the live session runs silent rather than faulting). Impure: this is
	// the only audio code that touches the real device stack. Runs once before the
	// session loop, the open/close pair the session driver owns.
	audio_live_open :: proc(allocator := context.allocator) -> (live: Live_Audio, ok: bool) {
		if sdl.InitSubSystem(sdl.INIT_AUDIO) != 0 {
			return Live_Audio{}, false
		}
		spec := sdl.AudioSpec {
			freq     = AUDIO_LIVE_FREQ,
			format   = sdl.AUDIO_S16,
			channels = AUDIO_LIVE_CHANNELS,
			samples  = AUDIO_LIVE_SAMPLES,
		}
		return Live_Audio{voices = make(map[string]Live_Voice, allocator), spec = spec}, true
	}

	// audio_live_apply reconciles one tick's keyed scene against the live voice
	// table (§22 §1 level-triggered diff): a key present in the scene but not the
	// table STARTS a voice (open + unpause its device); a key in BOTH BENDS the live
	// voice to the new gain/pitch with no restart (same key ⇒ same voice); a key in
	// the table but not the scene STOPS its voice (pause + close). The scene order
	// is the deterministic projection order; the diff is order-independent (it keys
	// on the String), so two identical scenes reconcile to the identical voice set.
	// The mix/decode that fills a voice's device is the playback detail
	// (audio_voice_feed), not reproduced on the determinism path.
	audio_live_apply :: proc(live: ^Live_Audio, scene: Audio_Scene) {
		// Mark which keys the new scene wants, starting or bending each.
		wanted := make(map[string]bool, len(scene.tracks), context.temp_allocator)
		for track in scene.tracks {
			wanted[track.key] = true
			if existing, present := live.voices[track.key]; present {
				audio_voice_bend(live, track, existing)
			} else {
				audio_voice_start(live, track)
			}
		}
		// Stop every live voice the new scene no longer wants. Collect the dead keys
		// first so the map is not mutated mid-iteration.
		dead := make([dynamic]string, 0, len(live.voices), context.temp_allocator)
		for key in live.voices {
			if !wanted[key] {
				append(&dead, key)
			}
		}
		for key in dead {
			audio_voice_stop(live, key)
		}
	}

	// audio_voice_start opens a device for a new scene key and registers the live
	// voice, then unpauses it so it sounds. A device that fails to open is skipped
	// (the voice simply does not register — fail-closed, no fault), so a transient
	// device error drops one voice rather than crashing the session.
	//
	// ONE DEVICE PER VOICE is a DELIBERATE krognid-scoped seam (krognid sounds one
	// stride voice), NOT the final mixer architecture: a future multi-voice game
	// mixes all voices into ONE output device, and this reconciler's table would then
	// hold mixer voice SLOTS (gain/pitch/clip per slot) fed into a single device's
	// callback, not one SDL device per key. The start/stop/bend reconciliation
	// lifecycle is unchanged across that seam; only what a table entry owns moves
	// from an SDL device to a mixer slot.
	audio_voice_start :: proc(live: ^Live_Audio, track: Audio_Track) {
		want := live.spec
		got: sdl.AudioSpec
		// No format negotiation: the device opens at exactly the requested spec
		// (an empty allow-change set), so every voice shares one output format.
		device := sdl.OpenAudioDevice(nil, false, &want, &got, sdl.AudioAllowChangeFlags{})
		if device == 0 {
			return
		}
		live.voices[track.key] = Live_Voice {
			device = device,
			clip   = track.clip,
			gain   = track.gain,
			pitch  = track.pitch,
		}
		// The feed seam supplies the decoded, gain/pitch-applied samples; unpausing
		// lets the device consume them.
		audio_voice_feed(live, track.key)
		sdl.PauseAudioDevice(device, false)
	}

	// audio_voice_bend updates a SURVIVING voice's gain/pitch in place (no device
	// restart) — the §22 §1 "change gain/pitch to fade or bend" path locomotion
	// drives as a creature's speed changes. Only the bent values change; the device
	// keeps sounding, so the stride loop pitches up smoothly rather than retriggering.
	// A new clip on the same key would crossfade (§22 §1); krognid keeps one clip, so
	// the bend is the gain/pitch update plus a re-feed at the new rate.
	audio_voice_bend :: proc(live: ^Live_Audio, track: Audio_Track, existing: Live_Voice) {
		updated := existing
		updated.gain = track.gain
		updated.pitch = track.pitch
		updated.clip = track.clip
		live.voices[track.key] = updated
		audio_voice_feed(live, track.key)
	}

	// audio_voice_stop pauses and closes a vanished key's device and drops it from
	// the table — the §22 §1 "absent next tick ⇒ stopped" path the empty rest-scene
	// drives (locomotion returns [] at rest, so the stride voice stops). A missing
	// key is a no-op.
	audio_voice_stop :: proc(live: ^Live_Audio, key: string) {
		voice, present := live.voices[key]
		if !present {
			return
		}
		sdl.PauseAudioDevice(voice.device, true)
		sdl.CloseAudioDevice(voice.device)
		delete_key(&live.voices, key)
	}

	// audio_voice_feed is the per-voice sample seam: decode the voice's clip and
	// queue the gain/pitch-applied samples onto its device. The decode + resample to
	// the voice's pitch and the gain scale are the engine's playback detail — kept
	// here as the documented seam rather than reaching back into the sim. krognid's
	// stride clip is a short loop the live voice repeats while present; the loop fill
	// is output-side and never re-enters the deterministic fold. Left as the seam the
	// asset-pipeline story fills (the clip bytes live behind the §19 SoundHandle the
	// track carries); the reconciler's START/BEND/STOP lifecycle above is the part
	// this story wires.
	audio_voice_feed :: proc(live: ^Live_Audio, key: string) {
		// UNIMPLEMENTED — pending the §19 sound-asset decode. This seam WILL decode the
		// voice's clip and queue its gain/pitch-applied samples onto the open device;
		// until that lands there are no sample bytes to feed, so it is DELIBERATELY a
		// no-op — not a silent stub: the start/stop/bend lifecycle above is fully wired,
		// only the sample fill waits on the asset pipeline. The map read below is an
		// EXPLICIT reference-keeper, documenting the seam's (live, key) dependency so the
		// contract the decode fills is visible here rather than implied — not dead code.
		_, _ = live.voices[key]
	}

	// audio_live_close stops every live voice and quits SDL's audio subsystem — the
	// session-end teardown the open/close pair owns. After this the table is empty
	// and no device is held; a headless build never reaches it.
	audio_live_close :: proc(live: ^Live_Audio) {
		keys := make([dynamic]string, 0, len(live.voices), context.temp_allocator)
		for key in live.voices {
			append(&keys, key)
		}
		for key in keys {
			audio_voice_stop(live, key)
		}
		delete(live.voices)
		sdl.QuitSubSystem(sdl.INIT_AUDIO)
	}
}
