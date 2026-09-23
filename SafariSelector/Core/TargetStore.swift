//
//  SafariSelector — open links in a chosen Safari window's active tab group.
//  Copyright (C) 2026 SafariSelector contributors
//
//  This program is free software: you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version. See <https://www.gnu.org/licenses/>.
//

import Foundation
import Combine
import os.log

/// The merged, live view of every openable Safari window.
///
/// AppleScript is the spine: it sees every window in every profile, and is the only
/// source of tab group names. Each awake profile's extension instance then supplies
/// the two things AppleScript cannot — the profile's identity and the WebExtension
/// window id that `tabs.create` needs.
///
/// Windows whose profile is dormant still appear, as *cold* targets. They become warm
/// when that profile is woken.
final class TargetStore: ObservableObject {

    @Published private(set) var targets: [SafariTarget] = []
    @Published private(set) var scanFailed = false

    private var byProfile: [String: [Bridge.WindowInfo]] = [:]
    private let lock = NSLock()
    private let log = Logger(subsystem: "cc.wtb.SafariSelector", category: "store")
    private let config: Config

    /// Allow small geometry differences, but never treat position/size as identity.
    private static let geometryTolerance = 40

    init(config: Config) {
        self.config = config
    }

    func update(profileUUID: String, windows: [Bridge.WindowInfo]) {
        lock.lock()
        byProfile[profileUUID] = windows
        lock.unlock()
        rebuild()
    }

    func forget(profileUUID: String) {
        lock.lock()
        byProfile.removeValue(forKey: profileUUID)
        lock.unlock()
        rebuild()
    }

    /// Saved profiles remain editable even when Safari has not run their worker
    /// this session. This is a catalog, not a claim that a worker is connected.
    var knownProfiles: [String] {
        lock.lock()
        let reported = Set(byProfile.keys)
        lock.unlock()
        return Array(reported.union(config.stored.profileAliases.keys)
            .union(config.stored.groupToProfile.values))
    }

    func owningProfile(of target: SafariTarget) -> String? {
        target.profileUUID ?? target.tabGroupLabel.flatMap { config.profileOwning(group: $0) }
    }

    func windowCount(for uuid: String) -> Int {
        windows(for: uuid).count
    }

    func windows(for uuid: String) -> [SafariTarget] {
        targets.filter { owningProfile(of: $0) == uuid }
    }

    /// Raw per-profile window counts, before merging. Diagnostic only.
    var rawCounts: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return byProfile.mapValues(\.count)
    }

    /// What each instance actually reported, geometry included. Diagnostic only —
    /// missing geometry means an instance is still running an older background.js.
    var rawWindows: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return byProfile.flatMap { profile, windows in
            windows.map { w in
                [
                    "profile": String(profile.prefix(8)),
                    "windowId": w.windowId,
                    "geometry": (w.left != nil)
                        ? "\(w.left!),\(w.top!) \(w.width!)x\(w.height!)"
                        : "MISSING - extension needs reloading",
                    "activeTabTitle": w.activeTabTitle,
                ] as [String: Any]
            }
        }
    }

    /// Recomputes the target list. Always runs the AppleScript on its own queue;
    /// `completion` fires on the main queue.
    func rebuild(completion: (() -> Void)? = nil) {
        AppleScriptProbe.queue.async { [weak self] in
            self?.rebuildNow()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    private func rebuildNow() {
        let scriptWindows = AppleScriptProbe.windows()

        lock.lock()
        let snapshot = byProfile
        lock.unlock()

        DispatchQueue.main.async {
            self.apply(scriptWindows: scriptWindows, snapshot: snapshot)
        }
    }

    /// Merge one scan on the main queue so learning and publishing use the same
    /// settings state. Also allows regression tests without running Safari.
    func apply(scriptWindows: [AppleScriptProbe.Window]?, snapshot: [String: [Bridge.WindowInfo]]) {
        guard let scriptWindows else {
            // A failed read is not evidence that every Safari window closed.
            scanFailed = true
            return
        }
        scanFailed = false
        let pairing = Self.pairWindows(scriptWindows: scriptWindows, snapshot: snapshot)

        // Learn which profile owns each tab group while it is visible, so the same
        // window is still labelled correctly later when its profile is dormant.
        for w in scriptWindows {
            if let group = w.prefix, let matched = pairing[w.appleScriptID] {
                let profile = matched.profile
                config.learn(group: group, belongsTo: profile)
            }
        }

        var out: [SafariTarget] = []
        for w in scriptWindows {
            let matched = pairing[w.appleScriptID]
            let owningProfile = matched?.profile ?? w.prefix.flatMap { config.profileOwning(group: $0) }
            let profileLabel = owningProfile.map { uuid in
                config.profileLabel(for: uuid) ?? String(uuid.prefix(8))
            } ?? "Unknown profile"

            // Show the window's title prefix as its label, whatever it says.
            //
            // Previously a prefix equal to the profile's name was treated as "loose
            // tabs", on the theory that Safari titles a loose-tab window with the
            // profile name. That breaks when a tab group is *named after its profile*
            // — a real case here — and mislabelled a genuine "Work" tab group
            // as loose tabs, which then matched the wrong auto-select pattern. The
            // two are genuinely indistinguishable from the title alone, and showing
            // the name is more useful than guessing wrong.
            let groupLabel = w.prefix

            out.append(SafariTarget(
                appleScriptWindowID: w.appleScriptID,
                profileUUID: matched?.profile,
                windowId: matched?.info.windowId,
                profileLabel: profileLabel,
                tabGroupLabel: groupLabel,
                activeTabTitle: w.activeTabTitle,
                activeTabURL: w.activeTabURL,
                tabCount: w.tabCount,
                isFocused: matched?.info.focused ?? false,
                bounds: w.bounds
            ))
        }

        out.sort {
            if $0.isFocused != $1.isFocused { return $0.isFocused }
            if $0.profileLabel != $1.profileLabel { return $0.profileLabel < $1.profileLabel }
            return $0.displayLabel < $1.displayLabel
        }

        targets = out
    }

    /// Geometry alone is not identity: different profiles can have overlapping or
    /// maximized windows, and extension snapshots can lag behind window changes.
    /// Require matching page content and tab count as well as nearby bounds. Only
    /// accept a mutually unique pair; an ambiguous match must not poison persisted
    /// ownership or route a link into another profile. A later snapshot can resolve it.
    static func pairWindows(
        scriptWindows: [AppleScriptProbe.Window],
        snapshot: [String: [Bridge.WindowInfo]]
    ) -> [Int: (profile: String, info: Bridge.WindowInfo)] {
        let candidates = snapshot.flatMap { profile, windows in
            windows.map { (profile: profile, info: $0) }
        }
        var matches: [Int: [Int]] = [:]
        var candidateUses: [Int: Int] = [:]
        for w in scriptWindows {
            for (i, candidate) in candidates.enumerated() {
                let c = candidate.info
                guard c.tabCount == w.tabCount,
                      c.activeTabUrl == w.activeTabURL,
                      c.activeTabTitle == w.activeTabTitle,
                      let left = c.left, let top = c.top,
                      let width = c.width, let height = c.height else { continue }
                let bounds = AppleScriptProbe.Bounds(left: left, top: top, width: width, height: height)
                guard w.bounds.shapeDistance(to: bounds) <= geometryTolerance,
                      w.bounds.verticalDistance(to: bounds) <= geometryTolerance else { continue }
                matches[w.appleScriptID, default: []].append(i)
                candidateUses[i, default: 0] += 1
            }
        }

        var pairing: [Int: (profile: String, info: Bridge.WindowInfo)] = [:]
        for (id, indices) in matches {
            guard indices.count == 1, let i = indices.first, candidateUses[i] == 1 else { continue }
            pairing[id] = candidates[i]
        }
        return pairing
    }
}
