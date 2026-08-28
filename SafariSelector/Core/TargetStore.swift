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

    private var byProfile: [String: [Bridge.WindowInfo]] = [:]
    private let lock = NSLock()
    private let log = Logger(subsystem: "cc.wtb.SafariSelector", category: "store")
    private let config: Config

    /// How far a window's left edge and size may disagree between the two views
    /// and still be considered the same window. These agree exactly in practice, so
    /// this only absorbs rounding.
    private static let shapeTolerance = 40

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

        let pairing = pairByGeometry(scriptWindows: scriptWindows, snapshot: snapshot)

        // Learn which profile owns each tab group while it is visible, so the same
        // window is still labelled correctly later when its profile is dormant.
        for w in scriptWindows {
            if let group = w.prefix, let matched = pairing[w.appleScriptID] {
                let profile = matched.profile
                DispatchQueue.main.async { self.config.learn(group: group, belongsTo: profile) }
            }
        }

        var out: [SafariTarget] = []
        for w in scriptWindows {
            let matched = pairing[w.appleScriptID]
            let owningProfile = matched?.profile ?? w.prefix.flatMap { config.profileOwning(group: $0) }
            let profileLabel = owningProfile.map { uuid in
                config.profileLabel(for: uuid) ?? String(uuid.prefix(8))
            } ?? "Unknown profile"

            // A window showing loose tabs is titled with the profile's own name, so
            // a prefix equal to the profile label is not a tab group.
            var groupLabel = w.prefix
            if let g = groupLabel, g.caseInsensitiveCompare(profileLabel) == .orderedSame {
                groupLabel = nil
            }

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

        DispatchQueue.main.async { self.targets = out }
    }

    /// Pairs AppleScript windows with extension windows, one-to-one, by geometry.
    ///
    /// The obvious key — the active tab's URL — is wrong. Several windows routinely
    /// show the same page (especially just after this app has opened the same link
    /// into a few of them), and they then collapse onto a single extension window,
    /// which sends later links to the wrong window. Geometry is genuinely unique.
    private func pairByGeometry(
        scriptWindows: [AppleScriptProbe.Window],
        snapshot: [String: [Bridge.WindowInfo]]
    ) -> [Int: (profile: String, info: Bridge.WindowInfo)] {

        var candidates: [(profile: String, info: Bridge.WindowInfo)] = []
        for (profile, windows) in snapshot {
            for w in windows { candidates.append((profile, w)) }
        }

        // Score every pair on shape, keeping vertical distance only as a tiebreak
        // for the rare case where two windows share a left edge and size.
        var scored: [(shape: Int, vertical: Int, scriptID: Int, index: Int)] = []
        for w in scriptWindows {
            for (i, c) in candidates.enumerated() {
                guard let l = c.info.left, let t = c.info.top,
                      let width = c.info.width, let h = c.info.height else { continue }
                let other = AppleScriptProbe.Bounds(left: l, top: t, width: width, height: h)
                let shape = w.bounds.shapeDistance(to: other)
                guard shape <= Self.shapeTolerance else { continue }
                scored.append((shape, w.bounds.verticalDistance(to: other), w.appleScriptID, i))
            }
        }

        // Best matches first, so one ambiguous window cannot cascade into a chain of
        // wrong assignments. Each side is used at most once.
        var pairing: [Int: (profile: String, info: Bridge.WindowInfo)] = [:]
        var used = Set<Int>()
        for pair in scored.sorted(by: { ($0.shape, $0.vertical) < ($1.shape, $1.vertical) }) {
            guard pairing[pair.scriptID] == nil, !used.contains(pair.index) else { continue }
            pairing[pair.scriptID] = candidates[pair.index]
            used.insert(pair.index)
        }
        return pairing
    }
}
