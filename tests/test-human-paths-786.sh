#!/usr/bin/env bash
# test-human-paths-786.sh -- merge.human_paths (#786): a PR that touches a listed
# path waits for a person's approval of its exact head before `gate merge`
# answers `merge`. The human signal is the PR label talos:human-approved:<sha12>,
# which pipeline-vcs.sh refuses to apply. Tests are named by the spec's AC ids.
# Stub providers (tests/stubs) and a journaling pipeline-vcs.sh stub; no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
TALOS="$TALOS_ROOT/scripts/talos.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git remote set-url origin git@gitlab.com:acme/widget.git

HP='[".github/workflows/**", "install.sh"]'

# setcfg <provider> <human_paths json>: the sandbox config for one provider.
setcfg() {
  local _p="$1" _v="$2" _extra=""
  case "$_p" in
    github) _extra='"repo": "acme/widget"' ;;
    gitlab) _extra='"repo": "acme/widget"' ;;
    azure) _extra='"repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}' ;;
    file) _extra='"plan_file": "plan.md"' ;;
  esac
  if [ -n "$_v" ]; then
    printf '{"vcs": {"provider": "%s", %s}, "merge": {"human_paths": %s}}\n' "$_p" "$_extra" "$_v" > talos.pipeline.json
  else
    printf '{"vcs": {"provider": "%s", %s}}\n' "$_p" "$_extra" > talos.pipeline.json
  fi
}

# hp <provider> <path>...: run `human-paths 9` with those changed paths in the
# provider's stub. Sets OUT (stdout) and RC.
hp() {
  local _p="$1" _j _s="" _x
  shift
  case "$_p" in
    github)
      OUT="$(STUB_PR_FILES="$(printf '%s\n' "$@")" bash "$VCS" human-paths 9 2>"$SANDBOX/err")"; RC=$? ;;
    gitlab)
      _j="["
      for _x in "$@"; do _j="$_j$_s{\"new_path\":\"$_x\"}"; _s=","; done
      OUT="$(STUB_GITLAB_MR_DIFFS="$_j]" bash "$VCS" human-paths 9 2>"$SANDBOX/err")"; RC=$? ;;
    azure)
      _j='{"changeEntries":['
      for _x in "$@"; do _j="$_j$_s{\"item\":{\"path\":\"/$_x\"},\"changeType\":\"edit\"}"; _s=","; done
      OUT="$(STUB_AZURE_PR_ITERATIONS='{"count":1,"value":[{"id":1}]}' STUB_AZURE_PR_CHANGES="$_j"'],"nextSkip":0,"nextTop":0}' \
        bash "$VCS" human-paths 9 2>"$SANDBOX/err")"; RC=$? ;;
  esac
}

# ── AC2 / AC3 / AC4: the human-paths verb on every provider ──────────────────
for prov in github gitlab azure; do
  setcfg "$prov" "$HP"
  hp "$prov" src/app.js .github/workflows/ci.yml scripts/install.sh README.md
  assert_eq "1" "$RC" "AC2 $prov human-paths exits 1 when a changed path matches"
  assert_eq ".github/workflows/ci.yml
scripts/install.sh" "$OUT" "AC2 $prov human-paths prints the full-path and the basename matches, one per line"

  hp "$prov" src/app.js README.md
  assert_eq "0" "$RC" "AC3 $prov human-paths exits 0 when no changed path matches"
  assert_eq "" "$OUT" "AC3 $prov human-paths prints nothing when no changed path matches"

  setcfg "$prov" ""
  hp "$prov" .github/workflows/ci.yml install.sh
  assert_eq "0" "$RC" "AC3 $prov human-paths exits 0 when merge.human_paths is unset"
  assert_eq "" "$OUT" "AC3 $prov human-paths prints nothing when merge.human_paths is unset"

  setcfg "$prov" "[]"
  hp "$prov" .github/workflows/ci.yml
  assert_eq "0" "$RC" "AC3 $prov human-paths exits 0 when merge.human_paths is empty"
  assert_eq "" "$OUT" "AC3 $prov human-paths prints nothing when merge.human_paths is empty"

  for notlist in '5' '{"a": 1}'; do
    setcfg "$prov" "$notlist"
    hp "$prov" .github/workflows/ci.yml
    assert_eq "2" "$RC" "AC4 $prov human-paths exits 2 when merge.human_paths is not a list ($notlist)"
    assert_eq "" "$OUT" "AC4 $prov human-paths prints nothing when merge.human_paths is not a list ($notlist)"
  done
done

# ── AC2: a rename out of a listed path still matches by its old name ────────
# The listing guards the old name; a rename's pr-files entry carries the new one.
setcfg github "$HP"
OUT="$(STUB_GH_PR_FILES_RAW='[{"filename":"docs/ci.yml","previous_filename":".github/workflows/ci.yml","status":"renamed"},{"filename":"README.md"}]' \
  bash "$VCS" human-paths 9 2>/dev/null)"; RC=$?
assert_eq "1" "$RC" "AC2 github human-paths exits 1 when a listed path is renamed away"
assert_eq ".github/workflows/ci.yml" "$OUT" "AC2 github human-paths prints the old name of a renamed file"
setcfg gitlab "$HP"
OUT="$(STUB_GITLAB_MR_DIFFS='[{"old_path":"install.sh","new_path":"tools/setup.sh","renamed_file":true},{"old_path":"a.txt","new_path":"a.txt"}]' \
  bash "$VCS" human-paths 9 2>/dev/null)"; RC=$?
assert_eq "1" "$RC" "AC2 gitlab human-paths exits 1 when a listed path is renamed away"
assert_eq "install.sh" "$OUT" "AC2 gitlab human-paths prints the old name of a renamed file"
setcfg azure "$HP"
OUT="$(STUB_AZURE_PR_ITERATIONS='{"count":1,"value":[{"id":1}]}' \
  STUB_AZURE_PR_CHANGES='{"changeEntries":[{"item":{"path":"/docs/ci.yml"},"originalPath":"/.github/workflows/ci.yml","changeType":"rename"}],"nextSkip":0,"nextTop":0}' \
  bash "$VCS" human-paths 9 2>/dev/null)"; RC=$?
assert_eq "1" "$RC" "AC2 azure human-paths exits 1 when a listed path is renamed away"
assert_eq ".github/workflows/ci.yml" "$OUT" "AC2 azure human-paths prints the old name of a renamed file"

setcfg github "$HP"
OUT="$(STUB_GH_API_FAIL=pr-files STUB_PR_FILES=install.sh bash "$VCS" human-paths 9 2>/dev/null)"; RC=$?
assert_eq "2" "$RC" "AC4 github human-paths exits 2 when pr-files fails"
assert_eq "" "$OUT" "AC4 github human-paths prints nothing when pr-files fails"
setcfg gitlab "$HP"
OUT="$(STUB_GITLAB_API_FAIL=1 bash "$VCS" human-paths 9 2>/dev/null)"; RC=$?
assert_eq "2" "$RC" "AC4 gitlab human-paths exits 2 when pr-files fails"
assert_eq "" "$OUT" "AC4 gitlab human-paths prints nothing when pr-files fails"
setcfg azure "$HP"
OUT="$(STUB_AZURE_PR_ITERATIONS_FAIL=1 bash "$VCS" human-paths 9 2>/dev/null)"; RC=$?
assert_eq "2" "$RC" "AC4 azure human-paths exits 2 when pr-files fails"
assert_eq "" "$OUT" "AC4 azure human-paths prints nothing when pr-files fails"
setcfg file "$HP"
OUT="$(bash "$VCS" human-paths 9 2>/dev/null)"; RC=$?
assert_eq "2" "$RC" "AC4 provider file human-paths exits 2"
assert_eq "" "$OUT" "AC4 provider file human-paths prints nothing"

# ── AC10: label-pr / label-issue refuse to add the human label ───────────────
# What reached a provider CLI or API; azure's local `az extension list` preflight
# is not a call about the label.
provider_calls() { cat "$GH_LOG" "$CURL_LOG" | grep -v '^AZ ARGS: \[extension\] \[list\]' || true; }
for prov in github gitlab azure; do
  setcfg "$prov" "$HP"
  for verb in label-pr label-issue; do
    : > "$GH_LOG"; : > "$CURL_LOG"
    bash "$VCS" "$verb" 9 --add talos:human-approved:abc123abc123 >/dev/null 2>&1; RC=$?
    assert_eq "1" "$RC" "AC10 $prov $verb refuses --add talos:human-approved:<sha12> (exit 1)"
    assert_eq "" "$(provider_calls)" "AC10 $prov $verb sends no provider call for the refused label"
    bash "$VCS" "$verb" 9 --add Talos:Human-Approved:ABC123ABC123 >/dev/null 2>&1; RC=$?
    assert_eq "1" "$RC" "AC10 $prov $verb refuses the label in other letter case"
    bash "$VCS" "$verb" 9 talos:human-approved:abc123abc123 >/dev/null 2>&1; RC=$?
    assert_eq "1" "$RC" "AC10 $prov $verb refuses the label as a positional add"
    bash "$VCS" "$verb" 9 --add pipeline:review --add talos:human-approved:abc123abc123 >/dev/null 2>&1; RC=$?
    assert_eq "1" "$RC" "AC10 $prov $verb refuses the whole call when one added label is the human label"
    assert_eq "" "$(provider_calls)" "AC10 $prov $verb sends nothing when one added label is the human label"
    bash "$VCS" "$verb" 9 --remove talos:human-approved:abc123abc123 >/dev/null 2>&1; RC=$?
    assert_eq "0" "$RC" "AC10 $prov $verb still removes the human label"
    bash "$VCS" "$verb" 9 --add pipeline:review >/dev/null 2>&1; RC=$?
    assert_eq "0" "$RC" "AC10 $prov $verb still adds any other label"
  done
done

# ── AC12: no agent prompt names the label ────────────────────────────────────
leaks="$(grep -rl 'talos:human-approved' "$TALOS_ROOT/agents" "$TALOS_ROOT/skills" "$TALOS_ROOT/templates" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$leaks" "AC12 no file under agents/, skills/ or templates/ contains talos:human-approved"

# ── AC13: the config row and the fail-closed list ────────────────────────────
row="$(awk -F'\t' '$1 == "merge.human_paths" { print $2 "|" $3 "|" $4 "|" $5 "|" $6 }' "$TALOS_ROOT/scripts/pipeline-defaults.sh")"
assert_eq "list||-|-|repo" "$row" "AC13 merge.human_paths is a repo-only list row with no default"
rc=0
out="$(bash -c '. "$1/scripts/pipeline-defaults-check.sh"; _talos_load_defaults "$1/scripts/pipeline-defaults.sh" && _talos_security_key merge.human_paths' _ "$TALOS_ROOT" 2>&1)" || rc=$?
assert_eq "0" "$rc" "AC13 merge.human_paths is a security key and the defaults table still loads"

# ── gate merge against a stub pipeline-vcs.sh (as in test-closing-keyword-unverified-wait.sh) ──
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="${1:-}"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then { printf "[%s]\n" "$*"; cat "$a"; } >> "$d/bodies"; fi
  prev="$a"
done
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh pipeline-draft-check.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
GATE="$GS/talos.sh"
HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
LABEL="talos:human-approved:0123456789ab"
APPROVALS='{"name":"qa:pass"},{"name":"review:approved"},{"name":"security:approved"},{"name":"docs:done"},{"name":"pipeline:review"}'

set_stub() {
  printf '%s\n' "$2" > "$STUB_DIR/$1.rc"
  printf '%s' "${3:-}" > "$STUB_DIR/$1.out"
  printf '%s' "${4:-}" > "$STUB_DIR/$1.err"
}
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$SANDBOX/talos.pipeline.json"
  set_stub view-pr 0 "{\"labels\":[$APPROVALS]}"
  set_stub view-issue 0 '{"labels":[{"name":"pipeline:review"}]}'
  set_stub pr-head 0 "$HEAD_SHA"
  set_stub read-comments 0 '{"comments":[]}'
  set_stub draft-check 0 "false"
  set_stub human-paths 1 ".github/workflows/ci.yml
install.sh"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
called() { journal | grep -c "^$1 \|^vcs $1 "; }
bodies() { cat "$STUB_DIR/bodies" 2>/dev/null; }
gm() { OUT="$(bash "$GATE" gate merge 9 42 2>"$SANDBOX/stderr")"; RC=$?; }
WAIT="verdict=wait
reason=human-approval
paths=.github/workflows/ci.yml,install.sh"

# AC1: no human_paths -> the verb finds nothing -> merge, whatever the diff.
reset_stubs; set_stub human-paths 0 ""
gm
assert_eq "verdict=merge" "$OUT" "AC1 an empty merge.human_paths leaves the verdict at merge"

# AC5: a listed path and no human label -> wait, naming the paths.
reset_stubs
gm
assert_eq "$WAIT" "$OUT" "AC5 a PR touching a listed path with no human label waits with reason=human-approval and the paths"
assert_eq "0" "$RC" "AC5 the wait exits 0"
assert_not_contains "$OUT" "verdict=merge" "AC5 the gate does not answer merge"

# AC6: the label for the current head -> merge.
reset_stubs; set_stub view-pr 0 "{\"labels\":[$APPROVALS,{\"name\":\"$LABEL\"}]}"
gm
assert_eq "verdict=merge" "$OUT" "AC6 the PR carrying talos:human-approved:<first 12 of head> merges"

# AC7: an older head's label, or the stage approvals alone, do not satisfy it.
reset_stubs; set_stub view-pr 0 "{\"labels\":[$APPROVALS,{\"name\":\"talos:human-approved:ffffffffffff\"}]}"
gm
assert_eq "$WAIT" "$OUT" "AC7 a human label naming a different head does not satisfy the gate"
reset_stubs; set_stub view-pr 0 "{\"labels\":[$APPROVALS,{\"name\":\"pipeline:approved\"},{\"name\":\"talos:human-approved\"}]}"
gm
assert_eq "$WAIT" "$OUT" "AC7 pipeline approval labels and a label with no sha do not satisfy the gate"

# AC8: one comment and one notification per head.
reset_stubs
gm
assert_eq "1" "$(bodies | grep -c '^\[comment-pr 9')" "AC8 the first wait on a head posts exactly one PR comment"
assert_contains "$(bodies)" "<!-- talos:human-approval $HEAD_SHA -->" "AC8 the comment carries the head marker"
assert_contains "$(bodies)" ".github/workflows/ci.yml" "AC8 the comment names the matched paths"
assert_contains "$(bodies)" "$LABEL" "AC8 the comment names the exact label to apply"
assert_eq "1" "$(journal | grep -c '^notify info human-approval')" "AC8 the first wait sends one notification"
marker_comment="{\"comments\":[{\"body\":\"hold\\n<!-- talos:human-approval $HEAD_SHA -->\",\"author\":{\"login\":\"talos-bot\"}}]}"
rm -f "$STUB_DIR/journal" "$STUB_DIR/bodies"
set_stub read-comments 0 "$marker_comment"
gm
assert_eq "$WAIT" "$OUT" "AC8 a second run on the same head still waits"
assert_eq "0" "$(called comment-pr)" "AC8 a second run on the same head posts no comment"
assert_eq "0" "$(journal | grep -c '^notify ')" "AC8 a second run on the same head sends no notification"
NEW_SHA="89abcdef0123456789abcdef0123456789abcdef"
set_stub pr-head 0 "$NEW_SHA"
gm
assert_eq "1" "$(called comment-pr)" "AC8 a run on a new head posts a comment again"
assert_contains "$(bodies)" "<!-- talos:human-approval $NEW_SHA -->" "AC8 the new comment carries the new head marker"
assert_contains "$(bodies)" "talos:human-approved:89abcdef0123" "AC8 the new comment names the label for the new head"

# AC9: the diff or config cannot be read -> wait, never merge.
reset_stubs; set_stub human-paths 2 ""
gm
assert_eq "verdict=wait
reason=human-paths-unverified" "$OUT" "AC9 human-paths exit 2 gives wait / human-paths-unverified"
assert_eq "0" "$(called comment-pr)" "AC9 an unverified read posts no comment"

# AC11: human-merge mode is unchanged.
reset_stubs; printf '{"merge": {"auto": false}}\n' > "$SANDBOX/talos.pipeline.json"
gm
assert_eq "verdict=handoff" "$OUT" "AC11 merge.auto false still answers handoff with human_paths matched"
set_stub view-pr 0 "{\"labels\":[$APPROVALS,{\"name\":\"pipeline:approved\"}]}"
gm
assert_eq "verdict=wait
reason=awaiting-human-merge" "$OUT" "AC11 merge.auto false answers awaiting-human-merge on the next run"

# AC14: the reasons are declared in the header and its verdict table.
hdr="$(sed -n '1,/^set -/p' "$TALOS")"
reasons=" $(printf '%s\n' "$hdr" | sed -n 's/^# gate-reasons: //p') "
assert_contains "$reasons" " human-approval " "AC14 # gate-reasons: lists human-approval"
assert_contains "$reasons" " human-paths-unverified " "AC14 # gate-reasons: lists human-paths-unverified"
table="$(printf '%s\n' "$hdr" | grep -A6 'verdict=wait')"
assert_contains "$table" "human-approval" "AC14 the verdict=wait table lists human-approval"
assert_contains "$table" "human-paths-unverified" "AC14 the verdict=wait table lists human-paths-unverified"

finish
