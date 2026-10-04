#!/usr/bin/env bash
# test-setup-status-file.sh -- the /pipeline-setup status file step (#349, part
# of epic #333). Grep-based like test-setup-draft-ci-check.sh, plus one sandbox
# run: the fenced `init` block is extracted from the skill and executed, so the
# test runs the command the wizard actually shows.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
# Private TMPDIR (#448): the init run below, and anything it mktemp's, lands in
# a directory only this run uses. The rm -rf is anchored on that checked path.
PRIV_TMP="$(mktemp -d "${TMPDIR:-/tmp}/talos-setup-sf.XXXXXX")" || exit 1
trap 'rm -rf "$SANDBOX" "$PRIV_TMP"' EXIT
export TMPDIR="$PRIV_TMP"

SETUP="${SETUP_FILE:-$TALOS_ROOT/skills/pipeline-setup/SKILL.md}"
GUIDE="$TALOS_ROOT/docs/user-guide.md"
EXAMPLE="$TALOS_ROOT/talos.pipeline.yml.example"
CHANGELOG="$TALOS_ROOT/CHANGELOG.md"
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
SN="$(flat "$SETUP")"

# One step of the skill, by heading prefix, flattened. Ends at the next `---` rule.
step() {
  awk -v a="$1" 'index($0, a) == 1 {on=1} on && /^---$/ {exit} on' "$SETUP" | tr '\n' ' ' | tr -s ' '
}

# ── The question: after the roles questions, one question, default yes ───────
roles_line="$(grep -n '^## Step 4 ' "$SETUP" | head -1 | cut -d: -f1)"
ask_line="$(grep -n '^## Step 4b' "$SETUP" | head -1 | cut -d: -f1)"
board_line="$(grep -n '^## Step 5 ' "$SETUP" | head -1 | cut -d: -f1)"
assert_eq "1" "$([ -n "$ask_line" ] && [ -n "$roles_line" ] && [ "$ask_line" -gt "$roles_line" ] && [ "$ask_line" -lt "$board_line" ] && echo 1 || echo 0)" "the status question sits after the roles questions (Step 4b)"
Q="$(step '## Step 4b')"
assert_contains "$Q" "[default: **no**]" "the status question defaults to no (#456, J1)"
assert_not_contains "$Q" "[default: **yes**]" "the status question no longer defaults to yes"
assert_contains "$Q" '`[skip ci]` commits' "the question says the base-branch commits are [skip ci] commits (#456)"
assert_contains "$Q" "one per merged PR" "the question names the commit cadence (#456)"
assert_contains "$Q" 'under `docs/status.d/`' "the question names the per-PR files under docs/status.d/ (#456)"
assert_contains "$Q" "a protected base branch needs an admin or bypass token" "the question matches the user guide on a protected base branch (#456)"
assert_contains "$Q" "an active block" "a decline writes an active block so Step 0 never asks again (#456)"
assert_contains "$Q" "any LLM" "the question says what it is for: resume after a stopped run, with any LLM"
assert_contains "$Q" "protected base branch" "the question warns about a protected base branch"
assert_contains "$Q" "straight to your base branch" "the question says status commits go straight to the base branch"
assert_contains "$Q" "vcs.provider: file" "the question is skipped on vcs.provider: file"
assert_contains "$Q" "skip" "the file-provider skip is spelled out"

# ── Step 7 template: the status: block, YAML and JSON ────────────────────────
T="$(step '## Step 7 ')"
assert_contains "$T" "status:" "Step 7 template has a status: block"
assert_contains "$T" "enabled: <true|false>" "the status block is enabled true when accepted, false otherwise"
for k in file fragments_dir log_days log_max resume_max_lines; do
  assert_contains "$T" "# $k:" "the status block shows $k as a commented default"
done
assert_contains "$T" '"status": { "enabled": true }' "a JSON config gets a status key when accepted"
assert_contains "$T" '"status": { "enabled": false }' "declined in JSON writes an explicit enabled: false (#456)"
assert_contains "$T" "declined writes the same block with \`enabled: false\`, active and not commented out" "declined in YAML writes status: with enabled: false, active (#456)"
assert_not_contains "$T" "the whole block commented out" "a YAML decline no longer comments the whole block out (#456)"

# ── The step that runs init, and what it tells the user ──────────────────────
S="$(step '## Step 7b')"
assert_contains "$S" "bash scripts/pipeline-status-file.sh init" "Step 7b runs pipeline-status-file.sh init"
assert_contains "$S" "commit" "Step 7b tells the user to commit"
assert_contains "$S" "talos.pipeline.yml" "Step 7b names the config in the commit advice"
assert_contains "$S" "together" "Step 7b says to commit the config and the status file together"
assert_contains "$S" "does not commit" "Step 7b says init does not commit"
assert_contains "$S" "vcs.provider: file" "Step 7b is skipped for the file provider"

# ── Union paths: the status file is NOT added ────────────────────────────────
assert_eq "1" "$(grep -c 'merge.union_paths' "$SETUP")" "the skill mentions merge.union_paths exactly once"
assert_contains "$SN" 'is NOT added to `merge.union_paths` (fragments replace union merging)' "the skill says the status file is NOT added to merge.union_paths"

# ── Step 0 re-run path ───────────────────────────────────────────────────────
Z="$(step '## Step 0')"
assert_not_contains "$Z" "Step 7 (bootstrap" "Step 0 no longer points the re-run path at Step 7 for bootstrap"
assert_contains "$Z" "Step 8" "Step 0's no-changes path jumps to Step 8 (bootstrap labels)"
assert_contains "$Z" "Step 4b" "Step 0's re-run path offers the status question"
assert_contains "$Z" 'ONLY the `status:` block' "the re-run path adds only the status: block"
assert_contains "$Z" "never parse and re-write it" "a JSON config is never re-serialised on the re-run path (#456)"
assert_contains "$Z" '"status": { "enabled": true },' "the JSON re-run path shows the line to add (#456)"
assert_contains "$Z" "directly after the file's opening" "the JSON re-run path says where the line goes (#456)"
assert_contains "$(step '## Step 8 ')" "pipeline:needs-owner" "Step 8 says a re-run creates pipeline:needs-owner"

# ── Step 11 summary and idempotency ──────────────────────────────────────────
SUM="$(step '## Step 11')"
assert_contains "$SUM" "Status file:" "the summary has a Status file line"
assert_contains "$SUM" '"disabled"' "the summary shows the path or disabled"
assert_contains "$SUM" "pipeline:needs-owner" "the control-label list includes pipeline:needs-owner"
IDEM="$(step '## Idempotency rules')"
assert_contains "$IDEM" "existing status file is never overwritten" "Idempotency: an existing status file is never overwritten"

# ── Sandbox: a fresh setup creates the status file ───────────────────────────
# Extract the fenced bash block that runs init, exactly as the skill shows it.
awk '/^```bash$/{buf=""; inb=1; next} /^```$/{ if (inb && buf ~ /pipeline-status-file\.sh init/) printf "%s", buf; inb=0; buf=""; next} inb{buf = buf $0 "\n"}' "$SETUP" > "$SANDBOX/init.sh"
assert_eq "1" "$([ -s "$SANDBOX/init.sh" ] && echo 1 || echo 0)" "the skill has a fenced init block"
assert_eq "1" "$(grep -c . "$SANDBOX/init.sh")" "the init block is the one command"
# Run only the init line, never the rest of the fenced block (#448): a block
# that ever grows another command must not execute it in the test.
grep 'pipeline-status-file\.sh init' "$SANDBOX/init.sh" > "$SANDBOX/init-only.sh"
assert_eq "1" "$(grep -c . "$SANDBOX/init-only.sh")" "exactly one line runs init"

REPO="$SANDBOX/fresh"
mkdir -p "$REPO" && cd "$REPO" || exit 1
git init -q -b main
git config user.email t@example.com; git config user.name t
ln -s "$TALOS_ROOT/scripts" scripts
printf 'base_branch: main\nvcs:\n  provider: github\nstatus:\n  enabled: true\n' > talos.pipeline.yml
out="$(bash "$SANDBOX/init-only.sh" 2>&1)"; rc=$?
assert_eq "0" "$rc" "the skill's init command exits 0 in a sandbox repo"
assert_contains "$out" "created TALOS_STATUS.md" "init reports it created the file"
assert_file_exists "$REPO/TALOS_STATUS.md" "init creates TALOS_STATUS.md"
body="$(cat "$REPO/TALOS_STATUS.md")"
assert_contains "$body" "## Resume here" "the status file has the resume heading"
assert_contains "$body" "## Log" "the status file has the log heading"
assert_eq "" "$(git log --oneline 2>/dev/null)" "init does not commit"

# Never overwritten: a second run leaves an edited file byte for byte alone.
printf 'KEEP ME\n' >> TALOS_STATUS.md
before="$(cat TALOS_STATUS.md)"
out2="$(bash "$SANDBOX/init-only.sh" 2>&1)"
assert_contains "$out2" "already has both headings" "a second run reports the file already has both headings"
assert_eq "$before" "$(cat TALOS_STATUS.md)" "a second run never overwrites an existing status file"

# ── User guide, example config, changelog ────────────────────────────────────
G="$(flat "$GUIDE")"
assert_contains "$G" "### The status file and resume" "user guide has the status file section"
for needle in "TALOS_STATUS.md" "docs/status.d/" "log_days" "log_max" "status/archive" "pipeline:needs-owner" "trusted author" "pipeline:blocked" "/talos:resume" "/talos-resume" "skills/resume/SKILL.md" "protected" "data describing a run" "pipeline-setup"; do
  assert_contains "$G" "$needle" "user guide mentions: $needle"
done
assert_eq "1" "$(awk '/^## Running the pipeline/{r=1; next} /^## /{r=0} r&&/^### The status file and resume/{f=1} END{print f+0}' "$GUIDE")" "the status section is a ### under Running the pipeline"
assert_not_contains "$(flat "$EXAMPLE")" "nothing reads status.*" "the example config no longer says nothing reads status.*"
assert_contains "$(flat "$CHANGELOG")" "(#349" "CHANGELOG has an entry for #349"

finish
