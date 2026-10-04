#!/usr/bin/env bash
# test-config-fail-closed.sh -- two #439 review items closed by #440 (epic #437):
#
#  (1) Fail closed. Once no call site passes a default, a missing, unreadable,
#      truncated or incomplete (no final sentinel, or a security row deleted)
#      scripts/pipeline-defaults.sh would make security-relevant keys read empty
#      (merge.auto, limits.*, hooks.*, roles.qa/reviewer/security, the
#      forbidden-files and approval-waiver lists, markers.*_authors). They now exit non-zero instead -- from
#      pipeline-config.sh (exit 3) and from cfg() (which ends the script, also
#      from inside a $(...) subshell). Every other key keeps degrading to empty
#      with one warning, and an explicit caller default still wins.
#  (2) `pipeline-config.sh --has KEY` has its own exit code for a config file
#      that does not parse: 0 set, 1 absent, 3 unknown (parse error).
#
# The sandbox has its own TALOS_HOME and HOME: the real ~/.talos is never read.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
export TALOS_HOME="$SANDBOX/talos-home"
mkdir -p "$TALOS_HOME" || exit 1
PROJ="$SANDBOX/project"
mkdir -p "$PROJ" || exit 1
cd "$PROJ" || exit 1
unset PIPELINE_CONFIG

SCRIPTS="$TALOS_ROOT/scripts"
CFG_SH="$SCRIPTS/pipeline-config.sh"

# ── The sandbox is hermetic: nothing from a real ~/.talos can answer ─────────
assert_eq "$SANDBOX/talos-home" "$TALOS_HOME" "TALOS_HOME is the sandbox directory"
case "$HOME" in "$SANDBOX"/*) pass "HOME is inside the sandbox" ;; *) fail "HOME is inside the sandbox" "HOME=$HOME" ;; esac

# ── (2) --has: its own exit code for a parse error ───────────────────────────
printf '%s\n' '{"status": {"enabled": true}}' > talos.pipeline.json
bash "$CFG_SH" --has status.enabled; _rc=$?
assert_eq "0" "$_rc" "--has: a key that is set exits 0"
bash "$CFG_SH" --has evidence.enabled; _rc=$?
assert_eq "1" "$_rc" "--has: an absent key in a good config exits 1"
printf '%s\n' '{"status": {"enabled": ' > talos.pipeline.json
bash "$CFG_SH" --has status.enabled 2>"$SANDBOX/err"; _rc=$?
assert_eq "3" "$_rc" "--has: a config that does not parse exits 3, not 1"
assert_contains "$(cat "$SANDBOX/err")" "could not be parsed" "--has: the parse error is explained on stderr"
assert_not_contains "$(cat "$SANDBOX/err")" "enabled" "--has: the message does not echo config content"
# a key found in the layer that did parse is still set
printf '%s\n' '{"status": {"enabled": true}}' > "$TALOS_HOME/talos.pipeline.json"
bash "$CFG_SH" --has status.enabled 2>/dev/null; _rc=$?
assert_eq "0" "$_rc" "--has: a key set in the global file is found although the repo file is malformed"
bash "$CFG_SH" --has evidence.enabled 2>/dev/null; _rc=$?
assert_eq "3" "$_rc" "--has: an absent key with a malformed repo file is unknown (3)"
rm -f "$TALOS_HOME/talos.pipeline.json" "$PROJ/talos.pipeline.json"
# a malformed global file counts as well
printf '%s\n' '{"status": ' > "$TALOS_HOME/talos.pipeline.json"
printf '%s\n' '{"board": {"enabled": true}}' > "$PROJ/talos.pipeline.json"
bash "$CFG_SH" --has status.enabled 2>/dev/null; _rc=$?
assert_eq "3" "$_rc" "--has: an absent key with a malformed global file is unknown (3)"
bash "$CFG_SH" --has board.enabled 2>/dev/null; _rc=$?
assert_eq "0" "$_rc" "--has: a key set in the good repo file is still 0"
rm -f "$TALOS_HOME/talos.pipeline.json" "$PROJ/talos.pipeline.json"
bash "$CFG_SH" --has status.enabled; _rc=$?
assert_eq "1" "$_rc" "--has: no config at all exits 1"

# ── (1) fail closed without a usable pipeline-defaults.sh ────────────────────
# "Usable" is pipeline-defaults-check.sh: readable, complete (ends with its
# sentinel) and holding a row for every security-relevant key. Each variant
# below is a scripts dir of symlinks to the real scripts with its own copy of
# the table, damaged in one way.
SEC_KEYS="merge.forbidden_files merge.forbidden_files_replace merge.forbidden_files_allow
merge.approval_waiver_paths merge.auto markers.verify_authors markers.trusted_authors
limits.max_fix_attempts limits.max_total_dispatches limits.max_retries limits.tokens_per_issue limits.warn_at
hooks.pre_dispatch hooks.post_stage hooks.timeout_s
roles.qa roles.reviewer roles.security"

cat > "$SANDBOX/probe-closed.sh" <<'TALOS_PRBfc3Xw8Kn5Dz'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$1"; KEY="$2"; MODE="${3:-plain}"
. "$SCRIPT_DIR/pipeline-cfg-cache.sh"
case "$MODE" in
  default) v="$(cfg "$KEY" fallback)" ;;
  *) v="$(cfg "$KEY")" ;;
esac
echo "reached:[$v]"
TALOS_PRBfc3Xw8Kn5Dz

# variant_dir NAME -- a scripts dir without a table; prints its path
variant_dir() {
  local d="$SANDBOX/variant-$1" f b
  mkdir -p "$d" || return 1
  for f in "$SCRIPTS"/*.sh; do
    b="$(basename "$f")"
    [ "$b" = "pipeline-defaults.sh" ] && continue
    ln -s "$f" "$d/$b"
  done
  printf '%s' "$d"
}

# check_closed DIR LABEL -- every security key fails closed, others degrade
check_closed() {
  local d="$1" label="$2" scope="${3:-}" key out rc
  for key in $SEC_KEYS; do
    out="$(bash "$d/pipeline-config.sh" "$key" 2>"$SANDBOX/err")"; rc=$?
    assert_eq "3" "$rc" "$label: pipeline-config.sh $key exits 3"
    assert_eq "" "$out" "$label: pipeline-config.sh $key prints nothing"
    assert_contains "$(cat "$SANDBOX/err")" "$key" "$label: the error names $key"
  done
  printf '%s\n' '{"agents": {"model": "m"}}' > "$PROJ/talos.pipeline.json"
  bash "$d/pipeline-config.sh" merge.auto >/dev/null 2>&1; rc=$?
  assert_eq "3" "$rc" "$label: a config that does not set merge.auto still exits 3 (python3 path)"
  printf '%s\n' '{"merge": {"auto": false}, "limits": {"max_fix_attempts": 4}}' > "$PROJ/talos.pipeline.json"
  assert_eq "false" "$(bash "$d/pipeline-config.sh" merge.auto 2>/dev/null)" "$label: a key the config sets is still read"
  assert_eq "4" "$(bash "$d/pipeline-config.sh" limits.max_fix_attempts 2>/dev/null)" "$label: limits.max_fix_attempts set in the config is read"
  rm -f "$PROJ/talos.pipeline.json"
  assert_eq "true" "$(bash "$d/pipeline-config.sh" merge.auto true 2>/dev/null)" "$label: an explicit caller default still answers for a security key"
  assert_contains "$(bash "$d/pipeline-config.sh" merge.auto true 2>&1 >/dev/null)" "pipeline-defaults.sh missing or unusable" "$label: the table problem is reported on stderr"
  if [ "$scope" != "all" ]; then
    out="$(bash "$d/pipeline-config.sh" board.enabled 2>/dev/null)"; rc=$?
    assert_eq "0" "$rc" "$label: a non-security key still exits 0"
    assert_eq "" "$out" "$label: a non-security key still prints nothing"
    assert_eq "reached:[]" "$(bash "$SANDBOX/probe-closed.sh" "$d" board.enabled 2>/dev/null)" \
      "$label: cfg of a non-security key degrades to empty"
  fi
  for key in merge.auto limits.max_fix_attempts hooks.pre_dispatch markers.verify_authors merge.forbidden_files limits.max_total_dispatches roles.qa roles.reviewer roles.security; do
    out="$(bash "$SANDBOX/probe-closed.sh" "$d" "$key" 2>/dev/null)"; rc=$?
    assert_eq "" "$out" "$label: cfg $key ends the script before the caller uses the value"
    assert_eq "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)" "$label: cfg $key exits non-zero (rc $rc)"
  done
  assert_eq "reached:[fallback]" "$(bash "$SANDBOX/probe-closed.sh" "$d" merge.auto default 2>/dev/null)" \
    "$label: cfg KEY default: the caller's default still answers"
}

# missing
D="$(variant_dir missing)" || exit 1
check_closed "$D" "missing table"

# present but unreadable (a root user reads mode 000, so the case cannot be set up)
D="$(variant_dir unreadable)" || exit 1
cp "$SCRIPTS/pipeline-defaults.sh" "$D/pipeline-defaults.sh" || exit 1
chmod 000 "$D/pipeline-defaults.sh" || exit 1
if [ "$(id -u)" -eq 0 ]; then
  pass "unreadable table: skipped (running as root)"
else
  check_closed "$D" "unreadable table"
fi
chmod 600 "$D/pipeline-defaults.sh"

# truncated: the first half of the file (inside the heredoc)
D="$(variant_dir truncated)" || exit 1
_lines="$(wc -l < "$SCRIPTS/pipeline-defaults.sh" | tr -d ' ')"
head -n $((_lines / 2)) "$SCRIPTS/pipeline-defaults.sh" > "$D/pipeline-defaults.sh" || exit 1
check_closed "$D" "truncated table"

# every line but the final sentinel
D="$(variant_dir nosentinel)" || exit 1
grep -v '^_TALOS_DEFAULTS_END=1$' "$SCRIPTS/pipeline-defaults.sh" > "$D/pipeline-defaults.sh" || exit 1
assert_eq "0" "$(grep -c '^_TALOS_DEFAULTS_END=1$' "$D/pipeline-defaults.sh" || true)" "the no-sentinel variant has no sentinel line"
check_closed "$D" "table without its sentinel"

# a security-relevant row deleted
D="$(variant_dir norow)" || exit 1
grep -v "^markers.verify_authors$(printf '\t')" "$SCRIPTS/pipeline-defaults.sh" > "$D/pipeline-defaults.sh" || exit 1
assert_eq "0" "$(grep -c "^markers.verify_authors$(printf '\t')" "$D/pipeline-defaults.sh" || true)" "the missing-row variant has no markers.verify_authors row"
check_closed "$D" "table missing a security row"

# the check helper itself missing: nothing can say which keys are safe
D="$(variant_dir nocheck)" || exit 1
rm -f "$D/pipeline-defaults-check.sh"
cp "$SCRIPTS/pipeline-defaults.sh" "$D/pipeline-defaults.sh" || exit 1
check_closed "$D" "check helper missing" all
out="$(bash "$D/pipeline-config.sh" board.enabled 2>/dev/null)"; rc=$?
assert_eq "3" "$rc" "check helper missing: even a non-security key fails closed (nothing can classify it)"

# an intact table: nothing changes, and no python3 is spawned without a config
PYBIN="$SANDBOX/pybin"
mkdir -p "$PYBIN" || exit 1
REAL_PY="$(command -v python3)"
PYLOG="$SANDBOX/py.log"
: > "$PYLOG"
printf '#!/bin/sh\necho spawn >> "%s"\nexec "%s" "$@"\n' "$PYLOG" "$REAL_PY" > "$PYBIN/python3"
chmod +x "$PYBIN/python3"
assert_eq "reached:[true]" "$(PATH="$PYBIN:$PATH" bash "$SANDBOX/probe-closed.sh" "$SCRIPTS" merge.auto 2>/dev/null)" "intact table: cfg merge.auto is its default"
assert_eq "reached:[3]" "$(PATH="$PYBIN:$PATH" bash "$SANDBOX/probe-closed.sh" "$SCRIPTS" limits.max_fix_attempts 2>/dev/null)" "intact table: cfg limits.max_fix_attempts is 3"
assert_eq "0" "$(wc -l < "$PYLOG" | tr -d ' ')" "intact table, no config: zero python3 spawns"
assert_eq "3" "$(PATH="$PYBIN:$PATH" bash "$SCRIPTS/pipeline-config.sh" limits.max_fix_attempts 2>/dev/null)" "intact table: pipeline-config.sh answers from the table"
assert_eq "0" "$(wc -l < "$PYLOG" | tr -d ' ')" "intact table, no config: pipeline-config.sh spawns no python3 either"

# ── the one list of security keys ────────────────────────────────────────────
# _talos_security_key is derived from _TALOS_SECURITY_KEYS (no second list to
# drift): every listed key is security-relevant, so is every limits.*/hooks.*
# row of the table, and an ordinary key is not.
(
  . "$SCRIPTS/pipeline-defaults-check.sh"
  . "$SCRIPTS/pipeline-defaults.sh"
  for k in $_TALOS_SECURITY_KEYS; do
    _talos_security_key "$k" || echo "not-security:$k"
    _talos_defaults_row "$k" || echo "no-row:$k"
  done
  for k in $(sed -n -E 's/^((limits|hooks)\.[a-z_]*)'"$(printf '\t')"'.*/\1/p' "$SCRIPTS/pipeline-defaults.sh"); do
    _talos_security_key "$k" || echo "not-security:$k"
  done
  _talos_security_key board.enabled && echo "wrongly-security:board.enabled"
  _talos_security_key roles.docs && echo "wrongly-security:roles.docs"
  echo done
) > "$SANDBOX/seckeys.out" 2>&1
assert_eq "done" "$(cat "$SANDBOX/seckeys.out")" "_talos_security_key matches _TALOS_SECURITY_KEYS and the limits.*/hooks.* rows"

# ── a missing cfg cache helper is fatal (no per-call fallback) ───────────────
# The old fallback ran pipeline-config.sh per call inside $(...), where its exit 3
# is discarded, so a broken table read as "caps off". Every script that sources
# the cache now stops with one line, whether or not the table is intact.
NOCACHE_MSG="talos: pipeline-cfg-cache.sh missing; reinstall Talos"
NOCACHE_SCRIPTS="bootstrap-board pipeline-agent pipeline-budget pipeline-changelog pipeline-events
pipeline-hooks pipeline-mergebase pipeline-notify pipeline-status pipeline-status-file
pipeline-verify pipeline-vcs pipeline-worktree"
for variant in intact broken; do
  D="$(variant_dir "nocache-$variant")" || exit 1
  rm -f "$D/pipeline-cfg-cache.sh"
  if [ "$variant" = intact ]; then
    cp "$SCRIPTS/pipeline-defaults.sh" "$D/pipeline-defaults.sh" || exit 1
  else
    printf '%s' 'truncated' > "$D/pipeline-defaults.sh"
  fi
  for name in $NOCACHE_SCRIPTS; do
    out="$(bash "$D/$name.sh" 2>&1 </dev/null)"; rc=$?
    assert_eq "1" "$rc" "no cache helper, $variant table: $name exits 1"
    assert_eq "$NOCACHE_MSG" "$out" "no cache helper, $variant table: $name prints the one line"
  done
done
# and no script is left with a per-call cfg() that runs pipeline-config.sh
assert_eq "" "$(grep -ln 'bash "$SCRIPT_DIR/pipeline-config.sh" "\$@"' "$SCRIPTS"/*.sh | tr '\n' ' ')" "no script keeps a cfg() fallback that runs pipeline-config.sh per call"

# ── the 2>/dev/null wrappers fail closed for a security key ──────────────────
# pipeline-status-file.sh (roles.*, merge.auto) and pipeline-changelog.sh used to
# wrap pipeline-config.sh in 2>/dev/null; both now read through the cache's cfg().
# refresh --print runs against a copy of scripts/ with a verb-level vcs stub.
mk_sf_variant() {  # NAME -> scripts dir (copy, stub vcs)
  local d="$SANDBOX/sf-$1"
  mkdir -p "$d" || return 1
  cp "$SCRIPTS"/*.sh "$d/" || return 1
  printf '%s\n' '#!/usr/bin/env bash' 'case "${1:-}" in list-prs|list-issues|list-needs-owner) echo "[]"; exit 0 ;; esac' 'exit 1' > "$d/pipeline-vcs.sh"
  printf '%s' "$d"
}
GITREPO="$SANDBOX/gitrepo"
mkdir -p "$GITREPO" || exit 1
git init -q -b main "$GITREPO" || exit 1
git -C "$GITREPO" config user.email t@talos.invalid
git -C "$GITREPO" config user.name talos-test
git -C "$GITREPO" config commit.gpgsign false
echo seed > "$GITREPO/README.md"
git -C "$GITREPO" add README.md
git -C "$GITREPO" commit -q -m seed || exit 1
git init -q --bare "$SANDBOX/origin.git" || exit 1
git -C "$GITREPO" remote add origin "$SANDBOX/origin.git"
git -C "$GITREPO" push -q origin main || exit 1
git -C "$GITREPO" fetch -q origin main
# every status.* key set explicitly, so a broken table is first felt at a role key
printf '%s\n' '{"base_branch": "main", "status": {"enabled": true, "file": "TALOS_STATUS.md", "log_heading": "## Log", "resume_heading": "## Resume here", "fragments_dir": "docs/status.d", "archive_dir": "status/archive", "log_days": 30, "log_max": 50, "resume_max_lines": 40}}' > "$GITREPO/talos.pipeline.json"
D="$(mk_sf_variant intact)" || exit 1
out="$(cd "$GITREPO" && bash "$D/pipeline-status-file.sh" refresh --print 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "status file, intact table: refresh --print exits 0"
assert_contains "$out" "## Resume here" "status file, intact table: refresh --print prints the block"
D="$(mk_sf_variant broken)" || exit 1
printf '%s' 'truncated' > "$D/pipeline-defaults.sh"
out="$(cd "$GITREPO" && bash "$D/pipeline-status-file.sh" refresh --print 2>"$SANDBOX/err")"; rc=$?
assert_eq "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)" "status file, broken table: refresh --print fails (rc $rc)"
assert_not_contains "$out" "## Resume here" "status file, broken table: no block is printed"
assert_contains "$(cat "$SANDBOX/err")" "stopping rather than guess" "status file, broken table: the fail-closed line names the cause"
# pipeline-changelog.sh has no lookup of its own left: its cfg() is the cache's.
assert_eq "0" "$(grep -c 'bash .*pipeline-config.sh' "$SCRIPTS/pipeline-changelog.sh" || true)" "pipeline-changelog.sh does not run pipeline-config.sh itself"
# pipeline-draft-check.sh is fail open by contract ("a check problem never blocks a run"). It reads
# only pr.draft and vcs.provider through its own 2>/dev/null wrapper; neither may become a security key.
(
  . "$SCRIPTS/pipeline-defaults-check.sh"
  for k in $(sed -n 's/.*_dc_cfg \([a-z_.]*\).*/\1/p' "$SCRIPTS/pipeline-draft-check.sh" | sort -u); do
    _talos_security_key "$k" && echo "security:$k"
  done
  echo done
) > "$SANDBOX/dc.out" 2>&1
assert_eq "done" "$(cat "$SANDBOX/dc.out")" "pipeline-draft-check.sh reads no security key through its fail-open wrapper"

finish
