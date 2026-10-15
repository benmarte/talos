#!/usr/bin/env bash
# test-body-file-extension.sh — a stage's body files are hook-safe (#712). A
# project's "no stray .md/.txt" PreToolUse hook blocks a `*.md` body file, so no
# stage could post. A role with Write names a `.talos/<role>-<name>.body` file; a
# role without Write (it cannot create a file) posts from stdin, `--body-file -`.
#  AC1 agents/*.md: --body-file/--summary-file args are `-` or literal .talos/<role>-*.body
#      paths; a profile whose tools: line lacks Write uses `-` only and names no .body path
#  AC2 no "render/post <template>.md" instruction in agents, prompts or refs; developer and
#      docs name their .body file, the read-only roles post with `--body-file -`
#  AC3 planner and llm-loop refs use .talos/*.body, not mktemp or the placeholder F
#  AC4 the body-file verbs treat a .body file exactly as a .md file
set -u
. "$(dirname "$0")/helpers.sh"

AGENTS="$TALOS_ROOT/agents"
PROMPTS="$TALOS_ROOT/templates/prompts"
REFS="$TALOS_ROOT/skills/pipeline/refs"
BODY_RE='^\.talos/[a-z0-9-]+\.body$'

# file_args <file> <flag-regex>: the token after each matching flag, one per line.
file_args() {
  grep -oE -e "--($2) +[^ ]+" "$1" | sed -E 's/^--[a-z-]+ +//; s/[]`\\.,;:)]+$//'
}

# bad_args <file> <flag-regex> [role]: the arguments that are not `-` or a
# literal .talos/*.body path (and, given a role, not under .talos/<role>-).
bad_args() {
  local arg bad=""
  while IFS= read -r arg; do
    [ -n "$arg" ] || continue
    [ "$arg" = "-" ] && continue
    [[ "$arg" =~ $BODY_RE ]] || bad="$bad $arg"
    if [ -n "${3:-}" ]; then
      case "$arg" in .talos/"$3"-*) ;; *) bad="$bad $arg" ;; esac
    fi
  done < <(file_args "$1" "$2")
  printf '%s' "$bad"
}

# ── AC1 ─────────────────────────────────────────────────────────────────────
for f in "$AGENTS"/*.md; do
  role="$(basename "$f" .md)"
  if grep -E '^tools:' "$f" | grep -qw Write; then
    assert_eq "" "$(bad_args "$f" 'body-file|summary-file' "$role")" \
      "AC1 $role: every --body-file/--summary-file argument is - or a literal .talos/$role-*.body path"
  else
    notstdin="$(file_args "$f" 'body-file|summary-file' | grep -vx -e '-' || true)"
    assert_eq "" "$notstdin" "AC1 $role: no Write tool, so every --body-file/--summary-file argument is -"
    assert_eq "0" "$(grep -cE '\.talos/[a-z0-9-]+\.body' "$f")" "AC1 $role: no Write tool, so no .talos/*.body path"
  fi
  text="$(cat "$f")"
  assert_not_contains "$text" "<verdict-file>" "AC1 $role: no <verdict-file> placeholder"
  assert_not_contains "$text" "<summary-file>" "AC1 $role: no <summary-file> placeholder"
  assert_not_contains "$text" "BODY_FILE" "AC1 $role: no BODY_FILE variable"
  assert_not_contains "$text" "COMMENT_BODY" "AC1 $role: no COMMENT_BODY variable"
  assert_eq "0" "$(grep -v 'Scratch scripts' "$f" | grep -c 'mktemp')" "AC1 $role: no mktemp body-file recipe"
done

# ── AC2 ─────────────────────────────────────────────────────────────────────
TEMPLATE_RE='\b([Rr]ender|[Pp]ost)( and post)? `?[a-z][a-z-]*\.md'
hits="$(grep -nE "$TEMPLATE_RE" "$AGENTS"/*.md "$PROMPTS"/*.md "$REFS"/*.md || true)"
assert_eq "" "$hits" "AC2 no instruction renders or posts a <template>.md"
for site in developer:developer-pr-opened developer:developer-blocked docs:docs-posted; do
  role="${site%%:*}"; name="${site#*:}"
  assert_contains "$(cat "$AGENTS/$role.md")" ".talos/$name.body" "AC2 $role: the $name site names .talos/$name.body"
done
for role in validator reviewer security qa adversarial; do
  assert_contains "$(cat "$AGENTS/$role.md")" "--body-file -" "AC2 $role: posts from stdin with --body-file -"
done

# ── AC3 ─────────────────────────────────────────────────────────────────────
planner="$(cat "$REFS/planner.md")"
assert_not_contains "$planner" "BODY_FILE" "AC3 planner ref: no BODY_FILE variable"
assert_contains "$planner" ".talos/planner-sub-issue.body" "AC3 planner ref: the sub-issue body is .talos/planner-sub-issue.body"
for f in "$REFS"/planner.md "$REFS"/llm-loop*.md; do
  n="$(basename "$f")"
  assert_eq "" "$(bad_args "$f" 'prior-file|summary-file|title-file|body-file')" \
    "AC3 $n: --prior-file/--summary-file/--title-file/--body-file recipes use .talos/*.body or -"
  assert_eq "0" "$(grep -c 'mktemp' "$f")" "AC3 $n: no mktemp recipe"
done

# ── AC4 ─────────────────────────────────────────────────────────────────────
make_sandbox
use_stubs
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git config user.email "test@talos.invalid"
git config user.name "talos-test"
export STUB_CURRENT_USER=bot
mkdir -p .talos

# run_verb <ext> <verb args...>: rc in $RC, output in $OUT with the file name
# erased; @F in an argument is the body file.
run_verb() {
  local ext="$1" args=() a; shift
  printf 'the body text\n' > ".talos/x.$ext"
  for a in "$@"; do args+=("$(printf '%s' "$a" | sed "s|@F|.talos/x.$ext|")"); done
  OUT="$(STUB_PR_HEAD_SHA="aabb1122ccdd3344eeff556677889900aabb1122" \
    STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]' \
    bash "$VCS" --dry-run "${args[@]}" 2>&1)"; RC=$?
  OUT="$(printf '%s' "$OUT" | sed "s/x\\.$ext/x.EXT/g")"
}
same_outcome() {  # <verb> <verb args...>
  local name="$1"; shift
  run_verb body "$@"; local rc_body="$RC" out_body="$OUT"
  run_verb md "$@"
  assert_exit_code "$rc_body" "$RC" "AC4 $name: a .body file exits as a .md file does"
  assert_eq "$out_body" "$OUT" "AC4 $name: a .body file prints what a .md file prints"
  assert_exit_code 0 "$rc_body" "AC4 $name: the .body file is accepted"
}
same_outcome comment-issue comment-issue 7 --body-file @F
same_outcome comment-pr comment-pr 8 --body-file @F
same_outcome edit-pr-body edit-pr-body 8 --body-file @F
same_outcome create-pr create-pr fix/x "a title" @F
same_outcome post-approval post-approval 9 qa --issue 5 --body-file @F

finish
