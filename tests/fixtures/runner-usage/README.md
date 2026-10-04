# runner-usage fixtures (#420)

Replayed by `tests/test-runner-usage.sh` through the `tests/stubs/claude` stub.

These are NOT captures from a live CLI. They were written from the documented
`claude -p --output-format json` result object (`result`, `usage`, `modelUsage`
with `inputTokens`, `outputTokens`, `cacheReadInputTokens`,
`cacheCreationInputTokens`) with synthetic numbers and a zeroed session id, and
no model CLI was run against an account to make them. Each `*.json` with a
`.txt` twin has what text mode prints for the same run, which is how the tests
prove the stdout is byte-identical. Replace them with a scrubbed real capture
when one is available; a changed field name only turns the parse into `null`.

- `claude-ok.json`: one model; expected tokens 12 + 210 + 2500 = 2722 (14000 cache reads excluded).
- `claude-subagent.json`: two models; expected tokens 2722 + (40 + 100 + 300) = 3162, model `claude-sonnet-4-5`.
- `claude-usage-only.json`: no `modelUsage`; top-level `usage` gives 2722.
- `claude-429.json`: a rate-limit error as the result; usage 5, `is_error` true.
