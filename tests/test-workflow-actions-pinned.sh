#!/usr/bin/env bash
# Every third-party `uses: <owner>/<repo>@<ref>` in the repo's workflows and in
# the CI templates must be pinned to a full 40-character commit SHA, with the
# release tag in a trailing `# v<version>` comment (#1018): a moveable tag lets
# whoever controls it decide what code runs. Checked with awk over the workflow
# text (no PyYAML). Local `./` actions and `docker://` refs are out of scope.
set -u
. "$(dirname "$0")/helpers.sh"

# uses_lines <file>: `<line>\t<value>` for each `uses:` step key, value being
# everything after `uses:` (ref plus any trailing comment).
uses_lines() {
  awk '/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]/ {
    v=$0; sub(/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/,"",v); print NR "\t" v }' "$1"
}

# is_third_party <value>: names <owner>/<repo>@<ref> (not ./ or docker://).
is_third_party() {
  case "$1" in
    ./*|docker://*) return 1 ;;
    *@*) return 0 ;;
    *) return 1 ;;
  esac
}

# bad_pins <file>: one `file:line: text` per third-party uses: not ending its
# ref in a 40-char lowercase hex SHA.
bad_pins() {
  local f="$1" n v ref
  while IFS=$'\t' read -r n v; do
    is_third_party "$v" || continue
    ref="${v#*@}"; ref="${ref%%[[:space:]#]*}"
    if ! grep -Eq '^[0-9a-f]{40}$' <<<"$ref"; then
      printf '%s:%s: uses: %s\n' "${f#"$TALOS_ROOT"/}" "$n" "$v"
    fi
  done < <(uses_lines "$f")
}

# bad_comments <file>: one `file:line: text` per third-party uses: lacking a
# trailing `# v<version>` comment.
bad_comments() {
  local f="$1" n v
  while IFS=$'\t' read -r n v; do
    is_third_party "$v" || continue
    if ! grep -Eq '[[:space:]]#[[:space:]]*v[0-9]+([.][0-9A-Za-z.-]+)*[[:space:]]*$' <<<"$v"; then
      printf '%s:%s: uses: %s\n' "${f#"$TALOS_ROOT"/}" "$n" "$v"
    fi
  done < <(uses_lines "$f")
}

FILES=()
for f in "$TALOS_ROOT"/.github/workflows/*.yml "$TALOS_ROOT"/templates/ci/*.yml; do
  [ -f "$f" ] && FILES+=("$f")
done

SHA=0123456789abcdef0123456789abcdef01234567

# Positive controls: the checks can fail, and skip what AC3 says to skip.
FIX="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
[ -n "$FIX" ] && [ -d "$FIX" ] || { echo "mktemp gave no directory" >&2; exit 1; }
cat > "$FIX/w.yml" <<YML
jobs:
  a:
    steps:
      - uses: actions/checkout@v4
      - uses: actions/checkout@$SHA
      - uses: actions/checkout@$SHA # latest
      - uses: ./.github/actions/local
      - uses: docker://alpine:3.20
        uses: actions/cache@$SHA # v4.1.0
YML
pins="$(bad_pins "$FIX/w.yml")"
cmts="$(bad_comments "$FIX/w.yml")"
rm -rf "${FIX:?}"
assert_contains "$pins" "w.yml:4:" "AC1 control: a tag ref is reported with its line"
assert_not_contains "$pins" "w.yml:5:" "AC1 control: a SHA ref passes"
assert_contains "$cmts" "w.yml:6:" "AC2 control: a non-version comment is reported"
assert_not_contains "$cmts" "w.yml:9:" "AC2 control: a # v<version> comment passes"
assert_not_contains "$pins$cmts" "w.yml:7:" "AC3 control: a local ./ action is skipped"
assert_not_contains "$pins$cmts" "w.yml:8:" "AC3 control: a docker:// ref is skipped"

if [ "${#FILES[@]}" -ge 4 ]; then
  assert_eq "ok" "ok" "AC1 the workflows and the CI template were discovered"
else
  assert_eq ">=4 files" "${#FILES[@]} files" "AC1 the workflows and the CI template were discovered"
fi

for f in "${FILES[@]}"; do
  rel="${f#"$TALOS_ROOT"/}"
  out="$(bad_pins "$f")"
  assert_eq "" "$out" "AC1 $rel: every third-party uses: is pinned to a 40-char SHA${out:+ -- $out}"
  out="$(bad_comments "$f")"
  assert_eq "" "$out" "AC2 $rel: every pinned uses: carries a # v<version> comment${out:+ -- $out}"
done

# AC4: the workflow files stay valid under actionlint when it is installed.
if command -v actionlint >/dev/null 2>&1; then
  for f in "${FILES[@]}"; do
    # -shellcheck= : the pins are the subject here, not unrelated shell style notes.
    out="$(actionlint -shellcheck= "$f" 2>&1)"; rc=$?
    assert_eq "0" "$rc" "AC4 ${f#"$TALOS_ROOT"/}: actionlint passes${out:+ ($out)}"
  done
else
  echo "  skip: actionlint not on PATH -- AC4 workflow lint not run"
fi

finish
