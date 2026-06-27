package funpack_runtime

Render_Check_Report :: struct {
	ticks:             int,
	drew:              bool,
	first_drawn_frame: int,
	total_cmds:        int,
	seeded:            bool,
	has_render_stage:  bool,
}

NO_DRAWN_FRAME :: -2

RENDER_CHECK_DEFAULT_TICKS :: ATTACH_FRESH_TICKS

render_check_session :: proc(s: ^Debug_Session, allocator := context.allocator) -> Render_Check_Report {
	tick_hz := s.program.entrypoint.tick_hz
	report := Render_Check_Report {
		ticks             = len(s.versions),
		first_drawn_frame = NO_DRAWN_FRAME,
		seeded            = s.seed.has_seed,
		has_render_stage  = program_has_render_stage(s.program),
	}

	startup_time := time_resource_at(tick_hz, 0, allocator)
	render_check_accumulate(s, s.startup, empty(), startup_time, -1, &report, allocator)

	for version, i in s.versions {
		time := time_resource_at(tick_hz, i, allocator)
		render_check_accumulate(s, version, s.snapshots[i], time, i, &report, allocator)
	}
	return report
}

program_has_render_stage :: proc(program: ^Program) -> bool {
	for step in program.pipeline {
		if step.stage == "render" {
			return true
		}
	}
	return false
}

@(private = "file")
render_check_accumulate :: proc(
	s: ^Debug_Session,
	version: World_Version,
	input: Input,
	time: Record_Value,
	frame: int,
	report: ^Render_Check_Report,
	allocator := context.allocator,
) {
	draw := render_version(s.program, version, input, time, allocator)
	if len(draw.cmds) == 0 {
		return
	}
	report.total_cmds += len(draw.cmds)
	if !report.drew {
		report.drew = true
		report.first_drawn_frame = frame
	}
}

render_check_artifact :: proc(
	artifact_path: string,
	ticks: int,
	seed_override: Maybe(i64) = nil,
	allocator := context.allocator,
) -> (
	report: Render_Check_Report,
	result: Open_Session_Result,
) {
	session, _, open_result := open_session_for_artifact(
		artifact_path,
		"",
		false,
		allocator,
		seed_override,
		ticks,
	)
	if open_result != .Ok {
		return Render_Check_Report{ticks = ticks, first_drawn_frame = NO_DRAWN_FRAME}, open_result
	}
	return render_check_session(&session, allocator), .Ok
}
