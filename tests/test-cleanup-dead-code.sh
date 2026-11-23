#!/usr/bin/env bash
# test-cleanup-dead-code.sh -- the dead-code cleanup of scripts/ (#1012) changes
# no behaviour:
#   AC1  pipeline-status.sh sources pipeline-board-shared.sh (no inline copy)
#        and resolves the board as before; without the file it stops.
#   AC2  install.sh's model hint reads `--show --origin-only agents.` (the
#        --dump-layers alias is gone) and still sees only the file-layer rows.
#   AC3  pipeline-worktree.sh, pipeline-mergebase.sh and pipeline-notify.sh take
#        pipeline-lock.sh's lock for real (a lock dir exists while the guarded
#        command runs) and stop, rather than run unlocked, without the helper.
#   AC4  (prose) the removed names are gone from scripts/ -- checked by grep.
#
# Uses the gh and curl stubs and a local bare repo as origin: no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

SCRIPTS="$TALOS_ROOT/scripts"
STATUS="$SCRIPTS/pipeline-status.sh"
CFG_SH="$SCRIPTS/pipeline-config.sh"
TAB="$(printf '\t')"
REAL_GIT="$(command -v git)"
REAL_PY="$(command -v python3)"

git config user.email "test@talos.invalid"
git config user.name "talos-test"
UPSTREAM_PARENT="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-dc-origin.XXXXXX")" || exit 1
git init -q --bare "$UPSTREAM_PARENT/upstream.git"
git remote set-url origin "$UPSTREAM_PARENT/upstream.git"
trap '_is_trap_owner && rm -rf "$SANDBOX" "$UPSTREAM_PARENT"' EXIT

# ── AC1: the board status move, through pipeline-board-shared.sh ─────────────
export GITHUB_TOKEN="test-secret-token-12345"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"},
 "board": {"enabled": true, "project_number": 4, "owner": "acme", "status_field": "Status"}}
EOF
USER_RESP='{"data":{"user":{"projectV2":{"id":"PVT_1"}}}}'
FIELDS_RESP='{"data":{"node":{"fields":{"nodes":[{"id":"FIELD_1","name":"Status","options":[{"id":"OPT_INREVIEW","name":"In review"},{"id":"OPT_DONE","name":"Done"}]}]}}}}'
ITEMS_RESP='{"data":{"node":{"items":{"nodes":[{"id":"ITEM_245","content":{"number":245}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'
UPDATE_RESP='{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"ITEM_245"}}}}'
: > "$CURL_LOG"
printf '%s\n' "$USER_RESP" "$FIELDS_RESP" "$ITEMS_RESP" "$UPDATE_RESP" > "$CURL_QUEUE"
out="$(bash "$STATUS" 245 "In review" 2>"$SANDBOX/err-ac1.txt")"; rc=$?
assert_eq "0" "$rc" "AC1 the board move exits 0 with pipeline-board-shared.sh present"
assert_contains "$out" "#245 → In review" "AC1 the board move prints the success line"
assert_contains "$(cat "$CURL_LOG")" "ITEM_245" "AC1 the update mutation carries the item resolved through the shared helpers"
assert_not_contains "$(cat "$SANDBOX/err-ac1.txt")" "inline board helpers" "AC1 no inline-helper warning"

# Without the shared helpers there is nothing to fall back to: stop, one line.
NOBOARD="$SANDBOX/no-board-scripts"
mkdir -p "$NOBOARD" && cp "$SCRIPTS"/*.sh "$NOBOARD"/ && rm -f "$NOBOARD/pipeline-board-shared.sh"
err="$(bash "$NOBOARD/pipeline-status.sh" 245 "In review" 2>&1 >/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC4 pipeline-status.sh exits 1 without pipeline-board-shared.sh"
assert_contains "$err" "pipeline-board-shared.sh not found next to this script -- aborting" "AC4 pipeline-status.sh names the missing file on stderr"

# ── AC2: the model hint's origin rows ────────────────────────────────────────
GHOME="$SANDBOX/talos-home"
mkdir -p "$GHOME"
printf '%s' '{"agents":{"model":"sonnet"},"limits":{"warn_at":0.5}}' > "$GHOME/talos.pipeline.json"
HINT_PROJ="$SANDBOX/hint-project"
mkdir -p "$HINT_PROJ"
printf '%s' '{"agents":{"roles":{"qa":{"model":"haiku"}}}}' > "$HINT_PROJ/talos.pipeline.json"
# The very command line install.sh runs, filter included.
hint_rows() {
  (cd "$1" && env -u PIPELINE_CONFIG TALOS_HOME="$GHOME" \
    bash "$CFG_SH" --show --origin-only agents. 2>/dev/null \
    | grep -E "${TAB}(global|repo)\$" || true)
}
assert_eq "$(printf 'agents.model\tglobal\nagents.roles.qa.model\trepo')" "$(hint_rows "$HINT_PROJ")" \
  "AC2 the hint lists the agents.* file-layer origins of a global and a project model"
rm -f "$HINT_PROJ/talos.pipeline.json"
assert_eq "agents.model${TAB}global" "$(hint_rows "$HINT_PROJ")" \
  "AC2 a global-only model is the one origin row"
rm -f "$GHOME/talos.pipeline.json"
assert_eq "" "$(hint_rows "$HINT_PROJ")" \
  "AC2 no config file, no rows: a default row never satisfies the hint"
assert_contains "$(cat "$TALOS_ROOT/install.sh")" 'pipeline-config.sh" --show --origin-only agents.' \
  "AC2 install.sh asks for the agents.* origins with --show --origin-only"

# ── AC3: the lock is real ────────────────────────────────────────────────────
# A shim in front of the tool the guarded command runs records whether the lock
# dir exists at that moment.
SHIM="$SANDBOX/shim"
SPY="$SANDBOX/lock-spy.log"
mkdir -p "$SHIM"
cat > "$SHIM/git" <<EOF
#!/bin/bash
case " \$* " in
  *" worktree add "*|*" worktree remove "*|*" worktree prune"*)
    if [ -d "\$("$REAL_GIT" rev-parse --git-common-dir)/talos-worktree.lock.d" ]; then
      echo "held git" >> "$SPY"; else echo "free git" >> "$SPY"; fi ;;
esac
exec "$REAL_GIT" "\$@"
EOF
cat > "$SHIM/python3" <<EOF
#!/bin/bash
if [ -n "\${STATE_FILE:-}" ] && [ "\${2:-}" = "-" ]; then
  if [ -d "\$STATE_FILE.lock.d" ]; then echo "held python3" >> "$SPY"; else echo "free python3" >> "$SPY"; fi
fi
exec "$REAL_PY" "\$@"
EOF
chmod +x "$SHIM/git" "$SHIM/python3"

# worktree remove: `git worktree prune` runs inside the lock.
git add -A >/dev/null 2>&1; git commit -qm seed >/dev/null 2>&1; git branch -M main
: > "$SPY"
PATH="$SHIM:$PATH" bash "$SCRIPTS/pipeline-worktree.sh" remove 7 >/dev/null 2>&1
assert_contains "$(cat "$SPY")" "held git" "AC3 pipeline-worktree.sh remove holds the lock while it runs git"
assert_not_contains "$(cat "$SPY")" "free git" "AC3 pipeline-worktree.sh never runs a worktree command unlocked"

# mergebase: the temp worktree is added (and removed) under the lock.
cat > CHANGELOG.md <<'EOF'
# Changelog

## [Unreleased]
### Added
- existing entry
EOF
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main"}
EOF
git add -A >/dev/null; git commit -qm "seed changelog"; git push -q origin main
git checkout -q -b pr-50 origin/main
python3 -c "
p = 'CHANGELOG.md'
open(p, 'w').write(open(p).read().replace('- existing entry', '- existing entry\n- PR bullet'))
"
git commit -aqm "pr: pr-50"; git push -q origin pr-50; git push -q origin pr-50:refs/pull/50/head
git checkout -q main
python3 -c "
p = 'CHANGELOG.md'
open(p, 'w').write(open(p).read().replace('- existing entry', '- existing entry\n- base bullet'))
"
git commit -aqm "base: bullet"; git push -q origin main
: > "$SPY"
PATH="$SHIM:$PATH" STUB_PR_HEAD_REF_NAME="pr-50" bash "$SCRIPTS/pipeline-mergebase.sh" 50 >/dev/null 2>&1
assert_contains "$(cat "$SPY")" "held git" "AC3 pipeline-mergebase.sh holds the lock while it adds its worktree"
assert_not_contains "$(cat "$SPY")" "free git" "AC3 pipeline-mergebase.sh never runs a worktree command unlocked"

# notify: the thread-state read-modify-write runs under the lock.
export PIPELINE_THREAD_STATE="$SANDBOX/threads.json"
: > "$SPY"; : > "$CURL_LOG"
PATH="$SHIM:$PATH" SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST \
  PIPELINE_ISSUE_TITLE="Fix login crash" bash "$SCRIPTS/pipeline-notify.sh" dispatched "#42" "kickoff" 42 >/dev/null 2>&1
assert_contains "$(cat "$SPY")" "held python3" "AC3 pipeline-notify.sh holds the lock while it writes thread state"
assert_not_contains "$(cat "$SPY")" "free python3" "AC3 pipeline-notify.sh never writes thread state unlocked"

# Without the helper each script stops with one line instead of running unlocked.
NOLOCK="$SANDBOX/no-lock-scripts"
mkdir -p "$NOLOCK" && cp "$SCRIPTS"/*.sh "$NOLOCK"/ && rm -f "$NOLOCK/pipeline-lock.sh"
for pair in "pipeline-worktree.sh remove 7" "pipeline-mergebase.sh 50" "pipeline-notify.sh info #1 msg 1"; do
  # shellcheck disable=SC2086
  set -- $pair
  s="$1"; shift
  err="$(bash "$NOLOCK/$s" "$@" 2>&1 >/dev/null)"; rc=$?
  assert_eq "1" "$rc" "AC3 $s exits 1 without pipeline-lock.sh"
  assert_contains "$err" "pipeline-lock.sh missing" "AC3 $s says the lock helper is missing"
done

# ── AC4: the removed names are gone from scripts/ ────────────────────────────
for name in '--dump-layers' '_talos_lease_held_line' 'talos_contract_json' 'inline board helpers' \
            'unsynchronized' '.claude-pipeline'; do
  hits="$(grep -rnF -- "$name" "$SCRIPTS" --include='*.sh' 2>/dev/null \
    | grep -v "scripts/pipeline-vcs.sh:.*claude-pipeline" | grep -v "pipeline-config.sh:.*claude-pipeline" || true)"
  assert_eq "" "$hits" "AC4 scripts/ no longer mentions $name"
done
assert_eq "" "$(grep -rn 'with_lock() *{ shift 2' "$SCRIPTS" || true)" "AC4 no unlocked with_lock stub remains in scripts/"
assert_eq "" "$(grep -rnF -- '--dump-layers' "$TALOS_ROOT/docs" "$TALOS_ROOT/README.md" "$TALOS_ROOT/skills" 2>/dev/null || true)" \
  "AC4 the docs no longer mention --dump-layers"

finish
