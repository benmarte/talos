#!/usr/bin/env bash
# Regression tests for pipeline-config.sh — key lookup, defaults, type coercion.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"

# JSON config works without PyYAML, so it is the baseline format for tests.
cat > talos.pipeline.json <<'EOF'
{
  "merge": {"method": "rebase"},
  "board": {"enabled": true, "project_number": 7},
  "notifications": {"slack_channel": "C0TEST", "events": ["merged", "blocked"]},
  "roles": {"qa": false}
}
EOF

assert_eq "rebase"  "$(bash "$CFG_SH" merge.method squash)"          "nested key lookup"
assert_eq "true"    "$(bash "$CFG_SH" board.enabled false)"          "bool normalised to lowercase string"
assert_eq "false"   "$(bash "$CFG_SH" roles.qa true)"                "false bool wins over default"
assert_eq "7"       "$(bash "$CFG_SH" board.project_number "")"      "numeric value"
assert_eq "C0TEST"  "$(bash "$CFG_SH" notifications.slack_channel)"  "string value, no default arg"
assert_eq "$(printf 'merged\nblocked')" "$(bash "$CFG_SH" notifications.events "")" \
  "list returned newline-separated"
assert_eq "fallback" "$(bash "$CFG_SH" no.such.key fallback)"        "missing key returns default"
assert_eq ""        "$(bash "$CFG_SH" no.such.key)"                  "missing key, no default → empty"

# PIPELINE_CONFIG env var takes priority over local files
mkdir -p elsewhere
cat > elsewhere/other.json <<'EOF'
{"merge": {"method": "merge"}}
EOF
assert_eq "merge" "$(PIPELINE_CONFIG="$SANDBOX/elsewhere/other.json" bash "$CFG_SH" merge.method squash)" \
  "PIPELINE_CONFIG env var overrides local config"

# No config anywhere → default
rm talos.pipeline.json
assert_eq "squash" "$(bash "$CFG_SH" merge.method squash)" "no config file returns default"

# Corrupt config never crashes
echo "{ not json" > talos.pipeline.json
assert_eq "safe" "$(bash "$CFG_SH" merge.method safe)" "corrupt config returns default"
rm talos.pipeline.json

# YAML path (only when PyYAML is available — matches script behaviour)
if python3 -c "import yaml" 2>/dev/null; then
  cat > talos.pipeline.yml <<'EOF'
merge:
  method: rebase
verify:
  - npm test
  - npm run lint
EOF
  assert_eq "rebase" "$(bash "$CFG_SH" merge.method squash)" "yaml nested key"
  assert_eq "$(printf 'npm test\nnpm run lint')" "$(bash "$CFG_SH" verify "")" "yaml list"
  rm talos.pipeline.yml
else
  echo "  skip: PyYAML not installed — yaml cases skipped"
fi

# Legacy config names still honored; talos.* wins when both exist
cat > .claude-pipeline.json <<'EOF'
{"merge": {"method": "merge"}}
EOF
assert_eq "merge" "$(bash "$CFG_SH" merge.method squash)" "legacy .claude-pipeline.json still read"
cat > talos.pipeline.json <<'EOF'
{"merge": {"required_checks": ["test"]}}
EOF
assert_eq "ci" "$(bash "$CFG_SH" verify.qa_mode local)" \
  "verify.qa_mode defaults to ci when merge.required_checks is non-empty (#195)"

cat > talos.pipeline.json <<'EOF'
{"merge": {"required_checks": []}}
EOF
assert_eq "local" "$(bash "$CFG_SH" verify.qa_mode local)" \
  "verify.qa_mode defaults to local when merge.required_checks is empty (#195)"

rm talos.pipeline.json
assert_eq "local" "$(bash "$CFG_SH" verify.qa_mode local)" \
  "verify.qa_mode defaults to local when no config / merge.required_checks is absent (#195)"

# Fail-closed guard: an explicit verify.qa_mode: ci with an empty
# merge.required_checks list must not pass QA vacuously -- it resolves to
# local instead, with a one-line warning on stderr (#195 review finding 3).
cat > talos.pipeline.json <<'EOF'
{"merge": {"required_checks": []}, "verify": {"qa_mode": "ci"}}
EOF
qa_mode_out="$(bash "$CFG_SH" verify.qa_mode local 2>/tmp/qa_mode_stderr.$$)"
assert_eq "local" "$qa_mode_out" \
  "explicit verify.qa_mode: ci with empty required_checks falls back to local (#195)"
assert_contains "$(cat /tmp/qa_mode_stderr.$$)" "qa_mode=ci" \
  "empty-required_checks fallback prints a stderr warning naming the reason (#195)"
rm -f /tmp/qa_mode_stderr.$$
rm talos.pipeline.json

assert_eq "true" "$(bash "$CFG_SH" verify.targeted true)" \
  "verify.targeted defaults to true when unset (#195)"

cat > talos.pipeline.json <<'EOF'
{
  "merge": {"required_checks": ["test"]},
  "verify": {"commands": ["pytest -q"], "qa_mode": "local", "targeted": false, "ci_wait_s": 60}
}
EOF
assert_eq "local" "$(bash "$CFG_SH" verify.qa_mode ci)" \
  "an explicit verify.qa_mode wins over the required_checks-derived default (#195)"
assert_eq "false" "$(bash "$CFG_SH" verify.targeted true)" \
  "explicit verify.targeted: false overrides the true default (#195)"
assert_eq "60" "$(bash "$CFG_SH" verify.ci_wait_s 900)" \
  "explicit verify.ci_wait_s overrides the 900 default (#195)"
assert_eq "pytest -q" "$(bash "$CFG_SH" verify "")" \
  "verify dict form still returns its commands list for the plain verify key (#195)"
rm talos.pipeline.json

# ── verify.timeout_ms (#205): default, explicit override, non-integer rejection ──
assert_eq "600000" "$(bash "$CFG_SH" verify.timeout_ms 600000)" \
  "verify.timeout_ms defaults to 600000 when absent (#205)"

cat > talos.pipeline.json <<'EOF'
{"verify": {"timeout_ms": 120000}}
EOF
assert_eq "120000" "$(bash "$CFG_SH" verify.timeout_ms 600000)" \
  "explicit verify.timeout_ms overrides the 600000 default (#205)"
rm talos.pipeline.json

cat > talos.pipeline.json <<'EOF'
{"verify": {"timeout_ms": "soon"}}
EOF
assert_eq "600000" "$(bash "$CFG_SH" verify.timeout_ms 600000)" \
  "non-integer verify.timeout_ms falls back to the default (#205)"
timeout_ms_err="$(bash "$CFG_SH" verify.timeout_ms 600000 2>&1 >/dev/null)"
assert_contains "$timeout_ms_err" "must be a positive integer" \
  "non-integer verify.timeout_ms warns on stderr (#205)"
rm talos.pipeline.json

cat > talos.pipeline.json <<'EOF'
{"verify": {"timeout_ms": 0}}
EOF
assert_eq "600000" "$(bash "$CFG_SH" verify.timeout_ms 600000)" \
  "non-positive verify.timeout_ms falls back to the default (#205)"
rm talos.pipeline.json

# ── verify.ci_wait_s (#205 security follow-up): default, explicit override, ──
# non-integer/non-positive rejection -- mirrors verify.timeout_ms exactly,
# because ci_wait_s is interpolated unquoted into a literal agent-executed
# shell test (`[ "$SECONDS" -ge <VERIFY_CI_WAIT_S> ]`).
assert_eq "900" "$(bash "$CFG_SH" verify.ci_wait_s 900)" \
  "verify.ci_wait_s defaults to 900 when absent (#205)"

cat > talos.pipeline.json <<'EOF'
{"verify": {"ci_wait_s": 120}}
EOF
assert_eq "120" "$(bash "$CFG_SH" verify.ci_wait_s 900)" \
  "explicit verify.ci_wait_s overrides the 900 default (#205)"
rm talos.pipeline.json

cat > talos.pipeline.json <<'EOF'
{"verify": {"ci_wait_s": "soon; rm -rf /"}}
EOF
assert_eq "900" "$(bash "$CFG_SH" verify.ci_wait_s 900)" \
  "non-integer verify.ci_wait_s (incl. shell metacharacters) falls back to the default (#205)"
ci_wait_s_err="$(bash "$CFG_SH" verify.ci_wait_s 900 2>&1 >/dev/null)"
assert_contains "$ci_wait_s_err" "must be a positive integer" \
  "non-integer verify.ci_wait_s warns on stderr (#205)"
rm talos.pipeline.json

cat > talos.pipeline.json <<'EOF'
{"verify": {"ci_wait_s": 0}}
EOF
assert_eq "900" "$(bash "$CFG_SH" verify.ci_wait_s 900)" \
  "non-positive verify.ci_wait_s falls back to the default (#205)"
rm talos.pipeline.json

cat > talos.pipeline.json <<'EOF'
{"merge": {"method": "rebase"}}
EOF
assert_eq "rebase" "$(bash "$CFG_SH" merge.method squash)" "talos.pipeline.json wins over legacy"
rm .claude-pipeline.json talos.pipeline.json

# roles.docs_mode (#200): default resolution — auto unless explicitly set
assert_eq "auto" "$(bash "$CFG_SH" roles.docs_mode auto)" \
  "roles.docs_mode: no config file returns the caller-supplied 'auto' default (#200)"

cat > talos.pipeline.json <<'EOF'
{"roles": {"docs_mode": "always"}}
EOF
assert_eq "always" "$(bash "$CFG_SH" roles.docs_mode auto)" \
  "roles.docs_mode: explicit 'always' overrides the 'auto' default (#200)"
rm talos.pipeline.json

cat > talos.pipeline.json <<'EOF'
{"roles": {"docs": true}}
EOF
assert_eq "auto" "$(bash "$CFG_SH" roles.docs_mode auto)" \
  "roles.docs_mode: absent key falls back to the caller default even with sibling roles.* keys set (#200)"
rm talos.pipeline.json

# ── --dump / single-key parity (#169 invariant, #212 review follow-up) ──────
# The header comment on --dump promises "a lookup against this dump is
# byte-identical to calling this script for that key directly". _dump_get
# parses --dump's NUL-delimited output the same way pipeline-cfg-cache.sh's
# cfg() does; a key absent from the dump means "apply the caller's own
# default", exactly like a missing key on the single-key path.
_dump_get() {
  local _key="$1" _dump_file="$2" _k _v
  while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do
    if [ "$_k" = "$_key" ]; then
      printf '%s' "$_v"
      return 0
    fi
  done < "$_dump_file"
  return 1
}

# Baseline parity: a valid config with several already-covered special
# cases (verify dict-form, verify.qa_mode, plain scalars) -- --dump's output
# for each key equals the single-key lookup for that key, unchanged by this
# PR.
cat > talos.pipeline.json <<'EOF'
{
  "merge": {"method": "rebase", "required_checks": ["test"]},
  "board": {"enabled": true, "project_number": 7},
  "verify": {"commands": ["pytest -q"], "qa_mode": "local", "ci_wait_s": 120, "timeout_ms": 120000}
}
EOF
dump_baseline="$SANDBOX/dump-baseline"
bash "$CFG_SH" --dump > "$dump_baseline" 2>/dev/null
for k in merge.method board.enabled board.project_number verify verify.qa_mode \
         verify.ci_wait_s verify.timeout_ms; do
  single="$(bash "$CFG_SH" "$k" "")"
  dumped="$(_dump_get "$k" "$dump_baseline")" || dumped=""
  assert_eq "$single" "$dumped" \
    "--dump matches single-key lookup for $k on a valid config (#169 parity)"
done
rm talos.pipeline.json

# Injection parity: verify.ci_wait_s carrying shell metacharacters and
# verify.timeout_ms carrying a non-positive value must resolve to their
# defaults -- and warn on stderr -- identically on both paths. Before this
# fix, --dump (what cfg() actually reads) returned the raw unvalidated
# value with no warning, reopening the injection surface the single-key
# path closed.
cat > talos.pipeline.json <<'EOF'
{"verify": {"ci_wait_s": "; rm -rf /", "timeout_ms": -5}}
EOF

single_ci_wait_s="$(bash "$CFG_SH" verify.ci_wait_s 900)"
assert_eq "900" "$single_ci_wait_s" \
  "single-key verify.ci_wait_s falls back to the default for an injection payload (#212)"
single_ci_wait_s_err="$(bash "$CFG_SH" verify.ci_wait_s 900 2>&1 >/dev/null)"
assert_contains "$single_ci_wait_s_err" "must be a positive integer" \
  "single-key verify.ci_wait_s warns on stderr for an injection payload (#212)"

single_timeout_ms="$(bash "$CFG_SH" verify.timeout_ms 600000)"
assert_eq "600000" "$single_timeout_ms" \
  "single-key verify.timeout_ms falls back to the default for a non-positive value (#212)"
single_timeout_ms_err="$(bash "$CFG_SH" verify.timeout_ms 600000 2>&1 >/dev/null)"
assert_contains "$single_timeout_ms_err" "must be a positive integer" \
  "single-key verify.timeout_ms warns on stderr for a non-positive value (#212)"

dump_injection="$SANDBOX/dump-injection"
dump_injection_err="$SANDBOX/dump-injection.stderr"
bash "$CFG_SH" --dump > "$dump_injection" 2>"$dump_injection_err"

dump_ci_wait_s="$(_dump_get verify.ci_wait_s "$dump_injection")" || dump_ci_wait_s="900"
assert_eq "900" "$dump_ci_wait_s" \
  "--dump verify.ci_wait_s falls back to the default for an injection payload, same as the single-key path (#212)"

dump_timeout_ms="$(_dump_get verify.timeout_ms "$dump_injection")" || dump_timeout_ms="600000"
assert_eq "600000" "$dump_timeout_ms" \
  "--dump verify.timeout_ms falls back to the default for a non-positive value, same as the single-key path (#212)"

assert_contains "$(cat "$dump_injection_err")" "verify.ci_wait_s must be a positive integer" \
  "--dump warns on stderr for verify.ci_wait_s, same as the single-key path (#212)"
assert_contains "$(cat "$dump_injection_err")" "verify.timeout_ms must be a positive integer" \
  "--dump warns on stderr for verify.timeout_ms, same as the single-key path (#212)"
rm talos.pipeline.json

finish
