#!/usr/bin/env bash
# test-buzz-plugin.sh -- the Buzz plugin (#902): buzz-plugin/plugin.js, its manifest,
# its install and its docs. Tests are named by the spec's id.
#   AC1  install.sh --global writes manifest.json (allowed keys, id, host exactly)
#   AC2  the installed plugin.js has no __TALOS_HOME__ and no import
#   AC3  .install-manifest lists both files; a file dropped from the source is removed
#   AC4  a per-repo install copies no plugin
#   AC5  apply registers one primary page with a badge; the badge sums tiles.needs
#   AC6  card order, a stale entry with a confirmed Remove from list
#   AC7  at most 3 needs rows, `+K more` only above 3
#   AC8  the prepared frame HTML and the iframe sandbox
#   AC9  a file name that is not a plain page is never read; a refused line shows
#   AC10 freshness with a fake clock (open, Projects view, backoff, busy, unmount)
#   AC11 an unchanged map re-read does not replace srcdoc
#   AC12 edge states: no registry, corrupt JSON, spawn rejects, silent non-zero exit
#   AC13 no root: last map, not-redrawn message, nothing spawned
#   AC14 the docs subsection exists and the README links it
#   AC16 the plugin consumes talos-buzz.sh's documented verbs and lines as they are
#        (talos-buzz.sh itself is covered by test-buzz-entry-904.sh)
# AC15 (CHANGELOG, timings) is prose; AC17 is the owner's live check in Buzz.
# The plugin runs under node with a stand-in ctx: a minimal react, a recording
# pages.register, readFile over a temp dir and a scripted spawn.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

TALOS_ROOT="${TALOS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC_PLUGIN="$TALOS_ROOT/buzz-plugin"

# ── AC1-AC4: install ─────────────────────────────────────────────────────────
_make_src() {
  local src="$1"
  mkdir -p "$src"
  cp "$TALOS_ROOT/install.sh" "$src/install.sh"
  cp -R "$TALOS_ROOT/scripts" "$TALOS_ROOT/agents" "$TALOS_ROOT/templates" "$TALOS_ROOT/skills" "$TALOS_ROOT/buzz-plugin" "$src/" 2>/dev/null
}
_install_global() {  # <src> <home> <talos home>
  env -u PIPELINE_CONFIG HOME="$2" TALOS_HOME="$3" CLAUDE_CONFIG_DIR="$2/.claude" \
    bash "$1/install.sh" --global --no-agent-skills --no-statusline 2>&1
}

SRC="$SANDBOX/src"; H="$SANDBOX/home"; T="$SANDBOX/talos home"
mkdir -p "$H"
_make_src "$SRC"
_install_global "$SRC" "$H" "$T" >/dev/null
MF="$T/buzz-plugin/manifest.json"
assert_file_exists "$MF" "AC1 install --global writes buzz-plugin/manifest.json"
JSON_CHECK='
import json, sys
m = json.load(open(sys.argv[1]))
home = sys.argv[2]
allowed = {"id", "name", "apiVersion", "description", "discovery", "host"}
bad = set(m) - allowed
if bad: print("unknown keys %s" % sorted(bad)); sys.exit(1)
if m.get("apiVersion") != 1: print("apiVersion %r" % m.get("apiVersion")); sys.exit(1)
if m.get("id") != "talos.map": print("id %r" % m.get("id")); sys.exit(1)
if not isinstance(m.get("name"), str) or not m["name"]: print("no name"); sys.exit(1)
d = m.get("description")
if not isinstance(d, str) or not 0 < len(d) <= 280: print("description length"); sys.exit(1)
want = {"files": True, "processes": [{"id": "talos", "program": "bash", "args": [home + "/scripts/talos-buzz.sh"]}]}
if m.get("host") != want: print("host %r" % (m.get("host"),)); sys.exit(1)
print("ok")
'
OUT="$(python3 -I -c "$JSON_CHECK" "$MF" "$T" 2>&1)"
assert_eq "ok" "$OUT" "AC1 manifest.json: only allowed keys, apiVersion 1, id talos.map, host exactly the absolute talos-buzz.sh process"

PJ="$T/buzz-plugin/plugin.js"
assert_file_exists "$PJ" "AC2 install --global writes buzz-plugin/plugin.js"
if [ -f "$PJ" ] && ! grep -q '__TALOS_HOME__' "$PJ"; then pass "AC2 the installed plugin.js has no __TALOS_HOME__ left"; else fail "AC2 the installed plugin.js has no __TALOS_HOME__ left"; fi
if [ -f "$PJ" ] && grep -Fq "$T" "$PJ"; then pass "AC2 plugin.js carries the absolute TALOS_HOME"; else fail "AC2 plugin.js carries the absolute TALOS_HOME"; fi
if [ -f "$PJ" ] && ! grep -Eq '(^|[^A-Za-z0-9_])import([^A-Za-z0-9_]|$)' "$PJ"; then pass "AC2 the installed plugin.js has no import"; else fail "AC2 the installed plugin.js has no import"; fi

MAN="$T/.install-manifest"
assert_contains "$(cat "$MAN" 2>/dev/null)" "buzz-plugin/plugin.js" "AC3 .install-manifest lists buzz-plugin/plugin.js"
assert_contains "$(cat "$MAN" 2>/dev/null)" "buzz-plugin/manifest.json" "AC3 .install-manifest lists buzz-plugin/manifest.json"

printf '// extra\nexport const x = 1;\n' > "$SRC/buzz-plugin/extra.js"
_install_global "$SRC" "$H" "$T" >/dev/null
assert_file_exists "$T/buzz-plugin/extra.js" "AC3 fixture: a second source file in buzz-plugin/ is installed"
printf 'mine\n' > "$T/buzz-plugin/mine.txt"
rm -f "$SRC/buzz-plugin/extra.js"
_install_global "$SRC" "$H" "$T" >/dev/null
if [ -f "$MAN" ] && grep -Fxq "buzz-plugin/plugin.js" "$MAN" && [ ! -e "$T/buzz-plugin/extra.js" ]; then
  pass "AC3 a file dropped from buzz-plugin/ in the source is removed on the next install"
else
  fail "AC3 a file dropped from buzz-plugin/ in the source is removed on the next install"
fi
assert_file_exists "$T/buzz-plugin/mine.txt" "AC3 a file the installer never listed survives"
assert_file_exists "$PJ" "AC3 the plugin itself survives the next install"

REPO="$SANDBOX/repo"; H2="$SANDBOX/home2"
mkdir -p "$REPO" "$H2"
env -u TALOS_HOME HOME="$H2" bash "$SRC/install.sh" "$REPO" --no-agent-skills >/dev/null 2>&1
FOUND="$(find "$REPO" "$H2" -iname '*buzz*' 2>/dev/null)"
assert_eq "" "$FOUND" "AC4 a per-repo install copies no plugin"

# ── AC5-AC13: the plugin under node ──────────────────────────────────────────
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 18 ]; then
  echo "  skip  AC5-AC13: node >= 18 is not on PATH"
else
  WORK="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-buzzplugin.XXXXXX")" || exit 1
  trap '_is_trap_owner && { rm -rf "${WORK:?}"; _sandbox_cleanup; }' EXIT
  cat > "$WORK/harness.mjs" <<'TALOS_NODE_HARNESS_7Q2K'
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [pluginFile, work] = process.argv.slice(2);
const HOME = path.join(work, "home");
const rendered = path.join(work, "plugin.rendered.mjs");
fs.writeFileSync(rendered, fs.readFileSync(pluginFile, "utf8").split("__TALOS_HOME__").join(HOME));
const P = await import(pathToFileURL(rendered).href);

// ── tiny test runner ────────────────────────────────────────────────────────
const tests = [];
const test = (label, fn) => tests.push([label, fn]);
const check = (cond, detail) => { if (!cond) throw new Error(detail || "assertion failed"); };
const eq = (got, want, what) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    throw new Error((what ? what + ": " : "") + "expected " + JSON.stringify(want) + " got " + JSON.stringify(got));
  }
};
const unhandled = [];
const allSpawns = []; // every process any test world spawned (AC16)
process.on("unhandledRejection", (e) => unhandled.push(String(e && e.message || e)));
const settle = async (n = 30) => { for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r)); };

// ── tree helpers ────────────────────────────────────────────────────────────
const walk = (n, f) => { if (n && typeof n === "object") { f(n); for (const c of n.children || []) walk(c, f); } };
const all = (tree, pred) => { const r = []; walk(tree, (n) => { if (pred(n)) r.push(n); }); return r; };
const textOf = (n) => (n == null || n === false ? "" : typeof n === "object" ? (n.children || []).map(textOf).join("") : String(n));
const cards = (tree) => all(tree, (n) => n.props && n.props["data-slug"]);
const buttonsIn = (tree, label) => all(tree, (n) => n.type === "button" && textOf(n).trim() === label);
const iframeOf = (tree) => all(tree, (n) => n.type === "iframe")[0];
const click = (btn) => btn.props.onClick({ target: { closest: () => null } });

// ── fixtures ────────────────────────────────────────────────────────────────
const MIN = 60e3, HOUR = 3600e3, DAY = 86400e3;
const NOW = Date.parse("2026-11-11T12:00:00Z");
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d+Z$/, "Z");
const mapHtml = (marker) => '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="60">' +
  '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">' +
  "<title>Talos · " + marker + "</title><style>body{margin:0}</style></head><body><div class=\"wrap\">" + marker + " — é ✓</div></body></html>\n";

function entry(slug, o = {}) {
  return {
    file: o.file === undefined ? slug + ".html" : o.file,
    updated: iso(NOW - (o.updatedAgo === undefined ? HOUR : o.updatedAgo)),
    line: "1 merged",
    provider: o.provider || "github",
    ...(o.noRoot ? {} : { root: "/work/" + slug }),
    tiles: { needs: o.needs || 0, in_flight: o.inFlight || 0, queued: 0, merged_7d: 2, tokens_7d: 10 },
    needs: o.rows || [],
    run: o.run || { going: false, lanes: 0 },
    state_read: o.readAgo === null ? null : iso(NOW - (o.readAgo === undefined ? 10 * MIN : o.readAgo)),
  };
}
const row = (n) => ({ issue: n, title: "Issue " + n, kind: "blocked", since: iso(NOW - 3 * HOUR), why: "why " + n, next: "next " + n, url: "https://github.com/o/r/issues/" + n });

function makeClock() {
  let t = NOW, id = 0;
  const iv = new Map();
  return {
    now: () => t,
    setInterval(fn, ms) { const k = ++id; iv.set(k, { fn, ms, next: t + ms }); return k; },
    clearInterval(k) { iv.delete(k); },
    async advance(ms) {
      const end = t + ms;
      for (;;) {
        let best = null;
        for (const v of iv.values()) if (v.next <= end && (!best || v.next < best.next)) best = v;
        if (!best) break;
        t = best.next; best.next += best.ms; best.fn();
        await settle(4);
      }
      t = end;
      await settle();
    },
  };
}

// A world: temp TALOS_HOME with maps/, a scripted host, a fake clock, a mounted page.
async function world(o = {}) {
  fs.rmSync(HOME, { recursive: true, force: true });
  fs.mkdirSync(path.join(HOME, "maps", ".refresh"), { recursive: true });
  const w = { reads: [], spawns: [], inflight: 0, maxInflight: 0, clock: makeClock(), registered: [], errors: [] };
  const write = (name, text) => fs.writeFileSync(path.join(HOME, "maps", name), text);
  w.write = write;
  if (o.registryText !== undefined) write("index.json", o.registryText);
  else if (o.entries) write("index.json", JSON.stringify(o.entries));
  for (const slug of Object.keys(o.entries || {})) {
    const f = o.entries[slug].file;
    if (typeof f === "string" && /^[A-Za-z0-9._-]+\.html$/.test(f) && !(o.noMapFor || []).includes(slug)) write(f, mapHtml(slug));
  }
  for (const [name, rec] of Object.entries(o.records || {})) write(".refresh/" + name + ".json", JSON.stringify(rec));
  const replies = o.replies || {};
  w.host = {
    async readFile(p) {
      w.reads.push(p);
      if (o.readFileThrows) throw new Error(o.readFileThrows);
      try { return new Uint8Array(fs.readFileSync(p)); } catch (e) { throw new Error("No such file or directory (os error 2): " + p); }
    },
    spawn(id, opts) {
      if (o.spawnThrows) throw new Error(o.spawnThrows);
      const s = { id, args: opts.args, killed: false };
      s.exited = new Promise((res, rej) => { s.exit = res; s.fail = rej; });
      s.say = (line) => opts.onStdout(new TextEncoder().encode(line + "\n"));
      s.kill = () => { s.killed = true; s.exit(null); };
      s.write = () => {}; s.end = () => {};
      w.inflight++; w.maxInflight = Math.max(w.maxInflight, w.inflight);
      s.exited.then(() => { w.inflight--; }, () => { w.inflight--; });
      w.spawns.push(s);
      allSpawns.push(s);
      const reply = replies[s.args[0]];
      if (o.rejectExited) setImmediate(() => s.fail(new Error(o.rejectExited)));
      else if (reply) setImmediate(() => { for (const l of reply.lines || []) s.say(l); s.exit(reply.rc === undefined ? 0 : reply.rc); });
      return s;
    },
  };
  const store = new Map();
  if (o.last) store.set("talos.map.last", o.last);
  w.storage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => { store.set(k, String(v)); }, removeItem: (k) => { store.delete(k); } };
  w.R = reactFor(w);
  const ctx = { react: w.R.React, pages: { register: (r) => { if (o.registerThrows) throw new Error("register boom"); w.registered.push(r); } }, host: w.host };
  const apply = () => P.apply(ctx, { now: w.clock.now, setInterval: w.clock.setInterval, clearInterval: w.clock.clearInterval, storage: w.storage, visible: () => true, theme: () => o.theme || "dark" });
  w.apply = apply;
  return w;
}
// One shared React whose hooks serve whichever root is rendering.
function reactFor(w) {
  let current = null;
  const React = {
    createElement(type, props, ...children) { return { type, props: props || {}, children: children.flat(Infinity) }; },
    useState(init) { return current.useState(init); },
    useEffect(fn, deps) { return current.useEffect(fn, deps); },
  };
  return {
    React,
    mount(Component) {
      const hooks = [];
      let idx = 0, tree = null, effects = [], scheduled = false, dead = false;
      const api = {
        useState(init) {
          const i = idx++;
          if (!(i in hooks)) hooks[i] = { v: typeof init === "function" ? init() : init };
          const slot = hooks[i];
          return [slot.v, (nv) => { slot.v = typeof nv === "function" ? nv(slot.v) : nv; schedule(); }];
        },
        useEffect(fn, deps) {
          const i = idx++;
          const prev = hooks[i];
          if (!prev || !deps || deps.length !== prev.deps.length || deps.some((d, j) => d !== prev.deps[j])) {
            effects.push(() => {
              if (prev && prev.cleanup) prev.cleanup();
              const c = fn();
              hooks[i] = { deps, cleanup: typeof c === "function" ? c : null };
            });
          } else hooks[i] = prev;
        },
      };
      function render() {
        scheduled = false;
        if (dead) return;
        const saved = current;
        current = api; idx = 0; effects = [];
        try { tree = Component({}); } finally { current = saved; }
        const run = effects; effects = [];
        current = api;
        try { for (const e of run) e(); } finally { current = saved; }
      }
      function schedule() { if (!scheduled && !dead) { scheduled = true; Promise.resolve().then(render); } }
      render();
      return { get tree() { return tree; }, unmount() { dead = true; for (const h of hooks) if (h && h.cleanup) h.cleanup(); } };
    },
  };
}
async function mountPage(w) {
  w.apply();
  const reg = w.registered[0];
  w.page = w.R.mount(reg.component);
  await settle();
  return reg;
}
const page = (w) => w.page.tree;
const pageText = (w) => textOf(page(w));

// ── AC5 ─────────────────────────────────────────────────────────────────────
test("AC5 apply registers exactly one primary page with a badge", async () => {
  const w = await world({ entries: { a: entry("a", { needs: 2 }) } });
  w.apply();
  eq(w.registered.length, 1, "registrations");
  const r = w.registered[0];
  check(r.primary === true, "primary is not true");
  check(typeof r.badge === "function", "no badge component");
  check(typeof r.component === "function", "no page component");
  check(typeof r.id === "string" && r.id === r.id.toLowerCase(), "id is not a lowercase string");
});

test("AC5 the badge renders the sum of tiles.needs over the registry, nothing at 0", async () => {
  const w = await world({ entries: { a: entry("a", { needs: 2 }), b: entry("b", { needs: 3 }), c: entry("c") } });
  w.apply();
  let b = w.R.mount(w.registered[0].badge);
  await settle();
  eq(textOf(b.tree).trim(), "5", "badge text");
  b.unmount();
  const z = await world({ entries: { a: entry("a"), b: entry("b") } });
  z.apply();
  b = z.R.mount(z.registered[0].badge);
  await settle();
  check(b.tree === null || textOf(b.tree).trim() === "", "badge shows something at 0: " + JSON.stringify(b.tree));
  b.unmount();
});

// ── AC6, AC7 ────────────────────────────────────────────────────────────────
const four = () => ({
  delta: entry("delta", { updatedAgo: 15 * DAY }),
  gamma: entry("gamma", { updatedAgo: 5 * HOUR }),
  beta: entry("beta", { updatedAgo: 1 * HOUR, run: { going: true, lanes: 1, issue: 12, role: "developer", stage_since: iso(NOW - 5 * MIN) } }),
  alpha: entry("alpha", { updatedAgo: 2 * DAY, needs: 4, rows: [row(1), row(2), row(3)] }),
});
test("AC6 card order is needs-you, then running, then the rest by updated newest first", async () => {
  const w = await world({ entries: four() });
  await mountPage(w);
  eq(cards(page(w)).map((c) => c.props["data-slug"]), ["alpha", "beta", "gamma", "delta"]);
  eq(P.orderEntries(four(), NOW).map((x) => x[0]), ["alpha", "beta", "gamma", "delta"], "orderEntries");
  check(pageText(w).includes("Running · developer on #12 · 5 min"), "run pill missing: " + pageText(w).slice(0, 300));
  check(pageText(w).includes("Idle · map 5 h old"), "idle pill missing");
});

test("AC6 a 15-day-old entry is stale with a Remove from list button that confirms in the card", async () => {
  const w = await world({ entries: four() });
  await mountPage(w);
  const by = (s) => cards(page(w)).find((c) => c.props["data-slug"] === s);
  eq(by("delta").props["data-stale"], "true");
  eq(by("gamma").props["data-stale"], "false");
  check(textOf(by("delta")).includes("Not updated in 15 days"), "stale pill missing");
  eq(buttonsIn(by("gamma"), "Remove from list").length, 0, "fresh card has a Remove button");
  const rm = buttonsIn(by("delta"), "Remove from list");
  eq(rm.length, 1, "stale card Remove buttons");
  click(rm[0]);
  await settle();
  eq(w.spawns.filter((s) => s.args[0] === "forget").length, 0, "forget spawned before the confirm");
  check(buttonsIn(by("delta"), "Remove").length === 1 && buttonsIn(by("delta"), "Cancel").length === 1, "no confirm step in the card");
  click(buttonsIn(by("delta"), "Remove")[0]);
  await settle();
  const f = w.spawns.filter((s) => s.args[0] === "forget");
  eq(f.length, 1, "forget spawns");
  eq(f[0].args, ["forget", "delta"]);
  eq(f[0].id, "talos");
});

test("AC7 a card shows at most 3 needs rows and +K more only above 3", async () => {
  const w = await world({ entries: {
    big: entry("big", { needs: 6, rows: [row(1), row(2), row(3), row(4)], updatedAgo: HOUR }),
    three: entry("three", { needs: 3, rows: [row(5), row(6), row(7)], updatedAgo: 2 * HOUR }),
    one: entry("one", { needs: 1, rows: [row(8)], updatedAgo: 3 * HOUR }),
  } });
  await mountPage(w);
  const by = (s) => cards(page(w)).find((c) => c.props["data-slug"] === s);
  const rows = (c) => all(c, (n) => n.type === "a");
  eq(rows(by("big")).length, 3, "big rows");
  check(textOf(by("big")).includes("+3 more · open map →"), "no +3 more: " + textOf(by("big")));
  eq(rows(by("three")).length, 3, "three rows");
  check(!textOf(by("three")).includes("more"), "+K more on a 3-need card");
  check(!textOf(by("one")).includes("more"), "+K more on a 1-need card");
  eq(rows(by("one"))[0].props.href, "https://github.com/o/r/issues/8", "row link");
});

// ── AC8 ─────────────────────────────────────────────────────────────────────
test("AC8 the prepared frame HTML: no refresh, no base, data-theme, otherwise identical", async () => {
  const src = mapHtml("x");
  const out = P.prepareFrame(src, "dark");
  check(!/http-equiv=["']?refresh/i.test(out), "refresh meta left");
  check(!/<base\b/i.test(out), "a base element was added");
  check(out.includes('<html lang="en" data-theme="dark">'), "data-theme: " + out.slice(0, 80));
  const back = out.replace(' data-theme="dark"', "");
  eq(back, src.replace('<meta http-equiv="refresh" content="60">', ""), "the rest of the file");
  check(P.prepareFrame(src, "light").includes('data-theme="light"'), "light theme");
  check(P.prepareFrame(P.prepareFrame(src, "dark"), "light").includes('data-theme="light"'), "a second prepare switches the theme");
  eq(P.themeFromColor("rgb(20, 20, 24)", false), "dark");
  eq(P.themeFromColor("#fafafa", true), "light");
  eq(P.themeFromColor("", true), "dark", "falls back to prefers-color-scheme");
});

test("AC8 the iframe sandbox is exactly allow-same-origin and carries the prepared map", async () => {
  const w = await world({ entries: { p: entry("p") }, last: "p", theme: "dark" });
  await mountPage(w);
  const f = iframeOf(page(w));
  check(f, "no iframe in the project view");
  eq(f.props.sandbox, "allow-same-origin");
  eq(f.props.srcDoc, P.prepareFrame(mapHtml("p"), "dark"), "srcDoc");
});

// ── AC9 ─────────────────────────────────────────────────────────────────────
test("AC9 a file of ../x.html, a/b.html or x.js is never read and a refused line shows", async () => {
  for (const bad of ["../x.html", "a/b.html", "x.js"]) {
    const w = await world({ entries: { ok: entry("ok", { updatedAgo: HOUR }), bad: entry("bad", { file: bad, updatedAgo: 2 * HOUR }) } });
    await mountPage(w);
    const open = all(cards(page(w)).find((c) => c.props["data-slug"] === "bad"), (n) => n.type === "button" && textOf(n) === "bad")[0];
    click(open);
    await settle();
    check(/refused/i.test(pageText(w)), "no refused line for " + bad + ": " + pageText(w).slice(0, 200));
    check(!iframeOf(page(w)), "a frame for " + bad);
    const base = bad.split("/").pop();
    check(!w.reads.some((p) => path.basename(p) === base || p.split("/").includes("..")), "readFile saw " + bad + ": " + JSON.stringify(w.reads));
  }
  // control: the recorder sees the registry read and a valid file read.
  const w = await world({ entries: { ok: entry("ok") }, last: "ok" });
  await mountPage(w);
  check(w.reads.some((p) => p.endsWith("/maps/index.json")), "control: index.json read not recorded");
  check(w.reads.some((p) => p.endsWith("/maps/ok.html")), "control: ok.html read not recorded");
});

// ── AC10 ────────────────────────────────────────────────────────────────────
const AUTO = { redraw: { lines: ["talos-buzz phase=render", "talos-buzz done map=/m/p.html"] }, refresh: { lines: ["talos-buzz phase=reading", "talos-buzz done map=/m/p.html"] } };
test("AC10 opening a project spawns redraw then refresh when state_read is 2 h old", async () => {
  const w = await world({ entries: { p: entry("p", { readAgo: 2 * HOUR }) }, last: "p", replies: AUTO });
  await mountPage(w);
  await settle();
  eq(w.spawns.map((s) => s.args), [["redraw", "p"], ["refresh", "p"]]);
});
test("AC10 opening a project spawns only redraw when state_read is 10 min old", async () => {
  const w = await world({ entries: { p: entry("p", { readAgo: 10 * MIN }) }, last: "p", replies: AUTO });
  await mountPage(w);
  await settle();
  eq(w.spawns.map((s) => s.args), [["redraw", "p"]]);
});
test("AC10 opening a project with a null state_read spawns redraw then refresh", async () => {
  const w = await world({ entries: { p: entry("p", { readAgo: null }) }, last: "p", replies: AUTO });
  await mountPage(w);
  eq(w.spawns.map((s) => s.args), [["redraw", "p"], ["refresh", "p"]]);
});
test("AC10 the Projects view refreshes stale projects one at a time", async () => {
  const w = await world({ entries: { a: entry("a", { readAgo: 2 * HOUR, updatedAgo: HOUR }), b: entry("b", { readAgo: 3 * HOUR, updatedAgo: 2 * HOUR }), c: entry("c", { readAgo: 5 * HOUR, updatedAgo: 3 * HOUR }), d: entry("d", { readAgo: 5 * MIN, updatedAgo: 4 * HOUR }) } });
  await mountPage(w);
  eq(w.spawns.map((s) => s.args), [["refresh", "a"]], "first");
  w.spawns[0].say("talos-buzz phase=reading");
  await settle();
  check(pageText(w).includes("Reading GitHub…"), "no reading footer: " + pageText(w).slice(0, 300));
  check(pageText(w).includes("refresh queued"), "no refresh queued footer");
  w.spawns[0].say("talos-buzz done map=/m/a.html"); w.spawns[0].exit(0);
  await settle();
  eq(w.spawns.map((s) => s.args.join(" ")), ["refresh a", "refresh b"], "second");
  w.spawns[1].exit(0);
  await settle();
  w.spawns[2].exit(0);
  await settle();
  eq(w.spawns.map((s) => s.args.join(" ")), ["refresh a", "refresh b", "refresh c"], "all three, none for the fresh one");
  eq(w.maxInflight, 1, "max processes at once");
});
const FAIL_AUTH = { refresh: { lines: ["talos-buzz phase=reading", "talos-buzz failed reason=auth detail=gh: not logged in"], rc: 1 }, redraw: AUTO.redraw };
test("AC10 after a failed reason=auth no automatic refresh runs for 15 min, a manual one does", async () => {
  const w = await world({ entries: { p: entry("p", { readAgo: 2 * HOUR }) }, last: "p", replies: FAIL_AUTH });
  await mountPage(w);
  await settle();
  eq(w.spawns.map((s) => s.args[0]), ["redraw", "refresh"], "first open");
  check(pageText(w).includes("gh auth login"), "no login hint: " + pageText(w).slice(0, 400));
  await w.clock.advance(60e3);
  click(buttonsIn(page(w), "← Projects")[0]);
  await settle();
  const open = () => click(all(cards(page(w))[0], (n) => n.type === "button" && textOf(n) === "p")[0]);
  open();
  await settle();
  eq(w.spawns.filter((s) => s.args[0] === "refresh").length, 1, "an automatic refresh ran inside 15 min");
  await w.clock.advance(16 * MIN);
  click(buttonsIn(page(w), "← Projects")[0]);
  await settle();
  check(w.spawns.filter((s) => s.args[0] === "refresh").length >= 2, "no automatic refresh after 15 min: " + JSON.stringify(w.spawns.map((s) => s.args)));
  // manual: a fresh failure, then Refresh at once.
  const m = await world({ entries: { p: entry("p", { readAgo: 2 * HOUR }) }, last: "p", replies: FAIL_AUTH });
  await mountPage(m);
  await settle();
  const before = m.spawns.length;
  const btn = buttonsIn(page(m), "Refresh")[0];
  check(btn && !btn.props.disabled, "Refresh is disabled after a failure");
  click(btn);
  await settle();
  check(m.spawns.length > before && m.spawns.some((s, i) => i >= before && s.args[0] === "refresh"), "a manual Refresh did not run: " + JSON.stringify(m.spawns.map((s) => s.args)));
});
test("AC10 a failed refresh record also pauses automatic refreshes", async () => {
  const w = await world({ entries: { p: entry("p", { readAgo: 2 * HOUR }) }, last: "p", replies: AUTO,
    records: { "p.html": { started: iso(NOW - 8 * MIN), finished: iso(NOW - 5 * MIN), ok: false, reason: "network", detail: "dns" } } });
  await mountPage(w);
  await settle();
  eq(w.spawns.map((s) => s.args[0]), ["redraw"], "spawns with a failed record 5 min old");
});
test("AC10 a busy line causes no retry", async () => {
  const w = await world({ entries: { p: entry("p", { readAgo: 2 * HOUR }) }, last: "p", replies: { redraw: AUTO.redraw, refresh: { lines: ["talos-buzz busy since=" + iso(NOW - 20e3)] } } });
  await mountPage(w);
  await settle();
  eq(w.spawns.map((s) => s.args[0]), ["redraw", "refresh"]);
  check(pageText(w).includes("Reading GitHub… The map updates by itself"), "no already-reading line after the busy line");
  await w.clock.advance(120e3);
  eq(w.spawns.map((s) => s.args[0]), ["redraw", "refresh"], "after 2 min");
  check(pageText(w).includes("Still reading."), "the spinner went away while another process is reading");
});
test("AC10 spawned processes are killed on unmount", async () => {
  const w = await world({ entries: { p: entry("p", { readAgo: 2 * HOUR }) }, last: "p" });
  await mountPage(w);
  eq(w.spawns.length, 1);
  w.page.unmount();
  await settle();
  check(w.spawns[0].killed, "the redraw process was not killed");
});
test("UX the open project is remembered and a refresh shows its progress lines", async () => {
  const w = await world({ entries: { p: entry("p", { readAgo: 2 * HOUR }), q: entry("q", { updatedAgo: 2 * HOUR }) }, replies: { redraw: AUTO.redraw } });
  await mountPage(w);
  click(all(cards(page(w)).find((c) => c.props["data-slug"] === "p"), (n) => n.type === "button" && textOf(n) === "p")[0]);
  await settle();
  eq(w.storage.getItem("talos.map.last"), "p", "remembered");
  w.page.unmount();
  const again = w.R.mount(w.registered[0].component);
  await settle();
  check(iframeOf(again.tree), "the page did not reopen the last project");
  const s = w.spawns.find((x) => x.args[0] === "refresh");
  check(s, "no refresh spawned");
  s.say("talos-buzz phase=reading");
  await settle();
  check(textOf(again.tree).includes("The map updates by itself when it's done."), "no progress line");
  check(all(again.tree, (n) => n.props && n.props.role === "progressbar").length === 1, "no progress bar");
  await w.clock.advance(125e3);
  check(textOf(again.tree).includes("Still reading. It keeps going in the background; you can leave this page."), "no long-read line");
});

// ── AC11 ────────────────────────────────────────────────────────────────────
test("AC11 an unchanged map re-read does not replace srcdoc, a changed one does", async () => {
  const w = await world({ entries: { p: entry("p", { readAgo: 10 * MIN }) }, last: "p", replies: AUTO });
  await mountPage(w);
  const first = iframeOf(page(w)).props.srcDoc;
  const store = P.createStore({ host: w.host, now: w.clock.now, setInterval: w.clock.setInterval, clearInterval: w.clock.clearInterval, storage: w.storage, theme: () => "dark" });
  store.state.mounted = true;
  await store.loadRegistry();
  await store.openProject("p");
  await settle();
  eq(store.proj("p").swaps, 1, "swaps after the first load");
  await w.clock.advance(30e3);
  eq(iframeOf(page(w)).props.srcDoc, first, "srcDoc after an unchanged poll");
  check(w.reads.filter((p) => p.endsWith("/maps/p.html")).length >= 3, "the map was not re-read");
  await store.openProject("p");
  await settle();
  eq(store.proj("p").swaps, 1, "swaps after an unchanged re-read");
  w.write("p.html", mapHtml("changed"));
  await w.clock.advance(30e3);
  const after = iframeOf(page(w)).props.srcDoc;
  check(after !== first && after.includes("changed"), "srcDoc did not change with the map");
  await store.openProject("p");
  await settle();
  eq(store.proj("p").swaps, 2, "swaps after a changed re-read");
});

// ── AC12 ────────────────────────────────────────────────────────────────────
test("AC12 no registry shows the empty message", async () => {
  const w = await world({});
  await mountPage(w);
  check(pageText(w).includes("No Talos projects on this Mac yet. Run `talos.sh map` in a repo, or start a Talos run there."), pageText(w));
});
test("AC12 a corrupt registry shows one error line and Refresh all stays", async () => {
  const w = await world({ registryText: "{not json" });
  await mountPage(w);
  check(pageText(w).includes("Couldn't read the Talos project list"), pageText(w));
  eq(buttonsIn(page(w), "Refresh all").length, 1, "Refresh all");
  const b = await world({ registryText: "[1,2]" });
  await mountPage(b);
  check(pageText(b).includes("Couldn't read the Talos project list"), "a non-object registry");
  const r = await world({ entries: { a: entry("a") }, readFileThrows: "permission denied" });
  await mountPage(r);
  check(pageText(r).includes("permission denied"), "an unreadable registry");
});
test("AC12 a spawn that throws, or whose exited rejects, shows its message", async () => {
  for (const [opt, word] of [[{ spawnThrows: "no such process" }, "no such process"], [{ rejectExited: "pipe closed" }, "pipe closed"]]) {
    const w = await world({ entries: { p: entry("p", { readAgo: 2 * HOUR }) }, last: "p", ...opt });
    await mountPage(w);
    await settle();
    const text = pageText(w);
    check(text.includes(word) && /Couldn't/.test(text), "no message for " + word + ": " + text.slice(0, 400));
    check(iframeOf(page(w)), "the last map vanished for " + word);
  }
});
test("AC12 a spawn that exits non-zero with no output shows a message", async () => {
  const w = await world({ entries: { p: entry("p", { readAgo: 2 * HOUR }) }, last: "p", replies: { redraw: { lines: [], rc: 3 }, refresh: { lines: [], rc: 1 } } });
  await mountPage(w);
  await settle();
  const text = pageText(w);
  check(text.includes("printed nothing"), "no message: " + text.slice(0, 400));
  check(iframeOf(page(w)), "the last map vanished");
});
test("AC12 nothing throws out of apply, a component or an unhandled rejection", async () => {
  const w = await world({ entries: { p: entry("p") }, registerThrows: true });
  w.apply();
  const bad = { react: null, pages: null, host: null };
  P.apply(bad);
  P.apply(undefined);
  const e = await world({ registryText: '{"p": 5, "q": {"tiles": "x", "needs": "y", "file": 7}}' });
  await mountPage(e);
  const reg = e.registered[0];
  const b = e.R.mount(reg.badge);
  await settle();
  check(b.tree === null || typeof b.tree === "object", "badge");
  check(unhandled.length === 0, "unhandled rejections: " + unhandled.join("; "));
});

// ── AC13 ────────────────────────────────────────────────────────────────────
test("AC13 an entry with no root shows the last map and the not-redrawn message, spawns nothing", async () => {
  const w = await world({ entries: { old: entry("old", { noRoot: true, readAgo: 3 * HOUR }) }, last: "old", replies: AUTO });
  await mountPage(w);
  await settle();
  check(iframeOf(page(w)), "no last map");
  check(pageText(w).includes("Talos hasn't redrawn this project since the update. It will at its next stage, or run `talos.sh map` in the repo once."), "no message: " + pageText(w).slice(0, 300));
  check(buttonsIn(page(w), "Refresh")[0].props.disabled === true, "Refresh is enabled");
  await w.clock.advance(60e3);
  eq(w.spawns.length, 0, "spawns for a project with no root");
  click(buttonsIn(page(w), "← Projects")[0]);
  await settle();
  check(textOf(cards(page(w))[0]).includes("hasn't redrawn this project"), "the card has no message");
  click(buttonsIn(page(w), "Refresh all")[0]);
  await settle();
  eq(w.spawns.length, 0, "Refresh all spawned for a project with no root");
});

// ── AC16 ────────────────────────────────────────────────────────────────────
test("AC16 the plugin consumes talos-buzz.sh's documented verbs and lines as they are", async () => {
  eq(P.parseLine("talos-buzz phase=render"), { kind: "phase", phase: "render" });
  eq(P.parseLine("talos-buzz done map=/m/p.html warn=merged-unavailable"), { kind: "done", map: "/m/p.html", warn: "merged-unavailable" });
  eq(P.parseLine("talos-buzz done forgot=p"), { kind: "done", forgot: "p" });
  eq(P.parseLine("talos-buzz busy since=2026-11-11T12:00:00Z"), { kind: "busy", since: "2026-11-11T12:00:00Z" });
  eq(P.parseLine("talos-buzz failed reason=auth detail=gh auth login"), { kind: "failed", reason: "auth", detail: "gh auth login" });
  eq(P.parseLine("talos-buzz error=root-invalid"), { kind: "error", reason: "root-invalid" });
  eq(P.parseLine("some other output"), null, "a line that is not talos-buzz's");
  check(allSpawns.length > 0, "no spawn was recorded by the earlier tests");
  for (const s of allSpawns) {
    check(s.id === "talos" && s.args.length === 2 && ["redraw", "refresh", "forget", "open"].includes(s.args[0]), "an undocumented spawn: " + JSON.stringify([s.id, s.args]));
  }
});

// ── run ─────────────────────────────────────────────────────────────────────
for (const [label, fn] of tests) {
  const before = unhandled.length;
  try {
    await fn();
    if (unhandled.length > before) throw new Error("unhandled rejection: " + unhandled.slice(before).join("; "));
    console.log("ok\t" + label);
  } catch (e) {
    console.log("FAIL\t" + label + "\t" + String(e && e.message || e).replace(/\s+/g, " ").slice(0, 600));
  }
}
process.exit(0);
TALOS_NODE_HARNESS_7Q2K
  OUT="$(cd "$WORK" && node "$WORK/harness.mjs" "$SRC_PLUGIN/plugin.js" "$WORK" 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ] && ! grep -q '^ok	\|^FAIL	' <<<"$OUT"; then
    fail "AC5-AC13 the node harness did not run (exit $RC)" "$(printf '%s' "$OUT" | head -5)"
  fi
  while IFS=$'\t' read -r verdict label detail; do
    case "$verdict" in
      ok) pass "$label" ;;
      FAIL) fail "$label" "$detail" ;;
    esac
  done <<<"$OUT"
  case "$OUT" in *$'\nok\t'*|ok$'\t'*|*FAIL$'\t'*) ;; *) fail "AC5-AC13 the node harness reported no test" ;; esac
fi

# ── AC14: docs ───────────────────────────────────────────────────────────────
REF="$TALOS_ROOT/docs/reference.md"
SECTION="$(awk '/^### Project map/{on=1; next} on && /^(##|###) /{exit} on{print}' "$REF")"
assert_contains "$SECTION" "#### Buzz plugin" "AC14 docs/reference.md has a Buzz plugin subsection under Project map"
assert_contains "$SECTION" "Load from folder" "AC14 the subsection says how to load the plugin"
assert_contains "$SECTION" "buzz-plugin" "AC14 the subsection names the plugin folder"
assert_contains "$(cat "$TALOS_ROOT/README.md")" "docs/reference.md#buzz-plugin" "AC14 the README links the Buzz plugin subsection"

finish
