#!/usr/bin/env bash
# test-talos-env.sh -- `scripts/talos.sh env` (#465, slice 1 of epic #422).
#
# `env` replaces the Step 0 reads and the per-role runner resolution that the
# orchestrator used to do by hand, so this file pins that it answers exactly
# what those reads answered:
#   (a) golden fixtures: the whole output under a sandbox with no config, and
#       under a sandbox with a project file, a user-level file and role
#       profiles (tests/fixtures/talos-env-{default,rich}.golden)
#   (b) equivalence: every Step 0 value equals `pipeline-config.sh <key>`, PR_DRAFT
#       equals `pipeline-draft-check.sh resolve`, and every role's fields equal
#       the `pipeline-agent.sh --resolve` line
#   (c) sanitising: control bytes, C1 bytes and a newline in a config value print
#       as \xNN and cannot forge a line; a backslash prints as \\ so the text \n
#       is never a list separator; bidi and zero-width characters print as \uXXXX;
#       an over-long value is cut, ends in [truncated] and is warned about
#   (d) the contract: every line is KEY=value or `stop|warn reason=<enum>`; the
#       checker itself is shown red by an unsanitised ESC byte, a bidi control
#       and by an out-of-enum reason
#   (e) stop and warn cases: isolation invalid, scripts missing, unknown verb,
#       usage, a failed PR_DRAFT resolve, an unusable runner
#
# Regenerate the fixtures after an intended change, and review the diff:
#   bash tests/test-talos-env.sh --regen-fixtures
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

TALOS="$TALOS_ROOT/scripts/talos.sh"
FIX_DEFAULT="$TALOS_ROOT/tests/fixtures/talos-env-default.golden"
FIX_RICH="$TALOS_ROOT/tests/fixtures/talos-env-rich.golden"
USER_DIR="$HOME/.talos"
ERR="$SANDBOX/stderr"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
ROLES="validator pm developer qa reviewer security adversarial docs planner"

reset_cfg() {
  rm -rf "${USER_DIR:?}" "${SANDBOX:?}"/talos.pipeline.* "${SANDBOX:?}/.claude"
  unset PIPELINE_CONFIG
}
proj_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
user_json() { mkdir -p "$USER_DIR"; printf '%s' "$1" > "$USER_DIR/talos.pipeline.json"; }
env_run() { bash "$TALOS" env 2>"$ERR"; }
# The golden copy masks the one machine-specific value, the scripts directory.
env_golden() { env_run | sed 's|^SCRIPTS_DIR=.*|SCRIPTS_DIR=<scripts>|'; }

# Role profiles under the sandbox, so --check-effort never reads the repo's own
# agents/*.md: every role says effort: medium, qa says low.
make_profiles() {
  local r e
  mkdir -p "$SANDBOX/.claude/agents"
  for r in $ROLES; do
    e=medium; [ "$r" = "qa" ] && e=low
    printf -- '---\nname: %s\neffort: %s\n---\nbody\n' "$r" "$e" > "$SANDBOX/.claude/agents/$r.md"
  done
}

RICH_PROJECT='{
  "vcs": {"provider": "github"},
  "board": {"enabled": true, "project_number": 7, "owner": "acme"},
  "issues": {"max_parallel": 2, "skip_labels": ["pipeline:blocked", "wontfix", "hold"]},
  "limits": {"max_fix_attempts": 5},
  "merge": {"auto": false, "auto_sync": false, "required_checks": ["ci / test", "ci / lint"]},
  "verify": {"commands": ["bash tests/run-tests.sh --quiet", "bash lint.sh"], "targeted": false, "ci_wait_s": 600, "timeout_ms": 300000},
  "roles": {"docs_mode": "always", "changelog_fragments": true, "adversarial": true, "planner": true, "pm_skip_when_spec_present": false},
  "spend": {"comment": false},
  "comments": {"templates_dir": "tpl/comments"},
  "execution": {"worktree_warn_threshold": 4},
  "agents": {"runner": "claude", "model": "sonnet", "effort": "medium", "fallback": ["codex"],
    "roles": {"qa": {"effort": "high"},
              "developer": {"runner": "custom", "runner_cmd": "my-runner --flag \"a b\" model=x effort=max"},
              "docs": {"model": "haiku"}}}
}'
RICH_USER='{"agents": {"roles": {"security": {"model": "opus"}}}}'

setup_default() { reset_cfg; }
setup_rich() { reset_cfg; proj_json "$RICH_PROJECT"; user_json "$RICH_USER"; make_profiles; }

if [ "${1:-}" = "--regen-fixtures" ]; then
  setup_default; env_golden > "$FIX_DEFAULT" || exit 1
  setup_rich; env_golden > "$FIX_RICH" || exit 1
  printf 'regenerated tests/fixtures/talos-env-{default,rich}.golden\n'
  exit 0
fi

# assert_golden LABEL FIXTURE ACTUAL-FILE: equal, or a unified diff and the regen command.
assert_golden() {
  if cmp -s "$2" "$3"; then pass "$1"; return; fi
  fail "$1" "talos.sh env output differs from $(basename "$2")"
  diff -u --label "fixture $(basename "$2")" --label "talos.sh env" "$2" "$3" | head -60 >&2
  printf '      If the change is intended, regenerate the fixtures and review the diff:\n        bash tests/test-talos-env.sh --regen-fixtures\n' >&2
}

# The enum of reasons lives in talos.sh's header; the checker reads it from there.
REASONS="$(sed -n 's/^# env-reasons: //p' "$TALOS" | head -n 1)"

# check_env_output FILE: every line is KEY=value (key [A-Za-z][A-Za-z0-9_.]*) or
# `stop|warn reason=<enum> [role=..|key=..]`; no byte below 0x20 but the line
# ends, no DEL, no C1 control. Exit 0 when it holds.
check_env_output() {
  python3 -I -c '
import re, sys
reasons = sys.argv[2].split()
data = open(sys.argv[1], "rb").read()
if re.search(rb"[\x00-\x09\x0b-\x1f\x7f]|\xc2[\x80-\x9f]", data):
    sys.exit(1)
if re.search("[\u200b-\u200f\u202a-\u202e\u2060\u2066-\u2069\u061c\u00ad\u2028\u2029\ufeff\U000e0000-\U000e007f]", data.decode("utf-8", "replace")):
    sys.exit(1)
kv = re.compile(r"[A-Za-z][A-Za-z0-9_.]*=")
sw = re.compile(r"(stop|warn) reason=([a-z-]+)( (role|key)=[A-Za-z0-9_.-]+)?\Z")
lines = data.decode("utf-8").split("\n")
if lines and lines[-1] == "":
    lines.pop()
if not lines:
    sys.exit(1)
for ln in lines:
    if kv.match(ln):
        continue
    m = sw.match(ln)
    if m and m.group(2) in reasons:
        continue
    sys.exit(1)
' "$1" "$REASONS"
}

# ── (a) golden fixtures ──────────────────────────────────────────────────────
setup_default
env_golden > "$SANDBOX/out.default"; rc=$?
assert_eq "0" "$rc" "default: exits 0"
assert_golden "default: no config at all matches the golden fixture" "$FIX_DEFAULT" "$SANDBOX/out.default"
assert_eq "0" "$(wc -c < "$ERR" | tr -d ' ')" "default: nothing on stderr"

setup_rich
env_golden > "$SANDBOX/out.rich"; rc=$?
assert_eq "0" "$rc" "rich: exits 0"
assert_golden "rich: project + user-level config and role profiles match the golden fixture" "$FIX_RICH" "$SANDBOX/out.rich"
rich="$(cat "$SANDBOX/out.rich")"
assert_contains "$rich" "agent.developer.runner_cmd=my-runner --flag \"a b\" model=x effort=max" "rich: a runner_cmd holding model= and effort= words is not split"
assert_contains "$rich" "agent.developer.model=sonnet" "rich: the global agents.model reaches a role with none of its own"
assert_contains "$rich" "agent.docs.model=haiku" "rich: a role model wins"
assert_contains "$rich" "agent.security.model=opus" "rich: the user-level role model is used"
assert_contains "$rich" "agent.qa.effort=high" "rich: a role effort wins"
assert_contains "$rich" "agent.qa.effort_notice=talos: notice: role 'qa' has effort=high in config but its frontmatter has effort=low" "rich: the --check-effort notice is relayed"
assert_not_contains "$rich" "agent.pm.effort_notice" "rich: no notice when config and frontmatter agree"
assert_contains "$rich" "agent.pm.fallback=codex" "rich: the fallback chain is relayed"
assert_contains "$rich" 'SKIP_LABELS=pipeline:blocked\nwontfix\nhold' "rich: a list is joined by the two characters \\n"
assert_contains "$rich" 'VERIFY_COMMANDS=bash tests/run-tests.sh --quiet\nbash lint.sh' "rich: verify commands are a \\n list"
assert_contains "$rich" "VERIFY_QA_MODE=ci" "rich: required checks derive qa_mode ci"
assert_contains "$rich" "AGENT_SOURCE=repo override (.claude/agents/)" "rich: a repo role file is the repo-override source"
check_env_output "$SANDBOX/out.rich"; assert_eq "0" "$?" "rich: output satisfies the line contract"
check_env_output "$SANDBOX/out.default"; assert_eq "0" "$?" "default: output satisfies the line contract"
assert_contains "$(cat "$SANDBOX/out.default")" "AGENT_SOURCE=global/bare (~/.claude/agents/ or none)" "default: no repo role file and no plugin is the global/bare source"
setup_default
out="$(CLAUDE_PLUGIN_ROOT="$SANDBOX/plugin" bash "$TALOS" env 2>/dev/null)"
assert_contains "$out" 'AGENT_SOURCE=plugin (talos:<role>, $CLAUDE_PLUGIN_ROOT set)' "default: CLAUDE_PLUGIN_ROOT set is the plugin source"
assert_eq "$TALOS_ROOT/scripts" "$(printf '%s\n' "$out" | sed -n 's/^SCRIPTS_DIR=//p')" "default: SCRIPTS_DIR is the directory talos.sh runs from"

# ── (b) equivalence with the reads Step 0 used to make ───────────────────────
env_value() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
table="$(awk '/^TABLE$/ { p = 0 } p { print } /cat <<.TABLE.$/ { p = 1 }' "$TALOS")"
n_rows="$(printf '%s\n' "$table" | wc -l | tr -d ' ')"
rows_ok=0; [ "$n_rows" -gt 30 ] || rows_ok=1
assert_eq "0" "$rows_ok" "equivalence: the Step 0 table was extracted ($n_rows rows)"
equiv() {  # $1 = label prefix, $2 = env output
  local var key kind want got bad=""
  while IFS="$(printf '\t')" read -r var key kind; do
    want="$(bash "$TALOS_ROOT/scripts/pipeline-config.sh" "$key" 2>/dev/null)"
    if [ "$kind" = "l" ]; then
      want="$(printf '%s\n' "$want" | paste -sd'|' -)"
      got="$(env_value "$2" "$var" | sed 's/\\n/|/g')"
    else
      got="$(env_value "$2" "$var")"
    fi
    [ "$want" = "$got" ] || bad="$bad $var(want '$want' got '$got')"
  done <<EOF
$table
EOF
  assert_eq "" "$bad" "$1: every Step 0 value equals pipeline-config.sh <key>"
}
out="$(cat "$SANDBOX/out.default")"; equiv "equivalence (no config)" "$out"
assert_eq "$(bash "$TALOS_ROOT/scripts/pipeline-draft-check.sh" resolve 2>/dev/null)" "$(env_value "$out" PR_DRAFT)" "equivalence (no config): PR_DRAFT equals pipeline-draft-check.sh resolve"
setup_rich; out="$rich"; equiv "equivalence (rich config)" "$out"
assert_eq "$(bash "$TALOS_ROOT/scripts/pipeline-draft-check.sh" resolve 2>/dev/null)" "$(env_value "$out" PR_DRAFT)" "equivalence (rich): PR_DRAFT equals pipeline-draft-check.sh resolve"
roles_bad=""
for r in $ROLES; do
  line="$(bash "$TALOS_ROOT/scripts/pipeline-agent.sh" --resolve "$r" 2>/dev/null)"
  rebuilt="runner=$(env_value "$out" "agent.$r.runner") runner_cmd=$(env_value "$out" "agent.$r.runner_cmd") model=$(env_value "$out" "agent.$r.model") effort=$(env_value "$out" "agent.$r.effort")"
  fb="$(env_value "$out" "agent.$r.fallback")"
  [ -z "$fb" ] || rebuilt="$rebuilt fallback=$fb"
  [ "$line" = "$rebuilt" ] || roles_bad="$roles_bad $r"
done
assert_eq "" "$roles_bad" "equivalence (rich): every role's fields rebuild the exact --resolve line"
assert_eq "worktree" "$(env_value "$out" ISOLATION)" "equivalence: ISOLATION is the configured mode"

# ── (c) sanitising ───────────────────────────────────────────────────────────
setup_default
proj_json '{"agents": {"roles": {"developer": {"runner_cmd": "x\u001b[2Jy\u009bz\nFORGED=1\u007f", "model": "m\u0007"}}}, "comments": {"header": "h\u001b]0;t\u0007"}}'
env_run > "$SANDBOX/out.hostile"; rc=$?
hostile="$(cat "$SANDBOX/out.hostile")"
assert_eq "0" "$rc" "sanitising: a hostile value does not fail the run"
assert_contains "$hostile" 'agent.developer.runner_cmd=x\x1b[2Jy\x9bz\x0aFORGED=1\x7f' "sanitising: ESC, a C1 control, newline and DEL in runner_cmd print as \\xNN"
assert_contains "$hostile" 'agent.developer.model=m\x07' "sanitising: BEL in a model prints as \\x07"
assert_contains "$hostile" 'COMMENTS_HEADER_TPL=h\x1b]0;t\x07' "sanitising: a terminal title sequence in a header prints as \\xNN"
assert_eq "0" "$(printf '%s\n' "$hostile" | grep -c '^FORGED')" "sanitising: a newline in a value cannot forge a line"
check_env_output "$SANDBOX/out.hostile"; assert_eq "0" "$?" "sanitising: the hostile output still satisfies the line contract"

python3 -I -c '
import json
print(json.dumps({"agents": {"model": "a" * 9000}}))' > "$SANDBOX/talos.pipeline.json"
env_run > "$SANDBOX/out.long"
long="$(cat "$SANDBOX/out.long")"
assert_contains "$long" "warn reason=value-truncated key=agent.pm.model" "sanitising: an over-long value is cut with a warn line naming the key"
assert_eq "$(python3 -I -c 'print("a" * 8192 + "[truncated]")')" "$(env_value "$long" agent.pm.model)" "sanitising: the value is cut at 8192 characters and ends in the [truncated] marker"
assert_eq "0" "$(env_value "$rich" agent.pm.model | grep -c 'truncated')" "sanitising: a value within the cap carries no marker"
check_env_output "$SANDBOX/out.long"; assert_eq "0" "$?" "sanitising: a truncation warn line satisfies the line contract"

# A backslash prints as \\: the text \n inside a list item is not the separator.
setup_default
proj_json '{"issues": {"skip_labels": ["a\\nb", "c"]}, "agents": {"model": "x\\y\\u202e"}}'
env_run > "$SANDBOX/out.bs"
bs="$(cat "$SANDBOX/out.bs")"
assert_contains "$bs" 'SKIP_LABELS=a\\nb\nc' "sanitising: the text \\n inside a list item prints as \\\\n, apart from the \\n separator"
assert_contains "$bs" 'agent.pm.model=x\\y\\u202e' "sanitising: a backslash in a scalar prints as \\\\, so literal text like \\u202e is not an escape"
check_env_output "$SANDBOX/out.bs"; assert_eq "0" "$?" "sanitising: a backslash value satisfies the line contract"

# Bidi controls and zero-width characters print as \uXXXX.
proj_json '{"agents": {"model": "a\u202eb\u2066c\u2069d\u200be\u200df\ufeffg"}, "comments": {"header": "x\u202ay\u202dz"}}'
env_run > "$SANDBOX/out.bidi"
bidi="$(cat "$SANDBOX/out.bidi")"
assert_contains "$bidi" 'agent.pm.model=a\u202eb\u2066c\u2069d\u200be\u200df\ufeffg' "sanitising: bidi controls and zero-width characters print as \\uXXXX"
assert_contains "$bidi" 'COMMENTS_HEADER_TPL=x\u202ay\u202dz' "sanitising: the bidi range ends U+202A and U+202D are escaped"
check_env_output "$SANDBOX/out.bidi"; assert_eq "0" "$?" "sanitising: escaped bidi output satisfies the line contract"

# One test per further invisible character (#466, the slice 1 security review).
# Each row is `<code>|<label>`; the JSON escape is a backslash, `u` and the code.
BS='\'
for _case in '2028|U+2028 line separator' '2029|U+2029 paragraph separator' '200e|U+200E left-to-right mark' \
             '200f|U+200F right-to-left mark' '061c|U+061C Arabic letter mark' '2060|U+2060 word joiner' \
             '00ad|U+00AD soft hyphen'; do
  proj_json "{\"agents\": {\"model\": \"a${BS}u${_case%%|*}b\"}}"
  env_run > "$SANDBOX/out.invisible"
  assert_contains "$(cat "$SANDBOX/out.invisible")" "agent.pm.model=a${BS}u${_case%%|*}b" "sanitising: ${_case#*|} prints as \\uXXXX"
  check_env_output "$SANDBOX/out.invisible"; assert_eq "0" "$?" "sanitising: ${_case#*|} output satisfies the line contract"
done
proj_json "{\"agents\": {\"model\": \"a$(printf '\363\240\201\201')b\"}}"
env_run > "$SANDBOX/out.invisible"
assert_contains "$(cat "$SANDBOX/out.invisible")" "agent.pm.model=a${BS}U000e0041b" "sanitising: a tag character (U+E0041) prints as \\UXXXXXXXX"
check_env_output "$SANDBOX/out.invisible"; assert_eq "0" "$?" "sanitising: a tag character output satisfies the line contract"

# A real "[truncated]" is never the cut marker: it prints as \x5btruncated], and
# only a cut value ends in the marker (which the warn line also names).
proj_json '{"agents": {"model": "ends [truncated]", "roles": {"qa": {"model": "[truncated] mid"}}}}'
env_run > "$SANDBOX/out.marker"
marker="$(cat "$SANDBOX/out.marker")"
assert_eq 'ends \x5btruncated]' "$(env_value "$marker" agent.pm.model)" "sanitising: a value ending in the text [truncated] does not look cut"
assert_eq '\x5btruncated] mid' "$(env_value "$marker" agent.qa.model)" "sanitising: [truncated] inside a value is escaped too"
assert_eq "0" "$(printf '%s\n' "$marker" | grep -c 'warn reason=value-truncated')" "sanitising: no truncation warn line for a value that was not cut"

# ── (d) the checker is not vacuous: mutations turn it red ────────────────────
cp "$SANDBOX/out.rich" "$SANDBOX/mut.esc"
printf 'EVIL=a\033[2Jb\n' >> "$SANDBOX/mut.esc"
check_env_output "$SANDBOX/mut.esc"; assert_eq "1" "$?" "mutation: an unsanitised ESC byte turns the checker red"
cp "$SANDBOX/out.rich" "$SANDBOX/mut.c1"
printf 'EVIL=a\302\233b\n' >> "$SANDBOX/mut.c1"
check_env_output "$SANDBOX/mut.c1"; assert_eq "1" "$?" "mutation: an unsanitised C1 control (U+009B) turns the checker red"
cp "$SANDBOX/out.rich" "$SANDBOX/mut.bidi"
printf 'EVIL=a\342\200\256b\n' >> "$SANDBOX/mut.bidi"
check_env_output "$SANDBOX/mut.bidi"; assert_eq "1" "$?" "mutation: an unsanitised bidi control (U+202E) turns the checker red"
cp "$SANDBOX/out.rich" "$SANDBOX/mut.reason"
printf 'stop reason=bogus-reason\n' >> "$SANDBOX/mut.reason"
check_env_output "$SANDBOX/mut.reason"; assert_eq "1" "$?" "mutation: an out-of-enum reason turns the checker red"
cp "$SANDBOX/out.rich" "$SANDBOX/mut.line"
printf 'free text with no key\n' >> "$SANDBOX/mut.line"
check_env_output "$SANDBOX/mut.line"; assert_eq "1" "$?" "mutation: a line that is neither KEY=value nor stop|warn turns the checker red"
cmp -s "$FIX_RICH" "$SANDBOX/mut.line"; assert_eq "1" "$?" "mutation: the golden compare is red for a changed output"

# ── (e) stop and warn cases ──────────────────────────────────────────────────
setup_default
proj_json '{"execution": {"isolation": "checkout"}}'
out="$(env_run)"; rc=$?
assert_eq "1" "$rc" "stop: an unimplemented isolation mode exits 1"
assert_eq "stop reason=isolation-invalid" "$out" "stop: stdout is exactly one stop line for an invalid isolation"
assert_contains "$(cat "$ERR")" "not yet implemented" "stop: the isolation error text stays on stderr"
proj_json '{"execution": {"isolation": "branch"}, "issues": {"max_parallel": 3}}'
out="$(env_run)"; rc=$?
assert_eq "1" "$rc" "stop: isolation branch with max_parallel > 1 exits 1"
assert_eq "stop reason=isolation-invalid" "$out" "stop: branch with max_parallel > 1 is isolation-invalid"

setup_default
mkdir "$SANDBOX/lone"
cp "$TALOS" "$SANDBOX/lone/talos.sh"
out="$(bash "$SANDBOX/lone/talos.sh" env 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "stop: talos.sh without its sibling scripts exits 1"
assert_eq "stop reason=scripts-missing" "$out" "stop: missing sibling scripts is scripts-missing"

out="$(bash "$TALOS" nonsense 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "stop: an unknown verb exits 2"
assert_eq "stop reason=unknown-verb" "$out" "stop: an unknown verb is unknown-verb"
out="$(bash "$TALOS" env extra 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "stop: env with an argument exits 2"
assert_eq "stop reason=usage" "$out" "stop: env with an argument is usage"
assert_contains "$(bash "$TALOS" help 2>&1)" "usage: talos.sh <verb>" "help: prints the usage"

# A PR_DRAFT resolve that fails must stop the run, never default to false.
setup_default
mkdir -p "$SANDBOX/badroot/scripts"
cp "$TALOS_ROOT"/scripts/* "$SANDBOX/badroot/scripts/"
printf '#!/usr/bin/env bash\nprintf "maybe\\n"\n' > "$SANDBOX/badroot/scripts/pipeline-draft-check.sh"
out="$(bash "$SANDBOX/badroot/scripts/talos.sh" env 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "stop: a PR_DRAFT resolve that prints neither true nor false exits 1"
assert_eq "stop reason=draft-resolve-failed" "$out" "stop: stdout is exactly the draft-resolve-failed stop line, no PR_DRAFT=false"
printf '#!/usr/bin/env bash\nexit 3\n' > "$SANDBOX/badroot/scripts/pipeline-draft-check.sh"
out="$(bash "$SANDBOX/badroot/scripts/talos.sh" env 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "stop: a PR_DRAFT resolve that exits non-zero exits 1"
assert_eq "stop reason=draft-resolve-failed" "$out" "stop: a failing resolver is draft-resolve-failed"
printf '%s\n' "$out" > "$SANDBOX/out.draftstop"
check_env_output "$SANDBOX/out.draftstop"; assert_eq "0" "$?" "stop: the draft-resolve-failed line satisfies the line contract"

proj_json '{"agents": {"runner": "bogus"}}'
out="$(env_run)"; rc=$?
assert_eq "0" "$rc" "warn: an unusable runner does not stop the run"
assert_eq "9" "$(printf '%s\n' "$out" | grep -c '^warn reason=resolve-failed role=')" "warn: one resolve-failed line per role"
assert_eq "0" "$(printf '%s\n' "$out" | grep -c '^agent\.')" "warn: no agent line for a role that failed to resolve"
assert_contains "$(cat "$ERR")" "unknown agents.runner 'bogus'" "warn: the resolver's stderr line passes through"
printf '%s\n' "$out" > "$SANDBOX/out.warn"
check_env_output "$SANDBOX/out.warn"; assert_eq "0" "$?" "warn: the warn lines satisfy the line contract"

finish
