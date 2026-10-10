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
# Python call in scripts/*.sh, install.sh and the fenced recipes in the
# playbook, agent profiles, templates, docs and README is `python3 -I`.
#   * -I (isolated mode) drops the script/cwd entry, PYTHON* env vars and user
#     site. It exists since Python 3.4; Python 3.9+ is the supported floor.
#   * -P / PYTHONSAFEPATH are not used: 3.9 (the macOS system python3) does not
#     know them.
#   * Test doubles in tests/stubs/ are guarded too (#452): they run with the
#     scratch repo as cwd, so a bare `python3 -c` there would run a planted
#     module just the same.
#
# This file checks the pattern two ways:
#   1. a behavioural run: planted json/yaml/subprocess/datetime/pathlib/re
#      modules (they only write marker files inside the sandbox) sit in the cwd
#      of a representative set of scripts, and no marker may appear;
#   2. a static guard: no non-comment python call with -c, - or << lacks -I
#      (scripts, install.sh and tests/stubs/* line by line, markdown inside
#      code fences).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

CFG="$TALOS_ROOT/scripts/pipeline-config.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
NOTIFY="$TALOS_ROOT/scripts/pipeline-notify.sh"
STATUS="$TALOS_ROOT/scripts/pipeline-status.sh"
HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
WT="$TALOS_ROOT/scripts/pipeline-worktree.sh"
MB="$TALOS_ROOT/scripts/pipeline-mergebase.sh"
EV="$TALOS_ROOT/scripts/pipeline-events.sh"

# ---- static guard ----------------------------------------------------------
# unsafe_py_calls [--fenced] <file>...: print file:line:text for every
# non-comment python call (python, python3, python3.N, /usr/bin/env python3,
# $PY, "$PYTHON", "${PY:-python3}") that reaches -c (also inside a combined
# short-flag cluster such as -Bc), - (stdin) or a heredoc without an I in the
# option group before it. Options that take a separate argument (-X dev,
# -W error, --check-hash-based-pycs always) are skipped over, and a backslash
# continuation is joined first (the report names the line the call starts on).
# With --fenced only lines inside a ``` or ~~~ fence are scanned (a fence closes
# on its own marker), so prose in a .md file never trips it. Interpreters also
# cover "$PYBIN", "$(command -v python3)" and "$(which python3)".
# The perl reads each file with 3-arg open (<<>>), never <>: a file named
# "x|" would otherwise be run as a pipe by the 2-arg open that <> uses.
unsafe_py_calls() {
  perl -e '
    my $fenced = @ARGV && $ARGV[0] eq "--fenced" ? shift(@ARGV) : 0;
    my $interp = qr/\bpython(?:3(?:\.\d+)?)?\b|"?\$\{?(?:PY|PYTHON|PYBIN)\b(?::-[^}]*)?\}?"?|"?\$\(\s*(?:command\s+-v|which)\s+python3?\s*\)"?/;
    my $opt    = qr/\s+-(?:[XW]\s+\S+|-check-hash-based-pycs\s+\S+|-?[A-Za-z][\w-]*)/;
    my $trig   = qr/\s+(?:-[A-Za-z]*c\b|-(?:\s|$)|<<)/;
    my ($in, $mark, $buf, $start) = (0, "", "", 0);
    my $check = sub {
      my ($file) = @_;
      my $text = $buf; $buf = "";
      return if $text =~ /^\s*#/;
      while ($text =~ /($interp(?:$opt)*$trig)/g) {
        next if $1 =~ /(?:^|\s)-[A-Za-z]*I[A-Za-z]*(?=\s|$)/;
        print "$file:$start:$text\n";
        last;
      }
    };
    while (<<>>) {
      if ($fenced && /^\s*(```|~~~)/) {
        if (!$in) { ($in, $mark) = (1, $1); } elsif ($1 eq $mark) { $in = 0; }
        $buf = ""; next;
      }
      next if $fenced && !$in;
      $start = $. if $buf eq "";
      chomp(my $l = $_);
      if ($l =~ s/\\$/ /) { $buf .= $l; next; }
      $buf .= $l;
      $check->($ARGV);
    } continue {
      if (eof) { $check->($ARGV) if $buf ne ""; $in = 0; close ARGV; }
    }
  ' -- "$@"
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
python3 -Bc 'x'
python3 -X dev -c 'x'
python3 -W error -c 'x'
python3.12 -c 'x'
$PY -c 'x'
"${PY:-python3}" -c 'x'
x="$(echo hi | "${PY:-python3}" -c 'x')"
PYTHONPATH=a \
  python3 \
  -c 'x'
python3 -BI -c 'x'
python3 -I -Bc 'x'
python3 -I -X dev -c 'x'
python3 -I -W error -c 'x'
python3.12 -I -c 'x'
$PY -I -c 'x'
"${PY:-python3}" -I -c 'x'
PYTHONPATH=a \
  python3 -I \
  -c 'x'
python3 -m json.tool
python3 -m pytest -c cfg
python3 script.py -c 'x'
"$PYBIN" -c 'x'
"$(command -v python3)" -c 'x'
x="$("$(command -v python3)" - <<PY)"
python3 --check-hash-based-pycs always -c 'x'
"$PYBIN" -I -c 'x'
"$(command -v python3)" -I -c 'x'
python3 -I --check-hash-based-pycs always -c 'x'
EOF_GUARD_FIXTURE_Zq7wKd3nVx91
# Lines 1-10 are the original forms; 20-29 the blind spots (combined flags,
# options with an argument, versioned binary, variable interpreters, and a
# continuation, reported at the line the call starts on).
_flagged="$(unsafe_py_calls "$_g" | cut -d: -f2 | tr '\n' ' ')"
# Lines 43-46 are the #452 forms: "$PYBIN", "$(command -v python3)" and a long
# option (with its argument) before -c; 47-49 are their -I counterparts.
assert_eq "1 2 3 4 5 6 7 8 9 10 20 21 22 23 24 25 26 27 43 44 45 46 " "$_flagged" \
  "guard: flags every unsafe python form and nothing else"

# Fenced mode: only code inside a ``` fence (indented or not) counts; prose,
# -I calls and python -m are not flagged.
_gm="$SANDBOX/guard-fixture.md"
cat > "$_gm" <<'EOF_GUARD_FIXTURE_MD_Bn4Yt8pQ2c'
Prose: run python3 -c to see it, or python3 - <<EOF here.

```bash
python3 -c 'x'
python3 -I -c 'x'
```

- list item

  ```bash
         python3 -c "
  print(1)
  "
  ```

Prose again: python3 -c 'x'

```
x="$(printf y | python3 -c 'x')"
python3 -m json.tool
```

~~~bash
python3 -c 'tilde fence'
~~~

~~~
```
python3 -c 'a backtick line inside a tilde fence stays inside it'
```
~~~

Prose after: python3 -c 'x'
EOF_GUARD_FIXTURE_MD_Bn4Yt8pQ2c
_flagged="$(unsafe_py_calls --fenced "$_gm" | cut -d: -f2 | tr '\n' ' ')"
# 24 is a ~~~ fence; 29 sits in a ~~~ fence whose body holds a ``` line (a fence
# only closes on its own marker); the prose line after it is not flagged.
assert_eq "4 11 19 24 29 " "$_flagged" \
  "guard --fenced: flags unsafe calls inside backtick and tilde fences only, indented fences included"

# A file whose name ends in "|" must be read as a file, not run as a pipe.
_pipe_dir="$SANDBOX/pipe-name"
mkdir -p "$_pipe_dir" || exit 1
printf 'python3 -c x\n' > "$_pipe_dir/echo hi|"
_pipe_out="$(cd "$_pipe_dir" && unsafe_py_calls "echo hi|" 2>&1)"
assert_eq "echo hi|:1:python3 -c x" "$_pipe_out" \
  "guard: a filename ending in | is read as a file (3-arg open), not run as a pipe"

_guard_files=("$TALOS_ROOT"/scripts/*.sh "$TALOS_ROOT/install.sh" "$TALOS_ROOT"/tests/stubs/*)
_unsafe="$(unsafe_py_calls "${_guard_files[@]}")"
assert_eq "" "$_unsafe" "guard: no embedded python call in scripts/*.sh, install.sh or tests/stubs/* lacks -I"
[ -z "$_unsafe" ] || printf "%s\n" "$_unsafe" | head -20 | cut -c1-200 >&2

# The playbook, agent profiles, templates, docs and README: fenced code only.
_md_files=()
while IFS= read -r _f; do _md_files+=("$_f"); done < <(
  { find "$TALOS_ROOT/skills" "$TALOS_ROOT/docs" -type f -name '*.md'
    find "$TALOS_ROOT/agents" -maxdepth 1 -type f -name '*.md'
    find "$TALOS_ROOT/templates" -type f
    printf '%s\n' "$TALOS_ROOT/README.md"; } | sort)
_unsafe="$(unsafe_py_calls --fenced "${_md_files[@]}")"
assert_eq "" "$_unsafe" \
  "guard: no fenced python call in skills, agents, templates, docs or README lacks -I"
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
# A lone legacy yml is refused by the gate (#526): the read exits 3 and never
# parses anything, so no planted module can run either way.
check "config read (lone legacy yml refused)" bash "$CFG" merge.method safe
check "vcs read-attempt (lone legacy yml)" bash "$VCS" read-attempt 42
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

finish
