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
#       The Tests: line is DATA, never a command. A path must be repo-relative,
#       tracked at the PR head, match ^[A-Za-z0-9_./-]+$ and not start with `-`
#       or contain `..`; a name filter must match ^[A-Za-z0-9_|. -]+$, not
#       start with `-` and not be a runner command. Anything else is refused:
#       nothing from the spec runs and the verdict is FAIL. With
#       tests/run-tests.sh the files run as `--for <path> ... --strict
#       --no-cache` (a cached run cannot hide the per-id lines, and no path
#       falls back to the full suite); otherwise the first `verify:` command
#       that mentions "test" runs with the paths and filters appended as
#       separate quoted arguments. Exit 3: no usable runner.
#
# Exit codes: 0 ok, 1 a failing report or an unreadable/empty input, 2 usage.
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
    if isinstance(b, str) and b.lstrip().startswith("**PM spec"):
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
_qa_restore() {
  [ "$_QA_MOVED" -eq 1 ] || return 0
  if git checkout -q "$_QA_ORIG" >/dev/null 2>&1; then
    _QA_MOVED=0
  else
    printf 'qa-run: WARNING: could not return to %s; run: git checkout %s\n' "$_QA_ORIG" "$_QA_ORIG" >&2
    return 1
  fi
}

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
    _talos_on_exit '_qa_restore'
  else
    cfg() { :; }
    trap '_qa_restore' EXIT
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

  # 3. The PR at its head.
  if ! bash "$vcs" checkout-pr "$pr" >/dev/null 2>"$tmp/checkout.err"; then
    echo "qa-run: checkout-pr $pr failed: $(head -c 200 "$tmp/checkout.err" | tr -cd '[:print:]')"
    _qa_fail "could not check out the PR"
    return $?
  fi
  local head head8
  head="$(git rev-parse HEAD 2>/dev/null)" || { _qa_fail "no HEAD after checkout"; return $?; }
  head8="${head:0:8}"

  # 4. The spec and its criteria table.
  local spec="$tmp/spec.md" table
  if ! bash "$vcs" view-issue "$issue" --spec 2>/dev/null | python3 -I -c "$_QA_SPEC_PY" > "$spec" || [ ! -s "$spec" ]; then
    echo "qa-run: could not read the spec for issue #$issue"
    _qa_fail "spec unreadable"
    return $?
  fi
  table="$(cmd_ids "$spec" 2>&1)" || { echo "qa-run: $table"; _qa_fail "the spec has no criteria checklist"; return $?; }
  local n_test n_prose
  n_test="$(printf '%s\n' "$table" | awk '$2 == "test"' | wc -l | tr -d ' ')"
  n_prose="$(printf '%s\n' "$table" | awk '$2 == "prose"' | wc -l | tr -d ' ')"

  # 5. The Tests: line, as data.
  local paths=() filters=() tag val refused="" found=0
  while IFS="$(printf '\t')" read -r tag val; do
    case "$tag" in
      P) paths+=("$val"); found=1 ;;
      F) filters+=("$val"); found=1 ;;
      B) refused="$val" ;;
    esac
  done <<EOF
$(python3 -I -c "$_QA_TESTS_PY" < "$spec")
EOF
  if [ -n "$refused" ]; then
    echo "qa-run: Tests: line refused ($refused); nothing from the spec ran"
    _qa_fail "the spec's Tests: line was refused; report it as a blocking finding"
    return $?
  fi
  if [ "$found" -eq 0 ]; then
    if [ "$n_test" -eq 0 ]; then
      cmd_ids "$spec" | awk '{ printf "%s prose hand-checked\n", $1 }'
      printf 'qa-run: verdict PASS (prose only: %s criteria to hand-check; no tests to run)\n' "$n_prose"
      return 0
    fi
    echo "qa-run: the spec has $n_test (test) criteria but no Tests: line"
    _qa_fail "no Tests: line in the spec, so no criterion can be proven"
    return $?
  fi

  # 6. Paths must be tracked files at the PR head.
  local p present=() missing=()
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

  # 9. Red run: the first commit after the merge-base, when it is tests-only.
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
$(git diff --name-only "$mb" "$red" 2>/dev/null)
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
  qa-run) cmd_qa_run "$@" ;;
  *) usage ;;
esac
