#!/usr/bin/env bash
# pipeline-criteria.sh -- map a spec's acceptance criteria to test results by
# id (#421). ids, map and report are pure text processing: no network, no LLM,
# no git. qa-run (#549) is the one verb that drives git and the test runner.
#
# The PM numbers each criterion `AC<n>` and marks it `(test)` or
# `(prose: <reason>)`; the developer names each criterion's test after its id
# (`AC2 rejects an expired token`), so a runner's own output maps back to the
# criterion. Talos's test helpers print one assertion label per line,
# `  ok  <label>` or `FAIL  <label>`; the id is the first word of the label.
#
# Usage:
#   pipeline-criteria.sh ids <spec-file>
#       One line per criterion: `AC<n> test|prose`. A spec with `AC<n>` ids
#       uses them. A spec with none (no PM stage: the issue's own checklist)
#       numbers its `- [ ]` / `- [x]` items 1-based; an unmarked item is test.
#   pipeline-criteria.sh map <runner-output-file> [--spec <spec-file>]
#       `AC<n> pass|fail` for each id seen in the output (`fail` when any
#       assertion for the id failed). With --spec: each (test) id of the spec,
#       `missing` when the output has no line for it (a crash, a typo).
#   pipeline-criteria.sh report --spec <spec-file> --red <output> \
#                               --head <output> --red-sha <sha8>
#       (--red-sha must be 7-40 hex characters, else exit 2.)
#       The QA verdict lines, one per id:
#         AC<n> red@<sha8> green@head       red at the first commit, green at head
#         AC<n> green@head (red: missing)   no per-id output at red: a note
#         AC<n> FAIL vacuous (green at red@<sha8>)
#         AC<n> FAIL head=<fail|missing> red=<state>
#         AC<n> prose hand-checked
#       Exit 1 when any line is FAIL.
#   pipeline-criteria.sh qa-run <issue> <pr> [--base <branch>]
#       The whole QA criteria check in one call (#549), run from the QA
#       worktree: tags the worktree for <issue> (best effort; the main checkout
#       is refused), checks `pr-mergeable` (CONFLICTING: nothing runs), checks
#       out the PR, reads the spec (`view-issue <issue> --spec`) and its
#       `Tests:` line, validates every item, runs the test files at the PR head
#       and at the red commit (the first commit after the merge-base), and
#       prints the `report` lines plus one verdict line:
#         qa-run: verdict PASS ...      the mechanical half passed (prose is yours)
#         qa-run: verdict FAIL <why>    exit 1
#         qa-run: verdict BLOCKED spec: <why>    exit 4 (#610): the spec is
#             unusable (the four faults of spec-usable below) and the PR was
#             not judged; no test ran
#       The Tests: line is DATA, never a command. A path must be repo-relative,
#       tracked at the PR head, match ^[A-Za-z0-9_./-]+$ and not start with `-`
#       or contain `..`; a name filter must match ^[A-Za-z0-9_|. -]+$, not
#       start with `-` and not be a runner command. Anything else is refused:
#       nothing from the spec runs and the verdict is BLOCKED. With
#       tests/run-tests.sh the files run as `--for <path> ... --strict
#       --no-cache` (a cached run cannot hide the per-id lines, and no path
#       falls back to the full suite); otherwise the first `verify:` command
#       that mentions "test" runs with the paths and filters appended as
#       separate quoted arguments. Exit 3: no usable runner.
#   pipeline-criteria.sh spec-check <spec-file>
#       Would qa-run accept this spec's `Tests:` line (#594)? Pure text, the
#       parser qa-run uses; `talos.sh done pm` runs it on the spec the PM just
#       posted. One line:
#         spec-check: ok
#         spec-check: refused tests-line-refused: <the parser's reason>
#         spec-check: refused tests-line-missing: <n> test criteria and no usable Tests: line
#         spec-check: refused tests-line-open: <the line>
#       tests-line-open (#648): a line other than the `Tests:` line leaves a test
#       file open (`developer's choosing`, `developer's choice`, `new or existing
#       file`, any case); every test criterion's file is on the `Tests:` line.
#       Exit 1 on a refusal. A spec with no test criterion (prose only, or no
#       checklist) needs no `Tests:` line and is ok.
#   pipeline-criteria.sh spec-usable <issue>
#       Can QA use this issue's spec (#610)? The check qa-run makes, on its own:
#       the read of `view-issue <issue> --spec`, the criteria table, the
#       `Tests:` line. No git command, no test. One line:
#         spec-usable: ok                      exit 0
#         spec-usable: BLOCKED spec: <why>     exit 4
#       <why> is one of: `unreadable for issue #<N>`, `no criteria checklist`,
#       `Tests: line refused (<the parser's reason>)`, `<n> test criteria and
#       no Tests: line`. `talos.sh run` asks it after a QA FAIL: a spec fault
#       blocks the issue instead of starting a developer fix round.
#   pipeline-criteria.sh placement <issue>
#       Is every (test) criterion's id in a test file the `Tests:` line names
#       (#648)? Run from the PR worktree; pure text, no test runs. The spec is
#       read through the same parse as qa-run (an unusable spec is BLOCKED). An
#       id counts when it is the first word of an assertion label (`"AC2 ..."`,
#       `ok  AC2 ...`) in one of those files; the same id in any other file does
#       not. Output and exit codes:
#         placement: ok                       exit 0
#         AC<n> not-in-tests-files            one per missing id, then
#         placement: GAP <n>                  exit 1
#         placement: BLOCKED spec: <why>      exit 4 (the spec-usable reasons)
#
# Exit codes: 0 ok, 1 a failing report or an unreadable/empty input, 2 usage, 3 no usable runner, 4 an unusable spec.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '/^# Usage:/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# ids FILE: the criteria table, `AC<n> test|prose`.
cmd_ids() {
  local file="${1:-}"
  [ -n "$file" ] || usage
  [ -f "$file" ] || { echo "pipeline-criteria: ids: no such file: $file" >&2; return 1; }
  local out
  out="$(awk '
    function kind(l) { return (l ~ /\(prose[:)]/) ? "prose" : "test" }
    /^[ \t]*[-*][ \t]+\[[ xX]\][ \t]/ {
      n++; plain_kind[n] = kind($0)
      if (match($0, /^[ \t]*[-*][ \t]+\[[ xX]\][ \t]+[*`]*AC[0-9]+/)) {
        id = substr($0, RSTART, RLENGTH); sub(/^.*AC/, "AC", id)
        ac++; ac_id[ac] = id; ac_kind[ac] = kind($0)
      }
    }
    END {
      if (ac > 0) for (i = 1; i <= ac; i++) print ac_id[i], ac_kind[i]
      else for (i = 1; i <= n; i++) print "AC" i, plain_kind[i]
    }' "$file")"
  [ -n "$out" ] || { echo "pipeline-criteria: ids: no criteria checklist in $file" >&2; return 1; }
  printf '%s\n' "$out"
}

# map FILE [--spec SPEC]: `AC<n> pass|fail|missing`.
cmd_map() {
  local file="${1:-}" spec="" want=""
  [ -n "$file" ] || usage
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec) spec="${2:-}"; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -f "$file" ] || { echo "pipeline-criteria: map: no such file: $file" >&2; return 1; }
  if [ -n "$spec" ]; then
    want="$(cmd_ids "$spec" | awk '$2 == "test" { printf "%s ", $1 }')" || return 1
  fi
  awk -v want="$want" '
    match($0, /^[ \t]*(ok|FAIL)[ \t]+AC[0-9]+([^0-9]|$)/) {
      line = substr($0, RSTART, RLENGTH)
      status = (line ~ /^[ \t]*ok/) ? "pass" : "fail"
      sub(/^[ \t]*(ok|FAIL)[ \t]+/, "", line); sub(/[^0-9]$/, "", line)
      if (!(line in state)) { order[++n] = line; state[line] = status }
      else if (status == "fail") state[line] = "fail"
    }
    END {
      if (want != "") {
        m = split(want, w, " ")
        for (i = 1; i <= m; i++) print w[i], ((w[i] in state) ? state[w[i]] : "missing")
      } else for (i = 1; i <= n; i++) print order[i], state[order[i]]
    }' "$file"
}

# report --spec F --red F --head F --red-sha SHA8
cmd_report() {
  local spec="" red="" head="" sha=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec) spec="${2:-}"; shift 2 || usage ;;
      --red) red="${2:-}"; shift 2 || usage ;;
      --head) head="${2:-}"; shift 2 || usage ;;
      --red-sha) sha="${2:-}"; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -n "$spec" ] && [ -n "$red" ] && [ -n "$head" ] && [ -n "$sha" ] || usage
  case "$sha" in
    *[!0-9a-fA-F]*) echo "pipeline-criteria: report: --red-sha must be 7-40 hex characters" >&2; return 2 ;;
  esac
  if [ "${#sha}" -lt 7 ] || [ "${#sha}" -gt 40 ]; then
    echo "pipeline-criteria: report: --red-sha must be 7-40 hex characters" >&2; return 2
  fi
  local table red_map head_map id kind r h rc=0
  table="$(cmd_ids "$spec")" || return 1
  red_map="$(cmd_map "$red" --spec "$spec")" || return 1
  head_map="$(cmd_map "$head" --spec "$spec")" || return 1
  while read -r id kind; do
    if [ "$kind" = "prose" ]; then
      printf '%s prose hand-checked\n' "$id"
      continue
    fi
    r="$(awk -v i="$id" '$1 == i { print $2 }' <<<"$red_map")"
    h="$(awk -v i="$id" '$1 == i { print $2 }' <<<"$head_map")"
    if [ "$h" != "pass" ]; then
      printf '%s FAIL head=%s red=%s\n' "$id" "${h:-missing}" "${r:-missing}"; rc=1
    elif [ "$r" = "fail" ]; then
      printf '%s red@%s green@head\n' "$id" "$sha"
    elif [ "$r" = "pass" ]; then
      printf '%s FAIL vacuous (green at red@%s)\n' "$id" "$sha"; rc=1
    else
      printf '%s green@head (red: missing)\n' "$id"
    fi
  done <<<"$table"
  return "$rc"
}

# ── qa-run (#549) ────────────────────────────────────────────────────────────

# The spec text from `view-issue --spec` JSON on stdin: the latest PM spec
# comment, else the issue body (no PM stage). Exit 1 when it is not that JSON.
_QA_SPEC_PY='
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
text = None
for c in d.get("comments") or []:
    b = c.get("body") if isinstance(c, dict) else None
    # view-issue --spec has vetted the comment: a bare spec, or one under the
    # pm stage header line (#645).
    lines = [l for l in b.splitlines() if l.strip()][:2] if isinstance(b, str) else []
    if any(l.lstrip().startswith("**PM spec") for l in lines):
        text = b
if text is None:
    text = d.get("body") if isinstance(d.get("body"), str) else ""
sys.stdout.write(text)
'

# The spec on stdin -> its `Tests:` items as data, one record per line:
#   P<TAB>path  F<TAB>filter  B<TAB>reason (refused)  N (no usable Tests: line)
# Nothing here executes anything; a value is a path or a filter or refused.
_QA_TESTS_PY='
import re, sys
text = sys.stdin.read()
PATH_RE = re.compile(r"^[A-Za-z0-9_./-]+$")
FILT_RE = re.compile(r"^[A-Za-z0-9_|. -]+$")
RUNNERS = set("npm npx yarn pnpm bun deno node pytest python python3 py.test tox nox bash sh zsh dash env make cmake ninja go cargo mvn gradle gradlew ant dotnet jest vitest mocha ava ruby rake rspec bundle php phpunit composer perl prove swift sbt mix elixir".split())

def show(v):
    v = "".join(ch if 32 <= ord(ch) < 127 else "?" for ch in v)
    return v[:60] + ("..." if len(v) > 60 else "")

def refuse(reason, v=""):
    print("B\t" + reason + ((": " + show(v)) if v else ""))
    sys.exit(0)

lines = text.splitlines()
rest = None
for i, l in enumerate(lines):
    m = re.match(r"^\s*(?:[-*+]\s+)?(?:\[[ xX]\]\s+)?\**Tests\**:\**\s*(.*)$", l)
    if m:
        rest = m.group(1).strip()
        for l2 in lines[i + 1:]:
            m2 = re.match(r"^\s+[-*+]\s+(.*)$", l2)
            if not m2:
                break
            rest += " " + m2.group(1).strip()
        break
if rest is None or not rest.strip("* "):
    print("N")
    sys.exit(0)

spans = re.findall(r"`([^`]*)`", rest)
if spans:
    residue = re.sub(r"`[^`]*`", " ", rest)
    if re.search(r"[;|&$<>\\{}`]", residue):
        refuse("shell syntax beside the test list", residue.strip())
    items = spans
else:
    items = [t for t in re.split(r"[,\s]+", rest.strip("* ")) if t]

paths, filters = [], []
for raw in items:
    it = raw.strip()
    if not it:
        continue
    if ".." in it:
        refuse("path or filter contains ..", it)
    is_path = "/" in it or re.search(r"\.[A-Za-z0-9]+$", it)
    if is_path:
        if not PATH_RE.match(it):
            refuse("test path outside [A-Za-z0-9_./-]", it)
        if it.startswith("/") or it.startswith("-"):
            refuse("test path is absolute or starts with -", it)
        if it.endswith("/"):
            refuse("test path is a directory", it)
        while it.startswith("./"):
            it = it[2:]
        if it and it not in paths:
            paths.append(it)
    else:
        words = it.split()
        if not FILT_RE.match(it) or it.startswith("-"):
            refuse("name filter outside [A-Za-z0-9_|. -] or starting with -", it)
        if any(w.startswith("-") for w in words):
            refuse("name filter holds a flag", it)
        if words and words[0].lower() in RUNNERS:
            refuse("a runner command, not a test path", it)
        if it not in filters:
            filters.append(it)
if len(paths) > 20:
    refuse("more than 20 test paths")
if not paths and not filters:
    print("N")
    sys.exit(0)
for p in paths:
    print("P\t" + p)
for f in filters:
    print("F\t" + f)
'

# _tests_line SPEC: the spec's `Tests:` line through _QA_TESTS_PY, the one parse
# qa-run and spec-check share (#594). It sets the caller's paths, filters,
# refused (the parser's reason) and found.
_tests_line() {
  local tag val
  paths=(); filters=(); refused=""; found=0
  while IFS="$(printf '\t')" read -r tag val; do
    case "$tag" in
      P) paths+=("$val"); found=1 ;;
      F) filters+=("$val"); found=1 ;;
      B) refused="$val" ;;
    esac
  done <<EOF
$(python3 -I -c "$_QA_TESTS_PY" < "$1")
EOF
}

# spec-check FILE (#594): the `Tests:` line first, then the test criteria it
# would have to cover. One line; exit 1 on a refusal.
cmd_spec_check() {
  local spec="${1:-}" paths filters refused found n_test open_line
  [ $# -eq 1 ] && [ -n "$spec" ] || usage
  [ -f "$spec" ] && [ -r "$spec" ] || { echo "pipeline-criteria: spec-check: no such file: $spec" >&2; return 2; }
  _tests_line "$spec"
  if [ -n "$refused" ]; then
    echo "spec-check: refused tests-line-refused: $refused"
    return 1
  fi
  n_test="$(cmd_ids "$spec" 2>/dev/null | awk '$2 == "test"' | wc -l | tr -d ' ')"
  if [ "$n_test" -gt 0 ]; then
    # #648: a test file left to the developer is a file QA does not run.
    open_line="$(grep -vE '^[[:space:]]*([-*+][[:space:]]+)?(\[[ xX]\][[:space:]]+)?\**Tests\**:' "$spec" \
      | grep -iE "developer.{1,3}s (choosing|choice)|new or existing file" | head -n 1 \
      | tr -cd '[:print:]' | sed 's/^ *//' | cut -c1-60)"
    if [ -n "$open_line" ]; then
      echo "spec-check: refused tests-line-open: $open_line"
      return 1
    fi
  fi
  if [ "$found" -eq 0 ]; then
    if [ "$n_test" -gt 0 ]; then
      echo "spec-check: refused tests-line-missing: $n_test test criteria and no usable Tests: line"
      return 1
    fi
  fi
  echo "spec-check: ok"
}

# _spec_usable ISSUE FILE (#610): the one definition of "QA can use the spec",
# shared by qa-run and spec-usable. It reads `view-issue ISSUE --spec` into
# FILE and sets the caller's table (the criteria), paths, filters, refused and
# found (the `Tests:` line) and spec_why: empty for a usable spec, else the
# fixed text of the fault. No git command, no test.
_spec_usable() {
  local issue="$1" spec="$2" n
  table=""; paths=(); filters=(); refused=""; found=0; spec_why=""
  if ! bash "$SCRIPT_DIR/pipeline-vcs.sh" view-issue "$issue" --spec 2>/dev/null | python3 -I -c "$_QA_SPEC_PY" > "$spec" || [ ! -s "$spec" ]; then
    spec_why="unreadable for issue #$issue"; return 1
  fi
  table="$(cmd_ids "$spec" 2>/dev/null)" || { spec_why="no criteria checklist"; return 1; }
  _tests_line "$spec"
  [ -z "$refused" ] || { spec_why="Tests: line refused ($refused)"; return 1; }
  n="$(printf '%s\n' "$table" | awk '$2 == "test"' | wc -l | tr -d ' ')"
  [ "$found" -eq 1 ] || [ "$n" -eq 0 ] || { spec_why="$n test criteria and no Tests: line"; return 1; }
}

# spec-usable ISSUE (#610): one line; exit 4 for an unusable spec.
cmd_spec_usable() {
  local issue="${1:-}" tmp table paths filters refused found spec_why
  [ $# -eq 1 ] || usage
  case "$issue" in ''|*[!0-9]*) usage ;; esac
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/talos-spec-usable.XXXXXX")" && [ -d "$tmp" ] \
    || { echo "pipeline-criteria: spec-usable: no scratch directory" >&2; return 1; }
  _spec_usable "$issue" "$tmp/spec.md"
  rm -rf "${tmp:?}"
  if [ -n "$spec_why" ]; then
    echo "spec-usable: BLOCKED spec: $spec_why"
    return 4
  fi
  echo "spec-usable: ok"
}

# placement ISSUE (#648): one line per (test) criterion whose id is in no file
# of the `Tests:` line, run from the PR worktree.
cmd_placement() {
  local issue="${1:-}" tmp table paths filters refused found spec_why top id p hit gaps=0 out=""
  [ $# -eq 1 ] || usage
  case "$issue" in ''|*[!0-9]*) usage ;; esac
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/talos-placement.XXXXXX")" && [ -d "$tmp" ] \
    || { echo "pipeline-criteria: placement: no scratch directory" >&2; return 1; }
  _spec_usable "$issue" "$tmp/spec.md"
  rm -rf "${tmp:?}"
  if [ -n "$spec_why" ]; then
    echo "placement: BLOCKED spec: $spec_why"
    return 4
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top="$(pwd)"
  cd "$top" || return 1
  for id in $(printf '%s\n' "$table" | awk '$2 == "test" { print $1 }'); do
    hit=0
    for p in ${paths[@]+"${paths[@]}"}; do
      if [ -f "$p" ] && grep -qE "([\"']|(ok|FAIL)[[:space:]]+)$id([^A-Za-z0-9_]|\$)" "$p"; then hit=1; break; fi
    done
    [ "$hit" -eq 1 ] || { out="$out$id not-in-tests-files"$'\n'; gaps=$((gaps + 1)); }
  done
  if [ "$gaps" -gt 0 ]; then
    printf '%s' "$out"
    echo "placement: GAP $gaps"
    return 1
  fi
  echo "placement: ok"
}

# A path a red (tests-only) commit may touch.
_qa_is_test_path() {
  case "$1" in
    tests/*|test/*|*/tests/*|*/test/*|__tests__/*|*/__tests__/*|spec/*|*/spec/*|specs/*|*/specs/*) return 0 ;;
    test_*|test-*|*/test_*|*/test-*|*_test.*|*-test.*|*.test.*|*.spec.*|*_spec.*) return 0 ;;
  esac
  return 1
}

# Put HEAD back where it was (idempotent; also an exit hook).
_QA_ORIG=""
_QA_MOVED=0
# Where the invoking checkout stood before the detached fallback of step 3 (a
# branch name, or a SHA when it started detached); _qa_restore_home puts it back.
_QA_HOME=""
_qa_restore() {
  [ "$_QA_MOVED" -eq 1 ] || return 0
  if git checkout -q "$_QA_ORIG" >/dev/null 2>&1; then
    _QA_MOVED=0
  else
    printf 'qa-run: WARNING: could not return to %s; run: git checkout %s\n' "$_QA_ORIG" "$_QA_ORIG" >&2
    return 1
  fi
}

# Return the invoking checkout to _QA_HOME (idempotent; also an exit hook).
# Same warning line as _qa_restore; the non-zero status is the caller's to use.
_qa_restore_home() {
  [ -n "$_QA_HOME" ] || return 0
  if git checkout -q "$_QA_HOME" -- >/dev/null 2>&1; then
    _QA_HOME=""
  else
    printf 'qa-run: WARNING: could not return to %s; run: git checkout %s\n' "$_QA_HOME" "$_QA_HOME" >&2
    return 1
  fi
}

# Exit hook: both restores, each tried.
_qa_exit() { _qa_restore; _qa_restore_home; }

# _qa_verdict_fail REASON -- the closing line of a refused or failed run.
_qa_fail() {
  printf 'qa-run: verdict FAIL %s\n' "$1"
  return 1
}

cmd_qa_run() {
  local issue="${1:-}" pr="${2:-}" base="" top
  [ $# -ge 2 ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="${2:-}"; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  case "$issue" in ''|*[!0-9]*) usage ;; esac
  case "$pr" in ''|*[!0-9]*) usage ;; esac
  case "$base" in *[!A-Za-z0-9_./-]*) usage ;; esac

  top="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "pipeline-criteria: qa-run: not inside a git checkout" >&2; return 1; }
  cd "$top" || return 1

  if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
    # shellcheck source=pipeline-cfg-cache.sh
    . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
    _talos_on_exit '_qa_exit'
  else
    cfg() { :; }
    trap '_qa_exit' EXIT
  fi
  local vcs="$SCRIPT_DIR/pipeline-vcs.sh" tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/talos-qa-run.XXXXXX")" && [ -d "$tmp" ] \
    || { echo "pipeline-criteria: qa-run: no scratch directory" >&2; return 1; }
  if type _talos_on_exit >/dev/null 2>&1; then _talos_on_exit "rm -rf \"$tmp\""; fi

  # 1. Let the sweeps find this working copy again once the PR is done (#240).
  #    Best effort: the main checkout is refused, a missing script is ignored.
  [ ! -f "$SCRIPT_DIR/pipeline-worktree.sh" ] \
    || bash "$SCRIPT_DIR/pipeline-worktree.sh" tag "$issue" >/dev/null 2>&1 || :

  # 2. A conflicting PR gets no CI run: stop before anything waits on one.
  local mg mg_rc
  mg="$(bash "$vcs" pr-mergeable "$pr" 2>/dev/null)"; mg_rc=$?
  if [ "$mg_rc" -eq 1 ] && [ "$mg" = CONFLICTING ]; then
    echo "qa-run: PR #$pr is CONFLICTING with its base; nothing ran"
    _qa_fail "PR conflicts with base; no CI run will be scheduled"
    return $?
  elif [ "$mg_rc" -ne 0 ]; then
    echo "qa-run: pr-mergeable did not answer for PR #$pr (exit $mg_rc); nothing ran"
    _qa_fail "mergeability unverified"
    return $?
  fi

  # 3. The PR at its head. Another worktree holding the PR branch (the
  #    developer's, under isolation: worktree) makes git refuse the named
  #    checkout: run detached at the PR's head SHA instead (#589).
  if ! bash "$vcs" checkout-pr "$pr" >/dev/null 2>"$tmp/checkout.err"; then
    local held_sha=""
    if grep -qE 'used by worktree|checked out at' "$tmp/checkout.err" 2>/dev/null; then
      held_sha="$(bash "$vcs" pr-head "$pr" 2>/dev/null)"
      if [[ "$held_sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
        git cat-file -e "$held_sha^{commit}" 2>/dev/null \
          || git fetch -q origin "$(bash "$vcs" pr-head-ref "$pr" 2>/dev/null)" >/dev/null 2>&1 || :
        _QA_HOME="$(git symbolic-ref -q --short HEAD 2>/dev/null || git rev-parse HEAD 2>/dev/null)"
        git checkout -q --detach "$held_sha" >/dev/null 2>&1 || { held_sha=""; _QA_HOME=""; }
      else
        held_sha=""
      fi
    fi
    if [ -z "$held_sha" ]; then
      echo "qa-run: checkout-pr $pr failed: $(head -c 200 "$tmp/checkout.err" | tr -cd '[:print:]')"
      _qa_fail "could not check out the PR"
      return $?
    fi
    echo "qa-run: PR #$pr's branch is held by another worktree; running detached at ${held_sha:0:8}"
  fi
  local head head8
  head="$(git rev-parse HEAD 2>/dev/null)" || { _qa_fail "no HEAD after checkout"; return $?; }
  head8="${head:0:8}"

  # 4. The spec, its criteria table and its Tests: line, as data. A spec QA
  #    cannot use is a fault of the spec, not a finding on the PR (#610).
  local spec="$tmp/spec.md" table paths filters refused found spec_why
  if ! _spec_usable "$issue" "$spec"; then
    printf 'qa-run: verdict BLOCKED spec: %s\n' "$spec_why"
    return 4
  fi
  local n_test n_prose
  n_test="$(printf '%s\n' "$table" | awk '$2 == "test"' | wc -l | tr -d ' ')"
  n_prose="$(printf '%s\n' "$table" | awk '$2 == "prose"' | wc -l | tr -d ' ')"

  # 5. No Tests: line on a usable spec: every criterion is prose.
  if [ "$found" -eq 0 ]; then
    printf '%s\n' "$table" | awk '{ printf "%s prose hand-checked\n", $1 }'
    printf 'qa-run: verdict PASS (prose only: %s criteria to hand-check; no tests to run)\n' "$n_prose"
    return 0
  fi

  # 6. Paths must be tracked files at the PR head.
  local p present=() missing=()
  for p in ${paths[@]+"${paths[@]}"}; do
    if [ -d "$p" ]; then
      printf 'qa-run: verdict BLOCKED spec: Tests: path is a directory: %s\n' "$p"
      return 4
    fi
  done
  for p in ${paths[@]+"${paths[@]}"}; do
    if [ -f "$p" ] && git cat-file -e "$head:$p" 2>/dev/null; then present+=("$p"); else missing+=("$p"); fi
  done
  for p in ${missing[@]+"${missing[@]}"}; do echo "qa-run: missing test file: $p"; done

  # 7. The runner.
  local runner="" vline=""
  if [ -f tests/run-tests.sh ]; then
    runner=talos
  else
    vline="$(cfg verify 2>/dev/null | grep -i 'test' | head -n 1)"
    [ -z "$vline" ] || runner=verify
  fi
  if [ -z "$runner" ]; then
    echo "qa-run: no tests/run-tests.sh and no test command in verify:"
    printf 'qa-run: verdict FAIL no usable test runner; hand-check the criteria and say so\n'
    return 3
  fi
  # _qa_exec OUTFILE PATH... -- one run; output (stdout+stderr) to OUTFILE.
  _qa_exec() {
    local out="$1" a=() q
    shift
    if [ "$runner" = talos ]; then
      for q in "$@"; do a+=(--for "$q"); done
      bash "$SCRIPT_DIR/pipeline-verify.sh" --issue "$issue" --worktree "$top" -- \
        bash tests/run-tests.sh "${a[@]}" --strict --no-cache > "$out" 2>&1
    else
      bash "$SCRIPT_DIR/pipeline-verify.sh" --issue "$issue" --worktree "$top" -- \
        bash -c "$vline \"\$@\"" talos-qa "$@" ${filters[@]+"${filters[@]}"} > "$out" 2>&1
    fi
  }

  # 8. Head run.
  : > "$tmp/head.out"; : > "$tmp/red.out"
  local head_rc=0
  if [ "${#present[@]}" -gt 0 ]; then
    _qa_exec "$tmp/head.out" "${present[@]}"; head_rc=$?
  fi

  # 9. Red run: the first commit after the merge-base, when its own change is tests-only.
  local note="" mb red="" red8="" f bad_path=""
  if [ "${#present[@]}" -eq 0 ]; then
    note="no test file to run; red proof skipped"
  else
    local bref="${base:-$(cfg base_branch 2>/dev/null)}"
    [ -n "$bref" ] || bref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
    [ -n "$bref" ] || bref=main
    mb="$(git merge-base HEAD "origin/$bref" 2>/dev/null || git merge-base HEAD "$bref" 2>/dev/null)"
    [ -z "$mb" ] || red="$(git rev-list --reverse "$mb"..HEAD 2>/dev/null | head -n 1)"
    if [ -z "$red" ]; then
      note="no red commit found after the merge-base with $bref; red proof skipped"
    else
      red8="${red:0:8}"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        _qa_is_test_path "$f" || { bad_path="$f"; break; }
      done <<EOF
$(git diff-tree --no-commit-id --name-only -r --root "$red" 2>/dev/null)
EOF
      if [ -n "$bad_path" ]; then
        note="red commit $red8 is not tests-only ($(printf '%s' "$bad_path" | tr -cd '[:print:]' | head -c 80)); red proof skipped"
        red=""
      elif [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        note="the head run left tracked files modified; red proof skipped"
        red=""
      fi
    fi
  fi
  if [ -n "$red" ]; then
    local at_red=()
    for p in "${present[@]}"; do
      git cat-file -e "$red:$p" 2>/dev/null && at_red+=("$p")
    done
    if [ "${#at_red[@]}" -eq 0 ]; then
      note="no test file exists at the red commit $red8; red proof skipped"
    else
      _QA_ORIG="$(git symbolic-ref -q --short HEAD 2>/dev/null || git rev-parse HEAD)"
      if git checkout -q --detach "$red" >/dev/null 2>&1; then
        _QA_MOVED=1
        _qa_exec "$tmp/red.out" "${at_red[@]}"
        _qa_restore || { _qa_fail "could not return to $_QA_ORIG after the red run"; return $?; }
      else
        note="could not check out the red commit $red8; red proof skipped"
      fi
    fi
  fi

  # 10. The report.
  local lines rep_rc=0 n_fail
  local tests_s=""
  for p in ${present[@]+"${present[@]}"}; do tests_s="${tests_s:+$tests_s }$p"; done
  echo "qa-run: issue #$issue PR #$pr head $head8 red ${red8:-none} runner $runner tests ${tests_s:-none}"
  [ -z "$note" ] || echo "note: $note"
  lines="$(cmd_report --spec "$spec" --red "$tmp/red.out" --head "$tmp/head.out" --red-sha "${red8:-$head8}")"; rep_rc=$?
  printf '%s\n' "$lines"
  n_fail="$(printf '%s\n' "$lines" | grep -c ' FAIL ')"
  if [ "$n_fail" -gt 0 ] || [ "$head_rc" -ne 0 ] || [ "${#missing[@]}" -gt 0 ]; then
    if grep -qE '^FAIL' "$tmp/head.out" 2>/dev/null; then
      echo "head run failures (test output, data):"
      grep -E -A2 '^FAIL' "$tmp/head.out" | cut -c1-200 | head -n 24 | sed 's/^/  /'
    fi
  fi
  local why=""
  [ "$n_fail" -eq 0 ] || why="$n_fail test criteria FAIL"
  [ "${#missing[@]}" -eq 0 ] || why="${why:+$why; }${#missing[@]} test file(s) missing"
  [ "$head_rc" -eq 0 ] || [ "${#present[@]}" -eq 0 ] || why="${why:+$why; }head run exited $head_rc"
  [ "$rep_rc" -eq 0 ] || [ -n "$why" ] || why="report failed"
  if [ -n "$why" ]; then
    _qa_fail "$why"
    return $?
  fi
  printf 'qa-run: verdict PASS (%s test criteria green, %s prose to hand-check)\n' "$n_test" "$n_prose"
  return 0
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  ids) cmd_ids "$@" ;;
  map) cmd_map "$@" ;;
  report) cmd_report "$@" ;;
  qa-run)
    cmd_qa_run "$@"; qa_rc=$?
    # The detached fallback's way home, on every path out of qa-run; a failure
    # is the warning line and a non-zero exit, never silence.
    _qa_restore_home || [ "$qa_rc" -ne 0 ] || qa_rc=1
    exit "$qa_rc" ;;
  spec-check) cmd_spec_check "$@" ;;
  spec-usable) cmd_spec_usable "$@" ;;
  placement) cmd_placement "$@" ;;
  *) usage ;;
esac
