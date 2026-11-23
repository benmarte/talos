#!/usr/bin/env bash
# Regression test for the CI concurrency/draft race (#1035): a draft-payload
# `synchronize` run (every job skipped) and the `ready_for_review` run for the
# same head shared one concurrency group, so whichever started second cancelled
# the other, and a PR could end with no CI. The group must carry the draft
# state. Checked with awk/sed over the workflow text (no PyYAML).
set -u
. "$(dirname "$0")/helpers.sh"

# group_of <file>: the text after `group:` in the top-level concurrency block.
group_of() {
  awk '/^concurrency:/{c=1;next} c&&/^[^ #]/{c=0} c&&/^  group:/{sub(/^  group: */,"");print;exit}' "$1"
}

# eval_group <group> <event> <pr-number> <draft true|false>: evaluate the
# expression pieces the fix uses; anything left unevaluated stays in the text.
eval_group() {
  local g="$1" ev="$2" num="$3" draft="$4" d
  case "$draft" in true) d=draft ;; *) d=ready ;; esac
  printf '%s' "$g" | sed \
    -e 's/\$[{][{] github\.event_name [}][}]/'"$ev"'/g' \
    -e 's/\$[{][{] github\.event\.pull_request\.number || github\.sha [}][}]/'"$num"'/g' \
    -e 's/\$[{][{] github\.event\.pull_request\.draft == true && .draft. || .ready. [}][}]/'"$d"'/g'
}

# Workflows/templates with a per-PR cancel-in-progress group and a draft skip.
FILES=()
for f in "$TALOS_ROOT"/.github/workflows/*.yml "$TALOS_ROOT"/templates/ci/*.yml; do
  [ -f "$f" ] || continue
  grep -q 'cancel-in-progress' "$f" || continue
  grep -q 'pull_request\.number' "$f" || continue
  grep -q 'pull_request\.draft' "$f" || continue
  FILES+=("$f")
done

WF="$TALOS_ROOT/.github/workflows/tests.yml"
TPL="$TALOS_ROOT/templates/ci/github-tests.yml"

check_group() {  # $1=file $2=AC id $3=label
  local file="$1" ac="$2" label="$3" g d r1 r2
  g="$(group_of "$file")"
  d="$(eval_group "$g" pull_request 42 true)"
  r1="$(eval_group "$g" pull_request 42 false)"
  r2="$(eval_group "$g" pull_request 42 false)"
  assert_not_contains "$d$r1" '${{' "$ac $label: the group evaluates fully for a draft and a ready event"
  if [ -n "$g" ] && [ "$d" != "$r1" ]; then
    assert_eq "differs" "differs" "$ac $label: the group differs between a draft and a ready event"
  else
    assert_eq "differs" "same: '$d'" "$ac $label: the group differs between a draft and a ready event"
  fi
  assert_eq "$r1" "$r2" "$ac $label: two ready events on one PR share a group"
  assert_contains "$d" "42" "$ac $label: the group is still per PR number"
}

check_group "$WF" AC1 ".github/workflows/tests.yml"
check_group "$TPL" AC2 "templates/ci/github-tests.yml"

# AC2: every other file of that shape is covered too.
if [ "${#FILES[@]}" -ge 2 ]; then
  assert_eq "ok" "ok" "AC2 the workflow and the template were both discovered"
else
  assert_eq ">=2 files" "${#FILES[@]} files" "AC2 the workflow and the template were both discovered"
fi
for f in "${FILES[@]}"; do
  case "$f" in "$WF"|"$TPL") continue ;; esac
  check_group "$f" AC2 "${f#"$TALOS_ROOT"/}"
done

# AC3: cancel-in-progress stays scoped to pull_request events.
for f in "${FILES[@]}"; do
  line="$(awk '/^concurrency:/{c=1;next} c&&/^[^ #]/{c=0} c&&/cancel-in-progress:/{print;exit}' "$f")"
  assert_contains "$line" "github.event_name == 'pull_request'" "AC3 ${f#"$TALOS_ROOT"/}: cancel-in-progress is limited to pull_request"
  assert_not_contains "$line" "cancel-in-progress: true" "AC3 ${f#"$TALOS_ROOT"/}: cancel-in-progress is not unconditional"
done

# AC4: the workflow files stay valid under actionlint when it is installed.
if command -v actionlint >/dev/null 2>&1; then
  for f in "${FILES[@]}"; do
    out="$(actionlint "$f" 2>&1)"; rc=$?
    assert_eq "0" "$rc" "AC4 ${f#"$TALOS_ROOT"/}: actionlint passes${out:+ ($out)}"
  done
else
  echo "  skip: actionlint not on PATH -- AC4 workflow lint not run"
fi

finish
