// Client for the SafariSelector app's loopback bridge (BridgeServer.swift).
//
// The app already runs one long-poll bridge that every Safari profile's
// extension instance talks to, knows each profile's real UUID and label, and
// correlates extension windows to AppleScript windows by screen geometry. This
// module just reads its token and calls two routes:
//   GET  /status   — every openable window with profile + tab-group labels
//   POST /command  — relay a command to one profile's extension, get its result
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

const BRIDGE_FILE = path.join(homedir(), "Library/Application Support/SafariSelector/bridge.json");

let cached = null;
async function conn() {
  if (cached) return cached;
  try {
    const { port = 53127, token } = JSON.parse(await readFile(BRIDGE_FILE, "utf8"));
    cached = { url: `http://127.0.0.1:${port}`, token };
  } catch {
    cached = { url: "http://127.0.0.1:53127", token: null };
  }
  return cached;
}

// Null when the app isn't running; callers fall back to AppleScript.
export async function status() {
  const { url } = await conn();
  try {
    const r = await fetch(`${url}/status`, { signal: AbortSignal.timeout(5000) });
    return r.ok ? await r.json() : null;
  } catch { return null; }
}

export async function command(profileUUID, type, args = {}, timeout = 15) {
  const { url, token } = await conn();
  if (!token) throw new Error(`no bridge token at ${BRIDGE_FILE} — is SafariSelector installed and running?`);
  const r = await fetch(`${url}/command`, {
    method: "POST",
    body: JSON.stringify({ token, profileUUID, type, args, timeout }),
    signal: AbortSignal.timeout((timeout + 2) * 1000),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || `bridge HTTP ${r.status}`);
  if (!j.ok) throw new Error(j.error || `${type} failed`);
  return j.data;
}
