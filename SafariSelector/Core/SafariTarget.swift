import Foundation

/// One openable destination: a Safari window, in some profile.
///
/// A tab group is not addressable in its own right. Safari places a new tab into
/// whatever group the target window is *currently showing*, so a window is the finest
/// target that exists, and `tabGroupLabel` describes what that window is showing.
///
/// A target may be **cold**: AppleScript can see every window in every profile, but
/// the extension worker that would actually open into it only runs in profiles Safari
/// considers active. A cold target has no `profileUUID`/`windowId` yet — those are
/// resolved by focusing the window, which wakes that profile's worker.
struct SafariTarget: Identifiable, Hashable {
    /// Safari's AppleScript window id. Present for anything AppleScript can see,
    /// which is everything; used to focus (and thereby wake) a cold target.
    var appleScriptWindowID: Int?
    /// Safari-assigned profile UUID, from `SFExtensionProfileKey`. Nil while cold.
    var profileUUID: String?
    /// WebExtension window id — what `tabs.create` takes. Nil while cold.
    var windowId: Int?

    var profileLabel: String
    /// Tab group the window is showing, or nil when it is showing loose tabs.
    var tabGroupLabel: String?
    var activeTabTitle: String
    var activeTabURL: String
    var tabCount: Int
    var isFocused: Bool

    /// True once this target can be opened into without waking anything.
    var isWarm: Bool { profileUUID != nil && windowId != nil }

    /// Stable across cold→warm transitions, so selection does not jump when a
    /// profile wakes mid-picker. The active tab URL is the same key the two views
    /// are correlated on.
    var id: String { activeTabURL.isEmpty ? "as:\(appleScriptWindowID ?? -1)" : activeTabURL }

    var displayLabel: String { tabGroupLabel ?? "Loose tabs" }

    var searchHaystack: String {
        [profileLabel, tabGroupLabel ?? "loose tabs", activeTabTitle, activeTabURL]
            .joined(separator: " ")
            .lowercased()
    }
}
