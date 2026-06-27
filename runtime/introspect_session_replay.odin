package funpack_runtime

import "core:fmt"
import "core:strings"

Session_Recorder :: struct {
	session: ^Debug_Session,
	writer:  Session_Log_Writer,
}

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

record_event :: proc(recorder: ^Session_Recorder, event_line: string) {
	log_session_entry(&recorder.writer, .Event, event_line)
}

finish_session_record :: proc(recorder: ^Session_Recorder, allocator := context.allocator) -> string {
	return finish_session_log(&recorder.writer, allocator)
}

delete_session_recorder :: proc(recorder: ^Session_Recorder) {
	delete_session_log_writer(&recorder.writer)
}

Session_Replay_Refusal :: enum {
	None,
	Recording_Mismatch,
	Diverged,
}

Session_Replay_Result :: struct {
	refusal:           Session_Replay_Refusal,
	requests_replayed: int,
	diagnostic:        string,
}

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
			i += 2
		case .Response:
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
			i += 1
		}
	}

	return Session_Replay_Result{refusal = .None, requests_replayed = replayed}
}

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
