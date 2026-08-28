# SafariSelector — Design

## The problem

macOS routes an externally-clicked link to the default browser. Safari then opens it as a
**loose tab in the last-used window of the last-used profile** — never inside a Tab Group. With
multiple profiles and multiple tab groups, every external link lands somewhere arbitrary and has
to be dragged into place by hand.

SafariSelector registers itself as a default web browser, intercepts the URL, shows a
keyboard-driven picker of every open Safari window across every profile, and opens the link
**inside the selected window's currently-selected tab group**.

## Why this is harder than it sounds

Neither of Safari's two automation surfaces can do the job alone. This was established
empirically before any code was written; see [SPIKE-FINDINGS.md](SPIKE-FINDINGS.md).

| | AppleScript | Web Extension |
|---|---|---|
| Sees windows in **all** profiles | ✅ | ❌ own profile only |
| Sees windows while profile is **dormant** | ✅ | ❌ worker not running |
| Knows the **tab group name** | ✅ via window title | ❌ no API at all |
| Knows **profile identity** | ❌ | ✅ `SFExtensionProfileKey` |
| Can open a tab **into a tab group** | ❌ | ✅ `tabs.create({windowId})` |

Specifically:

- Safari's scripting dictionary has **no tab group class and no profile class**. But a window's
  `name` renders as `TabGroupName — PageTitle` (or `ProfileName — PageTitle` when the window is
  showing loose tabs). That prefix is the only place a tab group's name is exposed anywhere.
- Safari's WebExtension API has **no `browser.tabGroups`**, no `groupId` on tabs, and no `title`
  on windows. But `tabs.create({windowId, url})` implicitly places the new tab into whatever tab
  group that window is currently showing. **This is the mechanism the whole app rests on**, and
  it was verified by spike before anything else was built.
- Extensions are enabled per profile and each instance sees only its own profile's windows.
  The native handler receives `SFExtensionProfileKey`, a stable Safari-assigned profile UUID —
  the only source of profile identity anywhere in the system.

So: **AppleScript is the spine, the extension is the hands.**

## Architecture

```
SafariSelector.app                    LSUIElement agent + default browser handler
├─ main.swift        explicit NSApplication entry (see note below)
├─ AppDelegate       application(_:open:) -> rules -> picker -> Opener
├─ AppleScriptProbe  every window, every profile, with tab group names
├─ BridgeServer      loopback HTTP server, one long-poll per profile
├─ TargetStore       merges the two views into [SafariTarget]
├─ Opener            opens via the extension; wakes cold profiles; fails open
├─ RuleEngine/Config domain rules, aliases, group→profile memory
└─ SelectorPanel/View  keyboard-driven picker

SafariSelector Extension.appex        enabled once, active in every profile
├─ background.js     discover -> long-poll -> snapshot / execute OPEN
└─ SafariWebExtensionHandler.swift    returns {port, profileUUID}
```

### Transport: loopback HTTP long-polling

Not a WebSocket. The spike verified `fetch()` to `http://127.0.0.1` works from a Safari
extension; `ws://` was never verified, and building on the transport we have evidence for was
the safer call. Long-polling also has a useful side effect: an in-flight `fetch` keeps the MV3
background worker alive.

- `POST /snapshot` — an instance reports its windows
- `GET /poll` — an instance parks here (30s) until the app has a command for it
- `POST /result` — an instance reports a command's outcome
- `GET /status` — read-only introspection, used for testing and Settings

**Commands are queued per profile, not handed to a live waiter.** There is always a gap between
one long-poll returning and the next arriving; requiring a parked connection meant commands sent
in that gap were silently lost and fell back to a plain Safari open.

### Cold targets and waking

Safari only runs an extension's background worker in profiles it considers active. A window in a
dormant profile therefore has no WebExtension window id, and cannot be opened into.

Rather than hide those windows, the picker lists them as **cold** targets — AppleScript sees them,
so they are always in the list. When one is chosen, the app focuses that window via AppleScript,
which fires `windows.onFocusChanged` inside that profile and starts its worker. The worker
connects, reports its windows, and the target is matched back **by AppleScript window id** (not by
active tab URL, which can be stale by then). Then the open proceeds normally.

Dormancy stops being a limitation and becomes a step in the flow.

### Labelling

`TargetStore` joins the two views on the **active tab URL**, which both sides observe.

A window showing loose tabs is titled with the *profile* name, so a title prefix equal to the
profile's own label is treated as "loose tabs" rather than a tab group.

Profile *names* are not available anywhere — Safari gives a UUID, never a name. Two mitigations:

1. The user names each profile once in Settings; the UUID keeps that name attached forever.
2. The app learns which profile owns each **tab group** while it can see it. A tab group belongs
   to exactly one profile and does not move, so a dormant profile's windows are still labelled
   correctly.

### Failing open

This app is the system's default browser. If any part of the pipeline fails — no extension, no
response, a window closed underneath us, an unexpected scheme — the URL is handed to Safari the
way the system would have. A dropped click is the one unacceptable outcome, so every failure path
in `Opener` ends at `openInSafariDirectly`.

## Auto-select

If the picker sits untouched for a configurable number of seconds, it can choose a window on its
own. The target is expressed as **text matched against "profile — tab group"**, not as a stored
window: WebExtension window ids are reassigned constantly and even profile UUIDs are opaque, but
`Work*` keeps meaning what you meant. Matching is a case-insensitive glob (`*`, `?`); a pattern
with no wildcard is a substring search.

If the pattern matches nothing, the picker stays open rather than guessing — opening a link
somewhere arbitrary is worse than waiting. Settings previews the current match live, so a typo is
obvious there rather than ten seconds into a link going somewhere unexpected. Any keystroke,
filter edit, or click cancels the countdown.

## Where the link came from

The picker names the app the link arrived from. `application(_:open:)` does not say, so it is
resolved in three steps:

1. The **sender pid on the Apple Event** that carried the URL (`keySenderPIDAttr`). Authoritative,
   and the only one that identifies an app which opened a link without ever coming to the front —
   the case that matters for links fired automatically by an AI assistant.
2. The current frontmost application, ignoring this app.
3. The last application to be frontmost that wasn't this one, tracked continuously — LaunchServices
   often activates this app before delivering the URL, which makes the frontmost app useless by
   itself.

## Known limitations

- **The bridge is unauthenticated.** Safari requires web-extension appexes to be sandboxed, so
  the appex cannot read the app's token from Application Support. The bridge accepts token-less
  instances and relies on binding to loopback only, which means any local process can ask it to
  open a URL in Safari. Closing this needs an App Group container shared by the app and appex.
- **Signing.** Safari loads an extension without *Develop → Allow Unsigned Extensions* only if it
  came from the App Store or — since Safari 18.4 — is signed with a **Developer ID** and notarized.
  An "Apple Development" certificate from a free Apple ID is **not** sufficient; Developer ID
  requires paid Apple Developer Program membership. Until then that switch must stay on, and Safari
  resets it on every launch. *Settings → General → Safari extension* can switch it back
  automatically, by driving Safari's Develop menu through Accessibility. It is off by default.
- **Tab group names are not unique.** Two profiles could each have a group called "Work"; the
  learned group→profile mapping would then be ambiguous. Rules pin a profile UUID as well.
