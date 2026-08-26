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
           bash "$VCS" --dry-run rerun-ci 9)"

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

export GITHUB_TOKEN="$TEST_TOKEN"

# ═══════════════════════════════════════════════════════════════════════════════
# NEW VERBS: pr-head, read-attempt, check-attempt, record-attempt,
#            check-approval-sha, check-closing-keyword
# ═══════════════════════════════════════════════════════════════════════════════

# ── Git setup for SHA-based tests ─────────────────────────────────────────────
git -C "$SANDBOX" config user.email "test@talos.invalid"
git -C "$SANDBOX" config user.name "talos-test"
printf 'initial\n' > "$SANDBOX/feature.txt"
git -C "$SANDBOX" add "$SANDBOX/feature.txt"
git -C "$SANDBOX" commit -q -m "initial commit"
SHA_A="$(git -C "$SANDBOX" rev-parse HEAD)"
printf 'readme\n' > "$SANDBOX/README.md"
git -C "$SANDBOX" add "$SANDBOX/README.md"
git -C "$SANDBOX" commit -q -m "docs: readme"
SHA_B="$(git -C "$SANDBOX" rev-parse HEAD)"

# ── pr-head: pass — returns head SHA ─────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":9,"head":{"sha":"'"$SHA_B"'"},"base":{"ref":"main"},"labels":[]}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" pr-head 9 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "pr-head: exits 0 on success"
assert_eq "$SHA_B" "$out"                        "pr-head: returns head SHA from REST"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "Authorization: Bearer"   "pr-head: auth header sent"

# ── pr-head: fail — head sha empty → exit 1 ──────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' '{"number":9,"head":{"sha":""},"labels":[]}' > "$CURL_QUEUE"

err="$(bash "$VCS" pr-head 9 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "pr-head: empty SHA exits 1"
assert_contains "$err" "could not resolve head SHA" "pr-head: error message on empty SHA"

# ── pr-head: dry-run ──────────────────────────────────────────────────────────
: > "$CURL_LOG"; : > "$CURL_QUEUE"
out="$(bash "$VCS" --dry-run pr-head 9 2>&1)"
assert_contains "$out" "[dry-run]"               "pr-head: dry-run prints [dry-run]"
assert_eq "" "$(cat "$CURL_LOG")"                "pr-head: dry-run makes no curl calls"

# ── read-attempt: no marker → zero counts, exit 0 ─────────────────────────────
: > "$CURL_LOG"
printf '[]' > "$CURL_QUEUE"

out="$(bash "$VCS" read-attempt 42 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "read-attempt: no marker exits 0"
assert_contains "$out" "count=0"                 "read-attempt: no marker count=0"
assert_contains "$out" "total=0"                 "read-attempt: no marker total=0"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "/issues/42/comments"     "read-attempt: fetched issue comments via REST"

# ── read-attempt: with marker, exit 0 ────────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"id":1,"body":"Talos attempt record\n<!-- talos:attempt stage=developer count=2 total=3 -->","user":{"login":"bot-user"}}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" read-attempt 42 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "read-attempt: marker found exits 0"
assert_contains "$out" "stage=developer"         "read-attempt: stage extracted"
assert_contains "$out" "count=2"                 "read-attempt: count extracted"
assert_contains "$out" "total=3"                 "read-attempt: total extracted"

# ── read-attempt: user.login normalisation ─────────────────────────────────────
# When markers.trusted_authors is configured, user.login must be mapped to
# author.login or the author check would reject the marker and return count=0.
: > "$CURL_LOG"
PARITY_CONFIG="$SANDBOX/parity-config.json"
printf '{"vcs":{"provider":"github-api","repo":"acme/widget"},"markers":{"trusted_authors":["bot-user"]}}' \
  > "$PARITY_CONFIG"
printf '%s\n' \
  '[{"id":1,"body":"Talos attempt record\n<!-- talos:attempt stage=qa count=1 total=1 -->","user":{"login":"bot-user"}}]' \
  > "$CURL_QUEUE"

out="$(PIPELINE_CONFIG="$PARITY_CONFIG" bash "$VCS" read-attempt 42 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "read-attempt: user.login normalised → exit 0"
assert_contains "$out" "stage=qa"                "read-attempt: user.login normalised → marker found"

# ── read-attempt: missing issue number → exit 1 ───────────────────────────────
err="$(bash "$VCS" read-attempt 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "read-attempt: missing issue number exits 1"
assert_contains "$err" "missing issue number"    "read-attempt: clear error message"

# ── read-attempt: dry-run ─────────────────────────────────────────────────────
: > "$CURL_LOG"; : > "$CURL_QUEUE"
out="$(bash "$VCS" --dry-run read-attempt 42 2>&1)"
assert_contains "$out" "[dry-run]"               "read-attempt: dry-run prints [dry-run]"
assert_eq "" "$(cat "$CURL_LOG")"                "read-attempt: dry-run makes no curl calls"

# ── check-attempt: pass — below ceiling ───────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '[{"id":1,"body":"Talos attempt record\n<!-- talos:attempt stage=developer count=1 total=2 -->","user":{"login":"bot"}}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" check-attempt 42 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "check-attempt: below ceiling exits 0"
assert_contains "$out" "check-attempt: ok"       "check-attempt: ok message on stdout"

# ── check-attempt: fail — total ceiling reached ───────────────────────────────
: > "$CURL_LOG"
# max_total_dispatches default = 8
printf '%s\n' \
  '[{"id":1,"body":"Talos attempt record\n<!-- talos:attempt stage=developer count=1 total=8 -->","user":{"login":"bot"}}]' \
  > "$CURL_QUEUE"

err="$(bash "$VCS" check-attempt 42 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "check-attempt: total ceiling exits 1"
assert_contains "$err" "BLOCKED"                 "check-attempt: blocked message on stderr"
assert_contains "$err" "total dispatches"        "check-attempt: explains total ceiling"

# ── check-attempt: dry-run ────────────────────────────────────────────────────
: > "$CURL_LOG"; : > "$CURL_QUEUE"
out="$(bash "$VCS" --dry-run check-attempt 42 2>&1)"
assert_contains "$out" "[dry-run]"               "check-attempt: dry-run prints [dry-run]"
assert_eq "" "$(cat "$CURL_LOG")"                "check-attempt: dry-run makes no curl calls"

# ── record-attempt: pass — posts comment, prints state ────────────────────────
: > "$CURL_LOG"
# CURL_QUEUE entry 1: read-attempt GET /issues/42/comments (no prior marker)
# CURL_QUEUE entry 2: POST /issues/42/comments response
printf '%s\n' \
  '[]' \
  '{"id":200,"html_url":"https://github.com/acme/widget/issues/42#issuecomment-200"}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" record-attempt 42 developer 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "record-attempt: first attempt exits 0"
assert_contains "$out" "stage=developer"         "record-attempt: stage in stdout"
assert_contains "$out" "count=1"                 "record-attempt: count=1 in stdout"
assert_contains "$out" "total=1"                 "record-attempt: total=1 in stdout"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "/issues/42/comments"     "record-attempt: GET and POST on /issues/42/comments"

# ── record-attempt: fail — stage ceiling after recording ─────────────────────
: > "$CURL_LOG"
# prior marker: developer count=2 total=5 (count=2 → after increment → count=3 >= max_stage=3)
printf '%s\n' \
  '[{"id":1,"body":"Talos attempt record\n<!-- talos:attempt stage=developer count=2 total=5 -->","user":{"login":"bot"}}]' \
  '{"id":201,"html_url":"https://github.com/acme/widget/issues/42#issuecomment-201"}' \
  > "$CURL_QUEUE"

err="$(bash "$VCS" record-attempt 42 developer 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "record-attempt: ceiling hit exits 1"
assert_contains "$err" "BLOCKED"                 "record-attempt: blocked message on stderr"

# ── record-attempt: dry-run ───────────────────────────────────────────────────
: > "$CURL_LOG"; : > "$CURL_QUEUE"
out="$(bash "$VCS" --dry-run record-attempt 42 developer 2>&1)"
assert_contains "$out" "[dry-run]"               "record-attempt: dry-run prints [dry-run]"
assert_eq "" "$(cat "$CURL_LOG")"                "record-attempt: dry-run makes no curl calls"

# ── record-attempt: exit-zero proof ───────────────────────────────────────────
# Mutation: if record-attempt exits 1 unconditionally, this fails.
: > "$CURL_LOG"
printf '%s\n' \
  '[]' \
  '{"id":202,"html_url":"https://github.com/acme/widget/issues/42#issuecomment-202"}' \
  > "$CURL_QUEUE"
out2="$(bash "$VCS" record-attempt 42 qa 2>&1)"; rc2=$?
assert_eq "0" "$rc2"                             "record-attempt: exit-zero proof — first qa attempt"

# ── check-approval-sha: no labels → exit 0 ───────────────────────────────────
: > "$CURL_LOG"
# GET /pulls/9 (no labels), GET /issues/9/comments (empty)
printf '%s\n' \
  '{"number":9,"head":{"sha":"'"$SHA_B"'"},"base":{"ref":"main"},"labels":[]}' \
  '[]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "check-approval-sha: no labels exits 0"
assert_contains "$out" "no approval labels"      "check-approval-sha: no labels message"

# ── check-approval-sha: pass — marker matches head SHA ───────────────────────
: > "$CURL_LOG"
MARKER_BODY="approval done\n<!-- talos:approval sha=${SHA_B} role=qa -->"
printf '%s\n' \
  '{"number":9,"head":{"sha":"'"$SHA_B"'"},"base":{"ref":"main"},"labels":[{"name":"qa:pass"}]}' \
  '[{"id":1,"body":"'"$MARKER_BODY"'","user":{"login":"bot"}}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "check-approval-sha: matching SHA exits 0"
assert_contains "$out" "all approval labels are current" "check-approval-sha: pass message"

# ── check-approval-sha: byte-identical pass message vs _github provider ────────
# _github uses gh stub; _github_api uses curl stub. Both should print the same string.
: > "$CURL_LOG"
STUB_PR_HEAD_SHA="$SHA_B" \
STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]' \
STUB_PR_COMMENTS_JSON='[{"body":"approval done\n<!-- talos:approval sha='"$SHA_B"' role=qa -->"}]' \
STUB_PR_BASE_REF_NAME="main" \
bash "$TALOS_ROOT/scripts/pipeline-vcs.sh" --dry-run check-approval-sha 9 >/dev/null 2>&1 || true
# Use github provider to get reference message
cat > "$SANDBOX/gh-config.json" <<EOF
{"vcs": {"provider": "github", "repo": "acme/widget"}}
EOF
GITHUB_PASS_MSG="$(STUB_PR_HEAD_SHA="$SHA_B" \
  STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]' \
  STUB_PR_COMMENTS_JSON='[{"body":"approval done\n<!-- talos:approval sha='"$SHA_B"' role=qa -->"}]' \
  STUB_PR_BASE_REF_NAME="main" \
  PIPELINE_CONFIG="$SANDBOX/gh-config.json" \
  bash "$VCS" check-approval-sha 9 2>/dev/null)"

: > "$CURL_LOG"
printf '%s\n' \
  '{"number":9,"head":{"sha":"'"$SHA_B"'"},"base":{"ref":"main"},"labels":[{"name":"qa:pass"}]}' \
  '[{"id":1,"body":"'"$MARKER_BODY"'","user":{"login":"bot"}}]' \
  > "$CURL_QUEUE"
API_PASS_MSG="$(bash "$VCS" check-approval-sha 9 2>/dev/null)"

assert_eq "$GITHUB_PASS_MSG" "$API_PASS_MSG"     "check-approval-sha: byte-identical pass message between providers"

# ── check-approval-sha: fail — abbreviated SHA ────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":9,"head":{"sha":"'"$SHA_B"'"},"base":{"ref":"main"},"labels":[{"name":"qa:pass"}]}' \
  '[{"id":1,"body":"approval\n<!-- talos:approval sha=abc1234 role=qa -->","user":{"login":"bot"}}]' \
  > "$CURL_QUEUE"

err="$(bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "check-approval-sha: abbreviated SHA exits 1"
assert_contains "$err" "STALE"                   "check-approval-sha: stale label reported for abbreviated SHA"

# ── check-approval-sha: fail — no marker ─────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":9,"head":{"sha":"'"$SHA_B"'"},"base":{"ref":"main"},"labels":[{"name":"qa:pass"}]}' \
  '[{"id":1,"body":"no marker here","user":{"login":"bot"}}]' \
  > "$CURL_QUEUE"

err="$(bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "check-approval-sha: no marker exits 1"
assert_contains "$err" "no SHA marker"           "check-approval-sha: explains missing marker"

# ── check-approval-sha: dry-run ───────────────────────────────────────────────
: > "$CURL_LOG"; : > "$CURL_QUEUE"
out="$(bash "$VCS" --dry-run check-approval-sha 9 2>&1)"
assert_contains "$out" "[dry-run]"               "check-approval-sha: dry-run prints [dry-run]"
assert_eq "" "$(cat "$CURL_LOG")"                "check-approval-sha: dry-run makes no curl calls"

# ── check-approval-sha: exit-zero proof ───────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":9,"head":{"sha":"'"$SHA_B"'"},"base":{"ref":"main"},"labels":[]}' \
  '[]' \
  > "$CURL_QUEUE"
out3="$(bash "$VCS" check-approval-sha 9 2>&1)"; rc3=$?
assert_eq "0" "$rc3"                             "check-approval-sha: exit-zero proof (no labels)"

# ── check-closing-keyword: no closing keyword → exit 0 ───────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":9,"head":{"sha":"'"$SHA_B"'","ref":"fix/issue-42"},"base":{"ref":"main"},"body":"Part of #42","labels":[]}' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "check-closing-keyword: no closing keyword exits 0"

# ── check-closing-keyword: closing keyword + no siblings → exit 0 ────────────
: > "$CURL_LOG"
# GET /pulls/9 → has "Closes #42" in body
# GET /pulls?state=open → only this PR (no siblings)
printf '%s\n' \
  '{"number":9,"head":{"sha":"'"$SHA_B"'","ref":"fix/issue-42"},"base":{"ref":"main"},"body":"Closes #42","labels":[]}' \
  '[{"number":9,"title":"fix","head":{"ref":"fix/issue-42"},"body":"Closes #42","state":"open"}]' \
  > "$CURL_QUEUE"

out="$(bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "check-closing-keyword: sole PR with closing keyword exits 0"

# ── check-closing-keyword: closing keyword + open siblings → exit 1 ──────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":9,"head":{"sha":"'"$SHA_B"'","ref":"fix/issue-42-auth"},"base":{"ref":"main"},"body":"Closes #42","labels":[]}' \
  '[{"number":9,"title":"fix auth","head":{"ref":"fix/issue-42-auth"},"body":"Closes #42","state":"open"},{"number":10,"title":"fix ui","head":{"ref":"fix/issue-42-ui"},"body":"also #42","state":"open"}]' \
  > "$CURL_QUEUE"

err="$(bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_eq "1" "$rc"                              "check-closing-keyword: open sibling exits 1"
assert_contains "$err" "sibling PR"              "check-closing-keyword: mentions sibling PRs"

# ── check-closing-keyword: dry-run ───────────────────────────────────────────
: > "$CURL_LOG"; : > "$CURL_QUEUE"
out="$(bash "$VCS" --dry-run check-closing-keyword 9 42 2>&1)"
assert_contains "$out" "[dry-run]"               "check-closing-keyword: dry-run prints [dry-run]"
assert_eq "" "$(cat "$CURL_LOG")"                "check-closing-keyword: dry-run makes no curl calls"

# ── check-closing-keyword: exit-zero proof ────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' \
  '{"number":9,"head":{"sha":"'"$SHA_B"'","ref":"fix/issue-42"},"base":{"ref":"main"},"body":"Part of #42","labels":[]}' \
  > "$CURL_QUEUE"
out4="$(bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc4=$?
assert_eq "0" "$rc4"                             "check-closing-keyword: exit-zero proof (no closing keyword)"

# ── dry-run: all 6 new verbs print [dry-run] and never invoke curl ─────────────
: > "$CURL_LOG"
: > "$CURL_QUEUE"

new_dry_out="$(bash "$VCS" --dry-run pr-head 9; \
               bash "$VCS" --dry-run read-attempt 42; \
               bash "$VCS" --dry-run check-attempt 42; \
               bash "$VCS" --dry-run record-attempt 42 developer; \
               bash "$VCS" --dry-run check-approval-sha 9; \
               bash "$VCS" --dry-run check-closing-keyword 9 42)"

assert_contains "$new_dry_out" "[dry-run]"       "dry-run (new verbs): all print [dry-run]"
assert_eq "" "$(cat "$CURL_LOG")"                "dry-run (new verbs): no curl calls made"

# ── label-pr → check-approval-sha routing under github-api ───────────────────
# After label-pr adds an approval label, the post-dispatch guard calls
# check-approval-sha. With no marker in place, a WARNING is printed.
: > "$CURL_LOG"
# CURL_QUEUE:
#   1. GET /issues/9/labels   (label-pr GET)
#   2. PUT /issues/9/labels   (label-pr PUT)
#   3. GET /pulls/9           (check-approval-sha)
#   4. GET /issues/9/comments (check-approval-sha)
printf '%s\n' \
  '[{"id":1,"name":"pipeline:review","color":"0075ca"}]' \
  '[{"id":1,"name":"pipeline:review"},{"id":2,"name":"qa:pass"}]' \
  '{"number":9,"head":{"sha":"'"$SHA_B"'"},"base":{"ref":"main"},"labels":[{"name":"qa:pass"}]}' \
  '[{"id":1,"body":"no marker","user":{"login":"bot"}}]' \
  > "$CURL_QUEUE"

warn="$(bash "$VCS" label-pr 9 --add qa:pass 2>&1)"; rc=$?
assert_eq "0" "$rc"                              "label-pr→check-approval-sha: label-pr exits 0"
assert_contains "$warn" "WARNING"                "label-pr→check-approval-sha: WARNING printed when no marker"
assert_contains "$warn" "no approval marker"     "label-pr→check-approval-sha: explains missing marker"
log="$(cat "$CURL_LOG")"
assert_contains "$log" "/pulls/9"                "label-pr→check-approval-sha: check-approval-sha called (GET /pulls)"

finish
