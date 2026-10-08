#!/usr/bin/env bash
# test-hooks-model-attribution.sh -- the model post_stage records (#379, part
# of #334). Covers:
#   (a) --model M wins over every config key, for any verdict
#   (b) no --model and a RESTAMP_PASS/RESTAMP_FAIL verdict: role restamp_model
#       -> agents.restamp_model -> role model -> agents.model, one fixture per
#       link (including a role with no agents.roles block, and a role with a
#       model but no restamp keys under a global agents.model)
#   (c) no --model and any other verdict: the chain is unchanged
#   (d) --model sanitizing: control characters stripped, capped at 100 chars,
#       empty (after sanitizing) falls back to the chain
#   (e) payload key order is unchanged, post_stage exits 0 and prints nothing
#   (f) the usage text documents --model in all three places
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
CAPTURE="$SANDBOX/hook-stdin.json"

# write_cfg <agents-json> -- talos.pipeline.json whose post_stage hook captures
# the stdin payload into $CAPTURE. The events log lands in the sandbox repo.
write_cfg() {
  cat > talos.pipeline.json <<EOF
{"agents": $1, "hooks": {"post_stage": "cat > $CAPTURE", "timeout_s": 5}}
EOF
}

# payload_field <key> -- the JSON value of <key> in the captured payload.
payload_field() {
  python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2])))" "$CAPTURE" "$1"
}

# model_of <post_stage flags...> -- runs post_stage for role qa, prints the
# recorded model as JSON.
model_of() {
  : > "$CAPTURE"
  bash "$HOOKS" post_stage stage_complete qa 42 "$@" >/dev/null 2>&1
  payload_field model
}

# ── (a) --model wins regardless of config ─────────────────────────────────────
write_cfg '{"model": "cfg-global", "restamp_model": "cfg-restamp", "roles": {"qa": {"model": "cfg-role", "restamp_model": "cfg-role-restamp"}}}'
assert_eq '"opus"' "$(model_of --verdict PASS --model opus)" "--model beats config on a PASS verdict"
assert_eq '"opus"' "$(model_of --verdict RESTAMP_PASS --model opus)" "--model beats the restamp chain on RESTAMP_PASS"
assert_eq '"opus"' "$(model_of --verdict RESTAMP_FAIL --model opus)" "--model beats the restamp chain on RESTAMP_FAIL"
assert_eq '"opus"' "$(model_of --model opus)" "--model works with no verdict at all"
write_cfg '{}'
assert_eq '"opus"' "$(model_of --verdict PASS --model opus)" "--model records even when config names no model"
assert_eq 'null' "$(model_of --verdict PASS)" "no --model and no config: null (session default), never a guess"

# ── (b) re-stamp chain, one fixture per link ──────────────────────────────────
write_cfg '{"model": "g-model", "restamp_model": "g-restamp", "roles": {"qa": {"model": "r-model", "restamp_model": "r-restamp"}}}'
assert_eq '"r-restamp"' "$(model_of --verdict RESTAMP_PASS)" "RESTAMP_PASS: role restamp_model first"
assert_eq '"r-restamp"' "$(model_of --verdict RESTAMP_FAIL)" "RESTAMP_FAIL: role restamp_model first"

write_cfg '{"model": "g-model", "restamp_model": "g-restamp", "roles": {"qa": {"model": "r-model"}}}'
assert_eq '"g-restamp"' "$(model_of --verdict RESTAMP_PASS)" "RESTAMP_PASS: global restamp_model when the role has none"

write_cfg '{"model": "g-model", "restamp_model": "g-restamp", "roles": {"dev": {"model": "d-model"}}}'
assert_eq '"g-restamp"' "$(model_of --verdict RESTAMP_PASS)" "RESTAMP_PASS: role absent from agents.roles still reaches agents.restamp_model"

write_cfg '{"roles": {"qa": {"model": "r-model"}}}'
assert_eq '"r-model"' "$(model_of --verdict RESTAMP_PASS)" "RESTAMP_PASS: role model when no restamp key and no agents.model"

write_cfg '{"model": "g-model", "roles": {"dev": {"model": "d-model"}}}'
assert_eq '"g-model"' "$(model_of --verdict RESTAMP_PASS)" "RESTAMP_PASS: agents.model last"

# Role model haiku + global sonnet + no restamp keys: the orchestrator spawns
# sonnet on a re-stamp (config folds agents.model into the restamp keys), so
# that is what is recorded -- not the role's own model.
write_cfg '{"model": "sonnet", "roles": {"qa": {"model": "haiku"}}}'
assert_eq '"sonnet"' "$(model_of --verdict RESTAMP_PASS)" "RESTAMP_PASS: role model haiku + global sonnet resolves to sonnet"
assert_eq '"haiku"' "$(model_of --verdict PASS)" "PASS: the same config still records the role model haiku"

write_cfg '{}'
assert_eq 'null' "$(model_of --verdict RESTAMP_PASS)" "RESTAMP_PASS: nothing configured is null"

# ── (c) any other verdict: chain unchanged, restamp keys ignored ──────────────
write_cfg '{"model": "g-model", "restamp_model": "g-restamp", "roles": {"qa": {"model": "r-model", "restamp_model": "r-restamp"}}}'
assert_eq '"r-model"' "$(model_of --verdict PASS)" "PASS: role model, restamp keys ignored"
assert_eq '"r-model"' "$(model_of --verdict FAIL)" "FAIL: role model, restamp keys ignored"
assert_eq '"r-model"' "$(model_of)" "no verdict: role model"
assert_eq '"r-model"' "$(model_of --verdict RESTAMP_PASS_EXTRA)" "verdict match is exact: RESTAMP_PASS_EXTRA is not a re-stamp"
write_cfg '{"model": "g-model", "restamp_model": "g-restamp"}'
assert_eq '"g-model"' "$(model_of --verdict PASS)" "PASS: agents.model when the role has no model"

# ── (d) --model sanitizing ────────────────────────────────────────────────────
write_cfg '{"model": "g-model", "roles": {"qa": {"model": "r-model"}}}'
assert_eq '"ab"' "$(model_of --verdict PASS --model "$(printf 'a\nb')")" "--model: newline stripped"
assert_eq '"abcd"' "$(model_of --verdict PASS --model "$(printf 'a\tb\033c\177d')")" "--model: tab, ESC and DEL stripped"
assert_eq '"r-model"' "$(model_of --verdict PASS --model "")" "--model empty: falls back to the chain"
assert_eq '"r-model"' "$(model_of --verdict PASS --model "$(printf '\n\t\033\177')")" "--model only control characters: falls back to the chain"
assert_eq '"g-model"' "$(model_of --verdict RESTAMP_PASS --model "")" "--model empty on RESTAMP_PASS: falls back to the restamp chain"

X98="$(printf 'x%.0s' $(seq 1 98))"
X100="$(printf 'x%.0s' $(seq 1 100))"
X150="$(printf 'x%.0s' $(seq 1 150))"
assert_eq "\"$X100\"" "$(model_of --verdict PASS --model "$X150")" "--model: capped at 100 chars"
assert_eq "\"$X100\"" "$(model_of --verdict PASS --model "$X100")" "--model: exactly 100 chars kept whole"
# Control characters are stripped before the cap, so they do not eat into it.
assert_eq "\"${X98}yy\"" "$(model_of --verdict PASS --model "$(printf '%s\n\n\t\033yyyyy' "$X98")")" "--model: control characters stripped before the 100-char cap"

# A value outside [A-Za-z0-9._:-]+ is dropped with one stderr line and the hook
# still fires (the chain answers instead) (#450).
: > "$CAPTURE"
bash "$HOOKS" post_stage stage_complete qa 42 --verdict PASS --model 'bad model;x' >/dev/null 2>"$SANDBOX/err.log"; rc=$?
assert_eq "0" "$rc" "--model with a bad character: exits 0"
assert_eq '"r-model"' "$(payload_field model)" "--model with a bad character: dropped, the hook still fires with the chain's model"
assert_eq "1" "$(grep -c . "$SANDBOX/err.log")" "--model with a bad character: exactly one stderr line"
assert_contains "$(cat "$SANDBOX/err.log")" "--model" "--model with a bad character: the line names --model"
assert_eq '"claude-opus-4.5:beta_1"' "$(model_of --verdict PASS --model 'claude-opus-4.5:beta_1')" "--model: letters digits . _ : - are kept"
assert_eq '"r-model"' "$(model_of --verdict PASS --model 'a b')" "--model: a space is outside the charset"
assert_eq '"r-model"' "$(model_of --verdict PASS --model 'a/b')" "--model: a slash is outside the charset"

# ── (e) payload shape: key order, exit code, stdout ───────────────────────────
KEYS='["event", "role", "issue", "pr", "repo", "sha", "verdict", "summary", "details", "attempt", "model", "runner", "duration_s", "tokens", "tool_uses", "ts"]'
KEYS_CI='["event", "role", "issue", "pr", "repo", "sha", "verdict", "summary", "details", "attempt", "model", "runner", "duration_s", "tokens", "tool_uses", "ci_runs", "ts"]'
keys_of() { python3 -c "import json,sys; print(json.dumps(list(json.load(open(sys.argv[1])).keys())))" "$CAPTURE"; }

: > "$CAPTURE"
out="$(bash "$HOOKS" post_stage stage_complete qa 42 --verdict PASS 2>"$SANDBOX/err.log")"; rc=$?
assert_eq "$KEYS" "$(keys_of)" "key order unchanged without --model"
assert_eq "0" "$rc" "no --model: exits 0"
assert_eq "" "$out" "no --model: no stdout"
: > "$CAPTURE"
out="$(bash "$HOOKS" post_stage stage_complete qa 42 --verdict RESTAMP_PASS --model opus 2>"$SANDBOX/err.log")"; rc=$?
assert_eq "$KEYS" "$(keys_of)" "key order unchanged with --model"
assert_eq "0" "$rc" "--model: exits 0"
assert_eq "" "$out" "--model: no stdout"
assert_eq "" "$(cat "$SANDBOX/err.log")" "--model: no stderr"
: > "$CAPTURE"
bash "$HOOKS" post_stage stage_complete qa 42 --verdict PASS --model opus --ci-runs 2 >/dev/null 2>&1
assert_eq "$KEYS_CI" "$(keys_of)" "ci_runs still lands between tool_uses and ts with --model"

# --model is accepted anywhere among the flags.
assert_eq '"opus"' "$(model_of --model opus --verdict PASS --pr 5)" "--model before other flags"

# The same value reaches the events log (sandbox repo, never the real one).
rm -f "$SANDBOX/.git/talos/events.jsonl"
bash "$HOOKS" post_stage stage_complete qa 42 --verdict PASS --model opus >/dev/null 2>&1
assert_eq '"opus"' "$(python3 -c "import json; print(json.dumps(json.loads(open('$SANDBOX/.git/talos/events.jsonl').readlines()[-1])['model']))")" "events log line records the --model value"

# A hostile --model value is data, never code.
bash "$HOOKS" post_stage stage_complete qa 42 --verdict PASS --model '$(touch '"$SANDBOX"'/pwned)"; touch '"$SANDBOX"'/pwned2' >/dev/null 2>&1
assert_file_absent "$SANDBOX/pwned" "--model: command substitution is not run"
assert_file_absent "$SANDBOX/pwned2" "--model: embedded quote does not break out"

# ── (f) usage text documents --model in all three places ─────────────────────
assert_contains "$(sed -n '1,25p' "$HOOKS")" "[--model M]" "header comment documents --model"
assert_contains "$(grep -A3 '^# post_stage EVENT' "$HOOKS")" "[--model M]" "function comment documents --model"
usage="$(bash "$HOOKS" bogus 2>&1)"
assert_contains "$usage" "[--model M]" "usage line documents --model"

finish
