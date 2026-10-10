#!/usr/bin/env bash
# test-pipeline-meta.sh -- scripts/pipeline-meta.sh (#554): the repo facts a
# notification names (board name, repo URL, issue and PR titles) without a
# GraphQL call per notification.
#
# Every notification used to ask `gh repo view` (twice), `gh issue view` and
# `gh pr view` -- GraphQL, four calls per message, for facts that do not change
# between messages. Now:
#   (a) the board name and repo URL come from --repo / the git remote: no call
#   (b) a title is read once over REST and kept (user-private, 6 h), per repo
#   (c) a failed read is not kept, and a title is a single clean line
#   (d) with nothing to derive from, it falls back to the old `gh repo view`
# Every test runs on stubs under make_sandbox: no GitHub call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

META="$TALOS_ROOT/scripts/pipeline-meta.sh"
export STUB_REPO=acme/widget STUB_ISSUE_TITLE="Fix login crash" STUB_PR_TITLE="fix: guard null session"
CACHE_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/talos/meta"
rm -rf "$CACHE_DIR"

# ── (a) board name and repo URL: no call ──────────────────────────────────────
: > "$GH_LOG"
assert_eq "acme-widget" "$(bash "$META" --repo acme/widget board)" "board: owner-name from --repo"
assert_eq "https://github.com/acme/widget" "$(bash "$META" --repo acme/widget repo-url)" "repo-url: from --repo"
assert_eq "" "$(cat "$GH_LOG")" "board/repo-url from --repo: no gh call"

git remote add origin git@github.com:acme/gadget.git 2>/dev/null || git remote set-url origin git@github.com:acme/gadget.git
assert_eq "acme-gadget" "$(bash "$META" board)" "board: owner-name from an ssh remote"
assert_eq "https://github.com/acme/gadget" "$(bash "$META" repo-url)" "repo-url: an ssh remote becomes its https URL"
git remote set-url origin https://ghe.example.com/team/svc.git
assert_eq "https://ghe.example.com/team/svc" "$(bash "$META" repo-url)" "repo-url: an enterprise remote keeps its host"
assert_eq "team-svc" "$(bash "$META" board)" "board: owner-name from an https remote"
assert_eq "" "$(cat "$GH_LOG")" "board/repo-url from the remote: no gh call"

# ── (b) titles: read once, then kept ──────────────────────────────────────────
: > "$GH_LOG"
assert_eq "Fix login crash" "$(bash "$META" --repo acme/widget issue-title 42)" "issue-title: the title"
assert_eq "fix: guard null session" "$(bash "$META" --repo acme/widget pr-title 9)" "pr-title: the title"
assert_contains "$(cat "$GH_LOG")" "api repos/acme/widget/issues/42 --jq .title" "issue-title: one REST read of the issue"
assert_contains "$(cat "$GH_LOG")" "api repos/acme/widget/pulls/9 --jq .title" "pr-title: one REST read of the PR"
assert_not_contains "$(cat "$GH_LOG")" "issue view" "issue-title: no GraphQL"
: > "$GH_LOG"
assert_eq "Fix login crash" "$(bash "$META" --repo acme/widget issue-title 42)" "issue-title: answered again"
assert_eq "fix: guard null session" "$(bash "$META" --repo acme/widget pr-title 9)" "pr-title: answered again"
assert_eq "" "$(cat "$GH_LOG")" "titles read twice: the second answer makes no call"
: > "$GH_LOG"
bash "$META" --repo other/repo issue-title 42 >/dev/null
assert_contains "$(cat "$GH_LOG")" "api repos/other/repo/issues/42" "titles are kept per repo: another repo's #42 is read, not reused"

# The cache is user-private; a world-writable or expired file is not trusted.
f="$(ls "$CACHE_DIR"/*acme_widget*issue*42 2>/dev/null | head -1)"
assert_file_exists "$f" "the kept title is a file in the cache directory"
assert_eq "0o600" "$(python3 -c "import os,stat; print(oct(stat.S_IMODE(os.stat('$f').st_mode)))")" "the kept title is mode 0600"
chmod 666 "$f"; : > "$GH_LOG"
STUB_ISSUE_TITLE="Renamed" bash "$META" --repo acme/widget issue-title 42 > "$SANDBOX/t.out"
assert_eq "Renamed" "$(cat "$SANDBOX/t.out")" "a world-writable cache file is ignored (the title is read again)"
touch -t 202001010000 "$f"; : > "$GH_LOG"
assert_eq "Fix login crash" "$(bash "$META" --repo acme/widget issue-title 42)" "an expired cache file is ignored"

# ── (c) a failed read is not kept; a title is one clean line ──────────────────
rm -rf "$CACHE_DIR"
assert_eq "" "$(STUB_GH_API_FAIL=title bash "$META" --repo acme/widget issue-title 77)" "a failed read prints nothing"
assert_eq "" "$(ls "$CACHE_DIR" 2>/dev/null)" "a failed read keeps nothing"
assert_eq "A title" "$(STUB_ISSUE_TITLE="$(printf 'A title\nsecond line')" bash "$META" --repo acme/widget issue-title 78)" "only the first line of a title is used"
assert_eq "" "$(bash "$META" --repo acme/widget issue-title abc)" "a non-numeric number is refused"
assert_eq "" "$(bash "$META" --repo acme/widget bogus)" "an unknown fact prints nothing"

# ── (d) nothing to derive from: the old gh repo view ──────────────────────────
git remote remove origin
: > "$GH_LOG"
assert_eq "acme-widget" "$(bash "$META" board)" "board: with no --repo and no remote, gh repo view answers"
assert_contains "$(cat "$GH_LOG")" "repo view --json nameWithOwner" "board fallback: the old call"
assert_eq "https://github.com/acme/widget" "$(bash "$META" repo-url)" "repo-url: with no --repo and no remote, gh repo view answers"

finish
