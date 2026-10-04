#!/usr/bin/env bash
# test-draft-check.sh -- scripts/pipeline-draft-check.sh (#435): the workflow
# check behind the draft-PR default, and the resolver's CI-aware cases.
#
# Covers:
#   (a) `check` prints exactly one of ok, no-skip, no-ready-trigger, none,
#       unknown, always exits 0 and never edits a file; run twice, once with
#       PyYAML and once with it hidden (TALOS_DRAFT_CHECK_NO_YAML=1, the grep
#       path), against the same fixtures: only a real draft skip counts as ok
#       (!= true, == false, !draft, && combined; not == true or an || branch),
#       the worst state wins across files, a symlink or a file over 1 MB is unknown
#   (b) templates/ci/github-tests.yml and this repo's tests.yml are `ok`
#   (c) `resolve` with a workflow check: warnings, and the fall back to the ready
#       flow on no-ready-trigger when pr.draft is unset (QA would hang)
#   (e) `edit`: the minimal, bounded workflow change (existing job if: combined,
#       types appended, permissions untouched; symlink, outside path, big file,
#       multi-line if: and list-form on: refused)
#   (d) the setup skill calls the script instead of typing a shell loop
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

DC="$TALOS_ROOT/scripts/pipeline-draft-check.sh"
SETUP="$TALOS_ROOT/skills/pipeline-setup/SKILL.md"
WARN_NOSKIP="pipeline: CI does not skip draft PRs; CI will still run on every push. See templates/ci/github-tests.yml"

# wf <name> : a fixture repo; reads the workflow YAML from stdin into <name>/.github/workflows/w.yml
wf() {
  mkdir -p "$SANDBOX/fx/$1/.github/workflows"
  cat > "$SANDBOX/fx/$1/.github/workflows/${2:-w.yml}"
}

wf ok <<'TALOS_w1Kp5Tz8Vn3a'
name: tests
on:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
jobs:
  test:
    if: github.event.pull_request.draft != true
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
TALOS_w1Kp5Tz8Vn3a

wf ok-quoted-on <<'TALOS_w2Mq6Ua9Wo4b'
name: tests
"on":
  pull_request:
    types: [ready_for_review]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
  b:
    if: ${{ github.event.pull_request.draft == false }}
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
TALOS_w2Mq6Ua9Wo4b

wf no-skip <<'TALOS_w3Nr7Vb1Xp5c'
name: tests
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
TALOS_w3Nr7Vb1Xp5c

wf no-skip-list <<'TALOS_w4Ps8Wc2Yq6d'
name: tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
TALOS_w4Ps8Wc2Yq6d

wf no-ready <<'TALOS_w5Qt9Xd3Zr7e'
name: tests
on:
  pull_request:
jobs:
  test:
    if: github.event.pull_request.draft != true
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
TALOS_w5Qt9Xd3Zr7e

wf no-ready-types <<'TALOS_w6Ru1Ye4As8f'
name: tests
on:
  pull_request:
    types: [opened, synchronize]
jobs:
  test:
    if: github.event.pull_request.draft != true
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
TALOS_w6Ru1Ye4As8f

wf none <<'TALOS_w7Sv2Zf5Bt9g'
name: release
on:
  push:
    tags: ['v*']
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
TALOS_w7Sv2Zf5Bt9g

wf unk-target <<'TALOS_w8Tw3Ag6Cu1h'
name: label
on:
  pull_request_target:
    types: [opened]
jobs:
  label:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
TALOS_w8Tw3Ag6Cu1h

wf unk-reusable <<'TALOS_w9Ux4Bh7Dv2i'
name: tests
on:
  pull_request:
    types: [opened, ready_for_review]
jobs:
  call:
    uses: ./.github/workflows/shared.yml
TALOS_w9Ux4Bh7Dv2i

wf unk-callable <<'TALOS_wAVy5Ci8Ew3j'
name: shared
on:
  workflow_call:
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
TALOS_wAVy5Ci8Ew3j

wf unk-broken <<'TALOS_wBWz6Dj9Fx4k'
name: [unterminated
on: {pull_request
jobs: : :
TALOS_wBWz6Dj9Fx4k

# Several workflows: the worst state wins, so a good one never hides a bad one.
OKWF='name: tests
on:
  pull_request:
    types: [opened, ready_for_review]
jobs:
  test:
    if: github.event.pull_request.draft != true
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'
NOSKIPWF='name: lint
on:
  pull_request:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'
NOREADYWF='name: e2e
on:
  pull_request:
    types: [opened, synchronize]
jobs:
  e2e:
    if: github.event.pull_request.draft != true
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'
printf '%s\n' "$OKWF" | wf worst-noskip ok.yml
printf '%s\n' "$NOSKIPWF" | wf worst-noskip lint.yaml
printf '%s\n' "$OKWF" | wf worst-noready ok.yml
printf '%s\n' "$NOREADYWF" | wf worst-noready e2e.yml
printf '%s\n' "$OKWF" | wf ok-unreadable ok.yml
printf 'name: [x\n' > "$SANDBOX/fx/ok-unreadable/.github/workflows/broken.yml"
printf '%s\n' "$OKWF" | wf ok-plus-target ok.yml
printf '%s\n' "$(cat "$SANDBOX/fx/unk-target/.github/workflows/w.yml")" > "$SANDBOX/fx/ok-plus-target/.github/workflows/label.yml"

# What counts as a real draft skip: != true, == false, !draft, alone or && with
# something else, bare or wrapped in ${{ }} or parentheses. == true, an || branch
# and a mere mention do not.
skipwf() {  # $1 = fixture name, $2 = the job's if: value
  printf 'name: t\non:\n  pull_request:\n    types: [ready_for_review]\njobs:\n  t:\n    if: %s\n    runs-on: x\n' "$2" | wf "$1"
}
skipwf s-neq "github.event.pull_request.draft != true"
skipwf s-eqfalse "github.event.pull_request.draft == false"
skipwf s-not '${{ !github.event.pull_request.draft }}'
skipwf s-and "github.event.pull_request.draft != true && github.actor != 'bot'"
skipwf s-wrapped '${{ github.event.pull_request.draft != true }}'
skipwf s-paren "(github.ref == 'refs/heads/main' || github.event_name == 'pull_request') && github.event.pull_request.draft != true"
skipwf s-notparen '${{ !(github.event.pull_request.draft) }}'
skipwf n-eqtrue "github.event.pull_request.draft == true"
skipwf n-or "github.event_name == 'push' || github.event.pull_request.draft != true"
skipwf n-always "always() || github.event.pull_request.draft != true"
skipwf n-mention "github.event.pull_request.draft"
skipwf n-orparen "(github.event.pull_request.draft != true) || github.actor == 'bot'"

# A symlinked workflow is never read (it could point outside the repo).
mkdir -p "$SANDBOX/fx/symlink/.github/workflows" "$SANDBOX/outside"
printf '%s\n' "$OKWF" > "$SANDBOX/outside/ok.yml"
ln -s "$SANDBOX/outside/ok.yml" "$SANDBOX/fx/symlink/.github/workflows/linked.yml"
# A file over 1 MB is never parsed.
printf '%s\n' "$OKWF" | wf huge
dd if=/dev/zero bs=1024 count=1100 2>/dev/null | tr '\0' ' ' >> "$SANDBOX/fx/huge/.github/workflows/w.yml"

mkdir -p "$SANDBOX/fx/empty/.github/workflows" "$SANDBOX/fx/absent"
printf 'x\n' > "$SANDBOX/fx/empty/.github/workflows/README.txt"

run_check() {  # $1 = fixture dir; sets out, rc
  out="$(cd "$1" && bash "$DC" 2>"$SANDBOX/err")"; rc=$?
  err="$(cat "$SANDBOX/err")"
}

check_all() {  # $1 = label suffix
  local sfx="$1" name want broken=""
  # A parse error is only detectable by a real YAML parser.
  [ "$sfx" = "default parser" ] && broken="unk-broken:unknown"
  for pair in $broken ok:ok ok-quoted-on:ok no-skip:no-skip no-skip-list:no-skip no-ready:no-ready-trigger \
              no-ready-types:no-ready-trigger none:none empty:none absent:none \
              unk-target:unknown unk-reusable:unknown unk-callable:unknown \
              worst-noskip:no-skip worst-noready:no-ready-trigger ok-unreadable:ok ok-plus-target:ok \
              s-neq:ok s-eqfalse:ok s-not:ok s-and:ok s-wrapped:ok s-paren:ok s-notparen:ok \
              n-eqtrue:no-skip n-or:no-skip n-always:no-skip n-mention:no-skip n-orparen:no-skip \
              symlink:unknown huge:unknown; do
    name="${pair%%:*}"; want="${pair#*:}"
    run_check "$SANDBOX/fx/$name"
    assert_eq "$want" "$out" "check ($sfx): $name prints $want"
    assert_eq "0" "$rc" "check ($sfx): $name exits 0"
    assert_eq "" "$err" "check ($sfx): $name prints nothing on stderr"
  done
}

# ── (a) both parse paths, same answers ───────────────────────────────────────
unset TALOS_DRAFT_CHECK_NO_YAML
check_all "default parser"
export TALOS_DRAFT_CHECK_NO_YAML=1
check_all "grep fallback"
unset TALOS_DRAFT_CHECK_NO_YAML

# #494: the Actions runner ignores SIGPIPE. `printf "$txt" | grep -q` then makes
# printf hit EPIPE when grep -q exits on its first match, and bash prints
# "printf: write error: Broken pipe" on stderr (a timing-dependent flake). The
# grep fallback reads the file through here-strings instead; prove it stays quiet
# with SIGPIPE ignored and a large (just under the 1 MB cap) workflow.
{
  printf '%s\n' 'on:' '  pull_request:' '    types: [opened, synchronize, ready_for_review]' 'jobs:' '  t:' '    if: github.event.pull_request.draft != true' '    steps:'
  awk 'BEGIN { for (i = 0; i < 15000; i++) print "      - run: echo " i " padding padding padding" }'
} | wf big-pipe
big_size="$(wc -c < "$SANDBOX/fx/big-pipe/.github/workflows/w.yml" | tr -d ' ')"
if [ "$big_size" -gt 700000 ] && [ "$big_size" -le 1048576 ]; then pass "SIGPIPE: the fixture workflow is large but under the 1 MB cap"; else fail "SIGPIPE: the fixture workflow is large but under the 1 MB cap" "$big_size bytes"; fi
pipe_out="$( ( trap '' PIPE; TALOS_DRAFT_CHECK_NO_YAML=1 bash "$DC" check "$SANDBOX/fx/big-pipe/.github/workflows" 2>"$SANDBOX/pipe-err" ) )"
assert_eq "ok" "$pipe_out" "SIGPIPE ignored, large input (grep fallback): still ok"
assert_eq "" "$(cat "$SANDBOX/pipe-err")" "SIGPIPE ignored, large input (grep fallback): nothing on stderr"

# A directory argument, a missing directory and a junk verb all fail open.
assert_eq "ok" "$(bash "$DC" check "$SANDBOX/fx/ok/.github/workflows")" "check <dir>: scans the given directory"
assert_eq "none" "$(bash "$DC" check "$SANDBOX/fx/nope")" "check <dir>: a missing directory is none"
out="$(bash "$DC" bogus 2>/dev/null)"; rc=$?
assert_eq "unknown" "$out" "an unknown verb prints unknown"
assert_eq "0" "$rc" "an unknown verb still exits 0"

# It reads only.
before="$(find "$SANDBOX/fx" -type f | sort | xargs cksum | cksum)"
for d in "$SANDBOX"/fx/*; do (cd "$d" && bash "$DC" >/dev/null 2>&1); done
after="$(find "$SANDBOX/fx" -type f | sort | xargs cksum | cksum)"
assert_eq "$before" "$after" "check never edits a workflow file"

# A multi-line if: cannot be read line by line: the grep path says unknown, never
# ok (PyYAML reads the folded string and can tell).
printf 'on:\n  pull_request:\n    types: [ready_for_review]\njobs:\n  t:\n    if: >-\n      github.event.pull_request.draft != true\n    runs-on: x\n' | wf ml-folded
printf 'on:\n  pull_request:\n    types: [ready_for_review]\njobs:\n  t:\n    if: github.actor != bot &&\n      github.event.pull_request.draft != true\n    runs-on: x\n' | wf ml-plain
for name in ml-folded ml-plain; do
  assert_eq "ok" "$(bash "$DC" check "$SANDBOX/fx/$name/.github/workflows")" "check (default parser): $name reads the condition and is ok"
  assert_eq "unknown" "$(TALOS_DRAFT_CHECK_NO_YAML=1 bash "$DC" check "$SANDBOX/fx/$name/.github/workflows")" "check (grep fallback): $name is unknown, not ok"
done

# ── (b) the shipped examples qualify ─────────────────────────────────────────
for how in yaml grep; do
  if [ "$how" = grep ]; then export TALOS_DRAFT_CHECK_NO_YAML=1; else unset TALOS_DRAFT_CHECK_NO_YAML; fi
  assert_eq "ok" "$(bash "$DC" check "$TALOS_ROOT/templates/ci")" "templates/ci/github-tests.yml is ok ($how)"
  assert_eq "ok" "$(bash "$DC" check "$TALOS_ROOT/.github/workflows")" "this repo's .github/workflows is ok ($how)"
done
unset TALOS_DRAFT_CHECK_NO_YAML

# ── (e) edit: the minimal, bounded workflow change /pipeline-setup offers ─────
# It adds two kinds of line (the types item, an if: on a job that has none) and
# NEVER rewrites an existing job if:, whatever its form; those are reported.
EDIT="$SANDBOX/edit"; mkdir -p "$EDIT/.github/workflows"
WFE="$EDIT/.github/workflows/ci.yml"
cat > "$WFE" <<'TALOS_x5Jd8Rq3Mv1T'
name: ci
on:
  push:
    branches: [main]
  pull_request:
    types: [opened]
permissions:
  contents: read
jobs:
  test:
    if: github.actor != 'dependabot[bot]'
    runs-on: ubuntu-latest
    steps:
      - run: echo test
  lint:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - run: echo lint
  multi:
    if: github.ref == 'refs/heads/main' &&
      !(github.actor == 'bot'
      || github.run_attempt > 3)
    runs-on: ubuntu-latest
    steps:
      - run: echo multi
  folded:
    if: >-
      github.actor != 'bot' &&
      github.run_attempt < 3
    runs-on: ubuntu-latest
    steps:
      - run: echo folded
  combo:
    if: ${{ github.run_attempt > 1 }} && ${{ github.actor != 'bot' }}
    runs-on: ubuntu-latest
    steps:
      - run: echo combo
  deploy:
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    environment: production
    runs-on: ubuntu-latest
    steps:
      - run: echo deploy
TALOS_x5Jd8Rq3Mv1T
cp "$WFE" "$SANDBOX/ci.orig"
edit() { (cd "$EDIT" && bash "$DC" edit "$@" 2>"$SANDBOX/err"); }

diff_out="$(edit .github/workflows/ci.yml)"; rc=$?
assert_eq "0" "$rc" "edit: a proposal exits 0"
assert_eq "$(cksum < "$SANDBOX/ci.orig")" "$(cksum < "$WFE")" "edit: without --write nothing is written"
assert_contains "$diff_out" "+    types: [opened, ready_for_review]" "edit: ready_for_review is appended to the existing types list"
assert_contains "$diff_out" "+    if: github.event.pull_request.draft != true" "edit: a job without an if: gets the skip"
changed_lines="$(printf '%s\n' "$diff_out" | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)')"
assert_eq "3" "$(printf '%s\n' "$changed_lines" | wc -l | tr -d ' ')" "edit: exactly three lines change (types out and in, one added if:)"
assert_not_contains "$changed_lines" "permissions" "edit: no changed line mentions permissions"
assert_not_contains "$(printf '%s\n' "$changed_lines" | grep '^-')" "if:" "edit: no existing if: line is removed or rewritten"
for job in test multi folded combo deploy; do
  assert_contains "$diff_out" "manual: job $job: existing condition left unchanged; combine manually: if: " "edit: the existing if: of job $job is reported, not edited"
done
assert_contains "$diff_out" "manual: job test: existing condition left unchanged; combine manually: if: (github.actor != 'dependabot[bot]') && github.event.pull_request.draft != true" "edit: a one-line condition gets the exact combined suggestion"
for job in multi folded combo; do
  assert_contains "$diff_out" "manual: job $job: existing condition left unchanged; combine manually: if: (<your existing condition>) && github.event.pull_request.draft != true" "edit: job $job (multi-line or compound) gets the generic suggestion"
done
assert_not_contains "$diff_out" "manual: job lint" "edit: a job that got the skip needs no manual note"

edit .github/workflows/ci.yml --write >"$SANDBOX/write.out"; rc=$?
assert_eq "0" "$rc" "edit --write: exits 0"
assert_contains "$(cat "$SANDBOX/write.out")" "manual: job multi:" "edit --write: the manual notes are printed too"
# Every pre-existing line is byte-identical except the one types: line; only two lines are new.
removed="$(diff "$SANDBOX/ci.orig" "$WFE" | grep '^<' | wc -l | tr -d ' ')"
added="$(diff "$SANDBOX/ci.orig" "$WFE" | grep '^>' | wc -l | tr -d ' ')"
assert_eq "1" "$removed" "edit --write: only the types: line is replaced"
assert_eq "2" "$added" "edit --write: the new types: line and one new if: are all that is added"
for frag in "    if: github.actor != 'dependabot[bot]'" "    if: github.ref == 'refs/heads/main' &&" "      || github.run_attempt > 3)" "    if: >-" '    if: ${{ github.run_attempt > 1 }} && ${{ github.actor != '"'"'bot'"'"' }}' "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'" "    environment: production"; do
  assert_eq "$(grep -cxF -- "$frag" "$SANDBOX/ci.orig")" "$(grep -cxF -- "$frag" "$WFE")" "edit --write: kept byte-identical: $frag"
done
assert_eq "$(sed -n '/^permissions:/,/^jobs:/p' "$SANDBOX/ci.orig")" "$(sed -n '/^permissions:/,/^jobs:/p' "$WFE")" "edit --write: the top-level permissions block is untouched"
assert_eq "$(grep -cxF '    permissions:' "$SANDBOX/ci.orig")" "$(grep -cxF '    permissions:' "$WFE")" "edit --write: the job-level permissions block is untouched"
assert_eq "ok" "$(cd "$EDIT" && bash "$DC" check)" "edit --write: the file now skips drafts through the job that got the line"
assert_contains "$(edit .github/workflows/ci.yml)" "no change needed" "edit: a second run has no diff to write"

# The post-edit check refuses anything but the allowed additions (a bug that
# modified, removed or inserted another line would stop here).
read -r -d '' VERIFY_TEST_PY <<'TALOS_f3Hn6Qw9Zc2K' || true
orig = ["on:", "  pull_request:", "    types: [opened]", "jobs:", "  t:", "    if: a && b", "    runs-on: x"]
good = orig[:]
good[2] = "    types: [opened, ready_for_review]"
mod = orig[:]
mod[5] = "    if: (a && b) && github.event.pull_request.draft != true"
print("good", verify(orig, good) is None)
print("modified-if", verify(orig, mod) is not None)
print("deleted", verify(orig, orig[:5] + orig[6:]) is not None)
print("extra-line", verify(orig, orig + ["permissions: write-all"]) is not None)
print("types-rewrite", verify(orig, ["on:", "  pull_request:", "    types: [push]"] + orig[3:]) is not None)
TALOS_f3Hn6Qw9Zc2K
verify_out="$( . "$DC" >/dev/null 2>&1; python3 -I -c "$_DC_PRED"$'\n'"$_DC_VERIFY_PY"$'\n'"$VERIFY_TEST_PY" )"
assert_contains "$verify_out" "good True" "verify: the allowed edit passes"
assert_contains "$verify_out" "modified-if True" "verify: a modified pre-existing if: line is refused"
assert_contains "$verify_out" "deleted True" "verify: a removed line is refused"
assert_contains "$verify_out" "extra-line True" "verify: an added line that is not an if: or types: item is refused"
assert_contains "$verify_out" "types-rewrite True" "verify: a types: line that loses its items is refused"

# types shapes: missing, block list, empty flow list.
mkedit() {  # $1 = name, stdin = workflow
  mkdir -p "$SANDBOX/e/$1/.github/workflows"; cat > "$SANDBOX/e/$1/.github/workflows/w.yml"
}
mkedit notypes <<'TALOS_y6Ke9Sr4Nw2U'
on:
  pull_request:
    branches: [main]
jobs:
  t:
    runs-on: x
TALOS_y6Ke9Sr4Nw2U
out="$(cd "$SANDBOX/e/notypes" && bash "$DC" edit .github/workflows/w.yml)"
assert_contains "$out" "+    types: [opened, synchronize, reopened, ready_for_review]" "edit: a missing types gets the default set plus ready_for_review"
mkedit blocklist <<'TALOS_z7Lf1Ts5Px3V'
on:
  pull_request:
    types:
      - opened
      - synchronize
jobs:
  t:
    runs-on: x
TALOS_z7Lf1Ts5Px3V
out="$(cd "$SANDBOX/e/blocklist" && bash "$DC" edit .github/workflows/w.yml)"
assert_contains "$out" "+      - ready_for_review" "edit: a block list gets one more item at its own indent"
mkedit bare <<'TALOS_a8Mg2Ut6Qy4W'
on:
  pull_request:
jobs:
  t:
    runs-on: x
TALOS_a8Mg2Ut6Qy4W
out="$(cd "$SANDBOX/e/bare" && bash "$DC" edit .github/workflows/w.yml --write)"
assert_eq "ok" "$(cd "$SANDBOX/e/bare" && bash "$DC" check)" "edit --write: a bare pull_request trigger ends ok"

# A job `if:` or the trigger's `types:` written in a non-plain form (quoted key,
# `key :`, `? key`, an escaped spelling, a `<<:` merge key, `types: []`) must
# get nothing added (a second key is invalid YAML): the job or trigger is
# reported as manual, exit 0, and --write leaves the file byte-identical.
np_case() {  # $1 = label, $2 = job body line(s) for job `guarded`, $3 = pull_request body line(s), $4 = expected manual text
  local d="$SANDBOX/e/np-$1" out before after rc
  mkdir -p "$d/.github/workflows"
  printf 'on:\n  pull_request:\n%s\njobs:\n  guarded:\n%s\n    runs-on: x\n' "$3" "$2" > "$d/.github/workflows/w.yml"
  before="$(cksum < "$d/.github/workflows/w.yml")"
  out="$(cd "$d" && bash "$DC" edit .github/workflows/w.yml --write)"; rc=$?
  after="$(cksum < "$d/.github/workflows/w.yml")"
  assert_eq "0" "$rc" "edit non-plain $1: exits 0 (the manual path)"
  assert_eq "$before" "$after" "edit non-plain $1: no line was added"
  assert_not_contains "$out" "written:" "edit non-plain $1: nothing is written"
  assert_contains "$out" "$4" "edit non-plain $1: reported as manual"
}
PLAIN_T='    types: [opened, ready_for_review]'
PLAIN_IF='    if: github.event.pull_request.draft != true'
JOB_MANUAL="manual: job guarded: existing condition left unchanged; combine manually: if: "
TRIG_MANUAL="manual: trigger pull_request: existing types left unchanged; add ready_for_review manually: types: "
np_case dq-if "    \"if\": github.actor != 'bot'" "$PLAIN_T" "$JOB_MANUAL"
np_case sq-if "    'if': github.actor != 'bot'" "$PLAIN_T" "$JOB_MANUAL"
np_case space-if "    if : github.actor != 'bot'" "$PLAIN_T" "$JOB_MANUAL"
np_case complex-if "    ? if
    : github.actor != 'bot'" "$PLAIN_T" "$JOB_MANUAL"
np_case escaped-if "    \"\\x69f\": github.actor != 'bot'" "$PLAIN_T" "$JOB_MANUAL"
np_case merge-if '    <<: *defaults' "$PLAIN_T" "$JOB_MANUAL"
np_case tagged-if "    !!str if: github.actor != 'bot'" "$PLAIN_T" "$JOB_MANUAL"
np_case anchored-if "    &a if: github.actor != 'bot'" "$PLAIN_T" "$JOB_MANUAL"
np_case wide-escape-if "    \"\\U00000069f\": github.actor != 'bot'" "$PLAIN_T" "$JOB_MANUAL"
np_case block-complex-if '    ? |
      if
    : github.actor' "$PLAIN_T" "$JOB_MANUAL"
np_case merge-beside-plain-if "    if: github.event.pull_request.draft != true
    <<: *defaults" "$PLAIN_T" "$JOB_MANUAL"
np_case tagged-types "$PLAIN_IF" '    !!str types: [opened]' "$TRIG_MANUAL"
np_case anchored-types "$PLAIN_IF" '    &a types: [opened]' "$TRIG_MANUAL"
np_case wide-escape-types "$PLAIN_IF" '    "\U00000074ypes": [opened]' "$TRIG_MANUAL"
np_case block-complex-types "$PLAIN_IF" '    ? |
      types
    : [opened]' "$TRIG_MANUAL"
np_case dq-types "$PLAIN_IF" '    "types": [opened]' "$TRIG_MANUAL"
np_case sq-types "$PLAIN_IF" "    'types': [opened]" "$TRIG_MANUAL"
np_case space-types "$PLAIN_IF" '    types : [opened]' "$TRIG_MANUAL"
np_case complex-types "$PLAIN_IF" '    ? types
    : [opened]' "$TRIG_MANUAL"
np_case merge-types "$PLAIN_IF" '    <<: *trigger' "$TRIG_MANUAL"
np_case empty-types "$PLAIN_IF" '    types: []' "$TRIG_MANUAL"
np_case empty-types-spaced "$PLAIN_IF" '    types: [ ]  # none' "$TRIG_MANUAL"
# The non-plain job is left alone while a sibling job with no if: still gets the skip.
mkedit mixed <<'TALOS_Vn4Qd7Ls2Ymx'
on:
  pull_request:
    types: [opened, ready_for_review]
jobs:
  quoted:
    "if": github.actor != 'bot'
    runs-on: x
  bare:
    runs-on: x
TALOS_Vn4Qd7Ls2Ymx
out="$(cd "$SANDBOX/e/mixed" && bash "$DC" edit .github/workflows/w.yml)"
assert_contains "$out" "manual: job quoted: " "edit non-plain: the quoted-if job is reported"
assert_contains "$out" "+    if: github.event.pull_request.draft != true" "edit non-plain: a sibling job without an if: still gets the skip"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^+    if:')" "edit non-plain: only the sibling gets an added if:"

# Refusals write nothing and exit 1 with `refused:`.
refuse_case() {  # $1 = label, $2 = fixture dir, $3 = path, $4 = text expected on stderr
  local before after
  before="$(find "$2" "$SANDBOX/outside" -type f | sort | xargs cksum | cksum)"
  (cd "$2" && bash "$DC" edit "$3" --write >/dev/null 2>"$SANDBOX/err"); rc=$?
  after="$(find "$2" "$SANDBOX/outside" -type f | sort | xargs cksum | cksum)"
  assert_eq "1" "$rc" "edit refuses: $1 (exit 1)"
  assert_contains "$(cat "$SANDBOX/err")" "refused: " "edit refuses: $1 (says why)"
  assert_contains "$(cat "$SANDBOX/err")" "$4" "edit refuses: $1 (reason)"
  assert_eq "$before" "$after" "edit refuses: $1 (nothing written, the link target is untouched)"
}
mkdir -p "$SANDBOX/e/linkfile/.github/workflows"
printf 'on:\n  pull_request:\njobs:\n  t:\n    runs-on: x\n' > "$SANDBOX/outside/target.yml"
ln -s "$SANDBOX/outside/target.yml" "$SANDBOX/e/linkfile/.github/workflows/w.yml"
refuse_case "a symlinked workflow file" "$SANDBOX/e/linkfile" .github/workflows/w.yml "symlink"
mkdir -p "$SANDBOX/e/linkdir/.github" "$SANDBOX/outside/workflows"
printf 'on:\n  pull_request:\njobs:\n  t:\n    runs-on: x\n' > "$SANDBOX/outside/workflows/w.yml"
ln -s "$SANDBOX/outside/workflows" "$SANDBOX/e/linkdir/.github/workflows"
refuse_case "a symlinked workflows directory" "$SANDBOX/e/linkdir" .github/workflows/w.yml "symlink"
mkedit elsewhere <<'TALOS_b9Nh3Vu7Rz5X'
on:
  pull_request:
jobs:
  t:
    runs-on: x
TALOS_b9Nh3Vu7Rz5X
cp "$SANDBOX/e/elsewhere/.github/workflows/w.yml" "$SANDBOX/e/elsewhere/other.yml"
refuse_case "a file outside .github/workflows" "$SANDBOX/e/elsewhere" other.yml "not a workflow file"
refuse_case "a file with a path escape" "$SANDBOX/e/elsewhere" .github/workflows/../../other.yml "not a workflow file"
mkdir -p "$SANDBOX/e/hugefile/.github/workflows"
cp "$SANDBOX/fx/huge/.github/workflows/w.yml" "$SANDBOX/e/hugefile/.github/workflows/w.yml"
refuse_case "a file over 1 MB" "$SANDBOX/e/hugefile" .github/workflows/w.yml "over 1 MB"
mkedit onlist <<'TALOS_d2Qk5Xw9Tb7Z'
on: [push, pull_request]
jobs:
  t:
    runs-on: x
TALOS_d2Qk5Xw9Tb7Z
refuse_case "a list-form on:" "$SANDBOX/e/onlist" .github/workflows/w.yml "not a block mapping"
out="$(bash "$DC" edit 2>&1)"; rc=$?
assert_eq "1" "$rc" "edit with no file exits 1"

# ── (c) resolve, with the CI check ───────────────────────────────────────────
resolve_in() {  # $1 = fixture dir, $2 = JSON config; prints "<value>|<stderr>"
  printf '%s\n' "$2" > "$SANDBOX/cfg.json"
  ( cd "$1" && PIPELINE_CONFIG="$SANDBOX/cfg.json" bash "$DC" resolve 2>"$SANDBOX/err" | tr -d '\n'; printf '|%s' "$(cat "$SANDBOX/err")" )
}
GH_UNSET='{"vcs":{"provider":"github"}}'
GH_TRUE='{"vcs":{"provider":"github"},"pr":{"draft":true}}'
GH_FALSE='{"vcs":{"provider":"github"},"pr":{"draft":false}}'
NOREADY_UNSET="false|pipeline: CI skips draft PRs but has no ready_for_review trigger, so QA would wait for a run that never starts; using the ready PR flow for this run. Add ready_for_review to on.pull_request.types (templates/ci/github-tests.yml) or set pr.draft: false"
NOREADY_TRUE="true|pipeline: pr.draft is true but CI skips draft PRs without a ready_for_review trigger; QA will wait for a run that never starts. Add ready_for_review to on.pull_request.types (templates/ci/github-tests.yml)"

assert_eq "true|" "$(resolve_in "$SANDBOX/fx/ok" "$GH_UNSET")" "resolve: ok CI, key unset: true, silent"
assert_eq "true|" "$(resolve_in "$SANDBOX/fx/none" "$GH_UNSET")" "resolve: no PR workflow, key unset: true, silent"
assert_eq "true|$WARN_NOSKIP" "$(resolve_in "$SANDBOX/fx/no-skip" "$GH_UNSET")" "resolve: CI that never skips drafts warns once and stays true"
assert_eq "true|$WARN_NOSKIP" "$(resolve_in "$SANDBOX/fx/no-skip" "$GH_TRUE")" "resolve: explicit true with a CI that never skips drafts warns and stays true"
assert_eq "$NOREADY_UNSET" "$(resolve_in "$SANDBOX/fx/no-ready" "$GH_UNSET")" "resolve: skip without ready_for_review, key unset: falls back to the ready flow with a warning (QA would hang)"
assert_eq "$NOREADY_TRUE" "$(resolve_in "$SANDBOX/fx/no-ready" "$GH_TRUE")" "resolve: skip without ready_for_review, explicit true: warns, stays true"
assert_eq "false|" "$(resolve_in "$SANDBOX/fx/no-ready" "$GH_FALSE")" "resolve: explicit false never runs the check, silent"
assert_eq "true|pipeline: could not verify that CI skips draft PRs; see templates/ci/github-tests.yml" "$(resolve_in "$SANDBOX/fx/unk-reusable" "$GH_UNSET")" "resolve: an unreadable CI gets one note and stays true"
# The CI check is github-only: gitlab and azure ignore .github/workflows.
assert_eq "true|" "$(resolve_in "$SANDBOX/fx/no-ready" '{"vcs":{"provider":"gitlab"}}')" "resolve: gitlab does not run the github CI check"
assert_eq "true|" "$(resolve_in "$SANDBOX/fx/no-skip" '{"vcs":{"provider":"azure"}}')" "resolve: azure does not run the github CI check"
assert_eq "false|pipeline: pr.draft ignored: provider github-api cannot open draft PRs" "$(resolve_in "$SANDBOX/fx/no-ready" '{"vcs":{"provider":"github-api"}}')" "resolve: github-api is false before any CI check"

# ── (d) the setup skill calls the script, no typed loop ──────────────────────
SETUP_TEXT="$(cat "$SETUP")"
assert_contains "$SETUP_TEXT" 'bash scripts/pipeline-draft-check.sh' "setup skill runs the check script"
assert_not_contains "$SETUP_TEXT" 'for f in .github/workflows' "setup skill carries no shell loop over the workflows"
assert_not_contains "$SETUP_TEXT" 'missing draft != true guard' "setup skill no longer carries the old loop's output lines"
for status in ok no-skip no-ready-trigger none unknown; do
  assert_contains "$SETUP_TEXT" "- \`$status\`:" "setup skill explains the $status status"
done
assert_contains "$SETUP_TEXT" 'Only after an explicit yes run the same command with `--write`' "setup skill edits a workflow only after an explicit yes"
assert_contains "$SETUP_TEXT" 'never write `draft: true`' "setup skill writes pr.draft only for the non-default"

finish
