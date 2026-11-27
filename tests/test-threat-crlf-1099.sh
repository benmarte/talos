#!/usr/bin/env bash
# test-threat-crlf-1099.sh -- line endings never decide whether a spec has a
# threat model (#1099).
#   AC1  a spec whose `## Threat model` line ends in CRLF routes to the developer
#   AC2  `post-threat-model` takes a CRLF section and posts no carriage return
#   AC3  an LF spec still routes to the developer
# The real talos.sh and pipeline-vcs.sh run against the gh stub's stateful
# comment store: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
export STUB_CURRENT_USER=x
export STUB_ISSUE_TITLE="Login hardening"
export STUB_ISSUE_BODY="Plain body."
export STUB_ISSUE_LABELS_JSON='[{"name": "pipeline:dev"}]'
export STUB_COMMENT_STORE="$SANDBOX/comments.json"
ERR="$SANDBOX/stderr"

# ── fixture: a copy of the install, only the provider-free scripts stubbed ───
GS="$SANDBOX/scripts"
mkdir -p "$GS" "$SANDBOX/templates" "$SANDBOX/agents"
cp "$TALOS_ROOT"/scripts/* "$GS/" 2>/dev/null
cp -R "$TALOS_ROOT"/templates/. "$SANDBOX/templates/"
cp "$TALOS_ROOT"/agents/*.md "$SANDBOX/agents/"
TN="$GS/talos.sh"
VCS="$GS/pipeline-vcs.sh"
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusHk7pWm2Xd'
#!/usr/bin/env bash
printf '%s' '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}'
exit 0
TALOS_stubstatusHk7pWm2Xd
for s in pipeline-notify.sh pipeline-hooks.sh pipeline-status.sh pipeline-events.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$GS/$s"
done

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '%s\n' '{"vcs": {"provider": "github", "repo": "acme/widget"}, "comments": {"enabled": false}, "issues": {"max_parallel": 4}, "roles": {"validator": true, "planner": false, "pm": true, "pm_skip_when_spec_present": false}, "pipeline": {"risk_areas": ["auth/authz/MFA"]}}' > "$PIPELINE_CONFIG"

SPEC="**PM spec:** login

**Acceptance criteria:**
- [ ] AC1 a login with a bad MFA code is refused (test)

**Goal:** harden the auth/authz/MFA path.

**Tests:** \`tests/test-login.sh\`"
SECTION="## Threat model
- [ ] AC2 a replayed MFA code is refused (test)"
SPEC_MODEL="$SPEC

$SECTION"

# crlf TEXT / cr TEXT: the text with CRLF, or lone CR, line endings.
crlf() { printf '%s' "${1//$'\n'/$'\r\n'}"; }
cr() { printf '%s' "${1//$'\n'/$'\r'}"; }

# thread BODY...: the issue's comments, oldest first, by the account Talos runs
# as; the comment id is its 1-based position.
thread() {
  python3 -I -c '
import json, sys
json.dump([dict(id=i + 1, user=dict(login="x"), created_at="2026-01-%02dT00:00:00Z" % (i + 1), body=b)
           for i, b in enumerate(sys.argv[2:])], open(sys.argv[1], "w"))' "$STUB_COMMENT_STORE" "$@"
}
# last_body: how many comments there are, the carriage returns in the last one,
# and whether it reads exactly as $1.
last_body() {
  python3 -I -c '
import json, sys
items = json.load(open(sys.argv[1]))
body = items[-1]["body"]
print("comments=%d cr=%d same=%s" % (len(items), body.count("\r"), "yes" if body.rstrip("\n") == sys.argv[2] else "no"))
' "$STUB_COMMENT_STORE" "$1"
}
nx() { reset_leases; OUT="$(bash "$TN" next --issue 22 2>"$ERR")"; RC=$?; }
# ptm SECTION: post-threat-model with the section on stdin.
ptm() { OUT="$(printf '%s\n' "$1" | bash "$VCS" post-threat-model 22 --body-file - 2>"$ERR")"; RC=$?; }

# ── AC1: a CRLF spec has its threat model ────────────────────────────────────
thread "$(crlf "$SPEC_MODEL")"
nx
assert_eq_ctx "action=dispatch stage=developer issue=22" "$OUT" "AC1 a CRLF ## Threat model line routes to the developer" "$(cat "$ERR")"
# The heading is the spec's last line, so only its own line ending follows it.
thread "$(crlf "$SPEC
## Threat model
none found")"
nx
assert_eq_ctx "action=dispatch stage=developer issue=22" "$OUT" "AC1 a CRLF heading with trailing blanks or text below it routes to the developer" "$(cat "$ERR")"

# ── AC2: a CRLF section is accepted and posted as LF ─────────────────────────
thread "$SPEC"
ptm "$(crlf "$SECTION")"$'\r'
assert_eq_ctx "0" "$RC" "AC2 post-threat-model accepts a CRLF section" "$(cat "$ERR")"
assert_eq "comments=2 cr=0 same=yes" "$(last_body "$SPEC_MODEL")" "AC2 the posted comment holds no carriage return"
thread "$SPEC"
ptm "$(cr "$SECTION")"
assert_eq_ctx "0" "$RC" "AC2 post-threat-model accepts a lone-CR section" "$(cat "$ERR")"
assert_eq "comments=2 cr=0 same=yes" "$(last_body "$SPEC_MODEL")" "AC2 a lone-CR section is posted as LF"
# A spec pasted from Windows: the posted comment still has one line-ending style.
thread "$(crlf "$SPEC")"
ptm "$(crlf "$SECTION")"
assert_eq_ctx "0" "$RC" "AC2 post-threat-model accepts a CRLF section on a CRLF spec" "$(cat "$ERR")"
assert_eq "comments=2 cr=0 same=yes" "$(last_body "$SPEC_MODEL")" "AC2 a CRLF spec above the section is posted as LF"

# ── AC3: LF specs already work ───────────────────────────────────────────────
thread "$SPEC_MODEL"
nx
assert_eq_ctx "action=dispatch stage=developer issue=22" "$OUT" "AC3 an LF ## Threat model line routes to the developer" "$(cat "$ERR")"

finish
