import Foundation

/// One openable destination: a specific Safari window, in a specific profile.
///
/// A "tab group" is not addressable in its own right. Safari places a new tab into
/// whatever group the target window is *currently showing*, so a window is the finest
/// target that exists, and `tabGroupLabel` describes what that window is showing.
struct SafariTarget: Identifiable, Hashable {
    /// Safari-assigned profile UUID, from `SFExtensionProfileKey`.
    let profileUUID: String
    /// WebExtension window id. This is what `tabs.create` takes.
    let windowId: Int

    var profileLabel: String
    /// Tab group the window is showing, or nil when it is showing loose tabs.
    var tabGroupLabel: String?
    var activeTabTitle: String
    var activeTabURL: String
    var tabCount: Int
    var isFocused: Bool

    var id: String { "\(profileUUID)#\(windowId)" }

    /// What the picker shows as the primary line.
    var displayLabel: String {
        tabGroupLabel ?? "Loose tabs"
    }

    /// Everything the fuzzy filter should match against.
    var searchHaystack: String {
        [profileLabel, tabGroupLabel ?? "loose tabs", activeTabTitle, activeTabURL]
            .joined(separator: " ")
            .lowercased()
    }
}
