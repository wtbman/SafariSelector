import Foundation
import Combine
import os.log

/// The merged, live view of every openable Safari window.
///
/// Two sources, neither sufficient alone:
///   - each profile's extension instance supplies window ids (the only thing that can
///     be opened into) and real profile identity;
///   - AppleScript supplies tab group names, which the extension cannot see.
/// They are joined on the active tab's URL.
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

    func forget(profileUUID: String) {
        lock.lock()
        byProfile.removeValue(forKey: profileUUID)
        lock.unlock()
        rebuild()
    }

    /// Recomputes the target list, re-reading AppleScript labels.
    func rebuild() {
        let names = AppleScriptProbe.windowNamesByActiveURL()

        lock.lock()
        let snapshot = byProfile
        lock.unlock()

        var out: [SafariTarget] = []
        for (profileUUID, windows) in snapshot {
            // A window showing loose tabs is titled with the *profile* name, so a
            // prefix equal to this profile's own label is not a tab group.
            let profileLabel = config.profileLabel(for: profileUUID)
                ?? inferProfileLabel(windows: windows, names: names)
                ?? String(profileUUID.prefix(8))

            for w in windows {
                let matched = names[w.activeTabUrl]
                var groupLabel = matched?.prefix
                if let g = groupLabel, g.caseInsensitiveCompare(profileLabel) == .orderedSame {
                    groupLabel = nil          // loose-tab window, not a tab group
                }
                out.append(SafariTarget(
                    profileUUID: profileUUID,
                    windowId: w.windowId,
                    profileLabel: profileLabel,
                    tabGroupLabel: groupLabel,
                    activeTabTitle: w.activeTabTitle,
                    activeTabURL: w.activeTabUrl,
                    tabCount: w.tabCount,
                    isFocused: w.focused
                ))
            }
        }

        out.sort {
            if $0.isFocused != $1.isFocused { return $0.isFocused }
            if $0.profileLabel != $1.profileLabel { return $0.profileLabel < $1.profileLabel }
            return $0.displayLabel < $1.displayLabel
        }

        DispatchQueue.main.async { self.targets = out }
    }

    /// A profile's own name shows up as the title prefix of any loose-tab window it
    /// owns. Without a user-supplied alias, the most frequent prefix across a
    /// profile's windows is the best available guess.
    private func inferProfileLabel(windows: [Bridge.WindowInfo],
                                   names: [String: AppleScriptProbe.WindowName]) -> String? {
        var counts: [String: Int] = [:]
        for w in windows {
            if let p = names[w.activeTabUrl]?.prefix { counts[p, default: 0] += 1 }
        }
        return counts.count == 1 ? counts.keys.first : nil
    }
}
