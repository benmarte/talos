#!/usr/bin/env bash
# pipeline-contract.sh -- single source of truth for Talos's roles, labels,
# and `talos:` markers (#178).
#
# Before this file existed, the same three lists were hand-restated in
# pipeline-vcs.sh (as Python literals inside embedded `python3 -c` blocks),
# bootstrap-labels.sh (its own `labels=(...)` array), skills/pipeline/
# SKILL.md, every agents/*.md, and the tests -- issue #155/#178 found the
# contract duplicated up to six times and drifting silently. Prompts and
# docs keep their hand-written prose; this file is what tests/test-
# contract.sh greps them against.
#
# Sourceable, not executable: every value below is a plain bash array or
# function, no side effects. Bash 3.2 compatible (macOS ships 3.2) --
# indexed arrays only, no `declare -A`.
#
# Consumers:
#   pipeline-vcs.sh      -- sources this, derives KNOWN_STAGES/
#                            APPROVAL_LABELS/VALID_ROLES for its embedded
#                            Python blocks from TALOS_ROLES/
#                            TALOS_APPROVAL_LABELS/TALOS_APPROVAL_ROLES
#                            (passed in via env, same pattern as
#                            TRUSTED_AUTHORS/TALOS_CFG already use).
#   bootstrap-labels.sh   -- sources this, iterates the label arrays
#                            instead of keeping its own list.
#   install.sh            -- copies this file alongside the other
#                            scripts/pipeline-*.sh files.
#   tests/test-contract.sh -- asserts every label/marker string that
#                            appears in prose (SKILL.md, agents/*.md,
#                            templates/**, README.md, docs/user-guide.md)
#                            is a member of the arrays below.

# ── Roles ──────────────────────────────────────────────────────────────────
# Every stage name recognised in `talos:attempt` markers, and the role half
# of the `talos:<role>` plugin-namespaced subagent identifiers
# (skills/pipeline/SKILL.md's `Agent(subagent_type: "talos:developer", ...)`
# form) -- those identifiers are this list prefixed with "talos:", not a
# separately maintained set.
TALOS_ROLES=(
  developer qa reviewer security docs validator pm orchestrator planner
)

# The subset of TALOS_ROLES that carries an approval label (gated by
# check-approval-sha / post-approval), in the same order as
# TALOS_APPROVAL_LABELS below -- index i's role owns index i's label.
TALOS_APPROVAL_ROLES=(qa reviewer security docs)

# ── Labels ─────────────────────────────────────────────────────────────────
# Format: "name|color|description" (pipe-delimited -- label names contain
# ':', so a pipe is the field separator). This is the shape
# bootstrap-labels.sh has always used; kept so it, and talos_contract_json,
# can read it directly.

# pipeline:* state-machine labels applied by the orchestrator/subagents as
# an issue or PR moves through the pipeline.
TALOS_STAGE_LABELS=(
  "pipeline:ready|0e8a16|Queued for the pipeline — validator picks it up"
  "pipeline:confirmed|1d76db|Validated as real & in-scope — PM writes the spec"
  "pipeline:dev|5319e7|Spec ready — developer implements + opens PR"
  "pipeline:review|fbca04|PR open — QA then reviewer/security/docs"
  "pipeline:approved|0e8a16|All stages passed — orchestrator merges when CI is green"
  "pipeline:blocked|b60205|Halted — a human needs to act (see comments)"
  "pipeline:epic-decomposed|c5def5|Epic split into sub-issues — never routed to developer"
  "pipeline:epic-children-done|c5def5|All sub-issues closed but the epic's own acceptance boxes are still unticked — human review needed"
)

# Approval labels a gate stage applies once its own check passes. Parallel
# to TALOS_APPROVAL_ROLES (same index order: qa, reviewer, security, docs).
TALOS_APPROVAL_LABELS=(
  "qa:pass|c2e0c6|QA verified acceptance criteria"
  "review:approved|c2e0c6|Code review approved"
  "security:approved|c2e0c6|Security review clear"
  "docs:done|c2e0c6|Documentation updated"
)

# Everything else bootstrap-labels.sh creates: human-applied override
# labels, the epic marker, and the priority ladder.
TALOS_MISC_LABELS=(
  "spec:ready|0e8a16|Human-applied: issue body is already a usable spec — force-skips the PM stage"
  "skip-qa|ededed|Human-applied: bypass QA/review/security gates (docs-only or hotfix); CI + forbidden-files still enforced"
  "epic|e4e669|Epic — planner decomposes into sub-issues"
  "p0|b60205|Priority: critical — dispatched first"
  "p1|d93f0b|Priority: high"
  "p2|fbca04|Priority: normal"
)

# ── Markers ────────────────────────────────────────────────────────────────
# Every `talos:` string emitted as a machine-readable marker -- either an
# HTML-comment marker in a PR/issue comment (talos:approval, talos:attempt)
# or a plain "talos:foo ..." diagnostic line on stdout/in a comment.
# Namespaced subagent identifiers (`talos:<role>`) are NOT listed here --
# see the TALOS_ROLES comment above.
TALOS_MARKERS=(
  talos:approval
  talos:attempt
  talos:ci-rerun
  talos:forbidden-files-active
  talos:forbidden-files-defaults-replaced
  talos:closing-keyword-unverified
  talos:comment-state-unverified
  talos:marker-authors-unverified
  talos:marker-authors-rejected
  talos:board-unverified
  talos:verify
  talos:runner
)

# ── talos_contract_json ──────────────────────────────────────────────────────
# Prints the whole contract as JSON: {"roles", "stage_labels",
# "approval_labels" (each entry carries its "role"), "misc_labels",
# "markers"}. Each *_labels entry is {"name", "color", "description"}.
talos_contract_json() {
  TALOS_ROLES_ENV="${TALOS_ROLES[*]}" \
  TALOS_APPROVAL_ROLES_ENV="${TALOS_APPROVAL_ROLES[*]}" \
  TALOS_STAGE_LABELS_ENV="$(printf '%s\n' "${TALOS_STAGE_LABELS[@]}")" \
  TALOS_APPROVAL_LABELS_ENV="$(printf '%s\n' "${TALOS_APPROVAL_LABELS[@]}")" \
  TALOS_MISC_LABELS_ENV="$(printf '%s\n' "${TALOS_MISC_LABELS[@]}")" \
  TALOS_MARKERS_ENV="${TALOS_MARKERS[*]}" \
  python3 -c "
import json, os

def parse_labels(env_name):
    out = []
    for line in os.environ.get(env_name, '').split(chr(10)):
        line = line.strip()
        if not line:
            continue
        name, color, description = line.split('|', 2)
        out.append({'name': name, 'color': color, 'description': description})
    return out

approval_roles  = os.environ.get('TALOS_APPROVAL_ROLES_ENV', '').split()
approval_labels = parse_labels('TALOS_APPROVAL_LABELS_ENV')
for i, entry in enumerate(approval_labels):
    entry['role'] = approval_roles[i] if i < len(approval_roles) else None

contract = {
    'roles':           os.environ.get('TALOS_ROLES_ENV', '').split(),
    'stage_labels':    parse_labels('TALOS_STAGE_LABELS_ENV'),
    'approval_labels': approval_labels,
    'misc_labels':     parse_labels('TALOS_MISC_LABELS_ENV'),
    'markers':         os.environ.get('TALOS_MARKERS_ENV', '').split(),
}
print(json.dumps(contract, indent=2))
"
}
