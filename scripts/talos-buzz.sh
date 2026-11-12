#!/usr/bin/env bash
# talos-buzz.sh <redraw|refresh|forget|open> <slug>  (#904)
# talos-buzz.sh open-url <slug> <url>                 (#917)
#
# The one narrow entry point of the Buzz plugin. Buzz's host.spawn appends the
# caller's arguments to a declared command, so a plugin that could spawn talos.sh
# itself could pass any verb, `run` included. This script takes five verbs, a
# project slug (and, for open-url, one URL), checks the slug against the registry (<TALOS_HOME>/maps/index.json),
# and runs talos.sh from the checkout the registry records, with the config it
# records. It needs no shell profile: python3 -I, coreutils and pure shell.
#
# Every stdout line starts `talos-buzz `; talos.sh's own stdout is never echoed.
# Exit status: 0 for done and busy, 1 for failed, 2 for usage and error.
# The registry is read here and never written (talos.sh map --forget writes it);
# a refresh writes only maps/.refresh/<file>.lock and <file>.json.
# open-url opens one http(s) link in the system browser: Buzz opens no popups and
# its plugin API has no open-URL call, so every link the plugin shows comes here.
# It runs the opener only for a URL Talos drew for that project (an href of the
# project's map page or a needs[].url of its entry) and writes nothing.
# docs/reference.md documents the lines and the record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || { echo "talos-buzz error=scripts-missing"; exit 2; }

say() { printf 'talos-buzz %s\n' "$*"; }
die() { say "error=$1"; exit 2; }

TMP=""; LOCK=""
cleanup() {
  # The lock is ours only while it still holds our pid: a refresh that overran the
  # 10 minutes may have been taken over.
  if [ -n "$LOCK" ] && [ "$(cut -d' ' -f1 "$LOCK" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK"; fi
  if [ -n "$TMP" ]; then rm -rf "${TMP:?}"; fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT HUP

[ "$#" -ge 2 ] || die usage
VERB="$1"; SLUG="$2"; URL=""
case "$VERB" in
  redraw | refresh | forget | open) [ "$#" -eq 2 ] || die usage ;;
  open-url) [ "$#" -eq 3 ] || die usage; URL="$3" ;;
  *) die usage ;;
esac
command -v python3 > /dev/null 2>&1 || die python-missing

HOME_DIR="${TALOS_HOME:-${HOME:-}/.talos}"
case "$HOME_DIR" in /*) ;; *) HOME_DIR="$PWD/$HOME_DIR" ;; esac

# The slug check: an exact registry key, an entry that points at a checkout, a
# config that is a file, and (refresh and open) a file name that is a plain page.
# Prints `root=`, `config=` and `file=` lines, or `error <reason>` and exits 1.
# Values go in as argv and come out validated: no control characters.
CHECK='
import json, os, re, sys
path, slug, verb = sys.argv[1:4]
def bad(why):
    print("error " + why)
    sys.exit(1)
def ctl(s):
    return any(ord(c) < 32 or ord(c) == 127 for c in s)
if not slug or len(slug.encode("utf-8", "surrogateescape")) > 200 or ctl(slug) or ".." in slug.split("/"):
    bad("bad-slug")
try:
    with open(path) as f:
        reg = json.load(f)
except (OSError, ValueError):
    bad("registry-unreadable")
if not isinstance(reg, dict) or slug not in reg:
    bad("unknown-slug")
e = reg[slug]
if not isinstance(e, dict):
    bad("entry-invalid")
root = e.get("root")
if (not isinstance(root, str) or ctl(root) or not os.path.isabs(root) or not os.path.isdir(root)
        or not os.path.exists(os.path.join(root, ".git"))):
    bad("root-invalid")
cfg = e.get("config")
if cfg is not None and (not isinstance(cfg, str) or ctl(cfg) or not os.path.isabs(cfg) or not os.path.isfile(cfg)):
    bad("config-invalid")
name = e.get("file")
if verb in ("refresh", "open", "open-url") and not (isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9._-]+\.html", name)):
    bad("file-invalid")
print("root=" + root)
print("config=" + (cfg or ""))
print("file=" + (name if isinstance(name, str) else ""))
'
CHK="$(python3 -I -c "$CHECK" "$HOME_DIR/maps/index.json" "$SLUG" "$VERB" 2> /dev/null)" || {
  REASON="${CHK#error }"
  case "$REASON" in '' | *[!a-z-]*) REASON=registry-unreadable ;; esac
  die "$REASON"
}
ROOT="$(sed -n 's/^root=//p' <<< "$CHK")"
CONFIG="$(sed -n 's/^config=//p' <<< "$CHK")"
FILE="$(sed -n 's/^file=//p' <<< "$CHK")"
[ -n "$ROOT" ] || die registry-unreadable

# open-url: the URL is one http(s) string of at most 2048 characters with no
# whitespace or control characters, and it equals an href of the project's map
# page (entities unescaped) or a needs[].url of the registry entry. Argv in, `ok`
# out, or `error <reason>` and exit 1. Nothing is written.
URLCHECK='
import json, re, sys
from html.parser import HTMLParser
reg_path, slug, page, url = sys.argv[1:5]
def bad(why):
    print("error " + why)
    sys.exit(1)
if len(url) > 2048 or not re.fullmatch(r"https?://[^\s\x00-\x1f\x7f-\x9f]+", url, re.A):
    bad("bad-url")
urls = set()
try:
    with open(reg_path) as f:
        need = json.load(f)[slug].get("needs")
    for n in need if isinstance(need, list) else []:
        if isinstance(n, dict) and isinstance(n.get("url"), str):
            urls.add(n["url"])
except (OSError, ValueError, KeyError, AttributeError):
    pass
class Hrefs(HTMLParser):
    def handle_starttag(self, tag, attrs):
        for k, v in attrs:
            if k == "href" and v is not None:
                urls.add(v)
try:
    with open(page, encoding="utf-8", errors="replace") as f:
        Hrefs(convert_charrefs=True).feed(f.read())
except OSError:
    pass
if url not in urls:
    bad("url-not-on-map")
print("ok")
'
if [ "$VERB" = open-url ]; then
  UCHK="$(python3 -I -c "$URLCHECK" "$HOME_DIR/maps/index.json" "$SLUG" "$HOME_DIR/maps/$FILE" "$URL" 2> /dev/null)" || {
    REASON="${UCHK#error }"
    case "$REASON" in bad-url | url-not-on-map) ;; *) REASON=url-not-on-map ;; esac
    die "$REASON"
  }
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/talos-buzz.XXXXXX")" || die tmp-unavailable
[ -n "$TMP" ] && [ -d "$TMP" ] || { TMP=""; die tmp-unavailable; }

# run_talos <talos.sh argument>...: talos.sh in the checkout, with the entry's
# config (or none: an ambient PIPELINE_CONFIG must not leak in) and TALOS_HOME.
# Its stdout and stderr go to $TMP/out and $TMP/err; stdin is closed.
run_talos() {
  (
    cd "$ROOT" || exit 126
    if [ -n "$CONFIG" ]; then export PIPELINE_CONFIG="$CONFIG"; else unset PIPELINE_CONFIG; fi
    export TALOS_HOME="$HOME_DIR"
    exec bash "$SCRIPT_DIR/talos.sh" "$@"
  ) < /dev/null > "$TMP/out" 2> "$TMP/err"
}

# classify: what talos.sh said, from $TMP/out and $TMP/err. Sets REASON, DETAIL,
# MAP and WARN. The detail is the last non-empty stderr line, control characters
# stripped, at most 200 characters. stdout is read for `map=`, `stop reason=` and
# `warn reason=merged-unavailable` only.
CLASSIFY='
import re, sys
out = open(sys.argv[1], errors="replace").read().splitlines()
err = open(sys.argv[2], errors="replace").read()
def clean(s):
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", "", s).strip()
lines = [clean(l) for l in err.splitlines() if clean(l)]
detail = lines[-1][:200] if lines else ""
stop = ""
mapped = ""
warn = "merged-unavailable" if "warn reason=merged-unavailable" in out else ""
for l in out:
    m = re.match(r"stop reason=([a-z][a-z0-9:-]*)$", l)
    if m:
        stop = m.group(1)
    if l.startswith("map="):
        mapped = clean(l[4:])
if re.search(r"gh auth login|az login|http[ /:]*(401|403)\b", err, re.I):
    reason = "auth"
elif stop == "state-unavailable":
    reason = "state-unavailable"
elif re.search(r"connection|timed? ?out|timeout|dns|could not resolve|name resolution|no such host|unreachable|no route", err, re.I):
    reason = "network"
else:
    reason = "failed"
print("reason=" + reason)
print("detail=" + detail)
print("map=" + mapped)
print("warn=" + warn)
'
classify() {
  local _c
  _c="$(python3 -I -c "$CLASSIFY" "$TMP/out" "$TMP/err" 2> /dev/null)" || _c=""
  REASON="$(sed -n 's/^reason=//p' <<< "$_c")"; [ -n "$REASON" ] || REASON=failed
  DETAIL="$(sed -n 's/^detail=//p' <<< "$_c")"
  MAP="$(sed -n 's/^map=//p' <<< "$_c")"
  WARN="$(sed -n 's/^warn=//p' <<< "$_c")"
}

# The refresh record: one finished refresh, a file of its own so that the registry
# is never written from here. Best effort: a record that cannot be written is not
# a failed refresh.
RECORD='
import json, os, sys
path, started, finished, ok, reason, detail = sys.argv[1:7]
tmp = "%s.%d.tmp" % (path, os.getpid())
try:
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"started": started, "finished": finished, "ok": ok == "true", "reason": reason, "detail": detail}, f)
        f.write("\n")
    os.replace(tmp, path)
except OSError:
    pass
'

# The lock: <file>.lock holds `<pid> <start time>`. A guard flock makes the
# check and the write one step, so two callers never both take a stale lock over.
# A lock is stale when its pid is dead, it is 10 minutes old or it is unreadable.
# Exit 0: taken. 3: held, prints `busy <start time>`.
ACQUIRE='
import datetime, fcntl, os, sys
lock, pid, now = sys.argv[1:4]
utc = datetime.timezone.utc
guard = open(lock + ".guard", "a")
fcntl.flock(guard, fcntl.LOCK_EX)
def alive(p):
    try:
        os.kill(p, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True
try:
    with open(lock) as f:
        held_pid, held_at = f.read().split()[:2]
    held_pid = int(held_pid)
    age = (datetime.datetime.now(utc) - datetime.datetime.strptime(held_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=utc)).total_seconds()
    if held_pid > 0 and alive(held_pid) and age < 600:
        print("busy " + held_at)
        sys.exit(3)
except (OSError, ValueError):
    pass
tmp = "%s.%s.tmp" % (lock, pid)
with open(tmp, "w") as f:
    f.write("%s %s\n" % (pid, now))
os.replace(tmp, lock)
'

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# failed <reason> <detail>: the one failure line.
failed() { say "failed reason=$1 detail=$2"; exit 1; }

# after_run <rc> [map]: the end of a verb that ran talos.sh. With `map`, a run
# that printed no map= path is a failure too.
after_run() {
  classify
  if [ "$1" -ne 0 ] || { [ "${2:-}" = map ] && [ -z "$MAP" ]; }; then
    [ -n "$DETAIL" ] || { [ "$1" -ne 0 ] && DETAIL="exit $1" || DETAIL="no map path"; }
    RESULT=failed
  else
    RESULT=done
  fi
}

case "$VERB" in
  redraw)
    say "phase=render"
    run_talos map; RC=$?
    after_run "$RC" map
    [ "$RESULT" = done ] || failed "$REASON" "$DETAIL"
    say "done map=$MAP"
    ;;
  refresh)
    DIR="$HOME_DIR/maps/.refresh"
    mkdir -p "$DIR" 2> /dev/null || die refresh-dir-unavailable
    STARTED="$(now_iso)"
    HELD="$(python3 -I -c "$ACQUIRE" "$DIR/$FILE.lock" "$$" "$STARTED" 2> /dev/null)"; LRC=$?
    case "$LRC" in
      0) LOCK="$DIR/$FILE.lock" ;;
      3) say "busy since=${HELD#busy }"; exit 0 ;;
      *) die lock-unavailable ;;
    esac
    say "phase=reading"
    run_talos map --refresh; RC=$?
    after_run "$RC" map
    if [ "$RESULT" = done ]; then
      python3 -I -c "$RECORD" "$DIR/$FILE.json" "$STARTED" "$(now_iso)" true ok "${WARN:+warn=$WARN}" 2> /dev/null
      say "done map=$MAP${WARN:+ warn=$WARN}"
    else
      python3 -I -c "$RECORD" "$DIR/$FILE.json" "$STARTED" "$(now_iso)" false "$REASON" "$DETAIL" 2> /dev/null
      failed "$REASON" "$DETAIL"
    fi
    ;;
  forget)
    run_talos map --forget "$SLUG"; RC=$?
    after_run "$RC"
    [ "$RESULT" = done ] || failed "$REASON" "$DETAIL"
    say "done forgot=$SLUG"
    ;;
  open)
    case "$(uname -s)" in Darwin) OPENER=open ;; *) OPENER=xdg-open ;; esac
    PAGE="$HOME_DIR/maps/$FILE"
    "$OPENER" "$PAGE" > /dev/null 2> "$TMP/err" < /dev/null; RC=$?
    : > "$TMP/out"
    after_run "$RC"
    [ "$RESULT" = done ] || failed failed "$DETAIL"
    say "done opened=$PAGE"
    ;;
  open-url)
    case "$(uname -s)" in Darwin) OPENER=open ;; *) OPENER=xdg-open ;; esac
    "$OPENER" "$URL" > /dev/null 2> "$TMP/err" < /dev/null; RC=$?
    : > "$TMP/out"
    after_run "$RC"
    [ "$RESULT" = done ] || failed failed "$DETAIL"
    say "done opened-url"
    ;;
esac
exit 0
