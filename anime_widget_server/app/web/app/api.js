// Connection to the Anime-Widget server.
//
// Two ways the page can be opened:
//
//  * From Home Assistant's www folder (/local/anime-widget/), like your
//    HTML dashboard. Then we log in to HA (normal HA login page, tokens
//    remembered in this browser), open HA's websocket, ask HA for an
//    ingress session, and talk to the add-on through HA's ingress proxy.
//    Everything stays on HA's own https address (e.g. Tailscale ts.net).
//
//  * Served by the add-on itself (…/app/), either through the HA sidebar
//    (ingress, already logged in) or straight on port 8099 (then the API
//    token is asked for once and remembered in this browser).

const TOKEN_KEY = "animewidget_ha_tokens";
const API_TOKEN_KEY = "animewidget_api_token";

export class ApiError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}

export class AnimeApi {
  constructor() {
    this.viaHA = location.pathname.includes("/local/");
    this.base = null;          // URL prefix for /api/... calls
    this.ws = null;
    this.msgId = 1;
    this.pending = new Map();
    this.session = null;
  }

  // ---------------- startup ----------------

  async init(stage = () => {}) {
    if (!this.viaHA) {
      // Served by the add-on: the API is one level up from /app/.
      this.base = new URL("../", location.href).href.replace(/\/$/, "");
      return;
    }

    stage("Reading add-on info");
    const cfg = await fetch("config.json", { cache: "no-store" }).then((r) => r.json());
    this.slug = cfg.slug;

    stage("Logging in to Home Assistant");
    await this.connectWs();

    let ingressUrl = cfg.ingressUrl;
    if (!ingressUrl || !this.slug) {
      stage("Looking up the add-on");
      ({ slug: this.slug, ingressUrl } = await this.findAddon());
    }
    this.base = location.origin + ingressUrl.replace(/\/$/, "");

    stage("Opening a session to the add-on");
    await this.newSession();
    // HA expires idle ingress sessions; keep ours alive.
    setInterval(() => this.keepSessionAlive(), 60_000);
  }

  // ---------------- Home Assistant login (same flow as the dashboard) ----------------

  get clientId() { return location.origin + "/"; }

  loadTokens() { try { return JSON.parse(localStorage.getItem(TOKEN_KEY) || "null"); } catch { return null; } }
  saveTokens(t) { try { localStorage.setItem(TOKEN_KEY, JSON.stringify(t)); } catch {} }

  async tokenRequest(body) {
    const res = await fetch(`${location.origin}/auth/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: this.clientId, ...body }),
    });
    if (!res.ok) throw new Error(`Token request failed (${res.status})`);
    return res.json();
  }

  redirectToLogin() {
    try { localStorage.removeItem(TOKEN_KEY); } catch {}
    location.href = `${location.origin}/auth/authorize?` + new URLSearchParams({
      response_type: "code", client_id: this.clientId, redirect_uri: location.origin + location.pathname,
    });
    return new Promise(() => {});
  }

  async accessToken() {
    const params = new URLSearchParams(location.search);
    if (params.get("code")) {
      const t = await this.tokenRequest({ grant_type: "authorization_code", code: params.get("code") });
      const tokens = { ...t, expires: Date.now() + t.expires_in * 1000 };
      this.saveTokens(tokens);
      history.replaceState(null, "", location.pathname);
      return tokens.access_token;
    }
    let tokens = this.loadTokens();
    if (!tokens) return this.redirectToLogin();
    if (Date.now() > tokens.expires - 60_000) {
      try {
        const t = await this.tokenRequest({ grant_type: "refresh_token", refresh_token: tokens.refresh_token });
        tokens = { ...tokens, ...t, expires: Date.now() + t.expires_in * 1000 };
        this.saveTokens(tokens);
      } catch (e) {
        if (/\((400|403)\)/.test(String(e))) return this.redirectToLogin();
        throw e;
      }
    }
    return tokens.access_token;
  }

  async connectWs() {
    const token = await this.accessToken();
    const url = location.origin.replace(/^http/, "ws") + "/api/websocket";
    await new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      const timer = setTimeout(() => reject(new Error("Home Assistant didn't answer within 15 s")), 15000);
      this.ws = ws;
      ws.onmessage = (ev) => {
        const msg = JSON.parse(ev.data);
        if (msg.type === "auth_required") ws.send(JSON.stringify({ type: "auth", access_token: token }));
        else if (msg.type === "auth_ok") { clearTimeout(timer); resolve(); }
        else if (msg.type === "auth_invalid") { clearTimeout(timer); this.redirectToLogin(); }
        else if (msg.type === "result") {
          const p = this.pending.get(msg.id);
          if (p) { this.pending.delete(msg.id); msg.success ? p.resolve(msg.result) : p.reject(msg.error); }
        }
      };
      ws.onerror = () => { clearTimeout(timer); reject(new Error("Couldn't connect to Home Assistant's websocket")); };
      ws.onclose = () => {
        this.pending.forEach((p) => p.reject({ message: "disconnected" }));
        this.pending.clear();
        this.ws = null;
      };
    });
  }

  async wsSend(msg) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) await this.connectWs();
    const id = this.msgId++;
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => { this.pending.delete(id); reject(new Error(`Timed out: ${msg.type}`)); }, 20000);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(t); resolve(v); },
        reject: (e) => { clearTimeout(t); reject(e); },
      });
      this.ws.send(JSON.stringify({ id, ...msg }));
    });
  }

  // Ask Home Assistant (Supervisor) for the add-on's slug and ingress URL.
  async findAddon() {
    let addons;
    try {
      const r = await this.wsSend({ type: "supervisor/api", endpoint: "/addons", method: "get" });
      addons = r.addons || r.data?.addons || [];
    } catch (e) {
      throw new Error("Couldn't look up the add-on through Home Assistant (this needs an HA admin user). " + (e?.message || ""));
    }
    const addon = addons.find((a) => /(^|_)anime_widget_server$/.test(a.slug));
    if (!addon) throw new Error("The Anime-Widget Server add-on isn't installed.");
    const info = await this.wsSend({ type: "supervisor/api", endpoint: `/addons/${addon.slug}/info`, method: "get" });
    const url = info.ingress_url || info.data?.ingress_url;
    if (!url) throw new Error("The add-on has no ingress URL. Is it started?");
    return { slug: addon.slug, ingressUrl: url };
  }

  setCookie(session) {
    document.cookie = `ingress_session=${session};path=/api/hassio_ingress/;SameSite=Strict` +
      (location.protocol === "https:" ? ";Secure" : "");
  }

  async newSession() {
    let result;
    try {
      // Current Home Assistant
      result = await this.wsSend({ type: "supervisor/ingress/session", slug: this.slug });
    } catch {
      try {
        // Older releases
        result = await this.wsSend({ type: "supervisor/api", endpoint: "/ingress/session", method: "post" });
      } catch (e) {
        throw new Error("Home Assistant refused an add-on session. This page needs an HA admin user. " +
          (e?.message || ""));
      }
    }
    this.session = result.session;
    this.setCookie(this.session);
  }

  async keepSessionAlive() {
    if (!this.viaHA || !this.session) return;
    try {
      await this.wsSend({ type: "supervisor/ingress/validate_session", session: this.session });
    } catch {
      try { await this.wsSend({ type: "supervisor/api", endpoint: "/ingress/validate_session", method: "post", data: { session: this.session } }); }
      catch { await this.newSession().catch(() => {}); }
    }
  }

  // ---------------- API calls ----------------

  apiToken() { try { return localStorage.getItem(API_TOKEN_KEY) || ""; } catch { return ""; } }
  setApiToken(t) { try { localStorage.setItem(API_TOKEN_KEY, t); } catch {} }

  async request(method, path, body, { timeout = 30000, retry = true } = {}) {
    const headers = {};
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const token = this.apiToken();
    if (!this.viaHA && token) headers.Authorization = `Bearer ${token}`;

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeout);
    let res;
    try {
      res = await fetch(this.base + path, {
        method, headers, credentials: "same-origin", signal: ctrl.signal,
        body: body !== undefined ? JSON.stringify(body) : undefined,
      });
    } catch (e) {
      throw new ApiError(e.name === "AbortError" ? "The server took too long to answer." : "Can't reach the server.", 0);
    } finally {
      clearTimeout(timer);
    }

    // Expired ingress session: get a new one and try once more.
    if (this.viaHA && retry && (res.status === 401 || res.status === 403)) {
      await this.newSession();
      return this.request(method, path, body, { timeout, retry: false });
    }

    let data = null;
    try { data = await res.json(); } catch {}
    if (!res.ok) throw new ApiError((data && data.error) || `HTTP ${res.status}`, res.status);
    return data;
  }

  get(path, opts) { return this.request("GET", path, undefined, opts); }
  post(path, body = {}, opts) { return this.request("POST", path, body, opts); }

  state() { return this.get("/api/state"); }
  wait(since) { return this.get(`/api/wait?since=${since}&timeout=25`, { timeout: 40000 }); }
}
