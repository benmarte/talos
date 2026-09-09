#!/usr/bin/env bash
# tests/test-contract.sh -- pipeline-contract.sh is the single source of
# truth for roles, labels, and `talos:` markers (#178). Three jobs:
#
#   (a) membership -- every pipeline:*/qa:pass/review:approved/
#       security:approved/docs:done/spec:ready/skip-qa string, and every
#       talos:[a-z-]+ marker, that appears in prose (skills/pipeline/
#       SKILL.md, agents/*.md, templates/**, README.md, docs/user-guide.md)
#       must be a member of the contract. A stray string here means the
#       prose and the contract have drifted -- exactly the failure mode
#       #155/#178 reported.
#   (b) bootstrap-labels.sh's effective label set (what it actually tells
#       `gh label create` to create) equals the contract's label set.
#   (c) talos_contract_json prints valid JSON with the expected top-level
#       keys.
#   (d) every label name/description in the contract is within GitHub's
#       50/100-char limits (#250), via talos_contract_check_label_length --
#       plus a negative check that the same helper rejects a synthetic
#       over-long entry.
set -u
. "$(dirname "$0")/helpers.sh"

CONTRACT="$TALOS_ROOT/scripts/pipeline-contract.sh"
[ -f "$CONTRACT" ] || fail "setup: pipeline-contract.sh exists" "not found at $CONTRACT"
. "$CONTRACT"

for _arr in TALOS_ROLES TALOS_STAGE_LABELS TALOS_APPROVAL_LABELS TALOS_APPROVAL_ROLES \
            TALOS_MISC_LABELS TALOS_MARKERS; do
  declare -p "$_arr" >/dev/null 2>&1 || fail "setup: $_arr is defined" "missing after sourcing $CONTRACT"
done
declare -F talos_contract_json >/dev/null 2>&1 \
  || fail "setup: talos_contract_json is defined" "missing after sourcing $CONTRACT"

# ═══════════════════════════════════════════════════════════════════════════
# (a) membership
# ═══════════════════════════════════════════════════════════════════════════

# Label-name universe: the part before the first '|' of every
# TALOS_*_LABELS entry.
_contract_label_names() {
  local entry
  for entry in "${TALOS_STAGE_LABELS[@]}" "${TALOS_APPROVAL_LABELS[@]}" "${TALOS_MISC_LABELS[@]}"; do
    printf '%s\n' "${entry%%|*}"
  done
}

# Marker-string universe: TALOS_MARKERS, plus "talos:<role>" for every
# TALOS_ROLES entry -- the plugin subagent-namespacing form
# (skills/pipeline/SKILL.md: `Agent(subagent_type: "talos:developer", ...)`)
# is TALOS_ROLES prefixed with "talos:", not a separately maintained list
# (see pipeline-contract.sh's TALOS_MARKERS comment).
_contract_marker_names() {
  printf '%s\n' "${TALOS_MARKERS[@]}"
  local role
  for role in "${TALOS_ROLES[@]}"; do
    printf 'talos:%s\n' "$role"
  done
}

CONTRACT_LABEL_NAMES="$(_contract_label_names)"
CONTRACT_MARKER_NAMES="$(_contract_marker_names)"

PROSE_FILES=("$TALOS_ROOT/skills/pipeline/SKILL.md")
for f in "$TALOS_ROOT"/agents/*.md "$TALOS_ROOT/README.md" "$TALOS_ROOT/docs/user-guide.md"; do
  [ -f "$f" ] && PROSE_FILES+=("$f")
done
while IFS= read -r -d '' f; do
  PROSE_FILES+=("$f")
done < <(find "$TALOS_ROOT/templates" -type f -print0 2>/dev/null)

_stray_found=false
for f in "${PROSE_FILES[@]}"; do
  [ -f "$f" ] || continue

  while IFS= read -r found; do
    [ -z "$found" ] && continue
    if ! printf '%s\n' "$CONTRACT_LABEL_NAMES" | grep -Fxq -- "$found"; then
      _stray_found=true
      fail "contract membership: label '$found' (${f#"$TALOS_ROOT"/})" \
        "not a member of TALOS_STAGE_LABELS/TALOS_APPROVAL_LABELS/TALOS_MISC_LABELS in $CONTRACT"
    fi
  done < <(grep -ohE 'pipeline:[a-z-]+|qa:pass|review:approved|security:approved|docs:done|spec:ready|skip-qa' "$f" 2>/dev/null | sort -u)

  while IFS= read -r found; do
    [ -z "$found" ] && continue
    if ! printf '%s\n' "$CONTRACT_MARKER_NAMES" | grep -Fxq -- "$found"; then
      _stray_found=true
      fail "contract membership: marker '$found' (${f#"$TALOS_ROOT"/})" \
        "not a member of TALOS_MARKERS (or talos:<TALOS_ROLES> namespacing) in $CONTRACT"
    fi
  done < <(grep -ohE 'talos:[a-z-]+' "$f" 2>/dev/null | sort -u)
done
[ "$_stray_found" = "false" ] && \
  pass "contract membership: every label/marker string in prose is a contract member"

# ═══════════════════════════════════════════════════════════════════════════
# (b) bootstrap-labels.sh's effective label set == contract label set
# ═══════════════════════════════════════════════════════════════════════════
make_sandbox
use_stubs
: > "$GH_LOG"
bash "$TALOS_ROOT/scripts/bootstrap-labels.sh" acme/widget >/dev/null
CREATED_NAMES="$(grep -oE 'label create [^ ]+' "$GH_LOG" | awk '{print $3}' | sort -u)"
EXPECTED_NAMES="$(printf '%s\n' "$CONTRACT_LABEL_NAMES" | sort -u)"
assert_eq "$EXPECTED_NAMES" "$CREATED_NAMES" \
  "bootstrap-labels.sh creates exactly the contract's label set"

# ═══════════════════════════════════════════════════════════════════════════
# (c) talos_contract_json is valid JSON with the expected keys
# ═══════════════════════════════════════════════════════════════════════════
JSON_OUT="$(talos_contract_json)"; rc=$?
assert_eq "0" "$rc" "talos_contract_json exits 0"

_json_check="$(printf '%s' "$JSON_OUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception as exc:
    print(f"INVALID: {exc}")
    sys.exit(0)
expected_keys = {"roles", "stage_labels", "approval_labels", "misc_labels", "markers"}
missing = expected_keys - set(data.keys())
if missing:
    print(f"MISSING KEYS: {sorted(missing)}")
elif not isinstance(data["roles"], list) or not data["roles"]:
    print("roles is not a non-empty list")
elif not all(isinstance(e, dict) and {"name", "color", "description"} <= set(e.keys()) for e in data["approval_labels"]):
    print("approval_labels entries missing name/color/description")
elif not all("role" in e for e in data["approval_labels"]):
    print("approval_labels entries missing role")
else:
    print("OK")
')"
assert_eq "OK" "$_json_check" "talos_contract_json is valid JSON with the expected keys"

# ═══════════════════════════════════════════════════════════════════════════
# (d) label name/description length limits (#250)
# ═══════════════════════════════════════════════════════════════════════════
declare -F talos_contract_check_label_length >/dev/null 2>&1 \
  || fail "setup: talos_contract_check_label_length is defined" "missing after sourcing $CONTRACT"

_length_violation=false
for entry in "${TALOS_STAGE_LABELS[@]}" "${TALOS_APPROVAL_LABELS[@]}" "${TALOS_MISC_LABELS[@]}"; do
  if ! talos_contract_check_label_length "$entry" >/dev/null 2>&1; then
    _length_violation=true
    fail "label length: '${entry%%|*}' is within GitHub's 50/100-char limits" \
      "$(talos_contract_check_label_length "$entry" 2>&1 >/dev/null)"
  fi
done
[ "$_length_violation" = "false" ] && \
  pass "label length: every contract label name/description is within GitHub's 50/100-char limits"

# Negative check: the same helper must reject an over-long entry -- proves
# the assertion above isn't vacuously true.
_over_long_desc="$(printf 'x%.0s' $(seq 1 101))"
talos_contract_check_label_length "over-long-description|ededed|$_over_long_desc" >/dev/null 2>&1
assert_exit_code "1" "$?" "label length: helper rejects a 101-char description"

_over_long_name="$(printf 'y%.0s' $(seq 1 51))"
talos_contract_check_label_length "$_over_long_name|ededed|short" >/dev/null 2>&1
assert_exit_code "1" "$?" "label length: helper rejects a 51-char name"

finish
