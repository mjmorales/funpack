// §28 §3 SESSION RECORD/REPLAY — the recorder driver and the replay re-drive
// driver, the consuming twins of the session command-log format
// (introspect_session_log.odin). "Sessions are themselves replayable — the command
// stream is NDJSON and logged, so a debug session (recording + command log) re-runs
// bit-identically and is shareable." The recorder logs a live session's
// request/event stream as it crosses the seam; the replayer re-drives a recorded
// command log through a FRESH session over the SAME recording and reproduces the
// session's transcript bit-for-bit — the shareable-repro property the §28 §5
// agent-driven verification driver builds on.
//
// THE RECORDER IS A THIN WRAPPER OVER THE FOLD (the engine boundary): record_request
// is session_request plus two log appends — it logs the request line, dispatches it
// through the EXACT same fold every driver uses, and logs the response line. It adds
// NOTHING to the dispatch path, so a recorded session digests identically to an
// unrecorded one (the recorder is observe-class w.r.t. the session). Async-events
// (§28 §3: breakpoint_hit / watch_fired / paused / reload_result / diverged) are
// logged through record_event when the live host pushes one; the present synchronous
// fold emits none, so the recorded stream is request+response pairs today, with the
// event entry kind reserved so the format IS the full §3 request/async-event stream
// the moment a probe/async surface lands (concurrent sibling work).
//
// REPLAY = FRESH OPEN + RE-DRIVE + COMPARE (mirroring the replay re-fold driver,
// replay.odin). The replayer takes a freshly-opened Debug_Session over the recording
// (the SAME program + snapshots + seed the command log pins — the caller pairs the
// recording with the log, exactly as replay() pairs a freshly-loaded artifact with a
// replay log) and re-feeds each logged REQUEST through session_request in stream
// order. Because session_request is a pure deterministic fold over (session_state,
// request), the re-driven session reproduces every response byte-for-byte. The
// replayer compares each reproduced response against the recorded RESPONSE entry; the
// first divergence is the §28 §3 `diverged` condition surfaced as a refusal with the
// stream offset and both transcripts, never a silent best-effort.
//
// runtime/** never imports funpack/**; the artifact bytes (and the envelope wire) are
// the only sanctioned coupling (§29, §09).
package funpack_runtime

import "core:fmt"
import "core:strings"

// Session_Recorder wraps a live Debug_Session with a command-log writer: every
// request dispatched through record_request is logged (request line, then response
// line) into the writer in stream order. The recorder borrows the session (it does
// not own it — the caller opened it) and owns the writer until finish_session_record
// hands back the assembled log bytes.
Session_Recorder :: struct {
	session: ^Debug_Session,
	writer:  Session_Log_Writer,
}

// open_session_recorder starts recording a live session against the recording's
// identity and snapshot count — the SAME identity the paired replay log pins, so the
// recording and the command log agree on the build the session ran against. The
// session is borrowed; the writer is allocated on the passed allocator and finished
// with finish_session_record / delete via the writer's lifecycle.
open_session_recorder :: proc(
	session: ^Debug_Session,
	identity: Replay_Identity,
	tick_count: int,
	allocator := context.allocator,
) -> Session_Recorder {
	return Session_Recorder {
		session = session,
		writer = open_session_log_writer(identity, tick_count, allocator),
	}
}

// record_request dispatches one request through the live session AND logs the
// request/response pair into the command log. It is session_request plus the two
// log appends — the dispatch is the identical pure fold, so recording perturbs the
// session not at all (a recorded session digests bit-identical to an unrecorded one).
// The returned response is the live response line, so a recording host still drives
// the session normally while logging it. The request is logged BEFORE dispatch and
// the response AFTER, so the stream order is the true wire order.
record_request :: proc(
	recorder: ^Session_Recorder,
	line: string,
	allocator := context.allocator,
) -> string {
	log_session_entry(&recorder.writer, .Request, line)
	response := session_request(recorder.session, line, allocator)
	log_session_entry(&recorder.writer, .Response, response)
	return response
}

// record_event logs one async-event the live host pushed (§28 §3: breakpoint_hit /
// watch_fired / paused / reload_result / diverged — correlated by event name, not an
// id). The present synchronous fold emits none, so this is the seam the async
// surface (concurrent sibling work) logs through; recording an event is a pure
// append, so it never perturbs the session. The event line is logged at the exact
// point it crosses the seam, preserving stream order against the surrounding
// request/response pairs.
record_event :: proc(recorder: ^Session_Recorder, event_line: string) {
	log_session_entry(&recorder.writer, .Event, event_line)
}

// finish_session_record assembles the recorded command log and returns its bytes —
// the byte-stable, shareable record the replayer re-drives. The returned string is
// owned by the caller; the recorder's writer is freed with
// delete_session_log_writer afterward.
finish_session_record :: proc(recorder: ^Session_Recorder, allocator := context.allocator) -> string {
	return finish_session_log(&recorder.writer, allocator)
}

// delete_session_recorder releases the recorder's writer builders. The recorder
// borrowed the session, so it does not free it.
delete_session_recorder :: proc(recorder: ^Session_Recorder) {
	delete_session_log_writer(&recorder.writer)
}

// --- The replay re-drive driver --------------------------------------------

// Session_Replay_Refusal is the closed set of reasons the replayer refuses to
// reproduce a recorded session. None is the success arm (every request re-fed
// reproduced its recorded response byte-for-byte — the bit-identical transcript
// property held). Recording_Mismatch is the recording-identity gate firing: the
// command log's pinned recording identity or snapshot extent does not match the
// session it is being re-driven over, so re-driving would feed the request stream
// against the wrong recording. Diverged is the §28 §3 `diverged` condition: a
// re-fed request produced a response that differs from the recorded one (a
// non-deterministic dispatch would be a runtime bug — the whole point of the
// property is that this never happens for a faithful re-drive).
Session_Replay_Refusal :: enum {
	None,
	Recording_Mismatch,
	Diverged,
}

// Session_Replay_Result is the outcome of a session re-drive: the refusal arm, the
// count of requests re-fed (the stream position the replay reached), and a
// human-readable diagnostic. On a Diverged refusal the diagnostic names the stream
// entry offset and quotes both the recorded and the reproduced response, so the
// divergence is fully localized. On a Recording_Mismatch no request is re-fed
// (requests_replayed = 0); on success requests_replayed is the recorded request
// count.
Session_Replay_Result :: struct {
	refusal:           Session_Replay_Refusal,
	requests_replayed: int,
	diagnostic:        string,
}

// replay_session re-drives a recorded command log through a FRESH session and proves
// the bit-identical transcript property. The caller opens `session` over the SAME
// recording the command log pins and passes `recording_identity` — the build
// fingerprint + tick-0 seed the recording was opened under, derived from the same
// artifact bytes (identity_from_program / _seeded), exactly as replay() takes
// artifact_bytes for its gate. replay_session FIRST gates the command log's pinned
// recording identity against that (the full §09 §5 fingerprint — whole-struct
// equality over Replay_Identity) AND cross-checks the snapshot extent against the
// session, then re-feeds each logged REQUEST through session_request in stream order
// and compares the reproduced response against the recorded RESPONSE entry.
//
// Gating the full build identity here — not just the seed — is the same discipline
// the replay log's identity gate keeps: a Debug_Session retains only `program`
// (no artifact bytes), so the caller supplies the fingerprint it derived to open the
// recording; re-driving a command log against the wrong build folds the request
// stream over a different program and is refused before a single request.
//
// The entries interleave request/response (and, in the async future, event) kinds in
// wire order. The re-drive walks them in order: a Request entry is re-fed and the NEXT
// Response entry must equal the reproduced response (the request's correlated answer);
// Event entries are part of the recorded transcript but the synchronous fold pushes
// none on re-drive, so they are walked past without re-feeding (the async surface that
// emits them is concurrent sibling work). The first response divergence stops the
// re-drive with a Diverged refusal naming the offset and both transcripts; an exhausted
// stream with every response reproduced is the success arm — the recorded session
// re-ran to a byte-identical transcript.
replay_session :: proc(
	session: ^Debug_Session,
	recording_identity: Replay_Identity,
	log: Session_Log,
	allocator := context.allocator,
) -> Session_Replay_Result {
	if !session_recording_matches(session, recording_identity, log) {
		return Session_Replay_Result {
			refusal    = .Recording_Mismatch,
			diagnostic = session_mismatch_diagnostic(session, recording_identity, log, allocator),
		}
	}

	replayed := 0
	i := 0
	for i < len(log.entries) {
		entry := log.entries[i]
		switch entry.kind {
		case .Request:
			reproduced := session_request(session, entry.envelope, allocator)
			replayed += 1
			// The recorded RESPONSE is the next entry (a request's correlated answer
			// is its immediate successor in the stream the recorder logged). A request
			// with no following response entry is a truncated log — fail closed.
			if i + 1 >= len(log.entries) || log.entries[i + 1].kind != .Response {
				return Session_Replay_Result {
					refusal           = .Diverged,
					requests_replayed = replayed,
					diagnostic        = fmt.aprintf(
						"session replay: request at stream offset %d has no recorded response (truncated log); reproduced %q",
						i,
						reproduced,
						allocator = allocator,
					),
				}
			}
			recorded := log.entries[i + 1].envelope
			if reproduced != recorded {
				return Session_Replay_Result {
					refusal           = .Diverged,
					requests_replayed = replayed,
					diagnostic        = fmt.aprintf(
						"session replay diverged at stream offset %d: recorded %q, reproduced %q",
						i + 1,
						recorded,
						reproduced,
						allocator = allocator,
					),
				}
			}
			i += 2 // consumed the request and its response
		case .Response:
			// A response with no preceding request the loop already paired is a
			// malformed stream — fail closed rather than silently skipping it.
			return Session_Replay_Result {
				refusal           = .Diverged,
				requests_replayed = replayed,
				diagnostic        = fmt.aprintf(
					"session replay: orphan response entry at stream offset %d (no preceding request)",
					i,
					allocator = allocator,
				),
			}
		case .Event:
			// An async-event is part of the recorded transcript but the synchronous
			// fold pushes none on re-drive — walk past it (the surface that emits and
			// re-emits events is concurrent sibling work).
			i += 1
		}
	}

	return Session_Replay_Result{refusal = .None, requests_replayed = replayed}
}

// session_recording_matches gates that the session being re-driven IS the recording
// the command log was made against: the command log's pinned recording identity must
// equal the recording identity the caller opened the session under (the full §09 §5
// build fingerprint + tick-0 seed), AND the recording's snapshot extent must equal the
// session's. A mismatch means the command log would be re-fed against the wrong
// recording, so the replay is refused before a single request is re-fed. The identity
// match is whole-struct equality — Replay_Identity is a flat record of comparable
// fields (schema, project name/version, tick rate, content hash, has_seed, seed), so
// `==` checks every field the replay log's identity gate checks, no field omitted.
@(private = "file")
session_recording_matches :: proc(
	session: ^Debug_Session,
	recording_identity: Replay_Identity,
	log: Session_Log,
) -> bool {
	if len(session.snapshots) != log.tick_count {
		return false
	}
	return log.identity == recording_identity
}

// session_mismatch_diagnostic renders the Recording_Mismatch reason — the snapshot
// extent and recording fingerprint the command log expects against what the session
// and its opening identity carry — so the caller sees which half of the pairing is
// wrong. It names the snapshot counts, the two build fingerprints (project, schema,
// tick rate, content hash), and the two seeds, mirroring the replay log's identity-
// gate refusal so a reader distinguishes a wrong extent, a wrong build, and a wrong
// seed.
@(private = "file")
session_mismatch_diagnostic :: proc(
	session: ^Debug_Session,
	recording_identity: Replay_Identity,
	log: Session_Log,
	allocator := context.allocator,
) -> string {
	expected := log.identity
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"session replay recording mismatch: command log expects %d snapshots of %s %s " +
		"(schema %d, tick_hz %d, hash %d, seeded=%v seed=%d), session has %d snapshots of %s %s " +
		"(schema %d, tick_hz %d, hash %d, seeded=%v seed=%d)",
		log.tick_count,
		expected.project_name,
		expected.project_version,
		expected.artifact_schema_version,
		expected.tick_hz,
		expected.content_hash,
		expected.has_seed,
		expected.seed,
		len(session.snapshots),
		recording_identity.project_name,
		recording_identity.project_version,
		recording_identity.artifact_schema_version,
		recording_identity.tick_hz,
		recording_identity.content_hash,
		recording_identity.has_seed,
		recording_identity.seed,
	)
	return strings.to_string(b)
}
