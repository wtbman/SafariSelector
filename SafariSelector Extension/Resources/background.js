// SafariSelector bridge.
//
// One instance of this worker runs per Safari profile. It reports that profile's
// windows to the SafariSelector app and executes open commands on the app's behalf.
//
// Transport is HTTP long-polling against 127.0.0.1 rather than a WebSocket: the
// capability spike verified that fetch() to loopback works from a Safari extension,
// ws:// was never verified, and an in-flight fetch keeps the MV3 worker alive.
//
// Opening via tabs.create({windowId}) is the whole point — Safari implicitly places
// the new tab in whatever tab group that window is currently showing. There is no
// API to name or choose a group. See docs/SPIKE-FINDINGS.md.

const api = typeof browser !== "undefined" ? browser : chrome;

const PORT = 53127;
const BASE = `http://127.0.0.1:${PORT}`;
const POLL_TIMEOUT_MS = 30000;

let profileUUID = null;
let token = null;
let backoff = 500;

// ---------------------------------------------------------------- discovery

// The native handler is the only thing that knows which profile we are: Safari
// passes it SFExtensionProfileKey. It also hands back the shared auth token.
async function discover() {
  const res = await api.runtime.sendNativeMessage("application.id", { type: "discover" });
  if (!res || !res.profileUUID) throw new Error("discover: no profileUUID in " + JSON.stringify(res));
  profileUUID = res.profileUUID;
  token = res.token || null;
}

// ----------------------------------------------------------------- snapshot

// Deliberately lightweight. Windows here hold 200+ tabs; sending the full tab
// array on every event would be pure waste. The app only needs enough to identify
// and label a window.
async function snapshot() {
  const wins = await api.windows.getAll({ populate: true });
  return wins
    .filter((w) => w.type === "normal")
    .map((w) => {
      const tabs = w.tabs || [];
      const active = tabs.find((t) => t.active) || {};
      return {
        windowId: w.id,
        focused: !!w.focused,
        tabCount: tabs.length,
        activeTabUrl: active.url || "",
        activeTabTitle: active.title || "",
        // Geometry is the correlation key against AppleScript's view of the same
        // windows. The active tab URL is not usable for this: several windows
        // routinely show the same page, and they then collapse onto one entry.
        left: w.left, top: w.top, width: w.width, height: w.height,
      };
    });
}

async function push() {
  const windows = await snapshot();
  await fetch(`${BASE}/snapshot`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ profileUUID, token, windows }),
  });
}

let pushTimer = null;
function schedulePush() {
  clearTimeout(pushTimer);
  pushTimer = setTimeout(() => push().catch(() => {}), 150);
}

// ----------------------------------------------------------------- commands

async function execute(cmd) {
  switch (cmd.type) {
    case "OPEN": {
      // Resolve the target window at execution time. Ids are not durable — Safari
      // reassigns them when this worker restarts — so geometry, which the app
      // captured from AppleScript's view of the same window, is the primary key.
      let windowId = null;
      const wins = await api.windows.getAll({ populate: false });

      if (cmd.matchLeft != null) {
        // Match on left edge and size; vertical position is only a tiebreak, since
        // one side's view of `top` can lag behind a window move.
        let best = null, bestShape = Infinity, bestVertical = Infinity;
        for (const w of wins) {
          if (w.type && w.type !== "normal") continue;
          const shape = Math.abs(w.left - cmd.matchLeft)
                      + Math.abs(w.width - cmd.matchWidth)
                      + Math.abs(w.height - cmd.matchHeight);
          if (shape > 40) continue;
          const vertical = Math.abs(w.top - cmd.matchTop);
          if (shape < bestShape || (shape === bestShape && vertical < bestVertical)) {
            bestShape = shape; bestVertical = vertical; best = w;
          }
        }
        if (best) windowId = best.id;
      }

      if (windowId == null && cmd.windowId != null &&
          wins.some((w) => w.id === cmd.windowId)) {
        windowId = cmd.windowId;
      }
      if (windowId == null) {
        const focused = await api.windows.getLastFocused();
        windowId = focused.id;
      }

      const tab = await api.tabs.create({ windowId, url: cmd.url, active: true });
      await api.windows.update(windowId, { focused: true });
      return {
        ok: true, tabId: tab.id, windowId: tab.windowId,
        usedFallback: windowId !== cmd.windowId,
      };
    }

    case "OPEN_NEW_WINDOW": {
      const win = await api.windows.create({ url: cmd.url });
      return { ok: true, windowId: win.id };
    }
    case "PING":
      return { ok: true };
    default:
      return { ok: false, error: "unknown command " + cmd.type };
  }
}

async function respond(cmd, result) {
  await fetch(`${BASE}/result`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ profileUUID, token, commandId: cmd.commandId, result }),
  });
}

// --------------------------------------------------------------- poll loop

async function pollOnce() {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), POLL_TIMEOUT_MS + 5000);
  try {
    const url = `${BASE}/poll?profile=${encodeURIComponent(profileUUID)}` +
                (token ? `&token=${encodeURIComponent(token)}` : "");
    const r = await fetch(url, { signal: ctl.signal });
    if (!r.ok) throw new Error("poll HTTP " + r.status);
    const body = await r.json();
    if (body && body.type && body.type !== "IDLE") {
      let result;
      try {
        result = await execute(body);
      } catch (e) {
        result = { ok: false, error: String(e && e.message ? e.message : e) };
      }
      await respond(body, result);
    }
  } finally {
    clearTimeout(timer);
  }
}

async function run() {
  for (;;) {
    try {
      if (!profileUUID) await discover();
      await push();
      backoff = 500;
      // Stay in the poll loop while the app is reachable.
      for (;;) await pollOnce();
    } catch (e) {
      console.warn("SafariSelector bridge:", String(e));
      // The app may be down, restarting, or the worker may have been revived
      // with stale state. Re-discover from scratch on the next pass.
      profileUUID = null;
      token = null;
      await new Promise((r) => setTimeout(r, backoff));
      backoff = Math.min(backoff * 2, 30000);
    }
  }
}

for (const ev of [
  api.windows.onCreated, api.windows.onRemoved, api.windows.onFocusChanged,
  api.tabs.onCreated, api.tabs.onRemoved, api.tabs.onUpdated, api.tabs.onActivated,
]) {
  try { ev.addListener(schedulePush); } catch (e) { /* not all events exist everywhere */ }
}

run();
