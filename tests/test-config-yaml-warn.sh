#!/usr/bin/env bash
# test-config-yaml-warn.sh -- #490's subject changed shape in #526: config is
# JSON only, so there is no "a YAML config was silently ignored without
# PyYAML" path anymore. The file keeps its name (the suite's count check
# requires every test file that exists on the base ref to exist here) and now
# pins the successor behavior:
#
#   1. a legacy talos.pipeline.yml with no json in its layer directory fails
#      the load closed with reason=config-legacy-file (no "pip install pyyaml"
#      note anywhere -- that warn machinery is deleted)
#   2. a clean json load with no PyYAML importable is silent (the loader never
#      imports yaml)
#   3. the script has no yaml import at all (the --convert verb was removed, #553)
#
# PyYAML is hidden with a python3 shim on PATH inside the sandbox (nothing is
# uninstalled): it runs the real python3 with sys.modules['yaml'] = None, so
# `import yaml` raises ImportError.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
REAL_PY="$(command -v python3)"
SHIM="$SANDBOX/shim"
GHOME="$SANDBOX/talos-home"
ERR="$SANDBOX/stderr"
mkdir -p "$SHIM" "$GHOME" || exit 1
unset PIPELINE_CONFIG
export TALOS_HOME="$GHOME"

cat > "$SHIM/python3" <<TALOS_SHIMy5Tq8Wm2Pd6Kt
#!/usr/bin/env bash
# python3 without PyYAML: handles the "-I -c CODE" and "-I -" (script on stdin) forms.
[ "\${1:-}" = "-I" ] && shift
case "\${1:-}" in
  -c) code="\$2"; shift 2 ;;
  -)  shift; code="\$(cat)" ;;
  *)  exec "$REAL_PY" -I "\$@" ;;
esac
exec "$REAL_PY" -I -c 'import sys; sys.modules["yaml"] = None; c = sys.argv[1]; sys.argv = ["-c"] + sys.argv[2:]; exec(compile(c, "<string>", "exec"), {"__name__": "__main__"})' "\$code" "\$@"
TALOS_SHIMy5Tq8Wm2Pd6Kt
chmod +x "$SHIM/python3"

# Precondition: the shim really hides PyYAML.
shim_rc=0
env PATH="$SHIM:$PATH" python3 -I -c 'import yaml' 2>/dev/null || shim_rc=$?
assert_eq "1" "$shim_rc" "precondition: the python3 shim cannot import yaml"

nolines() { wc -l < "$1" | tr -d ' '; }

# ---- 1. a lone legacy yml fails closed, and the old #490 warn is gone --------
printf 'pr:\n  draft: false\n' > talos.pipeline.yml
out="$(env PATH="$SHIM:$PATH" bash "$CFG_SH" pr.draft SENT 2>"$ERR")"; rc=$?
assert_eq "3" "$rc" "a lone legacy .yml fails the load closed (#526)"
assert_eq "" "$out" "a lone legacy .yml resolves no value"
assert_eq "1" "$(nolines "$ERR")" "a lone legacy .yml: exactly one stderr line"
assert_contains "$(cat "$ERR")" "reason=config-legacy-file" "the line names the legacy reason"
assert_not_contains "$(cat "$ERR")" "pip install pyyaml" "the deleted #490 warn is gone (no pip install pyyaml note)"
assert_not_contains "$(cat "$ERR")" "TALOS_YAML_WARN_DEDUP" "the deleted dedupe knob is gone from behavior and docs"
assert_not_contains "$(cat "$ERR")" ".json form" "the deleted '.json form' advice is gone"
rm -f talos.pipeline.yml

# ---- 2. a clean json load with no PyYAML importable is silent ----------------
printf '{"pr": {"draft": false}}\n' > talos.pipeline.json
out="$(env PATH="$SHIM:$PATH" bash "$CFG_SH" pr.draft SENT 2>"$ERR")"; rc=$?
assert_eq "0" "$rc" "a json load without PyYAML: still exits 0 (no crash)"
assert_eq "false" "$out" "a json load without PyYAML: the value is returned"
assert_eq "0" "$(nolines "$ERR")" "a json load without PyYAML: silent"
env PATH="$SHIM:$PATH" bash "$CFG_SH" --dump >/dev/null 2>"$ERR"; rc=$?
assert_eq "0" "$rc" "--dump without PyYAML: exits 0"
assert_eq "0" "$(nolines "$ERR")" "--dump without PyYAML: silent"
rm -f talos.pipeline.json

# ---- 3. nothing in the script reads YAML (the --convert verb is gone, #553) -
n_imports="$(grep -c 'import yaml' "$CFG_SH")"
assert_eq "0" "$n_imports" "no yaml import anywhere in the script"
if grep -q '_YAML_WARNED\|_yaml_warn_due\|_NoYamlError\|TALOS_YAML_WARN_DEDUP' "$CFG_SH"; then
  fail "the #490 machinery is deleted" "_YAML_WARNED/_yaml_warn_due/_NoYamlError/TALOS_YAML_WARN_DEDUP still present"
else
  pass "the #490 machinery is deleted"
fi

finish
