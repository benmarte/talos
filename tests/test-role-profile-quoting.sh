#!/usr/bin/env bash
# test-role-profile-quoting.sh -- issue-derived text never sits inside double
# quotes on a command line in a role profile or the pipeline playbook (#340).
#
# Issue titles and bodies are reporter-controlled. An agent that copies
#   pipeline-vcs.sh create-pr <branch> "<title>" ...
# literally hands its shell a double-quoted string, and a title containing
# $(...) or backticks is expanded. The safe form assigns the text to a variable
# from a single-quoted heredoc (nothing is expanded) and passes "$VAR".
#
# Scans agents/*.md and skills/*/SKILL.md. After joining backslash-continued
# lines, a line is unsafe when it
#   (a) calls pipeline-vcs.sh create-pr / create-issue / slug-for /
#       comment-issue / comment-pr and has a double-quoted argument holding a
#       placeholder (`<...>`) or an ellipsis, or
#   (b) writes a body with printf '%s' "..." holding a placeholder.
# A quoted argument that is only "$VAR", or a fixed string with no placeholder,
# is fine.
#
# ROLE_FILES="<paths>" points the scan at other files (positive controls).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

scan() {  # $@ = files -> prints "file:line: text" for every unsafe line
  python3 - "$@" <<'PY'
import re, sys

VERB = re.compile(r"pipeline-vcs\.sh\s+(create-pr|create-issue|slug-for|comment-issue|comment-pr)\b")
PRINTF = re.compile(r"printf\s+'%s'\s+\"")
DQ = re.compile(r'"((?:[^"\\]|\\.)*)"')

def placeholder_quoted(text):
    return any("<" in q or "..." in q for q in (m.group(1) for m in DQ.finditer(text)))

def unsafe(line):
    # Only what follows the verb counts: an enclosing "$(bash ... )" wrapper
    # (the comment recipe) would otherwise pair its quotes with the argument's.
    m = VERB.search(line)
    if m and placeholder_quoted(line[m.end():]):
        return True
    m = PRINTF.search(line)
    if m and placeholder_quoted(line[m.end() - 1:]):
        return True
    return False

for path in sys.argv[1:]:
    pending, start = "", 0
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.rstrip("\n")
        if not pending:
            start = n
        if line.endswith("\\"):
            pending += line[:-1] + " "
            continue
        logical, pending = pending + line, ""
        if unsafe(logical):
            print("%s:%d: %s" % (path, start, logical.strip()[:160]))
PY
}

if [ -n "${ROLE_FILES:-}" ]; then
  # shellcheck disable=SC2086
  FILES="$ROLE_FILES"
else
  FILES="$(ls "$TALOS_ROOT"/agents/*.md "$TALOS_ROOT"/skills/*/SKILL.md)"
fi
# shellcheck disable=SC2086
HITS="$(scan $FILES)"
assert_eq "" "$HITS" "no role profile or playbook line puts an issue-derived title/body inside double quotes on a command line"

# ── Positive controls: the detector sees the unsafe forms ─────────────────────
CTL="$SANDBOX/ctl.md"
for bad in \
  'bash scripts/pipeline-vcs.sh create-pr <branch> "<title>" body.md' \
  'bash scripts/pipeline-vcs.sh create-issue "<sub-task title>" f.md --label x' \
  'bash scripts/pipeline-vcs.sh slug-for "<title>"' \
  'bash scripts/pipeline-vcs.sh comment-issue <N> "**PM spec:** ..."' \
  "printf '%s' \"<body>\" > /tmp/sub-issue-1.md"; do
  printf '%s\n' "$bad" > "$CTL"
  [ -n "$(scan "$CTL")" ]; assert_eq "0" "$?" "positive control: flagged -- $bad"
done
printf 'bash scripts/pipeline-vcs.sh comment-issue <N> \\\n  "**Planner:** done <list>"\n' > "$CTL"
[ -n "$(scan "$CTL")" ]; assert_eq "0" "$?" "positive control: a quoted argument on a continuation line is flagged"
for good in \
  'bash scripts/pipeline-vcs.sh create-pr <branch> "$PR_TITLE" body.md' \
  'bash scripts/pipeline-vcs.sh slug-for "$ISSUE_TITLE"' \
  'bash scripts/pipeline-vcs.sh comment-issue <N> "**PM:** skipped, issue body is the spec"' \
  'bash scripts/pipeline-vcs.sh comment-pr <PR_NUMBER> "$COMMENT_BODY"'; do
  printf '%s\n' "$good" > "$CTL"
  [ -z "$(scan "$CTL")" ]; assert_eq "0" "$?" "control: safe form not flagged -- $good"
done

finish
