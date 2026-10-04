#!/usr/bin/env bash
# test-status-file-refresh.sh -- unit tests for scripts/pipeline-status-file.sh
# (#346, sub-task 4 of epic #333): `refresh`, `refresh --print` and
# `assemble --refresh`, the generated "Resume here" block.
#
# Contract:
#   refresh          regenerate the block from GitHub read verbs and push it
#                    (one commit, subject `docs(status): refresh resume block
#                    [skip ci]`); a block identical to the base's is a no-op.
#   refresh --print  block on stdout; no worktree, commit, push or write verb.
#   assemble --refresh  log and block in one commit; a failed GitHub read still
#                    assembles the log and says the block was not refreshed.
#   exit 1           any read that feeds the block failed (list-prs,
#                    list-issues, pr-head, check-approval-sha, list-needs-owner
#                    with exit 1): nothing pushed.
#
# Every refresh runs against a bare `origin` inside the sandbox (no network).
# The GitHub reads go through a VERB-LEVEL stub: scripts/ is copied into the
# sandbox and its pipeline-vcs.sh replaced (the script resolves it via its own
# directory), because the `gh` stub has one global head SHA and no isDraft
# handler. The real gh stub is used once, for the no-write assertion.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

SF_REAL="$TALOS_ROOT/scripts/pipeline-status-file.sh"
export TALOS_STATUS_TODAY="2026-09-20"

git config user.email "test@talos.invalid"
git config user.name "talos-test"
git config commit.gpgsign false

PARENT="$(mktemp -d "${TMPDIR:-/tmp}/talos-sf-refresh.XXXXXX")" || exit 1
{ [ -n "$PARENT" ] && [ -d "$PARENT" ]; } || exit 1
UPSTREAM="$PARENT/upstream.git"
WORK="$PARENT/work"
FX="$PARENT/fx"
SCR="$PARENT/scripts"
trap 'rm -rf "$SANDBOX" "$PARENT"' EXIT
mkdir -p "$PARENT/tmp"
export TMPDIR="$PARENT/tmp"
export SF_FX="$FX"

# rm_under_parent <path>...: rm -rf that only acts on paths strictly under
# $PARENT (the checked mktemp -d above); anything else, or a ".." component, is
# refused instead of removed (#448).
rm_under_parent() {
  local d
  for d in "$@"; do
    case "$d" in
      "$PARENT"/*) ;;
      *) echo "rm_under_parent: refusing '$d' (not under \$PARENT)" >&2; exit 1 ;;
    esac
    case "$d" in
      */../*|*/..) echo "rm_under_parent: refusing '$d' (.. component)" >&2; exit 1 ;;
    esac
    rm -rf "$d"
  done
}

# ── copied scripts dir with a verb-level pipeline-vcs.sh stub ───────────────
cp -R "$TALOS_ROOT/scripts" "$SCR"
cat > "$SCR/pipeline-vcs.sh" <<'TALOS_stubvcs7Hq2LmZx'
#!/usr/bin/env bash
# Verb-level stub. Fixtures live in $SF_FX; every call is logged. Any verb that
# is not a read verb is logged as WRITE and fails, so a test can see it.
FX="${SF_FX:?}"
verb="${1:-}"; shift
printf '%s %s\n' "$verb" "$*" >> "$FX/calls.log"
rc_of() { if [ -f "$FX/$1" ]; then cat "$FX/$1"; else echo "${2:-0}"; fi; }
[ -f "$FX/sleep.$verb" ] && sleep "$(cat "$FX/sleep.$verb")"
case "$verb" in
  list-prs)
    [ -f "$FX/prs.err" ] && cat "$FX/prs.err" >&2
    [ -f "$FX/prs.json" ] && cat "$FX/prs.json"
    exit "$(rc_of prs.rc 0)" ;;
  list-issues)
    [ -f "$FX/issues.err" ] && cat "$FX/issues.err" >&2
    [ -f "$FX/issues.json" ] && cat "$FX/issues.json"
    exit "$(rc_of issues.rc 0)" ;;
  pr-head)
    [ -f "$FX/head.$1" ] || exit 1
    cat "$FX/head.$1"; exit 0 ;;
  check-approval-sha)
    [ -f "$FX/stale.$1" ] && cat "$FX/stale.$1"
    exit "$(rc_of "stale.$1.rc" 0)" ;;
  pr-checks-required)
    exit "$(rc_of "ci.$1.rc" 0)" ;;
  pr-is-draft)
    rc="$(rc_of "draft.$1.rc" 1)"
    [ "$rc" = 0 ] && echo draft
    [ "$rc" = 1 ] && echo ready
    exit "$rc" ;;
  list-needs-owner)
    [ -f "$FX/owners.err" ] && cat "$FX/owners.err" >&2
    if [ -f "$FX/owners.json" ]; then cat "$FX/owners.json"; else echo '[]'; fi
    exit "$(rc_of owners.rc 0)" ;;
  *)
    printf 'WRITE %s\n' "$verb" >> "$FX/calls.log"
    exit 99 ;;
esac
TALOS_stubvcs7Hq2LmZx
SF="$SCR/pipeline-status-file.sh"

echo "seed" > README.md
printf 'talos.pipeline.json\n' >> .git/info/exclude
git add README.md
git commit -q -m "seed"
git branch -M main

# pr.draft is explicit (#435: the draft flow is the default, so a table that
# assumes the ready order must say so). RF_DRAFT=true overrides it.
cfg_rf() {  # $1 = extra top-level JSON members, $2 = extra status members
  printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main", "pr": {"draft": %s}%s, "status": {"enabled": true%s}}\n' \
    "${RF_DRAFT:-false}" "${1:+, $1}" "${2:+, $2}" > talos.pipeline.json
}

reset_fixture() {
  rm_under_parent "$UPSTREAM" "$WORK"
  git init -q --bare "$UPSTREAM"
  git --git-dir="$UPSTREAM" symbolic-ref HEAD refs/heads/main
  git remote set-url origin "$UPSTREAM"
  git push -q -f origin main
  git fetch -q origin main
  git clone -q -b main "$UPSTREAM" "$WORK"
  git -C "$WORK" config user.email "pr@talos.invalid"
  git -C "$WORK" config user.name "pr-author"
  git -C "$WORK" config commit.gpgsign false
  git -C "$WORK" config pull.rebase false
}

wk_add() {  # path content date
  mkdir -p "$WORK/$(dirname "$1")"
  printf '%s\n' "$2" > "$WORK/$1"
  git -C "$WORK" add -- "$1"
  GIT_AUTHOR_DATE="$3T12:00:00" GIT_COMMITTER_DATE="$3T12:00:00" \
    git -C "$WORK" commit -q -m "add $1"
}
wk_push() { git -C "$WORK" push -q origin HEAD:main; }
ofetch() { git fetch -q origin main; }
oshow() { git show "origin/main:$1" 2>/dev/null; }
osha() { git rev-parse origin/main; }
ocount() { git rev-list --count origin/main; }
wt_count() { git worktree list | wc -l | tr -d ' '; }
status_tmp_dirs() { ls -d "$PARENT"/tmp/talos-status.* 2>/dev/null | wc -l | tr -d ' '; }
run_sf() { bash "$SF" "$@" 2>&1; }

# ── fixtures for the verb stub ───────────────────────────────────────────────
PRS=(); ISS=()
fx_reset() { rm_under_parent "$FX"; mkdir -p "$FX"; : > "$FX/calls.log"; PRS=(); ISS=(); }
labels_json() {  # "a,b" -> [{"name":"a"},{"name":"b"}]
  local out="" l
  local IFS=,
  for l in $1; do out="${out:+$out,}{\"name\":\"$l\"}"; done
  printf '[%s]' "$out"
}
sha40() { printf '%040d' "$1"; }
add_pr() {  # number branch labels [isCrossRepository: false|true|absent] [baseRefName]
  local cross="\"isCrossRepository\":${4:-false},"
  [ "${4:-}" = "absent" ] && cross=""
  PRS+=("{\"number\":$1,\"title\":\"PR $1\",\"headRefName\":\"$2\",\"baseRefName\":\"${5:-main}\",${cross}\"labels\":$(labels_json "${3:-}")}")
  sha40 "$1" > "$FX/head.$1"
}
add_issue() {  # number labels
  ISS+=("{\"number\":$1,\"title\":\"Issue $1\",\"labels\":$(labels_json "${2:-}"),\"body\":\"\"}")
}
join_json() { local IFS=,; printf '[%s]' "$*"; }
fx_flush() {
  join_json ${PRS[@]+"${PRS[@]}"} > "$FX/prs.json"
  join_json ${ISS[@]+"${ISS[@]}"} > "$FX/issues.json"
}
calls() { cat "$FX/calls.log"; }

# block_of TEXT: the non-blank lines under the resume heading, up to the next heading.
block_of() { printf '%s\n' "$1" | awk '/^## Resume here$/ {f=1; next} /^## / {f=0} f && NF'; }
# without_resume TEXT: everything except the resume section.
without_resume() { printf '%s\n' "$1" | awk '/^## Resume here$/ {f=1; next} /^## / {f=0} !f'; }
line_of() { printf '%s\n' "$1" | grep "$2" | head -1; }
count_of() { printf '%s\n' "$1" | grep -c "$2" || true; }

# stage_of OUTPUT PR: the `next:` stage of a PR line
stage_of() { printf '%s\n' "$1" | sed -n "s/^- PR #$2 (#[0-9]*) head [0-9a-f]* next: //p"; }
# assert_stage LABEL EXPECTED: run `refresh --print` and check PR #10's stage
assert_stage() {
  local out rc
  fx_flush
  out="$(bash "$SF" refresh --print 2>"$PARENT/err")"; rc=$?
  assert_eq_ctx "0" "$rc" "$1: refresh --print exits 0" "$(head -c 300 "$PARENT/err")"
  assert_eq "$2" "$(stage_of "$out" 10)" "$1"
}

# ── header documents the contract ────────────────────────────────────────────
hdr="$(sed -n '1,/^set -uo pipefail/p' "$SF_REAL")"
assert_contains "$hdr" "refresh [--print]" "header: usage lists refresh"
assert_contains "$hdr" "assemble [--pr <pr> --issue <n>] [--refresh]" "header: usage lists assemble --refresh"
assert_contains "$hdr" "waiting on owner" "header: states when Next is waiting on owner"
assert_contains "$hdr" "list-needs-owner" "header: states what list-needs-owner exit codes do"
assert_contains "$hdr" "resume #" "header: states the Next wording"
assert_contains "$hdr" "waiting on human merge of #" "header: states the human-merge Next wording"
assert_contains "$hdr" "[answered|unanswered|unverified]" "header: states the Owner status field"
assert_contains "$hdr" "isCrossRepository" "header: states the fork rule"
assert_contains "$hdr" "TALOS_STATUS_READ_DEADLINE" "header: states the read deadline"

# ── status.enabled gates refresh, not refresh --print ───────────────────────
reset_fixture
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
before="$(osha)"
rm -f talos.pipeline.json
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "enabled: unset exits 0"
assert_contains "$out" "status.enabled is false" "enabled: unset says so"
printf '{"base_branch": "main", "status": {"enabled": false}}\n' > talos.pipeline.json
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "enabled: false exits 0"
assert_contains "$out" "status.enabled is false" "enabled: false says so"
ofetch
assert_eq "$before" "$(osha)" "enabled: false pushes nothing"
assert_eq "" "$(calls)" "enabled: false reads nothing from GitHub"
out="$(bash "$SF" refresh --print 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "enabled: refresh --print works with status.enabled false"
assert_contains "$out" "## Resume here" "enabled: refresh --print prints the heading"
assert_contains "$out" "- PR #10 (#5) head $(sha40 10) next: qa" "enabled: refresh --print prints the block"

# ── argument grammar ─────────────────────────────────────────────────────────
cfg_rf
out="$(run_sf refresh --bogus)"; rc=$?
assert_eq "1" "$rc" "args: refresh rejects an unknown argument"
out="$(run_sf refresh --refresh)"; rc=$?
assert_eq "1" "$rc" "args: refresh --refresh is not a thing"
out="$(run_sf assemble --print)"; rc=$?
assert_eq "1" "$rc" "args: assemble --print is not a thing"
out="$(run_sf refresh --print --print)"; rc=$?
assert_eq "1" "$rc" "args: refresh --print --print is rejected"

# ── three PRs: 40-char heads, stages, non-pipeline branches skipped ─────────
reset_fixture; cfg_rf
fx_reset
add_pr 21 fix/issue-7-b "qa:pass"
add_pr 20 feat/issue-6-a ""
add_pr 22 feat/issue-8 ""
add_pr 30 dependabot/npm/x ""
add_pr 31 feature/issue-9-nope ""
add_pr 32 fix/issue-abc-nope ""
add_pr 33 fix/issue-9x ""
add_issue 6 "pipeline:ready"; add_issue 7 ""; add_issue 8 ""
fx_flush
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "three PRs: refresh exits 0"
ofetch
st="$(oshow TALOS_STATUS.md)"
blk="$(block_of "$st")"
assert_eq "3" "$(count_of "$blk" '^- PR #')" "three PRs: exactly three PR lines"
assert_eq "- PR #20 (#6) head $(sha40 20) next: qa" "$(line_of "$blk" '^- PR #20 ')" "three PRs: #20 line, full 40-char head"
assert_eq "- PR #21 (#7) head $(sha40 21) next: docs" "$(line_of "$blk" '^- PR #21 ')" "three PRs: #21 line"
assert_eq "- PR #22 (#8) head $(sha40 22) next: qa" "$(line_of "$blk" '^- PR #22 ')" "three PRs: #22 line (branch with no slug)"
assert_eq "20 21 22" "$(printf '%s\n' "$blk" | sed -n 's/^- PR #\([0-9]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//')" "three PRs: ascending by PR number"
assert_not_contains "$blk" "#30" "three PRs: dependabot branch not listed"
assert_not_contains "$blk" "#31" "three PRs: feature/issue-* not listed"
assert_not_contains "$blk" "#32" "three PRs: non-digit issue part not listed"
assert_not_contains "$blk" "#33" "three PRs: digits followed by a letter not listed"
assert_eq "2" "$(printf '%s\n' "$blk" | head -2 | grep -c '^- \(Base\|Next\):')" "three PRs: Base and Next come first"
assert_eq "- Next: resume #20 at qa" "$(line_of "$blk" '^- Next:')" "next: lowest-numbered PR is resumed at its stage"
assert_eq "- Queued: #6" "$(line_of "$blk" '^- Queued:')" "queued: lists pipeline:ready issues"
assert_eq "TALOS_STATUS.md" "$(git show --name-only --format= origin/main)" "three PRs: the commit holds only the status file"
assert_eq "docs(status): refresh resume block [skip ci]" "$(git log -1 --format=%s origin/main)" "commit subject"

# ── next-stage table: one fixture per result ────────────────────────────────
ALL="qa:pass,docs:done,review:approved,security:approved"
fx_reset; reset_fixture; cfg_rf
add_pr 10 fix/issue-5-x "pipeline:blocked"; add_issue 5 ""
assert_stage "table: PR label pipeline:blocked -> blocked" blocked
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 "pipeline:blocked"
assert_stage "table: issue label pipeline:blocked -> blocked" blocked
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""
assert_stage "table: no labels -> qa" qa
fx_reset; add_pr 10 fix/issue-5-x "qa:pass"; add_issue 5 ""
assert_stage "table: qa:pass -> docs" docs
fx_reset; add_pr 10 fix/issue-5-x "qa:pass,docs:done"; add_issue 5 ""
assert_stage "table: qa+docs -> reviewer" reviewer
fx_reset; add_pr 10 fix/issue-5-x "qa:pass,docs:done,review:approved"; add_issue 5 ""
assert_stage "table: qa+docs+review -> security" security
cfg_rf '"roles": {"adversarial": true}'
fx_reset; add_pr 10 fix/issue-5-x "$ALL"; add_issue 5 ""
assert_stage "table: roles.adversarial true, no adversarial:approved -> adversarial" adversarial
cfg_rf
fx_reset; add_pr 10 fix/issue-5-x "$ALL"; add_issue 5 ""
assert_stage "table: roles.adversarial unset (default false) skips adversarial -> merge" merge
cfg_rf '"merge": {"required_checks": ["build"]}'
fx_reset; add_pr 10 fix/issue-5-x "$ALL"; add_issue 5 ""; echo 2 > "$FX/ci.10.rc"
assert_stage "table: required check pending (exit 2) -> ci" ci
fx_reset; add_pr 10 fix/issue-5-x "$ALL"; add_issue 5 ""; echo 1 > "$FX/ci.10.rc"
assert_stage "table: required check failed (exit 1) -> ci" ci
fx_reset; add_pr 10 fix/issue-5-x "$ALL"; add_issue 5 ""; echo 0 > "$FX/ci.10.rc"
assert_stage "table: required check passing -> merge" merge
cfg_rf '"merge": {"auto": false}'
fx_reset; add_pr 10 fix/issue-5-x "$ALL"; add_issue 5 ""
assert_stage "table: merge.auto false -> human-merge" human-merge
RF_DRAFT=true cfg_rf
fx_reset; add_pr 10 fix/issue-5-x "docs:done,review:approved,security:approved"; add_issue 5 ""; echo 0 > "$FX/draft.10.rc"
assert_stage "table: draft PR with docs/review/security done -> ready" ready
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; echo 0 > "$FX/draft.10.rc"
assert_stage "table: draft PR skips qa -> docs" docs
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; echo 2 > "$FX/draft.10.rc"
assert_stage "table: pr-is-draft exit 2 -> unverified" unverified
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; echo 1 > "$FX/draft.10.rc"
assert_stage "table: pr.draft true but PR is ready (exit 1) -> default order, qa" qa
cfg_rf
fx_reset; add_pr 10 fix/issue-5-x "$ALL"; add_issue 5 ""; echo 0 > "$FX/draft.10.rc"
assert_stage "table: pr.draft false never asks pr-is-draft" merge
assert_not_contains "$(calls)" "pr-is-draft" "table: pr.draft false makes no pr-is-draft call"
# pr.draft unset (#435): the default is the draft flow on github, and the ready
# flow on github-api (it cannot open draft PRs, so pr-is-draft would exit 2 and
# every PR would read `unverified`).
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main", "status": {"enabled": true}}\n' > talos.pipeline.json
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; echo 0 > "$FX/draft.10.rc"
assert_stage "default: pr.draft unset on github is the draft flow (draft PR skips qa -> docs)" docs
assert_contains "$(calls)" "pr-is-draft 10" "default: pr.draft unset on github asks pr-is-draft"
printf '{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "base_branch": "main", "status": {"enabled": true}}\n' > talos.pipeline.json
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; echo 2 > "$FX/draft.10.rc"
assert_stage "default: pr.draft unset on github-api is the ready flow, never unverified (qa)" qa
assert_not_contains "$(calls)" "pr-is-draft" "default: pr.draft unset on github-api makes no pr-is-draft call"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main", "pr": {"draft": false}, "status": {"enabled": true}}\n' > talos.pipeline.json
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; echo 0 > "$FX/draft.10.rc"
assert_stage "default: an explicit pr.draft false on github keeps the ready flow (qa)" qa
cfg_rf
fx_reset; add_pr 10 fix/issue-5-x "$ALL"; add_issue 5 ""
printf 'stale role=qa label=qa:pass\n' > "$FX/stale.10"; echo 1 > "$FX/stale.10.rc"
assert_stage "table: present but stale qa:pass -> qa" qa
fx_reset; add_pr 10 fix/issue-5-x "$ALL"; add_issue 5 ""
printf 'talos:marker-authors-unverified reader=check-approval-sha\nstale role=reviewer label=review:approved\n' > "$FX/stale.10"; echo 1 > "$FX/stale.10.rc"
assert_stage "table: stale review:approved with a marker-authors line before it -> reviewer" reviewer
fx_reset; add_pr 10 fix/issue-5-x "$ALL"; add_issue 5 ""
printf 'talos:marker-authors-unverified reader=check-approval-sha\n' > "$FX/stale.10"; echo 0 > "$FX/stale.10.rc"
assert_stage "table: a non-stale line is not an answer -> merge" merge
cfg_rf '"roles": {"docs": false, "qa": false}'
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""
assert_stage "table: disabled roles qa and docs are skipped -> reviewer" reviewer
cfg_rf
fx_reset; add_pr 10 fix/issue-5-x "$ALL"; add_issue 5 ""; fx_flush
assert_not_contains "$(bash "$SF" refresh --print 2>&1)" "stale" "table: no stale output rendered"
assert_contains "$(calls)" "check-approval-sha 10 --stale-list" "table: stale check uses --stale-list"

# approval labels absent -> check-approval-sha not needed; blocked PR short-circuits
fx_reset; add_pr 10 fix/issue-5-x "pipeline:blocked"; add_issue 5 ""
fx_flush; bash "$SF" refresh --print >/dev/null 2>&1
assert_not_contains "$(calls)" "check-approval-sha" "table: a blocked PR needs no approval read"

# ── check-approval-sha: exit 1 with no stale line is a failed read ──────────
reset_fixture; cfg_rf
fx_reset; add_pr 10 fix/issue-5-x "qa:pass"; add_issue 5 ""; echo 1 > "$FX/stale.10.rc"; fx_flush
before="$(osha)"
out="$(run_sf refresh)"; rc=$?
assert_eq "1" "$rc" "fail-closed: check-approval-sha exit 1 with no stale line exits 1"
ofetch
assert_eq "$before" "$(osha)" "fail-closed: check-approval-sha failure pushes nothing"

# ── Base line, determinism, second run is a no-op ───────────────────────────
reset_fixture; cfg_rf
wk_add src/code.txt "code" 2026-09-10; wk_push
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
ofetch
code_sha="$(git rev-parse origin/main)"
c0="$(ocount)"
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "base: refresh exits 0"
ofetch
st="$(oshow TALOS_STATUS.md)"
assert_eq "- Base: main @ $code_sha" "$(line_of "$st" '^- Base:')" "base: newest commit outside the status paths"
assert_eq "1" "$(( $(ocount) - c0 ))" "base: refresh made exactly one commit"
after1="$(osha)"; text1="$st"
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "second run: exits 0"
ofetch
assert_eq "$after1" "$(osha)" "second run: creates no commit"
assert_eq "$text1" "$(oshow TALOS_STATUS.md)" "second run: file unchanged"
assert_eq "- Base: main @ $code_sha" "$(line_of "$(oshow TALOS_STATUS.md)" '^- Base:')" "base: unchanged after refresh pushed its own commit"
p1="$(bash "$SF" refresh --print 2>/dev/null)"; p2="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "$p1" "$p2" "determinism: two --print runs are byte-identical"
assert_eq "$(block_of "$p1")" "$(block_of "$text1")" "determinism: --print equals the block refresh wrote"
# A date or time pattern, not the bare "202": a 40-hex SHA contains "202" in
# about 1 run in 6, which made this assertion flaky (#448).
_ts_re='[0-9]{4}-[0-9]{2}-[0-9]{2}|T[0-9]{2}:[0-9]{2}'
has_timestamp() { printf '%s' "$1" | grep -Eq "$_ts_re" && echo yes || echo no; }
assert_eq "no" "$(has_timestamp "$p1")" "determinism: no date or timestamp in the block"
assert_eq "no" "$(has_timestamp '- Base: main @ 1202ab3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f90')" "determinism: a SHA containing 202 is not a timestamp"
assert_eq "yes" "$(has_timestamp 'refreshed 2026-09-20')" "determinism: a date is caught"
assert_eq "yes" "$(has_timestamp 'at 2026-09-20T10:15:00Z')" "determinism: a timestamp is caught"

# a newer unrelated commit moves Base; a docs/status.d-only commit does not
wk_sync() { git -C "$WORK" fetch -q origin main && git -C "$WORK" checkout -q -B main origin/main; }
wk_sync
wk_add docs/status.d/1-2.md "frag" 2026-09-11; wk_push; ofetch
assert_eq "- Base: main @ $code_sha" "$(line_of "$(bash "$SF" refresh --print 2>/dev/null)" '^- Base:')" "base: a fragment-only commit does not move Base"
wk_sync
wk_add src/more.txt "more" 2026-09-12; wk_push; ofetch
assert_eq "- Base: main @ $(osha)" "$(line_of "$(bash "$SF" refresh --print 2>/dev/null)" '^- Base:')" "base: a code commit moves Base"

# no commit outside the status paths at all
rm_under_parent "$PARENT/solo" "$PARENT/solo.git"
git init -q --bare "$PARENT/solo.git"; git --git-dir="$PARENT/solo.git" symbolic-ref HEAD refs/heads/main
git init -q -b main "$PARENT/solo" 2>/dev/null || { git init -q "$PARENT/solo"; git -C "$PARENT/solo" checkout -q -b main; }
printf '# s\n\n## Resume here\n\nx\n\n## Log\n' > "$PARENT/solo/TALOS_STATUS.md"
git -C "$PARENT/solo" add TALOS_STATUS.md
git -C "$PARENT/solo" -c user.email=a@b -c user.name=n -c commit.gpgsign=false commit -q -m "only status"
git -C "$PARENT/solo" push -q "$PARENT/solo.git" main
git remote set-url origin "$PARENT/solo.git"
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "- Base: main @ none" "$(line_of "$out" '^- Base:')" "base: no commit outside the status paths reads none"
git remote set-url origin "$UPSTREAM"

# ── byte-identical other sections ────────────────────────────────────────────
reset_fixture; cfg_rf
orig="$(printf '# Mine\n\nintro text\n\n## Resume here\n\nold resume junk\n- hand edit\n\n## Notes\n\nnotes `code` here\n\n## Log\n\n- 2026-09-01 PR #1 (#1): first\n  continued\n- 2026-08-30 PR #2 (#2): second\n')"
wk_add TALOS_STATUS.md "$orig" 2026-09-01; wk_push; ofetch
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "sections: refresh exits 0"
ofetch
assert_eq "$(without_resume "$orig")" "$(without_resume "$(oshow TALOS_STATUS.md)")" "sections: everything outside the resume section is byte-identical"
assert_not_contains "$(oshow TALOS_STATUS.md)" "old resume junk" "sections: the old resume text is replaced"
assert_contains "$(oshow TALOS_STATUS.md)" "PR #1 (#1): first" "sections: log entries untouched"
# log heading last / resume heading last
reset_fixture; cfg_rf
wk_add TALOS_STATUS.md "$(printf '# T\n\n## Log\n\n- 2026-09-01 PR #1 (#1): first\n\n## Resume here\n')" 2026-09-01; wk_push; ofetch
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "sections: resume heading as the last section exits 0"
ofetch
assert_eq "$(printf '# T\n\n## Log\n\n- 2026-09-01 PR #1 (#1): first\n')" "$(oshow TALOS_STATUS.md | sed -n '1,/^- 2026-09-01/p')" "sections: text above a trailing resume section unchanged"
assert_contains "$(block_of "$(oshow TALOS_STATUS.md)")" "- Next:" "sections: a trailing resume section is filled"
# missing file: created with both headings
reset_fixture; cfg_rf
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
out="$(run_sf refresh)"; rc=$?
ofetch
assert_eq "0" "$rc" "missing file: refresh exits 0"
assert_contains "$(oshow TALOS_STATUS.md)" "## Log" "missing file: created with the log heading"
assert_contains "$(block_of "$(oshow TALOS_STATUS.md)")" "- PR #10 " "missing file: block written"

# ── cap ──────────────────────────────────────────────────────────────────────
reset_fixture; cfg_rf '' '"resume_max_lines": 1000'
fx_reset; add_issue 5 ""
for i in $(seq 100 159); do add_pr "$i" "fix/issue-$i-x" ""; done
fx_flush
full="$(block_of "$(bash "$SF" refresh --print 2>/dev/null)")"
total="$(printf '%s\n' "$full" | wc -l | tr -d ' ')"
assert_eq "62" "$total" "cap: precondition, 60 PRs + Base + Next = 62 lines uncapped"
cfg_rf '' '"resume_max_lines": 40'
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "cap: refresh exits 0"
ofetch
blk="$(block_of "$(oshow TALOS_STATUS.md)")"
assert_eq "40" "$(printf '%s\n' "$blk" | wc -l | tr -d ' ')" "cap: exactly 40 lines under the heading"
assert_eq "- +23 more" "$(printf '%s\n' "$blk" | tail -1)" "cap: last line is '- +K more', K = omitted lines (62 - 39)"
assert_contains "$(printf '%s\n' "$blk" | sed -n 1p)" "- Base:" "cap: Base is never dropped"
assert_contains "$(printf '%s\n' "$blk" | sed -n 2p)" "- Next:" "cap: Next is never dropped"
assert_eq "37" "$(count_of "$blk" '^- PR #')" "cap: 37 PR lines kept"
# a tiny cap still keeps Base, Next and the marker
cfg_rf '' '"resume_max_lines": 1'
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_contains "$(block_of "$out" | sed -n 1p)" "- Base:" "cap: max 1 still keeps Base"
assert_contains "$(block_of "$out" | sed -n 2p)" "- Next:" "cap: max 1 still keeps Next"
assert_contains "$(block_of "$out" | tail -1)" "more" "cap: max 1 still ends with the more marker"

# ── queued ordering, blocked, owner lines ───────────────────────────────────
reset_fixture; cfg_rf
fx_reset
add_issue 9 "pipeline:ready"; add_issue 4 "pipeline:ready,p2"; add_issue 8 "pipeline:ready,p1"
add_issue 3 "pipeline:ready,p0"; add_issue 7 "pipeline:ready,p1"; add_issue 2 "p0"; add_issue 12 "pipeline:ready"
add_issue 20 "pipeline:blocked"
add_pr 40 fix/issue-30-x "pipeline:blocked"
fx_flush
python3 -I -c '
import json
print(json.dumps([
  {"n": 20, "kind": "issue", "answered": "no", "question": "Pick A or B?"},
  {"n": 21, "kind": "issue", "answered": "yes", "question": "Ship now?"},
]))' > "$FX/owners.json"
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "- Queued: #3, #7, #8, #4, #9, #12" "$(line_of "$out" '^- Queued:')" "queued: p0, p1, p2, unlabelled, then by number"
assert_eq "- Blocked: issue #20 [question] Pick A or B?" "$(line_of "$out" '^- Blocked: issue')" "blocked: issue with an owner question, fixed fields first"
assert_eq "- Blocked: PR #40 [see comments]" "$(line_of "$out" '^- Blocked: PR')" "blocked: PR without a question says see comments"
assert_eq "- Owner: #20 [unanswered] Pick A or B?" "$(line_of "$out" '^- Owner: #20')" "owner: unanswered item, status before the question"
assert_eq "- Owner: #21 [answered] Ship now?" "$(line_of "$out" '^- Owner: #21')" "owner: answered item, status before the question"
assert_eq "- Next: start #3" "$(line_of "$out" '^- Next:')" "next: the first queued issue is started when no PR is actionable"
# order of lines: Base, Next, PR, Blocked, Owner, Queued
kinds="$(block_of "$out" | sed -n 's/^- \([A-Za-z]*\).*/\1/p' | uniq | tr '\n' ' ')"
assert_eq "Base Next PR Blocked Owner Queued " "$kinds" "order: Base, Next, PR, Blocked, Owner, Queued"
assert_contains "$(calls)" "list-needs-owner --json" "owner: read through --json"
assert_not_contains "$(calls)" "--clear-answered" "owner: never --clear-answered"
# unverified trust set: [unverified], never [answered]
printf 'pipeline-vcs: talos:marker-authors-unverified reader=needs-owner\n' > "$FX/owners.err"
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "- Owner: #21 [unverified] Ship now?" "$(line_of "$out" '^- Owner: #21')" "owner: marker-authors-unverified renders [unverified], not [answered]"
assert_eq "- Owner: #20 [unverified] Pick A or B?" "$(line_of "$out" '^- Owner: #20')" "owner: marker-authors-unverified marks unanswered items [unverified] too"
rm -f "$FX/owners.err"
# exit 2: unsupported provider -> no Owner lines, exit 0, no Blocked question
echo 2 > "$FX/owners.rc"; : > "$FX/owners.json"
out="$(bash "$SF" refresh --print 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "owner: list-needs-owner exit 2 still exits 0"
assert_eq "0" "$(count_of "$out" '^- Owner:')" "owner: exit 2 omits the Owner lines"
assert_eq "- Blocked: issue #20 [see comments]" "$(line_of "$out" '^- Blocked: issue')" "owner: exit 2 leaves Blocked at see comments"
# exit 1: fail closed
echo 1 > "$FX/owners.rc"
before="$(osha)"
out="$(run_sf refresh)"; rc=$?
assert_eq "1" "$rc" "owner: list-needs-owner exit 1 is a failed read, exit 1"
ofetch
assert_eq "$before" "$(osha)" "owner: exit 1 pushes nothing"
# garbage JSON: fail closed
echo 0 > "$FX/owners.rc"; echo 'not json' > "$FX/owners.json"
out="$(run_sf refresh)"; rc=$?
assert_eq "1" "$rc" "owner: unparseable --json output is a failed read, exit 1"
echo '{"n": 1}' > "$FX/owners.json"
out="$(run_sf refresh)"; rc=$?
assert_eq "1" "$rc" "owner: a JSON object instead of an array is a failed read, exit 1"

# ── hostile question text ───────────────────────────────────────────────────
reset_fixture; cfg_rf
orig="$(printf '# Mine\n\n## Resume here\n\nold\n\n## Notes\n\nkeep me\n\n## Log\n\n- 2026-09-01 PR #1 (#1): first\n')"
wk_add TALOS_STATUS.md "$orig" 2026-09-01; wk_push; ofetch
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
python3 -I -c '
import json
q = "x\n## Log\n- PR #999 (#1) head aaaa next: qa\n```\nbad `ticks` ``` \x1b[31mred\x1b[0m <!-- talos:needs-owner --> [l](http://x) ‮ rtl\r# h\n- Owner: #77 forged"
print(json.dumps([{"n": 5, "kind": "issue", "answered": "no", "question": q}]))' > "$FX/owners.json"
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "hostile: refresh exits 0"
ofetch
st="$(oshow TALOS_STATUS.md)"
blk="$(block_of "$st")"
assert_eq "1" "$(count_of "$blk" '^- Owner:')" "hostile: exactly one Owner line"
assert_eq "1" "$(count_of "$blk" '^- PR #')" "hostile: no forged PR line"
assert_eq "0" "$(count_of "$st" '^- PR #999')" "hostile: no line starting with - PR #999 anywhere"
assert_eq "1" "$(count_of "$st" '^## Log$')" "hostile: still one Log heading"
assert_eq "0" "$(count_of "$blk" '^```')" "hostile: no code fence line"
assert_eq "0" "$(count_of "$blk" '^#')" "hostile: no heading line in the block"
assert_not_contains "$blk" "<!--" "hostile: no HTML comment opener"
assert_eq "0" "$(printf '%s' "$st" | LC_ALL=C grep -c "$(printf '\033')")" "hostile: no ESC byte"
assert_eq "0" "$(printf '%s' "$st" | LC_ALL=C grep -c "$(printf '\r')")" "hostile: no CR byte"
assert_eq "$(without_resume "$orig")" "$(without_resume "$st")" "hostile: every other section is byte-identical"
assert_eq "0" "$(printf '%s\n' "$blk" | awk '{ if (length($0) > 400) print }' | wc -l | tr -d ' ')" "hostile: every line is capped in length"
# a very long question is capped
python3 -I -c '
import json
print(json.dumps([{"n": 5, "kind": "issue", "answered": "no", "question": "w " * 5000}]))' > "$FX/owners.json"
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "0" "$(printf '%s\n' "$out" | awk '{ if (length($0) > 400) print }' | wc -l | tr -d ' ')" "hostile: a 10000-character question is capped"
# a hostile question on a Blocked line is escaped the same way
add_issue 6 "pipeline:blocked"; fx_flush
python3 -I -c '
import json
print(json.dumps([{"n": 6, "kind": "issue", "answered": "no", "question": "a\n## Log\n- PR #999 x"}]))' > "$FX/owners.json"
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "0" "$(count_of "$out" '^## Log')" "hostile: Blocked question cannot start a heading"
assert_eq "0" "$(count_of "$out" '^- PR #999')" "hostile: Blocked question cannot start a list item"
assert_eq "1" "$(count_of "$out" '^- Blocked:')" "hostile: exactly one Blocked line"

# ── fail-closed reads ────────────────────────────────────────────────────────
for verb_rc in prs issues; do
  reset_fixture; cfg_rf
  fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
  echo 1 > "$FX/$verb_rc.rc"
  before="$(osha)"; wt_before="$(wt_count)"
  out="$(run_sf refresh)"; rc=$?
  assert_eq "1" "$rc" "fail-closed: list-$verb_rc exit 1 makes refresh exit 1"
  ofetch
  assert_eq "$before" "$(osha)" "fail-closed: list-$verb_rc failure pushes nothing"
  assert_eq "$wt_before" "$(wt_count)" "fail-closed: list-$verb_rc failure leaves no worktree"
  out="$(run_sf refresh --print)"; rc=$?
  assert_eq "1" "$rc" "fail-closed: list-$verb_rc exit 1 makes refresh --print exit 1"
done
reset_fixture; cfg_rf
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush; rm -f "$FX/head.10"
before="$(osha)"
out="$(run_sf refresh)"; rc=$?
assert_eq "1" "$rc" "fail-closed: an unresolvable pr-head exits 1"
ofetch
assert_eq "$before" "$(osha)" "fail-closed: an unresolvable pr-head pushes nothing"
echo 'not-a-sha' > "$FX/head.10"
out="$(run_sf refresh)"; rc=$?
assert_eq "1" "$rc" "fail-closed: a pr-head that is not a SHA exits 1"
# a cap warning is never rendered as complete
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
printf 'pipeline-vcs: list-prs: WARNING result capped at 100 (az repos pr list --top ceiling) -- some PRs may be missing\n' > "$FX/prs.err"
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_contains "$(printf '%s\n' "$out" | tail -1)" "capped" "cap warning: the last line of the block says the listing was capped"
assert_contains "$(printf '%s\n' "$out" | tail -1)" "list-prs" "cap warning: names list-prs"
rm -f "$FX/prs.err"
printf 'pipeline-vcs: list-issues: WARNING result capped at 100 (x) -- some issues may be missing\n' > "$FX/issues.err"
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_contains "$(printf '%s\n' "$out" | tail -1)" "list-issues" "cap warning: a capped list-issues is noted the same way"
rm -f "$FX/issues.err"
cfg_rf '' '"resume_max_lines": 5'
fx_reset; add_issue 5 ""; for i in 100 101 102 103 104 105; do add_pr "$i" "fix/issue-$i-x" ""; done; fx_flush
printf 'pipeline-vcs: list-prs: WARNING result capped at 100 (x) -- some PRs may be missing\n' > "$FX/prs.err"
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "5" "$(block_of "$out" | wc -l | tr -d ' ')" "cap warning: still at most resume_max_lines lines with the note"
assert_contains "$(block_of "$out" | tail -1)" "capped" "cap warning: the note stays last under the line cap"
assert_contains "$(block_of "$out" | tail -2 | head -1)" "more" "cap warning: the more marker precedes the note"

# ── refresh --print writes nothing ──────────────────────────────────────────
reset_fixture; cfg_rf
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
ofetch
before="$(osha)"; wt_before="$(wt_count)"
git status --porcelain > "$PARENT/porcelain.before"
out="$(bash "$SF" refresh --print 2>"$PARENT/err")"; rc=$?
assert_eq "0" "$rc" "print: exits 0"
assert_contains "$out" "## Resume here" "print: block on stdout"
ofetch
assert_eq "$before" "$(osha)" "print: no commit or push on origin"
assert_eq "$wt_before" "$(wt_count)" "print: no worktree created"
git status --porcelain > "$PARENT/porcelain.after"
assert_eq "$(cat "$PARENT/porcelain.before")" "$(cat "$PARENT/porcelain.after")" "print: the caller's checkout is untouched"
assert_not_contains "$(calls)" "WRITE" "print: the verb stub saw only read verbs"
assert_eq "" "$(awk '{print $1}' "$FX/calls.log" | sort -u | grep -v -x -e list-prs -e list-issues -e pr-head -e check-approval-sha -e pr-checks-required -e pr-is-draft -e list-needs-owner)" "print: only the documented read verbs were called"
assert_eq "0" "$(status_tmp_dirs)" "print: no talos-status temp directory left behind"

# the real gh stub: no POST/PATCH/PUT/DELETE and no label or comment call
export STUB_PR_HEAD_SHA="$(sha40 9)"
export STUB_GH_PRS_RAW='[{"number":9,"title":"fix: guard null session","head":{"ref":"fix/issue-42-guard","repo":{"full_name":"acme/widget"}},"base":{"ref":"main","repo":{"full_name":"acme/widget"}},"labels":[]}]'
: > "$GH_LOG"
out="$(bash "$SF_REAL" refresh --print 2>"$PARENT/err")"; rc=$?
assert_eq "0" "$rc" "gh stub: refresh --print exits 0 against the real pipeline-vcs.sh (stderr: $(head -c 200 "$PARENT/err"))"
assert_contains "$out" "- PR #9 (#42) head $(sha40 9) next: qa" "gh stub: the stubbed PR is rendered with the stubbed 40-char head"
log="$(cat "$GH_LOG")"
assert_not_contains "$log" "POST" "gh stub: no POST"
assert_not_contains "$log" "PATCH" "gh stub: no PATCH"
assert_not_contains "$log" "PUT" "gh stub: no PUT"
assert_not_contains "$log" "DELETE" "gh stub: no DELETE"
assert_not_contains "$log" "--add-label" "gh stub: no label add"
assert_not_contains "$log" "--remove-label" "gh stub: no label remove"
assert_not_contains "$log" "--method" "gh stub: no explicit write method"
assert_eq "" "$(printf '%s\n' "$log" | grep -v -e '^api --paginate repos/[^ ]*$' -e '^api user --jq .login$' -e '^pr view [0-9]* --json headRefOid ' || true)" "gh stub: every call is a read (paginated list, current user, head SHA)"
assert_not_contains "$log" "comment " "gh stub: no comment-writing call"
assert_not_contains "$log" "--edit" "gh stub: no edit call"
unset STUB_PR_HEAD_SHA STUB_GH_PRS_RAW
assert_eq "$before" "$(git rev-parse origin/main)" "gh stub: origin untouched"

# ── push race: refetch, regenerate, retry; at most 3 attempts ───────────────
install_race_hook() {  # $1 = number of pushes to race (racer adds an empty commit)
  local state="$PARENT/hook-state"
  rm_under_parent "$state"; mkdir -p "$state"
  echo 0 > "$state/n"; echo "$1" > "$state/max"
  cat > "$UPSTREAM/hooks/pre-receive" <<EOF
#!/bin/sh
unset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
n=\$(cat "$state/n"); max=\$(cat "$state/max")
if [ "\$n" -lt "\$max" ]; then
  echo \$((n + 1)) > "$state/n"
  parent=\$(git rev-parse refs/heads/main)
  tree=\$(git rev-parse refs/heads/main^{tree})
  c=\$(GIT_AUTHOR_NAME=racer GIT_AUTHOR_EMAIL=r@x GIT_COMMITTER_NAME=racer GIT_COMMITTER_EMAIL=r@x git commit-tree -m "race \$n" -p "\$parent" "\$tree")
  git update-ref refs/heads/main "\$c"
fi
exit 0
EOF
  chmod +x "$UPSTREAM/hooks/pre-receive"
}
# A racer that lands the very tree being pushed: a concurrent refresh that won.
install_twin_hook() {
  local state="$PARENT/hook-state"
  rm_under_parent "$state"; mkdir -p "$state"
  echo 0 > "$state/n"
  cat > "$UPSTREAM/hooks/pre-receive" <<EOF
#!/bin/sh
n=\$(cat "$state/n")
read old new ref
if [ "\$n" -lt 1 ]; then
  echo 1 > "$state/n"
  # The pushed objects sit in the quarantine; copy them into the real object
  # store first, then land a commit with the very same tree on top of \$old.
  git rev-list --objects "\$new" "^\$old" | cut -d' ' -f1 | git pack-objects --stdout -q \
    | ( unset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; git unpack-objects -q )
  unset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
  tree=\$(git rev-parse "\$new^{tree}")
  c=\$(GIT_AUTHOR_NAME=twin GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=twin GIT_COMMITTER_EMAIL=t@x git commit-tree -m "twin refresh" -p "\$old" "\$tree")
  git update-ref refs/heads/main "\$c"
fi
exit 0
EOF
  chmod +x "$UPSTREAM/hooks/pre-receive"
}

reset_fixture; cfg_rf
wk_add src/code.txt "code" 2026-09-10; wk_push
fx_reset; add_pr 10 fix/issue-5-x ""; add_pr 11 feat/issue-6-y "qa:pass"; add_issue 5 ""; add_issue 6 ""; fx_flush
ofetch
install_race_hook 1
wt_before="$(wt_count)"; c0="$(ocount)"
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "race once: exits 0 after a retry"
assert_eq "1" "$(cat "$PARENT/hook-state/n")" "race once: the hook raced exactly one push"
ofetch
assert_eq "2" "$(( $(ocount) - c0 ))" "race once: the racer plus exactly one refresh commit"
assert_contains "$(block_of "$(oshow TALOS_STATUS.md)")" "- PR #11 " "race once: block landed on the new base"
assert_eq "docs(status): refresh resume block [skip ci]" "$(git log -1 --format=%s origin/main)" "race once: commit subject"
assert_eq "$(git log --format=%H -1 origin/main~1 | wc -l | tr -d ' ')" "1" "race once: racer sits under the refresh commit"
assert_eq "$wt_before" "$(wt_count)" "race once: no worktree left behind"

reset_fixture; cfg_rf
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
ofetch
install_race_hook 99
c0="$(ocount)"
out="$(run_sf refresh)"; rc=$?
assert_eq "1" "$rc" "race always: exits 1 after 3 attempts"
assert_eq "3" "$(cat "$PARENT/hook-state/n")" "race always: exactly 3 attempts"
assert_contains "$out" "3 attempts" "race always: says it gave up"
ofetch
assert_not_contains "$(oshow TALOS_STATUS.md)" "- PR #10 " "race always: nothing refreshed on the base"
assert_eq "$wt_before" "$(wt_count)" "race always: no worktree left behind"

# ── two refreshes, same state, same origin ──────────────────────────────────
reset_fixture; cfg_rf
wk_add src/code.txt "code" 2026-09-10; wk_push
fx_reset; add_pr 10 fix/issue-5-x ""; add_pr 11 feat/issue-6-y "qa:pass,docs:done"; add_issue 5 ""; add_issue 6 "pipeline:ready"; fx_flush
rm_under_parent "$PARENT/copy.git"; cp -R "$UPSTREAM" "$PARENT/copy.git"
git remote set-url origin "$PARENT/copy.git"
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "twin: the sequential reference refresh exits 0"
seq_text="$(git --git-dir="$PARENT/copy.git" show main:TALOS_STATUS.md)"
git remote set-url origin "$UPSTREAM"
ofetch; c0="$(ocount)"
install_twin_hook
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "twin: the loser exits 0"
assert_eq "1" "$(cat "$PARENT/hook-state/n")" "twin: the collision was forced exactly once"
ofetch
assert_eq "1" "$(( $(ocount) - c0 ))" "twin: origin gained exactly one commit (the winner's), the loser added none"
assert_eq "$seq_text" "$(oshow TALOS_STATUS.md)" "twin: status file byte-identical to one sequential refresh on a copy of the same origin"
assert_eq "twin refresh" "$(git log -1 --format=%s origin/main)" "twin: the winner's commit is the tip"

# smoke: two real processes at once (bounded; both are waited for)
reset_fixture; cfg_rf
wk_add src/code.txt "code" 2026-09-10; wk_push
fx_reset; add_pr 10 fix/issue-5-x ""; add_pr 11 feat/issue-6-y "qa:pass,docs:done"; add_issue 5 ""; add_issue 6 "pipeline:ready"; fx_flush
ofetch; c0="$(ocount)"
bash "$SF" refresh > "$PARENT/par1.out" 2>&1 &
pid1=$!
bash "$SF" refresh > "$PARENT/par2.out" 2>&1 &
pid2=$!
wait "$pid1"; rc1=$?
wait "$pid2"; rc2=$?
assert_eq "0" "$rc1" "parallel: first process exits 0"
assert_eq "0" "$rc2" "parallel: second process exits 0"
ofetch
gained="$(( $(ocount) - c0 ))"
if [ "$gained" -ge 1 ] && [ "$gained" -le 1 ]; then pass "parallel: origin gained at most one commit"; else fail "parallel: origin gained at most one commit" "gained $gained"; fi
assert_eq "$seq_text" "$(oshow TALOS_STATUS.md)" "parallel: status file byte-identical to the sequential reference"

# ── paths, base branch ──────────────────────────────────────────────────────
reset_fixture; cfg_rf
mkdir -p "$WORK/scripts"; printf '#!/bin/sh\necho deploy\n' > "$WORK/scripts/deploy.sh"
git -C "$WORK" add scripts/deploy.sh; git -C "$WORK" commit -q -m "deploy"
ln -s scripts/deploy.sh "$WORK/TALOS_STATUS.md"; git -C "$WORK" add TALOS_STATUS.md; git -C "$WORK" commit -q -m "symlink"
wk_push; ofetch
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
before="$(osha)"
out="$(run_sf refresh)"; rc=$?
assert_eq "1" "$rc" "symlink: a symlinked status.file exits 1"
assert_contains "$out" "status.file" "symlink: names the key"
ofetch
assert_eq "$before" "$(osha)" "symlink: nothing pushed"
assert_contains "$(git show origin/main:scripts/deploy.sh)" "echo deploy" "symlink: deploy.sh untouched"
ln -s README.md TALOS_STATUS.md
out="$(run_sf refresh --print)"; rc=$?
rm -f TALOS_STATUS.md
assert_eq "1" "$rc" "symlink: refresh --print refuses a symlinked status.file in the checkout too"
assert_contains "$out" "status.file" "symlink: refresh --print names the key"
reset_fixture
cfg_rf; printf '{"base_branch": "ma in", "status": {"enabled": true}}\n' > talos.pipeline.json
out="$(run_sf refresh)"; rc=$?
assert_eq "1" "$rc" "base branch: an invalid name exits 1"
printf '{"base_branch": "--upload-pack=x", "status": {"enabled": true}}\n' > talos.pipeline.json
out="$(run_sf refresh --print)"; rc=$?
assert_eq "1" "$rc" "base branch: an option-looking name exits 1 for --print too"
cfg_rf '' '"file": "../x.md"'
out="$(run_sf refresh --print)"; rc=$?
assert_eq "1" "$rc" "paths: a '..' status.file exits 1 for refresh --print"

# ── assemble --refresh: one commit holding the log change and the block ─────
reset_fixture; cfg_rf
wk_add src/code.txt "code" 2026-09-10
wk_add docs/status.d/12-40.md "fragment text" 2026-09-10; wk_push; ofetch
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
c0="$(ocount)"
out="$(run_sf assemble --refresh)"; rc=$?
assert_eq "0" "$rc" "assemble --refresh: exits 0"
ofetch
assert_eq "1" "$(( $(ocount) - c0 ))" "assemble --refresh: exactly one commit"
st="$(oshow TALOS_STATUS.md)"
assert_contains "$st" "PR #40 (#12): fragment text" "assemble --refresh: the log entry is in the commit"
assert_contains "$(block_of "$st")" "- PR #10 (#5) head $(sha40 10) next: qa" "assemble --refresh: the block is in the same commit"
assert_eq "" "$(git ls-tree --name-only origin/main docs/status.d/ 2>/dev/null)" "assemble --refresh: the fragment was consumed"
assert_eq "TALOS_STATUS.md docs/status.d/12-40.md " "$(git diff --name-only origin/main~1 origin/main | LC_ALL=C sort | tr '\n' ' ')" "assemble --refresh: the commit holds only the status file and the fragment"
# no fragments, but the block is stale: still a commit
fx_reset; add_pr 10 fix/issue-5-x ""; add_pr 11 fix/issue-6-x ""; add_issue 5 ""; add_issue 6 ""; fx_flush
c0="$(ocount)"
out="$(run_sf assemble --refresh)"; rc=$?
assert_eq "0" "$rc" "assemble --refresh: no fragments, stale block: exits 0"
ofetch
assert_eq "1" "$(( $(ocount) - c0 ))" "assemble --refresh: no fragments, stale block: one commit"
assert_contains "$(block_of "$(oshow TALOS_STATUS.md)")" "- PR #11 " "assemble --refresh: no fragments: block refreshed"
# nothing at all to do
c0="$(ocount)"
out="$(run_sf assemble --refresh)"; rc=$?
assert_eq "0" "$rc" "assemble --refresh: nothing to do exits 0"
ofetch
assert_eq "0" "$(( $(ocount) - c0 ))" "assemble --refresh: nothing to do makes no commit"
# GitHub read fails: the log is still assembled
reset_fixture; cfg_rf
wk_add docs/status.d/13-41.md "second fragment" 2026-09-10; wk_push; ofetch
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush; echo 1 > "$FX/prs.rc"
out="$(bash "$SF" assemble --refresh 2>"$PARENT/err.txt")"; rc=$?
assert_eq "0" "$rc" "assemble --refresh: a failed GitHub read still exits 0"
ofetch
assert_contains "$(oshow TALOS_STATUS.md)" "PR #41 (#13): second fragment" "assemble --refresh: the log is still assembled and pushed"
assert_eq "1" "$(grep -c 'not refreshed' "$PARENT/err.txt")" "assemble --refresh: stderr carries exactly one 'not refreshed' line"
assert_contains "$(grep 'not refreshed' "$PARENT/err.txt")" "Resume block" "assemble --refresh: the line names the Resume block"
assert_not_contains "$(oshow TALOS_STATUS.md)" "- PR #10 " "assemble --refresh: no block was written"
# plain assemble is unchanged: it never reads GitHub
reset_fixture; cfg_rf
wk_add docs/status.d/14-42.md "third" 2026-09-10; wk_push; ofetch
fx_reset; fx_flush
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "plain assemble: exits 0"
assert_eq "" "$(calls)" "plain assemble: makes no GitHub read"
assert_not_contains "$(oshow TALOS_STATUS.md)" "- Base:" "plain assemble: does not write a block"

# ── F1: a pipeline-style branch name alone does not make a pipeline PR ──────
reset_fixture; cfg_rf
fx_reset
add_pr 77 fix/issue-3-evil "" true            # the security repro: unlabelled fork PR
add_issue 3 "pipeline:ready"
fx_flush
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "0" "$(count_of "$out" '^- PR #77')" "fork: an unlabelled cross-repo PR gets no PR line"
assert_eq "- Next: start #3" "$(line_of "$out" '^- Next:')" "fork: Next is unaffected by the fork PR"
assert_eq "- Ignored: 1 open PR(s) with a pipeline-style branch name and no Talos label from a fork" "$(line_of "$out" '^- Ignored:')" "fork: one summary line, a count only"
assert_not_contains "$out" "evil" "fork: no attacker-chosen text in the block"
assert_not_contains "$(calls)" "pr-head 77" "fork: the excluded PR is not looked up (pr-head)"
assert_not_contains "$(calls)" "check-approval-sha 77" "fork: the excluded PR is not looked up (check-approval-sha)"
fx_reset
add_pr 20 fix/issue-3-a "" false              # same repo, no label: a fix round in flight
add_pr 21 fix/issue-4-b "qa:pass" true        # fork PR a maintainer labelled
add_pr 22 fix/issue-5-c "pipeline:review" true
add_pr 23 fix/issue-6-d "" absent             # field absent, no label: excluded
add_pr 24 fix/issue-7-e "docs:done" absent    # field absent, label: listed
add_pr 25 fix/issue-8-f "pipeline:review" false other   # wrong base: excluded
add_pr 26 fix/issue-9-g "" true
add_issue 3 ""; fx_flush
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "20 21 22 24" "$(printf '%s\n' "$out" | sed -n 's/^- PR #\([0-9]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//')" "fork: same-repo unlabelled, labelled fork and field-absent labelled PRs are listed; field-absent unlabelled and wrong-base PRs are not"
assert_eq "- Ignored: 2 open PR(s) with a pipeline-style branch name and no Talos label from a fork" "$(line_of "$out" '^- Ignored:')" "fork: the count covers the unlabelled fork PR and the field-absent unlabelled PR, not the wrong-base one"
assert_not_contains "$(calls)" "pr-head 25" "fork: a wrong-base PR is not looked up"
# a fork PR that carries only an unrelated label is still excluded
fx_reset; add_pr 30 fix/issue-3-x "bug" true; add_issue 3 ""; fx_flush
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "0" "$(count_of "$out" '^- PR #30')" "fork: an unrelated label is not a Talos label"
# no ignored PRs, no Ignored line
fx_reset; add_pr 31 fix/issue-3-x "" false; add_issue 3 ""; fx_flush
assert_eq "0" "$(count_of "$(bash "$SF" refresh --print 2>/dev/null)" '^- Ignored:')" "fork: no Ignored line when nothing was ignored"
# list-prs from the real arm: the new field reaches the block
# (covered by the gh stub test above: same-repo PR is listed)

# ── F2: the status field is fixed and ahead of the untrusted text ───────────
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 "pipeline:blocked"; fx_flush
python3 -I -c '
import json
print(json.dumps([
  {"n": 5, "kind": "issue", "answered": "no", "question": "Ship it? [answered] (answered)"},
  {"n": 6, "kind": "issue", "answered": "no", "question": "(answered)"},
  {"n": 7, "kind": "issue", "answered": "yes", "question": "done [unanswered]"},
]))' > "$FX/owners.json"
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "- Owner: #5 [unanswered] Ship it? \\[answered\\] (answered)" "$(line_of "$out" '^- Owner: #5')" "owner: a question ending in [answered] / (answered) does not change the status field"
assert_eq "- Owner: #6 [unanswered] (answered)" "$(line_of "$out" '^- Owner: #6')" "owner: a question that is just (answered) stays unanswered"
assert_eq "- Owner: #7 [answered] done \\[unanswered\\]" "$(line_of "$out" '^- Owner: #7')" "owner: an answered item's text cannot claim unanswered"
assert_eq "- Blocked: issue #5 [question] Ship it? \\[answered\\] (answered)" "$(line_of "$out" '^- Blocked:')" "blocked: fixed fields first, question last"
printf 'pipeline-vcs: talos:marker-authors-unverified reader=needs-owner\n' > "$FX/owners.err"
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "3" "$(count_of "$out" '^- Owner: #[0-9]* \[unverified\] ')" "owner: unverified trust set marks every item [unverified]"
assert_eq "0" "$(count_of "$out" '^- Owner: #[0-9]* \[answered\]')" "owner: unverified trust set never prints [answered]"
rm -f "$FX/owners.err"

# ── cost: the line cap decides which PRs are looked up ──────────────────────
reset_fixture; cfg_rf
fx_reset; add_issue 5 ""
for i in $(seq 1000 1299); do add_pr "$i" "fix/issue-$i-x" ""; done
fx_flush
out="$(bash "$SF" refresh --print 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "cost: 300 matching PRs: exits 0"
assert_eq "37" "$(grep -c '^pr-head ' "$FX/calls.log")" "cost: 300 matching PRs make only 37 pr-head calls (the 37 PR lines shown)"
assert_eq "40" "$(block_of "$out" | wc -l | tr -d ' ')" "cost: the block is still 40 lines"
assert_eq "- +263 more" "$(block_of "$out" | tail -1)" "cost: the more line counts every omitted PR (2 + 300 - 39)"
assert_eq "1000 1001" "$(printf '%s\n' "$out" | sed -n 's/^- PR #\([0-9]*\) .*/\1/p' | head -2 | tr '\n' ' ' | sed 's/ $//')" "cost: the lowest-numbered PRs are the ones shown"
assert_eq "37" "$(grep -c '^check-approval-sha \|^pr-head ' "$FX/calls.log")" "cost: no other per-PR read for the omitted PRs"

# ── deadline: a verb that outlasts it fails the read phase, no hang ─────────
run_wd() {  # SECONDS cmd...: the command's output and exit code, or 124 after SECONDS
  python3 -I -c '
import subprocess, sys
try:
    p = subprocess.run(sys.argv[2:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=int(sys.argv[1]))
except subprocess.TimeoutExpired:
    sys.stdout.write("WATCHDOG: still running\n")
    sys.exit(124)
sys.stdout.buffer.write(p.stdout)
sys.exit(p.returncode)' "$@"
}
reset_fixture; cfg_rf
wk_add docs/status.d/15-43.md "deadline fragment" 2026-09-10; wk_push; ofetch
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
echo 20 > "$FX/sleep.pr-head"
before="$(osha)"
out="$(TALOS_STATUS_READ_DEADLINE=2 run_wd 40 bash "$SF" refresh)"; rc=$?
assert_eq "1" "$rc" "deadline: refresh exits 1 when a read verb outlasts the deadline (output: $(printf '%s' "$out" | head -c 200))"
assert_contains "$out" "deadline" "deadline: stderr names the deadline"
ofetch
assert_eq "$before" "$(osha)" "deadline: refresh pushed nothing"
assert_eq "0" "$(status_tmp_dirs)" "deadline: no talos-status temp directory left behind"
out="$(TALOS_STATUS_READ_DEADLINE=2 run_wd 40 bash "$SF" assemble --refresh)"; rc=$?
assert_eq "0" "$rc" "deadline: assemble --refresh still exits 0 (output: $(printf '%s' "$out" | head -c 200))"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c 'not refreshed')" "deadline: assemble --refresh says once that the Resume block was not refreshed"
ofetch
assert_contains "$(oshow TALOS_STATUS.md)" "PR #43 (#15): deadline fragment" "deadline: assemble --refresh still assembled and pushed the log"
assert_not_contains "$(oshow TALOS_STATUS.md)" "- PR #10 " "deadline: no block was written"
# a deadline that is not a number falls back to the default and everything works
rm -f "$FX/sleep.pr-head"
out="$(TALOS_STATUS_READ_DEADLINE=abc run_wd 60 bash "$SF" refresh)"; rc=$?
assert_eq "0" "$rc" "deadline: a bad TALOS_STATUS_READ_DEADLINE falls back to the default"

# ── next: human-merge and needs-owner ───────────────────────────────────────
reset_fixture; cfg_rf '"merge": {"auto": false}'
fx_reset; add_pr 12 fix/issue-5-x "$ALL"; add_pr 11 fix/issue-6-x "$ALL"; add_issue 5 ""; add_issue 6 ""; fx_flush
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "- Next: waiting on human merge of #11" "$(line_of "$out" '^- Next:')" "next: only human-merge PRs: waiting on human merge of the lowest"
fx_reset; add_pr 12 fix/issue-5-x "$ALL"; add_issue 5 ""; add_issue 9 "pipeline:ready"; fx_flush
assert_eq "- Next: start #9" "$(line_of "$(bash "$SF" refresh --print 2>/dev/null)" '^- Next:')" "next: a queued issue still comes before waiting on a human merge"
cfg_rf
fx_reset; add_pr 10 fix/issue-5-x "$ALL,pipeline:needs-owner"; add_issue 5 ""; fx_flush
out="$(bash "$SF" refresh --print 2>/dev/null)"
assert_eq "- Next: waiting on owner" "$(line_of "$out" '^- Next:')" "next: a needs-owner PR at merge is not offered as merge"
assert_contains "$out" "- PR #10 (#5) head $(sha40 10) next: merge" "next: the needs-owner PR is still listed at its stage"
fx_reset; add_pr 10 fix/issue-5-x "$ALL"; add_pr 11 fix/issue-6-x ""; add_issue 5 "pipeline:needs-owner"; add_issue 6 ""; fx_flush
assert_eq "- Next: resume #11 at qa" "$(line_of "$(bash "$SF" refresh --print 2>/dev/null)" '^- Next:')" "next: a PR whose issue is needs-owner is skipped for resume too"

# ── a resume heading above the log heading never swallows the log ───────────
reset_fixture; cfg_rf '' '"resume_heading": "# Resume here"'
orig="$(printf '# Resume here\n\nold block\n\n### a sub heading\n\nkeep this\n\n## Log\n\n- 2026-09-01 PR #1 (#1): first\n  continued\n')"
wk_add TALOS_STATUS.md "$orig" 2026-09-01; wk_push; ofetch
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "heading: a level-1 resume heading: refresh exits 0"
ofetch
st="$(oshow TALOS_STATUS.md)"
assert_contains "$st" "- 2026-09-01 PR #1 (#1): first" "heading: the log entry survives"
assert_contains "$st" "## Log" "heading: the log heading survives"
assert_contains "$st" "keep this" "heading: text after the next heading, of any level, is untouched"
assert_not_contains "$st" "old block" "heading: the old block text is replaced"
assert_eq "$(printf '%s\n' "$st" | sed -n '/^### a sub heading/,$p')" "$(printf '%s\n' "$orig" | sed -n '/^### a sub heading/,$p')" "heading: everything from the next heading on is byte-identical"
assert_contains "$st" "- PR #10 (#5) head" "heading: the block was written under the level-1 heading"

# ── the staged set must be the manifest, for the new verbs too ──────────────
reset_fixture; cfg_rf
wk_add docs/status.d/16-44.md "manifest fragment" 2026-09-10; wk_push; ofetch
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
GITDIR="$(git rev-parse --git-common-dir)"
mkdir -p "$GITDIR/hooks"
cat > "$GITDIR/hooks/post-checkout" <<'TALOS_hookQ4v8Zr2LmWx'
#!/bin/sh
# Stage a file the verb never wrote, the moment the throwaway worktree exists.
printf 'injected\n' > injected.txt
git add -f injected.txt
exit 0
TALOS_hookQ4v8Zr2LmWx
chmod +x "$GITDIR/hooks/post-checkout"
before="$(osha)"; wt_before="$(wt_count)"
out="$(run_sf refresh)"; rc=$?
assert_eq "1" "$rc" "manifest: refresh refuses a hook-staged extra file"
assert_contains "$out" "staged changes differ" "manifest: refresh says the staged set differs"
ofetch
assert_eq "$before" "$(osha)" "manifest: refresh pushed nothing"
assert_eq "$wt_before" "$(wt_count)" "manifest: refresh left no worktree"
out="$(run_sf assemble --refresh)"; rc=$?
assert_eq "1" "$rc" "manifest: assemble --refresh refuses a hook-staged extra file"
assert_contains "$out" "staged changes differ" "manifest: assemble --refresh says the staged set differs"
ofetch
assert_eq "$before" "$(osha)" "manifest: assemble --refresh pushed nothing"
assert_contains "$(git ls-tree --name-only origin/main docs/status.d/)" "16-44.md" "manifest: the fragment is still on the base"
rm -f "$GITDIR/hooks/post-checkout"
out="$(run_sf refresh)"; rc=$?
assert_eq "0" "$rc" "manifest: without the hook the same refresh succeeds"
ofetch
assert_eq "TALOS_STATUS.md" "$(git show --name-only --format= origin/main)" "manifest: the commit holds only the status file"

# ── no stage left a temp directory behind ───────────────────────────────────
assert_eq "0" "$(status_tmp_dirs)" "leak: no talos-status.* directory left in the test's TMPDIR after the whole file"

echo "test-status-file-refresh.sh: $_PASS passed, $_FAIL failed"
[ "$_FAIL" -eq 0 ]
