#!/usr/bin/env bash
# talos-statusline.sh -- wire Talos's status line into Claude Code's statusLine,
# chaining a status line that is already there (#585). The one implementation
# behind `install.sh --global` and `/talos:setup`.
#
# Usage:
#   talos-statusline.sh wire <settings.json> <talos-scripts-dir>
#   talos-statusline.sh undo <settings.json>
#
# State lives in ${TALOS_HOME:-~/.talos}:
#   statusline-previous.json  the original statusLine value, verbatim (written
#                             only when the current statusLine is not Talos's,
#                             never overwritten while statusLine runs the wrapper)
#   statusline-chain.sh       the wrapper (mode 0700), regenerated from the
#                             backup on every wire
#
# wire, by the current statusLine:
#   none                      -> bash <scripts>/talos-status.sh --line
#   Talos's own command       -> unchanged, or pointed at <scripts>
#   the chain wrapper         -> wrapper rewritten in place from the backup;
#                                settings.json and the backup are not touched
#   another command           -> backed up, wrapper written, statusLine.command
#                                becomes `bash <wrapper>` (other fields kept)
#   no string command, or settings.json that does not parse -> left alone, notice
# undo: statusLine goes back to exactly the backed-up value (key removed when
#   there is no backup and it was Talos's own command), wrapper and backup are
#   deleted; with nothing Talos-owned it says "nothing to undo".
#
# The wrapper reads Claude's JSON from stdin once and runs the original command
# (sh -c) and `talos-status.sh --line` side by side, each with that stdin, its own
# timeout (TALOS_STATUSLINE_TIMEOUT_S, 1..10, default 2) and its own failure
# (exit code and stderr ignored). It prints the original's rows, then the Talos
# line as the last row (Claude Code shows every output line as a row), or only
# the part that produced output, and always exits 0.
#
# The JSON edit is python3 -I, atomic and symlink-safe. Never aborts the caller:
# always exit 0, problems are one-line notices on stdout.

set -u

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  wire) [ "$#" -eq 3 ] || { usage >&2; exit 2; } ;;
  undo) [ "$#" -eq 2 ] || { usage >&2; exit 2; } ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "notice: python3 not found; the status line was not wired. Set statusLine.command to: bash ${3:-<talos scripts dir>}/talos-status.sh --line"
  exit 0
fi

IFS= read -r -d '' WRAPPER_TEMPLATE <<'TALOS_WRAPPER_SH' || true
#!/usr/bin/env bash
# Talos status line chain (#585): your original statusLine command and the Talos
# line, side by side. Written by talos-statusline.sh and regenerated on every
# install; do not edit. Undo: bash install.sh --global --statusline-undo
ORIG=@ORIG@
TALOS_STATUS=@STATUS@
T="${TALOS_STATUSLINE_TIMEOUT_S:-2}"
case "$T" in '' | *[!0-9]*) T=2 ;; esac
[ "${#T}" -gt 2 ] && T=10
[ "$T" -lt 1 ] && T=1
[ "$T" -gt 10 ] && T=10
D="$(mktemp -d "${TMPDIR:-/tmp}/talos-chain.XXXXXX" 2>/dev/null)" || exit 0
trap 'rm -rf "$D"' EXIT
cat > "$D/in" 2>/dev/null

# _run OUTFILE CMD... -- CMD with the saved stdin, stdout to OUTFILE, killed after
# T seconds; exit code and stderr are dropped.
_run() {
  local out="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$T" "$@" < "$D/in" > "$out" 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$T" "$@" < "$D/in" > "$out" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -I -c 'import os, signal, subprocess, sys
p = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    p.wait(int(sys.argv[1]))
except subprocess.TimeoutExpired:
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except OSError:
        pass' "$T" "$@" < "$D/in" > "$out" 2>/dev/null
  else
    "$@" < "$D/in" > "$out" 2>/dev/null
  fi
  return 0
}

_run "$D/orig" sh -c "$ORIG" &
_run "$D/talos" bash "$TALOS_STATUS" --line &
wait

orig="$(cat "$D/orig" 2>/dev/null)"
talos="$(cat "$D/talos" 2>/dev/null)"
if [ -n "$orig" ] && [ -n "$talos" ]; then
  printf '%s\n%s\n' "$orig" "$talos"
elif [ -n "$orig" ]; then
  printf '%s\n' "$orig"
elif [ -n "$talos" ]; then
  printf '%s\n' "$talos"
fi
exit 0
TALOS_WRAPPER_SH

IFS= read -r -d '' STATUSLINE_PY <<'TALOS_STATUSLINE_PY' || true
import json, os, re, shlex, sys, tempfile

TEMPLATE = os.environ["TALOS_WRAPPER_TEMPLATE"]
STATE = os.path.expanduser(os.environ.get("TALOS_HOME") or "~/.talos")
WRAPPER_NAME, BACKUP_NAME = "statusline-chain.sh", "statusline-previous.json"


def clean(v):
    # No control character of a path or command reaches the terminal.
    return "".join("?" if ord(c) < 32 or 0x7F <= ord(c) <= 0x9F else c for c in str(v))


def say(m):
    print(clean(m))


def atomic_write(path, text, mode):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".statusline-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def dumps(v):
    return json.dumps(v, indent=2, ensure_ascii=False) + "\n"


def load_settings(real):
    if not os.path.exists(real):
        return {}
    with open(real, encoding="utf-8") as f:
        doc = json.load(f)
    if not isinstance(doc, dict):
        raise ValueError("not a JSON object")
    return doc


def write_settings(real, doc):
    mode = os.stat(real).st_mode & 0o777 if os.path.exists(real) else 0o600
    atomic_write(real, dumps(doc), mode)


def split(cmd):
    try:
        return shlex.split(cmd)
    except ValueError:
        return []


HEADER = "Talos status line chain (#585)"


def has_header(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return HEADER in f.read(512)
    except OSError:
        return False


def chain_path(cmd):
    # The Talos wrapper is an absolute path that is either the wrapper under the
    # Talos state dir or a file carrying the Talos header (a wrapper left behind
    # by an install under another TALOS_HOME). A script that is merely named
    # statusline-chain.sh is somebody else's status line.
    a = split(cmd)
    if len(a) != 2 or a[0] != "bash" or not os.path.isabs(a[1]):
        return None
    if os.path.realpath(a[1]) == os.path.realpath(os.path.join(STATE, WRAPPER_NAME)) or has_header(a[1]):
        return a[1]
    return None


def is_direct(cmd):
    a = split(cmd)
    return len(a) == 3 and a[0] == "bash" and os.path.basename(a[1]) == "talos-status.sh" and a[2] == "--line"


def render(orig, status):
    # One pass: a placeholder inside the user's command is data, not a slot.
    values = {"@ORIG@": shlex.quote(orig), "@STATUS@": shlex.quote(status)}
    return re.sub(r"@ORIG@|@STATUS@", lambda m: values[m.group(0)], TEMPLATE)


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def status_cmd(sl):
    c = sl.get("command") if isinstance(sl, dict) else None
    return c if isinstance(c, str) else None


def wire(settings, scripts):
    # absolute, but as given (abspath would normalise a // in TMPDIR)
    status = os.path.join(scripts if os.path.isabs(scripts) else os.path.abspath(scripts), "talos-status.sh")
    direct = "bash %s --line" % shlex.quote(status)
    real = os.path.realpath(settings)
    try:
        doc = load_settings(real)
    except (OSError, ValueError) as e:
        say("notice: %s was not changed (%s: %s); wire it by hand: statusLine {\"type\": \"command\", \"command\": \"%s\"}"
            % (settings, type(e).__name__, e, direct))
        return
    sl = doc.get("statusLine")
    cmd = status_cmd(sl)
    if sl is not None and cmd is None:
        say("notice: %s has a statusLine without a command, left as it is (only a command status line can be chained): %s"
            % (settings, json.dumps(sl)))
        return
    if cmd is not None and chain_path(cmd):
        refresh_chain(chain_path(cmd), status)
        return
    if cmd is None or is_direct(cmd):
        if cmd == direct:
            say("skip (already wired): statusLine runs %s" % status)
            return
        new = dict(sl, command=direct) if sl else {"command": direct}
        new.setdefault("type", "command")
        doc["statusLine"] = new
        write_settings(real, doc)
        if sl is None:
            say("installed: statusLine -> %s" % direct)
        else:
            say("updated: statusLine now runs the installed copy (%s)" % status)
        return
    chain(real, doc, sl, cmd, status, settings)


def refresh_chain(wrapper, status):
    backup = next((p for p in (os.path.join(d, BACKUP_NAME) for d in (os.path.dirname(wrapper), STATE))
                   if os.path.exists(p)), None)
    orig = None
    if backup:
        try:
            with open(backup, encoding="utf-8") as f:
                orig = status_cmd(json.load(f))
        except (OSError, ValueError):
            pass
    if orig is None:
        say("notice: statusLine runs %s but its backup (%s) is missing or unreadable, left as it is; "
            "run install.sh --global --statusline-undo, or set statusLine by hand" % (wrapper, BACKUP_NAME))
        return
    text = render(orig, status)
    if read_text(wrapper) != text:
        atomic_write(wrapper, text, 0o700)
        say("updated: %s now calls %s (statusLine unchanged)" % (wrapper, status))
    else:
        if os.stat(wrapper).st_mode & 0o777 != 0o700:
            os.chmod(wrapper, 0o700)
        say("skip (already chained): statusLine runs %s" % wrapper)


def chain(real, doc, sl, cmd, status, settings):
    wrapper = os.path.join(STATE, WRAPPER_NAME)
    backup = os.path.join(STATE, BACKUP_NAME)
    if os.path.lexists(wrapper) and not has_header(wrapper):
        say("notice: %s is not a Talos wrapper, so the statusLine was not chained and nothing was overwritten; move that file away and run this again"
            % wrapper)
        return
    try:
        atomic_write(backup, dumps(sl), 0o600)
        atomic_write(wrapper, render(cmd, status), 0o700)
        new = dict(sl, command="bash %s" % shlex.quote(wrapper))
        new.setdefault("type", "command")
        doc["statusLine"] = new
        write_settings(real, doc)
    except OSError as e:
        for p in (wrapper, backup):
            try:
                os.unlink(p)
            except OSError:
                pass
        say("notice: %s was not changed (%s: %s); the existing statusLine is untouched" % (settings, type(e).__name__, e))
        return
    say("chained: statusLine now runs %s, which prints your original line (%s) and then the Talos line" % (wrapper, cmd))
    say("         original saved to %s; undo: bash install.sh --global --statusline-undo" % backup)


def undo(settings):
    real = os.path.realpath(settings)
    try:
        doc = load_settings(real) if os.path.exists(real) else None
    except (OSError, ValueError) as e:
        say("notice: %s was not changed (%s: %s); nothing was undone" % (settings, type(e).__name__, e))
        return
    sl = doc.get("statusLine") if doc else None
    cmd = status_cmd(sl)
    wrapper_in_use = chain_path(cmd) if cmd else None
    dirs = ([os.path.dirname(wrapper_in_use)] if wrapper_in_use else []) + [STATE]
    files = []
    for d in dirs:
        for name in (BACKUP_NAME, WRAPPER_NAME):
            p = os.path.join(d, name)
            if os.path.exists(p) and p not in files:
                files.append(p)
    backups = [p for p in files if os.path.basename(p) == BACKUP_NAME]
    owned = bool(cmd) and (wrapper_in_use is not None or is_direct(cmd))
    if not owned and not files:
        say("nothing to undo")
        return
    if owned:
        if backups:
            try:
                with open(backups[0], encoding="utf-8") as f:
                    doc["statusLine"] = json.load(f)
            except (OSError, ValueError) as e:
                say("notice: %s is unreadable (%s: %s); nothing was undone" % (backups[0], type(e).__name__, e))
                return
            what = "restored: statusLine is back to %s" % json.dumps(doc["statusLine"])
        else:
            del doc["statusLine"]
            what = "removed: the Talos statusLine"
        write_settings(real, doc)
        say(what)
    else:
        say("notice: statusLine is no longer Talos's, left as it is")
    for p in files:
        if os.path.basename(p) == WRAPPER_NAME and not has_header(p):
            say("notice: %s is not a Talos wrapper, left in place" % p)
            continue
        try:
            os.unlink(p)
            say("removed: %s" % p)
        except OSError:
            pass


try:
    if sys.argv[1] == "wire":
        wire(sys.argv[2], sys.argv[3])
    else:
        undo(sys.argv[2])
except OSError as e:
    say("notice: the status line was not changed (%s: %s)" % (type(e).__name__, e))
TALOS_STATUSLINE_PY

TALOS_WRAPPER_TEMPLATE="$WRAPPER_TEMPLATE" python3 -I -c "$STATUSLINE_PY" "$@" 2>/dev/null \
  || echo "notice: the status line was not changed (the settings edit failed)."
exit 0
