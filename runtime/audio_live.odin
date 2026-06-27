package funpack_runtime

import sdl "vendor:sdl2"

AUDIO_LIVE_SDL_ALIVE :: sdl.AudioDeviceID

AUDIO_LIVE_FREQ :: 44100
AUDIO_LIVE_CHANNELS :: 2
AUDIO_LIVE_SAMPLES :: 1024

when #config(FUNPACK_LIVE, false) {

	Live_Voice :: struct {
		device: sdl.AudioDeviceID,
		clip:   string,
		gain:   Fixed,
		pitch:  Fixed,
	}

	Live_Audio :: struct {
		voices: map[string]Live_Voice,
		spec:   sdl.AudioSpec,
	}

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

	audio_live_apply :: proc(live: ^Live_Audio, scene: Audio_Scene) {
		wanted := make(map[string]bool, len(scene.tracks), context.temp_allocator)
		for track in scene.tracks {
			wanted[track.key] = true
			if existing, present := live.voices[track.key]; present {
				audio_voice_bend(live, track, existing)
			} else {
				audio_voice_start(live, track)
			}
		}
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

	audio_voice_start :: proc(live: ^Live_Audio, track: Audio_Track) {
		want := live.spec
		got: sdl.AudioSpec
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
		audio_voice_feed(live, track.key)
		sdl.PauseAudioDevice(device, false)
	}

	audio_voice_bend :: proc(live: ^Live_Audio, track: Audio_Track, existing: Live_Voice) {
		updated := existing
		updated.gain = track.gain
		updated.pitch = track.pitch
		updated.clip = track.clip
		live.voices[track.key] = updated
		audio_voice_feed(live, track.key)
	}

	audio_voice_stop :: proc(live: ^Live_Audio, key: string) {
		voice, present := live.voices[key]
		if !present {
			return
		}
		sdl.PauseAudioDevice(voice.device, true)
		sdl.CloseAudioDevice(voice.device)
		delete_key(&live.voices, key)
	}

	audio_voice_feed :: proc(live: ^Live_Audio, key: string) {
		_, _ = live.voices[key]
	}

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
