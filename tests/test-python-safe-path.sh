#!/usr/bin/env bash
# test-python-safe-path.sh -- embedded python3 must not put the target repo on
# sys.path (#395).
#
# `python3 -c`, `python3 -` and `python3 - <<EOF` put the current directory
# first on sys.path. Talos scripts run with the target repo (or a PR worktree)
# as cwd, so a file in that repo named after a not-yet-imported module (json.py,
# yaml.py, subprocess.py, ...) used to execute inside Talos as the Talos user.
#
# THE PATTERN (stated once, here and in docs/user-guide.md): every embedded
# Python call in scripts/*.sh and install.sh is the literal `python3 -I`.
#   * -I (isolated mode) drops the script/cwd entry, PYTHON* env vars and user
#     site. It exists since Python 3.4; Python 3.9+ is the supported floor.
#   * -P / PYTHONSAFEPATH are not used: 3.9 (the macOS system python3) does not
#     know them.
#   * The four PyYAML import sites append the user site back (APPEND, so stdlib
#     and system packages win and cwd never enters) so a `pip install --user
#     pyyaml` keeps reading YAML config.
#   * Test doubles in tests/stubs/ are not product code and are not guarded.
#
# This file checks the pattern two ways:
#   1. a behavioural run: planted json/yaml/subprocess/datetime/pathlib/re
#      modules (they only write marker files inside the sandbox) sit in the cwd
#      of a representative set of scripts, and no marker may appear;
#   2. a static guard: no non-comment python call with -c, - or << lacks -I.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

REAL_PY="$(command -v python3)"
CFG="$TALOS_ROOT/scripts/pipeline-config.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
NOTIFY="$TALOS_ROOT/scripts/pipeline-notify.sh"
STATUS="$TALOS_ROOT/scripts/pipeline-status.sh"
HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
WT="$TALOS_ROOT/scripts/pipeline-worktree.sh"
MB="$TALOS_ROOT/scripts/pipeline-mergebase.sh"
EV="$TALOS_ROOT/scripts/pipeline-events.sh"

# ---- static guard ----------------------------------------------------------
# unsafe_py_calls <file>...: print file:line:text for every non-comment line
# that runs python (python, python3, /usr/bin/env python3, "$PYTHON") with -c,
# - (stdin) or a heredoc and no -I in the option group before it.
unsafe_py_calls() {
  perl -e '
    while (<>) {
      if (!/^\s*#/
          && /(?:\bpython3?|"?\$PYTHON\b"?)((?:\s+-[A-Za-z]+)*)\s+(?:-c\b|-(?:\s|$)|<<)/
          && $1 !~ /-[A-Za-z]*I/) {
        print "$ARGV:$.:$_";
      }
    } continue { close ARGV if eof }
  ' "$@"
}

# The guard itself: it must flag the bypass forms and pass the safe ones.
_g="$SANDBOX/guard-fixture.sh"
cat > "$_g" <<'EOF_GUARD_FIXTURE_Zq7wKd3nVx91'
python3 -c 'x'
python3 - <<PY
python3 <<PY
echo "$x" | python3 -
V=1 python3 -c 'x'
/usr/bin/env python3 -c 'x'
"$PYTHON" -c 'x'
$PYTHON - <<PY
python -c 'x'
python3 -B -c 'x'
python3 -I -c 'x'
python3 -I -
V=1 python3 -I - <<PY
python3 -I -B -c 'x'
python3 -B -I -c 'x'
"$PYTHON" -I -c 'x'
  # python3 -c 'a commented example'
echo "python3 is required"
python3 /some/script.py
EOF_GUARD_FIXTURE_Zq7wKd3nVx91
_flagged="$(unsafe_py_calls "$_g" | cut -d: -f2 | tr '\n' ' ')"
assert_eq "1 2 3 4 5 6 7 8 9 10 " "$_flagged" \
  "guard: flags every unsafe python form and nothing else"

_guard_files=("$TALOS_ROOT"/scripts/*.sh "$TALOS_ROOT/install.sh")
_unsafe="$(unsafe_py_calls "${_guard_files[@]}")"
assert_eq "" "$_unsafe" "guard: no embedded python call in scripts/*.sh or install.sh lacks -I"
[ -z "$_unsafe" ] || printf "%s\n" "$_unsafe" | head -20 | cut -c1-200 >&2

# ---- planted-module run ----------------------------------------------------
# The scratch repo is the cwd, the way a target repo is for Talos. Every
# planted module writes a marker file and raises ImportError; nothing else.
mkdir -p "$SANDBOX/markers" "$SANDBOX/tmp" "$SANDBOX/talos-home"
export TMPDIR="$SANDBOX/tmp"
export TALOS_HOME="$SANDBOX/talos-home"
export PIPELINE_RUN_ID="python-safe-path-$$"
MARK="$SANDBOX/markers"
for _m in json yaml subprocess datetime pathlib re; do
  printf 'open(%s, "w").write("ran")\nraise ImportError("planted %s (test #395)")\n' \
    "\"$MARK/$_m\"" "$_m" > "$SANDBOX/$_m.py"
done

# The gh/curl/az/glab doubles use bare `python3 -c` themselves. They are test
# doubles, not product code, so run Talos against -I copies: a marker can then
# only come from Talos.
ISO_STUBS="$SANDBOX/stubs-iso"
mkdir -p "$ISO_STUBS"
for _s in "$STUBS_DIR"/*; do
  perl -pe 's/\bpython3 (?=-c |- |-$|<<)/python3 -I /g' "$_s" > "$ISO_STUBS/$(basename "$_s")"
  chmod +x "$ISO_STUBS/$(basename "$_s")"
done
export PATH="$ISO_STUBS:${PATH#"$STUBS_DIR":}"

git config user.email "test@talos.invalid"
git config user.name "talos-test"
git commit -q --allow-empty -m root
printf '.talos/\n' > "$SANDBOX/.gitignore"
printf '{"base_branch":"main","merge":{"method":"rebase"}}\n' > "$SANDBOX/talos.pipeline.json"

# check <label> <command...>: run with the planted modules in cwd and assert no
# marker appears. The command's own exit status is not under test here.
check() {
  local label="$1" found; shift
  rm -f "$MARK"/*
  ( cd "$SANDBOX" && "$@" ) >/dev/null 2>&1 </dev/null || true
  found="$(ls "$MARK" | tr '\n' ' ')"
  assert_eq "" "$found" "no planted module ran: $label"
}

check "config read (JSON)" bash "$CFG" merge.method safe
check "config --dump" bash "$CFG" --dump

printf 'base_branch: main\nmerge:\n  method: rebase\n' > "$SANDBOX/talos.pipeline.yml"
mv "$SANDBOX/talos.pipeline.json" "$SANDBOX/talos.pipeline.json.off"
check "config read (YAML)" bash "$CFG" merge.method safe
check "vcs read-attempt (YAML config)" bash "$VCS" read-attempt 42
rm -f "$SANDBOX/talos.pipeline.yml"
mv "$SANDBOX/talos.pipeline.json.off" "$SANDBOX/talos.pipeline.json"

export STUB_ISSUE_COMMENTS_JSON='[{"body":"**Agent:** developer (talos)\n\nhi","user":{"login":"x"},"created_at":"2026-01-01T00:00:00Z"}]'
check "vcs view-issue"          bash "$VCS" view-issue 42
check "vcs view-issue --spec"   bash "$VCS" view-issue 42 --spec
check "vcs read-comments"       bash "$VCS" read-comments 42
check "vcs read-attempt"        bash "$VCS" read-attempt 42
check "vcs has-spec"            bash "$VCS" has-spec 42
check "vcs list-issues"         bash "$VCS" list-issues
check "vcs list-prs"            bash "$VCS" list-prs
check "vcs view-pr"             bash "$VCS" view-pr fix/issue-42-x
check "vcs pr-checks-required"  bash "$VCS" pr-checks-required 5
check "vcs check-pr-files"      bash "$VCS" check-pr-files 5 --max 5
check "vcs label-issue"         bash "$VCS" label-issue 42 --add pipeline:dev
check "vcs assert-sync"         bash "$VCS" assert-sync
check "notify"                  bash "$NOTIFY" validator "#42" "hello" 42
check "status"                  bash "$STATUS" 42 "Done"
check "hooks post_stage"        bash "$HOOKS" post_stage qa qa 42 --verdict PASS
check "hooks pre_dispatch"      bash "$HOOKS" pre_dispatch developer 42
check "worktree tag"            bash "$WT" tag 42
check "worktree list"           bash "$WT" list
check "worktree sweep"          bash "$WT" sweep
check "mergebase"               bash "$MB" 5 --union-paths CHANGELOG.md
check "events log"              bash "$EV" log --event qa --role qa --issue 42
check "events list"             bash "$EV" list --issue 42
check "events cost"             bash "$EV" cost --issue 42
check "events cost --line"      bash "$EV" cost --issue 42 --line

# ---- user-site PyYAML ------------------------------------------------------
# Under -I the user site is dropped, so the YAML import sites append it back.
# `python3 -S` (a PATH shim) removes system site-packages, so a system PyYAML
# cannot answer and the only candidates are cwd and the user site.
NOSYS="$SANDBOX/nosys-bin"
mkdir -p "$NOSYS"
printf '#!/bin/sh\nexec "%s" -S "$@"\n' "$REAL_PY" > "$NOSYS/python3"
chmod +x "$NOSYS/python3"

UB="$SANDBOX/ub"
USER_SITE="$(cd / && PYTHONUSERBASE="$UB" "$REAL_PY" -I -c 'import site; print(site.getusersitepackages())')"
mkdir -p "$USER_SITE/yaml"
cat > "$USER_SITE/yaml/__init__.py" <<'EOF_USERSITE_YAML_k3Hs9Rv2Lq0p'
YAMLError = ValueError
def safe_load(f):
    return {"merge": {"method": "from-user-site-yaml"}}
EOF_USERSITE_YAML_k3Hs9Rv2Lq0p

printf 'merge:\n  method: rebase\n' > "$SANDBOX/talos.pipeline.yml"
mv "$SANDBOX/talos.pipeline.json" "$SANDBOX/talos.pipeline.json.off"

rm -f "$MARK"/*
_got="$(cd "$SANDBOX" && PATH="$NOSYS:$PATH" PYTHONUSERBASE="$UB" bash "$CFG" merge.method safe 2>/dev/null)"
assert_eq "from-user-site-yaml" "$_got" \
  "user-site PyYAML: a YAML config read still finds PyYAML under PYTHONUSERBASE"
assert_eq "" "$(ls "$MARK" | tr '\n' ' ')" \
  "user-site PyYAML: the planted yaml.py in cwd did not run"

# No PyYAML in the user site: the planted yaml.py in cwd must still not run.
_got="$(cd "$SANDBOX" && PATH="$NOSYS:$PATH" PYTHONUSERBASE="$SANDBOX/ub-empty" bash "$CFG" merge.method safe 2>/dev/null)"
assert_eq "" "$(ls "$MARK" | tr '\n' ' ')" \
  "no user-site PyYAML: the planted yaml.py in cwd did not run"
assert_eq "safe" "$_got" \
  "no user-site PyYAML: the YAML config falls back (default returned), not a crash"

finish
