#!/usr/bin/env bash
# test-free-text-as-data.sh -- issue-derived and subagent-authored text reaches
# its consumer as data, byte for byte, through every recipe shape (#342).
#
# The one idiom: a heredoc on stdin whose delimiter is `TALOS_<rand>`, with
# <rand> invented fresh for each use, so the text cannot contain the closing
# line. The consumers are the real scripts (`pipeline-notify.sh <e> <r> -`,
# `pipeline-vcs.sh comment-issue|comment-pr|approve-pr|close-issue <n>
# --body-file -`) or a variable / `mktemp` file in the recipe itself.
#
# Part 1 runs the real scripts with the hostile body. Part 2 pulls every
# recipe out of agents/*.md and skills/pipeline/SKILL.md, fills the heredoc
# bodies with the hostile body and fresh delimiters, runs it in a sandbox
# against stub scripts, and checks what the consumer received.
#
# The hostile body holds: bare EOF / TALOS_EOF / TALOS_<rand> lines followed by
# `touch <sandbox>/pwned`, $(touch ...), backticks, both quote types, and a
# trailing newline. No file may be created.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

NOTIFY="$HOME/.talos/scripts/pipeline-notify.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# The hostile body. Written to a file so every use is byte-identical.
BODY="$SANDBOX/hostile.txt"
{
  printf 'first line\n'
  printf 'EOF\n'
  printf 'touch %s/pwned\n' "$SANDBOX"
  printf 'TALOS_EOF\n'
  printf 'touch %s/pwned-talos-eof\n' "$SANDBOX"
  printf 'TALOS_<rand>\n'
  printf 'touch %s/pwned-placeholder\n' "$SANDBOX"
  printf '$(touch %s/pwned2)\n' "$SANDBOX"
  printf '`touch %s/pwned3`\n' "$SANDBOX"
  printf "it's \"quoted\" and 'single' and \`tick\`\n"
  printf 'last line\n'
} > "$BODY"
# The same text without its final newline (what "$(cat)" and "read -r -d ''" hand back).
TRIMMED="$(cat "$BODY")"

assert_no_pwned() {  # $1=label
  local leaked=""
  for f in "$SANDBOX"/pwned*; do [ -e "$f" ] && leaked="$leaked $f"; done
  assert_eq "" "$leaked" "$1: nothing in the body ran (no pwned file)"
}
rand() { LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 16; }

# ══ Part 1: the real scripts take the text from stdin ═════════════════════════

# ── pipeline-notify.sh <event> <ref> - ... ───────────────────────────────────
CMD_OUT="$SANDBOX/cmd-stdin.json"
cat > talos.pipeline.json <<EOF
{"notifications": {"cmd": "cat > $CMD_OUT", "cmd_timeout_s": 5}}
EOF
msg_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"], end="")' "$CMD_OUT"; }

D="TALOS_$(rand)"
rm -f "$CMD_OUT"
{ printf 'bash %s qa "#42" - 42 <<'"'%s'"'\n' "$NOTIFY" "$D"; cat "$BODY"; printf '%s\n' "$D"; } > "$SANDBOX/n.sh"
bash "$SANDBOX/n.sh" </dev/null >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "notify -: exits 0"
assert_file_exists "$CMD_OUT" "notify -: the cmd sink got a payload"
assert_contains "$(msg_field)" "$TRIMMED" "notify -: the whole hostile text arrives in the message, byte for byte (trailing newlines trimmed)"
assert_no_pwned "notify -"

# The argv form is unchanged: same payload as the stdin form for a plain message.
rm -f "$CMD_OUT"; bash "$NOTIFY" qa "#42" "PASS: 3 criteria verified" 42 </dev/null >/dev/null 2>&1
ARGV_PAYLOAD="$(cat "$CMD_OUT")"
rm -f "$CMD_OUT"; printf 'PASS: 3 criteria verified\n' | bash "$NOTIFY" qa "#42" - 42 >/dev/null 2>&1
assert_eq "$ARGV_PAYLOAD" "$(cat "$CMD_OUT")" "notify: '-' with stdin gives the same payload as the argv form"
rm -f "$CMD_OUT"; bash "$NOTIFY" qa "#42" "-x" 42 </dev/null >/dev/null 2>&1
assert_contains "$(msg_field)" "-x" "notify: a message that merely starts with '-' stays literal"
rm -f "$CMD_OUT"; bash "$NOTIFY" qa "#42" - 42 </dev/null >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "notify -: empty stdin is not an error"
out="$(printf 'rendered text\n' | bash "$NOTIFY" --render default qa "#42" - 2>&1)"
assert_contains "$out" "rendered text" "notify --render: '-' reads the message from stdin too"

# ── pipeline-vcs.sh <verb> <n> --body-file - ─────────────────────────────────
# A gh that records the --body it was given, byte for byte, and answers the
# state / URL queries the verbs make.
FAKE="$SANDBOX/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"--json state"*) printf 'OPEN\n'; exit 0 ;;
  *"nameWithOwner"*) printf 'acme/widget\n'; exit 0 ;;
esac
prev=""
for a in "$@"; do
  if [ "$prev" = "--body" ]; then printf '%s' "$a" > "$GH_BODY_OUT"; printf '%s\n' "$*" > "$GH_ARGV_OUT"; fi
  prev="$a"
done
printf 'https://github.com/acme/widget/issues/1#issuecomment-1\n'
GH
chmod +x "$FAKE/gh"
export GH_BODY_OUT="$SANDBOX/gh.body" GH_ARGV_OUT="$SANDBOX/gh.argv"
rm -f talos.pipeline.json

vcs_stdin() {  # $1=verb $2=n  -> runs `<verb> <n> --body-file -` with the hostile body via a per-use delimiter
  local d="TALOS_$(rand)"
  { printf 'PATH=%q bash %q %s %s --body-file - <<'"'%s'"'\n' "$FAKE:$PATH" "$VCS" "$1" "$2" "$d"; cat "$BODY"; printf '%s\n' "$d"; } > "$SANDBOX/v.sh"
  rm -f "$GH_BODY_OUT" "$GH_ARGV_OUT"
  bash "$SANDBOX/v.sh" </dev/null >/dev/null 2>&1
}
for verb in comment-issue comment-pr approve-pr close-issue; do
  vcs_stdin "$verb" 5; rc=$?
  assert_eq "0" "$rc" "$verb --body-file -: exits 0"
  assert_eq "$TRIMMED" "$(cat "$GH_BODY_OUT" 2>/dev/null)" "$verb --body-file -: the provider got the hostile text byte for byte (trailing newlines trimmed)"
  assert_no_pwned "$verb --body-file -"
done
# The argv and file forms keep working unchanged.
rm -f "$GH_BODY_OUT"; PATH="$FAKE:$PATH" bash "$VCS" comment-issue 5 "plain body" </dev/null >/dev/null 2>&1
assert_eq "plain body" "$(cat "$GH_BODY_OUT" 2>/dev/null)" "comment-issue: the positional body form is unchanged"
rm -f "$GH_BODY_OUT"; PATH="$FAKE:$PATH" bash "$VCS" comment-pr 5 --body-file "$BODY" </dev/null >/dev/null 2>&1
assert_eq "$TRIMMED" "$(cat "$GH_BODY_OUT" 2>/dev/null)" "comment-pr: --body-file <path> is unchanged"
rm -f "$GH_BODY_OUT"; PATH="$FAKE:$PATH" bash "$VCS" approve-pr 5 "looks good" </dev/null >/dev/null 2>&1
assert_eq "looks good" "$(cat "$GH_BODY_OUT" 2>/dev/null)" "approve-pr: the positional body form is unchanged"
rm -f "$GH_BODY_OUT"; PATH="$FAKE:$PATH" bash "$VCS" close-issue 5 "closed by PR #6" </dev/null >/dev/null 2>&1
assert_eq "closed by PR #6" "$(cat "$GH_BODY_OUT" 2>/dev/null)" "close-issue: the positional body form is unchanged"
rm -f "$GH_BODY_OUT"; PATH="$FAKE:$PATH" bash "$VCS" approve-pr 5 --body-file "$SANDBOX/no-such-file" </dev/null >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "approve-pr --body-file <missing>: exits 1, nothing posted"
assert_file_absent "$GH_BODY_OUT" "approve-pr --body-file <missing>: nothing reached the provider"

# ══ Part 2: the recipes in the role profiles and the playbook ═════════════════
# recipe.py <out.sh> <body-file> <md> <needle> [<needle> ...]
#   For each needle, takes the fenced code block of <md> that contains it
#   (dedented), concatenates them, gives every `<<'TALOS_<rand>'` heredoc a
#   fresh random delimiter and the hostile body (plus a "heredoc k" line, so two
#   heredocs in one recipe are told apart; the bodies land in <out.sh>.bodies/k),
#   and fills the remaining placeholders. Fails if a needle matches no block.
cat > "$SANDBOX/recipe.py" <<'PY'
import os, random, re, sys, textwrap

out, body_file, md = sys.argv[1], sys.argv[2], sys.argv[3]
needles = sys.argv[4:]
sandbox = os.environ["SANDBOX"]
body = open(body_file, encoding="utf-8").read()
text = open(md, encoding="utf-8").read()
blocks = [textwrap.dedent(b) for b in re.findall(r"^[ \t]*```bash\n(.*?)^[ \t]*```", text, re.S | re.M)]
chosen = []
for needle in needles:
    hit = [b for b in blocks if needle in b]
    if not hit:
        sys.exit("no fenced recipe block contains %r in %s" % (needle, md))
    chosen.append(hit[0])
script = "\n".join(chosen)

SUBS = {
    "<TMPL_DIR>": sandbox + "/tmpl", "<template>": "validator-verdict",
    "<HEADER>": "**Agent:** test (talos)", "<PR_or_empty>": "", "<VERDICT>": "CONFIRMED",
    "<N>": "7", "<PR>": "8", "<pr>": "8", "<branch>": "fix/issue-7-x", "<role>": "qa", "<issue-n>": "7",
}
def fill(line):
    for a, b in SUBS.items():
        line = line.replace(a, b)
    return re.sub(r"<[A-Za-z][^<>\n]*>", "x", line) if "python3 -c" not in line else line


lines, res, k = script.split("\n"), [], 0
bodies_dir = out + ".bodies"
os.makedirs(bodies_dir, exist_ok=True)
i = 0
opener = re.compile(r"<<'TALOS_<rand>'")
while i < len(lines):
    line = lines[i]
    if opener.search(line):
        k += 1
        d = "TALOS_" + "".join(random.choice("0123456789abcdef") for _ in range(16))
        res.append(fill(opener.sub("<<'%s'" % d, line)))
        j = i + 1
        while lines[j].strip() != "TALOS_<rand>":
            j += 1
        content = body + "heredoc %d\n" % k
        open(os.path.join(bodies_dir, str(k)), "w", encoding="utf-8").write(content)
        res.append(content.rstrip("\n"))
        res.append(d)
        i = j + 1
        continue
    res.append(fill(line))
    i += 1
open(out, "w", encoding="utf-8").write("\n".join(res) + "\n")
PY

# Stub scripts: every call is recorded under $REC as call.XXXXXX.{argv,stdin,file},
# where .file is the content of the last argument when it is a readable file
# (the body-file of create-pr / create-issue, copied before the recipe removes it).
REC="$SANDBOX/rec"; STUBROOT="$SANDBOX/recipe-cwd"
mkdir -p "$STUBROOT/scripts" "$REC" "$SANDBOX/tmpl"
cp "$TALOS_ROOT"/templates/comments/*.md "$SANDBOX/tmpl/"
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-agent.sh; do
  cat > "$STUBROOT/scripts/$s" <<'STUB'
#!/usr/bin/env bash
base="$(mktemp "$REC/call.XXXXXX")"
printf '%s\0' "$(basename "$0")" "$@" > "$base.argv"
cat > "$base.stdin"
for a in "$@"; do [ -f "$a" ] && cp "$a" "$base.file"; done
printf 'https://example.test/comment/1\n'
STUB
  chmod +x "$STUBROOT/scripts/$s"
done
export REC SANDBOX

calls() { ls "$REC"/call.*.argv 2>/dev/null | wc -l | tr -d ' '; }
argv_of() { python3 -c 'import sys; print("|".join(open(sys.argv[1],"rb").read().decode().split("\0")[:-1]))' "$1"; }
first_call() { ls "$REC"/call.*.argv | head -1 | sed 's/\.argv$//'; }
run_recipe() {  # $1=md $2...=needles; leaves the script in $SANDBOX/r.sh, runs it, resets $REC
  local md="$1"; shift
  rm -rf "$REC"/* "$SANDBOX/r.sh.bodies"
  python3 "$SANDBOX/recipe.py" "$SANDBOX/r.sh" "$BODY" "$md" "$@" || return 99
  (cd "$STUBROOT" && bash "$SANDBOX/r.sh" </dev/null >"$SANDBOX/r.out" 2>"$SANDBOX/r.err"); return $?
}

# ── agents/pm.md: comment-issue <N> --body-file - ────────────────────────────
run_recipe "$TALOS_ROOT/agents/pm.md" 'comment-issue <N> --body-file -'; rc=$?
assert_eq "0" "$rc" "pm.md recipe: runs ($(head -c 200 "$SANDBOX/r.err"))"
c="$(first_call)"
assert_eq "pipeline-vcs.sh|comment-issue|7|--body-file|-" "$(argv_of "$c.argv")" "pm.md recipe: the spec goes in via --body-file -"
assert_eq "$(cat "$SANDBOX/r.sh.bodies/1")" "$(cat "$c.stdin")" "pm.md recipe: the stub received the spec byte for byte (hostile body + trailing newline)"
cmp -s "$SANDBOX/r.sh.bodies/1" "$c.stdin"; assert_eq "0" "$?" "pm.md recipe: byte-identical, trailing newline included (cmp)"
assert_no_pwned "pm.md recipe"

# ── agents/developer.md: mktemp body file + title heredoc + create-pr ────────
run_recipe "$TALOS_ROOT/agents/developer.md" 'create-pr <branch>'; rc=$?
assert_eq "0" "$rc" "developer.md recipe: runs ($(head -c 200 "$SANDBOX/r.err"))"
c="$(first_call)"
argv="$(argv_of "$c.argv")"
assert_contains "$argv" "pipeline-vcs.sh|create-pr|fix/issue-7-x|first line|" "developer.md recipe: the title is the first line of the title heredoc, as one argument"
cmp -s "$SANDBOX/r.sh.bodies/1" "$c.file"; assert_eq "0" "$?" "developer.md recipe: the body file the stub read is byte-identical to the hostile body"
bodyfile="${argv##*|}"
case "$bodyfile" in /tmp/pr-body-*) fail "developer.md recipe: body file is a fixed /tmp/pr-body-* name" ;; *) pass "developer.md recipe: body file is not a fixed /tmp/pr-body-* name ($(basename "$bodyfile" | cut -c1-8)...)" ;; esac
assert_file_absent "$bodyfile" "developer.md recipe: the mktemp body file is removed after create-pr succeeds"
assert_no_pwned "developer.md recipe"

# ── agents/reviewer.md: approve-pr <pr> --body-file - ────────────────────────
run_recipe "$TALOS_ROOT/agents/reviewer.md" 'approve-pr <pr> --body-file -'; rc=$?
assert_eq "0" "$rc" "reviewer.md recipe: runs"
c="$(first_call)"
assert_eq "pipeline-vcs.sh|approve-pr|8|--body-file|-" "$(argv_of "$c.argv")" "reviewer.md recipe: the summary goes in via --body-file -"
cmp -s "$SANDBOX/r.sh.bodies/1" "$c.stdin"; assert_eq "0" "$?" "reviewer.md recipe: the stub received the summary byte for byte"
assert_no_pwned "reviewer.md recipe"

# ── skills/pipeline/SKILL.md: the stage-comment rendering recipe ─────────────
# SUMMARY and DETAILS are read -r -d '' variables (the BLOCKED_BY shape). The
# variable form trims surrounding whitespace, so the comment holds each body
# without its trailing newline.
run_recipe "$TALOS_ROOT/skills/pipeline/SKILL.md" 'TMPL="<TMPL_DIR>'; rc=$?
assert_eq "0" "$rc" "playbook rendering recipe: runs ($(head -c 200 "$SANDBOX/r.err"))"
posted="$(argv_of "$(first_call).argv")"
assert_contains "$posted" "comment-issue|7|**Agent:** test (talos)" "playbook rendering recipe: the comment is rendered and posted"
python3 - "$(first_call).argv" "$SANDBOX/r.sh.bodies/1" "$SANDBOX/r.sh.bodies/2" <<'PY'
import sys
argv = open(sys.argv[1], "rb").read().decode().split("\0")[:-1]
body = argv[3]
want = [open(p, encoding="utf-8").read().strip() for p in sys.argv[2:4]]
sys.exit(0 if all(w in body for w in want) else 1)
PY
assert_eq "0" "$?" "playbook rendering recipe: SUMMARY and DETAILS each reach the comment byte for byte (trimmed)"
assert_no_pwned "playbook rendering recipe"

# ── skills/pipeline/SKILL.md: the Rule 2 relay ───────────────────────────────
run_recipe "$TALOS_ROOT/skills/pipeline/SKILL.md" 'pipeline-notify.sh <role> "#<N>" - <N> <<'; rc=$?
assert_eq "0" "$rc" "playbook relay recipe: runs ($(head -c 200 "$SANDBOX/r.err"))"
c="$(first_call)"
assert_eq 'pipeline-notify.sh|qa|#7|-|7' "$(argv_of "$c.argv")" "playbook relay recipe: ONE command, message passed as -"
cmp -s "$SANDBOX/r.sh.bodies/1" "$c.stdin"; assert_eq "0" "$?" "playbook relay recipe: the stub received the summary byte for byte"
assert_eq "1" "$(calls)" "playbook relay recipe: one relay is one command"
assert_no_pwned "playbook relay recipe"

# ── skills/pipeline/SKILL.md: sub-issue body + title + create-issue ──────────
run_recipe "$TALOS_ROOT/skills/pipeline/SKILL.md" 'BODY_FILE="$(mktemp)"' 'create-issue "$SUB_TITLE" "$BODY_FILE" \
  --label pipeline:ready'; rc=$?
assert_eq "0" "$rc" "playbook sub-issue recipe: runs ($(head -c 200 "$SANDBOX/r.err"))"
c="$(first_call)"
argv="$(argv_of "$c.argv")"
assert_contains "$argv" "pipeline-vcs.sh|create-issue|first line|" "playbook sub-issue recipe: the title is one argument"
cmp -s "$SANDBOX/r.sh.bodies/1" "$c.file"; assert_eq "0" "$?" "playbook sub-issue recipe: the body file is byte-identical to the hostile body"
assert_no_pwned "playbook sub-issue recipe"

# ── skills/pipeline/SKILL.md: the adapter prompt ─────────────────────────────
run_recipe "$TALOS_ROOT/skills/pipeline/SKILL.md" 'pipeline-agent.sh <role> - <<'; rc=$?
assert_eq "0" "$rc" "playbook adapter-prompt recipe: runs"
c="$(first_call)"
cmp -s "$SANDBOX/r.sh.bodies/1" "$c.stdin"; assert_eq "0" "$?" "playbook adapter-prompt recipe: the stub received the prompt byte for byte"
assert_no_pwned "playbook adapter-prompt recipe"

# ── Control: a fixed EOF delimiter IS exploitable, a fresh one is not ────────
# The shape the recipes had before #342, run on the same hostile body.
rm -f "$SANDBOX"/pwned*
{ printf "bash -c 'cat > /dev/null' <<'EOF'\n"; cat "$BODY"; printf 'EOF\n'; } > "$SANDBOX/old.sh"
bash "$SANDBOX/old.sh" </dev/null >/dev/null 2>&1
assert_file_exists "$SANDBOX/pwned" "control: with a fixed EOF delimiter the bare EOF line ends the heredoc and 'touch pwned' RUNS"
rm -f "$SANDBOX"/pwned*
D="TALOS_$(rand)"
{ printf "bash -c 'cat > /dev/null' <<'%s'\n" "$D"; cat "$BODY"; printf '%s\n' "$D"; } > "$SANDBOX/new.sh"
bash "$SANDBOX/new.sh" </dev/null >/dev/null 2>&1
assert_no_pwned "control: with a fresh per-use delimiter the same body runs nothing"

finish
