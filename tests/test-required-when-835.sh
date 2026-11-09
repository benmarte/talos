#!/usr/bin/env bash
# test-required-when-835.sh -- `roles.required_when` (#835, part 4 of #826):
# risk-based review. A repo names the paths that make reviewer, security and
# adversarial mandatory; a diff that touches none of them skips the roles that
# have an entry. Every gate stays; anything unclear requires every role.
#   AC1  required-roles: no match -> the roles with an entry are skipped
#   AC2  required-roles: any match (root-level cases included) -> every role
#   AC3  required-roles: every fail-closed input names its reason
#   AC4  no key: `next` makes no required-roles call, --required-when no
#   AC5  pipeline-next.py routes by the decision
#   AC6  gate merge waits only on the roles the decision requires
#   AC7  the decision is recorded once per head and decision
#   AC8  gate merge refuses a recorded decision that skips a role it requires
#   AC9  check-approval-sha is unchanged by the key
#   AC10 the defaults row and docs/reference.md name the key
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
SHA="0123456789abcdef0123456789abcdef01234567"
OTHER="fedcba9876543210fedcba9876543210fedcba98"

# ── AC1-AC3: the verb, over the github transport stub ────────────────────────
# One request for the head, one for the changed files (one canned response each).
GLOBS='"internal/auth/**","**/migrations/**","**/*secret*"'
RT_BOTH="\"required_when\": {\"security\": [$GLOBS], \"adversarial\": [$GLOBS]}"
rr() {  # <roles members> <files json> [provider leg]: run required-roles 9; OUT, RC
  github_leg "${3:-gh}" ",\"roles\": {\"adversarial\": true${1:+, $1}}"
  printf '%s\n%s\n' "{\"head\":{\"sha\":\"$SHA\"}}" "$2" > "$CURL_QUEUE"
  : > "$CURL_LINK_QUEUE"
  OUT="$(bash "$VCS" required-roles 9 2>"$SANDBOX/rr.err")"; RC=$?
}
field() { printf '%s\n' "$OUT" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1; }
fj() {  # paths... -> a files array of {"filename": path}
  local out="" p
  for p in "$@"; do out="${out:+$out,}{\"filename\":\"$p\",\"status\":\"modified\"}"; done
  printf '[%s]' "$out"
}

rr "$RT_BOTH" "$(fj docs/guide.md web/app.tsx)"
assert_eq "0" "$RC" "AC1 a non-matching diff: exit 0"
assert_eq "reviewer" "$(field roles)" "AC1 no match: roles= keeps reviewer"
assert_eq "security,adversarial" "$(field skipped)" "AC1 no match: skipped= names security and adversarial"
assert_eq "no-match" "$(field reason)" "AC1 no match: reason=no-match"
assert_eq "$SHA" "$(field head)" "AC1 the line carries the PR head"
rr "\"required_when\": {\"security\": [$GLOBS]}" "$(fj docs/guide.md)"
assert_eq "reviewer,adversarial" "$(field roles)" "AC1 a role with no required_when entry stays in roles="
assert_eq "security" "$(field skipped)" "AC1 only the role with an entry is skipped"

for _c in "migrations/001.sql" "secret.go" "Internal/Auth/x.go" "db/migrations/002.sql" "web/app.tsx|cmd/Crypto/Secret_Key.go"; do
  _paths=(${_c//|/ })
  rr "$RT_BOTH" "$(fj docs/guide.md "${_paths[@]}")"
  assert_eq "reviewer,security,adversarial" "$(field roles)" "AC2 $_c: every enabled review role"
  assert_eq "-" "$(field skipped)" "AC2 $_c: skipped=-"
  assert_eq "matched" "$(field reason)" "AC2 $_c: reason=matched"
  assert_contains "$(field matched)" "${_paths[${#_paths[@]}-1]}" "AC2 $_c: matched= lists the path"
done
rr "$RT_BOTH" "$(fj migrations/001.sql secret.go)"
assert_eq "2" "$(field matched_count)" "AC2 matched_count counts the matching paths"
# A disabled role stays off, matched or not.
github_leg gh ',"roles": {"adversarial": false, "required_when": {"security": ["internal/auth/**"]}}'
printf '%s\n%s\n' "{\"head\":{\"sha\":\"$SHA\"}}" "$(fj internal/auth/x.go)" > "$CURL_QUEUE"
OUT="$(bash "$VCS" required-roles 9 2>/dev/null)"
assert_eq "reviewer,security" "$(field roles)" "AC2 roles.adversarial false: it is not required"

# AC3: each of these requires every enabled review role and names its reason.
ALL3="reviewer,security,adversarial"
fail_case() {  # <label> <expected reason> <roles members> <files json> [leg]
  rr "$3" "$4" "${5:-gh}"
  assert_eq "$ALL3" "$(field roles)" "AC3 $1: every enabled review role"
  assert_eq "-" "$(field skipped)" "AC3 $1: skipped=-"
  assert_eq "$2" "$(field reason)" "AC3 $1: reason=$2"
  assert_eq "0" "$RC" "AC3 $1: still exit 0 (it decided)"
}
fail_case "empty file list" files-unreadable "$RT_BOTH" '[]'
github_leg gh ",\"roles\": {\"adversarial\": true, $RT_BOTH}"
printf '%s\n%s\n' "{\"head\":{\"sha\":\"$SHA\"}}" "500" > "$CURL_QUEUE"
OUT="$(bash "$VCS" required-roles 9 2>/dev/null)"
assert_eq "$ALL3" "$(field roles)" "AC3 unreadable file list: every enabled review role"
assert_eq "files-unreadable" "$(field reason)" "AC3 unreadable file list: reason=files-unreadable"
fail_case "absolute path" unclassified "$RT_BOTH" "$(fj docs/a.md /etc/passwd)"
fail_case "dot-dot segment" unclassified "$RT_BOTH" "$(fj docs/../internal/x.go)"
fail_case "backslash" unclassified "$RT_BOTH" '[{"filename":"docs\\a.md","status":"modified"}]'
fail_case "control character" unclassified "$RT_BOTH" '[{"filename":"docs/a\u0001.md","status":"modified"}]'
fail_case "rename from a matching path" unclassified "$RT_BOTH" \
  '[{"filename":"web/new.ts","status":"renamed","previous_filename":"internal/auth/old.go"}]'
fail_case "rename with no previous name" unclassified "$RT_BOTH" '[{"filename":"web/new.ts","status":"renamed"}]'
fail_case "non-list value" config-invalid '"required_when": {"security": "internal/auth/**"}' "$(fj docs/a.md)"
fail_case "empty glob" config-invalid '"required_when": {"security": [""]}' "$(fj docs/a.md)"
fail_case "role qa" config-invalid '"required_when": {"qa": ["internal/auth/**"]}' "$(fj docs/a.md)"
for _p in gitlab azure; do
  printf '{"vcs": {"provider": "%s"}, "roles": {"adversarial": true, %s}}\n' "$_p" "$RT_BOTH" > talos.pipeline.json
  OUT="$(bash "$VCS" required-roles 9 2>/dev/null)"; RC=$?
  assert_eq "unsupported-provider" "$(field reason)" "AC3 provider $_p: reason=unsupported-provider"
  assert_eq "$ALL3" "$(field roles)" "AC3 provider $_p: every enabled review role"
  assert_eq "0" "$RC" "AC3 provider $_p: exit 0"
done
# The same PR with a rename that matches neither side stays a no-match.
rr "$RT_BOTH" '[{"filename":"web/new.ts","status":"renamed","previous_filename":"web/old.ts"}]'
assert_eq "no-match" "$(field reason)" "AC1 a rename between non-matching paths is a no-match"

# ── AC4, AC5: next, through the real collect over a stub pipeline-vcs.sh ─────
PARENT="$SANDBOX/collect"
FX="$PARENT/fx"
SCR="$PARENT/scripts"
mkdir -p "$FX" || exit 1
export SF_FX="$FX"
cp -R "$TALOS_ROOT/scripts" "$SCR"
cat > "$SCR/pipeline-vcs.sh" <<'TALOS_stubvcs835Wq4NzRb'
#!/usr/bin/env bash
# Verb-level stub: a read verb answers from $SF_FX, any other verb is a WRITE.
FX="${SF_FX:?}"
verb="${1:-}"; shift
rc_of() { if [ -f "$FX/$1" ]; then cat "$FX/$1"; else echo "${2:-0}"; fi; }
case "$verb" in
  list-prs) cat "$FX/prs.json"; exit 0 ;;
  list-issues) cat "$FX/issues.json"; exit 0 ;;
  list-needs-owner) echo '[]'; exit 0 ;;
  pr-head) cat "$FX/head.$1"; exit 0 ;;
  check-approval-sha) exit 0 ;;
  pr-checks-required) exit 0 ;;
  pr-is-draft) echo ready; exit 1 ;;
  current-user) exit 1 ;;
  required-roles)
    printf 'required-roles %s\n' "$1" >> "$FX/rr.log"
    [ -f "$FX/rr.out" ] && cat "$FX/rr.out"
    exit "$(rc_of rr.rc 0)" ;;
  *) printf 'WRITE %s\n' "$verb" >> "$FX/writes.log"; exit 99 ;;
esac
TALOS_stubvcs835Wq4NzRb
stage_of() {  # <labels comma list>: the stage of PR 10 through collect
  local l out="" IFS=,
  for l in $1; do out="${out:+$out,}{\"name\":\"$l\"}"; done
  printf '[{"number":10,"title":"PR 10","headRefName":"fix/issue-10-x","baseRefName":"main","isCrossRepository":false,"labels":[%s]}]' "$out" > "$FX/prs.json"
  printf '[{"number":10,"title":"Issue 10","labels":[],"body":""}]' > "$FX/issues.json"
  printf '%s\n' "$SHA" > "$FX/head.10"
  rm -f "$FX/rr.log"
  bash "$SCR/pipeline-status-file.sh" collect 2>"$PARENT/err" | python3 -I -c '
import json, sys
print(" ".join("%d=%s" % (p["n"], p["stage"]) for p in json.load(sys.stdin)["prs"]))'
}
set_cfg() {  # <roles members>
  printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main", "roles": {"adversarial": true%s}, "pr": {"draft": false}}\n' \
    "${1:+, $1}" > "$SANDBOX/talos.pipeline.json"
}
APPROVED="qa:pass,docs:done,review:approved"
NOMATCH_LINE="required-roles head=$SHA roles=reviewer skipped=security,adversarial reason=no-match matched=- matched_count=0"
MATCH_LINE="required-roles head=$SHA roles=reviewer,security,adversarial skipped=- reason=matched matched=internal/auth/x.go matched_count=1"

# AC4: no key set. No required-roles call, and every enabled role routes as before.
set_cfg ""
assert_eq "10=security" "$(stage_of "$APPROVED")" "AC4 no key: a PR without security:approved routes to security"
assert_eq "" "$(cat "$FX/rr.log" 2>/dev/null)" "AC4 no key: next makes no required-roles call"
assert_eq "10=merge" "$(stage_of "$APPROVED,security:approved,adversarial:approved")" "AC4 no key: every approval present -> merge"
assert_eq "" "$(cat "$FX/rr.log" 2>/dev/null)" "AC4 no key, all approved: still no required-roles call"
# --required-when no|yes reaches pipeline-next.py: a stand-in for it records its argv.
mv "$SCR/pipeline-next.py" "$SCR/pipeline-next.py.real"
printf 'import sys\nopen(%s, "w").write(" ".join(sys.argv[1:]))\nprint("{}")\n' "'$FX/next.argv'" > "$SCR/pipeline-next.py"
bash "$SCR/pipeline-status-file.sh" collect > /dev/null 2>&1
assert_contains "$(cat "$FX/next.argv")" "--required-when no" "AC4 no key: the status file reports --required-when no"
set_cfg "\"required_when\": {\"security\": [\"internal/auth/**\"]}"
bash "$SCR/pipeline-status-file.sh" collect > /dev/null 2>&1
assert_contains "$(cat "$FX/next.argv")" "--required-when yes" "AC4 key set: the status file reports --required-when yes"
assert_contains "$(cat "$FX/next.argv")" "--roles qa,docs,reviewer,security,adversarial" "AC4 --roles is still every enabled role (qa and docs are never gated)"
mv "$SCR/pipeline-next.py.real" "$SCR/pipeline-next.py"

# AC5: the key set; the PR carries qa:pass, review:approved, docs:done, no security label.
set_cfg "\"required_when\": {\"security\": [\"internal/auth/**\"], \"adversarial\": [\"internal/auth/**\"]}"
printf '%s\n' "$NOMATCH_LINE" > "$FX/rr.out"; echo 0 > "$FX/rr.rc"
assert_eq "10=merge" "$(stage_of "$APPROVED")" "AC5 non-matching diff: security and adversarial are not routed (merge)"
assert_contains "$(cat "$FX/rr.log")" "required-roles 10" "AC5 the verb is asked for the PR"
printf '%s\n' "$MATCH_LINE" > "$FX/rr.out"
assert_eq "10=security" "$(stage_of "$APPROVED")" "AC5 matching diff: the same PR routes to security"
echo 1 > "$FX/rr.rc"
assert_eq "10=security" "$(stage_of "$APPROVED")" "AC5 the verb fails: every enabled role is required (security)"
echo 0 > "$FX/rr.rc"; printf 'not a decision\n' > "$FX/rr.out"
assert_eq "10=security" "$(stage_of "$APPROVED")" "AC5 an unparsable line: every enabled role is required (security)"
printf '%s\n' "$NOMATCH_LINE" > "$FX/rr.out"
assert_eq "10=reviewer" "$(stage_of "qa:pass,docs:done")" "AC5 non-matching diff: a role with no entry (reviewer) is still routed"
assert_eq "" "$(cat "$FX/writes.log" 2>/dev/null)" "AC5 collect made no write"

# ── AC6-AC8: gate merge, over the journaling stubs of test-talos-gate.sh ─────
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="${1:-}"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then { printf "[%s]\n" "$*"; cat "$a"; } >> "$d/bodies"; fi
  prev="$a"
done
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh pipeline-draft-check.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
GATE="$GS/talos.sh"
set_stub() { printf '%s\n' "$2" > "$STUB_DIR/$1.rc"; printf '%s' "${3:-}" > "$STUB_DIR/$1.out"; printf '%s' "${4:-}" > "$STUB_DIR/$1.err"; }
labels_json() { local out="" n; for n in "$@"; do out="${out:+$out,}{\"name\":\"$n\"}"; done; printf '{"labels":[%s]}' "$out"; }
gate_reset() {  # PR without the security and adversarial labels, the key set
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  set_stub view-pr 0 "$(labels_json qa:pass review:approved docs:done pipeline:review)"
  set_stub view-issue 0 "$(labels_json pipeline:review)"
  set_stub pr-head 0 "$SHA"
  set_stub read-comments 0 '{"comments":[]}'
  set_stub draft-check 0 "false"
  printf '{"roles": {"adversarial": true, "required_when": {"security": ["internal/auth/**"], "adversarial": ["internal/auth/**"]}}}' > "$SANDBOX/talos.pipeline.json"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
called() { journal | grep -c "^vcs $1 "; }
gm() { OUT="$(bash "$GATE" gate merge 9 42 2>"$SANDBOX/gate.err")"; RC=$?; }
gline() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n 1; }
DEC_NO="required-roles head=$SHA roles=reviewer skipped=security,adversarial reason=no-match matched=- matched_count=0"
DEC_YES="required-roles head=$SHA roles=reviewer,security,adversarial skipped=- reason=matched matched=internal/auth/x.go matched_count=1"
rec_comment() {  # <head> <required> <skipped> <reason>: a read-comments object holding that record
  printf '{"comments":[{"author":{"login":"talos-bot"},"body":"**Review roles:** x\\n<!-- talos:review-roles head=%s required=%s skipped=%s reason=%s -->"}]}' "$1" "$2" "$3" "$4"
}

# AC6: the decision narrows what the gate waits for.
gate_reset; set_stub required-roles 0 "$DEC_NO"
gm
assert_eq "merge" "$(gline verdict)" "AC6 non-matching diff: the missing security and adversarial labels do not wait"
assert_eq "" "$(gline reason)" "AC6 non-matching diff: no approvals-missing reason"
gate_reset; set_stub required-roles 0 "$DEC_YES"
gm
assert_eq "wait" "$(gline verdict)" "AC6 matching diff: wait"
assert_eq "approvals-missing" "$(gline reason)" "AC6 matching diff: approvals-missing"
assert_eq "security:approved,adversarial:approved" "$(gline missing)" "AC6 matching diff: missing names the security label"
gate_reset; set_stub required-roles 1 "" "boom"
gm
assert_eq "wait" "$(gline verdict)" "AC6 the verb fails: wait, every enabled role is required"
assert_contains "$(gline missing)" "security:approved" "AC6 the verb fails: missing names the security label"
gate_reset; set_stub required-roles 0 "garbage"
gm
assert_contains "$(gline missing)" "security:approved" "AC6 an unparsable answer: missing names the security label"
gate_reset; set_stub required-roles 0 "required-roles head=- roles=reviewer skipped=security,adversarial reason=no-match matched=- matched_count=0"
gm
assert_eq "wait" "$(gline verdict)" "AC6 an unreadable head (head=-): wait, every enabled role is required"
assert_contains "$(gline missing)" "security:approved" "AC6 an unreadable head (head=-): missing names the security label"
# AC4 on the gate: without the key nothing is called or posted.
gate_reset; printf '{"roles": {"adversarial": true}}' > "$SANDBOX/talos.pipeline.json"
gm
assert_eq "wait" "$(gline verdict)" "AC4 gate, no key: the missing labels wait as today"
assert_eq "0" "$(called required-roles)" "AC4 gate, no key: no required-roles call"
assert_eq "0" "$(called comment-pr)" "AC4 gate, no key: no Review roles comment"
assert_eq "0" "$(called read-comments)" "AC4 gate, no key: no comment read"

# AC7: recorded once per head and decision.
gate_reset; set_stub required-roles 0 "$DEC_NO"
gm
assert_eq "1" "$(called comment-pr)" "AC7 one comment is posted"
_b="$(cat "$STUB_DIR/bodies")"
assert_contains "$_b" "**Review roles:**" "AC7 the comment opens with the Review roles header"
assert_contains "$_b" "<!-- talos:review-roles head=$SHA required=reviewer skipped=security,adversarial reason=no-match -->" "AC7 the machine line carries head, required, skipped and reason"
gate_reset; set_stub required-roles 0 "$DEC_YES"
gm
_b="$(cat "$STUB_DIR/bodies")"
assert_contains "$_b" "required=reviewer,security,adversarial skipped=- reason=matched" "AC7 a matching decision is recorded as such"
assert_contains "$_b" "internal/auth/x.go" "AC7 the matched paths are in the comment"
gate_reset; set_stub required-roles 0 "$DEC_NO"; set_stub read-comments 0 "$(rec_comment "$SHA" reviewer security,adversarial no-match)"
gm
assert_eq "0" "$(called comment-pr)" "AC7 the same head and decision again: nothing is posted"
gate_reset; set_stub required-roles 0 "required-roles head=$OTHER roles=reviewer skipped=security,adversarial reason=no-match matched=- matched_count=0"
set_stub read-comments 0 "$(rec_comment "$SHA" reviewer security,adversarial no-match)"
gm
assert_eq "1" "$(called comment-pr)" "AC7 a new head posts a new comment"
gate_reset; set_stub required-roles 0 "$DEC_NO"; set_stub read-comments 0 "$(rec_comment "$SHA" reviewer,security,adversarial - matched)"
gm
assert_eq "1" "$(called comment-pr)" "AC7 a changed decision at the same head posts a new comment"
assert_contains "$(cat "$STUB_DIR/bodies")" "reason=no-match -->" "AC7 the new comment carries the new decision"

# AC8: the recorded decision skips a role the gate's own recomputation requires.
gate_reset; set_stub required-roles 0 "$DEC_YES"
set_stub view-pr 0 "$(labels_json qa:pass review:approved docs:done security:approved adversarial:approved pipeline:review)"
set_stub read-comments 0 "$(rec_comment "$SHA" reviewer security,adversarial no-match)"
gm
assert_eq "block" "$(gline verdict)" "AC8 a record that skips a required role: block"
assert_eq "roles-decision-mismatch" "$(gline reason)" "AC8 reason=roles-decision-mismatch"
assert_contains "$(journal)" "vcs label-pr 9 --add pipeline:blocked" "AC8 the PR gets pipeline:blocked"
assert_eq "0" "$(called merge-pr)" "AC8 no merge"
set_stub read-comments 0 "$(rec_comment "$OTHER" reviewer security,adversarial no-match)"
rm -f "$STUB_DIR/journal"
gm
assert_eq "merge" "$(gline verdict)" "AC8 a record of another head is not the current decision: no refusal"
set_stub read-comments 0 "$(rec_comment "$SHA" reviewer,security,adversarial - matched)"
gm
assert_eq "merge" "$(gline verdict)" "AC8 a record that agrees with the recomputation: no refusal"

# ── AC9: check-approval-sha is unchanged by the key ─────────────────────────
STALE_C="[{\"body\":\"ok\\n<!-- talos:approval sha=$OTHER role=security -->\"},{\"body\":\"ok\\n<!-- talos:approval sha=$SHA role=reviewer -->\"}]"
cas() {  # <flag> : stdout, stderr and exit of check-approval-sha with the current config
  OUT="$(PIPELINE_CONFIG="$CAS_CFG" STUB_PR_HEAD_SHA="$SHA" STUB_PR_LABELS_JSON='[{"name":"security:approved"},{"name":"review:approved"}]' \
    STUB_PR_COMMENTS_JSON="$STALE_C" bash "$VCS" check-approval-sha 9 $1 2>"$SANDBOX/cas.err")"; RC=$?
  printf '%s|%s|%s' "$RC" "$OUT" "$(cat "$SANDBOX/cas.err")"
}
unset GH_QUEUE GH_LINK_QUEUE GH_REST_LOG
CAS_CFG="$SANDBOX/cas-cfg.json"
printf '{"roles": {"adversarial": true}}\n' > "$CAS_CFG"
_off_s="$(cas --stale-list)"; _off_e="$(cas --evidence-list)"
printf '{"roles": {"adversarial": true, "required_when": {"security": ["internal/auth/**"]}}}\n' > "$CAS_CFG"
_on_s="$(cas --stale-list)"; _on_e="$(cas --evidence-list)"
assert_eq "$_off_s" "$_on_s" "AC9 --stale-list prints the same with the key set"
assert_eq "$_off_e" "$_on_e" "AC9 --evidence-list prints the same with the key set"
assert_contains "$_on_s" "stale role=security label=security:approved" "AC9 an approval of a skipped role is still checked against the head SHA"

# ── AC10: the defaults row and the docs ─────────────────────────────────────
assert_contains "$(cat "$TALOS_ROOT/scripts/pipeline-defaults.sh")" "$(printf 'roles.required_when.*\tlist\t\t-\t-\trepo')" "AC10 the defaults table has the repo-only row"
assert_contains "$(cat "$TALOS_ROOT/docs/reference.md")" '| `roles.required_when.*` | list | - | - | repo |' "AC10 the docs config table row is generated from the defaults row"
_docs="$(cat "$TALOS_ROOT/docs/reference.md")"
for _w in "roles.required_when.<role>" "talos:review-roles" "roles-decision-mismatch" "required-roles"; do
  assert_contains "$_docs" "$_w" "AC10 docs/reference.md names $_w"
done

finish
