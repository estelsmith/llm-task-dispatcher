I want to test the task dispatching workflow end to end, including the retry loop.

**Work:**

Under the project-local `testing/` directory, create a bash script that performs some simple math and prints exactly
these three lines to the terminal:

```
2 + 3 = 5
6 * 7 = 42
10 / 4 = 2.5
```

Then, create another test verification bash script that calls the first script and verifies its output against the
expected lines above, almost like a unit test.

**Research (for the planning agent):**

Bash arithmetic is integer-only, so `10 / 4 = 2.5` needs another approach. Compare at least two options (for example
`bc`, `awk`, or something else available on a stock macOS/Linux system) for portability, dependencies and output
formatting. Pick one for the plan, and report the comparison as research notes so it is kept for later reference.

**Intentional failure (for the implementation agent):**

- On implementation attempt 1, deliberately make the math script produce wrong output so that the test script fails.
  Do NOT fix it on this attempt, even though the test fails. Report back normally and mention the deliberate bug in
  your notes.
- On attempt 2 (the first retry), correct the math script so the test passes.

**Note for the verification agent (not an acceptance criterion):**

The intentional failure only exists to exercise the retry loop. Always judge the work against the correct final output
above, so a failing test on attempt 1 should get a `FAIL` verdict.
