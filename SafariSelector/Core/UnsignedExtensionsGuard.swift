//
//  SafariSelector — open links in a chosen Safari window's active tab group.
//  Copyright (C) 2026 SafariSelector contributors
//
//  This program is free software: you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version. See <https://www.gnu.org/licenses/>.
//

import AppKit
import ApplicationServices
import SafariServices
import os.log

/// Keeps Safari's *Allow unsigned extensions* switched on.
///
/// Where that switch lives moved in Safari 26: it used to be a Develop menu item, and
/// is now a checkbox in *Develop → Developer Settings…*. Both locations are handled,
/// the menu item first because it is cheaper and does not open a window.
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

    /// State of the switch, without changing it.
    enum State { case on, off, unavailable }

    static func currentState() -> State {
        // Older Safari: a Develop menu item.
        if let result = run(readMenuScript), let state = parse(result), state != .unavailable {
            return state
        }
        // Safari 26+: a checkbox in the Developer settings pane. Reading it means
        // opening that pane, which is closed again afterwards.
        guard let result = run(readDeveloperPaneScript) else { return .unavailable }
        return parse(result) ?? .unavailable
    }

    private static func parse(_ raw: String) -> State? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "on": return .on
        case "off": return .off
        case "unavailable": return .unavailable
        default: return nil
        }
    }

    /// What a check actually did — so the UI can say something specific rather than
    /// leaving the user wondering whether the button did anything.
    enum Outcome {
        case alreadyOn
        case turnedOn
        case couldNotTurnOn
        case noPermission
        case safariNotRunning

        var message: String {
            switch self {
            case .alreadyOn:        return "already on — nothing to do"
            case .turnedOn:         return "was off, switched it back on"
            case .couldNotTurnOn:   return "tried to switch it on, but it is still off"
            case .noPermission:     return "needs Accessibility permission"
            case .safariNotRunning: return "couldn't find the switch — is Safari running, with the Develop menu shown?"
            }
        }
    }

    @discardableResult
    static func ensureEnabled() -> Outcome {
        guard hasAccessibilityPermission else {
            log.info("no Accessibility permission; cannot manage the Develop menu")
            return .noPermission
        }
        switch currentState() {
        case .on:
            return .alreadyOn
        case .off:
            if run(clickMenuScript).map(parse) == .on {
                DebugLog.write("Allow Unsigned Extensions was off; re-enabled via menu")
                return .turnedOn
            }
            let nowOn = run(clickDeveloperPaneScript).map(parse) == .on
            DebugLog.write("Allow unsigned extensions was off; re-enabled via Developer settings: \(nowOn)")
            return nowOn ? .turnedOn : .couldNotTurnOn
        case .unavailable:
            // Safari not running, Develop menu hidden, or Apple moved it again.
            DebugLog.write("Allow unsigned extensions switch not found")
            return .safariNotRunning
        }
    }

    /// Opens *Develop → Developer Settings…* for the user, so a manual fix is one
    /// click away when the automatic one is not available.
    static func showDeveloperSettings() {
        _ = run("""
        tell application "Safari" to activate
        tell application "System Events" to tell process "Safari"
            click menu item "Developer Settings…" of menu 1 of menu bar item "Develop" of menu bar 1
        end tell
        """)
    }

    // MARK: - Scripts

    /// Pre-26 Safari: a menu item whose checkmark shows up as its AXMenuItemMarkChar.
    private static let readMenuScript = """
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

    private static let clickMenuScript = """
    tell application "System Events"
        tell process "Safari"
            try
                click menu item "Allow Unsigned Extensions" of menu 1 of ¬
                    menu bar item "Develop" of menu bar 1
            end try
        end tell
    end tell
    """ + readMenuScript

    /// Safari 26+: the Developer settings pane. Its window is titled "Developer".
    /// The checkbox is found by label with a recursive walk — `entire contents`
    /// returns nothing for this window, and hard-coding the group nesting would
    /// break on the next layout change. The pane is closed again if this opened it.
    private static func developerPaneScript(click: Bool) -> String {
        """
        on findBox(e, wanted, depth)
            if depth > 8 then return missing value
            tell application "System Events"
                try
                    if class of e is checkbox and name of e is wanted then return e
                end try
                try
                    repeat with c in UI elements of e
                        set found to my findBox(c, wanted, depth + 1)
                        if found is not missing value then return found
                    end repeat
                end try
            end tell
            return missing value
        end findBox

        tell application "System Events"
            if not (exists process "Safari") then return "unavailable"
            tell process "Safari"
                set alreadyOpen to exists window "Developer"
                if not alreadyOpen then
                    try
                        click menu item "Developer Settings…" of menu 1 of ¬
                            menu bar item "Develop" of menu bar 1
                    on error
                        return "unavailable"
                    end try
                end if
                set outcome to "unavailable"
                set cb to missing value
                repeat 30 times
                    if exists window "Developer" then
                        set cb to my findBox(window "Developer", "Allow unsigned extensions", 0)
                        if cb is not missing value then exit repeat
                    end if
                    delay 0.1
                end repeat
                if cb is not missing value then
                    \(click ? "click cb" : "")
                    delay 0.2
                    if (value of cb as integer) is 1 then
                        set outcome to "on"
                    else
                        set outcome to "off"
                    end if
                end if
                if not alreadyOpen and (exists window "Developer") then
                    try
                        click (first button of window "Developer" whose subrole is "AXCloseButton")
                    end try
                end if
                return outcome
            end tell
        end tell
        """
    }

    private static var readDeveloperPaneScript: String { developerPaneScript(click: false) }
    private static var clickDeveloperPaneScript: String { developerPaneScript(click: true) }

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
