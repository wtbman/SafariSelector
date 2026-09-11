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
import SafariServices
import os.log

/// Getting the user to the extension when Safari has let it stop.
///
/// Reinstalling the app replaces the `.appex` under a running Safari. Safari kills
/// every profile's background worker when that happens and does not start them
/// again — the extension still shows as enabled, but nothing is listening, focusing
/// a window no longer wakes anything, and every link ends up in whatever window is
/// frontmost. The same happens when *Allow unsigned extensions* is reset.
///
/// Switching the extension off and on in *Safari → Settings → Extensions* restarts
/// the workers. Doing that through Accessibility was tried and is not reliable on
/// Safari 26: the off click lands, the on click is silently ignored, and the user is
/// left worse off than before. So this only takes them to the switch.
enum SafariExtension {

    static let identifier = "cc.wtb.SafariSelector.Extension"

    private static let log = Logger(subsystem: "cc.wtb.SafariSelector", category: "extension")

    /// Opens Safari's settings at this extension. Falls back to the Settings menu
    /// item when SafariServices declines — it does, for example, when the running
    /// app is not the one Safari registered the extension from.
    static func showSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: identifier) { error in
            guard let error else { return }
            log.warning("showPreferencesForExtension: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.global().async { _ = run(openSettingsScript) }
        }
    }

    /// The settings window is titled after whichever pane is showing, so it is
    /// recognised by its toolbar instead.
    private static let openSettingsScript = """
    tell application "Safari" to activate
    tell application "System Events" to tell process "Safari"
        click menu item "Settings…" of menu 1 of menu bar item "Safari" of menu bar 1
        repeat 30 times
            repeat with x in windows
                try
                    repeat with b in buttons of toolbar 1 of x
                        if (value of attribute "AXTitle" of b as text) is "Extensions" then
                            click b
                            return "ok"
                        end if
                    end repeat
                end try
            end repeat
            delay 0.1
        end repeat
        return "not found"
    end tell
    """

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let out = script.executeAndReturnError(&error)
        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
            log.warning("System Events failed: \(message, privacy: .public)")
            DebugLog.write("extension settings script error: \(message)")
            return nil
        }
        return out.stringValue
    }
}
