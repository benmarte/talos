#!/usr/bin/env bash
# Regression tests for pipeline-vcs.sh — github verb → gh command mapping
# (via --dry-run and the gh stub) and the file-mode adapter's real logic.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── GitHub adapter: dry-run command construction ─────────────────────────────
out="$(bash "$VCS" --dry-run label-issue 5 --add pipeline:confirmed --remove pipeline:ready)"
assert_contains "$out" "gh issue edit 5" "label-issue targets the issue"
assert_contains "$out" "--add-label 'pipeline:confirmed'" "label-issue --add mapped"
assert_contains "$out" "--remove-label 'pipeline:ready'" "label-issue --remove mapped"

out="$(bash "$VCS" --dry-run merge-pr 9)"
assert_contains "$out" "gh pr merge 9 --squash --delete-branch" "merge-pr defaults to squash"

cat > talos.pipeline.json <<'EOF'
{"merge": {"method": "rebase"}}
EOF
out="$(bash "$VCS" --dry-run merge-pr 9)"
assert_contains "$out" "--rebase" "merge.method config changes merge flag"
rm talos.pipeline.json

out="$(bash "$VCS" --dry-run comment-pr 9 "review done")"
assert_contains "$out" "gh issue comment 9" "comment-pr uses issue comment API"

out="$(bash "$VCS" --dry-run close-issue 5 "resolved")"
assert_contains "$out" "gh issue close 5" "close-issue closes after commenting"

# Real-run against the stub: verify gh receives the calls
bash "$VCS" comment-issue 5 "findings body" >/dev/null 2>&1
assert_contains "$(cat "$GH_LOG")" "issue comment 5 --body findings body" \
  "comment-issue invokes gh with the body"

# ── Comment body: --body-file support, and no silent flag-as-body ─────────────
# Regression: passing `--body-file <path>` used to make "$2" the body verbatim,
# so the posted comment was the literal string "--body-file" and exit was 0.

printf 'verdict from a file' > body.md

out="$(bash "$VCS" --dry-run comment-issue 7 --body-file body.md)"
assert_contains "$out" "--body verdict from a file" \
  "comment-issue --body-file reads the file into the body"
assert_not_contains "$out" "body.md" \
  "comment-issue --body-file does not pass the path through as the body"

out="$(bash "$VCS" --dry-run comment-pr 8 --body-file body.md)"
assert_contains "$out" "--body verdict from a file" \
  "comment-pr --body-file reads the file into the body"

out="$(bash "$VCS" --dry-run comment-issue 7 --body "inline via flag")"
assert_contains "$out" "--body inline via flag" \
  "comment-issue --body accepts an explicit flag form too"

# A bare flag must never reach gh as the body.
out="$(bash "$VCS" --dry-run comment-issue 7 --body-file 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "comment-issue refuses a flag-shaped body"
assert_contains "$out" "looks like a flag" "the refusal explains itself"
assert_not_contains "$out" "gh issue comment" "no gh call is constructed"

out="$(bash "$VCS" --dry-run comment-pr 8 --body-file 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "comment-pr refuses a flag-shaped body"

# An unreadable path fails loudly rather than posting the path.
out="$(bash "$VCS" --dry-run comment-issue 7 --body-file no-such-file.md 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "comment-issue --body-file exits 1 on an unreadable path"
assert_contains "$out" "cannot read" "the unreadable path is named"

# A body that legitimately starts with a dash is still a body, not a flag.
out="$(bash "$VCS" --dry-run comment-issue 7 "- bullet one")"
assert_contains "$out" "--body - bullet one" "a leading single dash is not treated as a flag"

# Verbs that are not comment verbs keep their own flag handling.
out="$(bash "$VCS" --dry-run label-issue 7 --add pipeline:ready)"
assert_contains "$out" "--add-label 'pipeline:ready'" "label-issue flags are untouched"

rm -f body.md

# Unknown verb fails loudly
if bash "$VCS" no-such-verb 1 >/dev/null 2>&1; then
  fail "unknown verb exits non-zero"
else
  pass "unknown verb exits non-zero"
fi

# ── find-pr: locate PRs belonging to an issue ─────────────────────────────────
out="$(bash "$VCS" find-pr 42)"
assert_contains "$out" '"number": 9' "find-pr matches branch fix/issue-42"
out="$(bash "$VCS" find-pr 7)"
assert_eq "" "$out" "find-pr returns nothing for unrelated issue"

# ── check-pr-files: forbidden-files gate ──────────────────────────────────────
out="$(bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "0" "$rc" "clean PR passes forbidden-files check"
assert_contains "$out" "no forbidden files" "clean PR reported clean"

out="$(STUB_PR_FILES=$'src/app.js\ndeploy/prod.pem\n.env.production' bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "1" "$rc" "PR touching secrets exits 1 (default patterns)"
assert_contains "$out" "deploy/prod.pem" "violating path listed (*.pem)"
assert_contains "$out" ".env.production" "violating path listed (.env.*)"
assert_not_contains "$out" "src/app.js" "clean path not listed"

cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files": ["*.tfstate"]}}
EOF
out="$(STUB_PR_FILES=$'infra/prod.tfstate\n.env' bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "1" "$rc" "custom forbidden_files config enforced"
assert_contains "$out" "infra/prod.tfstate" "custom pattern matched"
# #61 fix: union semantics — defaults remain active when custom patterns are set
assert_contains "$out" ".env" "union: defaults still active alongside custom patterns"
rm talos.pipeline.json

# ── forbidden_files_allow: allow-list checked before deny patterns ─────────────
# .env.example matches the default .env.* deny pattern, but should be exempt.
cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files_allow": [".env.example"]}}
EOF
out="$(STUB_PR_FILES=$'.env.example\n.env.production' bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "1" "$rc" "allow-list: still blocks the non-allowed .env.production"
assert_not_contains "$out" ".env.example" "allow-list: .env.example is not reported as forbidden"
assert_contains "$out" ".env.production" "allow-list: .env.production is still blocked"

# A file in BOTH allow and deny is permitted (allow wins because it is checked first).
cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files_allow": [".env.example"], "forbidden_files": [".env.*", ".env.example"]}}
EOF
out="$(STUB_PR_FILES=$'.env.example' bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "0" "$rc" "allow-list before deny: allowed file is not blocked even when it appears in deny list"
assert_contains "$out" "no forbidden files" "allow-list before deny: clean result reported"
rm talos.pipeline.json

# ── forbidden_files_allow: semantic validation — full bypass matrix ────────────
# Each dangerous pattern is rejected at config time; the offending entry must be
# named in the error.  Every test below can fail independently: removing the
# validator (the python3 block guarded by || exit 1) turns them all RED.

_assert_allow_rejected() {
  # $1=entry $2=desc
  printf '{"merge": {"forbidden_files_allow": ["%s"]}}\n' "$1" > talos.pipeline.json
  _out="$(STUB_PR_FILES=$'.env.production' bash "$VCS" check-pr-files 9 2>&1)"; _rc=$?
  assert_eq "1" "$_rc" "allow-list $2: exits 1 (config rejected)"
  assert_contains "$_out" "$1" "allow-list $2: offending entry named in error"
  rm talos.pipeline.json
}

_assert_allow_rejected '*'        "catch-all '*'"
_assert_allow_rejected '**'       "catch-all '**'"
_assert_allow_rejected '*/*'      "path-wildcard '*/*'"
_assert_allow_rejected '**/*'     "path-wildcard '**/*'"
_assert_allow_rejected '[a-z]*'   "bracket-expression '[a-z]*'"

# *[!x]* contains shell-special chars so we use a JSON file directly.
cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files_allow": ["*[!x]*"]}}
EOF
out="$(STUB_PR_FILES=$'.env.production' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "allow-list bracket-expression '*[!x]*': exits 1 (config rejected)"
assert_contains "$out" "[!x]" "allow-list bracket-expression '*[!x]*': offending entry named in error"
rm talos.pipeline.json

# config/* — directory wildcard that bypasses via the full-path check.
_assert_allow_rejected 'config/*' "directory-wildcard 'config/*'"

# .env.example must be accepted AND must NOT exempt real secrets.
cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files_allow": [".env.example"]}}
EOF
out="$(STUB_PR_FILES=$'.env.example\n.env.production\nconfig/.env.production\nserver.pem' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "allow-list legitimate entry: accepted; real secrets still blocked"
assert_not_contains "$out" ".env.example" "allow-list legitimate entry: .env.example is exempt"
assert_contains "$out" ".env.production" "allow-list legitimate entry: .env.production is blocked"
assert_contains "$out" "server.pem" "allow-list legitimate entry: server.pem (*.pem) is still blocked"
rm talos.pipeline.json

# ── #61/#64 compound-chain regression: the complete 4-step bypass must now BLOCK ──
# Reproduction of the exact exploit:
#   1. merge.forbidden_files: all-literal list  -> #61: used to replace defaults wholesale
#   2. all-literal deny list                    -> #64: canary generator emitted nothing
#   3. merge.forbidden_files_allow: ['*']       -> no canaries -> allowed (WRONG)
#   4. .env, id_rsa, credentials.json           -> exempted, gate exits 0 (WRONG)
# After fix: union keeps defaults (which have wildcards), canaries are generated,
# allow:'*' is REJECTED, and check-pr-files exits non-zero.
cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files": [".env","id_rsa","credentials.json"], "forbidden_files_allow": ["*"]}}
EOF
out="$(STUB_PR_FILES=$'.env\nid_rsa\ncredentials.json\ndeploy/id_rsa' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "compound-chain: check-pr-files exits non-zero (bypass closed)"
assert_contains "$out" "*" "compound-chain: offending allow-entry '*' named in error"
rm talos.pipeline.json

# ── #61: transparency markers emitted on every run ────────────────────────────
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "transparency: clean PR still exits 0"
assert_contains "$out" "talos:forbidden-files-active patterns=" "transparency: active-patterns marker present"
assert_contains "$out" "defaults=in-force" "transparency: defaults in-force on default config"

# ── #61: merge.forbidden_files_replace: true restores old behaviour + emits warning ──
cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files": ["*.tfstate"], "forbidden_files_replace": true}}
EOF
out="$(STUB_PR_FILES=$'infra/prod.tfstate\n.env' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "replace=true: tfstate still blocked"
assert_contains "$out" "infra/prod.tfstate" "replace=true: custom pattern enforced"
assert_not_contains "$out" ".env" "replace=true: defaults suppressed as requested"
# Must emit both the stderr warning and the stdout marker
assert_contains "$out" "SUPPRESSED" "replace=true: stderr warning about suppressed defaults"
assert_contains "$out" "talos:forbidden-files-defaults-replaced" "replace=true: stdout marker emitted"
rm talos.pipeline.json

# ── #64: empty canary set falls back to built-ins; allow:['*'] still rejected ──
# Scenario: replace=true with all-literal deny list -> canary generator would emit
# nothing without the fallback.  Built-in canaries must catch allow:'*'.
cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files": [".env","id_rsa","credentials.json"], "forbidden_files_replace": true, "forbidden_files_allow": ["*"]}}
EOF
out="$(STUB_PR_FILES=$'.env' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "canary-fallback: allow='*' rejected under all-literal replace list"
assert_contains "$out" "*" "canary-fallback: offending entry named"
rm talos.pipeline.json

# ── #61: no forbidden files still exits 0 (gate does not over-correct) ────────
out="$(bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "0" "$rc" "exit-zero proof: clean PR exits 0 after fix"
assert_contains "$out" "no forbidden files" "exit-zero proof: clean result reported"

# ── #61: .env.example allow entry still works under union semantics ────────────
cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files": ["*.tfstate"], "forbidden_files_allow": [".env.example"]}}
EOF
out="$(STUB_PR_FILES=$'.env.example\ninfra/prod.tfstate\n.env.production' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "union+allow: real secrets still blocked"
assert_not_contains "$out" ".env.example" "union+allow: .env.example remains exempt"
assert_contains "$out" "infra/prod.tfstate" "union+allow: custom pattern blocked"
assert_contains "$out" ".env.production" "union+allow: default .env.* still blocks"
rm talos.pipeline.json

# ── #63: SSH private keys and keystores blocked by default ────────────────────
# Each of the 9 filenames must be blocked with NO config (default patterns only).

# --- Bare SSH key names (extensionless private keys) ---
out="$(STUB_PR_FILES='id_rsa' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63: id_rsa blocked by default (*id_rsa*)"
assert_contains "$out" "id_rsa" "#63: id_rsa listed in output"

out="$(STUB_PR_FILES='id_ecdsa' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63: id_ecdsa blocked by default (*id_ecdsa*)"
assert_contains "$out" "id_ecdsa" "#63: id_ecdsa listed in output"

out="$(STUB_PR_FILES='id_ed25519' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63: id_ed25519 blocked by default (*id_ed25519*)"
assert_contains "$out" "id_ed25519" "#63: id_ed25519 listed in output"

out="$(STUB_PR_FILES='id_dsa' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63: id_dsa blocked by default (*id_dsa*)"
assert_contains "$out" "id_dsa" "#63: id_dsa listed in output"

# --- Prefix variant (custom-named deploy key) ---
out="$(STUB_PR_FILES='deploy_id_rsa' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63: deploy_id_rsa blocked by default (*id_rsa*)"
assert_contains "$out" "deploy_id_rsa" "#63: deploy_id_rsa listed in output"

# --- Path-nested variant ---
out="$(STUB_PR_FILES='.ssh/id_rsa' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63: .ssh/id_rsa blocked by default (*id_rsa*)"
assert_contains "$out" ".ssh/id_rsa" "#63: .ssh/id_rsa listed in output"

# --- PuTTY private key ---
out="$(STUB_PR_FILES='key.ppk' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63: key.ppk blocked by default (*.ppk)"
assert_contains "$out" "key.ppk" "#63: key.ppk listed in output"

# --- Java KeyStore ---
out="$(STUB_PR_FILES='store.jks' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63: store.jks blocked by default (*.jks)"
assert_contains "$out" "store.jks" "#63: store.jks listed in output"

# --- Android keystore ---
out="$(STUB_PR_FILES='x.keystore' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63: x.keystore blocked by default (*.keystore)"
assert_contains "$out" "x.keystore" "#63: x.keystore listed in output"

# --- Accepted false positive: id_rsa.pub is blocked (pinned intentional behavior) ---
out="$(STUB_PR_FILES='id_rsa.pub' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63: id_rsa.pub blocked by *id_rsa* (accepted false positive — use allow list to exempt)"

# --- No over-blocking: benign files still pass ---
out="$(STUB_PR_FILES=$'README.md\nsrc/main.py\ntests/helpers.sh\nidentity.md\nrsa_notes.txt' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "#63: benign files not over-blocked"
assert_contains "$out" "no forbidden files" "#63: benign files reported clean"

# --- Previously-protected set still blocks ---
out="$(STUB_PR_FILES=$'.env\nserver.pem\n.env.production' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63: previously-protected .env/.pem still blocked"
assert_contains "$out" ".env" "#63: .env still blocked"
assert_contains "$out" "server.pem" "#63: server.pem still blocked"

# --- Allow-list can still exempt a specific SSH key file ---
cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files_allow": ["id_rsa.pub"]}}
EOF
out="$(STUB_PR_FILES=$'id_rsa.pub\nid_rsa' bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63: allow-list exempts id_rsa.pub but id_rsa is still blocked"
assert_not_contains "$out" "id_rsa.pub" "#63: id_rsa.pub exempted by allow-list"
assert_contains "$out" "id_rsa" "#63: id_rsa still blocked despite allow-list"
rm talos.pipeline.json

# ── list-prs passes --base and includes baseRefName ──────────────────────────
# With BASE_BRANCH set via config, --dry-run must show --base and baseRefName.
cat > talos.pipeline.json <<'EOF'
{"base_branch": "main"}
EOF
out="$(bash "$VCS" --dry-run list-prs)"
assert_contains "$out" "--base" "list-prs passes --base flag when base_branch is configured"
assert_contains "$out" "baseRefName" "list-prs includes baseRefName in the --json field list"
rm talos.pipeline.json

# ── rerun-ci: re-runs only failed runs for the head SHA ───────────────────────
: > "$GH_LOG"
bash "$VCS" rerun-ci 9 >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "run rerun 111 --failed" "failed run re-run"
assert_not_contains "$log" "run rerun 112" "successful run left alone"

# ── Dry-run variants of the new verbs never hit gh ────────────────────────────
: > "$GH_LOG"
out="$(bash "$VCS" --dry-run find-pr 42; bash "$VCS" --dry-run check-pr-files 9; bash "$VCS" --dry-run rerun-ci 9)"
assert_contains "$out" "[dry-run]" "new verbs support --dry-run"
assert_not_contains "$(grep -v "repo view" "$GH_LOG")" "pr " "dry-run makes no pr/run gh calls"

# ── GitHub adapter: create-issue ─────────────────────────────────────────────
out="$(bash "$VCS" --dry-run create-issue "Fix the crash" /dev/null --label pipeline:ready)"
assert_contains "$out" "gh issue create" "create-issue dry-run contains 'gh issue create'"
assert_contains "$out" "--label" "create-issue dry-run includes --label arg"

: > "$GH_LOG"
printf '' > "$SANDBOX/body.md"
bash "$VCS" create-issue "Fix the crash" "$SANDBOX/body.md" --label pipeline:ready >/dev/null 2>&1
assert_contains "$(cat "$GH_LOG")" "issue create" "create-issue invokes gh with issue create"
assert_contains "$(cat "$GH_LOG")" "--label pipeline:ready" "create-issue passes label to gh"

# ── GitLab adapter: new verbs fail open with a warning ───────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab"}}
EOF
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "gitlab: check-pr-files fails open (exit 0)"
assert_contains "$out" "not implemented for gitlab" "gitlab: fail-open warns the orchestrator"
rm talos.pipeline.json

# ── File-mode adapter: real markdown checklist manipulation ──────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "file", "file": {"source": {"path": "plan.md"}}}}
EOF
cat > plan.md <<'EOF'
# Plan

- [ ] Add login page
- [ ] Fix logout bug
- [x] Old finished item <!-- id: 1 -->
EOF

out="$(bash "$VCS" list-issues)"
assert_contains "$out" '"title": "Add login page"' "file: list-issues returns open items"
assert_not_contains "$out" "Old finished item" "file: checked items excluded"
assert_contains "$(cat plan.md)" "Add login page <!-- id: 2 -->" "file: ids auto-assigned"

out="$(bash "$VCS" view-issue 2)"
assert_contains "$out" "status: open" "file: view-issue shows status"

bash "$VCS" comment-issue 2 "validator: CONFIRMED" >/dev/null
assert_contains "$(cat plan.md)" "validator: CONFIRMED" "file: comment lands in detail block"

bash "$VCS" close-issue 2 "merged branch fix/login" >/dev/null
assert_contains "$(cat plan.md)" "- [x] Add login page" "file: close-issue checks the box"
assert_contains "$(cat plan.md)" "resolved: merged branch fix/login" "file: resolution note appended"

new_id="$(bash "$VCS" create-issue "Add dark mode" "$SANDBOX/body.md")"
assert_contains "$(cat plan.md)" "- [ ] Add dark mode <!-- id:" "file: create-issue appends checklist item"
# ID should be a number
assert_contains "$new_id" "" "file: create-issue prints the assigned id"
if ! printf '%s' "$new_id" | grep -qE '^[0-9]+$'; then
  fail "file: create-issue id is numeric"
else
  pass "file: create-issue id is numeric"
fi

out="$(bash "$VCS" create-pr branch t body 2>&1)"; rc=$?
assert_eq "0" "$rc" "file: create-pr is a safe no-op"

out="$(bash "$VCS" check-pr-files 1 2>&1)"; rc=$?
assert_eq "0" "$rc" "file: check-pr-files is a safe no-op"

finish
