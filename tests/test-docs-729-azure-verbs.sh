#!/usr/bin/env bash
# test-docs-729-azure-verbs.sh -- docs and stage profiles agree with the provider checks in pipeline-vcs.sh (#729).
set -u
. "$(dirname "$0")/helpers.sh"

R="$TALOS_ROOT"
REF="$R/docs/reference.md"
VCS="$R/scripts/pipeline-vcs.sh"
EX="$R/talos.pipeline.json.example"

has() { grep -qF -- "$2" "$R/$1"; }
# ok <name> <file> <present|absent> <text>
ok() {
  local name="$1" f="$2" want="$3" text="$4"
  if [ "$want" = present ]; then
    if has "$f" "$text"; then pass "$name"; else fail "$name"; fi
  else
    if has "$f" "$text"; then fail "$name"; else pass "$name"; fi
  fi
}

# AC1 the five profiles' post-approval paragraph no longer says GitHub-only
for f in adversarial docs qa reviewer security; do
  ok "AC1 agents/$f.md does not call post-approval GitHub-only" agents/$f.md absent 'GitHub-only'
done

# AC2 reference: post-approval and check-approval-sha run on github, github-api and azure
ok "AC2 reference: post-approval is not 'github and github-api only'" docs/reference.md absent '(`github` and `github-api` only) reads the head SHA'
ok "AC2 reference: check-approval-sha is not 'github and github-api only'" docs/reference.md absent '[--stale-list]` (`github` and `github-api` only)'
ok "AC2 reference: post-approval names azure" docs/reference.md present '(`github`, `github-api` and `azure`) reads the head SHA'
ok "AC2 reference: check-approval-sha names azure" docs/reference.md present '[--stale-list]` (`github`, `github-api` and `azure`)'

# AC3 the GitHub-only verbs paragraph marks every azure-capable verb it lists
para="$(awk '/^### GitHub-only verbs/{f=1;next} f&&/^#/{exit} f' "$REF")"
for v in record-attempt check-attempt read-attempt mark-needs-owner list-needs-owner has-spec; do
  if grep -qE -- "\`$v\`.{0,80}also on Azure" <<<"$para"; then pass "AC3 reference: $v is marked also on Azure"
  else fail "AC3 reference: $v is marked also on Azure"; fi
done
for v in upsert-pr-comment edit-pr-body conflict-files; do
  if grep -qF -- "\`$v\`" <<<"$para"; then pass "AC3 reference: $v stays listed as GitHub-only"
  else fail "AC3 reference: $v stays listed as GitHub-only"; fi
done

# AC4 the code comment above the post-approval block names azure
ok "AC4 pipeline-vcs.sh: the post-approval block comment drops 'GitHub-only (github and github-api providers). For other'" scripts/pipeline-vcs.sh absent '# GitHub-only (github and github-api providers). For other providers, exit 1.'
if grep -A2 'post-approval: atomic marker-post' "$VCS" | grep -qF 'github, github-api and azure'; then
  pass "AC4 pipeline-vcs.sh: the post-approval block comment names github, github-api and azure"
else
  fail "AC4 pipeline-vcs.sh: the post-approval block comment names github, github-api and azure"
fi

# AC5 reference documents the comment-issue / comment-pr body rules
ok "AC5 reference: names comment-issue" docs/reference.md present '`comment-issue`'
ok "AC5 reference: stage bodies go to .talos/<role>-*.body" docs/reference.md present '.talos/<role>-*.body'
ok "AC5 reference: or --body-file -" docs/reference.md present '`--body-file -`'
ok "AC5 reference: a lone file path body is refused" docs/reference.md present 'whitespace-free token naming a readable file'
ok "AC5 reference: the refusal points at --body-file" docs/reference.md present 'use `--body-file`'
hand="$(awk '/^### Commands to run by hand/{f=1;next} f&&/^#/{exit} f' "$REF")"
if grep -qF 'comment-issue' <<<"$hand" && grep -qF 'comment-pr' <<<"$hand"; then pass "AC5 Commands to run by hand lists comment-issue / comment-pr"
else fail "AC5 Commands to run by hand lists comment-issue / comment-pr"; fi

# AC6 the talos.sh Verbs list includes map
if grep -E '^Verbs: ' "$REF" | grep -qF '`map`'; then pass "AC6 talos.sh Verbs list includes map"
else fail "AC6 talos.sh Verbs list includes map"; fi

# AC7 qa.md lists the flaky and e2e qa-run lines
ok "AC7 qa.md lists AC<n> FAIL flaky" agents/qa.md present 'AC<n> FAIL flaky (failed at head, passed on re-run)'
ok "AC7 qa.md lists qa-run: e2e ok" agents/qa.md present 'qa-run: e2e ok'
ok "AC7 qa.md lists qa-run: verdict FAIL e2e exited" agents/qa.md present 'qa-run: verdict FAIL e2e exited <rc>'

# AC8 the example config keeps the default waiver *.example
if python3 -I - "$EX" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))["merge"]["approval_waiver_paths"]
sys.exit(0 if p == ["*.md", "docs/**", "CHANGELOG.md", "*.example"] else 1)
PY
then pass "AC8 example approval_waiver_paths matches the default"
else fail "AC8 example approval_waiver_paths matches the default"; fi

# AC9 guard: no profile or reference line calls an azure-capable verb GitHub-only.
# The code side: these verbs' provider checks accept azure.
azure_ok=true
for v in post-approval has-spec; do
  grep -A3 "\"\$VERB\" = \"$v\"" "$VCS" | grep -qF '"$PROVIDER" != "azure"' || azure_ok=false
done
if $azure_ok; then pass "AC9 pipeline-vcs.sh: post-approval and has-spec accept azure"
else fail "AC9 pipeline-vcs.sh: post-approval and has-spec accept azure"; fi
# A claim line is "GitHub-only" or "`github` and `github-api` only". In a profile it must not
# stand without naming one of the verbs the code still rejects on azure; in the reference a line
# naming an azure-capable verb must not carry it.
GH_ONLY_RE='GitHub-only|`github` and `github-api` only'
NOT_AZURE_RE='upsert-pr-comment|edit-pr-body|conflict-files'
AZURE_RE='post-approval|check-approval-sha|has-spec|record-attempt|check-attempt|read-attempt|mark-needs-owner|list-needs-owner'
bad=""
for f in "$R"/agents/*.md; do
  hits="$(grep -nE -- "$GH_ONLY_RE" "$f" | grep -vE -- "$NOT_AZURE_RE" || true)"
  [ -z "$hits" ] || bad="$bad
$f: $hits"
done
hits="$(grep -nE -- "$GH_ONLY_RE" "$REF" | grep -E -- "$AZURE_RE" | grep -vE -- '^[0-9]+:### ' || true)"
[ -z "$hits" ] || bad="$bad
$REF: $hits"
if [ -z "$bad" ]; then pass "AC9 no profile or reference line calls an azure-capable verb GitHub-only"
else fail "AC9 no profile or reference line calls an azure-capable verb GitHub-only" "$bad"; fi

finish
