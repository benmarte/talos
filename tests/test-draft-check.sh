#!/usr/bin/env bash
# test-draft-check.sh -- scripts/pipeline-draft-check.sh (#435): the workflow
# check behind the draft-PR default, and the resolver's CI-aware cases.
#
# Covers:
#   (a) `check` prints exactly one of ok, no-skip, no-ready-trigger, none,
#       unknown, always exits 0 and never edits a file; run twice, once with
#       PyYAML and once with it hidden (TALOS_DRAFT_CHECK_NO_YAML=1, the grep
#       path), against the same fixtures
#   (b) templates/ci/github-tests.yml and this repo's tests.yml are `ok`
#   (c) `resolve` with a workflow check: warnings, and the fall back to the ready
#       flow on no-ready-trigger when pr.draft is unset (QA would hang)
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

# Two workflows: one qualifies, one does not and one is unreadable. A qualifying
# workflow is enough.
wf mixed <<'TALOS_wCXa7Ek1Gy5l'
name: tests
on:
  pull_request:
    types: [opened, ready_for_review]
jobs:
  test:
    if: github.event.pull_request.draft != true
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
TALOS_wCXa7Ek1Gy5l
wf mixed other.yaml <<'TALOS_wDYb8Fl2Hz6m'
name: lint
on:
  pull_request:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
TALOS_wDYb8Fl2Hz6m
printf 'name: [x\n' > "$SANDBOX/fx/mixed/.github/workflows/broken.yml"

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
              unk-target:unknown unk-reusable:unknown unk-callable:unknown mixed:ok; do
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

# ── (b) the shipped examples qualify ─────────────────────────────────────────
for how in yaml grep; do
  if [ "$how" = grep ]; then export TALOS_DRAFT_CHECK_NO_YAML=1; else unset TALOS_DRAFT_CHECK_NO_YAML; fi
  assert_eq "ok" "$(bash "$DC" check "$TALOS_ROOT/templates/ci")" "templates/ci/github-tests.yml is ok ($how)"
  assert_eq "ok" "$(bash "$DC" check "$TALOS_ROOT/.github/workflows")" "this repo's .github/workflows is ok ($how)"
done
unset TALOS_DRAFT_CHECK_NO_YAML

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
assert_contains "$SETUP_TEXT" 'Edit the file only after an explicit yes' "setup skill edits a workflow only after an explicit yes"
assert_contains "$SETUP_TEXT" 'never write `draft: true`' "setup skill writes pr.draft only for the non-default"

finish
