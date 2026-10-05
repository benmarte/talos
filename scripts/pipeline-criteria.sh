#!/usr/bin/env bash
# pipeline-criteria.sh -- map a spec's acceptance criteria to test results by
# id (#421). Pure text processing: no network, no LLM, no git.
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
#
# Exit codes: 0 ok, 1 a failing report or an unreadable/empty input, 2 usage.
set -uo pipefail

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

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  ids) cmd_ids "$@" ;;
  map) cmd_map "$@" ;;
  report) cmd_report "$@" ;;
  *) usage ;;
esac
