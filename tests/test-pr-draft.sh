#!/usr/bin/env bash
# test-pr-draft.sh -- opt-in draft PR plumbing (#332, PR 1 of 2):
#   create-pr --draft, ready-pr, draft-pr, pr-is-draft, pr-ci-runs.
#
# Every provider command is asserted as the exact argv the CLI stub received
# (the #162 lesson: assert the constructed command, not a happy exit code).
# The gh/glab/az stubs live in this file (a private PATH dir) so the shared
# tests/stubs/* stay untouched.
#
# Covers:
#   (a) create-pr without --draft: golden argv per provider (default unchanged)
#   (b) create-pr --draft: exact argv per provider; github-api/file behaviour
#   (c) ready-pr / draft-pr: exact argv per provider (github with --undo)
#   (d) pr-is-draft: draft(0) / ready(1) / fetch failure(2) / garbage(2) /
#       non-numeric id(2) / github-api + file (2); stdout empty on every 2
#   (e) pr-ci-runs: executed-run count (skipped runs excluded), failure,
#       garbage, capped totals, non-github (2)
#   (f) setup errors (no token, unknown provider, missing CLI) on every draft
#       verb are exit 2 with the gate-verb stdout contract intact
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export TALOS_RETRY_SLEEP_SCALE=0

# ── Private CLI stubs ────────────────────────────────────────────────────────
# Each stub appends its argv, one "[arg]" per element, to $DRAFT_LOG. Replies
# come from env vars; STUB_FAIL=1 makes the data-fetch calls exit 1.
BIN="$SANDBOX/draftbin"
mkdir -p "$BIN"
export DRAFT_LOG="$SANDBOX/draft.log"
: > "$DRAFT_LOG"

cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "repo view"*) printf 'acme/widget\n'; exit 0 ;;
esac
{ for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'; } >> "$DRAFT_LOG"
case "$*" in
  "pr create "*) printf 'https://github.com/acme/widget/pull/9\n' ;;
  "pr view "*"--json isDraft"*)
    [ "${STUB_FAIL:-}" = "1" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    printf '%s' "${STUB_RESP:-}" ;;
  "pr view "*"--json headRefName"*)
    [ "${STUB_FAIL:-}" = "1" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    if [ -n "${STUB_HEAD+x}" ]; then printf '%s' "$STUB_HEAD"; else printf '{"headRefName":"feat/x"}'; fi ;;
  "api "*"actions/runs"*"status=skipped"*)
    [ "${STUB_RUNS_SKIPPED_FAIL:-}" = "1" ] && { echo "gh: HTTP 500" >&2; exit 1; }
    if [ -n "${STUB_RUNS_SKIPPED+x}" ]; then printf '%s' "$STUB_RUNS_SKIPPED"; else printf '{"total_count":0}'; fi ;;
  "api "*"actions/runs"*)
    [ "${STUB_RUNS_FAIL:-}" = "1" ] && { echo "gh: HTTP 500" >&2; exit 1; }
    printf '%s' "${STUB_RUNS:-}" ;;
  "pr ready "*)
    [ "${STUB_FAIL:-}" = "1" ] && { echo "gh: pr ready failed" >&2; exit 1; } ;;
esac
exit 0
EOF

cat > "$BIN/glab" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "repo view"*) printf 'main\n'; exit 0 ;;
esac
{ printf 'GLAB '; for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'; } >> "$DRAFT_LOG"
case "$*" in
  "mr create "*) printf 'https://gitlab.com/acme/widget/-/merge_requests/7\n' ;;
  "mr view "*)
    [ "${STUB_FAIL:-}" = "1" ] && { echo "glab: 500" >&2; exit 1; }
    printf '%s' "${STUB_RESP:-}" ;;
esac
exit 0
EOF

cat > "$BIN/az" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "extension list "*) printf 'azure-devops\n'; exit 0 ;;
esac
{ printf 'AZ '; for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'; } >> "$DRAFT_LOG"
case "$*" in
  "repos pr create "*) printf '{"pullRequestId":7}\n' ;;
  "repos pr show "*)
    [ "${STUB_FAIL:-}" = "1" ] && { echo "ERROR: TF401180" >&2; exit 1; }
    printf '%s' "${STUB_RESP:-}" ;;
esac
exit 0
EOF
chmod +x "$BIN/gh" "$BIN/glab" "$BIN/az"
export PATH="$BIN:$PATH"

BODY="$SANDBOX/body.md"
printf 'the body' > "$BODY"

set_provider() {  # $1 = github | github-api | gitlab | azure | file
  case "$1" in
    azure)
      cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "acme/widget",
         "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}},
 "base_branch": "main"}
EOF
      ;;
    *)
      printf '{"vcs": {"provider": "%s", "repo": "acme/widget"}, "base_branch": "main"}\n' "$1" > talos.pipeline.json
      ;;
  esac
}

# last_log -- the most recent argv line the stubs logged.
last_log() { tail -n 1 "$DRAFT_LOG"; }
log_lines() { wc -l < "$DRAFT_LOG" | tr -d ' '; }

# ── (a) create-pr without --draft: golden argv per provider ──────────────────
set_provider github; : > "$DRAFT_LOG"
bash "$VCS" create-pr feat/x "T" "$BODY" >/dev/null 2>&1
assert_eq "[pr][create][--base][main][--head][feat/x][--title][T][--body-file][$BODY][--repo][acme/widget]" \
  "$(last_log)" "github: create-pr without --draft keeps the golden argv"

set_provider gitlab; : > "$DRAFT_LOG"
bash "$VCS" create-pr feat/x "T" "$BODY" >/dev/null 2>&1
assert_eq "GLAB [mr][create][--head][feat/x][--target-branch][main][--title][T][--description][the body][-R][acme/widget]" \
  "$(last_log)" "gitlab: create-pr without --draft keeps the golden argv"

set_provider azure; : > "$DRAFT_LOG"
bash "$VCS" create-pr feat/x "T" "$BODY" >/dev/null 2>&1
assert_eq "AZ [repos][pr][create][--source-branch][feat/x][--target-branch][main][--title][T][--description][the body][--org][https://dev.azure.com/acme][--project][proj][--repository][acme/widget][--output][json]" \
  "$(last_log)" "azure: create-pr without --draft keeps the golden argv"

# ── (b) create-pr --draft ────────────────────────────────────────────────────
set_provider github; : > "$DRAFT_LOG"
out="$(bash "$VCS" create-pr feat/x "T" "$BODY" --draft 2>&1)"; rc=$?
assert_eq "0" "$rc" "github: create-pr --draft exits 0"
assert_eq "[pr][create][--base][main][--head][feat/x][--title][T][--body-file][$BODY][--repo][acme/widget][--draft]" \
  "$(last_log)" "github: create-pr --draft appends exactly --draft"
assert_contains "$out" "pull/9" "github: create-pr --draft still prints the PR URL"

set_provider gitlab; : > "$DRAFT_LOG"
bash "$VCS" create-pr feat/x "T" "$BODY" --draft >/dev/null 2>&1
assert_eq "GLAB [mr][create][--head][feat/x][--target-branch][main][--title][T][--description][the body][-R][acme/widget][--draft]" \
  "$(last_log)" "gitlab: create-pr --draft appends exactly --draft"

set_provider azure; : > "$DRAFT_LOG"
bash "$VCS" create-pr feat/x "T" "$BODY" --draft >/dev/null 2>&1
assert_eq "AZ [repos][pr][create][--source-branch][feat/x][--target-branch][main][--title][T][--description][the body][--org][https://dev.azure.com/acme][--project][proj][--repository][acme/widget][--output][json][--draft][true]" \
  "$(last_log)" "azure: create-pr --draft appends exactly --draft true"

set_provider github; : > "$DRAFT_LOG"
out="$(bash "$VCS" --dry-run create-pr feat/x "T" "$BODY" --draft 2>&1)"
assert_contains "$out" "gh pr create --base main --head feat/x" "github: dry-run prints the create command"
assert_contains "$out" "--draft" "github: dry-run create-pr --draft shows --draft"
assert_eq "0" "$(log_lines)" "github: dry-run create-pr --draft calls no CLI"

# github-api: never silently opens a non-draft PR; no HTTP call
set_provider github-api
export GITHUB_TOKEN="test-token-pr-draft"
: > "$CURL_LOG"
out="$(bash "$VCS" create-pr feat/x "T" "$BODY" --draft 2>"$SANDBOX/err.log")"; rc=$?
assert_eq "2" "$rc" "github-api: create-pr --draft exits 2"
assert_eq "" "$out" "github-api: create-pr --draft prints nothing on stdout"
assert_eq "" "$(cat "$CURL_LOG")" "github-api: create-pr --draft makes no HTTP call"
assert_contains "$(cat "$SANDBOX/err.log")" "not supported" "github-api: create-pr --draft explains itself on stderr"
: > "$CURL_LOG"
out="$(bash "$VCS" --dry-run create-pr feat/x "T" "$BODY" --draft 2>&1)"; rc=$?
assert_eq "2" "$rc" "github-api: create-pr --draft --dry-run also exits 2"

# file mode: create-pr --draft stays the existing no-op
set_provider file
out="$(bash "$VCS" create-pr feat/x "T" "$BODY" --draft 2>&1)"; rc=$?
assert_eq "0" "$rc" "file: create-pr --draft is a no-op (exit 0)"
assert_contains "$out" "no PR created" "file: create-pr --draft prints the usual no-op message"

# ── (c) ready-pr / draft-pr ──────────────────────────────────────────────────
set_provider github; : > "$DRAFT_LOG"
bash "$VCS" ready-pr 42 >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "github: ready-pr exits 0"
assert_eq "[pr][ready][42][--repo][acme/widget]" "$(last_log)" "github: ready-pr is gh pr ready <n>"
bash "$VCS" draft-pr 42 >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "github: draft-pr exits 0"
assert_eq "[pr][ready][42][--undo][--repo][acme/widget]" "$(last_log)" "github: draft-pr is gh pr ready <n> --undo"

set_provider gitlab; : > "$DRAFT_LOG"
bash "$VCS" ready-pr 42 >/dev/null 2>&1
assert_eq "GLAB [mr][update][42][--ready][-R][acme/widget]" "$(last_log)" "gitlab: ready-pr is glab mr update <n> --ready"
bash "$VCS" draft-pr 42 >/dev/null 2>&1
assert_eq "GLAB [mr][update][42][--draft][-R][acme/widget]" "$(last_log)" "gitlab: draft-pr is glab mr update <n> --draft"

set_provider azure; : > "$DRAFT_LOG"
bash "$VCS" ready-pr 42 >/dev/null 2>&1
assert_eq "AZ [repos][pr][update][--id][42][--draft][false][--org][https://dev.azure.com/acme][--output][json]" \
  "$(last_log)" "azure: ready-pr is az repos pr update --draft false"
bash "$VCS" draft-pr 42 >/dev/null 2>&1
assert_eq "AZ [repos][pr][update][--id][42][--draft][true][--org][https://dev.azure.com/acme][--output][json]" \
  "$(last_log)" "azure: draft-pr is az repos pr update --draft true"

set_provider github; : > "$DRAFT_LOG"
for v in ready-pr draft-pr; do
  out="$(bash "$VCS" $v "not-a-number" 2>/dev/null)"; rc=$?
  assert_eq "2" "$rc" "github: $v rejects a non-numeric PR id with exit 2"
  assert_eq "" "$out" "github: $v prints nothing for a non-numeric PR id"
done
assert_eq "0" "$(log_lines)" "github: a non-numeric PR id reaches no CLI"

out="$(bash "$VCS" --dry-run ready-pr 42 2>&1)"
assert_contains "$out" "gh pr ready 42" "github: ready-pr --dry-run prints the command"
assert_eq "0" "$(log_lines)" "github: ready-pr --dry-run calls no CLI"

# github-api: exit 2, no HTTP call
set_provider github-api; : > "$CURL_LOG"
for v in ready-pr draft-pr; do
  out="$(bash "$VCS" $v 42 2>/dev/null)"; rc=$?
  assert_eq "2" "$rc" "github-api: $v exits 2"
  assert_eq "" "$out" "github-api: $v prints nothing on stdout"
done
assert_eq "" "$(cat "$CURL_LOG")" "github-api: ready-pr/draft-pr make no HTTP call"

# file mode: exit 2
set_provider file
for v in ready-pr draft-pr; do
  out="$(bash "$VCS" $v 42 2>/dev/null)"; rc=$?
  assert_eq "2" "$rc" "file: $v exits 2"
  assert_eq "" "$out" "file: $v prints nothing on stdout"
done

# ── (d) pr-is-draft ──────────────────────────────────────────────────────────
# check_draft <provider> <label> <draft-json> <ready-json> <garbage-json>
check_draft() {
  local prov="$1" argv="$2" draft_json="$3" ready_json="$4"
  set_provider "$prov"
  : > "$DRAFT_LOG"
  out="$(STUB_RESP="$draft_json" bash "$VCS" pr-is-draft 42 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "$prov: pr-is-draft exits 0 for a draft"
  assert_eq "draft" "$out" "$prov: pr-is-draft prints draft"
  assert_eq "$argv" "$(last_log)" "$prov: pr-is-draft fetches the exact command"

  out="$(STUB_RESP="$ready_json" bash "$VCS" pr-is-draft 42 2>/dev/null)"; rc=$?
  assert_eq "1" "$rc" "$prov: pr-is-draft exits 1 for a ready PR"
  assert_eq "ready" "$out" "$prov: pr-is-draft prints ready"

  out="$(STUB_FAIL=1 STUB_RESP="$ready_json" bash "$VCS" pr-is-draft 42 2>/dev/null)"; rc=$?
  assert_eq "2" "$rc" "$prov: pr-is-draft exits 2 on a failed fetch"
  assert_eq "" "$out" "$prov: pr-is-draft prints nothing on a failed fetch"

  local garbage
  for garbage in 'not json at all' '' '[]' '{}' '{"unrelated":true}' '{"isDraft":"false","draft":"false"}' '{"isDraft":null,"draft":null}' '{"isDraft":0,"draft":0}'; do
    out="$(STUB_RESP="$garbage" bash "$VCS" pr-is-draft 42 2>/dev/null)"; rc=$?
    assert_eq "2" "$rc" "$prov: pr-is-draft exits 2 for response '${garbage:-<empty>}'"
    assert_eq "" "$out" "$prov: pr-is-draft prints nothing for response '${garbage:-<empty>}'"
  done

  : > "$DRAFT_LOG"
  for bad in abc 4x2 "" "-1" "4 2"; do
    out="$(STUB_RESP="$draft_json" bash "$VCS" pr-is-draft "$bad" 2>/dev/null)"; rc=$?
    assert_eq "2" "$rc" "$prov: pr-is-draft exits 2 for PR id '$bad'"
    assert_eq "" "$out" "$prov: pr-is-draft prints nothing for PR id '$bad'"
  done
  assert_eq "0" "$(log_lines)" "$prov: a bad PR id reaches no CLI"
}

check_draft github "[pr][view][42][--json][isDraft][--repo][acme/widget]" '{"isDraft":true}' '{"isDraft":false}'
check_draft gitlab "GLAB [mr][view][42][--output][json][-R][acme/widget]" '{"iid":42,"draft":true}' '{"iid":42,"draft":false}'
check_draft azure "AZ [repos][pr][show][--id][42][--org][https://dev.azure.com/acme][--output][json]" '{"isDraft":true}' '{"isDraft":false}'

# A PR whose fields are all there but only the *other* provider's key: still unverified.
set_provider github
out="$(STUB_RESP='{"draft":true}' bash "$VCS" pr-is-draft 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "github: a response without isDraft is unverified, not ready"
assert_eq "" "$out" "github: a response without isDraft prints nothing"

set_provider github
: > "$DRAFT_LOG"
out="$(bash "$VCS" --dry-run pr-is-draft 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "github: pr-is-draft --dry-run verifies nothing, so exits 2"
assert_eq "" "$out" "github: pr-is-draft --dry-run prints nothing on stdout"
out="$(bash "$VCS" --dry-run pr-is-draft 42 2>&1 >/dev/null)"
assert_contains "$out" "[dry-run] gh pr view 42 --json isDraft" "github: pr-is-draft --dry-run shows the command on stderr"
assert_eq "0" "$(log_lines)" "github: pr-is-draft --dry-run calls no CLI"

for prov in github-api file; do
  set_provider "$prov"; : > "$CURL_LOG"
  out="$(bash "$VCS" pr-is-draft 42 2>/dev/null)"; rc=$?
  assert_eq "2" "$rc" "$prov: pr-is-draft exits 2"
  assert_eq "" "$out" "$prov: pr-is-draft prints nothing on stdout"
  assert_eq "" "$(cat "$CURL_LOG")" "$prov: pr-is-draft makes no HTTP call"
done

# ── (e) pr-ci-runs ───────────────────────────────────────────────────────────
# Runs that executed = pull_request runs for the head branch minus those whose
# conclusion is "skipped" (a draft push whose jobs are all skipped by the
# `draft != true` guard still creates a run).
set_provider github; : > "$DRAFT_LOG"
out="$(STUB_RUNS='{"total_count":5,"workflow_runs":[]}' STUB_RUNS_SKIPPED='{"total_count":3}' bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github: pr-ci-runs exits 0"
assert_eq "2" "$out" "github: pr-ci-runs prints runs that executed (5 total - 3 skipped)"
assert_contains "$(cat "$DRAFT_LOG")" "[api][-X][GET][repos/acme/widget/actions/runs][-f][event=pull_request][-f][branch=feat/x][-F][per_page=1]" \
  "github: pr-ci-runs queries pull_request runs for the PR head branch"
assert_contains "$(cat "$DRAFT_LOG")" "[api][-X][GET][repos/acme/widget/actions/runs][-f][event=pull_request][-f][branch=feat/x][-f][status=skipped][-F][per_page=1]" \
  "github: pr-ci-runs also queries the skipped-conclusion total"
assert_contains "$(cat "$DRAFT_LOG")" "[pr][view][42][--json][headRefName][--repo][acme/widget]" \
  "github: pr-ci-runs resolves the head branch from the PR"

out="$(STUB_RUNS='{"total_count":3}' bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github: pr-ci-runs exits 0 when nothing was skipped"
assert_eq "3" "$out" "github: pr-ci-runs counts every run when none were skipped"

out="$(STUB_RUNS='{"total_count":4}' STUB_RUNS_SKIPPED='{"total_count":4}' bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github: pr-ci-runs exits 0 when every run was skipped"
assert_eq "0" "$out" "github: pr-ci-runs prints a real 0 when every run was skipped"

out="$(STUB_RUNS='{"total_count":0}' bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "github: pr-ci-runs exits 0 for zero runs"
assert_eq "0" "$out" "github: pr-ci-runs prints a real 0"

# more skipped than total is inconsistent data: unverified, never a negative count
out="$(STUB_RUNS='{"total_count":2}' STUB_RUNS_SKIPPED='{"total_count":3}' bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "github: pr-ci-runs exits 2 when skipped exceeds the total"
assert_eq "" "$out" "github: pr-ci-runs prints nothing when skipped exceeds the total"

for bad in '' 'not json' '[]' '{}' '{"total_count":"3"}' '{"total_count":-1}' '{"total_count":true}' '{"total_count":1.5}'; do
  out="$(STUB_RUNS="$bad" bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
  assert_eq "2" "$rc" "github: pr-ci-runs exits 2 for runs response '${bad:-<empty>}'"
  assert_eq "" "$out" "github: pr-ci-runs prints nothing for runs response '${bad:-<empty>}'"
  out="$(STUB_RUNS='{"total_count":5}' STUB_RUNS_SKIPPED="$bad" bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
  assert_eq "2" "$rc" "github: pr-ci-runs exits 2 for skipped response '${bad:-<empty>}'"
  assert_eq "" "$out" "github: pr-ci-runs prints nothing for skipped response '${bad:-<empty>}'"
done

# GitHub caps filtered run searches at 1000 results: a total (either query)
# that reaches the cap is unverified, never reported as a (short) count.
out="$(STUB_RUNS='{"total_count":1000}' bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "github: pr-ci-runs exits 2 when the total reaches the 1000-result cap"
assert_eq "" "$out" "github: pr-ci-runs prints no short count at the cap"
out="$(STUB_RUNS='{"total_count":999}' STUB_RUNS_SKIPPED='{"total_count":1000}' bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "github: pr-ci-runs exits 2 when the skipped total reaches the cap"
assert_eq "" "$out" "github: pr-ci-runs prints no short count when the skipped total is capped"

out="$(STUB_RUNS_FAIL=1 STUB_RUNS='{"total_count":3}' bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "github: pr-ci-runs exits 2 when the runs fetch fails"
assert_eq "" "$out" "github: pr-ci-runs prints nothing when the runs fetch fails"
out="$(STUB_RUNS_SKIPPED_FAIL=1 STUB_RUNS='{"total_count":3}' bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "github: pr-ci-runs exits 2 when the skipped fetch fails"
assert_eq "" "$out" "github: pr-ci-runs prints nothing when the skipped fetch fails"

out="$(STUB_FAIL=1 STUB_RUNS='{"total_count":3}' bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "github: pr-ci-runs exits 2 when the head branch cannot be fetched"
assert_eq "" "$out" "github: pr-ci-runs prints nothing when the head branch cannot be fetched"

out="$(STUB_HEAD='{"headRefName":""}' STUB_RUNS='{"total_count":3}' bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "github: pr-ci-runs exits 2 for an empty head branch"
assert_eq "" "$out" "github: pr-ci-runs prints nothing for an empty head branch"

: > "$DRAFT_LOG"
for bad in abc "" "4x"; do
  out="$(STUB_RUNS='{"total_count":3}' bash "$VCS" pr-ci-runs "$bad" 2>/dev/null)"; rc=$?
  assert_eq "2" "$rc" "github: pr-ci-runs exits 2 for PR id '$bad'"
  assert_eq "" "$out" "github: pr-ci-runs prints nothing for PR id '$bad'"
done
assert_eq "0" "$(log_lines)" "github: a bad PR id reaches no CLI"

out="$(bash "$VCS" --dry-run pr-ci-runs 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "github: pr-ci-runs --dry-run verifies nothing, so exits 2"
assert_eq "" "$out" "github: pr-ci-runs --dry-run prints nothing on stdout"

for prov in github-api gitlab azure file; do
  set_provider "$prov"; : > "$CURL_LOG"
  out="$(bash "$VCS" pr-ci-runs 42 2>/dev/null)"; rc=$?
  assert_eq "2" "$rc" "$prov: pr-ci-runs exits 2 (github only)"
  assert_eq "" "$out" "$prov: pr-ci-runs prints nothing on stdout"
  assert_eq "" "$(cat "$CURL_LOG")" "$prov: pr-ci-runs makes no HTTP call"
done

# ── (f) setup errors are exit 2, never a result ──────────────────────────────
# pr-is-draft / pr-ci-runs feed gates: exit 0 only with stdout exactly "draft"
# (or a count), exit 1 only with stdout exactly "ready"; ready-pr / draft-pr
# exit 0 only on success. Anything else -- no token, unknown provider, missing
# CLI -- is exit 2 with nothing on stdout.
check_setup_error() {  # $1 = label
  local v
  for v in pr-is-draft pr-ci-runs ready-pr draft-pr; do
    out="$(bash "$VCS" "$v" 42 2>/dev/null)"; rc=$?
    assert_eq "2" "$rc" "$1: $v exits 2"
    assert_eq "" "$out" "$1: $v prints nothing on stdout"
  done
  out="$(bash "$VCS" create-pr feat/x "T" "$BODY" --draft 2>/dev/null)"; rc=$?
  assert_eq "2" "$rc" "$1: create-pr --draft exits 2"
  assert_eq "" "$out" "$1: create-pr --draft prints nothing on stdout"
}

set_provider github-api
(unset GITHUB_TOKEN GH_TOKEN; check_setup_error "github-api without a token")

printf '{"vcs": {"provider": "bitbucket", "repo": "acme/widget"}, "base_branch": "main"}\n' > talos.pipeline.json
check_setup_error "unknown provider"

# Missing CLI: a PATH without gh/glab/az (skipped when the machine really has one there).
BASH_BIN="$(command -v bash)"
for prov_cli in "gitlab glab" "azure az" "github gh"; do
  prov="${prov_cli% *}"; cli="${prov_cli#* }"
  if PATH="/usr/bin:/bin" command -v "$cli" >/dev/null 2>&1; then
    pass "missing $cli: skipped, $cli is installed in /usr/bin or /bin"
    continue
  fi
  set_provider "$prov"
  for v in pr-is-draft pr-ci-runs ready-pr draft-pr; do
    out="$(PATH="/usr/bin:/bin" "$BASH_BIN" "$VCS" "$v" 42 2>/dev/null)"; rc=$?
    assert_eq "2" "$rc" "$prov without $cli: $v exits 2"
    assert_eq "" "$out" "$prov without $cli: $v prints nothing on stdout"
  done
done

# A failing gh pr ready is a failure, not a result.
set_provider github
for v in ready-pr draft-pr; do
  out="$(STUB_FAIL=1 bash "$VCS" "$v" 42 2>/dev/null)"; rc=$?
  assert_eq "2" "$rc" "github: $v exits 2 when gh fails"
  assert_eq "" "$out" "github: $v prints nothing when gh fails"
done

# ── pr.draft is a known config key ───────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"pr": {"draft": true}}
EOF
dump_err="$(bash "$TALOS_ROOT/scripts/pipeline-config.sh" --dump 2>&1 >/dev/null)"
assert_not_contains "$dump_err" "unknown" "config --dump: pr.draft raises no unknown-key warning"
dump_out="$(bash "$TALOS_ROOT/scripts/pipeline-config.sh" --dump 2>/dev/null)"
assert_contains "$dump_out" "pr.draft" "config --dump: pr.draft is dumped"

finish
