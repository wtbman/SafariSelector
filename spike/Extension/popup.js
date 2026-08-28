// Self-sufficient spike popup: does NOT depend on the background worker.
// Gathers the capability surface directly, renders it, and POSTs it to a local
// collector so findings can be read from disk instead of by eye. The POST also
// exercises the loopback transport the real design depends on.
const api = typeof browser !== "undefined" ? browser : chrome;
const COLLECTOR = "http://127.0.0.1:8787/report";
const TEST_URL = "https://example.com/?spike=" + Date.now();
const $ = (id) => document.getElementById(id);

let lastSnapshot = [];

function caps() {
  return {
    typeofTabGroups: typeof api.tabGroups,
    tabGroupsKeys: api.tabGroups ? Object.keys(api.tabGroups) : null,
    windowsKeys: api.windows ? Object.keys(api.windows).sort() : null,
    tabsKeys: api.tabs ? Object.keys(api.tabs).sort() : null,
    manifestVersion: api.runtime.getManifest().manifest_version,
    userAgent: navigator.userAgent,
  };
}

async function snapshot() {
  const wins = await api.windows.getAll({ populate: true });
  return wins.map((w) => ({
    ...w,
    tabs: (w.tabs || []).map((t) => {
      const c = { ...t };
      delete c.favIconUrl;
      return c;
    }),
  }));
}

async function post(label, extra) {
  const body = { label, at: new Date().toISOString(), caps: caps(),
                 windows: await snapshot(), ...extra };
  try {
    const r = await fetch(COLLECTOR, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    $("post").textContent = "collector: HTTP " + r.status;
  } catch (e) {
    $("post").textContent = "collector FAILED: " + e.message;
  }
}

// Native messaging is probed separately so a failure there doesn't stop the run.
async function probeNative() {
  try {
    const res = await api.runtime.sendNativeMessage("application.id", { label: "popup-probe" });
    $("native").textContent = "sendNativeMessage OK: " + JSON.stringify(res);
    return res;
  } catch (e) {
    $("native").textContent = "sendNativeMessage FAILED: " + String(e);
    return { error: String(e) };
  }
}

async function render() {
  $("caps").textContent = JSON.stringify(caps(), null, 2);
  const wins = await snapshot();
  lastSnapshot = wins;
  $("raw").textContent = JSON.stringify(wins, null, 2);

  const host = $("wins");
  host.textContent = "";
  for (const w of wins) {
    const active = (w.tabs || []).find((t) => t.active);
    const div = document.createElement("div");
    div.className = "win";
    const b = document.createElement("b");
    b.textContent = `window ${w.id}${w.focused ? " (focused)" : ""} — ${w.tabs.length} tabs`;
    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = active ? `active: ${active.title || "(untitled)"}` : "(no active tab)";
    const btn = document.createElement("button");
    btn.textContent = "tabs.create here";
    btn.onclick = () => openInto(w.id);
    div.append(b, meta, btn);
    host.append(div);
  }

  const nativeRes = await probeNative();
  await post("startup", { nativeProbe: nativeRes });
}

async function openInto(windowId) {
  const before = lastSnapshot.find((w) => w.id === windowId);
  try {
    const tab = await api.tabs.create({ windowId, url: TEST_URL, active: true });
    $("status").textContent =
      `created tab ${tab.id} in window ${tab.windowId}. LOOK: is it inside the tab group?`;
    setTimeout(() => post("createtest", {
      targetWindowId: windowId, createdTab: { ...tab }, windowBefore: before,
    }), 800);
  } catch (e) {
    $("status").textContent = "ERROR: " + e.message;
    post("createtest-error", { targetWindowId: windowId, error: String(e) });
  }
}

render();
