# SafariSelector MCP

An MCP server exposing Safari windows and tabs to an agent. It is a client of the SafariSelector
app's loopback bridge (`BridgeServer.swift`) — it does not run a bridge of its own.

## Tools

| Tool | What it does |
|---|---|
| `safari_status` | Is the app reachable; one line per window with profile / tab group / tab count |
| `safari_list_windows` | Windows as JSON: `asId`, `label` (tab group), `profile`, `extWindowId` |
| `safari_list_tabs` | Tabs, filterable by window, tab-group label, profile, substring, or minimum age |
| `safari_close_tabs` | Close by tab id and/or by exact URL |
| `safari_close_duplicate_tabs` | Close repeated URLs in a window, keeping the leftmost copy |
| `safari_move_tabs` | Move tabs to another window in the same profile → they join its current tab group |
| `safari_open_url` | Open a URL into a window chosen by id or tab-group label |
| `safari_activate_tab` | Bring a tab to the front |

## Backends

| | App bridge | AppleScript (JXA) |
|---|---|---|
| Needs | SafariSelector running, extension enabled | Safari running |
| Profile + tab-group labels | ✅ (from `/status`, geometry-correlated) | ✅ label only, parsed from the window title |
| Tab ids, move, activate by id | ✅ | ❌ |
| Last-active age per tab | ✅ tracked by the extension, keyed by URL | ❌ |
| Close by URL, open, duplicates | — | ✅ |

The server uses the app when it can and degrades to AppleScript-only listing when it cannot.

Tab ids are reassigned whenever Safari restarts an extension worker (which happens after idle), so
tools that take ids expect them from a listing made immediately beforehand and refuse stale ones;
closing by URL is the robust alternative. Ages are `?` until the extension has observed activity,
and `>Nd` for tabs never activated since tracking began.

## Protocol

The app's bridge gained one route for this: `POST /command` with
`{token, profileUUID, type, args, timeout}` relays a command to that profile's extension instance
and returns its `CommandResult`. The token is read from
`~/Library/Application Support/SafariSelector/bridge.json`. Commands the extension answers:
`TABS`, `CLOSE_TABS {tabIds}`, `MOVE_TABS {tabIds, windowId, index}`, `ACTIVATE_TAB {tabId}`.

## Running

```bash
npm install
node server.js          # stdio MCP
```

Register with your client, e.g. for Claude Code: `claude mcp add safari -- node /path/to/mcp/server.js`.
