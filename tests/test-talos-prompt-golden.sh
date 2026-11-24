#!/usr/bin/env bash
# test-talos-prompt-golden.sh -- the characterisation tests of the talos.sh
# simplification (#1020): table-driven `_talos_prompt`, generated `help`, shared
# run-loop tail helpers. The refactor changes no behaviour, so every criterion
# here is a "same as before" one, pinned against golden output captured from the
# code before the refactor (tests/fixtures/prompt-golden/).
#
#   AC1  `talos.sh prompt` renders the same bytes for each role and shape
#   AC2  `talos.sh help` prints the same text
#   AC3  the run loop's stop and exit lines (a pr-head failure, a clean wait)
#   (AC4, the line count and the helper use, is prose: no test)
#
# Regenerate the fixtures after an INTENDED change, and review the diff:
#   bash tests/test-talos-prompt-golden.sh --regen-fixtures
# Everything runs on stubs under the sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=0 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

FIXDIR="$TALOS_ROOT/tests/fixtures/prompt-golden"
TALOS="$TALOS_ROOT/scripts/talos.sh"
ARGV_ERR="$SANDBOX/golden.stderr"
ARGV_OUT="$SANDBOX/golden.stdout"
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
# Hermetic: an operator env such as PIPELINE_REPO maps onto vcs.repo and leaks into
# rendered prompts (a stub PR URL), so the goldens must never see it.
unset PIPELINE_REPO
# The sandbox repo has Talos's runner, so the qa prompt is the one the goldens pin.
mkdir -p "$SANDBOX/tests"
: > "$SANDBOX/tests/run-tests.sh"

# The prompt cases work on the run fixture's sandbox; its talos.pipeline.json is ours to set.
reset_cfg() { rm -rf "${SANDBOX:?}"/talos.pipeline.*; unset PIPELINE_CONFIG; }
proj_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }

RICH='{
  "vcs": {"provider": "github"},
  "base_branch": "develop",
  "merge": {"required_checks": ["ci / test", "ci / lint"]},
  "ci": {"parallel_with_qa": false},
  "verify": {"commands": ["bash tests/run-tests.sh --quiet", "bash lint.sh"], "targeted": false, "ci_wait_s": 600, "timeout_ms": 300000, "qa_mode": "ci"},
  "comments": {"templates_dir": "tpl/comments"}
}'
# CI scope changed, and the developer verification set with no required checks.
SCOPE='{"vcs": {"provider": "github"}, "merge": {"required_checks": ["ci / test"]}, "verify": {"ci_scope": "changed", "qa_mode": "ci"}}'
LOCAL='{"vcs": {"provider": "github"}, "execution": {"isolation": "branch"}, "verify": {"qa_mode": "local", "commands": ["bash lint.sh"], "dev_tests": ["bash tests/unit.sh"], "walk": {"specs": ["e2e/a.spec.ts"]}}, "ci": {"known_flakes": ["flaky one", "flaky two"]}}'
PARALLEL='{"vcs": {"provider": "github"}, "pr": {"draft": true}, "ci": {"parallel_with_qa": true, "known_flakes": ["flaky one"]}, "merge": {"required_checks": ["ci / test"]}, "verify": {"qa_mode": "ci"}}'
GATE='{"vcs": {"provider": "github"}, "base_branch": "develop", "verify": {"commands": ["bash tests/run-tests.sh --quiet", "bash lint.sh"], "qa_mode": "ci"}, "pr": {"draft": true, "ready_gate": "qa-local"}}'

# Input files for the free-text options (data: they hold shell metacharacters).
F_PRIOR="$SANDBOX/prior.txt"
F_CI="$SANDBOX/ci.txt"
F_DOCS="$SANDBOX/docs-paths.txt"
F_RS="$SANDBOX/restamp.txt"
F_DELTA="$SANDBOX/docs-delta.txt"
printf 'QA FAIL: criterion 2 ($(touch ./pwned) `id`)\nsecond line\n' > "$F_PRIOR"
printf 'check: ci / test\nurl: https://github.com/acme/widget/actions/runs/123\n' > "$F_CI"
printf 'README.md\ndocs/guide.md\n' > "$F_DOCS"
printf 'approved sha: aaa111\nstale files: scripts/a.sh\nhead sha: bbb222\n' > "$F_RS"
printf 'approved_sha=aaa111\nhead_sha=bbb222\ndocs/guide.md\n----- BEGIN DIFF tok590 -----\ndiff --git a/docs/guide.md b/docs/guide.md\n+a new line\n----- END DIFF tok590 -----\n' > "$F_DELTA"

# A private tree whose pipeline-vcs.sh answers pr-is-draft from the environment:
# the one way to reach the pre-CI shape of the qa prompt (talos.sh asks the PR).
GATE_TREE="$SANDBOX/t-gate"
rm -rf "${GATE_TREE:?}"
mkdir -p "$GATE_TREE"
cp -R "$TALOS_ROOT/scripts" "$GATE_TREE/scripts"
cp -R "$TALOS_ROOT/templates" "$GATE_TREE/templates"
printf '#!/usr/bin/env bash\n[ "${1:-}" = pr-is-draft ] || exit 0\nprintf "%%s" "${GATE_PRD_OUT:-}"\nexit "${GATE_PRD_RC:-2}"\n' > "$GATE_TREE/scripts/pipeline-vcs.sh"

# The golden prompt cases: NAME | config | args. Every role in every shape it
# supports (first, fix-round, restamp, pre-ci), under the configs that change its text.
CASES='validator-first|default|validator --issue 468
pm-first|default|pm --issue 468
developer-first|default|developer --issue 468 --prior-file F_PRIOR
developer-first-draft|rich|developer --issue 468 --draft --prior-file F_PRIOR --spec-source issue-body
developer-first-rich|rich|developer --issue 468 --prior-file F_PRIOR
developer-first-local|local|developer --issue 468 --prior-file F_PRIOR
developer-fix-round|default|developer --issue 468 --pr 77 --shape fix-round --prior-file F_PRIOR
developer-fix-round-ci|rich|developer --issue 468 --pr 77 --shape fix-round --draft --prior-file F_PRIOR --ci-failure-file F_CI
qa-first|default|qa --issue 468 --pr 77 --prior-file F_PRIOR
qa-first-rich|rich|qa --issue 468 --pr 77 --prior-file F_PRIOR
qa-first-scope|scope|qa --issue 468 --pr 77
qa-first-local|local|qa --issue 468 --pr 77
qa-first-parallel|parallel|qa --issue 468 --pr 77
qa-pre-ci|gate|qa --issue 468 --pr 77 --prior-file F_PRIOR
qa-restamp|default|qa --issue 468 --pr 77 --shape restamp --restamp-file F_RS
reviewer-first|default|reviewer --issue 468 --pr 77
reviewer-first-draft|default|reviewer --issue 468 --pr 77 --draft
reviewer-first-embed|default|reviewer --issue 468 --pr 77 --embed-change
reviewer-restamp|default|reviewer --issue 468 --pr 77 --shape restamp --restamp-file F_RS
security-first|default|security --issue 468 --pr 77 --prior-file F_PRIOR
security-first-embed|default|security --issue 468 --pr 77 --embed-change
security-restamp|default|security --issue 468 --pr 77 --shape restamp --restamp-file F_RS
adversarial-first|default|adversarial --issue 468 --pr 77
adversarial-restamp|default|adversarial --issue 468 --pr 77 --shape restamp --restamp-file F_RS
docs-first|default|docs --issue 468 --pr 77
docs-first-filtered|default|docs --issue 468 --pr 77 --docs-paths-file F_DOCS
docs-first-embed|default|docs --issue 468 --pr 77 --docs-paths-file F_DOCS --embed-change
docs-restamp|default|docs --issue 468 --pr 77 --shape restamp --restamp-file F_DELTA
validator-fix-round|default|validator --issue 468 --shape fix-round
qa-fix-round|default|qa --issue 468 --pr 77 --shape fix-round
developer-restamp|default|developer --issue 468 --pr 77 --shape restamp
pm-restamp|default|pm --issue 468 --shape restamp
developer-bad-shape|default|developer --issue 468 --shape nonsense'

# case_output CFG ARGS...: the rendered prompt (or the stop line and exit code) of
# one case on stdout. Paths of the checkout and the sandbox are made symbolic.
case_output() {
  local cfg="$1" a args=() talos="$TALOS"
  shift
  reset_cfg
  case "$cfg" in
    rich) proj_json "$RICH" ;;
    scope) proj_json "$SCOPE" ;;
    local) proj_json "$LOCAL" ;;
    parallel) proj_json "$PARALLEL" ;;
    gate) proj_json "$GATE"; talos="$GATE_TREE/scripts/talos.sh"; export GATE_PRD_RC=0 GATE_PRD_OUT=draft ;;
  esac
  for a in "$@"; do
    case "$a" in
      F_PRIOR) args+=("$F_PRIOR") ;; F_CI) args+=("$F_CI") ;; F_DOCS) args+=("$F_DOCS") ;;
      F_RS) args+=("$F_RS") ;; F_DELTA) args+=("$F_DELTA") ;;
      *) args+=("$a") ;;
    esac
  done
  bash "$talos" prompt "${args[@]}" > "$ARGV_OUT" 2> "$ARGV_ERR"
  local rc=$? pf
  unset GATE_PRD_RC GATE_PRD_OUT
  pf="$(sed -n 's/^prompt_file=//p' "$ARGV_OUT")"
  if [ -n "$pf" ]; then
    printf 'exit=%s\n' "$rc"
    # The sandbox path is spelled with `//` (TMPDIR ends in /) and, on macOS, with
    # or without /private: Talos prints the pwd form, so normalise that one.
    sed -E -e "s|$TALOS_ROOT|<TALOS_ROOT>|g" -e "s|$(cd "$SANDBOX" && pwd)|<SANDBOX>|g" \
      -e 's/^----- (BEGIN|END) (SPEC|DIFF) [A-Za-z0-9]{20,} -----$/----- \1 \2 <TOKEN> -----/' "$pf"
    rm -f "${pf:?}"
  else
    printf 'exit=%s\n' "$rc"
    cat "$ARGV_OUT"
  fi
}

# help_output: `talos.sh help` and its exit code.
help_output() {
  bash "$TALOS" help 2> "$ARGV_ERR"
  printf 'exit=%s\n' "$?"
}

# run_output NAME: the stdout and exit code of one run-loop fixture (the fixtures
# of tests/talos-run-sections.sh and tests/test-merge-pr-sha-941.sh).
HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
run_fixture() {
  export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
  case "$1" in
    clean-wait)
      reset_stubs
      LEASE_RESET
      printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}' \
        > "$STUB_DIR/collect.json"
      TALOS_NOW=9000 rn --max-iterations 3 ;;
    head-fail | head-short)
      merge_fixture "$ALL_APPROVALS"
      draft_ready
      printf '%s' "$HEAD_A" > "$STUB_DIR/pr-head.12"
      [ "$1" = head-fail ] && printf 1 > "$STUB_DIR/pr-head.12.rc"
      [ "$1" = head-fail ] || printf 'a4f9' > "$STUB_DIR/pr-head.12"
      TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 1 ;;
  esac
  printf '%s\nexit=%s\n' "$OUT" "$RC"
}
RUN_CASES="clean-wait head-fail head-short"

if [ "${1:-}" = "--regen-fixtures" ]; then
  mkdir -p "$FIXDIR"
  while IFS='|' read -r name cfg args; do
    # shellcheck disable=SC2086
    case_output "$cfg" $args > "$FIXDIR/$name.golden" || exit 1
  done <<EOF
$CASES
EOF
  help_output > "$FIXDIR/help.golden"
  for name in $RUN_CASES; do run_fixture "$name" > "$FIXDIR/run-$name.golden"; done
  printf 'regenerated tests/fixtures/prompt-golden/*.golden\n'
  exit 0
fi

# ── AC1: every rendered prompt is byte-identical ─────────────────────────────
while IFS='|' read -r name cfg args; do
  # shellcheck disable=SC2086
  case_output "$cfg" $args > "$SANDBOX/actual.golden"
  if cmp -s "$FIXDIR/$name.golden" "$SANDBOX/actual.golden"; then
    pass "AC1 prompt $name is byte-identical to the golden"
  else
    fail "AC1 prompt $name is byte-identical to the golden" "differs from tests/fixtures/prompt-golden/$name.golden"
    diff -u --label "golden $name" --label "talos.sh prompt" "$FIXDIR/$name.golden" "$SANDBOX/actual.golden" | head -40 >&2
  fi
done <<EOF
$CASES
EOF

# ── AC2: talos.sh help is unchanged ──────────────────────────────────────────
help_output > "$SANDBOX/actual.golden"
if cmp -s "$FIXDIR/help.golden" "$SANDBOX/actual.golden"; then
  pass "AC2 talos.sh help is byte-identical to the golden"
else
  fail "AC2 talos.sh help is byte-identical to the golden" "differs from tests/fixtures/prompt-golden/help.golden"
  diff -u --label "golden help" --label "talos.sh help" "$FIXDIR/help.golden" "$SANDBOX/actual.golden" | head -40 >&2
fi

# ── AC3: the run loop's stop and exit lines are unchanged ────────────────────
for name in $RUN_CASES; do
  run_fixture "$name" > "$SANDBOX/actual.golden"
  if cmp -s "$FIXDIR/run-$name.golden" "$SANDBOX/actual.golden"; then
    pass "AC3 run fixture $name: stdout and exit code are unchanged"
  else
    fail "AC3 run fixture $name: stdout and exit code are unchanged" "differs from tests/fixtures/prompt-golden/run-$name.golden"
    diff -u --label "golden $name" --label "talos.sh run" "$FIXDIR/run-$name.golden" "$SANDBOX/actual.golden" | head -40 >&2
  fi
done

# A scratch write fed through a pipe (the fix-round block) still stops the run
# with `stop reason=scratch-unavailable` and exit 1, as the old
# `> "$f" || _talos_stop` did. A `mktemp` shim makes the block's scratch file a
# directory inside the cache dir, so only that one write fails. Dropping the
# `|| _talos_stop scratch-unavailable` at that call site turns this red.
SHIM="$SANDBOX/shim-bin"
mkdir -p "$SHIM"
REAL_MKTEMP="$(command -v mktemp)"
printf '#!/bin/sh\nd="$(%s "$@")" || exit 1\ncase "$d" in *talos-cfg-cache.*) mkdir "$d/pb.FIX_ROUND_LINES" ;; esac\nprintf "%%s\\n" "$d"\n' "$REAL_MKTEMP" > "$SHIM/mktemp"
chmod +x "$SHIM/mktemp"
reset_cfg
env -u PIPELINE_CONFIG PATH="$SHIM:$PATH" bash "$TALOS" prompt developer --issue 468 --pr 77 --shape fix-round > "$SANDBOX/scratch.out" 2> "$SANDBOX/scratch.err"
scratch_rc=$?
if [ "$scratch_rc" -eq 1 ] && [ "$(cat "$SANDBOX/scratch.out")" = 'stop reason=scratch-unavailable' ]; then
  pass "AC3 a failed scratch write behind a pipe stops the run with scratch-unavailable"
else
  fail "AC3 a failed scratch write behind a pipe stops the run with scratch-unavailable" "rc=$scratch_rc out=$(cat "$SANDBOX/scratch.out")"
fi

# The goldens above must hold the shapes they claim (a golden of a stop line
# would pin nothing): a clean wait and the head-unresolved stop.
assert_contains "$(cat "$FIXDIR/run-clean-wait.golden")" "stop action=wait reason=none" "AC3 the clean-wait golden holds the wait stop line"
assert_contains "$(cat "$FIXDIR/run-head-fail.golden")" "stop reason=head-unresolved" "AC3 the pr-head failure golden holds stop reason=head-unresolved"

finish
