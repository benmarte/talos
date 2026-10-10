#!/usr/bin/env bash
# test-talos-postmerge.sh -- `scripts/talos.sh post-merge`, `sweep` and `summary`
# (#467, slice 3 of epic #422).
#
# The three verbs replace the post-merge, Step 1 sweep and Step 5 prose of
# skills/pipeline/SKILL.md, so this file pins that they do what the prose said, in
# its order, and that a re-run is a safe no-op:
#   (a) post-merge: the journal-ordered golden fixture, the ci-runs flag, each
#       optional item (status log), the trusted-marker idempotency
#       rule, every non-fatal failure as a `warn reason=`, the sibling sync, the
#       human-merge hand-off
#   (b) sweep: the heal (find-pr exit 2 is "not verified"), the worktree sweep,
#       the blocked report, the epic sweep, dependency unblocking, needs-owner
#   (c) summary: the worktree sweep with the open PRs kept, the warning, the cost
#       table, the status refresh
#   (d) the output contract (first line, KEY=value, fixed-enum reasons), the
#       sanitiser, usage and missing scripts
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"

# ── fixtures ─────────────────────────────────────────────────────────────────
# A copy of the scripts directory in which every script a verb calls is one
# journaling stub. <key> is what the stub looks up in $STUB_DIR/<key>.{out,err,rc}
# (rc 0 by default): for pipeline-vcs.sh `<verb>.<first arg>` then `<verb>`; for
# any other script `<name>.<first arg>.<line|md>` (events cost --line|--markdown),
# `<name>.<first arg>`, then `<name>`.
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
case " $* " in *" --markdown "*) sfx=md ;; *" --line "*) sfx=line ;; *" --summary "*) sfx=summary ;; *) sfx="" ;; esac
if [ "$n" = "vcs" ]; then cands="${1:-}.${2:-} ${1:-}"
else cands="$n.${1:-}.$sfx $n.${1:-} $n"; fi
key=""
for c in $cands; do
  if [ -e "$d/$c.out" ] || [ -e "$d/$c.err" ] || [ -e "$d/$c.rc" ]; then key="$c"; break; fi
done
printf "%s %s\n" "$n" "$*" >> "$d/journal"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then
    if [ "$a" = "-" ]; then cat > "$d/stdin"; else { printf "[%s]\n" "$*"; cat "$a"; } >> "$d/bodies"; cp "$a" "$d/last-body"; fi
  fi
  prev="$a"
done
if [ "$n" = "hooks" ]; then cat >> "$d/hooks.stdin"; fi
if [ -n "$key" ]; then
  if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
  if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
  if [ -s "$d/$key.seq" ]; then
    r="$(head -n 1 "$d/$key.seq")"; tail -n +2 "$d/$key.seq" > "$d/$key.seq.t"; mv "$d/$key.seq.t" "$d/$key.seq"; exit "$r"
  fi
  if [ -f "$d/$key.rc" ]; then exit "$(cat "$d/$key.rc")"; fi
fi
exit 0
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-mergebase.sh \
         pipeline-status.sh pipeline-worktree.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
PM="$GS/talos.sh"

cfg_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
# set_stub <key> <rc> [out] [err]
set_stub() {
  printf '%s\n' "$2" > "$STUB_DIR/$1.rc"
  printf '%s' "${3:-}" > "$STUB_DIR/$1.out"
  printf '%s' "${4:-}" > "$STUB_DIR/$1.err"
}
# reset_stubs: a GitHub provider, a trusted bot user, no sibling PRs, no comments.
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  cfg_json '{"vcs": {"provider": "github"}}'
  set_stub current-user 0 "bot"
  set_stub list-prs 0 "[]"
  set_stub read-comments 0 '{"comments":[]}'
  set_stub list-issues 0 "[$(issue_json 42 "")]"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
# jr: the journal with the temp body path normalised.
jr() { journal | sed 's| --body-file [^ ]*| --body-file F|'; }
called() { journal | grep -c "^$1 \|^vcs $1 "; }
line_of() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
pm() { OUT="$(bash "$PM" post-merge "$@" 2>"$ERR")"; RC=$?; }
sw() { OUT="$(bash "$PM" sweep "$@" 2>"$ERR")"; RC=$?; }
sm() { OUT="$(bash "$PM" summary "$@" 2>"$ERR")"; RC=$?; }
issue_json() {  # number "labels,..." [body] -> one list-issues item
  local n="$1" out="" l body="${3:-}"
  local IFS=,
  for l in $2; do out="${out:+$out,}{\"name\":\"$l\"}"; done
  printf '{"number":%s,"title":"t","labels":[%s],"body":%s}' "$n" "$out" "$(python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$body")"
}
pr_json() {  # number branch base "labels,..." cross
  local out="" l
  local IFS=,
  for l in $4; do out="${out:+$out,}{\"name\":\"$l\"}"; done
  printf '{"number":%s,"headRefName":"%s","baseRefName":"%s","labels":[%s],"isCrossRepository":%s}' "$1" "$2" "$3" "$out" "${5:-false}"
}

# ── the output contract, as a checker ────────────────────────────────────────
reasons_of() { sed -n "s/^# $1-reasons: //p" "$TALOS" | head -n 1; }
ALL_REASONS="$(reasons_of post-merge) $(reasons_of sweep) $(reasons_of summary)"
# check_out FILE FIRST: the first line is FIRST (post_merge=done ...) or a lone
# stop line; every line is KEY=value or `warn reason=<enum> [key=value]...`; a stop
# reason is in the header's stop set; no raw control byte.
check_out() {
  python3 -I -c '
import re, sys
reasons = set(sys.argv[3].split())
data = open(sys.argv[1], "rb").read()
if re.search(rb"[\x00-\x09\x0b-\x1f\x7f]|\xc2[\x80-\x9f]", data):
    sys.exit(1)
lines = data.decode("utf-8").split("\n")
if lines and lines[-1] == "":
    lines.pop()
if not lines:
    sys.exit(1)
stops = {"usage", "scripts-missing", "python-missing", "scratch-unavailable", "config-unreadable"}
if lines[0].startswith("stop "):
    sys.exit(0 if len(lines) == 1 and lines[0][12:] in stops else 1)
if not re.match(sys.argv[2] + r"\Z", lines[0]):
    sys.exit(1)
kv = re.compile(r"[A-Za-z][A-Za-z0-9_.]*=")
sw = re.compile(r"warn reason=([a-z-]+)( [a-z]+=[A-Za-z0-9_.-]+)*\Z")
for ln in lines[1:]:
    if kv.match(ln):
        continue
    m = sw.match(ln)
    if m and m.group(1) in reasons:
        continue
    sys.exit(1)
' "$1" "$2" "$ALL_REASONS"
}
assert_out() { printf '%s\n' "$OUT" > "$SANDBOX/out.pm"; check_out "$SANDBOX/out.pm" "$2"; assert_eq "0" "$?" "$1: output satisfies the line contract"; }
PM_FIRST='post_merge=done'

# ── (a) post-merge: the golden order ─────────────────────────────────────────
reset_stubs
cfg_json '{"vcs": {"provider": "github"}}'
set_stub events.cost.md 0 "spend-comment-body"
set_stub events.cost.line 0 "spend: 12 tokens"
pm 9 42 --ci-runs 3
assert_eq "0" "$RC" "post-merge: exits 0"
assert_eq "post_merge=done
recorded=no
spend=spend: 12 tokens" "$OUT" "post-merge: first line, recorded=no, the spend line, nothing else"
assert_out "post-merge" "$PM_FIRST"
assert_eq "vcs list-prs
vcs current-user
vcs read-comments 42
vcs comment-issue 42 --body-file F --allow-closed
vcs list-issues
vcs close-issue 42 closed by PR #9
status 42 Done
worktree remove 42
notify orchestrator #42 all stages passed — merged PR #9, issue closed 42
notify merged #42 PR #9 merged 42
notify issue-closed #42 issue resolved 42
hooks post_stage merged orchestrator 42 --pr 9 --summary PR #9 merged --ci-runs 3
hooks post_stage issue-closed orchestrator 42 --pr 9 --summary issue resolved
events cost --issue 42 --pr 9 --line
events cost --issue 42 --pr 9 --markdown
vcs upsert-pr-comment 9 --marker spend --body-file F" "$(jr)" "post-merge: the items run in the playbook's order, one call each"
assert_eq "spend-comment-body" "$(cat "$STUB_DIR/stdin")" "post-merge: the spend body reaches the upsert on stdin"
BODY="$(cat "$STUB_DIR/last-body" 2>/dev/null)"
assert_contains "$(cat "$STUB_DIR/bodies")" "**Agent:** orchestrator (talos)" "post-merge: the issue-closed comment carries the orchestrator header"
assert_contains "$(cat "$STUB_DIR/bodies")" "<!-- talos:issue-closed pr=9 -->" "post-merge: the comment carries the idempotency marker"
assert_contains "$(cat "$STUB_DIR/bodies")" "CLOSED - all stages passed" "post-merge: a missing template falls back to the inline body"

# The real template renders when the templates dir is set.
reset_stubs
cfg_json '{"vcs": {"provider": "github"}, "comments": {"templates_dir": "'"$TALOS_ROOT"'/templates/comments"}}'
pm 9 42
assert_contains "$(cat "$STUB_DIR/last-body")" "Closed by PR #9 — all pipeline stages passed." "post-merge: issue-closed.md is rendered from comments.templates_dir"
assert_not_contains "$(cat "$STUB_DIR/last-body")" '${' "post-merge: no placeholder is left in the comment"

# No --ci-runs: the flag is omitted, never guessed; a heal skips the sibling sync.
reset_stubs
pm 9 42
assert_not_contains "$(journal)" "--ci-runs" "post-merge: no --ci-runs value, no flag"
assert_eq "0" "$(called status-file)" "post-merge: no status log any more (#550)"
assert_eq "1" "$(journal | grep -c 'events cost.*--line')" "post-merge: the spend --line runs once"
assert_eq "0" "$(called upsert-pr-comment)" "post-merge: an empty spend body is never upserted"
pm 9 42 --heal
assert_eq "0" "$(called list-prs)" "heal: no sibling sync"
assert_contains "$(journal)" "vcs close-issue 42 closed by PR #9" "heal: the same bookkeeping runs"
assert_out "post-merge --heal" "$PM_FIRST"

# ── (a) post-merge: idempotency ──────────────────────────────────────────────
# A second run, after the first one's comment is on the issue, repeats nothing that
# tells someone: one comment, one merged event. close-issue is not one of them: a
# close that failed after the comment must be retried by the next heal.
reset_stubs
cfg_json '{"vcs": {"provider": "github"}}'
pm 9 42 --ci-runs 3
POSTED="$(cat "$STUB_DIR/last-body")"
python3 -I -c 'import json, sys; print(json.dumps({"comments": [{"author": {"login": "bot"}, "body": sys.stdin.read()}]}))' <<< "$POSTED" > "$SANDBOX/c.json"
set_stub read-comments 0 "$(cat "$SANDBOX/c.json")"
rm -f "$STUB_DIR/journal" "$STUB_DIR/bodies"
pm 9 42 --ci-runs 3
assert_contains "$OUT" "recorded=yes" "idempotent: the marker of the first run is seen"
assert_eq "0" "$(called comment-issue)" "idempotent: no second close comment"
assert_eq "1" "$(called close-issue)" "idempotent: close-issue runs again with the marker present (retry of a failed close)"
assert_eq "0" "$(called notify)" "idempotent: no second notice"
assert_eq "0" "$(called hooks)" "idempotent: no second merged event"
assert_eq "0" "$(called events)" "idempotent: no second spend block"
assert_eq "1" "$(called status)" "idempotent: board Done is idempotent in its script and still runs"
assert_eq "1" "$(called worktree)" "idempotent: worktree remove is a no-op when gone and still runs"
assert_out "idempotent" "$PM_FIRST"
# A close that failed after the marker was posted is retried, and succeeds the next time.
set_stub close-issue 1 "" "boom"
rm -f "$STUB_DIR/journal"
pm 9 42 --heal
assert_contains "$OUT" "recorded=yes" "retry: the marker is still seen"
assert_contains "$OUT" "warn reason=close-failed issue=42" "retry: a failing close warns again"
set_stub close-issue 0
rm -f "$STUB_DIR/journal"
pm 9 42 --heal
assert_contains "$(journal)" "vcs close-issue 42 closed by PR #9" "retry: the heal calls close-issue again with the marker present"
assert_not_contains "$OUT" "close-failed" "retry: and it goes through"
assert_eq "0" "$(called comment-issue)" "retry: the comment is still not repeated"
# Another PR's marker does not count.
python3 -I -c 'import json, sys; print(json.dumps({"comments": [{"author": {"login": "bot"}, "body": sys.stdin.read().replace("pr=9", "pr=8")}]}))' <<< "$POSTED" > "$SANDBOX/c.json"
set_stub read-comments 0 "$(cat "$SANDBOX/c.json")"
pm 9 42
assert_contains "$OUT" "recorded=no" "idempotent: a marker for another PR does not count"
assert_eq "1" "$(called comment-issue)" "idempotent: so the comment is posted"
# An outsider's marker does not count (markers.trusted_authors plus the current user).
python3 -I -c 'import json, sys; print(json.dumps({"comments": [{"author": {"login": "mallory"}, "body": sys.stdin.read()}]}))' <<< "$POSTED" > "$SANDBOX/c.json"
set_stub read-comments 0 "$(cat "$SANDBOX/c.json")"
pm 9 42
assert_contains "$OUT" "recorded=no" "idempotent: an untrusted author's marker does not count"
# markers.trusted_authors counts too.
cfg_json '{"vcs": {"provider": "github"}, "markers": {"trusted_authors": ["mallory"]}}'
pm 9 42
assert_contains "$OUT" "recorded=yes" "idempotent: a marker by a configured trusted author counts"
# No resolvable trust set: no marker counted, a warning, and the run goes on.
cfg_json '{"vcs": {"provider": "github"}}'
set_stub current-user 3 "" "boom"
rm -f "$STUB_DIR/journal"
pm 9 42
assert_contains "$OUT" "warn reason=trust-unverified issue=42" "idempotent: a refused identity warns"
assert_contains "$OUT" "recorded=no" "idempotent: and counts no marker"
assert_eq "1" "$(called close-issue)" "idempotent: the bookkeeping still runs"
assert_out "trust-unverified" "$PM_FIRST"
# An identity that cannot be looked up (exit 1) with no trusted_authors is the same: an
# outsider's marker is not counted, the comment is posted, the warning is printed.
set_stub current-user 1 "" "no identity"
set_stub read-comments 0 "$(cat "$SANDBOX/c.json")"
rm -f "$STUB_DIR/journal"
pm 9 42
assert_contains "$OUT" "warn reason=trust-unverified issue=42" "trust: an unresolvable identity warns"
assert_contains "$OUT" "recorded=no" "trust: and a marker by any author does not count (no fail-open)"
assert_eq "1" "$(called comment-issue)" "trust: so the comment is posted"
assert_out "trust-unverified (exit 1)" "$PM_FIRST"
# The same identity failure with trusted_authors set counts that author's marker.
cfg_json '{"vcs": {"provider": "github"}, "markers": {"trusted_authors": ["mallory"]}}'
pm 9 42
assert_contains "$OUT" "recorded=yes" "trust: an unresolvable identity with trusted_authors uses the set"
assert_not_contains "$OUT" "trust-unverified" "trust: and does not warn"
# Unreadable comments: the same.
reset_stubs; set_stub read-comments 1 "" "boom"
pm 9 42
assert_contains "$OUT" "warn reason=comments-unreadable issue=42" "idempotent: unreadable comments warn"
assert_eq "1" "$(called comment-issue)" "idempotent: and the comment is posted"
# Comments off: only the spend comment is gated, as in the old playbook (its issue-closed
# comment, like approved.md and the epic comment, was not).
reset_stubs; cfg_json '{"vcs": {"provider": "github"}, "comments": {"enabled": false}}'
set_stub events.cost.md 0 "spend-comment-body"
pm 9 42
assert_eq "1" "$(called comment-issue)" "comments off: the issue-closed comment is posted as before"
assert_eq "1" "$(called close-issue)" "comments off: close-issue runs"
assert_eq "0" "$(called upsert-pr-comment)" "comments off: no spend comment"

# close-issue is called only while the issue is open: the github verb posts a
# "closed by PR" comment on every call, so a closed issue must never reach it.
reset_stubs
set_stub list-issues 0 "[$(issue_json 7 ""),$(issue_json 8 "")]"
pm 9 42
assert_eq "0" "$(called close-issue)" "state: an issue that is not open (already closed) gets no close-issue call"
assert_not_contains "$OUT" "issue-state-unverified" "state: closed is not a warning"
assert_eq "1" "$(called status)" "state: board Done still runs for a closed issue"
assert_out "state: closed" "$PM_FIRST"
reset_stubs
pm 9 42
assert_eq "1" "$(called close-issue)" "state: an open issue is closed once"
assert_not_contains "$OUT" "issue-state-unverified" "state: open is not a warning"
reset_stubs; set_stub list-issues 1 "" "boom"
pm 9 42
assert_eq "0" "$(called close-issue)" "state: an unreadable state never closes blind (list-issues fails)"
assert_contains "$OUT" "warn reason=issue-state-unverified issue=42" "state: an unreadable state warns"
assert_eq "1" "$(called status)" "state: the other items still run"
assert_out "state: unreadable" "$PM_FIRST"
reset_stubs; set_stub list-issues 0 "not json"
pm 9 42
assert_eq "0" "$(called close-issue)" "state: an unparseable list never closes blind"
assert_contains "$OUT" "warn reason=issue-state-unverified issue=42" "state: an unparseable list warns"
# Another provider (gitlab: capped list, items carry iid): the list is not trusted, so
# close-issue runs even when the issue is absent from list-issues (main's behaviour).
reset_stubs; cfg_json '{"vcs": {"provider": "gitlab"}}'
set_stub list-issues 0 "[$(issue_json 7 "")]"
pm 9 42
assert_eq "1" "$(called close-issue)" "state: gitlab closes even when the issue is absent from list-issues"
assert_not_contains "$OUT" "issue-state-unverified" "state: gitlab never warns about the state"
reset_stubs; cfg_json '{"vcs": {"provider": "gitlab"}}'
set_stub list-issues 1 "" "boom"
pm 9 42
assert_eq "1" "$(called close-issue)" "state: gitlab closes without reading the list at all"
# Run twice on the same merged issue: the first closes it, the second sees it closed.
reset_stubs
pm 9 42
set_stub list-issues 0 "[]"
pm 9 42
assert_eq "1" "$(called close-issue)" "state: two runs on one merged issue close it, and comment, once overall"
# The sweep heal knows the issue is open from its own list: close-issue, no second list call.
reset_stubs
set_stub list-issues 0 "[$(issue_json 31 "pipeline:dev")]"
set_stub find-pr 0 '{"number":9}'
sw
assert_eq "1" "$(called close-issue)" "state: the sweep heal closes the open issue it listed"
assert_eq "1" "$(journal | grep -c "^vcs list-issues")" "state: the sweep heal reuses its own list"

# ── (a) post-merge: every item is non-fatal ──────────────────────────────────
reset_stubs
cfg_json '{"vcs": {"provider": "github"}}'
set_stub comment-issue 1 "" "boom"
set_stub close-issue 1 "" "boom"
set_stub status 1 "" "boom"
set_stub worktree 1 "" "boom"
set_stub notify 1 "" "boom"
set_stub events.cost.md 0 "body"
set_stub upsert-pr-comment 1 "" "boom"
pm 9 42
assert_eq "0" "$RC" "non-fatal: every item failing still exits 0"
for r in comment-failed close-failed board-failed worktree-remove-failed notify-failed spend-upsert-failed; do
  assert_contains "$OUT" "warn reason=$r issue=42" "non-fatal: warn reason=$r"
done
assert_eq "3" "$(printf '%s\n' "$OUT" | grep -c 'reason=notify-failed')" "non-fatal: each failed notice warns"
assert_eq "2" "$(called hooks)" "non-fatal: the events fire after the failures"
assert_out "non-fatal" "$PM_FIRST"
set_stub upsert-pr-comment 2 "" "not implemented"
pm 9 42
assert_not_contains "$OUT" "reason=spend-upsert-failed" "non-fatal: upsert rc=2 (non-GitHub provider) is silent"
assert_out "non-fatal (rc 2)" "$PM_FIRST"
set_stub list-prs 1 "" "boom"
pm 9 42
assert_contains "$OUT" "warn reason=siblings-unlisted issue=42" "non-fatal: an unreadable PR list skips the sibling sync with a warning"
assert_out "siblings-unlisted" "$PM_FIRST"
reset_stubs; cfg_json '{"vcs": {"provider": "github"}, "comments": {"header": ""}}'
pm 9 42
assert_contains "$OUT" "warn reason=comment-failed issue=42" "non-fatal: an empty comments.header posts nothing"
assert_eq "0" "$(called comment-issue)" "non-fatal: and no comment is posted without its Agent header"

# ── (a) post-merge: the sibling sync ─────────────────────────────────────────
reset_stubs
set_stub list-prs 0 "[$(pr_json 7 fix/issue-7-a main pipeline:review),$(pr_json 8 feat/issue-8-b main qa:pass),$(pr_json 9 fix/issue-42-x main pipeline:review),$(pr_json 10 fix/issue-10-c main pipeline:review),$(pr_json 11 fix/issue-11-d main pipeline:review),$(pr_json 12 fix/issue-12-e main '' true),$(pr_json 13 fix/issue-13-f other pipeline:review),$(pr_json 14 chore/x main pipeline:review),$(pr_json 15 fix/issue-15-g main '' false)]"
set_stub conflict-files.8 0 "src/a.sh"
set_stub conflict-files.10 0 "src/b.sh"
set_stub conflict-files.11 0 "src/c.sh"
set_stub conflict-files.15 0 ""
set_stub mergebase.10 3
set_stub mergebase.11 3
set_stub update-branch.11 1 "" "409"
set_stub pr-mergeable 0 "MERGEABLE"
pm 9 42
assert_eq "post_merge=done
sibling=7 action=clean
sibling=8 action=mergebase
sibling=10 action=update-branch
sibling=11 action=developer
sibling=15 action=clean
recorded=no" "$OUT" "siblings: every other open pipeline PR in PR order; a fork lookalike, another base and a non-pipeline branch are not siblings"
assert_out "siblings" "$PM_FIRST"
assert_eq "vcs list-prs
vcs conflict-files 7
vcs conflict-files 8
mergebase 8
vcs pr-mergeable 8
notify info merge-base #42 sibling PR #8 synced with new base (mergebase) 42
vcs conflict-files 10
mergebase 10
vcs update-branch 10
vcs pr-mergeable 10
notify info merge-base #42 sibling PR #10 synced with new base (update-branch) 42
vcs conflict-files 11
mergebase 11
vcs update-branch 11
vcs conflict-files 15" "$(jr | sed -n '1,/^vcs conflict-files 15/p')" "siblings: no conflict: nothing; else mergebase, then update-branch, then the developer; each sync is relayed and re-checked"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'action=developer')" "siblings: the developer fallback is reported, never dispatched here"
# A still-conflicting head after a sync goes to the developer.
reset_stubs
set_stub list-prs 0 "[$(pr_json 8 fix/issue-8-b main pipeline:review)]"
set_stub conflict-files 0 "src/a.sh"
set_stub pr-mergeable 1 "CONFLICTING"
pm 9 42
assert_contains "$OUT" "sibling=8 action=developer" "siblings: pr-mergeable still CONFLICTING after the sync: developer"
assert_eq "0" "$(journal | grep -c 'merge-base')" "siblings: no sync relay when the sync did not hold"
# merge.auto_sync false: the block is skipped entirely.
cfg_json '{"vcs": {"provider": "github"}, "merge": {"auto_sync": false}}'
pm 9 42
assert_eq "0" "$(called list-prs)" "siblings: merge.auto_sync false skips the sync"
# conflict-files failing, or another provider: pr-mergeable decides.
reset_stubs
set_stub list-prs 0 "[$(pr_json 8 fix/issue-8-b main pipeline:review),$(pr_json 9 fix/issue-9-b main pipeline:review),$(pr_json 10 fix/issue-10-b main pipeline:review)]"
cfg_json '{"vcs": {"provider": "gitlab"}}'
set_stub pr-mergeable.8 0 "MERGEABLE"
set_stub pr-mergeable.9 0 "CONFLICTING"
printf '1\n0\n' > "$STUB_DIR/pr-mergeable.9.seq"   # conflicting first, mergeable after the sync
set_stub pr-mergeable.10 2 "UNKNOWN"
set_stub mergebase 3
set_stub update-branch 0
pm 99 42
assert_eq "0" "$(called conflict-files)" "siblings: a provider without conflict-files never calls it"
assert_contains "$OUT" "sibling=8 action=clean" "siblings: MERGEABLE is clean"
assert_contains "$OUT" "sibling=9 action=update-branch" "siblings: CONFLICTING without a path list: mergebase, update-branch"
assert_contains "$OUT" "sibling=10 action=unverified" "siblings: UNKNOWN is reported unverified, not synced"
assert_out "siblings (gitlab)" "$PM_FIRST"

# ── (a) post-merge: the human-merge hand-off ─────────────────────────────────
reset_stubs
printf '%s\n' "- Evidence: https://example.test/e" > "$SANDBOX/details.txt"
pm 9 42 --handoff --details-file "$SANDBOX/details.txt"
assert_eq "post_merge=handoff" "$OUT" "handoff: first line names the mode and nothing else is printed"
assert_eq "vcs comment-pr 9 --body-file F
notify orchestrator #42 all stages passed — PR #9 ready for human merge 42" "$(jr)" "handoff: approved.md on the PR, then the relay; no close, no merge items"
assert_contains "$(cat "$STUB_DIR/last-body")" "**Agent:** orchestrator (talos)" "handoff: the comment carries the orchestrator header"
assert_contains "$(cat "$STUB_DIR/last-body")" "APPROVED - all stages passed" "handoff: the verdict and summary"
assert_contains "$(cat "$STUB_DIR/last-body")" "- Evidence: https://example.test/e" "handoff: the details file is the comment's details"
assert_out "handoff" 'post_merge=handoff'
reset_stubs; set_stub comment-pr 1 "" "boom"
pm 9 42 --handoff
assert_contains "$OUT" "warn reason=comment-failed issue=42" "handoff: a failed comment is a warning, and the relay still goes"
assert_eq "1" "$(called notify)" "handoff: the relay goes after a failed comment"

# ── (a) post-merge: the lease release (#470, AC4) ────────────────────────────
# The merge path is the run that held the issue's lease (`next` answered
# action=merge): its work complete, it frees the issue. A heal is another
# run's bookkeeping and releases nothing.
LEASE="$SANDBOX/.git/talos-lease.ledger"
reset_stubs
printf 'issue=42 held=1 expires=9999999999 pid=%s\n' "$$" > "$LEASE"
pm 9 42
assert_eq "0" "$RC" "lease release: post-merge still exits 0 with a held lease"
assert_not_contains "$(cat "$LEASE" 2>/dev/null)" "issue=42" "lease release: the merge path releases the issue's lease"
assert_not_contains "$OUT" "warn reason=lease" "lease release: a released lease warns nothing"
reset_stubs
printf 'issue=42 held=1 expires=9999999999 pid=%s\n' "$$" > "$LEASE"
pm 9 42 --heal
assert_contains "$(cat "$LEASE" 2>/dev/null)" "issue=42" "lease release: a heal is another run's bookkeeping and releases nothing"
assert_not_contains "$OUT" "warn reason=lease" "lease release: a heal never touches the lease it does not own"

# ── (b) sweep ────────────────────────────────────────────────────────────────
# Item 2: the heal.
reset_stubs
set_stub list-issues 0 "[$(issue_json 5 pipeline:review),$(issue_json 6 bug),$(issue_json 7 pipeline:dev),$(issue_json 8 pipeline:dev),$(issue_json 9 pipeline:dev)]"
set_stub find-pr.5 0 '{"number":31,"state":"MERGED","title":"t","headRefName":"fix/issue-5-x"}'
set_stub find-pr.7 2 "" "not implemented"
set_stub find-pr.8 0 ""
set_stub find-pr.9 1 "" "gh failed"
sw 1 2
assert_eq "0" "$RC" "sweep: exits 0"
assert_eq "$(printf 'vcs find-pr 5 merged\nvcs find-pr 7 merged\nvcs find-pr 8 merged\nvcs find-pr 9 merged')" "$(journal | grep '^vcs find-pr')" "heal: find-pr merged for each open pipeline:* issue, none for an unlabeled one"
assert_contains "$OUT" "heal=5 pr=31" "heal: a merged PR is healed"
assert_contains "$(journal)" "vcs close-issue 5 closed by PR #31" "heal: the post-merge items run (close)"
assert_contains "$(journal)" "hooks post_stage merged orchestrator 5 --pr 31 --summary PR #31 merged" "heal: the merged event, with no --ci-runs"
assert_not_contains "$(journal)" "--ci-runs" "heal: a heal never records ci_runs"
assert_not_contains "$(journal)" "vcs comment-issue 7" "heal: nothing for an unverified issue"
assert_contains "$OUT" "warn reason=find-pr-unverified issue=7" "heal: find-pr exit 2 is NOT VERIFIED: skipped and reported"
assert_not_contains "$OUT" "heal=7" "heal: exit 2 is never read as a merged PR"
assert_not_contains "$OUT" "issue=7 pr" "heal: exit 2 is never read as no PR either"
assert_contains "$OUT" "warn reason=find-pr-failed issue=9" "heal: any other non-zero is a fetch failure, reported"
assert_not_contains "$OUT" "heal=8" "heal: no merged PR: nothing to heal"
assert_eq "0" "$(called conflict-files)" "heal: no sibling sync on a heal"
assert_contains "$(journal)" "vcs comment-issue 5 --body-file" "heal: the close comment is posted"
assert_contains "$(journal)" "--allow-closed" "heal: with --allow-closed (GitHub may already have closed the issue)"
assert_out "heal" "sweep=done"
# A re-run, the comment now on the issue: no second comment.
python3 -I -c 'import json, sys; print(json.dumps({"comments": [{"author": {"login": "bot"}, "body": sys.stdin.read()}]}))' <<< "$(cat "$STUB_DIR/last-body")" > "$SANDBOX/c.json"
set_stub read-comments 0 "$(cat "$SANDBOX/c.json")"
rm -f "$STUB_DIR/journal"
sw 1 2
assert_eq "0" "$(called comment-issue)" "heal: a second sweep posts no second close comment"
assert_eq "1" "$(called close-issue)" "heal: the issue is still open, so close-issue is retried with the marker present"
# list-issues failing: the heal and the issue sweeps are skipped, the worktree sweep is not.
reset_stubs; set_stub list-issues 1 "" "boom"
sw 1
assert_contains "$OUT" "warn reason=issues-unlisted" "sweep: an unreadable issue list is reported"
assert_eq "0" "$(called find-pr)" "sweep: and nothing is healed"
assert_eq "1" "$(called worktree)" "sweep: the worktree sweep still runs"
assert_out "issues-unlisted" "sweep=done"

# Item 4: the worktree sweep with the queue ids.
reset_stubs
set_stub worktree.sweep 0 "removed /w/a
talos:worktree-sweep removed=2 kept=1 freed=3M"
sw 4 5
assert_contains "$(journal)" "worktree sweep 4 5" "worktrees: the queue ids are passed, in order"
assert_contains "$OUT" "worktree_sweep=talos:worktree-sweep removed=2 kept=1 freed=3M" "worktrees: the summary line is reported"
rm -f "$STUB_DIR/journal"
sw
assert_contains "$(journal)" "worktree sweep" "worktrees: no ids reclaims all of them"
assert_eq "worktree sweep" "$(journal | grep '^worktree')" "worktrees: and passes no id"
set_stub worktree.sweep 1 "" "boom"
sw 4
assert_contains "$OUT" "warn reason=worktree-sweep-failed" "worktrees: a failed sweep is a warning"

# Item 5: stale blocked work.
reset_stubs
set_stub list-issues 0 "[$(issue_json 8 pipeline:blocked),$(issue_json 3 pipeline:blocked,bug),$(issue_json 4 pipeline:ready)]"
set_stub list-prs 0 "[$(pr_json 21 fix/issue-8-x main pipeline:blocked,pipeline:review),$(pr_json 22 fix/issue-9-x main '' true),$(pr_json 23 fix/issue-10-x main pipeline:review),$(pr_json 24 chore/q main pipeline:blocked)]"
sw 4
assert_contains "$OUT" "blocked_issues=2" "blocked: two blocked issues"
assert_contains "$OUT" "blocked_prs=1" "blocked: one blocked pipeline PR (a fork lookalike and a non-pipeline branch do not count)"
assert_contains "$(journal)" "notify info backlog 2 blocked issues, 1 blocked PRs awaiting human action: #3, #8, PR #21 backlog" "blocked: one summary notice"
assert_eq "1" "$(called notify)" "blocked: exactly one notice"
assert_out "blocked" "sweep=done"
set_stub notify 1 "" "boom"
sw 4
assert_eq "warn reason=notify-failed" "$(printf '%s\n' "$OUT" | grep 'reason=notify-failed')" "blocked: a failed backlog notice is a warning with no issue key"
assert_out "blocked (notify failed)" "sweep=done"
reset_stubs
sw 4
assert_contains "$OUT" "blocked_issues=0" "blocked: none"
assert_eq "0" "$(called notify)" "blocked: K + J = 0 sends nothing"

# Items 6 and 7 need roles.planner.
reset_stubs
cfg_json '{"vcs": {"provider": "github"}, "roles": {"planner": true}}'
set_stub list-issues 0 "[$(issue_json 100 pipeline:epic-decomposed),$(issue_json 101 pipeline:epic-decomposed),$(issue_json 102 pipeline:epic-decomposed),$(issue_json 103 pipeline:epic-decomposed,pipeline:epic-children-done),$(issue_json 104 pipeline:epic-decomposed),$(issue_json 105 pipeline:epic-decomposed,pipeline:epic-children-done),$(issue_json 1 pipeline:epic-decomposed),$(issue_json 50 pipeline:dev 'Part of #101'),$(issue_json 51 pipeline:dev 'Part of #10')]"
set_stub check-epic-acceptance.100 0 ""
set_stub check-epic-acceptance.102 1 '- [ ] ship `$(touch '"$SANDBOX"'/pwned)` now'
set_stub check-epic-acceptance.103 1 "- [ ] still open"
set_stub check-epic-acceptance.104 2 "" "not supported"
set_stub check-epic-acceptance.105 0 ""
set_stub check-epic-acceptance.1 0 ""
sw 3
assert_eq "$(printf 'vcs check-epic-acceptance 1\nvcs check-epic-acceptance 100\nvcs check-epic-acceptance 102\nvcs check-epic-acceptance 103\nvcs check-epic-acceptance 104\nvcs check-epic-acceptance 105')" "$(journal | grep 'check-epic-acceptance')" "epics: the acceptance check runs on every sweep for each epic with no open child; an open child ('Part of #101') skips its epic, 'Part of #10' is not a child of #1"
assert_contains "$OUT" "epic=100 action=closed" "epics: exit 0 closes"
assert_contains "$(journal)" "vcs close-issue 100 All sub-issues resolved." "epics: the close call"
assert_contains "$OUT" "epic=105 action=closed" "epics: exit 0 closes an epic flagged on an earlier sweep"
assert_contains "$(journal)" "vcs label-issue 105 --remove pipeline:epic-children-done" "epics: and removes the children-done label"
assert_eq "0" "$(journal | grep -c 'label-issue 100 --remove')" "epics: an unflagged epic has no label to remove"
assert_contains "$OUT" "epic=102 action=pending" "epics: unticked boxes: flagged and commented once"
assert_contains "$(journal)" "vcs label-issue 102 --add pipeline:epic-children-done" "epics: the flag label"
assert_contains "$(journal)" "vcs comment-issue 102 --body-file" "epics: the comment goes by file"
assert_contains "$(cat "$STUB_DIR/bodies")" '- [ ] ship `$(touch '"$SANDBOX"'/pwned)` now' "epics: the unticked item is data in the body, byte for byte"
assert_eq "no" "$([ -e "$SANDBOX/pwned" ] && echo yes || echo no)" "epics: item text is never run as a command"
assert_contains "$(cat "$STUB_DIR/bodies")" "**Agent:** orchestrator (talos)" "epics: the comment carries the header"
assert_contains "$OUT" "epic=103 action=waiting" "epics: an epic already flagged is not labeled or commented again"
assert_eq "0" "$(journal | grep -c 'label-issue 103\|comment-issue 103')" "epics: the idempotency guard writes nothing"
assert_contains "$OUT" "warn reason=epic-acceptance-unsupported epic=104" "epics: exit 2 leaves the epic open and says so"
assert_eq "0" "$(journal | grep -c 'close-issue 104\|label-issue 104')" "epics: exit 2 writes nothing"
assert_out "epics" "sweep=done"
# Hostile text in an item cannot forge a line.
reset_stubs
cfg_json '{"vcs": {"provider": "github"}, "roles": {"planner": true}}'
set_stub list-issues 0 "[$(issue_json 100 pipeline:epic-decomposed)]"
set_stub check-epic-acceptance 1 "- [ ] x"
sw
assert_contains "$OUT" "epic=100 action=pending" "epics: the pending report is a fixed line"
# A failed epic close is a warning and no `epic=` line (the epic is still open).
reset_stubs
cfg_json '{"vcs": {"provider": "github"}, "roles": {"planner": true}}'
set_stub list-issues 0 "[$(issue_json 100 pipeline:epic-decomposed,pipeline:epic-children-done)]"
set_stub check-epic-acceptance 0 ""
set_stub close-issue 1 "" "boom"
sw
assert_contains "$OUT" "warn reason=epic-close-failed issue=100" "epics: a failed close warns"
assert_not_contains "$OUT" "epic=100 action=closed" "epics: and is not reported as closed"
assert_eq "0" "$(printf '%s\n' "$OUT" | grep -c '^epic=')" "epics: no epic= line at all after a failed close"
assert_eq "0" "$(journal | grep -c 'label-issue 100 --remove')" "epics: the flag label stays so the next sweep retries"
assert_out "epics (close failed)" "sweep=done"

# Dependency unblocking.
reset_stubs
cfg_json '{"vcs": {"provider": "github"}, "roles": {"planner": true}}'
set_stub list-issues 0 "[$(issue_json 30 pipeline:confirmed 'x
Depends on: #29'),$(issue_json 31 pipeline:confirmed 'Depends on: #28'),$(issue_json 28 pipeline:dev),$(issue_json 32 pipeline:ready 'Depends on: #29'),$(issue_json 33 bug 'Depends on: #29, #28'),$(issue_json 34 bug 'no deps')]"
sw 3
assert_eq "unblocked=30" "$(printf '%s\n' "$OUT" | grep '^unblocked=')" "unblock: only an issue whose every dependency is no longer open is unblocked"
assert_contains "$(journal)" "vcs label-issue 30 --add pipeline:ready" "unblock: pipeline:ready is added"
assert_eq "1" "$(called label-issue)" "unblock: no other issue is labeled (31 and 33 wait, 32 already queued, 34 has none)"
cfg_json '{"vcs": {"provider": "github"}}'
rm -f "$STUB_DIR/journal"
sw 3
assert_eq "0" "$(called label-issue)" "unblock: roles.planner off: no epic or dependency sweep"
assert_eq "0" "$(called check-epic-acceptance)" "epics: roles.planner off: no acceptance check"

# Item 8 (needs-owner clearing) went with the status file (#550): the sweep never reads the list.
reset_stubs
sw 3
assert_eq "0" "$(called list-needs-owner)" "sweep: the needs-owner list is not read any more"
assert_not_contains "$OUT" "needs_owner" "sweep: no needs_owner_* lines"

# ── (c) summary ──────────────────────────────────────────────────────────────
reset_stubs
set_stub list-prs 0 "[$(pr_json 21 fix/issue-8-x main pipeline:review),$(pr_json 22 feat/issue-9-y main pipeline:review),$(pr_json 23 fix/issue-12-z main '' true),$(pr_json 24 fix/issue-13-w other pipeline:review),$(pr_json 25 chore/x main pipeline:review)]"
set_stub worktree.sweep 0 "talos:worktree-sweep removed=1 kept=2 freed=1M"
sm 4 5
assert_eq "0" "$RC" "summary: exits 0"
assert_contains "$(journal)" "worktree sweep 4 5 8 9 12 13" "summary: the run's issues plus the issue of every open PR are kept (any base, label or fork, as the old Step 5 said; a non-issue branch has no id)"
assert_contains "$OUT" "worktree_sweep=talos:worktree-sweep removed=1 kept=2 freed=1M" "summary: the sweep line is reported"
assert_contains "$(journal)" "events cost --summary --issue 4 --issue 5" "summary: one cost call, one --issue each"
assert_eq "1" "$(called events)" "summary: exactly one cost call"
assert_eq "worktree sweep 4 5 8 9 12 13
worktree list
events cost --summary --issue 4 --issue 5" "$(journal | grep -v '^vcs')" "summary: sweep, then the threshold check, then the cost table"
assert_out "summary" "summary=done"
set_stub events.cost.summary 0 "| Issue | Cost |
| #4 | 12 |"
sm 4
assert_contains "$OUT" "cost=| Issue | Cost |" "summary: the cost table is passed on line by line"
assert_contains "$OUT" "cost=| #4 | 12 |" "summary: every line"
# The PR list unreadable: nothing is swept (a worktree awaiting review is not lost).
set_stub list-prs 1 "" "boom"
rm -f "$STUB_DIR/journal"
sm 4
assert_contains "$OUT" "warn reason=prs-unlisted" "summary: an unreadable PR list is reported"
assert_eq "0" "$(journal | grep -c '^worktree sweep')" "summary: no worktree is swept on an unknown PR list"
# The threshold warning is relayed once; none is silence.
reset_stubs
set_stub worktree.list 0 "pipeline-worktree: WARNING: 12 worktrees exist (threshold 10)
a b c"
sm 4
assert_contains "$OUT" "worktree_warning=pipeline-worktree: WARNING: 12 worktrees exist (threshold 10)" "summary: the warning line is reported"
assert_contains "$(journal)" "notify info worktrees pipeline-worktree: WARNING: 12 worktrees exist (threshold 10)" "summary: and relayed once as an info notice"
assert_eq "1" "$(called notify)" "summary: exactly one notice"
reset_stubs
set_stub worktree.list 0 "a b c"
sm 4
assert_eq "0" "$(called notify)" "summary: no warning line, no notice"
# No ids: no cost call; the sweep keeps only the open PRs' issues.
reset_stubs
sm
assert_eq "0" "$(called events)" "summary: no issue ids, no cost call"
# The status resume block went with the status file (#550).
reset_stubs
sm 4
assert_eq "0" "$(called status-file)" "summary: no status refresh any more"

# ── (d) sanitising ───────────────────────────────────────────────────────────
reset_stubs
set_stub notify 1 "" "$(printf 'boom \033[2Jx\nFORGED=1')"
set_stub events.cost.line 0 "$(printf 'spend \033[2Jx\nFORGED=2')"
pm 9 42
assert_eq "0" "$(printf '%s\n' "$OUT" | grep -c '^FORGED')" "sanitising: a newline in a value cannot forge a line"
assert_contains "$OUT" 'spend=spend \x1b[2Jx' "sanitising: a control byte in the spend line prints as \\xNN"
assert_contains "$(cat "$ERR")" 'note post-merge=notify msg=boom \x1b[2Jx' "sanitising: child stderr is relayed as a note line, escaped"
assert_not_contains "$(cat "$ERR")" "$(printf '\033')" "sanitising: no raw control byte reaches stderr"
assert_eq "0" "$(grep -c '^FORGED' "$ERR")" "sanitising: a relayed line cannot start with a key"
assert_out "sanitising" "$PM_FIRST"

# ── (d) the checker is not vacuous ───────────────────────────────────────────
printf 'post_merge=done\nrecorded=no\n' > "$SANDBOX/ok.pm"
check_out "$SANDBOX/ok.pm" "$PM_FIRST"; assert_eq "0" "$?" "checker: a plain run passes"
printf 'recorded=no\npost_merge=done\n' > "$SANDBOX/mut.pm"
check_out "$SANDBOX/mut.pm" "$PM_FIRST"; assert_eq "1" "$?" "mutation: the mode line not first turns the checker red"
printf 'post_merge=done\nwarn reason=because\n' > "$SANDBOX/mut.pm"
check_out "$SANDBOX/mut.pm" "$PM_FIRST"; assert_eq "1" "$?" "mutation: an out-of-enum reason turns the checker red"
printf 'post_merge=done\nfree text\n' > "$SANDBOX/mut.pm"
check_out "$SANDBOX/mut.pm" "$PM_FIRST"; assert_eq "1" "$?" "mutation: a line that is neither KEY=value nor warn turns the checker red"
printf 'post_merge=done\nx=a\033[2Jb\n' > "$SANDBOX/mut.pm"
check_out "$SANDBOX/mut.pm" "$PM_FIRST"; assert_eq "1" "$?" "mutation: a raw ESC byte turns the checker red"
printf 'stop reason=made-up\n' > "$SANDBOX/mut.pm"
check_out "$SANDBOX/mut.pm" "$PM_FIRST"; assert_eq "1" "$?" "mutation: an out-of-enum stop reason turns the checker red"

# ── (d) usage and environment ────────────────────────────────────────────────
reset_stubs
for args in "post-merge" "post-merge 9" "post-merge x 42" "post-merge 9 4x" "post-merge 9 42 --ci-runs" "post-merge 9 42 --ci-runs x" \
            "post-merge 9 42 --nope" "post-merge 9 42 extra" "post-merge 9 42 --handoff --heal" "post-merge 9 42 --handoff --ci-runs 3" \
            "post-merge 9 42 --details-file /nonexistent" "post-merge 9 42 --handoff --details-file /nonexistent" \
            "sweep x" "sweep 3 x" "sweep -1" "summary x" "summary 3 4x"; do
  # shellcheck disable=SC2086
  OUT="$(bash "$PM" $args 2>/dev/null)"; RC=$?
  assert_eq "2:stop reason=usage" "$RC:$OUT" "usage: talos.sh $args exits 2 with stop reason=usage"
done
assert_eq "0" "$(journal | wc -l | tr -d ' ')" "usage: a usage error calls nothing"

mkdir "$SANDBOX/lone"
cp "$TALOS" "$SANDBOX/lone/talos.sh"
for v in "post-merge 9 42" "sweep" "summary"; do
  # shellcheck disable=SC2086
  OUT="$(bash "$SANDBOX/lone/talos.sh" $v 2>/dev/null)"; RC=$?
  assert_eq "1:stop reason=scripts-missing" "$RC:$OUT" "stop: $v without its sibling scripts"
done
HELP="$(bash "$TALOS" help 2>&1)"
assert_contains "$HELP" "post-merge <pr> <issue>" "help: names post-merge"
assert_contains "$HELP" "sweep [<issue-id>...]" "help: names sweep"
assert_contains "$HELP" "summary [<issue-id>...]" "help: names summary"

finish
