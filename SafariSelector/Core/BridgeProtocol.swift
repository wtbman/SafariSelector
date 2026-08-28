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

/// Wire types for the loopback bridge between the app and each profile's extension
/// instance. Kept free of any networking so it can be unit-tested directly.
enum Bridge {

    /// One window as reported by an extension instance. Deliberately does not carry
    /// the tab array: windows here routinely hold 200+ tabs, and the app only needs
    /// enough to identify and label them.
    struct WindowInfo: Codable, Hashable {
        let windowId: Int
        let focused: Bool
        let tabCount: Int
        let activeTabUrl: String
        let activeTabTitle: String
        /// Screen geometry. This, not the active tab URL, is how a window in this
        /// list is matched to the same window in AppleScript's list.
        var left: Int?
        var top: Int?
        var width: Int?
        var height: Int?
    }

    struct Snapshot: Codable {
        let profileUUID: String
        let token: String?
        let windows: [WindowInfo]
    }

    /// A command the app parks on the poll endpoint until an extension picks it up.
    struct Command: Codable {
        let commandId: String
        let type: String
        var windowId: Int?
        var url: String?
        /// Geometry of the intended window. The extension resolves against this
        /// first, because window ids are reassigned when its worker restarts.
        var matchLeft: Int?
        var matchTop: Int?
        var matchWidth: Int?
        var matchHeight: Int?

        static func open(windowId: Int, url: String,
                         match: (left: Int, top: Int, width: Int, height: Int)?) -> Command {
            Command(commandId: UUID().uuidString, type: "OPEN", windowId: windowId, url: url,
                    matchLeft: match?.left, matchTop: match?.top,
                    matchWidth: match?.width, matchHeight: match?.height)
        }
        static func openNewWindow(url: String) -> Command {
            Command(commandId: UUID().uuidString, type: "OPEN_NEW_WINDOW", windowId: nil, url: url)
        }
        static let idle = Command(commandId: "", type: "IDLE", windowId: nil, url: nil)
    }

    struct CommandResult: Codable {
        let ok: Bool
        var tabId: Int?
        var windowId: Int?
        var error: String?
        /// True when the extension had to ignore the supplied window id because it
        /// had gone stale, and used the focused window instead.
        var usedFallback: Bool?
    }

    struct ResultEnvelope: Codable {
        let profileUUID: String
        let token: String?
        let commandId: String
        let result: CommandResult
    }
}
