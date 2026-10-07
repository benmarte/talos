#!/usr/bin/env bash
# test-runstate-not-committable.sh -- #517: Talos run state (events log +
# stage handoff) lives at <git common dir>/talos, OUTSIDE every git tree, the
# deliberately in-tree .talos/ files self-ignore via info/exclude, and no
# consumer-repo agent's `git add -A` can ever commit run state (dogfood
# finding #4: a developer stage committed .talos/events.jsonl and
# .talos/handoff/1.json onto its PR branch).
#
# One criterion per test; every assertion label starts with its AC id
# (AC1..AC5, AC7 -- pipeline-criteria.sh maps them back to the spec).
# Fixtures are fresh sandbox repos with NO .gitignore and no .talos rules in
# .git/info/exclude -- exactly the consumer-repo situation the dogfood run
# failed in. No stub runner is needed: only the writes and the ignore/exclude
# guards are exercised (checkpoint runs with --local, never a push).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
WTS="$TALOS_ROOT/scripts/pipeline-worktree.sh"
PATHS="$TALOS_ROOT/scripts/pipeline-paths.sh"
STATUS="$TALOS_ROOT/scripts/talos-status.sh"

# mode <path>: octal permission bits.
mode() { python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
# _realpath PATH -- canonicalize (macOS $TMPDIR is a symlink; git resolves
# its own output, tests must compare the resolved forms).
_realpath() { python3 -I -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$1"; }

# mk_repo <name> -- a fixture repo with NO .gitignore and a pristine
# info/exclude: init on main with one commit. Prints the path.
mk_repo() {
  local d
  d="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-runstate-$1.XXXXXX")" || exit 1
  git init -q "$d" || { echo "mk_repo: git init failed in $d" >&2; exit 1; }
  git -C "$d" config user.email "test@talos.invalid"
  git -C "$d" config user.name "talos test"
  git -C "$d" symbolic-ref HEAD refs/heads/main
  printf 'base\n' > "$d/base.txt"
  git -C "$d" add base.txt
  git -C "$d" commit -q -m root || { echo "mk_repo: root commit failed in $d" >&2; exit 1; }
  printf '%s' "$d"
}

# mk_wt <repo> <n> <slug> -- a linked worktree checked out on
# fix/issue-<n>-<slug>, placed OUTSIDE every worktree checkout (a plain
# `git worktree add`, NOT pipeline-worktree.sh create -- the .talos/env write
# is AC4's subject; the AC1/AC2/AC7 fixtures must contain no .talos path at
# all). Prints the path.
mk_wt() {
  local repo="$1" n="$2" slug="$3" wt
  wt="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-runstate-wt$n.XXXXXX")" || exit 1
  rmdir "$wt" || { echo "mk_wt: rmdir failed for $wt" >&2; exit 1; }
  git -C "$repo" worktree add -q -b "fix/issue-$n-$slug" "$wt" main \
    || { echo "mk_wt: git worktree add failed for $wt" >&2; exit 1; }
  printf '%s' "$wt"
}

# ck_in <worktree> <n> -- checkpoint <n> --local with a valid handoff stdin.
ck_in() {
  printf '%s' '{"stage":"developer step 1","criteria_done":[1],"criteria_remaining":[2],"last_verify":{"cmd":"true","rc":0,"failing":[]},"decisions":["run state lives outside the git tree"],"next_step":"finish ACs"}' \
    | (cd "$1" && bash "$WTS" checkpoint "$2" --local)
}

# ── AC1: events + handoff are outside every git tree and uncommittable ───────
R="$(mk_repo ac1)"
# post_stage runs INSIDE the fixture repo (its cwd resolves the log path)
( cd "$R" && bash "$HOOKS" post_stage verdict developer 1 --verdict approved --summary s 2>"$SANDBOX/ac1-err.log" </dev/null )
assert_eq "0" "$?" "AC1: post_stage exits 0 in a repo with no .gitignore"
W="$(mk_wt "$R" 1 run)"
printf 'work\n' > "$W/feature.txt"
ck_out="$(cd "$W" && ck_in "$W" 1 2>"$SANDBOX/ac1-ck-err.log")"; ck_rc=$?
assert_eq "0" "$ck_rc" "AC1: checkpoint --local exits 0 (stderr: $ck_out)"
assert_file_exists "$R/.git/talos/events.jsonl" "AC1: the events log landed under <git-common-dir>/talos"
assert_file_exists "$R/.git/talos/handoff/1.json" "AC1: the handoff landed under <git-common-dir>/talos/handoff"
assert_eq "700" "$(mode "$R/.git/talos")" "AC1: the run-state directory is 0700"
assert_eq "700" "$(mode "$R/.git/talos/handoff")" "AC1: the handoff directory is 0700"
assert_eq "600" "$(mode "$R/.git/talos/handoff/1.json")" "AC1: the handoff file is 0600"
assert_eq "" "$(find "$R" "$W" -name .talos 2>/dev/null)" "AC1: no path named .talos exists anywhere under the checked-out trees"
assert_eq "" "$(git -C "$W" status --porcelain)" "AC1: git status --porcelain is empty in the issue worktree after every run-state write"
assert_eq "" "$(git -C "$R" status --porcelain)" "AC1: the main checkout's git status --porcelain is empty too"
HEAD1="$(git -C "$W" rev-parse HEAD)"
(cd "$W" && git add -A && git commit -m x) >/dev/null 2>&1; rc=$?
assert_eq "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)" "AC1: git add -A && git commit exits non-zero -- there is nothing of Talos's left in the tree to commit"
assert_eq "$HEAD1" "$(git -C "$W" rev-parse HEAD)" "AC1: HEAD is unchanged after the refused commit"
rm -rf "$R" "$W"

# ── AC2: one canonical resolver, every consumer agrees ───────────────────────
assert_contains "$(cat "$PATHS")" "_talos_state_dir()" "AC2: scripts/pipeline-paths.sh defines the canonical _talos_state_dir"
for f in pipeline-hooks.sh pipeline-events.sh pipeline-worktree.sh; do
  assert_contains "$(cat "$TALOS_ROOT/scripts/$f")" "_talos_state_dir" "AC2: $f resolves the run state through _talos_state_dir"
done
assert_contains "$(sed -n '/def events_log_path/,/return path/p' "$STATUS")" "root = common_dir" "AC2: talos-status.sh roots the events log on the git common dir, not its parent"
NOT_A_REPO="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-runstate-notrepo.XXXXXX")" || exit 1
bash -c 'cd "$1" && . "$2" && _talos_state_dir >/dev/null 2>&1' _ "$NOT_A_REPO" "$PATHS"; rc=$?
assert_eq "1" "$rc" "AC2: _talos_state_dir exits 1 outside a git repository"
assert_file_absent "$NOT_A_REPO/talos" "AC2: _talos_state_dir creates nothing outside a repository"
R2="$(mk_repo ac2)"
( cd "$R2" && bash "$HOOKS" post_stage qa qa 42 --verdict PASS --summary "AC2 shared log" >/dev/null 2>&1 )
W2="$(mk_wt "$R2" 1 run)"
ck_in "$W2" 1 >/dev/null 2>&1
assert_contains "$(cd "$W2" && bash "$EVENTS" list --issue 42)" "AC2 shared log" "AC2: pipeline-events.sh list reads back the event appended under the common dir"
assert_contains "$(cd "$W2" && bash "$EVENTS" tail --issue 42)" "AC2 shared log" "AC2: tail from a linked worktree shows the same appended event"
assert_eq "$(_realpath "$R2/.git/talos/events.jsonl")" "$(_realpath "$(cd "$W2" && bash "$EVENTS" path)")" "AC2: the reader resolves the same single path from a linked worktree"
_hf="$(cd "$W2" && bash "$WTS" handoff 1 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC2: pipeline-worktree.sh handoff prints the validated JSON written under the common dir"
assert_contains "$_hf" '"criteria_remaining":[2]' "AC2: the handoff output is the checkpoint's validated JSON"
( cd "$R2" && printf '%s\n' '{"event":"qa","role":"qa","issue":42,"pr":null,"verdict":"PASS","tokens":1000,"tool_uses":1,"duration_s":10,"ts":"2026-10-06T00:00:00Z"}' >> "$R2/.git/talos/events.jsonl" )
_st="$(cd "$R2" && bash "$STATUS" --line 2>/dev/null)"
assert_contains "$_st" "#42" "AC2: talos-status.sh renders the same common-dir log (issue 42)"
rm -rf "$R2" "$W2" "$NOT_A_REPO"

# ── AC3: config default follows the new location ────────────────────────────
assert_contains "$(cat "$TALOS_ROOT/scripts/pipeline-defaults.sh")" "$(printf 'events.path\tpath\ttalos/events.jsonl\t-\t-\tany')" "AC3: the defaults table states events.path talos/events.jsonl"
assert_contains "$(cat "$TALOS_ROOT/tests/fixtures/config-golden-defaults.tsv")" "$(printf 'events.path\ttalos/events.jsonl\ttable')" "AC3: the golden-defaults fixture follows the new default"
R3="$(mk_repo ac3)"
( cd "$R3" && bash "$HOOKS" post_stage qa qa 517 --verdict PASS --summary "AC3 default root" >/dev/null 2>&1 )
assert_file_exists "$R3/.git/talos/events.jsonl" "AC3: with no config the log lands at <git common dir>/talos/events.jsonl"
assert_contains "$(cd "$R3" && bash "$EVENTS" list --issue 517)" "AC3 default root" "AC3: pipeline-events.sh list reads the default at the new location"
# a relative events.path resolves against the GIT COMMON DIR (was: repo root)
cat > "$R3/talos.pipeline.json" <<'EOF'
{"events": {"path": "custom/events.jsonl"}}
EOF
( cd "$R3" && bash "$HOOKS" post_stage qa qa 518 --verdict PASS --summary "AC3 relative root" >/dev/null 2>&1 )
assert_file_exists "$R3/.git/custom/events.jsonl" "AC3: a relative events.path resolves against the git common dir"
assert_file_absent "$R3/custom/events.jsonl" "AC3: a relative events.path no longer lands in the tree"
# an absolute events.path is unchanged (hooks writes it as-is; status refuses it)
ABS="$SANDBOX/ac3-abs-events.jsonl"
printf '%s\n' "{\"events\": {\"path\": \"$ABS\"}}" > "$R3/talos.pipeline.json"
( cd "$R3" && bash "$HOOKS" post_stage qa qa 519 --verdict PASS --summary "AC3 absolute" >/dev/null 2>&1 )
assert_file_exists "$ABS" "AC3: an absolute events.path is used as-is"
out="$(cd "$R3" && TALOS_STATUS_DEBUG=1 bash "$STATUS" --line 2>"$SANDBOX/ac3-dbg.log" </dev/null)"
assert_eq "" "$out" "AC3: talos-status.sh still refuses an absolute events.path"
assert_contains "$(cat "$SANDBOX/ac3-dbg.log")" "relative to the git common dir" "AC3: the refusal names the git common dir as the required root"
# a `..` that leaves the common dir is refused by the status line
printf '%s\n' '{"events": {"path": "../escape.jsonl"}}' > "$R3/talos.pipeline.json"
out="$(cd "$R3" && TALOS_STATUS_DEBUG=1 bash "$STATUS" --line 2>"$SANDBOX/ac3-dbg2.log" </dev/null)"
assert_eq "" "$out" "AC3: talos-status.sh refuses an events.path that leaves the common dir"
assert_contains "$(cat "$SANDBOX/ac3-dbg2.log")" "leaves the git common dir" "AC3: the containment refusal names the git common dir"
# ...and the WRITER refuses it too (fix round, 2026-10-07 review: the
# fail-open relative join in _events_log_path let "../escaped-events.jsonl"
# land as <repo-root>/escaped-events.jsonl -- untracked and NOT git-ignored,
# so an agent's git add -A could have committed it. The writer mirrors the
# status line's containment: one stderr note, a skipped append, exit 0 --
# the existing never-block contract).
printf '%s\n' '{"events": {"path": "../escaped-events.jsonl"}}' > "$R3/talos.pipeline.json"
( cd "$R3" && bash "$HOOKS" post_stage qa qa 520 --verdict PASS --summary "AC3 writer refuses dotdot" 2>"$SANDBOX/ac3-writer-dbg.log" </dev/null ); rc=$?
assert_eq "0" "$rc" "AC3: post_stage exits 0 when a relative events.path leaves the common dir (never-block contract)"
assert_contains "$(cat "$SANDBOX/ac3-writer-dbg.log")" "leaves the git common dir" "AC3: the writer's skip note names the git common dir"
assert_eq "1" "$(grep -c "leaves the git common dir" "$SANDBOX/ac3-writer-dbg.log")" "AC3: the writer's refusal is exactly ONE stderr note"
assert_file_absent "$R3/escaped-events.jsonl" "AC3: the writer never creates the escaping file outside the common dir"
assert_eq "" "$(git -C "$R3" status --porcelain -- ':!talos.pipeline.json')" "AC3: the skipped append leaves nothing committable in the tree"
rm -rf "$R3" "$ABS"

# ── AC4: in-tree .talos/ self-ignores via info/exclude, never .gitignore ────
R4="$(mk_repo ac4)"
EXCL="$R4/.git/info/exclude"
[ -e "$EXCL" ] || { echo "AC4 setup: fixture repo has no info/exclude" >&2; exit 1; }
LINES_BEFORE="$(wc -l < "$EXCL" | tr -d ' ')"
# `create` writes the per-worktree .talos/env -- the exclude rule must be in
# place before the first write.
W4="$(cd "$R4" && bash "$WTS" create 12 "fix/issue-12-demo" 2>/dev/null)"
assert_eq "1" "$([ -f "$W4/.talos/env" ] && echo 1 || echo 0)" "AC4 setup: create wrote the in-tree .talos/env"
assert_eq "0" "$(git -C "$W4" check-ignore -q .talos/env; echo $?)" "AC4: after create, git check-ignore passes on the written .talos/env"
assert_eq "$((LINES_BEFORE + 1))" "$(wc -l < "$EXCL" | tr -d ' ')" "AC4: the info/exclude diff is exactly one added line"
assert_eq "1" "$(grep -cxF '.talos/' "$EXCL")" "AC4: that one line is .talos/ and it was appended exactly once"
# second call (tag) -- idempotent: a second invocation adds nothing
(cd "$W4" && bash "$WTS" tag 12 >/dev/null 2>&1)
assert_eq "1" "$(grep -cxF '.talos/' "$EXCL")" "AC4: a second run-state write leaves exactly one .talos/ line in info/exclude (idempotent)"
assert_eq "" "$(git ls-files -- .gitignore)" "AC4: the repo still tracks no .gitignore -- the guard never creates one"
assert_eq "" "$(git -C "$W4" status --porcelain)" "AC4: after tag, the worktree's git status --porcelain is empty"
# evidence: capture is where evidence.command first writes under evidence.dir
R4B="$(mk_repo ac4evidence)"
cat > "$R4B/talos.pipeline.json" <<'EOF'
{"evidence": {"enabled": true, "command": "mkdir -p .talos/evidence && printf png > .talos/evidence/shot.png"}}
EOF
( cd "$R4B" && bash "$TALOS_ROOT/scripts/pipeline-evidence.sh" capture >/dev/null 2>&1 ); rc=$?
assert_eq "0" "$rc" "AC4 setup: evidence capture ran the command"
assert_eq "0" "$(git -C "$R4B" check-ignore -q .talos/evidence/shot.png; echo $?)" "AC4: the evidence dir's first write is self-ignored via info/exclude"
assert_eq "1" "$(grep -cxF '.talos/' "$R4B/.git/info/exclude")" "AC4: the evidence path appended exactly one exclude line"
assert_eq "" "$(cd "$R4B" && git status --porcelain -- ':!talos.pipeline.json')" "AC4: with only in-tree .talos/ evidence written, git status --porcelain is empty"
# _talos_ignore_in_tree is the ONE helper: every in-tree-writing consumer
# calls it (the providers.json mkdir in pipeline-agent.sh, the worktree
# env writes, the evidence dir, and the first stage dispatch of talos.sh run)
for f in pipeline-worktree.sh pipeline-agent.sh pipeline-evidence.sh talos.sh; do
  assert_contains "$(cat "$TALOS_ROOT/scripts/$f")" "_talos_ignore_in_tree" "AC4: $f routes its in-tree .talos/ writes through the shared helper"
done
rm -rf "$R4" "$W4" "$R4B"

# ── AC5: tracked .talos/ content warns once and is never touched ────────────
R5="$(mk_repo ac5)"
mkdir -p "$R5/.talos"
printf 'committed run state\n' > "$R5/.talos/tracked.json"
git -C "$R5" add .talos/tracked.json
git -C "$R5" commit -q -m "chore: record attempt 3 handoff and events"
W5="$(mk_wt "$R5" 1 run)"
OUT5="$(cd "$W5" && bash "$WTS" tag 1 2>"$SANDBOX/ac5-err.log")"; rc5=$?
assert_eq "0" "$rc5" "AC5: the warning never changes the command's exit code (tag exits 0)"
warns="$(grep -c "tracked .talos" "$SANDBOX/ac5-err.log")"
assert_eq "1" "$warns" "AC5: the helper warns at most once per invocation about the tracked .talos/ content"
assert_contains "$(git -C "$R5" ls-files -- .talos)" ".talos/tracked.json" "AC5: the tracked .talos/ file stays tracked after the guard runs"
assert_eq "" "$(git -C "$R5" status --porcelain)" "AC5: nothing was unstaged or rewritten in the main checkout"
assert_eq "" "$(git -C "$W5" status --porcelain)" "AC5: the worktree holds its own .talos/env (excluded) plus the untouched tracked .talos/ file"
# and a run-state write in a repo with tracked .talos/ still goes out of tree
ck_in "$W5" 1 >/dev/null 2>&1
assert_file_exists "$R5/.git/talos/handoff/1.json" "AC5: with tracked .talos/ content present, the handoff still lands outside the tree"
rm -rf "$R5" "$W5"

# ── AC7: no legacy shim -- old-location state is never read ─────────────────
R7="$(mk_repo ac7)"
mkdir -p "$R7/.talos/handoff"
printf '%s\n' '{"v":1,"issue":7,"stage":"legacy","next_step":"LEGACY MARKER"}' > "$R7/.talos/handoff/7.json"
H7="$(cd "$R7" && bash "$WTS" handoff 7 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC7: handoff exits 1 with the legacy in-tree file present"
assert_eq "1" "$(printf '%s\n' "$H7" | grep -c .)" "AC7: the absent case stays a one-line message"
assert_contains "$H7" "no handoff for #7" "AC7: the legacy .talos/handoff/7.json is not read -- the message is the plain absent one"
printf '%s\n' '{"event":"qa","role":"qa","issue":7,"pr":null,"verdict":"PASS","summary":"LEGACY MARKER","ts":"2026-10-06T00:00:00Z"}' > "$R7/.talos/events.jsonl"
assert_eq "" "$(cd "$R7" && bash "$EVENTS" list --issue 7)" "AC7: the reader never falls back to the old in-tree events log"
assert_not_contains "$(cat "$TALOS_ROOT/scripts/pipeline-paths.sh")" "migration" "AC7: the resolver ships no migration or cleanup of the old location"
assert_contains "$(cat "$TALOS_ROOT/scripts/pipeline-worktree.sh")" "_wt_unstage_forbidden" "AC7: the checkpoint-stage unstage guard is kept"
# the guard still does its job: checkpoint's own commit never contains
# .talos/ content an agent left in the worktree (defense-in-depth, unchanged)
W7="$(mk_wt "$R7" 1 run)"
mkdir -p "$W7/.talos" && printf 'x\n' > "$W7/.talos/scratch"
printf 'w\n' > "$W7/work.txt"
ck_in "$W7" 1 >/dev/null 2>&1
assert_not_contains "$(git -C "$W7" show --name-only --format= HEAD)" ".talos" "AC7: checkpoint's own commit still never contains .talos/ content"
rm -rf "$R7" "$W7"

finish
