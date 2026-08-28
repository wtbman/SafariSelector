import Foundation
import Combine
import os.log

/// The merged, live view of every openable Safari window.
///
/// AppleScript is the spine: it sees every window in every profile, and is the only
/// source of tab group names. Each awake profile's extension instance then supplies
/// the two things AppleScript cannot — the profile's identity and the WebExtension
/// window id that `tabs.create` needs. The two views are joined on the active tab URL.
///
/// Windows whose profile is dormant still appear, as *cold* targets. They become warm
/// when that profile is woken.
final class TargetStore: ObservableObject {

    @Published private(set) var targets: [SafariTarget] = []

    private var byProfile: [String: [Bridge.WindowInfo]] = [:]
    private let lock = NSLock()
    private let log = Logger(subsystem: "cc.wtb.SafariSelector", category: "store")
    private let config: Config

    init(config: Config) {
        self.config = config
    }

    func update(profileUUID: String, windows: [Bridge.WindowInfo]) {
        lock.lock()
        byProfile[profileUUID] = windows
        lock.unlock()
        rebuild()
    }

    /// Raw per-profile window counts, before merging. Diagnostic only.
    var rawCounts: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return byProfile.mapValues(\.count)
    }

    /// Looks up the live extension coordinates for a window, by its active tab URL.
    /// Used after waking a cold profile.
    func warmCoordinates(forActiveURL url: String) -> (profileUUID: String, windowId: Int)? {
        lock.lock(); defer { lock.unlock() }
        for (profile, windows) in byProfile {
            if let w = windows.first(where: { $0.activeTabUrl == url }) {
                return (profile, w.windowId)
            }
        }
        return nil
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

        // Active tab URL -> which profile/window the extension calls it.
        var warmByURL: [String: (profile: String, windowId: Int, focused: Bool)] = [:]
        for (profile, windows) in snapshot {
            for w in windows {
                warmByURL[w.activeTabUrl] = (profile, w.windowId, w.focused)
            }
        }

        // A profile's own name appears as the title prefix of its loose-tab windows,
        // so a prefix equal to the profile's label is not a tab group.
        var labelForProfile: [String: String] = [:]
        for profile in snapshot.keys {
            labelForProfile[profile] = config.profileLabel(for: profile)
                ?? String(profile.prefix(8))
        }

        var out: [SafariTarget] = []
        for w in scriptWindows {
            let warm = warmByURL[w.activeTabURL]
            let profileLabel = warm.map { labelForProfile[$0.profile] ?? $0.profile } ?? "Other profiles"
            var groupLabel = w.prefix
            if let g = groupLabel, g.caseInsensitiveCompare(profileLabel) == .orderedSame {
                groupLabel = nil   // loose-tab window, not a tab group
            }
            out.append(SafariTarget(
                appleScriptWindowID: w.appleScriptID,
                profileUUID: warm?.profile,
                windowId: warm?.windowId,
                profileLabel: profileLabel,
                tabGroupLabel: groupLabel,
                activeTabTitle: w.activeTabTitle,
                activeTabURL: w.activeTabURL,
                tabCount: w.tabCount,
                isFocused: warm?.focused ?? false
            ))
        }

        out.sort {
            if $0.isFocused != $1.isFocused { return $0.isFocused }
            if $0.profileLabel != $1.profileLabel { return $0.profileLabel < $1.profileLabel }
            return $0.displayLabel < $1.displayLabel
        }

        DispatchQueue.main.async { self.targets = out }
    }
}
