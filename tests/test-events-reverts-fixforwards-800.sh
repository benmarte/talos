#!/usr/bin/env bash
# test-events-reverts-fixforwards-800.sh -- the scoreboard counts reverts and
# fix-forwards of Talos-merged PRs (#800, slice 5 of #790), read on demand
# through the new `list-default-commits` and `list-regresses` verbs of
# pipeline-vcs.sh. Tests are named by the spec's criterion id (AC1 ...).
#   AC1  list-default-commits on github: shape, --since, --dry-run
#   AC2  list-default-commits on gitlab and azure: the same shape
#   AC3  list-regresses on github: only `**Regresses:** #<n>` lines
#   AC4  list-regresses on gitlab and azure: the same shape
#   AC5  the file provider and a read that hits its page cap exit 1
#   AC6  a `Revert "..."` commit is a revert of the last #<n> that has a merged event
#   AC7  a `**Regresses:**` line is a fix-forward, once per regressed PR
#   AC8  the two new columns; the row's repo; --repo, --since; a revert-only week
#   AC9  a failed read is unknown (? / null), never 0; the exit stays 0
#   AC10 no other verb and no normal run reads the provider
#   AC12 the PM and developer prompts carry the **Regresses:** line
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
LOG="$SANDBOX/.git/talos/events.jsonl"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
unset TALOS_ROLE TALOS_RUN_STARTED
git config user.email "test@talos.invalid"
git config user.name "talos-test"

jget() { python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); print(json.dumps(eval(sys.argv[2])))' "$1" "$2"; }
# vcs ARGS... : run the verb, stdout to $OUT, stderr to $ERR, status to $RC.
vcs() { OUT="$(bash "$VCS" "$@" 2>"$SANDBOX/err")"; RC=$?; ERR="$(cat "$SANDBOX/err")"; }
# cfg_github / cfg_gitlab / cfg_azure / cfg_file: point the sandbox at one provider.
cfg_github() {
  printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
  export GH_QUEUE="$CURL_QUEUE" GH_LINK_QUEUE="$CURL_LINK_QUEUE" GH_REST_LOG="$CURL_LOG"
  : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"; : > "$CURL_LOG"; : > "$GH_LOG"
}
cfg_gitlab() {
  git remote set-url origin git@gitlab.com:acme/widget.git
  printf '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
  : > "$GH_LOG"
}
cfg_azure() {
  printf '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}\n' > "$PIPELINE_CONFIG"
  : > "$GH_LOG"
}
cfg_file() {
  printf 'item\n' > "$SANDBOX/plan.md"
  printf '{"vcs": {"provider": "file", "file": {"source": {"path": "%s"}}}}\n' "$SANDBOX/plan.md" > "$PIPELINE_CONFIG"
}
# queue FILE JSON: one canned response for the next provider call.
queue() { printf '%s\n' "$2" >> "$1"; }

# ghc SHA SUBJECT DATE: one raw GitHub commit (the message has a body line too).
ghc() {
  python3 -I -c '
import json, sys
sha, subject, date = sys.argv[1:4]
print(json.dumps({"sha": sha, "commit": {"message": subject + "\n\nbody line", "committer": {"date": date}}}))' "$@"
}
# gh_issue NUMBER KIND DATE BODY: one raw GitHub issues-endpoint item (KIND issue|pr).
gh_issue() {
  python3 -I -c '
import json, sys
n, kind, date, body = sys.argv[1:5]
d = {"number": int(n), "created_at": date, "body": body or None, "title": "t"}
if kind == "pr":
    d["pull_request"] = {"url": "x"}
print(json.dumps(d))' "$@"
}
arr() { local IFS=,; printf '[%s]' "$*"; }

NL=$'\n'
# ── AC1 ─────────────────────────────────────────────────────────────────────
cfg_github
queue "$CURL_QUEUE" "$(arr "$(ghc aaa111 'Revert "feat: x (#799) (#804)"' 2026-10-14T10:00:00Z)" "$(ghc bbb222 'feat: y (#805)' 2026-10-13T10:00:00Z)")"
vcs list-default-commits --since 2026-10-01
assert_eq "0" "$RC" "AC1 list-default-commits exits 0"
assert_eq '[{"sha": "aaa111", "subject": "Revert \"feat: x (#799) (#804)\"", "date": "2026-10-14T10:00:00Z"}, {"sha": "bbb222", "subject": "feat: y (#805)", "date": "2026-10-13T10:00:00Z"}]' "$OUT" \
  "AC1 prints [{sha, subject, date}] with the first line of the message as the subject"
assert_contains "$(cat "$CURL_LOG")" "/commits?" "AC1 reads the commits endpoint"
assert_contains "$(cat "$CURL_LOG")" "since=2026-10-01" "AC1 passes --since to the provider"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "release"}\n' > "$PIPELINE_CONFIG"
: > "$CURL_LOG"; queue "$CURL_QUEUE" '[]'
vcs list-default-commits
assert_eq "[]" "$OUT" "AC1 an empty history prints []"
assert_contains "$(cat "$CURL_LOG")" "sha=release" "AC1 reads base_branch"
assert_not_contains "$(cat "$CURL_LOG")" "since=" "AC1 no --since, no since parameter"
cfg_github
vcs --dry-run list-default-commits --since 2026-10-01
assert_eq "0" "$RC" "AC1 --dry-run exits 0"
assert_contains "$OUT" "[dry-run]" "AC1 --dry-run describes the call"
assert_eq "0" "$(wc -c < "$CURL_LOG" | tr -d ' ')" "AC1 --dry-run makes no call"
vcs list-default-commits --since yesterday
assert_eq "1" "$RC" "AC1 a bad --since exits 1"
queue "$CURL_QUEUE" '{"message": "not a list"}'
vcs list-default-commits
assert_eq "1" "$RC" "AC1 a body that is not a JSON array exits 1"
assert_eq "" "$OUT" "AC1 a failed read prints nothing on stdout"

# ── AC2 ─────────────────────────────────────────────────────────────────────
cfg_gitlab
export STUB_GITLAB_COMMITS='[{"id":"aaa111","title":"Revert \"feat: x (#799) (#804)\"","message":"Revert \"feat: x (#799) (#804)\"\n\nbody","committed_date":"2026-10-14T10:00:00.000+00:00"}]
[{"id":"bbb222","title":"feat: y (#805)","message":"feat: y (#805)\n","committed_date":"2026-10-13T10:00:00.000+00:00"}]'
vcs list-default-commits --since 2026-10-01
assert_eq "0" "$RC" "AC2 gitlab exits 0 (stderr: $ERR)"
assert_eq '[{"sha": "aaa111", "subject": "Revert \"feat: x (#799) (#804)\"", "date": "2026-10-14T10:00:00.000+00:00"}, {"sha": "bbb222", "subject": "feat: y (#805)", "date": "2026-10-13T10:00:00.000+00:00"}]' "$OUT" "AC2 gitlab prints the same shape, pages merged"
assert_contains "$(cat "$GH_LOG")" "repository/commits?" "AC2 gitlab reads the commits endpoint"
assert_contains "$(cat "$GH_LOG")" "since=2026-10-01" "AC2 gitlab passes --since"
unset STUB_GITLAB_COMMITS
cfg_azure
export STUB_AZURE_COMMITS='{"value": [{"commitId": "aaa111", "comment": "Revert \"feat: x (#799) (#804)\"\n\nbody", "committer": {"date": "2026-10-14T10:00:00Z"}}, {"commitId": "bbb222", "comment": "feat: y (#805)", "committer": {"date": "2026-10-13T10:00:00Z"}}]}'
vcs list-default-commits --since 2026-10-01
assert_eq "0" "$RC" "AC2 azure exits 0 (stderr: $ERR)"
assert_eq '[{"sha": "aaa111", "subject": "Revert \"feat: x (#799) (#804)\"", "date": "2026-10-14T10:00:00Z"}, {"sha": "bbb222", "subject": "feat: y (#805)", "date": "2026-10-13T10:00:00Z"}]' "$OUT" "AC2 azure prints the same shape"
assert_contains "$(cat "$GH_LOG")" "/commits?" "AC2 azure reads the git commits API"
assert_contains "$(cat "$GH_LOG")" "searchCriteria.fromDate=2026-10-01" "AC2 azure passes --since"
unset STUB_AZURE_COMMITS

# ── AC3 ─────────────────────────────────────────────────────────────────────
cfg_github
BODY1="intro${NL}**Regresses:** #804 and more words${NL}more"
BODY2="**Regression:** tests/x.sh${NL}**regresses:** #5${NL}see **Regresses:** #6 in the middle${NL}  **Regresses:** #7${NL}**Regresses:**#8"
BODY3="**Regresses:** #11${NL}**Regresses:**   #12"
queue "$CURL_QUEUE" "$(arr "$(gh_issue 820 issue 2026-10-17T08:00:00Z "$BODY1")" "$(gh_issue 821 pr 2026-10-19T08:00:00Z "$BODY3")" "$(gh_issue 822 issue 2026-10-18T08:00:00Z "$BODY2")" "$(gh_issue 823 issue 2026-10-18T09:00:00Z "")")"
vcs list-regresses
assert_eq "0" "$RC" "AC3 list-regresses exits 0 (stderr: $ERR)"
assert_eq '[{"number": 820, "kind": "issue", "date": "2026-10-17T08:00:00Z", "regresses": 804}, {"number": 821, "kind": "pr", "date": "2026-10-19T08:00:00Z", "regresses": 11}, {"number": 821, "kind": "pr", "date": "2026-10-19T08:00:00Z", "regresses": 12}]' "$OUT" \
  "AC3 one entry per **Regresses:** #<n> line, with kind and creation date; **Regression:**, lowercase, mid-line, indented and no-space lines are not entries"
assert_contains "$(cat "$CURL_LOG")" "state=all" "AC3 reads issues and PRs of any state"
assert_not_contains "$OUT" "intro" "AC3 no body is printed"
queue "$CURL_QUEUE" "$(arr "$(gh_issue 820 issue 2026-09-01T08:00:00Z "$BODY1")")"
: > "$CURL_LOG"
vcs list-regresses --since 2026-10-01
assert_eq "[]" "$OUT" "AC3 --since drops an item created before it"
assert_contains "$(cat "$CURL_LOG")" "since=2026-10-01" "AC3 --since reaches the provider"
vcs --dry-run list-regresses
assert_contains "$OUT" "[dry-run]" "AC3 --dry-run describes the call"

# ── AC4 ─────────────────────────────────────────────────────────────────────
cfg_gitlab
export STUB_GITLAB_REGRESS_ISSUES="[{\"iid\": 820, \"created_at\": \"2026-10-17T08:00:00.000Z\", \"description\": $(python3 -I -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$BODY1")}]"
export STUB_GITLAB_REGRESS_MRS="[{\"iid\": 821, \"created_at\": \"2026-10-19T08:00:00.000Z\", \"description\": \"**Regresses:** #804\"}, {\"iid\": 822, \"created_at\": \"2026-10-19T09:00:00.000Z\", \"description\": null}]"
vcs list-regresses
assert_eq "0" "$RC" "AC4 gitlab exits 0 (stderr: $ERR)"
assert_eq '[{"number": 820, "kind": "issue", "date": "2026-10-17T08:00:00.000Z", "regresses": 804}, {"number": 821, "kind": "pr", "date": "2026-10-19T08:00:00.000Z", "regresses": 804}]' "$OUT" "AC4 gitlab prints the same shape for issues and MRs"
unset STUB_GITLAB_REGRESS_ISSUES STUB_GITLAB_REGRESS_MRS
cfg_azure
export STUB_AZURE_WORKITEM_LIST='[{"id": 820, "fields": {"System.CreatedDate": "2026-10-17T08:00:00Z", "System.Description": "<p>intro<br>\n<strong>Regresses:</strong> #804</p>"}}, {"id": 830, "fields": {"System.CreatedDate": "2026-10-17T09:00:00Z", "System.Description": "<p>see <strong>Regresses:</strong> #5 mid-line</p>"}}]'
export STUB_AZURE_PR_LIST='[{"pullRequestId": 821, "creationDate": "2026-10-19T08:00:00Z", "description": "**Regresses:** #804"}]'
vcs list-regresses
assert_eq "0" "$RC" "AC4 azure exits 0 (stderr: $ERR)"
assert_eq '[{"number": 820, "kind": "issue", "date": "2026-10-17T08:00:00Z", "regresses": 804}, {"number": 821, "kind": "pr", "date": "2026-10-19T08:00:00Z", "regresses": 804}]' "$OUT" "AC4 azure prints the same shape for work items and PRs"
unset STUB_AZURE_WORKITEM_LIST STUB_AZURE_PR_LIST

# ── AC5 ─────────────────────────────────────────────────────────────────────
cfg_file
for v in list-default-commits list-regresses; do
  vcs $v
  assert_eq "1" "$RC" "AC5 file provider: $v exits 1"
  assert_eq "" "$OUT" "AC5 file provider: $v prints nothing on stdout"
  assert_contains "$ERR" "$v" "AC5 file provider: $v prints a note naming the verb"
done
# a github read that never runs out of pages hits the cap: exit 1, one note, no partial list
cfg_github
for i in $(seq 1 40); do
  queue "$CURL_QUEUE" "$(arr "$(ghc "sha$i" "feat: c$i" 2026-10-13T10:00:00Z)")"
  queue "$CURL_LINK_QUEUE" "https://api.github.com/repos/acme/widget/commits?per_page=100&page=$((i + 1))"
done
vcs list-default-commits
assert_eq "1" "$RC" "AC5 list-default-commits at the page cap exits 1"
assert_eq "" "$OUT" "AC5 list-default-commits at the page cap prints no partial list"
assert_eq "1" "$(printf '%s\n' "$ERR" | grep -c 'page')" "AC5 list-default-commits at the page cap prints one note"
cfg_github
for i in $(seq 1 40); do
  queue "$CURL_QUEUE" "$(arr "$(gh_issue "$i" issue 2026-10-13T10:00:00Z "")")"
  queue "$CURL_LINK_QUEUE" "https://api.github.com/repos/acme/widget/issues?per_page=100&page=$((i + 1))"
done
vcs list-regresses
assert_eq "1" "$RC" "AC5 list-regresses at the page cap exits 1"
assert_eq "" "$OUT" "AC5 list-regresses at the page cap prints no partial list"
assert_eq "1" "$(printf '%s\n' "$ERR" | grep -c 'page')" "AC5 list-regresses at the page cap prints one note"
# azure: a full last page of commits is the cap too
cfg_azure
export STUB_AZURE_COMMITS_FULL=1
vcs list-default-commits
assert_eq "1" "$RC" "AC5 azure commits at the page cap exit 1"
assert_eq "" "$OUT" "AC5 azure commits at the page cap print no partial list"
unset STUB_AZURE_COMMITS_FULL

# ── scoreboard fixtures (AC6 .. AC11) ───────────────────────────────────────
W42="2026-10-14T10:00:00Z"   # ISO week 2026-W42 (Mon 2026-10-12 .. Sun 2026-10-18)
W43="2026-10-20T10:00:00Z"   # ISO week 2026-W43
ev() {
  python3 -I -c '
import json, sys
ts, event, role, issue, pr, repo = sys.argv[1:7]
rec = {"ts": ts, "event": event, "role": role,
       "issue": int(issue) if issue else None, "pr": int(pr) if pr else None}
if repo:
    rec["repo"] = repo
if len(sys.argv) > 7:
    rec.update(json.loads(sys.argv[7]))
print(json.dumps(rec))' "$@" >> "$LOG"
}
fresh() { rm -f "$LOG"; mkdir -p "$(dirname "$LOG")"; : > "$LOG"; }
sb() { OUT="$(bash "$EVENTS" scoreboard "$@" 2>"$SANDBOX/err")"; RC=$?; ERR="$(cat "$SANDBOX/err")"; }
row() { printf '%s\n' "$OUT" | sed -n "$(($1 + 1))p"; }
cell() { printf '%s' "$1" | cut -f"$2"; }
# seed_github COMMITS-ARRAY ISSUES-ARRAY: the two provider answers, in call order.
seed_github() { cfg_github; queue "$CURL_QUEUE" "$1"; queue "$CURL_QUEUE" "$2"; }

# PR 804 merged in W42 (acme/widget); PR 810 merged in W42 (acme/other); PR 900 has no merged event.
base_log() {
  fresh
  ev "$W42" merged orchestrator 799 804 acme/widget
  ev "$W42" merged orchestrator 805 810 acme/other
}

# ── AC6 ─────────────────────────────────────────────────────────────────────
base_log
seed_github "$(arr \
  "$(ghc c1 'Revert "feat: x (#799) (#804)"' 2026-10-16T09:00:00Z)" \
  "$(ghc c2 'Revert "feat: z (#900)"' 2026-10-16T10:00:00Z)" \
  "$(ghc c3 'fix: Revert "x" (#810)' 2026-10-16T11:00:00Z)" \
  "$(ghc c4 'Reverts the thing (#810)' 2026-10-16T12:00:00Z)")" '[]'
sb --json
assert_eq "0" "$RC" "AC6 exits 0 (stderr: $ERR)"
assert_eq '[["acme/widget", "2026-W42", 1]]' "$(jget "$OUT" '[[r["repo"], r["week"], r["reverts"]] for r in d["rows"] if r["reverts"]]')" \
  "AC6 one revert of PR 804 in the week of the commit; a revert of a PR with no merged event, and subjects not starting Revert \", are not counted"
# the last #<n> of the subject is the PR; the same PR reverted twice counts once, in the earliest week
base_log
seed_github "$(arr \
  "$(ghc c1 'Revert "Revert \"feat\" (#804)" (#810)' 2026-10-21T09:00:00Z)" \
  "$(ghc c2 'Revert "feat: x (#799) (#804)"' 2026-10-22T09:00:00Z)" \
  "$(ghc c3 'Revert "feat: x (#799) (#804)"' 2026-10-16T09:00:00Z)")" '[]'
sb --json
assert_eq '[["acme/other", "2026-W43", 1], ["acme/widget", "2026-W42", 1]]' "$(jget "$OUT" '[[r["repo"], r["week"], r["reverts"]] for r in d["rows"] if r["reverts"]]')" \
  "AC6 the last #<n> names the PR; a PR reverted twice counts once, in the week of the earliest revert"

# ── AC7 ─────────────────────────────────────────────────────────────────────
base_log
seed_github '[]' "$(arr \
  "$(gh_issue 820 issue 2026-10-17T08:00:00Z "**Regresses:** #804")" \
  "$(gh_issue 821 pr 2026-10-21T08:00:00Z "**Regresses:** #804")" \
  "$(gh_issue 830 issue 2026-10-20T08:00:00Z "**Regresses:** #810")" \
  "$(gh_issue 831 issue 2026-10-20T09:00:00Z "**Regresses:** #900")")"
sb --json
assert_eq '[["acme/other", "2026-W43", 1], ["acme/widget", "2026-W42", 1]]' "$(jget "$OUT" '[[r["repo"], r["week"], r["fix_forwards"]] for r in d["rows"] if r["fix_forwards"]]')" \
  "AC7 one fix-forward per distinct Talos-merged PR, in the week of the earliest issue or PR naming it; PR 900 has no merged event"

# ── AC8 ─────────────────────────────────────────────────────────────────────
base_log
seed_github "$(arr "$(ghc c1 'Revert "feat: x (#799) (#804)"' 2026-10-16T09:00:00Z)")" \
  "$(arr "$(gh_issue 830 issue 2026-10-20T08:00:00Z "**Regresses:** #810")")"
sb
HEADER="$(printf 'repo\tweek\tmerged\thands_free\tfix_rounds_per_pr\ttokens_per_pr\trun_ends\tfinding_outcomes\treverts\tfix_forwards')"
assert_eq "$HEADER" "$(row 0)" "AC8 the table ends with reverts and fix_forwards"
assert_eq "4" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "AC8 header plus three rows (a week with only a fix-forward has a row)"
assert_eq "acme/other	2026-W42	1	1	0.0	0	-	-	0	0" "$(row 1)" "AC8 acme/other W42 row: merged, no revert, no fix-forward yet"
assert_eq "acme/other	2026-W43	0	0	-	-	-	-	0	1" "$(row 2)" "AC8 a week with only a fix-forward gets its own row"
assert_eq "acme/widget	2026-W42	1	1	0.0	0	-	-	1	0" "$(row 3)" "AC8 the revert counts in the merged event's repo and week"
base_log
seed_github "$(arr "$(ghc c1 'Revert "feat: x (#799) (#804)"' 2026-10-23T09:00:00Z)")" '[]'
sb
assert_eq "acme/widget	2026-W43	0	0	-	-	-	-	1	0" "$(row 3)" "AC8 a week with only a revert gets its own row, in the merged event's repo"
# --repo and --since filter the counts
base_log
seed_github "$(arr "$(ghc c1 'Revert "feat: x (#799) (#804)"' 2026-10-16T09:00:00Z)" "$(ghc c2 'Revert "y (#810)"' 2026-10-16T10:00:00Z)")" '[]'
sb --json --repo acme/widget
assert_eq '[["acme/widget", 1]]' "$(jget "$OUT" '[[r["repo"], r["reverts"]] for r in d["rows"]]')" "AC8 --repo keeps one repo's counts"
base_log
seed_github "$(arr "$(ghc c1 'Revert "feat: x (#799) (#804)"' 2026-10-16T09:00:00Z)")" '[]'
sb --json --since 2026-10-17
assert_eq '[]' "$(jget "$OUT" '[r for r in d["rows"] if r["reverts"]]')" "AC8 --since drops a revert before it"
assert_contains "$(cat "$CURL_LOG")" "since=2026-10-17" "AC8 --since is the provider's since"
# without --since the oldest merged event sets it
base_log
seed_github '[]' '[]'
sb --json
assert_contains "$(cat "$CURL_LOG")" "since=2026-10-14" "AC8 the default since is the date of the oldest merged event"

# ── AC9 ─────────────────────────────────────────────────────────────────────
base_log
seed_github "404:{\"message\": \"Not Found\"}" "$(arr "$(gh_issue 830 issue 2026-10-15T08:00:00Z "**Regresses:** #810")")"
sb --json
assert_eq "0" "$RC" "AC9 a failed commit read leaves the exit 0"
assert_eq '[null, null]' "$(jget "$OUT" '[r["reverts"] for r in d["rows"]]')" "AC9 reverts is null for every row when the commit read fails"
assert_eq '[1, 0]' "$(jget "$OUT" '[r["fix_forwards"] for r in d["rows"]]')" "AC9 fix_forwards is still counted"
assert_eq "1" "$(printf '%s\n' "$ERR" | grep -c 'list-default-commits')" "AC9 one note names the failed read"
sb
assert_eq "?" "$(cell "$(row 1)" 9)" "AC9 the table shows ? for the unknown column"
base_log
seed_github "$(arr "$(ghc c1 'Revert "feat: x (#799) (#804)"' 2026-10-16T09:00:00Z)")" "404:{\"message\": \"Not Found\"}"
sb --json
assert_eq "0" "$RC" "AC9 a failed list-regresses leaves the exit 0"
assert_eq '[0, 1]' "$(jget "$OUT" '[r["reverts"] for r in d["rows"]]')" "AC9 reverts is still counted"
assert_eq '[null, null]' "$(jget "$OUT" '[r["fix_forwards"] for r in d["rows"]]')" "AC9 fix_forwards is null when list-regresses fails"
assert_eq "1" "$(printf '%s\n' "$ERR" | grep -c 'list-regresses')" "AC9 one note names the failed read"
sb
assert_eq "?" "$(cell "$(row 1)" 10)" "AC9 the table shows ? for the unknown fix_forwards"
base_log
cfg_file
sb --json
assert_eq "0" "$RC" "AC9 the file provider leaves the exit 0"
assert_eq '[null, null]' "$(jget "$OUT" '[r["reverts"] for r in d["rows"]]')" "AC9 file provider: reverts unknown"
assert_eq '[null, null]' "$(jget "$OUT" '[r["fix_forwards"] for r in d["rows"]]')" "AC9 file provider: fix_forwards unknown"
base_log
seed_github "not json at all" '[]'
sb --json
assert_eq '[null, null]' "$(jget "$OUT" '[r["reverts"] for r in d["rows"]]')" "AC9 bad JSON from the verb: reverts unknown"

# ── AC10 ────────────────────────────────────────────────────────────────────
base_log
cfg_github
for verb in "list" "tail" "cost" "note --issue 5 --kind unblocked --body-file -"; do
  printf 'x' | bash "$EVENTS" $verb >/dev/null 2>&1
done
assert_eq "0" "$(wc -c < "$CURL_LOG" | tr -d ' ')" "AC10 list, tail, cost and note make no provider call"
fresh
ev "$W42" run_end orchestrator 1 "" acme/widget
sb
assert_eq "0" "$(cat "$CURL_LOG" "$GH_LOG" | wc -c | tr -d ' ')" "AC10 a log with no merged event makes no provider read"
assert_eq "0" "$(cell "$(row 1)" 9)" "AC10 no merged event: reverts 0"
assert_eq "0" "$(cell "$(row 1)" 10)" "AC10 no merged event: fix_forwards 0"
OTHERS="$(grep -l -e 'list-default-commits' -e 'list-regresses' "$TALOS_ROOT"/scripts/*.sh "$TALOS_ROOT"/scripts/*.py | grep -v -e '/pipeline-vcs.sh$' -e '/pipeline-events.sh$' -e '/pipeline-eval.sh$' || true)"
assert_eq "" "$OTHERS" "AC10 only pipeline-vcs.sh, pipeline-events.sh and the on-demand pipeline-eval.sh name the two verbs (talos.sh run reads nothing)"
assert_eq "0" "$(awk '/^cmd_scoreboard\(\)/ {f = 1} !f && !/^[[:space:]]*#/ && /list-default-commits|list-regresses/ {n++} /^}/ {f = 0} END {print n + 0}' "$EVENTS")" \
  "AC10 pipeline-events.sh names the two verbs only inside cmd_scoreboard (and in comments)"

# ── AC11 ────────────────────────────────────────────────────────────────────
fresh
ev "$W42" developer developer 1 10 acme/widget '{"tokens": 1000}'
ev "$W42" developer developer 1 10 acme/widget '{"tokens": 500}'
ev "$W42" merged orchestrator 1 10 acme/widget
ev "$W42" run_end orchestrator 1 "" acme/widget '{"reason": "idle"}'
ev "$W42" finding_outcome orchestrator 1 10 acme/widget '{"stage": "reviewer", "outcome": "fixed"}'
seed_github '[]' '[]'
sb
assert_eq "0" "$RC" "AC11 exits 0 with no reverts or fix-forwards"
assert_eq "$HEADER" "$(row 0)" "AC11 the header is the #799 one plus the two appended columns"
assert_eq "acme/widget	2026-W42	1	1	1.0	1500	idle:1	reviewer/fixed:1	0	0" "$(row 1)" "AC11 the existing columns are unchanged, the two new ones are 0"
assert_eq "" "$ERR" "AC11 no note on stderr"

# ── AC12 ────────────────────────────────────────────────────────────────────
for f in pm developer; do
  T="$(cat "$TALOS_ROOT/agents/$f.md")"
  assert_contains "$T" '**Regresses:** #<pr>' "AC12 agents/$f.md tells the agent to add a **Regresses:** line"
  assert_contains "$T" 'not `**Regression:**`' "AC12 agents/$f.md says not to use **Regression:** for it"
done

[ "$_FAIL" -eq 0 ] || { printf '%d failed\n' "$_FAIL" >&2; exit 1; }
printf 'test-events-reverts-fixforwards-800: %d passed\n' "$_PASS"
