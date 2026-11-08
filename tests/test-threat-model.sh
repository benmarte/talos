#!/usr/bin/env bash
# test-threat-model.sh -- the threat-model stage (#837): after the PM spec and
# before the developer, an issue that touches a configured risk area
# (`pipeline.risk_areas`) gets a design-mode security pass on the spec; the
# findings land in the spec as `## Threat model` acceptance criteria.
#   AC1-AC4  `next --issue <N>`: the developer route answers stage=threat
#   AC5      `prompt threat` and `done threat` (no verdict)
#   AC6      `pipeline-agent.sh` resolves the `threat` role
#   AC7      `pipeline.risk_areas` in the defaults table
#   AC8      `pipeline-criteria.sh ids|map` read the appended section
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
ERR="$SANDBOX/stderr"

# ── fixture: a copy of the install with a stubbed provider ───────────────────
GS="$SANDBOX/scripts"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates" "$SANDBOX/agents"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT"/templates/. "$SANDBOX/templates/"
cp "$TALOS_ROOT"/agents/*.md "$SANDBOX/agents/"
TN="$GS/talos.sh"

cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusVb3nQx7Zt'
#!/usr/bin/env bash
printf '%s' "$(cat "${STUB_DIR:?}/collect.json" 2>/dev/null || echo '{}')"
exit 0
TALOS_stubstatusVb3nQx7Zt
# The provider stub: <verb>.<a1>.json / <verb>.json hold stdout, .rc the exit
# code; a `--body-file <path>` is copied to $STUB_DIR/body; every call is logged.
cat > "$GS/pipeline-vcs.sh" <<'TALOS_stubvcsHm6yRk2Wp'
#!/usr/bin/env bash
FX="${STUB_DIR:?}"
verb="$1"; shift
printf '%s %s\n' "$verb" "$*" >> "$FX/journal"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ] && [ -f "$a" ]; then cat "$a" > "$FX/body"; fi
  prev="$a"
done
key="$verb.${1:-}"
[ -e "$FX/$key.json" ] || [ -e "$FX/$key.rc" ] || key="$verb"
[ -f "$FX/$key.json" ] && cat "$FX/$key.json"
[ -f "$FX/$key.rc" ] && exit "$(cat "$FX/$key.rc")"
exit 0
TALOS_stubvcsHm6yRk2Wp
for s in pipeline-notify.sh pipeline-hooks.sh pipeline-status.sh pipeline-events.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$GS/$s"
done

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
AREAS='["tenant data", "auth/authz/MFA", "credentials", "isolation", "migrations", "egress", "approval/go-live gates"]'
# cfg <risk_areas JSON|-> <roles JSON>: the sandbox config.
cfg() {
  local _pipe=""
  [ "$1" = "-" ] || _pipe=", \"pipeline\": {\"risk_areas\": $1}"
  printf '{"vcs": {"provider": "github"}, "comments": {"enabled": false}, "issues": {"max_parallel": 4}, "roles": %s%s}' \
    "${2:-{\}}" "$_pipe" > "$PIPELINE_CONFIG"
}
ROLES_ALL='{"validator": true, "planner": false, "pm": true, "developer": true, "pm_skip_when_spec_present": false}'
reset_stubs() { rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"; }
LEASE="$SANDBOX/.git/talos-lease.ledger"
LEASE_RESET() { rm -f "$LEASE" "${LEASE:?}.lock.d"; }
printf '{"timestamp": "2026-10-11T10:00:00Z", "message": {"id": "m1", "usage": {"input_tokens": 5, "cache_read_input_tokens": 1000, "output_tokens": 50}}}\n' > "$SANDBOX/session.jsonl"
export TALOS_TRANSCRIPT_PATH="$SANDBOX/session.jsonl"

# issue <n> <labels,> <title> <body> [<spec text>]: view-issue answers for #n
# (the thread and `--spec` read the same file; the spec is its only comment).
issue() {
  python3 -I -c "
import json, sys
n, labels, title, body, spec = sys.argv[1:6]
d = {'number': int(n), 'title': title, 'body': body,
     'labels': [{'name': x} for x in labels.split(',') if x],
     'comments': [{'body': spec}] if spec else []}
print(json.dumps(d))" "$1" "$2" "$3" "$4" "${5:-}" > "$STUB_DIR/view-issue.$1.json"
}
# open_state <prs JSON> <queued...>
open_state() {
  local _prs="$1"; shift
  printf '{"prs": %s, "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}' "$_prs" > "$STUB_DIR/collect.json"
}
nxi() { LEASE_RESET; OUT="$(bash "$TN" next --issue "$@" 2>"$ERR")"; RC=$?; }

SPEC_PLAIN='**PM spec:** greet

**Acceptance criteria:**
- [ ] AC1 `greet` prints hello (test)

**Tests:** `tests/test-greet.sh`'
SPEC_AUTH="**PM spec:** login

**Acceptance criteria:**
- [ ] AC1 a login with a bad MFA code is refused (test)

**Goal:** harden the auth/authz/MFA path.

**Tests:** \`tests/test-login.sh\`"
SPEC_DONE="$SPEC_AUTH

## Threat model
- [ ] AC2 a replayed MFA code is refused (test)"

# ── AC1: a spec, title or body naming a risk area routes to the threat stage ──
reset_stubs; open_state '[]'
cfg "$AREAS" "$ROLES_ALL"
issue 22 "pipeline:dev" "Login hardening" "Plain body." "$SPEC_AUTH"
nxi 22
assert_eq "action=dispatch stage=threat issue=22" "$OUT" "AC1 a spec that names an area is dispatched to the threat stage"
issue 22 "pipeline:dev" "Greeting" "Rotate the CREDENTIALS of the bot." "$SPEC_PLAIN"
nxi 22
assert_eq "action=dispatch stage=threat issue=22" "$OUT" "AC1 an area named only in the issue body (any case) routes to threat"
issue 22 "pipeline:dev" "Add a tenant data export" "Plain body." "$SPEC_PLAIN"
nxi 22
assert_eq "action=dispatch stage=threat issue=22" "$OUT" "AC1 an area named only in the issue title routes to threat"

# ── AC2: no area named, or no areas configured: today's routing ──────────────
issue 22 "pipeline:dev" "Greeting" "Plain body." "$SPEC_PLAIN"
nxi 22
assert_eq "action=dispatch stage=developer issue=22" "$OUT" "AC2 a title, body and spec naming no area still go to the developer"
cfg '[]' "$ROLES_ALL"
issue 22 "pipeline:dev" "Login hardening" "Plain body." "$SPEC_AUTH"
nxi 22
assert_eq "action=dispatch stage=developer issue=22" "$OUT" "AC2 an empty pipeline.risk_areas never routes to threat"
cfg - "$ROLES_ALL"
nxi 22
assert_eq "action=dispatch stage=developer issue=22" "$OUT" "AC2 an unset pipeline.risk_areas never routes to threat"

# ── AC3: done, or a fix round: the developer ─────────────────────────────────
cfg "$AREAS" "$ROLES_ALL"
issue 22 "pipeline:dev" "Login hardening" "Plain body." "$SPEC_DONE"
nxi 22
assert_eq "action=dispatch stage=developer issue=22" "$OUT" "AC3 a spec with a ## Threat model line goes to the developer, no second threat dispatch"
issue 22 "pipeline:dev" "Login hardening" "Plain body." "$SPEC_AUTH"
open_state '[{"n": 12, "issue": 22, "head": "a4f9", "owner": false, "stage": "qa"}]'
nxi 22
assert_eq "action=dispatch stage=developer issue=22" "$OUT" "AC3 an issue with an open PR (fix round) never gets the threat dispatch"
open_state '[]'

# ── AC4: the pipeline:confirmed path with the PM skipped ─────────────────────
cfg "$AREAS" '{"validator": true, "planner": false, "pm": true, "developer": true, "pm_skip_when_spec_present": true}'
issue 22 "pipeline:confirmed" "Rotate credentials" "A spec in the body." ""
printf 0 > "$STUB_DIR/has-spec.22.rc"
nxi 22
assert_eq "action=dispatch stage=threat issue=22" "$OUT" "AC4 a confirmed issue whose PM is skipped for a spec is routed to threat, not the developer"
issue 22 "pipeline:confirmed" "Greeting" "A spec in the body." ""
nxi 22
assert_eq "action=dispatch stage=developer issue=22" "$OUT" "AC4 the same issue with no area keeps the developer route"

# ── AC5: prompt threat, done threat ──────────────────────────────────────────
reset_stubs
cfg "$AREAS" "$ROLES_ALL"
OUT="$(bash "$TN" prompt threat --issue 22 2>"$ERR")"; RC=$?
assert_eq "0" "$RC" "AC5 prompt threat exits 0"
PF="$(printf '%s\n' "$OUT" | sed -n 's/^prompt_file=//p')"
if [ -n "$PF" ] && [ -f "$PF" ]; then
  assert_contains "$(cat "$PF")" "Issue #22" "AC5 the threat prompt names the issue"
  assert_contains "$(cat "$PF")" "## Threat model" "AC5 the threat prompt names the ## Threat model section"
  rm -f "${PF:?}"
else
  fail "AC5 the threat prompt is rendered" "no prompt_file in: $OUT"
fi
SUM="$SANDBOX/summary.txt"
printf 'threat model: 2 findings appended\n' > "$SUM"
issue 22 "pipeline:dev" "Login hardening" "Plain body." "$SPEC_DONE"
OUT="$(bash "$TN" done threat --issue 22 --summary-file "$SUM" 2>"$ERR" < /dev/null)"; RC=$?
assert_eq "0" "$RC" "AC5 done threat is accepted with no verdict"
assert_contains "$OUT" "done=ok" "AC5 done threat reports done=ok"
assert_contains "$(cat "$STUB_DIR/journal" 2>/dev/null)" "view-issue 22 --spec" "AC5 done threat runs the spec check on the spec"
OUT="$(bash "$TN" done threat --issue 22 --verdict CLEAR --summary-file "$SUM" 2>"$ERR" < /dev/null)"; RC=$?
assert_eq "2:stop reason=verdict-invalid" "$RC:$OUT" "AC5 done threat refuses a verdict"

# ── AC6: the role resolves ───────────────────────────────────────────────────
cfg - "$ROLES_ALL"
printf '{"vcs": {"provider": "github"}, "agents": {"roles": {"threat": {"model": "strongest-model"}}}}' > "$PIPELINE_CONFIG"
OUT="$(bash "$GS/pipeline-agent.sh" --resolve-all 2>"$ERR")"
assert_contains "$OUT" "role=threat model=strongest-model" "AC6 --resolve-all lists threat with agents.roles.threat.model"
OUT="$(bash "$GS/pipeline-agent.sh" --resolve-roles threat 2>"$ERR" | tr '\0' '\n')"
assert_contains "$OUT" "strongest-model" "AC6 --resolve-roles threat resolves the pinned model"
OUT="$(bash "$GS/pipeline-agent.sh" --resolve-profile threat 2>"$ERR")"
assert_contains "$OUT" "agents/security.md" "AC6 the threat role runs the security profile"

# ── AC7: the defaults-table row ──────────────────────────────────────────────
cfg '["tenant data", "egress"]' "$ROLES_ALL"
assert_eq "tenant data
egress" "$(bash "$GS/pipeline-config.sh" pipeline.risk_areas 2>"$ERR")" "AC7 cfg pipeline.risk_areas prints its items one per line"
cfg - "$ROLES_ALL"
assert_eq "" "$(bash "$GS/pipeline-config.sh" pipeline.risk_areas 2>"$ERR")" "AC7 the default is empty"
assert_eq "1" "$(grep -c '^pipeline.risk_areas	list		-	-	repo$' "$TALOS_ROOT/scripts/pipeline-defaults.sh")" "AC7 the table row is a list key, empty default, scope repo"

# ── AC8: ids and map read the appended section ───────────────────────────────
printf '%s\n' "$SPEC_DONE" > "$SANDBOX/spec.md"
assert_eq "AC1 test
AC2 test" "$(bash "$GS/pipeline-criteria.sh" ids "$SANDBOX/spec.md" 2>"$ERR")" "AC8 ids lists the criteria of the appended ## Threat model section"
printf '  ok  AC1 a login with a bad MFA code is refused\n' > "$SANDBOX/run.out"
assert_eq "AC1 pass
AC2 missing" "$(bash "$GS/pipeline-criteria.sh" map "$SANDBOX/run.out" --spec "$SANDBOX/spec.md" 2>"$ERR")" "AC8 map reports a threat (test) id with no output as missing"

finish
