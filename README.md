# SafariSelector

A macOS app that registers as a default web browser. When you click a link anywhere in macOS,
SafariSelector shows a keyboard-driven picker of every open Safari window across every profile,
and opens the link **inside the selected window's currently-selected tab group**.

This fixes Safari's default behaviour, where an externally-clicked link lands as a loose tab in
the last-used window of the last-used profile — never in a tab group.

## How it works

Safari exposes no tab-group API to extensions and no tab-group concept to AppleScript, so neither
alone is sufficient. SafariSelector combines them:

- A **Safari Web Extension**, enabled once and active in every profile, enumerates that profile's
  windows and does the actual opening. `tabs.create({windowId})` implicitly places the new tab in
  whatever tab group the target window is currently showing — this is the mechanism, and it is
  [verified](docs/SPIKE-FINDINGS.md).
- **AppleScript** supplies the human-readable tab-group names, which the extension cannot see.
  Windows are correlated between the two views by active-tab URL.
- The native handler receives `SFExtensionProfileKey`, a stable Safari-assigned **profile UUID**,
  giving real per-profile identity.

See [`docs/SPIKE-FINDINGS.md`](docs/SPIKE-FINDINGS.md) for the capability probe this design rests
on, and [`AGENT_BUILD_INSTRUCTIONS.md`](AGENT_BUILD_INSTRUCTIONS.md) for the build plan.

## Building

```bash
xcodebuild -project SafariSelector.xcodeproj -scheme SafariSelector \
  -configuration Debug -derivedDataPath /tmp/SafariSelector-DD build
```

Keep `-derivedDataPath` outside the repo. Some filesystems attach extended attributes that make
codesigning fail with `resource fork, Finder information, or similar detritus not allowed`.

Then install it:

```bash
./scripts/install.sh
```

## Agent access (MCP)

`mcp/` is an [MCP](https://modelcontextprotocol.io) server that lets an AI agent (Claude Code,
Codex, GitHub Copilot, …) see and manage Safari tabs: list windows and tabs across every profile
with tab-group labels, find stale or duplicate tabs, close, move tabs between windows (which places
them in the target window's tab group), open a URL into a chosen tab group, and bring a tab to the
front. See [`mcp/README.md`](mcp/README.md).

```bash
cd mcp && npm install
```

`.mcp.json` registers it as `safari` for Claude Code in this repository. Elsewhere, point the client
at `node /path/to/SafariSelector/mcp/server.js`.

## Licence

GNU General Public License v3.0 — see [LICENSE](LICENSE).
