#!/usr/bin/env bash
# test-talos-prompt-golden.sh -- the talos.sh simplification pins (#1020).
#
# The refactor of scripts/talos.sh (table-driven `_talos_prompt`, a help text
# generated from the verb router, shared run-loop tails) changes no behaviour.
# The goldens under tests/fixtures/prompt-golden/ were captured from the code
# before the refactor; this file pins, by criterion id:
#   AC1  every rendered stage prompt is byte-identical: each role in each shape
#        it supports (first, fix-round, restamp, pre-ci), under a default
#        config and a rich one
#   AC2  `talos.sh help` is unchanged
#   AC3  the run loop's stop and exit lines are unchanged: a pr-head that cannot
#        be read before the merge, and a clean wait
# AC4 (complexity reduced) is prose: no test.
# Everything runs on stubs under make_sandbox: no GitHub write, no LLM call.
#
# Regenerate the goldens after an INTENDED output change, and review the diff:
#   bash tests/test-talos-prompt-golden.sh --regen-fixtures
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=1020 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
export TALOS_RETRY_SLEEP_SCALE=0
FIXDIR="$TALOS_ROOT/tests/fixtures/prompt-golden"
POUT="$SANDBOX/prompt.stdout"

# ── the prompt fixture ────────────────────────────────────────────────────────
# The sandbox repo has Talos's runner, so the qa prompt is the full one (#824).
mkdir -p "$SANDBOX/tests"
: > "$SANDBOX/tests/run-tests.sh"

reset_cfg() { rm -rf "${SANDBOX:?}"/talos.pipeline.*; }
RICH='{
  "vcs": {"provider": "github"},
  "base_branch": "develop",
  "merge": {"required_checks": ["ci / test", "ci / lint"]},
  "ci": {"parallel_with_qa": false},
  "verify": {"commands": ["bash tests/run-tests.sh --quiet", "bash lint.sh"], "targeted": false, "ci_wait_s": 600, "timeout_ms": 300000, "qa_mode": "ci"},
  "comments": {"templates_dir": "tpl/comments"}
}'
F_PRIOR="$SANDBOX/prior.txt"
F_CI="$SANDBOX/ci.txt"
F_DOCS="$SANDBOX/docs-paths.txt"
F_RS="$SANDBOX/restamp.txt"
F_DELTA="$SANDBOX/docs-delta.txt"
printf 'QA FAIL: criterion 2 ($(touch ./pwned) `id`)\nsecond line\n' > "$F_PRIOR"
printf 'check: ci / test\nurl: https://github.com/acme/widget/actions/runs/123\n' > "$F_CI"
printf 'README.md\ndocs/guide.md\n' > "$F_DOCS"
printf 'approved sha: aaa111\nstale files: scripts/a.sh\nhead sha: bbb222\n' > "$F_RS"
printf 'approved_sha=aaa111\nhead_sha=bbb222\ndocs/guide.md\n----- BEGIN DIFF tok1020 -----\ndiff --git a/docs/guide.md b/docs/guide.md\n+a new line\n----- END DIFF tok1020 -----\n' > "$F_DELTA"

# A copy of the install whose pipeline-vcs.sh answers pr-is-draft, for the pre-CI shape.
GATE_ROOT="$SANDBOX/t-gate"
mkdir -p "$GATE_ROOT"
cp -R "$TALOS_ROOT/scripts" "$GATE_ROOT/scripts"
cp -R "$TALOS_ROOT/templates" "$GATE_ROOT/templates"
printf '#!/usr/bin/env bash\n[ "${1:-}" = pr-is-draft ] || exit 0\nprintf "%%s" "${GATE_PRD_OUT:-}"\nexit "${GATE_PRD_RC:-2}"\n' > "$GATE_ROOT/scripts/pipeline-vcs.sh"

# CASES: name | config | install (main|gate) | args. F_* names stand for the input files.
CASES='validator-first|default|main|validator --issue 468
pm-first|default|main|pm --issue 468
developer-first|default|main|developer --issue 468 --prior-file F_PRIOR
developer-first-rich|rich|main|developer --issue 468 --prior-file F_PRIOR --spec-source issue-body
developer-first-rich-draft|rich|main|developer --issue 468 --draft
developer-fix-round|default|main|developer --issue 468 --pr 77 --shape fix-round --prior-file F_PRIOR
developer-fix-round-rich-draft|rich|main|developer --issue 468 --pr 77 --shape fix-round --draft --prior-file F_PRIOR --ci-failure-file F_CI
qa-first|default|main|qa --issue 468 --pr 77 --prior-file F_PRIOR
qa-first-rich|rich|main|qa --issue 468 --pr 77 --prior-file F_PRIOR
qa-first-scoped|scoped|main|qa --issue 468 --pr 77 --prior-file F_PRIOR
qa-first-local|local|main|qa --issue 468 --pr 77
developer-first-local|local|main|developer --issue 468
developer-first-devtests|devtests|main|developer --issue 468
qa-restamp|default|main|qa --issue 468 --pr 77 --shape restamp --restamp-file F_RS
qa-pre-ci|gate|gate|qa --issue 468 --pr 77 --prior-file F_PRIOR
reviewer-first|default|main|reviewer --issue 468 --pr 77
reviewer-first-draft|default|main|reviewer --issue 468 --pr 77 --draft
reviewer-restamp|default|main|reviewer --issue 468 --pr 77 --shape restamp --restamp-file F_RS
security-first|default|main|security --issue 468 --pr 77 --prior-file F_PRIOR
security-restamp|default|main|security --issue 468 --pr 77 --shape restamp --restamp-file F_RS
docs-first|default|main|docs --issue 468 --pr 77 --docs-paths-file F_DOCS
docs-first-nopaths|default|main|docs --issue 468 --pr 77
docs-restamp|default|main|docs --issue 468 --pr 77 --shape restamp --restamp-file F_DELTA'

# case_output CFG INSTALL ARGS...: the rendered prompt of one case on stdout.
case_output() {
  local cfg="$1" inst="$2" a args=() root="$TALOS_ROOT"
  shift 2
  reset_cfg
  case "$cfg" in
    scoped) printf '%s' '{"merge": {"required_checks": ["ci / test"]}, "verify": {"commands": ["bash lint.sh"], "ci_scope": "changed", "qa_mode": "ci", "walk": {"specs": ["e2e/a.spec.ts"]}}}' > "$SANDBOX/talos.pipeline.json" ;;
    local) printf '%s' '{"execution": {"isolation": "branch"}, "verify": {"qa_mode": "local", "timeout_ms": 120000}}' > "$SANDBOX/talos.pipeline.json" ;;
    devtests) printf '%s' '{"verify": {"dev_tests": ["bash tests/run-tests.sh --for a"], "commands": ["bash lint.sh"]}}' > "$SANDBOX/talos.pipeline.json" ;;
    rich) printf '%s' "$RICH" > "$SANDBOX/talos.pipeline.json" ;;
    gate) printf '%s' "${RICH%\}}, \"pr\": {\"draft\": true, \"ready_gate\": \"qa-local\"}}" > "$SANDBOX/talos.pipeline.json" ;;
  esac
  if [ "$inst" = gate ]; then root="$GATE_ROOT"; export GATE_PRD_RC=0 GATE_PRD_OUT=draft; fi
  for a in "$@"; do
    case "$a" in
      F_PRIOR) args+=("$F_PRIOR") ;; F_CI) args+=("$F_CI") ;; F_DOCS) args+=("$F_DOCS") ;;
      F_RS) args+=("$F_RS") ;; F_DELTA) args+=("$F_DELTA") ;;
      *) args+=("$a") ;;
    esac
  done
  env -u PIPELINE_CONFIG bash "$root/scripts/talos.sh" prompt "${args[@]}" > "$POUT" 2> "$SANDBOX/prompt.stderr"
  local rc=$? pf
  pf="$(sed -n 's/^prompt_file=//p' "$POUT")"
  if [ "$rc" -ne 0 ] || [ -z "$pf" ]; then printf 'render failed rc=%s: %s\n' "$rc" "$(cat "$POUT")"; return 1; fi
  # The install's absolute paths are the checkout's: the goldens say <TALOS_ROOT>.
  # The sandbox is named by mktemp (and may be spelled through a symlink): match its shape.
  sed -e 's|[^ ]*/talos-test\.[A-Za-z0-9]*/t-gate|<TALOS_ROOT>|g' -e "s|$TALOS_ROOT|<TALOS_ROOT>|g" \
    -e 's|[^ ]*/talos-test\.[A-Za-z0-9]*|<SANDBOX>|g' "$pf"
  rm -f "${pf:?}"
}

# run_tail_output NAME: stdout then the exit code of the two run-loop fixtures.
# pr-head: the head cannot be read before the merge gate; wait: an empty queue.
run_tail_output() {
  case "$1" in
    pr-head-unreadable)
      merge_fixture "$ALL_APPROVALS"
      draft_ready
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
      printf 1 > "$STUB_DIR/pr-head.12.rc"
      TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 1 ;;
    clean-wait)
      reset_stubs
      LEASE_RESET
      printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}' \
        > "$STUB_DIR/collect.json"
      TALOS_NOW=9000 rn --max-iterations 3 ;;
  esac
  printf '%s\nrc=%s\n' "$OUT" "$RC"
}

if [ "${1:-}" = "--regen-fixtures" ]; then
  mkdir -p "$FIXDIR"
  while IFS='|' read -r name cfg inst args; do
    # shellcheck disable=SC2086
    case_output "$cfg" "$inst" $args > "$FIXDIR/$name.golden" || exit 1
  done <<EOF
$CASES
EOF
  bash "$TALOS_ROOT/scripts/talos.sh" help > "$FIXDIR/help.golden"
  run_tail_output pr-head-unreadable > "$FIXDIR/run-pr-head-unreadable.golden"
  run_tail_output clean-wait > "$FIXDIR/run-clean-wait.golden"
  printf 'regenerated tests/fixtures/prompt-golden/*.golden\n'
  exit 0
fi

# check LABEL NAME ACTUAL-FILE: the actual output against the named golden.
check() {
  if cmp -s "$FIXDIR/$2.golden" "$3"; then
    pass "$1"
  else
    fail "$1" "differs from tests/fixtures/prompt-golden/$2.golden"
    diff -u --label "golden $2" --label "actual" "$FIXDIR/$2.golden" "$3" | head -40 >&2
  fi
}

# ── AC1: every rendered prompt is byte-identical ──────────────────────────────
while IFS='|' read -r name cfg inst args; do
  # shellcheck disable=SC2086
  case_output "$cfg" "$inst" $args > "$SANDBOX/actual.golden"
  check "AC1 the $name prompt is byte-identical" "$name" "$SANDBOX/actual.golden"
done <<EOF
$CASES
EOF
unset GATE_PRD_RC GATE_PRD_OUT

# ── AC2: talos.sh help is unchanged ───────────────────────────────────────────
bash "$TALOS_ROOT/scripts/talos.sh" help > "$SANDBOX/actual.help"
check "AC2 talos.sh help is byte-identical" help "$SANDBOX/actual.help"

# ── AC3: the run loop's stop and exit lines are unchanged ─────────────────────
run_tail_output pr-head-unreadable > "$SANDBOX/actual.run"
check "AC3 a pr-head that cannot be read stops the run with the same line and exit code" run-pr-head-unreadable "$SANDBOX/actual.run"
run_tail_output clean-wait > "$SANDBOX/actual.run"
check "AC3 a clean wait ends the run with the same line and exit code" run-clean-wait "$SANDBOX/actual.run"

# A scratch write fed through a pipe (the fix-round block) still stops the run
# with `stop reason=scratch-unavailable` and exit 1, as the old
# `> "$f" || _talos_stop` did. A `mktemp` shim makes the block's scratch file a
# directory inside the cache dir, so only that one write fails.
SHIM="$SANDBOX/shim-bin"
mkdir -p "$SHIM"
REAL_MKTEMP="$(command -v mktemp)"
printf '#!/bin/sh\nd="$(%s "$@")" || exit 1\ncase "$d" in *talos-cfg-cache.*) mkdir "$d/pb.FIX_ROUND_LINES" ;; esac\nprintf "%%s\\n" "$d"\n' "$REAL_MKTEMP" > "$SHIM/mktemp"
chmod +x "$SHIM/mktemp"
reset_cfg
env -u PIPELINE_CONFIG PATH="$SHIM:$PATH" bash "$TALOS_ROOT/scripts/talos.sh" prompt developer --issue 468 --pr 77 --shape fix-round > "$SANDBOX/scratch.out" 2> "$SANDBOX/scratch.err"
scratch_rc=$?
if [ "$scratch_rc" -eq 1 ] && [ "$(cat "$SANDBOX/scratch.out")" = 'stop reason=scratch-unavailable' ]; then
  pass "AC3 a failed scratch write behind a pipe stops the run with scratch-unavailable"
else
  fail "AC3 a failed scratch write behind a pipe stops the run with scratch-unavailable" "rc=$scratch_rc out=$(cat "$SANDBOX/scratch.out")"
fi

finish
