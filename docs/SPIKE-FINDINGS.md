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

## Becoming a selectable default browser

Claiming the `http`/`https` URL schemes is **not** sufficient to appear in
*System Settings → Desktop & Dock → Default web browser*. Two further things are required, and
neither produces any error when missing — the app simply never appears in the list:

1. **Do not set `LSUIElement` in Info.plist.** macOS filters agent apps out of the default browser
   list. Register as a regular app and call `NSApp.setActivationPolicy(.accessory)` at launch
   instead; the app is still dockless and menu-bar-only. With `LSUIElement` set, `lsregister -dump`
   shows `bundle flags: ... ui-element` and the app is excluded.
2. **Declare `CFBundleDocumentTypes` for `public.html`** with `CFBundleTypeRole = Viewer`. macOS
   builds the popup from an internal UTI, `com.apple.default-app.web-browser`, which LaunchServices
   only synthesises for apps that declare they can view HTML.

Verify with:

```bash
lsregister -dump | grep -A80 'path:.*YourApp.app (' | grep -i 'claimed UTIs'
# want: com.apple.default-app.web-browser, public.html
```

Real browsers also declare `http` and `https` as **separate** `CFBundleURLTypes` entries rather
than one entry listing both schemes; this build follows that convention.

System Settings caches the list — quit it with Cmd-Q and reopen before concluding a change failed.

### …but System Settings will still not list it

Even with all of the above correct, SafariSelector never appears in
*System Settings → Desktop & Dock → Default web browser*. That popup applies a further filter of
its own. LaunchServices itself is perfectly happy:

```swift
NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
// -> Safari, SafariSelector, ChatGPT, BetterTouchTool, Firefox
```

ChatGPT and BetterTouchTool are registered `https` handlers too, and are likewise absent from that
popup — so this is not something a bundle can declare its way out of.

**The supported path is `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`**, which
raises the system's own confirmation prompt. This works, and is what the app's
*Settings → General → Make SafariSelector the Default* button calls. Note that macOS prompts once
and applies the choice to both `http` and `https`, so the second call commonly reports an error
("The file couldn't be opened") even though the change succeeded — verify by reading the default
back rather than trusting the callback.

## WebExtension window ids are not durable

Safari reassigns `windowId` values when an extension's background worker restarts — observed
climbing 10522 → 18810 → 34480 → 35551 → 40778 for the *same* window within one session. A window
id captured in an earlier snapshot can therefore name a window that no longer exists, and
`tabs.create` fails with:

```
Invalid call to tabs.create(). Window not found.
```

Because the app fails open, that surfaced as the worst possible symptom: the link opened in
Safari's generic last-used window, exactly the behaviour the whole project exists to prevent.

Mitigations, all three applied:

1. The extension **validates the window id** with `windows.get` before using it, and falls back to
   `windows.getLastFocused()`.
2. The app **focuses the intended window via AppleScript immediately before sending `OPEN`**, so
   that fallback resolves to the right window. AppleScript window ids are stable within a Safari
   session, unlike WebExtension ids.
3. `SafariTarget.id` is keyed on the **tab group**, not the window id or the active tab URL —
   both of which change constantly. This is what routing rules and last-choice memory persist.

Related trap: `NSAppleScript.executeAndReturnError` returns a descriptor whose `stringValue` is
`nil` for a script with no result. Treating that as failure made a working `focus` call look
broken. Return `""` on success and reserve `nil` for a real error.

## A tab group can share its profile's name

Safari titles a window `TabGroupName — PageTitle` when a tab group is active and
`ProfileName — PageTitle` when it is showing loose tabs. It is tempting to infer "this window is
showing loose tabs" from *prefix == profile name* — and wrong. A tab group named after its own
profile (`Work` inside the `Work` profile) is a real configuration, and that
inference relabels it as loose tabs, which then matches the wrong auto-select pattern and sends
links to the wrong window.

The two cases are indistinguishable from the window title alone. The app therefore shows whatever
the prefix says and does not guess. A consequence: two windows in one profile can carry the same
label, so lists must key on `SafariTarget.rowKey` (per window) rather than `id` (per destination).

## Restarting the app leaves most profiles dormant

Killing and relaunching SafariSelector drops every extension connection. Safari does not restart a
profile's background worker just because something reconnected — MV3 workers start on browser
events — so typically only the frontmost profile comes back on its own, and `rawWindowCounts`
shows a single entry.

This is not a fault to fix at startup: the wake-on-demand path handles it at the moment it matters
(observed waking a cold profile in one attempt, ~700ms). But it does mean **after reinstalling the
app, most targets will read `cold` until they are used**, which looks alarming and is not.

If waking genuinely fails — `profile did not wake for AppleScript window N` — the extension is not
running in that profile at all. Check *Develop → Allow Unsigned Extensions* and that the extension
is enabled; toggling it off and on restores it.
