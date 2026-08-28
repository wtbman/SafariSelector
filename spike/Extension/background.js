// Spike background worker.
//
// Probes the capability surface and reports it to the native handler, which
// writes it to disk. Nothing here depends on browser.tabGroups existing.
const api = typeof browser !== "undefined" ? browser : chrome;

function capabilities() {
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
    // Spread first so we capture every field Safari actually provides,
    // including any we don't know to ask for.
    ...w,
    tabs: (w.tabs || []).map((t) => ({ ...t, favIconUrl: undefined })),
  }));
}

async function report(label, extra) {
  const payload = { label, caps: capabilities(), windows: await snapshot(), ...extra };
  try {
    const res = await api.runtime.sendNativeMessage("application.id", payload);
    console.log("spike: native replied", JSON.stringify(res));
    return res;
  } catch (e) {
    console.error("spike: sendNativeMessage failed", e);
    return { error: String(e) };
  }
}

api.runtime.onMessage.addListener((msg, sender, respond) => {
  if (msg && msg.type === "REPORT") {
    report(msg.label, msg.extra).then(respond);
    return true;
  }
  if (msg && msg.type === "SNAPSHOT") {
    snapshot().then((w) => respond({ caps: capabilities(), windows: w }));
    return true;
  }
  return false;
});

report("startup");
