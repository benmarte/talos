#!/usr/bin/env bash
# Tests for the user-level config layer (#336): ${TALOS_HOME:-$HOME/.talos}/
# talos.pipeline.{yml,yaml,json} is loaded by pipeline-config.sh and the
# project config is deep-merged over it, leaf by leaf. Only the agents.*
# subtree is read from the user-level file; it is untrusted input (parsed as
# data only, never sourced or evaluated).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
AGENT_SH="$TALOS_ROOT/scripts/pipeline-agent.sh"
USER_DIR="$HOME/.talos"
ERR="$SANDBOX/stderr"
OUT="$SANDBOX/out"

reset_cfg() {
  rm -rf "$USER_DIR" "$SANDBOX"/talos.pipeline.* "$SANDBOX/other"
  unset PIPELINE_CONFIG TALOS_HOME
  mkdir -p "$USER_DIR"
}
user_json() { printf '%s' "$1" > "$USER_DIR/talos.pipeline.json"; }
proj_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
get() { bash "$CFG_SH" "$1" "${2:-}" 2>"$ERR"; }
errlines() { wc -l < "$ERR" | tr -d ' '; }
dump() { bash "$CFG_SH" --dump 2>"$ERR" | tr '\0' '\n'; }

# ── AC3: hermetic sandbox (a real ~/.talos can never leak into a run) ────────
case "$HOME" in
  "$SANDBOX"/*) pass "make_sandbox points HOME inside the sandbox" ;;
  *) fail "make_sandbox points HOME inside the sandbox" "HOME=$HOME" ;;
esac
assert_eq "unset" "${TALOS_HOME:-unset}" "make_sandbox unsets TALOS_HOME"

# ── AC1: user-level file only, repo has no config ────────────────────────────
reset_cfg
user_json '{"agents": {"model": "sonnet", "roles": {"security": {"model": "opus"}}}}'
assert_eq "sonnet" "$(get agents.model "")" "AC1: user-level agents.model applies with no project config"
assert_eq "opus" "$(get agents.roles.security.model "")" "AC1: user-level role model applies with no project config"
assert_eq "none" "$(get agents.roles.qa.model none)" "AC1: an unset role still returns the caller default"
assert_contains "$(bash "$AGENT_SH" --resolve security 2>/dev/null)" "model=opus" "AC1: --resolve shows the user-level role model"
assert_contains "$(bash "$AGENT_SH" --resolve qa 2>/dev/null)" "model=sonnet" "AC1: --resolve falls back to user-level agents.model"
assert_contains "$(dump)" "agents.model" "AC1: --dump carries the user-level layer with no project config"

# yml / yaml / json lookup order among user-level extensions (same as project)
reset_cfg
printf 'agents:\n  model: fromyml\n' > "$USER_DIR/talos.pipeline.yml"
printf 'agents:\n  model: fromyaml\n' > "$USER_DIR/talos.pipeline.yaml"
user_json '{"agents": {"model": "fromjson"}}'
assert_eq "fromyml" "$(get agents.model "")" "AC3: user-level .yml wins over .yaml and .json"
rm "$USER_DIR/talos.pipeline.yml"
assert_eq "fromyaml" "$(get agents.model "")" "AC3: user-level .yaml wins over .json"
rm "$USER_DIR/talos.pipeline.yaml"
assert_eq "fromjson" "$(get agents.model "")" "AC3: user-level .json is read"

# ── AC2: project overrides one role, per leaf ────────────────────────────────
reset_cfg
user_json '{"agents": {"model": "sonnet", "effort": "high", "roles": {"security": {"model": "opus"}, "qa": {"model": "sonnet"}}}}'
proj_json '{"agents": {"roles": {"qa": {"model": "haiku"}}}}'
assert_eq "haiku" "$(get agents.roles.qa.model "")" "AC2: project role model overrides the user-level one"
assert_eq "opus" "$(get agents.roles.security.model "")" "AC2: other roles still return the user-level value"
assert_eq "sonnet" "$(get agents.model "")" "AC2: user-level agents.model survives a project agents block"
assert_eq "high" "$(get agents.effort "")" "AC2: merge is per leaf, not per subtree"
proj_json '{"agents": {"model": "haiku"}, "merge": {"method": "squash"}}'
assert_eq "haiku" "$(get agents.model "")" "AC2: project agents.model overrides the user-level one"
assert_eq "squash" "$(get merge.method "")" "AC2: project non-agents keys unaffected"

# ── AC3: $TALOS_HOME and $PIPELINE_CONFIG are both honoured ──────────────────
reset_cfg
mkdir -p "$SANDBOX/alt-home"
printf '%s' '{"agents": {"model": "alt"}}' > "$SANDBOX/alt-home/talos.pipeline.json"
user_json '{"agents": {"model": "home-default"}}'
assert_eq "home-default" "$(get agents.model "")" "AC3: default user-level dir is \$HOME/.talos"
export TALOS_HOME="$SANDBOX/alt-home"
assert_eq "alt" "$(get agents.model "")" "AC3: \$TALOS_HOME selects the user-level directory"
assert_contains "$(dump)" "alt" "AC3: --dump honours \$TALOS_HOME"
unset TALOS_HOME

reset_cfg
mkdir -p "$SANDBOX/other"
printf '%s' '{"agents": {"roles": {"qa": {"model": "haiku"}}}}' > "$SANDBOX/other/custom.json"
user_json '{"agents": {"model": "sonnet", "roles": {"qa": {"model": "opus"}}}}'
proj_json '{"agents": {"roles": {"qa": {"model": "should-not-win"}}}}'
export PIPELINE_CONFIG="$SANDBOX/other/custom.json"
assert_eq "haiku" "$(get agents.roles.qa.model "")" "AC3: \$PIPELINE_CONFIG file overrides the user-level layer"
assert_eq "sonnet" "$(get agents.model "")" "AC3: the user-level layer sits under a \$PIPELINE_CONFIG file"
unset PIPELINE_CONFIG

# ── AC4: non-agents key in the user-level file is ignored, one warning ───────
reset_cfg
user_json '{"agents": {"model": "sonnet"}, "board": {"project_number": 7}}'
assert_eq "none" "$(get board.project_number none)" "AC4: a non-agents key in the user-level file is ignored"
assert_eq "sonnet" "$(get agents.model "")" "AC4: agents.* still applies alongside the ignored key"
assert_eq "1" "$(errlines)" "AC4: exactly one stderr line for one ignored key"
assert_contains "$(cat "$ERR")" "board" "AC4: the warning names the ignored key"
dump >/dev/null
assert_eq "1" "$(errlines)" "AC4: --dump also emits exactly one warning"
assert_not_contains "$(dump)" "board" "AC4: --dump omits the ignored key"

# A hostile key name cannot inject control characters or newlines
reset_cfg
printf '%s' '{"agents": {"model": "sonnet"}, "evil\u001b[31m\nINJECTED": 1}' > "$USER_DIR/talos.pipeline.json"
get agents.model "" >/dev/null
assert_eq "1" "$(errlines)" "AC4: a newline in a key name cannot add stderr lines"
if LC_ALL=C grep -q "$(printf '\033')" "$ERR"; then
  fail "AC4: no raw ESC byte reaches stderr"
else
  pass "AC4: no raw ESC byte reaches stderr"
fi

# ── AC5: untrusted input behaves as absent ───────────────────────────────────
reset_cfg
proj_json '{"agents": {"model": "haiku"}}'
printf '%s' '{not json' > "$USER_DIR/talos.pipeline.json"
bash "$CFG_SH" agents.model "" >"$OUT" 2>"$ERR"; rc=$?
assert_eq "haiku" "$(cat "$OUT")" "AC5: malformed user-level file -> project value returned"
assert_eq "0" "$rc" "AC5: malformed user-level file leaves the exit status unchanged"
assert_eq "1" "$(errlines)" "AC5: malformed user-level file prints exactly one warning"
assert_eq "dflt" "$(get agents.roles.qa.model dflt)" "AC5: unset keys return the caller default"
bash "$CFG_SH" --dump >"$OUT" 2>"$ERR"; rc=$?
assert_eq "0" "$rc" "AC5: --dump exit status unchanged with a malformed user-level file"
assert_eq "1" "$(errlines)" "AC5: --dump prints exactly one warning"

for body in '' '   ' '[1,2]' '"just a string"' '42' '{"agents": [1,2]}' '{"agents": "x"}' 'null'; do
  reset_cfg
  proj_json '{"agents": {"model": "haiku"}}'
  printf '%s' "$body" > "$USER_DIR/talos.pipeline.json"
  bash "$CFG_SH" agents.model "" >"$OUT" 2>"$ERR"; rc=$?
  assert_eq "haiku" "$(cat "$OUT")" "AC5: user-level content '$body' behaves as absent"
  assert_eq "0" "$rc" "AC5: user-level content '$body' leaves exit status 0"
  if [ "$(errlines)" -le 1 ]; then
    pass "AC5: user-level content '$body' warns at most once"
  else
    fail "AC5: user-level content '$body' warns at most once" "$(cat "$ERR")"
  fi
done
reset_cfg
printf '%s' '[1,2]' > "$USER_DIR/talos.pipeline.json"
get agents.model "" >/dev/null
assert_eq "1" "$(errlines)" "AC5: non-mapping top level prints exactly one warning"

# missing / directory / unreadable
reset_cfg
proj_json '{"agents": {"model": "haiku"}}'
rm -rf "$USER_DIR"
assert_eq "haiku" "$(get agents.model "")" "AC5: missing user-level dir behaves as absent"
assert_eq "0" "$(errlines)" "AC5: missing user-level file is silent"
mkdir -p "$USER_DIR/talos.pipeline.json"
assert_eq "haiku" "$(get agents.model "")" "AC5: a directory named like the file behaves as absent"
rm -rf "$USER_DIR"; mkdir -p "$USER_DIR"
user_json '{"agents": {"model": "sonnet"}}'
chmod 000 "$USER_DIR/talos.pipeline.json"
bash "$CFG_SH" agents.model "" >"$OUT" 2>"$ERR"; rc=$?
if [ -r "$USER_DIR/talos.pipeline.json" ]; then
  pass "AC5: unreadable user-level file (skipped: file still readable, running as root)"
else
  assert_eq "haiku" "$(cat "$OUT")" "AC5: unreadable user-level file behaves as absent"
  assert_eq "0" "$rc" "AC5: unreadable user-level file leaves exit status 0"
fi
chmod 644 "$USER_DIR/talos.pipeline.json"

# malformed user-level + no project config: default, still exit 0
reset_cfg
printf '%s' '{oops' > "$USER_DIR/talos.pipeline.json"
bash "$CFG_SH" agents.model fallback >"$OUT" 2>"$ERR"; rc=$?
assert_eq "fallback" "$(cat "$OUT")" "AC5: malformed user-level, no project config -> default"
assert_eq "0" "$rc" "AC5: ... with exit status 0"

# shell metacharacters stay inert (data only; nothing is evaluated)
reset_cfg
user_json '{"agents": {"model": "$(touch '"$SANDBOX"'/PWNED); `touch '"$SANDBOX"'/PWNED2`; x"}}'
out="$(get agents.model "")"
assert_contains "$out" '$(touch ' "AC5: a value with \$(...) comes back verbatim"
assert_contains "$out" '`touch ' "AC5: a value with backticks comes back verbatim"
assert_file_absent "$SANDBOX/PWNED" "AC5: \$(...) in a user-level value is never executed"
assert_file_absent "$SANDBOX/PWNED2" "AC5: backticks in a user-level value are never executed"
assert_contains "$(dump)" '$(touch ' "AC5: --dump carries the metacharacter value inert"
assert_contains "$(bash "$AGENT_SH" --resolve qa 2>/dev/null)" '$(touch ' "AC5: --resolve prints the value as data"
assert_file_absent "$SANDBOX/PWNED" "AC5: --dump/--resolve never execute the value"
# YAML user-level file: unsafe tags are not constructed
reset_cfg
printf 'agents:\n  model: !!python/object/apply:os.system ["touch %s/PWNED3"]\n' "$SANDBOX" > "$USER_DIR/talos.pipeline.yml"
bash "$CFG_SH" agents.model "" >"$OUT" 2>"$ERR"; rc=$?
assert_eq "0" "$rc" "AC5: an unsafe YAML tag does not crash the lookup"
assert_file_absent "$SANDBOX/PWNED3" "AC5: an unsafe YAML tag is never constructed (safe load)"

# ── AC6: re-stamp chain across both layers; effort/runner layering ───────────
reset_cfg
user_json '{"agents": {"model": "sonnet", "restamp_model": "haiku", "roles": {"qa": {"restamp_model": "opus"}}}}'
proj_json '{"agents": {"roles": {"qa": {"model": "x"}}}}'
assert_eq "opus" "$(get agents.roles.qa.restamp_model "")" "AC6: user-level role restamp_model resolves"
assert_eq "haiku" "$(get agents.roles.docs.restamp_model "")" "AC6: role without restamp falls to user-level agents.restamp_model"
assert_eq "haiku" "$(get agents.restamp_model "")" "AC6: global restamp_model from the user-level layer"
proj_json '{"agents": {"roles": {"docs": {"restamp_model": "sonnet"}}}}'
assert_eq "sonnet" "$(get agents.roles.docs.restamp_model "")" "AC6: project role restamp beats user-level restamp"
user_json '{"agents": {"model": "sonnet"}}'
proj_json '{"agents": {"roles": {"qa": {"model": "x"}}}}'
assert_eq "sonnet" "$(get agents.roles.qa.restamp_model "")" "AC6: chain bottoms out at user-level agents.model"
assert_eq "sonnet" "$(get agents.restamp_model "")" "AC6: global restamp defaults to user-level agents.model"
proj_json '{"agents": {"restamp_model": "haiku", "roles": {"qa": {"model": "x"}}}}'
assert_eq "haiku" "$(get agents.roles.qa.restamp_model "")" "AC6: project global restamp beats user-level agents.model"
assert_contains "$(dump)" "$(printf 'agents.roles.qa.restamp_model\nhaiku')" "AC6: --dump answers the same restamp chain as the single-key path"

reset_cfg
user_json '{"agents": {"effort": "high", "restamp_effort": "low", "roles": {"qa": {"runner": "codex"}}}}'
proj_json '{"agents": {"roles": {"docs": {"effort": "max"}}}}'
assert_eq "high" "$(get agents.effort "")" "AC6: effort layers from the user-level file"
assert_eq "max" "$(get agents.roles.docs.effort "")" "AC6: project role effort layers over it"
assert_eq "low" "$(get agents.roles.docs.restamp_effort "")" "AC6: restamp_effort chain evaluated on the merged config"
assert_eq "codex" "$(get agents.roles.qa.runner "")" "AC6: per-role runner layers from the user-level file"
assert_contains "$(bash "$AGENT_SH" --resolve qa 2>/dev/null)" "runner=codex" "AC6: --resolve sees the layered per-role runner"

# ── AC6b: the merged --dump still costs one python3 spawn per invocation ─────
reset_cfg
user_json '{"agents": {"model": "sonnet", "roles": {"qa": {"model": "opus"}}}}'
proj_json '{"agents": {"roles": {"docs": {"model": "haiku"}}}}'
SHIMDIR="$SANDBOX/shim"; mkdir -p "$SHIMDIR"
PY_LOG="$SANDBOX/py.log"; : > "$PY_LOG"
REAL_PY="$(command -v python3)"
cat > "$SHIMDIR/python3" <<SHIM
#!/usr/bin/env bash
echo spawn >> "$PY_LOG"
exec "$REAL_PY" "\$@"
SHIM
chmod +x "$SHIMDIR/python3"
cat > "$SANDBOX/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$1"
. "$SCRIPT_DIR/pipeline-cfg-cache.sh"
printf '%s %s %s %s\n' "$(cfg agents.model "")" "$(cfg agents.roles.qa.model "")" \
  "$(cfg agents.roles.docs.model "")" "$(cfg agents.roles.qa.restamp_model "")"
PROBE
got="$(PATH="$SHIMDIR:$PATH" bash "$SANDBOX/probe.sh" "$TALOS_ROOT/scripts" 2>/dev/null)"
assert_eq "sonnet opus haiku sonnet" "$got" "AC6b: cfg() over the merged dump sees both layers"
assert_eq "1" "$(wc -l < "$PY_LOG" | tr -d ' ')" "AC6b: merged config still costs exactly one python3 spawn (#169)"

# ── Structure: one shared loader, no duplicated file-lookup loop ─────────────
_n="$(grep -c '"talos.pipeline.yml" "talos.pipeline.yaml" "talos.pipeline.json"' "$CFG_SH")"
assert_eq "1" "$_n" "AC6b: the project file lookup order is defined once in pipeline-config.sh"

finish
