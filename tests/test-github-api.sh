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

# Instant retries (#173): no test in this file should wait out a real backoff.
export TALOS_RETRY_SLEEP_SCALE=0

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

# ── 429 rate-limit retry/backoff (#173) ───────────────────────────────────────
# Replaces the old "429 immediately exits 1" test: under the new retry
# contract a single 429 is retried, not fatal. Covers retry-then-succeed,
# exhaustion (naming the verb + last status/reset), a plain 404 (no retry
# entered at all), and --dry-run (never sleeps, never retries, never even
# calls curl).
export GITHUB_TOKEN="$TEST_TOKEN"
_errfile="$SANDBOX/stderr.txt"

# -- retry-then-succeed: 429, 429, then a real 200 body --
: > "$CURL_LOG"
printf '429\n429\n%s\n' \
  '[{"number":3,"title":"Fix login bug","body":"Body text","labels":[]}]' \
  > "$CURL_QUEUE"
export CURL_RATE_LIMIT_RESET=1999999999

out="$(bash "$VCS" list-issues 2>"$_errfile")"; rc=$?
err="$(cat "$_errfile")"
assert_eq "0" "$rc"                              "429 retry: succeeds after two retries"
assert_contains "$out" '"number": 3'             "429 retry: returns the issue once the retry succeeds"
_retry_lines="$(printf '%s\n' "$err" | grep -c 'retry [0-9]*/[0-9]* in')"
assert_eq "2" "$_retry_lines"                    "429 retry: exactly two retry log lines"
_calls="$(wc -l < "$CURL_LOG" | tr -d ' ')"
assert_eq "3" "$_calls"                          "429 retry: three curl calls (two 429s + the success)"

# -- exhaustion: limits.max_retries (default 5) consecutive 429s -> exit 1,
#    naming the last status and reset epoch, after exactly max_retries+1 tries --
: > "$CURL_LOG"
: > "$_errfile"
printf '429\n429\n429\n429\n429\n429\n' > "$CURL_QUEUE"

out="$(bash "$VCS" list-issues 2>"$_errfile")"; rc=$?
err="$(cat "$_errfile")"
assert_eq "1" "$rc"                              "429 exhaustion: exits 1 once max_retries is exhausted"
assert_eq ""  "$out"                             "429 exhaustion: no partial output"
assert_contains "$err" "list-issues"             "429 exhaustion: message names the verb attempted"
assert_contains "$err" "rate-limited"             "429 exhaustion: message mentions rate-limited"
assert_contains "$err" "1999999999"              "429 exhaustion: message includes the last reset epoch"
_calls="$(wc -l < "$CURL_LOG" | tr -d ' ')"
assert_eq "6" "$_calls"                          "429 exhaustion: exactly max_retries+1 (6) curl calls, no more"

unset CURL_RATE_LIMIT_RESET

# -- GitHub 403 secondary-rate-limit body: retryable even though the status
#    is 403, not 429 --
: > "$CURL_LOG"
: > "$_errfile"
printf '403:{"message":"You have exceeded a secondary rate limit"}\n%s\n' \
  '[{"number":3,"title":"Fix login bug","body":"Body text","labels":[]}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" list-issues 2>"$_errfile")"; rc=$?
err="$(cat "$_errfile")"
assert_eq "0" "$rc"                              "403 secondary-limit: succeeds after one retry"
assert_contains "$out" '"number": 3'             "403 secondary-limit: returns the issue once the retry succeeds"
_retry_lines="$(printf '%s\n' "$err" | grep -c 'retry [0-9]*/[0-9]* in')"
assert_eq "1" "$_retry_lines"                    "403 secondary-limit: exactly one retry log line"

# -- plain 404 (no rate-limit body): fails immediately, no retry attempted --
: > "$CURL_LOG"
: > "$_errfile"
printf '404\n' > "$CURL_QUEUE"

out="$(bash "$VCS" list-issues 2>"$_errfile")"; rc=$?
err="$(cat "$_errfile")"
assert_eq "1" "$rc"                              "404: exits 1"
assert_not_contains "$err" "retry"               "404: no retry log line -- not a retryable status"
_calls="$(wc -l < "$CURL_LOG" | tr -d ' ')"
assert_eq "1" "$_calls"                          "404: exactly one curl call, no retry"

# -- --dry-run: never sleeps, never retries, never even reaches curl.
#    TALOS_RETRY_SLEEP_SCALE is deliberately left unset (defaults to 1) here so
#    the assertion proves --dry-run itself prevents the sleep, not the scale --
: > "$CURL_LOG"
printf '429\n' > "$CURL_QUEUE"
_t0="$(date +%s)"
out="$(bash "$VCS" --dry-run list-issues)"
_t1="$(date +%s)"
_elapsed=$((_t1 - _t0))
assert_contains "$out" "dry-run"                 "dry-run: prints the dry-run marker instead of calling curl"
_calls="$(wc -l < "$CURL_LOG" | tr -d ' ')"
assert_eq "0" "$_calls"                          "dry-run: no curl call is made at all"
if [ "$_elapsed" -lt 2 ]; then
  pass "dry-run: completes near-instantly (no backoff sleep)"
else
  fail "dry-run: completes near-instantly (no backoff sleep)" "elapsed=${_elapsed}s"
fi

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

# ── Pagination regression tests (#126) ───────────────────────────────────────
export GITHUB_TOKEN="$TEST_TOKEN"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF

# T-pagination: read-attempt finds marker at comment #101 (on page 2)
# Mutation: revert _ga_fetch_all_comments to single per_page=100 call → RED.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
_page2_url="https://api.github.com/repos/acme/widget/issues/42/comments?per_page=100&page=2"
_page1="$(python3 -c "
import json
c = [{'body': 'comment ' + str(i), 'user': {'login': 'user'}} for i in range(100)]
print(json.dumps(c))
")"
_page2='[{"body":"talos record\n<!-- talos:attempt stage=developer count=3 total=5 -->","user":{"login":"bot"}}]'
printf '%s\n' "$_page2_url" "" > "$CURL_LINK_QUEUE"
printf '%s\n' "$_page1" "$_page2" > "$CURL_QUEUE"
out="$(bash "$VCS" read-attempt 42 2>/dev/null)"; rc=$?
# Extract stage= line only (talos:marker-authors-unverified also goes to stdout)
stage_line="$(printf '%s' "$out" | grep '^stage=' || true)"
assert_eq "0" "$rc" \
  "T-pagination: read-attempt exits 0 when marker on page 2"
assert_eq "stage=developer count=3 total=5" "$stage_line" \
  "T-pagination: read-attempt finds attempt marker beyond comment #100 (mutation: remove pagination)"

# T-user-null: comment with "user": null does not crash; marker in later comment is found
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
_null_user_list='[{"body":"some text","user":null},{"body":"record\n<!-- talos:attempt stage=qa count=1 total=1 -->","user":{"login":"bot"}}]'
printf '%s\n' "$_null_user_list" > "$CURL_QUEUE"
out="$(bash "$VCS" read-attempt 42 2>&1)"; rc=$?
assert_eq "0" "$rc" \
  "T-user-null: user:null comment does not crash read-attempt"
assert_contains "$out" "stage=qa count=1 total=1" \
  "T-user-null: marker found in comment following user:null comment"

# T-check-attempt-ceil-paged: check-attempt exits 1 when marker is on page 2 and ceiling reached
# Mutation: revert pagination → check-attempt returns ok (exits 0) → RED.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
_ceil_url="https://api.github.com/repos/acme/widget/issues/42/comments?per_page=100&page=2"
printf '%s\n' "$_ceil_url" "" > "$CURL_LINK_QUEUE"
_ceil_p1="$(python3 -c "
import json
c = [{'body': 'comment ' + str(i), 'user': {'login': 'u'}} for i in range(100)]
print(json.dumps(c))
")"
_ceil_p2='[{"body":"<!-- talos:attempt stage=developer count=3 total=3 -->","user":{"login":"bot"}}]'
printf '%s\n' "$_ceil_p1" "$_ceil_p2" > "$CURL_QUEUE"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "limits": {"max_fix_attempts": 3}}
EOF
err="$(bash "$VCS" check-attempt 42 2>&1)"; rc=$?
assert_eq "1" "$rc" \
  "T-ceil-paged: check-attempt exits 1 when ceiling reached via page-2 marker (mutation: remove pagination)"
assert_contains "$err" "BLOCKED" \
  "T-ceil-paged: BLOCKED message when ceiling is reached on page 2"

# T-regression: behaviour on <100 comments is byte-identical to before
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
export GITHUB_TOKEN="$TEST_TOKEN"
printf '%s\n' \
  '[{"body":"<!-- talos:attempt stage=qa count=2 total=5 -->","user":{"login":"bot"}}]' \
  > "$CURL_QUEUE"
out="$(bash "$VCS" read-attempt 99 2>/dev/null)"; rc=$?
reg_stage="$(printf '%s' "$out" | grep '^stage=' || true)"
assert_eq "0" "$rc" \
  "T-regression: read-attempt exits 0 on <100-comment issue (no pagination needed)"
assert_eq "stage=qa count=2 total=5" "$reg_stage" \
  "T-regression: stage= output byte-identical to pre-fix for <100-comment path"

# ── Issue #128: Role validation — _github_api provider parity ────────────────
# Verifies that the VALID_ROLES check in _github_api behaves identically to
# the _github check. Reason strings must be byte-identical across providers.

export GITHUB_TOKEN="$TEST_TOKEN"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF

_API_HEAD="ff00112233445566778899aabbccddeeff001122"

# #128-api M1: unknown role=qa-extra is logged and skipped; gate exits 1.
# Without Change: gate still exits 1 (role-equality fails) but no log line.
# RED comes from the missing stderr line, not the exit code.
: > "$CURL_LOG"
printf '%s\n' \
  "{\"number\":7,\"head\":{\"sha\":\"$_API_HEAD\"},\"base\":{\"ref\":\"main\"},\"labels\":[{\"name\":\"qa:pass\"}]}" \
  "[{\"body\":\"approval done\\n<!-- talos:approval sha=${_API_HEAD} role=qa-extra -->\",\"user\":{\"login\":\"bot\"}}]" \
  > "$CURL_QUEUE"
out="$(bash "$VCS" check-approval-sha 7 2>&1)"; rc=$?
assert_eq "1" "$rc" \
  "#128-api M1 unknown role: exits 1 (_github_api)"
assert_contains "$out" "ignoring marker with unknown role 'qa-extra'" \
  "#128-api M1 unknown role: stderr line emitted (_github_api) — byte-identical to _github"
assert_contains "$out" "valid: docs, qa, reviewer, security" \
  "#128-api M1 unknown role: valid set listed (_github_api)"
assert_contains "$out" "no SHA marker" \
  "#128-api M1 unknown role: falls through to STALE (_github_api)"

# #128-api M3: full valid four-role set still exits 0 (regression guard).
: > "$CURL_LOG"
printf '%s\n' \
  "{\"number\":7,\"head\":{\"sha\":\"$_API_HEAD\"},\"base\":{\"ref\":\"main\"},\"labels\":[{\"name\":\"qa:pass\"},{\"name\":\"review:approved\"},{\"name\":\"security:approved\"},{\"name\":\"docs:done\"}]}" \
  "[{\"body\":\"<!-- talos:approval sha=${_API_HEAD} role=qa -->\"},{\"body\":\"<!-- talos:approval sha=${_API_HEAD} role=reviewer -->\"},{\"body\":\"<!-- talos:approval sha=${_API_HEAD} role=security -->\"},{\"body\":\"<!-- talos:approval sha=${_API_HEAD} role=docs -->\"}]" \
  > "$CURL_QUEUE"
out="$(bash "$VCS" check-approval-sha 7 2>&1)"; rc=$?
assert_eq "0" "$rc" \
  "#128-api M3 full four-role set: exits 0 (_github_api regression guard)"
assert_contains "$out" "all approval labels are current" \
  "#128-api M3 full four-role set: all current reported"
assert_not_contains "$out" "ignoring marker" \
  "#128-api M3 full four-role set: no spurious unknown-role warnings"

# ── Issue #142: near-miss message parity for _github_api ─────────────────────
# Case A: no talos:approval text -> existing message, byte-identical (regression guard).
: > "$CURL_LOG"
printf '%s\n' \
  "{\"number\":7,\"head\":{\"sha\":\"$_API_HEAD\"},\"base\":{\"ref\":\"main\"},\"labels\":[{\"name\":\"qa:pass\"}]}" \
  "[{\"body\":\"qa passed, no marker here\",\"user\":{\"login\":\"bot\"}}]" \
  > "$CURL_QUEUE"
out="$(bash "$VCS" check-approval-sha 7 2>&1)"; rc=$?
assert_eq "1" "$rc" \
  "#142-api Case A (no approval text): exits 1 (_github_api)"
assert_contains "$out" "no SHA marker in PR comments" \
  "#142-api Case A: existing message byte-identical (_github_api regression guard)"
assert_not_contains "$out" "found talos:approval text" \
  "#142-api Case A: near-miss message NOT shown when no approval text"

# Case B: unwrapped talos:approval sha= text -> new near-miss message.
# RED before fix: gate reported "no SHA marker" instead of naming the expected form.
: > "$CURL_LOG"
_NEAR_MISS_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
printf '%s\n' \
  "{\"number\":7,\"head\":{\"sha\":\"$_API_HEAD\"},\"base\":{\"ref\":\"main\"},\"labels\":[{\"name\":\"qa:pass\"}]}" \
  "[{\"body\":\"talos:approval sha=${_NEAR_MISS_SHA} role=qa\",\"user\":{\"login\":\"bot\"}}]" \
  > "$CURL_QUEUE"
out="$(bash "$VCS" check-approval-sha 7 2>&1)"; rc=$?
assert_eq "1" "$rc" \
  "#142-api Case B (near-miss): exits 1 (_github_api, unchanged)"
assert_contains "$out" "found talos:approval text but no valid marker" \
  "#142-api Case B: near-miss message emitted (_github_api) -- byte-identical to _github"
assert_contains "$out" "expected <!-- talos:approval sha=<40-hex-lowercase> role=<role> -->" \
  "#142-api Case B: expected form named (_github_api)"
assert_not_contains "$out" "no SHA marker in PR comments" \
  "#142-api Case B: old generic message NOT shown when near-miss present (_github_api)"

# ── unknown provider error still works (sanity) ──────────────────────────────
unset GITHUB_TOKEN GH_TOKEN
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
err="$(bash "$VCS" view-issue 3 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "github-api without token: exits 1"

# ── Issue #171: list-issues/list-prs pagination ──────────────────────────────
export GITHUB_TOKEN="$TEST_TOKEN"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF

# T171-issues-150: 150-issue backlog spread over two Link-paginated pages
# (100 + 50) returns all 150, not just the first page.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
_171_page2_url="https://api.github.com/repos/acme/widget/issues?state=open&per_page=100&page=2"
_171_p1="$(python3 -c "
import json
print(json.dumps([{'number': i, 'title': 't'+str(i), 'body': '', 'labels': []} for i in range(1, 101)]))
")"
_171_p2="$(python3 -c "
import json
print(json.dumps([{'number': i, 'title': 't'+str(i), 'body': '', 'labels': []} for i in range(101, 151)]))
")"
printf '%s\n' "$_171_page2_url" "" > "$CURL_LINK_QUEUE"
printf '%s\n' "$_171_p1" "$_171_p2" > "$CURL_QUEUE"
out="$(bash "$VCS" list-issues)"; rc=$?
_171_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
assert_eq "0" "$rc" "#171 github-api: list-issues exits 0 across pages"
assert_eq "150" "$_171_count" "#171 github-api: list-issues returns all 150 issues, not just page 1"
assert_contains "$out" '"number": 150' "#171 github-api: list-issues includes the last issue (id 150)"

# T171-issues-failed-page: page 2 returns HTTP 500 -> exit non-zero, no
# partial 100-item list printed as if it were complete.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
printf '%s\n' "$_171_page2_url" "" > "$CURL_LINK_QUEUE"
printf '%s\n' "$_171_p1" "500" > "$CURL_QUEUE"
out="$(bash "$VCS" list-issues 2>"$SANDBOX/171_err.txt")"; rc=$?
err="$(cat "$SANDBOX/171_err.txt")"
assert_eq "1" "$rc" "#171 github-api: list-issues exits non-zero when a page fails"
assert_eq "" "$out" "#171 github-api: list-issues prints no partial list on a failed page"
assert_contains "$err" "HTTP 500" "#171 github-api: list-issues names the failing HTTP status"

# T171-prs-150: same 150-item pagination proof for list-prs.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
_171_pr_page2_url="https://api.github.com/repos/acme/widget/pulls?state=open&per_page=100&page=2"
_171_pr_p1="$(python3 -c "
import json
print(json.dumps([{'number': i, 'title': 't'+str(i), 'head': {'ref': 'b'+str(i)}, 'labels': []} for i in range(1, 101)]))
")"
_171_pr_p2="$(python3 -c "
import json
print(json.dumps([{'number': i, 'title': 't'+str(i), 'head': {'ref': 'b'+str(i)}, 'labels': []} for i in range(101, 151)]))
")"
printf '%s\n' "$_171_pr_page2_url" "" > "$CURL_LINK_QUEUE"
printf '%s\n' "$_171_pr_p1" "$_171_pr_p2" > "$CURL_QUEUE"
out="$(bash "$VCS" list-prs)"; rc=$?
_171_pr_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
assert_eq "0" "$rc" "#171 github-api: list-prs exits 0 across pages"
assert_eq "150" "$_171_pr_count" "#171 github-api: list-prs returns all 150 PRs, not just page 1"
assert_contains "$out" '"number": 150' "#171 github-api: list-prs includes the last PR (id 150)"

# ── Issue #172: record-attempt --idempotency-key idempotency (github-api) ───
export GITHUB_TOKEN="$TEST_TOKEN"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "limits": {"max_fix_attempts": 3, "max_total_dispatches": 8}}
EOF

# First call with a key: posts normally, marker on the wire carries key=<token>.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
printf '%s\n%s\n' \
  '[]' \
  '{"id":900,"html_url":"https://github.com/acme/widget/issues/42#issuecomment-900"}' \
  > "$CURL_QUEUE"
out_g_idem1="$(bash "$VCS" record-attempt 42 qa --idempotency-key run-abc123 2>/dev/null)"; rc_g_idem1=$?
assert_eq "0" "$rc_g_idem1" "#172 github-api: idempotency-key first call exits 0"
assert_contains "$out_g_idem1" "count=1" "#172 github-api: idempotency-key first call count=1"
assert_contains "$(cat "$CURL_LOG")" "key=run-abc123" \
  "#172 github-api: idempotency-key first call marker carries the key"

# Second call, same key, against a prior marker that already carries it:
# does NOT post again -- count stays 1, not 2.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
printf '%s\n' \
  '[{"body":"<!-- talos:attempt stage=qa count=1 total=1 key=run-abc123 -->","user":{"login":"bot"}}]' \
  > "$CURL_QUEUE"
out_g_idem2="$(bash "$VCS" record-attempt 42 qa --idempotency-key run-abc123 2>/dev/null)"; rc_g_idem2=$?
assert_eq "0" "$rc_g_idem2" "#172 github-api: idempotency-key second call (same key) exits 0"
assert_contains "$out_g_idem2" "count=1" \
  "#172 github-api: idempotency-key second call count stays 1, not 2"
_g_idem2_log="$(cat "$CURL_LOG")"
assert_not_contains "$_g_idem2_log" $'\t{"body"' \
  "#172 github-api: idempotency-key second call posts no new comment"

# Invalid token rejected, exit 1, nothing posted.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
out_g_idem3="$(bash "$VCS" record-attempt 42 qa --idempotency-key 'bad key!' 2>&1)"; rc_g_idem3=$?
assert_eq "1" "$rc_g_idem3" "#172 github-api: invalid idempotency-key exits 1"
assert_eq "" "$(cat "$CURL_LOG")" "#172 github-api: invalid idempotency-key makes no curl call"

# ── Issue #172 QA follow-up: record-attempt --pr <pr-n> (github-api) ────────
# Retry-stable key derived server-side from the PR head SHA -- SKILL.md's
# qa/reviewer/security call sites now pass --pr instead of hand-minting a
# token with $(date +%s), which re-evaluated on every separate Bash
# invocation and reproduced the #172 double-post bug on retry (PR #193 QA).
_PR2_SHA1="aabb1122ccdd3344eeff556677889900aabb1122"
_PR2_SHA2="00112233445566778899aabbccddeeff00112233"

# The exact SKILL.md command form ("record-attempt <N> qa --pr <PR_NUMBER>"),
# run twice in two SEPARATE `bash -c` invocations (no shared shell state --
# the same harness gap the old $(date +%s) form fell into). Queue order per
# call: GET pulls/9 (pr-head), GET comments, POST comment.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
printf '%s\n%s\n%s\n' \
  "{\"head\":{\"sha\":\"$_PR2_SHA1\"}}" \
  '[]' \
  '{"id":901,"html_url":"https://github.com/acme/widget/issues/42#issuecomment-901"}' \
  > "$CURL_QUEUE"
out_g_pr1="$(bash -c 'bash "$0" record-attempt 42 qa --pr 9' "$VCS" 2>/dev/null)"; rc_g_pr1=$?
assert_eq "0" "$rc_g_pr1" "#172 github-api: --pr first call (bash -c #1) exits 0"
assert_contains "$out_g_pr1" "count=1" "#172 github-api: --pr first call (bash -c #1) count=1"
assert_contains "$(cat "$CURL_LOG")" "pulls/9" "#172 github-api: --pr first call resolved head via pulls/9"
assert_contains "$(cat "$CURL_LOG")" "key=qa-${_PR2_SHA1}" \
  "#172 github-api: --pr first call marker carries stage-sha key"

# Retry at the SAME head, in a second SEPARATE bash -c invocation, against
# comment state that already carries the marker call #1 posted: does not
# post again, count stays N+1 (1), not N+2 (2).
_g_pr_prior="[{\"body\":\"<!-- talos:attempt stage=qa count=1 total=1 key=qa-${_PR2_SHA1} -->\",\"user\":{\"login\":\"bot\"}}]"
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
printf '%s\n%s\n' \
  "{\"head\":{\"sha\":\"$_PR2_SHA1\"}}" \
  "$_g_pr_prior" \
  > "$CURL_QUEUE"
out_g_pr2="$(bash -c 'bash "$0" record-attempt 42 qa --pr 9' "$VCS" 2>/dev/null)"; rc_g_pr2=$?
assert_eq "0" "$rc_g_pr2" "#172 github-api: --pr retry (bash -c #2, same head) exits 0"
assert_contains "$out_g_pr2" "count=1" \
  "#172 github-api: --pr retry (bash -c #2, same head) count stays N+1 (1), not N+2 (2)"
_g_pr2_log="$(cat "$CURL_LOG")"
assert_not_contains "$_g_pr2_log" $'\t{"body"' \
  "#172 github-api: --pr retry (bash -c #2, same head) posts no new comment"

# A NEW head SHA (genuinely new commit) yields a different key and DOES
# increment, against that same prior marker.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
printf '%s\n%s\n%s\n' \
  "{\"head\":{\"sha\":\"$_PR2_SHA2\"}}" \
  "$_g_pr_prior" \
  '{"id":902,"html_url":"https://github.com/acme/widget/issues/42#issuecomment-902"}' \
  > "$CURL_QUEUE"
out_g_pr3="$(bash "$VCS" record-attempt 42 qa --pr 9 2>/dev/null)"; rc_g_pr3=$?
assert_eq "0" "$rc_g_pr3" "#172 github-api: --pr new head exits 0"
assert_contains "$out_g_pr3" "count=2" \
  "#172 github-api: --pr new head count increments to 2 (new key, new attempt)"
assert_contains "$(cat "$CURL_LOG")" "key=qa-${_PR2_SHA2}" \
  "#172 github-api: --pr new head posts a new marker keyed on the new head SHA"

# --pr and --idempotency-key together are rejected.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
out_g_pr_both="$(bash "$VCS" record-attempt 42 qa --pr 9 --idempotency-key run-abc123 2>&1)"; rc_g_pr_both=$?
assert_eq "1" "$rc_g_pr_both" "#172 github-api: --pr with --idempotency-key exits 1"
assert_contains "$out_g_pr_both" "mutually exclusive" \
  "#172 github-api: --pr with --idempotency-key error names the conflict"
assert_eq "" "$(cat "$CURL_LOG")" "#172 github-api: --pr with --idempotency-key makes no curl call"

# Unresolvable head SHA fails closed -- exit 1, nothing posted.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
printf '%s\n' '{"head":{}}' > "$CURL_QUEUE"
out_g_pr_nohead="$(bash "$VCS" record-attempt 42 qa --pr 404 2>&1)"; rc_g_pr_nohead=$?
assert_eq "1" "$rc_g_pr_nohead" "#172 github-api: --pr unresolvable head exits 1"
assert_not_contains "$(cat "$CURL_LOG")" $'\t{"body"' \
  "#172 github-api: --pr unresolvable head posts nothing"

# ── Issue #172: post-approval duplicate-marker detection, 150 comments,
#    marker on page 2 (github-api) ───────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
_172_SHA="cc00112233445566778899aabbccddeeff001122"
_172_page2_url="https://api.github.com/repos/acme/widget/issues/9/comments?per_page=100&page=2"
_172_p1="$(python3 -c "
import json
print(json.dumps([{'body': 'comment ' + str(i), 'user': {'login': 'someone'}} for i in range(100)]))
")"
_172_p2="$(python3 -c "
import json
c = [{'body': 'comment ' + str(i), 'user': {'login': 'someone'}} for i in range(49)]
c.append({'body': '<!-- talos:approval sha=${_172_SHA} role=qa -->', 'user': {'login': 'bot'}})
print(json.dumps(c))
")"

: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
printf '%s\n' "{\"head\":{\"sha\":\"$_172_SHA\"}}" > "$CURL_QUEUE"
printf '%s\n' "$_172_p1" >> "$CURL_QUEUE"
# CURL_LINK_QUEUE is popped on EVERY curl call, not just paginated ones -- the
# leading empty line accounts for the preceding pr-head GET (no Link header).
printf '%s\n' "" "$_172_page2_url" "" > "$CURL_LINK_QUEUE"
printf '%s\n' "$_172_p2" >> "$CURL_QUEUE"
# duplicate found -> label-pr still runs defensively (get labels + put)
printf '%s\n' '[]' '{"labels":[{"name":"qa:pass"}]}' >> "$CURL_QUEUE"
out_g_pa150="$(bash "$VCS" post-approval 9 qa 2>&1)"; rc_g_pa150=$?
assert_eq "0" "$rc_g_pa150" "#172 github-api T-pagination-150: post-approval exits 0 (marker on page 2)"
assert_contains "$out_g_pa150" "already exists" \
  "#172 github-api T-pagination-150: reports the marker already exists"
_g_pa150_log="$(cat "$CURL_LOG")"
assert_not_contains "$_g_pa150_log" $'\t{"body"' \
  "#172 github-api T-pagination-150: no comment POST logged (zero POSTs)"

# A failed page during the duplicate check fails closed: non-zero, nothing posted.
: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
printf '%s\n' "{\"head\":{\"sha\":\"$_172_SHA\"}}" > "$CURL_QUEUE"
printf '999\n' >> "$CURL_QUEUE"
out_g_pafail="$(bash "$VCS" post-approval 9 qa 2>&1)"; rc_g_pafail=$?
assert_eq "1" "$rc_g_pafail" "#172 github-api: failed duplicate-check page exits non-zero"
_g_pafail_log="$(cat "$CURL_LOG")"
assert_not_contains "$_g_pafail_log" $'\t{"body"' \
  "#172 github-api: failed duplicate-check page posts nothing"

unset GITHUB_TOKEN

finish
