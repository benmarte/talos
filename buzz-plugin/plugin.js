// Talos for Buzz (#902): every Talos project and its map inside Buzz.
//
// Plain JavaScript, no build step, no npm dependency. install.sh --global copies
// this file to ${TALOS_HOME:-~/.talos}/buzz-plugin/ with __TALOS_HOME__ replaced
// by the absolute TALOS_HOME, next to a generated manifest.json. The plugin holds
// no token and makes no network call: it reads maps/index.json, the map pages and
// maps/.refresh/<file>.json, and spawns the one declared process,
// scripts/talos-buzz.sh <redraw|refresh|forget|open> <slug>.
//
// Layout: pure helpers (exported for tests), createStore (all state and every
// spawn, no React), the components (thin views over the store), apply.

export const inject = ["react", "pages", "host"];

const TALOS_HOME = "__TALOS_HOME__";
const MAPS = TALOS_HOME + "/maps";
const PROCESS_ID = "talos";
const PAGE_ID = "talos.map";
const SANDBOX = "allow-popups allow-popups-to-escape-sandbox";
const FILE_RE = /^[A-Za-z0-9._-]+\.html$/;
const LAST_KEY = "talos.map.last";

const MIN = 60e3;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const READ_STALE_MS = HOUR; // a state read older than this is refreshed on open
const READ_AMBER_MS = DAY; // ... and shown amber past this
const STALE_ENTRY_MS = 14 * DAY; // dimmed, with a Remove button
const BACKOFF_MS = 15 * MIN; // automatic refreshes skip a project after a failed one
const POLL_MS = 30e3;
const LONG_READ_MS = 2 * MIN;
const BUSY_MAX_MS = 10 * MIN; // the refresh lock is taken over after this

const PROVIDERS = {
  github: { name: "GitHub", login: "gh auth login" },
  azure: { name: "Azure DevOps", login: "az login" },
  gitlab: { name: "GitLab", login: "" },
};

// ── pure helpers ─────────────────────────────────────────────────────────────

export function providerOf(entry) {
  const p = entry && PROVIDERS[entry.provider];
  return p || PROVIDERS.github;
}

export function validFile(name) {
  return typeof name === "string" && FILE_RE.test(name);
}

export function isoMs(iso) {
  if (typeof iso !== "string") return null;
  const t = Date.parse(iso);
  return Number.isNaN(t) ? null : t;
}

// An age in the plugin's one short form: "<1 min", "5 min", "3 h", "2 d".
export function age(ms) {
  const m = Math.floor(Math.max(0, ms) / MIN);
  if (m < 1) return "<1 min";
  if (m < 60) return m + " min";
  if (m < 48 * 60) return Math.floor(m / 60) + " h";
  return Math.floor(m / 60 / 24) + " d";
}

export function ageSince(iso, now) {
  const t = isoMs(iso);
  return t === null ? null : age(now - t);
}

export function hasRoot(entry) {
  return !!entry && typeof entry.root === "string" && entry.root !== "";
}

export function tilesOf(entry) {
  const t = (entry && entry.tiles) || {};
  const n = (v) => (Number.isFinite(v) && v > 0 ? v : 0);
  return { needs: n(t.needs), in_flight: n(t.in_flight), queued: n(t.queued), merged_7d: n(t.merged_7d) };
}

export function needsTotal(entries) {
  let total = 0;
  for (const slug of Object.keys(entries || {})) total += tilesOf(entries[slug]).needs;
  return total;
}

export function staleDays(entry, now) {
  const t = isoMs(entry && entry.updated);
  if (t === null || now - t <= STALE_ENTRY_MS) return 0;
  return Math.floor((now - t) / DAY);
}

export function isRunning(entry, now) {
  return !!(entry && entry.run && entry.run.going) && staleDays(entry, now) === 0;
}

// Needs you first, then running, then the rest; each group newest `updated` first.
export function orderEntries(entries, now) {
  const rank = (e) => (tilesOf(e).needs > 0 ? 0 : isRunning(e, now) ? 1 : 2);
  const when = (e) => isoMs(e && e.updated) || 0;
  return Object.keys(entries || {})
    .map((slug) => [slug, entries[slug]])
    .sort((a, b) => rank(a[1]) - rank(b[1]) || when(b[1]) - when(a[1]) || (a[0] < b[0] ? -1 : 1));
}

// A state read that is missing or over an hour old.
export function needsRead(entry, now) {
  const t = isoMs(entry && entry.state_read);
  return t === null || now - t > READ_STALE_MS;
}

// One stdout line of talos-buzz.sh: {kind: phase|done|busy|failed|error|other, ...}, or null.
export function parseLine(line) {
  const s = String(line == null ? "" : line).trim();
  if (!s.startsWith("talos-buzz ")) return null;
  const rest = s.slice("talos-buzz ".length);
  let m;
  if ((m = /^phase=(\S+)$/.exec(rest))) return { kind: "phase", phase: m[1] };
  if ((m = /^busy(?: since=(\S*))?$/.exec(rest))) return { kind: "busy", since: m[1] || "" };
  if ((m = /^failed reason=(\S+)(?: detail=(.*))?$/.exec(rest))) return { kind: "failed", reason: m[1], detail: m[2] || "" };
  if ((m = /^error=(\S+)$/.exec(rest))) return { kind: "error", reason: m[1] };
  if ((m = /^done(?: (.*))?$/.exec(rest))) {
    const out = { kind: "done" };
    const re = /(\w+)=(\S*)/g;
    let kv;
    while ((kv = re.exec(m[1] || ""))) out[kv[1]] = kv[2];
    return out;
  }
  return { kind: "other" };
}

// The page, ready for the sandboxed frame: no meta refresh (the browser refuses
// it there and the plugin reloads itself), one <base target="_blank"> after
// <head>, and data-theme on <html>. Nothing else changes.
export function prepareFrame(html, theme) {
  let out = String(html);
  out = out.replace(/<meta\s+http-equiv\s*=\s*["']?refresh["']?[^>]*>/gi, "");
  if (!out.includes('<base target="_blank">')) {
    out = out.replace(/<head\b[^>]*>/i, (m) => m + '<base target="_blank">');
  }
  const attr = ' data-theme="' + (theme === "dark" ? "dark" : "light") + '"';
  out = out.replace(/<html\b([^>]*)>/i, (m, attrs) => {
    const rest = attrs.replace(/\sdata-theme\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/i, "");
    return "<html" + rest + attr + ">";
  });
  return out;
}

// Buzz's theme from its computed --bg-panel (luminance below 0.5 is dark),
// falling back to the system preference.
export function themeFromColor(color, prefersDark) {
  const fallback = prefersDark ? "dark" : "light";
  const s = String(color || "").trim();
  let r, g, b, m;
  if ((m = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(s))) {
    let h = m[1];
    if (h.length === 3) h = h.replace(/./g, (c) => c + c);
    r = parseInt(h.slice(0, 2), 16);
    g = parseInt(h.slice(2, 4), 16);
    b = parseInt(h.slice(4, 6), 16);
  } else if ((m = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/i.exec(s))) {
    r = +m[1];
    g = +m[2];
    b = +m[3];
  } else {
    return fallback;
  }
  const luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
  return luminance < 0.5 ? "dark" : "light";
}

export function safeUrl(url) {
  return typeof url === "string" && /^https?:\/\//i.test(url) ? url : undefined;
}

function msg(e) {
  const s = e && e.message ? e.message : String(e);
  return s.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 200);
}

function isMissing(e) {
  return /No such file/i.test(msg(e));
}

function decode(chunk) {
  if (typeof chunk === "string") return chunk;
  return new TextDecoder().decode(chunk);
}

// What the card and the project view say about a failed read or redraw.
export function failureText(entry, failure) {
  const p = providerOf(entry);
  if (failure.reason === "auth") {
    const how = p.login ? "Run `" + p.login + "` in a terminal" : "Check the " + p.name + " login Talos uses";
    return "Couldn't read " + p.name + ": not signed in. " + how + ", then Refresh. The last map stays.";
  }
  const why = failure.detail ? failure.reason + ": " + failure.detail : failure.reason;
  return "Couldn't read " + p.name + " (" + why + "). The last map stays.";
}

const NO_ROOT_TEXT =
  "Talos hasn't redrawn this project since the update. It will at its next stage, or run `talos.sh map` in the repo once.";

// ── the store: state, files and spawns, no React ─────────────────────────────

export function createStore(env) {
  const host = env.host;
  const now = env.now || (() => Date.now());
  const every = env.setInterval || ((f, ms) => globalThis.setInterval(f, ms));
  const stopEvery = env.clearInterval || ((id) => globalThis.clearInterval(id));
  const visible = env.visible || (() => typeof document === "undefined" || document.visibilityState !== "hidden");
  const readTheme = env.theme || (() => "light");
  const storage = env.storage === undefined ? safeStorage() : env.storage;

  const state = { reg: { state: "loading", entries: {}, error: "" }, view: null, confirm: null, mounted: false };
  const projects = {};
  const listeners = new Set();
  const children = new Set();
  let queue = [];
  let running = null;
  let gen = 0;
  let users = 0;
  let poller = null;
  let ticker = null;

  function proj(slug) {
    if (!projects[slug]) {
      projects[slug] = {
        raw: null, frame: "", swaps: 0, mapState: "loading", reading: null, redrawing: false,
        failure: null, record: null, redrawError: "", openError: "", forgetError: "", noRoot: false,
      };
    }
    return projects[slug];
  }

  function emit() {
    for (const fn of Array.from(listeners)) {
      try { fn(); } catch (e) { /* a view that threw must not stop the others */ }
    }
  }

  function subscribe(fn) {
    listeners.add(fn);
    return () => listeners.delete(fn);
  }

  function remember(slug) {
    try { if (storage) storage.setItem(LAST_KEY, slug); } catch (e) { /* no storage: nothing remembered */ }
  }
  function remembered() {
    try { return storage ? storage.getItem(LAST_KEY) : null; } catch (e) { return null; }
  }
  function unremember(slug) {
    try { if (storage && storage.getItem(LAST_KEY) === slug) storage.removeItem(LAST_KEY); } catch (e) { /* ignore */ }
  }

  async function readText(path) {
    return decode(await host.readFile(path));
  }

  async function loadRegistry() {
    let text;
    try {
      text = await readText(MAPS + "/index.json");
    } catch (e) {
      state.reg = isMissing(e)
        ? { state: "none", entries: {}, error: "" }
        : { state: "bad", entries: {}, error: "Couldn't read the Talos project list (" + msg(e) + ")." };
      emit();
      return;
    }
    let data = null;
    try { data = JSON.parse(text); } catch (e) { data = null; }
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      state.reg = { state: "bad", entries: {}, error: "Couldn't read the Talos project list (index.json is not valid JSON)." };
      emit();
      return;
    }
    const entries = {};
    for (const slug of Object.keys(data)) {
      if (data[slug] && typeof data[slug] === "object" && !Array.isArray(data[slug])) entries[slug] = data[slug];
    }
    state.reg = { state: Object.keys(entries).length ? "ok" : "none", entries, error: "" };
    emit();
  }

  function refreshFrame(slug) {
    const p = proj(slug);
    if (p.raw === null) return;
    const html = prepareFrame(p.raw, readTheme());
    if (html !== p.frame) {
      p.frame = html;
      p.swaps += 1;
    }
  }

  async function loadMap(slug) {
    const p = proj(slug);
    const name = (state.reg.entries[slug] || {}).file;
    if (!validFile(name)) {
      p.mapState = "refused";
      p.raw = null;
      p.frame = "";
      emit();
      return;
    }
    try {
      const text = await readText(MAPS + "/" + name);
      p.mapState = "ok";
      p.raw = text;
      refreshFrame(slug);
    } catch (e) {
      if (p.raw === null) p.mapState = isMissing(e) ? "missing" : "unreadable";
    }
    emit();
  }

  async function loadRecord(slug) {
    const name = (state.reg.entries[slug] || {}).file;
    if (!validFile(name)) return;
    const p = proj(slug);
    try {
      const rec = JSON.parse(await readText(MAPS + "/.refresh/" + name + ".json"));
      p.record = rec && typeof rec === "object" ? rec : null;
    } catch (e) {
      p.record = null;
    }
    // A refresh another process was running has finished.
    if (p.reading && p.reading.busy && p.record) {
      const done = isoMs(p.record.finished);
      if (done !== null && done >= (p.reading.since || 0) - 1000) {
        p.reading = null;
        await loadRegistry();
        await loadMap(slug);
      }
    }
    if (p.reading && p.reading.busy && now() - p.reading.since > BUSY_MAX_MS) p.reading = null;
    syncTicker();
    emit();
  }

  // When automatic refreshes may start again for this project.
  function backoffUntil(p) {
    let last = 0;
    if (p.failure) last = Math.max(last, p.failure.at);
    if (p.record && p.record.ok === false) last = Math.max(last, isoMs(p.record.finished) || 0);
    return last ? last + BACKOFF_MS : 0;
  }

  function noRoot(slug) {
    return !hasRoot(state.reg.entries[slug]) || proj(slug).noRoot;
  }

  function autoEligible(slug) {
    const e = state.reg.entries[slug];
    if (!e || noRoot(slug)) return false;
    const p = proj(slug);
    return !p.reading && needsRead(e, now()) && now() >= backoffUntil(p);
  }

  // ── the one spawn lane: never two processes at once ─────────────────────────

  function key(j) {
    return (j.verb === "refresh" ? 1 : 0) * 2 + (j.auto ? 1 : 0);
  }

  function enqueue(job) {
    const same = (j) => j.verb === job.verb && j.slug === job.slug;
    const queued = queue.find(same);
    if (queued) {
      if (!job.auto && queued.auto) {
        queue = queue.filter((j) => j !== queued);
        queued.auto = false;
        job = queued;
      } else {
        return;
      }
    } else if (running && same(running) && job.verb !== "forget") {
      return;
    }
    let at = queue.length;
    for (let i = 0; i < queue.length; i++) {
      if (key(queue[i]) > key(job)) { at = i; break; }
    }
    queue.splice(at, 0, job);
    emit();
    pump();
  }

  function pump() {
    if (running || !state.mounted) return;
    const job = queue.shift();
    if (!job) return;
    running = job;
    const mine = job;
    emit();
    execute(job)
      .catch(() => {})
      .then(() => {
        if (running === mine) running = null;
        syncTicker();
        emit();
        pump();
      });
  }

  async function runVerb(verb, slug, onLine) {
    const lines = [];
    let buf = "";
    const feed = (chunk) => {
      buf += decode(chunk);
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        lines.push(buf.slice(0, i));
        onLine(parseLine(buf.slice(0, i)));
        buf = buf.slice(i + 1);
      }
    };
    let child;
    try {
      child = await host.spawn(PROCESS_ID, { args: [verb, slug], onStdout: feed, onStderr: () => {} });
    } catch (e) {
      return { rc: null, lines, error: msg(e) };
    }
    children.add(child);
    try {
      const rc = await child.exited;
      if (buf) { lines.push(buf); onLine(parseLine(buf)); buf = ""; }
      return { rc, lines };
    } catch (e) {
      return { rc: null, lines, error: msg(e) };
    } finally {
      children.delete(child);
    }
  }

  // The outcome of one talos-buzz run, from its lines and its exit.
  async function runOutcome(verb, slug) {
    const out = { ok: false, busy: null, failure: null, noRoot: false };
    const res = await runVerb(verb, slug, (l) => {
      if (!l) return;
      if (l.kind === "done") out.ok = true;
      if (l.kind === "busy") out.busy = l.since;
      if (l.kind === "failed") out.failure = { reason: l.reason, detail: l.detail };
      if (l.kind === "error") {
        if (l.reason === "root-invalid") out.noRoot = true;
        out.failure = { reason: l.reason, detail: "talos-buzz error=" + l.reason };
      }
    });
    if (res.error !== undefined) {
      out.failure = { reason: "spawn", detail: "Couldn't run Talos: " + res.error };
    } else if (out.busy === null && !out.failure && !out.ok) {
      const none = res.lines.length === 0;
      out.failure = {
        reason: "failed",
        detail: none ? "Talos exited" + (res.rc ? " with status " + res.rc : "") + " and printed nothing." : "Talos gave no result.",
      };
    }
    return out;
  }

  async function execute(job) {
    const mine = gen;
    const slug = job.slug;
    const p = proj(slug);
    const stale = () => mine !== gen;

    if (job.verb === "redraw") {
      p.redrawing = true;
      emit();
      const out = await runOutcome("redraw", slug);
      if (stale()) return;
      p.redrawing = false;
      if (out.noRoot) p.noRoot = true;
      p.redrawError = out.ok || out.noRoot ? "" : out.failure.detail || out.failure.reason;
      await loadRegistry();
      if (stale()) return;
      if (state.view === slug) await loadMap(slug);
      if (stale()) return;
      if (job.thenRefresh && autoEligible(slug)) enqueue({ verb: "refresh", slug, auto: true });
      return;
    }

    if (job.verb === "refresh") {
      if (job.auto) {
        await loadRecord(slug);
        if (stale()) return;
        if (!autoEligible(slug)) return;
      } else if (noRoot(slug)) {
        return;
      }
      p.reading = { since: now(), busy: false };
      syncTicker();
      emit();
      const out = await runOutcome("refresh", slug);
      if (stale()) return;
      if (out.busy !== null) {
        // Another process is already reading: show the spinner, never retry.
        p.reading = { since: isoMs(out.busy) || p.reading.since, busy: true };
      } else {
        p.reading = null;
        if (out.noRoot) p.noRoot = true;
        p.failure = out.ok || out.noRoot ? null : { reason: out.failure.reason, detail: out.failure.detail, at: now() };
      }
      await loadRegistry();
      if (stale()) return;
      await loadMap(slug);
      if (stale()) return;
      await loadRecord(slug);
      return;
    }

    if (job.verb === "forget") {
      p.forgetError = "";
      const out = await runOutcome("forget", slug);
      if (stale()) return;
      if (out.ok) {
        delete projects[slug];
        unremember(slug);
        if (state.view === slug) state.view = null;
      } else {
        p.forgetError = "Couldn't remove " + slug + ": " + (out.failure.detail || out.failure.reason);
      }
      state.confirm = null;
      await loadRegistry();
      return;
    }

    if (job.verb === "open") {
      p.openError = "";
      const out = await runOutcome("open", slug);
      if (stale()) return;
      if (!out.ok) p.openError = "Couldn't open the map in the browser: " + (out.failure.detail || out.failure.reason);
    }
  }

  function syncTicker() {
    let any = false;
    for (const slug of Object.keys(projects)) if (projects[slug].reading) any = true;
    if (any && state.mounted && !ticker) ticker = every(() => emit(), 1000);
    if ((!any || !state.mounted) && ticker) { stopEvery(ticker); ticker = null; }
  }

  // ── actions ───────────────────────────────────────────────────────────────

  async function showProjects() {
    state.view = null;
    state.confirm = null;
    emit();
    await loadRegistry();
    for (const [slug] of orderEntries(state.reg.entries, now())) {
      if (autoEligible(slug)) enqueue({ verb: "refresh", slug, auto: true });
    }
  }

  async function openProject(slug) {
    if (!state.reg.entries[slug]) return;
    state.view = slug;
    state.confirm = null;
    remember(slug);
    emit();
    await loadMap(slug);
    if (hasRoot(state.reg.entries[slug])) enqueue({ verb: "redraw", slug, thenRefresh: true });
  }

  async function refresh(slug) {
    if (!state.reg.entries[slug] || noRoot(slug)) return;
    enqueue({ verb: "redraw", slug, thenRefresh: false });
    enqueue({ verb: "refresh", slug, auto: false });
  }

  async function refreshAll() {
    await loadRegistry();
    for (const [slug] of orderEntries(state.reg.entries, now())) {
      if (!noRoot(slug)) {
        enqueue({ verb: "redraw", slug, thenRefresh: false });
        enqueue({ verb: "refresh", slug, auto: false });
      }
    }
  }

  function askForget(slug) { state.confirm = slug; emit(); }
  function cancelForget() { state.confirm = null; emit(); }
  function forget(slug) { enqueue({ verb: "forget", slug }); }
  function openInBrowser(slug) { enqueue({ verb: "open", slug }); }

  async function poll() {
    if (!visible()) return;
    try {
      await loadRegistry();
      if (state.mounted && state.view && state.reg.entries[state.view]) {
        await loadMap(state.view);
        await loadRecord(state.view);
      }
    } catch (e) { /* the next poll tries again */ }
  }

  function retain() {
    users += 1;
    if (users === 1) poller = every(poll, POLL_MS);
  }
  function release() {
    users = Math.max(0, users - 1);
    if (users === 0 && poller) { stopEvery(poller); poller = null; }
  }

  async function mount() {
    state.mounted = true;
    gen += 1;
    retain();
    try {
      await loadRegistry();
      const last = remembered();
      if (last && state.reg.entries[last]) await openProject(last);
      else await showProjects();
    } catch (e) { /* the views show what loaded */ }
  }

  function unmount() {
    state.mounted = false;
    gen += 1;
    queue = [];
    running = null;
    for (const child of Array.from(children)) {
      try { child.kill(); } catch (e) { /* already gone */ }
    }
    children.clear();
    for (const slug of Object.keys(projects)) {
      projects[slug].reading = null;
      projects[slug].redrawing = false;
    }
    syncTicker();
    release();
  }

  return {
    state, proj, subscribe, now, noRoot, loadRegistry, mount, unmount, retain, release,
    showProjects, openProject, refresh, refreshAll, askForget, cancelForget, forget, openInBrowser,
    isQueued: (slug) => queue.some((j) => j.verb === "refresh" && j.slug === slug),
  };
}

function safeStorage() {
  try { return globalThis.localStorage || null; } catch (e) { return null; }
}

function defaultTheme() {
  let dark = false;
  try { dark = !!globalThis.matchMedia && globalThis.matchMedia("(prefers-color-scheme: dark)").matches; } catch (e) { /* light */ }
  try {
    const c = globalThis.getComputedStyle(globalThis.document.documentElement).getPropertyValue("--bg-panel");
    return themeFromColor(c, dark);
  } catch (e) {
    return dark ? "dark" : "light";
  }
}

// ── views ────────────────────────────────────────────────────────────────────

const CSS = [
  ".tmap-spin{display:inline-block;width:11px;height:11px;border:2px solid currentColor;border-right-color:transparent;border-radius:50%;animation:tmap-rot .8s linear infinite;vertical-align:-2px;margin-right:6px}",
  "@keyframes tmap-rot{to{transform:rotate(360deg)}}",
  ".tmap-bar{height:3px;border-radius:2px;background:var(--border-standard,#8884);overflow:hidden;position:relative;flex:none}",
  ".tmap-bar::after{content:'';position:absolute;top:0;bottom:0;width:30%;background:#3b82f6;animation:tmap-slide 1.2s ease-in-out infinite}",
  "@keyframes tmap-slide{0%{left:-30%}100%{left:100%}}",
  ".tmap-card:hover{border-color:var(--text-secondary,#888)}",
  ".tmap-btn{cursor:pointer;font:inherit;padding:4px 10px;border-radius:6px;border:1px solid var(--border-standard,#8886);background:transparent;color:inherit}",
  ".tmap-btn:hover:not(:disabled){background:var(--border-standard,#8883)}",
  ".tmap-btn:disabled{opacity:.5;cursor:default}",
  ".tmap-btn:focus-visible,.tmap-link:focus-visible,.tmap-pick:focus-visible{outline:2px solid #3b82f6;outline-offset:1px}",
  ".tmap-link{color:inherit;text-decoration:none;display:block}",
  ".tmap-link:hover{text-decoration:underline}",
  "@media (max-width:640px){.tmap-bar-row{flex-direction:column;align-items:stretch!important}.tmap-cardhead{flex-direction:column;align-items:flex-start!important}}",
  "@media (prefers-reduced-motion:reduce){.tmap-spin,.tmap-bar::after{animation:none}}",
].join("");

const RED = "var(--text-danger, #dc2626)";
const BLUE = "#3b82f6";
const AMBER = "#d97706";
const MUTED = "var(--text-secondary, #888)";

function buildComponents(React, store) {
  const h = React.createElement;
  const { useState, useEffect } = React;
  const state = store.state;

  function useTick() {
    const [, set] = useState(0);
    useEffect(() => store.subscribe(() => set((n) => n + 1)), []);
  }

  const note = (text, extra) =>
    h("div", { className: "tmap-note", role: "status", style: Object.assign({ color: MUTED, padding: "12px 0" }, extra || {}) }, text);

  const button = (label, onClick, opts) => {
    const o = opts || {};
    return h("button", { type: "button", className: "tmap-btn", onClick, disabled: !!o.disabled, title: o.title, style: o.style }, label);
  };

  const spinner = () => h("span", { className: "tmap-spin", "aria-hidden": "true" });

  function chip(text, color) {
    return h("span", {
      key: text,
      style: { fontSize: 12, padding: "2px 8px", borderRadius: 999, border: "1px solid " + (color || "var(--border-standard, #8886)"), color: color || MUTED },
    }, text);
  }

  function providerBadge(entry) {
    return h("span", {
      style: { fontSize: 11, padding: "1px 6px", borderRadius: 4, border: "1px solid var(--border-standard, #8886)", color: MUTED },
    }, providerOf(entry).name);
  }

  function readingText(entry, p) {
    const secs = Math.max(0, Math.floor((store.now() - p.reading.since) / 1000));
    return "Reading " + providerOf(entry).name + "… " + secs + " s";
  }

  function footer(slug, entry) {
    const p = store.proj(slug);
    const now = store.now();
    const name = providerOf(entry).name;
    if (p.reading) {
      return h("div", { className: "tmap-footer", style: { color: BLUE, fontSize: 12 } }, spinner(), readingText(entry, p));
    }
    if (store.isQueued(slug)) {
      return h("div", { className: "tmap-footer", style: { color: MUTED, fontSize: 12 } }, "refresh queued");
    }
    const t = isoMs(entry.state_read);
    if (t === null) return h("div", { className: "tmap-footer", style: { color: AMBER, fontSize: 12 } }, "never read");
    return h("div", { className: "tmap-footer", style: { color: now - t > READ_AMBER_MS ? AMBER : MUTED, fontSize: 12 } },
      name + " read " + age(now - t) + " ago");
  }

  function pill(entry) {
    const now = store.now();
    const days = staleDays(entry, now);
    let text;
    let color = MUTED;
    if (days > 0) {
      text = "Not updated in " + days + " days";
    } else if (isRunning(entry, now)) {
      const run = entry.run || {};
      const parts = ["Running"];
      if (run.role && run.issue) parts.push(run.role + " on #" + run.issue);
      else if (run.role) parts.push(run.role);
      const a = ageSince(run.stage_since, now);
      if (a) parts.push(a);
      text = parts.join(" · ");
      color = BLUE;
    } else {
      const a = ageSince(entry.updated, now);
      text = "Idle" + (a ? " · map " + a + " old" : "");
    }
    return h("span", { className: "tmap-pill", style: { fontSize: 12, color, whiteSpace: "nowrap" } }, text);
  }

  function needRows(entry) {
    const now = store.now();
    const rows = Array.isArray(entry.needs) ? entry.needs.slice(0, 3) : [];
    return rows.map((r, i) => {
      const a = ageSince(r.since, now);
      const detail = [r.why, r.next].filter(Boolean).join(" · ");
      return h("a", {
        key: "need" + i, className: "tmap-link tmap-need", href: safeUrl(r.url), target: "_blank", rel: "noopener noreferrer",
        style: { padding: "6px 0", borderTop: "1px solid var(--border-standard, #8884)" },
      },
        h("div", { style: { display: "flex", gap: 8, justifyContent: "space-between", alignItems: "baseline" } },
          h("span", null, "#" + r.issue + " " + (r.title || "")),
          h("span", { style: { color: RED, fontSize: 12, whiteSpace: "nowrap" } }, [r.kind, a].filter(Boolean).join(" · "))),
        detail ? h("div", { style: { color: MUTED, fontSize: 12 } }, detail) : null);
    });
  }

  function card(slug, entry) {
    const p = store.proj(slug);
    const now = store.now();
    const tiles = tilesOf(entry);
    const days = staleDays(entry, now);
    const extra = tiles.needs - 3;
    const parts = [
      h("div", { key: "head", className: "tmap-cardhead", style: { display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8 } },
        h("span", { style: { display: "flex", gap: 8, alignItems: "center" } },
          h("button", {
            type: "button", className: "tmap-btn tmap-open", onClick: () => store.openProject(slug),
            style: { border: "none", fontWeight: 600, fontSize: 15, padding: 0 },
          }, slug),
          providerBadge(entry)),
        pill(entry)),
      h("div", { key: "chips", style: { display: "flex", gap: 6, flexWrap: "wrap" } },
        chip(tiles.needs + " need you", tiles.needs > 0 ? RED : null),
        chip(tiles.in_flight + " in flight", tiles.in_flight > 0 ? BLUE : null),
        chip(tiles.queued + " queued"),
        chip(tiles.merged_7d + " merged · 7 d")),
    ];
    parts.push(...needRows(entry));
    if (tiles.needs > 3) {
      parts.push(h("button", {
        key: "more", type: "button", className: "tmap-btn", onClick: () => store.openProject(slug),
        style: { border: "none", padding: "4px 0", color: MUTED, textAlign: "left" },
      }, "+" + extra + " more · open map →"));
    }
    if (!hasRoot(entry) || p.noRoot) parts.push(note(NO_ROOT_TEXT, { padding: "2px 0", fontSize: 12 }));
    if (!validFile(entry.file)) parts.push(note("Refused: this project's map file name is not a plain .html name, so it is never read.", { padding: "2px 0", fontSize: 12, color: RED }));
    parts.push(footer(slug, entry));
    if (p.failure) parts.push(h("div", { key: "fail", style: { color: RED, fontSize: 12 } }, failureText(entry, p.failure)));
    if (p.forgetError) parts.push(h("div", { key: "ferr", style: { color: RED, fontSize: 12 } }, p.forgetError));
    if (days > 0) {
      if (state.confirm === slug) {
        parts.push(h("div", { key: "confirm", className: "tmap-confirm", style: { display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" } },
          h("span", { style: { fontSize: 12 } }, "Remove " + slug + " from the list? Its map file and repository are not touched."),
          button("Remove", () => store.forget(slug), { style: { color: RED } }),
          button("Cancel", () => store.cancelForget())));
      } else {
        parts.push(h("div", { key: "remove" }, button("Remove from list", () => store.askForget(slug))));
      }
    }
    return h("div", {
      key: slug, className: "tmap-card", "data-slug": slug, "data-stale": days > 0 ? "true" : "false",
      style: {
        display: "flex", flexDirection: "column", gap: 8, padding: "var(--space-panel-inset, 14px)",
        border: "1px solid var(--border-standard, #8886)", borderRadius: "var(--radius-panel, 10px)",
        background: "var(--bg-panel, transparent)", opacity: days > 0 ? 0.6 : 1,
      },
    }, parts);
  }

  function ProjectsView() {
    const now = store.now();
    const entries = state.reg.entries;
    const slugs = Object.keys(entries);
    const needs = needsTotal(entries);
    const head = h("div", { key: "head", style: { display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, flexWrap: "wrap" } },
      h("div", null,
        h("h2", { style: { margin: 0, fontSize: 20 } }, "Talos"),
        h("div", { style: { color: MUTED, fontSize: 13 } }, slugs.length + (slugs.length === 1 ? " project" : " projects") + " · " + needs + " need you")),
      button("Refresh all", () => store.refreshAll()));
    let body;
    if (state.reg.state === "loading") body = note("Loading Talos projects…");
    else if (state.reg.state === "none") body = note("No Talos projects on this Mac yet. Run `talos.sh map` in a repo, or start a Talos run there.");
    else if (state.reg.state === "bad") body = note(state.reg.error, { color: RED });
    else body = h("div", { key: "cards", style: { display: "flex", flexDirection: "column", gap: 12 } }, orderEntries(entries, now).map(([slug, e]) => card(slug, e)));
    return h("div", { className: "tmap-projects", style: { display: "flex", flexDirection: "column", gap: 14 } }, head, body);
  }

  function banner(slug, entry) {
    const p = store.proj(slug);
    const now = store.now();
    const lines = [];
    if (p.reading) {
      const long = now - p.reading.since >= LONG_READ_MS;
      lines.push(h("div", { key: "bar", className: "tmap-bar", role: "progressbar", "aria-label": "Reading " + providerOf(entry).name }));
      lines.push(h("div", { key: "reading", style: { fontSize: 13, color: BLUE } },
        spinner(),
        long
          ? "Still reading. It keeps going in the background; you can leave this page."
          : "Reading " + providerOf(entry).name + "… The map updates by itself when it's done."));
    } else if (store.isQueued(slug)) {
      lines.push(h("div", { key: "queued", style: { fontSize: 13, color: MUTED } }, "refresh queued"));
    }
    if (p.redrawing) lines.push(h("div", { key: "redraw", style: { fontSize: 13, color: MUTED } }, "Redrawing the map…"));
    if (store.noRoot(slug)) lines.push(h("div", { key: "noroot", style: { fontSize: 13, color: AMBER } }, NO_ROOT_TEXT));
    if (p.failure) lines.push(h("div", { key: "fail", style: { fontSize: 13, color: RED } }, failureText(entry, p.failure)));
    if (p.redrawError) {
      const a = ageSince(entry.updated, now);
      lines.push(h("div", { key: "rerr", style: { fontSize: 13, color: RED } },
        "Couldn't redraw (" + p.redrawError + "). Showing the last map" + (a ? ", from " + a + " ago" : "") + "."));
    }
    if (p.openError) lines.push(h("div", { key: "oerr", style: { fontSize: 13, color: RED } }, p.openError));
    return lines;
  }

  function frameArea(slug) {
    const p = store.proj(slug);
    if (p.mapState === "refused") {
      return note("Refused: this project's map file name is not a plain .html name, so Talos never reads it.", { color: RED });
    }
    if (p.raw === null && p.mapState === "missing") return note("The map file isn't there yet. It appears after the next redraw; run `talos.sh map` in the repo to draw it now.");
    if (p.raw === null && p.mapState === "unreadable") return note("Couldn't read the map file.", { color: RED });
    if (p.raw === null) return note("Loading the map…");
    return h("iframe", {
      key: "frame", title: "Talos project map: " + slug, sandbox: SANDBOX, srcDoc: p.frame,
      style: { flex: "1 1 auto", minHeight: 0, width: "100%", border: "1px solid var(--border-standard, #8886)", borderRadius: "var(--radius-panel, 10px)", background: "var(--bg-panel, transparent)" },
    });
  }

  function ProjectView() {
    const slug = state.view;
    const entry = state.reg.entries[slug];
    if (!entry) return ProjectsView();
    const now = store.now();
    const p = store.proj(slug);
    const mapAge = ageSince(entry.updated, now);
    const readT = isoMs(entry.state_read);
    const sub = [
      mapAge ? "map " + mapAge + " old" : null,
      providerOf(entry).name + " read " + (readT === null ? "never" : age(now - readT) + " ago"),
    ].filter(Boolean).join(" · ");
    const options = Object.keys(state.reg.entries).map((s) =>
      h("option", { key: s, value: s }, s + " · " + tilesOf(state.reg.entries[s]).needs + " need you"));
    const bar = h("div", { key: "bar", className: "tmap-bar-row", style: { display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap", flex: "none" } },
      button("← Projects", () => store.showProjects()),
      h("select", {
        className: "tmap-pick", value: slug, "aria-label": "Project",
        onChange: (e) => store.openProject(e && e.target ? e.target.value : slug),
        style: { font: "inherit", padding: "4px 6px", borderRadius: 6, border: "1px solid var(--border-standard, #8886)", background: "transparent", color: "inherit" },
      }, options),
      h("span", { style: { color: MUTED, fontSize: 12, flex: "1 1 auto" } }, sub),
      button("Refresh", () => store.refresh(slug), { disabled: store.noRoot(slug) || !!p.reading || store.isQueued(slug) }),
      button("Open in browser", () => store.openInBrowser(slug), { disabled: !validFile(entry.file) }));
    return h("div", { className: "tmap-project", style: { display: "flex", flexDirection: "column", gap: 10, flex: "1 1 auto", minHeight: 0 } },
      bar, ...banner(slug, entry), frameArea(slug));
  }

  function Page() {
    useTick();
    useEffect(() => {
      store.mount();
      return () => store.unmount();
    }, []);
    let view;
    try {
      view = state.view ? ProjectView() : ProjectsView();
    } catch (e) {
      view = note("Talos couldn't draw this page (" + msg(e) + "). Try Refresh all.", { color: RED });
    }
    return h("div", {
      className: "tmap-page",
      style: {
        display: "flex", flexDirection: "column", height: "100%", minHeight: 0, boxSizing: "border-box",
        padding: "var(--space-panel-inset, 16px)", overflow: state.view ? "hidden" : "auto",
      },
    }, h("style", null, CSS), view);
  }

  function Badge() {
    useTick();
    useEffect(() => {
      store.retain();
      store.loadRegistry();
      return () => store.release();
    }, []);
    try {
      if (state.reg.state !== "ok") return null;
      const total = needsTotal(state.reg.entries);
      if (total <= 0) return null;
      return h("span", {
        className: "tmap-badge", "aria-label": total + " need you",
        style: { fontSize: 11, minWidth: 16, textAlign: "center", padding: "0 5px", borderRadius: 999, background: RED, color: "#fff" },
      }, String(total));
    } catch (e) {
      return null;
    }
  }

  function Icon(props) {
    const size = (props && props.size) || 16;
    return h("svg", { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 2, "aria-hidden": "true" },
      h("rect", { x: 3, y: 4, width: 18, height: 16, rx: 2 }),
      h("path", { d: "M3 9h18M9 9v11" }));
  }

  return { Page, Badge, Icon };
}

// ── entry ────────────────────────────────────────────────────────────────────

// Buzz calls apply(ctx). The second argument is a test seam (a fake clock, storage).
export function apply(ctx, testEnv) {
  try {
    const store = createStore(Object.assign({ host: ctx.host, theme: defaultTheme }, testEnv || {}));
    const { Page, Badge, Icon } = buildComponents(ctx.react, store);
    ctx.pages.register({ id: PAGE_ID, title: "Talos", primary: true, layout: "workspace", icon: Icon, badge: Badge, component: Page });
  } catch (e) {
    // A plugin that fails to apply must not take Buzz down with it.
    try { globalThis.console.error("talos plugin: " + msg(e)); } catch (e2) { /* nothing to report to */ }
  }
}
