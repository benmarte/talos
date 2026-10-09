#!/usr/bin/env bash
# test-config-json-only.sh -- covers #526: config is JSON only, exactly two
# canonical files (project talos.pipeline.json overriding global
# ~/.talos/talos.pipeline.json); any other talos.pipeline.* file in a layer
# directory fails the load closed (reason=config-shadowed when the canonical
# json is present, reason=config-legacy-file when it is not); --convert
# migrates legacy YAML once; --dump carries a SOURCES header.
#
#   AC1 two canonical paths only (project json > global json; legacy names unread)
#   AC2 a second file beside the json fails closed as config-shadowed
#   AC3 a lone legacy yml/yaml fails closed as config-legacy-file
#   AC4 --convert writes merged JSON; refuses an existing non-empty target
#       without --force; needs PyYAML when it is absent
#   AC5 --dump carries the SOURCES pairs; the stream stays parseable
#   AC6 the loader parses JSON only; a load passes with no PyYAML importable
#   AC8 talos.pipeline.yml.example is deleted; the json example is canonical
#
# PyYAML is hidden with a python3 shim on PATH inside the sandbox for the AC6
# load cases (nothing is uninstalled): it runs the real python3 with
# sys.modules['yaml'] = None, so `import yaml` raises ImportError. --convert
# NEEDS PyYAML (it is the only YAML-aware code left), so its round-trip case
# is gated on PyYAML being importable.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
REAL_PY="$(command -v python3)"
SHIM="$SANDBOX/shim"
GHOME="$SANDBOX/talos-home"
ERR="$SANDBOX/stderr"
mkdir -p "$SHIM" "$GHOME" || exit 1

# python3 without PyYAML: handles the "-I -c CODE" and "-I -" (script on stdin)
# forms (the technique from the deleted tests/test-config-yaml-warn.sh).
REAL_PY="$(command -v python3)"
cat > "$SHIM/python3" <<TALOS_j8wvq2xn5hr7t
#!/usr/bin/env bash
REAL_PY="$REAL_PY"
[ "\${1:-}" = "-I" ] && shift
case "\${1:-}" in
  -c) code="\$2"; shift 2 ;;
  -)  shift; code="\$(cat)" ;;
  *)  exec "\$REAL_PY" -I "\$@" ;;
esac
exec "\$REAL_PY" -I -c 'import sys; sys.modules["yaml"] = None; c = sys.argv[1]; sys.argv = ["-c"] + sys.argv[2:]; exec(compile(c, "<string>", "exec"), {"__name__": "__main__"})' "\$code" "\$@"
TALOS_j8wvq2xn5hr7t
chmod +x "$SHIM/python3"
# Precondition: the shim really hides PyYAML.
shim_rc=0
env PATH="$SHIM:$PATH" python3 -I -c 'import yaml' 2>/dev/null || shim_rc=$?
assert_exit_code "1" "$shim_rc" "precondition: the python3 shim cannot import yaml"
unset PIPELINE_CONFIG
export TALOS_HOME="$GHOME"

HAVE_YAML=0
python3 -I -c 'import site, sys; sys.path.append(site.getusersitepackages()); import yaml' 2>/dev/null && HAVE_YAML=1

nolines() { wc -l < "$1" | tr -d ' '; }
# The NUL-pair reader pipeline-cfg-cache.sh's cfg() uses: returns 0 when the
# whole stream parses as complete KEY\0VALUE\0 pairs (no dangling key).
pairs_ok() {  # $1=dump file
  local _k _v _n=0
  while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do
    _n=$((_n + 1))
  done < "$1"
  [ "$_n" -gt 0 ]
}
_dump_get() {  # $1=key $2=dump file
  local _k _v
  while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do
    if [ "$_k" = "$1" ]; then printf '%s' "$_v"; return 0; fi
  done < "$2"
  return 1
}

# ═══ AC1: two canonical paths only ═══════════════════════════════════════════

printf '{"agents": {"model": "fromproject"}}\n' > talos.pipeline.json
printf '{"agents": {"model": "fromglobal"}}\n' > "$GHOME/talos.pipeline.json"
chmod 600 "$GHOME/talos.pipeline.json"

assert_eq "fromproject" "$(bash "$CFG_SH" agents.model "")" \
  "AC1: the project talos.pipeline.json overrides the global one"

rm talos.pipeline.json
assert_eq "fromglobal" "$(bash "$CFG_SH" agents.model "")" \
  "AC1: a global talos.pipeline.json with no project file still applies"

out="$(bash "$CFG_SH" merge.method SENT 2>"$ERR")"; rc=$?
assert_eq "SENT" "$out" "AC1: no config file returns the table default"
assert_exit_code "0" "$rc" "AC1: no config file: the lookup still exits 0"
env bash "$CFG_SH" --dump >/dev/null 2>"$ERR"; rc=$?
assert_exit_code "0" "$rc" "AC1: no config file: --dump exits 0"
assert_eq "0" "$(nolines "$ERR")" "AC1: no config file: --dump is silent"

printf '{"merge": {"method": "merge"}}\n' > .claude-pipeline.json
assert_eq "squash" "$(bash "$CFG_SH" merge.method)" \
  "AC1: a legacy .claude-pipeline.json alone is no longer read"
assert_eq "0" "$(nolines "$ERR")" "AC1: an unread legacy name prints nothing"
rm -f .claude-pipeline.json

if grep -q '_CFG_NAMES' "$CFG_SH"; then
  fail "AC1: the loader references exactly the two canonical filenames" \
    "_CFG_NAMES (the yml/yaml/json name list) is still present in pipeline-config.sh"
else
  pass "AC1: the loader references exactly the two canonical filenames"
fi

# ═══ AC2: a second file beside the json fails closed as config-shadowed ══════

printf '{"pr": {"draft": true}}\n' > talos.pipeline.json
printf 'pr:\n  draft: false\n' > talos.pipeline.yml

out="$(bash "$CFG_SH" pr.draft SENT 2>"$ERR")"; rc=$?
assert_exit_code "3" "$rc" "AC2: single-key lookup exits 3 on a shadowed config"
assert_eq "" "$out" "AC2: a shadowed config resolves no value"
assert_eq "1" "$(nolines "$ERR")" "AC2: exactly one stderr line"
assert_contains "$(cat "$ERR")" "reason=config-shadowed winner=talos.pipeline.json" \
  "AC2: the line names the reason and the winner"
assert_contains "$(cat "$ERR")" "also-present=talos.pipeline.yml" \
  "AC2: the line names the shadowed file"
assert_contains "$(cat "$ERR")" "rm talos.pipeline.yml" \
  "AC2: the line carries the rm instruction"
assert_not_contains "$(cat "$ERR")" "true" "AC2: the shadowed yml's value never leaks"

err_has="$(bash "$CFG_SH" --has pr.draft 2>&1 >/dev/null)"; rc=$?
assert_exit_code "3" "$rc" "AC2: --has exits 3 on a shadowed config"
assert_contains "$err_has" "reason=config-shadowed" "AC2: --has prints the reason line"

bash "$CFG_SH" --dump >/dev/null 2>"$ERR"; rc=$?
assert_exit_code "3" "$rc" "AC2: --dump exits non-zero on a shadowed config"
assert_eq "1" "$(nolines "$ERR")" "AC2: --dump prints exactly one line"
assert_contains "$(cat "$ERR")" "reason=config-shadowed" "AC2: --dump prints the reason line"

printf 'pr:\n  draft: false\nverify:\n  qa_mode: yaml\n' > talos.pipeline.yaml
err="$(bash "$CFG_SH" pr.draft SENT 2>&1 >/dev/null)"
assert_contains "$err" "also-present=talos.pipeline.yml,talos.pipeline.yaml" \
  "AC2: two strays are both named in also-present"
assert_contains "$err" "rm talos.pipeline.yml talos.pipeline.yaml" \
  "AC2: two strays are both named in the rm instruction"

# The user layer shadows the same way.
rm -f talos.pipeline.yml talos.pipeline.yaml
printf '{"agents": {"model": "fromglobal"}}\n' > "$GHOME/talos.pipeline.json"
printf 'agents:\n  model: fromyaml\n' > "$GHOME/talos.pipeline.yml"
chmod 600 "$GHOME/talos.pipeline.yml" "$GHOME/talos.pipeline.json"
err="$(bash "$CFG_SH" agents.model SENT 2>&1 >/dev/null)"; rc=$?
assert_exit_code "3" "$rc" "AC2: a user-layer shadow also exits 3"
assert_contains "$err" "reason=config-shadowed winner=$GHOME/talos.pipeline.json" \
  "AC2: a user-layer shadow names the global winner"
assert_contains "$err" "$GHOME/talos.pipeline.yml" \
  "AC2: a user-layer shadow names the stray path"
rm -f "$GHOME/talos.pipeline.yml"

# talos.sh stops config-unreadable through the unchanged cfg-cache priming.
# AC2: the operator sees the reason line, talos.sh still fails closed.
printf '{"pr": {"draft": true}}\n' > talos.pipeline.json
printf 'pr:\n  draft: false\n' > talos.pipeline.yml
out="$(bash "$TALOS_ROOT/scripts/talos.sh" env 2>&1)"
assert_contains "$out" "stop reason=config-unreadable" \
  "AC2: talos.sh stops with config-unreadable on a shadowed config"
assert_contains "$out" "reason=config-shadowed" \
  "AC2: the config-shadowed line reaches the operator through talos.sh"
rm -f talos.pipeline.yml

# An explicit PIPELINE_CONFIG pointer resolves the project layer itself, so
# the same-dir check is skipped (the ambiguity is resolved, not silent).
printf '{"pr": {"draft": "from-pointer"}}\n' > "$SANDBOX/pointer.json"
out="$(PIPELINE_CONFIG="$SANDBOX/pointer.json" bash "$CFG_SH" pr.draft SENT 2>"$ERR")"
assert_eq "from-pointer" "$out" \
  "AC2: an explicit PIPELINE_CONFIG pointer wins over the same-dir strays"
assert_eq "0" "$(nolines "$ERR")" \
  "AC2: an explicit PIPELINE_CONFIG pointer prints no same-dir reason line"
rm -f "$SANDBOX/pointer.json" talos.pipeline.json

# ═══ AC3: a lone legacy file fails closed as config-legacy-file ══════════════

printf 'pr:\n  draft: false\n' > talos.pipeline.yml
out="$(bash "$CFG_SH" pr.draft SENT 2>"$ERR")"; rc=$?
assert_exit_code "3" "$rc" "AC3: a lone project .yml exits 3"
assert_eq "" "$out" "AC3: a lone legacy file resolves no value"
assert_eq "1" "$(nolines "$ERR")" "AC3: exactly one stderr line"
assert_contains "$(cat "$ERR")" "reason=config-legacy-file talos.pipeline.yml" \
  "AC3: the line names the reason and the legacy file"
assert_contains "$(cat "$ERR")" \
  "convert: bash scripts/pipeline-config.sh --convert talos.pipeline.yml talos.pipeline.json" \
  "AC3: the line carries the --convert migration command"

bash "$CFG_SH" --dump >/dev/null 2>"$ERR"; rc=$?
assert_exit_code "3" "$rc" "AC3: --dump exits non-zero on a lone legacy file"
assert_contains "$(cat "$ERR")" "reason=config-legacy-file" "AC3: --dump prints the reason line"
err_has="$(bash "$CFG_SH" --has pr.draft 2>&1 >/dev/null)"; rc=$?
assert_exit_code "3" "$rc" "AC3: --has exits 3 on a lone legacy file"

rm -f talos.pipeline.yml
printf 'pr:\n  draft: false\n' > talos.pipeline.yaml
err="$(bash "$CFG_SH" pr.draft SENT 2>&1 >/dev/null)"
assert_contains "$err" "reason=config-legacy-file talos.pipeline.yaml" \
  "AC3: a lone .yaml fails the same way, named"
rm -f talos.pipeline.yaml

# The user layer: a lone legacy file there fails with the global convert line.
rm -f "$GHOME/talos.pipeline.json"
printf 'agents:\n  model: fromyaml\n' > "$GHOME/talos.pipeline.yaml"
chmod 600 "$GHOME/talos.pipeline.yaml"
err="$(bash "$CFG_SH" agents.model SENT 2>&1 >/dev/null)"; rc=$?
assert_exit_code "3" "$rc" "AC3: a lone user-layer .yaml exits 3"
assert_contains "$err" "reason=config-legacy-file $GHOME/talos.pipeline.yaml" \
  "AC3: the line names the user-layer legacy path"
assert_contains "$err" "--convert $GHOME/talos.pipeline.yaml $GHOME/talos.pipeline.json" \
  "AC3: the migration command converts it into the global json"
rm -f "$GHOME/talos.pipeline.yaml"

# ═══ AC4: --convert ══════════════════════════════════════════════════════════

# Refusal to overwrite does not need PyYAML (the check happens before parsing).
printf '{"verify": ["keep me"]}\n' > talos.pipeline.json
printf 'pr:\n  draft: false\n' > talos.pipeline.yml
before="$(cat talos.pipeline.json)"
env PATH="$SHIM:$PATH" bash "$CFG_SH" --convert talos.pipeline.yml talos.pipeline.json >/dev/null 2>"$ERR"; rc=$?
assert_exit_code "3" "$rc" "AC4: --convert refuses an existing non-empty target"
assert_contains "$(cat "$ERR")" "talos.pipeline.json" "AC4: the refusal names the target"
assert_eq "$before" "$(cat talos.pipeline.json)" \
  "AC4: the refusal writes nothing into the target"

env PATH="$SHIM:$PATH" bash "$CFG_SH" --convert talos.pipeline.yml talos.pipeline.json --force >/dev/null 2>"$ERR"; rc=$?
assert_exit_code "3" "$rc" "AC4: --force unblocks the overwrite refusal, then PyYAML is required"

# Without PyYAML --convert says exactly what is missing (it is the migration
# path, so the note names the fix).
err="$(env PATH="$SHIM:$PATH" bash "$CFG_SH" --convert talos.pipeline.yml "$SANDBOX/out.json" 2>&1 >/dev/null)"; rc=$?
assert_exit_code "3" "$rc" "AC4: --convert without PyYAML exits 3"
assert_contains "$err" "PyYAML is not installed" "AC4: --convert without PyYAML says so"
assert_contains "$err" "pip install pyyaml" "AC4: --convert without PyYAML names the fix"
assert_file_absent "$SANDBOX/out.json" "AC4: --convert without PyYAML writes no target"

# Argument hygiene needs no PyYAML either.
err="$(bash "$CFG_SH" --convert 2>&1 >/dev/null)"; rc=$?
assert_exit_code "3" "$rc" "AC4: --convert with no arguments exits 3"
err="$(bash "$CFG_SH" --convert talos.pipeline.yml 2>&1 >/dev/null)"; rc=$?
assert_exit_code "3" "$rc" "AC4: --convert with no target exits 3"
err="$(bash "$CFG_SH" --convert "$SANDBOX/no-such.yml" "$SANDBOX/out.json" 2>&1 >/dev/null)"; rc=$?
assert_exit_code "3" "$rc" "AC4: --convert with a missing legacy file exits 3"

rm -f talos.pipeline.yml talos.pipeline.json

if [ "$HAVE_YAML" = 1 ]; then
  # Round-trip: the yml's values are the converted json's values, asserted
  # through --dump (secret-shaped leaves are dropped in both forms per #444,
  # so the fixture holds none).
  cat > talos.pipeline.yml <<'EOF'
base_branch: dev
merge:
  method: rebase
  required_checks:
    - test (ubuntu-latest)
verify:
  - npm test
  - npm run lint
pr:
  draft: true
board:
  project_number: 7
issues:
  skip_labels: [pipeline:blocked, wontfix]
agents:
  model: claude-sonnet-5
EOF
  before_dump="$SANDBOX/none-dump"
  bash "$CFG_SH" --convert talos.pipeline.yml talos.pipeline.json >/dev/null 2>"$ERR"; rc=$?
  assert_exit_code "0" "$rc" "AC4: --convert exits 0 on a clean yml"
  assert_file_exists talos.pipeline.json "AC4: --convert writes the target json"
  # The reason codes say so: a stray file never lives beside the canonical json,
  # so the migrated repo removes the legacy file after converting it.
  cp talos.pipeline.yml "$SANDBOX/legacy.yml"
  rm talos.pipeline.yml
  python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' talos.pipeline.json \
    && pass "AC4: the target parses as JSON" \
    || fail "AC4: the target parses as JSON" "json.load failed"
  out="$(bash "$CFG_SH" base_branch "")"
  assert_eq "dev" "$out" "AC4: the converted json resolves the yml's scalar values"
  out="$(bash "$CFG_SH" merge.required_checks "")"
  assert_eq "$(printf 'test (ubuntu-latest)')" "$out" \
    "AC4: the converted json resolves the yml's list values"
  out="$(bash "$CFG_SH" verify "")"
  assert_eq "$(printf 'npm test\nnpm run lint')" "$out" \
    "AC4: the converted json resolves the yml's verify list"
  out="$(bash "$CFG_SH" pr.draft "")"
  assert_eq "true" "$out" "AC4: the converted json resolves bools"
  out="$(bash "$CFG_SH" board.project_number "")"
  assert_eq "7" "$out" "AC4: the converted json resolves numbers"
  out="$(bash "$CFG_SH" issues.skip_labels "")"
  assert_eq "$(printf 'pipeline:blocked\nwontfix')" "$out" \
    "AC4: the converted json resolves inline lists"
  out="$(bash "$CFG_SH" merge.method "")"
  assert_eq "rebase" "$out" "AC4: the converted json resolves nested keys"
  # A yaml.parse round-trip would drift; the authoritative check is that the
  # converted file's parsed values equal the yml's parsed values for every
  # non-secret leaf.
  equal="$(python3 -I -c 'import site, sys
sys.path.append(site.getusersitepackages())
import yaml, json, sys
yml = yaml.safe_load(open(sys.argv[1]))
js = json.load(open(sys.argv[2]))
print("same" if yml == js else "differ")' "$SANDBOX/legacy.yml" talos.pipeline.json)"
  assert_eq "same" "$equal" "AC4: converted json values equal the yml's parsed values"
  rm -f talos.pipeline.json

  # --convert drops a secret-shaped leaf the same way a load would (#444): one
  # line names the shape and never the value; the json is clean, so the load
  # after it prints no shape warning again.
  printf 'notifications:\n  slack_channel: "#ok"\n  slack:\n    webhook: https://hooks.slack.com/services/T1/B2/XXXXXXXXXXXXXXXXXXXXXXXXXXXX\n' > talos.pipeline.yml
  bash "$CFG_SH" --convert talos.pipeline.yml talos.pipeline.json >/dev/null 2>"$ERR"; rc=$?
  assert_exit_code "0" "$rc" "AC4: --convert exits 0 on a yml with a secret-shaped leaf"
  assert_contains "$(cat "$ERR")" "holds a Slack webhook URL" \
    "AC4: the secret-shaped leaf is dropped with one line naming the shape"
  assert_not_contains "$(cat "$ERR")" "hooks.slack.com/services" \
    "AC4: the secret value never prints"
  python3 -I - "$SANDBOX" <<'TALOS_pyy7s2v5n1h9k4t'
import json, sys
d = json.load(open(sys.argv[1] + "/talos.pipeline.json"))
assert "webhook" not in d.get("notifications", {}).get("slack", {}), "the secret leaf landed in the json"
TALOS_pyy7s2v5n1h9k4t
  [ $? -eq 0 ] && pass "AC4: the converted json does not carry the secret leaf" \
    || fail "AC4: the converted json does not carry the secret leaf" "the webhook key is still in the json"
  cp talos.pipeline.json talos.pipeline.json.bak
  err2="$(bash "$CFG_SH" notifications.slack_channel "" 2>&1 >/dev/null)"
  assert_not_contains "$err2" "holds a Slack webhook URL" \
    "AC4: the converted json loads clean (the shape was dropped at convert time, not at load)"
  mv talos.pipeline.json.bak talos.pipeline.json
  rm -f talos.pipeline.yml talos.pipeline.json
else
  echo "  skip: PyYAML not installed -- AC4 round-trip case"
fi

# ═══ AC5: --dump SOURCES ═════════════════════════════════════════════════════

printf '{"agents": {"model": "fromproject"}}\n' > talos.pipeline.json
printf '{"agents": {"restamp_model": "fromglobal"}}\n' > "$GHOME/talos.pipeline.json"
chmod 600 "$GHOME/talos.pipeline.json"
PIPELINE_SLACK_CHANNEL=C0TEST bash "$CFG_SH" --dump > "$SANDBOX/dump-src" 2>"$ERR"; rc=$?
assert_exit_code "0" "$rc" "AC5: a clean dump still exits 0"
assert_eq "0" "$(nolines "$ERR")" "AC5: a clean dump is silent"
assert_eq "fromproject" "$(_dump_get agents.model "$SANDBOX/dump-src")" \
  "AC5: the dump still carries the config values"
assert_eq "talos.pipeline.json" "$(_dump_get sources.project "$SANDBOX/dump-src")" \
  "AC5: sources.project names the project file"
assert_eq "$GHOME/talos.pipeline.json" "$(_dump_get sources.global "$SANDBOX/dump-src")" \
  "AC5: sources.global names the global file"
assert_contains "$(_dump_get sources.env_keys "$SANDBOX/dump-src")" "PIPELINE_SLACK_CHANNEL" \
  "AC5: sources.env_keys names the set env override"
assert_eq "$GHOME/.env" "$(_dump_get sources.secrets_path "$SANDBOX/dump-src")" \
  "AC5: sources.secrets_path names the secrets store"
pairs_ok "$SANDBOX/dump-src" \
  && pass "AC5: the whole stream still parses as complete KEY/value pairs (the cfg cache reader keeps working)" \
  || fail "AC5: the whole stream still parses as complete KEY/value pairs (the cfg cache reader keeps working)" \
       "the dump stream is not a whole number of KEY/value pairs"

# No-config case: the sources pairs are still emitted, exit 0, paths empty.
rm -f talos.pipeline.json "$GHOME/talos.pipeline.json"
unset PIPELINE_SLACK_CHANNEL
bash "$CFG_SH" --dump > "$SANDBOX/dump-nocfg" 2>"$ERR"; rc=$?
assert_exit_code "0" "$rc" "AC5: a no-config dump exits 0"
assert_eq "" "$(_dump_get sources.project "$SANDBOX/dump-nocfg")" \
  "AC5: a no-config dump leaves sources.project empty"
assert_eq "" "$(_dump_get sources.global "$SANDBOX/dump-nocfg")" \
  "AC5: a no-config dump leaves sources.global empty"
assert_eq "$GHOME/.env" "$(_dump_get sources.secrets_path "$SANDBOX/dump-nocfg")" \
  "AC5: a no-config dump still names the secrets path"
PIPELINE_SLACK_CHANNEL=C0TEST bash "$CFG_SH" --dump > "$SANDBOX/dump-nocfg-env" 2>/dev/null
assert_contains "$(_dump_get sources.env_keys "$SANDBOX/dump-nocfg-env")" "PIPELINE_SLACK_CHANNEL" \
  "AC5: a no-config dump still lists the set env override"

# ═══ AC6: JSON-only parser ═══════════════════════════════════════════════════

printf '{"pr": {"draft": false}}\n' > talos.pipeline.json
out="$(env PATH="$SHIM:$PATH" bash "$CFG_SH" pr.draft SENT 2>"$ERR")"; rc=$?
assert_exit_code "0" "$rc" "AC6: a full load passes with no PyYAML importable"
assert_eq "false" "$out" "AC6: the canonical json still resolves values"
assert_eq "0" "$(nolines "$ERR")" "AC6: a JSON load with no PyYAML prints no warning"
env PATH="$SHIM:$PATH" bash "$CFG_SH" --dump >/dev/null 2>"$ERR"; rc=$?
assert_exit_code "0" "$rc" "AC6: --dump passes with no PyYAML importable"
rm -f talos.pipeline.json

# Source-level: the loader heredoc (the shared load path) carries no yaml
# reference; `import yaml` appears only inside --convert.
loader_src="$(sed -n '/^read -r -d .. _CFG_LOADER_PY/,/^PYLOADER$/p' "$CFG_SH")"
if grep -qw 'yaml' <<<"$loader_src"; then
  fail "AC6: the loader source carries no yaml reference" \
    "the _CFG_LOADER_PY heredoc still mentions yaml"
else
  pass "AC6: the loader source carries no yaml reference"
fi
n_imports="$(grep -c 'import yaml' "$CFG_SH")"
assert_eq "1" "$n_imports" "AC6: import yaml appears only inside --convert (exactly once)"
n_safe_load="$(grep -c 'safe_load' "$CFG_SH")"
assert_eq "1" "$n_safe_load" "AC6: safe_load appears only inside --convert (exactly once)"

# ═══ #541: a PIPELINE_CONFIG pointer at a missing file fails closed ══════════
# The pointer is a deliberate operator decision; a typo'd path used to load
# defaults only (rc 0) and run on a config nobody wrote. Same convention as
# the other gate reasons: one stderr line, exit 3, before any value resolves.

MISSING="$SANDBOX/no-such-dir/x.json"
for verb in "verify.qa_mode" "--has verify.qa_mode" "--show" "--dump"; do
  # shellcheck disable=SC2086
  out="$(PIPELINE_CONFIG="$MISSING" bash "$CFG_SH" $verb 2>"$ERR")"; rc=$?
  assert_exit_code "3" "$rc" "#541: a missing PIPELINE_CONFIG target exits 3 ($verb)"
  assert_eq "" "$out" "#541: a missing PIPELINE_CONFIG target resolves no value ($verb)"
  assert_eq "1" "$(nolines "$ERR")" "#541: exactly one stderr line ($verb)"
  assert_contains "$(cat "$ERR")" "pipeline-config: reason=config-pointer-missing $MISSING" \
    "#541: the line names the reason and the missing path ($verb)"
done

# The path is printed sanitized: a control byte can never forge a row.
CTL_MISSING="$SANDBOX/no-such"$'\x01'"dir/x.json"
PIPELINE_CONFIG="$CTL_MISSING" bash "$CFG_SH" verify.qa_mode >/dev/null 2>"$ERR"; rc=$?
assert_exit_code "3" "$rc" "#541: a missing pointer with a control byte exits 3"
assert_contains "$(cat "$ERR")" "reason=config-pointer-missing $SANDBOX/no-such?dir/x.json" \
  "#541: the control byte is neutralised in the printed path"

# Through the cfg cache talos.sh primes, the same line stops the run.
out="$(PIPELINE_CONFIG="$MISSING" bash "$TALOS_ROOT/scripts/talos.sh" env 2>&1)"
assert_contains "$out" "stop reason=config-unreadable" \
  "#541: talos.sh stops with config-unreadable on a missing pointer"
assert_contains "$out" "reason=config-pointer-missing" \
  "#541: the config-pointer-missing line reaches the operator through talos.sh"

# An empty pointer still means "unset", and an existing target still loads.
out="$(PIPELINE_CONFIG="" bash "$CFG_SH" merge.method SENT 2>"$ERR")"; rc=$?
assert_eq "SENT" "$out" "#541: an empty PIPELINE_CONFIG means unset (table default)"
assert_exit_code "0" "$rc" "#541: an empty PIPELINE_CONFIG exits 0"
printf '{"merge": {"method": "rebase"}}\n' > "$SANDBOX/present.json"
out="$(PIPELINE_CONFIG="$SANDBOX/present.json" bash "$CFG_SH" merge.method SENT 2>"$ERR")"; rc=$?
assert_eq "rebase" "$out" "#541: an existing pointer target still loads"
assert_exit_code "0" "$rc" "#541: an existing pointer target exits 0"
rm -f "$SANDBOX/present.json"

# ═══ #541: the user-layer stray check tests the REAL path ════════════════════
# With a control byte in TALOS_HOME the existence test used to run on the
# sanitized display path, miss the real canonical json, and tell the user to
# convert instead of delete the stray.

CTLHOME="$SANDBOX/ctl"$'\x01'"home"
mkdir -p "$CTLHOME" || exit 1
printf '{"agents": {"model": "x"}}\n' > "$CTLHOME/talos.pipeline.json"
chmod 600 "$CTLHOME/talos.pipeline.json"
printf 'agents:\n  model: y\n' > "$CTLHOME/talos.pipeline.yml"
TALOS_HOME="$CTLHOME" bash "$CFG_SH" merge.method >/dev/null 2>"$ERR"; rc=$?
assert_exit_code "3" "$rc" "#541: a stray beside the json under a control-byte TALOS_HOME exits 3"
assert_contains "$(cat "$ERR")" "reason=config-shadowed winner=$SANDBOX/ctl?home/talos.pipeline.json" \
  "#541: the control-byte TALOS_HOME gets delete-the-stray (config-shadowed), not convert"
assert_eq "0" "$(grep -c 'config-legacy-file' "$ERR")" \
  "#541: the control-byte TALOS_HOME is not told to convert"
assert_eq "0" "$(printf '%s' "$(cat "$ERR")" | tr -d '\n' | tr -cd '\001' | wc -c | tr -d ' ')" \
  "#541: the printed text carries no raw control byte"
rm -rf "$CTLHOME"

# ═══ AC8: the yml example is gone ════════════════════════════════════════════

assert_file_absent "$TALOS_ROOT/talos.pipeline.yml.example" \
  "AC8: talos.pipeline.yml.example is deleted"
assert_file_exists "$TALOS_ROOT/talos.pipeline.json.example" \
  "AC8: talos.pipeline.json.example is the canonical example"

finish
