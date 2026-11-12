#!/usr/bin/env bash
# test-buzz-open-url-917.sh -- `talos-buzz.sh open-url <slug> <url>` (#917). Tests are named by the spec's id.
#   AC1 a URL on the map page (entity-escaped too) is opened: one argv element, stdin closed
#   AC2 a URL only in the entry's needs[].url is opened
#   AC3 an https URL on neither is refused: url-not-on-map
#   AC4 javascript:, file:, a space, a newline, over 2048 characters: bad-url, even on the map page
#   AC5 an unknown slug: unknown-slug
#   AC6 a failing opener: failed, exit 1
#   AC7 argc: open-url takes 3 arguments, every other verb 2
#   AC8 a successful open-url writes neither the registry nor maps/.refresh/
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

FX="$(cd "$SANDBOX" && pwd -P)/fx"
S="$FX/scripts"; BIN="$FX/bin"; OPENED="$FX/opened"; STDIN_LOG="$FX/stdin"
export TALOS_HOME="$FX/home"
trap '_is_trap_owner && _sandbox_cleanup' EXIT
mkdir -p "$S" "$BIN" "$TALOS_HOME/maps" "$FX/r1/.git"
cp "$TALOS_ROOT/scripts/talos-buzz.sh" "$S/talos-buzz.sh" 2>/dev/null || true
# talos.sh must never run for open-url: a stub that records any call.
printf '#!/usr/bin/env bash\necho called >> "%s/talos-called"\n' "$FX" > "$S/talos.sh"
# The stub opener records its argv (one line per argument) and what stdin held.
cat > "$BIN/open" <<TALOS_STUBe8Rv3NpQ5Ly
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$OPENED"
cat > "$STDIN_LOG" 2>/dev/null
[ -f "$FX/opener-fails" ] && { echo "opener: no browser" >&2; exit 3; }
echo "opener stdout"
exit 0
TALOS_STUBe8Rv3NpQ5Ly
cp "$BIN/open" "$BIN/xdg-open"
chmod +x "$S/talos.sh" "$BIN/open" "$BIN/xdg-open"
export PATH="$BIN:$PATH"

ON_MAP='https://github.com/o/r/issues/12'
ESC_URL='https://github.com/o/r/issues/12?a=1&b=2'
NEEDS_URL='https://github.com/o/r/issues/99'
OFF_MAP='https://github.com/o/r/issues/404'
LONG="https://github.com/$(python3 -I -c 'print("a" * 2100)')"
SPACE='https://github.com/o/r/issues/1 2'
NEWLINE=$'https://github.com/o/r/issues/1\n2'
cat > "$FX/fixture.py" <<'TALOS_PYm3Qd7VxK2Ts'
import json, sys
fx, longurl, space = sys.argv[1:4]
reg = {"o/r": {"file": "o-r.html", "root": fx + "/r1",
               "needs": [{"issue": 99, "url": "https://github.com/o/r/issues/99"}]}}
json.dump(reg, open(fx + "/home/maps/index.json", "w"))
hrefs = ["https://github.com/o/r/issues/12", "https://github.com/o/r/issues/12?a=1&amp;b=2",
         "javascript:alert(1)", "file:///etc/passwd", space, longurl]
html = "<!doctype html><html><body>" + "".join('<a href="%s">x</a>' % h for h in hrefs) + '<a href="#needs">n</a></body></html>\n'
open(fx + "/home/maps/o-r.html", "w").write(html)
TALOS_PYm3Qd7VxK2Ts
python3 -I "$FX/fixture.py" "$FX" "$LONG" "$SPACE"

buzz() { OUT="$(bash "$S/talos-buzz.sh" "$@" 2> "$FX/buzz.err" < /dev/null)"; RC=$?; }
opened() { cat "$OPENED" 2>/dev/null; }
reset() { : > "$OPENED"; rm -f "$STDIN_LOG" "$FX/opener-fails" "$FX/talos-called"; }
nothing_ran() { assert_eq "" "$(opened)" "$1 the opener recorded nothing"; assert_file_absent "$FX/talos-called" "$1 talos.sh was not called"; }

# ── AC1 ──────────────────────────────────────────────────────────────────────
reset
buzz open-url o/r "$ON_MAP"
assert_eq "0" "$RC" "AC1 a URL on the map page exits 0"
assert_eq "talos-buzz done opened-url" "$OUT" "AC1 it prints done opened-url"
assert_eq "$ON_MAP" "$(opened)" "AC1 the opener got exactly that URL as its only argument"
assert_eq "" "$(cat "$STDIN_LOG" 2>/dev/null)" "AC1 the opener's stdin was closed (empty)"
reset
buzz open-url o/r "$ESC_URL"
assert_eq "0" "$RC" "AC1 an href written with &amp; matches after unescape"
assert_eq "$ESC_URL" "$(opened)" "AC1 the opener got the unescaped URL"

# ── AC2 ──────────────────────────────────────────────────────────────────────
reset
buzz open-url o/r "$NEEDS_URL"
assert_eq "0" "$RC" "AC2 a URL only in needs[].url exits 0"
assert_eq "talos-buzz done opened-url" "$OUT" "AC2 it prints done opened-url"
assert_eq "$NEEDS_URL" "$(opened)" "AC2 the opener got that URL"

# ── AC3 ──────────────────────────────────────────────────────────────────────
reset
buzz open-url o/r "$OFF_MAP"
assert_eq "2" "$RC" "AC3 a URL on neither list exits 2"
assert_eq "talos-buzz error=url-not-on-map" "$OUT" "AC3 it is url-not-on-map"
nothing_ran "AC3"
buzz open-url o/r 'https://github.com/o/r/issues/1'
assert_eq "talos-buzz error=url-not-on-map" "$OUT" "AC3 a prefix of a map URL is not on the map"
buzz open-url o/r 'http://github.com/o/r/issues/12'
assert_eq "talos-buzz error=url-not-on-map" "$OUT" "AC3 http for an https href is not on the map"
nothing_ran "AC3 (more)"

# ── AC4 ──────────────────────────────────────────────────────────────────────
reset
for bad in 'javascript:alert(1)' 'file:///etc/passwd' "$SPACE" "$NEWLINE" "$LONG" '' 'ftp://github.com/o/r' 'https://github.com/o/r/issues/12 '; do
  buzz open-url o/r "$bad"
  assert_eq "2" "$RC" "AC4 '${bad:0:30}' exits 2"
  assert_eq "talos-buzz error=bad-url" "$OUT" "AC4 '${bad:0:30}' is bad-url (even when it is a map href)"
done
nothing_ran "AC4"

# ── AC5 ──────────────────────────────────────────────────────────────────────
reset
buzz open-url no/such "$ON_MAP"
assert_eq "2" "$RC" "AC5 an unknown slug exits 2"
assert_eq "talos-buzz error=unknown-slug" "$OUT" "AC5 it is unknown-slug"
nothing_ran "AC5"

# ── AC6 ──────────────────────────────────────────────────────────────────────
reset
: > "$FX/opener-fails"
buzz open-url o/r "$ON_MAP"
assert_eq "1" "$RC" "AC6 a failing opener makes open-url exit 1"
assert_contains "$OUT" "talos-buzz failed" "AC6 it reports talos-buzz failed"
case "$OUT" in *"opener stdout"*) fail "AC6 the opener's stdout is not echoed" ;; *) pass "AC6 the opener's stdout is not echoed" ;; esac

# ── AC7 ──────────────────────────────────────────────────────────────────────
reset
buzz open-url o/r
assert_eq "2" "$RC" "AC7 open-url with 2 arguments exits 2"
assert_eq "talos-buzz error=usage" "$OUT" "AC7 2 arguments is usage"
buzz open-url o/r "$ON_MAP" extra
assert_eq "2" "$RC" "AC7 open-url with 4 arguments exits 2"
assert_eq "talos-buzz error=usage" "$OUT" "AC7 4 arguments is usage"
for verb in open redraw refresh forget; do
  buzz "$verb" o/r "$ON_MAP"
  assert_eq "2" "$RC" "AC7 $verb with 3 arguments exits 2"
  assert_eq "talos-buzz error=usage" "$OUT" "AC7 $verb with 3 arguments is usage"
done
nothing_ran "AC7"

# ── AC8 ──────────────────────────────────────────────────────────────────────
reset
before="$(cksum < "$TALOS_HOME/maps/index.json")"
buzz open-url o/r "$ON_MAP"
assert_eq "0" "$RC" "AC8 fixture: the open-url succeeds"
assert_eq "$before" "$(cksum < "$TALOS_HOME/maps/index.json")" "AC8 maps/index.json is byte-identical"
assert_file_absent "$TALOS_HOME/maps/.refresh" "AC8 nothing is created under maps/.refresh/"

finish
