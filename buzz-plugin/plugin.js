// Talos for Buzz (#902): every Talos project and its map inside Buzz.
//
// Plain JavaScript, no build step, no npm dependency. install.sh --global copies
// this file to ${TALOS_HOME:-~/.talos}/buzz-plugin/ with __TALOS_HOME__ replaced
// by the absolute TALOS_HOME, next to a generated manifest.json. The plugin holds
// no token and makes no network call: it reads maps/index.json, the map pages and
// maps/.refresh/<file>.json, and spawns the one declared process,
// scripts/talos-buzz.sh <redraw|refresh|forget|open> <slug> or open-url <slug> <url>.
//
// Layout: pure helpers (exported for tests), createStore (all state and every
// spawn, no React), the components (thin views over the store), apply.

export const inject = ["react", "pages", "host"];

const TALOS_HOME = "__TALOS_HOME__";
const MAPS = TALOS_HOME + "/maps";
const PROCESS_ID = "talos";
const PAGE_ID = "talos.map";
// Why the map frame has no popups and no scripts (#917): Buzz opens no new
// windows, and its CSP (script-src 'self') applies to a srcdoc frame too, so an
// inline script in the map cannot relay a click either. `allow-same-origin`
// without `allow-scripts` lets this plugin read the frame's document and handle
// its clicks (openUrl below) while the map itself still runs no code.
const SANDBOX = "allow-same-origin";
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
// it there and the plugin reloads itself) and data-theme on <html>. Nothing else
// changes. No <base target="_blank">: a popup from the frame goes nowhere in Buzz
// (see SANDBOX), so the frame's clicks are handled by frameClicks instead.
export function prepareFrame(html, theme) {
  let out = String(html);
  out = out.replace(/<meta\s+http-equiv\s*=\s*["']?refresh["']?[^>]*>/gi, "");
  const attr = ' data-theme="' + (theme === "dark" ? "dark" : "light") + '"';
  out = out.replace(/<html\b([^>]*)>/i, (m, attrs) => {
    const rest = attrs.replace(/\sdata-theme\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/i, "");
    return "<html" + rest + attr + ">";
  });
  return out;
}

// The map frame runs no code (see SANDBOX), so the plugin handles its clicks from
// outside, on the frame's document: an http(s) link opens through openUrl, a
// #fragment link scrolls that element of the frame into view, every other link
// does nothing. Middle-click opens an http(s) link the same way. Called on every
// load of the frame, since a redraw replaces srcDoc and so the document.
export function attachFrameClicks(doc, openUrl) {
  const linkOf = (ev) => {
    let t = ev && ev.target;
    if (t && typeof t.closest !== "function") t = t.parentElement;
    return t && typeof t.closest === "function" ? t.closest("a[href]") : null;
  };
  const isWeb = (href) => /^https?:\/\//i.test(href);
  doc.addEventListener("click", (ev) => {
    const a = linkOf(ev);
    if (!a) return;
    const href = String(a.getAttribute("href") || "");
    ev.preventDefault();
    if (isWeb(href)) {
      openUrl(href);
    } else if (href.startsWith("#")) {
      let id = href.slice(1);
      try { id = decodeURIComponent(id); } catch (e) { /* keep the raw fragment */ }
      const el = id ? doc.getElementById(id) : null;
      if (el && typeof el.scrollIntoView === "function") el.scrollIntoView();
    }
  });
  doc.addEventListener("auxclick", (ev) => {
    if (!ev || ev.button !== 1) return;
    const a = linkOf(ev);
    if (!a) return;
    const href = String(a.getAttribute("href") || "");
    ev.preventDefault();
    if (isWeb(href)) openUrl(href);
  });
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

  async function runVerb(verb, slug, onLine, extra = []) {
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
      child = await host.spawn(PROCESS_ID, { args: [verb, slug, ...extra], onStdout: feed, onStderr: () => {} });
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
  async function runOutcome(verb, slug, extra = []) {
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
    }, extra);
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

  // One link in the system browser (#917). It spawns at once, outside the queue:
  // it reads and writes nothing, so a running refresh must not delay a click.
  async function openUrl(slug, url) {
    const mine = gen;
    const p = proj(slug);
    p.openError = "";
    const out = await runOutcome("open-url", slug, [url]);
    if (mine !== gen) return;
    if (!out.ok) p.openError = "Couldn't open the link in the browser: " + (out.failure.detail || out.failure.reason);
    emit();
  }

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
    showProjects, openProject, refresh, refreshAll, askForget, cancelForget, forget, openInBrowser, openUrl,
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

// Colours come from Buzz's own Radix scales (--red-3 tint, --red-11 text, and
// so on), which switch with Buzz's light/dark mode. The fallbacks are the
// approved comp's light palette, for a Buzz without those tokens.
const CSS = [
  ".tmap-page{--tm-red:var(--red-11,#d33a3a);--tm-redbg:var(--red-3,#fde8e8);--tm-blue:var(--blue-11,#2f63d6);--tm-bluebg:var(--blue-3,#e6eefc);",
  "--tm-amber:var(--amber-11,#a86a00);--tm-amberbg:var(--amber-3,#fdf1dc);--tm-sub:var(--text-secondary,#6b6b74);",
  "--tm-border:var(--border-standard,rgba(127,127,127,.28));--tm-panel:var(--bg-panel,transparent);--tm-raised:rgba(127,127,127,.07);",
  "display:flex;flex-direction:column;height:100%;min-height:0;box-sizing:border-box;padding:18px 20px;font-size:14px;line-height:1.45}",
  ".tmap-page *{box-sizing:border-box}",
  ".tmap-projects{display:flex;flex-direction:column;gap:14px;width:100%}",
  ".tmap-head{display:flex;gap:10px;align-items:center;flex-wrap:wrap}",
  ".tmap-head h2{margin:0;font-size:18px;font-weight:600}",
  ".tmap-sub{color:var(--tm-sub);font-size:12.5px}",
  ".tmap-grow{flex:1 1 160px;min-width:0}",
  ".tmap-btn{cursor:pointer;font:inherit;font-size:12.5px;line-height:1.4;padding:5px 10px;border-radius:7px;border:1px solid var(--tm-border);background:var(--tm-raised);color:inherit;white-space:nowrap}",
  ".tmap-btn:hover:not(:disabled){border-color:var(--tm-blue)}",
  ".tmap-btn:disabled{opacity:.5;cursor:default}",
  ".tmap-btn.tmap-ic-refresh::before{content:'\\21BB';margin-right:5px}",
  ".tmap-btn.tmap-ic-out::after{content:'\\2197';margin-left:5px}",
  ".tmap-btn.tmap-linkbtn{border:0;background:none;padding:0;color:var(--tm-blue);font-size:12.5px}",
  ".tmap-btn.tmap-linkbtn:hover{text-decoration:underline}",
  ".tmap-btn.tmap-danger{color:var(--tm-red)}",
  ".tmap-btn:focus-visible,.tmap-link:focus-visible,.tmap-pick:focus-visible{outline:2px solid var(--tm-blue);outline-offset:2px}",
  ".tmap-cards{display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(min(100%,420px),1fr));align-items:stretch}",
  ".tmap-card[data-wide=true]{grid-column:1/-1}",
  ".tmap-card{border:1px solid var(--tm-border);border-radius:10px;background:var(--tm-raised);overflow:hidden;display:flex;flex-direction:column}",
  ".tmap-card:hover{border-color:var(--tm-blue)}",
  ".tmap-card[data-stale=true]{opacity:.55}",
  ".tmap-ctop{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:8px 12px;align-items:center;padding:12px 14px 10px}",
  ".tmap-name{display:flex;gap:6px;align-items:center;min-width:0}",
  ".tmap-btn.tmap-open{border:0;background:none;padding:0;font-weight:600;font-size:14.5px;overflow:hidden;text-overflow:ellipsis}",
  ".tmap-btn.tmap-open:hover{text-decoration:underline}",
  ".tmap-prov{font-size:11px;color:var(--tm-sub);border:1px solid var(--tm-border);border-radius:5px;padding:0 5px;white-space:nowrap}",
  ".tmap-chips{display:flex;gap:6px;flex-wrap:wrap;grid-column:1/-1}",
  ".tmap-chip{font-size:12px;border-radius:999px;padding:2px 9px;background:var(--tm-panel);border:1px solid var(--tm-border);white-space:nowrap}",
  ".tmap-chip b{font-weight:700}",
  ".tmap-chip.red{background:var(--tm-redbg);color:var(--tm-red);border-color:transparent}",
  ".tmap-chip.blue{background:var(--tm-bluebg);color:var(--tm-blue);border-color:transparent}",
  ".tmap-pill{font-size:11.5px;border-radius:999px;padding:2px 9px;white-space:nowrap}",
  ".tmap-pill.run{background:var(--tm-bluebg);color:var(--tm-blue);font-weight:600}",
  ".tmap-pill.idle{background:var(--tm-panel);color:var(--tm-sub);border:1px solid var(--tm-border)}",
  ".tmap-pill.stale{background:var(--tm-amberbg);color:var(--tm-amber)}",
  ".tmap-needs{border-top:1px solid var(--tm-border);padding:6px 14px 8px;display:grid;gap:2px}",
  ".tmap-need{display:grid;grid-template-columns:auto minmax(0,1fr) auto;gap:2px 8px;align-items:baseline;font-size:12.5px;padding:3px 0;color:inherit;text-decoration:none}",
  ".tmap-need:hover .tmap-t{text-decoration:underline}",
  ".tmap-num{color:var(--tm-blue);font-weight:600}",
  ".tmap-t{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}",
  ".tmap-k{font-size:11px;color:var(--tm-red);background:var(--tm-redbg);border-radius:4px;padding:0 6px;white-space:nowrap}",
  ".tmap-why{grid-column:2/-1;color:var(--tm-sub);font-size:12px}",
  ".tmap-btn.tmap-more{justify-self:start;margin-top:2px}",
  ".tmap-msg{font-size:12px;padding:6px 14px;border-top:1px solid var(--tm-border)}",
  ".tmap-msg.err{color:var(--tm-red)}",
  ".tmap-msg.warn{color:var(--tm-amber)}",
  ".tmap-footer{margin-top:auto;border-top:1px solid var(--tm-border);padding:6px 14px;font-size:12px;color:var(--tm-sub);display:flex;gap:6px 10px;align-items:center;flex-wrap:wrap;background:var(--tm-panel)}",
  ".tmap-footer .warn{color:var(--tm-amber)}",
  ".tmap-footer .busy{color:var(--tm-blue)}",
  ".tmap-confirm{display:flex;gap:8px;align-items:center;flex-wrap:wrap;padding:8px 14px;border-top:1px solid var(--tm-border);font-size:12px}",
  ".tmap-remove{padding:0 14px 10px}",
  ".tmap-spin{display:inline-block;width:10px;height:10px;border:2px solid rgba(127,127,127,.35);border-top-color:currentColor;border-radius:50%;vertical-align:-1px;margin-right:6px;animation:tmap-rot .9s linear infinite}",
  "@keyframes tmap-rot{to{transform:rotate(360deg)}}",
  ".tmap-project{display:flex;flex-direction:column;gap:10px;flex:1 1 auto;min-height:0}",
  ".tmap-bar-row{display:flex;gap:10px;align-items:center;flex-wrap:wrap;flex:none}",
  ".tmap-pick{font:inherit;font-size:12.5px;padding:4px 8px;border-radius:7px;border:1px solid var(--tm-border);background:var(--tm-raised);color:inherit;max-width:100%}",
  ".tmap-banner{border-radius:8px;padding:8px 12px;font-size:13px;background:var(--tm-amberbg);color:var(--tm-amber);flex:none}",
  ".tmap-banner.info{background:var(--tm-bluebg);color:var(--tm-blue)}",
  ".tmap-banner.err{background:var(--tm-redbg);color:var(--tm-red)}",
  ".tmap-banner.quiet{background:var(--tm-raised);color:var(--tm-sub)}",
  ".tmap-frame{flex:1 1 auto;min-height:0;display:flex;flex-direction:column;border:1px solid var(--tm-border);border-radius:10px;overflow:hidden;background:var(--tm-panel)}",
  ".tmap-frame iframe{flex:1 1 auto;min-height:0;width:100%;border:0;display:block;background:var(--tm-panel)}",
  ".tmap-bar{height:3px;background:var(--tm-bluebg);overflow:hidden;position:relative;flex:none}",
  ".tmap-bar::after{content:'';position:absolute;top:0;bottom:0;width:35%;background:var(--tm-blue);animation:tmap-slide 1.4s ease-in-out infinite}",
  "@keyframes tmap-slide{0%{left:-35%}100%{left:100%}}",
  ".tmap-note{color:var(--tm-sub);padding:12px 0}",
  ".tmap-note.err{color:var(--tm-red)}",
  ".tmap-empty{border:1px dashed var(--tm-border);border-radius:10px;padding:28px;text-align:center;color:var(--tm-sub)}",
  "@media (max-width:640px){.tmap-page{padding:12px}.tmap-ctop{grid-template-columns:1fr}}",
  "@media (prefers-reduced-motion:reduce){.tmap-spin,.tmap-bar::after{animation:none}}",
].join("");

function buildComponents(React, store) {
  const h = React.createElement;
  const { useState, useEffect } = React;
  const state = store.state;

  function useTick() {
    const [, set] = useState(0);
    useEffect(() => store.subscribe(() => set((n) => n + 1)), []);
  }

  const note = (text, cls) => h("div", { className: "tmap-note" + (cls ? " " + cls : ""), role: "status" }, text);

  const button = (label, onClick, opts) => {
    const o = opts || {};
    return h("button", { type: "button", className: "tmap-btn" + (o.cls ? " " + o.cls : ""), onClick, disabled: !!o.disabled, title: o.title }, label);
  };

  const spinner = () => h("span", { className: "tmap-spin", "aria-hidden": "true" });

  function chip(n, label, cls) {
    return h("span", { key: label, className: "tmap-chip" + (cls ? " " + cls : "") }, h("b", null, String(n)), " " + label);
  }

  function readingText(entry, p) {
    const secs = Math.max(0, Math.floor((store.now() - p.reading.since) / 1000));
    return "Reading " + providerOf(entry).name + "… " + secs + " s";
  }

  function footer(slug, entry) {
    const p = store.proj(slug);
    const now = store.now();
    const name = providerOf(entry).name;
    const items = [];
    if (p.reading) {
      items.push(h("span", { key: "busy", className: "busy" }, spinner(), readingText(entry, p)));
    } else {
      const t = isoMs(entry.state_read);
      if (t === null) items.push(h("span", { key: "read", className: "warn" }, "never read"));
      else items.push(h("span", { key: "read", className: now - t > READ_AMBER_MS ? "warn" : "" }, name + " read " + age(now - t) + " ago"));
      if (store.isQueued(slug)) items.push(h("span", { key: "queued" }, "· refresh queued"));
    }
    return h("div", { key: "foot", className: "tmap-footer" }, items);
  }

  function pill(entry) {
    const now = store.now();
    const days = staleDays(entry, now);
    if (days > 0) return h("span", { className: "tmap-pill stale" }, "Not updated in " + days + " days");
    if (isRunning(entry, now)) {
      const run = entry.run || {};
      const parts = ["Running"];
      if (run.role && run.issue) parts.push(run.role + " on #" + run.issue);
      else if (run.role) parts.push(run.role);
      const a = ageSince(run.stage_since, now);
      if (a) parts.push(a);
      return h("span", { className: "tmap-pill run" }, parts.join(" · "));
    }
    const a = ageSince(entry.updated, now);
    return h("span", { className: "tmap-pill idle" }, "Idle" + (a ? " · map " + a + " old" : ""));
  }

  function needRows(slug, entry) {
    const now = store.now();
    const rows = Array.isArray(entry.needs) ? entry.needs.slice(0, 3) : [];
    return rows.map((r, i) => {
      const a = ageSince(r.since, now);
      const detail = [r.why, r.next].filter(Boolean).join(" · ");
      const url = safeUrl(r.url);
      // The href stays for hover and copy; a click goes through the store (#917).
      const open = (ev) => { if (ev && ev.preventDefault) ev.preventDefault(); if (url) store.openUrl(slug, url); };
      return h("a", {
        key: "need" + i, className: "tmap-link tmap-need", href: url, rel: "noopener noreferrer",
        onClick: (ev) => { if (!ev || !ev.button) open(ev); },
        onKeyDown: (ev) => { if (ev && ev.key === "Enter") open(ev); },
      },
        h("span", { className: "tmap-num" }, "#" + r.issue),
        h("span", { className: "tmap-t" }, r.title || ""),
        h("span", { className: "tmap-k" }, [r.kind, a].filter(Boolean).join(" · ")),
        detail ? h("span", { className: "tmap-why" }, detail) : null);
    });
  }

  function card(slug, entry) {
    const p = store.proj(slug);
    const now = store.now();
    const tiles = tilesOf(entry);
    const days = staleDays(entry, now);
    const parts = [
      h("div", { key: "top", className: "tmap-ctop" },
        h("div", { className: "tmap-name" },
          h("button", { type: "button", className: "tmap-btn tmap-open", onClick: () => store.openProject(slug), title: "Open " + slug + "'s map" }, slug),
          h("span", { className: "tmap-prov" }, providerOf(entry).name)),
        pill(entry),
        h("div", { className: "tmap-chips" },
          chip(tiles.needs, "need you", tiles.needs > 0 ? "red" : ""),
          chip(tiles.in_flight, "in flight", tiles.in_flight > 0 ? "blue" : ""),
          chip(tiles.queued, "queued"),
          chip(tiles.merged_7d, "merged · 7 d"))),
    ];
    const rows = needRows(slug, entry);
    if (rows.length || tiles.needs > 3) {
      const more = tiles.needs > 3
        ? h("button", { key: "more", type: "button", className: "tmap-btn tmap-linkbtn tmap-more", onClick: () => store.openProject(slug) },
          "+" + (tiles.needs - 3) + " more · open map →")
        : null;
      parts.push(h("div", { key: "needs", className: "tmap-needs" }, rows, more));
    }
    if (!hasRoot(entry) || p.noRoot) parts.push(h("div", { key: "noroot", className: "tmap-msg warn" }, NO_ROOT_TEXT));
    if (!validFile(entry.file)) parts.push(h("div", { key: "refused", className: "tmap-msg err" }, "Refused: this project's map file name is not a plain .html name, so it is never read."));
    if (p.failure) parts.push(h("div", { key: "fail", className: "tmap-msg err" }, failureText(entry, p.failure)));
    if (p.openError) parts.push(h("div", { key: "oerr", className: "tmap-msg err" }, p.openError));
    if (p.forgetError) parts.push(h("div", { key: "ferr", className: "tmap-msg err" }, p.forgetError));
    if (days > 0) {
      if (state.confirm === slug) {
        parts.push(h("div", { key: "confirm", className: "tmap-confirm" },
          h("span", null, "Remove " + slug + " from the list? Its map file and repository are not touched."),
          button("Remove", () => store.forget(slug), { cls: "tmap-danger" }),
          button("Cancel", () => store.cancelForget())));
      } else {
        parts.push(h("div", { key: "remove", className: "tmap-remove" }, button("Remove from list", () => store.askForget(slug))));
      }
    }
    parts.push(footer(slug, entry));
    return h("div", { key: slug, className: "tmap-card", "data-slug": slug, "data-stale": days > 0 ? "true" : "false", "data-wide": rows.length ? "true" : "false" }, parts);
  }

  function ProjectsView() {
    const now = store.now();
    const entries = state.reg.entries;
    const slugs = Object.keys(entries);
    const needs = needsTotal(entries);
    const head = h("div", { key: "head", className: "tmap-head" },
      h("div", { className: "tmap-grow" },
        h("h2", null, "Talos"),
        h("div", { className: "tmap-sub" }, slugs.length + (slugs.length === 1 ? " project" : " projects") + " · " + needs + " need you")),
      button("Refresh all", () => store.refreshAll(), { cls: "tmap-ic-refresh" }));
    let body;
    if (state.reg.state === "loading") body = note("Loading Talos projects…");
    else if (state.reg.state === "none") body = h("div", { key: "empty", className: "tmap-empty", role: "status" }, "No Talos projects on this Mac yet. Run `talos.sh map` in a repo, or start a Talos run there.");
    else if (state.reg.state === "bad") body = h("div", { key: "bad", className: "tmap-banner err", role: "status" }, state.reg.error);
    else body = h("div", { key: "cards", className: "tmap-cards" }, orderEntries(entries, now).map(([slug, e]) => card(slug, e)));
    return h("div", { className: "tmap-projects" }, head, body);
  }

  function banner(slug, entry) {
    const p = store.proj(slug);
    const now = store.now();
    const lines = [];
    if (p.reading) {
      const long = now - p.reading.since >= LONG_READ_MS;
      lines.push(h("div", { key: "reading", className: "tmap-banner " + (long ? "" : "info"), role: "status" },
        spinner(),
        long
          ? "Still reading. It keeps going in the background; you can leave this page."
          : "Reading " + providerOf(entry).name + "… The map updates by itself when it's done."));
    } else if (store.isQueued(slug)) {
      lines.push(h("div", { key: "queued", className: "tmap-banner quiet" }, "refresh queued"));
    }
    if (p.redrawing) lines.push(h("div", { key: "redraw", className: "tmap-banner quiet" }, "Redrawing the map…"));
    if (store.noRoot(slug)) lines.push(h("div", { key: "noroot", className: "tmap-banner" }, NO_ROOT_TEXT));
    if (p.failure) lines.push(h("div", { key: "fail", className: "tmap-banner err" }, failureText(entry, p.failure)));
    if (p.redrawError) {
      const a = ageSince(entry.updated, now);
      lines.push(h("div", { key: "rerr", className: "tmap-banner err" },
        "Couldn't redraw (" + p.redrawError + "). Showing the last map" + (a ? ", from " + a + " ago" : "") + "."));
    }
    if (p.openError) lines.push(h("div", { key: "oerr", className: "tmap-banner err" }, p.openError));
    return lines;
  }

  function frameArea(slug) {
    const p = store.proj(slug);
    if (p.mapState === "refused") {
      return note("Refused: this project's map file name is not a plain .html name, so Talos never reads it.", "err");
    }
    if (p.raw === null && p.mapState === "missing") return h("div", { className: "tmap-empty", role: "status" }, "The map file isn't there yet. It appears after the next redraw; run `talos.sh map` in the repo to draw it now.");
    if (p.raw === null && p.mapState === "unreadable") return note("Couldn't read the map file.", "err");
    if (p.raw === null) return note("Loading the map…");
    return h("div", { key: "framebox", className: "tmap-frame" },
      p.reading ? h("div", { key: "bar", className: "tmap-bar", role: "progressbar", "aria-label": "Reading " + providerOf(state.reg.entries[slug] || {}).name }) : null,
      h("iframe", {
        key: "frame", title: "Talos project map: " + slug, sandbox: SANDBOX, srcDoc: p.frame,
        onLoad: (e) => {
          const frame = e && (e.currentTarget || e.target);
          let doc = null;
          try { doc = frame && frame.contentDocument; } catch (err) { /* not reachable: nothing to attach */ }
          if (doc) attachFrameClicks(doc, (url) => store.openUrl(slug, url));
        },
      }));
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
    const bar = h("div", { key: "bar", className: "tmap-bar-row" },
      button("← Projects", () => store.showProjects(), { cls: "tmap-linkbtn" }),
      h("select", {
        className: "tmap-pick", value: slug, "aria-label": "Project",
        onChange: (e) => store.openProject(e && e.target ? e.target.value : slug),
      }, options),
      h("span", { className: "tmap-sub tmap-grow" }, sub),
      button("Refresh", () => store.refresh(slug), { cls: "tmap-ic-refresh", disabled: store.noRoot(slug) || !!p.reading || store.isQueued(slug) }),
      button("Open in browser", () => store.openInBrowser(slug), { cls: "tmap-ic-out", disabled: !validFile(entry.file) }));
    return h("div", { className: "tmap-project" }, bar, ...banner(slug, entry), frameArea(slug));
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
      view = note("Talos couldn't draw this page (" + msg(e) + "). Try Refresh all.", "err");
    }
    return h("div", { className: "tmap-page", style: { overflow: state.view ? "hidden" : "auto" } }, h("style", null, CSS), view);
  }

  // The badge sits in Buzz's sidebar, outside the page and its stylesheet, so
  // it styles itself: Buzz's solid status red with its on-status ink.
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
        style: {
          display: "inline-block", minWidth: 18, padding: "0 6px", borderRadius: 999, textAlign: "center",
          fontSize: 11, fontWeight: 700, lineHeight: "18px", fontVariantNumeric: "tabular-nums",
          background: "var(--surface-status-danger, #ce2c31)", color: "var(--text-on-status, #fff)",
          boxShadow: "0 0 0 1px rgba(0,0,0,.12)",
        },
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
