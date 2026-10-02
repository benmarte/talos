#!/usr/bin/env bash
# test-needs-owner.sh -- the pipeline:needs-owner label and the
# mark-needs-owner / list-needs-owner verbs (#345, epic #333). Offline: the gh
# and curl stubs only; the real repository is never called.
#
# What is posted: `<text>`, a blank line, then `<!-- talos:needs-owner -->` (no
# header; templates/comments/needs-owner.md is the model for an agent that wraps
# text, and ends the same way). `question=` is the first non-blank line of the
# newest trusted marker comment after skipping a leading **Agent:** line and the
# marker line -- never `**Needs owner**`-style header text from the verb itself.
#
# The stock gh stub serves one comments fixture for every issue number, so this
# file puts a small wrapper in front of it (comments per number, and a switch
# per failing call). Everything else still reaches the stock stub and its log.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export STUBS_DIR
export NO_FIX="$SANDBOX/fixtures"
mkdir -p "$NO_FIX" "$SANDBOX/bin"

cat > "$SANDBOX/bin/gh" <<'TALOS_WRAPPER_h7Qk2LmP9xRt'
#!/usr/bin/env bash
# Per-number comments and per-call failures in front of the stock gh stub.
case "$*" in
  "api --paginate repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
    _n="${3#repos/*/issues/}"; _n="${_n%%/*}"
    if [ -e "$NO_FIX/fail-comments-$_n" ]; then echo "gh: HTTP 502: Bad Gateway" >&2; exit 1; fi
    if [ -f "$NO_FIX/comments-$_n.json" ]; then cat "$NO_FIX/comments-$_n.json"; else printf '[]'; fi
    exit 0 ;;
  "api --method POST repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
    if [ -e "$NO_FIX/fail-post-comment" ]; then echo "gh: HTTP 403: Forbidden" >&2; exit 1; fi
    exit 0 ;;
  "api --method DELETE repos/"*"/issues/"*"/labels/"*)
    printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
    _n="${4#repos/*/issues/}"; _n="${_n%%/*}"
    if [ -e "$NO_FIX/fail-delete-$_n" ]; then echo "gh: HTTP 404: Not Found" >&2; exit 1; fi
    exit 0 ;;
esac
exec "$STUBS_DIR/gh" "$@"
TALOS_WRAPPER_h7Qk2LmP9xRt
chmod +x "$SANDBOX/bin/gh"
export PATH="$SANDBOX/bin:$PATH"

set_cfg() { printf '%s\n' "$1" > talos.pipeline.json; }
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}}'
export STUB_CURRENT_USER="owner"
export TALOS_RETRY_SLEEP_SCALE=0

# mkc <n> 'login|body' ... -> comments-<n>.json in the REST shape read-comments
# reads. A literal \n in a body becomes a newline.
mkc() {
  local n="$1"; shift
  python3 - "$n" "$@" > "$NO_FIX/comments-$n.json" <<'TALOS_PY_c3Vd8WqZ1nYb'
import json, sys
out = []
for i, a in enumerate(sys.argv[2:]):
    login, body = a.split("|", 1)
    out.append({"id": i + 1, "user": {"login": login},
                "created_at": "2026-01-01T00:00:%02dZ" % i,
                "body": body.replace("\\n", "\n")})
print(json.dumps(out))
TALOS_PY_c3Vd8WqZ1nYb
}

reset() { : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_QUEUE"; rm -f "$NO_FIX"/*; unset STUB_GH_ISSUES_RAW STUB_GH_API_FAIL; }

# run <verb args...>: OUT, ERR, RC. stdin is closed off the terminal so a verb
# that wrongly read it would see EOF, not hang.
run() {
  OUT="$(bash "$VCS" "$@" </dev/null 2>"$SANDBOX/err")"; RC=$?
  ERR="$(cat "$SANDBOX/err")"
}

MARK='<!-- talos:needs-owner -->'
LABEL='pipeline:needs-owner'
NL=$'\n'

# ═══════════════════════════════════════════════════════════════════════════
# Contract, bootstrap, template, header
# ═══════════════════════════════════════════════════════════════════════════
. "$TALOS_ROOT/scripts/pipeline-contract.sh"
_entry=""
for e in "${TALOS_STAGE_LABELS[@]}"; do
  case "$e" in "$LABEL|"*) _entry="$e" ;; esac
done
assert_contains "$_entry" "$LABEL|" "contract: TALOS_STAGE_LABELS has the pipeline:needs-owner entry"
_desc="${_entry#*|}"; _desc="${_desc#*|}"
[ -n "$_desc" ] && [ "${#_desc}" -le 100 ] && pass "contract: description is 1..100 characters (${#_desc})" \
  || fail "contract: description is 1..100 characters" "length ${#_desc}"
_m=""; for e in "${TALOS_MARKERS[@]}"; do [ "$e" = "talos:needs-owner" ] && _m=1; done
assert_eq "1" "$_m" "contract: TALOS_MARKERS has talos:needs-owner"

reset
bash "$TALOS_ROOT/scripts/bootstrap-labels.sh" acme/widget >/dev/null 2>&1; RC=$?
assert_eq "0" "$RC" "bootstrap-labels.sh exits 0"
assert_contains "$(cat "$GH_LOG")" "label create $LABEL " "bootstrap-labels.sh creates pipeline:needs-owner"

TMPL="$(cat "$TALOS_ROOT/templates/comments/needs-owner.md")"
assert_contains "$TMPL" '${HEADER}' "template: renders HEADER"
assert_contains "$TMPL" '${SUMMARY}' "template: renders SUMMARY"
assert_contains "$TMPL" '${DETAILS}' "template: renders DETAILS"
assert_eq "$MARK" "$(printf '%s' "$TMPL" | tail -1)" "template: last line is the marker"

HDR="$(sed -n '1,/^set -/p' "$VCS")"
assert_contains "$HDR" "mark-needs-owner <n> <text>" "usage header documents mark-needs-owner"
assert_contains "$HDR" "list-needs-owner [--json] [--clear-answered]" "usage header documents list-needs-owner"
assert_contains "$HDR" "ALWAYS THE LAST field" "usage header says question= is always the last field"
assert_contains "$HDR" "gitlab, azure and file exit 2" "usage header documents exit 2 for other providers"

# ═══════════════════════════════════════════════════════════════════════════
# mark-needs-owner (github)
# ═══════════════════════════════════════════════════════════════════════════
reset
run mark-needs-owner 7 "Which option do we ship?"
assert_eq "0" "$RC" "mark: exits 0"
assert_eq "marked n=7 comment=posted" "$OUT" "mark: reports the comment was posted"
LOG="$(cat "$GH_LOG")"
assert_contains "$LOG" "api --method POST repos/acme/widget/issues/7/comments -f body=Which option do we ship?${NL}${NL}${MARK}" \
  "mark: posts the text, a blank line, then the marker as the last line"
assert_eq "1" "$(grep -c -- '--method POST repos/acme/widget/issues/7/comments' "$GH_LOG")" "mark: exactly one comment POST"
assert_eq "1" "$(printf '%s' "$LOG" | grep -c -F -- "$MARK")" "mark: the marker appears once"
assert_contains "$LOG" "api --method POST repos/acme/widget/issues/7/labels -f labels[]=$LABEL" "mark: adds the label"
_c="$(grep -n -- '--method POST repos/acme/widget/issues/7/comments' "$GH_LOG" | head -1 | cut -d: -f1)"
_l="$(grep -n -- '--method POST repos/acme/widget/issues/7/labels' "$GH_LOG" | head -1 | cut -d: -f1)"
[ -n "$_c" ] && [ -n "$_l" ] && [ "$_c" -lt "$_l" ] && pass "mark: the comment is posted before the label is added" \
  || fail "mark: the comment is posted before the label is added" "comment line '$_c', label line '$_l'"

# A PR number goes through the same issues route (it serves issues and PRs).
reset
run mark-needs-owner 12 "Merge now or wait?"
assert_eq "0" "$RC" "mark: a PR number exits 0"
assert_contains "$(cat "$GH_LOG")" "issues/12/labels -f labels[]=$LABEL" "mark: a PR number is labelled through the issues route"

# --body-file <path>
reset
printf 'From a file\nsecond line\n' > "$SANDBOX/q.txt"
run mark-needs-owner 7 --body-file "$SANDBOX/q.txt"
assert_eq "0" "$RC" "mark: --body-file <path> exits 0"
assert_contains "$(cat "$GH_LOG")" "-f body=From a file${NL}second line${NL}${NL}${MARK}" "mark: --body-file <path> posts the file text plus the marker"

# --body-file - (stdin, heredoc)
reset
OUT="$(bash "$VCS" mark-needs-owner 7 --body-file - 2>"$SANDBOX/err" <<'TALOS_TXT_p4Nw8ZxK2mQe'
Question from stdin with $(touch pwned) and `touch pwned2`
TALOS_TXT_p4Nw8ZxK2mQe
)"; RC=$?
assert_eq "0" "$RC" "mark: --body-file - exits 0"
assert_contains "$(cat "$GH_LOG")" 'body=Question from stdin with $(touch pwned) and `touch pwned2`' "mark: --body-file - posts the stdin text byte for byte"
assert_file_absent "$SANDBOX/pwned" "mark: stdin text is never executed"
assert_file_absent "pwned2" "mark: stdin text with backticks is never executed"

# A text that already ends in the marker (rendered template) is not marked twice.
reset
run mark-needs-owner 7 "Pick one${NL}${NL}${MARK}"
assert_eq "1" "$(cat "$GH_LOG" | grep -c -F -- "$MARK")" "mark: a text already ending in the marker is not marked twice"

# Closed stdin -> exit 1, nothing called
reset
bash "$VCS" mark-needs-owner 7 --body-file - <&- >/dev/null 2>"$SANDBOX/err"; RC=$?
assert_eq "1" "$RC" "mark: --body-file - with a closed stdin exits 1"
assert_eq "" "$(cat "$GH_LOG")" "mark: closed stdin makes no gh call"

# Refusals before any call
refuse() {  # label, then verb args
  local label="$1"; shift
  reset
  run mark-needs-owner "$@"
  assert_eq "1" "$RC" "mark: $label exits 1"
  assert_eq "" "$(cat "$GH_LOG")" "mark: $label makes no gh call"
}
refuse "non-numeric <n>" 7x "text"
refuse "empty text" 7 ""
refuse "blank text" 7 "   "
refuse "flag-like text" 7 "--body-file"
refuse "extra arguments" 7 "a" "b"
refuse "missing text" 7
refuse "unreadable --body-file" 7 --body-file "$SANDBOX/does-not-exist"
head -c 65537 /dev/zero | tr '\0' a > "$SANDBOX/long.txt"
refuse "a text over 65536 characters (file)" 7 --body-file "$SANDBOX/long.txt"
refuse "a text over 65536 characters (positional)" 7 "$(cat "$SANDBOX/long.txt")"
python3 -c "import sys; sys.stdout.write(chr(0x1F600) * 32000)" > "$SANDBOX/bytes.txt"
refuse "a text over 120000 bytes (file)" 7 --body-file "$SANDBOX/bytes.txt"
head -c 300000 /dev/zero | tr '\0' a > "$SANDBOX/huge.txt"
refuse "a file over 4x65536 bytes" 7 --body-file "$SANDBOX/huge.txt"
reset
bash "$VCS" mark-needs-owner 7 --body-file - < "$SANDBOX/long.txt" >/dev/null 2>&1; RC=$?
assert_eq "1" "$RC" "mark: a stdin text over 65536 characters exits 1"
assert_eq "" "$(cat "$GH_LOG")" "mark: an oversize stdin text makes no gh call"
reset
bash "$VCS" mark-needs-owner 7 --body-file - < "$SANDBOX/bytes.txt" >/dev/null 2>&1; RC=$?
assert_eq "1" "$RC" "mark: a stdin text over 120000 bytes exits 1"
assert_eq "" "$(cat "$GH_LOG")" "mark: an oversize-bytes stdin text makes no gh call"

# Comment POST fails -> exit 1 and no label call
reset
: > "$NO_FIX/fail-post-comment"
run mark-needs-owner 7 "Will this post?"
assert_eq "1" "$RC" "mark: a failed comment POST exits 1"
assert_not_contains "$(cat "$GH_LOG")" "/labels" "mark: a failed comment POST makes no label call"

# Reading the existing comments fails -> exit 1, nothing posted
reset
: > "$NO_FIX/fail-comments-7"
run mark-needs-owner 7 "Will this post?"
assert_eq "1" "$RC" "mark: a failed comment read exits 1"
assert_not_contains "$(cat "$GH_LOG")" "--method POST" "mark: a failed comment read posts nothing"

# ── idempotency ──────────────────────────────────────────────────────────
reset
mkc 7 "owner|Which option do we ship?\n\n$MARK"
run mark-needs-owner 7 "Which option do we ship?"
assert_eq "0" "$RC" "idempotent: same text, unanswered, exits 0"
assert_eq "marked n=7 comment=existing" "$OUT" "idempotent: reports the existing comment"
assert_eq "0" "$(grep -c -- '--method POST repos/acme/widget/issues/7/comments' "$GH_LOG")" "idempotent: no second comment"
assert_contains "$(cat "$GH_LOG")" "issues/7/labels -f labels[]=$LABEL" "idempotent: the label is still ensured"

# marker line and trailing whitespace are ignored; so are CRLF line endings
reset
mkc 7 "owner|Which option do we ship?   \r\n\r\n$MARK\n\n"
python3 - "$NO_FIX/comments-7.json" <<'TALOS_PY_x9Kt4HwQ7bLa'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d[0]["body"] = d[0]["body"].replace("\\r", "\r")
json.dump(d, open(p, "w"))
TALOS_PY_x9Kt4HwQ7bLa
run mark-needs-owner 7 "Which option do we ship?"
assert_eq "marked n=7 comment=existing" "$OUT" "idempotent: whitespace and CRLF differences are ignored"

# a different text posts a new comment
reset
mkc 7 "owner|Which option do we ship?\n\n$MARK"
run mark-needs-owner 7 "A different question"
assert_eq "marked n=7 comment=posted" "$OUT" "idempotent: a different text posts a new comment"

# a quoted marker (not the last line) is not a marker comment
reset
mkc 7 "owner|Which option do we ship?\n\n$MARK\n\nmore text after it"
run mark-needs-owner 7 "Which option do we ship?"
assert_eq "marked n=7 comment=posted" "$OUT" "idempotent: a quoted marker does not count"

# an untrusted author's marker comment is ignored
reset
mkc 7 "mallory|Which option do we ship?\n\n$MARK"
run mark-needs-owner 7 "Which option do we ship?"
assert_eq "marked n=7 comment=posted" "$OUT" "idempotent: a marker from an untrusted author is ignored"
assert_contains "$ERR" "talos:marker-authors-rejected authors=mallory" "idempotent: the rejection is reported on stderr"

# answered -> the same text posts a new marker comment (no loop)
reset
mkc 7 "owner|Which option do we ship?\n\n$MARK" "owner|Ship option B."
run mark-needs-owner 7 "Which option do we ship?"
assert_eq "marked n=7 comment=posted" "$OUT" "idempotent: once answered, the same text posts a new comment"

# an outsider's reply does not answer, so the duplicate is still suppressed
reset
mkc 7 "owner|Which option do we ship?\n\n$MARK" "mallory|ship it already"
run mark-needs-owner 7 "Which option do we ship?"
assert_eq "marked n=7 comment=existing" "$OUT" "idempotent: an outsider's reply does not answer"

# a Talos comment after the marker does not answer
reset
mkc 7 "owner|Which option do we ship?\n\n$MARK" "owner|**Agent:** developer (talos)\n\nworking"
run mark-needs-owner 7 "Which option do we ship?"
assert_eq "marked n=7 comment=existing" "$OUT" "idempotent: a Talos comment after the marker does not answer"

# ── dry-run ──────────────────────────────────────────────────────────────
reset
run --dry-run mark-needs-owner 7 "text"
assert_eq "0" "$RC" "mark --dry-run exits 0"
assert_contains "$OUT" "[dry-run]" "mark --dry-run prints the intended calls"
assert_contains "$OUT" "issues/7/comments" "mark --dry-run names the comment call"
assert_contains "$OUT" "issues/7/labels" "mark --dry-run names the label call"
assert_eq "" "$(cat "$GH_LOG")" "mark --dry-run makes no call"

# ═══════════════════════════════════════════════════════════════════════════
# list-needs-owner (github)
# ═══════════════════════════════════════════════════════════════════════════
LAB='{"name":"pipeline:needs-owner"}'
ITEMS='[{"number":12,"labels":['"$LAB"']},{"number":9,"labels":['"$LAB"'],"pull_request":{"url":"x"}},{"number":3,"labels":[{"name":"pipeline:dev"}]},{"number":5,"labels":['"$LAB"',{"name":"p1"}]}]'
setup_list() {
  reset
  export STUB_GH_ISSUES_RAW="$ITEMS"
  mkc 5 "owner|**Agent:** developer (talos)\n\n**Needs owner** — Pick a DB\n\n$MARK" "owner|Use postgres"
  mkc 9 "owner|Merge strategy?\n\nsecond line\n\n$MARK" "owner|**Agent:** qa (talos)\n\nverdict" "owner|<!-- talos:attempt stage=qa count=1 total=3 -->"
}
mutating() { grep -c -E -- '--method (POST|DELETE|PUT|PATCH)|--add-label|--remove-label| edit ' "$GH_LOG"; }

setup_list
run list-needs-owner
assert_eq "0" "$RC" "list: exits 0"
EXPECT="needs-owner n=5 kind=issue answered=yes question=**Needs owner** — Pick a DB${NL}needs-owner n=9 kind=pr answered=no question=Merge strategy?${NL}needs-owner n=12 kind=issue answered=no question=(no marker comment)"
assert_eq "$EXPECT" "$OUT" "list: one line per labelled item, numeric order, kind and answered resolved"
assert_eq "0" "$(mutating)" "list: without --clear-answered no label-mutating call is made"
assert_contains "$(cat "$GH_LOG")" "issues?state=open&labels=pipeline%3Aneeds-owner" "list: asks for open items carrying the label"

# the empty-list test can fail: the labelled fixture above prints lines, the
# unlabelled one prints nothing
reset
export STUB_GH_ISSUES_RAW='[{"number":3,"labels":[{"name":"pipeline:dev"}]}]'
run list-needs-owner
assert_eq "0" "$RC" "list: no labelled item exits 0"
assert_eq "" "$OUT" "list: no labelled item prints nothing"
setup_list
export STUB_GH_ISSUES_RAW='[{"number":5,"labels":['"$LAB"']}]'
run list-needs-owner
assert_contains "$OUT" "n=5 kind=issue" "list: positive control, a labelled item is printed (the empty-list assertion can fail)"

# --json
setup_list
run list-needs-owner --json
assert_eq "0" "$RC" "list --json: exits 0"
JSON_CHECK="$(printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ok = isinstance(d, list) and len(d) == 3 and all(sorted(x) == ["answered", "kind", "n", "question"] for x in d)
ok = ok and [(x["n"], x["kind"], x["answered"]) for x in d] == [(5, "issue", "yes"), (9, "pr", "no"), (12, "issue", "no")]
ok = ok and d[1]["question"] == "Merge strategy?" and d[2]["question"] == "(no marker comment)"
ok = ok and isinstance(d[0]["n"], int) and d[0]["question"].startswith("**Needs owner**")
print("ok" if ok else "bad: " + json.dumps(d))
')"
assert_eq "ok" "$JSON_CHECK" "list --json: one array of {n, kind, answered, question}"
reset
export STUB_GH_ISSUES_RAW='[]'
run list-needs-owner --json
assert_eq "[]" "$OUT" "list --json: no labelled item is an empty array"

# --clear-answered
setup_list
run list-needs-owner --clear-answered
assert_eq "0" "$RC" "clear: exits 0"
assert_contains "$OUT" "cleared n=5" "clear: prints cleared n=5"
assert_not_contains "$OUT" "cleared n=9" "clear: leaves an unanswered item alone (9)"
assert_not_contains "$OUT" "cleared n=12" "clear: leaves an item with no marker comment alone (12)"
assert_contains "$OUT" "needs-owner n=5 kind=issue answered=yes" "clear: the listing is still printed"
assert_eq "1" "$(mutating)" "clear: exactly one label-mutating call"
assert_contains "$(cat "$GH_LOG")" "api --method DELETE repos/acme/widget/issues/5/labels/pipeline%3Aneeds-owner" "clear: removes the label from the answered item"

# a PR is cleared through the same route
setup_list
mkc 9 "owner|Merge strategy?\n\n$MARK" "owner|squash"
run list-needs-owner --clear-answered
assert_contains "$OUT" "cleared n=9" "clear: an answered PR is cleared"
assert_contains "$(cat "$GH_LOG")" "issues/9/labels/pipeline%3Aneeds-owner" "clear: a PR is cleared through the issues route"

# --json keeps stdout one JSON array
run list-needs-owner --json --clear-answered
JSON_OK="$(printf '%s' "$OUT" | python3 -c 'import json, sys; json.load(sys.stdin); print("ok")' 2>/dev/null)"
assert_eq "ok" "$JSON_OK" "clear --json: stdout stays one JSON array"
assert_contains "$ERR" "cleared n=5" "clear --json: the cleared lines go to stderr"

# a failed removal: exit 1, cleared only for the removals that succeeded
setup_list
mkc 9 "owner|Merge strategy?\n\n$MARK" "owner|squash"
: > "$NO_FIX/fail-delete-5"
run list-needs-owner --clear-answered
assert_eq "1" "$RC" "clear: a failed removal exits 1"
assert_not_contains "$OUT" "cleared n=5" "clear: no cleared line for the failed removal"
assert_contains "$OUT" "cleared n=9" "clear: the other removal still happens and is reported"

# --dry-run
setup_list
run --dry-run list-needs-owner --clear-answered
assert_eq "0" "$RC" "list --dry-run exits 0"
assert_contains "$OUT" "[dry-run]" "list --dry-run prints the intended calls"
assert_contains "$OUT" "DELETE" "list --dry-run --clear-answered prints the intended removals"
assert_eq "" "$(cat "$GH_LOG")" "list --dry-run makes no call"

# unknown argument
setup_list
run list-needs-owner --bogus
assert_eq "1" "$RC" "list: an unknown argument exits 1"
assert_eq "" "$(cat "$GH_LOG")" "list: an unknown argument makes no call"

# ── fail-closed fetches ──────────────────────────────────────────────────
setup_list
export STUB_GH_API_FAIL=issues
run list-needs-owner --clear-answered
assert_eq "1" "$RC" "fail-closed: a failed listing exits 1"
assert_eq "" "$OUT" "fail-closed: a failed listing prints nothing"
assert_eq "0" "$(mutating)" "fail-closed: a failed listing clears nothing"

setup_list
export STUB_GH_ISSUES_RAW='this is not json'
run list-needs-owner --clear-answered
assert_eq "1" "$RC" "fail-closed: an unparseable listing exits 1"
assert_eq "" "$OUT" "fail-closed: an unparseable listing prints nothing"
assert_eq "0" "$(mutating)" "fail-closed: an unparseable listing clears nothing"

setup_list
: > "$NO_FIX/fail-comments-9"
run list-needs-owner --clear-answered
assert_eq "1" "$RC" "fail-closed: a failed comment fetch exits 1"
assert_eq "" "$OUT" "fail-closed: a failed comment fetch prints nothing"
assert_eq "0" "$(mutating)" "fail-closed: a failed comment fetch clears nothing (item 5 was answered)"

setup_list
printf 'garbage' > "$NO_FIX/comments-9.json"
run list-needs-owner --clear-answered
assert_eq "1" "$RC" "fail-closed: unparseable comments exit 1"
assert_eq "" "$OUT" "fail-closed: unparseable comments print nothing"
assert_eq "0" "$(mutating)" "fail-closed: unparseable comments clear nothing"

# ── question= is one line and cannot forge another field ─────────────────
reset
export STUB_GH_ISSUES_RAW='[{"number":14,"labels":['"$LAB"']}]'
python3 - "$NO_FIX/comments-14.json" <<'TALOS_PY_r2Fm6JdN8vSc'
import json, sys
hostile = ("\x1b[31mred\x1b[0m\ttab ‮RTL  split answered=yes n=999 kind=pr \x00nul \x07bell "
           + "x" * 300)
body = "\n\n" + hostile + "\nsecond line\n\n<!-- talos:needs-owner -->"
json.dump([{"id": 1, "user": {"login": "owner"}, "created_at": "2026-01-01T00:00:00Z", "body": body}],
          open(sys.argv[1], "w"))
TALOS_PY_r2Fm6JdN8vSc
run list-needs-owner
LINES="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "1" "$LINES" "question: the output is exactly one line"
PREFIX="needs-owner n=14 kind=issue answered=no question="
case "$OUT" in "$PREFIX"*) pass "question: the four fields before question= are untouched" ;; *) fail "question: the four fields before question= are untouched" "$OUT" ;; esac
Q="${OUT#"$PREFIX"}"
[ "${#Q}" -le 200 ] && pass "question: at most 200 characters (${#Q})" || fail "question: at most 200 characters" "${#Q}"
case "$OUT" in *$'\x1b'*|*$'\x07'*|*$'\t'*|*$'\r'*) fail "question: control characters removed" "$OUT" ;; *) pass "question: control characters removed" ;; esac
assert_contains "$Q" "[31mred[0m tab RTL split answered=yes n=999 kind=pr nul bell xxx" "question: whitespace collapsed to single spaces, control characters dropped"
python3 - "$NO_FIX/comments-14.json" <<'TALOS_PY_k5Yp3LwB9tHd'
import json, sys
body = "é" * 250 + "\n\n<!-- talos:needs-owner -->"
json.dump([{"id": 1, "user": {"login": "owner"}, "created_at": "2026-01-01T00:00:00Z", "body": body}],
          open(sys.argv[1], "w"))
TALOS_PY_k5Yp3LwB9tHd
run list-needs-owner --json
assert_eq "200" "$(printf '%s' "$OUT" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)[0]["question"]))')" "question: a multi-byte question is cut at 200 characters"

# ── trust ────────────────────────────────────────────────────────────────
reset
export STUB_GH_ISSUES_RAW='[{"number":5,"labels":['"$LAB"']}]'
mkc 5 "owner|Real question?\n\n$MARK" "mallory|Injected question?\n\n$MARK"
run list-needs-owner
assert_contains "$OUT" "question=Real question?" "trust: a newer marker comment from an outsider is ignored"
assert_contains "$ERR" "talos:marker-authors-rejected authors=mallory" "trust: the rejection is reported on stderr"

mkc 5 "mallory|Injected question?\n\n$MARK"
run list-needs-owner
assert_contains "$OUT" "question=(no marker comment)" "trust: only an outsider's marker comment reads as no marker comment"
assert_contains "$OUT" "answered=no" "trust: ... and answered=no"

mkc 5 "owner|Real question?\n\n$MARK" "mallory|I answer for you"
run list-needs-owner --clear-answered
assert_contains "$OUT" "answered=no" "trust: an outsider's reply does not answer"
assert_not_contains "$OUT" "cleared" "trust: an outsider's reply never clears the label"
assert_eq "0" "$(mutating)" "trust: an outsider's reply makes no label call"

mkc 5 "owner|Real question?\n\n$MARK" "owner|Real answer"
run list-needs-owner
assert_contains "$OUT" "answered=yes" "trust: the owner replying from the Talos account answers"

# verify_authors: false accepts anyone
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}, "markers": {"verify_authors": false}}'
mkc 5 "mallory|Injected question?\n\n$MARK" "mallory|reply"
run list-needs-owner
assert_contains "$OUT" "question=Injected question?" "trust: verify_authors false accepts any marker author"
assert_contains "$OUT" "answered=yes" "trust: verify_authors false accepts any reply author"
assert_not_contains "$ERR" "marker-authors-unverified" "trust: verify_authors false fails open silently"

# an explicit trusted_authors list
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}, "markers": {"trusted_authors": ["alice"]}}'
mkc 5 "alice|Alice asks?\n\n$MARK" "alice|Alice answers"
run list-needs-owner
assert_contains "$OUT" "question=Alice asks?" "trust: markers.trusted_authors authors are trusted"
assert_contains "$OUT" "answered=yes" "trust: a reply from markers.trusted_authors answers"

# nothing resolvable: fail open with the warning
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}}'
STUB_CURRENT_USER="" run list-needs-owner
assert_contains "$ERR" "talos:marker-authors-unverified" "trust: no trust set resolvable fails open with the unverified warning"
assert_contains "$OUT" "question=Alice asks?" "trust: ... and the marker comment is accepted"

# ═══════════════════════════════════════════════════════════════════════════
# other providers exit 2
# ═══════════════════════════════════════════════════════════════════════════
for p in gitlab azure file; do
  set_cfg '{"vcs": {"provider": "'"$p"'"}}'
  reset
  run mark-needs-owner 7 "text"
  assert_eq "2" "$RC" "$p: mark-needs-owner exits 2"
  assert_contains "$ERR" "not implemented for provider '$p'" "$p: mark-needs-owner says not implemented for provider '$p'"
  assert_eq "" "$OUT" "$p: mark-needs-owner prints nothing on stdout"
  run list-needs-owner
  assert_eq "2" "$RC" "$p: list-needs-owner exits 2"
  assert_contains "$ERR" "not implemented for provider '$p'" "$p: list-needs-owner says not implemented for provider '$p'"
  run --dry-run list-needs-owner
  assert_eq "2" "$RC" "$p: list-needs-owner --dry-run exits 2"
done
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}}'

# ═══════════════════════════════════════════════════════════════════════════
# github-api: the same verbs through the curl stub
# ═══════════════════════════════════════════════════════════════════════════
export GITHUB_TOKEN="test-token-needs-owner"
set_cfg '{"vcs": {"provider": "github-api", "repo": "acme/widget"}}'

reset
printf '%s\n' '[]' '{"html_url":"https://github.com/acme/widget/issues/7#issuecomment-1"}' '[{"name":"pipeline:needs-owner"}]' > "$CURL_QUEUE"
run mark-needs-owner 7 "Ship it?"
assert_eq "0" "$RC" "github-api mark: exits 0"
assert_eq "marked n=7 comment=posted" "$OUT" "github-api mark: reports the comment was posted"
CL="$(cat "$CURL_LOG")"
assert_contains "$CL" "https://api.github.com/repos/acme/widget/issues/7/comments	{\"body\": \"Ship it?\\n\\n$MARK\"}" "github-api mark: posts the text and the marker"
assert_contains "$CL" "issues/7/labels	{\"labels\":[\"$LABEL\"]}" "github-api mark: adds the label"
_c="$(grep -n 'issues/7/comments	{' "$CURL_LOG" | head -1 | cut -d: -f1)"
_l="$(grep -n 'issues/7/labels	' "$CURL_LOG" | head -1 | cut -d: -f1)"
[ -n "$_c" ] && [ -n "$_l" ] && [ "$_c" -lt "$_l" ] && pass "github-api mark: the comment comes before the label" \
  || fail "github-api mark: the comment comes before the label" "comment '$_c', label '$_l'"
assert_not_contains "$CL" "$GITHUB_TOKEN" "github-api mark: the token is not logged"

# comment POST fails -> exit 1, no label call
reset
printf '%s\n' '[]' '500' > "$CURL_QUEUE"
run mark-needs-owner 7 "Ship it?"
assert_eq "1" "$RC" "github-api mark: a failed comment POST exits 1"
assert_not_contains "$(cat "$CURL_LOG")" "/labels" "github-api mark: a failed comment POST makes no label call"

# idempotent
reset
python3 - > "$SANDBOX/c7.json" <<'TALOS_PY_n8Vq2ZtX5mJr'
import json
print(json.dumps([{"id": 1, "user": {"login": "owner"}, "created_at": "2026-01-01T00:00:00Z",
                   "body": "Ship it?\n\n<!-- talos:needs-owner -->"}]))
TALOS_PY_n8Vq2ZtX5mJr
{ cat "$SANDBOX/c7.json"; printf '%s\n' '[{"name":"pipeline:needs-owner"}]'; } > "$CURL_QUEUE"
run mark-needs-owner 7 "Ship it?"
assert_eq "marked n=7 comment=existing" "$OUT" "github-api mark: idempotent while unanswered"
assert_not_contains "$(cat "$CURL_LOG")" "issues/7/comments	{" "github-api mark: no second comment"

# list + clear
reset
python3 - > "$CURL_QUEUE" <<'TALOS_PY_w4Bd7KsH3nPe'
import json
lab = [{"name": "pipeline:needs-owner"}]
items = [{"number": 9, "labels": lab, "pull_request": {}}, {"number": 3, "labels": []}, {"number": 5, "labels": lab}]
def c(login, body):
    return {"id": 1, "user": {"login": login}, "created_at": "2026-01-01T00:00:00Z", "body": body}
m = "\n\n<!-- talos:needs-owner -->"
print(json.dumps(items))
print(json.dumps([c("owner", "Which DB?" + m), c("owner", "postgres")]))   # 5, answered
print(json.dumps([c("owner", "Merge how?" + m)]))                          # 9, unanswered
print("[]")                                                                # the DELETE reply
TALOS_PY_w4Bd7KsH3nPe
run list-needs-owner --clear-answered
assert_eq "0" "$RC" "github-api list: exits 0"
assert_eq "needs-owner n=5 kind=issue answered=yes question=Which DB?${NL}needs-owner n=9 kind=pr answered=no question=Merge how?${NL}cleared n=5" "$OUT" \
  "github-api list: lists in numeric order, resolves kind and answered, clears the answered item"
assert_contains "$(cat "$CURL_LOG")" "issues/5/labels/pipeline%3Aneeds-owner" "github-api clear: removes the label from the answered item"
assert_not_contains "$(cat "$CURL_LOG")" "issues/9/labels" "github-api clear: leaves the unanswered item alone"

# a failed listing is fail-closed
reset
printf '%s\n' '503' > "$CURL_QUEUE"
run list-needs-owner --clear-answered
assert_eq "1" "$RC" "github-api list: a failed listing exits 1"
assert_eq "" "$OUT" "github-api list: a failed listing prints nothing"
assert_not_contains "$(cat "$CURL_LOG")" "/labels/" "github-api list: a failed listing clears nothing"

# dry-run
reset
run --dry-run mark-needs-owner 7 "text"
assert_eq "0" "$RC" "github-api mark --dry-run exits 0"
assert_contains "$OUT" "[dry-run]" "github-api mark --dry-run prints the intended calls"
run --dry-run list-needs-owner --clear-answered
assert_contains "$OUT" "DELETE" "github-api list --dry-run --clear-answered prints the intended removals"
assert_eq "" "$(cat "$CURL_LOG")" "github-api --dry-run makes no call"

finish
