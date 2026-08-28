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

**Do not host this repo in iCloud Drive.** It was moved out for two reasons: iCloud's extended
attributes break codesigning (`resource fork, Finder information, or similar detritus not
allowed`), and macOS privacy controls can revoke a process's access to `~/Library/Mobile
Documents` mid-session, which makes the working tree unreadable.
