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

        static func open(windowId: Int, url: String) -> Command {
            Command(commandId: UUID().uuidString, type: "OPEN", windowId: windowId, url: url)
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
    }

    struct ResultEnvelope: Codable {
        let profileUUID: String
        let token: String?
        let commandId: String
        let result: CommandResult
    }
}
