#!/usr/bin/env bash
# test-docs-paths-754.sh -- `scripts/talos.sh docs-gate` reads the docs-relevant
# path globs from docs.paths (#754). Default: README.md, docs/*,
# scripts/pipeline-defaults.sh (the list the gate hardcoded before); a repo whose
# docs live under .claude/ names its own. A glob matches across `/`, as `docs/*` did.
#   AC6 docs.paths [".claude/docs/**"]: a PR touching .claude/docs/guide.md
#       dispatches (reason=docs-paths), README.md alone skips
#   AC7 docs.paths unset: README.md, docs/x.md and scripts/pipeline-defaults.sh
#       dispatch, every other path skips
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
ERR="$SANDBOX/stderr"

GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
mkdir -p "$SANDBOX/templates"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="$1"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-status.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
DG="$GS/talos.sh"

cfg_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
# reset <changed paths, one per line> [<extra config members>, with a leading comma]
reset() {
  rm -rf "${STUB_DIR:?}" "${SANDBOX:?}/.git/talos-lease.ledger"; mkdir -p "$STUB_DIR"
  cfg_json "$(printf '{"vcs": {"provider": "github"}, "comments": {"enabled": false}%s}' "${2:-}")"
  printf '%s\n' "$1" > "$STUB_DIR/pr-files.out"
}
# dg: run the verb; OUT, RC. PF is the paths file it names (if any).
dg() {
  OUT="$(bash "$DG" docs-gate 7 --issue 3 2>"$ERR")"; RC=$?
  PF="$(printf '%s\n' "$OUT" | sed -n 's/^docs=.* paths-file=\([^ ]*\).*/\1/p' | head -n 1)"
}
cleanup_pf() { [ -z "$PF" ] || rm -f "$PF"; }
CLAUDE_PATHS=', "docs": {"paths": [".claude/docs/**"]}'

# ── AC6: docs.paths names where the docs live ────────────────────────────────
reset $'.claude/docs/guide.md\nscripts/talos.sh' "$CLAUDE_PATHS"
dg
assert_eq "0" "$RC" "AC6 .claude/docs PR: exit 0"
assert_contains "$OUT" "docs=dispatch reason=docs-paths paths-file=" "AC6 .claude/docs/guide.md with docs.paths [.claude/docs/**]: dispatch"
assert_eq ".claude/docs/guide.md" "$(cat "$PF")" "AC6 the paths file holds only the docs.paths subset"
cleanup_pf

reset $'.claude/docs/sub/dir/deep.md' "$CLAUDE_PATHS"
dg
assert_contains "$OUT" "docs=dispatch reason=docs-paths" "AC6 a ** glob matches across /"
cleanup_pf

reset $'README.md' "$CLAUDE_PATHS"
dg
assert_contains "$OUT" "docs=skip reason=no-docs-paths" "AC6 README.md alone under docs.paths [.claude/docs/**]: skip"
assert_eq "" "$PF" "AC6 README.md alone: no paths file"

reset $'docs/x.md\nscripts/pipeline-defaults.sh' "$CLAUDE_PATHS"
dg
assert_contains "$OUT" "docs=skip reason=no-docs-paths" "AC6 docs.paths replaces the default list: docs/x.md and the defaults file skip"

reset $'README.md\n.claude/docs/a.md' ', "docs": {"paths": ["README.md", ".claude/docs/**"]}'
dg
assert_eq "$(printf 'README.md\n.claude/docs/a.md')" "$(cat "$PF")" "AC6 several globs: each matching path is kept"
cleanup_pf

# ── AC7: unset, the gate is what it was ──────────────────────────────────────
for _p in README.md docs/x.md scripts/pipeline-defaults.sh; do
  reset "$_p"
  dg
  assert_contains "$OUT" "docs=dispatch reason=docs-paths" "AC7 docs.paths unset: $_p dispatches"
  assert_eq "$_p" "$(cat "$PF")" "AC7 docs.paths unset: $_p is the paths file"
  cleanup_pf
done
reset $'scripts/talos.sh\ntests/test-x.sh\nCHANGELOG.md\n.claude/docs/guide.md\ndocs-extra/x.md\nsub/README.md'
dg
assert_contains "$OUT" "docs=skip reason=no-docs-paths" "AC7 docs.paths unset: every other path skips"

finish
