#!/usr/bin/env bash
# test-role-profile-quoting.sh -- issue-derived and subagent-authored text never
# sits inside shell quotes, a fixed-delimiter heredoc or a fixed /tmp path in a
# role profile or the pipeline playbook (#340, #342).
#
# Issue titles and bodies are reporter-controlled; subagent summaries quote
# them. An agent that copies
#   pipeline-vcs.sh create-pr <branch> "<title>" ...
# literally hands its shell a double-quoted string, and a title containing
# $(...) or backticks is expanded. A body written through a heredoc ending in a
# fixed word (EOF) is cut short by a line holding that word, and the lines after
# it run as commands. The safe forms are a heredoc whose delimiter is the
# unguessable per-use `TALOS_<rand>` placeholder, `-` / `--body-file -` stdin
# routes that take the text as data, and "$VAR".
#
# Scans agents/*.md and skills/*/SKILL.md as whole files (so a command wrapped
# across prose lines, with or without a trailing backslash, is one command).
# A construct is unsafe when
#   (a) pipeline-vcs.sh create-pr / create-issue / slug-for / comment-issue /
#       comment-pr / approve-pr / close-issue, or pipeline-notify.sh, takes its
#       free-text argument (title / body / message) as a quoted string that
#       holds a placeholder (`<...>`, `{x}`, an ellipsis); bare issue/PR-number
#       placeholders (<N>, <PR>, <PR_NUMBER> ...) do not count,
#   (b) `--summary "..."` of pipeline-hooks.sh, or printf '%s' "...", or an
#       assignment SUMMARY= / DETAILS= / BLOCKED_BY= / ... holds one,
#   (c) a heredoc delimiter is anything but the `TALOS_<rand>` placeholder
#       (EOF and TALOS_EOF are fixed words the text could contain), or
#   (d) a fixed /tmp/<name> path appears (use mktemp).
# "$VAR", `-`, and a fixed string with no placeholder are fine.
#
# The 14 unsafe forms the PR #351 security verdict (item 7 and 14) listed, and
# what happens to each (#452). A positive control below proves every FLAGGED one.
#   1  here-strings `<<< "<summary>"`                        FLAGGED
#   2  `echo`/`printf "<summary>" | pipeline-*.sh ...`       FLAGGED
#   3  unquoted `<<TALOS_<rand>` / `<<-TALOS_<rand>`         FLAGGED
#   4  `<<\EOF`, multi-word `<<'END OF BODY'`                FLAGGED
#   5  `comment-issue <N> <summary>`, `SUMMARY=<one-line>`,
#      `$'<summary>'`                                         FLAGGED
#   6  free-text variables other than the fixed list          FLAGGED by name
#      (MSG, *_TITLE, *_TEXT, ...). ACCEPTED: any other name and HEADER/VERDICT,
#      which hold a config or enumerated value, never issue text.
#   7  free text in a slot other than the indexed one (the
#      notify ref, an earlier positional)                     FLAGGED
#   8  commands outside vcs/notify: `pipeline-status.sh <N>
#      "<text>"`, `gh pr comment --body "<...>"`              FLAGGED
#      ACCEPTED: `pipeline-agent.sh <role> "<prompt>"` (the playbook documents
#      the adapter call; the prompt is built by the orchestrator, and the stage
#      text reaches it through the same heredoc recipes), `git commit -m` (no
#      recipe in agents/ or the playbook builds a commit message from issue
#      text; the playbook names conventional prefixes only), and any vcs verb
#      not in the VCS map (a new verb is added to the map with its recipe).
#   9  `--summary="<...>"`, `--verdict "<...>"`               FLAGGED
#  10  placeholders not written as <...>, {...} or an ellipsis ("[summary here]",
#      SUMMARY_TEXT_HERE)                                     ACCEPTED: the set of
#      ways to write "fill me in" cannot be enumerated; the three forms in use
#      are covered and a new recipe is reviewed.
#  11  `${TMPDIR:-/tmp}/name`, `/tmp/$N-body.md`, `mktemp -u` FLAGGED
#      ACCEPTED: a fixed name in the working directory (it is not under /tmp and
#      a recipe that writes one is a code-review matter, not a pattern).
#  12  a command split across two inline code spans           ACCEPTED: each span
#      is one command to the scanner and to a reader; an agent that joins two
#      spans into one command is not detectable from the text.
#  13  files outside agents/*.md and skills/*/SKILL.md        ACCEPTED: README,
#      docs and templates are read by people; the files an agent loads as its
#      instructions are the two globs scanned.
#  14  the concrete `--summary "3 criteria verified"` in playbook Rule 3
#      FIXED: Rule 3 now passes the summary on stdin
#      (`--summary -`) or by `--summary-file` (#481); the positive control below
#      keeps the quoted form flagged, and the negative controls pin the stdin and
#      file forms safe.
#
# The scan FAILS when it scans zero files, a file is unreadable, or a path
# contains a space and so was split (the file list is an array, always quoted).
#
# ROLE_FILES (newline-separated) or ROLE_ROOT (a tree with agents/ and
# skills/*/SKILL.md, e.g. `git archive <rev>`) point the scan elsewhere.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

SELF="$TALOS_ROOT/tests/test-role-profile-quoting.sh"
SCANNER="$SANDBOX/scan.py"
cat > "$SCANNER" <<'PY'
import re, sys

NUMERIC = re.compile(r"<(N|PR|PR_NUMBER|id|K|J|E|i|n|M|pr|issue-n)>")
PLACEHOLDER = re.compile(r"<[^<>]+>|(?<!\$)\{[A-Za-z_][^{}\n]*\}|…|\.\.\.")
# form 6: a variable that names free text, whatever its prefix (MSG, PR_TITLE,
# FINDINGS_TEXT). HEADER and VERDICT hold a config or an enumerated value, so
# they stay out of the list (accepted, see the end of the header).
NAMES = (r"(?:[A-Z][A-Z0-9]*_)*(?:SUMMARY|DETAILS|BLOCKED_BY|ATTENTION_REPORT|SPEC_BODY|COMMENT_BODY"
         r"|TITLE|MSG|MESSAGE|TEXT|REPORT|FINDINGS|REASON|DESCRIPTION|PROMPT)")

# verb -> index of the free-text positional argument after the verb
VCS = {"create-pr": 1, "create-issue": 0, "slug-for": 0, "comment-issue": 1,
       "comment-pr": 1, "approve-pr": 1, "close-issue": 1}
NOTIFY_MESSAGE = 2  # <event> <ref> <message> [thread_key]


def free(text):
    return bool(PLACEHOLDER.search(NUMERIC.sub("", text)))


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def tokens(text, pos, limit):
    """Up to `limit` shell-ish words after pos; newlines are plain whitespace."""
    out, i, n = [], pos, len(text)
    while len(out) < limit:
        while i < n and (text[i] in " \t\r\n" or text.startswith("\\\n", i)):
            i += 2 if text.startswith("\\\n", i) else 1
        if i >= n or text[i] in "`;|&)" or text.startswith("<<", i):
            break
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(("dq", text[i + 1:j], i))
            i = j + 1
        elif c == "'":
            j = text.find("'", i + 1)
            j = n if j < 0 else j
            out.append(("sq", text[i + 1:j], i))
            i = j + 1
        elif c == "<":
            j = text.find(">", i)
            j = n if j < 0 else j + 1
            out.append(("bare", text[i:j], i))
            i = j
        else:
            j = i
            while j < n and text[j] not in " \t\r\n`;|&)":
                j += 1
            out.append(("bare", text[i:j], i))
            i = j
    return out


def scan(path):
    hits = []
    text = open(path, encoding="utf-8").read()

    def hit(pos, rule):
        ln = line_of(text, pos)
        hits.append((ln, "%s:%d: %s: %s" % (path, ln, rule, text.splitlines()[ln - 1].strip()[:140])))

    # (a) free-text argument of a vcs / notify command, wrapped or not
    for m in re.finditer(r"pipeline-(vcs|notify)\.sh", text):
        toks = tokens(text, m.end(), 12)
        if m.group(1) == "vcs":
            toks = [t for t in toks]
            vi = next((k for k, t in enumerate(toks) if not t[1].startswith("--")), None)
            if vi is None or toks[vi][1] not in VCS:
                continue
            idx = vi + 1 + VCS[toks[vi][1]]
        else:
            if toks and toks[0][1] == "--render":
                continue
            idx = NOTIFY_MESSAGE
        if idx < len(toks) and toks[idx][0] in ("dq", "sq") and free(toks[idx][1]):
            hit(m.start(), "quoted free text")
        elif idx < len(toks) and toks[idx][0] == "bare" and free(toks[idx][1]) and not toks[idx][1].startswith("-"):
            hit(m.start(), "unquoted free text")  # form 5: `comment-issue <N> <summary>`
        else:
            # form 7: a quoted placeholder in another positional slot (notify ref, ...)
            span = toks[:idx + 1]
            if any(t[0] in ("dq", "sq") and free(t[1]) for t in span):
                hit(m.start(), "quoted free text")
    # (b) --summary, printf '%s' "...", NAME="..."
    # forms 9 (--summary= / --verdict) and 2 (printf or echo piped into a stdin route)
    for m in re.finditer(r"--(?:summary|verdict)(?:=|\s+)(\"(?:[^\"\\]|\\.)*\"|'[^']*')", text, re.S):
        if free(m.group(1)):
            hit(m.start(), "quoted free text")
    for m in re.finditer(r"(?:printf\s+'[^']*'|echo(?:\s+-[a-zA-Z]+)?)\s+(\"(?:[^\"\\]|\\.)*\"|'[^']*')\s*\|\s*(?:bash\s+)?\S*pipeline-", text, re.S):
        if free(m.group(1)):
            hit(m.start(), "quoted free text (piped into a stdin route)")
    for m in re.finditer(r"printf\s+'%s'\s+(\"(?:[^\"\\]|\\.)*\")", text, re.S):
        if free(m.group(1)):
            hit(m.start(), "quoted free text")
    # forms 1 (here-string) and 5 (ANSI-C $'...' and a bare placeholder assignment)
    for m in re.finditer(r"<<<\s*(\"(?:[^\"\\]|\\.)*\"|'[^']*'|\$'[^']*')", text, re.S):
        if free(m.group(1)):
            hit(m.start(), "quoted free text (here-string)")
    for m in re.finditer(r"\b(?:%s)=(\"(?:[^\"\\]|\\.)*\"|'[^']*'|\$'[^']*'|<[^<>\s]+>)" % NAMES, text, re.S):
        if free(m.group(1)):
            hit(m.start(), "quoted free text")
    # (c) heredoc delimiters
    # forms 3 and 4: the delimiter must be QUOTED (else the body is expanded) and
    # be exactly the placeholder; \EOF and a multi-word 'END OF BODY' are fixed words
    for m in re.finditer(r"(?<!<)<<(?!<)-?[ \t]*(?:'([^'\n]*)'|\"([^\"\n]*)\"|(\\?[A-Za-z_][A-Za-z0-9_<>.-]*))", text):
        quoted = m.group(1) if m.group(1) is not None else m.group(2)
        if quoted is None:
            hit(m.start(), "heredoc delimiter %r is unquoted (the body would be expanded)" % m.group(3))
        elif quoted != "TALOS_<rand>":
            hit(m.start(), "heredoc delimiter %r is not the TALOS_<rand> placeholder" % quoted)
    # (d) fixed temp paths; form 11 adds ${TMPDIR:-/tmp}/<name>, /tmp/$VAR and mktemp -u
    for m in re.finditer(r"/tmp/[A-Za-z0-9_<$-]|/tmp\}/[A-Za-z0-9_<$-]", text):
        hit(m.start(), "fixed /tmp path (use mktemp)")
    for m in re.finditer(r"mktemp\s+(?:-\w+\s+)*-u\b", text):
        hit(m.start(), "mktemp -u names a path without creating it (use mktemp)")
    # form 8: commands outside pipeline-vcs.sh / pipeline-notify.sh that take free text
    for m in re.finditer(r"pipeline-status\.sh\s+\S+\s+(\"(?:[^\"\\]|\\.)*\")|\bgh\s+pr\s+comment\b[^\n`]*?--body\s+(\"(?:[^\"\\]|\\.)*\")", text):
        if free(m.group(1) or m.group(2) or ""):
            hit(m.start(), "quoted free text")
    return hits


rc = 0
paths = sys.argv[1:]
if not paths:
    print("ERROR: scanning zero files", file=sys.stderr)
    sys.exit(3)
for path in paths:
    try:
        for _, line in sorted(set(scan(path))):
            print(line)
    except (OSError, UnicodeDecodeError) as e:
        print("ERROR: cannot scan %s: %s" % (path, e), file=sys.stderr)
        rc = 3
sys.exit(rc)
PY

# scan_files <path>... : prints hits, exits non-zero on zero files / unreadable.
scan_files() { python3 "$SCANNER" "$@"; }

# ── The real files ────────────────────────────────────────────────────────────
FILES=()
if [ -n "${ROLE_FILES:-}" ]; then
  case "$ROLE_FILES" in
    *$'\n'*) while IFS= read -r _f; do [ -n "$_f" ] && FILES+=("$_f"); done <<EOF
$ROLE_FILES
EOF
    ;;
    *) FILES+=("$ROLE_FILES") ;;
  esac
else
  _root="${ROLE_ROOT:-$TALOS_ROOT}"
  FILES=("$_root"/agents/*.md "$_root"/skills/*/SKILL.md "$_root"/skills/*/refs/*.md)
fi
assert_eq "1" "$([ "${#FILES[@]}" -gt 0 ] && echo 1 || echo 0)" "the scan has a non-empty file list (${#FILES[@]} files)"
HITS="$(scan_files "${FILES[@]}" 2>"$SANDBOX/scan.err")"; rc=$?
assert_eq "0" "$rc" "the scan ran over every file without an error: $(cat "$SANDBOX/scan.err")"
assert_eq "" "$HITS" "no role profile or playbook puts free text inside quotes, behind a fixed heredoc delimiter, or in a fixed /tmp path"

# ── Zero files and a path with a space cannot pass vacuously (#342) ──────────
scan_files >/dev/null 2>&1; assert_eq "3" "$?" "scanning zero files fails"
scan_files "$SANDBOX/no-such-file.md" >/dev/null 2>&1; assert_eq "3" "$?" "an unreadable/missing file fails"
SP="$SANDBOX/with space"
mkdir -p "$SP"
printf 'bash scripts/pipeline-vcs.sh slug-for "<title>"\n' > "$SP/ctl file.md"
out="$(scan_files "$SP/ctl file.md" 2>&1)"
assert_contains "$out" "ctl file.md:1: quoted free text" "a file whose path contains a space is scanned, not skipped"
# The whole test, run from a checkout under a path with a space, still scans the
# real files and still fails on a planted unsafe line. (TALOS_QUOTING_NESTED
# stops the copy from recursing into the same check.)
if [ -z "${TALOS_QUOTING_NESTED:-}" ]; then
  CK="$SP/talos"
  mkdir -p "$CK/tests/fixtures" "$CK/scripts" "$CK/skills"
  cp -R "$TALOS_ROOT/agents" "$CK/agents"
  for d in "$TALOS_ROOT"/skills/*/; do mkdir -p "$CK/skills/$(basename "$d")"; cp "$d/SKILL.md" "$CK/skills/$(basename "$d")/SKILL.md"; [ -d "$d/refs" ] && cp -R "$d/refs" "$CK/skills/$(basename "$d")/refs"; done
  cp "$SELF" "$TALOS_ROOT/tests/helpers.sh" "$CK/tests/"
  cp "$TALOS_ROOT/tests/fixtures/pre-340-unsafe-recipes.md" "$CK/tests/fixtures/"
  cp "$TALOS_ROOT/scripts/pipeline-paths.sh" "$CK/scripts/"
  # TALOS_ROOT is unset so the copy finds its own files, not this checkout's
  # (the runner exports it).
  (cd "$CK" && env -u ROLE_FILES -u ROLE_ROOT -u TALOS_ROOT TALOS_QUOTING_NESTED=1 bash tests/test-role-profile-quoting.sh >"$SANDBOX/sp.out" 2>&1); sp_rc=$?
  assert_eq "0" "$sp_rc" "the guard passes from a checkout whose path contains a space"
  assert_contains "$(cat "$SANDBOX/sp.out")" "the scan has a non-empty file list" "...and it did scan the files there"
  printf '\nbash scripts/pipeline-vcs.sh slug-for "<title>"\n' >> "$CK/agents/pm.md"
  (cd "$CK" && env -u ROLE_FILES -u ROLE_ROOT -u TALOS_ROOT TALOS_QUOTING_NESTED=1 bash tests/test-role-profile-quoting.sh >"$SANDBOX/sp.out" 2>&1); sp_rc=$?
  assert_eq "1" "$sp_rc" "a planted unsafe line fails the guard from a path with a space"
fi

# ── Positive controls: the detector sees every unsafe form ───────────────────
CTL="$SANDBOX/ctl.md"
flagged() { printf '%b' "$1" > "$CTL"; [ -n "$(scan_files "$CTL" 2>/dev/null)" ]; }
for bad in \
  'bash scripts/pipeline-vcs.sh create-pr <branch> "<title>" body.md' \
  'bash scripts/pipeline-vcs.sh create-issue "<sub-task title>" f.md --label x' \
  'bash scripts/pipeline-vcs.sh slug-for "<title>"' \
  'bash scripts/pipeline-vcs.sh comment-issue <N> "**PM spec:** ..."' \
  'bash scripts/pipeline-vcs.sh comment-pr <pr> "<findings>"' \
  'bash scripts/pipeline-vcs.sh approve-pr <pr> "<summary>"' \
  'bash scripts/pipeline-vcs.sh close-issue <id> "implemented on branch <branch>"' \
  'bash scripts/pipeline-vcs.sh comment-issue <N> "done \xe2\x80\xa6"' \
  'bash scripts/pipeline-vcs.sh comment-issue <N> "done {summary}"' \
  "bash scripts/pipeline-vcs.sh comment-issue <N> '<summary>'" \
  'bash scripts/pipeline-notify.sh qa "#<N>" "<subagent summary>" <N>' \
  'bash scripts/pipeline-notify.sh blocked "#<N>" "QA failed: <criterion>" <N>' \
  'bash scripts/pipeline-hooks.sh post_stage qa qa 42 --summary "<what happened>"' \
  "printf '%s' \"<body>\" > f.md" \
  'SUMMARY="<one-line>" DETAILS="<bullets>"' \
  'BLOCKED_BY="<file>:<quoted line>"' \
  "cat > f <<'EOF'" \
  "cat > f <<'TALOS_EOF'" \
  'cat > f <<EOF' \
  "read -r -d '' X <<\"EOF\" || true" \
  'body in /tmp/pr-body-<N>.md' \
  'bash scripts/pipeline-vcs.sh comment-issue <N> - <<< "<summary>"' \
  'bash scripts/pipeline-vcs.sh comment-issue <N> --body-file - <<< "<summary>"' \
  'echo "<summary>" | bash scripts/pipeline-notify.sh qa "#<N>" - <N>' \
  "printf '%s\\n' \"<summary>\" | bash scripts/pipeline-vcs.sh comment-pr <PR> --body-file -" \
  'cat > f <<TALOS_<rand>' \
  'cat > f <<-TALOS_<rand>' \
  'cat > f <<\\EOF' \
  "cat > f <<'END OF BODY'" \
  'bash scripts/pipeline-vcs.sh comment-issue <N> <summary>' \
  'bash scripts/pipeline-notify.sh qa "#<N>" <summary> <N>' \
  'SUMMARY=<one-line>' \
  "SUMMARY=\$'<one-line>'" \
  'MSG="<summary>"' \
  'TITLE="<issue title>"' \
  'bash scripts/pipeline-notify.sh info "<issue title>" - <N>' \
  'bash scripts/pipeline-status.sh <N> "<text>"' \
  'gh pr comment <PR> --body "<findings>"' \
  'bash scripts/pipeline-hooks.sh post_stage qa qa 42 --summary="<what happened>"' \
  'bash scripts/pipeline-hooks.sh post_stage qa qa 42 --verdict "<verdict>"' \
  'F="${TMPDIR:-/tmp}/pr-body-<N>.md"' \
  'F=/tmp/$N-body.md' \
  'F="$(mktemp -u)"'; do
  flagged "$bad\n"; assert_eq "0" "$?" "positive control: flagged -- $bad"
done
flagged 'bash scripts/pipeline-vcs.sh comment-issue <N> \\\n  "**Planner:** done <list>"\n'
assert_eq "0" "$?" "positive control: a quoted argument on a backslash continuation line is flagged"
flagged 'run `bash scripts/pipeline-vcs.sh\ncreate-pr <branch> "<title>" <body-file> --draft`\n'
assert_eq "0" "$?" "positive control: a command wrapped across prose lines (no backslash) is flagged"
flagged "use \`printf '%s' \"<spec summary>\\\\n\\\\nTest types: <unit>\n  say why>\" >\n  f.md\`\n"
assert_eq "0" "$?" "positive control: a printf body wrapped across prose lines is flagged"
flagged 'bash scripts/pipeline-vcs.sh comment-issue <N> "done <the\n   findings list>"\n'
assert_eq "0" "$?" "positive control: a quoted argument whose placeholder itself spans a line break is flagged"
flagged 'bash scripts/pipeline-notify.sh info "merge-base" "#<N> sibling PR #<PR>\n   synced (<mechanism>)" <N>\n'
assert_eq "0" "$?" "positive control: a notify message wrapped across lines is flagged"

# ── Negative controls: the safe forms are not flagged ─────────────────────────
for good in \
  'bash scripts/pipeline-vcs.sh create-pr <branch> "$PR_TITLE" "$BODY_FILE"' \
  'bash scripts/pipeline-vcs.sh slug-for "$ISSUE_TITLE"' \
  'bash scripts/pipeline-vcs.sh comment-issue <N> "**PM:** skipped, issue body is the spec"' \
  'bash scripts/pipeline-vcs.sh comment-pr <PR_NUMBER> "$COMMENT_BODY"' \
  'bash scripts/pipeline-vcs.sh comment-issue <N> --body-file - <<'"'"'TALOS_<rand>'"'"'' \
  'bash scripts/pipeline-vcs.sh approve-pr <pr> --body-file - <<'"'"'TALOS_<rand>'"'"'' \
  'bash scripts/pipeline-vcs.sh close-issue <N> "closed by PR #<PR_NUMBER>"' \
  'bash scripts/pipeline-vcs.sh label-issue <N> --add pipeline:dev --remove pipeline:confirmed' \
  'bash scripts/pipeline-notify.sh qa "#<N>" - <N> <<'"'"'TALOS_<rand>'"'"'' \
  'bash scripts/pipeline-notify.sh merged "#<N>" "PR #<PR_NUMBER> merged" <N>' \
  'bash scripts/pipeline-notify.sh info "backlog" "K blocked issues, J blocked PRs: #a, PR #b" backlog' \
  'bash scripts/pipeline-notify.sh --render slack qa "#42" "<sample>"' \
  'BODY_FILE="$(mktemp)"' \
  'DETAILS="$ITEMS"' \
  'HEADER="<HEADER>" VERDICT="<VERDICT>"' \
  'bash scripts/pipeline-hooks.sh post_stage qa qa 42 --summary - <<'"'"'TALOS_<rand>'"'"'' \
  'bash scripts/pipeline-hooks.sh post_stage qa qa 42 --summary-file "$SUMMARY_FILE"' \
  'bash scripts/pipeline-vcs.sh comment-issue <N> - <<'"'"'TALOS_<rand>'"'"'' \
  'bash scripts/pipeline-notify.sh qa "#<N>" - <N> <<-'"'"'TALOS_<rand>'"'"'' \
  'printf "%s\n" "$SUMMARY" | bash scripts/pipeline-notify.sh qa "#<N>" - <N>' \
  "cat > f <<\"TALOS_<rand>\"" \
  'F="$(mktemp)"'; do
  if flagged "$good\n"; then fail "control: safe form not flagged -- $good" "$(scan_files "$CTL" 2>&1)"; else pass "control: safe form not flagged -- $good"; fi
done

# ── The nine unsafe recipes on main before #340 are all flagged (#342) ───────
# tests/fixtures/pre-340-unsafe-recipes.md holds them verbatim from 29dc539,
# one per `<!-- case N -->` block. Every block needs at least one hit.
FIX="$TALOS_ROOT/tests/fixtures/pre-340-unsafe-recipes.md"
FIXHITS="$(scan_files "$FIX" 2>&1)"
missing="$(python3 - "$FIX" "$FIXHITS" <<'PY'
import re, sys
path, hits = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")
starts = [i + 1 for i, l in enumerate(lines) if l.startswith("<!-- case ")]
starts.append(len(lines) + 2)
hit_lines = {int(m.group(1)) for m in re.finditer(r":(\d+): ", hits)}
print(" ".join(str(n + 1) for n in range(len(starts) - 1)
               if not any(starts[n] <= h < starts[n + 1] for h in hit_lines)))
PY
)"
assert_eq "9" "$(grep -c '^<!-- case ' "$FIX")" "the fixture holds nine pre-#340 unsafe recipes"
assert_eq "" "$missing" "every one of the nine pre-#340 unsafe recipes is flagged (cases not flagged: ${missing:-none})"

# CI gate wording: the run URL is bound to this repository (#452)
assert_contains "$(tr '\n' ' ' < "$TALOS_ROOT/skills/pipeline/refs/ci-gate.md" | tr -s ' ')" "this repository's own, \`https://github.com/<owner>/<repo>/actions/runs/<digits>\` with \`<owner>/<repo>\` the slug you resolved" "CI gate: the CI run URL must be this repository's own"

finish
