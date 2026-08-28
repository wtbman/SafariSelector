# Agent build instructions — SafariSelector

Ordered, independently verifiable tasks for building this app from nothing. Each task states its
acceptance test. Written to be executable without the conversation that produced it.

Read [docs/DESIGN.md](docs/DESIGN.md) first, and [docs/SPIKE-FINDINGS.md](docs/SPIKE-FINDINGS.md)
for the measured behaviour every decision here rests on.

## Preconditions

- macOS 14+ (developed on 26.4.1), Xcode 26+, Safari 17+ (developed on 26.4).
- **The repo must not live in iCloud Drive.** Its extended attributes break codesigning
  (`resource fork, Finder information, or similar detritus not allowed`), and macOS can revoke a
  process's access to `~/Library/Mobile Documents` mid-session.
- Keep DerivedData outside the repo: `-derivedDataPath /tmp/SafariSelector-DD`.
- If there is no Developer ID (`security find-identity -v -p codesigning` → `0 valid identities`),
  build ad-hoc with `CODE_SIGN_IDENTITY="-"` and expect to use Safari's
  *Develop → Allow Unsigned Extensions*.

---

## Task 1 — Prove the mechanism (BLOCKING GATE)

Everything else is wasted effort if this fails. Build a throwaway Safari Web Extension whose
popup calls `browser.windows.getAll({populate:true})` and then
`browser.tabs.create({windowId, url})` targeting a window that is **currently showing a tab group**.

**Acceptance:** the new tab appears *inside* that tab group, not as a loose tab.

Also record `typeof browser.tabGroups`, the keys present on tab and window objects, and whether
`sendNativeMessage` returns a `SFExtensionProfileKey` UUID.

**If this fails, stop and report.** The extension-first design is void, and the alternative
(Accessibility scripting to drive ⌘T) is a decision for the user, not a silent substitution.

> Already done. Result: **passes.** See docs/SPIKE-FINDINGS.md.

## Task 2 — Project scaffolding

Generate the app + extension targets:

```bash
xcrun safari-web-extension-converter Extension \
  --project-location .build-gen --app-name SafariSelector \
  --bundle-identifier cc.wtb.SafariSelector \
  --swift --macos-only --copy-resources --no-open --no-prompt --force
```

Then, in `project.pbxproj` — **edit it as a plist, never line-by-line**
(`plutil -convert xml1`, edit with `plistlib`, write back as XML; Xcode reads XML pbxproj).
Line-based edits corrupt multi-line objects such as `PBXVariantGroup`.

- `MACOSX_DEPLOYMENT_TARGET = 14.0` (needed for `SFExtensionProfileKey`).
- App target: `ENABLE_APP_SANDBOX = NO` (it sends Apple Events and listens on loopback).
- **Extension target: `ENABLE_APP_SANDBOX = YES`.** Safari refuses to register an unsandboxed
  web-extension appex — `pluginkit` silently omits it, with no error anywhere.
- Remove `INFOPLIST_KEY_NSMainStoryboardFile`; delete `Main.storyboard` and `ViewController.swift`.
- The appex bundle id must be prefixed by the app's, or `ValidateEmbeddedBinary` fails.

**Acceptance:** `xcodebuild -list -project SafariSelector.xcodeproj` parses.

## Task 3 — App shell as a background agent

`Info.plist`: `NSAppleEventsUsageDescription`; `CFBundleURLTypes` with **separate** `http` and
`https` entries (`LSHandlerRank = Owner`); and `CFBundleDocumentTypes` declaring `public.html`
with `CFBundleTypeRole = Viewer`.

Two non-obvious requirements for appearing in *Default web browser*, both silent when missing:

- **Do not set `LSUIElement`** — macOS filters agent apps out of that list. Rely on
  `NSApp.setActivationPolicy(.accessory)` at launch for the dockless behaviour.
- **Declare `public.html`** — the popup is built from an internal UTI,
  `com.apple.default-app.web-browser`, which LaunchServices only synthesises for apps that say
  they can view HTML. Claiming the URL schemes alone is not enough.

**Add an explicit `main.swift`** that constructs `NSApplication`, assigns the delegate, and calls
`run()`. Do **not** rely on `@main` on the delegate: `NSApplicationMain` installs the delegate from
the main storyboard, so with no storyboard the app launches, runs, and never calls
`applicationDidFinishLaunching`.

**Acceptance:** launching the app logs its startup line and stays resident, and

```bash
lsregister -dump | grep -A80 'path:.*SafariSelector.app (' | grep -i 'claimed UTIs'
# must include: com.apple.default-app.web-browser, public.html
```

Then quit System Settings (Cmd-Q, it caches) and confirm the app is offered under
*Desktop & Dock → Default web browser*.

## Task 4 — Bridge server

Loopback `NWListener` on port 53127 speaking minimal HTTP/1.1, with routes `/snapshot`, `/poll`,
`/result`, `/status`, plus `OPTIONS` (the extension's JSON `fetch` triggers a CORS preflight).

- Set the listener's `stateUpdateHandler` — without it, a failed bind is completely silent.
- **Queue commands per profile**; do not require a parked waiter. There is always a gap between
  polls, and commands sent in it are otherwise lost.
- Never call a `queue.sync` property from code already running on the bridge queue — that
  deadlocks and traps (`EXC_BREAKPOINT` in `__DISPATCH_WAIT_FOR_QUEUE__`).

**Acceptance**, with the app running and no Safari involvement:

```bash
curl -s -XPOST -H 'Content-Type: application/json' \
  -d '{"profileUUID":"T","windows":[]}' http://127.0.0.1:53127/snapshot   # {"ok":true}
curl -s -XOPTIONS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:53127/snapshot  # 204
time curl -s "http://127.0.0.1:53127/poll?profile=T"   # parks ~30s, then {"type":"IDLE"}
```

## Task 5 — Extension

`manifest.json`: `permissions: [tabs, nativeMessaging, storage]`,
`host_permissions: ["http://127.0.0.1/*"]`, `background.service_worker`. Omit `persistent` —
Safari does not support it.

`background.js`: discover via `sendNativeMessage` → long-poll → push a **lightweight** snapshot
(`windowId, focused, tabCount, activeTabUrl, activeTabTitle`) on window/tab events. Windows here
routinely hold 200+ tabs; never send the full tab array. Reconnect with capped exponential
backoff and re-discover on every failure — MV3 workers are killed aggressively.

`SafariWebExtensionHandler`: return `{port, profileUUID}` from `SFExtensionProfileKey`.

**Acceptance:** with the extension enabled, `lsof -nP -iTCP:53127` shows established connections,
and `/status` lists profile UUIDs with non-zero `rawWindowCounts`.

## Task 6 — Target store

Merge AppleScript windows (all profiles, with tab-group names from the `" — "` title prefix)
with per-profile extension windows, joined on active tab URL. Windows with no live worker are
**cold** — keep them in the list.

Run `NSAppleScript` on one dedicated serial queue. It is not thread-safe, and a query against a
200-tab window is slow enough to matter.

**Acceptance:** `/status` lists every window AppleScript can see, with correct tab group labels,
and marks which are warm.

## Task 7 — Opener, with wake-on-demand

Warm target → `OPEN` command. Cold target → focus its window via AppleScript (wakes the profile),
then re-derive the target list and match **by AppleScript window id**, not active tab URL, which
can be stale by then. Retry ~10s.

Every failure path must end in `openInSafariDirectly`. This app is the default browser; a dropped
click is the one unacceptable outcome.

**Acceptance (the test that defines the project):** with a rule routing `example.com` to a tab
group, `open -a SafariSelector "https://example.com/"` raises that window's tab count by one and
the tab is visibly inside the tab group. Verify it works when the target starts cold.

## Task 8 — Picker UI

Borderless floating `NSPanel` that can become key. Type to filter; `↑`/`↓`; `⌘1`–`⌘9` to jump
(plain digits would collide with the filter field); `⏎` opens; `⌘⏎` new window; `esc` cancels.
Use SwiftUI's `onKeyPress` — a `handle(key:)` called from the panel cannot mutate `@State`.

Always offer "Open in Safari normally" so a click is never lost.

## Task 9 — Rules, aliases, memory

Rules match a host glob and name a **tab group**, resolved to a live window at open time so they
survive window churn. Rules must resolve against cold targets too, or they silently stop working
whenever Safari lets a profile go dormant.

Learn which profile owns each tab group so dormant profiles are still labelled correctly. Let the
user name profiles in Settings — Safari never exposes a profile name, only a UUID.

## Task 10 — Packaging

`scripts/install.sh`: build, `ditto` to `~/Applications`, `lsregister -f -R -trusted`, launch.

**Never `codesign --deep`** the installed bundle — it strips the appex entitlements and
`pluginkit` then silently refuses to register the extension. Leave the build's signature intact.

Prefer `pluginkit`/`lsregister` over Safari's Extensions pane for install/uninstall churn;
uninstalling from that pane has been observed to crash Safari.

## Remaining work

- Batch handling when several URLs arrive at once (show one picker, apply to all).
- App Group container so the bridge can authenticate instances (see DESIGN.md limitations).
- Unit tests: bridge codec, window-title parsing, rule matching, fuzzy-filter ranking.
