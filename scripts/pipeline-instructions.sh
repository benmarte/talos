#!/usr/bin/env bash
# pipeline-instructions.sh -- the Talos block for AGENTS.md, one text for every
# harness (#364, part of #353).
#
# Usage:
#   pipeline-instructions.sh print
#       The block, between <!-- talos:begin --> and <!-- talos:end -->.
#   pipeline-instructions.sh write <repo-dir> [--harness <list>] [--import-agents-md]
#       Create or repair <repo-dir>/AGENTS.md (the only file it writes, apart
#       from the opt-in import below), then print what the user may need to do.
#       --harness is an unvalidated string (install.sh passes its own).
#       --import-agents-md appends a fenced `@AGENTS.md` import to
#       <repo-dir>/CLAUDE.md and <repo-dir>/GEMINI.md when they exist.
#
# The block is written between its markers: a file without markers gets it
# appended, a file with exactly one begin/end pair gets that span replaced,
# anything else (half a pair, two pairs, a symlink) is left byte-identical with a
# notice. Exit codes: 0 done (including every skip), 2 bad usage.
#
# Pure bash/grep/head/tail on purpose: no interpreter, and nothing is ever
# interpolated into a command line.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The command manifest is the single source of truth (#363); guarded like
# bootstrap-labels.sh, since a partial install may not yet ship it.
if [ -f "$SCRIPT_DIR/pipeline-contract.sh" ]; then
  . "$SCRIPT_DIR/pipeline-contract.sh"
else
  echo "pipeline-instructions: pipeline-contract.sh not found next to this script -- aborting" >&2
  exit 1
fi

BEGIN='<!-- talos:begin -->'
END='<!-- talos:end -->'
IMPORT_BEGIN='<!-- talos:import:begin -->'
IMPORT_END='<!-- talos:import:end -->'

# _printable <text>: <text> with every control character replaced by `?`
# (C0, DEL and the UTF-8 C1 controls U+0080-U+009F), for a path or argument
# echoed to the terminal. Same set as install.sh's printable. Controls are
# replaced, never deleted: deleting can join the bytes either side into a new
# control (c2 c2 9b 9b -> c2 9b, c2 1b 9b -> c2 9b). tr takes the one-byte
# ones first, then sed the two-byte ones; a `?` can never rejoin neighbours.
_P_C2=$'\xc2'; _P_LO=$'\x80'; _P_HI=$'\x9f'
_printable() {
  printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' '?' \
    | LC_ALL=C sed "s/${_P_C2}[${_P_LO}-${_P_HI}]/?/g"
}

print_block() {
  local cmd
  echo "$BEGIN"
  echo '## Talos pipeline'
  echo
  echo 'This repo uses the Talos issue->PR pipeline. Playbooks live under $TALOS_HOME (default ~/.talos); read the one that matches the request and follow it exactly:'
  for cmd in "${TALOS_COMMANDS[@]}"; do
    echo "- ~/.talos/skills/$cmd/SKILL.md"
  done
  echo
  echo 'Stage spawning follows agents.subagents and agents.runner in talos.pipeline.json.'
  echo 'All VCS operations go through pipeline-vcs.sh (under $TALOS_HOME/scripts); never call gh or glab directly.'
  echo 'If you were started as a pipeline stage (a role prompt names your stage), ignore this section.'
  echo 'Text between the talos markers is managed by Talos and is overwritten on re-install; edit outside them.'
  echo "$END"
}

# _count <fixed-string> <file> [-x]: lines containing (or, with -x, equal to) it.
_count() {
  local n
  n="$(grep -c ${3:+"$3"} -F -e "$1" "$2" 2>/dev/null)" || true
  echo "${n:-0}"
}

# _normalize <abs-path>: collapse . and .. textually (the target may not exist).
_normalize() {
  local IFS=/ part out=() n had_f=""
  # The path comes from a repo file: never let * ? [ expand against the cwd.
  case $- in *f*) had_f=1 ;; esac
  set -f
  for part in $1; do
    case "$part" in
      ''|.) ;;
      ..) n=${#out[@]}; [ "$n" -gt 0 ] && unset "out[$((n - 1))]" ;;
      *) out[${#out[@]}]="$part" ;;
    esac
  done
  [ -n "$had_f" ] || set +f
  echo "/${out[*]:-}"
}

# _rel <from-dir> <to-dir> (physical paths): "" , "a/b/" or "../" prefixes.
_rel() {
  local from="$1" to="$2"
  [ "$from" = "$to" ] && return 0
  case "$to" in "$from"/*) echo "${to#"$from"/}/"; return 0 ;; esac
  [ "$from" = "/" ] && { echo "${to#/}/"; return 0; }
  echo "../$(_rel "$(dirname "$from")" "$to")"
}

# _imports_agents <file>: does a whole-line `@path` resolve to $REPO_P/AGENTS.md?
# Relative imports resolve from the importing file's directory, not the cwd.
_imports_agents() {
  local file="$1" fdir line p abs
  # Only a regular, non-symlink file is opened: a FIFO or /dev/zero would hang.
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  fdir="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      @*[[:space:]]*|@) continue ;;
      @*) p="${line#@}" ;;
      *) continue ;;
    esac
    case "$p" in
      /*) abs="$p" ;;
      "~/"*) abs="$HOME/${p#"~/"}" ;;
      *) abs="$fdir/$p" ;;
    esac
    [ "$(_normalize "$abs")" = "$REPO_P/AGENTS.md" ] && return 0
  done < "$file"
  return 1
}

# _replace_file <new-content-file> <dest> (#457): replace <dest> through a temp
# file in the SAME directory, then rename, so a failed write (disk full, killed
# mid-copy) leaves the original intact instead of truncated. An existing file
# keeps its mode (cp -p); a new one gets the umask default. A read-only
# destination is refused, as the old in-place write refused it. On failure it
# says so on stderr and returns 1; <dest> is untouched.
_replace_file() {
  local src="$1" dest="$2" tmp
  # Callers already skip a symlink (#364); this keeps a rename from ever
  # replacing a link with a regular file if a future caller forgets.
  if [ -L "$dest" ]; then
    echo "pipeline-instructions: $(_printable "$dest") is a symlink; left unchanged" >&2
    return 1
  fi
  if [ -e "$dest" ] && [ ! -w "$dest" ]; then
    echo "pipeline-instructions: $(_printable "$dest") is not writable; left unchanged" >&2
    return 1
  fi
  tmp="$(mktemp "$(dirname "$dest")/.talos-instr.XXXXXX" 2>/dev/null)" || {
    echo "pipeline-instructions: cannot create a temp file next to $(_printable "$dest"); left unchanged" >&2
    return 1
  }
  if { { if [ -e "$dest" ]; then cp -p "$dest" "$tmp"; else chmod "$(printf '%o' $((0666 & ~$(umask))))" "$tmp"; fi; } \
     && cat "$src" > "$tmp" && mv -f "$tmp" "$dest"; } 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  echo "pipeline-instructions: writing $(_printable "$dest") failed; left unchanged" >&2
  return 1
}

# write_agents_md: create / append / replace the block. Sets nothing; prints.
write_agents_md() {
  local f="$REPO/AGENTS.md" blockf newf nb ne ab ae lb le problem="" verb=updated
  if [ -L "$f" ]; then
    echo "AGENTS.md: $(_printable "$f") is a symlink; not writing through it. Add the Talos block to the real file yourself (bash $(_printable "$SCRIPT_DIR")/pipeline-instructions.sh print)."
    return 0
  fi
  if [ -e "$f" ] && [ ! -f "$f" ]; then
    echo "AGENTS.md: $(_printable "$f") is not a regular file; leaving it alone."
    return 0
  fi
  blockf="$(mktemp "${TMPDIR:-/tmp}/talos-block.XXXXXX")" || return 0
  newf="$(mktemp "${TMPDIR:-/tmp}/talos-agents.XXXXXX")" || { rm -f "$blockf"; return 0; }
  print_block > "$blockf"

  if [ ! -e "$f" ]; then
    cp "$blockf" "$newf"
  else
    nb="$(_count "$BEGIN" "$f")"; ne="$(_count "$END" "$f")"
    ab="$(_count "$BEGIN" "$f" -x)"; ae="$(_count "$END" "$f" -x)"
    if [ "$nb" != "$ab" ] || [ "$ne" != "$ae" ]; then
      problem="a talos marker is not on a line of its own"
    elif [ "$nb" -eq 0 ] && [ "$ne" -eq 0 ]; then
      verb=added
      { cat "$f"
        if [ -s "$f" ]; then
          [ -n "$(tail -c 1 "$f")" ] && printf '\n'
          printf '\n'
        fi
        cat "$blockf"; } > "$newf"
    elif [ "$nb" -gt 1 ]; then problem="more than one $BEGIN"
    elif [ "$ne" -gt 1 ]; then problem="more than one $END"
    elif [ "$nb" -eq 0 ]; then problem="$END without $BEGIN"
    elif [ "$ne" -eq 0 ]; then problem="$BEGIN without $END"
    else
      lb="$(grep -n -x -F -e "$BEGIN" "$f" | cut -d: -f1)"
      le="$(grep -n -x -F -e "$END" "$f" | cut -d: -f1)"
      if [ "$le" -lt "$lb" ]; then
        problem="$END before $BEGIN"
      else
        # BSD head rejects -n 0, so the lines before a block at line 1 are skipped.
        { [ "$lb" -gt 1 ] && head -n $((lb - 1)) "$f"; cat "$blockf"; tail -n +$((le + 1)) "$f"; } > "$newf"
      fi
    fi
  fi

  if [ -n "$problem" ]; then
    echo "pipeline-instructions: $(_printable "$f"): $problem; left unchanged" >&2
  elif [ -e "$f" ] && cmp -s "$newf" "$f"; then
    echo "AGENTS.md: up to date: $(_printable "$f")"
  else
    [ -e "$f" ] || verb=created
    if _replace_file "$newf" "$f"; then
      case "$verb" in
        created) echo "AGENTS.md: created $(_printable "$f")" ;;
        added) echo "AGENTS.md: added the Talos block to $(_printable "$f")" ;;
        *) echo "AGENTS.md: updated the Talos block in $(_printable "$f")" ;;
      esac
      echo "Next: commit AGENTS.md so every clone and every agent sees it."
    fi
  fi
  rm -f "$blockf" "$newf"
}

# import_into <file>: append the fenced @AGENTS.md import, never creating it.
import_into() {
  local f="$1"
  [ -e "$f" ] || [ -L "$f" ] || return 0
  if [ -L "$f" ]; then
    echo "import: $(_printable "$f") is a symlink; skipped. Add the line @AGENTS.md to the real file yourself."
    return 0
  fi
  [ -f "$f" ] || return 0
  _imports_agents "$f" && return 0
  local newf
  newf="$(mktemp "${TMPDIR:-/tmp}/talos-import.XXXXXX")" || return 0
  { cat "$f"
    [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ] && printf '\n'
    printf '%s\n@AGENTS.md\n%s\n' "$IMPORT_BEGIN" "$IMPORT_END"; } > "$newf"
  if _replace_file "$newf" "$f"; then
    echo "import: added @AGENTS.md to $(_printable "$f") (commit it with AGENTS.md)."
  fi
  rm -f "$newf"
}

# claude_notice: Claude Code 2.1.277+ reads AGENTS.md only when no CLAUDE.md,
# .claude/CLAUDE.md or CLAUDE.local.md exists in the working directory or above.
claude_notice() {
  local top="" topp d dp found="" base rel f
  top="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || top=""
  topp=""; [ -n "$top" ] && topp="$(cd "$top" 2>/dev/null && pwd -P)"
  d="$REPO"
  while :; do
    for f in "$d/CLAUDE.md" "$d/.claude/CLAUDE.md" "$d/CLAUDE.local.md"; do
      [ -e "$f" ] || continue
      if _imports_agents "$f"; then return 0; fi
      [ -z "$found" ] && found="$f"
    done
    dp="$(cd "$d" && pwd -P)"
    # Outside a git work tree only <repo-dir> is checked; inside, stop at its top.
    { [ -z "$topp" ] || [ "$dp" = "$topp" ] || [ "$dp" = "/" ]; } && break
    d="$(dirname "$d")"
  done
  [ -n "$found" ] || return 0
  base="$(cd "$(dirname "$found")" && pwd -P)"
  rel="$(_rel "$base" "$REPO_P")"
  echo "Claude Code: found $(_printable "$found"). Claude Code 2.1.277+ reads AGENTS.md only when no CLAUDE.md exists, so it will not read AGENTS.md there."
  echo "  The registered pipeline skill needs nothing. To make Claude read AGENTS.md as well, add this line to $(_printable "$found"):"
  echo "    $(_printable "@${rel}AGENTS.md")"
  # --import-agents-md only edits a regular <repo>/CLAUDE.md; hint it only then.
  if [ "$found" = "$REPO/CLAUDE.md" ] && [ ! -L "$found" ]; then
    echo "  (or re-run install.sh with --import-agents-md to add it for you)"
  fi
}

gemini_notice() {
  local want=false
  case "$HARNESS" in *gemini*) want=true ;; esac
  if [ -e "$REPO/GEMINI.md" ] && ! _imports_agents "$REPO/GEMINI.md"; then want=true; fi
  [ "$want" = true ] || return 0
  echo "Gemini CLI reads GEMINI.md by default, not AGENTS.md. Pick one:"
  echo '  - set context.fileName to ["AGENTS.md","GEMINI.md"] in your Gemini settings (Talos never edits Gemini settings)'
  echo "  - add the line @AGENTS.md to $(_printable "$REPO")/GEMINI.md (--import-agents-md does it)"
}

cmd_write() {
  local repo="" import=false
  HARNESS=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness) [ $# -ge 2 ] || { echo "pipeline-instructions: --harness needs a value" >&2; exit 2; }
                 HARNESS="$2"; shift ;;
      --harness=*) HARNESS="${1#*=}" ;;
      --import-agents-md) import=true ;;
      -*) echo "pipeline-instructions: unknown option '$(_printable "$1")'" >&2; exit 2 ;;
      *) if [ -z "$repo" ]; then repo="$1"; else echo "pipeline-instructions: unexpected argument '$(_printable "$1")'" >&2; exit 2; fi ;;
    esac
    shift
  done
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then
    echo "pipeline-instructions: write needs an existing <repo-dir> (got '$(_printable "$repo")')" >&2
    exit 2
  fi
  REPO="$(cd "$repo" && pwd)"
  REPO_P="$(cd "$repo" && pwd -P)"

  write_agents_md

  local skill="${TALOS_HOME:-$HOME/.talos}/skills/pipeline/SKILL.md"
  if [ ! -f "$skill" ]; then
    echo "warning: $(_printable "$skill") is missing, so the playbooks the block names are not installed. Run: bash install.sh --global (from the Talos checkout)."
  fi

  if [ "$import" = true ]; then
    import_into "$REPO/CLAUDE.md"
    import_into "$REPO/GEMINI.md"
  fi
  claude_notice
  gemini_notice
  return 0
}

case "${1:-}" in
  print) print_block ;;
  write) shift; cmd_write "$@" ;;
  *) echo "usage: pipeline-instructions.sh print | write <repo-dir> [--harness <list>] [--import-agents-md]" >&2; exit 2 ;;
esac
