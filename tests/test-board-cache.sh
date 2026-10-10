#!/usr/bin/env bash
# test-board-cache.sh -- board moves cost the fewest GraphQL calls (#554).
#
# A move used to resolve the owner and repo (`gh repo view` x2), the project
# (`project list`), page through `project item-list --limit 400` for the issue,
# and edit: five GraphQL calls, per move, plus `field-list` once. Now:
#   (a) the item is found by issue (one `projectItems` lookup), never by paging
#       the whole board
#   (b) the owner and repo come from config, so `gh repo view` is not called
#   (c) the project id, the status field's ids and each issue's item id are
#       cached per run, so the 2nd and 3rd move are one `item-edit`
#   (d) a stale cache (an option replaced since) costs one retry, not a lost move
#   (e) a cache for another owner/project, an old-format one, or an expired one
#       is never used
# Every test runs on stubs under make_sandbox: no GitHub write.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

STATUS="$TALOS_ROOT/scripts/pipeline-status.sh"
CACHE_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/talos"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "board": {"enabled": true, "project_number": 7, "owner": "acme"}}\n' > talos.pipeline.json

calls() { grep -c "$1" "$GH_LOG" || true; }
# graphql -- every gh call that is not the REST client's (`gh api -i`, which the "In progress" claim uses).
graphql() { grep -vc '^api -i ' "$GH_LOG" || true; }
sentinel() { printf '%s/board-validated-acme-7-%s' "$CACHE_DIR" "$1"; }

# ── (a)(b)(c) three moves of one issue in one run ─────────────────────────────
RUN="bc-run-$$"; rm -f "$(sentinel "$RUN")"; : > "$GH_LOG"
out1="$(PIPELINE_RUN_ID="$RUN" bash "$STATUS" 42 "In progress" 2>&1)"; rc1=$?
assert_eq "0" "$rc1" "move 1 exits 0"
assert_contains "$out1" "#42 → In progress" "move 1 reports the move"
assert_eq "1" "$(calls '^project list')" "move 1: one project lookup"
assert_eq "1" "$(calls '^project field-list')" "move 1: one field-list"
assert_eq "1" "$(calls '^api graphql .*projectItems')" "move 1: the item is found by issue, in one call"
assert_eq "0" "$(calls '^project item-list')" "move 1: the board is never paged through"
assert_eq "0" "$(calls '^repo view')" "move 1: owner and repo come from config, not gh repo view"
assert_eq "1" "$(calls '^project item-edit')" "move 1: one item-edit"
assert_eq "4" "$(graphql)" "move 1: four GraphQL calls in all"

: > "$GH_LOG"
out2="$(PIPELINE_RUN_ID="$RUN" bash "$STATUS" 42 "In review" 2>&1)"
out3="$(PIPELINE_RUN_ID="$RUN" bash "$STATUS" 42 "Done" 2>&1)"
assert_contains "$out2" "#42 → In review" "move 2 reports the move"
assert_contains "$out3" "#42 → Done" "move 3 reports the move"
assert_eq "2" "$(graphql)" "moves 2 and 3: one call each (the item-edit)"
assert_eq "2" "$(calls '^project item-edit --id ITEM_42 --project-id PROJ_ID_7 --field-id FIELD_ID_S')" "moves 2 and 3: edit the cached item with the cached ids"
assert_contains "$(cat "$GH_LOG")" "--single-select-option-id OPT_DONE" "move 3: the option is the one for its column"

# ── an issue that is on no board is added once, then cached ───────────────────
RUN="bc-add-$$"; rm -f "$(sentinel "$RUN")"; : > "$GH_LOG"
PIPELINE_RUN_ID="$RUN" bash "$STATUS" 99 "In progress" >/dev/null 2>&1
assert_eq "1" "$(calls '^project item-add 7 --owner acme --url https://github.com/acme/widget/issues/99')" "unknown issue: item-add runs"
: > "$GH_LOG"
PIPELINE_RUN_ID="$RUN" bash "$STATUS" 99 "Done" >/dev/null 2>&1
assert_eq "0" "$(calls '^project item-add')" "unknown issue: the second move does not add it again"
assert_eq "0" "$(calls 'projectItems')" "unknown issue: the second move does not look it up again"
assert_contains "$(cat "$GH_LOG")" "project item-edit --id ITEM_NEW" "unknown issue: the second move edits the item the add returned"

# ── the lookup takes the item of THIS project only ────────────────────────────
RUN="bc-proj-$$"; rm -f "$(sentinel "$RUN")"; : > "$GH_LOG"
STUB_BOARD_ITEMS_JSON='[{"id":"ITEM_OTHER","project":{"id":"PROJ_ID_OTHER"}},{"id":"ITEM_MINE","project":{"id":"PROJ_ID_7"}}]' \
  PIPELINE_RUN_ID="$RUN" bash "$STATUS" 50 "In progress" >/dev/null 2>&1
assert_contains "$(cat "$GH_LOG")" "project item-edit --id ITEM_MINE" "lookup: the item on this project is edited"
assert_not_contains "$(cat "$GH_LOG")" "ITEM_OTHER" "lookup: an item on another project is never edited"

# ── a lookup that fails reads as "not on the board": item-add is idempotent ───
RUN="bc-lookupfail-$$"; rm -f "$(sentinel "$RUN")"; : > "$GH_LOG"
out="$(STUB_BOARD_LOOKUP_FAIL=1 PIPELINE_RUN_ID="$RUN" bash "$STATUS" 42 "In progress" 2>&1)"
assert_eq "1" "$(calls '^project item-add')" "lookup failure: falls back to item-add, which returns the existing item"
assert_contains "$out" "#42 → In progress" "lookup failure: the move still lands"

# ── (d) a stale cache: one retry with fresh ids ───────────────────────────────
RUN="bc-stale-$$"; rm -f "$(sentinel "$RUN")"
PIPELINE_RUN_ID="$RUN" bash "$STATUS" 42 "In progress" >/dev/null 2>&1
python3 - "$(sentinel "$RUN")" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for f in d["fields"]:
    for o in f.get("options", []):
        if o["name"] == "Done":
            o["id"] = "OPT_STALE"
open(p, "w").write(json.dumps(d))
PY
: > "$GH_LOG"
out="$(STUB_ITEM_EDIT_FAIL_ID=OPT_STALE PIPELINE_RUN_ID="$RUN" bash "$STATUS" 42 "Done" 2>&1)"; rc=$?
assert_eq "0" "$rc" "stale cache: exits 0"
assert_contains "$out" "#42 → Done" "stale cache: the move lands on the retry"
assert_not_contains "$out" "talos:board-unverified" "stale cache: no unverified marker for a retried move"
assert_eq "2" "$(calls '^project item-edit')" "stale cache: the failed edit and exactly one retry"
assert_eq "1" "$(calls '^project field-list')" "stale cache: the retry re-reads the fields"
assert_contains "$(cat "$GH_LOG")" "--single-select-option-id OPT_DONE" "stale cache: the retry carries the fresh option id"
assert_contains "$(cat "$(sentinel "$RUN")")" "OPT_DONE" "stale cache: the cache was rewritten with the fresh ids"

# A persistent failure is not retried forever: it is the old fail-loud path.
RUN="bc-stale2-$$"; rm -f "$(sentinel "$RUN")"; : > "$GH_LOG"
out="$(STUB_ITEM_EDIT_FAIL=1 PIPELINE_RUN_ID="$RUN" bash "$STATUS" 42 "Done" 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "persistent failure: exits 0 (Rule 11)"
assert_contains "$out" "talos:board-unverified project=7" "persistent failure: reports unverified"
assert_eq "1" "$(calls '^project item-edit')" "persistent failure on fresh ids: no retry"

# ── (e) a cache that is not for this owner / project / age is never used ──────
plant() {  # plant <run> <json>
  mkdir -p "$CACHE_DIR"
  (umask 177 && printf '%s' "$2" > "$(sentinel "$1")")
}
FIELDS='[{"name":"Status","id":"FOREIGN_FIELD","options":[{"name":"In progress","id":"FOREIGN_OPT"}]}]'
RUN="bc-foreign-$$"
plant "$RUN" "{\"owner\":\"other\",\"number\":7,\"project_id\":\"FOREIGN_PROJ\",\"fields\":$FIELDS}"
: > "$GH_LOG"
PIPELINE_RUN_ID="$RUN" bash "$STATUS" 42 "In progress" >/dev/null 2>&1
assert_not_contains "$(cat "$GH_LOG")" "FOREIGN" "cache of another owner: never used"
assert_eq "1" "$(calls '^project field-list')" "cache of another owner: fresh field-list"
assert_contains "$(cat "$(sentinel "$RUN")")" '"owner": "acme"' "cache of another owner: rewritten for this owner"

RUN="bc-oldfmt-$$"
plant "$RUN" "{\"project_id\":\"PROJ_ID_7\",\"fields\":$FIELDS}"
: > "$GH_LOG"
PIPELINE_RUN_ID="$RUN" bash "$STATUS" 42 "In progress" >/dev/null 2>&1
assert_not_contains "$(cat "$GH_LOG")" "FOREIGN" "old-format cache (no owner/number): never used"
assert_eq "1" "$(calls '^project field-list')" "old-format cache: fresh field-list"

RUN="bc-aged-$$"; rm -f "$(sentinel "$RUN")"
PIPELINE_RUN_ID="$RUN" bash "$STATUS" 42 "In progress" >/dev/null 2>&1
touch -t 202001010000 "$(sentinel "$RUN")"
: > "$GH_LOG"
PIPELINE_RUN_ID="$RUN" bash "$STATUS" 42 "In review" >/dev/null 2>&1
assert_eq "1" "$(calls '^project field-list')" "expired cache: fresh field-list"

# Dry run reads but never writes the cache.
RUN="bc-dry-$$"; rm -f "$(sentinel "$RUN")"
out="$(PIPELINE_RUN_ID="$RUN" bash "$STATUS" --dry-run 42 "In progress" 2>&1)"
assert_contains "$out" "[dry-run] gh project item-edit --id ITEM_42" "dry run: shows the edit it would make"
assert_file_absent "$(sentinel "$RUN")" "dry run: writes no cache"

rm -f "$CACHE_DIR"/board-validated-acme-7-bc-* 2>/dev/null
finish
