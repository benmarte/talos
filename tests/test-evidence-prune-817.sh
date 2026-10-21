#!/usr/bin/env bash
# test-evidence-prune-817.sh -- `pipeline-vcs.sh evidence-prune [--merged]
# [--older-than <days>] [--list]` and `talos.sh evidence prune` remove the
# pr-<n>/ folders of finished PRs from the `talos-evidence` branch in ONE commit on
# GitHub, Azure DevOps and GitLab (#817). Offline: the gh, curl, az and glab stubs
# over tests/stubs/evprune.py, a fake evidence branch with its PRs and commit dates.
#   AC1  github: merged and closed folders go in one tree, one commit, one ref update
#   AC2  azure: one push with a delete change per file of those folders
#   AC3  gitlab: one commits call with a delete action per file of those folders
#   AC4  --older-than selects by the newest evidence commit; an open PR stays
#   AC5  `talos.sh evidence prune --merged --dry-run` lists would-prune, no write
#   AC6  no talos-evidence branch: a message, exit 0, no write
#   AC7  an empty selection: a message, exit 0, no write
#   AC8  a refused write: exit 1, the provider, the status and its message on stderr
#   AC9  a PR whose state cannot be read keeps its folder; the others still go
#   AC10 no selector, a bad --older-than, an unknown flag: exit 2, no call;
#        `talos.sh evidence` with another subcommand: stop reason=usage, exit 2
#   AC11 `talos.sh help` lists `evidence prune` with its three flags
# (AC12 is documentation wording and AC13 the existing parity suite: prose.)
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
TALOS="$TALOS_ROOT/scripts/talos.sh"
export TALOS_RETRY_SLEEP_SCALE=0
git config user.email "test@talos.invalid"
git config user.name "talos-test"

export STUB_EVPRUNE_WORLD="$SANDBOX/world.json"
export STUB_EVPRUNE_LOG="$SANDBOX/evprune.log"
export STUB_CURRENT_USER="bot"
HEAD40="$(printf 'c%.0s' $(seq 1 40))"
OLD="$(python3 -I -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(days=60)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
NEW="$(python3 -I -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(days=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

# world <branch true|false> <prs json> <dates json> -- the evidence branch: pr-1 and
# pr-2 hold two files each, pr-3 one, pr-4 and pr-9 one each; README.md and
# notes/x.txt are not evidence folders.
world() {
  python3 -I - "$@" <<'TALOS_PY_ep817Wd3Kq'
import json, os, sys
branch, prs, dates = sys.argv[1:4]
files = ["pr-1/01234567/a.png", "pr-1/01234567/b.webm", "pr-2/89abcdef/c.png", "pr-2/89abcdef/d.png",
         "pr-3/01234567/e.png", "pr-4/01234567/f.png", "pr-9/01234567/g.png", "README.md", "notes/x.txt"]
json.dump({"branch": branch == "true", "files": files, "prs": json.loads(prs), "dates": json.loads(dates)},
          open(os.environ["STUB_EVPRUNE_WORLD"], "w"))
TALOS_PY_ep817Wd3Kq
  : > "$STUB_EVPRUNE_LOG"
}
W3_PRS='{"1": "merged", "2": "closed", "3": "open"}'
w3() { world true "$W3_PRS" "{\"1\": \"$OLD\", \"2\": \"$NEW\", \"3\": \"$OLD\"}"; }

# count_log <ERE> -- lines of the evidence log that match (0 when none).
count_log() { local _n; _n="$(grep -cE -- "$1" "$STUB_EVPRUNE_LOG" || true)"; printf '%s' "${_n:-0}"; }

# deleted -- the paths the writes delete, sorted, one per line.
deleted() {
  python3 -I - "$STUB_EVPRUNE_LOG" <<'TALOS_PY_ep817Dl8Zt'
import json, sys
out = []
for line in open(sys.argv[1]):
    if not line.startswith("WRITE\t"):
        continue
    kind, body = line.rstrip("\n").split("\t", 2)[1:]
    d = json.loads(body)
    if kind == "tree":
        out += [e["path"] for e in d["tree"] if e.get("sha") is None]
    elif kind == "push":
        out += [c["item"]["path"].lstrip("/") for c in d["commits"][0]["changes"] if c["changeType"] == "delete"]
    elif kind == "commit" and "actions" in d:
        out += [a["file_path"] for a in d["actions"] if a["action"] == "delete"]
print("\n".join(sorted(out)))
TALOS_PY_ep817Dl8Zt
}
# other_changes -- 0 when every change of the push or commit is a delete (azure, gitlab).
other_changes() {
  python3 -I - "$STUB_EVPRUNE_LOG" <<'TALOS_PY_ep817Ot5Hn'
import json, sys
n = 0
for line in open(sys.argv[1]):
    if line.startswith("WRITE\tpush\t"):
        n += sum(1 for c in json.loads(line.split("\t", 2)[2])["commits"][0]["changes"] if c["changeType"] != "delete")
    elif line.startswith("WRITE\tcommit\t") and "actions" in line:
        n += sum(1 for a in json.loads(line.split("\t", 2)[2])["actions"] if a["action"] != "delete")
print(n)
TALOS_PY_ep817Ot5Hn
}
PRUNED_12=$'pr-1/01234567/a.png\npr-1/01234567/b.webm\npr-2/89abcdef/c.png\npr-2/89abcdef/d.png'
PRUNED_1=$'pr-1/01234567/a.png\npr-1/01234567/b.webm'

# provider <github|github-api|azure|gitlab> -- point the sandbox at that provider.
provider() {
  case "$1" in
    github) github_leg gh; git remote set-url origin git@github.com:acme/widget.git ;;
    github-api) github_leg curl; export STUB_GH_FIXTURES=1; git remote set-url origin git@github.com:acme/widget.git ;;
    azure)
      cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
EOF
      ;;
    gitlab)
      git remote set-url origin git@gitlab.com:acme/widget.git
      cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}
EOF
      ;;
  esac
}
# prune <args...> -- evidence-prune on the configured provider; sets RC, OUT and ERR.
prune() { OUT="$(bash "$VCS" evidence-prune "$@" 2>"$SANDBOX/err")"; RC=$?; ERR="$(cat "$SANDBOX/err")"; }
# tprune <args...> -- the same through talos.sh evidence prune.
tprune() { OUT="$(bash "$TALOS" evidence prune "$@" 2>"$SANDBOX/err")"; RC=$?; ERR="$(cat "$SANDBOX/err")"; }

# ── AC1: github, merged and closed in one tree, one commit, one ref update ───
for P in github github-api; do
  provider "$P"
  w3
  prune --merged
  assert_eq "0" "$RC" "AC1 $P: evidence-prune --merged exits 0"
  assert_eq "1" "$(count_log '^WRITE	tree	')" "AC1 $P: exactly one tree"
  assert_eq "1" "$(count_log '^WRITE	commit	')" "AC1 $P: exactly one commit"
  assert_eq "1" "$(count_log '^WRITE	ref	')" "AC1 $P: exactly one ref update"
  assert_eq "3" "$(count_log '^WRITE	')" "AC1 $P: no write beyond those three"
  assert_eq "$PRUNED_12" "$(deleted)" "AC1 $P: the tree deletes every file of pr-1 and pr-2 and nothing else"
  assert_not_contains "$(grep '^WRITE	ref	' "$STUB_EVPRUNE_LOG")" 'force' "AC1 $P: the ref update is not forced"
  assert_eq "0" "$(count_log 'pr-3/')" "AC1 $P: nothing under pr-3 is written"
  assert_contains "$OUT" "pruned pr=1 reason=merged" "AC1 $P: pr-1 is reported pruned as merged"
  assert_contains "$OUT" "pruned pr=2 reason=closed" "AC1 $P: pr-2 is reported pruned as closed"
  assert_contains "$OUT" "pruned folders=2 files=4" "AC1 $P: the summary line counts folders and files"
done

# ── AC2: azure, one push ─────────────────────────────────────────────────────
provider azure
w3
prune --merged
assert_eq "0" "$RC" "AC2 azure: evidence-prune --merged exits 0"
assert_eq "1" "$(count_log '^WRITE	')" "AC2 azure: exactly one write"
assert_eq "1" "$(count_log '^WRITE	push	')" "AC2 azure: it is one pushes POST"
assert_eq "$PRUNED_12" "$(deleted)" "AC2 azure: a delete change for every file of pr-1 and pr-2 only"
assert_eq "0" "$(other_changes)" "AC2 azure: every change is a delete"
assert_contains "$(grep '^WRITE	push	' "$STUB_EVPRUNE_LOG")" "\"oldObjectId\": \"$HEAD40\"" "AC2 azure: the push is based on the head it read"
assert_contains "$OUT" "pruned folders=2 files=4" "AC2 azure: the summary line counts folders and files"

# ── AC3: gitlab, one commit ──────────────────────────────────────────────────
provider gitlab
w3
prune --merged
assert_eq "0" "$RC" "AC3 gitlab: evidence-prune --merged exits 0"
assert_eq "1" "$(count_log '^WRITE	')" "AC3 gitlab: exactly one write"
assert_eq "1" "$(count_log '^WRITE	commit	')" "AC3 gitlab: it is one repository/commits POST"
assert_eq "$PRUNED_12" "$(deleted)" "AC3 gitlab: a delete action for every file of pr-1 and pr-2 only"
assert_eq "0" "$(other_changes)" "AC3 gitlab: every action is a delete"
assert_contains "$(grep '^WRITE	commit	' "$STUB_EVPRUNE_LOG")" '"branch": "talos-evidence"' "AC3 gitlab: the commit is on talos-evidence"
assert_contains "$OUT" "pruned folders=2 files=4" "AC3 gitlab: the summary line counts folders and files"

# ── AC4: --older-than by the newest evidence commit ──────────────────────────
for P in github azure gitlab; do
  provider "$P"
  w3
  prune --older-than 30
  assert_eq "0" "$RC" "AC4 $P: --older-than 30 exits 0"
  assert_eq "$PRUNED_1" "$(deleted)" "AC4 $P: only pr-1 (merged, 60 days) goes: pr-2 is 5 days old, pr-3 is open"
  assert_contains "$OUT" "pruned pr=1 reason=older" "AC4 $P: the reason is older"
  assert_not_contains "$OUT" "pr=3" "AC4 $P: the old folder of an open PR is not touched"
done

# ── AC5: talos.sh evidence prune --merged --dry-run ──────────────────────────
for P in github azure gitlab; do
  provider "$P"
  w3
  tprune --merged --dry-run
  assert_eq "0" "$RC" "AC5 $P: talos.sh evidence prune --merged --dry-run exits 0"
  assert_eq $'would-prune pr=1 reason=merged\nwould-prune pr=2 reason=closed' "$OUT" "AC5 $P: one would-prune line per selected folder"
  assert_eq "0" "$(count_log '^WRITE	')" "AC5 $P: no write call"
done

# ── AC6: no talos-evidence branch ────────────────────────────────────────────
for P in github azure gitlab; do
  provider "$P"
  world false "$W3_PRS" '{}'
  prune --merged
  assert_eq "0" "$RC" "AC6 $P: a missing branch exits 0"
  assert_eq "evidence-prune: no talos-evidence branch" "$OUT" "AC6 $P: it says so"
  assert_eq "0" "$(count_log '^WRITE	')" "AC6 $P: no write"
done

# ── AC7: an empty selection ──────────────────────────────────────────────────
for P in github azure gitlab; do
  provider "$P"
  world true '{"1": "open", "3": "open"}' "{\"1\": \"$OLD\", \"3\": \"$OLD\"}"
  prune --merged
  assert_eq "0" "$RC" "AC7 $P: only open PRs exits 0"
  assert_eq "evidence-prune: nothing to prune" "$OUT" "AC7 $P: only open PRs prints nothing to prune"
  assert_eq "0" "$(count_log '^WRITE	')" "AC7 $P: only open PRs makes no write"
  w3
  prune --older-than 90
  assert_eq "0" "$RC" "AC7 $P: nothing old enough exits 0"
  assert_eq "evidence-prune: nothing to prune" "$OUT" "AC7 $P: nothing old enough prints nothing to prune"
  assert_eq "0" "$(count_log '^WRITE	')" "AC7 $P: nothing old enough makes no write"
done

# ── AC8: a refused write ─────────────────────────────────────────────────────
provider github; w3
STUB_EVPRUNE_REFUSE="422:Update is not a fast forward" prune --merged
assert_eq "1" "$RC" "AC8 github: a refused ref update exits 1"
assert_contains "$ERR" "evidence-prune: github refused (422): Update is not a fast forward" "AC8 github: stderr names the provider, the status and the message"
provider azure; w3
STUB_EVPRUNE_REFUSE="400:TF401019: the push was refused" prune --merged
assert_eq "1" "$RC" "AC8 azure: a refused push exits 1"
assert_contains "$ERR" "evidence-prune: azure refused (400): TF401019: the push was refused" "AC8 azure: stderr names the provider, the status and the message"
provider gitlab; w3
STUB_EVPRUNE_REFUSE="400:A file with this name doesn't exist" prune --merged
assert_eq "1" "$RC" "AC8 gitlab: a refused commit exits 1"
assert_contains "$ERR" "evidence-prune: gitlab refused (400): A file with this name doesn't exist" "AC8 gitlab: stderr names the provider, the status and the message"

# ── AC9: a PR whose state cannot be read keeps its folder ────────────────────
for P in github azure gitlab; do
  provider "$P"
  world true '{"1": "merged", "2": "closed", "3": "open", "4": "error"}' "{\"1\": \"$OLD\", \"2\": \"$OLD\", \"3\": \"$OLD\"}"
  prune --merged
  assert_eq "0" "$RC" "AC9 $P: an unreadable PR does not fail the prune"
  assert_eq "$PRUNED_12" "$(deleted)" "AC9 $P: pr-4 (state read fails) and pr-9 (no such PR) stay; pr-1 and pr-2 still go"
done

# ── AC10: usage, before any call ─────────────────────────────────────────────
provider github; w3
for A in "" "--older-than 0" "--older-than abc" "--older-than" "--merged --frob" "--older-than 30 stray"; do
  # shellcheck disable=SC2086
  prune $A
  assert_eq "2" "$RC" "AC10 evidence-prune ${A:-<no flags>} exits 2"
  assert_contains "$ERR" "Usage: evidence-prune" "AC10 evidence-prune ${A:-<no flags>} prints the usage"
  assert_eq "" "$(cat "$STUB_EVPRUNE_LOG")" "AC10 evidence-prune ${A:-<no flags>} makes no call"
done
for A in "" "bogus" "prune" "prune --frob" "prune --older-than 0"; do
  # shellcheck disable=SC2086
  OUT="$(bash "$TALOS" evidence $A 2>/dev/null)"; RC=$?
  assert_eq "2" "$RC" "AC10 talos.sh evidence ${A:-<nothing>} exits 2"
done
OUT="$(bash "$TALOS" evidence bogus 2>/dev/null)"
assert_eq "stop reason=usage" "$OUT" "AC10 talos.sh evidence bogus stops reason=usage"
assert_eq "" "$(cat "$STUB_EVPRUNE_LOG")" "AC10 talos.sh evidence makes no call on a usage error"

# ── AC11: help ───────────────────────────────────────────────────────────────
H="$(bash "$TALOS" help 2>/dev/null)"
assert_contains "$H" "evidence prune" "AC11 talos.sh help lists evidence prune"
assert_contains "$H" "--merged" "AC11 help names --merged"
assert_contains "$H" "--older-than" "AC11 help names --older-than"
assert_contains "$H" "--dry-run" "AC11 help names --dry-run"

finish
