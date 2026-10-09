#!/usr/bin/env bash
# pipeline-events.sh — reader for the local events.jsonl audit log at
# <git common dir>/talos/events.jsonl (#517: outside every git tree; the
# default events.path "talos/events.jsonl" resolves against the git common
# dir) that scripts/pipeline-hooks.sh's post_stage verb appends to (#183). See
# pipeline-hooks.sh for the payload schema and the events.enabled/events.path
# config keys.
#
# Usage: pipeline-events.sh path
#        pipeline-events.sh list [--issue N] [--role R] [--event E] [--last K] [--json]
#        pipeline-events.sh tail [--issue N]
#        pipeline-events.sh cost [--issue N] [--pr M] [--json]
#        pipeline-events.sh cost --issue N [--pr M] --line
#        pipeline-events.sh cost --issue N [--pr M] --markdown
#        pipeline-events.sh cost --summary --issue A [--issue B ...]
#
#   path   Prints the resolved absolute path to the events log (does not
#          require the file to exist).
#   list   Prints matching events, oldest first. Default output is a compact
#          one-line-per-event table (ts, event, role, issue, pr, verdict,
#          summary truncated to 80 chars); --json prints one JSON object per
#          line instead (a filtered subset of the raw log, still one line
#          per event). --issue/--role/--event filter by exact match;
#          --last K keeps only the last K matching events.
#   tail   Shorthand for `list --last 20`, optionally scoped to --issue.
#   cost   Per-issue, per-role cost summary (#202): sums tokens, tool_uses
#          and duration_s, and counts events, grouped by (issue, role).
#          A row's tokens/tool_uses/duration_s are summed treating a null
#          value as 0; the `unrecorded` column instead counts how many of that
#          group's events had a null tokens field (e.g. adapter-path runs,
#          which record duration only, per #202's proposal), so a group
#          made entirely of untracked events is visible rather than
#          silently reading as a real zero. The `restamp` column (#258)
#          counts events with verdict RESTAMP_PASS or RESTAMP_FAIL -- a
#          cheap delta re-review of a PR the same role already approved,
#          separate from that group's full-stage events/tokens totals.
#          Ends with a TOTAL row. Default output is a compact table (issue,
#          role, events, tokens, tool_uses, duration_s, unrecorded, restamp);
#          --json prints the same data as one JSON object:
#          {"rows": [...], "total": {...}}. --issue filters to
#          one issue.
#          ci_runs (#332): when at least one matched event carries a ci_runs
#          value (post_stage --ci-runs, recorded on the merged event), the
#          table gains a trailing ci_runs column and every --json row and the
#          total gain a trailing ci_runs field, summing those values. With no
#          such event the output is exactly the shape described above.
#          A `stage_start` event (#550, the dispatch marker the status line reads)
#          is not a stage run: every cost form skips it. list and tail show it.
#          --pr M keeps only events whose pr is M (an event with pr null never
#          matches), in the table, --json and --line alike.
#          --line (needs --issue; wins over --json) prints one summary line
#          for the issue (#380), from the newest non-orchestrator event in
#          scope (last in file order), identically on every runner path:
#            talos: #764 security done — 56k tokens, 14 tools, 2m05s · PR total 3.41M (dev 1.57M, adv 596k, ...)
#          The reference is #<pr> with --pr (label `PR total`), else
#          #<issue> (label `issue total`). Events with role orchestrator are
#          left out of the stage, the totals and the unrecorded count. A null
#          tokens/tool_uses/duration_s is never printed as 0: the newest
#          event reads `tokens unrecorded`, a null tool count or duration is
#          dropped, `(+K unrecorded)` follows the total, and a scope with no
#          recorded tokens prints `total unrecorded`. The breakdown is sorted
#          by tokens descending and cut with `…` so the line stays <= 200
#          characters. Missing log or no matching events prints nothing.
#          With limits.tokens_per_issue set, ` · budget 82% of 4M` ends the line
#          at status warn or exceeded only (#383), read from `pipeline-budget.sh
#          check --issue N --json`; an empty, unparseable or `unknown` answer
#          adds nothing and never fails the line.
#   cost --issue N [--pr M] --markdown (#383) prints the body of the PR spend
#          comment: the comments.header value if set ({role} -> orchestrator),
#          `### Token spend — #N`, one table row per stage role (stage, model
#          family, runs, tokens, tool uses, duration, re-stamps, unrecorded)
#          over every event of the issue, a TOTAL row, `This PR (#M): ...`
#          (events whose pr is M), the budget line when the guard is on
#          (`Budget: 82% of 4M (warn at 80%)`, a warning mark at warn, a pause
#          notice at exceeded), the harness note and an orchestrator footnote.
#          No marker: `pipeline-vcs.sh upsert-pr-comment` adds it. Tokens and
#          duration cells are compact (`1.57M`, `2m05s`, the same formatters as
#          --line) and come from the integers `cost --json` reports; runs, tool
#          uses, re-stamps and unrecorded are exact. TOTAL is the sum of the
#          non-orchestrator rows. Role and model text from the log is stripped
#          of control characters and shown as a code span (inert: no mention,
#          link, image or comment renders). No log, or no stage event for N:
#          prints nothing, exit 0.
#   cost --summary --issue A [--issue B ...] (#383) prints the end-of-run
#          report: one row per (issue, PR) and a `pre-PR` row per issue for
#          events with pr null (issue, PR, tokens, unrecorded, stage models:
#          each stage's model in one cell, `dev sonnet · qa sonnet ×1,
#          session default ×1 · sec opus`), `Top PRs:` (up to 3), `Per issue:` totals and a `Total:`
#          line, at most 20 lines (the smallest rows fold into one `+K more
#          rows` line).
#          Orchestrator events are left out. No events: `no events recorded
#          for this run`.
#          --line, --markdown and --summary are exclusive (exit 2).
#          Both report forms need scripts/pipeline-spend-format.py; a missing
#          module prints one stderr note and nothing on stdout, exit 0.
#          Every embedded python3 here runs with -I, so a file planted in the
#          working directory (json.py) is never imported (#383). A sum that
#          overflows a float is clamped to the largest float, never Infinity.
#          A value-taking option with no value exits 2 with usage, and so
#          does an --issue or --pr value that is not digits only (#393).
#          The number, duration and role formatters --line uses live in
#          scripts/pipeline-spend-format.py, imported by explicit path; a
#          missing module prints one stderr note and an empty stdout, exit 0.
#          A token count that is not a finite non-negative number (a string,
#          boolean, negative, Infinity, NaN) is unrecorded in every cost form,
#          and --json is always strict JSON.
#
# A malformed line (not valid JSON, or not a JSON object) is skipped rather
# than aborting the read; the count of skipped lines is reported once on
# stderr, never on stdout.
#
# Never errors when the log is missing or empty -- prints nothing (list/tail)
# or an empty result, and always exits 0, except for the usage error below.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  echo "talos: pipeline-cfg-cache.sh missing; reinstall Talos" >&2
  exit 1
fi

# _talos_state_dir (#517): the one canonical resolver behind
# _events_log_path. Hard dependency, the same fail-closed pattern as
# pipeline-cfg-cache.sh above.
if [ -f "$SCRIPT_DIR/pipeline-paths.sh" ]; then
  . "$SCRIPT_DIR/pipeline-paths.sh"
else
  echo "talos: pipeline-paths.sh missing; reinstall Talos" >&2
  exit 1
fi

# _events_log_path -> prints the absolute path to the events log, or nothing
# (rc 1) if it can't be resolved. Mirrors pipeline-hooks.sh's
# _events_log_path exactly (same resolution through _talos_state_dir, same
# events.path default) -- see that copy's comment for why the GIT COMMON dir
# (#517), not the repo root or --git-dir, roots relative paths.
_events_log_path() {
  local path_cfg state
  path_cfg="$(cfg events.path)"
  case "$path_cfg" in
    /*) printf '%s' "$path_cfg"; return 0 ;;
    '') return 1 ;;
  esac
  state="$(_talos_state_dir)" || return 1
  printf '%s/%s' "$(dirname "$state")" "$path_cfg"
}

cmd_path() {
  local log_path
  log_path="$(_events_log_path)"
  if [ -z "$log_path" ]; then
    echo "pipeline-events: could not resolve the events log path (not a git repo?)" >&2
    return 1
  fi
  printf '%s\n' "$log_path"
}

# cmd_list ISSUE ROLE EVENT LAST JSON_MODE
cmd_list() {
  local issue="$1" role="$2" event="$3" last="$4" json_mode="$5"
  local log_path
  log_path="$(_events_log_path)" || {
    echo "pipeline-events: could not resolve the events log path (not a git repo?)" >&2
    return 1
  }
  if [ ! -f "$log_path" ]; then
    return 0
  fi

  python3 -I - "$log_path" "$issue" "$role" "$event" "$last" "$json_mode" <<'PYEOF'
import json
import sys

log_path, issue, role, event, last, json_mode = sys.argv[1:7]

def matches(rec):
    if issue and str(rec.get("issue")) != issue:
        return False
    if role and rec.get("role") != role:
        return False
    if event and rec.get("event") != event:
        return False
    return True

records = []
skipped = 0
with open(log_path, "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
            if not isinstance(rec, dict):
                raise ValueError("not an object")
        except (ValueError, TypeError):
            skipped += 1
            continue
        if matches(rec):
            records.append(rec)

if last:
    try:
        n = int(last)
        if n > 0:
            records = records[-n:]
    except ValueError:
        pass

for rec in records:
    if json_mode == "1":
        print(json.dumps(rec))
    else:
        summary = (rec.get("summary") or "")[:80]

        def _s(v):
            return "" if v is None else str(v)

        print("\t".join(_s(x) for x in [
            rec.get("ts"),
            rec.get("event"),
            rec.get("role"),
            rec.get("issue"),
            rec.get("pr"),
            rec.get("verdict"),
            summary,
        ]))

if skipped:
    print(f"pipeline-events: skipped {skipped} malformed line(s)", file=sys.stderr)
PYEOF
}

# _budget_json ISSUE -- the `pipeline-budget.sh check --issue ISSUE --json`
# object, or nothing (#383). The guard being off, a missing script, a crash
# and the exit code (1 = exceeded) all read as "no answer": the caller shows
# no budget, and a budget problem never fails a spend report. The budget
# script reads `cost --json` and `list --json`, never --markdown or --line,
# so this cannot recurse.
_budget_json() {
  local out
  [ -f "$SCRIPT_DIR/pipeline-budget.sh" ] || return 0
  out="$(bash "$SCRIPT_DIR/pipeline-budget.sh" check --issue "$1" --json 2>/dev/null)" || true
  printf '%s' "$out"
}

# cmd_cost ISSUE JSON_MODE -- per-(issue, role) cost summary (#202, #258,
# #259): sums tokens, tool_uses, duration_s and counts events, treating a
# null numeric field as 0 for the sum but tallying it separately in the
# unrecorded column (a group where every event is unrecorded is still
# visible as "no data", not a real zero -- e.g. adapter-path runs that
# record duration only, per #202, or a non-worktree-spawned stage whose
# harness never reports usage, per #259). The "restamp" column (#258)
# separately counts events whose verdict is RESTAMP_PASS or RESTAMP_FAIL --
# a cheap delta re-review of a PR the same role already approved (see
# skills/pipeline/SKILL.md's re-stamp dispatch) -- so a group's re-stamp
# cost is visible next to its full-stage cost instead of being folded into
# the same "events"/"tokens" totals with no way to tell them apart.
# PR (#380) keeps only events whose pr matches; "" means every event.
# MODE (#383) is "" (table / --json), "markdown" (the PR spend comment body:
# the table covers every event of ISSUE, PR only scopes the `This PR` line) or
# "summary" (the multi-issue run report over the comma-separated ISSUES). Both
# render through scripts/pipeline-spend-format.py, imported lazily.
cmd_cost() {
  local issue="$1" json_mode="$2" pr="${3:-}" mode="${4:-}" issues="${5:-}"
  local log_path budget="" header="" warn_at="0.8"
  log_path="$(_events_log_path)" || {
    echo "pipeline-events: could not resolve the events log path (not a git repo?)" >&2
    return 1
  }
  if [ ! -f "$log_path" ]; then
    [ "$mode" = "summary" ] && echo "no events recorded for this run"
    return 0
  fi
  if [ "$mode" = "markdown" ]; then
    budget="$(_budget_json "$issue")"
    # The spend report adds a header line only when comments.header is set.
    # The table's default (the `**Agent:** {role} (talos)` stage-comment
    # template) is NOT wanted here, so the unset case passes its own empty
    # fallback on purpose: the one call that keeps an explicit default (#440).
    header="$(cfg comments.header "$header")"
    warn_at="$(cfg limits.warn_at)"
  fi

  # -I: no cwd, PYTHONPATH or user site on sys.path, so a file planted in the
  # target repo (json.py) is never imported. -B: the lazily imported format
  # module leaves no __pycache__ in the install.
  python3 -I -B - "$log_path" "$issue" "$json_mode" "$pr" "$mode" "$issues" "$budget" "$header" "$warn_at" "$SCRIPT_DIR" <<'PYEOF'
import json
import math
import sys

log_path, issue, json_mode, pr, mode, issues, budget_json, header, warn_at, scripts_dir = sys.argv[1:11]
report = mode in ("markdown", "summary")
issue_set = set(issues.split(",")) if issues else set()

_MAX = sys.float_info.max

def _number(v):
    """v when it is a finite non-negative number, else None (unrecorded): a
    string, bool, negative, Infinity or NaN must neither crash the sums nor
    reach --json as a bare NaN/Infinity (#393). Values stay as recorded, so a
    valid log prints exactly as before."""
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0:
        return None
    if isinstance(v, float) and not math.isfinite(v):
        return None
    return v

def _add(a, b):
    """a + b, clamped to the largest float when the sum overflows: two valid
    1e308 values must not make --json print Infinity, and an int too big for a
    float must not crash the sum with an OverflowError (#383)."""
    try:
        s = a + b
    except OverflowError:
        return _MAX
    if isinstance(s, float) and not math.isfinite(s):
        return _MAX
    return s

def matches(rec):
    if mode == "summary":
        return str(rec.get("issue")) in issue_set
    if issue and str(rec.get("issue")) != issue:
        return False
    # markdown scopes only its `This PR` line to --pr, never the table
    if pr and mode != "markdown" and (rec.get("pr") is None or str(rec.get("pr")) != pr):
        return False
    return True

groups = {}
order = []
events = []   # (issue, pr, role, tokens or None, model) -- report modes only
skipped = 0
have_ci_runs = False
with open(log_path, "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
            if not isinstance(rec, dict):
                raise ValueError("not an object")
        except (ValueError, TypeError):
            skipped += 1
            continue
        # #550: a dispatch marker for the status line, not a finished stage.
        if rec.get("event") == "stage_start":
            continue
        if not matches(rec):
            continue
        key = (rec.get("issue"), rec.get("role"))
        if key not in groups:
            groups[key] = {"events": 0, "tokens": 0, "tool_uses": 0, "duration_s": 0, "unrecorded": 0, "restamp": 0, "ci_runs": 0}
            order.append(key)
        g = groups[key]
        g["events"] += 1
        tokens = _number(rec.get("tokens"))
        g["tokens"] = _add(g["tokens"], tokens or 0)
        g["tool_uses"] = _add(g["tool_uses"], _number(rec.get("tool_uses")) or 0)
        g["duration_s"] = _add(g["duration_s"], _number(rec.get("duration_s")) or 0)
        if tokens is None:
            g["unrecorded"] += 1
        if rec.get("verdict") in ("RESTAMP_PASS", "RESTAMP_FAIL"):
            g["restamp"] += 1
        ci_runs = rec.get("ci_runs")
        if type(ci_runs) is int and ci_runs >= 0:
            have_ci_runs = True
            g["ci_runs"] += ci_runs
        if report:
            events.append((rec.get("issue"), rec.get("pr"), rec.get("role"), tokens, rec.get("model")))

order.sort(key=lambda k: (str(k[0]), str(k[1])))

rows = []
total = {"events": 0, "tokens": 0, "tool_uses": 0, "duration_s": 0, "unrecorded": 0, "restamp": 0, "ci_runs": 0}
for key in order:
    g = groups[key]
    if not have_ci_runs:
        g.pop("ci_runs")
    rows.append({"issue": key[0], "role": key[1], **g})
    for field in g:
        # orchestrator rows (spend-guard blocks, failovers) are not stage
        # runs, so they never count as unrecorded, like in --markdown (#450)
        if field == "unrecorded" and key[1] == "orchestrator":
            continue
        total[field] = _add(total[field], g[field])

if not have_ci_runs:
    total.pop("ci_runs")

def load_format():
    """The shared formatter module, imported by explicit path; None (and one
    stderr note) when it is missing or broken: these verbs feed notifications
    and a PR comment, so they print nothing rather than fail."""
    import importlib
    sys.path.insert(0, scripts_dir)
    try:
        return importlib.import_module("pipeline-spend-format")
    except Exception as e:
        print("pipeline-events: pipeline-spend-format.py unavailable (%s); no spend report" % type(e).__name__, file=sys.stderr)
        return None

def render_markdown(fmt):
    stage_events = [e for e in events if e[2] != "orchestrator"]
    if not stage_events:
        return
    stage_rows = [r for r in rows if r["role"] != "orchestrator"]
    models = {}
    for _, _, role, _, model in stage_events:
        models.setdefault(role, []).append(model)
    tot = {"events": 0, "tokens": 0, "tool_uses": 0, "duration_s": 0, "unrecorded": 0, "restamp": 0}
    for r in stage_rows:
        for field in tot:
            tot[field] = _add(tot[field], r[field])

    def cells(*c):
        return "| " + " | ".join(str(x) for x in c) + " |"

    out = []
    if header:
        out += [header.replace("{role}", "orchestrator"), ""]
    out += ["### Token spend — #%s" % issue, "",
            cells("stage", "model", "runs", "tokens", "tool uses", "duration", "re-stamps", "unrecorded"),
            "|---|---|---:|---:|---:|---:|---:|---:|"]
    def tokens(v):
        return fmt.fmt_num(fmt.as_count(v))

    def row_tokens(r):
        # a row of runs that all reported no usage is "unrecorded", not 0
        return "unrecorded" if r["unrecorded"] == r["events"] else tokens(r["tokens"])

    def duration(v):
        return fmt.fmt_dur(fmt.as_count(v))

    # role and model come from the log: shown as code, never rendered.
    for r in stage_rows:
        out.append(cells(fmt.md_code(r["role"]), fmt.md_code(fmt.model_summary(models[r["role"]])), r["events"],
                         row_tokens(r), r["tool_uses"], duration(r["duration_s"]), r["restamp"], r["unrecorded"]))
    out.append(cells("TOTAL", "", tot["events"], tokens(tot["tokens"]), tot["tool_uses"], duration(tot["duration_s"]),
                     tot["restamp"], tot["unrecorded"]))
    if pr:
        in_pr = [e for e in stage_events if e[1] is not None and str(e[1]) == pr]
        pr_tokens, pr_unrecorded = 0, 0
        for e in in_pr:
            if e[3] is None:
                pr_unrecorded += 1
            else:
                pr_tokens = _add(pr_tokens, e[3])
        if not in_pr:
            text = "no events recorded"
        elif pr_unrecorded == len(in_pr):
            text = "unrecorded"
        else:
            text = "%s (%d tokens)" % (tokens(pr_tokens), fmt.as_count(pr_tokens))
            if pr_unrecorded:
                text += " (+%d unrecorded)" % pr_unrecorded
        out += ["", "This PR (#%s): %s" % (pr, text)]
    budget_line = fmt.fmt_budget(fmt.parse_budget(budget_json), warn_at)
    if budget_line:
        out += ["", budget_line]
    out += ["", "Tokens as reported by the harness: one total per run, no input/output split, no dollar cost; "
                "unrecorded = runs with no usage reported (adapter and pi paths)",
            "", "Orchestrator lifecycle rows (such as spend-guard blocks) are not counted in the rows or the total."]
    print("\n".join(out))

def render_summary(fmt):
    stage_events = [e for e in events if e[2] != "orchestrator"]
    if not stage_events:
        print("no events recorded for this run")
        return
    def safe(v):
        """A log value as one short token for a report line."""
        return fmt.strip_controls(str(v))[:20]

    # one row per (issue, PR), a pre-PR row per issue for the null-pr events
    rows_by = {}
    row_order = []
    for iss, p, role, tokens, model in stage_events:
        k = (safe(iss), None if p is None else safe(p))
        if k not in rows_by:
            rows_by[k] = {"tokens": 0, "unrecorded": 0, "models": {}}
            row_order.append(k)
        r = rows_by[k]
        if tokens is None:
            r["unrecorded"] += 1
        else:
            r["tokens"] = _add(r["tokens"], tokens)
        # the role comes from the log: cut to 20 chars, then reduced to [A-Za-z0-9_-]
        r["models"].setdefault(fmt.role_abbrev(safe(role)), []).append(model)

    def num_key(s):
        return (0, int(s)) if (s or "").isdigit() else (1, 0)

    # issue ascending, its PR rows in PR order, its pre-PR row last
    row_order.sort(key=lambda k: (num_key(k[0]), k[0], k[1] is None, num_key(k[1]), k[1] or ""))

    def num(v):
        return fmt.fmt_num(fmt.as_count(v))

    per_issue = {}
    grand, grand_unrecorded = 0, 0
    for k in row_order:
        r = rows_by[k]
        per_issue[k[0]] = _add(per_issue.get(k[0], 0), r["tokens"])
        grand = _add(grand, r["tokens"])
        grand_unrecorded += r["unrecorded"]

    # 5 fixed lines (title, column header, Top PRs, Per issue, Total) leave 15
    # for rows; past that the smallest rows fold into one line.
    cap = 15
    shown = row_order
    folded = ""
    if len(row_order) > cap:
        by_size = sorted(row_order, key=lambda k: -rows_by[k]["tokens"])  # stable
        keep = set(by_size[:cap - 1])
        rest = [k for k in row_order if k not in keep]
        shown = [k for k in row_order if k in keep]
        rest_tokens, rest_unrecorded = 0, 0
        for k in rest:
            rest_tokens = _add(rest_tokens, rows_by[k]["tokens"])
            rest_unrecorded += rows_by[k]["unrecorded"]
        folded = "+%d more rows: %s" % (len(rest), num(rest_tokens))
        if rest_unrecorded:
            folded += " (+%d unrecorded)" % rest_unrecorded

    def stage_models(by_role):
        """One cell: each stage and the models it ran with, first-seen order;
        past 8 stages the rest fold into `+K more`."""
        parts = ["%s %s" % (role, fmt.model_summary(ms)) for role, ms in by_role.items()]
        if len(parts) > 8:
            parts = parts[:8] + ["+%d more" % (len(parts) - 8)]
        return " · ".join(parts)

    table = [("issue", "PR", "tokens", "unrecorded", "stage models")]
    for k in shown:
        r = rows_by[k]
        table.append(("#" + k[0], "pre-PR" if k[1] is None else "#" + k[1], num(r["tokens"]),
                      str(r["unrecorded"]), stage_models(r["models"])))
    widths = [max(len(t[i]) for t in table) for i in range(4)]
    lines = ["Token spend — run summary"]
    for t in table:
        lines.append(("  ".join(t[i].ljust(widths[i]) for i in range(4)) + "  " + t[4]).rstrip())
    if folded:
        lines.append(folded)
    pr_rows = sorted((k for k in row_order if k[1] is not None), key=lambda k: -rows_by[k]["tokens"])
    lines.append("Top PRs: " + (", ".join("#%s %s" % (k[1], num(rows_by[k]["tokens"])) for k in pr_rows[:3]) or "none"))
    lines.append("Per issue: " + ", ".join("#%s %s" % (i, num(v)) for i, v in per_issue.items()))
    total_line = "Total: " + num(grand)
    if grand_unrecorded:
        total_line += " (+%d unrecorded)" % grand_unrecorded
    lines.append(total_line)
    print("\n".join(lines))

if report:
    fmt = load_format()
    if fmt is not None:
        sys.stdout.reconfigure(encoding="utf-8")
        (render_markdown if mode == "markdown" else render_summary)(fmt)
elif json_mode == "1":
    print(json.dumps({"rows": rows, "total": total}))
else:
    def _s(v):
        return "" if v is None else str(v)

    extra = ["ci_runs"] if have_ci_runs else []
    print("	".join(["issue", "role", "events", "tokens", "tool_uses", "duration_s", "unrecorded", "restamp"] + extra))
    for row in rows:
        print("	".join(_s(x) for x in [
            row["issue"], row["role"], row["events"], row["tokens"],
            row["tool_uses"], row["duration_s"], row["unrecorded"], row["restamp"],
        ] + [row[f] for f in extra]))
    print("	".join(_s(x) for x in [
        "TOTAL", "", total["events"], total["tokens"],
        total["tool_uses"], total["duration_s"], total["unrecorded"], total["restamp"],
    ] + [total[f] for f in extra]))

if skipped:
    print(f"pipeline-events: skipped {skipped} malformed line(s)", file=sys.stderr)
PYEOF
}

# cmd_cost_line ISSUE PR -- one summary line (#380): the newest
# non-orchestrator event in scope (last in file order, since ts has only
# second resolution) plus the scope's total and per-role breakdown. See the
# file header for the exact shape. Prints nothing when the log is missing or
# no event is in scope.
cmd_cost_line() {
  local issue="$1" pr="$2"
  local log_path
  log_path="$(_events_log_path)" || {
    echo "pipeline-events: could not resolve the events log path (not a git repo?)" >&2
    return 1
  }
  if [ ! -f "$log_path" ]; then
    return 0
  fi

  # The budget verdict (#383) adds ` · budget 82% of 4M` at warn / exceeded,
  # nothing otherwise; only called once the log exists.
  local budget
  budget="$(_budget_json "$issue")"

  local src
  IFS= read -r -d '' src <<'PYEOF' || true

log_path, issue, pr = sys.argv[1:4]
sys.stdout.reconfigure(encoding="utf-8")
suffix = fmt_budget_suffix(parse_budget(sys.argv[5]))
MAX_LEN = 200 - len(suffix)  # the suffix counts toward the 200

newest = None
recorded = {}
unrecorded = 0
total = 0
skipped = 0
with open(log_path, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
            if not isinstance(rec, dict):
                raise ValueError("not an object")
        except (ValueError, TypeError):
            skipped += 1
            continue
        if str(rec.get("issue")) != issue:
            continue
        if pr and (rec.get("pr") is None or str(rec.get("pr")) != pr):
            continue
        if rec.get("role") == "orchestrator":
            continue
        newest = rec
        tokens = as_count(rec.get("tokens"))
        if tokens is None:
            unrecorded += 1
        else:
            total += tokens
            label = role_label(rec.get("role"))
            recorded[label] = recorded.get(label, 0) + tokens

if skipped:
    print(f"pipeline-events: skipped {skipped} malformed line(s)", file=sys.stderr)
if newest is None:
    sys.exit(0)

parts = []
tokens = as_count(newest.get("tokens"))
parts.append("tokens unrecorded" if tokens is None else "%s tokens" % fmt_num(tokens))
tools = as_count(newest.get("tool_uses"))
if tools is not None:
    parts.append("%d tools" % tools)
dur = as_count(newest.get("duration_s"))
if dur is not None:
    parts.append(fmt_dur(dur))

head = "talos: #%s %s done — %s · %s total" % (
    pr or issue, role_label(newest.get("role")), ", ".join(parts),
    "PR" if pr else "issue")

if not recorded:
    print(head + " unrecorded" + suffix)
    sys.exit(0)

head += " " + fmt_num(total)
if unrecorded:
    head += " (+%d unrecorded)" % unrecorded
ordered = sorted(recorded.items(), key=lambda kv: -kv[1])  # stable: ties keep first-seen order
entries = ["%s %s" % (role_abbrev(r), fmt_num(n)) for r, n in ordered]
out = head + " (" + ", ".join(entries) + ")"
if len(out) > MAX_LEN:
    keep = len(entries)
    while keep > 0 and len(head + " (" + ", ".join(entries[:keep]) + ", …)") > MAX_LEN:
        keep -= 1
    out = head + " (" + "".join(e + ", " for e in entries[:keep]) + "…)"
    if len(out) > MAX_LEN:  # only a pathological role name gets here
        out = out[:MAX_LEN - 1] + "…"
print(out + suffix)
PYEOF

  # The formatters live in pipeline-spend-format.py next to this script,
  # imported lazily by explicit path (-I ignores PYTHONPATH and the script
  # dir; -B writes no __pycache__ into the install). A missing or broken
  # module prints one note and exits 0 with nothing on stdout: this verb
  # feeds notifications and must never fail one.
  python3 -I -B -c "import importlib, json, sys
sys.path.insert(0, sys.argv[4])
try:
    _m = importlib.import_module('pipeline-spend-format')
    fmt_num, fmt_dur, role_label, role_abbrev, as_count, parse_budget, fmt_budget_suffix = (
        _m.fmt_num, _m.fmt_dur, _m.role_label, _m.role_abbrev, _m.as_count,
        _m.parse_budget, _m.fmt_budget_suffix)
except Exception as e:
    print('pipeline-events: pipeline-spend-format.py unavailable (%s); no spend line' % type(e).__name__, file=sys.stderr)
    sys.exit(0)
$src" "$log_path" "$issue" "$pr" "$SCRIPT_DIR" "$budget"
}

# _usage -- the usage text, shared by the unknown-verb and bad-option exits.
_usage() {
  echo "Usage: pipeline-events.sh path" >&2
  echo "       pipeline-events.sh list [--issue N] [--role R] [--event E] [--last K] [--json]" >&2
  echo "       pipeline-events.sh tail [--issue N]" >&2
  echo "       pipeline-events.sh cost [--issue N] [--pr M] [--json]" >&2
  echo "       pipeline-events.sh cost --issue N [--pr M] --line" >&2
  echo "       pipeline-events.sh cost --issue N [--pr M] --markdown" >&2
  echo "       pipeline-events.sh cost --summary --issue A [--issue B ...]" >&2
}

# _need_value OPTION ARGC -- exit 2 with usage when a value-taking option is
# the last argument (`shift 2` with one argument left shifts nothing, which
# used to loop forever).
_need_value() {
  if [ "$2" -lt 2 ]; then
    echo "pipeline-events: $1 needs a value" >&2
    _usage
    exit 2
  fi
}

# _need_digits OPTION VALUE -- exit 2 with usage unless VALUE is one or more
# ASCII digits, so a hand-typed or hostile value never reaches a filter or a
# printed line (#393).
_need_digits() {
  case "$2" in
    ''|*[!0123456789]*)
      echo "pipeline-events: $1 must be digits only" >&2
      _usage
      exit 2
      ;;
  esac
}

VERB="${1:-}"
case "$VERB" in
  path)
    cmd_path
    ;;
  list)
    shift
    issue="" role="" event="" last="" json_mode="0"
    while [ $# -gt 0 ]; do
      case "$1" in
        --issue) _need_value "$1" $#; issue="$2"; shift 2 ;;
        --role) _need_value "$1" $#; role="$2"; shift 2 ;;
        --event) _need_value "$1" $#; event="$2"; shift 2 ;;
        --last) _need_value "$1" $#; last="$2"; shift 2 ;;
        --json) json_mode="1"; shift ;;
        *) shift ;;
      esac
    done
    cmd_list "$issue" "$role" "$event" "$last" "$json_mode"
    ;;
  tail)
    shift
    issue=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --issue) _need_value "$1" $#; issue="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cmd_list "$issue" "" "" "20" "0"
    ;;
  cost)
    shift
    issue="" pr="" json_mode="0" line_mode="0" md_mode="0" summary_mode="0" issues=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --issue) _need_value "$1" $#; _need_digits "$1" "$2"; issue="$2"; issues="${issues:+$issues,}$2"; shift 2 ;;
        --pr) _need_value "$1" $#; _need_digits "$1" "$2"; pr="$2"; shift 2 ;;
        --json) json_mode="1"; shift ;;
        --line) line_mode="1"; shift ;;
        --markdown) md_mode="1"; shift ;;
        --summary) summary_mode="1"; shift ;;
        *) shift ;;
      esac
    done
    if [ "$((line_mode + md_mode + summary_mode))" -gt 1 ]; then
      echo "pipeline-events: --line, --markdown and --summary are exclusive" >&2
      _usage
      exit 2
    fi
    if [ "$line_mode" = "1" ]; then
      if [ -z "$issue" ]; then
        echo "pipeline-events: --line needs --issue" >&2
        _usage
        exit 2
      fi
      cmd_cost_line "$issue" "$pr"
    elif [ "$md_mode" = "1" ]; then
      if [ -z "$issue" ]; then
        echo "pipeline-events: --markdown needs --issue" >&2
        _usage
        exit 2
      fi
      cmd_cost "$issue" "0" "$pr" markdown
    elif [ "$summary_mode" = "1" ]; then
      if [ -z "$issues" ]; then
        echo "pipeline-events: --summary needs at least one --issue" >&2
        _usage
        exit 2
      fi
      cmd_cost "" "0" "" summary "$issues"
    else
      cmd_cost "$issue" "$json_mode" "$pr"
    fi
    ;;
  *)
    _usage
    exit 2
    ;;
esac
