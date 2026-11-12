#!/usr/bin/env bash
# test-buzz-plugin-links-917.sh -- the Buzz plugin opens every link through talos-buzz.sh
# open-url (#917). Tests are named by the spec's id.
#   AC9  prepareFrame adds no <base>; the map iframe's sandbox is exactly allow-same-origin
#   AC10 a click on an http(s) link in the frame document spawns open-url, default prevented
#   AC11 a click on a #fragment link scrolls that element, spawns nothing
#   AC12 a click on a mailto: link is prevented and spawns nothing
#   AC13 auxclick button 1 on an http(s) link opens it; another button does not
#   AC14 a second load (a redraw replaced srcDoc) attaches the listener again
#   AC15 a needs row: primary click and Enter open it; the href stays
#   AC16 a needs-row click does not wait for a running refresh
#   AC17 a failed open-url shows its message
# The plugin runs under node with a stand-in ctx (the harness of test-buzz-plugin.sh, trimmed):
# a minimal react, a scripted host.spawn and a stand-in frame document; jsdom is not needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

TALOS_ROOT="${TALOS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC_PLUGIN="$TALOS_ROOT/buzz-plugin"

if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 18 ]; then
  echo "  skip  AC9-AC17: node >= 18 is not on PATH"
  finish
  exit 0
fi

WORK="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-buzzlinks.XXXXXX")" || exit 1
trap '_is_trap_owner && { rm -rf "${WORK:?}"; _sandbox_cleanup; }' EXIT
cat > "$WORK/harness.mjs" <<'TALOS_NODE_HARNESS_L917'
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [pluginFile, work] = process.argv.slice(2);
const HOME = path.join(work, "home");
const rendered = path.join(work, "plugin.rendered.mjs");
fs.writeFileSync(rendered, fs.readFileSync(pluginFile, "utf8").split("__TALOS_HOME__").join(HOME));
const P = await import(pathToFileURL(rendered).href);

const tests = [];
const test = (label, fn) => tests.push([label, fn]);
const check = (cond, detail) => { if (!cond) throw new Error(detail || "assertion failed"); };
const eq = (got, want, what) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    throw new Error((what ? what + ": " : "") + "expected " + JSON.stringify(want) + " got " + JSON.stringify(got));
  }
};
const unhandled = [];
process.on("unhandledRejection", (e) => unhandled.push(String(e && e.message || e)));
const settle = async (n = 30) => { for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r)); };

const walk = (n, f) => { if (n && typeof n === "object") { f(n); for (const c of n.children || []) walk(c, f); } };
const all = (tree, pred) => { const r = []; walk(tree, (n) => { if (pred(n)) r.push(n); }); return r; };
const textOf = (n) => (n == null || n === false ? "" : typeof n === "object" ? (n.children || []).map(textOf).join("") : String(n));
const buttonsIn = (tree, label) => all(tree, (n) => n.type === "button" && textOf(n).trim() === label);
const iframeOf = (tree) => all(tree, (n) => n.type === "iframe")[0];
const needRowsOf = (tree) => all(tree, (n) => n.type === "a" && String(n.props.className || "").includes("tmap-need"));

const MIN = 60e3, HOUR = 3600e3;
const NOW = Date.parse("2026-11-11T12:00:00Z");
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d+Z$/, "Z");
const mapHtml = (marker) => '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta http-equiv="refresh" content="60">' +
  "<title>Talos · " + marker + '</title></head><body><a href="https://github.com/o/r/pull/7">PR</a></body></html>\n';
const row = (n) => ({ issue: n, title: "Issue " + n, kind: "blocked", since: iso(NOW - 3 * HOUR), why: "why " + n, next: "next " + n, url: "https://github.com/o/r/issues/" + n });
function entry(slug, o = {}) {
  return {
    file: slug + ".html", updated: iso(NOW - HOUR), line: "1 merged", provider: "github", root: "/work/" + slug,
    tiles: { needs: (o.rows || []).length, in_flight: 0, queued: 0, merged_7d: 2, tokens_7d: 10 },
    needs: o.rows || [], run: { going: false, lanes: 0 }, state_read: iso(NOW - 10 * MIN),
  };
}

function makeClock() {
  let t = NOW, id = 0;
  return { now: () => t, setInterval() { return ++id; }, clearInterval() {} };
}

async function world(o = {}) {
  fs.rmSync(HOME, { recursive: true, force: true });
  fs.mkdirSync(path.join(HOME, "maps", ".refresh"), { recursive: true });
  const w = { spawns: [], clock: makeClock(), registered: [] };
  fs.writeFileSync(path.join(HOME, "maps", "index.json"), JSON.stringify(o.entries));
  for (const slug of Object.keys(o.entries)) fs.writeFileSync(path.join(HOME, "maps", o.entries[slug].file), mapHtml(slug));
  const replies = o.replies || {};
  w.host = {
    async readFile(p) { return new Uint8Array(fs.readFileSync(p)); },
    spawn(id, opts) {
      const s = { id, args: opts.args, killed: false, resolved: false };
      s.exited = new Promise((res, rej) => { s.exit = (v) => { s.resolved = true; res(v); }; s.fail = rej; });
      s.say = (line) => opts.onStdout(new TextEncoder().encode(line + "\n"));
      s.kill = () => { s.killed = true; s.exit(null); };
      w.spawns.push(s);
      const reply = replies[s.args[0]];
      if (reply && reply.reject) setImmediate(() => s.fail(new Error(reply.reject)));
      else if (reply) setImmediate(() => { for (const l of reply.lines || []) s.say(l); s.exit(reply.rc === undefined ? 0 : reply.rc); });
      return s;
    },
  };
  const store = new Map();
  if (o.last) store.set("talos.map.last", o.last);
  w.storage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => { store.set(k, String(v)); }, removeItem: (k) => { store.delete(k); } };
  w.R = reactFor();
  const ctx = { react: w.R.React, pages: { register: (r) => { w.registered.push(r); } }, host: w.host };
  w.apply = () => P.apply(ctx, { now: w.clock.now, setInterval: w.clock.setInterval, clearInterval: w.clock.clearInterval, storage: w.storage, visible: () => true, theme: () => "dark" });
  return w;
}
function reactFor() {
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
  w.page = w.R.mount(w.registered[0].component);
  await settle();
}
const page = (w) => w.page.tree;
const opens = (w) => w.spawns.filter((s) => s.args[0] === "open-url").map((s) => s.args);

// A stand-in frame document: listeners by type, elements by id.
function frameDoc(ids = []) {
  const listeners = {};
  const els = {};
  for (const id of ids) els[id] = { scrolled: 0, scrollIntoView() { this.scrolled++; } };
  return {
    listeners, els,
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    getElementById: (id) => els[id] || null,
  };
}
// An event whose target is (inside) an a[href=<href>], or inside no link when href is null.
function fire(doc, type, href, extra = {}) {
  const a = href === null ? null : { getAttribute: (n) => (n === "href" ? href : null) };
  const ev = {
    type, button: 0, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; },
    target: { closest: (sel) => (sel === "a[href]" || sel === "a" ? a : null) },
    ...extra,
  };
  for (const fn of doc.listeners[type] || []) fn(ev);
  return ev;
}
function loadFrame(w, doc) {
  const f = iframeOf(page(w));
  check(f && typeof f.props.onLoad === "function", "the map iframe has no onLoad handler");
  const el = { contentDocument: doc };
  f.props.onLoad({ target: el, currentTarget: el });
}
const projectWorld = (o = {}) => world({ entries: { p: entry("p", { rows: [row(5)] }) }, last: "p", ...o });

// ── AC9 ─────────────────────────────────────────────────────────────────────
test("AC9 prepareFrame adds no <base> element", async () => {
  const out = P.prepareFrame(mapHtml("x"), "dark");
  check(!/<base\b/i.test(out), "a <base> is left: " + out.slice(0, 120));
  check(!/http-equiv=["']?refresh/i.test(out), "the refresh meta is left");
  check(out.includes('data-theme="dark"'), "data-theme is gone");
});

test("AC9 the map iframe's sandbox is exactly allow-same-origin", async () => {
  const w = await projectWorld();
  await mountPage(w);
  const f = iframeOf(page(w));
  check(f, "no iframe in the project view");
  eq(f.props.sandbox, "allow-same-origin");
});

// ── AC10 ────────────────────────────────────────────────────────────────────
test("AC10 a click on an http(s) link in the frame spawns open-url with the URL, default prevented", async () => {
  const w = await projectWorld();
  await mountPage(w);
  const doc = frameDoc(["needs"]);
  loadFrame(w, doc);
  const ev = fire(doc, "click", "https://github.com/o/r/pull/7");
  check(ev.defaultPrevented, "the default was not prevented");
  eq(opens(w), [["open-url", "p", "https://github.com/o/r/pull/7"]]);
  const http = fire(doc, "click", "http://example.test/x");
  check(http.defaultPrevented, "an http link default was not prevented");
  eq(opens(w).length, 2, "http link spawns");
});

// ── AC11 ────────────────────────────────────────────────────────────────────
test("AC11 a click on #needs scrolls that element and spawns nothing", async () => {
  const w = await projectWorld();
  await mountPage(w);
  const doc = frameDoc(["needs"]);
  loadFrame(w, doc);
  const ev = fire(doc, "click", "#needs");
  check(ev.defaultPrevented, "the default was not prevented");
  eq(doc.els.needs.scrolled, 1, "scrollIntoView calls");
  eq(opens(w), [], "spawned");
  const miss = fire(doc, "click", "#nowhere");
  check(miss.defaultPrevented, "a missing fragment default was not prevented");
  eq(opens(w), [], "spawned for a missing fragment");
});

// ── AC12 ────────────────────────────────────────────────────────────────────
test("AC12 a click on a mailto: link is prevented and spawns nothing", async () => {
  const w = await projectWorld();
  await mountPage(w);
  const doc = frameDoc();
  loadFrame(w, doc);
  for (const href of ["mailto:a@b.test", "javascript:alert(1)", "file:///etc/passwd"]) {
    const ev = fire(doc, "click", href);
    check(ev.defaultPrevented, href + ": the default was not prevented");
  }
  eq(w.spawns.filter((s) => s.args[0] === "open-url"), [], "spawned");
});

// ── AC13 ────────────────────────────────────────────────────────────────────
test("AC13 auxclick button 1 on an http(s) link opens it; another button does not", async () => {
  const w = await projectWorld();
  await mountPage(w);
  const doc = frameDoc();
  loadFrame(w, doc);
  const mid = fire(doc, "auxclick", "https://github.com/o/r/pull/7", { button: 1 });
  check(mid.defaultPrevented, "middle click default not prevented");
  eq(opens(w), [["open-url", "p", "https://github.com/o/r/pull/7"]]);
  fire(doc, "auxclick", "https://github.com/o/r/pull/7", { button: 2 });
  eq(opens(w).length, 1, "a right button spawned");
});

// ── AC14 ────────────────────────────────────────────────────────────────────
test("AC14 a second load with a new document attaches the listener again", async () => {
  const w = await projectWorld();
  await mountPage(w);
  loadFrame(w, frameDoc());
  const second = frameDoc();
  loadFrame(w, second);
  const ev = fire(second, "click", "https://github.com/o/r/pull/7");
  check(ev.defaultPrevented, "the default was not prevented in the new document");
  eq(opens(w), [["open-url", "p", "https://github.com/o/r/pull/7"]]);
});

// ── AC15 ────────────────────────────────────────────────────────────────────
test("AC15 a primary click on a needs row, and Enter on it, open its URL; the href stays", async () => {
  const w = await world({ entries: { p: entry("p", { rows: [row(5)] }) } });
  await mountPage(w);
  const r = needRowsOf(page(w))[0];
  check(r, "no needs row on the projects view");
  eq(r.props.href, "https://github.com/o/r/issues/5", "row href");
  const click = { button: 0, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
  r.props.onClick(click);
  check(click.defaultPrevented, "click default not prevented");
  eq(opens(w), [["open-url", "p", "https://github.com/o/r/issues/5"]]);
  const key = { key: "Enter", defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
  r.props.onKeyDown(key);
  check(key.defaultPrevented, "Enter default not prevented");
  eq(opens(w).length, 2, "Enter spawns");
  const other = { key: "a", defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
  r.props.onKeyDown(other);
  eq(opens(w).length, 2, "another key spawned");
  eq(needRowsOf(page(w))[0].props.href, "https://github.com/o/r/issues/5", "row href after");
});

// ── AC16 ────────────────────────────────────────────────────────────────────
test("AC16 a needs-row click spawns open-url before a running refresh resolves", async () => {
  const w = await world({ entries: { p: entry("p", { rows: [row(5)] }) } });
  await mountPage(w);
  buttonsIn(page(w), "Refresh all")[0].props.onClick({});
  await settle();
  const busy = w.spawns.filter((s) => s.args[0] !== "open-url");
  check(busy.length >= 1 && !busy[0].resolved, "fixture: no refresh/redraw spawn is running");
  needRowsOf(page(w))[0].props.onClick({ button: 0, preventDefault() {} });
  const open = w.spawns.filter((s) => s.args[0] === "open-url");
  eq(open.length, 1, "open-url spawns");
  check(!busy[0].resolved, "the earlier spawn resolved first");
});

// ── AC17 ────────────────────────────────────────────────────────────────────
test("AC17 an open-url that exits non-zero with a failed line shows its message", async () => {
  const w = await world({
    entries: { p: entry("p", { rows: [row(5)] }) },
    replies: { "open-url": { lines: ["talos-buzz failed reason=failed detail=no browser here"], rc: 1 } },
  });
  await mountPage(w);
  needRowsOf(page(w))[0].props.onClick({ button: 0, preventDefault() {} });
  await settle();
  const text = textOf(page(w));
  check(text.includes("no browser here"), "no message on the projects view: " + text.slice(0, 300));
  w.page.unmount();
  const v = await projectWorld({ replies: { "open-url": { lines: ["talos-buzz failed reason=failed detail=no browser here"], rc: 1 } } });
  await mountPage(v);
  const doc = frameDoc();
  loadFrame(v, doc);
  fire(doc, "click", "https://github.com/o/r/pull/7");
  await settle();
  check(textOf(page(v)).includes("no browser here"), "no message on the project view");
});

test("AC17 an open-url spawn that rejects shows a message", async () => {
  const w = await world({
    entries: { p: entry("p", { rows: [row(5)] }) },
    replies: { "open-url": { reject: "spawn exploded" } },
  });
  await mountPage(w);
  needRowsOf(page(w))[0].props.onClick({ button: 0, preventDefault() {} });
  await settle();
  check(textOf(page(w)).includes("spawn exploded"), "no message: " + textOf(page(w)).slice(0, 300));
});

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
TALOS_NODE_HARNESS_L917
OUT="$(cd "$WORK" && node "$WORK/harness.mjs" "$SRC_PLUGIN/plugin.js" "$WORK" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && ! grep -q '^ok	\|^FAIL	' <<<"$OUT"; then
  fail "AC9-AC17 the node harness did not run (exit $RC)" "$(printf '%s' "$OUT" | head -5)"
fi
while IFS=$'\t' read -r verdict label detail; do
  case "$verdict" in
    ok) pass "$label" ;;
    FAIL) fail "$label" "$detail" ;;
  esac
done <<<"$OUT"
case "$OUT" in *$'\nok\t'*|ok$'\t'*|*FAIL$'\t'*) ;; *) fail "AC9-AC17 the node harness reported no test" ;; esac

finish
