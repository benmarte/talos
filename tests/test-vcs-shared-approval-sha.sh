#!/usr/bin/env bash
# test-vcs-shared-approval-sha.sh — direct unit tests for the approval-SHA
# waiver-rule helper shared by _github and _github_api (#177 slice 2):
#   _vcs_shared_check_approval_sha.
#
# These drive the shared function directly (not through either adapter's CLI
# verb) so a regression in the waiver logic itself is caught here even if
# both adapters happened to still agree by coincidence. Every test can fail:
# disabling/breaking the shared helper causes RED.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cfg() { bash "$TALOS_ROOT/scripts/pipeline-config.sh" "$@"; }
_TALOS_CFG=""

# ── Load ONLY the shared-helper function definitions ──────────────────────────
# Never `source`/`.` the whole script: it has top-level arg-parsing/dispatch
# that ends in `exit`, which would terminate this test process. Extract the
# byte range from `_vcs_shared_read_attempt() {` up to (not including) the
# `_github() {` adapter that follows it -- pure function definitions, safe to
# eval into this shell. (Same anchors as test-vcs-shared-markers.sh; picks up
# every shared helper defined so far, including _vcs_shared_check_approval_sha.)
_shared_src="$(awk '/^_github\(\) \{/{exit} /^_vcs_shared_read_attempt\(\) \{/{flag=1} flag{print}' "$VCS")"
if [ -z "$_shared_src" ]; then
  fail "setup: extracted shared-helper source is non-empty" "extraction produced nothing -- check the awk anchors against pipeline-vcs.sh"
fi
eval "$_shared_src"
if ! declare -F _vcs_shared_check_approval_sha >/dev/null; then
  fail "setup: _vcs_shared_check_approval_sha loaded" "function not defined after eval"
fi

# ── Sandbox git setup ─────────────────────────────────────────────────────────
# make_sandbox already ran `git init` and configured user.name/email via
# $HOME/.gitconfig. Build a small commit graph that exercises every waiver
# path the shared function has to reason about.
git checkout -q -b main 2>/dev/null || git checkout -q main

# SHA_BASE — the merge-base / origin default branch tip.
printf 'initial\n' > feature.txt
git add feature.txt
git commit -q -m "initial commit"
SHA_BASE="$(git rev-parse HEAD)"
git branch -q -f origin_default HEAD  # stand-in for "origin/main" (no real remote in sandbox)
git update-ref refs/remotes/origin/main HEAD

# SHA_DOCS — docs-only delta off SHA_BASE (covered by DEFAULT_WAIVER's *.md).
printf 'readme update\n' > README.md
git add README.md
git commit -q -m "docs: update readme"
SHA_DOCS="$(git rev-parse HEAD)"

# SHA_SCRIPTS — scripts/ path changed off SHA_DOCS (hard-coded non-waivable).
mkdir -p scripts
printf '#!/bin/bash\n# stub\n' > scripts/fake.sh
git add scripts/fake.sh
git commit -q -m "scripts: add fake helper"
SHA_SCRIPTS="$(git rev-parse HEAD)"

# HEAD_SHA — current PR head, one more docs-only commit past SHA_SCRIPTS.
printf 'more readme\n' >> README.md
git add README.md
git commit -q -m "docs: more readme"
HEAD_SHA="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main "$SHA_BASE"

# SHA_BASE_ONLY_HEAD — a second PR head built so the delta between an old
# marker SHA and this head includes a file that arrived ONLY via a
# base-branch sync (absent from the PR's own three-dot diff against
# origin/main), proving #102's base-only filtering still holds post-refactor.
# origin/main advances to include an unrelated non-waivable file (simulating
# "someone merged a change to main while this PR was open"); the PR branch
# then merges that in without itself touching the file.
git update-ref refs/remotes/origin/main "$SHA_BASE"
git checkout -q -b sync-base "$SHA_BASE"
mkdir -p scripts
printf '#!/bin/bash\n# base-only\n' > scripts/base-only.sh
git add scripts/base-only.sh
git commit -q -m "scripts: base-only change"
SHA_SYNC_BASE="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main "$SHA_SYNC_BASE"

git checkout -q -b pr-branch "$SHA_DOCS"
git merge -q -m "merge base sync" "$SHA_SYNC_BASE"
SHA_BASE_ONLY_HEAD="$(git rev-parse HEAD)"

git checkout -q main

# ── Helpers ───────────────────────────────────────────────────────────────────

# entries_json <label> <role> <sha> — one-entry MARKER_ENTRIES payload with a
# current (non-stale-at-marker-extraction) marker, i.e. reason=null.
entries_json() {
  printf '{"entries":[{"label":"%s","role":"%s","sha":"%s","reason":null}]}' "$1" "$2" "$3"
}

# run_check <head_sha> <base_ref_name> <marker_entries_json> [stale_list] --
# call the shared function directly with a minimal normalised PR payload.
# (REPO_ROOT is left unset: every test below runs with $SANDBOX as cwd, which
# is exactly what an empty REPO_ROOT falls back to -- subprocess.run(cwd=None).)
run_check() {
  local head="$1" base="$2" entries="$3" stale_list="${4:-false}"
  printf '{"headRefOid":"%s","baseRefName":"%s"}' "$head" "$base" \
    | MARKER_ENTRIES="$entries" STALE_LIST="$stale_list" _vcs_shared_check_approval_sha
}

# ═══════════════════════════════════════════════════════════════════════════
# fresh approval: marker SHA == head SHA
# ═══════════════════════════════════════════════════════════════════════════
_entries="$(entries_json "qa:pass" "qa" "$HEAD_SHA")"
out="$(run_check "$HEAD_SHA" "" "$_entries" 2>&1)"; rc=$?
assert_eq "0" "$rc" "fresh approval: exits 0"
assert_eq "check-approval-sha: all approval labels are current" "$out" "fresh approval: reports all current"

# ═══════════════════════════════════════════════════════════════════════════
# stale by non-waivable path: scripts/fake.sh changed since the marker SHA
# ═══════════════════════════════════════════════════════════════════════════
_entries="$(entries_json "qa:pass" "qa" "$SHA_DOCS")"
out="$(run_check "$HEAD_SHA" "" "$_entries" 2>&1)"; rc=$?
assert_eq "1" "$rc" "stale by non-waivable path: exits 1"
assert_contains "$out" "STALE qa:pass (qa)" "stale by non-waivable path: names label and role"
assert_contains "$out" "non-waivable files changed since $SHA_DOCS" "stale by non-waivable path: cites the marker SHA"
assert_contains "$out" "scripts/fake.sh" "stale by non-waivable path: names the offending file"

# ═══════════════════════════════════════════════════════════════════════════
# waived by *.md: only README.md changed since the marker SHA
# ═══════════════════════════════════════════════════════════════════════════
_entries="$(entries_json "qa:pass" "qa" "$SHA_BASE")"
out="$(run_check "$SHA_DOCS" "" "$_entries" 2>&1)"; rc=$?
assert_eq "0" "$rc" "waived by *.md: exits 0 (DEFAULT_WAIVER covers docs-only delta)"
assert_eq "check-approval-sha: all approval labels are current" "$out" "waived by *.md: reports all current"

# ═══════════════════════════════════════════════════════════════════════════
# base-only change filtered (#102): the marker SHA differs from head only by
# a file that arrived purely via a base-branch sync -- excluded from
# consideration once baseRefName lets the shared function compute the PR's
# own three-dot diff.
# ═══════════════════════════════════════════════════════════════════════════
_entries="$(entries_json "qa:pass" "qa" "$SHA_DOCS")"
out="$(run_check "$SHA_BASE_ONLY_HEAD" "main" "$_entries" 2>&1)"; rc=$?
assert_eq "0" "$rc" "base-only change filtered: exits 0 (#102 excludes base-sync-only files)"
assert_eq "check-approval-sha: all approval labels are current" "$out" "base-only change filtered: reports all current"

# Sanity: WITHOUT baseRefName (so the three-dot filter cannot run), the same
# delta is correctly flagged non-waivable -- proves the #102 filter (not a
# bug in the waiver rules) is what made the case above pass.
out="$(run_check "$SHA_BASE_ONLY_HEAD" "" "$_entries" 2>&1)"; rc=$?
assert_eq "1" "$rc" "base-only change filtered: without baseRefName, filter is skipped and the file is flagged"
assert_contains "$out" "scripts/base-only.sh" "base-only change filtered: names the file when the filter is skipped"

# ═══════════════════════════════════════════════════════════════════════════
# --stale-list output
# ═══════════════════════════════════════════════════════════════════════════
_entries="$(entries_json "qa:pass" "qa" "$SHA_DOCS")"
out="$(run_check "$HEAD_SHA" "" "$_entries" true 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "--stale-list: still exits 1"
assert_contains "$out" "stale role=qa label=qa:pass" "--stale-list: stdout carries the greppable stale line"

err_only="$(run_check "$HEAD_SHA" "" "$_entries" true 2>&1 1>/dev/null)"
assert_contains "$err_only" "STALE qa:pass (qa)" "--stale-list: stderr prose unchanged"

# Without the flag: no stdout stale-list line.
out_noflag="$(run_check "$HEAD_SHA" "" "$_entries" 2>/dev/null)"
assert_not_contains "$out_noflag" "stale role=" "no --stale-list: no stdout stale-list line"

# ═══════════════════════════════════════════════════════════════════════════
# agent instructions are non-waivable (#428): each path gets its own isolated
# one-file delta off SHA_BASE, so a stale verdict cannot come from scripts/.
# README.md, docs/ and templates/comments/ are the positive controls (waived),
# as is a near-miss prefix (agentsx/). Matching is casefolded, covers the
# runner dot-directories (.claude/{agents,...,rules}/, .agents/, .agent/,
# .gemini/, .pi/, .codex/) at any depth, and any AGENTS.md, CLAUDE.md,
# GEMINI.md, AGENTS.override.md or CLAUDE.local.md at any depth;
# docs/agents/ stays waived; a rename out of skills/ reports the old path too.
# ═══════════════════════════════════════════════════════════════════════════
delta_head() {  # <path> -- one-file commit off SHA_BASE; prints the new SHA
  git checkout -q --detach "$SHA_BASE"
  mkdir -p "$(dirname "$1")"
  printf 'edit %s\n' "$1" > "$1"
  git add "$1"
  git commit -q -m "edit $1"
  git rev-parse HEAD
}

_entries="$(entries_json "qa:pass" "qa" "$SHA_BASE")"
for _p in agents/qa.md skills/pipeline/SKILL.md templates/prompts/qa.md AGENTS.md CLAUDE.md \
          sub/AGENTS.md a/b/CLAUDE.md \
          .claude/agents/developer.md .claude/skills/x/SKILL.md .claude/commands/pr.md .claude/talos/scripts/x.sh .agents/x.md \
          Skills/pipeline/SKILL.md Agents/qa.md Templates/Prompts/qa.md AGENTS.MD Claude.md claude.md sub/agents.md .Claude/agents/x.md \
          GEMINI.md sub/GEMINI.md .gemini/system.md .agent/rules/x.md .pi/SYSTEM.md AGENTS.override.md a/b/AGENTS.override.md \
          .codex/config.toml .codex/notes.md .claude/rules/x.md CLAUDE.local.md sub/CLAUDE.local.md \
          GEMINI.MD Gemini.md .Gemini/x.md .PI/x.md AGENTS.OVERRIDE.MD claude.LOCAL.md .Claude/Rules/x.md \
          sub/.claude/rules/x.md sub/.agents/rules/x.md sub/.agent/rules/x.md sub/.gemini/system.md sub/.pi/SYSTEM.md sub/.codex/notes.md \
          a/b/.claude/skills/x/SKILL.md a/.claude/agents/x.md a/.Claude/Commands/x.md a/.AGENTS/x.md; do
  _h="$(delta_head "$_p")"
  out="$(run_check "$_h" "" "$_entries" 2>&1)"; rc=$?
  assert_eq "1" "$rc" "non-waivable instruction path $_p: exits 1 under the default waiver"
  assert_contains "$out" "STALE qa:pass (qa)" "non-waivable instruction path $_p: approval is stale"
  assert_contains "$out" "$_p" "non-waivable instruction path $_p: names the file"
done

for _p in README.md docs/user-guide.md CHANGELOG.md templates/comments/qa-verdict.md agentsx/note.md .claude/notes.md Docs/guide.md \
          docs/agents/x.md docs/skills/x.md docs/gemini-notes.md .pip/x.md .agentx/x.md .gemini-notes/x.md .codexx/x.md \
          GEMINI.md.example sub/.pip/x.md sub/.agentx/x.md sub/.claude/notes.md; do
  _h="$(delta_head "$_p")"
  out="$(run_check "$_h" "" "$_entries" 2>&1)"; rc=$?
  assert_eq "0" "$rc" "waivable path $_p: exits 0 under the default waiver"
  assert_not_contains "$out" "note:" "waivable path $_p: no note on the default waiver"
done

# A config waiver cannot widen the runner instruction paths, nested or not;
# an entry under one of them is reported as ignored.
for _p in GEMINI.md .pi/SYSTEM.md sub/.claude/rules/x.md sub/.agents/rules/x.md; do
  _h="$(delta_head "$_p")"
  for _w in '["*.md"]' '["*.md*"]'; do
    out="$(WAIVER_PATHS="$_w" run_check "$_h" "" "$_entries" 2>&1)"; rc=$?
    assert_eq "1" "$rc" "config waiver $_w cannot waive $_p"
    assert_contains "$out" "STALE qa:pass (qa)" "config waiver $_w: $_p stays stale"
  done
done
_h="$(delta_head ".gemini/system.md")"
out="$(WAIVER_PATHS='[".gemini/**"]' run_check "$_h" "" "$_entries" 2>&1)"; rc=$?
assert_eq "1" "$rc" "waiver .gemini/** cannot waive .gemini/system.md"
assert_contains "$out" "entry '.gemini/**' ignored for agent-instruction paths" "waiver .gemini/**: ignored-entry note"
git checkout -q main

# Non-ASCII and control characters in paths: without `-z` git quotes them
# ("skills/\303\274/SKILL.md") and the quoted string misses the non-waivable
# check, so a broad config waiver such as *.md* would waive an instruction
# file. Real paths must be compared, under the default waiver AND *.md*.
_NA_UE="$(printf '\303\274')"
for _p in "skills/$_NA_UE/SKILL.md" "Skills/$_NA_UE/x.md"; do
  _h="$(delta_head "$_p")"
  for _w in '' '["*.md*"]'; do
    if [ -n "$_w" ]; then
      out="$(WAIVER_PATHS="$_w" run_check "$_h" "" "$_entries" 2>&1)"; rc=$?
    else
      out="$(run_check "$_h" "" "$_entries" 2>&1)"; rc=$?
    fi
    assert_eq "1" "$rc" "non-ASCII instruction path $_p (waiver ${_w:-default}): exits 1"
    assert_contains "$out" "STALE qa:pass (qa)" "non-ASCII instruction path $_p (waiver ${_w:-default}): stale"
  done
done

# Waivable docs with a non-ASCII name, a tab or a newline stay waived (the
# quoted form of a non-ASCII name used to be a false stale). git can create
# all of these in the sandbox, so none is skipped.
_TAB="$(printf '\t')"
_NL='
'
for _p in "docs/$_NA_UE.md" "docs/a${_TAB}b.md" "docs/a${_NL}b.md"; do
  _h="$(delta_head "$_p")"
  out="$(run_check "$_h" "" "$_entries" 2>&1)"; rc=$?
  assert_eq "0" "$rc" "waivable docs path with special characters: exits 0 under the default waiver"
done
git checkout -q main

# Rename out of an instruction path: git mv skills/x/SKILL.md docs/x.md. With
# rename detection only docs/x.md would be reported (waived); --no-renames
# reports the deleted old path as well, so the approval goes stale.
git checkout -q --detach "$SHA_BASE"
mkdir -p skills/x
printf 'instructions\n' > skills/x/SKILL.md
git add skills/x/SKILL.md
git commit -q -m "add skills/x/SKILL.md"
_R0="$(git rev-parse HEAD)"
mkdir -p docs
git mv skills/x/SKILL.md docs/x.md
git commit -q -m "mv skills/x/SKILL.md docs/x.md"
_R1="$(git rev-parse HEAD)"
out="$(run_check "$_R1" "" "$(entries_json "qa:pass" "qa" "$_R0")" 2>&1)"; rc=$?
assert_eq "1" "$rc" "rename out of skills/ to docs/: exits 1"
assert_contains "$out" "skills/x/SKILL.md" "rename out of skills/ to docs/: names the old path"
git checkout -q main

# A config that lists an instruction path as waivable is ignored for it, with
# a stderr note; a docs-only delta alongside it is still waived.
_h="$(delta_head skills/pipeline/SKILL.md)"
out="$(WAIVER_PATHS='["skills/**","*.md"]' run_check "$_h" "" "$_entries" 2>&1)"; rc=$?
assert_eq "1" "$rc" "config lists skills/**: still stale for a skills/ delta"
assert_contains "$out" "note: merge.approval_waiver_paths entry 'skills/**' ignored for agent-instruction paths" "config lists skills/**: stderr note names the entry"
assert_not_contains "$out" "entry '*.md'" "config lists skills/**: no note for the *.md entry"

_h="$(delta_head sub/CLAUDE.md)"
out="$(WAIVER_PATHS='["AGENTS.md","*.md"]' run_check "$_h" "" "$_entries" 2>&1)"; rc=$?
assert_eq "1" "$rc" "config lists AGENTS.md: still stale for a nested CLAUDE.md delta"
assert_contains "$out" "entry 'AGENTS.md' ignored" "config lists AGENTS.md: stderr note names the entry"

# The note prints once per entry, and a differently-cased entry gets one too.
out="$(WAIVER_PATHS='["skills/**","Agents/**","*.md"]' run_check "$_h" "" "$_entries" 2>&1)"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c "entry 'skills/\*\*' ignored")" "note prints once for the skills/** entry"
assert_contains "$out" "entry 'Agents/**' ignored" "casefolded entry Agents/** also gets the note"

_h="$(delta_head docs/user-guide.md)"
out="$(WAIVER_PATHS='["agents/**","docs/**"]' run_check "$_h" "" "$_entries" 2>&1)"; rc=$?
assert_eq "0" "$rc" "config lists agents/**: a docs-only delta stays waived"
assert_contains "$out" "entry 'agents/**' ignored" "config lists agents/**: note still printed on success"
git checkout -q main

finish
