#!/usr/bin/env bash
# test-config-defaults-table.sh -- the config schema table (#439, epic #437):
# scripts/pipeline-defaults.sh holds every key's type and default, the known-keys
# list is generated from it, and `cfg KEY` / `pipeline-config.sh KEY` fall back
# to it when the key is absent and the caller gave no default.
#
# Spawn cost (zero python3 with no config, one with a config) is asserted in
# tests/test-config-cache.sh next to the existing per-invocation cache tests.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

DEFAULTS_SH="$TALOS_ROOT/scripts/pipeline-defaults.sh"
CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
PROJ="$SANDBOX/project"
mkdir -p "$PROJ" || exit 1
cd "$PROJ" || exit 1

# ── The table is well formed ─────────────────────────────────────────────────
_out="$(python3 -I - "$DEFAULTS_SH" <<'TALOS_PYtab7Gw3Nd5Xk'
import re
import sys

src = open(sys.argv[1]).read()
m = re.search(r"<<'(TALOS_\w+)' \|\| true\n(.*?)\n\1\n", src, re.S)
rows = [r.split("\t") for r in m.group(2).split("\n")]
bad = []
seen = set()
for r in rows:
    key = r[0]
    if len(r) != 6:
        bad.append("%s: %d fields, want 6" % (key, len(r)))
        continue
    _, typ, default, derived, env, scope = r
    if scope not in ("any", "repo"):
        bad.append("%s: scope column %r" % (key, scope))
    if key in seen:
        bad.append("%s: duplicate key" % key)
    seen.add(key)
    if typ not in ("str", "path", "int", "float", "bool", "enum", "list", "secret"):
        bad.append("%s: type %r" % (key, typ))
    if derived not in ("derived", "-"):
        bad.append("%s: derived column %r" % (key, derived))
    if env != "-" and not re.fullmatch(r"[A-Z][A-Z0-9_]*", env):
        bad.append("%s: env-override %r" % (key, env))
    if derived == "derived" and default != "":
        bad.append("%s: a derived key keeps an empty default" % key)
    if typ == "secret" and default != "":
        bad.append("%s: a secret key has no default (it holds an env:NAME reference)" % key)
    if typ == "bool" and default not in ("", "true", "false"):
        bad.append("%s: bool default %r" % (key, default))
    if typ == "int" and not re.fullmatch(r"[0-9]*", default):
        bad.append("%s: int default %r" % (key, default))
    if typ == "float" and not re.fullmatch(r"([0-9]+(\.[0-9]+)?)?", default):
        bad.append("%s: float default %r" % (key, default))
    if re.search(r"[^\x20-\x7e]", default):
        bad.append("%s: default has a control or non-ASCII character" % key)
print("\n".join(bad))
print("ROWS=%d" % len(rows))
TALOS_PYtab7Gw3Nd5Xk
)"
assert_eq "ROWS=113" "$(printf '%s\n' "$_out" | tail -n1)" "the table has one row per config key (113 rows)"
assert_eq "" "$(printf '%s\n' "$_out" | sed '$d')" \
  "every row has six fields, a unique key, a valid type/derived/env/scope column, and a default of the right shape"

# ── (d) the table's key set is the old known-keys list: no key lost ──────────
OLD_KEYS="base_branch repo vcs.provider vcs.repo vcs.token_env vcs.azure.org_url
vcs.azure.project vcs.azure.work_item_type vcs.azure.area_path vcs.file.source.path
board.enabled board.project_number board.owner board.status_field board.statuses.*
board.status_map.* board.azure_states.* board.azure_states.ready board.azure_states.in_progress
board.azure_states.in_review board.azure_states.done verify verify.commands verify.qa_mode
verify.targeted verify.ci_wait_s verify.timeout_ms merge.auto merge.method
merge.required_checks merge.forbidden_files
merge.forbidden_files_replace merge.forbidden_files_allow merge.approval_waiver_paths
merge.union_paths merge.auto_sync issues.label_filter issues.skip_labels
issues.max_parallel issues.assignee issues.claim identity.name execution.isolation execution.worktree_warn_threshold
roles.validator roles.pm roles.pm_skip_when_spec_present roles.qa roles.reviewer
roles.security roles.adversarial roles.docs roles.docs_mode roles.planner
comments.enabled comments.header comments.templates_dir
notifications.slack_channel notifications.discord_channel notifications.buzz_channel
notifications.buzz_relay notifications.buzz_timeout_s notifications.templates_dir
notifications.threading notifications.events notifications.cmd
notifications.cmd_timeout_s notifications.slack.webhook notifications.discord.webhook notifications.teams.webhook notifications.slack.bot_token notifications.discord.bot_token notifications.buzz.bot_key agents.runner agents.subagents agents.runner_args
agents.runner_cmd agents.model agents.restamp_model agents.effort agents.restamp_effort
agents.roles.*.model agents.roles.*.runner agents.roles.*.runner_cmd
agents.roles.*.restamp_model agents.roles.*.effort agents.roles.*.restamp_effort
agents.claude_allowed_tools agents.claude_permission_mode agents.roles.*.claude_allowed_tools agents.roles.*.claude_permission_mode
agents.fallback agents.roles.*.fallback agents.provider_down_s agents.stage_timeout_s agents.roles.*.stage_timeout_s agents.capture_usage agents.profile agents.mode limits.max_fix_attempts
limits.max_total_dispatches limits.max_retries limits.tokens_per_issue limits.warn_at
spend.comment pr.draft markers.trusted_authors markers.verify_authors
hooks.pre_dispatch hooks.post_stage hooks.timeout_s events.enabled events.path"

_table_keys="$( . "$DEFAULTS_SH"; _talos_defaults_keys | LC_ALL=C sort )"
_old_sorted="$(printf '%s\n' $OLD_KEYS | LC_ALL=C sort)"
assert_eq "$_old_sorted" "$_table_keys" "the table's key set equals the old _KNOWN_CONFIG_KEYS_JSON list"

# The JSON handed to the unknown-key check is generated from the table.
_json="$( . "$DEFAULTS_SH"; _talos_known_keys_json )"
_json_keys="$(printf '%s' "$_json" | python3 -I -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin))))')"
assert_eq "$_old_sorted" "$_json_keys" "_talos_known_keys_json is valid JSON naming exactly the table keys"

# ── (a) no config: the table answers; an explicit default still wins ─────────
assert_eq "true" "$(bash "$CFG_SH" board.enabled)" \
  "(a) pipeline-config.sh board.enabled with no config prints the table value (true)"
assert_eq "false" "$(bash "$CFG_SH" board.enabled false)" "an explicit default argument wins over the table"
assert_eq "" "$(bash "$CFG_SH" board.enabled "")" "an explicit empty default also wins over the table"
assert_eq "squash" "$(bash "$CFG_SH" merge.method)" "a string key falls back to the table (merge.method)"
assert_eq "0.8" "$(bash "$CFG_SH" limits.warn_at)" "a float key falls back to the table (limits.warn_at)"
assert_eq "600000" "$(bash "$CFG_SH" verify.timeout_ms)" "an int key falls back to the table (verify.timeout_ms)"
assert_eq "$(printf 'pipeline:blocked\nwontfix')" "$(bash "$CFG_SH" issues.skip_labels)" \
  "a list default prints one item per line, like a list read from config"
assert_eq "" "$(bash "$CFG_SH" no.such.key)" "an unknown key with no default prints nothing"
assert_eq "x" "$(bash "$CFG_SH" no.such.key x)" "an unknown key with a default prints the default"

# Derived keys: the table has no default, the caller's fallback stays in charge.
for _k in base_branch vcs.repo board.owner agents.restamp_model merge.forbidden_files pr.draft; do
  assert_eq "" "$(bash "$CFG_SH" "$_k")" "derived key $_k: no default argument prints nothing"
  assert_eq "caller" "$(bash "$CFG_SH" "$_k" caller)" "derived key $_k: the caller's fallback is kept"
done
assert_eq "dev" "$(bash "$CFG_SH" agents.roles.dev.model dev)" "a wildcard derived key keeps the caller's fallback"
# verify.qa_mode (#440): with no config there is no check list, so the derived
# value is "local"; the table states it so the playbook needs no `local` literal.
assert_eq "local" "$(bash "$CFG_SH" verify.qa_mode)" "verify.qa_mode with no config prints the table value (local)"
assert_eq "caller" "$(bash "$CFG_SH" verify.qa_mode caller)" "verify.qa_mode: the caller's fallback is kept"
# board.azure_states.<state> (#440): the four states with a default have a row.
assert_eq "New Committed Committed Done" "$(for _s in ready in_progress in_review done; do printf '%s ' "$(bash "$CFG_SH" board.azure_states.$_s)"; done | sed 's/ $//')" \
  "board.azure_states.<state> falls back to the table for the four states with a default"
assert_eq "" "$(bash "$CFG_SH" board.azure_states.blocked)" "board.azure_states.blocked has no default"

# ── (h) pr.draft: no second copy of #435's resolver ──────────────────────────
_row="$( . "$DEFAULTS_SH"; _talos_defaults_row pr.draft; printf '%s|%s' "$_TD_DERIVED" "$_TD_DEFAULT" )"
assert_eq "derived|" "$_row" "pr.draft is marked derived with no default of its own"

# ── (b) an explicit config value wins; absent keys still fall back ───────────
cat > talos.pipeline.json <<'TALOS_JSONq4Lm9Tz2Vb'
{"board": {"enabled": false}, "merge": {"method": "rebase"}, "limits": {"warn_at": 0.5}}
TALOS_JSONq4Lm9Tz2Vb
assert_eq "false" "$(bash "$CFG_SH" board.enabled)" "(b) an explicit config value wins over the table (no default arg)"
assert_eq "false" "$(bash "$CFG_SH" board.enabled true)" "an explicit config value wins over the caller's default"
assert_eq "rebase" "$(bash "$CFG_SH" merge.method)" "an explicit string value wins over the table"
assert_eq "0.5" "$(bash "$CFG_SH" limits.warn_at)" "an explicit numeric value wins over the table"
assert_eq "3" "$(bash "$CFG_SH" limits.max_fix_attempts)" "a key absent from a present config falls back to the table"
assert_eq "7" "$(bash "$CFG_SH" limits.max_fix_attempts 7)" "a key absent from a present config keeps the caller's default"
assert_eq "local" "$(bash "$CFG_SH" verify.qa_mode)" "verify.qa_mode keeps its computed default with a config present"

# ── (f) --has KEY ────────────────────────────────────────────────────────────
bash "$CFG_SH" --has board.enabled; _rc=$?
assert_eq "0" "$_rc" "(f) --has exits 0 for a key set in the config"
bash "$CFG_SH" --has limits.max_fix_attempts; _rc=$?
assert_eq "1" "$_rc" "(f) --has exits 1 for an absent key, even one with a table default"
bash "$CFG_SH" --has board; _rc=$?
assert_eq "0" "$_rc" "--has exits 0 for a section that is set"
bash "$CFG_SH" --has board.enabled.nope; _rc=$?
assert_eq "1" "$_rc" "--has exits 1 for a path below a leaf"
bash "$CFG_SH" --has ""; _rc=$?
assert_eq "1" "$_rc" "--has with an empty key exits 1"
assert_eq "" "$(bash "$CFG_SH" --has board.enabled)" "--has prints nothing on stdout"

# An empty value is still "set"; a null one is not.
cat > talos.pipeline.json <<'TALOS_JSONr8Hc5Wp3Ne'
{"issues": {"assignee": ""}, "hooks": {"post_stage": null}}
TALOS_JSONr8Hc5Wp3Ne
bash "$CFG_SH" --has issues.assignee; _rc=$?
assert_eq "0" "$_rc" "--has exits 0 for a key set to the empty string"
bash "$CFG_SH" --has hooks.post_stage; _rc=$?
assert_eq "1" "$_rc" "--has exits 1 for a key set to null"

rm -f "${PROJ:?}/talos.pipeline.json"
bash "$CFG_SH" --has board.enabled; _rc=$?
assert_eq "1" "$_rc" "--has exits 1 when no config file exists"

# The user-level layer counts as a file layer.
mkdir -p "$SANDBOX/th" || exit 1
printf '{"agents": {"model": "m1"}}\n' > "$SANDBOX/th/talos.pipeline.json"
TALOS_HOME="$SANDBOX/th" bash "$CFG_SH" --has agents.model; _rc=$?
assert_eq "0" "$_rc" "--has sees a key set only in the user-level file"
TALOS_HOME="$SANDBOX/th" bash "$CFG_SH" --has agents.effort; _rc=$?
assert_eq "1" "$_rc" "--has exits 1 for an agents key the user-level file does not set"

# ── cfg(): the same rule, from the per-invocation cache ──────────────────────
cat > "$SANDBOX/probe-cfg.sh" <<'TALOS_PROBEs2Fk7Qy4Bc'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$1"
. "$SCRIPT_DIR/pipeline-cfg-cache.sh"
printf '%s\n' "[$(cfg board.enabled)]" "[$(cfg board.enabled false)]" "[$(cfg limits.warn_at)]" \
  "[$(cfg limits.warn_at "")]" "[$(cfg base_branch develop)]" "[$(cfg base_branch)]" "[$(cfg no.such.key)]"
TALOS_PROBEs2Fk7Qy4Bc
_want="$(printf '%s\n' '[true]' '[false]' '[0.8]' '[]' '[develop]' '[]' '[]')"
assert_eq "$_want" "$(bash "$SANDBOX/probe-cfg.sh" "$TALOS_ROOT/scripts")" \
  "cfg with no config: table default without a default arg, caller's default (even empty) otherwise"

cat > talos.pipeline.json <<'TALOS_JSONt6Jd1Mx8Rg'
{"board": {"enabled": false}, "limits": {"warn_at": 0.5}}
TALOS_JSONt6Jd1Mx8Rg
_want="$(printf '%s\n' '[false]' '[false]' '[0.5]' '[0.5]' '[develop]' '[]' '[]')"
assert_eq "$_want" "$(bash "$SANDBOX/probe-cfg.sh" "$TALOS_ROOT/scripts")" \
  "cfg with a config: an explicit value wins; an absent key still falls back"
rm -f "${PROJ:?}/talos.pipeline.json"

# ── A partial install without the table still works, with one warning ────────
NOTAB="$SANDBOX/no-table-scripts"
mkdir -p "$NOTAB" || exit 1
for f in "$TALOS_ROOT"/scripts/*.sh; do
  _b="$(basename "$f")"
  [ "$_b" = "pipeline-defaults.sh" ] && continue
  ln -s "$f" "$NOTAB/$_b"
done
assert_eq "x" "$(bash "$NOTAB/pipeline-config.sh" board.enabled x 2>/dev/null)" \
  "pipeline-config.sh without pipeline-defaults.sh still honours a caller default"
assert_eq "" "$(bash "$NOTAB/pipeline-config.sh" board.enabled 2>/dev/null)" \
  "pipeline-config.sh without pipeline-defaults.sh prints nothing for a key with no default"
_warn="$(bash "$NOTAB/pipeline-config.sh" board.enabled 2>&1 >/dev/null)"
assert_contains "$_warn" "pipeline-defaults.sh missing" "the missing table is reported once on stderr"
cat > "$SANDBOX/probe-cfg-notab.sh" <<'TALOS_PROBEu9Wn3Lz6Kd'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$1"
. "$SCRIPT_DIR/pipeline-cfg-cache.sh"
printf '[%s][%s]' "$(cfg board.enabled)" "$(cfg board.enabled x)"
TALOS_PROBEu9Wn3Lz6Kd
assert_eq "[][x]" "$(bash "$SANDBOX/probe-cfg-notab.sh" "$NOTAB" 2>"$SANDBOX/notab.err")" \
  "cfg without pipeline-defaults.sh degrades to the caller's default"
assert_contains "$(cat "$SANDBOX/notab.err")" "pipeline-defaults.sh missing" \
  "cfg without pipeline-defaults.sh surfaces the missing-table warning (stderr not swallowed)"

# ── The lookups are bash 3.2 safe: run them under /bin/bash (3.2 on macOS) ───
_v="$(/bin/bash -c '. "$1"; _talos_default board.enabled; _talos_default issues.skip_labels | wc -l | tr -d " "' _ "$DEFAULTS_SH")"
assert_eq "true1" "$(printf '%s' "$_v" | tr -d '\n')" "the table lookups work under /bin/bash"

finish
