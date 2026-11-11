#!/usr/bin/env bash
# test-title-cache-886.sh -- the map's title cache (#886, part A of #884):
#   AC1  issue-title never caches or prints a GitHub error body (a failed `gh`, or a JSON body)
#   AC2  a multi-line value is neither printed nor cached
#   AC3  with vcs.provider azure or gitlab, issue-title and pr-title make no gh call
#   AC4  talos-map.py renders `(title not cached)` for a cache file holding a JSON error body
#   AC5  a successful collect fills the title cache from the list-issues rows, with no extra call
#   AC6  a collect whose list-issues fails writes nothing to the title cache
#   AC7  provider github: a clean title is still printed and cached; board/repo-url make no gh call
# Every test runs on shims: no GitHub call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

PARENT="$(mktemp -d "${TMPDIR:-/tmp}/talos-titlecache.XXXXXX")" || exit 1
{ [ -n "$PARENT" ] && [ -d "$PARENT" ]; } || exit 1
trap '_is_trap_owner && rm -rf "$SANDBOX" "$PARENT"' EXIT

META="$TALOS_ROOT/scripts/pipeline-meta.sh"
export XDG_RUNTIME_DIR="$PARENT/xdg"
mkdir -p "$XDG_RUNTIME_DIR"
CACHE="$XDG_RUNTIME_DIR/talos/meta"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
cfg_provider() { printf '{"vcs": {"provider": "%s", "repo": "acme/widget"}}\n' "$1" > "$PIPELINE_CONFIG"; }
cached() { ls "$CACHE" 2>/dev/null | tr '\n' ' '; }
clear_cache() { rm -rf "${CACHE:?}"; }

# A gh shim: logs each call; prints $GHS_OUT (with a literal \n turned into a newline) and exits $GHS_RC.
SHIM="$PARENT/shim"
mkdir -p "$SHIM"
cat > "$SHIM/gh" <<'TALOS_ghshim886Kq3Zw'
#!/bin/sh
printf '%s\n' "$*" >> "${GHS_LOG:?}"
[ -n "${GHS_OUT:-}" ] && printf '%b\n' "$GHS_OUT"
exit "${GHS_RC:-0}"
TALOS_ghshim886Kq3Zw
chmod +x "$SHIM/gh"
export GHS_LOG="$PARENT/gh.log"
: > "$GHS_LOG"
ERR404='{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'

# ── AC1: an error body is never cached or printed ─────────────────────────────
cfg_provider github
clear_cache
OUT="$(PATH="$SHIM:$PATH" GHS_OUT="$ERR404" GHS_RC=1 bash "$META" --repo acme/widget issue-title 7 2>/dev/null)"
assert_eq "" "$OUT" "AC1 a 404 body with gh exiting 1 prints nothing"
assert_eq "" "$(cached)" "AC1 a 404 body with gh exiting 1 caches nothing"
OUT="$(PATH="$SHIM:$PATH" GHS_OUT="$ERR404" GHS_RC=0 bash "$META" --repo acme/widget issue-title 7 2>/dev/null)"
assert_eq "" "$OUT" "AC1 a JSON body with gh exiting 0 prints nothing"
assert_eq "" "$(cached)" "AC1 a JSON body with gh exiting 0 caches nothing"
OUT="$(PATH="$SHIM:$PATH" GHS_OUT='x documentation_url "documentation_url" y' GHS_RC=0 bash "$META" --repo acme/widget issue-title 7 2>/dev/null)"
assert_eq "" "$OUT" "AC1 a value naming documentation_url prints nothing"
assert_eq "" "$(cached)" "AC1 a value naming documentation_url caches nothing"

# ── AC2: a two-line value is refused ──────────────────────────────────────────
OUT="$(PATH="$SHIM:$PATH" GHS_OUT='first line\nsecond line' GHS_RC=0 bash "$META" --repo acme/widget issue-title 7 2>/dev/null)"
assert_eq "" "$OUT" "AC2 a two-line value prints nothing"
assert_eq "" "$(cached)" "AC2 a two-line value caches nothing"

# ── AC3: a non-GitHub provider makes no gh call ───────────────────────────────
for prov in azure gitlab; do
  cfg_provider "$prov"
  clear_cache
  : > "$GHS_LOG"
  OUT="$(PATH="$SHIM:$PATH" GHS_OUT="A title" bash "$META" --repo acme/widget issue-title 8 2>/dev/null)"
  OUT="$OUT$(PATH="$SHIM:$PATH" GHS_OUT="A title" bash "$META" --repo acme/widget pr-title 8 2>/dev/null)"
  assert_eq "" "$OUT" "AC3 $prov: issue-title and pr-title print nothing"
  assert_eq "" "$(cat "$GHS_LOG")" "AC3 $prov: no gh call"
  assert_eq "" "$(cached)" "AC3 $prov: nothing cached"
done

# ── AC4: the map ignores a cached error body ──────────────────────────────────
cfg_provider github
STATE="$SANDBOX/.git/talos"
mkdir -p "$STATE" "$CACHE"
: > "$STATE/events.jsonl"
python3 -I -c '
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"ts": now, "collect_ts": now, "priority": {}, "run": {"active": True, "started": now},
           "collect": {"prs": [], "queued": [61, 62, 63], "inflight": [], "held": [], "blocked": [], "capped": [], "owners": []}},
          open(sys.argv[1], "w"))' "$STATE/state.json"
printf '%s\n' "$ERR404" > "$CACHE/acme_widget.issue.61"
printf '{\n  "message": "Not Found"\n}\n' > "$CACHE/acme_widget.issue.62"
printf 'see "documentation_url" for more\n' > "$CACHE/acme_widget.issue.63"
bash "$TALOS_ROOT/scripts/talos.sh" map >/dev/null 2>"$SANDBOX/err"
PAGE="$(cat "$HOME/.talos/maps/acme-widget.html" 2>/dev/null)"
for n in 61 62 63; do
  assert_contains "$PAGE" "#$n</a></td><td>(title not cached)</td>" "AC4 #$n: a cached JSON error body renders (title not cached)"
done
assert_not_contains "$PAGE" "Not Found" "AC4 the error body is not on the page"

# ── AC5, AC6: collect fills the cache from its own read ───────────────────────
SCR="$PARENT/scripts"
FX="$PARENT/fx"
mkdir -p "$FX"
export SF_FX="$FX"
cp -R "$TALOS_ROOT/scripts" "$SCR"
cat > "$SCR/pipeline-vcs.sh" <<'TALOS_stubvcs886Lm4Xa'
#!/usr/bin/env bash
FX="${SF_FX:?}"
verb="${1:-}"; shift
printf '%s\n' "$verb" >> "$FX/calls.log"
case "$verb" in
  list-prs) echo '[]'; exit 0 ;;
  list-issues) [ -f "$FX/issues.rc" ] && exit "$(cat "$FX/issues.rc")"; cat "$FX/issues.json"; exit 0 ;;
  list-needs-owner) echo '[]'; exit 0 ;;
  current-user) exit 1 ;;
  *) printf 'OTHER %s\n' "$verb" >> "$FX/calls.log"; exit 99 ;;
esac
TALOS_stubvcs886Lm4Xa
cat > "$FX/issues.json" <<'TALOS_issues886Rt5Yb'
[{"number": 71, "title": "Add retry to the sync", "labels": [{"name": "pipeline:ready"}]},
 {"number": 72, "title": "Second one", "labels": [{"name": "pipeline:dev"}]},
 {"number": 73, "title": "{\"not\": \"a title\"}", "labels": [{"name": "pipeline:ready"}]}]
TALOS_issues886Rt5Yb
cfg_provider azure
clear_cache
: > "$FX/calls.log"; : > "$GHS_LOG"
OUT="$(PATH="$SHIM:$PATH" bash "$SCR/pipeline-status-file.sh" collect 2>"$SANDBOX/err")"; RC=$?
assert_eq "0" "$RC" "AC5 the collect succeeds" "$(cat "$SANDBOX/err")"
assert_eq "Add retry to the sync" "$(cat "$CACHE/acme_widget.issue.71" 2>/dev/null)" "AC5 #71's title is cached under the key the map reads"
assert_eq "Second one" "$(cat "$CACHE/acme_widget.issue.72" 2>/dev/null)" "AC5 #72's title is cached"
assert_eq "no" "$([ -e "$CACHE/acme_widget.issue.73" ] && echo yes || echo no)" "AC5 a title that is JSON is not cached"
assert_eq "" "$(cat "$GHS_LOG")" "AC5 no gh call"
assert_eq "" "$(grep -v -x -e list-prs -e list-issues -e list-needs-owner -e current-user "$FX/calls.log")" "AC5 only the verbs collect already used"
assert_contains "$OUT" '"queued"' "AC5 collect's stdout is still the state JSON"

clear_cache
printf '1' > "$FX/issues.rc"
OUT="$(PATH="$SHIM:$PATH" bash "$SCR/pipeline-status-file.sh" collect 2>/dev/null)"; RC=$?
assert_eq "1" "$RC" "AC6 a failed list-issues fails the collect"
assert_eq "" "$(cached)" "AC6 a failed list-issues writes nothing to the title cache"
rm -f "$FX/issues.rc"

# ── AC7: GitHub still works ───────────────────────────────────────────────────
cfg_provider github
clear_cache
: > "$GHS_LOG"
OUT="$(PATH="$SHIM:$PATH" GHS_OUT="Fix login crash" bash "$META" --repo acme/widget issue-title 9 2>/dev/null)"
assert_eq "Fix login crash" "$OUT" "AC7 provider github: a clean title is printed"
assert_eq "Fix login crash" "$(cat "$CACHE/acme_widget.issue.9" 2>/dev/null)" "AC7 provider github: a clean title is cached"
assert_contains "$(cat "$GHS_LOG")" "api repos/acme/widget/issues/9 --jq .title" "AC7 provider github: one REST read"
: > "$GHS_LOG"
PATH="$SHIM:$PATH" bash "$META" --repo acme/widget board >/dev/null 2>&1
PATH="$SHIM:$PATH" bash "$META" --repo acme/widget repo-url >/dev/null 2>&1
assert_eq "" "$(cat "$GHS_LOG")" "AC7 board and repo-url make no gh call"

finish
