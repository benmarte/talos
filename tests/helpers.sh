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

# Hermetic user-level config (#336). pipeline-config.sh layers
# ${TALOS_HOME:-$HOME/.talos}/talos.pipeline.* under every project config, so a
# developer's real ~/.talos (or an ambient TALOS_HOME) would otherwise answer
# lookups in any test that does not call make_sandbox. Point it at a path that
# no local user can create -- every test file sources this helper, so the fix
# holds for `bash tests/<file>.sh` as well as for the runner. make_sandbox
# replaces this with a clean sandbox HOME (and unsets TALOS_HOME); a test that
# exercises a user-level file does so inside its own sandbox. The path sits
# below /dev/null (a character device, never a directory) rather than under
# $TMPDIR, where another account on a shared host could pre-create it with a
# config (#340). pipeline-config.sh only tests `[ -f "$dir/talos.pipeline.*" ]`,
# so a non-directory parent reads as "no user-level file" on macOS and Linux.
export TALOS_HOME="/dev/null/talos-test-no-user-config"

# Hermetic legacy secrets file (#476). pipeline-secrets.sh falls back to
# $HOME/.hermes/.env, and a test must never read the real one. An empty
# TALOS_HERMES_ENV switches the fallback off for every test file; make_sandbox
# points it at a path inside the sandbox, where a test that exercises the
# fallback writes its file (an ambient TALOS_HERMES_ENV is overwritten here).
export TALOS_HERMES_ENV=""

# Hermetic file modes (#443). The global config is refused when it is group- or
# world-writable (pipeline-secrets.sh, the config-file trust check), and a test
# writes one with a plain redirect, so the mode it gets is the caller's umask: a
# 002 umask (a Linux login shell, some CI runners) makes it 0664 and the loader
# reads it as absent. Pin 022 for every test file; the trust check itself is
# never weakened, and tests that want a bad mode chmod it explicitly.
umask 022

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

# safe_mktemp_dir [template] — `mktemp -d` that fails closed (#459). Prints the
# new directory, or returns 1 with nothing on stdout when mktemp fails or the
# result is empty or not a directory. An unchecked `X="$(mktemp -d)"` leaves X
# empty, and a later `rm -rf "$X/..."` then deletes from `/`. Use it as
#   X="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-foo.XXXXXX")" || exit 1
# (`exit`, not `return`, at file level: inside `$(...)` the helper can only
# return, so the caller has to stop the test). tests/test-unsafe-cleanup-guard.sh
# fails on a `$(mktemp` assignment with no `||` after it.
safe_mktemp_dir() {
  local _smd_dir
  _smd_dir="$(mktemp -d "$@")" || return 1
  if [ -z "$_smd_dir" ] || [ ! -d "$_smd_dir" ]; then
    printf 'safe_mktemp_dir: ERROR: mktemp -d returned %s\n' "${_smd_dir:-an empty path}" >&2
    return 1
  fi
  printf '%s\n' "$_smd_dir"
}

# _sandbox_cleanup — make_sandbox's EXIT-trap body. Removes $SANDBOX only in the
# process that created it (see the owner note at the trap in make_sandbox).
# BASHPID is bash >= 4; bash 3.2 falls back to $$, where the race cannot occur.
_sandbox_cleanup() {
  [ "${BASHPID:-$$}" = "${_SANDBOX_OWNER:-}" ] || return 0
  [ -n "${SANDBOX:-}" ] || return 0
  rm -rf "$SANDBOX"
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
  unset TALOS_HOME CLAUDE_PLUGIN_ROOT CLAUDE_CONFIG_DIR TALOS_AGENTS_HOME XDG_RUNTIME_DIR \
        TALOS_ISSUE TALOS_ISSUE_NUMBER TALOS_ROLE TALOS_WORKTREE_PATH

  # Fail closed (#448): a failed mktemp must not leave SANDBOX empty with the
  # EXIT trap armed and the caller still in its own directory (every later
  # `git init` or write would land in the cwd). About 100 callers do not write
  # `|| exit 1`, so the helper exits itself: this point is only reachable from a
  # directly executed test file (the sourced case returned above), so exiting
  # ends that test, never an interactive shell.
  SANDBOX="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-test.XXXXXX")" || {
    printf 'make_sandbox: ERROR: mktemp -d failed under %s -- not continuing\n' "${TMPDIR:-/tmp}" >&2
    SANDBOX=""
    exit 1
  }
  # Owner-guarded (#566): bash >= 5 installs a fatal-signal handler once an EXIT
  # trap exists, and a forked child inherits it until it execs or clears traps.
  # A `( sleep 30 ) & kill "$!"` that wins the race (Linux schedules the parent
  # first; macOS runs the child first, so it never showed locally) makes the
  # child run THIS trap and delete the live test's sandbox. Only the process
  # that created the sandbox may remove it.
  _SANDBOX_OWNER="${BASHPID:-$$}"
  trap '_sandbox_cleanup' EXIT
  cd "$SANDBOX" || exit 1
  git init -q
  git remote add origin git@github.com:acme/widget.git
  # Hermetic HOME. pipeline-notify.sh reads webhooks and bot credentials from
  # ${TALOS_HOME:-$HOME/.talos}/.env and the legacy ~/.hermes/.env (#443,
  # scripts/pipeline-secrets.sh), so on a developer machine with Slack/Discord/
  # Buzz configured the real values bleed into the sandbox and invert
  # credential-absence assertions ("without private key produces no buzz output"
  # starts finding a key). Kept as a subdirectory so HOME is never the repo root
  # itself, and seeded with a gitconfig so suites that commit still resolve an
  # identity. NOTE: this HOME sits inside the sandbox's own git work tree, and
  # the .env trust check refuses a .env inside any work tree -- so a test that
  # needs a user-level .env to be READ points TALOS_HOME at a directory outside
  # it (see tests/test-secret-refs.sh, which drops the sandbox repo first).
  mkdir -p "$SANDBOX/.home"
  export HOME="$SANDBOX/.home"
  export TALOS_HERMES_ENV="$HOME/.hermes/.env"
  printf '[user]\n\tname = talos-test\n\temail = test@talos.invalid\n' > "$HOME/.gitconfig"
  # Hermetic `claude` (#335). install.sh --global registers the talos plugin
  # through `claude plugin ...`, which on a machine with Claude Code would write
  # that user's Claude config and fetch the agent-skills dependency over the
  # network. Put a stub first on PATH so no test reaches the real binary; it
  # keeps its state and log under the sandbox HOME (inside the already-untracked
  # .home, so the sandbox repo's `git status` is unchanged). A test of the
  # "no claude on PATH" cases builds its own stripped PATH, as it always did.
  export CLAUDE_STUB_STATE="$HOME/.claude-stub/state"
  export CLAUDE_PLUGIN_LOG="$HOME/.claude-stub/plugin.log"
  unset CLAUDE_STUB_NO_PLUGIN CLAUDE_STUB_LIST_RAW CLAUDE_STUB_ADD_FAIL CLAUDE_STUB_INSTALL_FAIL
  mkdir -p "$HOME/.claude-stub"
  export PATH="$STUBS_DIR/plugin-claude:$PATH"
}

# use_stubs — put the gh/curl/nak stubs first on PATH and reset their logs.
# Sets GH_LOG, CURL_LOG, NAK_LOG, and NAK_ENV_LOG (files the stubs append every
# invocation to; NAK_ENV_LOG carries nak's NOSTR_* environment, #281).
use_stubs() {
  export PATH="$STUBS_DIR:$PATH"
  export GH_LOG="$SANDBOX/gh.log"
  export CURL_LOG="$SANDBOX/curl.log"
  export CURL_QUEUE="$SANDBOX/curl.queue"        # optional: one canned response per line
  export CURL_LINK_QUEUE="$SANDBOX/curl.link.queue"  # optional: Link: next URL per call
  export NAK_LOG="$SANDBOX/nak.log"
  export NAK_QUEUE="$SANDBOX/nak.queue"     # optional: "fail"/"reject"/"hang" or canned event JSON per line
  export NAK_ENV_LOG="$SANDBOX/nak.env.log" # NOSTR_* env vars seen by the nak stub
  export VERIFY_LOG="$SANDBOX/verify.log"   # one line per simulated `verify:` run (#195)
  : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
  : > "$NAK_LOG"; : > "$NAK_QUEUE"; : > "$NAK_ENV_LOG"; : > "$VERIFY_LOG"
}

# github_leg <gh|curl> [<extra config members>] — point the sandbox at ONE of the
# two GitHub transports (#551). `gh` is vcs.provider github with the gh stub;
# `curl` is vcs.provider github-api with the curl stub and a token. The queue and
# the request log are shared names, so a test written against CURL_QUEUE and
# CURL_LOG runs unchanged on either: the gh stub reads GH_QUEUE / GH_LINK_QUEUE and
# writes GH_REST_LOG in the curl stub's formats (the log's auth field is empty on
# the gh leg: it carries no token). <extra config members> is JSON text that
# starts with a comma, e.g. ',"merge": {"method": "rebase"}'.
github_leg() {
  local _gl_prov=github
  [ "$1" = curl ] && _gl_prov=github-api
  printf '{"vcs": {"provider": "%s", "repo": "acme/widget"}%s}\n' "$_gl_prov" "${2:-}" > talos.pipeline.json
  export GITHUB_TOKEN="${GITHUB_TOKEN:-leg-test-token}"
  export GH_QUEUE="$CURL_QUEUE" GH_LINK_QUEUE="$CURL_LINK_QUEUE" GH_REST_LOG="$CURL_LOG"
}

# install_talos — install Talos globally into the sandbox HOME (~/.talos/) and
# configure the sandbox repo (config only). Scripts land in $HOME/.talos/scripts/
# which is probe position 2 in the canonical order, so all probe-using helpers
# find them without per-repo vendoring.
# After calling install_talos, use TALOS_SCRIPTS="$HOME/.talos/scripts" to
# reference installed scripts.
install_talos() {
  # --harness claude: the Claude copies land regardless of whether `claude` is
  # on the ambient PATH (#365).
  bash "$TALOS_ROOT/install.sh" --global --no-agent-skills --harness claude >/dev/null
  # --no-agents-md: the AGENTS.md block is covered by test-install-agents-md.sh;
  # keeping it out of the sandbox leaves every other test file's repo unchanged.
  bash "$TALOS_ROOT/install.sh" "$SANDBOX" --no-agent-skills --no-agents-md --harness claude >/dev/null

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
    # Per-platform notification templates (#280) live one level deeper.
    for sub in "$TALOS_ROOT/templates/$dir"/*/; do
      [ -d "$sub" ] || continue
      mkdir -p "$SANDBOX/.claude/talos/templates/$dir/$(basename "$sub")"
      cp "$sub"*.md "$SANDBOX/.claude/talos/templates/$dir/$(basename "$sub")/" 2>/dev/null || true
    done
  done
  for agent in validator pm developer qa reviewer security adversarial docs planner; do
    for src in "$TALOS_ROOT/agents/$agent.md" "$TALOS_ROOT/.claude/agents/$agent.md"; do
      [ -f "$src" ] && cp "$src" "$SANDBOX/.claude/agents/$agent.md" && break
    done
  done
}

# talos_env_key VAR -- the config key `scripts/talos.sh env` reads for the Step 0
# variable VAR (its table row, #465); empty when VAR has no row.
talos_env_key() { awk -F'\t' -v v="$1" '$1 == v && NF == 3 { print $2 }' "$TALOS_ROOT/scripts/talos.sh"; }
# talos_env_default VAR -- VAR's value in the no-config golden of `talos.sh env`.
talos_env_default() { sed -n "s/^$1=//p" "$TALOS_ROOT/tests/fixtures/talos-env-default.golden"; }
# talos_prompt_text ARGS... -- the stage prompt `scripts/talos.sh prompt ARGS...`
# renders (#468), on stdout, its file removed. Config comes from the cwd (the
# sandbox); a stop line makes it fail with that line on stdout.
talos_prompt_text() {
  local _tpt_out _tpt_file
  _tpt_out="$(bash "$TALOS_ROOT/scripts/talos.sh" prompt "$@")" || { printf '%s\n' "$_tpt_out"; return 1; }
  _tpt_file="${_tpt_out#prompt_file=}"
  [ -f "$_tpt_file" ] || return 1
  cat "$_tpt_file"
  rm -f "${_tpt_file:?}"
}

# finish — print summary for this file and exit non-zero on any failure.
finish() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$_PASS" "$_FAIL"
  [ "$_FAIL" -eq 0 ]
}
