---
description: Run the funpack game's `test` blocks and interpret the results.
argument-hint: "[extra funpack args]"
---

Run the funpack project's tests and read the results. funpack tests are top-level `test "…" { assert
… }` declarations that call behaviors directly with deterministic fixtures — see `funpack-game-model`.

1. Run `funpack test` (passing through any `$ARGUMENTS`) from the project root.
2. Read the **exit code** as the contract: **0** = all pass; **1** = one or more `assert`s failed;
   **2** = a compile/gate error (not a test failure — fix the build first, e.g. via `/funpack:build
   --check`).
3. On a failed assert, inspect the failing `test` block. Because every behavior is a pure function,
   reproduce the case by reading `name.step(args)` and the expected value: decide whether the **test**
   or the **behavior** is wrong, then fix the smaller, clearly-correct side.
4. If the surface is under-tested, propose new `test` blocks: a behavior is testable by feeding
   constructed fixtures (`View.of([…])`, `Input.empty().with_value(…)`, `Time.at(dt)`) and asserting
   the exact returned blackboard / signal list / command list (renderers included). Keep each test
   self-contained.
5. Report pass/fail counts and any fix applied.

If no funpack toolchain is on PATH, say so and instead reason through the asserts statically against
the source — do not fabricate a test runner's output.
