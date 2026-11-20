#!/usr/bin/env bash
# test-ref-checks-required-928.sh -- merge queue 1/5 (#928): the merge.queue*
# config keys, and `pipeline-vcs.sh ref-checks-required <sha|branch>`, which
# judges merge.required_checks on a commit or a branch head (not a PR) on
# github, gitlab, azure and file with one contract: exit 0 all pass, 1 one
# failed, 2 pending or missing, 3 could not judge (nothing on stdout).
# Uses the gh / glab / az stubs and a sandbox repo; no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
CONFIG="$TALOS_ROOT/scripts/pipeline-config.sh"
DEFAULTS="$TALOS_ROOT/scripts/pipeline-defaults.sh"
SHA="1111111111111111111111111111111111111111"
OTHER="2222222222222222222222222222222222222222"
ERR="$SANDBOX/err.txt"

# _run <args...>: runs the verb; sets OUT (stdout), ERRS (stderr) and RC.
_run() {
  OUT="$(bash "$VCS" ref-checks-required "$@" 2>"$ERR")"; RC=$?
  ERRS="$(cat "$ERR")"
}
# _kind: "could not read" / "could not parse" / "other", from the reason line.
_kind() {
  case "$ERRS" in
    *"pipeline-vcs: ref-checks-required: could not read"*) printf 'read' ;;
    *"pipeline-vcs: ref-checks-required: could not parse"*) printf 'parse' ;;
    *"pipeline-vcs: ref-checks-required: could not resolve"*) printf 'resolve' ;;
    *) printf 'other' ;;
  esac
}
_lines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }
_no_calls() { cat "$GH_LOG" "$GH_LOG.rest" "$CURL_LOG" 2>/dev/null; }
_reset_logs() { : > "$GH_LOG"; : > "$GH_LOG.rest"; : > "$CURL_LOG"; }

# ── AC1: the three keys and their defaults ───────────────────────────────────
printf '{}\n' > talos.pipeline.json
assert_eq "off" "$(bash "$CONFIG" merge.queue 2>/dev/null)" "AC1 merge.queue defaults to off"
assert_eq "3" "$(bash "$CONFIG" merge.queue_batch 2>/dev/null)" "AC1 merge.queue_batch defaults to 3"
assert_eq "talos/queue/" "$(bash "$CONFIG" merge.queue_branch_prefix 2>/dev/null)" "AC1 merge.queue_branch_prefix defaults to talos/queue/"
_row() { grep -E "^$1	" "$DEFAULTS" | head -n 1; }
assert_eq "merge.queue	enum	off	-	-	any" "$(_row 'merge\.queue')" "AC1 merge.queue row: enum, off, derived -, env -, scope any"
assert_eq "merge.queue_batch	int	3	-	-	any" "$(_row 'merge\.queue_batch')" "AC1 merge.queue_batch row: int, 3, derived -, env -, scope any"
assert_eq "merge.queue_branch_prefix	str	talos/queue/	-	-	any" "$(_row 'merge\.queue_branch_prefix')" "AC1 merge.queue_branch_prefix row: str, talos/queue/, derived -, env -, scope any"
python3 -I "$TALOS_ROOT/tests/check-defaults-table.py" >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "AC1 tests/check-defaults-table.py accepts the table"

# ── github ───────────────────────────────────────────────────────────────────
_gh_config() {
  printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "merge": {"required_checks": %s}}\n' "$1" > talos.pipeline.json
}
_gh_config '["build", "test"]'
export STUB_GH_COMMIT_SHA="$SHA"
_reset_logs
STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://ci/b\ntest\tpass\t2m\thttps://ci/t\nlint\tfail\t0\thttps://ci/l')" _run "$SHA"
assert_eq "0" "$RC" "AC3 github sha: both required checks green exits 0"
assert_eq "2" "$(_lines "$OUT")" "AC3 github sha: two lines on stdout (only the required checks)"
assert_contains "$OUT" "$(printf 'build\tpass\t')" "AC3 github sha: a pr-checks-shaped line for build"
assert_contains "$(cat "$GH_LOG.rest")" "commits/$SHA/check-runs" "AC3 github sha: the check runs of that sha are read"
_reset_logs
STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://ci/b\ntest\tpass\t2m\thttps://ci/t')" _run feature/x
assert_eq "0" "$RC" "AC3 github branch: both green exits 0"
assert_eq "2" "$(_lines "$OUT")" "AC3 github branch: two lines on stdout"
assert_contains "$(cat "$GH_LOG.rest")" "commits/feature%2Fx" "AC3 github branch: the branch is resolved through commits/<ref>"
assert_contains "$(cat "$GH_LOG.rest")" "commits/$SHA/check-runs" "AC3 github branch: the checks of the resolved sha are read"
for ref in "$SHA" feature/x; do
  STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://ci/b\ntest\tfail\t2m\thttps://ci/t')" _run "$ref"
  assert_eq "1" "$RC" "AC3 github $ref: one failed exits 1"
  assert_contains "$ERRS" "pr-checks-required: failed: test" "AC3 github $ref: names the failed check"
  STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://ci/b\ntest\tpending\t0\thttps://ci/t')" _run "$ref"
  assert_eq "2" "$RC" "AC3 github $ref: one running exits 2"
  STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://ci/b')" _run "$ref"
  assert_eq "2" "$RC" "AC3 github $ref: one unreported exits 2"
done

GREEN_GH="$(printf 'build\tpass\t1m\thttps://ci/b\ntest\tpass\t2m\thttps://ci/t')"
STUB_GH_API_FAIL=commit STUB_PR_CHECKS="$GREEN_GH" _run feature/x
assert_eq "3||resolve" "$RC|$OUT|$(_kind)" "AC7 github ref read failure exits 3"
STUB_GH_API_FAIL=check-runs STUB_PR_CHECKS="$GREEN_GH" _run feature/x
assert_eq "3||read" "$RC|$OUT|$(_kind)" "AC7 github read failure exits 3"
STUB_GH_COMMIT_RAW='not json' STUB_PR_CHECKS="$GREEN_GH" _run feature/x
assert_eq "3|" "$RC|$OUT" "AC7 github unparseable response exits 3"
STUB_GH_COMMIT_SHA="abc123" STUB_PR_CHECKS="$GREEN_GH" _run feature/x
assert_eq "3|" "$RC|$OUT" "AC7 github a resolved value that is not a sha exits 3"
_gh_config '[]'
STUB_PR_CHECKS="$GREEN_GH" _run "$SHA"
assert_eq "3|" "$RC|$OUT" "AC7 github empty merge.required_checks exits 3"
assert_contains "$ERRS" "pipeline-vcs: ref-checks-required: " "AC7 github empty list prints the reason line"
_gh_config '["build", "test"]'
for ref in -x a..b "a b" "x;y" ""; do
  _reset_logs
  _run "$ref"
  assert_eq "3||" "$RC|$OUT|$(_no_calls)" "AC8 github ref '$ref' exits 3 with no stub call"
done
unset STUB_GH_COMMIT_SHA

# ── gitlab ───────────────────────────────────────────────────────────────────
git remote set-url origin git@gitlab.com:acme/widget.git
_gl_config() {
  printf '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}, "merge": {"required_checks": %s}}\n' "$1" > talos.pipeline.json
}
_job() { printf '{"id":%s,"name":"%s","status":"%s","duration":62.5,"web_url":"https://gl/j/%s"}' "$1" "$2" "$3" "$1"; }
_gl_config '["build", "test"]'
export STUB_GITLAB_COMMIT="{\"id\":\"$SHA\"}"
export STUB_GITLAB_PIPELINES='[{"id":501,"sha":"'"$SHA"'","status":"running"}]'
_reset_logs
STUB_GITLAB_PIPELINE_JOBS="[$(_job 1 build success),$(_job 2 test success),$(_job 3 lint failed)]" _run feature/x
assert_eq "0" "$RC" "AC4 gitlab every job success exits 0"
assert_eq "2" "$(_lines "$OUT")" "AC4 gitlab prints one line per required job"
assert_contains "$OUT" "$(printf 'build\tpass\t1m2s\thttps://gl/j/1')" "AC4 gitlab line carries elapsed from duration and url from web_url"
assert_contains "$(cat "$GH_LOG")" "repository/commits/feature%2Fx" "AC4 gitlab resolves the branch through repository/commits/<ref>"
assert_contains "$(cat "$GH_LOG")" "pipelines?sha=$SHA&order_by=id&sort=desc&per_page=1" "AC4 gitlab reads the newest pipeline of the sha"
assert_contains "$(cat "$GH_LOG")" "api --paginate projects/acme%2Fwidget/pipelines/501/jobs" "AC4 gitlab reads every page of that pipeline's jobs"
STUB_GITLAB_PIPELINE_JOBS="[$(_job 1 build success),$(_job 2 test failed)]" _run "$SHA"
assert_eq "1" "$RC" "AC4 gitlab a failed job exits 1"
assert_contains "$ERRS" "pr-checks-required: failed: test" "AC4 gitlab names the failed job"
STUB_GITLAB_PIPELINE_JOBS="[$(_job 1 build success),$(_job 2 test running)]" _run "$SHA"
assert_eq "2" "$RC" "AC4 gitlab a running job exits 2"
STUB_GITLAB_PIPELINE_JOBS="[$(_job 1 build success)]" _run "$SHA"
assert_eq "2" "$RC" "AC4 gitlab a missing job exits 2"
STUB_GITLAB_PIPELINE_JOBS="[$(_job 9 test failed),$(_job 4 test success),$(_job 1 build success)]" _run "$SHA"
assert_eq "1" "$RC" "AC4 gitlab of two same-name jobs the higher id decides (failed)"
STUB_GITLAB_PIPELINE_JOBS="[$(_job 4 test failed),$(_job 9 test success),$(_job 1 build success)]" _run "$SHA"
assert_eq "0" "$RC" "AC4 gitlab of two same-name jobs the higher id decides (passed)"
STUB_GITLAB_PIPELINES='[]' STUB_GITLAB_PIPELINE_JOBS="[$(_job 1 build success),$(_job 2 test success)]" _run "$SHA"
assert_eq "2|" "$RC|$OUT" "AC4 gitlab no pipeline for the sha exits 2"

GREEN_GL="[$(_job 1 build success),$(_job 2 test success)]"
STUB_GITLAB_COMMIT_FAIL=1 STUB_GITLAB_PIPELINE_JOBS="$GREEN_GL" _run feature/x
assert_eq "3||resolve" "$RC|$OUT|$(_kind)" "AC7 gitlab ref read failure exits 3"
STUB_GITLAB_JOBS_FAIL=1 STUB_GITLAB_PIPELINE_JOBS="$GREEN_GL" _run feature/x
assert_eq "3||read" "$RC|$OUT|$(_kind)" "AC7 gitlab read failure exits 3"
STUB_GITLAB_PIPELINES_FAIL=1 STUB_GITLAB_PIPELINE_JOBS="$GREEN_GL" _run feature/x
assert_eq "3||read" "$RC|$OUT|$(_kind)" "AC7 gitlab a failed pipeline read exits 3"
STUB_GITLAB_PIPELINE_JOBS='not json' _run feature/x
assert_eq "3||parse" "$RC|$OUT|$(_kind)" "AC7 gitlab unparseable response exits 3"
STUB_GITLAB_COMMIT='{"id":"nope"}' STUB_GITLAB_PIPELINE_JOBS="$GREEN_GL" _run feature/x
assert_eq "3|" "$RC|$OUT" "AC7 gitlab a resolved value that is not a sha exits 3"
_gl_config '[]'
STUB_GITLAB_PIPELINE_JOBS="$GREEN_GL" _run "$SHA"
assert_eq "3|" "$RC|$OUT" "AC7 gitlab empty merge.required_checks exits 3"
_gl_config '["build", "test"]'
for ref in -x a..b "a b" "x;y" ""; do
  _reset_logs
  _run "$ref"
  assert_eq "3||" "$RC|$OUT|$(_no_calls)" "AC8 gitlab ref '$ref' exits 3 with no stub call"
done
unset STUB_GITLAB_COMMIT STUB_GITLAB_PIPELINES

# ── azure ────────────────────────────────────────────────────────────────────
_az_config() {
  printf '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}, "merge": {"required_checks": %s}}\n' "$1" > talos.pipeline.json
}
# One status: $1 state, $2 context.name, $3 context.genre ("" = none).
_st() {
  local g=""
  [ -n "${3:-}" ] && g=",\"genre\":\"$3\""
  printf '{"state":"%s","context":{"name":"%s"%s},"targetUrl":"https://az/%s"}' "$1" "$2" "$g" "$2"
}
_sts() { printf '{"count":2,"value":[%s]}' "$1"; }
_az_config '["Build", "ci/test"]'
export STUB_AZURE_REFS="{\"value\":[{\"name\":\"refs/heads/feature/xy\",\"objectId\":\"$OTHER\"},{\"name\":\"refs/heads/feature/x\",\"objectId\":\"$SHA\"}]}"
_reset_logs
STUB_AZURE_STATUSES="$(_sts "$(_st succeeded build),$(_st succeeded test ci),$(_st failed lint)")" _run "$SHA"
assert_eq "0" "$RC" "AC5 azure succeeded exits 0"
assert_eq "2" "$(_lines "$OUT")" "AC5 azure prints one line per required check"
assert_contains "$OUT" "$(printf 'Build\tpass\t')" "AC5 azure name matching is case-insensitive (Build matches build)"
assert_contains "$OUT" "$(printf 'ci/test\tpass\t')" "AC5 azure genre/name matches"
assert_contains "$(cat "$GH_LOG")" "/commits/$SHA/statuses?latestOnly=true" "AC5 azure reads the latest statuses of the sha"
STUB_AZURE_STATUSES="$(_sts "$(_st succeeded build),$(_st failed test ci)")" _run "$SHA"
assert_eq "1" "$RC" "AC5 azure failed exits 1"
assert_contains "$ERRS" "pr-checks-required: failed: ci/test" "AC5 azure names the failed check"
STUB_AZURE_STATUSES="$(_sts "$(_st succeeded build),$(_st error test ci)")" _run "$SHA"
assert_eq "1" "$RC" "AC5 azure error exits 1"
STUB_AZURE_STATUSES="$(_sts "$(_st succeeded build),$(_st pending test ci)")" _run "$SHA"
assert_eq "2" "$RC" "AC5 azure pending exits 2"
STUB_AZURE_STATUSES="$(_sts "$(_st succeeded build),$(_st notApplicable test ci)")" _run "$SHA"
assert_eq "2" "$RC" "AC5 azure notApplicable exits 2"
STUB_AZURE_STATUSES="$(_sts "$(_st succeeded build)")" _run "$SHA"
assert_eq "2" "$RC" "AC5 azure missing exits 2"
STUB_AZURE_STATUSES="$(_sts "$(_st succeeded BUILD),$(_st succeeded TEST CI)")" _run "$SHA"
assert_eq "0" "$RC" "AC5 azure name matching is case-insensitive"
_reset_logs
STUB_AZURE_STATUSES="$(_sts "$(_st succeeded build),$(_st succeeded test ci)")" _run feature/x
assert_eq "0" "$RC" "AC5 azure a branch resolves through refs"
assert_contains "$(cat "$GH_LOG")" "/refs?filter=heads/feature%2Fx" "AC5 azure the branch is read through refs?filter=heads/<branch>"
assert_contains "$(cat "$GH_LOG")" "/commits/$SHA/statuses" "AC5 azure the exact refs/heads/<branch> head is judged, not a prefix match"
STUB_AZURE_STATUSES="$(_sts "$(_st succeeded build),$(_st succeeded test ci)")" _run feature/none
assert_eq "3||resolve" "$RC|$OUT|$(_kind)" "AC5 azure a branch with no exact ref exits 3"

GREEN_AZ="$(_sts "$(_st succeeded build),$(_st succeeded test ci)")"
STUB_AZURE_REFS_FAIL=1 STUB_AZURE_STATUSES="$GREEN_AZ" _run feature/x
assert_eq "3||resolve" "$RC|$OUT|$(_kind)" "AC7 azure ref read failure exits 3"
STUB_AZURE_STATUSES_FAIL=1 STUB_AZURE_STATUSES="$GREEN_AZ" _run feature/x
assert_eq "3||read" "$RC|$OUT|$(_kind)" "AC7 azure read failure exits 3"
STUB_AZURE_STATUSES='not json' _run feature/x
assert_eq "3||parse" "$RC|$OUT|$(_kind)" "AC7 azure unparseable response exits 3"
STUB_AZURE_REFS='not json' STUB_AZURE_STATUSES="$GREEN_AZ" _run feature/x
assert_eq "3|" "$RC|$OUT" "AC7 azure unparseable refs response exits 3"
_az_config '[]'
STUB_AZURE_STATUSES="$GREEN_AZ" _run "$SHA"
assert_eq "3|" "$RC|$OUT" "AC7 azure empty merge.required_checks exits 3"
_az_config '["Build", "ci/test"]'
for ref in -x a..b "a b" "x;y" ""; do
  _reset_logs
  _run "$ref"
  assert_eq "3||" "$RC|$OUT|$(_no_calls)" "AC8 azure ref '$ref' exits 3 with no stub call"
done
unset STUB_AZURE_REFS

# ── file ─────────────────────────────────────────────────────────────────────
_file_config() {
  printf '{"vcs": {"provider": "file"}, "merge": {"required_checks": %s}}\n' "$1" > talos.pipeline.json
}
_file_config '["build", "test"]'
git commit -q --allow-empty -m one
git branch feature/x
FSHA="$(git rev-parse HEAD)"
STORE="$(git rev-parse --git-common-dir)/talos-checks"
mkdir -p "$STORE"
_tsv() { printf '%b' "$1" > "$STORE/$FSHA.tsv"; }
_tsv 'build\tpass\t1m\thttps://ci/b\ntest\tpass\t2m\thttps://ci/t\nlint\tfail\t0\t\n'
_run "$FSHA"
assert_eq "0" "$RC" "AC6 file all pass exits 0"
assert_eq "$(printf 'build\tpass\t1m\thttps://ci/b\ntest\tpass\t2m\thttps://ci/t')" "$OUT" "AC6 file prints the required lines"
_run feature/x
assert_eq "0" "$RC" "AC6 file a branch name reads its head sha's tsv"
_tsv 'build\tpass\t1m\thttps://ci/b\ntest\tfail\t2m\thttps://ci/t\n'
_run "$FSHA"
assert_eq "1" "$RC" "AC6 file one fail exits 1"
assert_contains "$ERRS" "pr-checks-required: failed: test" "AC6 file names the failed check"
_tsv 'build\tpass\t1m\thttps://ci/b\ntest\tskipping\t0\t\n'
_run "$FSHA"
assert_eq "2" "$RC" "AC6 file a skipping check is pending (exit 2)"
rm -f "$STORE/$FSHA.tsv"
_run "$FSHA"
assert_eq "2|" "$RC|$OUT" "AC6 file no tsv exits 2"

_tsv 'build\tpass\t1m\thttps://ci/b\ntest\tpass\t2m\thttps://ci/t\n'
_run "$OTHER"
assert_eq "3||resolve" "$RC|$OUT|$(_kind)" "AC7 file ref read failure exits 3"
_run no-such-branch
assert_eq "3||resolve" "$RC|$OUT|$(_kind)" "AC7 file an unknown branch exits 3"
rm -f "$STORE/$FSHA.tsv"; mkdir "$STORE/$FSHA.tsv"
_run "$FSHA"
assert_eq "3||read" "$RC|$OUT|$(_kind)" "AC7 file read failure exits 3"
rmdir "$STORE/$FSHA.tsv"
_tsv 'build\tpass\t1m\thttps://ci/b\ntest\tgreen\n'
_run "$FSHA"
assert_eq "3||parse" "$RC|$OUT|$(_kind)" "AC7 file unparseable response (a malformed line) exits 3"
_tsv 'build\tpass\t1m\thttps://ci/b\ntest\tpass\t2m\thttps://ci/t\n'
_file_config '[]'
_run "$FSHA"
assert_eq "3|" "$RC|$OUT" "AC7 file empty merge.required_checks exits 3"
_file_config '["build", "test"]'
for ref in -x a..b "a b" "x;y" ""; do
  _run "$ref"
  assert_eq "3|" "$RC|$OUT" "AC8 file ref '$ref' exits 3"
done

# ── AC10 (same): pr-checks and pr-checks-required are unchanged ──────────────
# Green before and after the github check-table split and the gitlab script move.
_pr() { OUT="$(bash "$VCS" "$@" 2>"$ERR")"; RC=$?; ERRS="$(cat "$ERR")"; }
_summary() { printf '%s\n' "$ERRS" | grep '^pr-checks-required: ' | tail -n 1; }
git remote set-url origin git@github.com:acme/widget.git
_gh_config '["build", "test"]'
STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://ci/b\ntest\tfail\t2m\thttps://ci/t\nlint\tpending\t0\thttps://ci/l')" _pr pr-checks 9
assert_eq "1|$(printf 'build\tpass\t1m2s\thttps://ci/b\ntest\tfail\t1m2s\thttps://ci/t\nlint\tpending\t0\thttps://ci/l')" "$RC|$OUT" \
  "AC10 github pr-checks prints every check and exits 1 on a failure"
STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://ci/b\nlint\tpending\t0\thttps://ci/l')" _pr pr-checks 9
assert_eq "8" "$RC" "AC10 github pr-checks exits 8 while one is pending"
STUB_PR_CHECKS="$GREEN_GH" _pr pr-checks-required 9
assert_eq "0||pr-checks-required: all required checks passed: build, test" "$RC|$OUT|$(_summary)" "AC10 github pr-checks-required all green exits 0"
STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://ci/b\ntest\tcancel\t2m\thttps://ci/t')" _pr pr-checks-required 9
assert_eq "1||pr-checks-required: failed: test" "$RC|$OUT|$(_summary)" "AC10 github pr-checks-required a cancelled check exits 1"
STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://ci/b\ntest\tskipping\t0\thttps://ci/t')" _pr pr-checks-required 9
assert_eq "2||pr-checks-required: pending or missing: test" "$RC|$OUT|$(_summary)" "AC10 github pr-checks-required a skipped check exits 2"
STUB_GH_API_FAIL=pr STUB_PR_CHECKS="$GREEN_GH" _pr pr-checks-required 9
assert_eq "2" "$RC" "AC10 github pr-checks-required a failed read is still exit 2"

git remote set-url origin git@gitlab.com:acme/widget.git
_mr() { printf '{"iid":9,"sha":"%s","head_pipeline":{"id":501,"status":"%s","sha":"%s"}}' "$SHA" "$1" "$SHA"; }
_gl_config '["build", "test"]'
STUB_GITLAB_MR_API="$(_mr running)" STUB_GITLAB_PIPELINE_JOBS="$GREEN_GL" _pr pr-checks-required 9
assert_eq "0||pr-checks-required: all required checks passed: build, test" "$RC|$OUT|$(_summary)" "AC10 gitlab pr-checks-required named jobs green exits 0"
STUB_GITLAB_MR_API="$(_mr running)" STUB_GITLAB_PIPELINE_JOBS="[$(_job 9 test failed),$(_job 4 test success),$(_job 1 build success)]" _pr pr-checks-required 9
assert_eq "1||pr-checks-required: failed: test" "$RC|$OUT|$(_summary)" "AC10 gitlab pr-checks-required the highest job id decides"
STUB_GITLAB_MR_API="$(_mr running)" STUB_GITLAB_PIPELINE_JOBS='not json' _pr pr-checks-required 9
assert_eq "1" "$RC" "AC10 gitlab pr-checks-required unparseable jobs still exit 1"
_gl_config '[]'
STUB_GITLAB_MR_API="$(_mr success)" _pr pr-checks-required 9
assert_eq "0||pr-checks-required: all required checks passed: pipeline 501" "$RC|$OUT|$(_summary)" "AC10 gitlab pr-checks-required the head pipeline stands in for an empty list"
STUB_GITLAB_MR_API="$(_mr failed)" _pr pr-checks-required 9
assert_eq "1" "$RC" "AC10 gitlab pr-checks-required a failed head pipeline exits 1"

# ── AC11 (same): nothing outside the defaults table and docs reads merge.queue* ─
_readers="$(git -C "$TALOS_ROOT" grep -l -e 'merge\.queue' -- . ':(exclude)docs' ':(exclude)tests' ':(exclude)*.md' \
  ':(exclude)scripts/pipeline-defaults.sh' ':(exclude)talos.pipeline.json.example')"; _grc=$?
assert_eq "1|" "$_grc|$_readers" "AC11 no script outside scripts/pipeline-defaults.sh reads merge.queue* (git grep finds none)"

finish
