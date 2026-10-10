#!/usr/bin/env bash
# talos-statusline.sh -- wire Talos's status line into Claude Code's statusLine,
# chaining a status line that is already there (#585). The one implementation
# behind `install.sh --global` and `/talos:setup`.
#
# Usage:
#   talos-statusline.sh wire <settings.json> <talos-scripts-dir>
#   talos-statusline.sh undo <settings.json>
#
# State: exactly two files in ${TALOS_HOME:-~/.talos}, the only paths Talos reads,
# writes or deletes (a file or backup anywhere else is never looked at):
#   W  statusline-chain.sh        the wrapper (mode 0700), regenerated from B on
#                                 every wire; written only when missing or
#                                 header-carrying
#   B  statusline-previous.json   the original statusLine value, verbatim (0600),
#                                 written only when chaining a foreign command
#
# One classification of the statusLine command (classify), used by wire and undo:
#   none      no statusLine
#   ours      some word of the command (a leading ~, $HOME, ${HOME}, $TALOS_HOME,
#             ${TALOS_HOME} expanded) resolves to W; interpreter, env prefixes
#             and arguments do not matter
#   reserved  not ours, but the command text contains `statusline-chain.sh`
#             anywhere (`bash W; x`, `bash -c 'bash W'`, `(bash W)`, `W|tail`, a
#             user's own script of that name)
#   direct    Talos's own `bash <scripts>/talos-status.sh --line`
#   foreign   everything else
#
# wire, by class:
#   none/direct -> bash <scripts>/talos-status.sh --line (set, or pointed at <scripts>)
#   foreign     -> B written, W written, statusLine.command becomes `bash W`
#                  (other fields kept); a user's file at W: notice, nothing changed
#   ours        -> W rewritten in place from B; settings.json and B untouched;
#                  a user's file at W, or no usable B: notice, nothing changed
#   reserved    -> one notice, nothing written, never chained or saved as the original
#   no string command, or settings.json that does not parse -> left alone, notice
# A backup value is usable only when its command is foreign: an unusable B is
# never restored and never used to render W.
# undo, by class (every printed line matches what was done):
#   ours        -> a user's file at W: one notice, nothing changed or deleted (B
#                  included). Otherwise statusLine goes back to exactly B's value
#                  (the key is removed with no usable B); W (header only) and B
#                  are deleted, each reported.
#   direct      -> the key removed; a leftover W (header only) or B deleted
#   reserved    -> statusLine left as it is, nothing deleted, one notice
#   foreign/none-> statusLine untouched; a leftover W (header only) or B deleted;
#                  nothing there: "nothing to undo"
#
# The wrapper reads Claude's JSON from stdin once and runs the original command
# (sh -c) and `talos-status.sh --line` side by side, each with that stdin, its own
# timeout (TALOS_STATUSLINE_TIMEOUT_S, 1..10, default 2) and its own failure
# (exit code and stderr ignored). It prints the original's rows, then the Talos
# line as the last row (Claude Code shows every output line as a row), or only
# the part that produced output, and always exits 0. A wrapper started inside a
# wrapper (TALOS_STATUSLINE_CHAIN set) skips the original and prints only the
# Talos line.
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
# Recursion guard: a wrapper started by a wrapper (corrupted state) skips the
# original and prints only the Talos line.
SKIP_ORIG=
[ -n "${TALOS_STATUSLINE_CHAIN:-}" ] && SKIP_ORIG=1
export TALOS_STATUSLINE_CHAIN=1

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

[ -n "$SKIP_ORIG" ] || _run "$D/orig" sh -c "$ORIG" &
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


def state_wrapper():
    return os.path.join(STATE, WRAPPER_NAME)


def expand(token):
    # a leading ~, $HOME, ${HOME}, $TALOS_HOME or ${TALOS_HOME}, as a shell would
    home = os.environ.get("HOME") or os.path.expanduser("~")
    for var, val in (("${HOME}", home), ("$HOME", home), ("${TALOS_HOME}", STATE), ("$TALOS_HOME", STATE)):
        if token.startswith(var) and (len(token) == len(var) or token[len(var)] == "/"):
            return val + token[len(var):]
    if token.startswith("~"):
        return os.path.expanduser(token)
    return token


def classify(cmd):
    # THE decision, used by wire and undo. Talos owns exactly two files, W and B
    # (<TALOS_HOME>/statusline-chain.sh and statusline-previous.json); no other path
    # is ever read, written or deleted.
    #   none     no statusLine
    #   ours     a token (a leading ~, $HOME, ${HOME}, $TALOS_HOME, ${TALOS_HOME}
    #            expanded) resolves to W; interpreter, env prefixes, arguments do not matter
    #   reserved not ours, but the command text contains the wrapper's file name
    #            anywhere (`bash W; x`, `bash -c 'bash W'`, `W|tail`, a user's own
    #            script of that name): never chained, never saved as the original
    #   direct   Talos's own `bash <scripts>/talos-status.sh --line`
    #   foreign  everything else
    if not cmd:
        return "none"
    mine = os.path.realpath(state_wrapper())
    for token in split(cmd):
        path = expand(token)
        if os.path.isabs(path) and os.path.realpath(path) == mine:
            return "ours"
    if WRAPPER_NAME in cmd:
        return "reserved"
    return "direct" if is_direct(cmd) else "foreign"


def user_file(path):
    # a file at the wrapper's place that Talos did not write
    return os.path.lexists(path) and not has_header(path)


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


def not_ours(path, what):
    say("notice: %s is not a Talos wrapper (it has no Talos header), so %s; nothing was changed or deleted" % (path, what))


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
    kind = classify(cmd)
    if kind == "reserved":
        say("notice: the status line names %s but is not the Talos wrapper; left unchanged (%s). "
            "To show the Talos line, set statusLine.command to: %s" % (WRAPPER_NAME, cmd, direct))
        return
    if kind == "ours":
        # chained already: only the wrapper file is rewritten, never the command or the backup
        wrapper = state_wrapper()
        if user_file(wrapper):
            not_ours(wrapper, "the statusLine that names it was left as it is")
        else:
            refresh_chain(wrapper, status)
        return
    if kind in ("none", "direct"):
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


def load_backup(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def usable(value):
    # a backup value is usable only when its command is a foreign one: never the
    # wrapper, never a reserved name, never Talos's own command
    cmd = status_cmd(value)
    return cmd is not None and classify(cmd) == "foreign"


def read_backup():
    value = load_backup(os.path.join(STATE, BACKUP_NAME))
    return value if usable(value) else None


def refresh_chain(wrapper, status):
    value = read_backup()
    if value is None:
        say("notice: statusLine runs %s but its backup (%s) is missing, unreadable or not a usable command, left as it is; "
            "run install.sh --global --statusline-undo, or set statusLine by hand" % (wrapper, BACKUP_NAME))
        return
    text = render(status_cmd(value), status)
    if read_text(wrapper) != text:
        atomic_write(wrapper, text, 0o700)
        say("updated: %s now calls %s (statusLine unchanged)" % (wrapper, status))
    else:
        if os.stat(wrapper).st_mode & 0o777 != 0o700:
            os.chmod(wrapper, 0o700)
        say("skip (already chained): statusLine runs %s" % wrapper)


def chain(real, doc, sl, cmd, status, settings):
    wrapper = state_wrapper()
    backup = os.path.join(STATE, BACKUP_NAME)
    if user_file(wrapper):
        not_ours(wrapper, "the statusLine was not chained")
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


def remove(path, what):
    try:
        os.unlink(path)
        say("removed: %s (%s)" % (path, what))
    except OSError:
        pass


def undo(settings):
    real = os.path.realpath(settings)
    try:
        doc = load_settings(real) if os.path.exists(real) else None
    except (OSError, ValueError) as e:
        say("notice: %s was not changed (%s: %s); nothing was undone" % (settings, type(e).__name__, e))
        return
    sl = doc.get("statusLine") if doc else None
    kind = classify(status_cmd(sl))
    wrapper, backup = state_wrapper(), os.path.join(STATE, BACKUP_NAME)
    if kind == "reserved":
        say("notice: the status line names %s but is not the Talos wrapper; left unchanged, nothing was deleted" % WRAPPER_NAME)
        return
    if kind == "ours":
        if user_file(wrapper):
            not_ours(wrapper, "the statusLine that names it was left as it is")
            return
        value = load_backup(backup)
        if usable(value):
            doc["statusLine"] = value
            say("restored: statusLine is back to %s" % json.dumps(value))
        else:
            del doc["statusLine"]
            say("removed: the statusLine key (no usable backup of the original)")
        write_settings(real, doc)
    elif kind == "direct":
        del doc["statusLine"]
        write_settings(real, doc)
        say("removed: the statusLine key (it ran Talos's own command)")
    left = False
    if os.path.lexists(wrapper):
        left = True
        if has_header(wrapper):
            remove(wrapper, "the Talos wrapper")
        else:
            not_ours(wrapper, "it was left in place")
    if os.path.lexists(backup):
        left = True
        remove(backup, "the saved original")
    if not left and kind in ("none", "foreign"):
        say("nothing to undo")


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
