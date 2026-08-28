//
//  SafariSelector — open links in a chosen Safari window's active tab group.
//  Copyright (C) 2026 SafariSelector contributors
//
//  This program is free software: you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version. See <https://www.gnu.org/licenses/>.
//

import AppKit
import os.log

/// Opens URLs, via the extension when possible and via Safari directly when not.
///
/// The fallback is not a nicety. This app is the system's default browser: if any
/// part of the pipeline fails, the click must still reach Safari rather than
/// vanishing. Every failure path here ends in `openInSafariDirectly`.
final class Opener {

    private let bridge: BridgeServer
    private let store: TargetStore
    private let log = Logger(subsystem: "cc.wtb.SafariSelector", category: "opener")

    init(bridge: BridgeServer, store: TargetStore) {
        self.bridge = bridge
        self.store = store
    }

    /// Opens `url` in the target's window, landing in whatever tab group that window
    /// is currently showing. Wakes the target's profile first if it is cold.
    func open(_ url: URL, in target: SafariTarget) async {
        DebugLog.write("open \(url.absoluteString) into \(target.displayLabel) warm=\(target.isWarm)")
        guard let warm = await resolve(target) else {
            log.error("could not resolve target for \(url.absoluteString, privacy: .public)")
            openInSafariDirectly(url)
            return
        }
        let match = target.bounds.map {
            (left: $0.left, top: $0.top, width: $0.width, height: $0.height)
        }
        let command = Bridge.Command.open(windowId: warm.windowId, url: url.absoluteString,
                                          match: match)
        // Focus the intended window first. This keeps the extension's fallback
        // correct if the window id has gone stale, and matches what the user just
        // picked: the tab lands in the window they are looking at.
        if let scriptID = target.appleScriptWindowID {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                AppleScriptProbe.queue.async {
                    AppleScriptProbe.focus(windowID: scriptID)
                    c.resume()
                }
            }
        }
        DebugLog.write("sending OPEN windowId=\(warm.windowId) profile=\(warm.profileUUID)")
        let result = await bridge.send(command, to: warm.profileUUID)
        DebugLog.write("OPEN result: ok=\(result?.ok ?? false) err=\(result?.error ?? "-") fallback=\(result?.usedFallback ?? false)")
        guard let result, result.ok else {
            log.error("open failed: \(result?.error ?? "no response", privacy: .public)")
            openInSafariDirectly(url)
            return
        }
        activateSafari()
    }

    /// Turns a possibly-cold target into live extension coordinates.
    ///
    /// Safari only runs an extension's background worker in profiles it considers
    /// active, so a window in a dormant profile has no window id we can open into.
    /// Focusing that window fires `windows.onFocusChanged` inside its profile, which
    /// starts the worker; it then connects and reports its windows, and the window we
    /// want appears, paired by geometry like every other window.
    private func resolve(_ target: SafariTarget) async -> (profileUUID: String, windowId: Int)? {
        if let p = target.profileUUID, let w = target.windowId { return (p, w) }
        guard let scriptID = target.appleScriptWindowID else { return nil }

        DebugLog.write("waking cold profile by focusing AppleScript window \(scriptID)")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            AppleScriptProbe.queue.async {
                AppleScriptProbe.focus(windowID: scriptID)
                c.resume()
            }
        }

        // Re-derive both views on each attempt and match on the AppleScript window
        // id, which is stable within a Safari session.
        for attempt in 0..<40 {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                store.rebuild { c.resume() }
            }
            if let t = store.targets.first(where: { $0.appleScriptWindowID == scriptID }),
               let p = t.profileUUID, let w = t.windowId {
                DebugLog.write("woke after \(attempt) attempts: profile=\(p) windowId=\(w)")
                return (p, w)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        DebugLog.write("profile did not wake for AppleScript window \(scriptID)")
        log.warning("profile did not wake for window \(scriptID)")
        return nil
    }

    func openInNewWindow(_ url: URL, profileUUID: String?) async {
        guard let profileUUID else { openInSafariDirectly(url); return }
        let result = await bridge.send(.openNewWindow(url: url.absoluteString), to: profileUUID)
        guard let result, result.ok else { openInSafariDirectly(url); return }
        activateSafari()
    }

    /// Last resort: hand the URL to Safari the way the system would have.
    func openInSafariDirectly(_ url: URL) {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            log.fault("Safari not found; dropping \(url.absoluteString, privacy: .public)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: config)
    }

    private func activateSafari() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Safari")
            .first?
            .activate()
    }
}
