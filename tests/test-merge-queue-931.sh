#!/usr/bin/env bash
# test-merge-queue-931.sh -- merge queue 4/5 (#931): a red `queue run`
# candidate is bisected until one PR is isolated; that PR is ejected through its
# `talos:queue` marker (failing check + link) and the merge gate routes it to a
# developer fix round; the rest is re-tested and merges. A failed lookup or a
# timeout mid-bisection merges nothing. Tests are named by the spec's criterion id.
#
# The fixture is the #930 one (tests/test-merge-queue-930.sh): the sandbox and
# journaling stubs of tests/talos-run-sections.sh (TALOS_RUN_PART=931
# TALOS_RUN_EMBED=1), a local bare `origin` and real PR branches. PRs 11, 12, 13
# (issues 41, 42, 43) each add their own file a<pr>.txt; the check hook answers
# red, with one `fail` row, when the candidate tree holds the file of a PR listed
# in $STUB_DIR/bad. No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=931 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0
MARK='<!-- talos:queue -->'

# ── fixtures (as tests/test-merge-queue-930.sh) ──────────────────────────────
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
UPD="$SANDBOX/origin-updates.log"
export Q_ORIGIN="$ORIGIN" Q_SEED="$SEED"
git remote set-url origin "$ORIGIN"

GQ="$SANDBOX/gq"
mkdir -p "$GQ"
cp "$GS"/* "$GQ/"
for s in pipeline-mergebase.sh pipeline-worktree.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GQ/$s"
done

sg() { git -C "$SEED" "$@"; }
origin_reset() {
  rm -rf "${ORIGIN:?}" "${SEED:?}"
  : > "$UPD"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  cat > "$ORIGIN/hooks/update" <<TALOS_updhookV7c2Nq8Rj4
#!/bin/sh
printf '%s %s %s\n' "\$1" "\$2" "\$3" >> "$UPD"
TALOS_updhookV7c2Nq8Rj4
  chmod +x "$ORIGIN/hooks/update"
  git init -q "$SEED"
  sg symbolic-ref HEAD refs/heads/main
  sg config user.name talos-test
  sg config user.email test@talos.invalid
  sg config commit.gpgsign false
  printf 'base\n' > "$SEED/base.txt"
  sg add -A
  sg commit -q -m base
  sg remote add origin "$ORIGIN"
  sg push -q origin main
}
comments_json() {
  python3 -I -c '
import json, sys
out = []
for a in sys.argv[1:]:
    login, body = a.split("|", 1)
    out.append({"author": {"login": login}, "body": body.replace("\\n", "\n")})
print(json.dumps({"comments": out}))' "$@"
}
qbody() { printf '**Merge queue:**\\n\\nqueue: base=%s head=%s eligible=%s\\n\\n%s' "$1" "$2" "$3" "$MARK"; }
ebody() { printf '**Merge queue:** ejected\\n\\nqueue: ejected base=%s head=%s\\nFailing check: unit-tests (fail)\\n\\n%s' "$1" "$2" "$MARK"; }
Q_LIST=""
Q_SEQ=0
q_pr() {  # <pr> <issue>: branch feat/issue-<issue>-q adds a<pr>.txt; queued
  local _pr="$1" _n="$2" _br="feat/issue-$2-q" _h
  sg checkout -q -B "$_br" main
  printf 'x%s\n' "$_pr" > "$SEED/a$_pr.txt"
  sg add -A
  sg commit -q -m "pr$_pr"
  sg push -q -f origin "$_br"
  _h="$(sg rev-parse HEAD)"
  sg checkout -q main
  Q_SEQ=$((Q_SEQ + 1))
  printf '%s' "$_h" > "$STUB_DIR/pr-head.$_pr"
  comments_json "owner|$(qbody main "$_h" "$(printf '2026-11-01T00:00:%02dZ' "$Q_SEQ")")" > "$STUB_DIR/read-comments.$_pr"
  printf '{"number": %s, "headRefName": "%s", "baseRefName": "main", "labels": [], "state": "open"}' "$_pr" "$_br" > "$STUB_DIR/view-pr.$_pr"
  Q_LIST="$Q_LIST${Q_LIST:+,}{\"number\":$_pr,\"baseRefName\":\"main\",\"headRefName\":\"$_br\",\"isCrossRepository\":false}"
  export LIST_PRS="[$Q_LIST]"
}
q_cfg() {  # <merge.queue or ->
  local _q=""
  [ "$1" = "-" ] || _q="\"queue\": \"$1\", "
  printf '{"vcs": {"provider": "github"}, "base_branch": "main", "merge": {%s"method": "squash"}}' "$_q" > "$SANDBOX/talos.pipeline.json"
}
# The check hook: each call logs the candidate's PRs and its base (the commit
# under its one squash commit per PR) to cands, and how many candidates origin
# holds to cand.live; red with $STUB_DIR/badrow (default one `fail` row) when the
# tree holds a PR named in $STUB_DIR/bad.
CHECK_HOOK='t="$(git -C "$Q_ORIGIN" ls-tree --name-only "$2" | sed -n "s/^a\([0-9]*\)\.txt\$/\1/p" | tr "\n" " " | sed "s/ \$//")"
printf "(%s) %s\n" "$t" "$(git -C "$Q_ORIGIN" rev-parse "$2~$(printf "%s" "$t" | wc -w | tr -d " ")")" >> "$d/cands"
git -C "$Q_ORIGIN" for-each-ref --format="%(refname:short)" refs/heads/talos/queue/ | grep -c . >> "$d/cand.live"
for b in $(cat "$d/bad" 2>/dev/null); do
  case " $t " in *" $b "*)
    if [ -f "$d/badrow" ]; then cat "$d/badrow"; else printf "unit-tests\tfail\t1m2s\thttps://ci.example/runs/%s\n" "$2"; fi
    exit 1 ;;
  esac
done
'
q_reset() {
  reset_stubs
  LEASE_RESET
  Q_LIST=""; Q_SEQ=0
  export LIST_PRS="[]" LIST_ISSUES="[]"
  printf 'owner' > "$STUB_DIR/current-user"
  printf 'talos:checkout state=kept' > "$STUB_DIR/worktree.out"
  printf 'upserted pr=12 comment=updated' > "$STUB_DIR/upsert-pr-comment.out"
  printf '%s' "$CHECK_HOOK" > "$STUB_DIR/hook.ref-checks-required"
  q_cfg talos
  origin_reset
}
q_three() { q_pr 11 41; q_pr 12 42; q_pr 13 43; }
bad() { printf '%s\n' "$*" > "$STUB_DIR/bad"; }
qr() { OUT="$(bash "${QG:-$GQ}/talos.sh" queue run </dev/null 2>"$ERR")"; RC=$?; }
jc() { journal | grep -c -E "$1"; }
cand_pushes() { grep -c -E '^refs/heads/talos/queue/main-[0-9]+ 0{40} ' "$UPD"; }
queue_left() { git -C "$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads/talos/queue/ | grep -c .; }
line1() { printf '%s\n' "$OUT" | sed -n 1p; }
has_line() { grep -qx -- "$1" <<< "$OUT"; }
assert_line() { if has_line "$2"; then pass "$1"; else fail "$1" "no line '$2' in: $(printf '%s' "$OUT" | tr '\n' '|')"; fi; }
merge_order() { journal | grep -oE '^vcs merge-pr [0-9]+' | tr '\n' '>' | sed 's/>$//'; }
cand_sets() { sed 's/ [0-9a-f]*$//' "$STUB_DIR/cands" 2>/dev/null | tr '\n' ',' | sed 's/,$//'; }
# upsert_body <pr>: the body of the upsert-pr-comment call on <pr>, as posted (the
# verb appends a blank line and the marker).
upsert_body() {
  awk -v h="[upsert-pr-comment $1 --marker queue --body-file -]" '
    /^\[/ { on = ($0 == h); next } on { print }' "$STUB_DIR/bodies" 2>/dev/null
  printf '\n%s\n' "$MARK"
}

# ── AC1, AC2, AC3: one bad PR of three ───────────────────────────────────────
q_reset; q_three; bad 12
H12="$(cat "$STUB_DIR/pr-head.12")"
qr
assert_eq "0|verdict=merged" "$RC|$(line1)" "AC1 one bad PR of three: verdict=merged, exit 0"
assert_line "AC1 the bad PR is ejected: ejected=12 issue=42" "ejected=12 issue=42"
assert_eq "vcs merge-pr 11>vcs merge-pr 13" "$(merge_order)" "AC1 merge-pr 11 then 13, never 12"
assert_eq "0" "$(queue_left)" "AC1 no candidate is left on origin"
assert_eq "1" "$(sort -u "$STUB_DIR/cand.live" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" \
  "AC1 origin holds one candidate at every check (the previous one deleted first)"
assert_eq "(11 12 13),(11),(11 12),(11 13)" "$(cand_sets)" "AC2 candidates tested in order (11 12 13), (11), (11 12), (11 13)"
assert_eq "1" "$(sed 's/.* //' "$STUB_DIR/cands" 2>/dev/null | sort -u | grep -c .)" "AC2 every candidate is cut from the same base sha"
assert_eq "$(git -C "$ORIGIN" rev-parse main)" "$(sed -n '1s/.* //p' "$STUB_DIR/cands" 2>/dev/null)" "AC2 that base sha is main's head"
assert_eq "1" "$(jc '^vcs upsert-pr-comment ')" "AC3 exactly one upsert-pr-comment call"
assert_eq "1" "$(jc '^vcs upsert-pr-comment 12 --marker queue ')" "AC3 the upsert is on PR 12 with --marker queue"
B12="$(upsert_body 12)"
assert_eq "queue: ejected base=main head=$H12" "$(printf '%s\n' "$B12" | grep '^queue:')" "AC3 the body has the single data line queue: ejected base=main head=<12 head>"
assert_eq "**Merge queue:** ejected" "$(printf '%s\n' "$B12" | sed -n 1p)" "AC3 the body starts **Merge queue:** ejected"
assert_contains "$B12" "unit-tests" "AC3 the body names the failing check"
assert_contains "$B12" "https://ci.example/runs/" "AC3 the body carries the check url"
assert_eq "$MARK" "$(printf '%s\n' "$B12" | grep . | tail -n 1)" "AC3 the posted comment ends with the marker"

# ── AC4: a batch of one red PR ───────────────────────────────────────────────
q_reset; q_pr 12 42; bad 12
qr
assert_eq "verdict=ejected" "$(line1)" "AC4 a batch of one red PR: verdict=ejected"
assert_line "AC4 ejected=12 issue=42" "ejected=12 issue=42"
assert_eq "1|0|0" "$(cand_pushes)|$(jc '^vcs merge-pr')|$(queue_left)" "AC4 one push, no merge-pr, no candidate left"

# ── AC5: every check red ─────────────────────────────────────────────────────
q_reset; q_three; bad 11 12 13
qr
assert_eq "verdict=ejected" "$(line1)" "AC5 every check red: verdict=ejected"
assert_eq "ejected=11 issue=41
ejected=12 issue=42
ejected=13 issue=43" "$(printf '%s\n' "$OUT" | grep '^ejected=')" "AC5 11, 12, 13 ejected in order"
assert_eq "0|0" "$(jc '^vcs merge-pr')|$(queue_left)" "AC5 no merge-pr, no candidate left"

# ── AC6, AC7: a lookup failure or a timeout mid-bisection merges nothing ─────
q_bad_then() {  # <rc>: the first check call is red, every later one exits <rc>
  q_reset; q_three; bad 12
  printf '[ "$(grep -c "^vcs ref-checks-required " "$d/journal")" -le 1 ] || exit %s\n%s' "$1" "$CHECK_HOOK" \
    > "$STUB_DIR/hook.ref-checks-required"
  qr
}
q_bad_then 3
assert_eq "verdict=wait" "$(line1)" "AC6 a sub-candidate check exit 3: verdict=wait"
assert_line "AC6 reason=checks-unverified" "reason=checks-unverified"
assert_eq "0|0|0|0" "$(jc '^vcs merge-pr')|$(jc '^vcs upsert-pr-comment')|$(jc '^hooks post_stage queue_eject ')|$(queue_left)" \
  "AC6 no merge-pr, no upsert, no queue_eject, no candidate left"
q_bad_then 2
assert_eq "verdict=wait" "$(line1)" "AC7 a sub-candidate pending: verdict=wait"
assert_line "AC7 reason=candidate-timeout" "reason=candidate-timeout"
assert_eq "121" "$(jc '^vcs ref-checks-required ')" "AC7 one red call, then 120 calls on the sub-candidate"
assert_eq "0|0|0" "$(jc '^vcs merge-pr')|$(jc '^vcs upsert-pr-comment')|$(queue_left)" "AC7 no merge-pr, no upsert, no candidate left"

# ── AC8: the isolating red answer names no failed check ──────────────────────
q_reset; q_three; bad 12
printf 'unit-tests\tpass\t1m\thttps://ci.example/ok\nlint\tpending\t0s\thttps://ci.example/p\n' > "$STUB_DIR/badrow"
qr
assert_eq "verdict=wait" "$(line1)" "AC8 a red answer with no fail or cancel row: verdict=wait"
assert_line "AC8 reason=checks-unverified" "reason=checks-unverified"
assert_eq "0|0" "$(jc '^vcs upsert-pr-comment')|$(jc '^vcs merge-pr')" "AC8 no upsert, no merge-pr"
q_reset; q_pr 12 42; bad 12
printf 'unit-tests\tcancel\t1m\thttps://ci.example/c\n' > "$STUB_DIR/badrow"
qr
assert_eq "verdict=ejected" "$(line1)" "AC8 a cancel row is a failed check: the PR is ejected"
assert_contains "$(upsert_body 12)" "https://ci.example/c" "AC8 the cancel row's url is in the eject comment"

# ── AC9: the eject write fails ───────────────────────────────────────────────
q_reset; q_three; bad 12
printf 1 > "$STUB_DIR/upsert-pr-comment.rc"
qr
assert_eq "verdict=wait" "$(line1)" "AC9 a failed eject upsert: verdict=wait"
assert_line "AC9 reason=queue-state-unverified" "reason=queue-state-unverified"
assert_line "AC9 pr=12" "pr=12"
assert_eq "0|0|0" "$(jc '^vcs merge-pr')|$(jc '^hooks post_stage queue_eject ')|$(queue_left)" "AC9 no merge-pr, no queue_eject, no candidate left"

# ── AC10: queue_eject reaches events.jsonl through the real hooks ────────────
GQ2="$SANDBOX/gq2"
mkdir -p "$GQ2"
cp "$GQ"/* "$GQ2/"
cp "$TALOS_ROOT/scripts/pipeline-hooks.sh" "$TALOS_ROOT/scripts/pipeline-events.sh" "$GQ2/"
EVENTS="$SANDBOX/.git/talos/events.jsonl"
q_reset; q_three; bad 12; rm -f "$EVENTS"
H12="$(cat "$STUB_DIR/pr-head.12")"
QG="$GQ2" qr
if r="$(python3 -I -c '
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
ej = [e for e in evs if e.get("event") == "queue_eject"]
if len(ej) != 1:
    sys.exit("queue_eject events: %d" % len(ej))
e = ej[0]
got = (e.get("role"), e.get("issue"), e.get("pr"), e.get("sha"), e.get("batch_size"))
if got != ("orchestrator", 42, 12, sys.argv[2], 3):
    sys.exit("role/issue/pr/sha/batch_size: %r" % (got,))
if not isinstance(e.get("duration_s"), int) or isinstance(e.get("duration_s"), bool):
    sys.exit("duration_s: %r" % e.get("duration_s"))
if list(e).index("batch_size") != len(e) - 2:
    sys.exit("batch_size is not right before ts: %r" % list(e))
' "$EVENTS" "$H12" 2>&1)"; then
  pass "AC10 one queue_eject: role orchestrator, issue 42, pr 12, sha the 12 head, batch_size 3 before ts, integer duration_s"
else fail "AC10 one queue_eject: role orchestrator, issue 42, pr 12, sha the 12 head, batch_size 3 before ts, integer duration_s" "$r"; fi

# ── AC11: an ejected marker at the current head leaves the queue ─────────────
q_reset; q_three
comments_json "owner|$(ebody main "$(cat "$STUB_DIR/pr-head.12")")" > "$STUB_DIR/read-comments.12"
OUT="$(bash "$GQ/talos.sh" queue list </dev/null 2>"$ERR")"; RC=$?
assert_eq "0" "$RC" "AC11 queue list with an ejected marker exits 0"
assert_eq "11 13" "$(printf '%s\n' "$OUT" | sed -n 's/^queued pr=\([0-9]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//')" \
  "AC11 queue list omits the ejected PR and lists the rest"
qr
assert_eq "(11 13)" "$(cand_sets)" "AC11 queue run leaves the ejected PR out of the candidate"
assert_eq "verdict=merged" "$(line1)" "AC11 queue run merges the rest"

# ── AC12, AC13: gate merge on an ejected marker ──────────────────────────────
HA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HB="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
g_fixture() {  # <ejected head>: PR 12 (issue 9) passes every gate at head HA
  origin_reset
  merge_fixture "$ALL_APPROVALS" ', "base_branch": "main", "merge": {"queue": "talos"}'
  draft_ready
  printf 'owner' > "$STUB_DIR/current-user"
  printf '%s' "$HA" > "$STUB_DIR/pr-head.12"
  comments_json "owner|$(ebody main "$1")" > "$STUB_DIR/read-comments.12"
  printf 'upserted pr=12 comment=updated' > "$STUB_DIR/upsert-pr-comment.out"
  export LIST_PRS="[]"
}
gm() { rm -f "$STUB_DIR/journal" "$STUB_DIR/bodies"; OUT="$(bash "$RUN" gate merge 12 9 </dev/null 2>"$ERR")"; RC=$?; }
g_fixture "$HA"; gm
assert_eq "verdict=redispatch
reason=queue-ejected" "$OUT" "AC12 an ejected marker at the current head: verdict=redispatch reason=queue-ejected"
assert_eq "0|0" "$(jc '^vcs upsert-pr-comment')|$(jc '^hooks post_stage queue_enqueue ')" "AC12 no upsert, no queue_enqueue"
g_fixture "$HB"; gm
assert_eq "verdict=wait
reason=queued" "$OUT" "AC13 an ejected marker for an older head: verdict=wait reason=queued"
assert_eq "1" "$(grep -c "^queue: base=main head=$HA eligible=" "$STUB_DIR/bodies" 2>/dev/null)" \
  "AC13 the marker is rewritten to queue: base=main head=<new head>"

# ── AC14: run takes a queue-ejected redispatch to a developer fix round ──────
g_fixture "$HA"
printf 'https://github.com/acme/widget/pull/12\nfixed the failing check\n' > "$STUB_DIR/message.developer"
cat > "$STUB_DIR/hook.developer.1" <<'TALOS_devhookK3p9Wz7Lq2'
cp "$d/agent.stdin" "$d/developer.prompt"
printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"
TALOS_devhookK3p9Wz7Lq2
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 1
assert_eq "0" "$RC" "AC14 a queue-ejected redispatch: the run exits 0"
assert_eq "vcs record-attempt 9 developer --pr 12>agent developer" \
  "$(grep -oE 'vcs record-attempt 9 developer --pr 12|agent developer' "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//')" \
  "AC14 record-attempt developer --pr, then one developer dispatch"
assert_contains "$(cat "$STUB_DIR/developer.prompt" 2>/dev/null)" "ejected from the merge queue" \
  "AC14 the fix-round summary says the PR was ejected from the merge queue"
assert_eq "0|0" "$(jc '^vcs merge-pr')|$(jc '^vcs ref-checks-required')" "AC14 no merge-pr, no queue run check"
assert_not_contains "$OUT" "stop queue" "AC14 no queue run"

# ── AC15: unset or off is unchanged ──────────────────────────────────────────
for q in - off; do
  q_reset; q_three; bad 12; q_cfg "$q"; : > "$UPD"
  qr
  assert_eq "0|verdict=off" "$RC|$OUT" "AC15 merge.queue=$q: queue run answers verdict=off"
  assert_eq "0|0" "$(jc '^vcs ')|$(grep -c . "$UPD")" "AC15 merge.queue=$q: no provider call, no push"
done

finish
