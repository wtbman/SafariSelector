# Spike findings — Safari 26.4 WebExtension capability probe

Run 2026-08-28 on macOS 26.4.1 / Safari 26.4 / Xcode 26.6, against a live profile with
8 Safari profiles and windows holding 77–214 tabs each.

The spike is a throwaway Safari Web Extension (`spike/Extension`) whose popup gathers the
capability surface directly and POSTs it to a local collector, so results are read from disk
rather than by eye.

## The load-bearing question — ANSWERED YES

> Does `browser.tabs.create({windowId, url})` place the new tab **inside** the target window's
> currently-selected tab group?

**Yes.** Verified visually: creating a tab into window `4985`, which was displaying the
`Tickets` tab group, placed the new `example.com` tab inside `Tickets` — not as a
loose tab. This is the entire basis of the extension-first design, and it holds.

Note that this is *implicit* behaviour: the tab joins whatever group the window is currently
showing. There is no API to name or choose a group. Targeting a specific tab group therefore
means "target the window that is currently showing it".

## What Safari does NOT provide

| Probe | Result |
|---|---|
| `typeof browser.tabGroups` | `"undefined"` — no tab group API whatsoever |
| Tab object keys | `active, audible, height, highlighted, id, incognito, index, isArticle, isInReaderMode, mutedInfo, pinned, selected, status, title, url, width, windowId` — **no `groupId`** |
| Window object keys | `alwaysOnTop, focused, height, id, incognito, left, state, tabs, top, type, width` — **no `title`** |

**Consequence:** the extension can enumerate and target windows, but cannot *name* the tab group
a window is showing. Tab-group labels must come from elsewhere.

## What Safari DOES provide

- **`sendNativeMessage` works** from the extension to the bundled `.appex`.
- **Real profile identity.** The native handler receives `SFExtensionProfileKey` — a stable,
  Safari-assigned profile UUID (observed: `6374DACA-F2E9-4731-B9FB-F1338354A6FC`, identical
  across separate invocations). Strictly better than minting our own UUID into per-profile
  `browser.storage.local`, which the original plan proposed.
- **Loopback HTTP works** from the extension with `host_permissions: ["http://127.0.0.1/*"]`,
  confirming the bridge transport is viable.
- **Per-profile isolation is real.** This profile's extension saw **3** windows; AppleScript saw
  **6** across all profiles. One extension instance per profile is genuinely required.
- **Enabling is cheap.** Ticking the extension once activated it in **all 8 profiles** at once.

## Design consequences

1. **AppleScript stays in the design** — not as the opening mechanism, but as the *labelling*
   source. `name of window` yields `TabGroupName — PageTitle` (or `ProfileName — PageTitle` for a
   loose-tab window). Correlate AppleScript windows to extension windows by **active tab URL**,
   with tab count as a tiebreak.
2. **Profile identity comes from `SFExtensionProfileKey`**, plumbed from the `.appex` to the app.
   User-facing aliases still turn a UUID into "Work", but identity is stable without them.
3. **Do not snapshot all tabs.** With 214 tabs in a window, sending the full tab array on every
   change is wasteful. The bridge sends only `{windowId, focused, activeTabUrl, activeTabTitle,
   tabCount}`.
4. **The popup is not a reliable reporter.** Creating a tab dismisses the popup, killing pending
   work — the `createtest` POST never fired. Anything outliving a UI action belongs in the
   background worker.

## Environment gotchas

- **Never build inside iCloud Drive.** Codesigning fails with `resource fork, Finder information,
  or similar detritus not allowed`. Always pass a `-derivedDataPath` outside the tree.
- **No codesigning identity exists on this machine** (`security find-identity` → `0 valid
  identities found`). Builds are ad-hoc signed, requiring Safari's *Develop → Allow Unsigned
  Extensions* — which resets on every Safari relaunch.
- **Do not re-sign the app bundle with `codesign --deep`.** It strips the appex entitlements and
  `pluginkit` then silently refuses to register the extension. Copy with `ditto` and leave the
  build's signature intact.
- **Uninstalling the extension from Safari's Extensions pane crashed Safari.** Prefer
  `pluginkit`/`lsregister` from the command line for install/uninstall churn.
- The app must live somewhere stable (`~/Applications`), not in DerivedData.
- The generated project's appex bundle id must be prefixed by the app's bundle id, or
  `ValidateEmbeddedBinary` fails.
- `MACOSX_DEPLOYMENT_TARGET` must be ≥ 14.0 for `SFExtensionProfileKey`.

## Follow-up findings (app build)

- **Safari web extension appexes must be sandboxed.** With `ENABLE_APP_SANDBOX = NO` on the
  extension target, `pluginkit` silently refuses to register the extension — it simply never
  appears in the list, with no error anywhere. Re-enabling the sandbox fixed it immediately.
  - *Consequence:* the appex cannot read `~/Library/Application Support/SafariSelector/bridge.json`,
    so the shared auth token cannot reach the extension this way. The bridge accepts token-less
    instances and relies on binding to loopback only. Closing this properly would need an App
    Group container shared between the app and the appex.
- **`@main` on an `NSApplicationDelegate` does not install the delegate** when there is no
  storyboard. `NSApplicationMain` gets the delegate from the main storyboard, so a background
  agent with `INFOPLIST_KEY_NSMainStoryboardFile` removed launches, runs, and never calls
  `applicationDidFinishLaunching`. An explicit `main.swift` that sets `app.delegate` is required.
- **`NWParameters.requiredLocalEndpoint` is the wrong knob for a listener** — combined with
  `allowLocalEndpointReuse`, binding loopback works, but the listener's `stateUpdateHandler` is
  the only place failures surface. Without it, a failed bind is completely silent.
- **Do not edit `project.pbxproj` with line-based tools.** Deleting lines that mention a file
  corrupts multi-line objects such as `PBXVariantGroup`. Convert with
  `plutil -convert xml1`, edit via `plistlib`, and write back as XML — Xcode reads XML pbxproj.
