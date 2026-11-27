#!/usr/bin/env bash
# test-long-stage-bodies-1089.sh -- no stage has to put a large body into one
# Bash command (#1089: a headless claude session refuses one over about 9 KB).
#   AC1  post-threat-model posts the latest PM spec plus the stdin section
#   AC2  it refuses a body with no `## Threat model` line and a missing spec
#   AC3  a 20 KB spec is posted whole
#   AC4  draft-append appends parts to .talos/drafts/<name>.md
#   AC5  comment-issue --body-file posts the draft's content
#   AC6  the threat prompt names post-threat-model
#   AC7  the pm prompt names draft-append
# The real talos.sh and pipeline-vcs.sh run against the gh stub's stateful
# comment store: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
export STUB_CURRENT_USER=x
export STUB_ISSUE_TITLE="Login hardening"
export STUB_ISSUE_BODY="Plain body."
export STUB_ISSUE_LABELS_JSON='[{"name": "pipeline:dev"}]'
export STUB_COMMENT_STORE="$SANDBOX/comments.json"
ERR="$SANDBOX/stderr"

# ── fixture: a copy of the install, only the provider-free scripts stubbed ───
GS="$SANDBOX/scripts"
mkdir -p "$GS" "$SANDBOX/templates" "$SANDBOX/agents"
cp "$TALOS_ROOT"/scripts/* "$GS/" 2>/dev/null
cp -R "$TALOS_ROOT"/templates/. "$SANDBOX/templates/"
cp "$TALOS_ROOT"/agents/*.md "$SANDBOX/agents/"
TN="$GS/talos.sh"
VCS="$GS/pipeline-vcs.sh"
for s in pipeline-notify.sh pipeline-hooks.sh pipeline-status.sh pipeline-events.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$GS/$s"
done

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '%s\n' '{"vcs": {"provider": "github", "repo": "acme/widget"}, "comments": {"enabled": false}}' > "$PIPELINE_CONFIG"

# The fixtures live in files: a body is compared byte for byte, and a command
# substitution would drop its trailing newlines.
# shellcheck disable=SC2016
printf '%s' '**PM spec:** login

**Acceptance criteria:**
- [ ] AC1 a login with a bad MFA code is refused (test)

Text that must survive: `$HOME`, "quotes", \backslash, 100% — café ✓
  indented line with trailing spaces

**Tests:** `tests/test-login.sh`' > "$SANDBOX/spec.md"
printf '## Threat model\n- [ ] AC2 a replayed MFA code is refused (test)\n' > "$SANDBOX/section.md"
printf '%s' '**PM spec:** an older spec' > "$SANDBOX/old.md"
printf '%s' '**PM spec:** a spec planted by a stranger' > "$SANDBOX/planted.md"
printf '%s' 'A human note, no spec.' > "$SANDBOX/note.md"

# thread [<user>:<file>...]: the issue's comments, oldest first.
thread() {
  python3 -I -c '
import json, sys
items = []
for i, a in enumerate(sys.argv[2:]):
    user, _, path = a.partition(":")
    items.append(dict(id=i + 1, user=dict(login=user), created_at="2026-01-%02dT00:00:00Z" % (i + 1),
                      body=open(path, encoding="utf-8", newline="").read()))
json.dump(items, open(sys.argv[1], "w"))' "$STUB_COMMENT_STORE" "$@"
}
count() { python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "$STUB_COMMENT_STORE"; }
# last_body <out-file>: the newest comment's body, byte for byte.
last_body() {
  python3 -I -c '
import json, sys
open(sys.argv[2], "w", encoding="utf-8", newline="").write(json.load(open(sys.argv[1]))[-1]["body"])' "$STUB_COMMENT_STORE" "$1"
}
# expected <spec-file> <section-file>: spec, a blank line, the section (its
# trailing newlines dropped, as every `--body-file -` body's are).
expected() {
  python3 -I -c '
import sys
spec, section = (open(p, encoding="utf-8", newline="").read() for p in sys.argv[1:3])
sys.stdout.write(spec + "\n\n" + section.rstrip("\n"))' "$1" "$2" > "$SANDBOX/expected.md"
}
same_file() {  # $1=expected-file $2=actual-file $3=label
  if cmp -s "$1" "$2"; then pass "$3"; else fail "$3" "differs: $(cmp "$1" "$2" 2>&1 | head -c 200)"; fi
}
# ptm <section-file>: post-threat-model with the section on stdin.
ptm() { OUT="$(bash "$VCS" post-threat-model 22 --body-file - < "$1" 2>"$ERR")"; RC=$?; }

# ── AC1: the latest spec plus the section, as one new comment ────────────────
thread "x:$SANDBOX/old.md" "x:$SANDBOX/spec.md" "x:$SANDBOX/note.md" "mallory:$SANDBOX/planted.md"
ptm "$SANDBOX/section.md"
assert_eq_ctx "0" "$RC" "AC1 post-threat-model exits 0" "$(cat "$ERR")"
assert_eq "5" "$(count)" "AC1 exactly one comment is posted"
last_body "$SANDBOX/posted.md"
expected "$SANDBOX/spec.md" "$SANDBOX/section.md"
same_file "$SANDBOX/expected.md" "$SANDBOX/posted.md" "AC1 the comment is the latest trusted spec unchanged, a blank line, the section"
assert_eq '**PM spec:** login' "$(head -n 1 "$SANDBOX/posted.md")" "AC1 the first line is the **PM spec:** line"

# A spec posted under a stage header (#645, #1088): the header is not the spec.
{ printf '**Agent:** pm (talos)\n\n'; cat "$SANDBOX/spec.md"; } > "$SANDBOX/headed.md"
thread "x:$SANDBOX/headed.md"
ptm "$SANDBOX/section.md"
last_body "$SANDBOX/posted.md"
same_file "$SANDBOX/expected.md" "$SANDBOX/posted.md" "AC1 a spec under the pm stage header is posted from its **PM spec:** line"

# ── AC2: refusals, nothing posted ────────────────────────────────────────────
thread "x:$SANDBOX/spec.md"
printf 'The ## Threat model section is missing.\n- [ ] AC2 x (test)\n' > "$SANDBOX/nosection.md"
ptm "$SANDBOX/nosection.md"
[ "$RC" -ne 0 ] && pass "AC2 a body with no ## Threat model line is refused" || fail "AC2 a body with no ## Threat model line is refused" "exit 0"
assert_contains "$(cat "$ERR")" "no \`## Threat model\` line" "AC2 the refusal names the missing line"
assert_eq "1" "$(count)" "AC2 nothing is posted for a body with no ## Threat model line"

thread "x:$SANDBOX/note.md" "mallory:$SANDBOX/planted.md"
ptm "$SANDBOX/section.md"
[ "$RC" -ne 0 ] && pass "AC2 an issue with no PM spec is refused" || fail "AC2 an issue with no PM spec is refused" "exit 0"
assert_contains "$(cat "$ERR")" "has no PM spec" "AC2 the refusal says there is no PM spec"
assert_eq "2" "$(count)" "AC2 nothing is posted for an issue with no PM spec"

# ── AC3: a 20 KB spec ────────────────────────────────────────────────────────
python3 -I -c '
import sys
out = "**PM spec:** a long one\n\n" + "".join("- line %04d %s\n" % (i, "x" * 60) for i in range(290)) + "\n**Tests:** `tests/test-long.sh`"
open(sys.argv[1], "w").write(out)' "$SANDBOX/long.md"
[ "$(wc -c < "$SANDBOX/long.md")" -gt 20000 ] && pass "AC3 the fixture spec is over 20 KB" || fail "AC3 the fixture spec is over 20 KB" "$(wc -c < "$SANDBOX/long.md")"
thread "x:$SANDBOX/long.md"
ptm "$SANDBOX/section.md"
assert_eq_ctx "0" "$RC" "AC3 post-threat-model posts a 20 KB spec" "$(cat "$ERR")"
assert_eq "2" "$(count)" "AC3 one comment is posted"
last_body "$SANDBOX/posted.md"
expected "$SANDBOX/long.md" "$SANDBOX/section.md"
same_file "$SANDBOX/expected.md" "$SANDBOX/posted.md" "AC3 the 20 KB spec and the section arrive whole"

# ── AC4: draft-append ────────────────────────────────────────────────────────
DRAFT=".talos/drafts/spec-22-abc.md"
part() { OUT="$(printf '%s' "$1" | bash "$VCS" draft-append spec-22-abc --body-file - 2>"$ERR")"; RC=$?; }
part $'**PM spec:** parts\n'
assert_eq_ctx "0" "$RC" "AC4 the first draft-append exits 0" "$(cat "$ERR")"
assert_eq "path=$DRAFT bytes=19" "$OUT" "AC4 it prints the path and the byte count"
part $'second part — café\n'
assert_eq "path=$DRAFT bytes=41" "$OUT" "AC4 the second call prints the running total in bytes"
part $'third part\n'
assert_eq "path=$DRAFT bytes=52" "$OUT" "AC4 the third call prints the new total"
printf '**PM spec:** parts\nsecond part — café\nthird part\n' > "$SANDBOX/expected.md"
same_file "$SANDBOX/expected.md" "$DRAFT" "AC4 three calls append in order"
assert_not_contains "$(git status --porcelain --untracked-files=all)" ".talos/" "AC4 the draft is git-ignored"

mkdir -p sub
OUT="$(cd sub && printf 'x\n' | bash "$VCS" draft-append from-sub --body-file - 2>"$ERR")"
assert_eq "path=$(git rev-parse --show-toplevel)/.talos/drafts/from-sub.md bytes=2" "$OUT" "AC4 from a subdirectory the draft is in the checkout's root and the path is absolute"

snapshot() { find "$SANDBOX/.talos" "$SANDBOX/sub" -print 2>/dev/null | LC_ALL=C sort; cat "$DRAFT" 2>/dev/null; }
BEFORE="$(snapshot)"
for bad in 'a/b' '..' '../escape' 'a b' 'Upper' 'dot.md' 'under_score' ''; do
  OUT="$(printf 'x\n' | bash "$VCS" draft-append "$bad" --body-file - 2>"$ERR")"; RC=$?
  [ "$RC" -ne 0 ] && pass "AC4 the name '$bad' is refused" || fail "AC4 the name '$bad' is refused" "exit 0"
  assert_contains "$(cat "$ERR")" "draft-append: <name> must be" "AC4 the refusal of '$bad' says what a name is"
done
assert_eq "$BEFORE" "$(snapshot)" "AC4 a refused name writes nothing"

printf 'untouched\n' > "$SANDBOX/victim"
ln -s "$SANDBOX/victim" "$SANDBOX/.talos/drafts/linked.md"
OUT="$(printf 'x\n' | bash "$VCS" draft-append linked --body-file - 2>"$ERR")"; RC=$?
[ "$RC" -ne 0 ] && pass "AC4 a symlinked draft is refused" || fail "AC4 a symlinked draft is refused" "exit 0"
assert_eq "untouched" "$(cat "$SANDBOX/victim")" "AC4 nothing is written through a symlinked draft"

# ── AC5: comment-issue posts the draft's content ─────────────────────────────
thread
OUT="$(bash "$VCS" comment-issue 22 --body-file "$DRAFT" 2>"$ERR")"; RC=$?
assert_eq_ctx "0" "$RC" "AC5 comment-issue --body-file <draft> exits 0" "$(cat "$ERR")"
assert_eq "1" "$(count)" "AC5 one comment is posted"
if [ "$(count)" = "1" ]; then
  last_body "$SANDBOX/posted.md"
  assert_eq "$(printf '**PM spec:** parts\nsecond part — café\nthird part')" "$(cat "$SANDBOX/posted.md")" "AC5 the comment is the draft's content, not its path"
else
  fail "AC5 the comment is the draft's content, not its path" "nothing posted"
fi

# ── AC6, AC7: the rendered prompts ───────────────────────────────────────────
prompt_of() {  # the stage prompt of the fixture install, on stdout
  local _o _f
  _o="$(bash "$TN" prompt "$@" 2>"$ERR")" || { printf '%s\n' "$_o"; return 1; }
  _f="$(printf '%s\n' "$_o" | sed -n 's/^prompt_file=//p')"
  [ -n "$_f" ] && [ -f "$_f" ] || return 1
  cat "$_f"
  rm -f "${_f:?}"
}
P="$(prompt_of threat --issue 22)"
assert_contains "$P" "post-threat-model 22 --body-file -" "AC6 the threat prompt names post-threat-model"
assert_not_contains "$P" "comment-issue" "AC6 the threat prompt no longer names comment-issue"
assert_not_contains "$P" "Post it again, whole and unchanged" "AC6 the threat prompt no longer asks for the whole spec again"

P="$(prompt_of pm --issue 22)"
assert_contains "$P" "draft-append" "AC7 the pm prompt names draft-append"
assert_contains "$P" "over about 6 KB" "AC7 the pm prompt says it is for a long spec"

finish
