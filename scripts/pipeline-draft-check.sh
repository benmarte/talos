#!/usr/bin/env bash
# pipeline-draft-check.sh -- the draft-PR default (#435): the one resolver for
# `pr.draft` and the check that the repo's CI pairs with it.
#
# Usage: pipeline-draft-check.sh [check [<workflows-dir>]]
#        pipeline-draft-check.sh resolve
#        pipeline-draft-check.sh edit <workflow-file> [--write]
#
#   check     Scan <workflows-dir> (default .github/workflows) for *.yml and
#             *.yaml and print ONE status on stdout. Always exit 0 (fail open:
#             a check problem never blocks a run). A file's draft skip counts
#             only when a job- (or workflow-) level `if:` is
#             `github.event.pull_request.draft != true`, `== false` or
#             `!github.event.pull_request.draft`, alone or `&&`-combined;
#             `== true`, an `||` branch or a mere mention does not count.
#               ok                every workflow with a `pull_request` trigger
#                                 skips drafts and lists `ready_for_review` in
#                                 `types`
#               no-skip           a PR-triggered workflow does not skip drafts
#               no-ready-trigger  a workflow skips drafts but `ready_for_review`
#                                 is not in `types`: `ready-pr` fires no event
#                                 for it, no run starts, and QA waits for one
#               none              no workflow has a `pull_request` trigger
#               unknown           parse error, `pull_request_target`, a reusable
#                                 workflow, a symlink or a file over 1 MB,
#                                 anything doubtful
#             When files disagree the worst wins: no-ready-trigger, then
#             no-skip, then ok, then unknown, then none. It parses with PyYAML
#             when importable, else a conservative grep of the same signals.
#             TALOS_DRAFT_CHECK_NO_YAML=1 forces the grep path (the tests use
#             it). check never edits a file.
#   resolve   The effective PR_DRAFT on stdout, `true` or `false`, from
#             `pr.draft` and `vcs.provider`; at most one warning line on stderr.
#               explicit false                         false
#               github-api, file                       false (they cannot open
#                                                      draft PRs); warns when a
#                                                      `true` was asked for or
#                                                      defaulted (file: only an
#                                                      explicit true; no PRs
#                                                      exist there)
#               gitlab, azure                          true unless explicit false
#               github, unset or true                  true, after the CI check:
#                 no-skip / unknown                    warn, stay true (only the
#                                                      saving is lost)
#                 no-ready-trigger                     key unset: warn and
#                                                      false (the ready flow, so
#                                                      QA cannot hang); explicit
#                                                      true: warn, stay true
#             Used by /pipeline Step 0 and pipeline-status-file.sh, so both
#             read the same value.
#   edit      The minimal workflow change /pipeline-setup offers. Without
#             --write it prints the unified diff and writes nothing; with
#             --write it applies exactly that diff. Only two kinds of change:
#             append `ready_for_review` to `on.pull_request.types` (a missing
#             `types` gets `[opened, synchronize, reopened, ready_for_review]`),
#             and add `if: github.event.pull_request.draft != true` to a job
#             that has no `if:`. An existing job `if:` (any form) is NEVER
#             edited; it is listed after the diff as `manual: job <name>: ...`
#             with the suggested combined condition, for the user to apply by
#             hand. The result is checked line by line (`verify`) and refused
#             if any pre-existing line, other than the one `types:` flow line,
#             would change (never `permissions:`, other events, secrets or
#             steps). It prints `refused: <why>` on stderr and exits 1, writing
#             nothing, for a file that is not a regular non-symlink file
#             directly under .github/workflows (no symlink on the path), over
#             1 MB, or in a shape it cannot edit minimally (`on:` as a list or
#             scalar, flow-style `pull_request`).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── The draft-skip predicate, shared by check (PyYAML) and edit ───────────────
read -r -d '' _DC_PRED <<'TALOS_p4Xr9Lw2Qn7B' || true
import re

DRAFT = "github.event.pull_request.draft"
FORMS = {DRAFT + "!=true", DRAFT + "==false", "!" + DRAFT}

def _split(e, op):
    parts, depth, cur, i = [], 0, "", 0
    while i < len(e):
        c = e[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if depth == 0 and e.startswith(op, i):
            parts.append(cur)
            cur, i = "", i + len(op)
            continue
        cur += c
        i += 1
    parts.append(cur)
    return parts

def _unwrap(e):
    while e.startswith("("):
        depth = 0
        for i, c in enumerate(e):
            depth += (c == "(") - (c == ")")
            if depth == 0:
                break
        if i != len(e) - 1:
            break
        e = e[1:-1]
    return e

def real_skip(expr):
    """True only when the condition holds back a draft: draft != true, == false,
    or !draft, alone or && combined; an || branch, == true or a mention is not."""
    if not isinstance(expr, str):
        return False
    e = re.sub(r"\s+", "", expr)
    m = re.fullmatch(r"\$\{\{(.*)\}\}", e)
    if m:
        e = m.group(1)
    e = _unwrap(e)
    if len(_split(e, "||")) > 1:
        return False
    return any(p in FORMS or (p.startswith("!") and _unwrap(p[1:]) == DRAFT)
               or (p.startswith("(") and real_skip(p)) for p in _split(e, "&&"))
TALOS_p4Xr9Lw2Qn7B

# ── The post-edit check: the only allowed changes are added `if:` lines (the
# draft skip on a job that had none), the `types:` line and one added
# `- ready_for_review` item. Any modified or removed pre-existing line, other
# than that one `types:` flow line, is refused.
read -r -d '' _DC_VERIFY_PY <<'TALOS_v6Yb2Kq8Zr4D' || true
import difflib

_ADDED = re.compile(r"^\s*(if: " + re.escape(DRAFT + " != true") +
                    r"|types: \[opened, synchronize, reopened, ready_for_review\]|- ready_for_review)\s*$")
_TYPES = re.compile(r"^\s*types:\s*\[")

def verify(orig, new):
    """None when new only adds the allowed lines to orig, else the reason."""
    a = [x.rstrip("\r\n") for x in orig]
    b = [x.rstrip("\r\n") for x in new]
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        if tag == "insert" and all(_ADDED.match(x) for x in b[j1:j2]):
            continue
        if tag == "replace" and i2 - i1 == 1 and j2 - j1 == 1 and _TYPES.match(a[i1]) and _TYPES.match(b[j1]) \
                and b[j1].startswith(a[i1].split("]")[0]):
            continue
        return "the edit would change a pre-existing line (%s, line %d)" % (tag, i1 + 1)
    return None
TALOS_v6Yb2Kq8Zr4D

# ── check ─────────────────────────────────────────────────────────────────────
# Per file, four 0/1 flags: trigger skip ready unknown.
read -r -d '' _DC_YAML_PY <<'TALOS_k3v9XqLm2Wd7' || true
import sys
import yaml

def names(on):
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return {str(x) for x in on}
    if isinstance(on, dict):
        return {str(k) for k in on}
    return set()

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    if not isinstance(doc, dict):
        raise ValueError("not a mapping")
    # PyYAML reads the bare key `on` as the boolean True.
    on = doc.get(True, doc.get("on"))
    trig = names(on)
    if "pull_request" not in trig:
        unknown = 1 if (trig & {"pull_request_target", "workflow_call"} or not trig) else 0
        print(0, 0, 0, unknown)
        sys.exit(0)
    pr = on.get("pull_request") if isinstance(on, dict) else None
    types = pr.get("types") if isinstance(pr, dict) else None
    if isinstance(types, str):
        types = [types]
    ready = int(isinstance(types, list) and "ready_for_review" in types)
    jobs = doc.get("jobs")
    jobs = jobs if isinstance(jobs, dict) else {}
    skip = int(real_skip(doc.get("if")) or any(
        isinstance(j, dict) and real_skip(j.get("if")) for j in jobs.values()))
    # A job that calls a reusable workflow may skip drafts where this file
    # cannot see: doubtful, not "no-skip".
    unknown = int(not skip and any(
        isinstance(j, dict) and "uses" in j for j in jobs.values()))
    print(1, skip, ready, unknown)
except Exception:
    print(0, 0, 0, 1)
TALOS_k3v9XqLm2Wd7

_dc_flags_yaml() { python3 -I -c "$_DC_PRED"$'\n'"$_DC_YAML_PY" "$1" 2>/dev/null; }

_dc_flags_grep() {
  local f="$1" t s r u txt skiplines
  txt="$(sed 's/[[:space:]]*#.*//' "$f" 2>/dev/null)" || { echo "0 0 0 1"; return; }
  t=0; s=0; r=0; u=0
  if printf '%s\n' "$txt" | grep -Eq '^[[:space:]]*(-[[:space:]]*)?pull_request[[:space:]]*:?[[:space:]]*$|^[[:space:]]*(on|"on"|true)[[:space:]]*:[[:space:]]*(pull_request[[:space:]]*$|\[([^]]*[[:space:],])?pull_request[],[:space:]])'; then
    t=1
    printf '%s\n' "$txt" | grep -q 'ready_for_review' && r=1
    # A real skip, per line: draft != true, == false or !draft (parentheses
    # read as blanks for the form), and no `||` once parenthesised groups are
    # removed (`(a || b) && draft != true` is still a skip).
    [ -n "$(printf '%s\n' "$txt" | awk '
      /github\.event\.pull_request\.draft/ {
        flat = $0; gsub(/[()]/, " ", flat)
        if (flat !~ /github\.event\.pull_request\.draft[ \t]*(!=[ \t]*true|==[ \t]*false)|![ \t]*github\.event\.pull_request\.draft/) next
        strip = $0
        while (strip ~ /\([^()]*\)/) gsub(/\([^()]*\)/, "", strip)
        if (strip !~ /\|\|/) print "1"
      }')" ] && s=1
    # A multi-line `if:` (`>-`, `|`, or a continued plain scalar) cannot be read
    # line by line: doubtful, never ok.
    if [ -n "$(printf '%s\n' "$txt" | awk '
      /^[ ]*if:/ { match($0, /^ */); pind = RLENGTH; v = $0; sub(/^[ ]*if:[ ]*/, "", v)
                   if (v == "" || v ~ /^[>|]/) print 1
                   pend = 1; next }
      pend && NF { match($0, /^ */); if (RLENGTH > pind) print 1; pend = 0 }')" ]; then
      s=0; u=1
    fi
    [ "$s" = 0 ] && printf '%s\n' "$txt" | grep -Eq '^[[:space:]]*uses:' && u=1
  elif printf '%s\n' "$txt" | grep -Eq 'pull_request_target|workflow_call'; then
    u=1
  fi
  echo "$t $s $r $u"
}

_dc_check() {
  local dir="${1:-.github/workflows}" f flags t s r u size
  local noready=0 noskip=0 ok=0 unk=0 have_yaml=0
  if [ "${TALOS_DRAFT_CHECK_NO_YAML:-}" != 1 ] && python3 -I -c 'import yaml' 2>/dev/null; then
    have_yaml=1
  fi
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -e "$f" ] || [ -L "$f" ] || continue   # an unmatched glob stays literal: skip it
    # A symlink, a non-regular file or an oversized one is never read.
    if [ -L "$f" ] || [ ! -f "$f" ]; then unk=1; continue; fi
    size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
    case "${size:-x}" in ''|*[!0-9]*) unk=1; continue ;; esac
    if [ "$size" -gt 1048576 ]; then unk=1; continue; fi
    if [ "$have_yaml" = 1 ]; then flags="$(_dc_flags_yaml "$f")"; else flags="$(_dc_flags_grep "$f")"; fi
    # shellcheck disable=SC2034
    read -r t s r u <<EOF
$flags
EOF
    case "${t:-x}${s:-x}${r:-x}${u:-x}" in
      [01][01][01][01]) ;;
      *) unk=1; continue ;;
    esac
    if [ "$t" = 1 ]; then
      if [ "$s" = 1 ] && [ "$r" = 1 ]; then ok=1
      elif [ "$s" = 1 ]; then noready=1
      elif [ "$u" = 1 ]; then unk=1
      else noskip=1
      fi
    elif [ "$u" = 1 ]; then
      unk=1
    fi
  done
  if [ "$noready" = 1 ]; then echo no-ready-trigger
  elif [ "$noskip" = 1 ]; then echo no-skip
  elif [ "$ok" = 1 ]; then echo ok
  elif [ "$unk" = 1 ]; then echo unknown
  else echo none
  fi
}

# ── resolve ───────────────────────────────────────────────────────────────────
_dc_cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$1" "" 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

_dc_resolve() {
  local key provider status
  key="$(_dc_cfg pr.draft)"
  case "$key" in true|false) ;; *) key="" ;; esac
  provider="$(_dc_cfg vcs.provider)"
  [ -n "$provider" ] || provider="github"
  [ "$key" = false ] && { echo false; return; }
  case "$provider" in
    github-api|file)
      if [ "$provider" = github-api ] || [ "$key" = true ]; then
        echo "pipeline: pr.draft ignored: provider $provider cannot open draft PRs" >&2
      fi
      echo false; return ;;
    github) ;;
    *) echo true; return ;;
  esac
  status="$(_dc_check)"
  case "$status" in
    no-skip)
      echo "pipeline: CI does not skip draft PRs; CI will still run on every push. See templates/ci/github-tests.yml" >&2 ;;
    no-ready-trigger)
      if [ -z "$key" ]; then
        echo "pipeline: CI skips draft PRs but has no ready_for_review trigger, so QA would wait for a run that never starts; using the ready PR flow for this run. Add ready_for_review to on.pull_request.types (templates/ci/github-tests.yml) or set pr.draft: false" >&2
        echo false; return
      fi
      echo "pipeline: pr.draft is true but CI skips draft PRs without a ready_for_review trigger; QA will wait for a run that never starts. Add ready_for_review to on.pull_request.types (templates/ci/github-tests.yml)" >&2 ;;
    unknown)
      echo "pipeline: could not verify that CI skips draft PRs; see templates/ci/github-tests.yml" >&2 ;;
  esac
  echo true
}

# ── edit ──────────────────────────────────────────────────────────────────────
read -r -d '' _DC_EDIT_PY <<'TALOS_e7Zt3Hc8Vm5F' || true
import difflib, os, shutil, stat, sys, tempfile

SKIP = DRAFT + " != true"
TYPES = "[opened, synchronize, reopened, ready_for_review]"
MAX = 1 << 20
write = len(sys.argv) > 2 and sys.argv[2] == "--write"

def refuse(msg):
    print("refused: " + msg, file=sys.stderr)
    sys.exit(1)

# ── the file: .github/workflows/<name>.yml|yaml, regular, no symlink on the path
rel = os.path.relpath(sys.argv[1])
parts = rel.split(os.sep)
if len(parts) != 3 or parts[:2] != [".github", "workflows"] or not parts[2].endswith((".yml", ".yaml")):
    refuse("not a workflow file directly under .github/workflows")
def check_path():
    cur = ""
    for p in parts:
        cur = os.path.join(cur, p)
        try:
            st = os.lstat(cur)
        except OSError:
            refuse("cannot inspect " + cur)
        if stat.S_ISLNK(st.st_mode):
            refuse(cur + " is a symlink")
    if not stat.S_ISREG(st.st_mode):
        refuse(rel + " is not a regular file")
    if st.st_size > MAX:
        refuse(rel + " is over 1 MB")
check_path()
try:
    with open(rel, "rb") as fh:
        text = fh.read(MAX + 1).decode("utf-8")
except (OSError, UnicodeDecodeError):
    refuse("cannot read " + rel + " as UTF-8")
eol = "\r\n" if "\r\n" in text else "\n"
orig = text.splitlines(keepends=True)
if orig and not orig[-1].endswith(("\n", "\r")):
    orig[-1] += eol
lines = list(orig)

def indent(l):
    return len(l) - len(l.lstrip(" "))
def sig(l):
    s = l.strip()
    return bool(s) and not s.startswith("#")
def block_end(start, base):
    for i in range(start + 1, len(lines)):
        if sig(lines[i]) and indent(lines[i]) <= base:
            return i
    return len(lines)
def first_sig(a, b):
    for i in range(a, b):
        if sig(lines[i]):
            return i
    return None
def body(l):
    return l.rstrip("\r\n")
if any("\t" in l[:len(l) - len(l.lstrip())] for l in lines):
    refuse("tab indentation")

ops = []     # (index, "replace"|"after", new line without eol)
manual = []  # existing job conditions we report but never touch

# ── on.pull_request.types
i_on = next((i for i, l in enumerate(lines) if re.match(r"^(on|\"on\"|'on'):\s*(#.*)?$", body(l))), None)
if i_on is None:
    refuse("`on:` is not a block mapping (a list or scalar `on:` needs a hand edit)")
on_end = block_end(i_on, 0)
f = first_sig(i_on + 1, on_end)
if f is None:
    refuse("empty `on:`")
ei = indent(lines[f])
i_pr = next((i for i in range(i_on + 1, on_end)
             if indent(lines[i]) == ei and re.match(r"^\s*pull_request:\s*(#.*)?$", body(lines[i]))), None)
if i_pr is None:
    refuse("no block-style `pull_request:` trigger")
pr_end = block_end(i_pr, ei)
kids = [i for i in range(i_pr + 1, pr_end) if sig(lines[i])]
ki = indent(lines[kids[0]]) if kids else ei + 2
t_idx = next((i for i in kids if indent(lines[i]) == ki and re.match(r"^\s*types:", body(lines[i]))), None)
if t_idx is None:
    ops.append((i_pr, "after", " " * ki + "types: " + TYPES))
else:
    line = body(lines[t_idx])
    m = re.match(r"^(\s*types:\s*)\[([^\]]*)\](\s*(#.*)?)$", line)
    if m:
        items = [x.strip().strip("'\"") for x in m.group(2).split(",") if x.strip()]
        if "ready_for_review" not in items:
            inner = m.group(2).rstrip()
            new = m.group(1) + "[" + inner + (", " if inner.strip() else "") + "ready_for_review]" + m.group(3)
            ops.append((t_idx, "replace", new))
    elif re.match(r"^\s*types:\s*(#.*)?$", line):
        items, last, j = [], None, t_idx + 1
        while j < pr_end:
            if sig(lines[j]):
                im = re.match(r"^\s*-\s*(.+?)\s*(#.*)?$", body(lines[j]))
                if not im or indent(lines[j]) <= ki:
                    break
                items.append(im.group(1).strip("'\""))
                last = j
            j += 1
        if last is None:
            refuse("`types:` has an unsupported shape")
        if "ready_for_review" not in items:
            ops.append((last, "after", " " * indent(lines[last]) + "- ready_for_review"))
    else:
        refuse("`types:` has an unsupported shape")

# ── jobs
i_jobs = next((i for i, l in enumerate(lines) if re.match(r"^jobs:\s*(#.*)?$", body(l))), None)
if i_jobs is None:
    refuse("no block-style `jobs:`")
j_end = block_end(i_jobs, 0)
f = first_sig(i_jobs + 1, j_end)
if f is None:
    refuse("empty `jobs:`")
ji = indent(lines[f])
for i in range(i_jobs + 1, j_end):
    if not sig(lines[i]) or indent(lines[i]) != ji or not re.match(r"^\s*([\"']?)[A-Za-z0-9_.-]+\1:\s*(#.*)?$", body(lines[i])):
        continue
    job_end = block_end(i, ji)
    b = first_sig(i + 1, job_end)
    if b is None:
        continue
    kk = indent(lines[b])
    if_idx = next((k for k in range(i + 1, job_end)
                   if sig(lines[k]) and indent(lines[k]) == kk and re.match(r"^\s*if:", body(lines[k]))), None)
    if if_idx is None:
        ops.append((i, "after", " " * kk + "if: " + SKIP))
        continue
    # An existing if: is never edited (line-based YAML condition rewriting is
    # where guards get lost). It is reported with a suggestion instead.
    val = re.match(r"^\s*if:\s*(.*)$", body(lines[if_idx])).group(1).rstrip()
    nxt = first_sig(if_idx + 1, job_end)
    multiline = val == "" or val[0] in ">|" or (nxt is not None and indent(lines[nxt]) > kk)
    if not multiline and real_skip(val):
        continue
    sugg = "(<your existing condition>) && " + SKIP
    if not multiline:
        cm = re.match(r"^(.*?)(\s+#.*)?$", val)
        plain = cm.group(1)
        # A concrete suggestion only for a simple one-line condition.
        if not (cm.group(2) and ("'" in val or '"' in val)) and plain[:1] not in ("'", '"'):
            w = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", plain)
            if w and "${{" not in w.group(1) and "}}" not in w.group(1):
                sugg = "${{ (" + w.group(1) + ") && " + SKIP + " }}"
            elif "${{" not in plain:
                sugg = "(" + plain + ") && " + SKIP
    manual.append("manual: job %s: existing condition left unchanged; combine manually: if: %s"
                  % (body(lines[i]).strip().rstrip(":").strip("\"'"), sugg))

for idx, kind, new in sorted(ops, key=lambda o: -o[0]):
    if kind == "replace":
        lines[idx] = new + eol
    else:
        lines.insert(idx + 1, new + eol)

if lines == orig:
    print("no change needed")
    if manual:
        print("\n".join(manual))
    sys.exit(0)

err = verify(orig, lines)
if err:
    refuse("internal check: " + err + "; nothing written")

sys.stdout.write("".join(difflib.unified_diff(orig, lines, fromfile=rel, tofile=rel + " (proposed)", n=2)))
if write:
    check_path()
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(rel), prefix=".talos-edit-")
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as out:
        out.write("".join(lines))
    shutil.copymode(rel, tmp)
    os.replace(tmp, rel)
    print("written: " + rel)
if manual:
    print("\n".join(manual))
TALOS_e7Zt3Hc8Vm5F

_dc_edit() {
  [ -n "${1:-}" ] || { echo "refused: usage: pipeline-draft-check.sh edit <workflow-file> [--write]" >&2; return 1; }
  python3 -I -c "$_DC_PRED"$'\n'"$_DC_VERIFY_PY"$'\n'"$_DC_EDIT_PY" "$@"
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0   # sourced (the tests read _DC_PRED and _DC_VERIFY_PY)
case "${1:-check}" in
  check)   _dc_check "${2:-}"; exit 0 ;;
  resolve) _dc_resolve; exit 0 ;;
  edit)    shift; _dc_edit "$@"; exit $? ;;
  *) echo "usage: pipeline-draft-check.sh [check [<workflows-dir>] | resolve | edit <file> [--write]]" >&2; echo unknown; exit 0 ;;
esac
