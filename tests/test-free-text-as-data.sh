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
# recipe out of agents/*.md and skills/pipeline/refs/*.md (#547), fills the heredoc
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
# Bounded read (#479): `tr </dev/urandom | head` never ends when SIGPIPE is
# ignored (the Actions runner does that) and tr is BSD tr, which ignores EPIPE.
rand() { LC_ALL=C od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }

# A hung tr is a grandchild of the job that started it, so a kill takes the tree.
kill_tree() {  # $1=pid
  local p="${1:-}" kids c
  [ -n "$p" ] || return 0
  kids="$(pgrep -P "$p" 2>/dev/null)"
  kill "$p" 2>/dev/null
  for c in $kids; do kill_tree "$c"; done
  return 0
}
WPID=""
trap '_is_trap_owner && { kill_tree "$WPID"; rm -rf "$SANDBOX"; }' EXIT

# rand() returns with SIGPIPE ignored. A watchdog (no `timeout` on macOS) kills
# the job's tree after 20 s; the watchdog is itself killed on every path.
RAND_OUT="$SANDBOX/rand-ignored-pipe.txt"
( trap '' PIPE; printf '%s' "$(rand)" > "$RAND_OUT" ) &
RPID=$!
( sleep 20; kill_tree "$RPID" ) &
WPID=$!
wait "$RPID"; rrc=$?
kill_tree "$WPID"; wait "$WPID" 2>/dev/null
WPID=""
assert_eq "0" "$rrc" "rand: returns with SIGPIPE ignored (a watchdog kill would be 143)"
assert_eq "16" "$(wc -c < "$RAND_OUT" | tr -d ' ')" "rand: 16 characters"
case "$(cat "$RAND_OUT")" in *[!a-f0-9]*|'') fail "rand: lowercase hex only" "$(cat "$RAND_OUT")" ;; *) pass "rand: lowercase hex only" ;; esac

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
# A gh that records the "body" of the JSON payload it was given (the file after
# `--input`), byte for byte, and answers the state / URL queries the verbs make.
FAKE="$SANDBOX/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth token") exit 0 ;;
  "api -i") ;;
  *) exit 0 ;;
esac
in=""; prev=""
for a in "$@"; do
  [ "$prev" = "--input" ] && in="$a"
  prev="$a"
done
if [ -n "$in" ]; then
  python3 -I -c "
import json, sys
d = json.load(open(sys.argv[1]))
if 'body' in d:
    open(sys.argv[2], 'w').write(d['body'])
" "$in" "$GH_BODY_OUT"
  printf '%s\n' "$*" > "$GH_ARGV_OUT"
fi
case "$*" in
  *"-X POST"*) body='{"id":1,"html_url":"https://github.com/acme/widget/issues/1#issuecomment-1"}' ;;
  *) body='{"state":"open","merged_at":null}' ;;
esac
printf 'HTTP/2.0 200 OK\nX-Stub: 1\r\n\r\n%s\n' "$body"
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

# ── The stdin routes never hang, whatever fd 0 is ────────────────────────────
# A closed fd 0 would make "$(cat)" read its own pipe; a terminal would wait for
# a human. Each case runs under a watchdog (exit 124 = it hung) so a regression
# fails the test instead of hanging the suite.
cat > "$SANDBOX/runfd.py" <<'PY'
import os, pty, subprocess, sys

mode, limit, errfile = sys.argv[1], float(sys.argv[2]), sys.argv[3]
cmd = sys.argv[4:]
kw, feed, master = {}, None, None
if mode == "closed":
    kw["preexec_fn"] = lambda: os.close(0)
elif mode == "tty":
    master, slave = pty.openpty()
    kw["stdin"] = slave
elif mode == "empty":
    kw["stdin"], feed = subprocess.PIPE, b""
elif mode == "spaces":
    kw["stdin"], feed = subprocess.PIPE, b"   \n \t \n"
else:
    sys.exit("bad mode")
with open(errfile, "wb") as err:
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=err, **kw)
    try:
        if feed is not None:
            p.stdin.write(feed)
            p.stdin.close()
        sys.exit(p.wait(timeout=limit))
    except subprocess.TimeoutExpired:
        p.kill()
        sys.exit(124)
PY
fd_run() { python3 "$SANDBOX/runfd.py" "$1" 20 "$SANDBOX/fd.err" "${@:2}"; }

cat > talos.pipeline.json <<EOF
{"notifications": {"cmd": "cat > $CMD_OUT", "cmd_timeout_s": 5}}
EOF
for mode in closed tty empty spaces; do
  rm -f "$CMD_OUT"
  fd_run "$mode" bash "$NOTIFY" qa "#42" - 42; rc=$?
  assert_eq "0" "$rc" "notify - with $mode stdin: exits 0, no hang"
  case "$mode" in
    closed|tty)
      assert_contains "$(cat "$SANDBOX/fd.err")" "stdin is closed or a terminal" "notify - with $mode stdin: one stderr line says why"
      assert_file_absent "$CMD_OUT" "notify - with $mode stdin: nothing was sent" ;;
  esac
done
rm -f talos.pipeline.json
for verb in comment-issue approve-pr; do
  for mode in closed tty empty spaces; do
    rm -f "$GH_BODY_OUT"
    PATH="$FAKE:$PATH" fd_run "$mode" bash "$VCS" "$verb" 5 --body-file -; rc=$?
    case "$mode" in
      closed|tty)
        assert_eq "1" "$rc" "$verb --body-file - with $mode stdin: exits 1, no hang"
        assert_contains "$(cat "$SANDBOX/fd.err")" "stdin is closed or a terminal" "$verb --body-file - with $mode stdin: one stderr line says why"
        assert_eq "1" "$(wc -l < "$SANDBOX/fd.err" | tr -d ' ')" "$verb --body-file - with $mode stdin: that is a single line"
        assert_file_absent "$GH_BODY_OUT" "$verb --body-file - with $mode stdin: nothing reached the provider" ;;
      *)
        [ "$rc" -ne 124 ]; assert_eq "0" "$?" "$verb --body-file - with $mode stdin: does not hang (rc=$rc)" ;;
    esac
  done
done

# ── Long messages: no "Argument list too long", no silent drop (#342) ────────
# Linux fails an exec when ONE environment/argv string exceeds 128 KiB; macOS
# does not, so this only fails on Linux unless the script caps the message
# before it reaches any python helper or curl. A message over 16384 bytes is
# cut (never inside a character), marked, announced on stderr, and still sent.
cat > talos.pipeline.json <<EOF
{"notifications": {"cmd": "cat > $CMD_OUT", "cmd_timeout_s": 5}}
EOF
msg_len() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["message"].encode()))' "$CMD_OUT"; }
python3 -c 'import sys; sys.stdout.write("see PR #12 " + "x" * 200000 + "\n")' > "$SANDBOX/big.txt"
rm -f "$CMD_OUT"
bash "$NOTIFY" qa "#42" - 42 < "$SANDBOX/big.txt" >/dev/null 2>"$SANDBOX/big.err"; rc=$?
assert_eq "0" "$rc" "notify - with a 200 KB message: exits 0"
assert_eq "pipeline-notify: message was 200011 bytes; truncated to at most 16384 bytes" "$(cat "$SANDBOX/big.err")" "notify - with a 200 KB message: stderr is exactly the one truncation line (no Broken pipe, no Argument list too long)"
assert_file_exists "$CMD_OUT" "notify - with a 200 KB message: something WAS sent"
assert_contains "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"])' "$CMD_OUT")" "[message truncated to 16384 bytes]" "notify - with a 200 KB message: the delivered message says it was truncated"
[ "$(msg_len)" -le 17500 ] && [ "$(msg_len)" -ge 16384 ]; assert_eq "0" "$?" "notify - with a 200 KB message: the delivered message is cut to the cap ($(msg_len) bytes)"
# The argv form is capped the same way (one place, before any exec).
rm -f "$CMD_OUT"
bash "$NOTIFY" qa "#42" "$(python3 -c 'print("y" * 100000)')" 42 >/dev/null 2>"$SANDBOX/big.err"
assert_contains "$(cat "$SANDBOX/big.err")" "truncated to at most 16384 bytes" "notify with a 100 KB argv message: truncated and announced"
assert_file_exists "$CMD_OUT" "notify with a 100 KB argv message: still sent"
# Multi-byte text: the cut never splits a character, so the payload stays valid UTF-8.
python3 -c 'import sys; sys.stdout.write("€" * 20000 + "\n")' > "$SANDBOX/euro.txt"
rm -f "$CMD_OUT"
bash "$NOTIFY" qa "#42" - 42 < "$SANDBOX/euro.txt" >/dev/null 2>"$SANDBOX/big.err"
assert_eq "1" "$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["message"]; n=m.count("\u20ac"); print(int(0 < 16384 - n * 3 < 4 and "\u20ac\n[message truncated" in m))' "$CMD_OUT" 2>/dev/null)" "notify - multi-byte message: cut on a character boundary (whole characters only, within 3 bytes of the cap), valid UTF-8"
# Under the cap: untouched, silent.
python3 -c 'import sys; sys.stdout.write("z" * 10000 + "\n")' > "$SANDBOX/mid.txt"
rm -f "$CMD_OUT"
bash "$NOTIFY" qa "#42" - 42 < "$SANDBOX/mid.txt" >/dev/null 2>"$SANDBOX/big.err"
assert_eq "" "$(cat "$SANDBOX/big.err")" "notify - a 10 KB message: stderr is empty"
assert_contains "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"])' "$CMD_OUT")" "$(python3 -c 'print("z" * 10000)')" "notify - a 10 KB message: delivered whole"
rm -f talos.pipeline.json

# ── The vcs stdin verbs with a body above 128 KB, and just under the caps ────
# GitHub's own comment limit is 65536 characters; Linux's per-argument limit is
# 128 KiB. A 200 KB body is refused up front (exit 1, one line, nothing
# posted, no exec of gh); 50000 three-byte characters are under GitHub's
# character limit but over the byte cap, so they are refused on bytes; 60000
# ASCII characters are delivered whole.
python3 -c 'import sys; sys.stdout.write("w" * 200000 + "\n")' > "$SANDBOX/b200k.txt"
python3 -c 'import sys; sys.stdout.write("€" * 50000 + "\n")' > "$SANDBOX/bcjk.txt"
python3 -c 'import sys; sys.stdout.write("v" * 60000 + "\n")' > "$SANDBOX/b60k.txt"
for verb in comment-issue comment-pr approve-pr close-issue; do
  for size in b200k bcjk; do
    rm -f "$GH_BODY_OUT"
    PATH="$FAKE:$PATH" bash "$VCS" "$verb" 5 --body-file - < "$SANDBOX/$size.txt" >/dev/null 2>"$SANDBOX/big.err"; rc=$?
    assert_eq "1" "$rc" "$verb --body-file - with $size: refused, exit 1"
    assert_contains "$(cat "$SANDBOX/big.err")" "nothing posted" "$verb --body-file - with $size: the refusal says nothing was posted"
    assert_not_contains "$(cat "$SANDBOX/big.err")" "Argument list too long" "$verb --body-file - with $size: no exec failure"
    assert_file_absent "$GH_BODY_OUT" "$verb --body-file - with $size: the provider was never called"
  done
  rm -f "$GH_BODY_OUT"
  PATH="$FAKE:$PATH" bash "$VCS" "$verb" 5 --body-file - < "$SANDBOX/b60k.txt" >/dev/null 2>"$SANDBOX/big.err"; rc=$?
  assert_eq "0" "$rc" "$verb --body-file - with 60000 characters: exits 0"
  assert_eq "$(python3 -c 'print("v" * 60000)')" "$(cat "$GH_BODY_OUT" 2>/dev/null)" "$verb --body-file - with 60000 characters: delivered whole"
done

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
    return re.sub(r"<[A-Za-z][^<>\n]*>", "x", line) if not re.search(r"python3 (-I )?-c", line) else line


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
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-agent.sh pipeline-hooks.sh; do
  cat > "$STUBROOT/scripts/$s" <<'STUB'
#!/usr/bin/env bash
# Counter-named, so the order of calls is the order they were made.
base="$REC/call.$(printf '%03d' "$(( $(ls "$REC" | grep -c '\.argv$') + 1 ))")"
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
# call_of <name>: the first recorded call whose script or verb is <name>, found
# by content, never by position or directory order.
call_of() {
  python3 - "$REC" "$1" <<'PYC'
import glob, sys
for f in sorted(glob.glob(sys.argv[1] + "/call.*.argv")):
    argv = open(f, "rb").read().decode().split("\0")[:-1]
    if sys.argv[2] in argv[:2]:
        print(f[:-len(".argv")])
        break
PYC
}
run_recipe() {  # $1=md $2...=needles; leaves the script in $SANDBOX/r.sh, runs it, resets $REC
  local md="$1"; shift
  rm -rf "${REC:?}"/* "${SANDBOX:?}/r.sh.bodies"
  python3 "$SANDBOX/recipe.py" "$SANDBOX/r.sh" "$BODY" "$md" "$@" || return 99
  (cd "$STUBROOT" && bash "$SANDBOX/r.sh" </dev/null >"$SANDBOX/r.out" 2>"$SANDBOX/r.err"); return $?
}

# ── agents/pm.md: comment-issue <N> --body-file - ────────────────────────────
run_recipe "$TALOS_ROOT/agents/pm.md" 'comment-issue <N> --body-file -'; rc=$?
assert_eq "0" "$rc" "pm.md recipe: runs ($(head -c 200 "$SANDBOX/r.err"))"
c="$(call_of comment-issue)"
assert_eq "pipeline-vcs.sh|comment-issue|7|--body-file|-" "$(argv_of "$c.argv")" "pm.md recipe: the spec goes in via --body-file -"
assert_eq "$(cat "$SANDBOX/r.sh.bodies/1")" "$(cat "$c.stdin")" "pm.md recipe: the stub received the spec byte for byte (hostile body + trailing newline)"
cmp -s "$SANDBOX/r.sh.bodies/1" "$c.stdin"; assert_eq "0" "$?" "pm.md recipe: byte-identical, trailing newline included (cmp)"
assert_no_pwned "pm.md recipe"

# ── agents/developer.md: mktemp body file + title heredoc + create-pr ────────
run_recipe "$TALOS_ROOT/agents/developer.md" 'create-pr <branch>'; rc=$?
assert_eq "0" "$rc" "developer.md recipe: runs ($(head -c 200 "$SANDBOX/r.err"))"
c="$(call_of create-pr)"
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
c="$(call_of approve-pr)"
assert_eq "pipeline-vcs.sh|approve-pr|8|--body-file|-" "$(argv_of "$c.argv")" "reviewer.md recipe: the summary goes in via --body-file -"
cmp -s "$SANDBOX/r.sh.bodies/1" "$c.stdin"; assert_eq "0" "$?" "reviewer.md recipe: the stub received the summary byte for byte"
assert_no_pwned "reviewer.md recipe"

# ── skills/pipeline/refs/comments.md: the stage-comment rendering recipe ─────────────
# SUMMARY and DETAILS are read -r -d '' variables (the BLOCKED_BY shape). The
# variable form trims surrounding whitespace, so the comment holds each body
# without its trailing newline.
run_recipe "$TALOS_ROOT/skills/pipeline/refs/comments.md" 'TMPL="<TMPL_DIR>'; rc=$?
assert_eq "0" "$rc" "playbook rendering recipe: runs ($(head -c 200 "$SANDBOX/r.err"))"
posted="$(argv_of "$(call_of comment-issue).argv")"
assert_contains "$posted" "comment-issue|7|**Agent:** test (talos)" "playbook rendering recipe: the comment is rendered and posted"
python3 - "$(call_of comment-issue).argv" "$SANDBOX/r.sh.bodies/1" "$SANDBOX/r.sh.bodies/2" <<'PY'
import sys
argv = open(sys.argv[1], "rb").read().decode().split("\0")[:-1]
body = argv[3]
want = [open(p, encoding="utf-8").read().strip() for p in sys.argv[2:4]]
sys.exit(0 if all(w in body for w in want) else 1)
PY
assert_eq "0" "$?" "playbook rendering recipe: SUMMARY and DETAILS each reach the comment byte for byte (trimmed)"
assert_no_pwned "playbook rendering recipe"

# ── skills/pipeline/SKILL.md Rule 2: `talos.sh done` and the stage summary ───
# The relay (`pipeline-notify.sh <role> "#<N>" - <N>`) and the role's post_stage event
# moved out of the playbook into `talos.sh done` (#469). The summary reaches the verb in
# a file (or stdin) and its consumers as stdin and a file, never as an argument: the
# hostile body arrives byte for byte, and one call is one relay and one event.
DS="$SANDBOX/done-scripts"
mkdir -p "$DS"
cp "$TALOS_ROOT"/scripts/* "$DS/"
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-status.sh pipeline-events.sh; do
  cp "$STUBROOT/scripts/pipeline-vcs.sh" "$DS/$s"
done
done_run() {  # $1=stdin source ($BODY or /dev/null) $2...=args of `done`
  local in="$1"; shift
  rm -rf "${REC:?}"/*
  (cd "$STUBROOT" && bash "$DS/talos.sh" done "$@" <"$in" >"$SANDBOX/done.out" 2>"$SANDBOX/done.err"); return $?
}
done_run /dev/null qa --issue 7 --pr 8 --verdict PASS --summary-file "$BODY"; rc=$?
assert_eq "0" "$rc" "talos.sh done: runs ($(head -c 200 "$SANDBOX/done.err"))"
c="$(call_of pipeline-notify.sh)"
assert_eq 'pipeline-notify.sh|qa|#7|-|7' "$(argv_of "$c.argv")" "talos.sh done: the relay is ONE command, the message passed as -"
cmp -s "$BODY" "$c.stdin"; assert_eq "0" "$?" "talos.sh done: the relay stub received the summary byte for byte (cmp, trailing newline included)"
c="$(call_of pipeline-hooks.sh)"
assert_contains "$(argv_of "$c.argv")" 'pipeline-hooks.sh|post_stage|qa|qa|7|--pr|8|--verdict|PASS|--summary-file|' "talos.sh done: post_stage gets the summary by --summary-file, never as an argument"
cmp -s "$BODY" "$c.file"; assert_eq "0" "$?" "talos.sh done: the hook stub read the summary file byte for byte"
all_argv=""
for f in "$REC"/call.*.argv; do all_argv="$all_argv$(argv_of "$f")"$'\n'; done
assert_not_contains "$all_argv" "touch" "talos.sh done: no call carries the summary text on its command line"
assert_eq "1" "$(grep -c '^pipeline-notify.sh|' <<< "$all_argv")" "talos.sh done: one stage return is one relay"
assert_eq "1" "$(grep -c '^pipeline-hooks.sh|post_stage|' <<< "$all_argv")" "talos.sh done: one stage return is one post_stage"
assert_no_pwned "talos.sh done (file)"
done_run "$BODY" qa --issue 7 --pr 8 --verdict PASS --summary-file -; rc=$?
assert_eq "0" "$rc" "talos.sh done --summary-file -: runs ($(head -c 200 "$SANDBOX/done.err"))"
c="$(call_of pipeline-notify.sh)"
cmp -s "$BODY" "$c.stdin"; assert_eq "0" "$?" "talos.sh done --summary-file -: the relay stub received the stdin summary byte for byte"
assert_no_pwned "talos.sh done (stdin)"

# ── skills/pipeline/refs/planner.md: sub-issue body + title + create-issue ──────────
run_recipe "$TALOS_ROOT/skills/pipeline/refs/planner.md" 'BODY_FILE="$(mktemp)"' 'create-issue "$SUB_TITLE" "$BODY_FILE" \
  --label pipeline:ready'; rc=$?
assert_eq "0" "$rc" "playbook sub-issue recipe: runs ($(head -c 200 "$SANDBOX/r.err"))"
c="$(call_of create-issue)"
argv="$(argv_of "$c.argv")"
assert_contains "$argv" "pipeline-vcs.sh|create-issue|first line|" "playbook sub-issue recipe: the title is one argument"
cmp -s "$SANDBOX/r.sh.bodies/1" "$c.file"; assert_eq "0" "$?" "playbook sub-issue recipe: the body file is byte-identical to the hostile body"
assert_no_pwned "playbook sub-issue recipe"

# ── skills/pipeline/refs/harness.md: the adapter prompt ─────────────────────────────
# The prompt text reaches the runner from a file (#468): `talos.sh prompt` writes the
# hostile prior summary into it as data (it is read from a file and never evaluated),
# and the playbook's adapter recipe pipes that file to the runner on stdin.
PF_OUT="$(bash "$TALOS_ROOT/scripts/talos.sh" prompt developer --issue 7 --prior-file "$BODY")"
export PROMPT_FILE="${PF_OUT#prompt_file=}"
assert_file_exists "$PROMPT_FILE" "the prompt verb rendered the hostile prior summary into a file"
assert_no_pwned "the prompt verb"
run_recipe "$TALOS_ROOT/skills/pipeline/refs/harness.md" 'pipeline-agent.sh <role> - < "$PROMPT_FILE"'; rc=$?
assert_eq "0" "$rc" "playbook adapter-prompt recipe: runs"
c="$(call_of pipeline-agent.sh)"
cmp -s "$PROMPT_FILE" "$c.stdin"; assert_eq "0" "$?" "playbook adapter-prompt recipe: the stub received the prompt byte for byte"
python3 -I -c 'import sys; b = open(sys.argv[1], encoding="utf-8").read().rstrip("\n"); p = open(sys.argv[2], encoding="utf-8").read(); sys.exit(0 if b in p else 1)' "$BODY" "$c.stdin"
assert_eq "0" "$?" "playbook adapter-prompt recipe: the prompt carries the hostile summary verbatim"
assert_no_pwned "playbook adapter-prompt recipe"
rm -f "${PROMPT_FILE:?}"
unset PROMPT_FILE

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
