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

    /// Stable identity of a *destination*, not of a moment.
    ///
    /// Keyed on the tab group, because that is what the user is actually choosing and
    /// it survives everything volatile: WebExtension window ids are reassigned when a
    /// background worker restarts, and the active tab URL changes the instant a tab is
    /// opened. Windows showing loose tabs have no group, so they fall back to the
    /// AppleScript window id, which at least lasts a Safari session.
    var id: String {
        if let group = tabGroupLabel {
            return "group:\(profileUUID ?? "?"):\(group)"
        }
        return "window:\(appleScriptWindowID ?? -1)"
    }

    var displayLabel: String { tabGroupLabel ?? "Loose tabs" }

    var searchHaystack: String {
        [profileLabel, tabGroupLabel ?? "loose tabs", activeTabTitle, activeTabURL]
            .joined(separator: " ")
            .lowercased()
    }
}
