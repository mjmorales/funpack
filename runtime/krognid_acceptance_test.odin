// Krognid two-machine bit-identity acceptance harness (spec §07 §4, §09 §5, §10,
// §16 §7, §20 §1, §28): the determinism floor pong/hunt/yard established, now over
// the RIGGED-WALKER surface — the §16 §7 pose/anim evaluation (sin/trig kernel,
// Pose.blend over idle+walk, Skeleton/PartSet handles), the §20 §1 3D draw-list
// (Draw3::Camera/Light/Plane/Rigged), the committed §10 Vec3 `pos` column, and the
// §22 audio: stage (locomotion) — over the FIRST multi-module artifact the runtime
// executes (Lore #7, #8, #9, #14). It proves, end to end and against the REAL golden
// krognid artifact, the SAME three properties pong/hunt/yard rest on, over a scripted
// session that walks the creature a lap around the field so the digest folds a real
// evolving walk-cycle (pos moves, phase wraps, speed varies, the walk pose blends
// over idle, and the idle bob advances over logical time):
//
//   - LIVE-VS-REPLAY BIT-IDENTITY: a live krognid run captured per-tick (the digest
//     surface — committed world state + the §20 §1 Draw3 draw-list) and the
//     production re-fold of its RECORDED log, captured the same way through the same
//     identity-gated replay_capture driver, produce bit-identical per-tick AND
//     session frame digests — the digest reads committed state + the draw-list, so
//     substituting the input source (live resolution vs the recorded snapshot)
//     changes nothing (§07 §4). Equal per-tick digests prove every committed tick
//     matched: the moving Vec3 pos, the wrapped fixed-point phase, AND the rig fold
//     (the per-bone pose Transforms blended idle↔walk by speed, the handle op-logs,
//     the Vec3 draw `at`) — all raw fixed-point, no float (§10).
//   - CROSS-BUILD GOLDEN RE-FOLD: a golden replay log committed under testdata/,
//     re-folded on the CURRENT build, reproduces the committed expected session
//     digest bit-identically — the honest, CI-runnable mechanical proxy for
//     "identical on a second machine", since a different build re-folding the same
//     committed log must reproduce the same committed digest (§09 §5 interpreter-as-
//     ground-truth: input is the SOLE nondeterminism source — krognid is SEEDLESS,
//     no RNG, pure fixed-point pose/gait (Lore #14) — so has_seed=false and the
//     committed log plus the committed digest are the durable milestone regression
//     fixtures).
//   - GATE REPRODUCTION RECIPE: a true cross-hardware/second-build run is
//     operator-gated, not CI-mechanizable — the operator runs the same golden
//     re-fold on a second machine or an independently rebuilt binary and confirms the
//     produced session digest equals the committed expected digest. The GOLDEN-FIXTURE
//     REGENERATION + OPERATOR GATE recipe below documents both the regeneration
//     command and the exact reproduction command, AND the live SDL visual gate.
//
// THE DIGEST BOUNDARY (what the session digest folds, and what it deliberately does
// NOT). The per-tick digest covers the committed world state (every thing's
// blackboard, including the §10 Vec3 `pos` column under the v6 Field_Tag.Vec3 arm)
// and the §20 §1 Draw3 draw-list (the four 3D command arms under the v6 Cmd_Tag
// ordinals, including the full rig fold). It does NOT fold the §22 `audio:` scene:
// FRAME_DIGEST_SCHEMA_VERSION is 6 and carries NO audio tag, by design — the keyed
// Audio projection (the locomotion stride loop) is a present-boundary OUTPUT, never a
// determinism input, and it is proven SEPARATELY by the audio story's tests
// (audio_test.odin). Folding the audio scene into the session digest would be a
// further schema bump for no determinism gain; the harness deliberately digests world
// state + the Draw3 draw-list only, exactly as the yard harness digests world state +
// its 2D draw-list. run_pipeline_fold already skips the audio: stage (it is a terminal
// projection like render), so the committed state the digest folds never reflects it.
//
// THE WALK ARC THE DIGEST FOLDS (the non-trivial evolving shape that makes the
// per-tick digests distinct): krognid_session_inputs drives the creature a lap around
// the field — forward, strafe right, back, strafe left, then a rest tail — through the
// two 1D Drive axes (Drive::Strafe → x, Drive::Forward → z on the XZ ground plane).
// The Vec3 pos sweeps a rectangle, clamp_to_board pins it inside the BOARD on the rails,
// the walk-cycle phase wraps into one turn each leg, the speed ramps the walk pose over
// the idle, and the rest tail drops to speed 0 so the walk pose decays to the pure idle
// bob (which still advances over logical time `t`). So the digest folds a real evolving
// rigged walk, not a static posed creature.
//
// GOLDEN-FIXTURE REGENERATION (rebuild the committed log + expected digest):
//
//     FUNPACK_REGEN_GOLDEN=1 task -d runtime test
//
// That env var arms test_regenerate_krognid_golden_fixtures, which records the
// scripted session (krognid_session_inputs) through the production recorder against
// the golden krognid artifact's pinned SEEDLESS identity, writes the byte-stable log
// to testdata/krognid_golden.replay, re-folds it through replay_capture, and writes
// the produced session digest (decimal u64) to testdata/krognid_golden.digest. Commit
// both regenerated files. Regenerate ONLY when a deliberate change to the artifact,
// the replay encoding, or the frame-digest encoding intentionally moves the digest —
// a digest that moves without such a change is a determinism regression, not a stale
// fixture.
//
// OPERATOR GATE — second-machine / second-build reproduction (verifies_by:gate). Two
// independent reproductions, both operator-driven:
//
//   (1) HEADLESS DIGEST REPRODUCTION. On a second machine, or against an
//       independently rebuilt binary, run
//
//           task -d runtime test
//
//       and confirm test_committed_krognid_log_reproduces_expected_digest PASSES.
//       That test re-folds the COMMITTED testdata/krognid_golden.replay on the build
//       under test and asserts its session digest equals the COMMITTED
//       testdata/krognid_golden.digest — so a passing run on the second machine is a
//       bit-identical reproduction of the committed digest. The committed fixtures are
//       embedded with #load, so the reproduction needs no funpack source and no cwd —
//       only the runtime package and the committed testdata/.
//
//   (2) LIVE SDL VISUAL GATE (the human visual check). Build the live binary and run
//       the committed artifact under it:
//
//           cd runtime
//           odin build . -define:FUNPACK_LIVE=true -out:funpack-live
//           ./funpack-live testdata/krognid.artifact
//
//       EXPECT a window (the largest integer scale of the artifact's 160x120 logical
//       extent that fits, so 4x → 640x480) showing the gray ground plane (the §20 §1
//       Draw3::Plane projected top-down on the XZ ground) with a white marker (the
//       Draw3::Rigged creature's XZ footprint — a deliberate 2D stand-in for the
//       skinned mesh under the flat top-down present, the present-decision the Draw3
//       story made). DRIVE with WASD or the left stick: the marker WALKS around the
//       field (W/S forward/back = +Z/−Z, A/D strafe = −X/+X), clamped inside the board.
//       The 3D camera/light contribute no painted pixels under the flat present (the
//       digest still folds them). Press Escape (or close the window) to exit; the
//       session writes testdata/krognid.replay beside the artifact. VERIFY THE DIGEST
//       ON A SECOND MACHINE: the live session is NOT bit-pinned (the player's live
//       input is free), so it is the VISUAL gate; the DIGEST gate is recipe (1) above
//       over the COMMITTED golden log, which IS bit-pinned. A machine with no display
//       runs neither the live gate nor needs to — recipe (1) is the headless proof.
package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

// KROGNID_GOLDEN_REPLAY_LOG is the committed golden krognid replay log, embedded at
// compile time — so the cross-build re-fold test runs with no filesystem and no cwd,
// only the runtime package. It is the byte-stable log krognid_session_inputs records
// through the production recorder; the regeneration test rewrites it. (KROGNID_ARTIFACT
// itself is embedded in krognid_load_test.odin — the ONE #load of the multi-module
// artifact, shared across the krognid runtime tests.)
KROGNID_GOLDEN_REPLAY_LOG := #load("testdata/krognid_golden.replay", string)

// KROGNID_GOLDEN_EXPECTED_DIGEST is the committed expected session digest of the
// krognid golden log's re-fold, embedded as a decimal u64 text fixture. A build that
// re-folds KROGNID_GOLDEN_REPLAY_LOG must reproduce exactly this value; a divergence
// is the determinism target failing, not a stale fixture.
KROGNID_GOLDEN_EXPECTED_DIGEST := #load("testdata/krognid_golden.digest", string)

// KROGNID_SESSION_TICKS is the scripted session length: long enough to walk a full
// lap around the field (forward, strafe right, back, strafe left) plus a rest tail
// where the creature stops and the walk pose decays to the pure idle bob — so the
// digest folds a real evolving walk-cycle (the moving Vec3 pos, the wrapping phase,
// the speed-driven walk↔idle blend, the logical-time idle bob) rather than a static
// posed creature.
@(private = "file")
KROGNID_SESSION_TICKS :: 240

// KROGNID_STRAFE / KROGNID_FORWARD are krognid's Drive axis actions — Drive is the
// SOLE Axis enum in the declaration walk, so its variants mint ActionId 0 (Strafe)
// and 1 (Forward) in variant order (build_action_registry). read_drive reads each as
// a 1D `input.value` (NOT a 2D axis), so the scripted session drives the two
// components independently through with_value.
@(private = "file")
KROGNID_STRAFE :: ActionId(0)
@(private = "file")
KROGNID_FORWARD :: ActionId(1)

// krognid_session_inputs builds the scripted input session the golden fixtures are
// generated from and the live-vs-replay test drives. The creature spawns at the board
// center (25, 0, 25); the legs walk it a lap on the XZ ground plane — forward (+Z),
// strafe right (+X), back (−Z), strafe left (−X) — then a rest tail with no drive so
// it stops, the walk pose decays to the pure idle bob, and the speed-0 audio: stage
// goes silent. Each component is driven through its own 1D Drive axis (Strafe → x,
// Forward → z), the read_drive body's twin `input.value` reads. The SAME sequence
// drives the live capture, the recorded re-fold, and the committed-log regeneration,
// so the three stay reproducible from this one definition. SEEDLESS — no Rng threads.
@(private = "file")
krognid_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, KROGNID_SESSION_TICKS, allocator)
	one := to_fixed(1)
	zero := Fixed(0)

	// One drive() builds a tick's Input from a (strafe, forward) pair on the two 1D
	// Drive axes — the read_drive body's `input.value(player, Drive::Strafe/Forward)`.
	drive :: proc(strafe, forward: Fixed) -> Input {
		return with_value(with_value(empty(), .P1, KROGNID_STRAFE, strafe), .P1, KROGNID_FORWARD, forward)
	}

	// Each leg is (strafe, forward, tick-count); they concatenate into the full
	// session. The trailing rest leg absorbs the remaining ticks so
	// KROGNID_SESSION_TICKS is the single length knob.
	Leg :: struct {
		strafe:  Fixed,
		forward: Fixed,
		ticks:   int,
	}
	legs := []Leg {
		{zero, one, 45}, // walk forward (+Z)
		{one, zero, 45}, // strafe right (+X)
		{zero, fixed_neg(one), 45}, // walk back (−Z)
		{fixed_neg(one), zero, 45}, // strafe left (−X), closing the lap
	}

	tick := 0
	for leg in legs {
		for _ in 0 ..< leg.ticks {
			if tick >= KROGNID_SESSION_TICKS {
				return inputs
			}
			inputs[tick] = drive(leg.strafe, leg.forward)
			tick += 1
		}
	}
	// Rest tail: no drive — the creature stops, the walk pose decays to the idle bob,
	// and the audio: stage goes silent. The idle bob still advances over logical time.
	for tick < KROGNID_SESSION_TICKS {
		inputs[tick] = empty()
		tick += 1
	}
	return inputs
}

// load_krognid parses the embedded krognid fixture into a Program against the test's
// temp allocator, failing the test on any refusal — the krognid counterpart of
// load_yard / load_golden. It also asserts the artifact is the v6 stamp the
// multi-module seam-fn carry + the §16 §7/§20 §1 anim/3D-render surface require: a
// lower stamp would mean the loader cannot decode the multi-module shape, and
// surfacing it here fails the harness with a clear cause rather than a downstream
// resolve miss.
load_krognid :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(KROGNID_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "golden krognid artifact must load, got %v", err) {
		return {}, false
	}
	if !testing.expect_value(t, loaded.schema_version, ARTIFACT_SCHEMA_VERSION) {
		return {}, false
	}
	return loaded, true
}

// krognid_live_capture drives a golden krognid session LIVE — restarting from setup
// and stepping the tick loop once per scripted input — capturing each committed tick's
// frame digest over the world state (including the §10 Vec3 `pos` column) and its §20
// §1 Draw3 draw-list (the camera/light/plane + the rig fold), then folding the session
// digest. It is the ground-truth capture the re-fold must reproduce; it drives the SAME
// run_startup + step_tick + render_version seam the production re-fold capture does, the
// only difference being that the input here is the live scripted snapshot rather than
// one parsed from a recorded log. Time rebinds per committed tick (time_resource_at) so
// `time.t` advances — krognid's pose_idle bob reads logical time — through the EXACT
// derivation refold_capture uses, so the render digest cannot fork. krognid is SEEDLESS:
// no Rng is threaded.
@(private = "file")
krognid_live_capture :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	tick_hz := program.entrypoint.tick_hz
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input, i in inputs {
		time := time_resource_at(tick_hz, i, allocator)
		version = step_tick(program, version, input, time, allocator)
		draw := render_version(program, version, input, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

// record_krognid_session records the scripted session through the production recorder
// against the golden krognid artifact's pinned identity and returns the finished log
// bytes — the byte-stable record both the live-vs-replay test re-folds and the
// regeneration test persists. The header pins the SEEDLESS golden identity derived
// from the real artifact bytes (krognid has no RNG, has_seed = false), so the log
// re-folds against the exact build it was recorded for (§09 §5).
@(private = "file")
record_krognid_session :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> string {
	identity := identity_from_program(program^, KROGNID_ARTIFACT)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(test)
test_krognid_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	// A live krognid run and the production re-fold of its RECORDED log yield
	// bit-identical per-tick AND session frame digests (§07 §4, §16 §7, §20 §1). The
	// live capture and the re-fold capture share only the artifact and the recorded
	// snapshots — the re-fold substitutes nothing but the input source (the parsed
	// log) — so equal per-tick digests prove every committed tick matched (the moving
	// Vec3 pos column, the wrapped fixed-point phase, AND the rig fold: the per-bone
	// pose Transforms, the handle op-logs, the Vec3 draw `at`) and an equal session
	// digest is the whole-run summary of that match. The re-fold runs through the
	// production replay_capture driver (identity-gated, SEEDLESS), not a test-only tick
	// loop, so the harness exercises the real recorder → reader → driver path over
	// krognid's rigged-walker surface — the FIRST multi-module artifact the runtime
	// executes.
	context.allocator = context.temp_allocator

	live_program, ok := load_krognid(t)
	if !ok {
		return
	}
	inputs := krognid_session_inputs()
	live := krognid_live_capture(&live_program, inputs)

	// Record the scripted session, then read it back through the production parser —
	// the re-fold re-feeds these parsed snapshots, never the live run's state.
	log_bytes := record_krognid_session(&live_program, inputs)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	// Re-fold against a FRESH program load through the production capturing driver.
	refold_program, refold_ok := load_krognid(t)
	if !refold_ok {
		return
	}
	result := replay_capture(&refold_program, KROGNID_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	if !testing.expect_value(t, len(result.capture.per_tick), len(live.per_tick)) {
		return
	}
	for frame, i in live.per_tick {
		testing.expect_value(t, result.capture.per_tick[i].tick, frame.tick)
		testing.expect_value(t, result.capture.per_tick[i].digest, frame.digest)
	}
	testing.expect_value(t, result.capture.session, live.session)
}

@(test)
test_committed_krognid_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	// The COMMITTED krognid golden replay log, re-folded on the CURRENT build, produces
	// a session digest exactly equal to the COMMITTED expected digest fixture (§09 §5,
	// §28). This is the cross-build two-machine proxy: input is the sole recorded
	// nondeterminism source (krognid is seedless — no RNG, has_seed = false, Lore #14)
	// and the interpreter is the determinism ground truth, so a DIFFERENT build
	// re-folding this SAME committed log must reproduce this SAME digest — a passing run
	// on a second machine is a bit-identical reproduction. A divergence here is the
	// determinism target failing (the pose/trig kernel, the Vec3 column, or the Draw3
	// fold drifting), not a stale fixture.
	context.allocator = context.temp_allocator

	program, ok := load_krognid(t)
	if !ok {
		return
	}

	log, parse_ok := read_replay(KROGNID_GOLDEN_REPLAY_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay_capture(&program, KROGNID_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	expected, digest_ok := parse_krognid_committed_digest(KROGNID_GOLDEN_EXPECTED_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, result.capture.session, expected)
}

// parse_krognid_committed_digest reads the committed expected-digest fixture — a
// decimal u64 with any trailing newline trimmed — into its u64 value. The fixture is a
// bare decimal so a human can read the committed digest at a glance and a regeneration
// writes it back the same way; ok is false on a malformed fixture so the test fails
// closed rather than comparing against a zero default.
@(private = "file")
parse_krognid_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	trimmed := strings.trim_space(text)
	return strconv.parse_u64(trimmed)
}

@(test)
test_regenerate_krognid_golden_fixtures :: proc(t: ^testing.T) {
	// Regeneration is armed only by FUNPACK_REGEN_GOLDEN — a normal `task test` run
	// SKIPS this, so the committed fixtures are never silently rewritten by an ordinary
	// test pass; only a deliberate regeneration touches them. When armed, it records the
	// scripted session through the production recorder, writes the byte-stable log to
	// testdata/krognid_golden.replay, re-folds it through the production capturing
	// driver, and writes the produced session digest (decimal u64) to
	// testdata/krognid_golden.digest — both relative to the runtime/ cwd
	// `task -d runtime test` runs from. Commit both regenerated files.
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator

	program, ok := load_krognid(t)
	if !ok {
		return
	}
	inputs := krognid_session_inputs()
	log_bytes := record_krognid_session(&program, inputs)

	log_path, log_join_err := filepath.join({"testdata", "krognid_golden.replay"})
	if !testing.expect(t, log_join_err == nil) {
		return
	}
	if !testing.expect(t, write_replay_file(log_path, log_bytes)) {
		return
	}

	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}
	result := replay_capture(&program, KROGNID_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], result.capture.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "krognid_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}
