#!/usr/bin/env node
// MCP server: lets an agent list, inspect, close, move and open Safari tabs.
//
// Two backends, merged per call:
//   - The SafariSelector app bridge (bridge.js): profile + tab-group labels for
//     every window, and per-profile tab lists with stable-for-now tab ids and
//     last-active times from the extension. Needs the app running and the
//     extension enabled.
//   - AppleScript (applescript.js): every profile at once, no app needed.
//     Close-by-URL, open, activate, duplicate removal. Always available.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import * as as from "./applescript.js";
import * as bridge from "./bridge.js";

const server = new McpServer({ name: "safari-selector", version: "0.2.0" });
const text = (s) => ({ content: [{ type: "text", text: typeof s === "string" ? s : JSON.stringify(s, null, 2) }] });
const fail = (e) => ({ isError: true, content: [{ type: "text", text: String(e.message || e) }] });

// tabId -> profileUUID from the most recent listing, so id-based tools can
// route without the caller naming a profile. Ids are reassigned when Safari
// restarts an extension worker, so this is only ever as fresh as the last list.
const tabOwner = new Map();

// One row per window, from the app when it's running (labels, profile, ext id)
// or from AppleScript alone otherwise. Tabs are fetched per connected profile
// and attached by extension window id.
// Safari only runs an extension worker in profiles it considers active. Focusing
// one of a dormant profile's windows (via AppleScript) starts the worker, which
// then reports in; the app's /status shows the window with an extWindowId.
// This steals focus briefly, so it is opt-in.
async function wakeCold(windows) {
  const cold = windows.filter((w) => w.source === "app" && w.extWindowId == null && w.asId != null);
  const byProfile = new Map();
  for (const w of cold) if (!byProfile.has(w.profileUUID ?? w.profile)) byProfile.set(w.profileUUID ?? w.profile, w);
  for (const w of byProfile.values()) {
    await as.focusWindow(w.asId);
    for (let i = 0; i < 20; i++) {
      await new Promise((r) => setTimeout(r, 250));
      const st = await bridge.status();
      if (st?.targets.some((t) => t.asID === w.asId && t.windowId != null)) break;
    }
  }
}

async function merged({ withTabs = true, wake = false } = {}) {
  let st = await bridge.status();
  if (st && wake) {
    await wakeCold(st.targets.map((t) => ({ asId: t.asID, extWindowId: t.windowId, profileUUID: t.profileUUID, profile: t.profileLabel, source: "app" })));
    st = await bridge.status();
  }
  if (!st) {
    const windows = (await as.listWindows()).map((w) => ({ ...w, source: "applescript" }));
    const tabs = withTabs ? await as.listTabs() : [];
    return { app: false, windows, tabs };
  }
  const windows = st.targets.map((t) => ({
    asId: t.asID, label: t.tabGroupLabel === "(loose tabs)" ? null : t.tabGroupLabel,
    profile: t.profileLabel, profileUUID: t.profileUUID, extWindowId: t.windowId,
    tabCount: t.tabCount, activeTabTitle: t.activeTabTitle, focused: t.focused, source: "app",
  }));
  if (!withTabs) return { app: true, windows, tabs: [] };

  const byExt = new Map(windows.filter((w) => w.extWindowId != null).map((w) => [`${w.profileUUID}/${w.extWindowId}`, w]));
  const profiles = [...new Set(windows.map((w) => w.profileUUID).filter(Boolean))];
  const results = await Promise.allSettled(profiles.map((p) => bridge.command(p, "TABS")));
  const tabs = [];
  const errors = [];
  results.forEach((r, i) => {
    if (r.status !== "fulfilled") { errors.push(`${profiles[i]}: ${r.reason.message}`); return; }
    for (const w of r.value.windows) {
      const win = byExt.get(`${profiles[i]}/${w.windowId}`);
      for (const t of w.tabs) {
        tabOwner.set(t.id, profiles[i]);
        tabs.push({ asWindowId: win?.asId ?? null, windowLabel: win?.label ?? null, profile: win?.profile ?? null,
          profileUUID: profiles[i], extWindowId: w.windowId, index: t.index + 1, tabId: t.id,
          url: t.url, title: t.title, active: t.active, pinned: t.pinned, lastActive: t.lastActive, firstSeen: t.firstSeen });
      }
    }
  });
  // Windows in profiles whose worker didn't answer still get an AppleScript tab list.
  const covered = new Set(tabs.map((t) => t.asWindowId));
  const missing = windows.filter((w) => w.asId != null && !covered.has(w.asId));
  if (missing.length) {
    const asTabs = await as.listTabs();
    for (const t of asTabs) {
      const w = missing.find((m) => m.asId === t.asWindowId);
      if (w) tabs.push({ ...t, profile: w.profile, profileUUID: w.profileUUID, tabId: null });
    }
  }
  return { app: true, windows, tabs, errors };
}

const age = (ms) => {
  const h = (Date.now() - ms) / 36e5;
  return h < 1 ? `${Math.round(h * 60)}m` : h < 48 ? `${Math.round(h)}h` : `${Math.round(h / 24)}d`;
};
// Time since last active; ">Nd" = never activated since tracking began N days ago.
const ageCol = (t) => t.lastActive ? age(t.lastActive) : t.firstSeen ? `>${age(t.firstSeen)}` : "?";
const tabLine = (t) =>
  `${t.asWindowId ?? "?"}:${t.index}${t.tabId != null ? ` #${t.tabId}` : ""}${t.active ? " *" : ""}` +
  ` [${ageCol(t)}] ${t.title || "(untitled)"} — ${t.url}`;
const winLine = (w) =>
  `${w.asId} ${w.profile ? `${w.profile} / ` : ""}${w.label ?? "(loose tabs)"} — ${w.tabCount} tabs` +
  (w.extWindowId != null ? ` [ext ${w.extWindowId}]` : w.source === "app" ? " [cold]" : " [AppleScript only]");

// Group tab ids by owning profile, refreshing the listing if any are unknown.
async function routeIds(tabIds) {
  if (tabIds.some((id) => !tabOwner.has(id))) await merged();
  const unknown = tabIds.filter((id) => !tabOwner.has(id));
  if (unknown.length) throw new Error(`unknown tab ids ${unknown.join(",")} — ids change when Safari restarts the extension; run safari_list_tabs and use fresh ids, or close by URL`);
  const groups = new Map();
  for (const id of tabIds) (groups.get(tabOwner.get(id)) || groups.set(tabOwner.get(id), []).get(tabOwner.get(id))).push(id);
  return groups;
}

server.registerTool("safari_status", {
  description: "Whether the SafariSelector app bridge is reachable, and one line per Safari window: asId, profile / tab group, tab count, extension window id.",
}, async () => {
  try {
    const m = await merged({ withTabs: false });
    return text((m.app ? "SafariSelector app: connected" : "SafariSelector app: NOT running — AppleScript only (no tab ids, ages, or moves)") +
      "\n" + m.windows.map(winLine).join("\n"));
  } catch (e) { return fail(e); }
});

server.registerTool("safari_list_windows", {
  description: "List Safari windows across all profiles as JSON. `label` is the tab group the window is currently showing (null = loose tabs); `asId` is the AppleScript window id used by other tools; `extWindowId` + `profileUUID` are needed for moves.",
}, async () => {
  try { return text((await merged({ withTabs: false })).windows); } catch (e) { return fail(e); }
});

server.registerTool("safari_list_tabs", {
  description: "List tabs, one line each: `<asWindowId>:<index> #<tabId> [age] title — url`. Age is time since the tab was last active; `>Nd` means never activated since tracking began N days ago; `?` = unknown. `#tabId` and ages need the SafariSelector app + extension. NOTE: tab ids are reassigned whenever Safari restarts the extension, so take ids from a listing made immediately before closing/moving by id; closing by URL is the robust alternative.",
  inputSchema: {
    asWindowId: z.number().optional().describe("Only this AppleScript window"),
    windowLabel: z.string().optional().describe("Only windows whose tab-group label contains this (case-insensitive)"),
    profile: z.string().optional().describe("Only windows whose profile label contains this (case-insensitive)"),
    contains: z.string().optional().describe("Only tabs whose URL or title contains this (case-insensitive)"),
    olderThanHours: z.number().optional().describe("Only tabs not active for at least this many hours (uses first-seen for never-activated tabs)"),
    wake: z.boolean().optional().default(false).describe("Wake dormant profiles (marked [cold] in safari_status) by briefly focusing one of their windows, so their tabs get ids and ages. Steals focus for a moment."),
    limit: z.number().optional().default(300),
    json: z.boolean().optional().default(false),
  },
}, async ({ asWindowId, windowLabel, profile, contains, olderThanHours, wake, limit, json }) => {
  try {
    const m = await merged({ wake });
    let tabs = m.tabs;
    const has = (s, q) => (s || "").toLowerCase().includes(q.toLowerCase());
    if (asWindowId != null) tabs = tabs.filter((t) => t.asWindowId === asWindowId);
    if (windowLabel) tabs = tabs.filter((t) => has(t.windowLabel, windowLabel));
    if (profile) tabs = tabs.filter((t) => has(t.profile, profile));
    if (contains) tabs = tabs.filter((t) => has(t.url, contains) || has(t.title, contains));
    if (olderThanHours != null) { const cut = Date.now() - olderThanHours * 36e5; tabs = tabs.filter((t) => (t.lastActive || t.firstSeen || Infinity) < cut); }
    const total = tabs.length;
    tabs = tabs.slice(0, limit);
    if (json) return text(tabs);
    const cold = m.windows.filter((w) => w.source === "app" && w.extWindowId == null).map((w) => w.label ?? w.asId);
    const warn = (cold.length ? `\n(dormant profiles — no ids/ages for: ${cold.join(", ")}; pass wake:true to wake them)` : "") +
      (m.errors?.length ? `\n(extension did not answer for: ${m.errors.join("; ")})` : "");
    return text(`${total} tab(s)${total > limit ? `, showing ${limit}` : ""}${warn}\n` + tabs.map(tabLine).join("\n"));
  } catch (e) { return fail(e); }
});

server.registerTool("safari_close_tabs", {
  description: "Close tabs by tabId (precise, from a fresh listing) and/or by exact URL (closes every tab with that URL, optionally limited to one window). Irreversible — confirm with the user before closing anything they didn't explicitly name.",
  inputSchema: {
    tabIds: z.array(z.number()).optional(),
    urls: z.array(z.string()).optional(),
    asWindowId: z.number().optional().describe("Restrict URL-based closing to this AppleScript window"),
  },
}, async ({ tabIds = [], urls = [], asWindowId }) => {
  try {
    const out = {};
    if (tabIds.length) {
      out.byId = 0;
      for (const [profile, ids] of await routeIds(tabIds)) out.byId += (await bridge.command(profile, "CLOSE_TABS", { tabIds: ids })).closed;
      for (const id of tabIds) tabOwner.delete(id);
    }
    if (urls.length) out.byUrl = await as.closeTabsByUrl(urls, asWindowId);
    return text(out);
  } catch (e) { return fail(e); }
});

server.registerTool("safari_close_duplicate_tabs", {
  description: "Close tabs whose exact URL is already open at a lower index in the same window, keeping the leftmost (oldest) copy. Optionally limited to one window. Returns the closed tabs.",
  inputSchema: { asWindowId: z.number().optional() },
}, async ({ asWindowId }) => {
  try { const c = await as.closeDuplicateTabs(asWindowId); return text(`closed ${c.length}\n` + c.map((t) => `${t.asWindowId}:${t.index} ${t.title} — ${t.url}`).join("\n")); }
  catch (e) { return fail(e); }
});

server.registerTool("safari_move_tabs", {
  description: "Move tabs (by tabId, from a fresh listing) into another window in the SAME profile. The tabs join whatever tab group that window is currently showing — this is the only way to put a tab into a tab group. Safari has no native tabs.move, so each tab is re-created in the target window and the original closed: URL and position are kept, back/forward history is not. Requires the SafariSelector app + extension.",
  inputSchema: {
    tabIds: z.array(z.number()).min(1),
    toExtWindowId: z.number().describe("Target window's extWindowId from safari_list_windows"),
    index: z.number().optional().default(-1).describe("Position in target window; -1 = end"),
  },
}, async ({ tabIds, toExtWindowId, index }) => {
  try {
    const groups = await routeIds(tabIds);
    if (groups.size > 1) throw new Error("tabs span more than one profile; move one profile's tabs at a time");
    const [profile, ids] = [...groups][0];
    return text(await bridge.command(profile, "MOVE_TABS", { tabIds: ids, windowId: toExtWindowId, index }));
  } catch (e) { return fail(e); }
});

server.registerTool("safari_open_url", {
  description: "Open a URL as a new tab in a specific window (it joins that window's current tab group). Identify the window by asWindowId or by tab-group label substring.",
  inputSchema: {
    url: z.string().url(),
    asWindowId: z.number().optional(),
    windowLabel: z.string().optional(),
    activate: z.boolean().optional().default(true),
  },
}, async ({ url, asWindowId, windowLabel, activate }) => {
  try {
    if (asWindowId == null) {
      const w = (await merged({ withTabs: false })).windows.find((w) => (w.label || "").toLowerCase().includes((windowLabel || "").toLowerCase()));
      if (!w) throw new Error(`no window with label containing '${windowLabel}'`);
      asWindowId = w.asId;
    }
    return text(await as.openUrl(asWindowId, url, activate));
  } catch (e) { return fail(e); }
});

server.registerTool("safari_activate_tab", {
  description: "Bring a tab to the front, by tabId (fresh listing) or by AppleScript window id + 1-based index.",
  inputSchema: { tabId: z.number().optional(), asWindowId: z.number().optional(), index: z.number().optional() },
}, async ({ tabId, asWindowId, index }) => {
  try {
    if (tabId != null) { const [[profile]] = [...await routeIds([tabId])]; return text(await bridge.command(profile, "ACTIVATE_TAB", { tabId })); }
    if (asWindowId == null || index == null) throw new Error("give tabId, or asWindowId and index");
    return text(await as.activateTab(asWindowId, index));
  } catch (e) { return fail(e); }
});

await server.connect(new StdioServerTransport());
