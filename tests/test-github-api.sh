#!/usr/bin/env bash
# Regression tests for the github-api provider in pipeline-vcs.sh.
# Uses the curl stub (CURL_LOG + CURL_QUEUE) — no real network calls.
# Covers: list-issues, comment-issue, label-issue, create-pr, merge-pr,
#         find-pr, check-pr-files, approve-pr, rerun-ci, plus missing-token
#         and dry-run variants.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── Config: use github-api provider with a test token ────────────────────────
TEST_TOKEN="test-secret-token-12345"
export GITHUB_TOKEN="$TEST_TOKEN"

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF

# ── list-issues ───────────────────────────────────────────────────────────────
printf '%s\n' \
  '[{"number":3,"title":"Fix login bug","body":"Body text","labels":[{"name":"pipeline:dev"},{"name":"p1"}]},{"number":7,"title":"Add dark mode","body":"","labels":[]}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" list-issues)"
assert_contains "$out" '"number": 3'       "list-issues: issue number present"
assert_contains "$out" '"title": "Fix login bug"' "list-issues: issue title present"
assert_contains "$out" '"name": "pipeline:dev"'   "list-issues: label name present"
assert_contains "$out" '"number": 7'       "list-issues: second issue present"

# Verify auth header was sent (CURL_LOG contains Authorization: Bearer)
log="$(cat "$CURL_LOG")"
assert_contains "$log" "Authorization: Bearer"   "list-issues: auth header sent"
assert_not_contains "$log" "$TEST_TOKEN"         "list-issues: token value not in curl log"

# Token must NOT appear in stdout
assert_not_contains "$out" "$TEST_TOKEN"         "list-issues: token not in output"

# ── comment-issue ─────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"state":"open","title":"issue 3"}' \
  '{"id":100,"body":"Test comment","html_url":"https://github.com/acme/widget/issues/3#issuecomment-100"}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" comment-issue 3 "validator: CONFIRMED")"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "api.github.com"           "comment-issue: called GitHub API"
assert_contains "$log" "Authorization: Bearer"    "comment-issue: auth header sent"
assert_contains "$log" "validator: CONFIRMED"     "comment-issue: body in payload"
assert_not_contains "$log" "$TEST_TOKEN"          "comment-issue: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"          "comment-issue: token not in output"
assert_contains "$out" "issuecomment-100"         "comment-issue: returns html_url on stdout"

# ── label-issue (multi-step: GET current labels + PUT updated list) ───────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"id":1,"name":"pipeline:dev","color":"5319e7"}]' \
  '[{"id":1,"name":"pipeline:dev"},{"id":2,"name":"pipeline:review"}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" label-issue 3 --add pipeline:review --remove pipeline:dev 2>&1)"
log="$(cat "$CURL_LOG")"
# Two API calls should have been made
line_count="$(grep -c 'api.github.com' "$CURL_LOG" || true)"
assert_contains "$log" "Authorization: Bearer"   "label-issue: auth header sent"
assert_not_contains "$log" "$TEST_TOKEN"         "label-issue: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"         "label-issue: token not in output"

# ── create-pr ─────────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":99,"title":"fix: login bug","html_url":"https://github.com/acme/widget/pull/99","head":{"ref":"fix/issue-3-login","sha":"abc123"},"base":{"ref":"main"}}' \
  > "$CURL_QUEUE"

echo "PR body content" > pr-body.txt
out="$(bash "$VCS" create-pr fix/issue-3-login "fix: login bug" pr-body.txt)"
assert_contains "$out" "https://github.com/acme/widget/pull/99" "create-pr: returns PR URL"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "Authorization: Bearer"   "create-pr: auth header sent"
assert_contains "$log" "fix/issue-3-login"       "create-pr: branch in payload"
assert_not_contains "$log" "$TEST_TOKEN"         "create-pr: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"         "create-pr: token not in output"

# ── create-issue ──────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":55,"title":"feat: planner role","html_url":"https://github.com/acme/widget/issues/55","body":""}' \
  > "$CURL_QUEUE"

echo "Sub-issue body content." > sub-issue.txt
out="$(bash "$VCS" create-issue "feat: planner role" sub-issue.txt --label pipeline:ready)"
assert_contains "$out" "https://github.com/acme/widget/issues/55" "create-issue: returns issue URL"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "api.github.com"            "create-issue: called GitHub API"
assert_contains "$log" "/issues"                   "create-issue: hit issues endpoint"
assert_contains "$log" "Authorization: Bearer"     "create-issue: auth header sent"
assert_contains "$log" "pipeline:ready"            "create-issue: label in payload"
assert_not_contains "$log" "$TEST_TOKEN"           "create-issue: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"           "create-issue: token not in output"

# ── merge-pr ──────────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"sha":"abc123merged","merged":true,"message":"Pull Request successfully merged"}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" merge-pr 99 2>&1)"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "Authorization: Bearer"   "merge-pr: auth header sent"
assert_contains "$log" "/pulls/99/merge"         "merge-pr: correct endpoint called"
assert_not_contains "$log" "$TEST_TOKEN"         "merge-pr: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"         "merge-pr: token not in output"

# ── find-pr ───────────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"number":9,"title":"fix: guard null session","head":{"ref":"fix/issue-42-guard"},"body":"Closes #42","labels":[{"name":"pipeline:review"}],"state":"open"},{"number":10,"title":"chore: cleanup","head":{"ref":"chore/cleanup"},"body":"no issue","labels":[],"state":"open"}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" find-pr 42)"
assert_contains "$out" '"number": 9'             "find-pr: matches by branch"
assert_not_contains "$out" '"number": 10'        "find-pr: unrelated PR excluded"

: > "$CURL_LOG"
printf '%s\n' \
  '[{"number":9,"title":"fix: guard null session","head":{"ref":"fix/issue-42-guard"},"body":"Closes #42","labels":[],"state":"open"}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" find-pr 7)"
assert_eq "" "$out"                              "find-pr: no match returns empty"

# ── check-pr-files ────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"filename":"src/auth.js","status":"modified"},{"filename":"tests/auth.test.js","status":"added"}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "0" "$rc"                              "check-pr-files: clean PR exits 0"
assert_contains "$out" "no forbidden files"      "check-pr-files: clean PR reported"

: > "$CURL_LOG"
printf '%s\n' \
  '[{"filename":"src/auth.js","status":"modified"},{"filename":"deploy/prod.pem","status":"added"},{"filename":".env.production","status":"added"}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "check-pr-files: secrets PR exits 1"
assert_contains "$out" "deploy/prod.pem"         "check-pr-files: pem file listed"
assert_contains "$out" ".env.production"         "check-pr-files: env file listed"
assert_not_contains "$out" "src/auth.js"         "check-pr-files: clean file not listed"

# ── github-api: check-pr-files — compound-chain regression (#61+#64) ──────────
# Same 4-step bypass as test-vcs.sh — must block under github-api provider too.
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "merge": {"forbidden_files": [".env","id_rsa","credentials.json"], "forbidden_files_allow": ["*"]}}
EOF
: > "$CURL_LOG"
printf '%s\n' \
  '[{"filename":".env","status":"added"},{"filename":"id_rsa","status":"added"}]' \
  > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "github-api compound-chain: exits non-zero (bypass closed)"
assert_contains "$out" "*" "github-api compound-chain: offending allow-entry '*' named"
# Restore original config
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF

# ── #76 github-api: wildcard allow entries defeating literal deny — now rejected ──
# Mutation-verify: the assertions below go RED when the literal-skip guard
# (the 'continue' on non-wildcard patterns) is restored in the github-api block,
# and GREEN with the fix.

# *.env — wildcard allow entry matching the literal .env deny pattern: REJECTED.
# (Validation fails before the API call, so curl queue content is irrelevant.)
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "merge": {"forbidden_files_allow": ["*.env"]}}
EOF
: > "$CURL_LOG"
: > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#76 github-api *.env: validation exits 1 (wildcard defeats literal .env)"
assert_contains "$out" "*.env" "#76 github-api *.env: offending entry named in error"
assert_contains "$out" ".env" "#76 github-api *.env: error message names the matched canary"

# ?env — glob ? matches leading dot; must also be rejected.
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "merge": {"forbidden_files_allow": ["?env"]}}
EOF
: > "$CURL_LOG"
: > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#76 github-api ?env: validation exits 1 (wildcard defeats literal .env)"
assert_contains "$out" "?env" "#76 github-api ?env: offending entry named in error"

# Exact literal .env — deliberate operator override: still ACCEPTED.
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "merge": {"forbidden_files_allow": [".env"]}}
EOF
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"src/app.js","status":"modified"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "#76 github-api exact-literal-override: .env allow entry is accepted"

# .env.example — must still be ACCEPTED by validation and must NOT exempt bare .env.
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "merge": {"forbidden_files_allow": [".env.example"]}}
EOF
: > "$CURL_LOG"
printf '%s\n' '[{"filename":".env.example","status":"added"},{"filename":".env","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#76 github-api .env.example: validation accepted; bare .env still blocked"
assert_not_contains "$out" ".env.example" "#76 github-api .env.example: .env.example is exempt"
assert_contains "$out" "FORBIDDEN" "#76 github-api .env.example: .env is still blocked"

# Real secret (.env) is still blocked with no allow entry.
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
: > "$CURL_LOG"
printf '%s\n' '[{"filename":".env","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#76 github-api .env blocked: .env is still blocked with no allow entry"
assert_contains "$out" ".env" "#76 github-api .env blocked: .env listed in output"

# Restore original config
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF

# ── github-api: check-pr-files — transparency markers ─────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"filename":"src/auth.js","status":"modified"}]' \
  > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "github-api transparency: clean PR exits 0"
assert_contains "$out" "talos:forbidden-files-active patterns=" "github-api transparency: active-patterns marker present"
assert_contains "$out" "no forbidden files" "github-api transparency: clean result reported"

# ── #63: SSH private keys and keystores blocked by default (github-api provider) ─
# Restore base config first
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF

# id_rsa
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"id_rsa","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63 github-api: id_rsa blocked by default (*id_rsa*)"
assert_contains "$out" "id_rsa" "#63 github-api: id_rsa listed in output"

# id_ecdsa
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"id_ecdsa","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63 github-api: id_ecdsa blocked by default (*id_ecdsa*)"
assert_contains "$out" "id_ecdsa" "#63 github-api: id_ecdsa listed in output"

# id_ed25519
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"id_ed25519","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63 github-api: id_ed25519 blocked by default (*id_ed25519*)"
assert_contains "$out" "id_ed25519" "#63 github-api: id_ed25519 listed in output"

# id_dsa
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"id_dsa","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63 github-api: id_dsa blocked by default (*id_dsa*)"
assert_contains "$out" "id_dsa" "#63 github-api: id_dsa listed in output"

# deploy_id_rsa (prefix variant)
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"deploy_id_rsa","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63 github-api: deploy_id_rsa blocked by default (*id_rsa*)"
assert_contains "$out" "deploy_id_rsa" "#63 github-api: deploy_id_rsa listed in output"

# .ssh/id_rsa (path-nested variant)
: > "$CURL_LOG"
printf '%s\n' '[{"filename":".ssh/id_rsa","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63 github-api: .ssh/id_rsa blocked by default (*id_rsa*)"
assert_contains "$out" ".ssh/id_rsa" "#63 github-api: .ssh/id_rsa listed in output"

# key.ppk (PuTTY private key)
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"key.ppk","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63 github-api: key.ppk blocked by default (*.ppk)"
assert_contains "$out" "key.ppk" "#63 github-api: key.ppk listed in output"

# store.jks (Java KeyStore)
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"store.jks","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63 github-api: store.jks blocked by default (*.jks)"
assert_contains "$out" "store.jks" "#63 github-api: store.jks listed in output"

# x.keystore (Android keystore)
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"x.keystore","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63 github-api: x.keystore blocked by default (*.keystore)"
assert_contains "$out" "x.keystore" "#63 github-api: x.keystore listed in output"

# id_rsa.pub — accepted false positive, pinned intentionally
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"id_rsa.pub","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63 github-api: id_rsa.pub blocked by *id_rsa* (accepted false positive)"

# No over-blocking: benign files pass
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"README.md","status":"modified"},{"filename":"src/main.py","status":"added"},{"filename":"identity.md","status":"added"},{"filename":"rsa_notes.txt","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "#63 github-api: benign files not over-blocked"
assert_contains "$out" "no forbidden files" "#63 github-api: benign files reported clean"

# Previously-protected set still blocks
: > "$CURL_LOG"
printf '%s\n' '[{"filename":".env","status":"added"},{"filename":"server.pem","status":"added"},{"filename":".env.production","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63 github-api: previously-protected files still blocked"
assert_contains "$out" ".env" "#63 github-api: .env still blocked"
assert_contains "$out" "server.pem" "#63 github-api: server.pem still blocked"

# Allow-list can still exempt a specific file
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "merge": {"forbidden_files_allow": ["id_rsa.pub"]}}
EOF
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"id_rsa.pub","status":"added"},{"filename":"id_rsa","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#63 github-api: allow-list exempts id_rsa.pub but id_rsa is still blocked"
assert_not_contains "$out" "id_rsa.pub" "#63 github-api: id_rsa.pub exempted by allow-list"
assert_contains "$out" "id_rsa" "#63 github-api: id_rsa still blocked"
# Restore base config
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF

# ── #78: Extended forbidden-files defaults (5 new patterns, github-api provider) ─

# --- *.pkcs12 (PKCS#12 bundle) ---
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"bundle.pkcs12","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#78 github-api: bundle.pkcs12 blocked by default (*.pkcs12)"
assert_contains "$out" "bundle.pkcs12" "#78 github-api: bundle.pkcs12 listed in output"

# --- *.kdbx (KeePass database) ---
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"passwords.kdbx","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#78 github-api: passwords.kdbx blocked by default (*.kdbx)"
assert_contains "$out" "passwords.kdbx" "#78 github-api: passwords.kdbx listed in output"

# --- *.ovpn (OpenVPN profile) ---
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"client.ovpn","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#78 github-api: client.ovpn blocked by default (*.ovpn)"
assert_contains "$out" "client.ovpn" "#78 github-api: client.ovpn listed in output"

# --- .netrc (literal — root) ---
: > "$CURL_LOG"
printf '%s\n' '[{"filename":".netrc","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#78 github-api: .netrc blocked by default (.netrc)"
assert_contains "$out" ".netrc" "#78 github-api: .netrc listed in output"

# --- .netrc (literal — nested path) ---
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"home/.netrc","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#78 github-api: home/.netrc blocked by default (.netrc — nested)"
assert_contains "$out" "home/.netrc" "#78 github-api: home/.netrc listed in output"

# --- _netrc (Windows spelling — literal) ---
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"_netrc","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#78 github-api: _netrc blocked by default (_netrc)"
assert_contains "$out" "_netrc" "#78 github-api: _netrc listed in output"

# --- _netrc (Windows spelling — nested path) ---
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"home/_netrc","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#78 github-api: home/_netrc blocked by default (_netrc — nested)"
assert_contains "$out" "home/_netrc" "#78 github-api: home/_netrc listed in output"

# --- REJECTED patterns: legitimate files must PASS ---

# *.asc — detached signatures
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"release.tar.gz.asc","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "#78 github-api: release.tar.gz.asc NOT blocked (*.asc deliberately excluded)"
assert_contains "$out" "no forbidden files" "#78 github-api: release.tar.gz.asc reported clean"

# *.gpg — encrypted-at-rest workflow
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"vault/entry.gpg","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "#78 github-api: vault/entry.gpg NOT blocked (*.gpg deliberately excluded)"
assert_contains "$out" "no forbidden files" "#78 github-api: vault/entry.gpg reported clean"

# *.der — public X.509 certificates
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"fixtures/ca-root.der","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "#78 github-api: fixtures/ca-root.der NOT blocked (*.der deliberately excluded)"
assert_contains "$out" "no forbidden files" "#78 github-api: fixtures/ca-root.der reported clean"

# --- #76 canary: *netrc wildcard allow entry must be REJECTED ---
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "merge": {"forbidden_files_allow": ["*netrc"]}}
EOF
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"README.md","status":"modified"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "#78/#76 github-api: *netrc wildcard allow entry rejected (would defeat .netrc/_netrc)"

# --- #76 canary: exact allow entry for literal pattern is accepted ---
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "merge": {"forbidden_files_allow": [".netrc"]}}
EOF
: > "$CURL_LOG"
printf '%s\n' '[{"filename":".netrc","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "#78/#76 github-api: exact allow entry .netrc permits that specific file"
assert_not_contains "$out" ".netrc" "#78/#76 github-api: .netrc not reported as forbidden when exact-allowed"
assert_contains "$out" "no forbidden files" "#78/#76 github-api: exact-allowed .netrc reported clean"

# Restore base config
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF

# --- EXIT-ZERO PROOF: clean PR exits 0 ---
: > "$CURL_LOG"
printf '%s\n' '[{"filename":"README.md","status":"modified"},{"filename":"src/main.py","status":"added"}]' > "$CURL_QUEUE"
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "#78 github-api: exit-zero proof — clean PR exits 0"
assert_contains "$out" "no forbidden files" "#78 github-api: exit-zero proof — clean result reported"

# ── approve-pr ────────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"id":200,"state":"APPROVED","body":"LGTM"}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" approve-pr 9 "LGTM" 2>&1)"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "/pulls/9/reviews"        "approve-pr: correct endpoint"
assert_contains "$log" "Authorization: Bearer"   "approve-pr: auth header sent"
assert_not_contains "$log" "$TEST_TOKEN"         "approve-pr: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"         "approve-pr: token not in output"

# ── rerun-ci ──────────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":9,"head":{"sha":"abc123sha","ref":"fix/issue-42-guard"},"title":"fix: guard"}' \
  '{"total_count":2,"workflow_runs":[{"id":111,"conclusion":"failure","name":"CI"},{"id":112,"conclusion":"success","name":"CI"}]}' \
  '{}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" rerun-ci 9 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "rerun-ci: exits 0 on success"
assert_contains "$out" "rerun-ci: re-ran failed runs for PR #9" "rerun-ci: prints success line"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "/actions/runs/111/rerun-failed-jobs" "rerun-ci: failed run restarted"
assert_not_contains "$log" "/actions/runs/112/rerun-failed-jobs" "rerun-ci: successful run skipped"
assert_contains "$log" "Authorization: Bearer"   "rerun-ci: auth header sent"
assert_not_contains "$log" "$TEST_TOKEN"         "rerun-ci: token not in log"
assert_not_contains "$out" "$TEST_TOKEN"         "rerun-ci: token not in output"

# ── rerun-ci: no failed runs returns exit 0 with informational message ─────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":9,"head":{"sha":"abc123sha","ref":"fix/issue-42-guard"},"title":"fix: guard"}' \
  '{"total_count":1,"workflow_runs":[{"id":112,"conclusion":"success","name":"CI"}]}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" rerun-ci 9 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "rerun-ci: no failures exits 0"
assert_contains "$out" "no failed runs"          "rerun-ci: no failures prints informational message"

# ── find-pr merged: maps state=merged to state=closed + merged_at filter ─────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"number":9,"title":"fix: guard null session","head":{"ref":"fix/issue-42-guard"},"body":"Closes #42","labels":[],"state":"closed","merged_at":"2026-07-09T10:00:00Z"},{"number":10,"title":"fix: other","head":{"ref":"fix/issue-42-other"},"body":"also #42","labels":[],"state":"closed","merged_at":null}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" find-pr 42 merged)"
assert_contains "$out" '"number": 9'             "find-pr merged: matches merged PR"
assert_contains "$out" '"state": "MERGED"'       "find-pr merged: state normalized to MERGED"
assert_not_contains "$out" '"number": 10'        "find-pr merged: closed-not-merged excluded"

# ── find-pr open: state field is OPEN ─────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"number":9,"title":"fix: guard null session","head":{"ref":"fix/issue-42-guard"},"body":"Closes #42","labels":[],"state":"open","merged_at":null}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" find-pr 42)"
assert_contains "$out" '"state": "OPEN"'         "find-pr open: state normalized to OPEN"

# ── 429 rate-limit: logs reset epoch and exits 1 ─────────────────────────────
export GITHUB_TOKEN="$TEST_TOKEN"
: > "$CURL_LOG"
# A bare 3-digit number in CURL_QUEUE is treated as an HTTP status override.
printf '429\n' > "$CURL_QUEUE"
export CURL_RATE_LIMIT_RESET=1999999999

err="$(bash "$VCS" list-issues 2>&1 >/dev/null)"; rc=$?
assert_eq "1" "$rc"                                          "429: exits 1"
assert_contains "$err" "rate-limited"                        "429: stderr mentions rate-limited"
assert_contains "$err" "1999999999"                          "429: stderr includes reset epoch"

unset CURL_RATE_LIMIT_RESET

# ── missing token → clear error ───────────────────────────────────────────────
unset GITHUB_TOKEN GH_TOKEN
: > "$CURL_QUEUE"

err="$(bash "$VCS" list-issues 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "missing-token: exits 1"
assert_contains "$err" "GITHUB_TOKEN or GH_TOKEN required" "missing-token: clear error message"

export GITHUB_TOKEN="$TEST_TOKEN"  # restore for remaining tests

# ── pr-head ───────────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":7,"head":{"sha":"aabbccddeeff001122334455667788990011aabb"},"base":{"ref":"main"}}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" pr-head 7)"; rc=$?
assert_eq "0" "$rc"                                                      "pr-head: exits 0"
assert_eq "aabbccddeeff001122334455667788990011aabb" "$out"              "pr-head: prints 40-char SHA"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "pulls/7"                                         "pr-head: called pulls endpoint"
assert_contains "$log" "Authorization: Bearer"                           "pr-head: auth header sent"

# pr-head: error when SHA is absent
: > "$CURL_LOG"
printf '%s\n' '{"number":7,"head":{}}' > "$CURL_QUEUE"
err="$(bash "$VCS" pr-head 7 2>&1)"; rc=$?
assert_eq "1" "$rc"                                                      "pr-head: exits 1 when SHA absent"
assert_contains "$err" "pr-head: could not resolve head SHA"             "pr-head: error message on missing SHA"

# ── read-attempt ──────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"body":"Talos attempt record -- stage=qa count=2 total=5\n<!-- talos:attempt stage=qa count=2 total=5 -->","user":{"login":"bot"}}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" read-attempt 9)"; rc=$?
assert_eq "0" "$rc"                                                      "read-attempt: exits 0"
assert_contains "$out" "stage=qa count=2 total=5"                        "read-attempt: extracts marker values"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "issues/9/comments"                               "read-attempt: called comments endpoint"
assert_contains "$log" "Authorization: Bearer"                           "read-attempt: auth header sent"

# read-attempt: no marker present → zero state
: > "$CURL_LOG"
printf '%s\n' '[]' > "$CURL_QUEUE"
out="$(bash "$VCS" read-attempt 9)"; rc=$?
assert_eq "0" "$rc"                                                      "read-attempt: exits 0 with no marker"
assert_eq "stage= count=0 total=0" "$out"                               "read-attempt: zero state when no marker"

# ── record-attempt ────────────────────────────────────────────────────────────
: > "$CURL_LOG"
# First call: read-attempt (returns prior state: developer count=1)
# Second call: POST comment
printf '%s\n' \
  '[{"body":"Talos attempt record\n<!-- talos:attempt stage=developer count=1 total=1 -->","user":{"login":"bot"}}]' \
  '{"id":200,"html_url":"https://github.com/acme/widget/issues/9#issuecomment-200"}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" record-attempt 9 developer)"; rc=$?
assert_eq "0" "$rc"                                                      "record-attempt: exits 0 under ceiling"
assert_contains "$out" "stage=developer count=2 total=2"                 "record-attempt: increments consecutive count"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "issues/9/comments"                               "record-attempt: POSTed comment"

# ── check-attempt ─────────────────────────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"body":"<!-- talos:attempt stage=qa count=1 total=2 -->","user":{"login":"bot"}}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" check-attempt 9)"; rc=$?
assert_eq "0" "$rc"                                                      "check-attempt: exits 0 below ceiling"
assert_contains "$out" "ok (stage=qa"                                    "check-attempt: reports ok state"

# check-attempt: ceiling exceeded (max_fix_attempts=1, count=1 >= 1)
: > "$CURL_LOG"
printf '%s\n' \
  '[{"body":"<!-- talos:attempt stage=developer count=1 total=1 -->","user":{"login":"bot"}}]' \
  > "$CURL_QUEUE"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "limits": {"max_fix_attempts": 1}}
EOF
err="$(bash "$VCS" check-attempt 9 2>&1)"; rc=$?
assert_eq "1" "$rc"                                                      "check-attempt: exits 1 when ceiling exceeded"
assert_contains "$err" "BLOCKED"                                         "check-attempt: BLOCKED in stderr"
# Restore config
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
export GITHUB_TOKEN="$TEST_TOKEN"

# ── check-approval-sha ────────────────────────────────────────────────────────
: > "$CURL_LOG"
_HEAD="aabbccddeeff001122334455667788990011aabb"
# Call 1: GET /pulls/7  (pr-data)
# Call 2: GET /issues/7/comments (comments)
printf '%s\n' \
  "{\"number\":7,\"head\":{\"sha\":\"$_HEAD\"},\"base\":{\"ref\":\"main\"},\"labels\":[{\"name\":\"qa:pass\"}]}" \
  "[{\"body\":\"<!-- talos:approval sha=${_HEAD} role=qa -->\",\"user\":{\"login\":\"bot\"}}]" \
  > "$CURL_QUEUE"

out="$(bash "$VCS" check-approval-sha 7)"; rc=$?
assert_eq "0" "$rc"                                                      "check-approval-sha: exits 0 for current SHA"
assert_contains "$out" "all approval labels are current"                 "check-approval-sha: current message"

# check-approval-sha: stale detection (SHA mismatch, non-waivable file changed)
: > "$CURL_LOG"
_STALE="0000000000000000000000000000000000000001"
printf '%s\n' \
  "{\"number\":7,\"head\":{\"sha\":\"$_HEAD\"},\"base\":{\"ref\":\"main\"},\"labels\":[{\"name\":\"qa:pass\"}]}" \
  "[{\"body\":\"<!-- talos:approval sha=${_STALE} role=qa -->\",\"user\":{\"login\":\"bot\"}}]" \
  > "$CURL_QUEUE"
err="$(bash "$VCS" check-approval-sha 7 2>&1)"; rc=$?
# rc may be 1 (STALE) OR 0 (when git diff is not available in test env, probe fails)
# The important thing is that a mismatched short SHA is detected — check message:
# (Stale detection requires git cat-file to succeed; in sandbox it won't have the
# commit, so we get the "does not exist" stale reason — either way rc is nonzero.)
assert_eq "1" "$rc"                                                      "check-approval-sha: exits 1 for stale label"
assert_contains "$err" "STALE qa:pass"                                   "check-approval-sha: STALE in stderr"

# ── check-closing-keyword ─────────────────────────────────────────────────────
: > "$CURL_LOG"
# No closing keyword: should exit 0, one API call only
printf '%s\n' \
  '{"number":7,"body":"Part of #9","head":{"ref":"fix/branch"},"base":{"ref":"main"}}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" check-closing-keyword 7 9 2>&1)"; rc=$?
assert_eq "0" "$rc"                                                      "check-closing-keyword: exits 0 when no closing keyword"
log="$(cat "$CURL_LOG")"
# Only one API call should have been made (no sibling fetch needed)
_call_count="$(grep -c 'api.github.com' "$CURL_LOG" || true)"
assert_eq "1" "$_call_count"                                             "check-closing-keyword: only one API call when no keyword"

# check-closing-keyword: closing keyword present, no open siblings
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":7,"body":"Closes #9","head":{"ref":"fix/branch"},"base":{"ref":"main"}}' \
  '[{"number":7,"head":{"ref":"fix/branch"},"title":"the PR","body":"Closes #9","state":"open"}]' \
  > "$CURL_QUEUE"
out="$(bash "$VCS" check-closing-keyword 7 9 2>&1)"; rc=$?
assert_eq "0" "$rc"                                                      "check-closing-keyword: exits 0 when only sibling is self"

# check-closing-keyword: open sibling → exit 1
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":7,"body":"Closes #9","head":{"ref":"fix/branch"},"base":{"ref":"main"}}' \
  '[{"number":7,"head":{"ref":"fix/branch"},"title":"PR 7","body":"Closes #9","state":"open"},{"number":8,"head":{"ref":"fix/issue-9-other"},"title":"PR 8","body":"Part of #9","state":"open"}]' \
  > "$CURL_QUEUE"
err="$(bash "$VCS" check-closing-keyword 7 9 2>&1)"; rc=$?
assert_eq "1" "$rc"                                                      "check-closing-keyword: exits 1 when open sibling present"
assert_contains "$err" "sibling"                                         "check-closing-keyword: sibling in error message"

# ── label-pr gate: check-approval-sha routes through github-api when provider=github-api ──
# Verify that label-pr's internal check-approval-sha call works end-to-end via _github_api.
: > "$CURL_LOG"
_HEAD2="ccddee112233445566778899aabbccddeeff0011"
# label-pr queues: 1) GET current labels, 2) PUT updated labels, 3) GET /pulls/$n (check-approval-sha), 4) GET /issues/$n/comments
printf '%s\n' \
  "[{\"id\":1,\"name\":\"pipeline:review\",\"color\":\"5319e7\"}]" \
  "[{\"id\":1,\"name\":\"pipeline:review\"},{\"id\":2,\"name\":\"qa:pass\"}]" \
  "{\"number\":3,\"head\":{\"sha\":\"$_HEAD2\"},\"base\":{\"ref\":\"main\"},\"labels\":[{\"name\":\"qa:pass\"}]}" \
  "[{\"body\":\"<!-- talos:approval sha=${_HEAD2} role=qa -->\",\"user\":{\"login\":\"bot\"}}]" \
  > "$CURL_QUEUE"
out="$(bash "$VCS" label-pr 3 --add qa:pass 2>&1)"; rc=$?
assert_eq "0" "$rc"                                                      "label-pr gate: exits 0 with current marker"

# ── dry-run: all new verbs print [dry-run] and never invoke curl ──────────────
: > "$CURL_LOG"
: > "$CURL_QUEUE"

dry_out="$(bash "$VCS" --dry-run list-issues; \
           bash "$VCS" --dry-run comment-issue 3 "body"; \
           bash "$VCS" --dry-run label-issue 3 --add foo; \
           bash "$VCS" --dry-run create-issue "title" /dev/null --label pipeline:ready; \
           bash "$VCS" --dry-run create-pr branch title /dev/null; \
           bash "$VCS" --dry-run merge-pr 9; \
           bash "$VCS" --dry-run find-pr 42; \
           bash "$VCS" --dry-run check-pr-files 9; \
           bash "$VCS" --dry-run approve-pr 9 body; \
           bash "$VCS" --dry-run rerun-ci 9; \
           bash "$VCS" --dry-run pr-head 7; \
           bash "$VCS" --dry-run read-attempt 9; \
           bash "$VCS" --dry-run record-attempt 9 developer; \
           bash "$VCS" --dry-run check-attempt 9; \
           bash "$VCS" --dry-run check-approval-sha 7; \
           bash "$VCS" --dry-run check-closing-keyword 7 9)"

assert_contains "$dry_out" "[dry-run]"           "dry-run: all verbs print [dry-run]"
# Curl log should be empty (no curl calls in dry-run)
dry_log="$(cat "$CURL_LOG")"
assert_eq "" "$dry_log"                          "dry-run: no curl calls made"

# ── unknown provider error still works (sanity) ──────────────────────────────
unset GITHUB_TOKEN GH_TOKEN
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
err="$(bash "$VCS" view-issue 3 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "github-api without token: exits 1"

finish
