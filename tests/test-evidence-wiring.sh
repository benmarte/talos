#!/usr/bin/env bash
# test-evidence-wiring.sh -- covers issue #410 (sub-task of epic #352): the
# evidence capture is wired into the pipeline, strictly opt-in.
#   1. `pipeline-evidence.sh enabled` (Step 0): exit code, stdout and stderr for
#      unset / false / unsupported provider / gh without --attach / on.
#   2. The per-file cap is ONE constant, handed to both embedded pythons.
#   3. `attach` when capture itself fails to run reports capture=<n>.
#   4. skills/pipeline/SKILL.md and agents/qa.md: every new line sits inside an
#      `<!-- evidence:start -->` / `<!-- evidence:end -->` block; with the blocks
#      stripped agents/qa.md equals tests/fixtures/agents-qa-default.md (main's
#      text, copied verbatim before the change; the SKILL.md default text is
#      proven by test-draft-stage-order.sh's fixtures); no evidence verb appears
#      outside a block; the QA wording the acceptance criteria pin.
#   5. A sandbox walk: the fenced attach command from agents/qa.md, with its
#      placeholders filled in, runs against tests/stubs/gh and a stub
#      evidence.command: one attach call, one post, one status line; a second
#      round also deletes the older comment; `assert-sync` stays clean under
#      isolation: branch because the evidence dir is ignored.
# Everything runs against tests/stubs/gh (first on PATH): no real GitHub call,
# never a post to a real PR.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

EV="$TALOS_ROOT/scripts/pipeline-evidence.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
SKILL="$TALOS_ROOT/skills/pipeline/SKILL.md"
QA="$TALOS_ROOT/agents/qa.md"
QA_DEFAULT="$TALOS_ROOT/tests/fixtures/agents-qa-default.md"
assert_file_exists "$EV" "pipeline-evidence.sh exists"
assert_file_exists "$QA_DEFAULT" "the default qa.md fixture exists"

export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
use_stubs
export GH_STDIN_LOG="$SANDBOX/gh.stdin.log"
export STUB_ATTACH_LOG="$SANDBOX/attach.log"
export STUB_COMMENT_STORE="$SANDBOX/comments.json"
export STUB_CURRENT_USER="talosbot"

OUT="$SANDBOX/out.txt"
ERR="$SANDBOX/err.txt"
RC=0

# ---- helpers ----------------------------------------------------------------
# The command-mode capture script: 2 PNG + 1 WEBM into ev/ (run through
# `bash -c "bash <this>"` at the worktree toplevel). Lives outside the repo.
MKEV="$SANDBOX/mkev.sh"
cat > "$MKEV" <<'TALOS_MKEV_Hn4Zc8Rv2Qa'
mkdir -p ev
printf '\211PNG\r\n\032\nalpha' > ev/shot-a.png
printf '\211PNG\r\n\032\nbravo' > ev/shot-b.png
printf '\032\105\337\243\102\202\204webmclip' > ev/0-run.webm
TALOS_MKEV_Hn4Zc8Rv2Qa

new_repo() {   # new_repo <config-json> -- a repo whose ev/ dir is ignored
  REPO="$(mktemp -d "$SANDBOX/repo.XXXXXX")"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.name "talos test"
  git -C "$REPO" config user.email "test@talos.invalid"
  printf 'ev/\n' > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore
  git -C "$REPO" commit -q -m init
  mkdir -p "$REPO/ev"
  printf '%s\n' "$1" > "$REPO/talos.pipeline.json"
  cd "$REPO" || exit 1
}
reset() {
  : > "$GH_LOG"; : > "$CURL_LOG"; : > "$GH_STDIN_LOG"; : > "$STUB_ATTACH_LOG"
  printf '[]' > "$STUB_COMMENT_STORE"
  unset STUB_GH_ATTACH STUB_GH_VERSION STUB_COMMENT_DELETE_FAIL STUB_ATTACH_FAIL
  export STUB_CURRENT_USER="talosbot"
}
run() { "$@" >"$OUT" 2>"$ERR"; RC=$?; }
out() { cat "$OUT"; }
err() { cat "$ERR"; }
gh_log() { cat "$GH_LOG"; }
posts() { grep -c -- '--body-file' "$GH_LOG" || true; }
deletes() { grep -c -- '--method DELETE' "$GH_LOG" || true; }
lines() { wc -l < "$1" | tr -d ' '; }
# the cap constant, read from the script and never written here
FILE_MB="$(sed -n 's/^_EVIDENCE_FILE_MB=\([0-9][0-9]*\).*/\1/p' "$EV")"
case "$FILE_MB" in ''|*[!0-9]*) fail "the per-file cap constant is readable from the script"; FILE_MB=1 ;; esac

# =============================================================================
# 1. `enabled`
# =============================================================================
SENTINEL_CMD='touch SENTINEL'
for cfgtxt in \
  "{}" \
  "{\"evidence\": {\"command\": \"$SENTINEL_CMD\"}}" \
  "{\"evidence\": {\"enabled\": false, \"command\": \"$SENTINEL_CMD\"}}" \
  "{\"vcs\": {\"provider\": \"gitlab\"}, \"evidence\": {\"enabled\": false}}"; do
  new_repo "$cfgtxt"; reset
  run bash "$EV" enabled
  assert_eq "1" "$RC" "enabled [$cfgtxt]: exit 1"
  assert_eq "" "$(out)" "enabled [$cfgtxt]: empty stdout"
  assert_eq "" "$(err)" "enabled [$cfgtxt]: silent (no warning when evidence is not asked for)"
  assert_eq "" "$(gh_log)" "enabled [$cfgtxt]: no gh call"
  assert_file_absent "$REPO/SENTINEL" "enabled [$cfgtxt]: evidence.command did not run"
done

for prov in gitlab azure file; do
  new_repo "{\"vcs\": {\"provider\": \"$prov\"}, \"evidence\": {\"enabled\": true, \"command\": \"$SENTINEL_CMD\"}}"; reset
  run bash "$EV" enabled
  assert_eq "1" "$RC" "enabled provider $prov: exit 1"
  assert_eq "" "$(out)" "enabled provider $prov: empty stdout"
  assert_eq "pipeline: evidence ignored: provider '$prov' is not supported" "$(err)" "enabled provider $prov: one stderr line"
  assert_eq "" "$(gh_log)" "enabled provider $prov: no gh call"
  assert_file_absent "$REPO/SENTINEL" "enabled provider $prov: evidence.command did not run"
done

new_repo '{"evidence": {"enabled": true}}'; reset
export STUB_GH_ATTACH=0
run bash "$EV" enabled
assert_eq "1" "$RC" "enabled gh without --attach: exit 1"
assert_eq "" "$(out)" "enabled gh without --attach: empty stdout"
assert_eq "pipeline: evidence ignored: gh has no --attach (gh v2.99.0 or newer required)" "$(err)" "enabled gh without --attach: one stderr line"
assert_eq "pr comment --help" "$(gh_log)" "enabled gh without --attach: only the help probe ran"
unset STUB_GH_ATTACH

new_repo '{"evidence": {"enabled": true, "dir": "ev", "command": "bash x.sh"}}'; reset
run bash "$EV" enabled
assert_eq "0" "$RC" "enabled on (command): exit 0"
assert_eq "evidence on when=user-facing mode=command" "$(out)" "enabled on (command): exactly the one line, when defaults to user-facing"
assert_eq "" "$(err)" "enabled on (command): no stderr"
assert_eq "pr comment --help" "$(gh_log)" "enabled on: the only gh call is the help probe (no network)"
new_repo '{"evidence": {"enabled": true, "when": "always"}}'; reset
run bash "$EV" enabled
assert_eq "0" "$RC" "enabled on (agent): exit 0"
assert_eq "evidence on when=always mode=agent" "$(out)" "enabled on (agent): when=always, no evidence.command is mode=agent"
new_repo '{"vcs": {"provider": "github-api"}, "evidence": {"enabled": true, "command": "   "}}'; reset
run bash "$EV" enabled
assert_eq "evidence on when=user-facing mode=agent" "$(out)" "enabled on (github-api, blank command): mode=agent"
run bash "$EV" enabled extra
assert_eq "2" "$RC" "enabled: an argument is a usage error"
run bash "$EV" bogus
assert_eq "2" "$RC" "usage: an unknown subcommand still exits 2"
assert_contains "$(err)" "| enabled" "usage: the usage line lists enabled"

# =============================================================================
# 2. the per-file cap is one constant, passed to the embedded python
# =============================================================================
assert_eq "1" "$(grep -c '^_EVIDENCE_FILE_MB=' "$EV")" "cap: the constant is assigned exactly once"
assert_eq "0" "$(grep -cE 'FILE_CAP[A-Z_]*[[:space:]]*=[[:space:]]*[0-9]' "$EV" || true)" "cap: no python assignment of a cap literal (only the shell constant)"
# a copy of the scripts with the constant changed: collect and attach follow it
CP="$SANDBOX/scripts-copy"
mkdir -p "$CP"
cp "$TALOS_ROOT"/scripts/*.sh "$CP/"
sed 's/^_EVIDENCE_FILE_MB=[0-9][0-9]*/_EVIDENCE_FILE_MB=1/' "$EV" > "$CP/pipeline-evidence.sh"
new_repo '{"evidence": {"enabled": true, "dir": "ev", "max_mb": 100}}'; reset
python3 -I -c '
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n" + b"\0" * (2 * 1024 * 1024))' ev/big.png
run bash "$CP/pipeline-evidence.sh" collect ev
assert_eq "4" "$RC" "cap 1: a 2 MiB file is over the changed cap"
assert_contains "$(err)" "file-mb=2.00/1" "cap 1: the over-cap line carries the changed cap"
run bash "$CP/pipeline-evidence.sh" attach 7
assert_contains "$(out)" "status=over-cap" "cap 1: attach reports over-cap"
run bash "$EV" attach 7
assert_contains "$(out)" "status=posted" "cap $FILE_MB: the real script accepts the same file"
rm -f ev/big.png
printf '\211PNG\r\n\032\nsmall' > ev/small.png
run bash "$CP/pipeline-evidence.sh" attach 7
assert_contains "$(out)" "status=posted images=1" "cap 1: a small file still posts (the upload python got the changed cap as a number)"

# =============================================================================
# 3. attach: capture that fails to run is reported as capture=<its exit code>
# =============================================================================
REAL_MKTEMP="$(command -v mktemp)"
SHIM="$SANDBOX/shim"
mkdir -p "$SHIM"
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "$*" in *talos-evidence.XXXXXX*) exit 1 ;; esac\n'
  printf 'exec %s "$@"\n' "$REAL_MKTEMP"
} > "$SHIM/mktemp"
chmod +x "$SHIM/mktemp"
new_repo "{\"evidence\": {\"enabled\": true, \"dir\": \"ev\", \"command\": \"bash $MKEV\"}}"; reset
PATH="$SHIM:$PATH" run bash "$EV" attach 7
assert_eq "0" "$RC" "capture fails to run: attach still exits 0 (the upload went ahead)"
assert_eq "evidence-attach pr=7 status=empty images=0 videos=0 capture=1 comment=" "$(out)" "capture fails to run: capture=<capture's exit code>, no files because the command never ran"
assert_contains "$(err)" "cannot create the capture log" "capture fails to run: the reason is on stderr"
assert_file_absent "$REPO/ev/shot-a.png" "capture fails to run: evidence.command never ran"
assert_eq "0" "$(posts)" "capture fails to run: nothing posted"
# files left by something else are still uploaded: a failed capture never gates the upload
png_pre() { printf '\211PNG\r\n\032\nearlier' > "$1"; }
png_pre ev/earlier.png
PATH="$SHIM:$PATH" run bash "$EV" attach 7
assert_eq "evidence-attach pr=7 status=posted images=1 videos=0 capture=1 comment=https://github.com/acme/widget/pull/7#issuecomment-5001" "$(out)" "capture fails to run: the upload still ran, capture=1"

# =============================================================================
# 4. the playbook and the QA profile: structure
# =============================================================================
EV_START='<!-- evidence:start -->'
EV_END='<!-- evidence:end -->'
PD_START='<!-- pr-draft:start -->'
PD_END='<!-- pr-draft:end -->'

# strip_ev: the file with every evidence block (markers included) removed.
strip_ev() {
  awk -v s="$EV_START" -v e="$EV_END" '
    { t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t) }
    t == s { skip = 1; next }
    t == e { skip = 0; next }
    !skip' "$1"
}
# ev_text: only the lines inside evidence blocks.
ev_text() {
  awk -v s="$EV_START" -v e="$EV_END" '
    { t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t) }
    t == s { inb = 1; next }
    t == e { inb = 0; next }
    inb' "$1"
}
# markers_ok: evidence markers alternate, none nested, none open at the end, at
# least one block, none inside a code fence, and none opened or closed while a
# pr-draft block is open (the two kinds never overlap).
markers_ok() {
  awk -v s="$EV_START" -v e="$EV_END" -v ps="$PD_START" -v pe="$PD_END" '
    { t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t) }
    t ~ /^```/ { fence = !fence }
    t == ps { pd = 1 }
    t == pe { pd = 0 }
    t == s { if (open || fence || pd) bad = 1; open = 1; n++ }
    t == e { if (!open || fence || pd) bad = 1; open = 0 }
    END { exit (bad || open || n == 0) }' "$1"
}
# forbidden: lines of stdin that name an evidence verb or key.
forbidden() { grep -nE 'pipeline-evidence|EVIDENCE_|evidence-attach|evidence\.|Evidence:'; }
norm() { tr '\n' ' ' | tr -s ' '; }

for f in "$SKILL" "$QA"; do
  n="$(basename "$f")"
  markers_ok "$f" && pass "$n: evidence markers alternate, sit outside code fences and never overlap a pr-draft block" \
    || fail "$n: evidence markers alternate, sit outside code fences and never overlap a pr-draft block"
  assert_eq "" "$(strip_ev "$f" | forbidden)" "$n: no evidence verb or key outside an evidence block"
  [ -n "$(ev_text "$f" | forbidden)" ] && pass "$n: the evidence blocks do carry the wiring" || fail "$n: the evidence blocks do carry the wiring"
done

if [ "$(strip_ev "$QA")" = "$(cat "$QA_DEFAULT")" ]; then
  pass "qa.md: with the evidence blocks stripped it equals tests/fixtures/agents-qa-default.md (main's text)"
else
  fail "qa.md: with the evidence blocks stripped it equals tests/fixtures/agents-qa-default.md" \
    "$(diff <(cat "$QA_DEFAULT") <(strip_ev "$QA") | head -20)"
fi
[ -z "$(forbidden < "$QA_DEFAULT")" ] && pass "the default qa.md fixture names no evidence verb" || fail "the default qa.md fixture names no evidence verb"

# Step 1 and Step 4 carry no evidence text at all, inside a block or not
step1="$(awk '/^## Step 1 — /{p=1} /^## Step 2 — /{p=0} p' "$SKILL")"
step4="$(awk '/^## Step 4 — /{p=1} /^## Step 5 — /{p=0} p' "$SKILL")"
[ -n "$step1" ] && [ -n "$step4" ] && pass "Step 1 and Step 4 were extracted" || fail "Step 1 and Step 4 were extracted"
assert_eq "" "$(printf '%s\n' "$step1" | forbidden)" "Step 1 (reconcile): no evidence text, post-merge and sweep are not wired"
assert_eq "" "$(printf '%s\n' "$step4" | forbidden)" "Step 4 (merge): no evidence text"
assert_eq "" "$(printf '%s\n' "$step1" "$step4" | grep -iE 'remove-pr|sweep --keep' | grep -i evidence)" "Steps 1 and 4: no evidence remove-pr or sweep"

# ---- wording: QA profile ----------------------------------------------------
qa_ev="$(ev_text "$QA" | norm)"
has() { case "$qa_ev" in *"$1"*) pass "qa.md: $2" ;; *) fail "qa.md: $2" "missing: $1" ;; esac; }
has 'only when your prompt carries an `Evidence:` line' "acts only on an Evidence: line"
has 'A prompt without one (a re-stamp included) means no capture' "a re-stamp never re-captures"
has 'run `date +%s` now and keep the digits as `<epoch>`' "mode=agent notes the epoch"
has 'ONLY to an absolute path under `<worktree-path>/<dir>`' "agent screenshots go only to an absolute path under the worktree evidence dir"
has 'bash scripts/pipeline-evidence.sh dir' "the evidence dir comes from the dir verb"
has 'run it ONLY when EVERY criterion passed' "attach only when every criterion passed"
has 'evidence skipped: not user-facing' "the user-facing skip line"
has '`browser-testing-with-devtools`' "user-facing means the browser skill"
has 'It never changes PASS/FAIL, including under `when: always`' "never changes PASS/FAIL, including when: always"
has 'a non-zero capture rc and a tool timeout' "capture failure and timeout are named as never a FAIL"
has 'Never open, Read or describe an image or video file' "QA never opens an image or video"
has 'never fetch the comment body' "QA never fetches the comment"
has 'evidence unavailable' "exit 2 with no stdout is evidence unavailable"
has 'Decide from `status=` plus a non-empty `comment=`' "decides from status= and comment=, not the exit code"
has 'as the 3rd line of your final message' "the line is relayed as the 3rd final line"
# order in the file: epoch note before step 6; attach after step 7 and before Outcome:
qa_pos() { grep -n "$1" "$QA" | head -n 1 | cut -d: -f1; }
p_epoch="$(qa_pos 'run `date +%s` now')"; p_six="$(qa_pos '^6\. Exercise')"
p_seven="$(qa_pos '^7\. Look for missing')"; p_attach="$(qa_pos 'Evidence upload (#410')"; p_out="$(qa_pos '^Outcome:')"
if [ -n "$p_epoch" ] && [ -n "$p_six" ] && [ "$p_epoch" -lt "$p_six" ]; then pass "qa.md: the epoch note precedes step 6"; else fail "qa.md: the epoch note precedes step 6"; fi
if [ -n "$p_attach" ] && [ -n "$p_seven" ] && [ -n "$p_out" ] && [ "$p_seven" -lt "$p_attach" ] && [ "$p_attach" -lt "$p_out" ]; then
  pass "qa.md: attach follows step 7 and precedes Outcome:"
else fail "qa.md: attach follows step 7 and precedes Outcome:"; fi

# ---- wording: the playbook --------------------------------------------------
sk_ev="$(ev_text "$SKILL" | norm)"
shas() { case "$sk_ev" in *"$1"*) pass "SKILL.md: $2" ;; *) fail "SKILL.md: $2" "missing: $1" ;; esac; }
shas 'EVIDENCE_LINE="$(bash scripts/pipeline-evidence.sh enabled)"; EVIDENCE_RC=$?' "Step 0 is one enabled call"
shas 'EVIDENCE_ENABLED is true only when `EVIDENCE_RC` is 0' "EVIDENCE_ENABLED comes from the exit code"
shas 'pipeline: evidence ignored: <reason>' "the unsupported-provider warning is relayed once"
shas '`evidence.enabled`: false' "the default is documented"
shas 'right after `Prior stage summary:`: `Evidence: <EVIDENCE_LINE>`' "QA prompt: the Evidence: line after Prior stage summary"
shas 'A re-stamp dispatch (Step 3e and Step 4, "prompt inputs only") never does' "re-stamp dispatches never get the line"
shas "never changes PASS/FAIL" "the playbook says the line never changes PASS/FAIL"
shas "'^https://[^[:space:]]+#issuecomment-[0-9]+\$'" "reviewer: the URL is validated by regex"
shas 'with a heredoc whose delimiter is `TALOS_<rand>`' "reviewer: the subagent-authored URL is assigned through a TALOS_<rand> heredoc"
shas 'do not fetch, open or Read it' "reviewer: the line tells it not to fetch the link"
shas '`PR_DRAFT = true`, where this stage runs BEFORE QA so there is no link yet' "reviewer: the line is omitted under PR_DRAFT"
shas 'Security, docs and adversarial never get the line' "only the reviewer gets the link"
# no Claude-only tool is named in any new line
assert_eq "" "$( { ev_text "$SKILL"; ev_text "$QA"; } | grep -E '`(Skill|Agent|Task|Read)` tool|\bSkill tool\b|Agent tool' )" "no Claude-only tool is named in an evidence block"
# the evidence blocks come after the prompt fences they extend, so no marker is ever sent to a subagent
for pat in 'Final message (2-3 lines): PASS/FAIL' 'Final (2-3 lines): APPROVED/CHANGES'; do
  ok="$(awk -v pat="$pat" -v s="$EV_START" '
    index($0, pat) { seen = 1; next }
    seen && !closed && /^```[[:space:]]*$/ { closed = 1; next }
    closed && NF { print (index($0, s) ? "after" : "no"); exit }' "$SKILL")"
  [ "$ok" = after ] && pass "SKILL.md: the evidence block follows the prompt fence ($pat)" || fail "SKILL.md: the evidence block follows the prompt fence ($pat)"
done

# =============================================================================
# 5. sandbox walk: the fenced attach command from qa.md, placeholders filled in
# =============================================================================
fenced_cmd() {   # fenced_cmd <regex> -- the one fenced line of an evidence block matching it
  ev_text "$QA" | grep -E "$1" | head -n 1 | sed 's/^[[:space:]]*//'
}
CMD_TPL="$(fenced_cmd 'pipeline-verify.sh --issue <issue-n> --worktree <worktree-path> -- bash scripts/pipeline-evidence.sh attach <pr>$')"
AGENT_TPL="$(fenced_cmd '^[[:space:]]*bash scripts/pipeline-evidence.sh attach <pr> --since <epoch>$')"
[ -n "$CMD_TPL" ] && pass "walk: the mode=command attach line was found in qa.md" || fail "walk: the mode=command attach line was found in qa.md"
[ -n "$AGENT_TPL" ] && pass "walk: the mode=agent attach line was found in qa.md" || fail "walk: the mode=agent attach line was found in qa.md"
assert_eq "1" "$(ev_text "$QA" | grep -c 'pipeline-evidence.sh attach <pr>$')" "walk: exactly one mode=command attach call in the profile"
assert_eq "2" "$(ev_text "$QA" | grep -c 'pipeline-evidence.sh attach <pr>')" "walk: two attach lines in all (command and agent), none else"

fill() {   # fill <template> <worktree> <epoch>
  printf '%s' "$1" | sed -e "s|<issue-n>|410|" -e "s|<worktree-path>|$2|" -e "s|<pr>|7|" -e "s|<epoch>|$3|" \
    -e "s|bash scripts/|bash $TALOS_ROOT/scripts/|g"
}

# a repo with a local bare origin, a tracked config and an ignored ev/
new_walk_repo() {
  REPO="$(mktemp -d "$SANDBOX/walk.XXXXXX")"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.name "talos test"
  git -C "$REPO" config user.email "test@talos.invalid"
  printf 'ev/\n' > "$REPO/.gitignore"
  printf '%s\n' "{\"base_branch\": \"main\", \"execution\": {\"isolation\": \"branch\"}, \"evidence\": {\"enabled\": true, \"dir\": \"ev\", \"command\": \"bash $MKEV\"}}" > "$REPO/talos.pipeline.json"
  git -C "$REPO" add .gitignore talos.pipeline.json
  git -C "$REPO" commit -q -m init
  ORIGIN="$SANDBOX/walk-origin.$$.git"
  rm -rf "$ORIGIN"
  git clone -q --bare "$REPO" "$ORIGIN"
  git -C "$REPO" remote remove origin 2>/dev/null
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" fetch -q origin
  git -C "$REPO" branch -u origin/main main >/dev/null 2>&1
  mkdir -p "$REPO/ev"
  cd "$REPO" || exit 1
}

new_walk_repo; reset
WALK_CMD="$(fill "$CMD_TPL" "$REPO" 0)"
run bash -c "$WALK_CMD"
assert_eq "0" "$RC" "walk: the qa.md command exits 0"
assert_eq "evidence-attach pr=7 status=posted images=2 videos=1 capture=0 comment=https://github.com/acme/widget/pull/7#issuecomment-5001" "$(out)" "walk: one stdout line, status=posted"
assert_eq "1" "$(lines "$OUT")" "walk: exactly one stdout line"
assert_eq "1" "$(posts)" "walk: exactly one gh pr comment --attach create"
assert_contains "$(gh_log)" "--attach ./shot-a.png --attach ./shot-b.png --attach ./0-run.webm" "walk: the files were attached"
assert_eq "0" "$(deletes)" "walk: no delete on the first round"
assert_eq "1" "$(grep -c 'talos:verify issue=410' "$ERR")" "walk: the stage identity was exported by pipeline-verify.sh"
run bash "$VCS" assert-sync
assert_eq "0" "$RC" "walk: assert-sync is clean under isolation: branch (the evidence dir is ignored)"
assert_eq "" "$(err)" "walk: assert-sync prints nothing"
# round two replaces the first: still one post, and the older comment is deleted
: > "$GH_LOG"
run bash -c "$WALK_CMD"
assert_eq "1" "$(posts)" "walk round 2: exactly one post"
assert_eq "1" "$(deletes)" "walk round 2: exactly one delete of the older evidence comment"
assert_contains "$(out)" "status=posted" "walk round 2: status=posted"
run bash "$VCS" assert-sync
assert_eq "0" "$RC" "walk round 2: assert-sync is still clean"

# the mode=agent line, with a screenshot saved under the evidence dir
new_walk_repo; reset
printf '%s\n' '{"base_branch": "main", "evidence": {"enabled": true, "dir": "ev"}}' > talos.pipeline.json
git add talos.pipeline.json; git commit -q -m cfg
printf '\211PNG\r\n\032\nshot' > ev/agent.png
WALK_AGENT="$(fill "$AGENT_TPL" "$REPO" 1)"
run bash -c "$WALK_AGENT"
assert_eq "0" "$RC" "walk (agent): exit 0"
assert_eq "evidence-attach pr=7 status=posted images=1 videos=0 capture=agent comment=https://github.com/acme/widget/pull/7#issuecomment-5001" "$(out)" "walk (agent): one line, status=posted"
assert_eq "1" "$(posts)" "walk (agent): exactly one post"

# the walk with evidence off: attach refuses, nothing is called, nothing posted
new_walk_repo; reset
printf '%s\n' '{"base_branch": "main", "evidence": {"enabled": false, "dir": "ev"}}' > talos.pipeline.json
run bash -c "$(fill "$AGENT_TPL" "$REPO" 1)"
assert_eq "2" "$RC" "walk (off): attach exits 2"
assert_eq "" "$(out)" "walk (off): empty stdout, which QA writes as evidence unavailable"
assert_eq "" "$(gh_log)" "walk (off): no gh call"

finish
