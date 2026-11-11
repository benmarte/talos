#!/usr/bin/env bash
# test-map-registry-903.sh -- the map registry's card data, checkout and config
# paths, locked writes and theme override (#903). Tests are named by the spec's id.
#   AC1 the entry carries provider, root, tiles, needs (3 rows, 7 keys), run and
#       state_read; no snapshot: state_read null, run idle, needs empty
#   AC2 title, why and next are at most 200 characters
#   AC3 provider is github, gitlab or azure; github-api is recorded as github
#   AC4 a render from a linked worktree records the main checkout as root
#   AC5 config is PIPELINE_CONFIG's absolute path when it is a regular file
#   AC6 registry writes run under an exclusive flock on index.json.lock; two
#       renders at once keep both entries (20 rounds)
#   AC8 the CSS dark palette follows prefers-color-scheme unless data-theme is
#       light, and always follows data-theme dark; the page never sets it
#   AC9 file, updated and line are unchanged
# AC7 and AC10 are prose (a 10 s wait and the doc wording).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

TALOS="$TALOS_ROOT/scripts/talos.sh"
MAPPY="$TALOS_ROOT/scripts/talos-map.py"
unset PIPELINE_CONFIG TALOS_ROLE TALOS_RUN_STARTED TALOS_RUN_PID
git config user.email "test@talos.invalid"
git config user.name "talos-test"

FX="$SANDBOX/fx"
EVENTS="$FX/events.jsonl"
mkdir -p "$FX/titles"
ISO() { python3 -I -c 'import datetime, sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
LONG="$(python3 -I -c 'print("q" * 300)')"

# ── The fixture: 4 stuck issues, 2 in flight, 1 live lane, 1 recent merge ───
printf '%s\n' "$LONG" > "$FX/titles/acme_widget.issue.11"
for n in 12 13 14 21 22; do printf 'Title %s\n' "$n" > "$FX/titles/acme_widget.issue.$n"; done
LATE="$(ISO 100)"; STAGE_AT="$(ISO 250)"; READ_AT="$(ISO 600)"
python3 -I -c '
import json, sys
fx, late, long_ = sys.argv[1], sys.argv[2], sys.argv[3]
ev = [
    {"event": "merged", "role": "orchestrator", "issue": 5, "pr": 50, "ts": late},
    {"event": "developer", "role": "developer", "issue": 12, "verdict": "BLOCKED", "summary": "tests keep failing", "tokens": 1500, "ts": late},
    {"event": "pm", "role": "pm", "issue": 13, "verdict": "BLOCKED", "summary": "BLOCKED: " + long_, "tokens": 1500, "ts": late},
]
open(fx + "/events.jsonl", "w").write("".join(json.dumps(e) + "\n" for e in ev))
' "$FX" "$LATE" "$LONG"
write_state() {  # <file> <read at | none>
  python3 -I -c '
import json, sys
path, read_at, long_ = sys.argv[1], sys.argv[2], sys.argv[3]
collect = {"prs": [], "queued": [], "inflight": [21, 22], "held": [], "blocked": [["issue", 14]], "capped": [],
           "owners": [{"n": 11, "status": "unanswered", "question": long_}]}
snap = {"ts": read_at, "priority": {}, "run": {"active": True, "started": read_at}, "collect": collect, "collect_ts": read_at}
if read_at == "none":
    snap = {"ts": "2026-01-01T00:00:00Z", "run": {}, "collect": {}}
json.dump(snap, open(path, "w"))' "$1" "$2" "$LONG"
}
lane() {  # <state dir> <name> <issue> <role> <stage start>: a live lane record (this shell's pid)
  mkdir -p "$1/lanes"
  python3 -I -c '
import json, sys
a = sys.argv
json.dump({"worktree": "/work/" + a[2], "issue": int(a[3]), "role": a[4], "stage_start": a[5], "ts": a[6], "pid": int(a[7])},
          open("%s/lanes/%s.json" % (a[1], a[2]), "w"))' "$1" "$2" "$3" "$4" "$5" "$(ISO 5)" "$$"
}
mapper() {  # <home> <state dir> <provider> <repo> [extra args]: the renderer, as talos.sh calls it
  local home="$1" sd="$2" prov="$3" repo="$4"; shift 4
  python3 -I "$MAPPY" --events "$EVENTS" --state "$sd/state.json" --home "$home" --provider "$prov" \
    --repo "$repo" --scripts "$TALOS_ROOT/scripts" --titles "$FX/titles" "$@" < /dev/null > /dev/null 2> "$SANDBOX/err"
}
reg() {  # <home> <slug> <python expression over e, the entry>
  python3 -I -c '
import json, sys
e = json.load(open(sys.argv[1] + "/maps/index.json")).get(sys.argv[2])
print(json.dumps(eval(sys.argv[3]), sort_keys=True, ensure_ascii=False))' "$1" "$2" "$3" 2>&1
}
tile() {  # <page> <label>: the number on a tile
  python3 -I -c '
import re, sys
m = re.search(r"<b>([^<]+)</b><span>%s</span>" % sys.argv[2], open(sys.argv[1]).read())
print(m.group(1) if m else "<none>")' "$1" "$2"
}

# ── AC1: the registry fields ─────────────────────────────────────────────────
SD1="$FX/state1"; H1="$FX/home1"; mkdir -p "$SD1"
write_state "$SD1/state.json" "$READ_AT"
lane "$SD1" lane-1 21 developer "$STAGE_AT"
mapper "$H1" "$SD1" github acme/widget --root /work/main
PAGE="$H1/maps/acme-widget.html"
assert_eq '"github"' "$(reg "$H1" acme/widget 'e["provider"]')" "AC1 provider"
assert_eq '"/work/main"' "$(reg "$H1" acme/widget 'e["root"]')" "AC1 root is the --root argument"
assert_eq '{"in_flight": 2, "merged_7d": 1, "needs": 4, "queued": 0, "tokens_7d": 3000}' "$(reg "$H1" acme/widget 'e["tiles"]')" "AC1 tiles"
assert_eq "4" "$(tile "$PAGE" 'needs you')" "AC1 the page's needs tile"
assert_eq "2" "$(tile "$PAGE" 'in flight')" "AC1 the page's in-flight tile"
assert_eq "1" "$(tile "$PAGE" 'merged · 7 days')" "AC1 the page's merged tile"
assert_eq "3k" "$(tile "$PAGE" 'tokens · 7 days')" "AC1 the page's tokens tile, which tiles.tokens_7d is the integer of"
assert_eq "3" "$(reg "$H1" acme/widget 'len(e["needs"])')" "AC1 needs holds exactly 3 rows"
assert_eq '[11, 12, 13]' "$(reg "$H1" acme/widget '[r["issue"] for r in e["needs"]]')" "AC1 needs rows are in page order"
assert_eq '[["issue", "kind", "next", "since", "title", "url", "why"]]' "$(reg "$H1" acme/widget '[sorted(k) for k in {tuple(sorted(r)) for r in e["needs"]}]')" "AC1 every row has the seven keys, and no other"
assert_eq '["owner question", "blocked", "epic · split proposed"]' "$(reg "$H1" acme/widget '[r["kind"] for r in e["needs"]]')" "AC1 kind is the stop kind the page shows"
assert_eq '["answer on the issue.", "read the issue'"'"'s latest comment, resolve what it names, then run again.", "approve or edit the split."]' "$(reg "$H1" acme/widget '[r["next"] for r in e["needs"]]')" "AC1 next is the To continue text, unescaped, without its prefix"
assert_eq '["https://github.com/acme/widget/issues/11", "https://github.com/acme/widget/issues/12", "https://github.com/acme/widget/issues/13"]' "$(reg "$H1" acme/widget '[r["url"] for r in e["needs"]]')" "AC1 url is the issue link"
assert_eq '"tests keep failing"' "$(reg "$H1" acme/widget 'e["needs"][1]["why"]')" "AC1 why is the row's reason"
assert_eq '"Title 12"' "$(reg "$H1" acme/widget 'e["needs"][1]["title"]')" "AC1 title is the page's title, not HTML"
assert_eq "\"$LATE\"" "$(reg "$H1" acme/widget 'e["needs"][1]["since"]')" "AC1 since is the ISO time of the issue's latest event"
assert_eq "\"$READ_AT\"" "$(reg "$H1" acme/widget 'e["needs"][0]["since"]')" "AC1 since is the state read's time for an issue with no event"
assert_eq '{"going": true, "issue": 21, "lanes": 1, "role": "developer", "stage_since": "'"$STAGE_AT"'"}' "$(reg "$H1" acme/widget 'e["run"]')" "AC1 run: going, the lane count and the live lane"
assert_eq "\"$READ_AT\"" "$(reg "$H1" acme/widget 'e["state_read"]')" "AC1 state_read is the snapshot's collect_ts"
# A second live lane that started later is the newest one, whatever its worktree's name.
lane "$SD1" lane-2 22 reviewer "$(ISO 50)"
mapper "$H1" "$SD1" github acme/widget
assert_eq '[2, 22, "reviewer"]' "$(reg "$H1" acme/widget '[e["run"]["lanes"], e["run"]["issue"], e["run"]["role"]]')" "AC1 run.lanes counts every live lane and the rest names the one with the greatest stage_start"
assert_eq 'false' "$(reg "$H1" acme/widget '"root" in e')" "AC1 without --root there is no root key"

SD0="$FX/state0"; H0="$FX/home0"; mkdir -p "$SD0"
write_state "$SD0/state.json" none
EVENTS="$FX/no-events.jsonl"   # the events alone would still make issues 12 and 13 Stuck
mapper "$H0" "$SD0" github acme/widget
EVENTS="$FX/events.jsonl"
assert_eq 'null' "$(reg "$H0" acme/widget 'e["state_read"]')" "AC1 no snapshot: state_read is null"
assert_eq '{"going": false, "lanes": 0}' "$(reg "$H0" acme/widget 'e["run"]')" "AC1 no snapshot: run is idle"
assert_eq '[]' "$(reg "$H0" acme/widget 'e["needs"]')" "AC1 no snapshot: needs is empty"

# ── AC2: the 200 character cap ───────────────────────────────────────────────
assert_eq '[200, 200, 200]' "$(reg "$H1" acme/widget '[len(e["needs"][0]["title"]), len(e["needs"][0]["why"]), len(e["needs"][2]["why"])]')" "AC2 a 300-character title and reason are cut to 200"
assert_eq 'true' "$(reg "$H1" acme/widget 'all(len(r[k]) <= 200 for r in e["needs"] for k in ("title", "why", "next"))')" "AC2 title, why and next are at most 200 characters"

# ── AC3: the provider ────────────────────────────────────────────────────────
HP="$FX/homep"
mapper "$HP" "$SD1" github-api acme/widget
assert_eq '"github"' "$(reg "$HP" acme/widget 'e["provider"]')" "AC3 github-api is recorded as github"
mapper "$HP" "$SD1" gitlab grp/proj
assert_eq '"gitlab"' "$(reg "$HP" grp/proj 'e["provider"]')" "AC3 gitlab"
mapper "$HP" "$SD1" azure widget --azure-org https://dev.azure.com/acme --azure-project proj
assert_eq '"azure"' "$(reg "$HP" acme/proj/widget 'e["provider"]')" "AC3 azure"

# ── AC4: a lane worktree records the main checkout ───────────────────────────
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
git commit -q --allow-empty -m init
git worktree add -q -b lane-x "$SANDBOX/lane-wt" HEAD
MAIN="$(cd "$SANDBOX" && pwd -P)"
export TALOS_HOME="$SANDBOX/th"
bash "$TALOS" map > /dev/null 2>&1
assert_eq "\"$MAIN\"" "$(reg "$TALOS_HOME" acme/widget 'e["root"]')" "AC4 from the main checkout root is that checkout"
rm -rf "${TALOS_HOME:?}"
(cd "$SANDBOX/lane-wt" && bash "$TALOS" map > /dev/null 2>&1)
assert_eq "\"$MAIN\"" "$(reg "$TALOS_HOME" acme/widget 'e["root"]')" "AC4 from a linked worktree root is the main checkout, not the worktree"

# ── AC5: config ──────────────────────────────────────────────────────────────
assert_eq "\"$PIPELINE_CONFIG\"" "$(reg "$TALOS_HOME" acme/widget 'e["config"]')" "AC5 config is PIPELINE_CONFIG's absolute path"
rm -rf "${TALOS_HOME:?}"
unset PIPELINE_CONFIG   # the project's talos.pipeline.json is still found from the cwd
bash "$TALOS" map > /dev/null 2>&1
assert_eq 'false' "$(reg "$TALOS_HOME" acme/widget '"config" in e')" "AC5 with PIPELINE_CONFIG unset, config is absent"
mapper "$FX/homem" "$SD1" github acme/widget --config "$SANDBOX/missing.json"
assert_eq 'false' "$(reg "$FX/homem" acme/widget '"config" in e')" "AC5 a path that is no regular file leaves config out"
mapper "$FX/homem" "$SD1" github acme/widget --config "$SANDBOX"
assert_eq 'false' "$(reg "$FX/homem" acme/widget '"config" in e')" "AC5 a directory leaves config out"
unset TALOS_HOME

# ── AC6: the lock ────────────────────────────────────────────────────────────
HL="$FX/homel"; mkdir -p "$HL/maps"
HOLD="$FX/hold-ready"; RELEASE="$FX/hold-release"
rm -f "$HOLD" "$RELEASE"
python3 -I -c '
import fcntl, os, sys, time
f = open(sys.argv[1], "a")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
end = time.time() + 30
while not os.path.exists(sys.argv[3]) and time.time() < end:
    time.sleep(0.05)' "$HL/maps/index.json.lock" "$HOLD" "$RELEASE" &
HOLDER=$!
wait_until 10 test -e "$HOLD"
printf '{"other/repo": {"file": "other-repo.html", "line": "x", "updated": "2026-01-01T00:00:00Z"}}\n' > "$HL/maps/index.json"
mapper "$HL" "$SD1" github acme/widget &
RENDER=$!
sleep 1.5
assert_eq '["other/repo"]' "$(python3 -I -c 'import json, sys; print(json.dumps(sorted(json.load(open(sys.argv[1])))))' "$HL/maps/index.json")" "AC6 while the lock is held the render does not rewrite index.json"
: > "$RELEASE"
wait "$RENDER"
wait "$HOLDER"
assert_eq '["acme/widget", "other/repo"]' "$(python3 -I -c 'import json, sys; print(json.dumps(sorted(json.load(open(sys.argv[1])))))' "$HL/maps/index.json")" "AC6 once the lock is released the render adds its entry and keeps the other"
assert_file_exists "$HL/maps/index.json.lock" "AC6 the lock file is maps/index.json.lock"

HC="$FX/homec"; lost=0
for i in $(seq 1 20); do
  rm -rf "${HC:?}"
  mapper "$HC" "$SD1" github acme/widget &
  A=$!
  mapper "$HC" "$SD1" github acme/other &
  B=$!
  wait "$A"; wait "$B"
  got="$(python3 -I -c 'import json, sys; print(json.dumps(sorted(json.load(open(sys.argv[1])))))' "$HC/maps/index.json" 2>&1)"
  [ "$got" = '["acme/other", "acme/widget"]' ] || { lost=$((lost + 1)); LAST="$got"; }
done
assert_eq "0" "$lost" "AC6 two renders at once keep both entries, 20 rounds" "${LAST:-}"

# ── AC8: the theme override, from the emitted CSS ────────────────────────────
CSS="$(cat "$PAGE")"
python3 -I -c '
import re, sys
css = re.search(r"<style>(.*?)</style>", open(sys.argv[1]).read(), re.S).group(1)
media = re.search(r"@media \(prefers-color-scheme:dark\)\{(.*?)\}\}", css, re.S)
forced = re.search(r":root\[data-theme=\"dark\"\]\{(.*?)\}", css, re.S)
print("media-selector", ":root:not([data-theme=\"light\"])" in (media.group(1) if media else ""))
print("media-bare", bool(media and re.match(r"\s*:root\{", media.group(1))))
print("forced-dark", bool(forced and "--bg:#151513" in forced.group(1)))
print("same-palette", bool(media and forced and media.group(1).split("{", 1)[1] == forced.group(1)))
print("light-root", bool(re.search(r"^:root\{--bg:#f7f6f2", css, re.M)))
print("sets-attribute", "data-theme" in re.sub(r"<style>.*?</style>", "", open(sys.argv[1]).read(), flags=re.S))' "$PAGE" > "$FX/theme.out"
assert_contains "$(cat "$FX/theme.out")" "media-selector True" "AC8 the dark palette under prefers-color-scheme is limited to :root:not([data-theme=\"light\"])"
assert_contains "$(cat "$FX/theme.out")" "media-bare False" "AC8 no bare :root dark rule is left under the media query"
assert_contains "$(cat "$FX/theme.out")" "forced-dark True" "AC8 :root[data-theme=\"dark\"] carries the dark palette"
assert_contains "$(cat "$FX/theme.out")" "same-palette True" "AC8 the forced and the preferred dark palettes are the same"
assert_contains "$(cat "$FX/theme.out")" "light-root True" "AC8 the light palette stays the :root default"
assert_contains "$(cat "$FX/theme.out")" "sets-attribute False" "AC8 the page itself never sets data-theme"
assert_not_contains "$CSS" '<html lang="en" data-theme' "AC8 the html element carries no data-theme"

# ── AC9: the existing keys ───────────────────────────────────────────────────
assert_eq '"acme-widget.html"' "$(reg "$H1" acme/widget 'e["file"]')" "AC9 file is unchanged"
assert_eq 'true' "$(reg "$H1" acme/widget 'e["line"] == "1 merged · 2 in flight · 4 stuck · 0 not started"')" "AC9 line is unchanged"
assert_eq 'true' "$(reg "$H1" acme/widget 'bool(__import__("re").fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", e["updated"]))')" "AC9 updated is unchanged"

finish
