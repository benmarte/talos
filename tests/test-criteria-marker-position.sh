#!/usr/bin/env bash
# test-criteria-marker-position.sh -- a criterion's kind marker is the first marker
# that directly follows its id (or checkbox); marker-shaped text later on the line
# or inside backticks is description (#956). Each assertion label starts with its AC id.
#   AC1  `ids` and red-check read the marker after the id, not a quoted one
#   AC2  revise-spec flips only the marker after the id
#   AC3  a revised issue-body spec starts with the header; the prose is unchanged
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

CRIT="$TALOS_ROOT/scripts/pipeline-criteria.sh"
SPECF="$SANDBOX/spec.md"
Q='quoting `(same: refactor)` in the description'

# ── AC1 ids: the marker after the id wins over a quoted same-kind marker ──────
printf '%s\n' \
  "- [ ] AC1 (test) A criterion $Q" \
  '- [ ] AC2 (same: refactor) Keeps the flag, see `(test)` here' \
  '- [ ] AC3 (prose: docs) Documented, with a `(test)` span' \
  '- [ ] AC4 Trailing marker form (test)' > "$SPECF"
OUT="$(bash "$CRIT" ids "$SPECF" 2>&1)"
assert_eq "AC1 test
AC2 same
AC3 prose
AC4 test" "$OUT" "AC1 ids reads the marker right after the id, a backtick-quoted marker is never the kind"

# a positional (checkbox) line: the marker right after the checkbox wins
printf '%s\n' '- [ ] (test) first, quoting `(same: x)`' '- [ ] (same: x) second, quoting `(test)`' > "$SPECF"
OUT="$(bash "$CRIT" ids "$SPECF" 2>&1)"
assert_eq "AC1 test
AC2 same" "$OUT" "AC1 a positional line's marker right after the checkbox wins over a quoted one"

# marker-shaped text later on the line, outside backticks, does not override the one after the id
printf '%s\n' '- [ ] AC1 (test) Prints text such as (same: x) verbatim' > "$SPECF"
OUT="$(bash "$CRIT" ids "$SPECF" 2>&1)"
assert_eq "AC1 test" "$OUT" "AC1 an unquoted later marker does not override the marker after the id"

# ── AC1 red-check on a fixture branch ─────────────────────────────────────────
REPO="$SANDBOX/repo"
export QA_SPEC_FILE="$SANDBOX/qa-spec.md"
mkdir -p "$REPO/scripts" "$REPO/tests"
cd "$REPO" || exit 1
git init -q -b main
git remote add origin git@github.com:acme/widget.git
git config user.email t@t.invalid
git config user.name t
cp "$TALOS_ROOT"/scripts/* scripts/
cat > tests/run-tests.sh <<'TALOS_Vh3tQ8mWc2Ke'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in --for) bash "$2"; shift 2 ;; *) shift ;; esac
done
TALOS_Vh3tQ8mWc2Ke
cat > scripts/pipeline-vcs.sh <<'TALOS_Nb5yR1dXf7Lp'
#!/usr/bin/env bash
case "$1" in
  view-issue)
    python3 -I -c 'import json, sys
print(json.dumps({"title": "t", "body": "issue body", "labels": [],
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$QA_SPEC_FILE" ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_Nb5yR1dXf7Lp
printf 'base\n' > README.md
git add -A; git commit -q -m base
git update-ref refs/remotes/origin/main HEAD
git checkout -q -b feat/issue-7-greet
printf '#!/usr/bin/env bash\nprintf "FAIL  AC1 label\\n"\n' > tests/test-greet.sh
git add -A; git commit -q -m "test(#7): red first"
printf 'done\n' > feature.txt; git add -A; git commit -q -m "feat(#7): greet"
printf '%s\n' '**PM spec:** greeting' '' '**Acceptance criteria**' "- [ ] AC1 (test) greet prints hello $Q" '' '**Tests:** `tests/test-greet.sh`' > "$QA_SPEC_FILE"
OUT="$(bash scripts/pipeline-criteria.sh red-check 7 2>/dev/null)"; RC=$?
assert_eq "red-check: ok" "$OUT" "AC1 red-check reads a (test) criterion that quotes a (same) marker as test: red at the red commit is ok"
assert_eq "0" "$RC" "AC1 red-check exits 0"
cd "$SANDBOX" || exit 1

# ── AC2 revise-spec: only the marker after the id changes ─────────────────────
RS="$SANDBOX/rs"
mkdir -p "$RS"
cp "$TALOS_ROOT"/scripts/* "$RS/"
cat > "$RS/pipeline-vcs.sh" <<'TALOS_Rv4nQ7sXk2Dj'
#!/usr/bin/env bash
case "$1" in
  view-issue)
    python3 -I -c 'import json, sys
print(json.dumps({"title": "t", "body": open(sys.argv[1]).read(), "labels": [], "comments": []}))' "$RS_BODY" ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_Rv4nQ7sXk2Dj
export RS_BODY="$SANDBOX/rs-body.md"
revise() {
  OUT="$(printf '%s\n' "$1" | bash "$RS/pipeline-criteria.sh" revise-spec 7 2>"$SANDBOX/rs.err")"; RC=$?
}
MARK='(same: green at the red commit, found by red-check)'
LEAD='**PM spec:** revised by the driver after red-check: AC1 is (same) (green at the red commit)'
printf '%s\n' '**PM spec:** greeting' '' "- [ ] AC1 (test) A criterion $Q" '' '**Tests:** `tests/test-x.sh`' > "$RS_BODY"
revise 'kind-mismatch AC1 want=same'
assert_eq "0" "$RC" "AC2 revise-spec on a criterion quoting a same marker exits 0"
assert_eq "$(printf '%s\n' "$LEAD" '' greeting '' "- [ ] AC1 $MARK A criterion $Q" '' '**Tests:** `tests/test-x.sh`')" "$OUT" \
  "AC2 only the marker after the id is flipped; the quoted (same: refactor) text is untouched"

# the other direction: (same) after the id, quoted (test) in the description
printf '%s\n' '- [ ] AC1 (same: refactor) Keeps `(test)` as is' > "$RS_BODY"
revise 'kind-mismatch AC1 want=test'
assert_contains "$OUT" '- [ ] AC1 (test) Keeps `(test)` as is' "AC2 a (same) after the id flips to (test), the quoted (test) is untouched"

# ── AC3 the header leads a revised issue-body spec ────────────────────────────
printf '%s\n' 'Intro: the `**PM spec:**` header is written by the PM.' '' '- [ ] AC1 (test) first works' '- Fix: keep `**PM spec:**` in the prose.' '' '**Tests:** `tests/test-x.sh`' > "$RS_BODY"
revise 'kind-mismatch AC1 want=same'
assert_eq "0" "$RC" "AC3 revise-spec on a body spec whose prose holds the header text exits 0"
assert_eq "$(printf '%s\n' "$LEAD" '' 'Intro: the `**PM spec:**` header is written by the PM.' '' "- [ ] AC1 $MARK first works" '- Fix: keep `**PM spec:**` in the prose.' '' '**Tests:** `tests/test-x.sh`')" "$OUT" \
  "AC3 the revised spec starts with the header line and the prose is unchanged"
assert_eq "$LEAD" "$(printf '%s\n' "$OUT" | head -1)" "AC3 the first line of the revised spec is the header"

finish
