# helpers.sh — shared assertions and sandbox setup for talos tests.
# Source this from every test file. Requires TALOS_ROOT to be exported
# by run-tests.sh (falls back to the repo root relative to this file).

TALOS_ROOT="${TALOS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STUBS_DIR="$TALOS_ROOT/tests/stubs"

# _resolve_talos_dir() -- the same canonical scripts-dir probe pipeline-agent.sh
# and pipeline-notify.sh use. Sourced once here (function-definition only, no
# side effects) so install_talos and any test can call it directly instead of
# re-sourcing it per call.
. "$TALOS_ROOT/scripts/pipeline-paths.sh"

_PASS=0
_FAIL=0

pass() { _PASS=$((_PASS + 1)); printf '  ok  %s\n' "$1"; }

fail() {
  _FAIL=$((_FAIL + 1))
  printf 'FAIL  %s\n' "$1" >&2
  [ -n "${2:-}" ] && printf '      %s\n' "$2" >&2
}

assert_eq() {  # $1=expected $2=actual $3=label
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected: $1 | actual: $2"; fi
}

assert_contains() {  # $1=haystack $2=needle $3=label
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3" "missing: $2 | in: $(printf '%s' "$1" | head -c 300)" ;;
  esac
}

assert_not_contains() {  # $1=haystack $2=needle $3=label
  case "$1" in
    *"$2"*) fail "$3" "unexpected: $2" ;;
    *) pass "$3" ;;
  esac
}

assert_file_exists() {  # $1=path $2=label
  if [ -f "$1" ]; then pass "$2"; else fail "$2" "file not found: $1"; fi
}

assert_file_absent() {  # $1=path $2=label
  if [ -e "$1" ]; then fail "$2" "file should not exist: $1"; else pass "$2"; fi
}

assert_exit_code() {  # $1=expected $2=actual $3=label
  assert_eq "$1" "$2" "$3"
}

# assert_eq_ctx -- like assert_eq, but appends extra diagnostic context (e.g.
# a captured stderr stream) to the failure message only. Passing tests print
# nothing extra; failing tests get the context that would otherwise be
# silently redirected to /dev/null, which is exactly what a flaky CI failure
# needs to be diagnosable from the log alone (#208).
assert_eq_ctx() {  # $1=expected $2=actual $3=label $4=context
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3" "expected: $1 | actual: $2 | stderr: ${4:-<empty>}"
  fi
}

# make_sandbox — create an isolated temp dir with a git repo + fake origin.
# Sets SANDBOX and cds into it. Cleaned up automatically on exit.
#
# WARNING (#121): make_sandbox cds into a temp dir and registers an EXIT trap
# that deletes it. This function must only be called inside a subprocess
# (e.g. "bash tests/my-test.sh") — never sourced into the caller's own shell.
# Sourcing it changes the caller's CWD to a directory that gets deleted when
# the subprocess exits, stranding the caller in a non-existent path.
#
# The guard below detects the sourced case by comparing BASH_SOURCE[-1]
# (the outermost file in the call stack) with $0 (the running script). When
# a test file is executed directly ("bash tests/test-foo.sh"), both equal the
# test file path. When helpers.sh is sourced into an interactive shell,
# BASH_SOURCE[-1] differs from $0 — the guard fires and returns 1.
make_sandbox() {
  # Guard: refuse when called from a sourced context.
  # BASH_SOURCE[-1] (bash 4+) is spelled out portably for bash 3.2 (macOS).
  _msb_outer="${BASH_SOURCE[${#BASH_SOURCE[@]}-1]:-}"
  if [ -n "$_msb_outer" ] && [ "$_msb_outer" != "$0" ]; then
    printf 'make_sandbox: ERROR: do not source test files -- run them directly:\n' >&2
    printf '  bash %s\n' "$_msb_outer" >&2
    printf 'Sourcing make_sandbox cds the caller shell into a temp dir that is\n' >&2
    printf 'deleted on exit, stranding the caller in a non-existent path.\n' >&2
    unset _msb_outer
    return 1
  fi
  unset _msb_outer

  # Isolate from ambient identity/override env vars (#208). A developer shell
  # (or a Talos agent invoking this very suite from inside a worktree) commonly
  # exports one or more of these -- CLAUDE_CONFIG_DIR in particular routinely
  # points at a real ~/.claude on a machine with Claude Code installed. Left
  # ambient, they redirect install_talos's "global" install (and the role/
  # identity vars pipeline-agent.sh reads) outside the per-test sandbox: two
  # tests racing on the same real path under the parallel runner, or a test
  # silently overwriting a developer's real ~/.talos or ~/.claude.
  #
  # XDG_RUNTIME_DIR (#252): pipeline-status.sh's board sentinel cache resolves
  # to "${XDG_RUNTIME_DIR:-$HOME/.cache}/talos" -- on a machine/CI runner
  # where XDG_RUNTIME_DIR is set ambiently (common under a systemd user
  # session), leaving it exported here would make every test write its
  # sentinel to that *real*, shared location instead of the sandboxed HOME
  # set below -- exactly how the real ~/.cache/talos got poisoned with a
  # stale cross-owner cache in the first place.
  unset TALOS_HOME CLAUDE_PLUGIN_ROOT CLAUDE_CONFIG_DIR XDG_RUNTIME_DIR \
        TALOS_ISSUE TALOS_ISSUE_NUMBER TALOS_ROLE TALOS_WORKTREE_PATH

  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/talos-test.XXXXXX")"
  trap 'rm -rf "$SANDBOX"' EXIT
  cd "$SANDBOX"
  git init -q
  git remote add origin git@github.com:acme/widget.git
  # Hermetic HOME. pipeline-notify.sh scrapes ~/.hermes/.env for bot
  # credentials, so on a developer machine with Slack/Discord/Buzz configured
  # the real values bleed into the sandbox and invert credential-absence
  # assertions ("without private key produces no buzz output" starts finding a
  # key). Kept as a subdirectory so HOME is never the repo root itself, and
  # seeded with a gitconfig so suites that commit still resolve an identity.
  mkdir -p "$SANDBOX/.home"
  export HOME="$SANDBOX/.home"
  printf '[user]\n\tname = talos-test\n\temail = test@talos.invalid\n' > "$HOME/.gitconfig"
}

# use_stubs — put the gh/curl/nak stubs first on PATH and reset their logs.
# Sets GH_LOG, CURL_LOG, and NAK_LOG (files the stubs append every invocation to).
use_stubs() {
  export PATH="$STUBS_DIR:$PATH"
  export GH_LOG="$SANDBOX/gh.log"
  export CURL_LOG="$SANDBOX/curl.log"
  export CURL_QUEUE="$SANDBOX/curl.queue"        # optional: one canned response per line
  export CURL_LINK_QUEUE="$SANDBOX/curl.link.queue"  # optional: Link: next URL per call
  export NAK_LOG="$SANDBOX/nak.log"
  export NAK_QUEUE="$SANDBOX/nak.queue"     # optional: "fail" or canned event JSON per line
  export VERIFY_LOG="$SANDBOX/verify.log"   # one line per simulated `verify:` run (#195)
  : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
  : > "$NAK_LOG"; : > "$NAK_QUEUE"; : > "$VERIFY_LOG"
}

# install_talos — install Talos globally into the sandbox HOME (~/.talos/) and
# configure the sandbox repo (config only). Scripts land in $HOME/.talos/scripts/
# which is probe position 2 in the canonical order, so all probe-using helpers
# find them without per-repo vendoring.
# After calling install_talos, use TALOS_SCRIPTS="$HOME/.talos/scripts" to
# reference installed scripts.
install_talos() {
  bash "$TALOS_ROOT/install.sh" --global --no-agent-skills >/dev/null
  bash "$TALOS_ROOT/install.sh" "$SANDBOX" --no-agent-skills >/dev/null

  # Hardening (#208): confirm the "global" install actually landed under the
  # sandboxed $HOME by running the same probe pipeline-agent.sh uses. If any
  # of the vars make_sandbox unsets above ever leaks back in (or a future
  # change to install.sh adds a new override), this fails loudly here instead
  # of two unrelated tests silently racing on a real, shared path.
  _resolved="$(_resolve_talos_dir 2>/dev/null || true)"
  case "$_resolved" in
    "$HOME"/*) pass "install_talos: resolved scripts dir is under \$HOME" ;;
    *) fail "install_talos: resolved scripts dir is under \$HOME" \
            "resolved: ${_resolved:-<none>} | HOME: $HOME" ;;
  esac
  unset _resolved
}

# install_talos_vendored — legacy helper: copies scripts directly into
# .claude/talos/scripts/ to test probe position 4 (vendored back-compat).
# Use only in tests that explicitly test the old vendored layout.
install_talos_vendored() {
  mkdir -p "$SANDBOX/.claude/talos/scripts" "$SANDBOX/.claude/talos/templates/notifications" \
           "$SANDBOX/.claude/talos/templates/comments" "$SANDBOX/.claude/agents"
  for script in "$TALOS_ROOT"/scripts/pipeline-*.sh "$TALOS_ROOT"/scripts/bootstrap-*.sh; do
    cp "$script" "$SANDBOX/.claude/talos/scripts/"
    chmod +x "$SANDBOX/.claude/talos/scripts/$(basename "$script")"
  done
  for dir in notifications comments; do
    for tmpl in "$TALOS_ROOT/templates/$dir"/*.md; do
      [ -f "$tmpl" ] || continue
      cp "$tmpl" "$SANDBOX/.claude/talos/templates/$dir/"
    done
  done
  for agent in validator pm developer qa reviewer security adversarial docs planner; do
    for src in "$TALOS_ROOT/agents/$agent.md" "$TALOS_ROOT/.claude/agents/$agent.md"; do
      [ -f "$src" ] && cp "$src" "$SANDBOX/.claude/agents/$agent.md" && break
    done
  done
}

# finish — print summary for this file and exit non-zero on any failure.
finish() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$_PASS" "$_FAIL"
  [ "$_FAIL" -eq 0 ]
}
