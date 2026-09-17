// SafariSelector bridge.
//
// One persistent background page runs per Safari profile. It reports that profile's
// windows to the SafariSelector app and executes open commands on the app's behalf.
//
// Transport is HTTP long-polling against 127.0.0.1 rather than a WebSocket: the
// capability spike verified that fetch() to loopback works from a Safari extension,
// ws:// was never verified. This macOS-only extension uses a Manifest V2 persistent
// page: a pending fetch did NOT reliably keep Safari's MV3 worker alive, and focusing
// the chosen window did not reliably wake it. External links need a ready listener.
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

// A hung optional API or network request must not permanently wedge the bridge.
async function withTimeout(operation, milliseconds) {
  let timer;
  try {
    return await Promise.race([
      operation,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("bridge operation timed out")), milliseconds);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function request(path, options = {}, milliseconds = 5000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), milliseconds);
  try {
    const response = await fetch(`${BASE}${path}`, {
      ...options, cache: "no-store", signal: controller.signal,
    });
    if (!response.ok) throw new Error(`${path.split("?")[0]} HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------- discovery

// The native handler is the only thing that knows which profile we are: Safari
// passes it SFExtensionProfileKey. It also hands back the shared auth token.
async function discover() {
  const res = await withTimeout(
    api.runtime.sendNativeMessage("application.id", { type: "discover" }), 5000);
  if (!res || !res.profileUUID) throw new Error("discover: no profileUUID in " + JSON.stringify(res));
  profileUUID = res.profileUUID;
  token = res.token || null;
}

// ----------------------------------------------------------------- activity

// Per-URL first-seen / last-active times, so an agent can ask "which tabs has
// nobody touched in a month". Safari exposes nothing like this itself. Keyed by
// URL rather than tab id: Safari reassigns every tab id whenever this worker
// restarts, which would wipe a tab-id-keyed history several times a day.
let activity = {};
let activityDirty = false;

async function loadActivity() {
  const { activity: stored } = await api.storage.local.get("activity");
  activity = stored || {};
  const tabs = await api.tabs.query({});
  const now = Date.now();
  const seen = new Set();
  for (const t of tabs) {
    if (!t.url) continue;
    seen.add(t.url);
    if (!activity[t.url]) activity[t.url] = { firstSeen: now, lastActive: t.active ? now : null };
    else if (t.active) activity[t.url].lastActive = now;
  }
  // Drop URLs no tab shows any more; onRemoved doesn't tell us the URL.
  for (const u of Object.keys(activity)) if (!seen.has(u)) delete activity[u];
  activityDirty = true;
  await saveActivity();
}

async function saveActivity() {
  if (!activityDirty) return;
  activityDirty = false;
  await api.storage.local.set({ activity });
}

function touch(url) {
  if (!url) return;
  const now = Date.now();
  (activity[url] ||= { firstSeen: now }).lastActive = now;
  activityDirty = true;
}

api.tabs.onActivated.addListener(async ({ tabId }) => {
  try { touch((await api.tabs.get(tabId)).url); saveActivity(); } catch (e) { /* tab gone */ }
});
api.tabs.onUpdated.addListener((tabId, info, tab) => {
  // A navigation moves the tab to a new URL; that counts as activity on it.
  if (info.url) { touch(info.url); if (tab.active) saveActivity(); }
});

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
  // Events can arrive before discovery or while the app is reconnecting.
  if (!profileUUID) return;
  const windows = await withTimeout(snapshot(), 5000);
  await request("/snapshot", {
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

    // ---- relayed commands: issued by the MCP server via the app's /command.
    // Results go in `data`; the app relays them verbatim.

    case "TABS": {
      // Full tab list with activity. Heavy (200+ tabs per window) — only sent
      // on request, never on the event-driven push.
      const wins = await api.windows.getAll({ populate: true });
      return { ok: true, data: { windows: wins.filter((w) => w.type === "normal").map((w) => ({
        windowId: w.id, focused: !!w.focused,
        tabs: (w.tabs || []).map((t) => ({
          id: t.id, index: t.index, url: t.url || "", title: t.title || "",
          active: !!t.active, pinned: !!t.pinned,
          lastActive: activity[t.url]?.lastActive ?? null,
          firstSeen: activity[t.url]?.firstSeen ?? null,
        })),
      })) } };
    }

    case "CLOSE_TABS": {
      const ids = (cmd.args && cmd.args.tabIds) || [];
      await assertKnownTabIds(ids);
      await api.tabs.remove(ids);
      return { ok: true, data: { closed: ids.length } };
    }

    case "MOVE_TABS": {
      // Tabs join whatever tab group the target window is currently showing —
      // the only way to put a tab into a group.
      //
      // Safari does not implement tabs.move (verified: it is undefined), so a
      // move is emulated as create-in-target + close-original. Back/forward
      // history does not survive; the URL, pinned state, and position do.
      const { tabIds = [], windowId, index = -1 } = cmd.args || {};
      await assertKnownTabIds(tabIds);
      const moved = [];
      for (const id of tabIds) {
        const src = await api.tabs.get(id);
        const created = await api.tabs.create({
          windowId, url: src.url, active: false,
          ...(index >= 0 ? { index: index + moved.length } : {}),
        });
        if (src.pinned) { try { await api.tabs.update(created.id, { pinned: true }); } catch (e) { /* optional */ } }
        await api.tabs.remove(id);
        moved.push({ id: created.id, windowId: created.windowId, index: created.index, url: src.url });
      }
      return { ok: true, data: { moved, note: "Safari has no tabs.move; tabs were re-created in the target window (history not preserved)" } };
    }

    case "ACTIVATE_TAB": {
      const { tabId } = cmd.args || {};
      await assertKnownTabIds([tabId]);
      const t = await api.tabs.update(tabId, { active: true });
      await api.windows.update(t.windowId, { focused: true });
      return { ok: true, data: { windowId: t.windowId } };
    }
    case "PING":
      return { ok: true, data: {
        version: api.runtime.getManifest().version,
        backgroundMode: "persistent",
      } };
    default:
      return { ok: false, error: "unknown command " + cmd.type };
  }
}

// Ids from before this worker's last restart are stale, and Safari's
// tabs.remove() hangs on an unknown id rather than rejecting — so check first.
async function assertKnownTabIds(ids) {
  const live = new Set((await api.tabs.query({})).map((t) => t.id));
  const unknown = ids.filter((id) => !live.has(id));
  if (unknown.length) {
    throw new Error("unknown tab ids (stale after a worker restart? re-list first): " + unknown.join(","));
  }
}

async function respond(cmd, result) {
  await request("/result", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ profileUUID, token, commandId: cmd.commandId, result }),
  });
}

// --------------------------------------------------------------- poll loop

async function pollOnce() {
  const path = `/poll?profile=${encodeURIComponent(profileUUID)}` +
               (token ? `&token=${encodeURIComponent(token)}` : "");
  const body = await request(path, {}, POLL_TIMEOUT_MS + 5000);
  if (body && body.type && body.type !== "IDLE") {
    let result;
    try {
      // Never let a hung tabs API call wedge the poll loop.
      result = await withTimeout(execute(body), 10000);
    } catch (e) {
      result = { ok: false, error: String(e && e.message ? e.message : e) };
    }
    await respond(body, result);
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

// History is optional. In Safari a storage/tab API can stall; waiting for it used
// to prevent discovery and polling from ever starting in that profile.
loadActivity().catch(() => {});
run();
