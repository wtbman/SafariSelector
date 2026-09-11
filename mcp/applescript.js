// AppleScript (JXA) backend.
//
// Sees every Safari profile at once and is the only source of tab-group /
// profile labels (via the window title, "Group — PageTitle"). Cannot move tabs
// and has no notion of tab age; the extension backend covers those.
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

// Run a JXA snippet against Safari. `body` must end in an expression whose
// JSON.stringify'd value is the result.
export async function jxa(body, timeoutMs = 15000) {
  const script = `const s = Application("Safari"); ${body}`;
  let stdout;
  try {
    ({ stdout } = await execFileP("osascript", ["-l", "JavaScript", "-e", script], {
      timeout: timeoutMs,
      maxBuffer: 32 * 1024 * 1024,
    }));
  } catch (e) {
    // Say what actually went wrong rather than echoing the script. The two
    // common failures are both about the *client* process, not Safari:
    // macOS Automation permission (TCC) is granted per app, so a server
    // launched by VS Code, Codex etc. needs its own grant, and the first
    // attempt blocks on a consent dialog until it is answered.
    const stderr = (e.stderr || "").trim();
    if (e.killed || e.signal) {
      throw new Error(`AppleScript timed out after ${timeoutMs}ms. If this is the first use from this app, macOS is probably showing an Automation consent dialog ("… wants access to control Safari") — accept it, or grant it under System Settings › Privacy & Security › Automation › <this app> › Safari.`);
    }
    if (/-1743|not authori[sz]ed/i.test(stderr)) {
      throw new Error(`macOS denied Automation access to Safari for the app running this MCP server. Enable it under System Settings › Privacy & Security › Automation › <that app> › Safari. (${stderr})`);
    }
    throw new Error(`AppleScript failed: ${stderr || e.message}`);
  }
  const out = stdout.trim();
  return out ? JSON.parse(out) : null;
}

// Safari window titles are "<TabGroup or Profile> — <Page title>". A window
// showing a tab group uses the group name; a loose-tab window uses the profile
// name. We can't tell the two cases apart from the title alone.
export function parseWindowName(name) {
  const i = name.indexOf(" — ");
  if (i < 0) return { label: null, pageTitle: name };
  return { label: name.slice(0, i), pageTitle: name.slice(i + 3) };
}

export async function listWindows() {
  const r = await jxa(`
    JSON.stringify({
      ids: s.windows.id(), names: s.windows.name(), index: s.windows.index(),
      cur: s.windows.currentTab.index(), counts: s.windows.tabs.url().map(t => t.length),
      curUrl: s.windows.currentTab.url(), curTitle: s.windows.currentTab.name(),
    })`);
  if (!r) return [];
  return r.ids.map((id, i) => ({
    asId: id,
    index: r.index[i],
    ...parseWindowName(r.names[i]),
    tabCount: r.counts[i],
    activeTab: { index: r.cur[i], url: r.curUrl[i], title: r.curTitle[i] },
  }));
}

export async function listTabs() {
  const r = await jxa(`
    JSON.stringify({ ids: s.windows.id(), names: s.windows.name(),
      urls: s.windows.tabs.url(), titles: s.windows.tabs.name(),
      cur: s.windows.currentTab.index() })`);
  if (!r) return [];
  const out = [];
  r.ids.forEach((asId, w) => {
    const { label } = parseWindowName(r.names[w]);
    r.urls[w].forEach((url, i) => {
      out.push({ asWindowId: asId, windowLabel: label, index: i + 1,
        url, title: r.titles[w][i], active: i + 1 === r.cur[w] });
    });
  });
  return out;
}

// Close tabs by exact URL. Returns the number closed. Closing by URL rather
// than index keeps this safe when the tab list shifts under us.
export async function closeTabsByUrl(urls, asWindowId = null) {
  const r = await jxa(`
    const urls = new Set(${JSON.stringify(urls)});
    const wins = ${asWindowId == null ? "s.windows()" : `[s.windows.byId(${asWindowId})]`};
    let n = 0;
    for (const w of wins) {
      // One batched read of every URL (a single Apple event), then close
      // high-to-low so closing one doesn't shift the ones still to visit.
      const all = w.tabs.url(), tabs = w.tabs();
      for (let i = all.length - 1; i >= 0; i--) {
        if (urls.has(all[i])) { tabs[i].close(); n++; }
      }
    }
    JSON.stringify({ closed: n })`);
  return r.closed;
}

export async function openUrl(asWindowId, url, activate = true) {
  return jxa(`
    const w = s.windows.byId(${asWindowId});
    const t = s.Tab({ url: ${JSON.stringify(url)} });
    w.tabs.push(t);
    ${activate ? "w.currentTab = t;" : ""}
    JSON.stringify({ asWindowId: ${asWindowId}, index: w.tabs.length })`);
}

// Close every tab whose URL also appears at a lower index in the same window,
// keeping the leftmost (oldest, since Safari appends new tabs) copy. Returns
// the closed tabs so the caller can report them.
export async function closeDuplicateTabs(asWindowId = null) {
  const r = await jxa(`
    const wins = ${asWindowId == null ? "s.windows()" : `[s.windows.byId(${asWindowId})]`};
    const closed = [];
    for (const w of wins) {
      const urls = w.tabs.url(), names = w.tabs.name(), seen = new Set(), idx = [];
      urls.forEach((u, i) => seen.has(u) ? idx.push(i) : seen.add(u));
      const tabs = w.tabs();
      for (const i of idx.reverse()) { closed.push({ asWindowId: w.id(), index: i + 1, title: names[i], url: urls[i] }); tabs[i].close(); }
    }
    JSON.stringify(closed.reverse())`);
  return r;
}

// Bring a window to the front. Used to wake a dormant profile's extension
// worker: Safari starts it on windows.onFocusChanged.
export async function focusWindow(asWindowId) {
  return jxa(`s.windows.byId(${asWindowId}).index = 1; s.activate(); JSON.stringify({ ok: true })`);
}

export async function activateTab(asWindowId, index) {
  return jxa(`
    const w = s.windows.byId(${asWindowId});
    w.currentTab = w.tabs[${index - 1}];
    w.index = 1;
    s.activate();
    JSON.stringify({ ok: true })`);
}
