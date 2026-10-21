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
  Windows are correlated between the two views by page URL/title, tab count, and bounds.
- The native handler receives `SFExtensionProfileKey`, a stable Safari-assigned **profile UUID**,
  giving real per-profile identity.

See [`docs/SPIKE-FINDINGS.md`](docs/SPIKE-FINDINGS.md) for the capability probe this design rests
on, and [`AGENT_BUILD_INSTRUCTIONS.md`](AGENT_BUILD_INSTRUCTIONS.md) for the build plan.

## Supported installation

Safari 18.4 and later supports Safari web extensions distributed outside the Mac
App Store when the containing app is **Developer ID signed and notarized**.
This installation does not need **Allow Unsigned Extensions**. An Apple Development
certificate alone is insufficient for this distribution channel.

Use the existing paid Apple account in Xcode. Existing local signing keys stay in
this Mac's Keychain and can serve multiple projects; Xcode may use Apple's managed
cloud signing for the Developer ID export. Never revoke another app's certificate
to repair this app. Team IDs, account details and signing assets stay outside Git.

```bash
export DEVELOPMENT_TEAM='<your paid team ID>'
export RELEASE_DIR="$(mktemp -d /tmp/SafariSelector-release.XXXXXX)"
./scripts/release.sh
./scripts/install.sh "$RELEASE_DIR/Export/SafariSelector.app"
```

The release script archives a hardened Release build, uses Xcode's existing account
to sign and upload it to Apple's notary service, and exports the notarized app.
Xcode may create a Developer ID Application certificate when none exists. If Apple
is still processing, keep the same `RELEASE_DIR` and resume with
`./scripts/release.sh export`; do not rebuild or resubmit merely to wait.
The `archive`, `submit` and `export` phases can also run separately.
This upload is for Apple's notarization service. It does not create an App Store
listing, request App Store review, or publish the app.

The installer checks the app and extension signatures, stapled ticket and Gatekeeper
assessment before replacing `/Applications/SafariSelector.app`. It saves the previous
app as a recovery ZIP under the app's Application Support directory and preserves
settings. Enable SafariSelector in Safari Settings → Extensions for each profile.
On a Developer ID build, the app hides and ignores the unsigned-extension workaround,
including a previously saved setting. Safari window automation may need macOS consent
again after changing signing identity.

When migrating from an unsigned build, macOS may also ask permission for
**SafariSelector Extension** to use its existing application data. Approve that
system dialog to retain the extension's container. Until it is answered, macOS
can hold the native handler in sandbox initialization before any app code runs;
the extension can appear enabled while the bridge has no connections. Do not
delete the container or reset shared signing certificates to resolve this wait.
After approval, reload the extension if its background pages were left waiting.
Safari may ignore an automated attempt to enable the extension; use the checkbox
directly in Safari Settings when that happens.

Changing from unsigned to Developer ID signing can also change Safari's opaque
extension profile identifiers. Verify saved aliases and rule destinations against
the live profiles after migration. Match identities through a known profile's
window; do not infer them from UUID order or delete settings to clear old names.

See [Apple's distribution documentation](https://developer.apple.com/documentation/safariservices/distributing-your-safari-web-extension).

## Development builds

```bash
xcodebuild -project SafariSelector.xcodeproj -scheme SafariSelector \
  -configuration Debug -derivedDataPath /tmp/SafariSelector-DD build
```

Keep `-derivedDataPath` outside the repo. Some filesystems attach extended attributes that make
codesigning fail with `resource fork, Finder information, or similar detritus not allowed`.

Then install it:

```bash
./scripts/install.sh --development
```

This explicit debugging path uses ad-hoc signing and requires Safari's **Allow
Unsigned Extensions**, which resets at Safari launch. It refuses to overwrite an
installed Developer ID release.

Run the settings and auto-select regression checks without launching Safari:

```bash
./scripts/test-config.sh
bash scripts/test-routing.sh
bash scripts/test-opener.sh
bash scripts/test-attribution.sh
node --test tests/ExtensionRegressionTests.cjs
```

Auto-select supports separate profile and tab-group patterns. Older combined patterns
keep their original behavior until you choose **Use separate fields** in Settings.
Saved settings from older versions retain their aliases, rules, and history when newer
settings are absent.

Settings → Profiles shows up to four tab-group hints beneath each unnamed profile's UUID.
The focused window's group comes first, followed by other open groups and previously seen
groups, without duplicates. These are naming clues from Safari window titles, which can
also contain a profile name; they disappear once you name the profile.

Use **Show Window** beside a profile to restore and bring its open Safari window
forward while naming it. If several windows are open, choose one by its tab-group
and page title from the menu. Profiles with no open windows have a disabled button.
This works for named and unnamed profiles and does not open or change any tabs.
When a profile's window list relies on previously learned group ownership, Settings
labels it **Uses remembered ownership**. Live matching requires matching page URL,
page title, tab count, and nearby window bounds. For secondary displays where Safari's
two APIs report different vertical origins, at least two unique windows in the same
profile must confirm the same offset with distinct URLs. Once confirmed, that display
offset can also match a uniquely identified window in another profile. Blank and
ambiguous pages cannot use this exception. Open commands use the matched extension's coordinates.
Ambiguous matches stay unresolved
instead of teaching the app that a window belongs to an arbitrary profile.
Window scans capture stable Safari IDs before reading details, so bringing a window
forward cannot shift the enumeration and duplicate or skip a window. Failed scans
keep the last known list and show a refresh message instead of resetting counts.

Saved profiles remain in Settings across restarts. Window counts and the link picker include
only open browsing windows; saved tab groups without an open window are not destinations.
Before routing a link, the app focuses the chosen window and waits for its extension to
answer a PING. An enabled extension can still have a sleeping background worker, so an old
snapshot is not proof that it is ready. Timed-out queued commands are discarded instead of
being replayed after Safari has already received the fallback link.
Readiness allows a single PING up to eight seconds within the ten-second wake
budget, so a healthy but slow reply is not repeatedly discarded after one second.

The macOS extension uses a Manifest V2 persistent background page. Safari suspended
the former Manifest V3 worker even with a pending poll, and focusing a window did
not reliably restart it. Optional tab-history loading no longer blocks the bridge.
After installing this update, reload the extension in Safari Settings. A PING reply
reports extension version `1.1.1` and background mode `persistent` to verify the
running copy, rather than just the files installed on disk.

This trades lower idle resource use for reliable routing: the extension background
context stays loaded in each enabled profile and renews its local poll about every
30 seconds. It does not pin ordinary webpages in memory or request that macOS stay
awake. Memory and energy overhead, and recovery after system sleep, have not yet
been measured.

## Agent access (MCP)

`mcp/` is an [MCP](https://modelcontextprotocol.io) server that lets an AI agent (Claude Code,
Codex, GitHub Copilot, …) see and manage Safari tabs: list windows and tabs across every profile
with tab-group labels, find stale or duplicate tabs, close, move tabs between windows (which places
them in the target window's tab group), open a URL into a chosen tab group, and bring a tab to the
front. See [`mcp/README.md`](mcp/README.md). Tab-report requests follow the reusable
[report workflow](mcp/TAB_REPORTS.md), grouped by profile and tab group and saved in the user's
configured memory location.

```bash
cd mcp && npm install
```

`.mcp.json` registers it as `safari` for Claude Code in this repository. Elsewhere, point the client
at `node /path/to/SafariSelector/mcp/server.js`.

## Licence

GNU General Public License v3.0 — see [LICENSE](LICENSE).

Tab-activity storage saves are coalesced and serialized. Failed reads or writes retry
with backoff without blocking routing or discarding unsaved activity. Closed-tab URLs
are pruned on each save. PING includes `activityPersistence` with `status`, `pending`,
and `lastSaved`; check this separately from bridge connectivity. `retrying` means
Safari storage is failing, while `saving` can indicate an outstanding storage call.
Diagnostics omit storage error text because Safari embeds browsing URLs in it.
