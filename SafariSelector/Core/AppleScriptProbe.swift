import Foundation
import os.log

/// Supplies the one thing the WebExtension API cannot: human-readable tab group names.
///
/// Safari's scripting dictionary has no tab group class either, but a window's `name`
/// is rendered as "TabGroupName — PageTitle" when the window is showing a tab group,
/// and "ProfileName — PageTitle" when it is showing loose tabs. That prefix is the
/// only place the tab group's name is exposed anywhere.
enum AppleScriptProbe {

    struct WindowName {
        let prefix: String?      // tab group name, or profile name for a loose-tab window
        let activeTabURL: String
        let tabCount: Int
    }

    private static let log = Logger(subsystem: "cc.wtb.SafariSelector", category: "applescript")

    /// U+2014 EM DASH, the separator Safari uses between prefix and page title.
    private static let separator = " — "

    private static let script = """
    tell application "Safari"
        set out to ""
        repeat with w in windows
            try
                set out to out & (name of w) & "\\t" & (URL of current tab of w) & "\\t" & (count of tabs of w) & "\\n"
            end try
        end repeat
        return out
    end tell
    """

    /// Window names keyed by active tab URL. That URL is the correlation key against
    /// the extension's view: both sides see the same active tab, and it is far more
    /// discriminating than window geometry or index.
    static func windowNamesByActiveURL() -> [String: WindowName] {
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return [:] }
        let output = apple.executeAndReturnError(&error)
        if let error {
            log.warning("AppleScript failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
        var result: [String: WindowName] = [:]
        for line in (output.stringValue ?? "").split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let name = String(fields[0])
            let url = String(fields[1])
            let count = Int(fields[2]) ?? 0
            let prefix = name.components(separatedBy: separator).first
            result[url] = WindowName(
                prefix: (prefix?.isEmpty == false && prefix != name) ? prefix : nil,
                activeTabURL: url,
                tabCount: count
            )
        }
        return result
    }
}
