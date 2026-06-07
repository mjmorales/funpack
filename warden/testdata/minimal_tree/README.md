# minimal_tree — synthetic §14 project-tree fixture

A minimal funpack §14 project tree (`funpack_configs/` + `src/` siblings of the
derived, gitignored `.funpack/`) used to exercise warden's spawn seam without a
real funpack-spec checkout.

The invocation tests point a **stub** funpack binary at this directory via the
`FUNPACK_BIN` override and assert that warden set the subprocess working
directory here (so funpack's `.` root resolution and `.funpack/` outputs would
land in this tree) and captured the stub's stdout/stderr/exit code. The stub
does not parse these files, so the config and source contents are
shape-representative, not a tested compilation input — a later story that drives
the real binary owns grammar fidelity.
