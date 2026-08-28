import AppKit
import ApplicationServices
import os.log

/// Keeps Safari's *Develop → Allow Unsigned Extensions* switched on.
///
/// Safari refuses to load an extension unless it came from the App Store or — since
/// Safari 18.4 — is signed with a **Developer ID** and notarized, which requires paid
/// Apple Developer Program membership. An "Apple Development" certificate from a free
/// Apple ID is not sufficient. So while this app is not distributed through either
/// channel, that switch has to be on, and Safari resets it every time it relaunches.
///
/// Rather than leave the user to notice links silently going to the wrong window, the
/// app can flip it back automatically. This needs Accessibility permission, is off by
/// default, and does nothing unless explicitly enabled.
enum UnsignedExtensionsGuard {

    private static let log = Logger(subsystem: "cc.wtb.SafariSelector", category: "unsigned")

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt if permission has not been granted yet.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// State of the menu item, without changing it.
    enum State { case on, off, unavailable }

    static func currentState() -> State {
        guard let result = run(readScript) else { return .unavailable }
        switch result.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "on": return .on
        case "off": return .off
        default: return .unavailable
        }
    }

    /// Turns the setting on if it is off. Returns true if it is on afterwards.
    @discardableResult
    static func ensureEnabled() -> Bool {
        guard hasAccessibilityPermission else {
            log.info("no Accessibility permission; cannot manage the Develop menu")
            return false
        }
        switch currentState() {
        case .on:
            return true
        case .off:
            _ = run(clickScript)
            let nowOn = currentState() == .on
            DebugLog.write("Allow Unsigned Extensions was off; re-enabled: \(nowOn)")
            return nowOn
        case .unavailable:
            // Safari not running, Develop menu hidden, or Apple renamed the item.
            DebugLog.write("Allow Unsigned Extensions menu item not found")
            return false
        }
    }

    // MARK: - Scripts

    /// A menu item's checkmark shows up as its AXMenuItemMarkChar.
    private static let readScript = """
    tell application "System Events"
        if not (exists process "Safari") then return "unavailable"
        tell process "Safari"
            try
                set mi to menu item "Allow Unsigned Extensions" of menu 1 of ¬
                    menu bar item "Develop" of menu bar 1
                if value of attribute "AXMenuItemMarkChar" of mi is missing value then
                    return "off"
                else if (value of attribute "AXMenuItemMarkChar" of mi) is "" then
                    return "off"
                else
                    return "on"
                end if
            on error
                return "unavailable"
            end try
        end tell
    end tell
    """

    private static let clickScript = """
    tell application "System Events"
        tell process "Safari"
            try
                click menu item "Allow Unsigned Extensions" of menu 1 of ¬
                    menu bar item "Develop" of menu bar 1
            end try
        end tell
    end tell
    """

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let out = script.executeAndReturnError(&error)
        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
            log.warning("System Events failed: \(message, privacy: .public)")
            return nil
        }
        return out.stringValue
    }
}
