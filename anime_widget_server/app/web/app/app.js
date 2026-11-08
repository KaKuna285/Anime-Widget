// Anime-Widget phone app: the same checklist as the KDE widget, live-synced
// through the Home Assistant add-on.

import { AnimeApi, ApiError } from "./api.js";

const api = new AnimeApi();
const $ = (s, el = document) => el.querySelector(s);

// ---------------- icons ----------------
const svg = (d) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
const I = {
  check: svg('<path d="M5 12.5 10 17 19 7"/>'),
  undo: svg('<path d="M9 14 4 9l5-5"/><path d="M4 9h11a5 5 0 0 1 0 10h-3"/>'),
  more: svg('<circle cx="12" cy="5" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="12" cy="19" r="1.6"/>'),
  list: svg('<path d="M8 6h13M8 12h13M8 18h13"/><circle cx="3.5" cy="6" r="1"/><circle cx="3.5" cy="12" r="1"/><circle cx="3.5" cy="18" r="1"/>'),
  gear: svg('<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1Z"/>'),
  trash: svg('<path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14"/>'),
  x: svg('<path d="M6 6l12 12M18 6 6 18"/>'),
  off: svg('<path d="M2 2l20 20"/><path d="M8.5 16.5a5 5 0 0 1 7 0M5 13a10 10 0 0 1 5.2-2.8M19 13a10 10 0 0 0-2.2-1.6M2 8.8a15 15 0 0 1 4.2-2.7M22 8.8A15 15 0 0 0 10.7 5"/><circle cx="12" cy="20" r="1"/>'),
  tv: svg('<rect x="3" y="5" width="18" height="12" rx="2"/><path d="M8 21h8"/>'),
  search: svg('<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>'),
  party: svg('<path d="M4 20 9 7l8 8-13 5Z"/><path d="M14 4v2M19 9h2M17 6l1.5-1.5"/>'),
};

const esc = (t) => String(t ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

// ---------------- settings (this browser only) ----------------
const PREFS_KEY = "animewidget_prefs";
const prefs = Object.assign({ preferEnglishTitle: false, confirmUndo: true, askToGrade: true },
  (() => { try { return JSON.parse(localStorage.getItem(PREFS_KEY) || "{}"); } catch { return {}; } })());
const savePrefs = () => { try { localStorage.setItem(PREFS_KEY, JSON.stringify(prefs)); } catch {} };

// ---------------- state ----------------
let data = { episodes: [], history: [], seriesMap: {}, pendingMatches: {}, pendingGrades: {}, batchWarnings: {}, lastRemoved: {} };
let rev = -1;
let online = true;
const busy = new Set();            // episodes with a request in flight
const doneFlash = new Set();       // just-ticked episodes, shown checked until they leave
const laterMatches = new Set();    // match prompts dismissed with "Later" (this visit)
let openSheet = null;              // { kind, key, close, update }
let needToken = false;

const epId = (e) => `${e.series}|${e.kind || "episode"}|${e.season}|${e.episode}`;
const keyOf = (e) => e.seriesKey || e.series;

// ---------------- labels (same rules as the widget) ----------------
function preferredTitle(entry) {
  if (!entry) return null;
  if (prefs.preferEnglishTitle && entry.englishTitle) return entry.englishTitle;
  return entry.title || null;
}

function seriesKeyLabel(key) {
  const parts = key.split("::");
  if (parts.length !== 2) return key;
  const m = parts[1].match(/^(episode|movie|ova|special)S(\d+)$/);
  if (!m) return key;
  if (m[1] === "episode") return `${parts[0]} Season ${parseInt(m[2])}`;
  return `${parts[0]} (${m[1] === "ova" ? "OVA" : m[1][0].toUpperCase() + m[1].slice(1)})`;
}

function groupLabel(key) {
  const entry = data.seriesMap[key];
  return (entry && entry.malId && preferredTitle(entry)) || seriesKeyLabel(key);
}

function kindName(kind) {
  return kind === "ova" ? "OVA" : kind === "ona" ? "ONA" : kind[0].toUpperCase() + kind.slice(1);
}

function episodeLabel(e) {
  const kind = e.kind || "episode";
  if (kind === "episode") return `Episode ${e.episode}`;
  return (e.kindCount || 1) > 1 ? `${kindName(kind)} ${e.episode}` : kindName(kind);
}

function groupedEpisodes() {
  const groups = {};
  const prio = { episode: 0, special: 1, ova: 2, movie: 3 };
  for (const e of data.episodes) (groups[keyOf(e)] ||= []).push({ ...e });
  return Object.entries(groups).map(([key, eps]) => {
    const counts = {};
    eps.forEach((e) => { const k = e.kind || "episode"; counts[k] = (counts[k] || 0) + 1; });
    eps.forEach((e) => (e.kindCount = counts[e.kind || "episode"]));
    eps.sort((a, b) => ((prio[a.kind || "episode"] ?? 99) - (prio[b.kind || "episode"] ?? 99)) || a.season - b.season || a.episode - b.episode);
    return { key, label: groupLabel(key), entry: data.seriesMap[key], episodes: eps };
  }).sort((a, b) => a.label.localeCompare(b.label));
}

// ---------------- toast ----------------
let toastTimer;
function toast(msg, error = false) {
  const t = $("#toast");
  t.textContent = msg;
  t.className = "show" + (error ? " error" : "");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.className = ""), error ? 6000 : 2500);
}
const fail = (e) => toast(e?.message || String(e), true);

// ---------------- rendering ----------------
function render() {
  const groups = groupedEpisodes();
  $("#count").textContent = data.episodes.length || "";
  $("#btn-undo").disabled = !(data.history.length || Object.keys(data.lastRemoved || {}).length);
  const conn = $("#conn");
  conn.hidden = online;
  conn.innerHTML = `${I.off}<span>Offline</span>`;

  // notices: batch warnings + snoozed match prompts
  const notices = [];
  for (const [key, w] of Object.entries(data.batchWarnings || {})) {
    notices.push(`<div class="notice"><p>${esc(w.message || w.warning || key)}</p>
      <button class="icon-btn" data-dismiss="${esc(key)}" aria-label="Dismiss">${I.x}</button></div>`);
  }
  const snoozed = [...laterMatches].filter((k) => k in data.pendingMatches);
  if (snoozed.length) {
    notices.push(`<div class="notice action" data-unsnooze><p>${snoozed.length} series waiting to be matched to MyAnimeList. Tap to match.</p></div>`);
  }
  $("#notices").innerHTML = notices.join("");

  if (!groups.length) {
    $("#list").innerHTML = `<div class="empty">${I.party}<p>No new episodes.</p></div>`;
    return;
  }

  $("#list").innerHTML = groups.map((g) => {
    const pic = g.entry?.picture;
    const poster = pic
      ? `<img class="poster" src="${esc(pic)}" alt="" loading="lazy" onerror="this.replaceWith(Object.assign(document.createElement('span'),{className:'poster'}))">`
      : `<div class="poster ph">${esc(g.label.trim()[0] || "?")}</div>`;
    const sub = g.entry?.malId
      ? `${g.episodes.length} new${g.entry.numEpisodes ? ` · ${g.entry.numEpisodes} eps` : ""}`
      : g.entry?.skipped ? `${g.episodes.length} new · not on MAL` : `${g.episodes.length} new · not matched yet`;
    return `<section class="card">
      <div class="card-head">
        ${poster}
        <div class="card-title"><b>${esc(g.label)}</b><small>${esc(sub)}</small></div>
        <button class="icon-btn" data-series="${esc(g.key)}" aria-label="Series options">${I.more}</button>
      </div>
      ${g.episodes.map((e) => {
        const id = epId(e);
        const cls = busy.has(id) ? "busy" : doneFlash.has(id) ? "done" : "";
        return `<div class="ep ${cls}">
          <button class="ep-check" data-done="${esc(id)}" ${busy.has(id) ? "disabled" : ""}>
            <span class="box">${I.check}</span><span class="ep-label">${esc(episodeLabel(e))}</span>
          </button>
          <button class="icon-btn" data-ep="${esc(id)}" aria-label="Episode options">${I.more}</button>
        </div>`;
      }).join("")}
    </section>`;
  }).join("");
}

function findEpisode(id) { return data.episodes.find((e) => epId(e) === id); }

// ---------------- sheets ----------------
function sheet(kind, key, html, mount) {
  closeSheet();
  const root = $("#sheet-root");
  const scrim = document.createElement("div");
  scrim.className = "scrim";
  scrim.innerHTML = `<div class="sheet" role="dialog" aria-modal="true"><div class="grab"></div>${html}</div>`;
  root.appendChild(scrim);
  const el = $(".sheet", scrim);
  const s = { kind, key, el, update: null, close: () => { scrim.remove(); if (openSheet === s) openSheet = null; } };
  scrim.addEventListener("click", (ev) => { if (ev.target === scrim) { s.onDismiss?.(); s.close(); } });
  openSheet = s;
  mount?.(el, s);
  return s;
}
function closeSheet() { openSheet?.close(); }
addEventListener("keydown", (e) => { if (e.key === "Escape" && openSheet) { openSheet.onDismiss?.(); closeSheet(); } });

function confirmSheet(title, text, okLabel, onOk, danger = false) {
  sheet("confirm", null, `<h2>${esc(title)}</h2><p class="sub">${esc(text)}</p>
    <div class="actions"><button class="btn ghost" data-x>Cancel</button>
    <button class="btn ${danger ? "danger" : "primary"}" data-ok>${esc(okLabel)}</button></div>`,
  (el, s) => {
    $("[data-x]", el).onclick = s.close;
    $("[data-ok]", el).onclick = () => { s.close(); onOk(); };
  });
}

// ---------------- actions ----------------
async function run(promise, okToast = true) {
  try {
    const r = await promise;
    if (okToast && r?.message) toast(r.message);
    await refresh();
    return r;
  } catch (e) { fail(e); await refresh().catch(() => {}); }
}

async function markDone(id) {
  const ep = findEpisode(id);
  if (!ep || busy.has(id)) return;
  busy.add(id); render();
  try {
    const r = await api.post("/api/done", { series: ep.series, season: ep.season, episode: ep.episode, kind: ep.kind || "episode" }, { timeout: 60000 });
    busy.delete(id); doneFlash.add(id); render();
    toast(`${groupLabel(keyOf(ep))}: ${episodeLabel(ep)} watched${r?.message && !/^Marked/.test(r.message) ? "\n" + r.message : ""}`);
    setTimeout(() => { doneFlash.delete(id); }, 1500);
  } catch (e) {
    busy.delete(id); render(); fail(e);
  }
  await refresh();
}

function undo() {
  const go = () => run(api.post("/api/undo"));
  if (prefs.confirmUndo) {
    confirmSheet("Undo last action?", "This undoes the most recent tick or removal, whichever came last, including the MyAnimeList change.", "Undo", go);
  } else go();
}

function episodeMenu(id) {
  const ep = findEpisode(id);
  if (!ep) return;
  sheet("ep", id, `<h2>${esc(groupLabel(keyOf(ep)))}</h2><p class="sub">${esc(episodeLabel(ep))}</p>
    <div class="menu">
      <button data-a="done">${I.check}Mark watched</button>
      <button data-a="remove" class="danger">${I.trash}Remove from list</button>
    </div>`, (el, s) => {
    $('[data-a="done"]', el).onclick = () => { s.close(); markDone(id); };
    $('[data-a="remove"]', el).onclick = () => {
      s.close();
      run(api.post("/api/remove", { series: ep.series, kind: ep.kind || "episode", season: ep.season, episode: ep.episode }));
    };
  });
}

function seriesMenu(key) {
  const label = groupLabel(key);
  const count = data.episodes.filter((e) => keyOf(e) === key).length;
  const mal = data.seriesMap[key]?.malId;
  sheet("series", key, `<h2>${esc(label)}</h2><p class="sub">${count} episode(s) in the list</p>
    <div class="menu">
      ${mal ? `<button data-a="mal">${I.tv}Open on MyAnimeList</button>` : ""}
      <button data-a="match">${I.search}${mal ? "Change MAL match" : "Match to MyAnimeList"}</button>
      <button data-a="delete" class="danger">${I.trash}Delete series</button>
    </div>`, (el, s) => {
    $('[data-a="mal"]', el)?.addEventListener("click", () => { s.close(); open(`https://myanimelist.net/anime/${mal}`, "_blank"); });
    $('[data-a="match"]', el).onclick = () => { s.close(); laterMatches.delete(key); remap(key, key.split("::")[0]); };
    $('[data-a="delete"]', el).onclick = () => {
      s.close();
      confirmSheet("Delete series?", `Remove all ${count} episode(s) of "${label}" from the list? MyAnimeList isn't changed, and Undo brings them back.`,
        "Delete series", () => run(api.post("/api/remove-series", { seriesKey: key, label })), true);
    };
  });
}

async function remap(key, query) {
  await run(api.post("/api/series/remap", { seriesKey: key, query }), false);
  maybePrompt();
}

// ---------------- MAL match prompt ----------------
function parseMalId(text) {
  const m = String(text).match(/anime\/(\d+)/) || String(text).match(/^\s*(\d+)\s*$/);
  return m ? parseInt(m[1]) : -1;
}

function matchSheet(key) {
  let selected = null;
  const s = sheet("match", key, `<h2>Which anime is this?</h2><p class="sub" data-q></p>
    <p class="sub" data-status></p>
    <div class="row"><input type="search" data-query placeholder="Search MyAnimeList" enterkeyhint="search">
      <button class="btn" data-search>${I.search}</button></div>
    <div class="cands" data-cands></div>
    <div class="row"><input type="text" data-id placeholder="Or MAL ID / myanimelist.net link" inputmode="url">
      <button class="btn" data-useid disabled>Use ID</button></div>
    <div class="actions">
      <button class="btn ghost" data-later>Later</button>
      <button class="btn" data-skip>Not on MAL</button>
      <button class="btn primary" data-confirm disabled>Confirm</button>
    </div>`, (el, s) => {
    const entry = () => data.pendingMatches[key] || {};
    $("[data-query]", el).value = entry().query || key.split("::")[0];
    const search = () => { const q = $("[data-query]", el).value.trim(); if (q) remap(key, q); };
    $("[data-search]", el).onclick = search;
    $("[data-query]", el).onkeydown = (e) => { if (e.key === "Enter") search(); };
    const idInput = $("[data-id]", el);
    idInput.oninput = () => ($("[data-useid]", el).disabled = parseMalId(idInput.value) < 1);
    $("[data-useid]", el).onclick = () => {
      s.close();
      run(api.post("/api/series/confirm", { seriesKey: key, malId: parseMalId(idInput.value), title: "" }));
    };
    $("[data-later]", el).onclick = () => { laterMatches.add(key); s.close(); render(); maybePrompt(); };
    s.onDismiss = () => { laterMatches.add(key); setTimeout(() => { render(); maybePrompt(); }); };
    $("[data-skip]", el).onclick = () => { s.close(); run(api.post("/api/series/skip", { seriesKey: key })).then(maybePrompt); };
    $("[data-confirm]", el).onclick = () => {
      if (!selected) return;
      s.close();
      run(api.post("/api/series/confirm", { seriesKey: key, malId: selected.id, title: selected.title })).then(maybePrompt);
    };

    s.update = () => {
      const p = entry();
      $("[data-q]", el).textContent = `Downloaded as "${seriesKeyLabel(key)}"`;
      const st = $("[data-status]", el);
      const searching = p.status === "searching";
      st.className = "sub" + (p.status === "error" ? " err" : "");
      st.textContent = searching ? "Searching MyAnimeList…"
        : p.status === "no_results" ? `No MyAnimeList results for "${p.query || ""}". Try another search, or enter the MAL ID.`
        : p.status === "error" ? `MAL search failed: ${p.error || ""}` : "";
      st.hidden = !st.textContent;
      $("[data-search]", el).disabled = searching;
      const cands = p.candidates || [];
      if (selected && !cands.some((c) => c.id === selected.id)) selected = null;
      $("[data-cands]", el).innerHTML = cands.map((c) => `<button class="cand" data-c="${c.id}" aria-pressed="${selected?.id === c.id}">
        ${c.picture ? `<img src="${esc(c.picture)}" alt="" loading="lazy" onerror="this.replaceWith(Object.assign(document.createElement('span'),{className:'poster'}))">` : `<span class="poster"></span>`}
        <span><b>${esc(prefs.preferEnglishTitle && c.englishTitle ? c.englishTitle : c.title)}</b>
        <small>${esc([c.mediaType && c.mediaType.toUpperCase(), c.startYear].filter(Boolean).join(" · "))}</small></span></button>`).join("");
      el.querySelectorAll("[data-c]").forEach((b) => (b.onclick = () => {
        selected = cands.find((c) => c.id === +b.dataset.c);
        s.update();
      }));
      $("[data-confirm]", el).disabled = !selected;
    };
    s.update();
  });
  return s;
}

// ---------------- grading ----------------
function gradeSheet(key) {
  const g = data.pendingGrades[key];
  let score = null;
  sheet("grade", key, `<h2>Finished!</h2><p class="sub">You've watched all of <b>${esc(preferredTitle(g) || key)}</b>. Rate it on MyAnimeList?</p>
    <div class="scores">${[1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((n) => `<button data-s="${n}" aria-pressed="false">${n}</button>`).join("")}</div>
    <div class="actions"><button class="btn" data-skip>Skip rating</button>
    <button class="btn primary" data-ok disabled>Rate</button></div>`, (el, s) => {
    el.querySelectorAll("[data-s]").forEach((b) => (b.onclick = () => {
      score = +b.dataset.s;
      el.querySelectorAll("[data-s]").forEach((x) => x.setAttribute("aria-pressed", String(+x.dataset.s === score)));
      $("[data-ok]", el).disabled = false;
    }));
    $("[data-skip]", el).onclick = () => { s.close(); run(api.post("/api/grade", { seriesKey: key, score: null })).then(maybePrompt); };
    $("[data-ok]", el).onclick = () => { s.close(); run(api.post("/api/grade", { seriesKey: key, score })).then(maybePrompt); };
    s.onDismiss = () => setTimeout(maybePrompt, 0);
  });
}

// Show the next prompt that needs attention: grades first, then matches.
let gradeSnoozed = new Set();
function maybePrompt() {
  if (openSheet) {
    // close prompts that were answered elsewhere (widget, other phone)
    if (openSheet.kind === "match" && !(openSheet.key in data.pendingMatches)) closeSheet();
    else if (openSheet.kind === "grade" && !(openSheet.key in data.pendingGrades)) closeSheet();
    else { openSheet.update?.(); return; }
  }
  for (const key of Object.keys(data.pendingGrades)) {
    if (gradeSnoozed.has(key)) continue;
    if (!prefs.askToGrade) { gradeSnoozed.add(key); api.post("/api/grade", { seriesKey: key, score: null }).then(refresh).catch(fail); continue; }
    gradeSnoozed.add(key);   // ask once per visit; it stays pending on the server
    gradeSheet(key);
    return;
  }
  for (const [key, p] of Object.entries(data.pendingMatches)) {
    if (laterMatches.has(key)) continue;
    if (["ready", "no_results", "error"].includes(p.status)) { matchSheet(key); return; }
  }
}

// ---------------- manage series ----------------
function manageSheet() {
  let showFinished = false;
  sheet("manage", null, `<h2>Series matches</h2><p class="sub">Search MyAnimeList again, or set the MAL ID by hand.</p><div data-body></div>`, (el, s) => {
    s.update = () => {
      const active = new Set(data.episodes.map(keyOf));
      const all = Object.entries(data.seriesMap).sort((a, b) => groupLabel(a[0]).localeCompare(groupLabel(b[0])));
      const act = all.filter(([k]) => active.has(k));
      const fin = all.filter(([k]) => !active.has(k));
      const item = ([k, e]) => `<div class="series-item" data-k="${esc(k)}">
        <b>${esc(groupLabel(k))}</b>
        <small>${esc(k)} · ${e.skipped ? "not on MAL" : e.malId ? `MAL ${e.malId}` : "unmatched"}</small>
        <div class="row"><input type="search" placeholder="Search MAL as…" value="${esc(k.split("::")[0])}" data-q>
          <button class="btn" data-search>${I.search}</button></div>
        <div class="row"><input type="text" placeholder="MAL ID or link" data-id inputmode="url">
          <button class="btn" data-set>Set</button></div>
      </div>`;
      $("[data-body]", el).innerHTML =
        (act.length ? act.map(item).join("") : `<p class="sub">No series with episodes in the list.</p>`) +
        (fin.length ? `<hr><button class="btn ghost" data-fin>${showFinished ? "Hide" : "Show"} ${fin.length} finished series</button>
          ${showFinished ? fin.map(item).join("") : ""}` : "");
      $("[data-fin]", el)?.addEventListener("click", () => { showFinished = !showFinished; s.update(); });
      el.querySelectorAll(".series-item").forEach((row) => {
        const k = row.dataset.k;
        $("[data-search]", row).onclick = () => { s.close(); laterMatches.delete(k); remap(k, $("[data-q]", row).value.trim()); };
        $("[data-set]", row).onclick = () => {
          const id = parseMalId($("[data-id]", row).value);
          if (id < 1) return toast("Enter a MAL ID or a myanimelist.net/anime/… link", true);
          run(api.post("/api/series/confirm", { seriesKey: k, malId: id, title: "" }));
        };
      });
    };
    s.update();
  });
}

// ---------------- settings ----------------
function settingsSheet() {
  sheet("settings", null, `<h2>Settings</h2><p class="sub">Saved in this browser.</p>
    <label class="switch-row">Prefer English titles <input type="checkbox" data-p="preferEnglishTitle"></label>
    <label class="switch-row">Confirm before undo <input type="checkbox" data-p="confirmUndo"></label>
    <label class="switch-row">Ask for a rating when a show is finished <input type="checkbox" data-p="askToGrade"></label>
    <hr><div class="kv" data-info>Loading server info…</div>
    <div class="actions">${api.viaHA ? `<button class="btn ghost" data-logout>Log out of this page</button>` : ""}</div>`, (el, s) => {
    el.querySelectorAll("[data-p]").forEach((cb) => {
      cb.checked = !!prefs[cb.dataset.p];
      cb.onchange = () => { prefs[cb.dataset.p] = cb.checked; savePrefs(); render(); };
    });
    $("[data-logout]", el)?.addEventListener("click", () => {
      try { localStorage.removeItem("animewidget_ha_tokens"); } catch {}
      location.reload();
    });
    api.get("/api/info").then((info) => {
      $("[data-info]", el).innerHTML = `Server <b>v${esc(info.version)}</b> · MyAnimeList <b>${info.mal?.loggedIn ? "logged in" : "not logged in"}</b>` +
        (info.mal?.loggedIn ? "" : `<br>Log in from the add-on's page in Home Assistant.`);
    }).catch((e) => ($("[data-info]", el).textContent = e.message));
  });
}

// ---------------- sync ----------------
async function refresh() {
  try {
    const s = await api.state();
    data = s; rev = s.rev; setOnline(true);
    render();
    maybePrompt();
  } catch (e) {
    if (e instanceof ApiError && e.status === 401 && !api.viaHA) { needToken = true; return askToken(); }
    setOnline(false);
    throw e;
  }
}

function setOnline(v) { if (online !== v) { online = v; render(); } }

async function liveLoop() {
  for (;;) {
    try {
      const r = await api.wait(rev);
      if (r.changed) await refresh();
    } catch {
      setOnline(false);
      await new Promise((r) => setTimeout(r, 5000));
      await refresh().catch(() => {});
    }
  }
}

document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh().catch(() => {}); });

// ---------------- events ----------------
document.addEventListener("click", (ev) => {
  const t = ev.target.closest("button, [data-unsnooze]");
  if (!t) return;
  if (t.dataset.done) markDone(t.dataset.done);
  else if (t.dataset.ep) episodeMenu(t.dataset.ep);
  else if (t.dataset.series) seriesMenu(t.dataset.series);
  else if (t.dataset.dismiss) run(api.post("/api/batch-warnings/dismiss", { key: t.dataset.dismiss }), false);
  else if ("unsnooze" in t.dataset) { laterMatches.clear(); maybePrompt(); render(); }
});
$("#btn-undo").innerHTML = I.undo;
$("#btn-manage").innerHTML = I.list;
$("#btn-settings").innerHTML = I.gear;
$("#btn-undo").onclick = undo;
$("#btn-manage").onclick = manageSheet;
$("#btn-settings").onclick = settingsSheet;

// ---------------- boot ----------------
function askToken() {
  const boot = $("#boot");
  boot.hidden = false;
  boot.innerHTML = `<h2>API token</h2><p>Paste the token shown on the add-on's page in Home Assistant.</p>
    <div class="row" style="width:min(420px,100%)"><input type="password" id="tok" autocomplete="off">
    <button class="btn primary" id="tokok">Save</button></div>`;
  $("#tokok").onclick = () => { api.setApiToken($("#tok").value.trim()); location.reload(); };
}

(async function boot() {
  const stage = (t) => ($("#boot-stage").textContent = t);
  try {
    await api.init(stage);
    stage("Loading your list");
    await refresh();
    if (needToken) return;
    $("#boot").hidden = true;
    liveLoop();
  } catch (e) {
    if ($("#boot").querySelector("#tok")) return;
    $("#boot").innerHTML = `<p class="err">${esc(e.message || e)}</p><button class="btn" onclick="location.reload()">Try again</button>`;
  }
})();
