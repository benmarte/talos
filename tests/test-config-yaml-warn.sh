#!/usr/bin/env bash
# test-config-yaml-warn.sh -- covers #490: a YAML config (repo or user layer) was
# silently ignored when PyYAML could not be imported, so a user's settings
# reverted to the defaults with no message.
#
# PyYAML is hidden with a python3 shim on PATH inside the sandbox (nothing is
# uninstalled): it runs the real python3 with sys.modules['yaml'] = None, so
# `import yaml` raises ImportError.
#
#   1. repo YAML file, no PyYAML: ONE stderr line naming the file and the fix;
#      the lookup still exits 0 and returns the default (no crash)
#   2. --dump and the user-level (global) layer warn the same way, one line per file
#   3. a JSON config (and JSON content in a .yml) stays silent
#   4. with PyYAML available, a YAML config is read and nothing is warned
#   5. every call is its own process: a stamp under $TMPDIR limits the note to
#      once per file (until the file changes); a user-level YAML file gets that
#      one line, not also the older "unreadable or malformed" one
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
REAL_PY="$(command -v python3)"
SHIM="$SANDBOX/shim"
PROJ="$SANDBOX/project"
GHOME="$SANDBOX/talos-home"
ERR="$SANDBOX/stderr"
mkdir -p "$SHIM" "$PROJ" "$GHOME" || exit 1
cd "$PROJ" || exit 1

cat > "$SHIM/python3" <<TALOS_SHIMx7Kq2Wm9Pd4Lt
#!/usr/bin/env bash
# python3 without PyYAML: handles the "-I -c CODE" and "-I -" (script on stdin) forms.
[ "\${1:-}" = "-I" ] && shift
case "\${1:-}" in
  -c) code="\$2"; shift 2 ;;
  -)  shift; code="\$(cat)" ;;
  *)  exec "$REAL_PY" -I "\$@" ;;
esac
exec "$REAL_PY" -I -c 'import sys; sys.modules["yaml"] = None; c = sys.argv[1]; sys.argv = ["-c"] + sys.argv[2:]; exec(compile(c, "<string>", "exec"), {"__name__": "__main__"})' "\$code" "\$@"
TALOS_SHIMx7Kq2Wm9Pd4Lt
chmod +x "$SHIM/python3"

# Precondition: the shim really hides PyYAML.
shim_rc=0
env PATH="$SHIM:$PATH" python3 -I -c 'import yaml' 2>/dev/null || shim_rc=$?
assert_eq "1" "$shim_rc" "precondition: the python3 shim cannot import yaml"

nolines() { wc -l < "$1" | tr -d ' '; }
unset PIPELINE_CONFIG
export TALOS_HOME="$GHOME"
# Stamps go inside the sandbox, never the real $TMPDIR. Sections 1-4 count the
# note per process, so they opt out of the cross-process dedupe (section 5 uses it).
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR" || exit 1
export TALOS_YAML_WARN_DEDUP=0

# ---- 1. repo YAML file, no PyYAML -------------------------------------------
printf 'pr:\n  draft: false\n' > "$PROJ/talos.pipeline.yml"
out="$(env PATH="$SHIM:$PATH" bash "$CFG_SH" pr.draft SENT 2>"$ERR")"; rc=$?
assert_eq "0" "$rc" "repo .yml without PyYAML: still exits 0 (no crash)"
assert_eq "SENT" "$out" "repo .yml without PyYAML: the default is returned"
assert_eq "1" "$(nolines "$ERR")" "repo .yml without PyYAML: exactly one stderr line"
assert_contains "$(cat "$ERR")" "talos.pipeline.yml" "repo .yml without PyYAML: the line names the file"
assert_contains "$(cat "$ERR")" "pip install pyyaml" "repo .yml without PyYAML: the line names the fix"
assert_contains "$(cat "$ERR")" ".json" "repo .yml without PyYAML: the line offers the .json form"

# ---- 2. --dump, and the user-level layer ------------------------------------
env PATH="$SHIM:$PATH" bash "$CFG_SH" --dump >/dev/null 2>"$ERR"; rc=$?
assert_eq "0" "$rc" "--dump without PyYAML: exits 0"
assert_eq "1" "$(nolines "$ERR")" "--dump without PyYAML: exactly one stderr line"

printf 'limits:\n  warn_at: 0.6\n' > "$GHOME/talos.pipeline.yml"
chmod 600 "$GHOME/talos.pipeline.yml"
out="$(env PATH="$SHIM:$PATH" bash "$CFG_SH" limits.warn_at SENT 2>"$ERR")"; rc=$?
assert_eq "0" "$rc" "global .yml without PyYAML: still exits 0"
assert_eq "2" "$(grep -c 'pip install pyyaml' "$ERR")" "global + repo .yml: one fix line per YAML file"
assert_contains "$(cat "$ERR")" "$GHOME" "global .yml without PyYAML: a line names the global file"
assert_not_contains "$(cat "$ERR")" "malformed" "global .yml without PyYAML: no second, older line for the same file"
rm -f "$GHOME/talos.pipeline.yml" "$PROJ/talos.pipeline.yml"

# ---- 3. JSON stays silent ----------------------------------------------------
printf '{"pr": {"draft": false}}' > "$PROJ/talos.pipeline.json"
out="$(env PATH="$SHIM:$PATH" bash "$CFG_SH" pr.draft SENT 2>"$ERR")"
assert_eq "false" "$out" "JSON config without PyYAML is still read"
assert_eq "0" "$(nolines "$ERR")" "JSON config without PyYAML: no warning"
rm -f "$PROJ/talos.pipeline.json"

printf '{"pr": {"draft": false}}' > "$PROJ/talos.pipeline.yml"
out="$(env PATH="$SHIM:$PATH" bash "$CFG_SH" pr.draft SENT 2>"$ERR")"
assert_eq "false" "$out" "JSON content in a .yml without PyYAML is still read"
assert_eq "0" "$(nolines "$ERR")" "JSON content in a .yml without PyYAML: no warning"
rm -f "$PROJ/talos.pipeline.yml"

# ---- 4. with PyYAML: read, no warning ----------------------------------------
if python3 -I -c 'import site, sys; sys.path.append(site.getusersitepackages()); import yaml' 2>/dev/null; then
  printf 'pr:\n  draft: false\n' > "$PROJ/talos.pipeline.yml"
  out="$(bash "$CFG_SH" pr.draft SENT 2>"$ERR")"
  assert_eq "false" "$out" "with PyYAML: the repo .yml is read"
  assert_eq "0" "$(nolines "$ERR")" "with PyYAML: no warning"
else
  echo "  skip: PyYAML not installed -- with-PyYAML case"
fi

# ---- 5. one warning per file across processes ---------------------------------
unset TALOS_YAML_WARN_DEDUP
printf 'pr:\n  draft: false\n' > "$PROJ/talos.pipeline.yml"
env PATH="$SHIM:$PATH" bash "$CFG_SH" pr.draft SENT >/dev/null 2>"$ERR"
assert_eq "1" "$(nolines "$ERR")" "dedupe: the first call warns"
env PATH="$SHIM:$PATH" bash "$CFG_SH" pr.draft SENT >/dev/null 2>"$ERR"
assert_eq "0" "$(nolines "$ERR")" "dedupe: a second call (new process) does not warn again"
env PATH="$SHIM:$PATH" bash "$CFG_SH" --dump >/dev/null 2>"$ERR"
assert_eq "0" "$(nolines "$ERR")" "dedupe: --dump (another process) does not warn again either"
out="$(env PATH="$SHIM:$PATH" bash "$CFG_SH" pr.draft SENT 2>/dev/null)"
assert_eq "SENT" "$out" "dedupe: the lookup still returns the default"
TALOS_YAML_WARN_DEDUP=0 env PATH="$SHIM:$PATH" bash "$CFG_SH" pr.draft SENT >/dev/null 2>"$ERR"
assert_eq "1" "$(nolines "$ERR")" "dedupe: TALOS_YAML_WARN_DEDUP=0 warns on every call"
touch -t 203001010000 "$PROJ/talos.pipeline.yml"
env PATH="$SHIM:$PATH" bash "$CFG_SH" pr.draft SENT >/dev/null 2>"$ERR"
assert_eq "1" "$(nolines "$ERR")" "dedupe: a changed file (new mtime) warns again"
stamp_dir="$TMPDIR/talos-yaml-warn-$(id -u)"
assert_eq "700" "$(stat -f %Lp "$stamp_dir" 2>/dev/null || stat -c %a "$stamp_dir")" "dedupe: the stamp dir is private (0700)"
# An unusable stamp location never hides the warning and never fails the lookup.
rm -rf "${stamp_dir:?}"
printf 'x' > "$stamp_dir"
env PATH="$SHIM:$PATH" TALOS_HOME="$GHOME" bash "$CFG_SH" pr.draft SENT >/dev/null 2>"$ERR"; rc=$?
assert_eq "0" "$rc" "dedupe: an unusable stamp dir does not fail the lookup"
assert_eq "1" "$(nolines "$ERR")" "dedupe: an unusable stamp dir still warns"
rm -f "$stamp_dir" "$PROJ/talos.pipeline.yml"

finish
