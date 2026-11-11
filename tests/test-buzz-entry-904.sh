#!/usr/bin/env bash
# test-buzz-entry-904.sh -- scripts/talos-buzz.sh, the narrow redraw/refresh/forget/open
# entry point, and `talos.sh map --forget <slug>` (#904). Tests are named by the spec's id.
#   AC1 a slug, an entry or a verb the script refuses: error, exit 2, talos.sh never called
#   AC2 redraw: cwd = root, the one argument `map`, PIPELINE_CONFIG as the entry says
#   AC3 refresh failures: auth, state-unavailable, network, failed; the record; the detail
#   AC4 a successful refresh: done, warn=merged-unavailable, the record
#   AC5 one refresh per project: busy, the lock, a dead or old lock taken over
#   AC6 map --forget removes one key and no file; buzz forget runs it
#   AC7 a render of another repository during map --forget keeps its entry (20 rounds)
#   AC8 open: the stub opener gets the rebuilt path; a bad file name exits 2
#   AC9 every stdout line starts `talos-buzz `, and the stub's stdout is never echoed
# AC10 is prose (the doc wording); AC11 is covered by test-map-refresh-889.sh and
# test-map-registry-903.sh.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

TALOS="$TALOS_ROOT/scripts/talos.sh"
MAPPY="$TALOS_ROOT/scripts/talos-map.py"
unset PIPELINE_CONFIG TALOS_ROLE TALOS_RUN_STARTED TALOS_RUN_PID

FX="$(cd "$SANDBOX" && pwd -P)/fx"
S="$FX/scripts"; BIN="$FX/bin"; CALLS="$FX/calls"; OPENED="$FX/opened"
export TALOS_HOME="$FX/home"
NOGIT="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-buzz904.XXXXXX")" || exit 1
trap '_is_trap_owner && { rm -rf "${NOGIT:?}"; _sandbox_cleanup; }' EXIT
mkdir -p "$S" "$BIN" "$TALOS_HOME/maps"
cp "$TALOS_ROOT/scripts/talos-buzz.sh" "$S/talos-buzz.sh" 2>/dev/null || true

# The stub talos.sh beside the copy of talos-buzz.sh: it logs how it was called
# (cwd | args | PIPELINE_CONFIG | TALOS_HOME) and behaves as the `mode` file says.
cat > "$S/talos.sh" <<'TALOS_STUBb7Qx2LmPz4Wd'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$PWD" "$*" "${PIPELINE_CONFIG-<unset>}" "${TALOS_HOME-<unset>}" >> "$(dirname "$0")/../calls"
case "$(cat "$(dirname "$0")/mode")" in
  ok)     echo "secret stub stdout"; echo "map=/maps/stub.html"; echo "index=/maps/index.html" ;;
  auth)   echo "gh: To authenticate, please run: gh auth login" >&2; exit 1 ;;
  az)     echo "ERROR: Please run 'az login' to setup account." >&2; exit 1 ;;
  h401)   echo "gh: Bad credentials (HTTP 401)" >&2; exit 1 ;;
  h403)   echo "gh: Resource not accessible (HTTP 403)" >&2; exit 1 ;;
  state)  echo "stop reason=state-unavailable"; exit 1 ;;
  net)    echo "curl: (28) Connection timed out after 30001 milliseconds" >&2; exit 1 ;;
  dns)    echo "dial tcp: lookup api.github.com: no such host (DNS failure)" >&2; exit 1 ;;
  other)  printf 'first line\nboom \001\033[31mred\033[0m %0300d\n\n' 0 >&2; exit 1 ;;
  warn)   echo "map=/maps/stub.html"; echo "warn reason=merged-unavailable" ;;
  slow)   sleep 3; echo "map=/maps/stub.html" ;;
  nomap)  echo "index=/maps/index.html" ;;
esac
TALOS_STUBb7Qx2LmPz4Wd
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\necho "opener stdout"\n' "$OPENED" > "$BIN/open"
cp "$BIN/open" "$BIN/xdg-open"
printf '#!/usr/bin/env bash\necho "gh must not run" >> "%s/gh-called"\nexit 1\n' "$FX" > "$BIN/gh"
chmod +x "$S/talos.sh" "$BIN/open" "$BIN/xdg-open" "$BIN/gh"
export PATH="$BIN:$PATH"
: > "$CALLS"

mkdir -p "$FX/r1/.git" "$FX/r2/.git" "$FX/nogit-root" "$FX/space dir/.git"
: > "$FX/cfg.json"
put_reg() {  # <python expression building the registry dict>
  python3 -I -c '
import json, sys
fx = sys.argv[1]
reg = eval(sys.argv[2])
json.dump(reg, open(fx + "/home/maps/index.json", "w"))' "$FX" "$1"
}
GOOD='{"acme/widget": {"file": "acme-widget.html", "root": fx + "/r1", "config": fx + "/cfg.json"}, "acme/bare": {"file": "acme-bare.html", "root": fx + "/r2"}}'
put_reg "$GOOD"
mode() { printf '%s' "$1" > "$S/mode"; }
buzz() {  # <verb> <slug>: stdout in $OUT, status in $RC
  OUT="$(bash "$S/talos-buzz.sh" "$@" 2> "$FX/buzz.err")"; RC=$?
}
ncalls() { wc -l < "$CALLS" | tr -d ' '; }
rec() {  # <file> <python expression over d, the refresh record>
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps(eval(sys.argv[2]), sort_keys=True, ensure_ascii=False))' "$TALOS_HOME/maps/.refresh/$1.json" "$2" 2>&1
}
all_buzz() {  # every non-empty line of $1 starts `talos-buzz `
  printf '%s\n' "$1" | awk 'NF && $0 !~ /^talos-buzz / { bad++ } END { print bad + 0 }'
}
no_calls() { assert_eq "0" "$(ncalls)" "$1 talos.sh was not called"; }

# ── AC1: what is refused ─────────────────────────────────────────────────────
mode ok
LONGKEY="$(python3 -I -c 'print("a" * 201)')"
put_reg '{
  "acme/widget": {"file": "w.html", "root": fx + "/r1"},
  "rel/root": {"file": "a.html", "root": "r1"},
  "gone/root": {"file": "b.html", "root": fx + "/missing"},
  "nogit/root": {"file": "c.html", "root": fx + "/nogit-root"},
  "rel/config": {"file": "d.html", "root": fx + "/r1", "config": "cfg.json"},
  "gone/config": {"file": "e.html", "root": fx + "/r1", "config": fx + "/missing.json"},
  "dir/config": {"file": "f.html", "root": fx + "/r1", "config": fx + "/r2"},
  "a/b\tc": {"file": "g.html", "root": fx + "/r1"},
  "/".join(["acme", "..", "widget"]): {"file": "h.html", "root": fx + "/r1"},
  "a" * 201: {"file": "i.html", "root": fx + "/r1"}}'
: > "$CALLS"
for slug in no/such "acme/../widget" "acme/widget/../x" "$LONGKEY" "$(printf 'a/b\tc')" rel/root gone/root nogit/root rel/config gone/config dir/config; do
  for verb in redraw refresh; do
    buzz "$verb" "$slug"
    assert_eq "2" "$RC" "AC1 $verb ${slug:0:20} exits 2"
    assert_contains "$OUT" "talos-buzz error=" "AC1 $verb ${slug:0:20} prints error="
  done
done
buzz frobnicate acme/widget
assert_eq "2" "$RC" "AC1 an unknown verb exits 2"
assert_contains "$OUT" "talos-buzz error=usage" "AC1 an unknown verb is usage"
buzz run acme/widget
assert_eq "2" "$RC" "AC1 the verb run is refused"
buzz redraw
assert_eq "2" "$RC" "AC1 no slug exits 2"
OUT="$(bash "$S/talos-buzz.sh" redraw acme/widget extra 2>&1)"; RC=$?
assert_eq "2" "$RC" "AC1 an extra argument exits 2"
no_calls "AC1"
assert_file_absent "$TALOS_HOME/maps/.refresh" "AC1 a refused refresh made no .refresh directory"

# ── AC2: redraw ──────────────────────────────────────────────────────────────
put_reg "$GOOD"
: > "$CALLS"
PIPELINE_CONFIG=/ambient/other.json buzz redraw acme/widget
assert_eq "0" "$RC" "AC2 redraw exits 0"
assert_eq "$FX/r1|map|$FX/cfg.json|$TALOS_HOME" "$(cat "$CALLS")" "AC2 the stub saw cwd = root, the one argument map, the entry's config and TALOS_HOME"
assert_eq "talos-buzz phase=render
talos-buzz done map=/maps/stub.html" "$OUT" "AC2 redraw prints phase=render, then done map= (the stub's map= line)"
: > "$CALLS"
PIPELINE_CONFIG=/ambient/other.json buzz redraw acme/bare
assert_eq "$FX/r2|map|<unset>|$TALOS_HOME" "$(cat "$CALLS")" "AC2 an entry with no config leaves PIPELINE_CONFIG unset, whatever the caller had"
mode nomap
buzz redraw acme/bare
assert_eq "1" "$RC" "AC2 redraw whose talos.sh printed no map= is a failure"
assert_contains "$OUT" "talos-buzz failed reason=failed" "AC2 redraw without a map path says failed"

# ── AC3: refresh failures ────────────────────────────────────────────────────
refresh_fails() {  # <mode> <reason> <label>
  mode "$1"; : > "$CALLS"
  buzz refresh acme/widget
  assert_eq "1" "$RC" "AC3 $3 exits 1"
  assert_eq "talos-buzz phase=reading" "$(printf '%s\n' "$OUT" | sed -n 1p)" "AC3 $3 prints phase=reading first"
  assert_contains "$OUT" "talos-buzz failed reason=$2 detail=" "AC3 $3 is reason=$2"
  assert_eq "map --refresh" "$(cut -d'|' -f2 "$CALLS")" "AC3 $3: the stub ran map --refresh"
  assert_eq "[false, \"$2\"]" "$(rec acme-widget.html '[d["ok"], d["reason"]]')" "AC3 $3 record: ok false, reason $2"
}
refresh_fails auth auth "gh auth login"
assert_contains "$OUT" "detail=gh: To authenticate, please run: gh auth login" "AC3 the detail is the last stderr line"
refresh_fails az auth "az login"
refresh_fails h401 auth "HTTP 401"
refresh_fails h403 auth "HTTP 403"
refresh_fails state state-unavailable "stop reason=state-unavailable"
refresh_fails net network "a connection timeout"
refresh_fails dns network "a DNS fault"
refresh_fails other failed "any other failure"
DETAIL="$(printf '%s\n' "$OUT" | sed -n 's/^talos-buzz failed reason=failed detail=//p')"
assert_eq "boom" "$(printf '%s' "$DETAIL" | cut -c1-4)" "AC3 the detail is the last non-empty stderr line"
assert_eq "true" "$(rec acme-widget.html 'len(d["detail"]) <= 200 and not any(ord(c) < 32 for c in d["detail"])')" "AC3 the record's detail is at most 200 chars with no control characters"
assert_eq "true" "$([ "${#DETAIL}" -le 200 ] && ! grep -q "$(printf '[\001\033]')" <<< "$DETAIL" && echo true || echo false)" "AC3 the printed detail is at most 200 chars with no control characters"
assert_eq "true" "$(rec acme-widget.html 'bool(__import__("re").fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d["started"])) and bool(__import__("re").fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d["finished"]))')" "AC3 started and finished are ISO times"
assert_file_exists "$TALOS_HOME/maps/.refresh/acme-widget.html.json" "AC3 the record is maps/.refresh/<file>.json"
assert_file_absent "$TALOS_HOME/maps/.refresh/acme-widget.html.lock" "AC3 a failed refresh leaves no lock"

# ── AC4: a successful refresh ────────────────────────────────────────────────
mode ok; : > "$CALLS"
buzz refresh acme/widget
assert_eq "0" "$RC" "AC4 refresh exits 0"
assert_eq "talos-buzz phase=reading
talos-buzz done map=/maps/stub.html" "$OUT" "AC4 refresh prints phase=reading, then done map="
assert_eq "true" "$(rec acme-widget.html 'sorted(d) == ["detail", "finished", "ok", "reason", "started"] and d["ok"] is True')" "AC4 the record has the five keys and ok: true"
mode warn
buzz refresh acme/widget
assert_eq "0" "$RC" "AC4 a merged-unavailable warn still exits 0"
assert_eq "talos-buzz done map=/maps/stub.html warn=merged-unavailable" "$(printf '%s\n' "$OUT" | sed -n 2p)" "AC4 the done line adds warn=merged-unavailable"
assert_eq "true" "$(rec acme-widget.html 'd["ok"] is True')" "AC4 a warned refresh's record is ok"

# ── AC5: one refresh per project ─────────────────────────────────────────────
mode slow; : > "$CALLS"
rm -f "$FX/o1" "$FX/o2"
bash "$S/talos-buzz.sh" refresh acme/widget > "$FX/o1" 2>&1 & P1=$!
bash "$S/talos-buzz.sh" refresh acme/widget > "$FX/o2" 2>&1 & P2=$!
wait_until 5 test -e "$TALOS_HOME/maps/.refresh/acme-widget.html.lock"
LOCKTXT="$(cat "$TALOS_HOME/maps/.refresh/acme-widget.html.lock" 2>/dev/null)"
wait "$P1"; RC1=$?; wait "$P2"; RC2=$?
assert_eq "0" "$((RC1 + RC2))" "AC5 busy exits 0, so both calls exit 0"
assert_eq "1" "$(cat "$FX/o1" "$FX/o2" | grep -c '^talos-buzz busy since=[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9:]*Z$')" "AC5 exactly one of two simultaneous refreshes prints busy since=<iso>"
assert_eq "1" "$(cat "$FX/o1" "$FX/o2" | grep -c '^talos-buzz done map=')" "AC5 exactly one of them ran"
assert_eq "1" "$(ncalls)" "AC5 the stub ran once"
assert_contains "$LOCKTXT" "Z" "AC5 the lock holds a start time"
assert_eq "true" "$(grep -Eq '^[0-9]+ ' <<< "$LOCKTXT" && echo true || echo false)" "AC5 the lock holds a pid"
assert_file_absent "$TALOS_HOME/maps/.refresh/acme-widget.html.lock" "AC5 the lock is gone after the refresh ends"

mode ok
LOCK="$TALOS_HOME/maps/.refresh/acme-widget.html.lock"
sleep 0 & DEAD=$!; wait "$DEAD"
printf '%s %s\n' "$DEAD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK"
: > "$CALLS"; buzz refresh acme/widget
assert_eq "0:1" "$RC:$(ncalls)" "AC5 a lock whose pid is dead is taken over and the refresh runs"
assert_file_absent "$LOCK" "AC5 the taken-over lock is gone after the refresh"
OLD="$(python3 -I -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=11)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
printf '%s %s\n' "$$" "$OLD" > "$LOCK"
: > "$CALLS"; buzz refresh acme/widget
assert_eq "0:1" "$RC:$(ncalls)" "AC5 a live lock older than 10 minutes is taken over"
printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK"
: > "$CALLS"; buzz refresh acme/widget
assert_eq "0:0" "$RC:$(ncalls)" "AC5 a live, fresh lock is busy: exit 0, the stub not run"
assert_contains "$OUT" "talos-buzz busy since=" "AC5 the busy line"
assert_file_exists "$LOCK" "AC5 a busy call leaves the other refresh's lock"
rm -f "$LOCK"

# ── AC6: map --forget ────────────────────────────────────────────────────────
put_reg "$GOOD"
printf 'page' > "$TALOS_HOME/maps/acme-widget.html"; printf 'page' > "$TALOS_HOME/maps/acme-bare.html"
mkdir -p "$TALOS_HOME/maps/.refresh"; printf '{}' > "$TALOS_HOME/maps/.refresh/acme-widget.html.json"
maps_files() {  # every file in maps/ but the registry, its page and its lock (a forget rewrites those)
  (cd "$TALOS_HOME/maps" && find . -type f ! -name 'index.json' ! -name 'index.html' ! -name 'index.json.lock' | sort | tr '\n' ' ')
}
BEFORE="$(maps_files)"
REPO_BEFORE="$(find "$FX/r1" | sort | tr '\n' ' ')"
OUT="$(cd "$NOGIT" && env -i PATH="$PATH" HOME="$NOGIT" TALOS_HOME="$TALOS_HOME" bash "$TALOS" map --forget acme/widget 2> "$FX/forget.err")"; RC=$?
assert_eq "0" "$RC" "AC6 map --forget exits 0 from a directory with no git repo and no config"
assert_contains "$OUT" "forgot=acme/widget" "AC6 map --forget prints forgot=<slug>"
assert_contains "$OUT" "index=$TALOS_HOME/maps/index.html" "AC6 map --forget prints index=<path>"
assert_eq '["acme/bare"]' "$(python3 -I -c 'import json, sys; print(json.dumps(sorted(json.load(open(sys.argv[1])))))' "$TALOS_HOME/maps/index.json")" "AC6 only that key is removed"
assert_eq "$BEFORE" "$(maps_files)" "AC6 no other file in maps/ is deleted"
assert_eq "$REPO_BEFORE" "$(find "$FX/r1" | sort | tr '\n' ' ')" "AC6 nothing in the repository changes"
assert_file_exists "$TALOS_HOME/maps/acme-widget.html" "AC6 the forgotten project's page stays"
assert_file_exists "$TALOS_HOME/maps/index.json.lock" "AC6 the registry lock is maps/index.json.lock"
assert_contains "$(cat "$TALOS_HOME/maps/index.html")" "acme/bare" "AC6 index.html is regenerated with the remaining entry"
assert_not_contains "$(cat "$TALOS_HOME/maps/index.html")" "acme/widget" "AC6 index.html no longer lists the forgotten entry"
OUT="$(cd "$NOGIT" && env -i PATH="$PATH" HOME="$NOGIT" TALOS_HOME="$TALOS_HOME" bash "$TALOS" map --forget acme/widget 2>&1)"; RC=$?
assert_eq "2" "$RC" "AC6 an unknown slug exits 2"
assert_eq "stop reason=usage" "$OUT" "AC6 an unknown slug is usage"
for bad in "" "../etc" "a b"; do
  OUT="$(cd "$NOGIT" && env -i PATH="$PATH" HOME="$NOGIT" TALOS_HOME="$TALOS_HOME" bash "$TALOS" map --forget "$bad" 2>&1)"; RC=$?
  assert_eq "2:stop reason=usage" "$RC:$OUT" "AC6 the slug '$bad' is usage"
done
OUT="$(cd "$NOGIT" && env -i PATH="$PATH" HOME="$NOGIT" TALOS_HOME="$TALOS_HOME" bash "$TALOS" map --forget 2>&1)"; RC=$?
assert_eq "2:stop reason=usage" "$RC:$OUT" "AC6 --forget with no slug is usage"
assert_eq '["acme/bare"]' "$(python3 -I -c 'import json, sys; print(json.dumps(sorted(json.load(open(sys.argv[1])))))' "$TALOS_HOME/maps/index.json")" "AC6 a refused forget changes nothing"

# buzz forget: the stub is called with `map --forget <slug>`, then done forgot=
put_reg "$GOOD"; : > "$CALLS"; mode ok
buzz forget acme/widget
assert_eq "0" "$RC" "AC6 buzz forget exits 0"
assert_eq "$FX/r1|map --forget acme/widget|$FX/cfg.json|$TALOS_HOME" "$(cat "$CALLS")" "AC6 buzz forget runs map --forget <slug> in root"
assert_eq "talos-buzz done forgot=acme/widget" "$OUT" "AC6 buzz forget prints done forgot=<slug>"

# ── AC7: a render of another repository while map --forget runs ──────────────
lost=0; LAST=""
for i in $(seq 1 20); do
  rm -rf "${TALOS_HOME:?}/maps"; mkdir -p "$TALOS_HOME/maps"
  printf '{"gone/repo": {"file": "gone-repo.html", "line": "x", "updated": "2026-01-01T00:00:00Z"}}\n' > "$TALOS_HOME/maps/index.json"
  python3 -I "$MAPPY" --home "$TALOS_HOME" --provider github --repo acme/widget --scripts "$TALOS_ROOT/scripts" \
    --titles "$FX/titles" < /dev/null > /dev/null 2>&1 &
  A=$!
  (cd "$NOGIT" && bash "$TALOS" map --forget gone/repo > /dev/null 2>&1) &
  B=$!
  wait "$A"; wait "$B"
  got="$(python3 -I -c 'import json, sys; print(json.dumps(sorted(json.load(open(sys.argv[1])))))' "$TALOS_HOME/maps/index.json" 2>&1)"
  [ "$got" = '["acme/widget"]' ] || { lost=$((lost + 1)); LAST="$got"; }
done
assert_eq "0" "$lost" "AC7 a render and map --forget at once keep the render's entry and drop the forgotten one, 20 rounds" "$LAST"

# ── AC8: open ────────────────────────────────────────────────────────────────
put_reg "$GOOD"; : > "$OPENED"
buzz open acme/widget
assert_eq "0" "$RC" "AC8 open exits 0"
assert_eq "$TALOS_HOME/maps/acme-widget.html" "$(cat "$OPENED")" "AC8 the opener is called once with the path rebuilt from maps/ and the entry's file"
assert_eq "talos-buzz done opened=$TALOS_HOME/maps/acme-widget.html" "$OUT" "AC8 open prints done opened=<path>"
for badfile in "../x.html" "x.htm" "a b.html" "sub/x.html" ".html" ""; do
  put_reg "{\"acme/widget\": {\"file\": \"$badfile\", \"root\": fx + \"/r1\"}}"
  : > "$OPENED"; : > "$CALLS"
  buzz open acme/widget
  assert_eq "2" "$RC" "AC8 the file '$badfile' exits 2"
  assert_contains "$OUT" "talos-buzz error=" "AC8 the file '$badfile' prints error="
  assert_eq "" "$(cat "$OPENED")" "AC8 the file '$badfile' opens nothing"
done
put_reg '{"acme/widget": {"root": fx + "/r1"}}'
buzz open acme/widget
assert_eq "2" "$RC" "AC8 an entry with no file exits 2"

# ── AC9: every stdout line starts `talos-buzz ` ──────────────────────────────
put_reg "$GOOD"
for m in ok warn auth state net other nomap; do
  mode "$m"
  for verb in redraw refresh forget open; do
    buzz "$verb" acme/widget
    assert_eq "0:1" "$(all_buzz "$OUT"):$([ -n "$OUT" ] && echo 1 || echo 0)" "AC9 $verb with the stub in mode $m: some stdout, and every line starts talos-buzz"
    assert_not_contains "$OUT" "secret stub stdout" "AC9 $verb ($m) does not echo the stub's stdout"
    assert_not_contains "$OUT" "opener stdout" "AC9 $verb ($m) does not echo the opener's stdout"
    put_reg "$GOOD"
  done
done
buzz nope no/such
assert_eq "0" "$(all_buzz "$OUT")" "AC9 an error line starts talos-buzz"
assert_file_absent "$FX/gh-called" "AC9 buzz never calls gh itself"

# ── AC11: map and map --refresh keep their shapes (their own tests are 889's and 903's) ──
export PIPELINE_CONFIG="$FX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
git -C "$SANDBOX" -c user.name=t -c user.email=t@talos.invalid commit -q --allow-empty -m init
export TALOS_HOME="$FX/home11"
OUT="$(cd "$SANDBOX" && bash "$TALOS" map 2> /dev/null)"; RC=$?
assert_eq "0" "$RC" "AC11 a plain map still exits 0"
assert_contains "$OUT" "map=$TALOS_HOME/maps/acme-widget.html" "AC11 a plain map still prints map="
assert_contains "$OUT" "index=$TALOS_HOME/maps/index.html" "AC11 a plain map still prints index="
OUT="$(cd "$SANDBOX" && bash "$TALOS" map --bogus 2>&1)"; RC=$?
assert_eq "2:stop reason=usage" "$RC:$OUT" "AC11 any other map argument is still usage"
OUT="$(cd "$SANDBOX" && bash "$TALOS" map --refresh extra 2>&1)"; RC=$?
assert_eq "2:stop reason=usage" "$RC:$OUT" "AC11 --refresh with an extra argument is still usage"
unset PIPELINE_CONFIG

finish
