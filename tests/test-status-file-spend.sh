#!/usr/bin/env bash
# test-status-file-spend.sh -- the merged PR's token total in its status-file
# log entry (#384, sub-task 7 of epic #334): `pipeline-status-file.sh assemble`
# reads the figures with `pipeline-events.sh cost --json` (issue scope and
# issue+PR scope) in the caller's checkout, before the temporary worktree
# exists, and writes `- DATE PR #P (#I): [tag] text`.
#
# Contract pinned here:
#   [3.41M tokens]                      PR total, issue total the same
#   [PR 3.41M · issue 3.52M tokens]     issue total differs
#   [..., +K unrecorded]                K unrecorded stage events
#   [tokens unrecorded]                 every stage event unrecorded
#   orchestrator events never count; no log, no events for the pair, junk
#   output, or a missing formatter module leave the entry byte-identical
#   the tag is never cut by the 400-character / 3-line caps
#   a new fragment for the same PR replaces the entry (and retags it); a
#   second `--pr` fallback run is a no-op
#
# Same fixture shape as test-status-file-assemble.sh: a bare `origin` inside
# the sandbox (no network, no push anywhere else), the events log written only
# inside the sandbox repo.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

SF="$TALOS_ROOT/scripts/pipeline-status-file.sh"
export TALOS_STATUS_TODAY="2026-09-20"

git config user.email "test@talos.invalid"
git config user.name "talos-test"
git config commit.gpgsign false

PARENT="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-sf-spend.XXXXXX")" || exit 1
UPSTREAM="${PARENT:?}/upstream.git"
WORK="${PARENT:?}/work"
trap 'rm -rf "$SANDBOX" "$PARENT"' EXIT
mkdir -p "$PARENT/tmp"
export TMPDIR="$PARENT/tmp"

echo "seed" > README.md
printf 'talos.pipeline.json\n.talos/\n' >> .git/info/exclude
git add README.md
git commit -q -m "seed"
git branch -M main

printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main", "status": {"enabled": true}}\n' \
  > talos.pipeline.json

LOG="$SANDBOX/.talos/events.jsonl"
mkdir -p "$SANDBOX/.talos"

reset_fixture() {  # fresh bare origin with the seed commit, fresh WORK clone, empty events log
  rm -rf "$UPSTREAM" "$WORK"
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
  : > "$LOG"
}

wk_sync() { git -C "$WORK" fetch -q origin main && git -C "$WORK" checkout -q -B main origin/main; }
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
entry() { oshow TALOS_STATUS.md | grep "^- .* PR #$1 "; }  # the whole entry line(s) for PR $1
run_sf() { bash "$SF" "$@" 2>&1; }
status_tmp_dirs() { ls -d "$PARENT"/tmp/talos-status.* 2>/dev/null | wc -l | tr -d ' '; }

# ev ROLE ISSUE PR TOKENS -- append one event (null for a null field).
ev() {
  printf '{"event":"%s","role":"%s","issue":%s,"pr":%s,"verdict":"PASS","tokens":%s,"tool_uses":1,"duration_s":1,"ts":"2026-10-03T00:00:00Z"}\n' \
    "$1" "$1" "$2" "$3" "$4" >> "$LOG"
}

# frag_run ISSUE PR TEXT -- publish a fragment on origin and assemble it.
frag_run() {
  wk_sync
  wk_add "docs/status.d/$1-$2.md" "$3" 2026-09-18
  wk_push
  run_sf assemble >/dev/null
  ofetch
}

# ── fragment entry: PR total equals the issue total ─────────────────────────
reset_fixture
ev developer 20 60 1000000
ev qa        20 60 2411000
ev orchestrator 20 60 999999   # excluded
ev orchestrator 20 null null
frag_run 20 60 "added the thing"
assert_eq "- 2026-09-18 PR #60 (#20): [3.41M tokens] added the thing" "$(entry 60)" "fragment: [3.41M tokens] sits before the text"

# ── issue total differs (a developer run before the PR existed) ─────────────
reset_fixture
ev developer 20 60 1000000
ev qa        20 60 2411000
ev developer 20 null 110000
frag_run 20 60 "added the thing"
assert_eq "- 2026-09-18 PR #60 (#20): [PR 3.41M · issue 3.52M tokens] added the thing" "$(entry 60)" "differs: PR and issue totals both shown"

# ── only the (issue, PR) pair's events count; other issues are ignored ──────
reset_fixture
ev developer 20 60 1500
ev developer 21 61 9000000
frag_run 20 60 "scoped"
assert_eq "- 2026-09-18 PR #60 (#20): [2k tokens] scoped" "$(entry 60)" "scope: another issue's events do not count (1500 -> 2k)"

# ── unrecorded events ───────────────────────────────────────────────────────
reset_fixture
ev developer 20 60 1000000
ev qa        20 60 null
ev docs      20 60 null
frag_run 20 60 "partial"
assert_eq "- 2026-09-18 PR #60 (#20): [1.00M tokens, +2 unrecorded] partial" "$(entry 60)" "unrecorded: K is appended to the tag"

reset_fixture
ev developer 20 60 1000000
ev qa        20 60 null
ev developer 20 null 500000
frag_run 20 60 "partial two"
assert_eq "- 2026-09-18 PR #60 (#20): [PR 1.00M · issue 1.50M tokens, +1 unrecorded] partial two" "$(entry 60)" "unrecorded: differing totals and K together"

reset_fixture
ev developer 20 60 null
ev qa        20 60 "\"junk\""
ev orchestrator 20 60 5000
frag_run 20 60 "none recorded"
assert_eq "- 2026-09-18 PR #60 (#20): [tokens unrecorded] none recorded" "$(entry 60)" "unrecorded: every stage event unrecorded (a junk string counts)"

# ── --pr fallback entry ─────────────────────────────────────────────────────
reset_fixture
wk_sync; wk_add README.md "touch" 2026-09-01; wk_push
export STUB_PR_TITLE="fix: guard null session"
ev developer 20 50 3000000
ev developer 20 null 100000
out="$(run_sf assemble --pr 50 --issue 20)"; rc=$?
ofetch
assert_eq "0" "$rc" "fallback: exits 0"
assert_eq "- 2026-09-20 PR #50 (#20): [PR 3.00M · issue 3.10M tokens] fix: guard null session" "$(entry 50)" "fallback: the title entry carries the tag"
before="$(git rev-parse origin/main)"
ev qa 20 50 7000000
run_sf assemble --pr 50 --issue 20 >/dev/null
ofetch
assert_eq "$before" "$(git rev-parse origin/main)" "fallback: a second --pr run is a no-op"
assert_contains "$(entry 50)" "[PR 3.00M · issue 3.10M tokens]" "fallback: the first tag is left as it was"
unset STUB_PR_TITLE

# ── a fresh fragment for the same PR replaces the entry and retags it ───────
reset_fixture
ev developer 20 60 1000000
frag_run 20 60 "first version"
assert_eq "- 2026-09-18 PR #60 (#20): [1.00M tokens] first version" "$(entry 60)" "replace: the first entry is tagged"
ev qa 20 60 2000000
frag_run 20 60 "second version"
assert_eq "1" "$(oshow TALOS_STATUS.md | grep -c 'PR #60 ')" "replace: still exactly one entry"
assert_eq "- 2026-09-18 PR #60 (#20): [3.00M tokens] second version" "$(entry 60)" "replace: the new fragment gives the new text and the recomputed tag"

# ── nothing to say: the entry is byte-identical to the untagged form ────────
reset_fixture
rm -f "$LOG"
frag_run 20 60 "no log at all"
assert_eq "- 2026-09-18 PR #60 (#20): no log at all" "$(entry 60)" "none: no events log leaves the entry untagged"

reset_fixture
ev developer 21 61 5000      # other pair
ev developer 20 null 5000    # same issue, no PR
frag_run 20 60 "no events for the pair"
assert_eq "- 2026-09-18 PR #60 (#20): no events for the pair" "$(entry 60)" "none: no events for the pair leaves the entry untagged"

reset_fixture
ev orchestrator 20 60 5000
ev orchestrator 20 60 null
frag_run 20 60 "orchestrator only"
assert_eq "- 2026-09-18 PR #60 (#20): orchestrator only" "$(entry 60)" "none: orchestrator-only events leave the entry untagged"

reset_fixture
ev developer 20 60 1000
printf 'this is not json\n' >> "$LOG"
printf '{"event":"qa","role":"qa","issue":20,"pr":60,"tokens":"junk"}\n' >> "$LOG"
frag_run 20 60 "junk lines"
assert_eq "- 2026-09-18 PR #60 (#20): [1k tokens, +1 unrecorded] junk lines" "$(entry 60)" "junk: a bad line is skipped and a bad token count is unrecorded"

# a failing events tool means no figures, not a failed assemble
reset_fixture
ev developer 20 60 1000
SHIMS="$PARENT/failshim"
mkdir -p "$SHIMS"
cp -R "$TALOS_ROOT/scripts/." "$SHIMS/"
printf '#!/usr/bin/env bash\nexit 3\n' > "$SHIMS/pipeline-events.sh"
wk_sync; wk_add docs/status.d/20-60.md "events tool failed" 2026-09-18; wk_push
out="$(bash "$SHIMS/pipeline-status-file.sh" assemble 2>&1)"; rc=$?
ofetch
assert_eq "0" "$rc" "failing tool: assemble still exits 0"
assert_eq "- 2026-09-18 PR #60 (#20): events tool failed" "$(entry 60)" "failing tool: entry untagged"

# ── a missing formatter module: one stderr note, untagged, same exit code ──
reset_fixture
ev developer 20 60 1000
rm -f "$SHIMS/pipeline-spend-format.py"
cp "$TALOS_ROOT/scripts/pipeline-events.sh" "$SHIMS/pipeline-events.sh"
wk_sync; wk_add docs/status.d/20-60.md "module missing" 2026-09-18; wk_push
out="$(bash "$SHIMS/pipeline-status-file.sh" assemble 2>&1)"; rc=$?
ofetch
assert_eq "0" "$rc" "module missing: assemble still exits 0"
assert_eq "- 2026-09-18 PR #60 (#20): module missing" "$(entry 60)" "module missing: entry untagged"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c 'pipeline-spend-format.py unavailable')" "module missing: exactly one stderr note"

# ── a module planted in the caller's cwd is never imported ──────────────────
reset_fixture
ev developer 20 60 1000
printf 'raise SystemExit("planted module ran")\n' > "$SANDBOX/pipeline-spend-format.py"
wk_sync; wk_add docs/status.d/20-60.md "planted" 2026-09-18; wk_push
out="$(run_sf assemble)"; rc=$?
ofetch
rm -f "$SANDBOX/pipeline-spend-format.py"
assert_eq "0" "$rc" "planted: assemble exits 0"
assert_not_contains "$out" "planted module ran" "planted: the cwd module is never imported"
assert_eq "- 2026-09-18 PR #60 (#20): [1k tokens] planted" "$(entry 60)" "planted: the real module formats the tag"

# ── the tag is never truncated by the caps ──────────────────────────────────
reset_fixture
ev developer 20 60 1000000
ev qa        20 60 2411000
ev developer 20 null 110000
ev qa        20 60 null
TAG="[PR 3.41M · issue 3.52M tokens, +1 unrecorded]"
LONG="$(python3 -I -c 'print("x" * 400)')"
frag_run 20 60 "$LONG"
e="$(entry 60)"
assert_contains "$e" "(#20): $TAG x" "cap: a 400-character fragment keeps the whole tag"
assert_eq "400" "$(printf '%s' "$e" | python3 -I -c 'import sys; print(len(sys.stdin.read()))')" "cap: the entry is cut to exactly 400 characters"
assert_eq "…" "$(printf '%s' "$e" | python3 -I -c 'import sys; print(sys.stdin.read()[-1])')" "cap: only the text is cut, and ends with the ellipsis"

reset_fixture
ev developer 20 60 1000000
frag_run 20 60 "$(printf 'line one\nline two\nline three\nline four\nline five')"
e="$(oshow TALOS_STATUS.md | sed -n '/^- .* PR #60 /,/^$/p')"
assert_contains "$e" "(#20): [1.00M tokens] line one" "cap: the tag leads line one of a multi-line fragment"
assert_not_contains "$e" "line four" "cap: the 3-line cap still applies to the text"

assert_eq "0" "$(status_tmp_dirs)" "leak: no talos-status.* directory left in the test's TMPDIR"

finish
