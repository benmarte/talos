#!/usr/bin/env bash
# test-map-refresh-889.sh -- `talos.sh map --refresh` and the `list-merged-prs`
# read behind it (#889, part D of #884). Tests are named by the spec's id.
#   AC1 list-merged-prs: number, issue (null when unknown), title, merge time,
#       newest first, merged only and since the date, on github, github-api,
#       gitlab and azure
#   AC2 a failed or capped read: exit 1, no partial output; file: exit 2; a
#       missing or malformed --since: exit 1
#   AC3 --refresh: exactly one collect, one list-merged-prs, at most one
#       list-issues; prints map= and index=
#   AC4 the page counts the provider's merges of the last 7 days and lists as
#       In flight only the collect's live issues
#   AC5 "merged elsewhere" rows: no stage bar; a PR with no issue is one; a merge
#       with local events is not duplicated
#   AC6 a failed merged list is one warn, exit 0; a failed collect stops
#   AC7 a plain map after a refresh makes no network call and shows the rows;
#       any other argument is usage
#   AC8 --refresh writes with map.enabled false and leaves the run entry
#   AC9 a snapshot with no merged_remote renders as before, offline
# AC10 is prose.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
unset TALOS_ROLE TALOS_RUN_STARTED TALOS_RUN_PID TALOS_COLLECT_CACHE
git config user.email "test@talos.invalid"
git config user.name "talos-test"

jnorm() { python3 -I -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1]), sort_keys=True))' "$1" 2>/dev/null || echo "<not json: $1>"; }
vcs() { OUT="$(bash "$VCS" "$@" 2>"$SANDBOX/err")"; RC=$?; ERR="$(cat "$SANDBOX/err")"; }
cfg_gh() { github_leg "$1"; export GH_QUEUE="$CURL_QUEUE" GH_LINK_QUEUE="$CURL_LINK_QUEUE" GH_REST_LOG="$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"; : > "$CURL_LOG"; : > "$GH_LOG"; }
cfg_gitlab() {
  git remote set-url origin git@gitlab.com:acme/widget.git
  printf '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
  : > "$GH_LOG"
}
cfg_azure() {
  printf '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}\n' > "$PIPELINE_CONFIG"
  : > "$GH_LOG"
}
cfg_file() {
  printf 'item\n' > "$SANDBOX/plan.md"
  printf '{"vcs": {"provider": "file", "file": {"source": {"path": "%s"}}}}\n' "$SANDBOX/plan.md" > "$PIPELINE_CONFIG"
}
arr() { local IFS=,; printf '[%s]' "$*"; }
# ghpr NUMBER MERGED|null HEAD BODY TITLE UPDATED: one raw GitHub closed PR.
ghpr() {
  python3 -I -c '
import json, sys
n, merged, head, body, title, upd = sys.argv[1:7]
print(json.dumps({"number": int(n), "title": title, "body": body, "state": "closed",
                  "merged_at": None if merged == "null" else merged, "updated_at": upd,
                  "head": {"ref": head}, "base": {"ref": "main"}}))' "$@"
}

# What every provider must print for the fixtures below (newest merge first):
# 14 no issue, 11 closes #7 by keyword, 10 branch issue-5. 12 is closed
# unmerged and 13 merged before the date: both left out.
WANT='[{"number": 14, "issue": null, "title": "chore: no issue", "mergedAt": "2026-11-09T10:00:00Z"},
{"number": 11, "issue": 7, "title": "feat: b", "mergedAt": "2026-11-08T10:00:00Z"},
{"number": 10, "issue": 5, "title": "feat: a", "mergedAt": "2026-11-05T10:00:00Z"}]'

# ── AC1: github and github-api ───────────────────────────────────────────────
for leg in gh curl; do
  cfg_gh "$leg"
  printf '%s\n' "$(arr \
    "$(ghpr 10 2026-11-05T10:00:00Z fix/issue-5-x '' 'feat: a' 2026-11-05T11:00:00Z)" \
    "$(ghpr 11 2026-11-08T10:00:00Z feat/b 'Closes #7' 'feat: b' 2026-11-08T11:00:00Z)" \
    "$(ghpr 12 null fix/issue-6-y 'Closes #6' 'feat: unmerged' 2026-11-08T12:00:00Z)" \
    "$(ghpr 13 2026-10-01T10:00:00Z fix/issue-4-z '' 'feat: old' 2026-11-02T10:00:00Z)" \
    "$(ghpr 14 2026-11-09T10:00:00Z feat/c '' 'chore: no issue' 2026-11-09T11:00:00Z)")" >> "$CURL_QUEUE"
  vcs list-merged-prs --since 2026-11-01
  assert_eq "0" "$RC" "AC1 $leg: list-merged-prs exits 0 ($ERR)"
  assert_eq "$(jnorm "$WANT")" "$(jnorm "$OUT")" "AC1 $leg: number, issue, title and mergedAt, newest first, merged since the date only"
  assert_contains "$(cat "$CURL_LOG")" "state=closed" "AC1 $leg: reads the closed pulls"
done

# ── AC1: gitlab ──────────────────────────────────────────────────────────────
cfg_gitlab
export STUB_GITLAB_MR_PAGES='[{"iid":10,"title":"feat: a","description":"","source_branch":"fix/issue-5-x","state":"merged","merged_at":"2026-11-05T10:00:00Z"},{"iid":11,"title":"feat: b","description":"Closes #7","source_branch":"feat/b","state":"merged","merged_at":"2026-11-08T10:00:00Z"}]
[{"iid":12,"title":"feat: unmerged","description":"","source_branch":"fix/issue-6-y","state":"closed","merged_at":null},{"iid":13,"title":"feat: old","description":"","source_branch":"fix/issue-4-z","state":"merged","merged_at":"2026-10-01T10:00:00Z"},{"iid":14,"title":"chore: no issue","description":"","source_branch":"feat/c","state":"merged","merged_at":"2026-11-09T10:00:00Z"}]'
vcs list-merged-prs --since 2026-11-01
assert_eq "0" "$RC" "AC1 gitlab: list-merged-prs exits 0 ($ERR)"
assert_eq "$(jnorm "$WANT")" "$(jnorm "$OUT")" "AC1 gitlab: the same shape, both pages, newest first, merged since the date only"
unset STUB_GITLAB_MR_PAGES

# ── AC1: azure ───────────────────────────────────────────────────────────────
cfg_azure
export STUB_AZURE_PR_LIST='[{"pullRequestId":10,"title":"feat: a","description":"","status":"completed","sourceRefName":"refs/heads/fix/issue-5-x","closureDate":"2026-11-05T10:00:00Z"},{"pullRequestId":11,"title":"feat: b","description":"Closes #7","status":"completed","sourceRefName":"refs/heads/feat/b","closureDate":"2026-11-08T10:00:00Z"},{"pullRequestId":12,"title":"feat: unmerged","description":"","status":"abandoned","sourceRefName":"refs/heads/fix/issue-6-y","closureDate":"2026-11-08T12:00:00Z"},{"pullRequestId":13,"title":"feat: old","description":"","status":"completed","sourceRefName":"refs/heads/fix/issue-4-z","closureDate":"2026-10-01T10:00:00Z"},{"pullRequestId":14,"title":"chore: no issue","description":"","status":"completed","sourceRefName":"refs/heads/feat/c","closureDate":"2026-11-09T10:00:00Z"}]'
vcs list-merged-prs --since 2026-11-01
assert_eq "0" "$RC" "AC1 azure: list-merged-prs exits 0 ($ERR)"
assert_eq "$(jnorm "$WANT")" "$(jnorm "$OUT")" "AC1 azure: the same shape; an abandoned PR and one merged before the date are left out"
export STUB_AZURE_PR_WORKITEMS='[{"id":9}]'
vcs list-merged-prs --since 2026-11-01
assert_contains "$(jnorm "$OUT")" '"issue": 9, "mergedAt": "2026-11-09T10:00:00Z"' "AC1 azure: a PR with no branch or keyword takes its linked work item"
unset STUB_AZURE_PR_WORKITEMS STUB_AZURE_PR_LIST

# ── AC2: failures, file, --since ─────────────────────────────────────────────
cfg_gh gh
printf '{"message": "not a list"}\n' >> "$CURL_QUEUE"
vcs list-merged-prs --since 2026-11-01
assert_eq "1" "$RC" "AC2 github: a body that is not a list exits 1"
assert_eq "" "$OUT" "AC2 github: a failed read prints nothing on stdout"
cfg_gh gh
for i in $(seq 1 40); do
  printf '%s\n' "$(arr "$(ghpr "$i" 2026-11-05T10:00:00Z fix/issue-5-x '' 'feat: a' 2026-11-05T11:00:00Z)")" >> "$CURL_QUEUE"
  printf '%s\n' "https://api.github.com/repos/acme/widget/pulls?state=closed&per_page=100&page=$((i + 1))" >> "$CURL_LINK_QUEUE"
done
vcs list-merged-prs --since 2026-11-01
assert_eq "1" "$RC" "AC2 github: a read that hits the page cap exits 1"
assert_eq "" "$OUT" "AC2 github: a capped read prints no partial list"
assert_contains "$ERR" "page" "AC2 github: a capped read names the cap"
cfg_gitlab
export STUB_GITLAB_API_FAIL=1
vcs list-merged-prs --since 2026-11-01
assert_eq "1" "$RC" "AC2 gitlab: a failed read exits 1"
assert_eq "" "$OUT" "AC2 gitlab: a failed read prints nothing on stdout"
unset STUB_GITLAB_API_FAIL
cfg_azure
export STUB_AZURE_PR_LIST_FAIL=1
vcs list-merged-prs --since 2026-11-01
assert_eq "1" "$RC" "AC2 azure: a failed read exits 1"
assert_eq "" "$OUT" "AC2 azure: a failed read prints nothing on stdout"
unset STUB_AZURE_PR_LIST_FAIL
export STUB_AZURE_PR_LIST_FULL=1
vcs list-merged-prs --since 2026-11-01
assert_eq "1" "$RC" "AC2 azure: a list that never ends hits the page cap and exits 1"
assert_eq "" "$OUT" "AC2 azure: a capped read prints no partial list"
unset STUB_AZURE_PR_LIST_FULL
cfg_file
vcs list-merged-prs --since 2026-11-01
assert_eq "2" "$RC" "AC2 file: exits 2"
assert_eq "" "$OUT" "AC2 file: prints nothing on stdout"
assert_contains "$ERR" "not implemented for provider 'file'" "AC2 file: the not-implemented note"
cfg_gh gh
vcs list-merged-prs --since yesterday
assert_eq "1" "$RC" "AC2 a malformed --since exits 1"
vcs list-merged-prs --since
assert_eq "1" "$RC" "AC2 a --since with no value exits 1"
vcs --dry-run list-merged-prs --since 2026-11-01
assert_eq "0" "$RC" "AC2 --dry-run exits 0"
assert_contains "$OUT" "[dry-run]" "AC2 --dry-run describes the call"
assert_eq "0" "$(wc -c < "$CURL_LOG" | tr -d ' ')" "AC2 --dry-run makes no call"

# ── map --refresh ────────────────────────────────────────────────────────────
TALOS_SRC="$TALOS_ROOT/scripts"
cfg_map() { printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "comments": {"enabled": false}%s}\n' "${1:-}" > "$PIPELINE_CONFIG"; }
cfg_map
TH="$HOME/.talos"
MAP="$TH/maps/acme-widget.html"
STATE="$SANDBOX/.git/talos"
SNAP="$STATE/state.json"
META="$HOME/.cache/talos/meta"
mkdir -p "$STATE" "$META"

GS="$SANDBOX/gs"
mkdir -p "$GS"
cp "$TALOS_SRC"/* "$GS/" 2>/dev/null
CALLS="$SANDBOX/calls.log"
cat > "$GS/pipeline-vcs.sh" <<'TALOS_q8w3nk5vz2ra'
#!/usr/bin/env bash
printf 'vcs %s\n' "$*" >> "$CALLS"
case "$1" in
  list-merged-prs) [ -z "${MERGED_FAIL:-}" ] || exit 1; cat "$GS_MERGED" ;;
  list-issues) cat "$GS_ISSUES" ;;
esac
exit 0
TALOS_q8w3nk5vz2ra
cat > "$GS/pipeline-status-file.sh" <<'TALOS_h7d4mp9cx1tb'
#!/usr/bin/env bash
printf 'collect\n' >> "$CALLS"
[ -z "${COLLECT_FAIL:-}" ] || exit 1
cat "$GS_COLLECT"
TALOS_h7d4mp9cx1tb
for s in pipeline-notify.sh pipeline-hooks.sh pipeline-status.sh pipeline-events.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$GS/$s"
done
export CALLS GS_MERGED="$SANDBOX/merged.json" GS_ISSUES="$SANDBOX/issues.json" GS_COLLECT="$SANDBOX/collect.json"
TALOS="$GS/talos.sh"
printf '%s' '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [50], "held": [], "inflight": [51], "owners": [], "capped": [], "priority": {}}' > "$GS_COLLECT"
printf '[{"number": 50, "title": "queued fifty"}, {"number": 51, "title": "flying fifty-one"}]\n' > "$GS_ISSUES"

daysago() { python3 -I -c '
import datetime, sys
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
ev() {  # <event> <role> <issue> <pr> <verdict> <days ago>
  python3 -I -c '
import datetime, json, sys
a = sys.argv
ts = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=float(a[6]))
print(json.dumps({"event": a[1], "role": a[2], "issue": int(a[3]), "pr": int(a[4]) if a[4] else None,
                  "verdict": a[5] or None, "summary": "", "ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ")}))' "$@" >> "$STATE/events.jsonl"
}
reset() { rm -rf "${STATE:?}/state.json" "${TH:?}/maps" "${META:?}"/*; mkdir -p "$META"; : > "$CALLS"; }
snap_field() {
  python3 -I -c '
import json, sys
try:
    snap = json.load(open(sys.argv[1]))
    print(eval(sys.argv[2]))
except Exception:
    print("<none>")' "$SNAP" "$1"
}
tile() {
  python3 -I -c '
import re, sys
m = re.search(r"<b>(\d+)</b><span>%s</span>" % sys.argv[2], sys.argv[1])
print(m.group(1) if m else "<none>")' "$1" "$2"
}
in_flight() {  # <page> <issue>
  python3 -I -c '
import re, sys
m = re.search(r"<section id=\"flight\">.*?</section>", sys.argv[1], re.S)
print("yes" if m and (">#%s</a>" % sys.argv[2]) in m.group(0) else "no")' "$1" "$2"
}
row_of() {  # <page> <needle>: the merged-table row holding the needle
  python3 -I -c '
import re, sys
for r in re.findall(r"<tr>.*?</tr>", sys.argv[1], re.S):
    if sys.argv[2] in r:
        print(r); break' "$1" "$2"
}
refresh() { OUT="$(bash "$TALOS" map --refresh 2>"$SANDBOX/err" </dev/null)"; RC=$?; ERR="$(cat "$SANDBOX/err")"; }
count_calls() { grep -c "$1" "$CALLS" 2>/dev/null || true; }

# The fixture: #60 has stale local events and was merged by the provider (PR 101);
# #61 has a local merged event and the provider lists it too (PR 102); #62 was
# merged by the provider 8 days ago (PR 103); PR 104 closes no known issue.
reset
: > "$STATE/events.jsonl"
ev validator validator 60 "" CONFIRMED 20
ev pm pm 60 "" "" 19
ev merged orchestrator 61 99 "" 1
printf '%s\n' "queued fifty" > "$META/acme_widget.issue.50"
printf '%s\n' "flying fifty-one" > "$META/acme_widget.issue.51"
python3 -I -c '
import json, sys
d = lambda x: __import__("datetime").datetime.now(__import__("datetime").timezone.utc) - __import__("datetime").timedelta(days=x)
f = lambda x: d(x).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump([{"number": 101, "issue": 60, "title": "feat: sixty by provider", "mergedAt": f(2)},
           {"number": 102, "issue": 61, "title": "feat: provider title for 61", "mergedAt": f(1)},
           {"number": 103, "issue": 62, "title": "feat: eight days old", "mergedAt": f(8)},
           {"number": 104, "issue": None, "title": "chore: no known issue", "mergedAt": f(1)}], open(sys.argv[1], "w"))' "$GS_MERGED"

# ── AC3 and AC4 ──────────────────────────────────────────────────────────────
refresh
assert_eq "0" "$RC" "AC3 map --refresh exits 0 ($ERR)"
assert_contains "$OUT" "map=" "AC3 prints map="
assert_contains "$OUT" "index=" "AC3 prints index="
assert_eq "1" "$(count_calls '^collect$')" "AC3 exactly one collect"
assert_eq "1" "$(count_calls '^vcs list-merged-prs')" "AC3 exactly one list-merged-prs"
assert_eq "0" "$(count_calls '^vcs list-issues')" "AC3 no list-issues when every listed issue has a cached title"
WEEK="$(python3 -I -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)).strftime("%Y-%m-%d"))')"
assert_contains "$(cat "$CALLS")" "list-merged-prs --since $WEEK" "AC3 the merged list is for the last 7 days"
PAGE="$(cat "$MAP" 2>/dev/null)"
assert_eq "3" "$(tile "$PAGE" 'merged · 7 days')" "AC4 the page counts the provider's merges of the last 7 days (#60, #61 and PR 104; the 8-day-old PR 103 is not counted)"
assert_eq "no" "$(in_flight "$PAGE" 60)" "AC4 an issue with stale local events that the provider merged is not In flight"
assert_eq "yes" "$(in_flight "$PAGE" 51)" "AC4 the collect's live issue is In flight"
assert_not_contains "$PAGE" ">#62<" "AC4 a merge older than 7 days has no row"

# ── AC5 ──────────────────────────────────────────────────────────────────────
ROW60="$(row_of "$PAGE" '>#60<')"
assert_contains "$ROW60" "merged elsewhere" "AC5 a provider merge with no local merged event reads merged elsewhere"
assert_contains "$ROW60" "feat: sixty by provider" "AC5 the PR title stands in when no issue title is cached"
assert_not_contains "$ROW60" 'class="bar' "AC5 a merged-elsewhere row has no stage bar"
assert_not_contains "$ROW60" "tokens" "AC5 a merged-elsewhere row has no tokens cell"
ROW104="$(row_of "$PAGE" 'chore: no known issue')"
assert_contains "$ROW104" "merged elsewhere" "AC5 a PR with no known issue is a merged-elsewhere row"
assert_contains "$ROW104" "#104" "AC5 that row links the PR"
ROW61="$(row_of "$PAGE" '>#61<')"
assert_not_contains "$ROW61" "merged elsewhere" "AC5 a merge with local events keeps its local row"
assert_not_contains "$PAGE" "feat: provider title for 61" "AC5 the provider's title does not replace the local row"
assert_eq "1" "$(grep -o '>#61<' <<< "$PAGE" | wc -l | tr -d ' ')" "AC5 a merge with local events is not duplicated"
assert_eq "2" "$(grep -o 'merged elsewhere' <<< "$PAGE" | wc -l | tr -d ' ')" "AC5 two merged-elsewhere rows"
assert_contains "$(snap_field 'sorted(p["number"] for p in snap["merged_remote"])')" "[101, 102, 103, 104]" "AC3 the snapshot holds the provider's list"

# The title list: one call, made only for a listed issue with no cached title.
rm -f "$META/acme_widget.issue.50"
: > "$CALLS"
refresh
assert_eq "0" "$RC" "AC3 a refresh with one missing title exits 0 ($ERR)"
assert_eq "1" "$(count_calls '^collect$')" "AC3 a refresh with a missing title still makes one collect"
assert_eq "1" "$(count_calls '^vcs list-merged-prs')" "AC3 a refresh with a missing title still makes one list-merged-prs"
assert_eq "1" "$(count_calls '^vcs list-issues')" "AC3 one list-issues for the missing title"
assert_contains "$(cat "$META/acme_widget.issue.50" 2>/dev/null)" "queued fifty" "AC3 the title list fills the title cache"

# ── AC7: a plain map after a refresh is offline ──────────────────────────────
NET="$SANDBOX/net"; NETLOG="$SANDBOX/net.log"
mkdir -p "$NET"; : > "$NETLOG"
for t in gh curl glab az; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit 1\n' "$t" "$NETLOG" > "$NET/$t"
  chmod +x "$NET/$t"
done
: > "$CALLS"
OUT="$(PATH="$NET:$PATH" bash "$TALOS_SRC/talos.sh" map 2>"$SANDBOX/err" </dev/null)"; RC=$?
assert_eq "0" "$RC" "AC7 a plain map after a refresh exits 0"
assert_contains "$OUT" "map=" "AC7 a plain map prints map="
assert_eq "0" "$(wc -c < "$NETLOG" | tr -d ' ')" "AC7 a plain map never runs gh, curl, glab or az"
assert_eq "0" "$(wc -l < "$CALLS" | tr -d ' ')" "AC7 a plain map makes no provider call"
assert_contains "$(cat "$MAP")" "merged elsewhere" "AC7 a plain map shows the refreshed merged rows from the snapshot"
for bad in "--bogus" "extra" "--refresh extra" "extra --refresh"; do
  OUT="$(bash "$TALOS" map $bad 2>/dev/null </dev/null)"; RC=$?
  assert_eq "2" "$RC" "AC7 map $bad is usage, exit 2"
  assert_contains "$OUT" "usage" "AC7 map $bad prints the usage stop"
done

# ── AC6: failures ────────────────────────────────────────────────────────────
reset
printf '%s\n' "queued fifty" > "$META/acme_widget.issue.50"
printf '%s\n' "flying fifty-one" > "$META/acme_widget.issue.51"
MERGED_FAIL=1 refresh
assert_eq "0" "$RC" "AC6 a failed merged list leaves exit 0"
assert_eq "1" "$(grep -c 'warn reason=merged-unavailable' <<< "$OUT"$'\n'"$ERR")" "AC6 a failed merged list is one warn reason=merged-unavailable"
assert_file_exists "$MAP" "AC6 the page still renders after a failed merged list"
assert_eq "1" "$(count_calls '^collect$')" "AC6 the collect was still made once"
BEFORE="$(cksum < "$MAP")"
: > "$CALLS"
COLLECT_FAIL=1 refresh
assert_eq "1" "$RC" "AC6 a failed collect stops"
assert_contains "$OUT" "state-unavailable" "AC6 a failed collect stops state-unavailable"
assert_eq "$BEFORE" "$(cksum < "$MAP")" "AC6 a failed collect changes no page"
assert_eq "0" "$(count_calls '^vcs list-merged-prs')" "AC6 a failed collect makes no merged list call"

# ── AC8: map.enabled false, the run entry ────────────────────────────────────
cfg_map ', "map": {"enabled": false}'
reset
python3 -I -c '
import json, sys
json.dump({"ts": "2026-01-01T00:00:00Z", "priority": {}, "collect": {}, "run": {"active": False, "started": "2026-01-01T00:00:00Z", "end": "done", "pid": 1}}, open(sys.argv[1], "w"))' "$SNAP"
printf '%s\n' "queued fifty" > "$META/acme_widget.issue.50"
printf '%s\n' "flying fifty-one" > "$META/acme_widget.issue.51"
refresh
assert_eq "0" "$RC" "AC8 --refresh with map.enabled false exits 0 ($ERR)"
assert_file_exists "$MAP" "AC8 --refresh writes the page with map.enabled false"
assert_eq "{'active': False, 'started': '2026-01-01T00:00:00Z', 'end': 'done', 'pid': 1}" "$(snap_field 'snap["run"]')" "AC8 the snapshot's run entry is left as it is"
assert_eq "4" "$(snap_field 'len(snap["merged_remote"])')" "AC8 --refresh writes the merged list to the snapshot"
OUT="$(bash "$TALOS" map 2>/dev/null </dev/null)"
assert_contains "$OUT" "map=" "AC8 a plain map renders as before"
cfg_map

# ── AC9: a snapshot with no merged_remote ────────────────────────────────────
reset
: > "$STATE/events.jsonl"
ev merged orchestrator 61 99 "" 1
python3 -I -c '
import json, sys
json.dump({"ts": "2026-01-01T00:00:00Z", "priority": {}, "collect": {}, "run": {}}, open(sys.argv[1], "w"))' "$SNAP"
: > "$NETLOG"
OUT="$(PATH="$NET:$PATH" bash "$TALOS_SRC/talos.sh" map 2>/dev/null </dev/null)"; RC=$?
assert_eq "0" "$RC" "AC9 a plain map on a snapshot with no merged_remote exits 0"
assert_not_contains "$(cat "$MAP")" "merged elsewhere" "AC9 no merged-elsewhere row without merged_remote"
assert_eq "1" "$(tile "$(cat "$MAP")" 'merged · 7 days')" "AC9 only the local merge counts"
assert_eq "0" "$(wc -c < "$NETLOG" | tr -d ' ')" "AC9 plain map makes no network call"

finish
