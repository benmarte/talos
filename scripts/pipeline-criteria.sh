#!/usr/bin/env bash
# pipeline-criteria.sh -- map a spec's acceptance criteria to test results by
# id (#421). ids, map and report are pure text processing: no network, no LLM,
# no git. qa-run (#549) and red-check (#747) are the verbs that drive git and the
# test runner.
#
# The PM numbers each criterion `AC<n>` and marks it `(test)`,
# `(same: <why>)` (behaviour that must not change: green at the red commit and
# at the head, #715) or `(prose: <reason>)`; the developer names each criterion's test after its id
# (`AC2 rejects an expired token`), so a runner's own output maps back to the
# criterion. Talos's test helpers print one assertion label per line,
# `  ok  <label>` or `FAIL  <label>`; the id is the first word of the label.
#
# Usage:
#   pipeline-criteria.sh ids <spec-file>
#       One line per criterion: `AC<n> test|same|prose`. A spec with `AC<n>` ids
#       uses them. A spec with none (no PM stage: the issue's own checklist)
#       numbers its `- [ ]` / `- [x]` items 1-based; an unmarked item is test.
#       `(same)` with or without a reason is `same`; `(prose` is checked first.
#   pipeline-criteria.sh map <runner-output-file> [--spec <spec-file>] \
#                            [--pass-re <ERE>] [--fail-re <ERE>]
#       `AC<n> pass|fail` for each id seen in the output (`fail` when any
#       assertion for the id failed). With --spec: each (test) and (same) id of the spec,
#       `missing` when the output has no line for it (a crash, a typo).
#       --pass-re / --fail-re (#716): extended regexes matched against one output
#       line, `{n}` replaced by the criterion number and not continuing into
#       another digit (`AC1` never matches `AC10`); a missing one is today's
#       `ok AC<n>` / `FAIL AC<n>` line. Without --spec the ids tried are AC1..AC99.
#   pipeline-criteria.sh report --spec <spec-file> --red <output> \
#                               --head <output> --red-sha <sha8> [--frozen <output>] \
#                               [--rerun <output>] [--ack-changed <reason>]
#       (--red-sha must be 7-40 hex characters, else exit 2.)
#       The QA verdict lines, one per id:
#         AC<n> red@<sha8> green@head       red at the first commit, green at head
#         AC<n> green@head (red: missing)   no per-id output at red: a note
#         AC<n> FAIL vacuous (green at red@<sha8>)
#         AC<n> guard green@head (green at red@<sha8>)   #693: a vacuous line
#                                   beside a red-then-green one, no other FAIL
#         AC<n> FAIL head=<fail|missing> red=<state>
#         AC<n> prose hand-checked
#       A (same) criterion (#715) passes when green at red AND at head:
#         AC<n> PASS same red@<sha8> green@head
#         AC<n> PASS same green@head (red: missing)   no per-id output at red
#         AC<n> FAIL same red=<state> head=<state>    red or missing at head, or red at red
#       Exit 1 when any line is FAIL.
#       --frozen <output> (#714): the red commit's version of each Tests file the
#       PR changed since, run against the head code (parsed like --red/--head).
#       --rerun <output> (#717): the head files run a second time; a test or same
#       criterion that is fail in --head and pass in --rerun prints
#       `AC<n> FAIL flaky (failed at head, passed on re-run)`.
#       A criterion with a frozen state adds a column or fails:
#         AC<n> red@<sha8> green@head frozen@head   the red-commit test still passes
#         AC<n> FAIL weakened (red-commit test fails at head)
#       An existing FAIL (vacuous, head=fail) wins over weakened. No frozen state
#       for an id (its file did not change) adds no column; without --frozen the
#       output is exactly the lines above. --ack-changed <reason> (printable
#       ASCII, 1-200 chars, else usage exit 2) reports the weakened line as
#       `AC<n> weakened-ack (red-commit test fails at head; changed on purpose:
#       <reason>)`, which is not a FAIL.
#   pipeline-criteria.sh qa-run <issue> <pr> [--base <branch>] [--ack-changed <reason>]
#       The whole QA criteria check in one call (#549), run from the QA
#       worktree: tags the worktree for <issue> (best effort; the main checkout
#       is refused), checks `pr-mergeable` (CONFLICTING: nothing runs), checks
#       out the PR, reads the spec (`view-issue <issue> --spec`) and its
#       `Tests:` line, validates every item, runs the test files at the PR head
#       and at the red commit (the first commit after the merge-base), and
#       prints the `report` lines plus one verdict line:
#         qa-run: verdict PASS ...      the mechanical half passed (prose is yours);
#             `, <k> same` is named before the prose count when k > 0
#       The frozen run (#714): when a Tests file differs between the red commit
#       and the head, the red commit's version of it runs against the head code
#       (one more targeted run; none when no file changed or the red proof was
#       skipped), then the head versions are put back. Each such file prints
#       `note: frozen run: <file> differs from red commit <sha8>`; the report
#       adds `frozen@head` or `FAIL weakened`; a frozen run that exits non-zero
#       with no weakened line is `qa-run: verdict FAIL frozen run exited <rc>`.
#       The flaky re-run (#717): a head run that exits non-zero is run once more,
#       the same present Tests files at the head, before the red run; `report
#       --rerun <output>` turns a test or same criterion that failed at the head
#       and passed there into `AC<n> FAIL flaky (failed at head, passed on
#       re-run)`, and the verdict names it: `FAIL <n> test criteria FAIL (<k>
#       flaky)`. The driver sends a flaky-only verdict to the owner, not to a
#       fix round.
#       The regression run (#773): a `**Regression:**` line (same path parse as
#       `Tests:`; a missing file counts like a missing Tests file) names files that
#       must stay green. Each runs whole at the head, apart from the Tests run, with
#       the same runner choice; a non-zero exit is `qa-run: verdict FAIL regression
#       run exited <N>` (its FAIL lines shown). A pass adds nothing: no id in that
#       output is mapped to a criterion.
#       The e2e step (#717): verify.e2e (repo-only, default empty) is one command
#       run once from the repo root through pipeline-verify.sh, at the head, only
#       on an otherwise green verdict with tests to run. Exit 0 prints `qa-run:
#       e2e ok` and appends ` e2e ok` to the PASS line; non-zero prints `e2e
#       failure output (data):` and the last 24 lines (200 chars each) and the
#       verdict is `FAIL e2e exited <rc>`.
#       --ack-changed <reason> (QA, after reading the file's diff between the
#       red commit and the head) turns FAIL weakened into `weakened-ack`: the
#       frozen failure is still printed, the verdict can be PASS.
#       verify.ready (#751, repo-only list, default empty): shell commands run in
#       order from the repo root through pipeline-verify.sh before every run of
#       the Tests files (the head run, the re-run, the red run after its checkout,
#       the frozen run), e.g. restart the app and wait until it answers. The first
#       one to exit non-zero ends the run: HEAD and the test files are put back,
#       the verdict is `BLOCKED environment: <cmd> exited <N>` (exit 5), followed
#       by `environment failure output (data):` and the last 30 lines (200 chars
#       each); no AC line, no report. TALOS_QA_RESULTS then starts with
#       `BLOCKED environment: <cmd> exited <N>`; the driver stops `reason=
#       environment` and starts no fix round (the code is unchanged).
#       On a FAIL or BLOCKED verdict the run's head.out, rerun.out, red.out and
#       frozen.out (those that exist) are copied to <repo root>/.talos/qa-run-<pr>/
#       (replaced each run, removed by a run that passes) and `qa-run: raw output
#       kept in <path>` is printed before the verdict line. When verify.targeted_commands
#       loaded entries, `qa-run: targeted_commands from <config file>` says where
#       they came from.
#         qa-run: verdict FAIL <why>    exit 1
#         qa-run: verdict BLOCKED environment: <cmd> exited <N>    exit 5 (#751)
#         qa-run: verdict BLOCKED spec: <why>    exit 4 (#610): the spec is
#             unusable (the four faults of spec-usable below) and the PR was
#             not judged; no test ran
#       The Tests: line is DATA, never a command. A path must be repo-relative,
#       tracked at the PR head, match ^[A-Za-z0-9_./()[]-]+$ (the parentheses and
#       square brackets of a Next.js route group or dynamic segment, #752) and
#       not start with `-` or contain `..`; a name filter must match ^[A-Za-z0-9_|. -]+$, not
#       start with `-` and not be a runner command. Anything else is refused:
#       nothing from the spec runs and the verdict is BLOCKED. With
#       tests/run-tests.sh the files run as `--for <path> ... --strict
#       --no-cache` (a cached run cannot hide the per-id lines, and no path
#       falls back to the full suite); otherwise the first `verify:` command
#       that mentions "test" runs with the paths and filters appended as
#       separate quoted arguments. Exit 3: no usable runner.
#       verify.targeted_commands (#716, repo-only): a list of
#       {match, run, pass, fail} entries, first match wins. A Tests: file whose
#       repo-relative path fits `match` (a glob: `*` any characters but `/`, `?`
#       one, `**/` zero or more directories) runs as `run`, once per file, with
#       {file}, {class} (file name without its last extension) and {dir}
#       substituted shell-quoted (#752: already quoted, never wrap them in
#       quotes; a path of letters, digits and _ . / - is unchanged), from the
#       repo root through pipeline-verify.sh. `pass` and
#       `fail` are EREs for one output line ({n} is the criterion number; map
#       above); a missing one is today's `ok`/`FAIL` line. A file that fits no
#       entry uses the runner above. A malformed entry is skipped with one
#       stderr note naming its index. A path outside [A-Za-z0-9_./()[]-] that an
#       entry matches is `verdict BLOCKED spec`, exit 4; nothing runs.
#   pipeline-criteria.sh spec-check <spec-file>
#       Would qa-run accept this spec's `Tests:` line (#594)? Pure text, the
#       parser qa-run uses; `talos.sh done pm` runs it on the spec the PM just
#       posted. One line:
#         spec-check: ok
#         spec-check: refused tests-line-refused: <the parser's reason and its fix>
#         spec-check: refused tests-line-missing: <n> test criteria and no usable Tests: line (<fix>)
#         spec-check: refused tests-line-open: name the file, QA runs no file left open: <the line>
#       Each refusal is one line and says how to fix it: a note beside the list
#       moves to its own line, a path holds letters, digits and _ . / - ( ) [ ],
#       the paths go on the `Tests:` line or in a bullet list right under a bare
#       `Tests:` label (unindented bullets count; the list ends at the first
#       blank or non-bullet line), a test file is named, not left open.
#       tests-line-open (#648): the `Tests:` line or a line of its list leaves a test
#       file open (`developer's choosing`, `developer's choice`, `new or existing
#       file`, any case); every test criterion's file is on the `Tests:` line.
#       Other sections (Files likely to change) are not scanned (#752).
#       Exit 1 on a refusal. A (same) criterion counts as a test criterion. A
#       spec with none (prose only, or no checklist) needs no `Tests:` line and
#       is ok.
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
#       Is every (test) and (same) criterion's id in a test file the `Tests:` line names
#       (#648)? Run from the PR worktree; pure text, no test runs. The spec is
#       read through the same parse as qa-run (an unusable spec is BLOCKED). An
#       id counts when it is the first word of an assertion label (`"AC2 ..."`,
#       `ok  AC2 ...`) in one of those files; the same id in any other file does
#       not. Output and exit codes:
#         placement: ok                       exit 0
#         AC<n> not-in-tests-files            one per missing id, then
#         placement: GAP <n>                  exit 1
#         placement: BLOCKED spec: <why>      exit 4 (the spec-usable reasons)
#   pipeline-criteria.sh red-check <issue> [<ref>]
#       Is each criterion's kind right at the red commit (#747)? The red proof
#       qa-run takes (the first commit after the merge-base with the base branch,
#       only when it is tests-only), with the same runner choice, `Tests:` parse and
#       verify.targeted_commands, but run in a throwaway detached worktree: the
#       caller's checkout, HEAD and branch are never touched. <ref> (default HEAD)
#       is the branch tip or SHA whose red commit is used. Findings first, one per
#       line, then one verdict line:
#         kind-mismatch AC<n> want=same   a (test) that is pass at the red commit
#         kind-mismatch AC<n> want=test   a (same) that is fail at the red commit
#         id-collision AC<n> file=<f>     pure text: <f> is a `Tests:` file that exists
#                                         at the merge-base and already labels AC<n>
#                                         (an earlier issue's id), or AC<n> is labelled
#                                         by two `Tests:` files at the red commit; not
#                                         printed for the droppable case below
#         drop-file <f> reason=id-collision-with-<g>   (#773) exactly two `Tests:` files label
#                                         an id, <f> exists at the merge-base and <g>
#                                         (a file the branch adds) does not: <f> is left out
#                                         of the red run, so its results reach no
#                                         kind-mismatch, and qa-run runs it whole at the head
#         to-prose AC<n> file=<f>         a (test)/(same) criterion labelled at the red
#                                         commit in a dropped file <f> and in no kept file
#         red-check: ok                           exit 0
#         red-check: MISMATCH <k>                 exit 1 (kind-mismatch lines only)
#         red-check: REVISE <k>                   exit 1: k = kind-mismatch + drop-file +
#                                                 to-prose lines, at least one drop-file
#                                                 and no remaining collision
#         red-check: COLLISION <k>                exit 4 (wins over a mismatch, whose
#                                                 lines are still printed, and over a
#                                                 droppable collision, whose drop-file
#                                                 lines are then not printed: both files
#                                                 new, both on the base, a lone
#                                                 pre-existing file, or three or more)
#         red-check: skipped <why>                exit 0: no `Tests:` line or no test
#                                                 criteria, no red commit, the red commit
#                                                 is not tests-only, or no test file there
#         red-check: BLOCKED spec: <why>          exit 4 (the spec-usable reasons)
#       A `missing` state at the red commit (no per-id output) is no finding. A
#       non-numeric issue is usage (exit 2); no usable runner is exit 3. `talos.sh
#       run` calls it once per PR after the first-round developer opens it.
#   pipeline-criteria.sh revise-spec <issue>
#       Reads `kind-mismatch`, `drop-file` and `to-prose` lines on stdin and prints the
#       issue's spec comment with just those criteria's final kind markers flipped, led
#       by `**PM spec:** revised by the driver after red-check: ...` (the driver posts
#       it). A `to-prose` criterion's marker becomes `(prose: <f> must pass at head)`;
#       a `drop-file` file leaves the `Tests:` line (or its bullet) for a `**Regression:**`
#       line of the dropped files in backticks, right after it (#773). Exit 1 when the spec is unreadable, a listed
#       criterion is not a flippable line, or a dropped file is not on the Tests: line.
#
# Exit codes: 0 ok, 1 a failing report or an unreadable/empty input, 2 usage, 3 no usable runner, 4 an unusable spec, 5 a broken environment (qa-run).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '/^# Usage:/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# ids FILE: the criteria table, `AC<n> test|same|prose`.
cmd_ids() {
  local file="${1:-}"
  [ -n "$file" ] || usage
  [ -f "$file" ] || { echo "pipeline-criteria: ids: no such file: $file" >&2; return 1; }
  local out
  out="$(awk '
    # The last marker names the kind: a criterion may mention another marker in its text.
    function kind(l,   k) {
      k = "test"
      while (match(l, /\((test|prose|same)[:)]/)) {
        k = substr(l, RSTART + 1, RLENGTH - 2)
        l = substr(l, RSTART + RLENGTH)
      }
      return k
    }
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

# _re_valid RE (#716): an extended regex grep accepts ({n} read as a digit).
_re_valid() {
  local rc=0
  grep -E -e "${1//\{n\}/1}" </dev/null >/dev/null 2>&1 || rc=$?
  [ "$rc" -le 1 ]
}

# _re_line_hit RE N FILE (#716): a line of FILE matches RE with {n} = N and does
# not continue into another digit (the same RE with N followed by a digit is
# what a longer id would match: `AC1` is not `AC10`).
_re_line_hit() {
  local exact="${1//\{n\}/$2}" longer="${1//\{n\}/$2[0-9]}"
  case "$1" in
    *'{n}'*) grep -E -e "$exact" "$3" 2>/dev/null | grep -Ev -e "$longer" >/dev/null 2>&1 ;;
    *) grep -E -e "$exact" "$3" >/dev/null 2>&1 ;;
  esac
}

# _map_patterns FILE WANT PASS_RE FAIL_RE (#716): cmd_map with a pass and a fail
# pattern. WANT is the spec's ids (a missing one is listed); empty tries AC1..AC99.
_map_patterns() {
  local file="$1" want="$2" pre="$3" fre="$4" id n i
  [ -n "$pre" ] || pre='^[[:space:]]*ok[[:space:]]+AC{n}'
  [ -n "$fre" ] || fre='^[[:space:]]*FAIL[[:space:]]+AC{n}'
  if ! _re_valid "$pre" || ! _re_valid "$fre"; then
    echo "pipeline-criteria: map: not a valid extended regex" >&2
    return 2
  fi
  if [ -z "$want" ]; then
    for ((i = 1; i < 100; i++)); do want="$want AC$i"; done
  fi
  for id in $want; do
    n="${id#AC}"
    if _re_line_hit "$fre" "$n" "$file"; then echo "$id fail"
    elif _re_line_hit "$pre" "$n" "$file"; then echo "$id pass"
    elif [ "$5" = spec ]; then echo "$id missing"
    fi
  done
}

# map FILE [--spec SPEC] [--pass-re RE] [--fail-re RE]: `AC<n> pass|fail|missing`.
cmd_map() {
  local file="${1:-}" spec="" want="" pass_re="" fail_re=""
  [ -n "$file" ] || usage
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec) spec="${2:-}"; shift 2 || usage ;;
      --pass-re) pass_re="${2:-}"; shift 2 || usage ;;
      --fail-re) fail_re="${2:-}"; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -f "$file" ] || { echo "pipeline-criteria: map: no such file: $file" >&2; return 1; }
  if [ -n "$spec" ]; then
    want="$(cmd_ids "$spec" | awk '$2 == "test" || $2 == "same" { printf "%s ", $1 }')" || return 1
  fi
  if [ -n "$pass_re$fail_re" ]; then
    _map_patterns "$file" "$want" "$pass_re" "$fail_re" "$([ -n "$spec" ] && echo spec || echo seen)"
    return $?
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

# _ack_reason_ok REASON (#714): non-empty, printable ASCII, at most 200 chars.
_ack_reason_ok() {
  [ -n "$1" ] || return 1
  # $(...) strips newlines, so refuse them before the character-class check.
  case "$1" in *$'\n'*) return 1 ;; esac
  [ -z "$(printf '%s' "$1" | LC_ALL=C tr -d ' -~')" ] || return 1
  [ "${#1}" -le 200 ]
}

# report --spec F --red F --head F --red-sha SHA8 [--frozen F] [--rerun F] [--ack-changed WHY]
cmd_report() {
  local spec="" red="" head="" sha="" frozen="" rerun="" ack=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec) spec="${2:-}"; shift 2 || usage ;;
      --red) red="${2:-}"; shift 2 || usage ;;
      --head) head="${2:-}"; shift 2 || usage ;;
      --red-sha) sha="${2:-}"; shift 2 || usage ;;
      --frozen) frozen="${2:-}"; shift 2 || usage ;;
      --rerun) rerun="${2:-}"; shift 2 || usage ;;
      --ack-changed) ack="${2:-}"; _ack_reason_ok "$ack" || usage; shift 2 || usage ;;
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
  local table red_map head_map frozen_map="" rerun_map="" id kind r h f rr fcol rc=0
  table="$(cmd_ids "$spec")" || return 1
  red_map="$(cmd_map "$red" --spec "$spec")" || return 1
  head_map="$(cmd_map "$head" --spec "$spec")" || return 1
  [ -z "$frozen" ] || frozen_map="$(cmd_map "$frozen" --spec "$spec")" || return 1
  [ -z "$rerun" ] || rerun_map="$(cmd_map "$rerun" --spec "$spec")" || return 1
  # The lines are buffered: a vacuous (test) criterion is a guard or a FAIL
  # (#693) only once every criterion is classified. `guards` holds the indexes
  # of the vacuous lines, `rtg` counts the red-then-green criteria and `rc`
  # (set by every other FAIL) is the clean-remainder check.
  local -a buf=() guards=()
  local rtg=0 i
  while read -r id kind; do
    if [ "$kind" = "prose" ]; then
      buf[${#buf[@]}]="$id prose hand-checked"
      continue
    fi
    r="$(awk -v i="$id" '$1 == i { print $2 }' <<<"$red_map")"
    h="$(awk -v i="$id" '$1 == i { print $2 }' <<<"$head_map")"
    # The red commit's version of the test, run at the head (#714): `missing`
    # (no frozen column) when its file did not change or there was no run.
    f="$(awk -v i="$id" '$1 == i { print $2 }' <<<"$frozen_map")"
    fcol=""; [ "$f" != "pass" ] || fcol=" frozen@head"
    # Failed at the head, passed on the one re-run (#717): flaky, not a finding on the PR.
    rr="$(awk -v i="$id" '$1 == i { print $2 }' <<<"$rerun_map")"
    if [ "$h" = "fail" ] && [ "$rr" = "pass" ]; then
      buf[${#buf[@]}]="$id FAIL flaky (failed at head, passed on re-run)"; rc=1
    elif [ "$kind" = "same" ]; then
      if [ "$h" != "pass" ]; then
        buf[${#buf[@]}]="$id FAIL same red=${r:-missing} head=${h:-missing}"; rc=1
      elif [ "$r" = "fail" ]; then
        buf[${#buf[@]}]="$id FAIL same red=fail head=pass"; rc=1
      elif [ "$f" = "fail" ]; then
        buf[${#buf[@]}]="$(_weakened "$id" "$ack")" || rc=1
      elif [ "$r" = "pass" ]; then
        buf[${#buf[@]}]="$id PASS same red@$sha green@head$fcol"
      else
        buf[${#buf[@]}]="$id PASS same green@head$fcol (red: missing)"
      fi
    elif [ "$h" != "pass" ]; then
      buf[${#buf[@]}]="$id FAIL head=${h:-missing} red=${r:-missing}"; rc=1
    elif [ "$r" = "pass" ]; then
      guards[${#guards[@]}]="${#buf[@]} $id"
      buf[${#buf[@]}]="$id FAIL vacuous (green at red@$sha)"
    elif [ "$f" = "fail" ]; then
      buf[${#buf[@]}]="$(_weakened "$id" "$ack")" || rc=1
    elif [ "$r" = "fail" ]; then
      buf[${#buf[@]}]="$id red@$sha green@head$fcol"; rtg=$((rtg + 1))
    else
      buf[${#buf[@]}]="$id green@head$fcol (red: missing)"
    fi
  done <<<"$table"
  # A vacuous criterion is a regression guard (#693) when another criterion went
  # red then green and no other FAIL line exists; else it is the FAIL it was.
  if [ "${#guards[@]}" -gt 0 ]; then
    local g
    if [ "$rtg" -gt 0 ] && [ "$rc" -eq 0 ]; then
      for g in "${guards[@]}"; do
        buf[${g%% *}]="${g#* } guard green@head (green at red@$sha)"
      done
    else
      rc=1
    fi
  fi
  [ "${#buf[@]}" -eq 0 ] || for i in "${buf[@]}"; do printf '%s\n' "$i"; done
  return "$rc"
}

# _weakened ID ACK (#714): the line for a criterion whose red-commit test fails
# at the head. Without an ack reason it is a FAIL (status 1); with one it is
# reported, not failed.
_weakened() {
  if [ -n "$2" ]; then
    printf '%s weakened-ack (red-commit test fails at head; changed on purpose: %s)\n' "$1" "$2"
  else
    printf '%s FAIL weakened (red-commit test fails at head)\n' "$1"; return 1
  fi
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
#   O<TAB>line (the Tests line or a line of its list leaves a test file open)
# Nothing here executes anything; a value is a path or a filter or refused.
_QA_TESTS_PY='
import re, sys
text = sys.stdin.read()
# The label parsed: Tests by default, Regression (#773) when qa-run asks for it.
LABEL = "Regression" if sys.argv[1:] == ["Regression"] else "Tests"
PATH_RE = re.compile(r"^[A-Za-z0-9_./()\[\]-]+$")
OPEN_RE = re.compile(r"developer.{1,3}s (choosing|choice)|new or existing file", re.I)
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
block = []
for i, l in enumerate(lines):
    m = re.match(r"^\s*(?:[-*+]\s+)?(?:\[[ xX]\]\s+)?\**" + LABEL + r"\**:\**\s*(.*)$", l)
    if m:
        rest = m.group(1).strip()
        block = [l]
        # A bare label takes the bullets right under it, indented or not (the
        # Azure comment round trip flattens them); a label with paths on it
        # takes indented bullets only. Either list ends at a blank or non-bullet line.
        if rest.strip("* "):
            item = r"^\s+[-*+]\s+(.*)$"
        else:
            item = r"^\s*[-*+]\s+(?!\[[ xX]\]\s)(.*)$"
        for l2 in lines[i + 1:]:
            m2 = re.match(item, l2)
            if not m2:
                break
            rest += " " + m2.group(1).strip()
            block.append(l2)
        break
for b in block:
    if OPEN_RE.search(b):
        print("O\t" + show(b.strip()))
        break
if rest is None or not rest.strip("* "):
    print("N")
    sys.exit(0)

spans = re.findall(r"`([^`]*)`", rest)
if spans:
    residue = re.sub(r"`[^`]*`", " ", rest)
    if re.search(r"[;|&$<>\\{}`]", residue):
        refuse("shell syntax beside the test list (move the note to its own line)", residue.strip())
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
            refuse("test path has a character outside letters, digits, _ . / - ( ) [ ]", it)
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
# refused (the parser's reason), found and open_line (a Tests-line text that
# leaves a test file open, #648).
_tests_line() {
  local tag val
  paths=(); filters=(); refused=""; found=0; open_line=""
  while IFS="$(printf '\t')" read -r tag val; do
    case "$tag" in
      P) paths+=("$val"); found=1 ;;
      F) filters+=("$val"); found=1 ;;
      B) refused="$val" ;;
      O) open_line="$val" ;;
    esac
  done <<EOF
$(python3 -I -c "$_QA_TESTS_PY" < "$1")
EOF
}

# _regression_line SPEC (#773): the spec's `**Regression:**` line, the same parse
# as `Tests:` (_QA_TESTS_PY). Sets the caller's reg_paths and reg_refused (the
# parser's reason). Filters and a missing line are no regression files.
_regression_line() {
  local tag val
  reg_paths=(); reg_refused=""
  while IFS="$(printf '\t')" read -r tag val; do
    case "$tag" in
      P) reg_paths+=("$val") ;;
      B) reg_refused="$val" ;;
    esac
  done <<EOF
$(python3 -I -c "$_QA_TESTS_PY" Regression < "$1")
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
  n_test="$(cmd_ids "$spec" 2>/dev/null | awk '$2 == "test" || $2 == "same"' | wc -l | tr -d ' ')"
  if [ "$n_test" -gt 0 ]; then
    # #648: a test file left to the developer is a file QA does not run.
    if [ -n "$open_line" ]; then
      echo "spec-check: refused tests-line-open: name the file, QA runs no file left open: $open_line"
      return 1
    fi
  fi
  if [ "$found" -eq 0 ]; then
    if [ "$n_test" -gt 0 ]; then
      echo "spec-check: refused tests-line-missing: $n_test test criteria and no usable Tests: line (put the test paths on the Tests: line or in a bullet list right under it)"
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
  n="$(printf '%s\n' "$table" | awk '$2 == "test" || $2 == "same"' | wc -l | tr -d ' ')"
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
  for id in $(printf '%s\n' "$table" | awk '$2 == "test" || $2 == "same" { print $1 }'); do
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

# The Tests files the frozen run (#714) swapped for the red commit's versions;
# _qa_restore_frozen puts the head's back (idempotent; also an exit hook, so an
# interrupt inside the frozen run leaves no red-commit test file behind).
_QA_FROZEN=()
_qa_restore_frozen() {
  [ "${#_QA_FROZEN[@]}" -gt 0 ] || return 0
  if git checkout -q HEAD -- "${_QA_FROZEN[@]}" >/dev/null 2>&1; then
    _QA_FROZEN=()
  else
    printf 'qa-run: WARNING: could not restore the head test files; run: git checkout HEAD -- %s\n' "${_QA_FROZEN[*]}" >&2
    return 1
  fi
}

# Exit hook: the restores, each tried.
_qa_exit() { _qa_restore_frozen; _qa_restore; _qa_restore_home; }

# _qa_verdict_fail REASON -- the closing line of a refused or failed run.
_qa_fail() {
  _qa_keep_raw
  _qa_art_attach
  printf 'qa-run: verdict FAIL %s\n' "$1"
  return 1
}

# verify.e2e_artifacts (#776, repo-only): the screenshots and videos the repo's
# own e2e run wrote, attached to the PR as one evidence comment. qa-run calls
# _qa_art_begin before each judging run (the head run, the verify.e2e command)
# and _qa_art_collect right after it, which copies the files of `dir` that match
# `include` and are not older than the run into $tmp/art, before the re-run, the
# red run and the frozen run can empty `dir`. A run that wrote some replaces the
# earlier run's files; one that wrote none keeps them. _qa_art_attach, called by
# both the PASS path and _qa_fail, applies max_files and max_mb and runs
# `pipeline-vcs.sh attach-files`. Every outcome but a clean attach prints one
# `qa-run: e2e artifacts ...` line; none of them touches the verdict or the exit
# code.
_QA_ART=0 _QA_ART_RAN=0 _QA_ART_DONE=0
_QA_ART_DIR="" _QA_ART_MAXF=12 _QA_ART_MAXMB=25
_QA_ART_TMP="" _QA_ART_TOP="" _QA_ART_PR="" _QA_ART_VCS=""
_QA_ART_INC=()

# _qa_art_init TMP TOP PR VCS -- read the config; the feature is on only with a
# dir and at least one include glob.
_qa_art_init() {
  local dir g
  _QA_ART=0; _QA_ART_RAN=0; _QA_ART_DONE=0; _QA_ART_INC=()
  _QA_ART_TMP="$1"; _QA_ART_TOP="$2"; _QA_ART_PR="$3"; _QA_ART_VCS="$4"
  dir="$(cfg verify.e2e_artifacts.dir 2>/dev/null)"
  [ -n "$dir" ] || return 0
  while IFS= read -r g; do
    [ -z "$g" ] || _QA_ART_INC+=("$g")
  done <<EOF
$(cfg verify.e2e_artifacts.include 2>/dev/null)
EOF
  [ "${#_QA_ART_INC[@]}" -gt 0 ] || return 0
  dir="${dir%/}"
  case "/$dir/" in
    //*|*/../*|*/./*|*[[:cntrl:]]*)
      echo "qa-run: e2e artifacts ignored: dir must be a repo-relative path without .. (got '$dir')"
      return 0 ;;
  esac
  _QA_ART_MAXF="$(cfg verify.e2e_artifacts.max_files 2>/dev/null)"
  _QA_ART_MAXMB="$(cfg verify.e2e_artifacts.max_mb 2>/dev/null)"
  case "$_QA_ART_MAXF" in ''|*[!0-9]*|0) _QA_ART_MAXF=12 ;; esac
  case "$_QA_ART_MAXMB" in ''|*[!0-9]*|0) _QA_ART_MAXMB=25 ;; esac
  _QA_ART_DIR="$dir"
  _QA_ART=1
}

# _qa_art_begin -- the stamp a file must not be older than to belong to the next run.
_qa_art_begin() {
  [ "$_QA_ART" -eq 1 ] || return 0
  touch "$_QA_ART_TMP/art.stamp"
}

# _qa_art_collect -- after a judging run: copy its matching files, flat, into
# $tmp/art (the name is the path under dir with `/` as `-`), listed in sorted
# path order in $tmp/art.list. Symlinks and anything outside the repo are skipped.
_qa_art_collect() {
  [ "$_QA_ART" -eq 1 ] || return 0
  _QA_ART_RAN=1
  local new="$_QA_ART_TMP/art.new"
  rm -rf "${new:?}" "${_QA_ART_TMP:?}/art.new.list"
  mkdir -p "$new" || return 0
  python3 -I -c '
import fnmatch, os, re, shutil, sys
top, rel, stamp, dest = sys.argv[1:5]
globs = sys.argv[5:]
base = os.path.realpath(top)
root = os.path.realpath(os.path.join(base, rel))
if not os.path.isdir(root) or not root.startswith(base + os.sep):
    sys.exit(0)
since = os.stat(stamp).st_mtime_ns
found = []
for d, dirs, files in os.walk(root, followlinks=False):
    for f in files:
        p = os.path.join(d, f)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        if not any(fnmatch.fnmatchcase(f, g) for g in globs):
            continue
        if os.stat(p).st_mtime_ns < since:
            continue
        found.append(os.path.relpath(p, root))
found.sort()
used, out = set(), []
for r in found:
    n = re.sub(r"[^A-Za-z0-9_.-]", "-", r.replace(os.sep, "-")).lstrip(".-") or "file"
    stem, ext = os.path.splitext(n)
    k = 2
    while n.lower() in used:
        n = "%s-%d%s" % (stem, k, ext)
        k += 1
    used.add(n.lower())
    shutil.copyfile(os.path.join(root, r), os.path.join(dest, n))
    out.append(n)
if out:
    print("\n".join(out))
' "$_QA_ART_TOP" "$_QA_ART_DIR" "$_QA_ART_TMP/art.stamp" "$new" "${_QA_ART_INC[@]}" > "$_QA_ART_TMP/art.new.list" 2>/dev/null || :
  if [ -s "$_QA_ART_TMP/art.new.list" ]; then
    rm -rf "${_QA_ART_TMP:?}/art"
    mv "$new" "$_QA_ART_TMP/art" && mv "$_QA_ART_TMP/art.new.list" "$_QA_ART_TMP/art.list"
  else
    rm -rf "${new:?}" "${_QA_ART_TMP:?}/art.new.list"
  fi
}

# _qa_art_attach -- once per qa-run, ahead of the verdict line, for a run that
# judged the head: the limits, then attach-files.
_qa_art_attach() {
  [ "$_QA_ART" -eq 1 ] && [ "$_QA_ART_RAN" -eq 1 ] && [ "$_QA_ART_DONE" -eq 0 ] || return 0
  _QA_ART_DONE=1
  local plan line files=() rc=0
  if [ ! -s "$_QA_ART_TMP/art.list" ]; then
    echo "qa-run: e2e artifacts none found in $_QA_ART_DIR"
    return 0
  fi
  plan="$(python3 -I -c '
import os, sys
art, maxf, maxmb = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
names = [l.rstrip("\n") for l in open(art + ".list") if l.strip()]
notes = []
if len(names) > maxf:
    notes.append("kept the first %d of %d files (max_files %d)" % (maxf, len(names), maxf))
    names = names[:maxf]
cap, total, keep, skipped = maxmb * 1024 * 1024, 0, [], 0
for n in names:
    size = os.path.getsize(os.path.join(art, n))
    if total + size > cap:
        skipped += 1
        continue
    total += size
    keep.append(n)
if skipped:
    notes.append("skipped %d file(s) over the %d MB total (max_mb)" % (skipped, maxmb))
for n in notes:
    print("N " + n)
for n in keep:
    print("F " + n)
' "$_QA_ART_TMP/art" "$_QA_ART_MAXF" "$_QA_ART_MAXMB" 2>/dev/null)" || plan=""
  while IFS= read -r line; do
    case "$line" in
      "N "*) printf 'qa-run: e2e artifacts %s\n' "${line#N }" ;;
      "F "*) files+=("$_QA_ART_TMP/art/${line#F }") ;;
    esac
  done <<EOF
$plan
EOF
  [ "${#files[@]}" -gt 0 ] || return 0
  bash "$_QA_ART_VCS" attach-files "$_QA_ART_PR" "${files[@]}" >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || printf 'qa-run: e2e artifacts upload failed (exit %s)\n' "$rc"
  return 0
}

# The run's scratch directory and where its raw output is kept (#751); qa-run
# sets both, so a verb that does not (red-check) keeps nothing.
_QA_RAW_SRC=""
_QA_RAW_DST=""
# _qa_keep_raw: copy the head, rerun, red and frozen outputs that exist to the
# kept directory and name it, ahead of a FAIL or BLOCKED verdict line.
_qa_keep_raw() {
  local f n=0
  [ -n "$_QA_RAW_SRC" ] && [ -n "$_QA_RAW_DST" ] || return 0
  for f in head rerun regression red frozen; do [ ! -f "$_QA_RAW_SRC/$f.out" ] || n=$((n + 1)); done
  [ "$n" -gt 0 ] || return 0
  rm -rf "${_QA_RAW_DST:?}"
  mkdir -p "$_QA_RAW_DST" || return 0
  for f in head rerun regression red frozen; do
    [ ! -f "$_QA_RAW_SRC/$f.out" ] || cp "$_QA_RAW_SRC/$f.out" "$_QA_RAW_DST/$f.out" 2>/dev/null || :
  done
  printf 'qa-run: raw output kept in %s\n' "$_QA_RAW_DST"
}

# verify.ready (#751): the commands that make the environment fit to test, set by
# qa-run. _qa_ready (below) records the first failure in _QA_ENV_FAIL as
# `<cmd> exited <N>`; qa-run then ends BLOCKED environment (_qa_env_blocked).
_QA_READY=()
_QA_ENV_FAIL=""
_qa_ready() {
  local c r
  for c in ${_QA_READY[@]+"${_QA_READY[@]}"}; do
    bash "$SCRIPT_DIR/pipeline-verify.sh" --issue "$issue" --worktree "$top" -- \
      bash -c "$c" > "$tmp/ready.out" 2>&1; r=$?
    if [ "$r" -ne 0 ]; then
      _QA_ENV_FAIL="$(printf '%s' "$c" | tr -cd '[:print:]' | cut -c1-120) exited $r"
      return 1
    fi
  done
}

# _qa_env_blocked: the closing of a run whose verify.ready command failed. HEAD
# and the Tests files go back first; the verdict, the output tail and the
# driver's results file follow. Exit 5; no AC line, no report.
_qa_env_blocked() {
  local etail
  _qa_restore_frozen
  _qa_restore || { _qa_fail "could not return to $_QA_ORIG after the environment failure"; return $?; }
  etail="$(tail -n 30 "$tmp/ready.out" 2>/dev/null | tr -d '\000-\010\013-\037\177' | cut -c1-200 | sed 's/^/  /')"
  _qa_keep_raw
  printf 'qa-run: verdict BLOCKED environment: %s\n' "$_QA_ENV_FAIL"
  echo "environment failure output (data):"
  printf '%s\n' "$etail"
  [ -z "${TALOS_QA_RESULTS:-}" ] \
    || printf 'BLOCKED environment: %s\n%s\n' "$_QA_ENV_FAIL" "$etail" > "$TALOS_QA_RESULTS" 2>/dev/null || :
  return 5
}

# verify.targeted_commands (#716) -> the entries as data: JSON on stdin, one
# record per line, `E idx ere run =pass =fail` for a usable entry (ere is the
# `match` glob as an anchored ERE; `=` guards an empty field) and `S idx reason`
# for a skipped one, `W reason` for a value that is not a list. Nothing here runs.
_TC_PY='
import json, re, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    print("W\tnot valid JSON")
    sys.exit(0)
if not isinstance(d, list):
    print("W\tnot a list")
    sys.exit(0)
CTRL = re.compile(r"[\x00-\x1f\x7f]")

def glob_ere(g):
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out += "(.*/)?"; i += 3
        elif g[i] == "*":
            while i < len(g) and g[i] == "*":
                i += 1
            out += "[^/]*"
        elif g[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += ("\\" if g[i] in ".^$+(){}[]|\\" else "") + g[i]; i += 1
    return "^" + out + "$"

for i, e in enumerate(d):
    if not isinstance(e, dict):
        print("S\t%d\tnot an object" % i); continue
    m, r = e.get("match"), e.get("run")
    if not (isinstance(m, str) and m and isinstance(r, str) and r):
        print("S\t%d\tneeds a match and a run string" % i); continue
    opt = []
    for k in ("pass", "fail"):
        v = e.get(k)
        if v is not None and not (isinstance(v, str) and v):
            print("S\t%d\t%s is not a non-empty string" % (i, k)); break
        opt.append(v or "")
    else:
        if any(CTRL.search(x) for x in (m, r, opt[0], opt[1])):
            print("S\t%d\ta control character in a field" % i)
        else:
            print("E\t%d\t%s\t%s\t=%s\t=%s" % (i, glob_ere(m), r, opt[0], opt[1]))
'

# _tc_load: sets the TC_* arrays (idx, glob ERE, run, pass, fail) from the config,
# and prints one stderr note per skipped entry. Absent key: no entries.
TC_IDX=(); TC_ERE=(); TC_RUN=(); TC_PASS=(); TC_FAIL=()
_VERB=qa-run  # the verb whose stderr notes _tc_load writes (red-check sets its own)
_tc_load() {
  local raw tag a b c d e
  TC_IDX=(); TC_ERE=(); TC_RUN=(); TC_PASS=(); TC_FAIL=()
  raw="$(cfg verify.targeted_commands 2>/dev/null)"
  [ -n "$raw" ] || return 0
  while IFS=$'\t' read -r tag a b c d e; do
    case "$tag" in
      W) printf '%s: verify.targeted_commands ignored: %s\n' "$_VERB" "$a" >&2 ;;
      S) printf '%s: verify.targeted_commands entry %s skipped: %s\n' "$_VERB" "$a" "$b" >&2 ;;
      E)
        c="${c#=}"; d="${d#=}"; e="${e#=}"
        if { [ -z "$d" ] || _re_valid "$d"; } && { [ -z "$e" ] || _re_valid "$e"; }; then
          TC_IDX+=("$a"); TC_ERE+=("$b"); TC_RUN+=("$c"); TC_PASS+=("$d"); TC_FAIL+=("$e")
        else
          printf '%s: verify.targeted_commands entry %s skipped: pass or fail is not a valid regex\n' "$_VERB" "$a" >&2
        fi ;;
    esac
  done <<EOF
$(python3 -I -c "$_TC_PY" <<<"$raw")
EOF
}
# The tab-split above reads `E idx ere run pass fail`: with `=` on pass and fail
# no field is empty, so the tab (whitespace to read) cannot collapse one.

# _tc_origin (#751): after _tc_load took entries, one line names the config file
# that set verify.targeted_commands, so nobody has to guess the layer.
_tc_origin() {
  local layer f
  [ "${#TC_IDX[@]}" -gt 0 ] || return 0
  layer="$(bash "$SCRIPT_DIR/pipeline-config.sh" --show --origin-only verify.targeted_commands 2>/dev/null \
    | awk -F'\t' '$1 == "verify.targeted_commands" { print $2 }')"
  case "$layer" in
    repo)
      f="${PIPELINE_CONFIG:-talos.pipeline.json}"
      case "$f" in /*) ;; *) f="$PWD/$f" ;; esac ;;
    *) f="the $layer layer" ;;
  esac
  printf 'qa-run: targeted_commands from %s\n' "$f"
}

# _tc_pick PATH: sets TC_SEL to the index of the first entry whose glob fits, else -1.
TC_SEL=-1
_tc_pick() {
  local i=0 n="${#TC_ERE[@]}"
  TC_SEL=-1
  while [ "$i" -lt "$n" ]; do
    if [[ "$1" =~ ${TC_ERE[$i]} ]]; then TC_SEL="$i"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# _red_commit REF BASE (#747): the red proof qa-run and red-check share. Sets the
# caller's bref (BASE, else base_branch, else origin/HEAD, else main), mb (the
# merge-base of REF with it), red (the first commit after it, empty when it
# cannot be used), red8 (its short sha, set once a commit was found) and red_why
# (empty for a usable red commit, else the reason: no commit, or not tests-only).
_red_commit() {
  local ref="$1" f bad_path=""
  bref="${2:-$(cfg base_branch 2>/dev/null)}"
  [ -n "$bref" ] || bref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
  [ -n "$bref" ] || bref=main
  red=""; red8=""; red_why=""
  mb="$(git merge-base "$ref" "origin/$bref" 2>/dev/null || git merge-base "$ref" "$bref" 2>/dev/null)"
  [ -z "$mb" ] || red="$(git rev-list --reverse "$mb".."$ref" 2>/dev/null | head -n 1)"
  if [ -z "$red" ]; then
    red_why="no red commit found after the merge-base with $bref"
    return 0
  fi
  red8="${red:0:8}"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _qa_is_test_path "$f" || { bad_path="$f"; break; }
  done <<EOF
$(git diff-tree --no-commit-id --name-only -r --root "$red" 2>/dev/null)
EOF
  if [ -n "$bad_path" ]; then
    red_why="red commit $red8 is not tests-only ($(printf '%s' "$bad_path" | tr -cd '[:print:]' | head -c 80))"
    red=""
  fi
}

# _runner_pick DIR FILE... (#747): the runner for the Tests files FILE... (the
# ones present), looked for under DIR. Sets the caller's runner (talos|verify|
# empty: only verify.targeted_commands entries run), vline and runner_why, and
# returns 0, 4 (a path no entry may take: runner_why is the spec fault) or 3 (no
# usable runner). Needs paths and the _tc_load entries.
_runner_pick() {
  local dir="$1" p n_entry=0 bad_re='[^]A-Za-z0-9_./()[-]'
  shift
  runner=""; vline=""; runner_why=""
  for p in ${paths[@]+"${paths[@]}"}; do
    _tc_pick "$p" || continue
    if [[ "$p" =~ $bad_re ]]; then
      runner_why="$(printf 'Tests: path outside letters, digits, _ . / - ( ) [ ] fits verify.targeted_commands entry %s: %s' \
        "${TC_IDX[$TC_SEL]}" "$(printf '%s' "$p" | tr -cd '[:print:]' | head -c 60)")"
      return 4
    fi
  done
  for p in "$@"; do _tc_pick "$p" && n_entry=$((n_entry + 1)); done
  if [ -f "$dir/tests/run-tests.sh" ]; then
    runner=talos
  else
    vline="$(cfg verify 2>/dev/null | grep -i 'test' | head -n 1)"
    [ -z "$vline" ] || runner=verify
  fi
  if [ -z "$runner" ] && { [ "$n_entry" -eq 0 ] || [ "$n_entry" -lt "$#" ]; }; then
    return 3
  fi
  return 0
}

# _tc_exec OUTFILE SEL FILE -- one run of a verify.targeted_commands entry; its
# lines are appended to OUTFILE. Reads the caller's tmp, issue, top and spec.
_tc_exec() {
  local out="$1" sel="$2" f="$3" cmd base cls dir raw rc id st
  base="${f##*/}"; cls="${base%.*}"; [ -n "$cls" ] || cls="$base"
  dir="${f%/*}"; [ "$dir" != "$f" ] || dir="."
  # Shell-quoted (#752): a route-group path holds ( ) [ ]; one in the old
  # charset has nothing to quote and goes in unchanged.
  printf -v f '%q' "$f"; printf -v cls '%q' "$cls"; printf -v dir '%q' "$dir"
  cmd="${TC_RUN[$sel]}"
  cmd="${cmd//\{file\}/$f}"; cmd="${cmd//\{class\}/$cls}"; cmd="${cmd//\{dir\}/$dir}"
  raw="$tmp/entry.out"
  bash "$SCRIPT_DIR/pipeline-verify.sh" --issue "$issue" --worktree "$top" -- \
    bash -c "$cmd" > "$raw" 2>&1; rc=$?
  cat "$raw" >> "$out"
  if [ -n "${TC_PASS[$sel]}${TC_FAIL[$sel]}" ]; then
    while read -r id st; do
      case "$st" in
        pass) printf '  ok  %s (verify.targeted_commands entry %s)\n' "$id" "${TC_IDX[$sel]}" >> "$out" ;;
        fail) printf 'FAIL  %s (verify.targeted_commands entry %s)\n' "$id" "${TC_IDX[$sel]}" >> "$out" ;;
      esac
    done <<EOF
$(cmd_map "$raw" --spec "$spec" --pass-re "${TC_PASS[$sel]}" --fail-re "${TC_FAIL[$sel]}")
EOF
  fi
  return "$rc"
}

# _qa_exec OUTFILE PATH... -- one run of the Tests files, from the current
# directory; output (stdout+stderr) to OUTFILE. Reads the caller's tmp, issue,
# top, spec, runner, vline and filters. verify.ready (#751) runs first; when it
# fails the files do not run and _QA_ENV_FAIL is set (the caller checks it).
_qa_exec() {
  local out="$1" a=() rest=() q rc=0 r
  shift
  : > "$out"
  _qa_ready || return 1
  for q in "$@"; do
    if _tc_pick "$q"; then
      _tc_exec "$out" "$TC_SEL" "$q"; r=$?
      [ "$rc" -ne 0 ] || rc="$r"
    else
      rest+=("$q")
    fi
  done
  [ "${#rest[@]}" -gt 0 ] || return "$rc"
  if [ "$runner" = talos ]; then
    for q in "${rest[@]}"; do a+=(--for "$q"); done
    bash "$SCRIPT_DIR/pipeline-verify.sh" --issue "$issue" --worktree "$top" -- \
      bash tests/run-tests.sh "${a[@]}" --strict --no-cache >> "$out" 2>&1; r=$?
  else
    bash "$SCRIPT_DIR/pipeline-verify.sh" --issue "$issue" --worktree "$top" -- \
      bash -c "$vline \"\$@\"" talos-qa "${rest[@]}" ${filters[@]+"${filters[@]}"} >> "$out" 2>&1; r=$?
  fi
  [ "$rc" -ne 0 ] || rc="$r"
  return "$rc"
}

cmd_qa_run() {
  local issue="${1:-}" pr="${2:-}" base="" ack="" top
  [ $# -ge 2 ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="${2:-}"; shift 2 || usage ;;
      --ack-changed) ack="${2:-}"; _ack_reason_ok "$ack" || usage; shift 2 || usage ;;
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
  # The raw outputs of an earlier run of this PR are replaced (#751).
  _QA_RAW_SRC="$tmp"; _QA_RAW_DST="$top/.talos/qa-run-$pr"
  rm -rf "${_QA_RAW_DST:?}"
  _QA_READY=(); _QA_ENV_FAIL=""
  _qa_art_init "$tmp" "$top" "$pr" "$vcs"

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
  local n_test n_same n_prose
  n_test="$(printf '%s\n' "$table" | awk '$2 == "test"' | wc -l | tr -d ' ')"
  n_same="$(printf '%s\n' "$table" | awk '$2 == "same"' | wc -l | tr -d ' ')"
  n_prose="$(printf '%s\n' "$table" | awk '$2 == "prose"' | wc -l | tr -d ' ')"

  # 5. No Tests: line on a usable spec: every criterion is prose.
  if [ "$found" -eq 0 ]; then
    printf '%s\n' "$table" | awk '{ printf "%s prose hand-checked\n", $1 }'
    printf 'qa-run: verdict PASS (prose only: %s criteria to hand-check; no tests to run)\n' "$n_prose"
    return 0
  fi

  # 6. Paths must be tracked files at the PR head.
  #    The `**Regression:**` files (#773) are held to the same rules.
  local p present=() missing=() reg_paths reg_refused reg_present=()
  _regression_line "$spec"
  if [ -n "$reg_refused" ]; then
    printf 'qa-run: verdict BLOCKED spec: Regression: line refused (%s)\n' "$reg_refused"
    return 4
  fi
  for p in ${paths[@]+"${paths[@]}"} ${reg_paths[@]+"${reg_paths[@]}"}; do
    if [ -d "$p" ]; then
      printf 'qa-run: verdict BLOCKED spec: Tests: path is a directory: %s\n' "$p"
      return 4
    fi
  done
  for p in ${paths[@]+"${paths[@]}"}; do
    if [ -f "$p" ] && git cat-file -e "$head:$p" 2>/dev/null; then present+=("$p"); else missing+=("$p"); fi
  done
  for p in ${reg_paths[@]+"${reg_paths[@]}"}; do
    if [ -f "$p" ] && git cat-file -e "$head:$p" 2>/dev/null; then reg_present+=("$p"); else missing+=("$p"); fi
  done
  for p in ${missing[@]+"${missing[@]}"}; do echo "qa-run: missing test file: $p"; done

  # 7. The runner. A Tests file that fits a verify.targeted_commands entry (#716)
  #    runs as that entry; the runner below is for the files that fit none.
  local runner vline runner_why label runner_rc=0 c
  _tc_load
  _tc_origin
  while IFS= read -r c; do [ -z "$c" ] || _QA_READY+=("$c"); done <<EOF
$(cfg verify.ready 2>/dev/null)
EOF
  _runner_pick . ${present[@]+"${present[@]}"} ${reg_present[@]+"${reg_present[@]}"} || runner_rc=$?
  case "$runner_rc" in
    4) printf 'qa-run: verdict BLOCKED spec: %s\n' "$runner_why"; return 4 ;;
    3)
      echo "qa-run: no tests/run-tests.sh and no test command in verify:"
      printf 'qa-run: verdict FAIL no usable test runner; hand-check the criteria and say so\n'
      return 3 ;;
  esac
  label="${runner:-targeted}"

  # 8. Head run.
  : > "$tmp/head.out"; : > "$tmp/red.out"
  local head_rc=0
  if [ "${#present[@]}" -gt 0 ]; then
    _qa_art_begin
    _qa_exec "$tmp/head.out" "${present[@]}"; head_rc=$?
    [ -z "$_QA_ENV_FAIL" ] || { _qa_env_blocked; return $?; }
    _qa_art_collect
  fi
  # A failing head run is run once more (#717): the same present Tests files, at
  # the head, before the red run checks anything out. The combined head output
  # has no id-to-file map, so it is the whole set, not one file.
  local rerun_rc=0 rerun_ran=0
  if [ "$head_rc" -ne 0 ] && [ "${#present[@]}" -gt 0 ]; then
    : > "$tmp/rerun.out"
    _qa_exec "$tmp/rerun.out" "${present[@]}"; rerun_rc=$?
    [ -z "$_QA_ENV_FAIL" ] || { _qa_env_blocked; return $?; }
    rerun_ran=1
  fi
  # The **Regression:** files (#773), whole, at the head and apart from the Tests
  # run. Nothing from this output reaches the report: a pass is no evidence for a
  # criterion; a non-zero exit fails the gate below.
  local reg_rc=0
  if [ "${#reg_present[@]}" -gt 0 ]; then
    : > "$tmp/regression.out"
    _qa_exec "$tmp/regression.out" "${reg_present[@]}"; reg_rc=$?
    [ -z "$_QA_ENV_FAIL" ] || { _qa_env_blocked; return $?; }
  fi

  # 9. Red run: the first commit after the merge-base, when its own change is tests-only.
  local note="" bref mb red="" red8="" red_why="" frozen_files=() frozen_rc=0
  if [ "${#present[@]}" -eq 0 ]; then
    note="no test file to run; red proof skipped"
  else
    _red_commit HEAD "$base"
    if [ -n "$red_why" ]; then
      note="$red_why; red proof skipped"
    elif [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      note="the head run left tracked files modified; red proof skipped"
      red=""
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
        [ -z "$_QA_ENV_FAIL" ] || { _qa_env_blocked; return $?; }
        _qa_restore || { _qa_fail "could not return to $_QA_ORIG after the red run"; return $?; }
        # The frozen run (#714): the red commit's version of each Tests file the
        # PR changed since, against the head code. The head versions go back on
        # every path out (_qa_exit covers an interrupt).
        for p in "${at_red[@]}"; do
          git diff --quiet "$red" HEAD -- "$p" 2>/dev/null || frozen_files+=("$p")
        done
        if [ "${#frozen_files[@]}" -gt 0 ]; then
          : > "$tmp/frozen.out"
          _QA_FROZEN=("${frozen_files[@]}")
          if git checkout -q "$red" -- "${frozen_files[@]}" >/dev/null 2>&1; then
            _qa_exec "$tmp/frozen.out" "${frozen_files[@]}"; frozen_rc=$?
            [ -z "$_QA_ENV_FAIL" ] || { _qa_env_blocked; return $?; }
          else
            frozen_rc=-1
          fi
          _qa_restore_frozen
          if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
            _qa_fail "could not restore the head test files after the frozen run"
            return $?
          fi
          [ "$frozen_rc" -ge 0 ] || { _qa_fail "could not check out the red commit's test files for the frozen run"; return $?; }
        fi
      else
        note="could not check out the red commit $red8; red proof skipped"
      fi
    fi
  fi

  # 10. The report.
  local lines rep_rc=0 n_fail
  local tests_s=""
  for p in ${present[@]+"${present[@]}"}; do tests_s="${tests_s:+$tests_s }$p"; done
  echo "qa-run: issue #$issue PR #$pr head $head8 red ${red8:-none} runner $label tests ${tests_s:-none}"
  [ -z "$note" ] || echo "note: $note"
  local rep_args=(--spec "$spec" --red "$tmp/red.out" --head "$tmp/head.out" --red-sha "${red8:-$head8}")
  for p in ${frozen_files[@]+"${frozen_files[@]}"}; do
    printf 'note: frozen run: %s differs from red commit %s\n' "$p" "$red8"
  done
  [ "${#frozen_files[@]}" -eq 0 ] || rep_args+=(--frozen "$tmp/frozen.out")
  [ "$rerun_ran" -eq 0 ] || rep_args+=(--rerun "$tmp/rerun.out")
  [ -z "$ack" ] || rep_args+=(--ack-changed "$ack")
  lines="$(cmd_report "${rep_args[@]}")"; rep_rc=$?
  printf '%s\n' "$lines"
  # The driver's spec-fault check reads these lines, not QA's prose (#678).
  [ -z "${TALOS_QA_RESULTS:-}" ] || printf '%s\n' "$lines" > "$TALOS_QA_RESULTS" 2>/dev/null || :
  n_fail="$(printf '%s\n' "$lines" | grep -cE '^AC[0-9]+ FAIL ')"
  if [ "$n_fail" -gt 0 ] || [ "$head_rc" -ne 0 ] || [ "${#missing[@]}" -gt 0 ]; then
    if grep -qE '^FAIL' "$tmp/head.out" 2>/dev/null; then
      echo "head run failures (test output, data):"
      grep -E -A2 '^FAIL' "$tmp/head.out" | cut -c1-200 | head -n 24 | sed 's/^/  /'
    fi
  fi
  if [ "$reg_rc" -ne 0 ] && grep -qE '^FAIL' "$tmp/regression.out" 2>/dev/null; then
    echo "regression run failures (test output, data):"
    grep -E -A2 '^FAIL' "$tmp/regression.out" | cut -c1-200 | head -n 24 | sed 's/^/  /'
  fi
  # The frozen failure is always shown (#714), also when --ack-changed lets it pass.
  if [ "${#frozen_files[@]}" -gt 0 ] && grep -q 'weakened' <<<"$lines" && grep -qE '^FAIL' "$tmp/frozen.out" 2>/dev/null; then
    echo "frozen run failures (test output, data):"
    grep -E -A2 '^FAIL' "$tmp/frozen.out" | cut -c1-200 | head -n 24 | sed 's/^/  /'
  fi
  local why="" n_flaky
  n_flaky="$(printf '%s\n' "$lines" | grep -cE '^AC[0-9]+ FAIL flaky ')"
  [ "$n_fail" -eq 0 ] || why="$n_fail test criteria FAIL"
  [ "$n_flaky" -eq 0 ] || why="$why ($n_flaky flaky)"
  # A frozen run that failed with no weakened line is a crash, not a verdict on a criterion.
  [ "${#frozen_files[@]}" -eq 0 ] || [ "$frozen_rc" -eq 0 ] || grep -q 'weakened' <<<"$lines" \
    || why="${why:+$why; }frozen run exited $frozen_rc"
  [ "${#missing[@]}" -eq 0 ] || why="${why:+$why; }${#missing[@]} test file(s) missing"
  # A head run that failed only by a flake (the re-run was clean) is already named.
  [ "$head_rc" -eq 0 ] || [ "${#present[@]}" -eq 0 ] || { [ "$n_flaky" -gt 0 ] && [ "$rerun_rc" -eq 0 ]; } \
    || why="${why:+$why; }head run exited $head_rc"
  [ "$reg_rc" -eq 0 ] || why="${why:+$why; }regression run exited $reg_rc"
  [ "$rep_rc" -eq 0 ] || [ -n "$why" ] || why="report failed"
  if [ -n "$why" ]; then
    _qa_fail "$why"
    return $?
  fi
  # The optional e2e step (#717): verify.e2e is repo config, run once at the
  # head, only on an otherwise green verdict that had tests to run.
  local e2e e2e_rc=0 e2e_s=""
  e2e="$(cfg verify.e2e 2>/dev/null)"
  if [ -n "$e2e" ] && [ "${#present[@]}" -gt 0 ]; then
    _qa_art_begin
    bash "$SCRIPT_DIR/pipeline-verify.sh" --issue "$issue" --worktree "$top" -- \
      bash -c "$e2e" > "$tmp/e2e.out" 2>&1; e2e_rc=$?
    _qa_art_collect
    if [ "$e2e_rc" -ne 0 ]; then
      echo "e2e failure output (data):"
      tail -n 24 "$tmp/e2e.out" | cut -c1-200 | sed 's/^/  /'
      _qa_fail "e2e exited $e2e_rc"
      return $?
    fi
    echo "qa-run: e2e ok"
    e2e_s=" e2e ok"
  fi
  _qa_art_attach
  printf 'qa-run: verdict PASS (%s test criteria green,%s %s prose to hand-check)%s\n' "$n_test" "$([ "$n_same" -eq 0 ] || printf ' %s same,' "$n_same")" "$n_prose" "$e2e_s"
  return 0
}

# The throwaway worktree of red-check's red commit (removed on every path out).
_RC_HOME=""
_RC_WT=""
_rc_exit() {
  [ -n "$_RC_WT" ] || return 0
  git -C "$_RC_HOME" worktree remove --force "$_RC_WT" >/dev/null 2>&1 || :
  git -C "$_RC_HOME" worktree prune >/dev/null 2>&1 || :
  _RC_WT=""
}

# _rc_label_re ID: the ERE for a label of ID, the placement parse: the id first
# in a quoted string or after ok/FAIL.
_rc_label_re() { printf '%s' "([\"']|(ok|FAIL)[[:space:]]+)$1([^A-Za-z0-9_]|\$)"; }

# _rc_collisions: lines on stdout for the criteria (table) whose id is already
# labelled in a Tests file before this branch (the file exists at the merge-base
# mb and labels it there) or labelled by two Tests files at the red commit. Pure
# text, one `git show` per file and commit. `id-collision AC<n> file=<f>` for a
# collision a human settles; `droppable AC<n> old=<f> new=<g>` (#773) when exactly
# two Tests files label the id, <f> exists at the merge-base and <g> does not.
_rc_collisions() {
  local id p i re n_red n_lab n_old o_i n_i hit
  local red_txt=() mb_txt=() on_mb=() lab_r=() lab_m=()
  for p in ${paths[@]+"${paths[@]}"}; do
    red_txt+=("$(git show "$red:$p" 2>/dev/null)")
    mb_txt+=("$([ -z "$mb" ] || git show "$mb:$p" 2>/dev/null)")
    if [ -n "$mb" ] && git cat-file -e "$mb:$p" 2>/dev/null; then on_mb+=(1); else on_mb+=(0); fi
  done
  for id in $(printf '%s\n' "$table" | awk '$2 == "test" || $2 == "same" { print $1 }'); do
    re="$(_rc_label_re "$id")"
    n_red=0; n_lab=0; n_old=0; o_i=-1; n_i=-1; i=0
    lab_r=(); lab_m=()
    for p in ${paths[@]+"${paths[@]}"}; do
      lab_r+=(0); lab_m+=(0)
      grep -qE "$re" <<<"${red_txt[$i]}" && { lab_r[$i]=1; n_red=$((n_red + 1)); }
      grep -qE "$re" <<<"${mb_txt[$i]}" && lab_m[$i]=1
      if [ "${lab_r[$i]}" -eq 1 ] || [ "${lab_m[$i]}" -eq 1 ]; then
        n_lab=$((n_lab + 1))
        if [ "${on_mb[$i]}" -eq 1 ]; then n_old=$((n_old + 1)); o_i=$i; else n_i=$i; fi
      fi
      i=$((i + 1))
    done
    if [ "$n_lab" -eq 2 ] && [ "$n_old" -eq 1 ]; then
      printf 'droppable %s old=%s new=%s\n' "$id" "${paths[$o_i]}" "${paths[$n_i]}"
      continue
    fi
    i=0
    for p in ${paths[@]+"${paths[@]}"}; do
      hit="${lab_m[$i]}"
      if [ "$n_red" -ge 2 ] && [ "${lab_r[$i]}" -eq 1 ]; then hit=1; fi
      [ "$hit" -eq 0 ] || printf 'id-collision %s file=%s\n' "$id" "$p"
      i=$((i + 1))
    done
  done
}

# red-check ISSUE [REF] (#747): each criterion's kind against its state at the
# red commit, in a throwaway worktree (the caller's checkout is never touched).
cmd_red_check() {
  local issue="${1:-}" ref="${2:-HEAD}" home sha tmp
  [ $# -ge 1 ] && [ $# -le 2 ] || usage
  case "$issue" in ''|*[!0-9]*) usage ;; esac
  case "$ref" in ''|-*|*[!A-Za-z0-9_./~^@{}-]*) usage ;; esac

  home="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "pipeline-criteria: red-check: not inside a git checkout" >&2; return 1; }
  cd "$home" || return 1
  _VERB=red-check
  if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
    # shellcheck source=pipeline-cfg-cache.sh
    . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
    _talos_on_exit '_rc_exit'
  else
    cfg() { :; }
    trap '_rc_exit' EXIT
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/talos-red-check.XXXXXX")" && [ -d "$tmp" ] \
    || { echo "pipeline-criteria: red-check: no scratch directory" >&2; return 1; }
  if type _talos_on_exit >/dev/null 2>&1; then _talos_on_exit "rm -rf \"$tmp\""; fi

  # 1. The spec, as data; what there is to check.
  local spec="$tmp/spec.md" table paths filters refused found spec_why n_test
  if ! _spec_usable "$issue" "$spec"; then
    printf 'red-check: BLOCKED spec: %s\n' "$spec_why"
    return 4
  fi
  n_test="$(printf '%s\n' "$table" | awk '$2 == "test" || $2 == "same"' | wc -l | tr -d ' ')"
  if [ "$found" -eq 0 ]; then echo "red-check: skipped no Tests: line (prose-only spec)"; return 0; fi
  if [ "$n_test" -eq 0 ]; then echo "red-check: skipped no test criteria"; return 0; fi

  # 2. The red commit of REF.
  sha="$(git rev-parse --verify -q "$ref^{commit}" 2>/dev/null)"
  if [ -z "$sha" ] && [[ "$ref" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
    git fetch -q origin "$ref" >/dev/null 2>&1 || :
    sha="$(git rev-parse --verify -q "$ref^{commit}" 2>/dev/null)"
  fi
  [ -n "$sha" ] || { echo "pipeline-criteria: red-check: cannot resolve $ref" >&2; return 1; }
  local bref mb red red8 red_why p
  _red_commit "$sha" ""
  if [ -n "$red_why" ]; then echo "red-check: skipped $red_why"; return 0; fi
  local at_red=()
  for p in ${paths[@]+"${paths[@]}"}; do
    git cat-file -e "$red:$p" 2>/dev/null && at_red+=("$p")
  done
  if [ "${#at_red[@]}" -eq 0 ]; then echo "red-check: skipped no test file exists at the red commit $red8"; return 0; fi

  # 3. The id collisions (text), then the red run in a detached worktree.
  local out="" cols drop_c n_col=0 n_mis=0 line
  out="$(_rc_collisions)"
  cols="$(printf '%s\n' "$out" | grep '^id-collision ')"
  drop_c="$(printf '%s\n' "$out" | grep '^droppable ')"
  [ -z "$cols" ] || n_col="$(printf '%s\n' "$cols" | wc -l | tr -d ' ')"
  # A droppable collision (#773): the pre-existing file leaves the criteria run
  # and is run whole at the head by qa-run; no drop-file line beside a real collision.
  local dropped=() drops="" n_drop=0 i q id_d old_d new_d kept=()
  if [ "$n_col" -eq 0 ] && [ -n "$drop_c" ]; then
    while read -r _ id_d old_d new_d; do
      old_d="${old_d#old=}"; new_d="${new_d#new=}"
      i=0
      for q in ${dropped[@]+"${dropped[@]}"}; do [ "$q" != "$old_d" ] || i=1; done
      [ "$i" -eq 0 ] || continue
      dropped+=("$old_d")
      drops="${drops}drop-file $old_d reason=id-collision-with-$new_d"$'\n'; n_drop=$((n_drop + 1))
    done <<EOF
$drop_c
EOF
    for p in "${at_red[@]}"; do
      i=0
      for q in "${dropped[@]}"; do [ "$q" != "$p" ] || i=1; done
      [ "$i" -eq 1 ] || kept+=("$p")
    done
    at_red=("${kept[@]}")
    # A (test)/(same) criterion labelled at the red commit in a dropped file and in no kept file.
    local re hit_d hit_k
    for id_d in $(printf '%s\n' "$table" | awk '$2 == "test" || $2 == "same" { print $1 }'); do
      re="$(_rc_label_re "$id_d")"; hit_d=""; hit_k=0
      for p in ${paths[@]+"${paths[@]}"}; do
        git show "$red:$p" 2>/dev/null | grep -qE "$re" || continue
        i=0
        for q in "${dropped[@]}"; do [ "$q" != "$p" ] || i=1; done
        if [ "$i" -eq 1 ]; then hit_d="${hit_d:-$p}"; else hit_k=1; fi
      done
      [ -z "$hit_d" ] || [ "$hit_k" -eq 1 ] || { drops="${drops}to-prose $id_d file=$hit_d"$'\n'; n_drop=$((n_drop + 1)); }
    done
  fi
  local runner vline runner_why runner_rc=0 top="$tmp/wt"
  git worktree add -q --detach "$top" "$red" >/dev/null 2>&1 \
    || { echo "red-check: skipped could not check out the red commit $red8"; return 0; }
  _RC_HOME="$home"; _RC_WT="$top"
  _tc_load
  _runner_pick "$top" "${at_red[@]}" || runner_rc=$?
  case "$runner_rc" in
    4) printf 'red-check: BLOCKED spec: %s\n' "$runner_why"; return 4 ;;
    3) echo "red-check: no tests/run-tests.sh and no test command in verify:"; return 3 ;;
  esac
  : > "$tmp/red.out"
  ( cd "$top" && _qa_exec "$tmp/red.out" "${at_red[@]}" ) >/dev/null 2>&1 || :
  _rc_exit

  # 4. Each (test) that passed at red and each (same) that failed there.
  local id st kind mis=""
  while read -r id st; do
    kind="$(printf '%s\n' "$table" | awk -v i="$id" '$1 == i { print $2 }')"
    if [ "$kind" = test ] && [ "$st" = pass ]; then mis="${mis}kind-mismatch $id want=same"$'\n'; n_mis=$((n_mis + 1))
    elif [ "$kind" = same ] && [ "$st" = fail ]; then mis="${mis}kind-mismatch $id want=test"$'\n'; n_mis=$((n_mis + 1)); fi
  done <<EOF
$(cmd_map "$tmp/red.out" --spec "$spec")
EOF
  [ -z "$mis" ] || printf '%s' "$mis"
  [ -z "$cols" ] || printf '%s\n' "$cols"
  [ -z "$drops" ] || printf '%s' "$drops"
  if [ "$n_col" -gt 0 ]; then echo "red-check: COLLISION $n_col"; return 4; fi
  if [ "$n_drop" -gt 0 ]; then echo "red-check: REVISE $((n_mis + n_drop))"; return 1; fi
  if [ "$n_mis" -gt 0 ]; then echo "red-check: MISMATCH $n_mis"; return 1; fi
  echo "red-check: ok"
}

# The spec text on argv[1] with the red-check findings on stdin applied: each
# `kind-mismatch AC<n> want=same|test` flips the final kind marker of that
# criterion's checklist line. `to-prose AC<n> file=<f>` (#773) rewrites it to
# `(prose: <f> must pass at head)`; `drop-file <f> ...` moves <f> from the
# `Tests:` line (backtick span or bullet) to a `**Regression:**` line right after
# it. The spec's leading `**PM spec:**` is followed by a line saying the driver
# revised it. Every other byte is unchanged. Exit 1 when a listed criterion is
# not a flippable line of the spec or a dropped file is not on the Tests: line.
_REVISE_PY='
import re, sys
text = open(sys.argv[1], encoding="utf-8", newline="").read()
want, order, prose, drops = {}, [], {}, []
for ln in sys.stdin:
    ln = ln.strip()
    m = re.match(r"^kind-mismatch (AC[0-9]+) want=(same|test)$", ln)
    if m and m.group(1) not in want:
        want[m.group(1)] = m.group(2)
        order.append(m.group(1))
    m = re.match(r"^to-prose (AC[0-9]+) file=(\S+)$", ln)
    if m and m.group(1) not in prose:
        prose[m.group(1)] = m.group(2)
    m = re.match(r"^drop-file (\S+)( reason=\S+)?$", ln)
    if m and m.group(1) not in drops:
        drops.append(m.group(1))
if not want and not prose and not drops:
    sys.exit(1)
item = re.compile(r"^[ \t]*[-*][ \t]+\[[ xX]\][ \t]+[*`]*(AC[0-9]+)")
marker = re.compile(r"\((test|prose|same)[:)]")
done = set()
lines = text.split("\n")
for i, ln in enumerate(lines):
    m = item.match(ln)
    if not m or (m.group(1) not in want and m.group(1) not in prose) or m.group(1) in done:
        continue
    ms = list(marker.finditer(ln))
    if not ms:
        continue
    start = ms[-1].start()
    end = ln.find(")", start)
    if end < 0:
        continue
    if m.group(1) in prose:
        # A (test) or (same) whose evidence was only in a dropped file is prose.
        if ms[-1].group(1) == "prose":
            continue
        new = "(prose: %s must pass at head)" % prose[m.group(1)]
    else:
        # (test) is flipped to (same), (same...) to (test); anything else is not a kind to flip.
        if ms[-1].group(1) != ("test" if want[m.group(1)] == "same" else "same"):
            continue
        new = "(same: green at the red commit, found by red-check)" if want[m.group(1)] == "same" else "(test)"
    lines[i] = ln[:start] + new + ln[end + 1:]
    done.add(m.group(1))
if len(done) != len(order) + len(prose):
    sys.stderr.write("revise-spec: not a flippable criterion line: " + " ".join(a for a in order + list(prose) if a not in done) + "\n")
    sys.exit(1)
if drops:
    label = re.compile(r"^\s*(?:[-*+]\s+)?(?:\[[ xX]\]\s+)?\**Tests\**:\**\s*(.*)$")
    at = [(i, label.match(l)) for i, l in enumerate(lines) if label.match(l)]
    if not at:
        sys.stderr.write("revise-spec: no Tests: line to drop from\n")
        sys.exit(1)
    first, m = at[0]
    # The same block the Tests: parse reads: a bare label takes the bullets right under it.
    bullet = r"^\s*[-*+]\s+(?!\[[ xX]\]\s)(.*)$" if not m.group(1).strip().strip("* ") else r"^\s+[-*+]\s+(.*)$"
    last = first + 1
    while last < len(lines) and re.match(bullet, lines[last]):
        last += 1
    block = lines[first:last]
    ch = r"A-Za-z0-9_./()\[\]-"
    for f in drops:
        hit = False
        for k, l in enumerate(block):
            tok = re.escape("`" + f + "`") if "`" in l else "(?<![" + ch + "])" + re.escape(f) + "(?![" + ch + "])"
            for pat in (",[ \t]*" + tok, "[ \t]*" + tok + ",?"):
                new = re.sub(pat, "", l, count=1)
                if new != l:
                    block[k], hit = new, True
                    break
            if hit:
                break
        if not hit:
            sys.stderr.write("revise-spec: not on the Tests: line: " + f + "\n")
            sys.exit(1)
    # A bullet that held only the dropped file goes with it.
    block = [l for k, l in enumerate(block) if k == 0 or re.sub(r"^\s*[-*+]\s*", "", l).strip("*`, \t")]
    block.append("**Regression:** " + " ".join("`%s`" % f for f in drops))
    lines[first:last] = block
text = "\n".join(lines)
why = [("%s is (same) (green at the red commit)" if want[a] == "same" else "%s is (test) (red at the red commit)") % a for a in order]
why += ["%s is (prose: %s must pass at head)" % (a, prose[a]) for a in prose]
why += ["%s is dropped from Tests: (it shares an id with a file the branch adds) and runs as a regression check" % f for f in drops]
why = ", ".join(why)
lead = "**PM spec:**"
note = lead + " revised by the driver after red-check: " + why + "\n\n"
at = text.find(lead)
if at < 0:
    sys.stdout.write(note + text)
else:
    rest = text[at + len(lead):].lstrip(" \t")
    if rest.startswith("\n"):
        rest = rest[1:]
    sys.stdout.write(text[:at] + note + rest)
'

# revise-spec ISSUE (#747): the issue's spec with the red-check findings on
# stdin applied (see _REVISE_PY); the new spec comment on stdout. Reads only.
cmd_revise_spec() {
  local issue="${1:-}" tmp rc=0
  [ $# -eq 1 ] || usage
  case "$issue" in ''|*[!0-9]*) usage ;; esac
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/talos-revise-spec.XXXXXX")" && [ -d "$tmp" ] \
    || { echo "pipeline-criteria: revise-spec: no scratch directory" >&2; return 1; }
  if bash "$SCRIPT_DIR/pipeline-vcs.sh" view-issue "$issue" --spec 2>/dev/null | python3 -I -c "$_QA_SPEC_PY" > "$tmp/spec.md" && [ -s "$tmp/spec.md" ]; then
    python3 -I -c "$_REVISE_PY" "$tmp/spec.md" || rc=$?
  else
    echo "pipeline-criteria: revise-spec: spec unreadable for issue #$issue" >&2; rc=1
  fi
  rm -rf "${tmp:?}"
  return "$rc"
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
  red-check) cmd_red_check "$@" ;;
  revise-spec) cmd_revise_spec "$@" ;;
  *) usage ;;
esac
