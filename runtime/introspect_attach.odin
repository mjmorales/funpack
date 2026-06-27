package funpack_runtime

import "core:bytes"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

ATTACH_AUTH_ENV :: "FUNPACK_ATTACH_TOKEN"

ATTACH_DEFAULT_PORT :: 7341

Attach_Auth :: struct {
	expected: string,
	check:    proc(expected: string, presented: string) -> bool,
}

attach_token_check :: proc(expected: string, presented: string) -> bool {
	if len(expected) != len(presented) {
		return false
	}
	diff := 0
	for i in 0 ..< len(expected) {
		diff |= int(expected[i] ~ presented[i])
	}
	return diff == 0
}

attach_auth_from_token :: proc(token: string, allocator := context.allocator) -> (auth: Attach_Auth, ok: bool) {
	if token == "" {
		return {}, false
	}
	return Attach_Auth{expected = strings.clone(token, allocator), check = attach_token_check}, true
}

attach_auth_from_env :: proc(allocator := context.allocator) -> (auth: Attach_Auth, ok: bool) {
	token, found := os.lookup_env(ATTACH_AUTH_ENV, allocator)
	if !found || token == "" {
		return {}, false
	}
	return attach_auth_from_token(token, allocator)
}

attach_auth_from_file :: proc(path: string, allocator := context.allocator) -> (auth: Attach_Auth, ok: bool) {
	raw, read_err := os.read_entire_file_from_path(path, allocator)
	if read_err != nil {
		return {}, false
	}
	token := strings.trim_space(string(raw))
	if token == "" {
		return {}, false
	}
	return attach_auth_from_token(token, allocator)
}

attach_auth_resolve :: proc(token_file: string, has_token_file: bool, allocator := context.allocator) -> (auth: Attach_Auth, ok: bool) {
	if has_token_file {
		return attach_auth_from_file(token_file, allocator)
	}
	return attach_auth_from_env(allocator)
}

attach_auth_decide :: proc(auth: Attach_Auth, presented: string) -> bool {
	if auth.check == nil {
		return false
	}
	return auth.check(auth.expected, presented)
}

parse_attach_auth_line :: proc(line: string, allocator := context.allocator) -> (token: string, ok: bool) {
	parsed, parse_err := json.parse(transmute([]u8)line, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return "", false
	}
	object, is_object := parsed.(json.Object)
	if !is_object {
		return "", false
	}
	if declared, has_version := json_int_field(object, "v"); has_version {
		if declared != INTROSPECT_PROTOCOL_VERSION {
			return "", false
		}
	}
	presented, has_auth := json_string_field(object, "auth")
	if !has_auth {
		return "", false
	}
	return presented, true
}

attach_handshake_response :: proc(ok: bool, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "{{\"v\":%d,\"handshake\":true,\"ok\":%s", INTROSPECT_PROTOCOL_VERSION, ok ? "true" : "false")
	if !ok {
		strings.write_string(&b, ",\"error\":")
		write_json_string(&b, "auth required — connection refused")
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

attach_listen_endpoint :: proc(port: int) -> net.Endpoint {
	return net.Endpoint{address = net.IP4_Loopback, port = port}
}

Line_Transport :: struct {
	userdata: rawptr,
	recv:     proc(userdata: rawptr, buf: []byte) -> (n: int, ok: bool),
	send:     proc(userdata: rawptr, buf: []byte) -> (ok: bool),
}

Line_Reader :: struct {
	transport: Line_Transport,
	pending:   [dynamic]byte,
	closed:    bool,
}

new_line_reader :: proc(transport: Line_Transport, allocator := context.allocator) -> Line_Reader {
	return Line_Reader{transport = transport, pending = make([dynamic]byte, allocator)}
}

reader_next_line :: proc(r: ^Line_Reader, allocator := context.allocator) -> (line: string, ok: bool) {
	for {
		if idx := bytes.index_byte(r.pending[:], '\n'); idx >= 0 {
			line = strings.clone(string(r.pending[:idx]), allocator)
			remaining := len(r.pending) - (idx + 1)
			if remaining > 0 {
				copy(r.pending[:], r.pending[idx + 1:])
			}
			resize(&r.pending, remaining)
			return line, true
		}
		if r.closed {
			return "", false
		}
		chunk: [4096]byte
		n, recv_ok := r.transport.recv(r.transport.userdata, chunk[:])
		if !recv_ok || n == 0 {
			r.closed = true
			continue
		}
		append(&r.pending, ..chunk[:n])
	}
}

serve_attach_connection :: proc(s: ^Debug_Session, auth: Attach_Auth, transport: Line_Transport, allocator := context.allocator) {
	reader := new_line_reader(transport, allocator)
	defer delete(reader.pending)

	if !attach_connection_authed(&reader, auth, allocator) {
		transport_send_line(transport, attach_handshake_response(false, allocator), allocator)
		return
	}
	transport_send_line(transport, attach_handshake_response(true, allocator), allocator)

	for {
		line, have_request := reader_next_line(&reader, allocator)
		if !have_request {
			return
		}
		response := session_request(s, line, allocator)
		if !transport_send_line(transport, response, allocator) {
			return
		}
	}
}

attach_connection_authed :: proc(r: ^Line_Reader, auth: Attach_Auth, allocator := context.allocator) -> bool {
	line, have_line := reader_next_line(r, allocator)
	if !have_line {
		return false
	}
	presented, parsed := parse_attach_auth_line(line, allocator)
	if !parsed {
		return false
	}
	return attach_auth_decide(auth, presented)
}

transport_send_line :: proc(transport: Line_Transport, line: string, allocator := context.allocator) -> bool {
	framed := strings.concatenate({line, "\n"}, allocator)
	return transport.send(transport.userdata, transmute([]byte)framed)
}

ATTACH_FRESH_TICKS :: 64

ATTACH_EPHEMERAL_PORT :: 0

Attach_Args :: struct {
	artifact:        string,
	replay_log:      string,
	has_replay:      bool,
	port:            int,
	port_file:       string,
	has_port_file:   bool,
	token_file:      string,
	has_token_file:  bool,
	seed:            i64,
	has_seed:        bool,
}

parse_attach_args :: proc(args: []string) -> (parsed: Attach_Args, ok: bool) {
	result := Attach_Args{port = ATTACH_DEFAULT_PORT}
	positionals := 0
	i := 2
	for i < len(args) {
		arg := args[i]
		switch {
		case arg == "--port":
			if i + 1 >= len(args) {
				return {}, false
			}
			port, port_ok := strconv.parse_int(args[i + 1])
			if !port_ok || port < 0 || port > 65535 {
				return {}, false
			}
			result.port = port
			i += 2
		case strings.has_prefix(arg, "--port="):
			port, port_ok := strconv.parse_int(arg[len("--port="):])
			if !port_ok || port < 0 || port > 65535 {
				return {}, false
			}
			result.port = port
			i += 1
		case arg == "--port-file":
			if i + 1 >= len(args) || args[i + 1] == "" {
				return {}, false
			}
			result.port_file = args[i + 1]
			result.has_port_file = true
			i += 2
		case strings.has_prefix(arg, "--port-file="):
			value := arg[len("--port-file="):]
			if value == "" {
				return {}, false
			}
			result.port_file = value
			result.has_port_file = true
			i += 1
		case arg == "--token-file":
			if i + 1 >= len(args) || args[i + 1] == "" {
				return {}, false
			}
			result.token_file = args[i + 1]
			result.has_token_file = true
			i += 2
		case strings.has_prefix(arg, "--token-file="):
			value := arg[len("--token-file="):]
			if value == "" {
				return {}, false
			}
			result.token_file = value
			result.has_token_file = true
			i += 1
		case arg == "--seed":
			if i + 1 >= len(args) {
				return {}, false
			}
			seed, seed_ok := strconv.parse_i64(args[i + 1])
			if !seed_ok {
				return {}, false
			}
			result.seed = seed
			result.has_seed = true
			i += 2
		case strings.has_prefix(arg, "--seed="):
			seed, seed_ok := strconv.parse_i64(arg[len("--seed="):])
			if !seed_ok {
				return {}, false
			}
			result.seed = seed
			result.has_seed = true
			i += 1
		case strings.has_prefix(arg, "--"):
			return {}, false
		case positionals == 0:
			result.artifact = arg
			positionals += 1
			i += 1
		case positionals == 1:
			result.replay_log = arg
			result.has_replay = true
			positionals += 1
			i += 1
		case:
			return {}, false
		}
	}
	if positionals == 0 {
		return {}, false
	}
	return result, true
}

attach_port_file_contents :: proc(port: int, allocator := context.allocator) -> string {
	return fmt.aprintf("%d\n", port, allocator = allocator)
}

Open_Session_Result :: enum {
	Ok,
	Artifact_Read_Failed,
	Artifact_Malformed,
	Replay_Read_Failed,
	Replay_Malformed,
	Replay_Identity_Mismatch,
	Session_Alloc_Failed,
}

open_session_for_artifact :: proc(
	artifact_path: string,
	replay_log: string,
	has_replay: bool,
	allocator := context.allocator,
	seed_override: Maybe(i64) = nil,
	fresh_ticks: int = ATTACH_FRESH_TICKS,
) -> (
	session: Debug_Session,
	program: ^Program,
	result: Open_Session_Result,
) {
	artifact_bytes, read_err := os.read_entire_file_from_path(artifact_path, allocator)
	if read_err != nil {
		return {}, nil, .Artifact_Read_Failed
	}
	program = new(Program, allocator)
	loaded, load_err := load_program(string(artifact_bytes), allocator)
	if load_err != .None {
		return {}, nil, .Artifact_Malformed
	}
	program^ = loaded

	snapshots: []Input
	run_seed := NO_SEED
	if has_replay {
		log, log_ok, io_ok := read_replay_file(replay_log, allocator)
		if !io_ok {
			return {}, nil, .Replay_Read_Failed
		}
		if !log_ok {
			return {}, nil, .Replay_Malformed
		}
		if log.identity.has_seed {
			run_seed = seeded_run(log.identity.seed)
		}
		loaded_identity :=
			log.identity.has_seed ? identity_from_program_seeded(program^, string(artifact_bytes), log.identity.seed) : identity_from_program(program^, string(artifact_bytes))
		if log.identity != loaded_identity {
			return {}, nil, .Replay_Identity_Mismatch
		}
		snapshots = log.snapshots
	} else {
		fresh := make([]Input, fresh_ticks, allocator)
		for i in 0 ..< fresh_ticks {
			fresh[i] = empty()
		}
		snapshots = fresh
		if program_uses_rng(program) {
			run_seed = seeded_run(resolve_root_seed(seed_override, program.entrypoint))
		}
	}

	session = open_debug_session(program, snapshots, run_seed, allocator)
	return session, program, .Ok
}

when #config(FUNPACK_LIVE, false) {

	run_attach_server :: proc(
		s: ^Debug_Session,
		auth: Attach_Auth,
		port: int = ATTACH_DEFAULT_PORT,
		port_file: string = "",
		has_port_file: bool = false,
	) -> int {
		endpoint := attach_listen_endpoint(port)
		listener, listen_err := net.listen_tcp(endpoint)
		if listen_err != nil {
			fmt.eprintfln("error: remote attach failed to bind 127.0.0.1:%d (%v)", port, listen_err)
			return 1
		}
		defer net.close(listener)

		bound, bound_err := net.bound_endpoint(listener)
		if bound_err != nil {
			fmt.eprintfln("error: remote attach could not read the bound port (%v)", bound_err)
			return 1
		}
		actual_port := bound.port

		if has_port_file {
			contents := attach_port_file_contents(actual_port, context.temp_allocator)
			if write_err := os.write_entire_file_from_string(port_file, contents); write_err != nil {
				fmt.eprintfln("error: remote attach could not write port file %s (%v)", port_file, write_err)
				return 1
			}
		}
		fmt.printfln("remote attach listening on 127.0.0.1:%d (auth required)", actual_port)

		for {
			client, _, accept_err := net.accept_tcp(listener)
			if accept_err != nil {
				continue
			}
			transport := attach_socket_transport(client)
			serve_attach_connection(s, auth, transport)
			free(transport.userdata)
			net.close(client)
		}
	}

	run_attach_session :: proc(args: []string) -> int {
		parsed, args_ok := parse_attach_args(args)
		if !args_ok {
			fmt.eprintln(
				"usage: funpack attach <artifact-path> [recorded.replay] [--port N] [--port-file P] [--token-file T]",
			)
			return 2
		}

		auth, auth_ok := attach_auth_resolve(parsed.token_file, parsed.has_token_file)
		if !auth_ok {
			if parsed.has_token_file {
				fmt.eprintfln(
					"error: remote attach requires a non-empty token in %s (the auth-required floor)",
					parsed.token_file,
				)
			} else {
				fmt.eprintfln(
					"error: remote attach requires %s (the auth-required floor) — set a shared token or pass --token-file",
					ATTACH_AUTH_ENV,
				)
			}
			return 1
		}

		seed_override: Maybe(i64)
		if parsed.has_seed {
			seed_override = parsed.seed
		}
		session, _, result := open_session_for_artifact(
			parsed.artifact,
			parsed.replay_log,
			parsed.has_replay,
			seed_override = seed_override,
		)
		switch result {
		case .Ok:
		case .Artifact_Read_Failed:
			fmt.eprintfln("error: cannot read artifact %s", parsed.artifact)
			return 1
		case .Artifact_Malformed:
			fmt.eprintfln("error: malformed artifact %s", parsed.artifact)
			return 1
		case .Replay_Read_Failed:
			fmt.eprintfln("error: cannot read replay log %s", parsed.replay_log)
			return 1
		case .Replay_Malformed:
			fmt.eprintfln("error: malformed replay log %s", parsed.replay_log)
			return 1
		case .Replay_Identity_Mismatch:
			fmt.eprintfln(
				"error: replay log %s does not match artifact %s (different build or seed)",
				parsed.replay_log,
				parsed.artifact,
			)
			return 1
		case .Session_Alloc_Failed:
			fmt.eprintfln("error: could not allocate the session for artifact %s", parsed.artifact)
			return 1
		}

		return run_attach_server(&session, auth, parsed.port, parsed.port_file, parsed.has_port_file)
	}

	attach_socket_transport :: proc(socket: net.TCP_Socket) -> Line_Transport {
		boxed := new(net.TCP_Socket)
		boxed^ = socket
		return Line_Transport {
			userdata = boxed,
			recv = proc(userdata: rawptr, buf: []byte) -> (n: int, ok: bool) {
				socket := (^net.TCP_Socket)(userdata)^
				read, recv_err := net.recv_tcp(socket, buf)
				if recv_err != nil {
					return 0, false
				}
				return read, true
			},
			send = proc(userdata: rawptr, buf: []byte) -> (ok: bool) {
				socket := (^net.TCP_Socket)(userdata)^
				written, send_err := net.send_tcp(socket, buf)
				if send_err != nil {
					return false
				}
				return written == len(buf)
			},
		}
	}
} else {
	run_attach_session :: proc(args: []string) -> int {
		_ = args
		fmt.eprintln(
			"funpack: this build has no attach runtime (compiled without FUNPACK_LIVE); rebuild with -define:FUNPACK_LIVE=true",
		)
		return 2
	}
}
