#!/usr/bin/env bash
# Tests for the global config layer (#441, part of epic #437): every key may be
# set in ${TALOS_HOME:-$HOME/.talos}/talos.pipeline.{yml,yaml,json} except the
# repo-only keys (the table's scope column), and the env column forms a fourth
# layer on top. Layer order: table defaults, global file, repo file, env.
#
# Sandboxed: TALOS_HOME always points inside $SANDBOX, so the real ~/.talos is
# never read or written. Secret-shaped values are planted only to prove they
# never reach stdout or stderr.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
# PyYAML probe, same lookup as the loader (-I drops the user site; it is appended back, #395).
HAVE_YAML=0
python3 -I -c 'import site, sys; sys.path.append(site.getusersitepackages()); import yaml' 2>/dev/null && HAVE_YAML=1

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
DEFAULTS_SH="$TALOS_ROOT/scripts/pipeline-defaults.sh"
PROJ="$SANDBOX/project"
GHOME="$SANDBOX/talos-home"
ERR="$SANDBOX/stderr"
mkdir -p "$PROJ" "$GHOME" || exit 1
cd "$PROJ" || exit 1

ENV_VARS="PIPELINE_REPO PIPELINE_PROJECT_NUMBER PIPELINE_BOARD_OWNER PIPELINE_STATUS_FIELD PIPELINE_SLACK_CHANNEL PIPELINE_DISCORD_CHANNEL PIPELINE_BUZZ_CHANNEL PIPELINE_BUZZ_RELAY"
reset_cfg() {
  rm -f "${PROJ:?}"/talos.pipeline.* "${GHOME:?}"/talos.pipeline.*
  unset PIPELINE_CONFIG $ENV_VARS
  export TALOS_HOME="$GHOME"
}
glob_json() { printf '%s' "$1" > "$GHOME/talos.pipeline.json"; }
proj_json() { printf '%s' "$1" > "$PROJ/talos.pipeline.json"; }
get() { bash "$CFG_SH" "$1" "${2:-SENT}" 2>"$ERR"; }
errlines() { wc -l < "$ERR" | tr -d ' '; }
dump() { bash "$CFG_SH" --dump 2>"$ERR" | tr '\0' '\n'; }

assert_eq "unset" "${TALOS_HOME:-unset}" "(f) make_sandbox leaves no ambient TALOS_HOME"
reset_cfg
case "$TALOS_HOME" in "$SANDBOX"/*) pass "(f) reset_cfg keeps TALOS_HOME inside the sandbox" ;; *) fail "(f) reset_cfg keeps TALOS_HOME inside the sandbox" "TALOS_HOME=$TALOS_HOME" ;; esac

# ── The table's scope column ─────────────────────────────────────────────────
_scope_out="$(python3 -I - "$DEFAULTS_SH" <<'TALOS_PYscp4Hq8Wn2Zt'
import re
import sys

src = open(sys.argv[1]).read()
m = re.search(r"<<'(TALOS_\w+)' \|\| true\n(.*?)\n\1\n", src, re.S)
rows = [r.split("\t") for r in m.group(2).split("\n")]
repo = sorted(r[0] for r in rows if len(r) == 6 and r[5] == "repo")
bad = ["%s: scope %r" % (r[0], r[5]) for r in rows if len(r) == 6 and r[5] not in ("any", "repo")]
print("\n".join(bad))
print("REPO=" + " ".join(repo))
TALOS_PYscp4Hq8Wn2Zt
)"
EXPECTED_REPO="base_branch board.azure_states.* board.azure_states.done board.azure_states.in_progress board.azure_states.in_review board.azure_states.ready board.enabled board.owner board.project_number board.status_field board.status_map.* board.statuses.* evidence.command issues.label_filter issues.skip_labels markers.trusted_authors markers.verify_authors merge.approval_waiver_paths merge.forbidden_files merge.forbidden_files_allow merge.forbidden_files_replace merge.required_checks merge.union_paths release_branch repo status.archive_dir status.file status.fragments_dir vcs.azure.area_path vcs.azure.org_url vcs.azure.project vcs.azure.work_item_type vcs.file.source.path vcs.provider vcs.repo verify verify.commands verify.qa_mode"
assert_eq "REPO=$EXPECTED_REPO" "$(printf '%s\n' "$_scope_out" | tail -n1)" "the repo-only set is exactly the owner-approved list (hooks.* and notifications.cmd stay global)"
assert_eq "" "$(printf '%s\n' "$_scope_out" | sed '$d')" "every table row's scope is any or repo"

# ── (a) global-only keys are read; the repo overrides key by key ─────────────
GLOBAL_ANY='{"pr":{"draft":false},"limits":{"max_fix_attempts":5,"warn_at":0.5,"tokens_per_issue":9000},"spend":{"comment":false},"evidence":{"enabled":true,"max_files":7},"verify":{"ci_wait_s":321,"targeted":false},"hooks":{"pre_dispatch":"echo hi","timeout_s":9},"notifications":{"cmd":"echo n","slack_channel":"CGLOBAL"},"issues":{"max_parallel":3}}'
reset_cfg
glob_json "$GLOBAL_ANY"
assert_eq "false" "$(get pr.draft)" "(a) pr.draft from the global file alone"
assert_eq "5" "$(get limits.max_fix_attempts)" "(a) limits.max_fix_attempts from the global file alone"
assert_eq "0.5" "$(get limits.warn_at)" "(a) limits.warn_at from the global file alone"
assert_eq "9000" "$(get limits.tokens_per_issue)" "(a) limits.tokens_per_issue from the global file alone"
assert_eq "false" "$(get spend.comment)" "(a) spend.comment from the global file alone"
assert_eq "true" "$(get evidence.enabled)" "(a) evidence.enabled from the global file alone"
assert_eq "7" "$(get evidence.max_files)" "(a) evidence.max_files from the global file alone"
assert_eq "321" "$(get verify.ci_wait_s)" "(a) verify.ci_wait_s from the global file alone"
assert_eq "false" "$(get verify.targeted)" "(a) verify.targeted from the global file alone"
assert_eq "echo hi" "$(get hooks.pre_dispatch)" "(a) hooks.pre_dispatch is allowed globally"
assert_eq "echo n" "$(get notifications.cmd)" "(a) notifications.cmd is allowed globally"
assert_eq "3" "$(get issues.max_parallel)" "(a) issues.max_parallel from the global file alone"
assert_eq "0" "$(errlines)" "(a) a global file of any-scope keys is silent"
_d="$(dump)"
assert_contains "$_d" "$(printf 'limits.warn_at\n0.5')" "(a) --dump carries the global-only keys"
assert_contains "$_d" "$(printf 'pr.draft\nfalse')" "(a) --dump carries pr.draft from the global file"

proj_json '{"pr":{"draft":true},"limits":{"warn_at":0.9},"evidence":{"max_files":2}}'
assert_eq "true" "$(get pr.draft)" "(a) a repo value overrides the global one"
assert_eq "0.9" "$(get limits.warn_at)" "(a) the repo overrides limits.warn_at"
assert_eq "2" "$(get evidence.max_files)" "(a) the repo overrides evidence.max_files"
assert_eq "5" "$(get limits.max_fix_attempts)" "(a) a sibling key the repo does not set keeps the global value"
assert_eq "true" "$(get evidence.enabled)" "(a) override is key by key, not per subtree"
assert_eq "321" "$(get verify.ci_wait_s)" "(a) a key absent from the repo file keeps the global value"
_d="$(dump)"
assert_contains "$_d" "$(printf 'limits.warn_at\n0.9')" "(a) --dump has the repo override"
assert_contains "$_d" "$(printf 'limits.max_fix_attempts\n5')" "(a) --dump keeps the global sibling"

# An absent global file or a key set nowhere still returns the caller default
reset_cfg
assert_eq "SENT" "$(get limits.warn_at)" "(a) no layer sets the key: the caller default"
assert_eq "0.8" "$(bash "$CFG_SH" limits.warn_at 2>/dev/null)" "(a) no layer and no default argument: the table default"

# ── (b) repo-only keys in the global file: dropped, one note each, no value ──
reset_cfg
glob_json '{"board":{"owner":"PLANTED-owner-value-7"},"limits":{"warn_at":0.5}}'
assert_eq "SENT" "$(get board.owner)" "(b) a repo-only key in the global file does not apply"
assert_eq "1" "$(errlines)" "(b) exactly one stderr line for one repo-only key"
assert_contains "$(cat "$ERR")" "board.owner" "(b) the note names the key"
assert_not_contains "$(cat "$ERR")" "PLANTED-owner-value-7" "(b) the note never prints the value"
assert_eq "0.5" "$(get limits.warn_at)" "(b) a sibling any-scope key still applies"
_d="$(dump)"
assert_eq "1" "$(errlines)" "(b) --dump prints exactly one note too"
assert_not_contains "$_d" "board.owner" "(b) --dump omits the repo-only key"
assert_not_contains "$_d" "PLANTED-owner-value-7" "(b) --dump never carries the dropped value"
assert_not_contains "$(bash "$CFG_SH" --has board.owner 2>/dev/null && echo yes)" "yes" "(b) --has treats the dropped key as absent"

# Every repo-only group, one key each, one note each
reset_cfg
glob_json '{"base_branch":"b1","release_branch":"b2","repo":"o/r","vcs":{"provider":"azure","repo":"o/r2","azure":{"org_url":"u","project":"p"},"file":{"source":{"path":"x.md"}}},"board":{"enabled":false,"project_number":4,"statuses":{"ready":"R"},"status_map":{"a":"b"}},"verify":{"commands":["make"],"qa_mode":"ci"},"merge":{"required_checks":["ci"],"forbidden_files":["f"],"forbidden_files_allow":["g"],"approval_waiver_paths":["w"],"union_paths":["u"]},"markers":{"trusted_authors":["t"],"verify_authors":false},"issues":{"label_filter":"l","skip_labels":["s"]},"evidence":{"command":"c"},"status":{"file":"S.md","fragments_dir":"fd","archive_dir":"ad"}}'
get base_branch >/dev/null
assert_eq "27" "$(errlines)" "(b) one note per dropped repo-only key (27 keys across every group)"
_e="$(cat "$ERR")"
for _k in base_branch release_branch repo vcs.provider vcs.repo vcs.azure.org_url vcs.azure.project vcs.file.source.path board.enabled board.project_number board.statuses.ready board.status_map.a verify.commands verify.qa_mode merge.required_checks merge.forbidden_files merge.forbidden_files_allow merge.approval_waiver_paths merge.union_paths markers.trusted_authors markers.verify_authors issues.label_filter issues.skip_labels evidence.command status.file status.fragments_dir status.archive_dir; do
  assert_contains "$_e" "'$_k'" "(b) the repo-only key $_k is named in a note"
done
assert_eq "main" "$(bash "$CFG_SH" release_branch 2>/dev/null)" "(b) a dropped repo-only key falls back to the table default"
_all_dropped="$(dump)"
glob_json '{}'
assert_eq "$(dump)" "$_all_dropped" "(b) --dump of a global file of only repo-only keys equals the dump of an empty global file"
# the legacy bare verify list is the same setting as verify.commands: repo-only
glob_json '{"verify":["make test"]}'
assert_eq "SENT" "$(get verify)" "(b) a bare verify list in the global file does not apply"
assert_eq "1" "$(errlines)" "(b) ... and prints one note"

# the repo file still sets every repo-only key (the scope only limits the global file)
reset_cfg
glob_json '{"board":{"owner":"fromglobal"}}'
proj_json '{"board":{"owner":"fromrepo"},"verify":{"commands":["make"]}}'
assert_eq "fromrepo" "$(get board.owner)" "(b) the repo file sets a repo-only key as before"
assert_eq "make" "$(get verify.commands)" "(b) the repo file sets verify.commands as before"

# A hostile key name cannot add stderr lines or inject control characters
reset_cfg
printf '%s' '{"board":{"evil\u001b[31m\nINJECTED":1}}' > "$GHOME/talos.pipeline.json"
get base_branch >/dev/null
assert_eq "1" "$(errlines)" "(b) a newline in a repo-only key name cannot add stderr lines"
if LC_ALL=C grep -q "$(printf '\033')" "$ERR"; then fail "(b) no raw ESC byte reaches stderr"; else pass "(b) no raw ESC byte reaches stderr"; fi

# ── (c) scalars and dicts merge; a repo list replaces the global list whole ──
reset_cfg
glob_json '{"notifications":{"events":["a","b"],"slack_channel":"CGLOBAL","threading":false},"agents":{"fallback":["pi","codex"],"roles":{"qa":{"model":"gq"},"docs":{"model":"gd"}}},"markers":{}}'
proj_json '{"notifications":{"events":["c"]},"agents":{"fallback":["gemini"],"roles":{"qa":{"model":"rq"}}}}'
assert_eq "c" "$(get notifications.events)" "(c) a repo list replaces the global list whole (no union)"
assert_eq "gemini" "$(get agents.fallback)" "(c) a repo fallback list replaces the global one whole"
assert_eq "rq" "$(get agents.roles.qa.model)" "(c) dicts merge: the repo leaf wins"
assert_eq "gd" "$(get agents.roles.docs.model)" "(c) dicts merge: the global sibling survives"
assert_eq "CGLOBAL" "$(get notifications.slack_channel)" "(c) a scalar the repo does not set keeps the global value"
assert_eq "false" "$(get notifications.threading)" "(c) a global bool the repo does not set keeps its value"
proj_json '{"agents":{"roles":{"qa":{"model":"rq"}}}}'
assert_eq "$(printf 'a\nb')" "$(get notifications.events)" "(c) a global list the repo does not set applies whole"
assert_eq "$(printf 'pi\ncodex')" "$(get agents.fallback)" "(c) a global fallback list applies when the repo has none"
proj_json '{"notifications":{"events":null}}'
assert_eq "$(printf 'a\nb')" "$(get notifications.events)" "(c) an empty (null) repo leaf does not erase the global value"
# a repo-only list in the global file never merges into the repo list
reset_cfg
glob_json '{"merge":{"forbidden_files":["globalpat"]}}'
proj_json '{"merge":{"forbidden_files":["repopat"]}}'
assert_eq "repopat" "$(get merge.forbidden_files)" "(c) merge.forbidden_files: the global file contributes nothing (repo-only)"

# ── (d) --dump and the single-key path agree for every key ───────────────────
reset_cfg
glob_json '{"pr":{"draft":false},"limits":{"max_fix_attempts":5,"warn_at":5,"tokens_per_issue":9000},"spend":{"comment":"maybe"},"evidence":{"enabled":"yes","max_files":7,"dir":"../up"},"verify":{"ci_wait_s":"abc","timeout_ms":1234,"commands":["x"]},"hooks":{"timeout_s":-3,"pre_dispatch":"echo hi"},"status":{"log_days":12,"file":"G.md"},"notifications":{"events":["a","b"],"slack_channel":"CG","cmd_timeout_s":4},"agents":{"model":"sonnet","effort":"nope","fallback":["pi","pi"],"provider_down_s":7,"roles":{"qa":{"model":"gq","effort":"high","fallback":["codex"]}}},"board":{"owner":"gone"},"vcs":{"token_env":"TOK"}}'
proj_json '{"limits":{"warn_at":0.7},"merge":{"required_checks":["ci"]},"board":{"project_number":3},"notifications":{"events":["c"]},"agents":{"roles":{"docs":{"model":"rd"}}}}'
export PIPELINE_SLACK_CHANNEL=CENV PIPELINE_BOARD_OWNER=envowner
_parity="$(python3 -I - "$CFG_SH" "$DEFAULTS_SH" <<'TALOS_PYpar9Rk3Vb6Lm'
import subprocess
import sys

cfg_sh, defaults_sh = sys.argv[1], sys.argv[2]
keys = subprocess.run(
    ["bash", "-c", '. "$1"; _talos_defaults_keys', "x", defaults_sh],
    capture_output=True, text=True, check=True).stdout.split()
# A role the fixture names (qa, docs): --dump only computes derived per-role keys
# for roles present in the config; an unnamed role answers through the caller
# default by design (see the --dump comment in pipeline-config.sh).
keys = [k.replace("agents.roles.*", "agents.roles.qa").replace("*", "x") for k in keys]
keys += ["agents.roles.docs.model", "agents.roles.docs.restamp_model", "agents.roles.docs.effort", "no.such.key"]
raw = subprocess.run(["bash", cfg_sh, "--dump"], capture_output=True, check=True).stdout
parts = raw.split(b"\0")
dump = {parts[i].decode(): parts[i + 1].decode() for i in range(0, len(parts) - 1, 2)}
bad = []
for k in keys:
    single = subprocess.run(["bash", cfg_sh, k, "SENT"], capture_output=True, text=True).stdout
    want = dump.get(k, "SENT")
    if single != want:
        bad.append("%s: single=%r dump=%r" % (k, single, want))
print("\n".join(bad))
print("KEYS=%d DUMPED=%d" % (len(keys), len(dump)))
TALOS_PYpar9Rk3Vb6Lm
)"
assert_eq "" "$(printf '%s\n' "$_parity" | sed '$d')" "(d) --dump and the single-key path agree for every table key across global, repo and env layers"
case "$(printf '%s\n' "$_parity" | tail -n1)" in
  KEYS=1[0-9][0-9]*DUMPED=[1-9]*) pass "(d) the parity run covered the whole table and a non-trivial dump" ;;
  *) fail "(d) the parity run covered the whole table and a non-trivial dump" "$(printf '%s\n' "$_parity" | tail -n1)" ;;
esac
unset PIPELINE_SLACK_CHANNEL PIPELINE_BOARD_OWNER

# ── (e) validators run on the merged value, whichever layer set it ───────────
reset_cfg
glob_json '{"verify":{"ci_wait_s":"abc","timeout_ms":-1},"hooks":{"timeout_s":0},"limits":{"warn_at":5},"spend":{"comment":"yes"},"evidence":{"enabled":"yes","max_files":500,"dir":"../x"},"agents":{"effort":"extreme","fallback":["pi","pi"],"provider_down_s":5,"roles":{"qa":{"effort":"nope"}}}}'
assert_eq "SENT" "$(get verify.ci_wait_s)" "(e) a non-integer global verify.ci_wait_s is rejected"
assert_contains "$(cat "$ERR")" "verify.ci_wait_s must be a positive integer" "(e) ... with the positive-integer warning"
assert_eq "SENT" "$(get verify.timeout_ms)" "(e) a negative global verify.timeout_ms is rejected"
assert_eq "SENT" "$(get hooks.timeout_s)" "(e) a zero global hooks.timeout_s is rejected"
assert_eq "SENT" "$(get limits.warn_at)" "(e) an out-of-range global limits.warn_at is rejected"
assert_eq "SENT" "$(get spend.comment)" "(e) a non-bool global spend.comment is rejected"
assert_eq "SENT" "$(get evidence.enabled)" "(e) a non-bool global evidence.enabled is rejected (_CFG_EVIDENCE_PY)"
assert_eq "SENT" "$(get evidence.max_files)" "(e) an out-of-range global evidence.max_files is rejected"
assert_eq "SENT" "$(get evidence.dir)" "(e) a path-escaping global evidence.dir is rejected"
assert_eq "SENT" "$(get agents.effort)" "(e) a bad global agents.effort is rejected"
assert_eq "SENT" "$(get agents.fallback)" "(e) a duplicate-runner global agents.fallback is rejected (_CFG_FALLBACK_PY)"
assert_eq "SENT" "$(get agents.provider_down_s)" "(e) an out-of-range global agents.provider_down_s is rejected"
_d="$(dump)"
for _k in verify.ci_wait_s verify.timeout_ms hooks.timeout_s limits.warn_at spend.comment evidence.enabled evidence.max_files evidence.dir agents.effort agents.fallback agents.provider_down_s; do
  assert_not_contains "$_d" "$_k" "(e) --dump drops the invalid global $_k too"
done
# a valid repo value beats an invalid global one; an invalid repo value does not fall back to the global value
reset_cfg
glob_json '{"limits":{"warn_at":0.4}}'
proj_json '{"limits":{"warn_at":5}}'
assert_eq "SENT" "$(get limits.warn_at)" "(e) the merged (repo) value is what is validated: invalid repo wins, then is dropped"

# ── env layer: the table's env column, on top of repo and global ─────────────
reset_cfg
glob_json '{"notifications":{"slack_channel":"CGLOBAL","discord_channel":"DGLOBAL"}}'
proj_json '{"notifications":{"slack_channel":"CREPO"},"board":{"project_number":3}}'
assert_eq "CREPO" "$(get notifications.slack_channel)" "(env) precondition: the repo beats the global file"
export PIPELINE_SLACK_CHANNEL=CENV
assert_eq "CENV" "$(get notifications.slack_channel)" "(env) the env var beats the repo and the global file"
assert_eq "DGLOBAL" "$(get notifications.discord_channel)" "(env) a key with no env var set is unaffected"
assert_contains "$(dump)" "$(printf 'notifications.slack_channel\nCENV')" "(env) --dump carries the env value"
export PIPELINE_PROJECT_NUMBER=42
assert_eq "42" "$(get board.project_number)" "(env) PIPELINE_PROJECT_NUMBER beats the repo value"
unset PIPELINE_PROJECT_NUMBER
export PIPELINE_SLACK_CHANNEL=""
assert_eq "CREPO" "$(get notifications.slack_channel)" "(env) an empty env var is treated as unset"
unset PIPELINE_SLACK_CHANNEL
assert_eq "0" "$(bash "$CFG_SH" --has notifications.discord_channel >/dev/null 2>&1; echo $?)" "(env) --has still reads file layers"
export PIPELINE_BUZZ_CHANNEL=BENV
assert_eq "1" "$(bash "$CFG_SH" --has notifications.buzz_channel >/dev/null 2>&1; echo $?)" "(env) --has reports file layers only: an env-only key is not set in a config file"
assert_eq "BENV" "$(get notifications.buzz_channel)" "(env) an env var sets a key no file sets"
unset PIPELINE_BUZZ_CHANNEL
# no generic scheme: a TALOS_CFG_* variable does nothing
export TALOS_CFG_NOTIFICATIONS_SLACK_CHANNEL=NOPE TALOS_CFG_LIMITS_WARN_AT=0.1
assert_eq "CREPO" "$(get notifications.slack_channel)" "(env) no generic TALOS_CFG_* mapping exists"
assert_eq "SENT" "$(get limits.warn_at)" "(env) a TALOS_CFG_* variable never reaches a key"
unset TALOS_CFG_NOTIFICATIONS_SLACK_CHANNEL TALOS_CFG_LIMITS_WARN_AT
# a repo-only key set by its env var is still honoured (env is the last layer)
reset_cfg
glob_json '{"board":{"owner":"gone"}}'
export PIPELINE_BOARD_OWNER=envowner
assert_eq "envowner" "$(get board.owner)" "(env) a repo-only key's env var applies (the scope limits the global file only)"
unset PIPELINE_BOARD_OWNER

# env with no config file anywhere: applied in pure shell, no python3 spawn
reset_cfg
rm -rf "${GHOME:?}"; mkdir -p "$GHOME"
SHIMDIR="$SANDBOX/shim"; mkdir -p "$SHIMDIR"
PY_LOG="$SANDBOX/py.log"; : > "$PY_LOG"
REAL_PY="$(command -v python3)"
cat > "$SHIMDIR/python3" <<SHIM
#!/usr/bin/env bash
echo spawn >> "$PY_LOG"
exec "$REAL_PY" "\$@"
SHIM
chmod +x "$SHIMDIR/python3"
export PIPELINE_SLACK_CHANNEL=CNOFILE
assert_eq "CNOFILE" "$(PATH="$SHIMDIR:$PATH" bash "$CFG_SH" notifications.slack_channel SENT 2>/dev/null)" "(env) no config file: the single-key path still answers from env"
assert_eq "SENT" "$(PATH="$SHIMDIR:$PATH" bash "$CFG_SH" notifications.discord_channel SENT 2>/dev/null)" "(env) no config file and no env var: the caller default"
# The no-config dump still answers "where is talos configured" (#526): the
# SOURCES header names both file paths as empty, the set env override, and the
# secrets store (named even when absent).
assert_eq "$(printf 'sources.project\nsources.global\nsources.env_keys\nPIPELINE_SLACK_CHANNEL\nsources.secrets_path\n%s\nnotifications.slack_channel\nCNOFILE' "$GHOME/.env")" "$(PATH="$SHIMDIR:$PATH" bash "$CFG_SH" --dump 2>/dev/null | tr '\0' '\n' | sed '/^$/d')" "(env) no config file: --dump carries the sources header plus the env pair"
assert_eq "0" "$(wc -l < "$PY_LOG" | tr -d ' ')" "(env) no config file: zero python3 spawns (#439 spawn guard holds)"
unset PIPELINE_SLACK_CHANNEL
assert_eq "$(printf 'sources.project\nsources.global\nsources.env_keys\nsources.secrets_path\n%s' "$GHOME/.env")" "$(PATH="$SHIMDIR:$PATH" bash "$CFG_SH" --dump 2>/dev/null | tr '\0' '\n' | sed '/^$/d')" "(env) no config file and no env: --dump is just the sources header"
assert_eq "0" "$(wc -l < "$PY_LOG" | tr -d ' ')" "(env) still zero python3 spawns"

# the merged global + repo + env config still costs one python3 spawn
reset_cfg
glob_json '{"limits":{"warn_at":0.5}}'
proj_json '{"notifications":{"slack_channel":"CREPO"}}'
export PIPELINE_SLACK_CHANNEL=CENV
: > "$PY_LOG"
cat > "$SANDBOX/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$1"
. "$SCRIPT_DIR/pipeline-cfg-cache.sh"
printf '%s %s %s\n' "$(cfg limits.warn_at "")" "$(cfg notifications.slack_channel "")" "$(cfg pr.draft x)"
PROBE
got="$(PATH="$SHIMDIR:$PATH" bash "$SANDBOX/probe.sh" "$TALOS_ROOT/scripts" 2>/dev/null)"
assert_eq "0.5 CENV x" "$got" "cfg() sees the global, repo and env layers through one dump"
assert_eq "1" "$(wc -l < "$PY_LOG" | tr -d ' ')" "global + repo + env costs exactly one python3 spawn (#169)"
unset PIPELINE_SLACK_CHANNEL

# ── Structure: one shared loader carries the new logic ───────────────────────
assert_eq "1" "$(grep -c '^def _drop_repo_only' "$CFG_SH")" "the repo-only filter is defined once, in the shared loader"
assert_eq "1" "$(grep -c '^def _apply_env' "$CFG_SH")" "the env layer is defined once, in the shared loader"

finish
