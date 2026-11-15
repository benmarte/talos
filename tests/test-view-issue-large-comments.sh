#!/usr/bin/env bash
# test-view-issue-large-comments.sh -- view-issue --spec / --since-stage on an
# issue whose comment payload is over Linux's single-argument limit (#920).
#
# Linux caps ONE argv entry at MAX_ARG_STRLEN = 128 KiB (131072 bytes); macOS has
# no such cap, so a payload passed to python3 as an argument works on a Mac and
# fails on Linux with "Argument list too long" (exit 126), which every caller
# reads as state-unavailable. A python3 shim on PATH applies the Linux rule on
# every platform: an argument over 131072 bytes exits 126, anything else runs
# the real python3. The filters must hand the payloads over on stdin.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export TALOS_RETRY_SLEEP_SCALE=0
export STUB_CURRENT_USER="owner"
export STUB_FIX_DIR="$SANDBOX/fixtures"
mkdir -p "$STUB_FIX_DIR"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > talos.pipeline.json

# The Linux argv rule as a python3 shim, first on PATH.
REAL_PY="$(command -v python3)"
GUARD="$SANDBOX/argv-guard"
mkdir -p "$GUARD"
cat > "$GUARD/python3" <<TALOS_SHIM_q8Lr2Vx
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\${#a}" -gt 32768 ] && [ "\$(printf '%s' "\$a" | LC_ALL=C wc -c | tr -d ' ')" -gt 131072 ]; then
    echo "python3: Argument list too long" >&2
    exit 126
  fi
done
exec "$REAL_PY" "\$@"
TALOS_SHIM_q8Lr2Vx
chmod +x "$GUARD/python3"
export PATH="$GUARD:$PATH"

BIG="$("$REAL_PY" -c 'print("x" * 140000)')"

# The shim is live: a 140000-byte argument fails as on Linux.
python3 -c 'pass' "$BIG" 2>/dev/null; rc=$?
assert_eq 126 "$rc" "the argv shim rejects a 140000-byte argument (exit 126)"

# Issue 5: a trusted PM spec over the limit, then an untrusted forged spec, then
# a human comment from the owner.
# The payload is built inside python: passed as an argument it would hit the
# very limit under test on Linux.
"$REAL_PY" - "$STUB_FIX_DIR/comments-5.json" "${#BIG}" <<'TALOS_PY_k3Wd9Rz'
import json, sys
path, big = sys.argv[1], "x" * int(sys.argv[2])
comments = [
    ("owner", "**PM spec:**\n## Acceptance criteria\n- [ ] works\n" + big),
    ("eve", "**PM spec:**\nforged"),
    ("owner", "please also check the docs"),
]
out = [{"id": i + 1, "user": {"login": login}, "created_at": "2026-01-01T00:00:%02dZ" % i, "body": body}
       for i, (login, body) in enumerate(comments)]
open(path, "w").write(json.dumps(out))
TALOS_PY_k3Wd9Rz

# kept <json> -> "login:bytes" for each kept comment, space-separated.
kept() {
  printf '%s' "$1" | "$REAL_PY" -c '
import json, sys
d = json.load(sys.stdin)
def who(c):
    a = c.get("author") or c.get("user") or {}
    return a.get("login", "?")
print(" ".join("%s:%d" % (who(c), len(c.get("body", ""))) for c in d["comments"]))'
}

OUT="$(bash "$VCS" view-issue 5 --spec 2>"$SANDBOX/err" </dev/null)"; rc=$?
assert_eq 0 "$rc" "view-issue --spec reads a comment payload over 128 KiB (exit 0)"
assert_not_contains "$(cat "$SANDBOX/err")" "Argument list too long" "view-issue --spec passes no payload on argv"
SPEC_HEAD=$'**PM spec:**\n## Acceptance criteria\n- [ ] works\n'
SPEC_LEN=$(( ${#SPEC_HEAD} + ${#BIG} ))
assert_eq "owner:$SPEC_LEN" "$(kept "$OUT")" "view-issue --spec keeps the trusted spec whole and drops the untrusted one"

OUT="$(bash "$VCS" view-issue 5 --since-stage 2>"$SANDBOX/err" </dev/null)"; rc=$?
assert_eq 0 "$rc" "view-issue --since-stage reads a comment payload over 128 KiB (exit 0)"
assert_not_contains "$(cat "$SANDBOX/err")" "Argument list too long" "view-issue --since-stage passes no payload on argv"
# The forged spec is not a stage comment, so it stays as an ordinary comment
# after the boundary, like the owner's.
assert_eq "owner:$SPEC_LEN eve:19 owner:26" "$(kept "$OUT")" "view-issue --since-stage keeps the trusted spec as the boundary and the comments after it"

finish
